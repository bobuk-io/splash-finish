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
        attempt(source.targets, index: 0, source: source, app: app, completion: completion)
    }

    /// Each attempt is independent: a stale terminal handle must not stop the
    /// chat reveal that follows it, and activation is never proof of arrival.
    private static func attempt(_ targets: [OrcaTarget], index: Int, source: OrcaSource, app: URL,
                               completion: @escaping (Bool) -> Void) {
        guard index < targets.count else { completion(false); return }
        let next = { attempt(targets, index: index + 1, source: source, app: app, completion: completion) }
        switch targets[index] {
        case .terminal:
            switchTerminal(source, app: app) { opened in
                if opened { activate(); completion(true) } else { next() }
            }
        case .chat:
            guard let session = source.session else { next(); return }
            revealChat(session, app: app) { opened in
                if opened { activate(); completion(true) } else { next() }
            }
        }
    }

    private static func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: OrcaSource.bundleID).first?.activate(options: [])
    }

    private static func switchTerminal(_ source: OrcaSource, app: URL, completion: @escaping (Bool) -> Void) {
        let cli = app.appendingPathComponent("Contents/Resources/bin/orca")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { completion(false); return }
        run(cli, ["terminal", "list", "--limit", "10000", "--json"], environment: orcaEnvironment(), timeout: 4) { data in
            guard let data, let terminals = try? OrcaReply.terminals(from: data),
                  let handle = source.resolve(in: terminals),
                  (try? OrcaSource(terminal: handle).validated()) != nil else { completion(false); return }
            run(cli, ["terminal", "switch", "--terminal", handle, "--json"], environment: orcaEnvironment(), timeout: 4) { result in
                completion(result.map(OrcaReply.switched) ?? false)
            }
        }
    }

    /// Orca's chat has no terminal handle, so the only exact route back is its own
    /// runtime client. That client is bundled with the installed app and needs a
    /// Node runtime, which Electron provides through ELECTRON_RUN_AS_NODE.
    private static func revealChat(_ session: String, app: URL, completion: @escaping (Bool) -> Void) {
        guard let script = Bundle.module.url(forResource: "reveal-agent-session", withExtension: "js", subdirectory: "Orca"),
              let executable = Bundle(url: app)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { completion(false); return }
        let resources = app.appendingPathComponent("Contents/Resources")
        let client = ["app.asar.unpacked/out/cli/runtime-client.js", "app.asar/out/cli/runtime-client.js"]
            .map { resources.appendingPathComponent($0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
        guard let client else { completion(false); return }
        var environment = orcaEnvironment()
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        run(executable, [script.path, client.path, session], environment: environment, timeout: 8) { data in
            completion(data.map { OrcaReply.revealed($0, session: session) } ?? false)
        }
    }

    /// GUI navigation is strictly local; do not inherit a paired-server target.
    private static func orcaEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ORCA_ENVIRONMENT", "ORCA_PAIRING_CODE", "ORCA_TERMINAL_HANDLE", "ORCA_WORKTREE_ID",
                    "ORCA_WORKSPACE_ID", "ORCA_AGENT_SESSION_ID", "NODE_OPTIONS", "NODE_REPL_EXTERNAL_MODULE"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// Bounded background execution: hooks do not call Orca, only a user click does.
    /// Never use a shell or allow event data to choose an executable/subcommand.
    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                            timeout: TimeInterval, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                defer { timeoutItem.cancel(); try? pipe.fileHandleForReading.close() }
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
