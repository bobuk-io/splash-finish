import SwiftUI

public struct ShortcutHint: Hashable, Identifiable {
    public let keys: String
    public let action: String
    public var id: Self { self }
    public init(_ keys: String, _ action: String) { self.keys = keys; self.action = action }
}

/// Each shortcut and its caption stay together; complete groups wrap onto another line.
/// These are hints, never hidden keyboard handlers. Apps own all actual commands.
/// Pass `onSettings` to show a trailing settings gear button in the footer bar.
public struct ShortcutFooter: View {
    private let hints: [ShortcutHint]
    private let palette: PickerPalette
    private let settingsLabel: String
    private let settingsHelp: String
    private let onSettings: (() -> Void)?

    public init(_ hints: [ShortcutHint],
                palette: PickerPalette,
                settingsLabel: String = "Settings",
                settingsHelp: String = "Settings",
                onSettings: (() -> Void)? = nil) {
        self.hints = hints
        self.palette = palette
        self.settingsLabel = settingsLabel
        self.settingsHelp = settingsHelp
        self.onSettings = onSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HintFlowLayout {
                ForEach(hints) { hint in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(hint.keys).fontWeight(.medium).fixedSize()
                            .foregroundStyle(Color(nsColor: palette.text))
                        Text(hint.action).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color(nsColor: palette.secondary))
                    }
                    .font(.system(size: PickerMetrics.footerFontSize, design: .monospaced))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hint.keys): \(hint.action)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)

            if let onSettings {
                GlyphButton(.settings, label: settingsLabel, help: settingsHelp, palette: palette,
                            width: 22, height: 22, glyphSize: 13, action: onSettings)
            }
        }
    }
}

/// Deterministic geometry, also used by tests without presenting a window.
enum HintPacking {
    static func frames(sizes: [CGSize], width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        return sizes.map { size in
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + PickerMetrics.footerLineSpacing
                lineHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + PickerMetrics.footerSpacing
            lineHeight = max(lineHeight, size.height)
            return frame
        }
    }
}

private struct HintFlowLayout: Layout {
    private func frames(width: CGFloat?, subviews: Subviews) -> [CGRect] {
        let sizes = subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            guard let width, width.isFinite else { return ideal }
            return view.sizeThatFits(ProposedViewSize(width: min(ideal.width, max(0, width)), height: nil))
        }
        return HintPacking.frames(sizes: sizes, width: width ?? .infinity)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? frames.map(\.maxX).max() ?? 0,
                      height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
