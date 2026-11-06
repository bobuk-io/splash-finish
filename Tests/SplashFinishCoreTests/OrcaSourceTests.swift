import XCTest
@testable import SplashFinishCore

final class OrcaSourceTests: XCTestCase {
    private let workspace = "repo-123::/Users/test/My Project"
    private func terminal(_ handle: String = "term_new", workspace: String? = nil, tab: String = "tab-1", leaf: String = "leaf-1",
                          host: String = "local", connected: Bool = true, orphaned: Bool = false) -> OrcaTerminal {
        OrcaTerminal(handle: handle, worktreeId: workspace ?? self.workspace, tabId: tab, leafId: leaf,
                     executionHostId: host, orphaned: orphaned, connected: connected)
    }

    func testStructuredChatCaptureAndTargets() throws {
        // Orca's built-in chat injects only the session identity: no terminal, pane or worktree.
        let chat = OrcaSource.capture(environment: ["ORCA_AGENT_SESSION_ID": "claude_450ad2e5_96a8_475f_bfc8_10fb9d07e794"])
        XCTAssertEqual(chat, OrcaSource(session: "claude_450ad2e5_96a8_475f_bfc8_10fb9d07e794"))
        XCTAssertEqual(chat?.targets, [.chat])
        // A terminal keeps priority; the chat stays as a second attempt.
        let both = OrcaSource(terminal: "term_a", worktree: workspace, pane: "tab-1:leaf-1", session: "claude_abc12345")
        XCTAssertEqual(try both.validated().targets, [.terminal, .chat])
        XCTAssertEqual(OrcaSource(terminal: "term_a").targets, [.terminal])
        XCTAssertEqual(OrcaSource(worktree: workspace, pane: "tab-1:leaf-1").targets, [.terminal])
    }

    func testRejectsMalformedChatIdentity() {
        for session in ["", "short", "--help", "claude_450ad2e5 96a8", "claude/450", String(repeating: "a", count: 129),
                        "splash-finish://clear", "claude_450ad2e5_96a8\nv2"] {
            XCTAssertThrowsError(try OrcaSource(session: session).validated(), session)
        }
        XCTAssertNoThrow(try OrcaSource(session: "claude_450ad2e5_96a8_475f_bfc8_10fb9d07e794").validated())
        XCTAssertFalse(OrcaSource.isSessionID("has space"))
        XCTAssertFalse(OrcaSource.isSessionID("short7"))
    }

    func testChatSessionSurvivesDeepLinkAndPersistence() throws {
        let source = EventSource(bundleID: OrcaSource.bundleID, orca: OrcaSource(session: "claude_450ad2e5_96a8_475f_bfc8_10fb9d07e794"))
        let event = AgentEvent(task: "session", agent: "Claude Code", status: .done, title: "Done", source: source)
        let url = try DeepLink.eventURL(event)
        XCTAssertTrue(url.absoluteString.contains("orca-session=claude_450ad2e5_96a8_475f_bfc8_10fb9d07e794"))
        XCTAssertEqual(try DeepLink.parse(url).source, source)
        var inbox = Inbox()
        try inbox.receive(event)
        XCTAssertEqual(try JSONDecoder().decode(Inbox.self, from: JSONEncoder().encode(inbox)).items.first?.source, source)
        let legacy = try JSONDecoder().decode(EventSource.self, from: Data(#"{"bundleID":"com.stablyai.orca","orca":{"terminal":"term_a"}}"#.utf8))
        XCTAssertNil(legacy.orca?.session)
    }

    func testRevealReplyMustConfirmTheClickedSession() {
        let workspace = "repo-1::/Users/me/orca/files-speed"
        func replies(_ reveal: String, _ activate: String) -> Data { Data((reveal + "\n" + activate + "\n").utf8) }
        let revealed = #"{"ok":true,"result":{"ok":true,"sessionId":"claude_abc12345","workspaceId":"__W__","agent":"claude","readable":true}}"#
            .replacingOccurrences(of: "__W__", with: workspace)
        let activated = #"{"ok":true,"result":{"repoId":"repo-1","worktreeId":"__W__","activated":true}}"#
            .replacingOccurrences(of: "__W__", with: workspace)
        XCTAssertTrue(OrcaReply.revealed(replies(revealed, activated), session: "claude_abc12345"))
        // A different chat, an unconfirmed activation or a different workspace must not consume the card.
        XCTAssertFalse(OrcaReply.revealed(replies(revealed, activated), session: "claude_other123"))
        XCTAssertFalse(OrcaReply.revealed(replies(revealed, #"{"ok":true,"result":{"activated":false}}"#), session: "claude_abc12345"))
        XCTAssertFalse(OrcaReply.revealed(replies(revealed, #"{"ok":true,"result":{"activated":true,"worktreeId":"other::/tmp"}}"#), session: "claude_abc12345"))
        XCTAssertTrue(OrcaReply.revealed(replies(revealed, activated) + Data("\n".utf8), session: "claude_abc12345"),
                      "the writer terminates every JSON line")
        for failure in [#"{"ok":true,"result":{"ok":false,"refusal":{"code":"agent_session_operation_unknown"}}}"# +
                        "\n" + activated, #"{"ok":false,"error":{"code":"terminal_exited"}}"# + "\n" + activated,
                        revealed, "not json"] {
            XCTAssertFalse(OrcaReply.revealed(Data(failure.utf8), session: "claude_abc12345"), failure)
        }
    }

    func testCaptureIsIndependentOfAgentAndWorkingDirectory() {
        let source = OrcaSource.capture(environment: [
            "ORCA_TERMINAL_HANDLE": "term_original", "ORCA_WORKTREE_ID": workspace,
            "ORCA_PANE_KEY": "tab-1:leaf-1", "WEZTERM_PANE": "999"
        ])
        XCTAssertEqual(source, OrcaSource(terminal: "term_original", worktree: workspace, pane: "tab-1:leaf-1"))
        XCTAssertNil(OrcaSource.capture(environment: ["TERM_PROGRAM": "WezTerm"]))
        XCTAssertNil(OrcaSource.capture(environment: ["ORCA_PI_STATUS_OWNED": "123"]))
        XCTAssertNil(OrcaSource.capture(environment: ["ORCA_AGENT_SESSION_ID": "nope"]))
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
