import AppKit
import SplashFinishCore

@MainActor enum CLI {
    /// Single source of truth is version.env, injected into Info.plist by package_app.sh.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }
    static let help = """
    Splash Finish \(version) — a landing strip for your AI agents

    Usage: splash-finish <command> [options]

      show                         Show the inbox
      notify                       Send an agent event (see options below)
      snooze                       Hide until the next event or for 15 minutes
      clear                        Dismiss every notification and hide
      status [--raw]               Summarize the inbox, or print full JSON with --raw
      doctor                       Diagnose agent integrations
      install-skills               Install agent skills, hooks and pi extension
      uninstall-skills             Remove only Splash Finish integrations
      version                      Print the version

    notify options:
      --agent NAME                 Agent display name (required)
      --task ID                    Stable session/task identifier (required)
      --status done|attention|running   Default: done; running removes a stale entry
      --title TEXT                 A short result or question
      --detail TEXT                Supporting text
      --project NAME               Project label (default: working directory)
      --source-url URL             Optional link to the originating session
      --run INTEGER                Optional monotonic run generation
      --sequence INTEGER           Optional sequence within the run

    install-skills / uninstall-skills options:
      --agent all|claude|codex|pi   Default: all

    Examples:
      splash-finish install-skills
      splash-finish notify --agent Codex --task auth --title 'Authentication fixed'
      splash-finish uninstall-skills --agent pi

    Hooks are observers, not permission gates. Codex hooks require trust via /hooks.
    """

