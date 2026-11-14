import AppKit
import Darwin
import SplashFinishCore

@MainActor enum RexNavigator {
    static func open(_ source: RexSource, completion: @escaping (Bool, String?) -> Void) {
        guard (try? source.validated()) != nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RexSource.bundleID),
              let executable = executable(app: app) else {
            completion(false, "Rex is unavailable. Install Rex with its CLI, then try again."); return
        }
        navigate(source, executable: executable, client: localClient, activate: {
            NSRunningApplication.runningApplications(withBundleIdentifier: RexSource.bundleID)
                .first?.activate(options: []) == true
        }, run: run, completion: completion)
    }

    typealias Runner = (URL, [String], @escaping (Data?, String?) -> Void) -> Void
    static func navigate(_ source: RexSource, executable: URL,
                         client: @escaping (Data) -> String?, activate: @escaping () -> Bool,
                         run: @escaping Runner, completion: @escaping (Bool, String?) -> Void) {
        guard (try? source.validated()) != nil else { completion(false, "Invalid Rex source."); return }
        let fail: (String) -> Void = { completion(false, "Could not return to the original Rex pane. " + $0) }
        run(executable, source.inspectArguments) { data, error in
            guard let data, let window = try? source.window(from: data) else {
                fail(error ?? "The pane is closed or no longer belongs to its original session."); return
            }
            run(executable, ["client", "ls", "--json"]) { data, error in
                // A remote app or a CLI connection must never receive local UI actions.
                guard let data, let client = client(data) else {
                    fail(error ?? "Keep exactly one local Rex Mac app connected. Multiple clients are ambiguous."); return
                }
                run(executable, source.focusArguments) { data, error in
                    guard data != nil else { fail(error ?? "The original pane could not be focused."); return }
                    guard let arguments = try? source.selectArguments(client: client, window: window) else {
                        fail("Invalid Rex navigation coordinates."); return
                    }
                    run(executable, arguments) { data, error in
                        // session.select is a synchronous client action. A successful exit
                        // acknowledges the client request; null is its documented void reply.
                        guard data != nil else {
                            fail(error ?? "Rex must be open with Remote Control enabled. Splash Finish never enables it."); return
                        }
                        run(executable, ["session", "inspect", source.session, "--json"]) { data, error in
                            guard let data, source.focused(in: data, window: window),
                                  activate() else {
                                fail(error ?? "Rex did not confirm the original tab and pane. The notification was kept."); return
                            }
                            completion(true, nil)
                        }
                    }
                }
            }
        }
    }

    static func executable(app: URL) -> URL? {
        // Finder has a minimal PATH. Both the app helper and the installed server
        // CLI are stable discovery locations; event data never supplies this path.
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let candidates = [app.appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"),
            support.appendingPathComponent("com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func localClient(_ data: Data) -> String? {
        localClient(data, pids: Set(NSRunningApplication.runningApplications(withBundleIdentifier: RexSource.bundleID).map(\.processIdentifier)))
    }

    static func localClient(_ data: Data, pids: Set<Int32>) -> String? {
        struct Reply: Decodable {
            struct Client: Decodable {
                struct Info: Decodable { var kind: String; var platform: String }
                struct Principal: Decodable { var transport: String; var pid: Int32?; var uid: UInt32? }
                var client_id: String; var info: Info?; var principal: Principal?; var connection_state: String
            }
            var clients: [Client]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        let clients = reply.clients.filter {
            $0.info?.kind == "app" && $0.info?.platform == "macos" && $0.connection_state == "connected" &&
            $0.principal?.transport == "unix" && $0.principal?.uid == getuid() &&
            $0.principal?.pid.map { pids.contains($0) } == true && RexSource.isID($0.client_id, kind: "client")
        }
        return clients.count == 1 ? clients[0].client_id : nil
    }

    private static func run(_ executable: URL, _ arguments: [String], completion: @escaping (Data?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["--autostart=false", "--timeout", "3s"] + arguments
            var environment = ProcessInfo.processInfo.environment
            // Always use the default local server. Never use an inherited host,
            // session, block, or client from the GUI launch environment.
            for key in environment.keys.filter({ $0.hasPrefix("REX_") }) { environment.removeValue(forKey: key) }
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                let timer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timer)
                defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
                var output = Data(), oversized = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                    output.append(chunk)
                    if output.count > 2_000_000 {
                        oversized = true
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                }
                process.waitUntilExit()
                let ok = !oversized && process.terminationStatus == 0
                let detail = AgentEvent.clean(String(decoding: output, as: UTF8.self), limit: 400)
                let error = detail.isEmpty ? "Rex timed out or refused the request. Check that Rex is open and Remote Control is enabled." : detail
                DispatchQueue.main.async { completion(ok ? output : nil, ok ? nil : error) }
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                DispatchQueue.main.async { completion(nil, "The installed Rex CLI could not run.") }
            }
        }
    }
}
