import Darwin
import Foundation

public enum ACPAgentLaunchError: LocalizedError, Equatable, Sendable {
    case notInstalled(agent: String, installHint: String)
    case acpAdapterMissing(agent: String, installHint: String)
    case invalidOverride(variable: String)
    case sandboxUnavailable

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(agent, installHint):
            "\(agent) is not installed. \(installHint)"
        case let .acpAdapterMissing(agent, installHint):
            "\(agent) is installed, but its ACP adapter is missing. \(installHint)"
        case let .invalidOverride(variable):
            "\(variable) must point to an executable file."
        case .sandboxUnavailable:
            "The macOS sandbox helper (/usr/bin/sandbox-exec) is unavailable."
        }
    }
}

/// Installation state of an ACP agent preset on the current Mac.
public enum ACPAgentAvailability: Equatable, Sendable {
    /// The ACP-capable executable or adapter is installed and ready to launch.
    case ready(executableURL: URL)
    /// The underlying agent CLI is installed, but its separate ACP adapter is missing.
    case needsACPAdapter(cliURL: URL)
    /// Neither the ACP adapter nor the underlying CLI was found.
    case notInstalled
}

/// Full detection result for an ACP agent preset.
public struct ACPAgentStatus: Equatable, Identifiable, Sendable {
    public let preset: ACPAgentPreset
    public let availability: ACPAgentAvailability
    public var id: String { preset.id }
    public var name: String { preset.name }

    public var isReady: Bool {
        if case .ready = availability { return true }
        return false
    }

    public var needsACPAdapter: Bool {
        if case .needsACPAdapter = availability { return true }
        return false
    }

    public var executableURL: URL? {
        if case let .ready(url) = availability { return url }
        return nil
    }

    public var cliURL: URL? {
        if case let .needsACPAdapter(url) = availability { return url }
        return nil
    }

    public init(preset: ACPAgentPreset, availability: ACPAgentAvailability) {
        self.preset = preset
        self.availability = availability
    }
}

/// Errors produced when installing a missing ACP adapter via `npm`.
public enum ACPAdapterInstallError: LocalizedError, Equatable, Sendable {
    case notApplicable(agent: String)
    case npmNotFound(command: String)
    case failed(status: Int32, output: String, command: String)
    case installedBinaryNotFound(agent: String, command: String)

