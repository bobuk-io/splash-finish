import Foundation

public enum EventStatus: String, Codable, Sendable {
    case done, attention, running
}

public struct EventSource: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var bundleID: String?
    public var url: String?
    public var weztermPane: UInt64?
    public var orca: OrcaSource?
    public init(pid: Int32? = nil, bundleID: String? = nil, url: String? = nil, weztermPane: UInt64? = nil,
                orca: OrcaSource? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.url = url; self.weztermPane = weztermPane; self.orca = orca
    }
}

public struct AgentEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var task: String
    public var agent: String
    public var status: EventStatus
    public var title: String
    public var detail: String
    public var project: String
    public var source: EventSource?
    public var date: Date
    /// Optional producer-defined run generation and sequence. Legacy senders omit both.
    public var run: Int64?
    public var sequence: Int64?
    public var phase: String?
    public var key: String { agent.lowercased() + ":" + task }

    public init(id: String = UUID().uuidString, task: String, agent: String, status: EventStatus,
                title: String, detail: String = "", project: String = "", source: EventSource? = nil,
                date: Date = Date(), run: Int64? = nil, sequence: Int64? = nil, phase: String? = nil) {
        self.id = id; self.task = task; self.agent = agent; self.status = status
        self.title = title; self.detail = detail; self.project = project; self.source = source; self.date = date
        self.run = run; self.sequence = sequence; self.phase = phase
    }

    public func validated() throws -> Self {
        guard !task.isEmpty, task.utf8.count <= 512, !agent.isEmpty, agent.utf8.count <= 80,
              !id.isEmpty, id.utf8.count <= 128 else { throw EventError.invalid("Invalid event identity") }
        guard (run == nil && sequence == nil) || (run != nil && sequence != nil && run! >= 0 && sequence! >= 0) else {
            throw EventError.invalid("Event run and sequence must both be non-negative integers")
        }
        guard phase == nil || phase == "progress" else { throw EventError.invalid("Invalid event phase") }
        var event = self
        event.agent = Self.clean(agent, limit: 40)
        event.title = Self.clean(title, limit: 160)
        event.detail = Self.clean(detail, limit: 400)
        event.project = Self.clean(project, limit: 100)
        if event.title.isEmpty { event.title = status == .attention ? "Needs your attention" : "Work completed" }
        if let link = source?.url, !Self.isSafeSourceURL(link) { throw EventError.invalid("Unsupported source URL scheme") }
        if let orca = source?.orca { _ = try orca.validated() }
        return event
    }

    public static func clean(_ text: String, limit: Int) -> String {
        let printable = text.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : String(scalar)
        }.joined()
        return String(printable.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    public static func isSafeSourceURL(_ text: String) -> Bool {
        guard text.utf8.count <= 2048, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http", "vscode", "vscode-insiders", "cursor", "windsurf", "zed", "iterm2", "codex"].contains(scheme)
    }
}

public enum EventError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public enum DeepLink {
    public static let scheme = "splash-finish"
    public static func eventURL(_ event: AgentEvent) throws -> URL {
        let event = try event.validated()
        var c = URLComponents(); c.scheme = scheme; c.host = "event"
        var fields = ["id": event.id, "task": event.task, "agent": event.agent, "status": event.status.rawValue,
                      "title": event.title, "detail": event.detail, "project": event.project]
        if let phase = event.phase { fields["phase"] = phase }
        if let run = event.run, let sequence = event.sequence {
            fields["run"] = String(run); fields["sequence"] = String(sequence)
        }
        if let source = event.source {
            fields["source-pid"] = source.pid.map(String.init)
            fields["source-bundle"] = source.bundleID
            fields["source-url"] = source.url
            fields["wezterm-pane"] = source.weztermPane.map(String.init)
            fields["orca-terminal"] = source.orca?.terminal
            fields["orca-worktree"] = source.orca?.worktree
            fields["orca-pane"] = source.orca?.pane
        }
        c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw EventError.invalid("Could not encode event") }
        return url
    }

    public static func parse(_ url: URL) throws -> AgentEvent {
        guard url.scheme == scheme, url.host == "event", url.absoluteString.utf8.count <= 16384,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EventError.invalid("Invalid event URL") }
        var fields = [String: String]()
        for item in c.queryItems ?? [] {
            guard fields[item.name] == nil else { throw EventError.invalid("Duplicate URL field: \(item.name)") }
            fields[item.name] = item.value ?? ""
        }
        guard let agent = fields["agent"], let task = fields["task"],
              let status = EventStatus(rawValue: fields["status"] ?? "") else { throw EventError.invalid("Event requires agent, task and status") }
        let pane = fields["wezterm-pane"].flatMap(UInt64.init)
        guard fields["wezterm-pane"] == nil || pane != nil else { throw EventError.invalid("Invalid WezTerm pane ID") }
        let hasOrca = ["orca-terminal", "orca-worktree", "orca-pane"].contains { fields[$0] != nil }
        let orca = hasOrca ? OrcaSource(terminal: fields["orca-terminal"], worktree: fields["orca-worktree"], pane: fields["orca-pane"]) : nil
        let source = EventSource(pid: fields["source-pid"].flatMap(Int32.init), bundleID: fields["source-bundle"],
                                 url: fields["source-url"], weztermPane: pane, orca: orca)
        let run = fields["run"].flatMap(Int64.init), sequence = fields["sequence"].flatMap(Int64.init)
        guard (fields["run"] == nil && fields["sequence"] == nil) || (run != nil && sequence != nil) else {
            throw EventError.invalid("Invalid event ordering fields")
        }
        return try AgentEvent(id: fields["id"] ?? UUID().uuidString, task: task, agent: agent, status: status,
                              title: fields["title"] ?? "", detail: fields["detail"] ?? "", project: fields["project"] ?? "", source: source,
                              run: run, sequence: sequence, phase: fields["phase"]).validated()
    }
}
