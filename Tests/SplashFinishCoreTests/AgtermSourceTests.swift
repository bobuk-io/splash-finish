import XCTest
@testable import SplashFinishCore

final class AgtermSourceTests: XCTestCase {
    let source = AgtermSource(session: "01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                              window: "01a1d9ff-f9b9-7128-9e91-792dd93deaa7",
                              pane: "01a1d9ff-f9a9-7831-b1e9-1187fcbf6756", socket: "/tmp/agterm test.sock")

    var environment: [String: String] {
        ["AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": source.session, "AGTERM_WINDOW_ID": source.window,
         "AGTERM_PANE_ID": source.pane!, "AGTERM_SOCKET": source.socket]
    }

    func testCaptureUsesOnlyCompleteLocalInheritedCoordinates() throws {
        XCTAssertEqual(AgtermSource.bundleID, "com.umputun.agterm")
        XCTAssertEqual(AgtermSource.capture(environment: environment), source)
        for key in ["AGTERM_ENABLED", "AGTERM_SESSION_ID", "AGTERM_WINDOW_ID", "AGTERM_SOCKET"] {
            var env = environment; env.removeValue(forKey: key)
            XCTAssertNil(AgtermSource.capture(environment: env), key)
        }
        var withoutPane = environment; withoutPane.removeValue(forKey: "AGTERM_PANE_ID")
        var expected = source; expected.pane = nil
        XCTAssertEqual(AgtermSource.capture(environment: withoutPane), expected)
        for extra in [["AGTERM_ENABLED": "0"], ["AGTERM_ENABLED": "true"],
                      ["SSH_CONNECTION": ""], ["SSH_TTY": ""], ["SSH_CLIENT": ""],
                      ["AGTERM_SESSION_ID": "short"], ["AGTERM_WINDOW_ID": "--help"],
                      ["AGTERM_PANE_ID": "primary"], ["AGTERM_PANE_ID": ""],
                      ["AGTERM_SOCKET": "relative.sock"], ["AGTERM_SOCKET": ""]] {
            XCTAssertNil(AgtermSource.capture(environment: environment.merging(extra) { _, new in new }))
        }
        XCTAssertNil(AgtermSource.capture(environment: [:]))
    }

    func testValidationRejectsUnsafeIDsAndSocketPaths() throws {
        XCTAssertEqual(try source.validated(), source)
        for id in ["", "primary", String(source.session.suffix(8)), "{" + source.session + "}", source.session + "\n"] {
            var invalid = source; invalid.session = id
            XCTAssertThrowsError(try invalid.validated())
            invalid = source; invalid.window = id
            XCTAssertThrowsError(try invalid.validated())
            invalid = source; invalid.pane = id
            XCTAssertThrowsError(try invalid.validated())
        }
        for socket in ["", "tmp/test.sock", "/tmp/../test.sock", "/tmp/./test.sock", "/tmp/test\0.sock",
                       "/tmp/test\n.sock", "/tmp/test\t.sock", "/" + String(repeating: "a", count: 103),
                       "/" + String(repeating: "é", count: 52)] {
            var invalid = source; invalid.socket = socket
            XCTAssertThrowsError(try invalid.validated(), socket.debugDescription)
        }
        var boundary = source; boundary.socket = "/" + String(repeating: "a", count: 102)
        XCTAssertEqual(try boundary.validated(), boundary)
        boundary.socket = "/" + String(repeating: "é", count: 51)
        XCTAssertEqual(try boundary.validated(), boundary)
    }

    func testEventDeepLinkAndCodablePreserveExactCoordinates() throws {
        for pane in [source.pane, nil] {
            var coordinate = source; coordinate.pane = pane
            let event = AgentEvent(task: "agterm", agent: "pi", status: .done, title: "Done",
                                   source: EventSource(pid: 42, bundleID: AgtermSource.bundleID, agterm: coordinate))
            let parsed = try DeepLink.parse(DeepLink.eventURL(event)).validated()
            XCTAssertEqual(parsed.source, event.source)
            let restored = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(parsed)).validated()
            XCTAssertEqual(restored.source?.agterm, coordinate)
            XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event)), event)
        }
        XCTAssertNil(try JSONDecoder().decode(EventSource.self, from: Data("{\"pid\":42}".utf8)).agterm)
        let legacy = AgentEvent(task: "legacy", agent: "pi", status: .done, title: "Done", source: EventSource(pid: 42))
        XCTAssertNil(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(legacy)).source?.agterm)
        XCTAssertNil(try DeepLink.parse(DeepLink.eventURL(legacy)).source?.agterm)
        XCTAssertFalse(AgentEvent.isSafeSourceURL("agterm://session/" + source.session))
    }

    func testHooksPreserveCapturedCoordinatesForBothAgents() throws {
        let input = Data("{\"session_id\":\"agent-session\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Done\"}".utf8)
        let captured = try XCTUnwrap(AgtermSource.capture(environment: environment))
        for agent in ["claude", "codex"] {
            let event = try XCTUnwrap(HookEvent.parse(agent: agent, input: input, source: EventSource(agterm: captured)))
            XCTAssertEqual(try DeepLink.parse(DeepLink.eventURL(event)).source?.agterm, captured)
        }
    }

    func testPartialOrUnsafeDeepLinkCoordinatesCannotFallBackToOtherSources() throws {
        let event = AgentEvent(task: "agterm", agent: "pi", status: .done, title: "Done",
                               source: EventSource(pid: 42, bundleID: AgtermSource.bundleID, agterm: source))
        let url = try DeepLink.eventURL(event)
        let keys = ["agterm-session", "agterm-window", "agterm-pane", "agterm-socket"]
        for key in keys {
            var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.queryItems = components.queryItems?.filter { !keys.contains($0.name) || $0.name == key }
            XCTAssertThrowsError(try DeepLink.parse(XCTUnwrap(components.url)), key)
        }
        for key in ["agterm-session", "agterm-window", "agterm-socket"] {
            var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.queryItems?.removeAll { $0.name == key }
            XCTAssertThrowsError(try DeepLink.parse(XCTUnwrap(components.url)), key)
        }
        for (key, value) in [("agterm-pane", "primary"), ("agterm-session", "short"),
                             ("agterm-window", ""), ("agterm-socket", "/tmp/../other.sock")] {
            var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.queryItems?.removeAll { $0.name == key }
            components.queryItems?.append(URLQueryItem(name: key, value: value))
            XCTAssertThrowsError(try DeepLink.parse(XCTUnwrap(components.url)))
        }
        var invalid = event; invalid.source?.agterm?.pane = "primary"
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertThrowsError(try DeepLink.eventURL(invalid))
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(invalid))
        XCTAssertThrowsError(try decoded.validated())
    }
}
