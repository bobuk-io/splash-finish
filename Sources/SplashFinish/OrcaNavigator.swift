import AppKit
import Darwin
import SplashFinishCore

@MainActor enum OrcaNavigator {
    static func open(_ source: OrcaSource, completion: @escaping (Bool) -> Void) {
        // Resolve the trusted installed app, not a path supplied by an unauthenticated
        // deep link. Finder's PATH often does not contain /usr/local/bin.
        guard (try? source.validated()) != nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OrcaSource.bundleID) else {
            completion(false); return
        }
        let cli = app.appendingPathComponent("Contents/Resources/bin/orca")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { completion(false); return }
        run(cli, ["terminal", "list", "--limit", "10000", "--json"]) { data in
            guard let data, let terminals = try? OrcaReply.terminals(from: data),
                  let handle = source.resolve(in: terminals),
                  (try? OrcaSource(terminal: handle).validated()) != nil else { completion(false); return }
            run(cli, ["terminal", "switch", "--terminal", handle, "--json"]) { result in
                let switched = result.map(OrcaReply.switched) ?? false
                if switched {
                    NSRunningApplication.runningApplications(withBundleIdentifier: OrcaSource.bundleID).first?.activate(options: [])
                }
                completion(switched)
            }
        }
    }

    /// Bounded background execution: hooks do not call Orca, only a user click does.
    /// Never use a shell or allow event data to choose an executable/subcommand.
    private static func run(_ cli: URL, _ arguments: [String], completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = cli
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // GUI navigation is strictly local; do not inherit a paired-server target.
            for key in ["ORCA_ENVIRONMENT", "ORCA_PAIRING_CODE", "ORCA_TERMINAL_HANDLE", "ORCA_WORKTREE_ID", "ORCA_WORKSPACE_ID", "NODE_OPTIONS", "NODE_REPL_EXTERNAL_MODULE"] {
                environment.removeValue(forKey: key)
            }
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
                defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
                var output = Data()
                var oversized = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                    output.append(chunk)
                    if output.count > 2_000_000 {
                        oversized = true
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                }
                process.waitUntilExit()
                let result = !oversized && process.terminationStatus == 0 ? output : nil
                DispatchQueue.main.async { completion(result) }
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
