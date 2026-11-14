import XCTest
import Darwin
import SplashFinishCore
@testable import SplashFinish

@MainActor final class RexNavigatorTests: XCTestCase {
    func testSharedCLICaptureCarriesOriginalRexPane() {
        let env = ["REX_SESSION": "session:01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                   "REX_BLOCK": "block:01a1d9ff-f9a9-7831-b1e9-1187fcbf6756"]
        let captured = SourceNavigator.capture(environment: env)
        XCTAssertEqual(captured?.bundleID, RexSource.bundleID)
        XCTAssertEqual(captured?.rex, RexSource.capture(environment: env))
    }

    func testLocalClientSelectionRejectsRemoteCLIAndAmbiguousClients() throws {
        let id = "client:01a1d68b-9a94-719e-b67d-423e3084ed10"
        let app: [String: Any] = ["client_id": id, "info": ["kind": "app", "platform": "macos"],
            "principal": ["transport": "unix", "uid": getuid(), "pid": 123], "connection_state": "connected"]
        func reply(_ clients: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["clients": clients]) }
        XCTAssertEqual(RexNavigator.localClient(try reply([app]), pids: [123]), id)
        XCTAssertNil(RexNavigator.localClient(try reply([app, app]), pids: [123]))
        XCTAssertNil(RexNavigator.localClient(try reply([app]), pids: [456]))
        var remote = app; remote["principal"] = ["transport": "tcp", "pid": 123, "uid": getuid()]
        XCTAssertNil(RexNavigator.localClient(try reply([remote]), pids: [123]))
        var cli = app; cli["info"] = ["kind": "cli", "platform": "macos"]
        XCTAssertNil(RexNavigator.localClient(try reply([cli]), pids: [123]))
        XCTAssertNil(RexNavigator.localClient(Data("{}".utf8), pids: [123]))
    }

    func testNavigationAndEachFailureKeepExactSuccessSeparate() {
        let source = RexSource(session: "session:01a1d6be-ed97-7d65-b0bf-dbccd7256f1a",
                               block: "block:01a1d9ff-f9a9-7831-b1e9-1187fcbf6756")
        let window = "window:01a1d9ff-f9b9-7128-9e91-792dd93deaa7"
        let client = "client:01a1d68b-9a94-719e-b67d-423e3084ed10"
        let inspect = Data("{\"session_id\":\"\(source.session)\",\"block\":{\"block_id\":\"\(source.block)\",\"window_id\":\"\(window)\",\"placement\":\"placed\"}}".utf8)
        let focused = Data("{\"session_id\":\"\(source.session)\",\"active_window_id\":\"\(window)\",\"windows\":[{\"window_id\":\"\(window)\",\"focused_block_id\":\"\(source.block)\"}]}".utf8)
        let replies = [inspect, Data("{}".utf8), Data(), Data("null".utf8), focused]
        for failAt in 0...7 {
            var commands = [[String]](), result: Bool?, activated = false
            RexNavigator.navigate(source, executable: URL(fileURLWithPath: "/no/rex"), client: { _ in client },
                activate: { activated = true; return failAt != 7 }, run: { _, args, done in
                    let index = commands.count; commands.append(args)
                    done(index == failAt ? nil : (index == 4 && failAt == 6 ? Data("{}".utf8) : replies[index]), index == failAt ? "Remote Control refused" : nil)
                }, completion: { ok, error in result = ok; XCTAssertEqual(error == nil, ok) })
            XCTAssertEqual(result, failAt == 5)
            XCTAssertEqual(activated, failAt == 5 || failAt == 7)
            XCTAssertEqual(commands.first, source.inspectArguments)
            XCTAssertEqual(commands.count, min(failAt + 1, 5))
            if commands.count > 3 { XCTAssertEqual(commands[3], try? source.selectArguments(client: client, window: window)) }
        }
        var result: Bool?
        RexNavigator.navigate(source, executable: URL(fileURLWithPath: "/no/rex"), client: { _ in nil }, activate: { XCTFail(); return true },
            run: { _, args, done in done(args == source.inspectArguments ? inspect : Data(), nil) },
            completion: { ok, _ in result = ok })
        XCTAssertEqual(result, false, "Ambiguous clients must not select a session")
    }
}
