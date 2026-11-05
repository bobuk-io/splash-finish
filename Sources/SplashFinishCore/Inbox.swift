import Foundation

public struct Inbox: Codable, Equatable, Sendable {
    public private(set) var items: [AgentEvent] = []
    public private(set) var snoozedUntil: Date?
    public private(set) var seenEventIDs: [String] = []
    public init() {}
    public var attention: [AgentEvent] { items.filter { $0.status == .attention } }
    public var completed: [AgentEvent] { items.filter { $0.status == .done } }

    /// Returns true only when this event should reveal the panel.
    @discardableResult public mutating func receive(_ raw: AgentEvent) throws -> Bool {
        let event = try raw.validated()
        guard !seenEventIDs.contains(event.id) else { return false }
        seenEventIDs.append(event.id)
        seenEventIDs = Array(seenEventIDs.suffix(512))
        if event.status == .running {
            items.removeAll { $0.key == event.key }
            if items.isEmpty { snoozedUntil = nil }
            return false
        }
        if let previous = items.first(where: { $0.key == event.key }),
           previous.status == event.status, previous.title == event.title, previous.detail == event.detail,
           previous.project == event.project, previous.source == event.source { return false }
        if let index = items.firstIndex(where: { $0.key == event.key }) { items[index] = event }
        else { items.append(event) }
        items = Array(items.suffix(200))
        snoozedUntil = nil
        return true
    }

    public mutating func dismiss(key: String) {
        items.removeAll { $0.key == key }
        if items.isEmpty { snoozedUntil = nil }
    }
    public mutating func clear() { items.removeAll(); snoozedUntil = nil }
    public mutating func snooze(now: Date = Date()) {
        guard !items.isEmpty else { return }
        snoozedUntil = now.addingTimeInterval(15 * 60)
    }
    @discardableResult public mutating func wakeIfDue(now: Date = Date()) -> Bool {
        guard let deadline = snoozedUntil, now >= deadline else { return false }
        snoozedUntil = nil
        return !items.isEmpty
    }
    public mutating func reveal() { snoozedUntil = nil }
}

public struct StateFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Inbox {
        try SafeFiles.check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return Inbox() }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw EventError.invalid("Inbox state is too large") }
        return try JSONDecoder().decode(Inbox.self, from: data)
    }
    public func save(_ inbox: Inbox) throws {
        try SafeFiles.prepareDirectory(url.deletingLastPathComponent())
        try SafeFiles.write(try JSONEncoder().encode(inbox), to: url)
    }
}

public enum AppPaths {
    public static let bundleID = "io.bobuk.splash-finish"
    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment["SPLASH_FINISH_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Splash Finish", isDirectory: true)
    }
    public static var state: URL { support.appendingPathComponent("state.json") }
}
