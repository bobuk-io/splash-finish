import AppKit
import XCTest
import SplashFinishCore
@testable import SplashFinish

final class SnoozeWakeTests: XCTestCase {
    /// Events that keep arriving after the deadline must not postpone the wake.
    func testEventsAfterDeadlineDoNotPostponeWake() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(stateURL: root.appendingPathComponent("state.json"))
            model.respectFocus = false
            var reveals: [Bool] = []
            model.onChange = { reveals.append($0) }
            model.receive(AgentEvent(task: "one", agent: "Codex", status: .done, title: "First"))
            model.snooze(until: Date().addingTimeInterval(3600))
            reveals.removeAll()
            model.receive(AgentEvent(task: "two", agent: "Codex", status: .done, title: "Second"))
            XCTAssertEqual(reveals, [false], "An event during snooze must not reveal the panel")
            XCTAssertNotNil(model.inbox.snoozedUntil)

            model.snooze(until: Date().addingTimeInterval(0.01))
            Thread.sleep(forTimeInterval: 0.03) // Deadline passes; the wake timer has not run yet.
            reveals.removeAll()
            // A burst of events, each within the 50 ms timer floor, without running the run loop.
            for index in 0..<5 {
                model.receive(AgentEvent(task: "burst-\(index)", agent: "Codex", status: .done, title: "Burst \(index)"))
            }
            XCTAssertNil(model.inbox.snoozedUntil, "A passed deadline must end snooze at once")
            XCTAssertTrue(reveals.contains(true), "The first event after the deadline reveals the panel")

            model.snooze(until: Date().addingTimeInterval(0.01))
            Thread.sleep(forTimeInterval: 0.03)
            reveals.removeAll()
            // A progress event does not reveal by itself, but the due wake must not be lost.
            model.receive(AgentEvent(task: "burst-0", agent: "Codex", status: .running, title: "Working"))
            XCTAssertNil(model.inbox.snoozedUntil)
            XCTAssertEqual(reveals, [true], "A due wake reveals the panel even on a progress event")
            model.clear()
        }
    }

    @MainActor
    func testEmptyInboxRefreshesWithoutRevealingWhenSnoozeExpires() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(stateURL: root.appendingPathComponent("state.json"))
        defer { model.onChange = nil }
        model.snooze(until: Date().addingTimeInterval(0.05))

        let expired = expectation(description: "The menu bar receives the snooze expiration")
        model.onChange = { reveal in
            XCTAssertFalse(reveal, "An empty inbox must stay hidden")
            XCTAssertNil(model.inbox.snoozedUntil)
            expired.fulfill()
        }
        await fulfillment(of: [expired], timeout: 2)
    }

    @MainActor
    func testUnsnoozeKeepsInboxHiddenAndResumesNotifications() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(stateURL: root.appendingPathComponent("state.json"))
        model.respectFocus = false
        var reveals: [Bool] = []
        model.onChange = { reveals.append($0) }

        for deadline in [nil, Date.distantFuture] {
            model.receive(AgentEvent(task: "old", agent: "Codex", status: .done, title: "First"))
            model.snooze(until: deadline)
            XCTAssertTrue(model.isSnoozed)
            reveals.removeAll()

            model.unsnooze()
            XCTAssertFalse(model.isSnoozed)
            XCTAssertEqual(reveals, [false])
            XCTAssertEqual(model.items.map(\.task), ["old"])

            model.receive(AgentEvent(task: "new", agent: "Codex", status: .attention, title: "Second"))
            XCTAssertEqual(reveals, [false, true])
            model.clear()
        }
    }
}
