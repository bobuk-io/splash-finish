import AppKit
import Darwin
import SplashFinishCore

@MainActor enum SourceNavigator {
    static func capture(environment env: [String: String] = ProcessInfo.processInfo.environment) -> EventSource? {
        // PTY hosts can obscure the app ancestor. Inherited terminal coordinates
        // are both more precise and cheaper than walking the process tree.
        if let rex = RexSource.capture(environment: env) {
            return EventSource(bundleID: RexSource.bundleID, rex: rex)
        }
        if let orca = OrcaSource.capture(environment: env) {
            return EventSource(bundleID: OrcaSource.bundleID, orca: orca)
        }
        var pid = getppid()
        for _ in 0..<48 {
            guard pid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleID = app.bundleIdentifier, bundleID != AppPaths.bundleID,
               app.activationPolicy != .prohibited {
                let pane = bundleID == "com.github.wez.wezterm" ? env["WEZTERM_PANE"].flatMap(UInt64.init) : nil
                return EventSource(pid: pid, bundleID: bundleID, weztermPane: pane)
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
    /// True means the source link was accepted or the exact terminal pane was reached.
    /// Merely activating an app is a fallback, not proof of reaching the right tab.
    static func open(_ event: AgentEvent, model: AppModel, completion: @escaping (Bool) -> Void) {
        if let raw = event.source?.url, AgentEvent.isSafeSourceURL(raw), let url = URL(string: raw) {
            if NSWorkspace.shared.open(url) { completion(true); return }
        }
        if let rex = event.source?.rex {
            RexNavigator.open(rex) { opened, message in
                if !opened { model.message = message }
                completion(opened)
            }
            return
        }
        if let orca = event.source?.orca {
            OrcaNavigator.open(orca) { opened in
                if !opened {
                    NSRunningApplication.runningApplications(withBundleIdentifier: OrcaSource.bundleID).first?.activate(options: [])
                    model.message = "The original Orca chat or terminal is unavailable. No other project was selected."
                }
                completion(opened)
            }
            return
        }
        if let pane = event.source?.weztermPane, event.source?.bundleID == "com.github.wez.wezterm",
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") {
            let cli = app.appendingPathComponent("Contents/MacOS/wezterm")
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process(); process.executableURL = cli
                process.arguments = ["cli", "--no-auto-start", "activate-pane", "--pane-id", String(pane)]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                process.terminationHandler = { process in
                    DispatchQueue.main.async {
                        if process.terminationStatus == 0,
                           NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.wez.wezterm").first?.activate(options: []) == true {
                            completion(true)
                        } else {
                            activateApp(event, model: model, completion: completion)
                        }
                    }
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        if process.isRunning { process.terminate() }
                    }
                    return
                } catch { /* Fall back to activating the source app. */ }
            }
        }
        activateApp(event, model: model, completion: completion)
    }
    private static func activateApp(_ event: AgentEvent, model: AppModel, completion: (Bool) -> Void) {
        defer { completion(false) }
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
