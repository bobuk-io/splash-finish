import Darwin
import Foundation

/// Process-level isolation, independent of the client-side ACP permission policy.
public enum ACPProcessIsolation: Sendable {
    /// The launcher receives its own arguments, then the agent executable and its arguments.
    /// The caller supplies a trusted launcher and a policy appropriate for the app.
    case sandboxed(launcher: URL, arguments: [String])
    /// Start the agent directly, with the application's OS privileges.
    case unrestricted
}

/// Client-side ACP capabilities and permission behavior for an agent session.
public enum ACPAccessPolicy: Equatable, Sendable {
    /// Pure text chat: advertises no filesystem/terminal capabilities, cancels permission requests,
    /// and disconnects if the agent executes a tool call.
    case textOnly
    /// Workspace-enabled agent: opens the session in `ACPLaunchConfiguration.directory`,
    /// advertises `fs.readTextFile` (and `fs.writeTextFile` when `allowWrite` is true) scoped to
    /// `ACPLaunchConfiguration.directory` plus `additionalRoots`, permits tool call updates, and
    /// automatically selects `allow_once` on `session/request_permission` when `autoApproveTools` is true.
    case workspace(allowWrite: Bool = true, autoApproveTools: Bool = true, additionalRoots: [URL] = [])
}

public struct ACPLaunchConfiguration: Sendable {
    public let executable: URL
    public let arguments: [String]
    /// Working directory (`cwd`) passed to the subprocess and to ACP `session/new`.
    public let directory: URL
    public let environment: [String: String]?
    public let clientName: String
    public let isolation: ACPProcessIsolation
    public let access: ACPAccessPolicy

    public init(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String]? = nil,
        clientName: String,
        isolation: ACPProcessIsolation,
        access: ACPAccessPolicy = .textOnly
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.clientName = clientName
        self.isolation = isolation
        self.access = access
    }
}

public struct ACPModels: Equatable, Sendable {
    public struct Choice: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
    }
    public let current: String
    public let choices: [Choice]
    fileprivate let configID: String

    fileprivate init?(_ result: [String: Any], categories: Set<String>, ids: Set<String>) {
        guard let config = (result["configOptions"] as? [[String: Any]])?.first(where: {
            $0["type"] as? String == "select"
                && (categories.contains(($0["category"] as? String ?? "").lowercased())
                    || ids.contains(($0["id"] as? String ?? "").lowercased()))
        }), let id = config["id"] as? String, let current = config["currentValue"] as? String else { return nil }
        let values = config["options"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        choices = values.flatMap { ($0["options"] as? [[String: Any]]) ?? [$0] }.compactMap { option in
            guard let value = option["value"] as? String, seen.insert(value).inserted else { return nil }
            return Choice(id: value, name: option["name"] as? String ?? value)
        }
        self.current = current
        configID = id
    }

    fileprivate init?(_ result: [String: Any]) {
        self.init(result, categories: ["model"], ids: ["model"])
    }

    fileprivate func resolve(_ query: String) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = choices.first(where: { $0.id == needle }) { return exact.id }
        if let ciExact = choices.first(where: {
            $0.id.caseInsensitiveCompare(needle) == .orderedSame
                || $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }) { return ciExact.id }
        if let partial = choices.first(where: {
            $0.id.localizedCaseInsensitiveContains(needle)
                || $0.name.localizedCaseInsensitiveContains(needle)
        }) { return partial.id }
        return nil
    }
}

/// Options for a headless one-shot ACP call (`ACPAgentPreset.ask(...)`).
public struct ACPPromptOptions: Equatable, Sendable {
    /// Model ID, display name, or case-insensitive substring (e.g. `"gemini-3.8-flash"` or `"sonnet"`).
    public var model: String?
    /// Reasoning effort / thinking level (e.g. `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`).
    public var effort: String?
    public var sandboxed: Bool
    public var access: ACPAccessPolicy
    public var requestTimeout: Duration
    public var turnTimeout: Duration
    public var extraArguments: [String]

