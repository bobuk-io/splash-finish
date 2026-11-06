import AppKit
import SwiftUI
import XCTest
@testable import SplashFinish

final class MessagePreviewTests: XCTestCase {
    func testChatRevealScriptsShipInsideTheBundle() throws {
        // A missing resource would silently downgrade every Orca chat click to app activation.
        let script = Bundle.module.url(forResource: "reveal-agent-session", withExtension: "js", subdirectory: "Orca")
        let source = try String(contentsOf: try XCTUnwrap(script), encoding: .utf8)
        XCTAssertTrue(source.contains("agentSession.reveal"))
        XCTAssertFalse(source.contains("exec("), "The reveal script must never run event-supplied text")
    }

    func testNativeTextRetainsStylesAndSafeLinks() async {
        await MainActor.run {
            let view = MessagePreview(text: "**Done** *today* ~~old~~ `swift test` [release](https://example.com)",
                size: 16, color: .white, lines: 2, characterLimit: 160, onOpenSource: {})
            let text = view.content
            XCTAssertEqual(text.string, "Done today old swift test release")
            let bold = text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
            let code = (text.string as NSString).range(of: "swift test").location
            XCTAssertTrue((text.attribute(.font, at: code, effectiveRange: nil) as! NSFont).isFixedPitch)
            let link = (text.string as NSString).range(of: "release").location
            XCTAssertEqual(text.attribute(.link, at: link, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        }
    }

    func testPreviewContainerFollowsActualWidthAfterLayoutProbes() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let preview = MessagePreview(
                text: "Готово. [0.3.5](https://example.com) опубликован, установлен и запущен локально. CI зелёный на коммите релиза.",
                size: 16, color: .white, lines: 2, characterLimit: 160, onOpenSource: {})
            let host = NSHostingView(rootView: preview.frame(width: 320))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
            host.layoutSubtreeIfNeeded()
            @MainActor func findPreview(in view: NSView) -> PreviewTextView? {
                if let preview = view as? PreviewTextView { return preview }
                return view.subviews.compactMap { findPreview(in: $0) }.first
            }
            let text = try XCTUnwrap(findPreview(in: host))
            let container = try XCTUnwrap(text.textContainer)
            let layout = try XCTUnwrap(text.layoutManager)
            // SwiftUI may probe a narrow width before placing the view at its final width.
            for width: CGFloat in [75, 320, 240, 320] {
                text.setFrameSize(NSSize(width: width, height: 40))
                layout.ensureLayout(for: container)
                XCTAssertEqual(container.containerSize.width, width, accuracy: 0.5,
                    "Drawing must follow the actual frame, not the last sizing proposal")
            }
            // A later measurement must not change drawing or clickable link geometry.
            let measured = try XCTUnwrap(text.measuredSize(width: 75))
            XCTAssertEqual(measured.width, 75)
            XCTAssertEqual(container.containerSize.width, 320, accuracy: 0.5)
            XCTAssertEqual(text.measuredSize(width: 320)?.width, 320)
            layout.ensureLayout(for: container)
            var lastLine = CGRect.zero
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
                lastLine = used
            }
            XCTAssertGreaterThan(lastLine.width, 280, "The second line should use the available width")
            XCTAssertEqual(text.attributedString().string, preview.content.string)
        }
    }

    func testLinkAndOrdinaryTextHaveIndependentActions() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let text = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
            text.isEditable = false
            text.isSelectable = false
            text.textContainerInset = .zero
            text.textContainer?.lineFragmentPadding = 0
            text.textContainer?.maximumNumberOfLines = 2
            text.textContainer?.lineBreakMode = .byTruncatingTail
            window.contentView = text
            let content = MessagePreview(text: "Done: [release](https://example.com)", size: 16,
                color: .white, lines: 2, characterLimit: 160, onOpenSource: {}).content
            text.textStorage?.setAttributedString(content)
            let layout = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            layout.ensureLayout(for: container)
            var sourceOpens = 0
            var links = [URL]()
            text.onOpenSource = { sourceOpens += 1 }
            text.onOpenLink = { links.append($0) }
            @MainActor func clickCharacter(_ index: Int) throws {
                let glyph = layout.glyphIndexForCharacter(at: index)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let point = text.convert(NSPoint(x: rect.midX + text.textContainerOrigin.x,
                                                 y: rect.midY + text.textContainerOrigin.y), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                text.mouseDown(with: event)
            }
            try clickCharacter(7) // 'e' in release
            XCTAssertEqual(links, [URL(string: "https://example.com")!])
            XCTAssertEqual(sourceOpens, 0, "A web link must not open/consume the agent notification")
            try clickCharacter(1) // 'o' in Done
            XCTAssertEqual(sourceOpens, 1)
            XCTAssertEqual(links.count, 1)
            XCTAssertFalse(text.acceptsFirstResponder, "Markdown must not steal inbox keyboard handling")
        }
    }
}
