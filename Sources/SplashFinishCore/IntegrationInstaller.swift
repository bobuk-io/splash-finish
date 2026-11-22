import BobukCore
import Foundation

public enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, copilot, agy, pi, omp

    fileprivate var patchesHooks: Bool {
        self == .claude || self == .codex
    }
}

public enum IntegrationState: String, Sendable {
    case notInstalled = "not installed"
    case installed
    case incomplete
    case updateAvailable = "update available"
    case error
}

public struct IntegrationStatus: Identifiable, Sendable {
    public var id: String { agent.rawValue }
    public var agent: AgentKind
    public var state: IntegrationState
    public var detail: String
    public var lastEvent: Date?
    public var richQuestionsEnabled: Bool = false
    public var piAskDetected: Bool = false
}

public struct IntegrationInstaller {
    public let home: URL
    public let environment: [String: String]
    public let executable: String
    public let resources: URL
    private let marker = "--managed-splash-finish"
    private let fileMarker = "Managed by Splash Finish"
    private let piExtensionMarker = "// Managed by Splash Finish. Reinstall to update; uninstall-skills removes this file."
    private let ompExtensionMarker = "// Managed by Splash Finish (OMP). Reinstall to update; uninstall-skills removes this file."
    private static let ompProfileWhitespace = CharacterSet.whitespacesAndNewlines
        .subtracting(CharacterSet(charactersIn: "\u{0085}"))
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                executable: String, resources: URL) {
        self.home = home; self.environment = environment; self.executable = executable; self.resources = resources
    }
    private var piRoot: URL {
        environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".pi/agent")
    }
    private func ompProfile(_ value: String?) throws -> String? {
        // Match OMP's normalizeProfileName, including its portable filename rules.
        guard let name = value?.trimmingCharacters(in: Self.ompProfileWhitespace),
              !name.isEmpty, name != "default" else { return nil }
        guard name.wholeMatch(of: #/[a-z0-9][a-z0-9._-]{0,63}/#) != nil,
              !name.hasSuffix("."),
              name.wholeMatch(of: #/(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\..*)?/#) == nil else {
            throw EventError.invalid("Invalid OMP profile. Set OMP_PROFILE or PI_PROFILE to a valid OMP profile name.")
        }
        return name
    }
    private func ompRoot() throws -> URL {
        let config = environment["PI_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let configRoot = home.appendingPathComponent(config, isDirectory: true).standardizedFileURL
        func profileRoot(_ name: String) -> URL {
            configRoot.appendingPathComponent("profiles/\(name)/agent", isDirectory: true)
        }
        if let profile = try ompProfile(environment["OMP_PROFILE"] ?? environment["PI_PROFILE"]) {
            return profileRoot(profile)
        }
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            // OMP ignores an inherited override exported by a bypassed named profile.
            let legacyDir = (try? ompProfile(environment["PI_PROFILE"])).map { profileRoot($0).path }
            if override != legacyDir {
                return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            }
        }
        return configRoot.appendingPathComponent("agent", isDirectory: true)
    }
    private func root(_ agent: AgentKind) throws -> URL {
        let key: String; let fallback: String
        switch agent {
        case .claude: key = "CLAUDE_CONFIG_DIR"; fallback = ".claude"
        case .codex: key = "CODEX_HOME"; fallback = ".codex"
        case .copilot: key = "COPILOT_HOME"; fallback = ".copilot"
        case .agy: key = "ANTIGRAVITY_CONFIG_DIR"; fallback = ".gemini/config"
        case .pi: return piRoot
        case .omp: return try ompRoot()
        }
        return environment[key].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(fallback)
    }
    private func sameAgentRoot(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhs = lhs.standardizedFileURL, rhs = rhs.standardizedFileURL
        if lhs.path == rhs.path { return true }

        // Compare through macOS aliases even before the destination exists.
        func resolve(_ url: URL) -> (path: String, ancestor: URL) {
            var ancestor = url
            while ancestor.path != "/" && !FileManager.default.fileExists(atPath: ancestor.path) {
                ancestor.deleteLastPathComponent()
            }
            let canonical = ancestor.resolvingSymlinksInPath()
            let suffix = url.pathComponents.dropFirst(ancestor.pathComponents.count)
            let destination = suffix.reduce(canonical) { $0.appendingPathComponent($1, isDirectory: true) }
            return (destination.path, canonical)
        }
        let left = resolve(lhs), right = resolve(rhs)
        if left.path == right.path { return true }
        guard left.path.caseInsensitiveCompare(right.path) == .orderedSame else { return false }
        return (try? left.ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
    }
    /// Detect a configured, installed global package; project-local extensions may still exist.
    public func piAgentAskDetected() -> Bool {
        guard let settings = try? readObject(piRoot.appendingPathComponent("settings.json")),
              let packages = settings["packages"] as? [Any] else { return false }
        for entry in packages {
            let object = entry as? [String: Any]
            let source = (entry as? String) ?? (object?["source"] as? String) ?? ""
            if let extensions = object?["extensions"] as? [String], extensions.isEmpty { continue }
            let packageURL: URL
            if source == "npm:pi-agent-ask" || source.hasPrefix("npm:pi-agent-ask@") {
                packageURL = piRoot.appendingPathComponent("npm/node_modules/pi-agent-ask/package.json")
            } else if source.contains("github.com/alexshpunt/pi-agent-ask") {
                packageURL = piRoot.appendingPathComponent("git/github.com/alexshpunt/pi-agent-ask/package.json")
            } else { continue }
            guard let package = try? readObject(packageURL), package["name"] as? String == "pi-agent-ask" else { continue }
            return true
        }
        return false
    }
    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func hookCommand(_ agent: AgentKind) -> String {
        "if [ \"${SPLASH_FINISH_DISABLED:-}\" != 1 ]; then \(quote(executable)) hook \(agent.rawValue) \(marker); fi"
    }
    private func owned(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(" hook ") && command.contains(" " + marker)
    }
    private func configuration(_ agent: AgentKind, root: URL) -> URL {
        root.appendingPathComponent(agent == .claude ? "settings.json" : "hooks.json")
    }
    private func readObject(_ url: URL) throws -> [String: Any] {
        try SafeFile.check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count < 4_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventError.invalid("Expected a JSON object: \(url.path)")
        }
        return value
    }
    private func patch(_ agent: AgentKind, root: URL, install: Bool, dryRun: Bool = false) throws {
        let url = configuration(agent, root: root)
        if !install && !FileManager.default.fileExists(atPath: url.path) { return }
        let before = try? Data(contentsOf: url)
        var config = try readObject(url)
        if let existing = config["hooks"], !(existing is [String: Any]) {
            throw EventError.invalid("Invalid hooks object: \(url.path)")
        }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        // Keep unrelated matchers, unknown metadata and handlers, even in mixed groups.
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else {
                throw EventError.invalid("Invalid hook groups for \(event): \(url.path)")
            }
            var kept = [[String: Any]]()
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw EventError.invalid("Invalid hook handlers: \(url.path)")
                }
                let filtered = handlers.filter { !owned($0) }
                if filtered.count == handlers.count { kept.append(group) }
                else if !filtered.isEmpty { group["hooks"] = filtered; kept.append(group) }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if install {
            var events = ["Stop", "PermissionRequest", "UserPromptSubmit", "PostToolUse", "SessionEnd"]
            if agent == .claude { events += ["Notification", "StopFailure"] }
            if agent == .codex { events += ["Interrupt"] }
            let handler: [String: Any] = ["type": "command", "command": hookCommand(agent), "timeout": 3]
            for event in events {
                var group: [String: Any] = ["hooks": [handler]]
                if event == "Notification" { group["matcher"] = "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input" }
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(group); hooks[event] = groups
            }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        // Do not rewrite a file when the semantic result is unchanged.
        let after = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
        if let before, let old = try? JSONSerialization.jsonObject(with: before) as? NSDictionary,
           old.isEqual(to: config) { return }
        if dryRun { return }
        guard (try? Data(contentsOf: url)) == before else { throw EventError.invalid("Configuration changed while installing: \(url.path); retry") }
        if let before {
            let backup = url.appendingPathExtension("splash-finish-backup-" + UUID().uuidString)
            try SafeFile.write(before, to: backup)
            pruneBackups(of: url, keeping: 3)
        }
        try SafeFile.write(after, to: url)
    }
    /// Every config edit creates a backup; keep only the newest few so the agent
    /// configuration directory does not accumulate files forever.
    private func pruneBackups(of url: URL, keeping limit: Int) {
        let prefix = url.lastPathComponent + ".splash-finish-backup-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.creationDateKey]) else { return }
        let backups = entries.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        }
        for stale in backups.dropFirst(limit) { try? FileManager.default.removeItem(at: stale) }
    }
    private func agyHookCommand(_ event: String, fallbackOutput: String = "{}") -> String {
        "if [ \"${SPLASH_FINISH_DISABLED:-}\" != 1 ]; then \(quote(executable)) hook agy \(event) \(marker); else printf '%s\\n' '\(fallbackOutput)'; fi"
    }
    private func agyPluginRoot(in root: URL) -> URL {
        root.appendingPathComponent("plugins/splash-finish", isDirectory: true)
    }
    private func managedFiles(_ agent: AgentKind, root: URL) throws -> [(URL, Data)] {
        let skill = try String(contentsOf: resources.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let command = quote(executable)
        let renderedSkill = skill.replacingOccurrences(of: "__COMMAND__", with: command)
        if agent == .agy {
            let pluginRoot = agyPluginRoot(in: root)
            let manifest: [String: Any] = [
                "name": "splash-finish",
                "version": "1.0.0",
                "description": "\(fileMarker). Native macOS inbox notifications for Antigravity.",
                "homepage": "https://bobuk.io/apps/splash-finish",
                "repository": "https://github.com/bobuk-io/splash-finish"
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
            let flatHandler: (String) -> [[String: Any]] = { event in
                [["type": "command", "command": self.agyHookCommand(event), "timeout": 3]]
            }
            let toolGroup: (String, String) -> [[String: Any]] = { event, fallback in
                [[
                    "matcher": "ask_question",
                    "hooks": [["type": "command", "command": self.agyHookCommand(event, fallbackOutput: fallback), "timeout": 3]]
                ]]
            }
            let hooksConfig: [String: Any] = [
                "splash-finish": [
                    "PreInvocation": flatHandler("PreInvocation"),
                    "PreToolUse": toolGroup("PreToolUse", "{\"decision\":\"allow\"}"),
                    "PostToolUse": toolGroup("PostToolUse", "{}"),
                    "Stop": flatHandler("Stop")
                ]
            ]
            let hooksData = try JSONSerialization.data(withJSONObject: hooksConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
            return [
                (pluginRoot.appendingPathComponent("plugin.json"), manifestData),
                (pluginRoot.appendingPathComponent("hooks.json"), hooksData),
                (pluginRoot.appendingPathComponent("skills/splash-finish/SKILL.md"), Data(renderedSkill.utf8))
            ]
        }
        var files = [(root.appendingPathComponent("skills/splash-finish/SKILL.md"), Data(renderedSkill.utf8))]
        if agent == .copilot {
            var hooks: [String: [[String: Any]]] = [:]
            for event in ["Stop", "UserPromptSubmit", "PostToolUse", "SessionEnd", "notification"] {
                var handler: [String: Any] = [
                    "type": "command",
                    "bash": "if [ \"${SPLASH_FINISH_DISABLED:-}\" != 1 ]; then \(command) hook copilot \(event) \(marker); fi",
                    "timeoutSec": 3
                ]
                if event == "notification" { handler["matcher"] = "permission_prompt|elicitation_dialog" }
                hooks[event] = [handler]
            }
            let config: [String: Any] = ["version": 1, "description": fileMarker, "hooks": hooks]
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
            files.append((root.appendingPathComponent("hooks/splash-finish.json"), data))
        }
        if agent == .pi || agent == .omp {
            let template = try String(contentsOf: resources.appendingPathComponent("\(agent.rawValue).ts"), encoding: .utf8)
            let encoded = String(data: try JSONEncoder().encode(executable), encoding: .utf8)!
            files.append((root.appendingPathComponent("extensions/splash-finish.ts"),
                          Data(template.replacingOccurrences(of: "__EXECUTABLE_JSON__", with: encoded).utf8)))
        }
        return files
    }
    private func richPiFile() throws -> (URL, Data) {
        let template = try String(contentsOf: resources.appendingPathComponent("pi-questions.ts"), encoding: .utf8)
        let encoded = String(data: try JSONEncoder().encode(executable), encoding: .utf8)!
        return (piRoot.appendingPathComponent("extensions/splash-finish-questions.ts"),
                Data(template.replacingOccurrences(of: "__EXECUTABLE_JSON__", with: encoded).utf8))
    }
    private func checkOwnership(_ url: URL, agent: AgentKind) throws {
        try SafeFile.check(url)
        if FileManager.default.fileExists(atPath: url.path) {
            if url.lastPathComponent == "splash-finish.json" {
                guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      object["description"] as? String == fileMarker else {
                    throw EventError.invalid("Refusing to overwrite an unmanaged or malformed file: \(url.path)")
                }
                return
            }
            if url.lastPathComponent == "plugin.json" {
                guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      let description = object["description"] as? String,
                      description.contains(fileMarker) else {
                    throw EventError.invalid("Refusing to overwrite an unmanaged or malformed file: \(url.path)")
                }
                return
            }
            if url.lastPathComponent == "hooks.json" {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object.keys.count == 1,
                      object["splash-finish"] is [String: Any],
                      let text = String(data: data, encoding: .utf8),
                      text.contains(marker) else {
                    throw EventError.invalid("Refusing to overwrite an unmanaged or malformed file: \(url.path)")
                }
                return
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw EventError.invalid("Refusing to overwrite an unmanaged file: \(url.path)")
            }
            let ours: Bool
            if url.lastPathComponent == "splash-finish.ts" {
                // Both use the same basename, but neither owns the other's adapter.
                let firstLine = text.prefix { !$0.isNewline }
                if firstLine == (agent == .omp ? piExtensionMarker : ompExtensionMarker) {
                    let other = agent == .omp ? "pi" : "OMP"
                    throw EventError.invalid("Refusing to change an adapter managed for \(other): \(url.path)")
                }
                ours = firstLine == (agent == .omp ? ompExtensionMarker : piExtensionMarker)
            } else {
                ours = text.contains(fileMarker)
            }
            guard ours else {
                throw EventError.invalid("Refusing to overwrite an unmanaged file: \(url.path)")
            }
        }
    }
    /// Last event date for an agent. Agent display names can vary ("Claude Code"
    /// versus "claude"), so try every known spelling of the normalized key.
    private func lastEvent(inbox: Inbox, agent: AgentKind) -> Date? {
        guard let timestamps = inbox.lastEvents else { return nil }
        let aliases: [String]
        switch agent {
        case .claude: aliases = ["claudecode", "claude code", "claude"]
        case .codex: aliases = ["codex", "codexcli"]
        case .copilot: aliases = ["githubcopilotcli", "copilotcli", "copilot"]
        case .agy: aliases = ["antigravity", "agy", "antigravitycli"]
        case .pi: aliases = ["pi"]
        case .omp: aliases = ["omp"]
        }
        for alias in aliases where timestamps[alias] != nil { return timestamps[alias] }
        return nil
    }
    /// Inspect the managed hook entries without touching any files.
    private func hookState(agent: AgentKind, root: URL) throws -> (present: Bool, current: Bool, count: Int) {
        guard agent.patchesHooks else { return (true, true, 0) }
        let config = try readObject(configuration(agent, root: root))
        if let raw = config["hooks"], !(raw is [String: Any]) { throw EventError.invalid("Invalid hooks object") }
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        var required: Set<String> = ["Stop", "PermissionRequest", "UserPromptSubmit", "PostToolUse", "SessionEnd"]
        if agent == .claude { required.formUnion(["Notification", "StopFailure"]) }
        else { required.insert("Interrupt") }
        var found: Set<String> = []
        var current = true
        var count = 0
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { throw EventError.invalid("Invalid hook group") }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw EventError.invalid("Invalid hook handlers") }
                let ours = handlers.filter(owned)
                count += ours.count
                if !ours.isEmpty { found.insert(eventName) }
                if ours.contains(where: { ($0["command"] as? String) != hookCommand(agent) }) {
                    current = false
                }
            }
        }
        return (required.isSubset(of: found), current, count)
    }
    public func inspect(inbox: Inbox) -> [IntegrationStatus] {
        AgentKind.allCases.map { agent in
            let last = lastEvent(inbox: inbox, agent: agent)
            do { return try inspect(agent: agent, lastEvent: last) }
            catch { return IntegrationStatus(agent: agent, state: .error, detail: error.localizedDescription, lastEvent: last) }
        }
    }
    private func inspect(agent: AgentKind, lastEvent: Date?) throws -> IntegrationStatus {
        let root = try self.root(agent)
        let piAsk = agent == .pi && piAgentAskDetected()
        let files = try managedFiles(agent, root: root)
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.0.path) }
        for (url, _) in files { try checkOwnership(url, agent: agent) }
        let hooks = try hookState(agent: agent, root: root)
        if existing.isEmpty && hooks.count == 0 {
            let detail = agent == .pi
                ? (piAsk ? "pi-agent-ask detected. Enable rich questions when installing." : "pi-agent-ask not detected globally. Install with: pi install npm:pi-agent-ask")
                : "Install the integration to receive events."
            return IntegrationStatus(agent: agent, state: .notInstalled, detail: detail, lastEvent: lastEvent, piAskDetected: piAsk)
        }
        let richFile = try agent == .pi ? richPiFile() : nil
        let richEnabled = richFile.map { FileManager.default.fileExists(atPath: $0.0.path) } == true
        if !hooks.present || existing.count != files.count {
            return IntegrationStatus(agent: agent, state: .incomplete, detail: "Some managed files or hooks are missing. Reinstall to repair.", lastEvent: lastEvent, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
        }
        let filesCurrent = files.allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 }
        if !filesCurrent || !hooks.current {
            return IntegrationStatus(agent: agent, state: .updateAvailable, detail: "Managed files differ from this app. Reinstall to update.", lastEvent: lastEvent, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
        }
        if let richFile, FileManager.default.fileExists(atPath: richFile.0.path) {
            try checkOwnership(richFile.0, agent: agent)
            if (try? Data(contentsOf: richFile.0)) != richFile.1 {
                return IntegrationStatus(agent: agent, state: .updateAvailable, detail: "Rich pi question integration differs from this app. Reinstall to update.", lastEvent: lastEvent, richQuestionsEnabled: true, piAskDetected: piAsk)
            }
        }
        let detail = agent == .codex ? "Installed. Hook trust is not detectable: review /hooks in Codex." :
            agent == .pi ? "Installed. \(piAsk ? (richEnabled ? "Rich questions enabled." : "pi-agent-ask detected; enable rich questions below.") : "pi-agent-ask not detected globally; install with: pi install npm:pi-agent-ask") Run /reload in existing pi sessions." :
            agent == .agy ? "Installed as plugin. Start a new agy or Antigravity session to load." :
            agent == .omp ? "Installed. Start a new OMP session to load the extension." :
            agent == .copilot ? "Installed. Restart Copilot CLI to load hooks. Hooks can be disabled in Copilot settings." : "Installed. Restart Claude Code to load hooks."
        return IntegrationStatus(agent: agent, state: .installed, detail: detail, lastEvent: lastEvent, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
    }
    public func run(install: Bool, agents: [AgentKind], richQuestions: Bool? = nil) throws -> [String] {
        let destinations = try agents.map { ($0, try root($0)) }
        if let pi = destinations.first(where: { $0.0 == .pi })?.1,
           let omp = destinations.first(where: { $0.0 == .omp })?.1,
           sameAgentRoot(pi, omp) {
            throw EventError.invalid("pi and OMP share an agent directory via PI_CODING_AGENT_DIR. Select --agent pi or --agent omp explicitly.")
        }
        let lock = try FileLock(url: AppPaths.splashFinish(environment: environment, home: home).file("skills.lock"),
                                busyMessage: Splash.busyMessage)
        return try withExtendedLifetime(lock) {
            // Preserve explicitly enabled project-local integrations on CLI reinstall.
            let existingRich = try agents.contains(.pi) && FileManager.default.fileExists(atPath: richPiFile().0.path)
            let enableRich = agents.contains(.pi) && (richQuestions ?? (piAgentAskDetected() || existingRich))
            // Validate all destinations before editing the first agent.
            let planned = try destinations.map { agent, root -> (AgentKind, URL, [(URL, Data)]) in
                var files = try managedFiles(agent, root: root)
                if agent == .pi {
                    let optional = try richPiFile()
                    // Always preflight the optional file, including when disabling it.
                    try checkOwnership(optional.0, agent: agent)
                    if enableRich || !install { files.append(optional) }
                }
                for (url, _) in files { try checkOwnership(url, agent: agent) }
                if agent.patchesHooks { try patch(agent, root: root, install: install, dryRun: true) }
                return (agent, root, files)
            }
            var messages = [String]()
            for (agent, root, files) in planned {
                if install {
                    if agent == .pi && !enableRich {
                        let optional = try richPiFile().0
                        if FileManager.default.fileExists(atPath: optional.path) { try FileManager.default.removeItem(at: optional) }
                    }
                    for (url, data) in files { try SafeFile.write(data, to: url) }
                    if agent.patchesHooks { try patch(agent, root: root, install: true) }
                } else {
                    if agent.patchesHooks { try patch(agent, root: root, install: false) }
                    for (url, _) in files where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    let cleanupDirs: [URL]
                    if agent == .agy {
                        let pluginRoot = agyPluginRoot(in: root)
                        cleanupDirs = [pluginRoot.appendingPathComponent("skills/splash-finish"),
                                       pluginRoot.appendingPathComponent("skills"), pluginRoot]
                    } else {
                        cleanupDirs = [root.appendingPathComponent("skills/splash-finish")]
                    }
                    for dir in cleanupDirs {
                        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true {
                            try FileManager.default.removeItem(at: dir)
                        }
                    }
                }
                let kind = (agent == .pi || agent == .omp) ? "skill and extension" : agent == .agy ? "plugin (skill and hooks)" : "skill and hooks"
                messages.append("\(install ? "Installed" : "Removed") \(agent.rawValue) \(kind)")
            }
            if install && agents.contains(.codex) { messages.append("Codex: review and trust the new hooks using /hooks. No security settings were changed.") }
            if install && agents.contains(.copilot) { messages.append("Copilot CLI: restart existing sessions to load hooks and skills.") }
            if install && agents.contains(.agy) { messages.append("Antigravity: start a new agy or Antigravity session to load the plugin.") }
            if install && agents.contains(.pi) {
                if piAgentAskDetected() {
                    messages.append(enableRich ? "Pi: rich questions enabled for pi-agent-ask." : "Pi: pi-agent-ask detected. Enable rich questions in Integrations.")
                } else {
                    messages.append("Pi: pi-agent-ask not detected globally. Install it with: pi install npm:pi-agent-ask (project-local installations may still work).")
                }
                messages.append("Pi: run /reload in existing sessions.")
            }
            if install && agents.contains(.omp) { messages.append("OMP: start a new session to load the extension.") }
            return messages
        }
    }
}