    public init(
        model: String? = nil,
        effort: String? = nil,
        sandboxed: Bool = true,
        access: ACPAccessPolicy = .textOnly,
        requestTimeout: Duration = .seconds(25),
        turnTimeout: Duration = .seconds(180),
        extraArguments: [String] = []
    ) {
        self.model = model
        self.effort = effort
        self.sandboxed = sandboxed
        self.access = access
        self.requestTimeout = requestTimeout
        self.turnTimeout = turnTimeout
        self.extraArguments = extraArguments
    }
}

/// Result returned by a headless one-shot ACP call.
public struct ACPPromptResponse: Equatable, Sendable {
    public let text: String
    public let stopReason: String
    public let model: String?
    public let effort: String?

    public init(text: String, stopReason: String, model: String?, effort: String?) {
        self.text = text
        self.stopReason = stopReason
        self.model = model
        self.effort = effort
    }
}

public enum ACPError: LocalizedError, Equatable, Sendable {
    case disconnected, timedOut, invalidResponse, unsupportedVersion, authenticationRequired
    case busy, invalidModel, promptTooLarge, outputTooLarge, unexpectedTool, startFailed, rejected

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The agent disconnected. Connect again to continue."
        case .timedOut: "The agent did not respond in time. Connect again to retry."
        case .invalidResponse: "The agent returned an invalid ACP response."
        case .unsupportedVersion: "This agent does not support ACP version 1."
        case .authenticationRequired: "Sign in to the agent in Terminal, then connect again."
        case .busy: "Wait for the current request to finish."
        case .invalidModel: "That model is no longer available."
        case .promptTooLarge: "The message is too long. Shorten it and try again."
        case .outputTooLarge: "The agent exceeded the response size limit."
        case .unexpectedTool: "The agent tried to use a tool in a text-only session."
        case .startFailed: "The agent could not be started. Check its installation."
        case .rejected: "The agent did not complete the request. Check its configuration and try again."
        }
    }
}

