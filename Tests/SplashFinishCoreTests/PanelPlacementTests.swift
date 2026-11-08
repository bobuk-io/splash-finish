import XCTest
@testable import SplashFinishCore

final class PanelPlacementTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let external = CGRect(x: 1440, y: 200, width: 2560, height: 1415)
    let size = CGSize(width: 470, height: 600)

    func testDefaultCentersSlightlyAboveTheMiddleOfTheActiveScreen() {
        let placed = PanelPlacement.place(size: size, remembered: nil, screens: [main, external], active: external)
        XCTAssertEqual(placed.frame.midX, external.midX)
        XCTAssertEqual(placed.frame.midY, external.midY - 55)
        XCTAssertEqual(placed.area, external)
    }

    func testDefaultKeepsMarginOnAShortScreen() {
        let short = CGRect(x: 0, y: 0, width: 1200, height: 500)
        let placed = PanelPlacement.place(size: size, remembered: nil, screens: [short], active: short)
        XCTAssertEqual(placed.frame.minY, 16, "A panel taller than the screen still starts at the bottom margin")
    }

    func testRememberedCornerWinsOverTheActiveScreen() {
        let corner = CGPoint(x: 3000, y: 1500)
        let placed = PanelPlacement.place(size: size, remembered: corner, screens: [main, external], active: main)
        XCTAssertEqual(placed.frame.origin, CGPoint(x: 3000, y: 900))
        XCTAssertEqual(placed.area, external)
    }

    func testRememberedCornerIsClampedOntoItsScreen() {
        let placed = PanelPlacement.place(size: size, remembered: CGPoint(x: 1300, y: 300), screens: [main], active: main)
        XCTAssertEqual(placed.frame.maxX, main.maxX)
        XCTAssertEqual(placed.frame.minY, main.minY)
    }

    func testRememberedCornerOnADisconnectedScreenFallsBackToDefault() {
        let placed = PanelPlacement.place(size: size, remembered: CGPoint(x: 3000, y: 1500), screens: [main], active: main)
        XCTAssertEqual(placed.frame.midX, main.midX)
        XCTAssertEqual(placed.area, main)
    }

    func testCornerExactlyOnTheTopEdgeStillCounts() {
        let placed = PanelPlacement.place(size: size, remembered: CGPoint(x: 100, y: main.maxY), screens: [main], active: external)
        XCTAssertEqual(placed.frame.maxY, main.maxY)
        XCTAssertEqual(placed.area, main)
    }
}
