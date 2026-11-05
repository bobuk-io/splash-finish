import Foundation

public struct EventOrder: Codable, Equatable, Sendable {
    public var run: Int64
    public var sequence: Int64
    public var received: Date
}

public struct Inbox: Codable, Equatable, Sendable {
    public private(set) var items: [AgentEvent] = []
    public private(set) var snoozedUntil: Date?
    public private(set) var seenEventIDs: [String] = []
    // Optional for compatibility with state files written by older versions.
    public private(set) var latestOrders: [String: EventOrder]?
    public private(set) var lastEvents: [String: Date]?
    public init() {}
    public var attention: [AgentEvent] { items.filter { $0.status == .attention } }
    public var completed: [AgentEvent] { items.filter { $0.status == .done } }

    /// Returns true only when this event should reveal the panel.
    @discardableResult public mutating func receive(_ raw: AgentEvent) throws -> Bool {
        let event = try raw.validated()
        guard !seenEventIDs.contains(event.id) else { return false }
        // Once a producer upgrades a task to ordered events, do not let a delayed
        // legacy event erase the newer state. Ordering metadata is per task.
        if event.run == nil && latestOrders?[event.key] != nil { return false }
        if let run = event.run, let sequence = event.sequence {
            var orders = latestOrders ?? [:]
            if let current = orders[event.key],
               run < current.run || (run == current.run && sequence <= current.sequence) { return false }
            orders[event.key] = EventOrder(run: run, sequence: sequence, received: Date())
            if orders.count > 512 {
                for key in orders.sorted(by: { $0.value.received < $1.value.received }).prefix(orders.count - 512).map(\.key) {
                    orders.removeValue(forKey: key)
                }
            }
            latestOrders = orders
        }
        var timestamps = lastEvents ?? [:]
        timestamps[event.agent.lowercased()] = Date()
        lastEvents = timestamps
        seenEventIDs.append(event.id)
        seenEventIDs = Array(seenEventIDs.suffix(512))
        if event.status == .running {
            // Concurrent tool-completion hooks can arrive after the final Stop.
            // A progress event can clear attention, but not a completed result.
            if event.phase == "progress", items.contains(where: { $0.key == event.key && $0.status == .done }) {
                return false
            }
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