    public var errorDescription: String? {
        switch self {
        case let .notApplicable(agent):
            return "\(agent) does not use a separate npm ACP adapter."
        case let .npmNotFound(command):
            return "npm was not found. Install Node.js, then run: \(command)"
        case let .failed(status, output, command):
            let detail = output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(3)
                .joined(separator: " · ")
            if detail.isEmpty {
                return "Adapter install failed (exit \(status)). Try running in Terminal: \(command)"
            }
            return "Adapter install failed (exit \(status)): \(detail)"
        case let .installedBinaryNotFound(agent, command):
            return "npm finished, but the \(agent) ACP adapter was not found in PATH. Run in Terminal: \(command)"
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
    /// Underlying CLI binary names for agents that require a separate ACP adapter (e.g. `["codex"]`, `["claude"]`).
    public let cliExecutables: [String]
    /// npm package name that provides the ACP adapter when `cliExecutables` is non-empty.
    public let adapterNPMPackage: String?
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

    /// Ready-to-run shell command that installs the separate ACP adapter, if this preset uses one.
    public var adapterInstallCommand: String? {
        adapterNPMPackage.map { "npm i -g \($0)" }
    }

    /// True when this agent needs a separate ACP adapter package in addition to its CLI.
    public var requiresSeparateACPAdapter: Bool {
        !cliExecutables.isEmpty
    }

    public init(
        id: String,
        name: String,
        executables: [String],
        cliExecutables: [String] = [],
        adapterNPMPackage: String? = nil,
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
        self.cliExecutables = cliExecutables
        self.adapterNPMPackage = adapterNPMPackage
        self.arguments = arguments
        self.sandboxArguments = sandboxArguments
        self.extraHomeBinDirectories = extraHomeBinDirectories
        self.stateHomeDirectories = stateHomeDirectories
        self.overrideVariable = overrideVariable
        self.installHint = installHint
        self.requiresModelCatalog = requiresModelCatalog
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, executables, cliExecutables, adapterNPMPackage
        case arguments, sandboxArguments, extraHomeBinDirectories, stateHomeDirectories
        case overrideVariable, installHint, requiresModelCatalog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executables = try c.decode([String].self, forKey: .executables)
        cliExecutables = try c.decodeIfPresent([String].self, forKey: .cliExecutables) ?? []
        adapterNPMPackage = try c.decodeIfPresent(String.self, forKey: .adapterNPMPackage)
        arguments = try c.decode([String].self, forKey: .arguments)
        sandboxArguments = try c.decodeIfPresent([String].self, forKey: .sandboxArguments) ?? []
        extraHomeBinDirectories = try c.decodeIfPresent([String].self, forKey: .extraHomeBinDirectories) ?? []
        stateHomeDirectories = try c.decodeIfPresent([String].self, forKey: .stateHomeDirectories) ?? []
        overrideVariable = try c.decode(String.self, forKey: .overrideVariable)
        installHint = try c.decode(String.self, forKey: .installHint)
        requiresModelCatalog = try c.decodeIfPresent(Bool.self, forKey: .requiresModelCatalog) ?? false
    }

    // MARK: - Popular ACP Agents

    public static let antigravity = ACPAgentPreset(
        id: "antigravity",
        name: "Antigravity",
        executables: ["agy"],
        arguments: ["acp", "--disable-telemetry", "--include-default-customizations=false"],
        sandboxArguments: ["--sandbox"],
        extraHomeBinDirectories: [".gemini/antigravity-cli/bin", ".local/bin"],
        stateHomeDirectories: [".gemini/antigravity-cli", ".gemini/config"],
        overrideVariable: "BOBUK_ACP_ANTIGRAVITY_PATH",
        installHint: "Install Antigravity CLI and sign in via 'agy' in Terminal.",
        requiresModelCatalog: true
    )

    public static let codex = ACPAgentPreset(
        id: "codex",
        name: "Codex",
        executables: ["codex-acp"],
        cliExecutables: ["codex"],
        adapterNPMPackage: "@agentclientprotocol/codex-acp",
        arguments: [],
        extraHomeBinDirectories: [".local/share/mise/installs/npm-openai-codex/latest/bin", ".local/bin"],
        stateHomeDirectories: [".codex"],
        overrideVariable: "BOBUK_ACP_CODEX_PATH",
        installHint: "Install the Codex ACP adapter: npm i -g @agentclientprotocol/codex-acp"
    )

    public static let claude = ACPAgentPreset(
        id: "claude",
        name: "Claude",
        executables: ["claude-agent-acp", "claude-code-acp"],
        cliExecutables: ["claude"],
        adapterNPMPackage: "@agentclientprotocol/claude-agent-acp",
        arguments: [],
        extraHomeBinDirectories: [".local/bin", ".claude/local"],
        stateHomeDirectories: [".claude", ".config/claude"],
        overrideVariable: "BOBUK_ACP_CLAUDE_PATH",
        installHint: "Install the Claude ACP adapter: npm i -g @agentclientprotocol/claude-agent-acp"
    )

    public static let pi = ACPAgentPreset(
        id: "pi",
        name: "Pi",
        executables: ["pi-acp"],
        cliExecutables: ["pi"],
        adapterNPMPackage: "pi-acp",
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

    /// Returns every agent preset whose ACP executable is currently installed on the user's Mac,
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

    /// Detects the detailed availability (ready, needs ACP adapter, or not installed)
    /// for every preset in `candidates`, preserving order.
    public static func detectAll(
        in candidates: [ACPAgentPreset] = all,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ACPAgentStatus] {
        candidates.map { preset in
            ACPAgentStatus(
                preset: preset,
                availability: preset.detectAvailability(home: home, environment: environment)
            )
        }
    }

    /// Returns the installation status of this preset: ready for ACP, CLI present without ACP adapter, or not installed.
    public func detectAvailability(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ACPAgentAvailability {
        if let acpURL = resolveExecutable(home: home, environment: environment) {
            return .ready(executableURL: acpURL)
        }
        if let cliURL = resolveCLIExecutable(home: home, environment: environment) {
            return .needsACPAdapter(cliURL: cliURL)
        }
        return .notInstalled
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
        ".local/share/mise/installs/node/latest/bin",
        ".local/share/mise/installs/bun/latest/bin",
        ".local/share/mise/shims",
        ".volta/bin",
        ".bun/bin",
        ".npm-global/bin",
        "Library/pnpm",
        ".local/share/pnpm",
        ".fnm/current/bin",
        ".nodenv/shims",
        ".asdf/shims",
        ".cargo/bin",
    ]

    private static let commonSystemBins = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
    ]

    private static let multiCallShimNames: Set<String> = [
        "mise",
        "volta-shim",
        "asdf",
    ]

    public func searchDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        Self.searchDirectories(extraHomeBins: extraHomeBinDirectories, home: home, environment: environment)
    }

    private static let baseSystemBins: Set<String> = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static func searchDirectories(
        extraHomeBins: [String],
        home: URL,
        environment: [String: String]
    ) -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            dirs.append(path)
        }
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }

