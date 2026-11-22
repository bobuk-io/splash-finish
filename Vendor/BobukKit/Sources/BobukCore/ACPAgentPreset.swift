import Darwin
import Foundation

public enum ACPAgentLaunchError: LocalizedError, Equatable, Sendable {
    case notInstalled(agent: String, installHint: String)
    case invalidOverride(variable: String)
    case sandboxUnavailable

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(agent, installHint):
            "\(agent) is not installed. \(installHint)"
        case let .invalidOverride(variable):
            "\(variable) must point to an executable file."
        case .sandboxUnavailable:
            "The macOS sandbox helper (/usr/bin/sandbox-exec) is unavailable."
        }
    }
}

/// Detected availability of an ACP CLI agent on the current Mac.
public struct DetectedACPAgent: Equatable, Identifiable, Sendable {
    public let preset: ACPAgentPreset
    public let executableURL: URL
    public var id: String { preset.id }
    public var name: String { preset.name }

    public init(preset: ACPAgentPreset, executableURL: URL) {
        self.preset = preset
        self.executableURL = executableURL
    }
}

/// Built-in and custom definitions for popular ACP v1 CLI agents.
public struct ACPAgentPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Executable names checked in order (e.g. `["claude-agent-acp", "claude-code-acp"]`).
    public let executables: [String]
    /// Arguments passed to the executable to start ACP stdio mode.
    public let arguments: [String]
    /// Extra arguments appended only when `sandboxed == true`.
    public let sandboxArguments: [String]
    /// Extra directories relative to `$HOME` checked when locating the executable.
    public let extraHomeBinDirectories: [String]
    /// Directories relative to `$HOME` that the agent needs to read/write for auth and state.
    public let stateHomeDirectories: [String]
    /// Environment variable name that overrides executable lookup (e.g. `BOBUK_ACP_CODEX_PATH`).
    public let overrideVariable: String
    /// Short, actionable installation instruction shown when the executable is missing.
    public let installHint: String
    /// Whether the agent requires a non-empty ACP model catalog before sending prompts.
    public let requiresModelCatalog: Bool

    public init(
        id: String,
        name: String,
        executables: [String],
        arguments: [String],
        sandboxArguments: [String] = [],
        extraHomeBinDirectories: [String] = [],
        stateHomeDirectories: [String] = [],
        overrideVariable: String,
        installHint: String,
        requiresModelCatalog: Bool = false
    ) {
        self.id = id
        self.name = name
        self.executables = executables
        self.arguments = arguments
        self.sandboxArguments = sandboxArguments
        self.extraHomeBinDirectories = extraHomeBinDirectories
        self.stateHomeDirectories = stateHomeDirectories
        self.overrideVariable = overrideVariable
        self.installHint = installHint
        self.requiresModelCatalog = requiresModelCatalog
    }

    // MARK: - Popular ACP Agents

    public static let antigravity = ACPAgentPreset(
        id: "antigravity",
        name: "Antigravity",
        executables: ["agy"],
        arguments: ["acp", "--disable-telemetry", "--include-default-customizations=false"],
        sandboxArguments: ["--sandbox"],
        extraHomeBinDirectories: [".local/bin"],
        stateHomeDirectories: [".gemini/antigravity-cli", ".gemini/config"],
        overrideVariable: "BOBUK_ACP_ANTIGRAVITY_PATH",
        installHint: "Install Antigravity CLI and sign in via 'agy' in Terminal.",
        requiresModelCatalog: true
    )

    public static let codex = ACPAgentPreset(
        id: "codex",
        name: "Codex",
        executables: ["codex-acp"],
        arguments: [],
        extraHomeBinDirectories: [".local/bin"],
        stateHomeDirectories: [".codex"],
        overrideVariable: "BOBUK_ACP_CODEX_PATH",
        installHint: "Install the Codex ACP adapter: npm i -g @agentclientprotocol/codex-acp"
    )

    public static let claude = ACPAgentPreset(
        id: "claude",
        name: "Claude",
        executables: ["claude-agent-acp", "claude-code-acp"],
        arguments: [],
        extraHomeBinDirectories: [".local/bin"],
        stateHomeDirectories: [".claude", ".config/claude"],
        overrideVariable: "BOBUK_ACP_CLAUDE_PATH",
        installHint: "Install the Claude ACP adapter: npm i -g @agentclientprotocol/claude-agent-acp"
    )

    public static let pi = ACPAgentPreset(
        id: "pi",
        name: "Pi",
        executables: ["pi-acp"],
        arguments: [],
        extraHomeBinDirectories: [".pi/agent/bin", ".local/bin"],
        stateHomeDirectories: [".pi"],
        overrideVariable: "BOBUK_ACP_PI_PATH",
        installHint: "Install the Pi ACP adapter: npm i -g pi-acp"
    )

    public static let kimi = ACPAgentPreset(
        id: "kimi",
        name: "Kimi",
        executables: ["kimi"],
        arguments: ["acp"],
        extraHomeBinDirectories: [".kimi-code/bin", ".local/bin"],
        stateHomeDirectories: [".kimi", ".kimi-code"],
        overrideVariable: "BOBUK_ACP_KIMI_PATH",
        installHint: "Install Kimi CLI and sign in via 'kimi acp --login' in Terminal."
    )

    public static let gemini = ACPAgentPreset(
        id: "gemini",
        name: "Gemini",
        executables: ["gemini"],
        arguments: ["--acp"],
        extraHomeBinDirectories: [".local/share/mise/installs/gemini-cli/latest/bin", ".local/bin"],
        stateHomeDirectories: [".gemini"],
        overrideVariable: "BOBUK_ACP_GEMINI_PATH",
        installHint: "Install Gemini CLI: npm i -g @google/gemini-cli"
    )

    public static let opencode = ACPAgentPreset(
        id: "opencode",
        name: "OpenCode",
        executables: ["opencode"],
        arguments: ["acp"],
        extraHomeBinDirectories: [".opencode/bin", ".local/bin"],
        stateHomeDirectories: [".config/opencode", ".local/share/opencode"],
        overrideVariable: "BOBUK_ACP_OPENCODE_PATH",
        installHint: "Install OpenCode: brew install opencode"
    )

    public static let all: [ACPAgentPreset] = [
        .antigravity,
        .codex,
        .claude,
        .pi,
        .kimi,
        .gemini,
        .opencode,
    ]

    public static func named(_ id: String) -> ACPAgentPreset? {
        all.first { $0.id == id }
    }

    // MARK: - Auto-detection of Available Agents

    /// Returns every agent preset whose executable is currently installed on the user's Mac,
    /// preserving the order of `candidates`.
    public static func detectInstalled(
        in candidates: [ACPAgentPreset] = all,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DetectedACPAgent] {
        candidates.compactMap { preset in
            guard let url = preset.resolveExecutable(home: home, environment: environment) else { return nil }
            return DetectedACPAgent(preset: preset, executableURL: url)
        }
    }

    /// Returns the first installed agent in `candidates`, or `fallback` when none are installed.
    public static func preferredAvailable(
        in candidates: [ACPAgentPreset] = all,
        fallback: ACPAgentPreset = .antigravity,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ACPAgentPreset {
        detectInstalled(in: candidates, home: home, environment: environment).first?.preset ?? fallback
    }

    // MARK: - Executable Resolution & Launch

    private static let commonHomeBins = [
        ".local/bin",
        ".local/share/mise/shims",
        ".local/share/mise/installs/node/latest/bin",
        ".volta/bin",
        ".npm-global/bin",
        ".asdf/shims",
    ]

    private static let commonSystemBins = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    public func searchDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            dirs.append(path)
        }
        for rel in extraHomeBinDirectories + Self.commonHomeBins {
            add(home.appendingPathComponent(rel).path)
        }
        for sys in Self.commonSystemBins {
            add(sys)
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") where entry.hasPrefix("/") {
            add(String(entry))
        }
        return dirs
    }

    public func resolveExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let files = FileManager.default
        if let override = environment[overrideVariable], !override.isEmpty {
            guard override.hasPrefix("/"), files.isExecutableFile(atPath: override) else { return nil }
            return Self.canonical(URL(fileURLWithPath: override))
        }
        let dirs = searchDirectories(home: home, environment: environment)
        for exe in executables {
            for dir in dirs {
                let candidate = "\(dir)/\(exe)"
                if files.isExecutableFile(atPath: candidate) {
                    return Self.canonical(URL(fileURLWithPath: candidate))
                }
            }
        }
        return nil
    }

    public func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolveExecutable(home: home, environment: environment) != nil
    }

    /// Creates an ACP launch configuration opened in `directory` (`cwd`), with network access
    /// enabled and `access` controlling ACP file/tool permissions (defaults to `.workspace()`).
    public func launch(
        in directory: URL,
        sandboxed: Bool = true,
        access: ACPAccessPolicy = .workspace(),
        clientName: String,
        extraArguments: [String] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ACPLaunchConfiguration {
        let files = FileManager.default
        if let override = environment[overrideVariable], !override.isEmpty {
            guard override.hasPrefix("/"), files.isExecutableFile(atPath: override) else {
                throw ACPAgentLaunchError.invalidOverride(variable: overrideVariable)
            }
        }
        guard let agent = resolveExecutable(home: home, environment: environment) else {
            throw ACPAgentLaunchError.notInstalled(agent: name, installHint: installHint)
        }

        let canonicalDirectory = Self.canonical(directory)
        let canonicalHome = Self.canonical(home)
        let mergedPath = searchDirectories(home: canonicalHome, environment: environment).joined(separator: ":")

        var args = arguments + extraArguments
        for root in Self.additionalRoots(from: access) {
            if id == "antigravity" {
                args.append(contentsOf: ["--add-dir", Self.canonical(root).path])
            }
        }

        var env: [String: String] = [
            "HOME": canonicalHome.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": mergedPath,
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
        ]
        for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY", "KIMI_API_KEY"] {
            if let value = environment[key], !value.isEmpty { env[key] = value }
        }

        let isolation: ACPProcessIsolation
        if sandboxed {
            let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            guard files.isExecutableFile(atPath: launcher.path) else {
                throw ACPAgentLaunchError.sandboxUnavailable
            }
            args.append(contentsOf: sandboxArguments)
            env["GODEBUG"] = "netdns=go"
            let profile = sandboxProfile(home: canonicalHome, directory: canonicalDirectory, access: access)
            isolation = .sandboxed(launcher: launcher, arguments: ["-p", profile])
        } else {
            isolation = .unrestricted
        }

        return ACPLaunchConfiguration(
            executable: agent,
            arguments: args,
            directory: canonicalDirectory,
            environment: env,
            clientName: clientName,
            isolation: isolation,
            access: access
        )
    }

    /// Runs a single headless prompt against this agent and returns the full response.
    /// No UI is required; the subprocess is always terminated before returning.
    public func ask(
        _ prompt: String,
        in directory: URL = FileManager.default.temporaryDirectory,
        options: ACPPromptOptions = .init(),
        clientName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onTool: (@Sendable (String?) async -> Void)? = nil,
        onChunk: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ACPPromptResponse {
        let config = try launch(
            in: directory,
            sandboxed: options.sandboxed,
            access: options.access,
            clientName: clientName,
            extraArguments: options.extraArguments,
            home: home,
            environment: environment
        )
        let client = ACPClient(
            launch: config,
            requestTimeout: options.requestTimeout,
            turnTimeout: options.turnTimeout
        )
        defer { Task { await client.close() } }

        var activeModels = try await client.connect()
        if let model = options.model, !model.isEmpty {
            activeModels = try await client.selectModel(model)
        }
        var activeEffort = await client.currentEffort()
        if let effort = options.effort, !effort.isEmpty {
            if let updated = try await client.selectEffort(effort) {
                activeEffort = updated
            }
        }

        actor Collector {
            var text = ""
            func append(_ chunk: String) { text += chunk }
        }
        let collector = Collector()
        let reason = try await client.prompt(prompt, onTool: onTool) { chunk in
            await collector.append(chunk)
            await onChunk?(chunk)
        }
        let reply = await collector.text
        await client.close()
        return ACPPromptResponse(
            text: reply,
            stopReason: reason,
            model: activeModels?.current,
            effort: activeEffort
        )
    }

    /// Convenience one-shot call using the first auto-detected installed agent.
    public static func ask(
        _ prompt: String,
        in directory: URL = FileManager.default.temporaryDirectory,
        candidates: [ACPAgentPreset] = all,
        options: ACPPromptOptions = .init(),
        clientName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onTool: (@Sendable (String?) async -> Void)? = nil,
        onChunk: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ACPPromptResponse {
        let chosen = preferredAvailable(in: candidates, home: home, environment: environment)
        return try await chosen.ask(
            prompt,
            in: directory,
            options: options,
            clientName: clientName,
            home: home,
            environment: environment,
            onTool: onTool,
            onChunk: onChunk
        )
    }

    /// Backward-compatible alias for `launch(in:sandboxed:access:clientName:...)`.
    public func launch(
        workspace: URL,
        sandboxed: Bool = true,
        access: ACPAccessPolicy = .workspace(),
        clientName: String,
        extraArguments: [String] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ACPLaunchConfiguration {
        try launch(
            in: workspace,
            sandboxed: sandboxed,
            access: access,
            clientName: clientName,
            extraArguments: extraArguments,
            home: home,
            environment: environment
        )
    }

    /// macOS Seatbelt profile for ACP CLI agents:
    /// - Network access is allowed (from `(allow default)`), with Go DNS compatible via `resolv.conf`.
    /// - `directory` (and any `additionalRoots` in `access`) can be read (and written when allowed),
    ///   even if `directory` lives inside `/Volumes`, `~/Documents`, or `~/Downloads`.
    /// - Unrelated user folders (`~/Downloads`, `~/Desktop`, `~/Documents`, `/Volumes`, `/Network`)
    ///   remain blocked when not explicitly opened as `directory` / `additionalRoots`.
    public func sandboxProfile(
        home: URL,
        directory: URL,
        access: ACPAccessPolicy = .workspace()
    ) -> String {
        let home = Self.canonical(home)
        let directory = Self.canonical(directory)
        let extraRoots = Self.additionalRoots(from: access).map(Self.canonical)
        let allowedWorkspaceRoots = [directory] + extraRoots

        let defaultProtected = [
            home.appendingPathComponent("Downloads").path,
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Pictures").path,
            home.appendingPathComponent("Movies").path,
            home.appendingPathComponent("Music").path,
            "/Volumes",
            "/Network",
        ]

        let allowWorkspaceReads = allowedWorkspaceRoots.map { "(subpath \(Self.quoted($0.path)))" }.joined(separator: " ")
        let denyProtected = defaultProtected.map { "(subpath \(Self.quoted($0)))" }.joined(separator: " ")

        let canWriteWorkspace: Bool = {
            switch access {
            case .textOnly: return false
            case let .workspace(allowWrite, _, _): return allowWrite
            }
        }()

        var writableSubpaths = [
            "/private/tmp",
            "/tmp",
            "/private/var/folders",
        ] + stateHomeDirectories.map { home.appendingPathComponent($0).path }

        if canWriteWorkspace {
            writableSubpaths.append(contentsOf: allowedWorkspaceRoots.map(\.path))
        }

        let allowWrite = (writableSubpaths.map { "(subpath \(Self.quoted($0)))" }
            + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")"]).joined(separator: " ")

        return """
        (version 1)
        (allow default)
        (deny file-read* file-write* (require-all (require-any \(denyProtected)) (require-not (require-any \(allowWorkspaceReads)))))
        (deny file-write* (require-not (require-any \(allowWrite))))
        """
    }

    private static func additionalRoots(from access: ACPAccessPolicy) -> [URL] {
        switch access {
        case .textOnly: return []
        case let .workspace(_, _, additionalRoots): return additionalRoots
        }
    }

    static func canonical(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
