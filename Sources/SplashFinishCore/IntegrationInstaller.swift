import Foundation

public enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, pi
}

public struct IntegrationStatus: Identifiable, Sendable {
    public var id: String { agent.rawValue }
    public var agent: AgentKind
    public var state: String
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                executable: String, resources: URL) {
        self.home = home; self.environment = environment; self.executable = executable; self.resources = resources
    }
    private func root(_ agent: AgentKind) -> URL {
        let key: String; let fallback: String
        switch agent {
        case .claude: key = "CLAUDE_CONFIG_DIR"; fallback = ".claude"
        case .codex: key = "CODEX_HOME"; fallback = ".codex"
        case .pi: key = "PI_CODING_AGENT_DIR"; fallback = ".pi/agent"
        }
        return environment[key].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(fallback)
    }
    /// Detect a configured, installed global package; project-local extensions may still exist.
    public func piAgentAskDetected() -> Bool {
        let piRoot = root(.pi)
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
    private func owned(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(" hook ") && command.contains(" " + marker)
    }
    private func configuration(_ agent: AgentKind) -> URL {
        root(agent).appendingPathComponent(agent == .claude ? "settings.json" : "hooks.json")
    }
    private func readObject(_ url: URL) throws -> [String: Any] {
        try SafeFiles.check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count < 4_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventError.invalid("Expected a JSON object: \(url.path)")
        }
        return value
    }
    private func patch(_ agent: AgentKind, install: Bool, dryRun: Bool = false) throws {
        let url = configuration(agent)
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
            let handler: [String: Any] = ["type": "command", "command": "\(quote(executable)) hook \(agent.rawValue) \(marker)", "timeout": 3]
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
            try SafeFiles.write(before, to: backup)
        }
        try SafeFiles.write(after, to: url)
    }
    private func managedFiles(_ agent: AgentKind) throws -> [(URL, Data)] {
        let skill = try String(contentsOf: resources.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let command = quote(executable)
        let renderedSkill = skill.replacingOccurrences(of: "__COMMAND__", with: command)
        var files = [(root(agent).appendingPathComponent("skills/splash-finish/SKILL.md"), Data(renderedSkill.utf8))]
        if agent == .pi {
            let template = try String(contentsOf: resources.appendingPathComponent("pi.ts"), encoding: .utf8)
            let encoded = String(data: try JSONEncoder().encode(executable), encoding: .utf8)!
            files.append((root(agent).appendingPathComponent("extensions/splash-finish.ts"),
                          Data(template.replacingOccurrences(of: "__EXECUTABLE_JSON__", with: encoded).utf8)))
        }
        return files
    }
    private func richPiFile() throws -> (URL, Data) {
        let template = try String(contentsOf: resources.appendingPathComponent("pi-questions.ts"), encoding: .utf8)
        let encoded = String(data: try JSONEncoder().encode(executable), encoding: .utf8)!
        return (root(.pi).appendingPathComponent("extensions/splash-finish-questions.ts"),
                Data(template.replacingOccurrences(of: "__EXECUTABLE_JSON__", with: encoded).utf8))
    }
    private func checkOwnership(_ url: URL) throws {
        try SafeFiles.check(url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(fileMarker) else {
                throw EventError.invalid("Refusing to overwrite an unmanaged file: \(url.path)")
            }
        }
    }
    public func inspect(inbox: Inbox) -> [IntegrationStatus] {
        AgentKind.allCases.map { agent in
            let display = agent == .claude ? "claude code" : agent.rawValue
            let last = inbox.lastEvents?[display]
            let piAsk = agent == .pi && piAgentAskDetected()
            do {
                let files = try managedFiles(agent)
                let existing = files.filter { FileManager.default.fileExists(atPath: $0.0.path) }
                for (url, _) in existing { try checkOwnership(url) }
                var hooksPresent = agent == .pi
                var hooksCurrent = true
                var hookCount = 0
                if agent != .pi {
                    let config = try readObject(configuration(agent))
                    if let raw = config["hooks"], !(raw is [String: Any]) { throw EventError.invalid("Invalid hooks object") }
                    let hooks = config["hooks"] as? [String: Any] ?? [:]
                    var required: Set<String> = ["Stop", "PermissionRequest", "UserPromptSubmit", "PostToolUse", "SessionEnd"]
                    if agent == .claude { required.formUnion(["Notification", "StopFailure"]) }
                    else { required.insert("Interrupt") }
                    var found: Set<String> = []
                    for (eventName, value) in hooks {
                        guard let groups = value as? [[String: Any]] else { throw EventError.invalid("Invalid hook group") }
                        for group in groups {
                            guard let handlers = group["hooks"] as? [[String: Any]] else { throw EventError.invalid("Invalid hook handlers") }
                            let ours = handlers.filter(owned)
                            hookCount += ours.count
                            if !ours.isEmpty { found.insert(eventName) }
                            if ours.contains(where: { ($0["command"] as? String) != "\(quote(executable)) hook \(agent.rawValue) \(marker)" }) {
                                hooksCurrent = false
                            }
                        }
                    }
                    hooksPresent = required.isSubset(of: found)
                }
                if existing.isEmpty && !hooksPresent && hookCount == 0 {
                    return IntegrationStatus(agent: agent, state: "not installed", detail: "Install the integration to receive events.", lastEvent: last)
                }
                if agent == .pi && existing.isEmpty {
                    return IntegrationStatus(agent: agent, state: "not installed", detail: piAsk ? "pi-agent-ask detected. Enable rich questions when installing." : "pi-agent-ask not detected globally. Install with: pi install npm:pi-agent-ask", lastEvent: last, piAskDetected: piAsk)
                }
                let richFile = try agent == .pi ? richPiFile() : nil
                let richEnabled = richFile.map { FileManager.default.fileExists(atPath: $0.0.path) } == true
                let filesCurrent = existing.count == files.count && files.allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 }
                if !hooksPresent || existing.count != files.count {
                    return IntegrationStatus(agent: agent, state: "incomplete", detail: "Some managed files or hooks are missing. Reinstall to repair.", lastEvent: last, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
                }
                if !filesCurrent || !hooksCurrent {
                    return IntegrationStatus(agent: agent, state: "update available", detail: "Managed files differ from this app. Reinstall to update.", lastEvent: last, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
                }
                if let richFile, FileManager.default.fileExists(atPath: richFile.0.path) {
                    try checkOwnership(richFile.0)
                    if (try? Data(contentsOf: richFile.0)) != richFile.1 {
                        return IntegrationStatus(agent: agent, state: "update available", detail: "Rich pi question integration differs from this app. Reinstall to update.", lastEvent: last, richQuestionsEnabled: true, piAskDetected: piAsk)
                    }
                }
                let detail = agent == .codex ? "Installed. Hook trust is not detectable: review /hooks in Codex." :
                    agent == .pi ? "Installed. \(piAsk ? (richEnabled ? "Rich questions enabled." : "pi-agent-ask detected; enable rich questions below.") : "pi-agent-ask not detected globally; install with: pi install npm:pi-agent-ask") Run /reload in existing pi sessions." : "Installed. Restart Claude Code to load hooks."
                return IntegrationStatus(agent: agent, state: "installed", detail: detail, lastEvent: last, richQuestionsEnabled: richEnabled, piAskDetected: piAsk)
            } catch {
                return IntegrationStatus(agent: agent, state: "error", detail: error.localizedDescription, lastEvent: last)
            }
        }
    }
    public func run(install: Bool, agents: [AgentKind], richQuestions: Bool? = nil) throws -> [String] {
        let lockRoot = environment["SPLASH_FINISH_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/Splash Finish")
        let lock = try FileLock(url: lockRoot.appendingPathComponent("skills.lock"))
        return try withExtendedLifetime(lock) {
            // Preserve explicitly enabled project-local integrations on CLI reinstall.
            let existingRich = try agents.contains(.pi) && FileManager.default.fileExists(atPath: richPiFile().0.path)
            let enableRich = richQuestions ?? (piAgentAskDetected() || existingRich)
            // Validate all destinations before editing the first agent.
            let planned = try agents.map { agent -> (AgentKind, [(URL, Data)]) in
                var files = try managedFiles(agent)
                if agent == .pi {
                    let optional = try richPiFile()
                    // Always preflight the optional file, including when disabling it.
                    try checkOwnership(optional.0)
                    if enableRich || !install { files.append(optional) }
                }
                for (url, _) in files { try checkOwnership(url) }
                if agent != .pi { try patch(agent, install: install, dryRun: true) }
                return (agent, files)
            }
            var messages = [String]()
            for (agent, files) in planned {
                if install {
                    if agent == .pi && !enableRich {
                        let optional = try richPiFile().0
                        if FileManager.default.fileExists(atPath: optional.path) { try FileManager.default.removeItem(at: optional) }
                    }
                    for (url, data) in files { try SafeFiles.write(data, to: url) }
                    if agent != .pi { try patch(agent, install: true) }
                } else {
                    if agent != .pi { try patch(agent, install: false) }
                    for (url, _) in files where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    let skillDir = root(agent).appendingPathComponent("skills/splash-finish")
                    if (try? FileManager.default.contentsOfDirectory(atPath: skillDir.path).isEmpty) == true {
                        try FileManager.default.removeItem(at: skillDir)
                    }
                }
                messages.append("\(install ? "Installed" : "Removed") \(agent.rawValue) skill\(agent == .pi ? " and extension" : " and hooks")")
            }
            if install && agents.contains(.codex) { messages.append("Codex: review and trust the new hooks using /hooks. No security settings were changed.") }
            if install && agents.contains(.pi) {
                if piAgentAskDetected() {
                    messages.append(enableRich ? "Pi: rich questions enabled for pi-agent-ask." : "Pi: pi-agent-ask detected. Enable rich questions in Integrations.")
                } else {
                    messages.append("Pi: pi-agent-ask not detected globally. Install it with: pi install npm:pi-agent-ask (project-local installations may still work).")
                }
                messages.append("Pi: run /reload in existing sessions.")
            }
            return messages
        }
    }
}
