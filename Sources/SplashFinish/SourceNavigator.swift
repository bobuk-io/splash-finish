import AppKit
import Darwin
import SplashFinishCore

@MainActor enum SourceNavigator {
    static func capture() -> EventSource? {
        var pid = getppid()
        for _ in 0..<48 {
            guard pid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleID = app.bundleIdentifier, bundleID != AppPaths.bundleID,
               app.activationPolicy != .prohibited {
                return EventSource(pid: pid, bundleID: bundleID)
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            let result = mib.withUnsafeMutableBufferPointer { buffer in
                sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
            }
            guard result == 0, size > 0, info.kp_eproc.e_ppid != pid else { break }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }
    static func open(_ event: AgentEvent, model: AppModel) {
        if let raw = event.source?.url, AgentEvent.isSafeSourceURL(raw), let url = URL(string: raw) {
            if NSWorkspace.shared.open(url) { return }
        }
        if let pid = event.source?.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           let bundle = event.source?.bundleID, app.bundleIdentifier == bundle {
            if app.activate(options: [.activateAllWindows]) { return }
        }
        if let bundle = event.source?.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
           app.activate(options: [.activateAllWindows]) { return }
        model.message = "Source unavailable. The original app may have closed."
    }
}
