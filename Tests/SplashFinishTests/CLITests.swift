import Foundation
import XCTest
@testable import SplashFinish

final class CLITests: XCTestCase {
    @MainActor func testDisabledWorkerNotifyReturnsBeforeParsingOrDelivery() {
        let previous = ProcessInfo.processInfo.environment["SPLASH_FINISH_DISABLED"]
        defer {
            if let previous { setenv("SPLASH_FINISH_DISABLED", previous, 1) }
            else { unsetenv("SPLASH_FINISH_DISABLED") }
        }
        setenv("SPLASH_FINISH_DISABLED", "1", 1)
        XCTAssertEqual(CLI.run(["notify", "--invalid"]), 0)
        XCTAssertEqual(CLI.run(["hook", "pi"]), 0)
        setenv("SPLASH_FINISH_DISABLED", "0", 1)
        XCTAssertEqual(CLI.run(["notify", "--invalid"]), 1, "Only the exact opt-out value 1 suppresses notifications")
    }
}