        for rel in extraHomeBins {
            add(home.appendingPathComponent(rel).path)
        }
        // Respect explicit user PATH entries ahead of fallback system bins (e.g. Homebrew).
        for entry in pathEntries where !baseSystemBins.contains(entry) {
            add(entry)
        }
        for rel in commonHomeBins {
            add(home.appendingPathComponent(rel).path)
        }
        if let prefix = npmPrefix(home: home, environment: environment) {
            add(prefix.appendingPathComponent("bin").path)
        }
        for dynamic in dynamicHomeBinDirectories(home: home) {
            add(dynamic)
        }
        for sys in commonSystemBins {
            add(sys)
        }
        for entry in pathEntries {
            add(entry)
        }
        return dirs
    }

    private static func npmPrefix(home: URL, environment: [String: String]) -> URL? {
        if let envPrefix = environment["npm_config_prefix"] ?? environment["NPM_CONFIG_PREFIX"] {
            let trimmed = envPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return expandTilde(trimmed, home: home)
            }
        }
        let npmrc = home.appendingPathComponent(".npmrc")
        guard let content = try? String(contentsOf: npmrc, encoding: .utf8) else { return nil }
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "prefix" else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")),
               value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty {
                return expandTilde(value, home: home)
            }
        }
        return nil
    }

    private static func expandTilde(_ path: String, home: URL) -> URL? {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func dynamicHomeBinDirectories(home: URL) -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        // Versioned nvm node bins (newest version first).
        let nvmNodes = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmNodes.path) {
            for version in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
                let bin = nvmNodes.appendingPathComponent(version).appendingPathComponent("bin").path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: bin, isDirectory: &isDir), isDir.boolValue {
                    found.append(bin)
                }
            }
        }

        // Versioned fnm node bins (newest version first).
        let fnmNodes = home.appendingPathComponent(".fnm/node-versions")
        if let versions = try? fm.contentsOfDirectory(atPath: fnmNodes.path) {
            for version in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
                let bin = fnmNodes.appendingPathComponent(version).appendingPathComponent("installation/bin").path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: bin, isDirectory: &isDir), isDir.boolValue {
                    found.append(bin)
                }
            }
        }

        // mise tool installs under ~/.local/share/mise/installs/*/{latest,<version>}/bin.
        let miseInstalls = home.appendingPathComponent(".local/share/mise/installs")
        if let tools = try? fm.contentsOfDirectory(atPath: miseInstalls.path) {
            for tool in tools.sorted() {
                let toolDir = miseInstalls.appendingPathComponent(tool)
                let latestBin = toolDir.appendingPathComponent("latest/bin").path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: latestBin, isDirectory: &isDir), isDir.boolValue {
                    found.append(latestBin)
                }
                if let versions = try? fm.contentsOfDirectory(atPath: toolDir.path) {
                    for ver in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending })
                    where ver != "latest" && !ver.hasPrefix(".") {
                        let verBin = toolDir.appendingPathComponent(ver).appendingPathComponent("bin").path
                        var isVerDir: ObjCBool = false
                        if fm.fileExists(atPath: verBin, isDirectory: &isVerDir), isVerDir.boolValue {
                            found.append(verBin)
                        }
                    }
                }
            }
        }

        return found
    }

    private static func isShimPath(_ url: URL) -> Bool {
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let resolved = canonical(url)
        return parentName == "shims" || multiCallShimNames.contains(resolved.lastPathComponent)
    }

    private static func resolveCandidate(at path: String, files: FileManager) -> URL? {
        guard files.isExecutableFile(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        // Keep shim paths (mise/volta/asdf) from collapsing to the shim dispatcher binary so argv[0] stays intact.
        if isShimPath(url) {
            let canonicalParent = canonical(url.deletingLastPathComponent())
            return canonicalParent.appendingPathComponent(url.lastPathComponent)
        }
        return canonical(url)
    }

    public func resolveExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let files = FileManager.default
        if let override = environment[overrideVariable], !override.isEmpty {
            guard override.hasPrefix("/") else { return nil }
            return Self.resolveCandidate(at: override, files: files)
        }
        let dirs = searchDirectories(home: home, environment: environment)
        var shimFallback: URL?
        for exe in executables {
            for dir in dirs {
                let candidate = "\(dir)/\(exe)"
                guard let resolved = Self.resolveCandidate(at: candidate, files: files) else { continue }
                if Self.isShimPath(URL(fileURLWithPath: candidate)) {
                    if shimFallback == nil { shimFallback = resolved }
                } else {
                    return resolved
                }
            }
        }
        return shimFallback
    }

    /// Resolves the underlying agent CLI binary (e.g. `codex` or `claude`) when this preset uses a separate ACP adapter.
    public func resolveCLIExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !cliExecutables.isEmpty else { return nil }
        let files = FileManager.default
        let dirs = searchDirectories(home: home, environment: environment)
        for exe in cliExecutables {
            for dir in dirs {
                if let resolved = Self.resolveCandidate(at: "\(dir)/\(exe)", files: files) {
                    return resolved
                }
            }
        }
        return nil
    }

    /// Locates an auxiliary CLI tool such as `npm` using the same GUI-safe search directories.
    public static func resolveTool(
        _ name: String,
        overrideVariable: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let files = FileManager.default
        if let overrideVariable, let override = environment[overrideVariable], !override.isEmpty {
            guard override.hasPrefix("/") else { return nil }
            return resolveCandidate(at: override, files: files)
        }
        let dirs = searchDirectories(extraHomeBins: [], home: home, environment: environment)
        for dir in dirs {
            if let resolved = resolveCandidate(at: "\(dir)/\(name)", files: files) {
                return resolved
            }
        }
        return nil
    }

    /// Installs this preset's separate ACP adapter globally via `npm i -g <package>` and returns the resolved executable URL.
    public func installACPAdapter(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onOutput: (@Sendable (String) async -> Void)? = nil
    ) async throws -> URL {
        guard let package = adapterNPMPackage, let command = adapterInstallCommand else {
            throw ACPAdapterInstallError.notApplicable(agent: name)
        }
        guard let npmURL = Self.resolveTool(
            "npm",
            overrideVariable: "BOBUK_ACP_NPM_PATH",
            home: home,
            environment: environment
        ) else {
            throw ACPAdapterInstallError.npmNotFound(command: command)
        }

        let canonicalHome = Self.canonical(home)
        let npmDir = npmURL.deletingLastPathComponent().path
        var pathParts = [npmDir]
        for dir in searchDirectories(home: canonicalHome, environment: environment) where dir != npmDir {
            pathParts.append(dir)
        }

        var env: [String: String] = [
            "HOME": canonicalHome.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": pathParts.joined(separator: ":"),
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
        ]
        for key in ["npm_config_prefix", "NPM_CONFIG_PREFIX", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
                    "http_proxy", "https_proxy", "no_proxy", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"] {
            if let value = environment[key], !value.isEmpty { env[key] = value }
        }

        let result = try await Self.runInstallerProcess(
            executable: npmURL,
            arguments: ["install", "-g", package],
            environment: env,
            onOutput: onOutput
        )
        guard result.status == 0 else {
            throw ACPAdapterInstallError.failed(status: result.status, output: result.output, command: command)
        }

        var postEnv = environment
        let existingPath = postEnv["PATH"] ?? ""
        postEnv["PATH"] = existingPath.isEmpty ? npmDir : "\(npmDir):\(existingPath)"
        if let installed = resolveExecutable(home: home, environment: postEnv) {
            return installed
        }
        throw ACPAdapterInstallError.installedBinaryNotFound(agent: name, command: command)
    }

    private struct InstallerProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    private static func runInstallerProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) async -> Void)?
    ) async throws -> InstallerProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            final class Buffer: @unchecked Sendable {
                private let lock = NSLock()
                private var data = Data()
                func append(_ chunk: Data) {
                    lock.lock()
                    data.append(chunk)
                    lock.unlock()
                }
                func text() -> String {
                    lock.lock()
                    defer { lock.unlock() }
                    return String(data: data, encoding: .utf8) ?? ""
                }
            }
            let buffer = Buffer()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                if let onOutput, let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                    Task { await onOutput(text) }
                }
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty {
                    buffer.append(remaining)
                }
                try? pipe.fileHandleForReading.close()
                continuation.resume(returning: InstallerProcessResult(
                    status: finished.terminationStatus,
                    output: buffer.text()
                ))
            }

            do {
                try process.run()
                try? pipe.fileHandleForWriting.close()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
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
            if resolveCLIExecutable(home: home, environment: environment) != nil {
                throw ACPAgentLaunchError.acpAdapterMissing(agent: name, installHint: installHint)
            }
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

    /// Briefly connects to this agent in a temporary folder to read its available ACP models and
    /// reasoning effort options, then closes the subprocess immediately.
    public func probeCapabilities(
        sandboxed: Bool = true,
        clientName: String = "bobuk-probe",
        requestTimeout: Duration = .seconds(15),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (models: ACPModels?, efforts: ACPModels?) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bobuk-acp-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = try launch(
            in: dir,
            sandboxed: sandboxed,
            access: .textOnly,
            clientName: clientName,
            home: home,
            environment: environment
        )
        let client = ACPClient(launch: config, requestTimeout: requestTimeout, turnTimeout: requestTimeout)
        do {
            let models = try await client.connect()
            let efforts = await client.effortOptions()
            await client.close()
            return (models, efforts)
        } catch {
            await client.close()
            throw error
        }
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

        do {
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
        } catch {
            await client.close()
            throw error
        }
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
            case .textOnly, .tools: return false
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

        var allowWriteClauses = writableSubpaths.map { "(subpath \(Self.quoted($0)))" }
            + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")"]
        switch access {
        case .textOnly:
            break
        case .tools, .workspace:
            // Allow tool-enabled agents to allocate PTYs when running built-in or workspace tools.
            allowWriteClauses.append(contentsOf: [
                "(literal \"/dev/ptmx\")",
                "(regex #\"^/dev/ttys[0-9]+$\")",
            ])
        }
        let allowWrite = allowWriteClauses.joined(separator: " ")

        return """
        (version 1)
        (allow default)
        (deny file-read* file-write* (require-all (require-any \(denyProtected)) (require-not (require-any \(allowWorkspaceReads)))))
        (deny file-write* (require-not (require-any \(allowWrite))))
        """
    }

    private static func additionalRoots(from access: ACPAccessPolicy) -> [URL] {
        switch access {
        case .textOnly, .tools: return []
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
