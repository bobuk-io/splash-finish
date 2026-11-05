import Foundation

public enum EventStatus: String, Codable, Sendable {
    case done, attention, running
}

public struct EventSource: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var bundleID: String?
    public var url: String?
    public init(pid: Int32? = nil, bundleID: String? = nil, url: String? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.url = url
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
    public var key: String { agent.lowercased() + ":" + task }

    public init(id: String = UUID().uuidString, task: String, agent: String, status: EventStatus,
                title: String, detail: String = "", project: String = "", source: EventSource? = nil,
                date: Date = Date()) {
        self.id = id; self.task = task; self.agent = agent; self.status = status
        self.title = title; self.detail = detail; self.project = project; self.source = source; self.date = date
    }

    public func validated() throws -> Self {
        guard !task.isEmpty, task.utf8.count <= 512, !agent.isEmpty, agent.utf8.count <= 80,
              !id.isEmpty, id.utf8.count <= 128 else { throw EventError.invalid("Invalid event identity") }
        var event = self
        event.agent = Self.clean(agent, limit: 40)
        event.title = Self.clean(title, limit: 160)
        event.detail = Self.clean(detail, limit: 400)
        event.project = Self.clean(project, limit: 100)
        if event.title.isEmpty { event.title = status == .attention ? "Needs your attention" : "Work completed" }
        if let link = source?.url, !Self.isSafeSourceURL(link) { throw EventError.invalid("Unsupported source URL scheme") }
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
        if let source = event.source {
            fields["source-pid"] = source.pid.map(String.init)
            fields["source-bundle"] = source.bundleID
            fields["source-url"] = source.url
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
        let source = EventSource(pid: fields["source-pid"].flatMap(Int32.init), bundleID: fields["source-bundle"], url: fields["source-url"])
        return try AgentEvent(id: fields["id"] ?? UUID().uuidString, task: task, agent: agent, status: status,
                              title: fields["title"] ?? "", detail: fields["detail"] ?? "", project: fields["project"] ?? "", source: source).validated()
    }
}
