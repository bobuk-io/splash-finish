import XCTest
@testable import SplashFinishCore

final class OrcaSourceTests: XCTestCase {
    private let workspace = "repo-123::/Users/test/My Project"
    private func terminal(_ handle: String = "term_new", workspace: String? = nil, tab: String = "tab-1", leaf: String = "leaf-1",
                          host: String = "local", connected: Bool = true, orphaned: Bool = false) -> OrcaTerminal {
        OrcaTerminal(handle: handle, worktreeId: workspace ?? self.workspace, tabId: tab, leafId: leaf,
                     executionHostId: host, orphaned: orphaned, connected: connected)
    }

    func testCaptureIsIndependentOfAgentAndWorkingDirectory() {
        let source = OrcaSource.capture(environment: [
            "ORCA_TERMINAL_HANDLE": "term_original", "ORCA_WORKTREE_ID": workspace,
            "ORCA_PANE_KEY": "tab-1:leaf-1", "WEZTERM_PANE": "999"
        ])
        XCTAssertEqual(source, OrcaSource(terminal: "term_original", worktree: workspace, pane: "tab-1:leaf-1"))
        XCTAssertNil(OrcaSource.capture(environment: ["TERM_PROGRAM": "WezTerm"]))
        XCTAssertNil(OrcaSource.capture(environment: ["ORCA_PI_STATUS_OWNED": "123"]))
        let folder = OrcaSource.capture(environment: [
            "ORCA_TERMINAL_HANDLE": "term_folder", "ORCA_WORKSPACE_ID": "folder:abc"
        ])
        XCTAssertEqual(folder?.worktree, "folder:abc")
    }

    func testExactPaneWinsOverActiveOrSiblingTerminalsAfterRestart() {
        let source = OrcaSource(terminal: "term_old", worktree: workspace, pane: "tab-1:leaf-1")
        XCTAssertEqual(source.resolve(in: [terminal("term_sibling", leaf: "leaf-2"), terminal()]), "term_new")
        XCTAssertNil(source.resolve(in: [terminal("term_sibling", leaf: "leaf-2")]))
        XCTAssertNil(source.resolve(in: [terminal(workspace: "other-project")]))
        XCTAssertNil(source.resolve(in: [terminal(), terminal("term_duplicate")]))
        XCTAssertNil(source.resolve(in: [terminal(host: "remote")]))
        XCTAssertNil(source.resolve(in: [terminal(connected: false)]))
        XCTAssertNil(source.resolve(in: [terminal(orphaned: true)]))
        XCTAssertEqual(OrcaSource(terminal: "term_new").resolve(in: [terminal()]), "term_new")
        XCTAssertNil(OrcaSource(terminal: "term_old").resolve(in: [terminal()]))
    }

    func testEventRoundTripPersistenceAndLegacyCompatibility() throws {
        let source = EventSource(bundleID: OrcaSource.bundleID,
                                 orca: OrcaSource(terminal: "term_original", worktree: workspace, pane: "tab-1:leaf-1"))
        let event = AgentEvent(task: "session", agent: "Claude Code", status: .done, title: "Done", source: source)
        XCTAssertEqual(try DeepLink.parse(DeepLink.eventURL(event)).source, source)
        var inbox = Inbox()
        try inbox.receive(event)
        let restored = try JSONDecoder().decode(Inbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(restored.items.first?.source, source)
        let old = try JSONDecoder().decode(EventSource.self, from: Data(#"{"bundleID":"com.apple.Terminal","pid":123}"#.utf8))
        XCTAssertNil(old.orca)
        XCTAssertEqual(old.pid, 123)
    }

    func testRejectsMalformedCoordinatesAndDoesNotAllowCLIFlagInjection() throws {
        for source in [OrcaSource(), OrcaSource(terminal: "--help"), OrcaSource(terminal: "term_a; touch /tmp/evil"),
                       OrcaSource(terminal: String(repeating: "a", count: 129)),
                       OrcaSource(terminal: "term_a", worktree: "bad\nworkspace"),
                       OrcaSource(terminal: "term_a", pane: "bad:pane:extra")] {
            XCTAssertThrowsError(try source.validated())
        }
        let url = URL(string: "splash-finish://event?agent=pi&task=t&status=done&orca-terminal=--help")!
        XCTAssertThrowsError(try DeepLink.parse(url))
    }

    func testReplyParsingRejectsErrorsTruncationAndNoNavigation() throws {
        let json = #"{"ok":true,"result":{"terminals":[{"handle":"term_a","worktreeId":"folder:abc","tabId":"tab","leafId":"leaf","executionHostId":"local","connected":true,"orphaned":false}],"truncated":false}}"#
        XCTAssertEqual(try OrcaReply.terminals(from: Data(json.utf8)).first?.handle, "term_a")
        XCTAssertThrowsError(try OrcaReply.terminals(from: Data(#"{"ok":false}"#.utf8)))
        XCTAssertThrowsError(try OrcaReply.terminals(from: Data(#"{"ok":true,"result":{"terminals":[],"truncated":true}}"#.utf8)))
        XCTAssertTrue(OrcaReply.switched(Data(#"{"ok":true,"result":{"focus":{"navigated":true}}}"#.utf8)))
        XCTAssertFalse(OrcaReply.switched(Data(#"{"ok":true,"result":{"focus":{"navigated":false}}}"#.utf8)))
        XCTAssertFalse(OrcaReply.switched(Data(#"{"ok":false}"#.utf8)))
    }
}
