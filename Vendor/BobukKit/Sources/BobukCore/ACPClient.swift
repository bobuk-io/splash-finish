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

public struct ACPLaunchConfiguration: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]?
    public let clientName: String
    public let isolation: ACPProcessIsolation

    public init(executable: URL, arguments: [String], directory: URL,
                environment: [String: String]? = nil, clientName: String, isolation: ACPProcessIsolation) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.clientName = clientName
        self.isolation = isolation
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

    fileprivate init?(_ result: [String: Any]) {
        guard let config = (result["configOptions"] as? [[String: Any]])?.first(where: {
            $0["type"] as? String == "select" && ($0["category"] as? String == "model" || $0["id"] as? String == "model")
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
        case .unexpectedTool: "The agent tried to use a tool. This text-only session was disconnected."
        case .startFailed: "The agent could not be started. Check its installation."
        case .rejected: "The agent did not complete the request. Check its configuration and try again."
        }
    }
}

/// Minimal ACP v1 text client. Never provides filesystem, terminal, or MCP capabilities.
/// Declining ACP callbacks is not a sandbox. The caller chooses explicit process isolation.
public actor ACPClient {
    public static let maxPromptBytes = 8_192
    private static let maxFrameBytes = 1_048_576
    private static let maxReplyBytes = 131_072

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
    private var modelUpdates: (@Sendable (ACPModels?) async -> Void)?
    private var chunks: (@Sendable (String) async -> Void)?
    private var replyBytes = 0
    private var stopping = false
    private var closed = false

    public init(launch: ACPLaunchConfiguration, requestTimeout: Duration = .seconds(20),
                turnTimeout: Duration = .seconds(120)) {
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
            let hello = try await request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:],
                                                                  "clientInfo": ["name": launch.clientName, "version": "0.1.0"]])
            guard hello["protocolVersion"] as? Int == 1 else { throw ACPError.unsupportedVersion }
            let result = try await request("session/new", params: ["cwd": launch.directory.path, "mcpServers": []])
            guard let id = result["sessionId"] as? String, !id.isEmpty else { throw ACPError.invalidResponse }
            session = id
            models = ACPModels(result)
            modelUpdates = onModels
            return models
        } catch {
            close()
            throw error
        }
    }

    public func selectModel(_ value: String) async throws -> ACPModels? {
        guard let session else { throw ACPError.disconnected }
        guard let models, models.choices.contains(where: { $0.id == value }) else { throw ACPError.invalidModel }
        let result = try await request("session/set_config_option", params: ["sessionId": session,
                                                                               "configId": models.configID, "value": value])
        self.models = ACPModels(result)
        return self.models
    }

    public func prompt(_ text: String, onChunk: @escaping @Sendable (String) async -> Void) async throws -> String {
        try Task.checkCancellation()
        guard let session else { throw ACPError.disconnected }
        guard pending == nil, chunks == nil else { throw ACPError.busy }
        guard text.utf8.count <= Self.maxPromptBytes else { throw ACPError.promptTooLarge }
        chunks = onChunk
        replyBytes = 0
        stopping = false
        defer { chunks = nil; stopping = false }
        let result = try await request("session/prompt", params: ["sessionId": session, "prompt": [["type": "text", "text": text]]],
                                       timeout: turnTimeout)
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
        child.standardError = FileHandle.nullDevice  // May contain provider data. Never surface it to the application.
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
                // JSON-RPC server requests use their own IDs, independent of our pending request.
                do {
                    if method == "session/request_permission" {
                        try send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                    } else {
                        try send(["id": id, "error": ["code": -32601, "message": "Method not supported"]])
                    }
                } catch { disconnect(.disconnected) }
                return
            }
            guard method == "session/update", let params = message["params"] as? Object,
                  let session, params["sessionId"] as? String == session, let update = params["update"] as? Object else { return }
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                if !stopping, let chunks, let content = update["content"] as? Object,
                   content["type"] as? String == "text", let text = content["text"] as? String {
                    replyBytes += text.utf8.count
                    guard replyBytes <= Self.maxReplyBytes else { disconnect(.outputTooLarge); return }
                    await chunks(text)
                }
            case "tool_call", "tool_call_update":
                // Reported tool execution is unexpected. Sandbox restrictions must already be in place.
                if let status = update["status"] as? String,
                   ["in_progress", "completed"].contains(status) { disconnect(.unexpectedTool) }
            case "config_option_update":
                models = ACPModels(update)
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
        modelUpdates = nil
        buffer.removeAll()
        if let pending {
            self.pending = nil
            pending.timeout?.cancel()
            pending.continuation.resume(throwing: error)
        }
    }
}
