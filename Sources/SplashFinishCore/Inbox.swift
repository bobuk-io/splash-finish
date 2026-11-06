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
        timestamps[Self.agentKey(event.agent)] = Date()
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

    /// Stable key for per-agent bookkeeping; display names may gain spaces or case.
    public static func agentKey(_ agent: String) -> String {
        agent.lowercased().filter { !$0.isWhitespace }
    }

    public mutating func dismiss(key: String) {
        items.removeAll { $0.key == key }
        if items.isEmpty { snoozedUntil = nil }
    }
    /// Consume only a successfully opened notification. Navigation can finish after
    /// a newer event for the same task arrives; that newer card must stay in the inbox.
    @discardableResult public mutating func completeSourceNavigation(_ event: AgentEvent, reachedExactSource: Bool) -> Bool {
        guard reachedExactSource, items.first(where: { $0.key == event.key }) == event else { return false }
        dismiss(key: event.key)
        return true
    }
    public mutating func clear() { items.removeAll(); snoozedUntil = nil }
    /// Dismiss everything except live keys, e.g. questions that are still connected.
    /// The per-item path stays in the caller because only it knows the open connections.
    public mutating func dismissAll(except keep: Set<String>) {
        items.removeAll { !keep.contains($0.key) }
        if items.isEmpty { snoozedUntil = nil }
    }
    /// Question placeholders are tied to ephemeral sockets and are stale after a restart.
    public mutating func discardQuestionPlaceholders() {
        items.removeAll { $0.agent.lowercased() == "pi" && $0.status == .attention && $0.task.hasPrefix(QuestionTask.prefix) }
        if items.isEmpty { snoozedUntil = nil }
    }
    public mutating func snooze(now: Date = Date(), duration: TimeInterval = 15 * 60) {
        guard !items.isEmpty else { return }
        snoozedUntil = now.addingTimeInterval(duration)
    }
    @discardableResult public mutating func wakeIfDue(now: Date = Date()) -> Bool {
        guard let deadline = snoozedUntil, now >= deadline else { return false }
        snoozedUntil = nil
        return !items.isEmpty
    }
    public mutating func reveal() { snoozedUntil = nil }
}

public enum QuestionTask {
    /// Task identifier prefix used for cards awaiting an answer.
    public static let prefix = "question-"
    public static func id(fromTask task: String) -> String? {
        task.hasPrefix(prefix) ? String(task.dropFirst(prefix.count)) : nil
    }
}

public enum Snooze {
    /// Seconds until the next morning, so the inbox stays quiet for the rest of the day.
    public static func untilTomorrowMorning(now: Date = Date(), hour: Int = 8, calendar: Calendar = .current) -> TimeInterval {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let morning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) else { return 12 * 60 * 60 }
        return max(60, morning.timeIntervalSince(now))
    }
}

public enum FocusStatus {
    /// Best-effort Do Not Disturb detection. macOS exposes no public Focus API; the
    /// system stores active assertions in this database. Unreadable means "not active".
    public static func isDoNotDisturbActive(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return false }
        return items.contains { !(($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty }
    }
}

public struct StateFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Inbox {
        try SafeFiles.check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return Inbox() }
        let data = try Data(contentsOf: url)
        // 200 bounded Markdown payloads, including JSON escaping and source metadata.
        guard data.count <= 8_000_000 else { throw EventError.invalid("Inbox state is too large") }
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
