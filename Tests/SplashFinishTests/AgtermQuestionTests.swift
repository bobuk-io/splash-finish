import XCTest
import SplashFinishCore
@testable import SplashFinish

final class AgtermQuestionTests: XCTestCase {
    func testQuestionWirePreservesAgtermCoordinates() throws {
        let source = AgtermSource(session: "01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                                  window: "01a1d9ff-f9a9-7831-b1e9-1187fcbf6756",
                                  pane: "01a1d9ff-f9a9-7831-b1e9-1187fcbf6757", socket: "/tmp/agterm.sock")
        let coordinates = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
        let wire = try JSONSerialization.data(withJSONObject: [
            "title": "Private question", "project": "demo", "session": "pi-session", "agterm": coordinates,
            "questions": [["id": "q", "label": "Private label", "prompt": "Private prompt", "type": "single",
                           "options": [["value": "a", "label": "Private answer"]]]]
        ])
        let question = try JSONDecoder().decode(PiQuestion.self, from: wire)
        XCTAssertEqual(try question.agterm?.validated(), source)
        XCTAssertEqual(question.session, "pi-session")
        let persisted = EventSource(bundleID: AgtermSource.bundleID, agterm: try XCTUnwrap(question.agterm))
        let data = try JSONEncoder().encode(persisted)
        XCTAssertEqual(try JSONDecoder().decode(EventSource.self, from: data).agterm, source)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("Private"))
        XCTAssertFalse(text.contains("pi-session"))
    }

    func testQuestionWireAllowsAbsentAgtermAndOptionalPane() throws {
        let base: [String: Any] = ["questions": [], "project": "demo"]
        let legacy = try JSONDecoder().decode(PiQuestion.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertNil(legacy.agterm)
        var wire = base
        wire["agterm"] = ["session": "01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                          "window": "01a1d9ff-f9a9-7831-b1e9-1187fcbf6756", "socket": "/tmp/agterm.sock"]
        let question = try JSONDecoder().decode(PiQuestion.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertNotNil(try question.agterm?.validated())
        XCTAssertNil(question.agterm?.pane)
    }
}
