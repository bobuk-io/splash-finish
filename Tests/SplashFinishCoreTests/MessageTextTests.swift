import XCTest
@testable import SplashFinishCore

final class MessageTextTests: XCTestCase {
    func testInlineMarkdownStylesAndPlainText() {
        let text = MessageText.render("**Strong** *italic* ~~old~~ `swift test` & plain")
        XCTAssertEqual(String(text.characters), "Strong italic old swift test & plain")
        for (word, intent) in [("Strong", InlinePresentationIntent.stronglyEmphasized),
                               ("italic", .emphasized), ("old", .strikethrough), ("swift test", .code)] {
            let range = text.range(of: word)!
            XCTAssertTrue(text[range].runs.contains { $0.inlinePresentationIntent?.contains(intent) == true })
        }
    }

    func testLongLinkIsParsedBeforeDisplayTruncation() throws {
        let url = "https://github.com/bobuk-io/splash-finish/releases/tag/v0.3.4?" + String(repeating: "q", count: 200)
        let source = "Готово: [0.3.4](\(url)) опубликован."
        let event = try AgentEvent(task: "t", agent: "pi", status: .done, title: source).validated()
        XCTAssertEqual(event.title, source)
        let text = MessageText.render(event.title, limit: 160)
        XCTAssertEqual(String(text.characters), "Готово: 0.3.4 опубликован.")
        XCTAssertEqual(text.runs.compactMap(\.link).map(\.absoluteString), [url])
    }

    func testVisibleTruncationKeepsLinkDestinationAndStyles() {
        let source = "**[" + String(repeating: "a", count: 200) + "](https://example.com)**"
        let text = MessageText.render(source, limit: 160)
        XCTAssertEqual(String(text.characters), String(repeating: "a", count: 160) + "…")
        XCTAssertEqual(text.runs.first?.link, URL(string: "https://example.com"))
        XCTAssertTrue(text.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        XCTAssertNil(text.runs.last?.link, "The ellipsis must not be a web link")
    }

    func testUnsafeAndRelativeLinksBecomeInertText() {
        for target in ["file:///tmp/run.sh", "javascript:alert%281%29", "data:text/html,test", "splash-finish://clear",
                       "iterm2://command/run", "./relative", "https://user:secret@example.com", "https://"] {
            let text = MessageText.render("[Review](\(target))")
            XCTAssertTrue(text.runs.compactMap(\.link).isEmpty, target)
            XCTAssertTrue(String(text.characters).contains("Review"))
        }
        XCTAssertFalse(MessageText.isSafeLink(URL(string: "https://example.com/" + String(repeating: "a", count: 2048))!))
    }

    func testCodeEscapesAndMalformedMarkdownAreNotLinks() {
        XCTAssertTrue(MessageText.render("`[file](https://example.com)`").runs.compactMap(\.link).isEmpty)
        XCTAssertEqual(MessageText.plain(#"\*literal\* and **unfinished"#), "*literal* and **unfinished")
        XCTAssertFalse(MessageText.plain("![alt](https://example.com/image.png)").isEmpty)
        XCTAssertEqual(MessageText.plain(""), "")
    }

    func testRawPayloadIsBoundedByUTF8WithoutSplittingGraphemes() throws {
        let source = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
        let cleaned = MessageText.clean(source)
        XCTAssertLessThanOrEqual(cleaned.utf8.count, MessageText.maximumBytes)
        XCTAssertTrue(source.hasPrefix(cleaned))
        XCTAssertFalse(cleaned.contains("�"))
        XCTAssertEqual(MessageText.clean(" \n **Hello**\u{1B}\t world \r\n "), "**Hello** world")
    }

    func testUnicodeMarkdownDeepLinkRoundTripWithinWireBudget() throws {
        let value = "[Релиз](https://example.com/path) " + String(repeating: "ёж", count: 2000)
        let event = try AgentEvent(task: "t", agent: "pi", status: .done, title: value, detail: value,
            source: EventSource(orca: OrcaSource(terminal: "term_a", worktree: String(repeating: "я", count: 1000)))).validated()
        let url = try DeepLink.eventURL(event)
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, 65536)
        let decoded = try DeepLink.parse(url)
        XCTAssertEqual(decoded.title, event.title)
        XCTAssertEqual(decoded.detail, event.detail)
        XCTAssertEqual(MessageText.render(decoded.title).runs.compactMap(\.link).first, URL(string: "https://example.com/path"))
    }

    func testFullInboxWithEscapedMarkdownCanBeSavedAndLoaded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = StateFile(url: directory.appendingPathComponent("state.json"))
        let payload = String(repeating: "\"", count: MessageText.maximumBytes)
        var inbox = Inbox()
        for index in 0..<200 {
            try inbox.receive(AgentEvent(task: String(index), agent: "pi", status: .done, title: payload, detail: payload))
        }
        try file.save(inbox)
        XCTAssertGreaterThan(try Data(contentsOf: file.url).count, 2_000_000)
        XCTAssertEqual(try file.load(), inbox)
    }

    func testHookPreservesCompleteMarkdownLink() throws {
        let source = "Готово: [release](https://example.com/" + String(repeating: "a", count: 200) + ")"
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "s", "hook_event_name": "Stop", "last_assistant_message": source])
        for agent in ["claude", "codex"] {
            let event = try XCTUnwrap(HookEvent.parse(agent: agent, input: data))
            XCTAssertEqual(event.title, source)
            XCTAssertEqual(MessageText.plain(event.title), "Готово: release")
        }
    }
}
