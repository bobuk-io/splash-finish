import AppKit
import Darwin
import SplashFinishCore

@MainActor enum AgtermNavigator {
    typealias Runner = (URL, [String], @escaping (Data?, String?) -> Void) -> Void

    static func open(_ source: AgtermSource, completion: @escaping (Bool, String?) -> Void) {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: AgtermSource.bundleID)
        guard applications.count == 1, let application = applications.first,
              let bundle = application.bundleURL, let executable = executable(app: bundle) else {
            completion(false, "Agterm must already be running with its bundled agtermctl installed."); return
        }
        navigate(source, executable: executable, activate: { application.activate(options: []) },
                 run: run, completion: completion)
    }

    static func navigate(_ source: AgtermSource, executable: URL,
                         activate: @escaping () -> Bool, run: @escaping Runner,
                         socketIsTrusted: @escaping (String) -> Bool = trustedSocket,
                         completion: @escaping (Bool, String?) -> Void) {
        guard (try? source.validated()) != nil else { completion(false, "Invalid Agterm source."); return }
        Navigation(source: source, executable: executable, activate: activate, run: run,
                   socketIsTrusted: socketIsTrusted, completion: completion).start()
    }

    static func executable(app: URL) -> URL? {
        guard app.isFileURL, app.pathExtension == "app",
              Bundle(url: app)?.bundleIdentifier == AgtermSource.bundleID else { return nil }
        let cli = app.appendingPathComponent("Contents/MacOS/agtermctl")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    nonisolated static func trustedSocket(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0 &&
            info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
    }

    private struct Reply<Value: Decodable>: Decodable { let ok: Bool; let result: Value }
    private struct Acknowledgement: Decodable { let id: String? }
    private struct Windows: Decodable { let windows: [Window] }
    private struct Window: Decodable {
        let id: UUID
        let open: Bool
        let active: Bool
        let remote: Remote?
        struct Remote: Decodable { let host: String? }
    }
    private struct TreeResult: Decodable { let tree: Tree }
    private struct Tree: Decodable {
        let workspaces: [Workspace]
        let zoomedSurface: String?
        let quickVisible: Bool?
        let pickPending: String?
        let askPending: String?
        let dashboardMembers: [String]?
        var sessions: [Session] { workspaces.flatMap(\.sessions) }
        struct Workspace: Decodable { let sessions: [Session] }
        var obstructed: Bool {
            quickVisible == true || pickPending != nil || askPending != nil || dashboardMembers != nil
        }
    }
    private struct Session: Decodable {
        let id: UUID
        let active: Bool
        let split: Bool
        let scratch: Bool
        let overlay: Bool
        let surfaces: [Surface]
        var hasSplit: Bool { split || surfaces.contains { $0.kind == "right" } }
    }
    private struct Surface: Decodable {
        let id: String
        let kind: String
        let paneID: UUID?
        let active: Bool
        let visible: Bool
        let remote: Bool?
    }

    @MainActor private final class Navigation {
        let source: AgtermSource
        let executable: URL
        let activate: () -> Bool
        let run: Runner
        let socketIsTrusted: (String) -> Bool
        let completion: (Bool, String?) -> Void
        var finished = false

        init(source: AgtermSource, executable: URL, activate: @escaping () -> Bool,
             run: @escaping Runner, socketIsTrusted: @escaping (String) -> Bool,
             completion: @escaping (Bool, String?) -> Void) {
            self.source = source; self.executable = executable; self.activate = activate
            self.run = run; self.socketIsTrusted = socketIsTrusted; self.completion = completion
        }

        func fail(_ detail: String) {
            guard !finished else { return }
            finished = true
            completion(false, "Could not return to the original Agterm destination. " + detail)
        }

        func request<Value: Decodable>(_ command: [String], as: Value.Type,
                                       then: @escaping (Value) -> Void) {
            guard !finished else { return }
            guard socketIsTrusted(source.socket) else {
                fail("The captured local socket is missing, is not a socket, or is not owned by this user."); return
            }
            run(executable, command + ["--socket", source.socket, "--json"]) { data, error in
                guard !self.finished else { return }
                guard error == nil, let data else {
                    self.fail(error ?? "agtermctl returned no response."); return
                }
                guard let reply = try? JSONDecoder().decode(Reply<Value>.self, from: data), reply.ok else {
                    let detail = AgentEvent.clean(String(decoding: data, as: UTF8.self), limit: 300)
                    self.fail("agtermctl refused the request or returned an invalid response. " + detail); return
                }
                then(reply.result)
            }
        }

        func mutate(_ command: [String], then: @escaping () -> Void) {
            request(command, as: Acknowledgement.self) { _ in then() }
        }

        func start() {
            request(["window", "list"], as: Windows.self) { reply in
                let local = reply.windows.filter { $0.open && $0.remote == nil }
                let originalWindow = UUID(uuidString: self.source.window)
                let ordered = local.filter { $0.id == originalWindow } + local.filter { $0.id != originalWindow }
                self.discover(ordered, index: 0)
            }
        }

        func discover(_ windows: [Window], index: Int) {
            guard index < windows.count else {
                fail("The original session is not in any open local window. No window was reopened."); return
            }
            let window = windows[index]
            readTree(window.id) { tree in
                let sessionID = UUID(uuidString: self.source.session)
                let matches = tree.sessions.filter { $0.id == sessionID }
                guard !matches.isEmpty else { self.discover(windows, index: index + 1); return }
                guard self.destination(in: tree) != nil else { return }
                self.select(in: window.id)
            }
        }

        func readTree(_ window: UUID, then: @escaping (Tree) -> Void) {
            request(["tree", "--window", window.uuidString], as: TreeResult.self) { then($0.tree) }
        }

        // Resolving the stable token again after selection avoids relying on a stale spawn role.
        func destination(in tree: Tree) -> (Session, Surface?)? {
            let sessionID = UUID(uuidString: source.session)
            let sessions = tree.sessions.filter { $0.id == sessionID }
            guard sessions.count == 1 else { fail("The original session disappeared or is ambiguous."); return nil }
            let session = sessions[0]
            guard let pane = source.pane else { return (session, nil) }
            let paneID = UUID(uuidString: pane)
            let surfaces = session.surfaces.filter { $0.paneID == paneID }
            guard surfaces.count == 1, let surface = surfaces.first,
                  ["left", "right", "scratch"].contains(surface.kind), surface.remote != true else {
                fail("The original pane no longer exists as a local terminal in its session."); return nil
            }
            return (session, surface)
        }

        func sessionArguments(_ command: [String], window: UUID) -> [String] {
            command + ["--target", source.session, "--window", window.uuidString]
        }

        func select(in window: UUID) {
            // Recheck before window.select: that command can otherwise reopen a closed window.
            request(["window", "list"], as: Windows.self) { reply in
                guard reply.windows.contains(where: { $0.id == window && $0.open && $0.remote == nil }) else {
                    self.fail("The destination window closed or became remote."); return
                }
                self.mutate(self.sessionArguments(["session", "select"], window: window)) {
                    guard self.source.pane != nil else { self.raise(window); return }
                    self.readTree(window) { tree in
                        guard let (session, surface) = self.destination(in: tree), let surface else { return }
                        if surface.kind != "scratch" && session.scratch {
                            self.mutate(self.sessionArguments(["session", "scratch", "off"], window: window)) {
                                self.focusPane(in: window)
                            }
                        } else {
                            self.focusPane(in: window, tree: tree)
                        }
                    }
                }
            }
        }

        func focusPane(in window: UUID, tree: Tree? = nil) {
            guard let tree else { readTree(window) { self.focusPane(in: window, tree: $0) }; return }
            guard let (session, surface) = destination(in: tree), let surface else { return }
            if surface.kind == "scratch" {
                if session.scratch && surface.active && surface.visible { raise(window); return }
                // The preceding live tree must still contain this exact scratch token. Never create a replacement.
                mutate(sessionArguments(["session", "scratch", "on"], window: window)) { self.raise(window) }
            } else if session.hasSplit {
                mutate(sessionArguments(["session", "focus", surface.kind], window: window)) { self.raise(window) }
            } else {
                guard surface.kind == "left" else { fail("The original split pane disappeared."); return }
                raise(window)
            }
        }

        func raise(_ window: UUID) {
            request(["window", "list"], as: Windows.self) { reply in
                guard reply.windows.contains(where: { $0.id == window && $0.open && $0.remote == nil }) else {
                    self.fail("The destination window closed or became remote."); return
                }
                self.mutate(["window", "select", window.uuidString]) {
                    guard self.activate() else { self.fail("Agterm could not be activated. The notification was kept."); return }
                    self.confirm(window)
                }
            }
        }

        func confirm(_ window: UUID) {
            request(["window", "list"], as: Windows.self) { reply in
                let active = reply.windows.filter { $0.active && $0.open }
                guard active.count == 1, active[0].id == window, active[0].remote == nil else {
                    self.fail("Agterm did not confirm the exact active local window."); return
                }
                self.readTree(window) { tree in
                    guard let (session, surface) = self.destination(in: tree) else { return }
                    guard session.active, tree.sessions.filter({ $0.active }).count == 1, !tree.obstructed else {
                        self.fail("The original session is not active or is covered by a picker, dashboard, or quick terminal."); return
                    }
                    if let surface {
                        guard surface.active, surface.visible,
                              tree.zoomedSurface == nil || tree.zoomedSurface == surface.id else {
                            self.fail("The original pane is not active and visible. An overlay or zoom may still cover it."); return
                        }
                    } else {
                        guard session.surfaces.contains(where: {
                            $0.active && $0.visible && (tree.zoomedSurface == nil || tree.zoomedSurface == $0.id)
                        }) else {
                            self.fail("The original session has no active visible surface. An overlay or zoom may still cover it."); return
                        }
                    }
                    self.finished = true
                    self.completion(true, nil)
                }
            }
        }
    }

    private static func run(_ executable: URL, _ arguments: [String], completion: @escaping (Data?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys.filter({ $0.hasPrefix("AGTERM_") }) { environment.removeValue(forKey: key) }
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            do {
                try process.run()
                try pipe.fileHandleForWriting.close()
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    DispatchQueue.main.async { completion(nil, "The agtermctl response could not be read safely.") }; return
                }
                let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
                var output = Data(), buffer = [UInt8](repeating: 0, count: 16384)
                var failure: String?
                while true {
                    if DispatchTime.now().uptimeNanoseconds >= deadline {
                        failure = "agtermctl timed out. Check that the original Agterm instance is responding."; break
                    }
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        guard output.count + count <= 2_000_000 else { failure = "agtermctl returned too much data."; break }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 || (count < 0 && errno == EAGAIN && !process.isRunning) {
                        break
                    } else if count < 0 && errno != EAGAIN && errno != EINTR {
                        failure = "The agtermctl response could not be read."; break
                    } else { usleep(10_000) }
                }
                while failure == nil && process.isRunning {
                    if DispatchTime.now().uptimeNanoseconds >= deadline { failure = "agtermctl timed out."; break }
                    usleep(10_000)
                }
                if failure != nil && process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                let ok = failure == nil && process.terminationStatus == 0
                let error: String?
                if ok {
                    error = nil
                } else {
                    let detail = AgentEvent.clean(String(decoding: output, as: UTF8.self), limit: 400)
                    error = failure ?? (detail.isEmpty ? "agtermctl refused the request." : detail)
                }
                DispatchQueue.main.async { completion(ok ? output : nil, error) }
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                DispatchQueue.main.async { completion(nil, "The running Agterm app's bundled CLI could not run.") }
            }
        }
    }
}
