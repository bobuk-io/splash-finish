import XCTest
@testable import SplashFinishCore

final class KeyboardNavigationTests: XCTestCase {
    func testSelectionFollowsVisibleOrderAndClampsAtEnds() {
        var selection = KeyboardSelection()
        let keys = ["attention:a", "done:b", "done:c"]
        selection.reconcile(keys: keys)
        XCTAssertEqual(selection.key, "attention:a")
        selection.move(-1, keys: keys)
        XCTAssertEqual(selection.key, "attention:a")
        selection.move(1, keys: keys)
        XCTAssertEqual(selection.key, "done:b")
        selection.move(1, keys: keys)
        selection.move(1, keys: keys)
        XCTAssertEqual(selection.key, "done:c")
    }

    func testSelectionSurvivesReorderingAndPicksNeighborWhenDeleted() {
        var selection = KeyboardSelection()
        selection.reconcile(keys: ["a", "b", "c"])
        selection.move(1, keys: ["a", "b", "c"])
        selection.reconcile(keys: ["b", "a", "c"])
        XCTAssertEqual(selection.key, "b")
        selection.reconcile(keys: ["a", "c"])
        XCTAssertEqual(selection.key, "a")
        selection.reconcile(keys: [])
        XCTAssertNil(selection.key)
        selection.move(1, keys: [])
        XCTAssertNil(selection.key)
        selection.reconcile(keys: ["new"])
        XCTAssertEqual(selection.key, "new")
    }

    func testKeysModifiersAndRepeats() {
        func action(_ key: UInt16, modifiers: Bool = false, repeat repeated: Bool = false) -> PanelKeyAction? {
            PanelKeyAction.from(keyCode: key, hasCommandModifiers: modifiers, isRepeat: repeated)
        }
        XCTAssertEqual(action(53), .snooze)
        XCTAssertEqual(action(51), .clearAll)
        XCTAssertEqual(action(126), .previous)
        XCTAssertEqual(action(125), .next)
        XCTAssertEqual(action(36), .open)
        XCTAssertEqual(action(76), .open)
        XCTAssertNil(action(117)) // Forward Delete isn't Backspace.
        XCTAssertNil(action(51, modifiers: true))
        XCTAssertNil(action(53, repeat: true))
        XCTAssertNil(action(51, repeat: true))
        XCTAssertNil(action(36, repeat: true))
        XCTAssertEqual(action(125, repeat: true), .next)
    }
}
