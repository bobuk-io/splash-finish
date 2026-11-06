import AppKit
import SwiftUI
import SplashFinishCore

/// Native text layout gives links their own hit targets without nesting a link
/// inside the notification's source button. Non-link text still opens the agent.
struct MessagePreview: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let color: NSColor
    let lines: Int
    let characterLimit: Int
    let onOpenSource: () -> Void

    var content: NSAttributedString {
        let parsed = MessageText.render(text, limit: characterLimit)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let weight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : (size >= 16 ? .medium : .regular)
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor(srgbRed: 0.94, green: 0.765, blue: 0.478, alpha: 1)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    func makeNSView(context: Context) -> PreviewTextView {
        let view = PreviewTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(srgbRed: 0.94, green: 0.765, blue: 0.478, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: PreviewTextView, context: Context) {
        let content = content
        if view.attributedString() != content { view.textStorage?.setAttributedString(content) }
        view.textContainer?.maximumNumberOfLines = lines
        view.onOpenSource = onOpenSource
        view.setAccessibilityLabel(content.string)
        view.window?.invalidateCursorRects(for: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 320)
        nsView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

final class PreviewTextView: NSTextView {
    var onOpenSource: (() -> Void)?
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    // Don't become a text editor: panel Enter/arrows/Esc keep their existing role.
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let url = link(at: point), MessageText.isSafeLink(url) {
            // Opening a web link never consumes the notification or opens its agent.
            onOpenLink(url)
        } else {
            onOpenSource?()
        }
    }

    private func link(at point: CGPoint) -> URL? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let point = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        // A clipped-away link must not be clickable through the ellipsis.
        let truncated = layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)
        guard truncated.location == NSNotFound || !NSLocationInRange(glyph, truncated) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is URL else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), cursor: .pointingHand)
            }
        }
    }
}
