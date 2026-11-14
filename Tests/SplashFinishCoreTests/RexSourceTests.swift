import XCTest
@testable import SplashFinishCore

final class RexSourceTests: XCTestCase {
    let source = RexSource(session: "session:01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                           block: "block:01a1d9ff-f9a9-7831-b1e9-1187fcbf6756")
    let window = "window:01a1d9ff-f9b9-7128-9e91-792dd93deaa7"
    func testCaptureUsesInheritedCoordinatesAndRejectsPartialRemoteAndInvalidIDs() {
        let env = ["REX_SESSION": source.session, "REX_BLOCK": source.block]
        XCTAssertEqual(RexSource.capture(environment: env), source)
        for extra in [["REX_BLOCK": "shell"], ["REX_SESSION": "--help"], ["SSH_CONNECTION": "remote"],
                      ["REX_SERVER": "https://remote"], ["REX_BLOCK": source.block + "\n"]] {
            XCTAssertNil(RexSource.capture(environment: env.merging(extra) { _, new in new }))
        }
        XCTAssertNil(RexSource.capture(environment: ["REX_SESSION": source.session]))
        XCTAssertNil(RexSource.capture(environment: [:]))
    }
    func testSerializationAndLegacyCompatibility() throws {
        let event = AgentEvent(task: "rex", agent: "pi", status: .done, title: "Done", source: EventSource(rex: source))
        XCTAssertEqual(try DeepLink.parse(DeepLink.eventURL(event)).source?.rex, source)
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event)), event)
        XCTAssertNil(try JSONDecoder().decode(EventSource.self, from: Data("{\"orca\":null,\"pid\":42}".utf8)).rex)
        XCTAssertThrowsError(try DeepLink.parse(URL(string: "splash-finish://event?agent=pi&task=t&status=done&rex-session=" + source.session)!))
        var invalid = event; invalid.source?.rex?.block = "block:short"
        XCTAssertThrowsError(try invalid.validated())
    }
    func testHooksKeepTheCapturedRexSourceForBothAgents() throws {
        let input = Data("{\"session_id\":\"agent-session\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Done\"}".utf8)
        for agent in ["claude", "codex"] {
            let event = try XCTUnwrap(HookEvent.parse(agent: agent, input: input, source: EventSource(rex: source)))
            XCTAssertEqual(try DeepLink.parse(DeepLink.eventURL(event)).source?.rex, source)
        }
    }

    func testArgumentsAndExactReplyValidation() throws {
        XCTAssertEqual(source.focusArguments, ["focus", "-s", source.session, source.block])
        XCTAssertEqual(try source.selectArguments(client: "client:01a1d68b-9a94-719e-b67d-423e3084ed10", window: window),
                       ["-C", "client:01a1d68b-9a94-719e-b67d-423e3084ed10", "do", "session.select", "session_id=" + source.session, "window_id=" + window, "--json"])
        XCTAssertThrowsError(try source.selectArguments(client: "--help", window: window))
        let reply = Data("{\"session_id\":\"\(source.session)\",\"block\":{\"block_id\":\"\(source.block)\",\"window_id\":\"\(window)\",\"placement\":\"placed\"}}".utf8)
        XCTAssertEqual(try source.window(from: reply), window)
        XCTAssertThrowsError(try source.window(from: Data("{}".utf8)))
        let focus = "{\"session_id\":\"\(source.session)\",\"active_window_id\":\"\(window)\",\"windows\":[{\"window_id\":\"\(window)\",\"focused_block_id\":\"\(source.block)\"}]}"
        XCTAssertTrue(source.focused(in: Data(focus.utf8), window: window))
        XCTAssertFalse(source.focused(in: Data(focus.replacingOccurrences(of: source.block, with: "other").utf8), window: window))
    }
}
