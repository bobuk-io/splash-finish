import XCTest
@testable import SplashFinishCore

final class RelativeTimeTests: XCTestCase {
    func testAgesAreCalmAndNeverCountSeconds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        func age(_ seconds: TimeInterval) -> String { RelativeTime.describe(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(-30), "just now", "Clock skew must not produce negative ages")
        XCTAssertEqual(age(59), "just now")
        XCTAssertEqual(age(60), "1 min ago")
        XCTAssertEqual(age(5 * 60 + 11), "5 min ago")
        XCTAssertEqual(age(3600), "1 hour ago")
        XCTAssertEqual(age(3 * 3600 + 59 * 60), "3 hours ago")
        XCTAssertEqual(age(23 * 3600), "23 hours ago")
        XCTAssertEqual(age(24 * 3600), "yesterday")
        XCTAssertEqual(age(3 * 24 * 3600), "3 days ago")
        XCTAssertEqual(age(10 * 24 * 3600), "Nov 4")
    }
}