/// ACP v1 JSON-RPC client over stdio.
/// Supports both `.textOnly` sessions and `.workspace` sessions with scoped file access and tool calls.
public actor ACPClient {
    public static let maxPromptBytes = 32_768
    private static let maxFrameBytes = 2_097_152
    private static let maxReplyBytes = 262_144
    private static let maxFileReadBytes = 524_288

    private typealias Object = [String: Any]
    private struct Response: @unchecked Sendable { let object: Object }
    private struct Pending {
        let id: Int
        let continuation: CheckedContinuation<Response, Error>
        var timeout: Task<Void, Never>?
    }

    private let launch: ACPLaunchConfiguration
    private let requestTimeout: Duration
    private let turnTimeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var frames: AsyncStream<Data>.Continuation?
    private var reader: Task<Void, Never>?
    private var pending: Pending?
    private var buffer = Data()
    private var serial = 0
    private var session: String?
    private var models: ACPModels?
    private var efforts: ACPModels?
    private var modelUpdates: (@Sendable (ACPModels?) async -> Void)?
    private var chunks: (@Sendable (String) async -> Void)?
    private var toolStatuses: (@Sendable (String?) async -> Void)?
    private var replyBytes = 0
    private var stopping = false
    private var closed = false

    public init(launch: ACPLaunchConfiguration, requestTimeout: Duration = .seconds(25),
                turnTimeout: Duration = .seconds(180)) {
        self.launch = launch
        self.requestTimeout = requestTimeout
        self.turnTimeout = turnTimeout
    }

    public func connect(onModels: (@Sendable (ACPModels?) async -> Void)? = nil) async throws -> ACPModels? {
        guard !closed else { throw ACPError.disconnected }
        if session != nil { return models }
        guard process == nil else { throw ACPError.busy }
        try start()
        do {
            let hello = try await request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": clientCapabilities(),
                "clientInfo": ["name": launch.clientName, "version": "0.1.0"],
            ])
            guard hello["protocolVersion"] as? Int == 1 else { throw ACPError.unsupportedVersion }
            let result = try await request("session/new", params: [
                "cwd": Self.canonicalPath(launch.directory),
                "mcpServers": [],
            ])
            guard let id = result["sessionId"] as? String, !id.isEmpty else { throw ACPError.invalidResponse }
            session = id
            models = ACPModels(result)
            efforts = Self.parseEfforts(result)
            modelUpdates = onModels
            return models
        } catch {
            close()
            throw error
        }
    }

    public func selectModel(_ value: String) async throws -> ACPModels? {
        guard let session else { throw ACPError.disconnected }
        guard let models, let resolved = models.resolve(value) else { throw ACPError.invalidModel }
        let result = try await request("session/set_config_option", params: [
            "sessionId": session,
            "configId": models.configID,
            "value": resolved,
        ])
        self.models = ACPModels(result)
        self.efforts = Self.parseEfforts(result) ?? self.efforts
        return self.models
    }

    /// Selects reasoning effort / thinking level (e.g. `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`).
    /// Returns `nil` when the agent does not expose an effort option.
    public func selectEffort(_ value: String) async throws -> String? {
        guard let session else { throw ACPError.disconnected }
        guard let efforts, let resolved = efforts.resolve(value) else { return nil }
        let result = try await request("session/set_config_option", params: [
            "sessionId": session,
            "configId": efforts.configID,
            "value": resolved,
        ])
        self.models = ACPModels(result) ?? self.models
        self.efforts = Self.parseEfforts(result) ?? self.efforts
        return self.efforts?.current ?? resolved
    }

    public func currentEffort() -> String? {
        efforts?.current
    }

    private static func parseEfforts(_ result: Object) -> ACPModels? {
        ACPModels(
            result,
            categories: ["thought_level", "reasoning_effort", "effort"],
            ids: ["thought_level", "reasoning_effort", "effort", "thinking_level", "thinking"]
        )
    }

    public func prompt(
        _ text: String,
        onTool: (@Sendable (String?) async -> Void)? = nil,
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        guard let session else { throw ACPError.disconnected }
        guard pending == nil, chunks == nil else { throw ACPError.busy }
        guard text.utf8.count <= Self.maxPromptBytes else { throw ACPError.promptTooLarge }
        chunks = onChunk
        toolStatuses = onTool
        replyBytes = 0
        stopping = false
        defer {
            chunks = nil
            toolStatuses = nil
            stopping = false
        }
        let result = try await request(
            "session/prompt",
            params: ["sessionId": session, "prompt": [["type": "text", "text": text]]],
            timeout: turnTimeout
        )
        if stopping { return "cancelled" }
        guard let reason = result["stopReason"] as? String else { throw ACPError.invalidResponse }
        return reason
    }

    public func cancel() {
        guard let session, chunks != nil, let current = pending, !stopping else { return }
        stopping = true
        do {
            try send(["method": "session/cancel", "params": ["sessionId": session]])
            current.timeout?.cancel()
            pending?.timeout = deadline(current.id, after: .seconds(3))
        } catch { close() }
    }

    /// End this session and free the child process. Create a fresh client to reconnect.
    public func close() { disconnect(.disconnected) }

    // MARK: - Capabilities & Server Requests

    private func clientCapabilities() -> Object {
        switch launch.access {
        case .textOnly:
            return [:]
        case let .workspace(allowWrite, _, _):
            return ["fs": ["readTextFile": true, "writeTextFile": allowWrite]]
        }
    }

    private func allowedRoots() -> [String] {
        switch launch.access {
        case .textOnly:
            return []
        case let .workspace(_, _, additionalRoots):
            return ([launch.directory] + additionalRoots).map(Self.canonicalPath)
        }
    }

    private func isPathAllowed(_ rawPath: String, forWriting: Bool) -> URL? {
        guard rawPath.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL
        // Resolve existing parent directory for new files so symlinks cannot escape allowed roots.
        let probeURL: URL = FileManager.default.fileExists(atPath: standardized.path)
            ? standardized
            : standardized.deletingLastPathComponent()
        let resolvedParent = Self.canonicalPath(probeURL)
        let candidatePath = FileManager.default.fileExists(atPath: standardized.path)
            ? resolvedParent
            : (resolvedParent == "/" ? "/\(standardized.lastPathComponent)" : "\(resolvedParent)/\(standardized.lastPathComponent)")

        let allowed = allowedRoots().contains { root in
            if root == "/" { return true }
            return candidatePath == root || candidatePath.hasPrefix(root + "/")
        }
        guard allowed else { return nil }

        if forWriting {
            // Never allow writing hidden control files (.git, .env, dotfiles) via ACP fs callbacks.
            let components = URL(fileURLWithPath: candidatePath).pathComponents
            if components.contains(where: { $0 == ".git" || $0 == ".gemini" || $0 == ".claude" || $0 == ".codex" }) {
                return nil
            }
        }
        return URL(fileURLWithPath: candidatePath)
    }

    private func handleServerRequest(id: Any, method: String, params: Object?) throws {
        switch method {
        case "session/request_permission":
            if stopping {
                try send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                return
            }
            if case let .workspace(_, autoApproveTools, _) = launch.access, autoApproveTools,
               let options = params?["options"] as? [Object] {
                let allowOption = options.first(where: { $0["kind"] as? String == "allow_once" })
                    ?? options.first(where: { ($0["kind"] as? String)?.hasPrefix("allow") == true })
                if let optionID = allowOption?["optionId"] as? String {
                    try send(["id": id, "result": ["outcome": ["outcome": "selected", "optionId": optionID]]])
                    return
                }
            }
            let rejectOption = (params?["options"] as? [Object])?.first(where: {
                ($0["kind"] as? String)?.hasPrefix("reject") == true
            })
            if let optionID = rejectOption?["optionId"] as? String {
                try send(["id": id, "result": ["outcome": ["outcome": "selected", "optionId": optionID]]])
            } else {
                try send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
            }

        case "fs/read_text_file":
            guard case .workspace = launch.access else {
                try send(["id": id, "error": ["code": -32601, "message": "Method not supported"]])
                return
            }
            guard let path = params?["path"] as? String, let fileURL = isPathAllowed(path, forWriting: false) else {
                try send(["id": id, "error": ["code": -32000, "message": "Path is outside the allowed workspace"]])
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maxFileReadBytes) ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                let sliced = Self.sliceLines(text, line: params?["line"] as? Int, limit: params?["limit"] as? Int)
                try send(["id": id, "result": ["content": sliced]])
            } catch {
                try send(["id": id, "error": ["code": -32000, "message": error.localizedDescription]])
            }

        case "fs/write_text_file":
            guard case let .workspace(allowWrite, _, _) = launch.access, allowWrite else {
                try send(["id": id, "error": ["code": -32601, "message": "Method not supported"]])
                return
            }
            guard let path = params?["path"] as? String,
                  let content = params?["content"] as? String,
                  let fileURL = isPathAllowed(path, forWriting: true) else {
                try send(["id": id, "error": ["code": -32000, "message": "Write denied outside allowed workspace"]])
                return
            }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: fileURL, options: .atomic)
                try send(["id": id, "result": [:]])
            } catch {
                try send(["id": id, "error": ["code": -32000, "message": error.localizedDescription]])
            }

        default:
            try send(["id": id, "error": ["code": -32601, "message": "Method not supported"]])
        }
    }

    private static func sliceLines(_ content: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return content }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return "" }
        let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Subprocess & Transport

    private func start() throws {
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        switch launch.isolation {
        case let .sandboxed(launcher, arguments):
            child.executableURL = launcher
            child.arguments = arguments + [launch.executable.path] + launch.arguments
        case .unrestricted:
            child.executableURL = launch.executable
            child.arguments = launch.arguments
        }
        child.currentDirectoryURL = launch.directory
        child.environment = launch.environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let writer = stdin.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else { throw ACPError.startFailed }
        do { try child.run() } catch { throw ACPError.startFailed }

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let output = stdout.fileHandleForReading
        process = child
        input = writer
        self.output = output
        frames = continuation
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() }
            else if case .dropped = continuation.yield(data) { continuation.finish() }
        }
        reader = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(data)
            }
            if !Task.isCancelled { await self?.close() }
        }
    }

    private func request(_ method: String, params: Object, timeout: Duration? = nil) async throws -> Object {
        guard pending == nil else { throw ACPError.busy }
        serial += 1
        let id = serial
        let duration = timeout ?? requestTimeout
        let response: Response = try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: id, continuation: continuation, timeout: deadline(id, after: duration))
            do { try send(["id": id, "method": method, "params": params]) }
            catch { disconnect(.disconnected) }
        }
        return response.object
    }

    private func deadline(_ id: Int, after duration: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.expire(id)
        }
    }

    private func expire(_ id: Int) {
        if pending?.id == id { disconnect(.timedOut) }
    }

    private func send(_ message: Object) throws {
        guard let input else { throw ACPError.disconnected }
        var envelope = message
        envelope["jsonrpc"] = "2.0"
        var data = try JSONSerialization.data(withJSONObject: envelope)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) async {
        guard process != nil else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= Self.maxFrameBytes else {
                disconnect(.outputTooLarge)
                return
            }
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            if line.isEmpty { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? Object,
                  message["jsonrpc"] as? String == "2.0" else {
                disconnect(.invalidResponse)
                return
            }
            await receiveMessage(message)
            guard !Task.isCancelled, process != nil else { return }
        }
        if buffer.count > Self.maxFrameBytes { disconnect(.outputTooLarge) }
    }

    private func receiveMessage(_ message: Object) async {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                do {
                    try handleServerRequest(id: id, method: method, params: message["params"] as? Object)
                } catch {
                    disconnect(.disconnected)
                }
                return
            }
            guard method == "session/update", let params = message["params"] as? Object,
                  let session, params["sessionId"] == nil || params["sessionId"] as? String == session,
                  let update = params["update"] as? Object else { return }
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if !stopping, let chunks, let content = update["content"] as? Object,
                   content["type"] as? String == "text", let text = content["text"] as? String {
                    replyBytes += text.utf8.count
                    guard replyBytes <= Self.maxReplyBytes else { disconnect(.outputTooLarge); return }
                    await chunks(text)
                }
            case "tool_call", "tool_call_update":
                let status = update["status"] as? String
                if launch.access == .textOnly {
                    if let status, ["in_progress", "completed"].contains(status) {
                        disconnect(.unexpectedTool)
                    }
                } else {
                    if status == "in_progress" || status == "pending" {
                        let title = (update["title"] as? String) ?? (update["name"] as? String) ?? "Running tool…"
                        await toolStatuses?(title)
                    } else if status == "completed" || status == "failed" || status == "cancelled" {
                        await toolStatuses?(nil)
                    }
                }
            case "config_option_update":
                models = ACPModels(update) ?? models
                efforts = Self.parseEfforts(update) ?? efforts
                await modelUpdates?(models)
            default: break
            }
            return
        }
        guard let id = message["id"] as? Int, let pending, pending.id == id else { return }
        self.pending = nil
        pending.timeout?.cancel()
        if let error = message["error"] as? Object {
            let auth = error["code"] as? Int == -32000
                && (error["message"] as? String)?.localizedCaseInsensitiveContains("auth") == true
            if stopping { pending.continuation.resume(returning: Response(object: ["stopReason": "cancelled"])) }
            else { pending.continuation.resume(throwing: auth ? ACPError.authenticationRequired : .rejected) }
        } else if let result = message["result"] as? Object {
            pending.continuation.resume(returning: Response(object: result))
        } else { pending.continuation.resume(throwing: ACPError.invalidResponse) }
    }

    private func disconnect(_ error: ACPError) {
        closed = true
        reader?.cancel()
        reader = nil
        frames?.finish()
        frames = nil
        output?.readabilityHandler = nil
        try? output?.close()
        try? input?.close()
        output = nil
        input = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        session = nil
        models = nil
        efforts = nil
        modelUpdates = nil
        buffer.removeAll()
        if let pending {
            self.pending = nil
            pending.timeout?.cancel()
            pending.continuation.resume(throwing: error)
        }
    }
}