    struct Options {
        var values = [String: String]()
        init(_ args: ArraySlice<String>, allowed: Set<String>, flags: Set<String> = []) throws {
            var index = args.startIndex
            while index < args.endIndex {
                let key = args[index]
                guard key.hasPrefix("--"), allowed.contains(key) else { throw EventError.invalid("Unknown option: \(key)") }
                if key == "--managed-splash-finish" { index += 1; continue }
                if flags.contains(key) {
                    guard values[key] == nil else { throw EventError.invalid("Repeated option: \(key)") }
                    values[key] = "true"; index += 1; continue
                }
                guard index + 1 < args.endIndex, values[key] == nil else {
                    throw EventError.invalid("Missing or repeated value for \(key)")
                }
                values[key] = args[index + 1]; index += 2
            }
        }
        subscript(_ name: String) -> String? { values["--" + name] }
    }
    static var executable: String {
        // Finder/Launch Services can supply a bare argv[0], unrelated to the current directory.
        if Bundle.main.bundleURL.pathExtension == "app", let url = Bundle.main.executableURL {
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func integrationInstaller() throws -> IntegrationInstaller {
        guard let resources = Bundle.module.url(forResource: "Integrations", withExtension: nil) else {
            throw EventError.invalid("Integration resources are missing; reinstall the app")
        }
        return IntegrationInstaller(executable: executable, resources: resources)
    }
    static func send(_ url: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let executableURL = URL(fileURLWithPath: executable)
        let app = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" { process.arguments = ["-g", "-a", app.path, url.absoluteString] }
        else { process.arguments = ["-g", url.absoluteString] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EventError.invalid("Could not contact Splash Finish. Install and open Splash Finish.app first.") }
    }
    /// Cheap read of the persisted inbox; used to skip no-op hook work.
    private static func hasInboxEntry(_ key: String) -> Bool {
        guard let inbox = try? StateFile(url: AppPaths.state).load() else { return false }
        return inbox.items.contains { $0.key == key }
    }
    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else { return 0 }
        // Hook output must never deny tools, alter prompts or fail the agent's run.
        if command == "hook" {
            do {
                guard args.count >= 2 else { return 0 }
                var input = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
                    input.append(chunk)
                    if input.count > 1_048_576 { print("{}"); return 0 }
                }
                if var event = try HookEvent.parse(agent: args[1], input: input) {
                    // Claude Code and Codex run a hook on every tool call. A progress event
                    // only clears an existing "working" entry, so skip the process inspection
                    // and the deep link entirely when the inbox has nothing to clear.
                    if event.status != .running || event.phase != "progress" || hasInboxEntry(event.key) {
                        event.source = SourceNavigator.capture()
                        try send(DeepLink.eventURL(event))
                    }
                }
            } catch { /* Best effort. Nothing agent-facing, no transcript or secret logging. */ }
            print("{}")
            return 0
        }
        do {
            switch command {
            case "help", "--help", "-h": print(help)
            case "version", "--version": print(version)
            case "show", "snooze", "clear":
                guard args.count == 1 else { throw EventError.invalid("\(command) takes no arguments") }
                try send(URL(string: "\(DeepLink.scheme)://\(command)")!)
            case "status":
                let options = try Options(args.dropFirst(), allowed: ["--raw"], flags: ["--raw"])
                let state = try StateFile(url: AppPaths.state).load()
                if options["raw"] != nil {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(state), as: UTF8.self))
                } else {
                    let formatter = ISO8601DateFormatter()
                    print("attention: \(state.attention.count)  completed: \(state.completed.count)  snoozed: \(state.snoozedUntil.map { formatter.string(from: $0) } ?? "no")")
                    // Newest first, matching how the panel groups attention before completed.
                    for event in (state.attention + state.completed).reversed() {
                        print([event.status.rawValue, event.agent, event.project, event.title]
                            .filter { !$0.isEmpty }.joined(separator: " | "))
                    }
                    if !state.items.isEmpty { print("Use --raw for the full JSON state.") }
                }
            case "doctor":
                guard args.count == 1 else { throw EventError.invalid("doctor takes no arguments") }
                let inbox = try StateFile(url: AppPaths.state).load()
                let statuses = try integrationInstaller().inspect(inbox: inbox)
                let formatter = ISO8601DateFormatter()
                for item in statuses {
                    print("\(item.agent.rawValue): \(item.state.rawValue)")
                    print("  \(item.detail)")
                    if item.agent == .pi {
                        print(item.piAskDetected ? "  pi-agent-ask detected; run install-skills to enable rich questions." : "  pi-agent-ask not detected globally; install: pi install npm:pi-agent-ask (project-local installs may still work).")
                    }
                    print("  Last event: \(item.lastEvent.map { formatter.string(from: $0) } ?? "none recorded")")
                }
            case "notify":
                let options = try Options(args.dropFirst(), allowed: ["--agent", "--task", "--status", "--title", "--detail", "--project", "--source-url", "--run", "--sequence"])
                guard let agent = options["agent"], let task = options["task"],
                      let status = EventStatus(rawValue: options["status"] ?? "done") else {
                    throw EventError.invalid("notify requires --agent, --task and a valid --status")
                }
                var source = SourceNavigator.capture() ?? EventSource()
                source.url = options["source-url"]
                let run = options["run"].flatMap(Int64.init), sequence = options["sequence"].flatMap(Int64.init)
                guard (options["run"] == nil && options["sequence"] == nil) || (run != nil && sequence != nil) else {
                    throw EventError.invalid("--run and --sequence must both be integers")
                }
                let event = AgentEvent(task: task, agent: agent, status: status, title: options["title"] ?? "",
                                       detail: options["detail"] ?? "", project: options["project"] ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
                                       source: source, run: run, sequence: sequence)
                try send(DeepLink.eventURL(event))
            case "install-skills", "uninstall-skills":
                let options = try Options(args.dropFirst(), allowed: ["--agent"])
                let selection = options["agent"] ?? "all"
                let agents: [AgentKind]
                if selection == "all" { agents = AgentKind.allCases }
                else if let agent = AgentKind(rawValue: selection) { agents = [agent] }
                else { throw EventError.invalid("Agent must be all, claude, codex or pi") }
                try integrationInstaller().run(install: command == "install-skills", agents: agents).forEach { print($0) }
            default: throw EventError.invalid("Unknown command: \(command). Try splash-finish --help")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Splash Finish: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
