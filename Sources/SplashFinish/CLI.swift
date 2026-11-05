import AppKit
import SplashFinishCore

@MainActor enum CLI {
    static let version = "0.1.1"
    static let help = """
    Splash Finish \(version) — a landing strip for your AI agents

    Usage: splash-finish <command> [options]

      show                         Show the inbox
      notify                       Send an agent event (see options below)
      snooze                       Hide until the next event or for 15 minutes
      clear                        Dismiss every notification and hide
      status                       Print the persisted inbox as JSON
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
        init(_ args: ArraySlice<String>, allowed: Set<String>) throws {
            var index = args.startIndex
            while index < args.endIndex {
                let key = args[index]
                guard key.hasPrefix("--"), allowed.contains(key) else { throw EventError.invalid("Unknown option: \(key)") }
                if key == "--managed-splash-finish" { index += 1; continue }
                guard index + 1 < args.endIndex, values[key] == nil else {
                    throw EventError.invalid("Missing or repeated value for \(key)")
                }
                values[key] = args[index + 1]; index += 2
            }
        }
        subscript(_ name: String) -> String? { values["--" + name] }
    }
    static var executable: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
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
                if let event = try HookEvent.parse(agent: args[1], input: input, source: SourceNavigator.capture()) {
                    try send(DeepLink.eventURL(event))
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
                guard args.count == 1 else { throw EventError.invalid("status takes no arguments") }
                let state = try StateFile(url: AppPaths.state).load()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(state), as: UTF8.self))
            case "notify":
                let options = try Options(args.dropFirst(), allowed: ["--agent", "--task", "--status", "--title", "--detail", "--project", "--source-url"])
                guard let agent = options["agent"], let task = options["task"],
                      let status = EventStatus(rawValue: options["status"] ?? "done") else {
                    throw EventError.invalid("notify requires --agent, --task and a valid --status")
                }
                var source = SourceNavigator.capture() ?? EventSource()
                source.url = options["source-url"]
                let event = AgentEvent(task: task, agent: agent, status: status, title: options["title"] ?? "",
                                       detail: options["detail"] ?? "", project: options["project"] ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
                                       source: source)
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
