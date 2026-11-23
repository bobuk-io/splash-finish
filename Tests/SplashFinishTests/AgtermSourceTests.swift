import XCTest
@testable import SplashFinish

@MainActor final class AgtermSourceTests: XCTestCase {
    private let sessionID = "123e4567-e89b-12d3-a456-426614174000"

    func testCaptureLinksToLocalAgtermSession() {
        let source = SourceNavigator.capture(environment: ["AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": sessionID])
        XCTAssertEqual(source?.url, "agterm://session/\(sessionID)")
    }

    func testCaptureDoesNotGuessAgtermDestination() {
        for environment in [
            ["AGTERM_ENABLED": "0", "AGTERM_SESSION_ID": sessionID],
            ["AGTERM_ENABLED": "1"],
            ["AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": String(sessionID.prefix(8))],
            ["AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": sessionID, "SSH_TTY": "/dev/ttys001"]
        ] {
            XCTAssertNil(SourceNavigator.capture(environment: environment)?.url)
        }
    }
}
