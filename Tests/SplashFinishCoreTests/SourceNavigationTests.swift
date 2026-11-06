import XCTest
@testable import SplashFinishCore

final class SourceNavigationTests: XCTestCase {
    private func event(_ task: String = "one", title: String = "Done") -> AgentEvent {
        AgentEvent(task: task, agent: "pi", status: .done, title: title)
    }

    func testExactNavigationRemovesLastCardAndLeavesInboxEmpty() throws {
        var inbox = Inbox()
        let opened = event()
        try inbox.receive(opened)
        inbox.snooze()
        XCTAssertTrue(inbox.completeSourceNavigation(opened, reachedExactSource: true))
        XCTAssertTrue(inbox.items.isEmpty, "An empty visible inbox hides the panel")
        XCTAssertNil(inbox.snoozedUntil)
        var selection = KeyboardSelection()
        selection.reconcile(keys: inbox.items.map(\.key))
        XCTAssertNil(selection.key)
        XCTAssertFalse(try inbox.receive(opened), "Opening does not reset event replay protection")
    }

    func testExactNavigationRemovesOnlyOpenedCardAndKeepsOthers() throws {
        var inbox = Inbox()
        let first = event("one"), opened = event("two"), third = event("three")
        for item in [first, opened, third] { try inbox.receive(item) }
        var selection = KeyboardSelection()
        selection.reconcile(keys: inbox.items.map(\.key))
        selection.move(1, keys: inbox.items.map(\.key))
        XCTAssertEqual(selection.key, opened.key)
        XCTAssertTrue(inbox.completeSourceNavigation(opened, reachedExactSource: true))
        XCTAssertEqual(inbox.items, [first, third])
        selection.reconcile(keys: inbox.items.map(\.key))
        XCTAssertEqual(selection.key, third.key)
    }

    func testFailureOrAppOnlyFallbackKeepsCardAndSnooze() throws {
        var inbox = Inbox()
        let opened = event()
        try inbox.receive(opened)
        inbox.snooze()
        let before = inbox
        XCTAssertFalse(inbox.completeSourceNavigation(opened, reachedExactSource: false))
        XCTAssertEqual(inbox, before)
    }

    func testLateNavigationCannotDeleteNewerUpdateForSameTask() throws {
        var inbox = Inbox()
        let opened = event()
        try inbox.receive(opened)
        let newer = event(title: "New result waiting for review")
        try inbox.receive(newer)
        XCTAssertFalse(inbox.completeSourceNavigation(opened, reachedExactSource: true))
        XCTAssertEqual(inbox.items, [newer])
        XCTAssertTrue(inbox.completeSourceNavigation(newer, reachedExactSource: true))
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testCompareWholeSnapshotNotOnlyIDAndIgnoreDuplicateCompletions() throws {
        var inbox = Inbox()
        let opened = event()
        try inbox.receive(opened)
        // External senders may reuse a replay ID after it leaves the bounded history.
        // Even then, a callback must match the actual card, not just its key or ID.
        var stale = opened
        stale.title = "Old snapshot"
        XCTAssertFalse(inbox.completeSourceNavigation(stale, reachedExactSource: true))
        XCTAssertEqual(inbox.items, [opened])
        XCTAssertTrue(inbox.completeSourceNavigation(opened, reachedExactSource: true))
        XCTAssertFalse(inbox.completeSourceNavigation(opened, reachedExactSource: true))
    }
}
