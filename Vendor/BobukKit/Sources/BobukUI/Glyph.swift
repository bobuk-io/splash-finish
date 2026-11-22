// Line icons for window strips, row actions and info lines, from lowkey. One CGPath per glyph on a
// 16×16 grid (y grows downward), drawn by AppKit views and SwiftUI alike, so every app's close
// cross looks the same. Use these instead of SF Symbols in chrome.
import AppKit
import SwiftUI

public enum Glyph: String, CaseIterable, Sendable {
    /// A cross: close or hide a window, dismiss a row.
    case close
    /// A small round "q": close for good (lowkey closes a site and its session).
    case terminate
    case back
    case forward
    /// An arrow to a bar (⇤): back to the start page.
    case start
    case lock
    case reload
    case plus
    case minus
    case check
    /// Three dots: more actions.
    case more
    /// A gear: open Settings.
    case settings

    /// Glyphs that destroy or dismiss: their strip button turns red on hover.
    public var isDestructive: Bool { self == .close || self == .terminate }

    /// The outline of the glyph, fitted to a square centered in `rect`, for stroking with
    /// `lineWidth(for:)`. Coordinates grow downward, as in flipped AppKit views and SwiftUI.
    public func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        let path = CGMutablePath()
        func line(_ points: (CGFloat, CGFloat)...) {
            path.move(to: p(points[0].0, points[0].1))
            for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: origin.x + (cx - r) * scale, y: origin.y + (cy - r) * scale,
                                       width: 2 * r * scale, height: 2 * r * scale))
        }
        switch self {
        case .close:
            line((4, 4), (12, 12))
            line((12, 4), (4, 12))
        case .terminate:
            circle(7, 7, 4.5)
            line((10.2, 10.2), (13.5, 13.5))
        case .back:
            line((10, 3), (5, 8), (10, 13))
        case .forward:
            line((6, 3), (11, 8), (6, 13))
        case .start:
            line((3, 3), (3, 13))
            line((13.5, 8), (6, 8))
            line((9.5, 4.5), (6, 8), (9.5, 11.5))
        case .lock:
            path.addRoundedRect(in: CGRect(x: origin.x + 4 * scale, y: origin.y + 7 * scale, width: 8 * scale, height: 7 * scale),
                                cornerWidth: 1.5 * scale, cornerHeight: 1.5 * scale)
            path.move(to: p(5.5, 7))
            path.addLine(to: p(5.5, 4.5))
            path.addArc(center: p(8, 4.5), radius: 2.5 * scale, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            path.addLine(to: p(10.5, 7))
        case .reload:
            path.addArc(center: p(8, 8.5), radius: 4.8 * scale, startAngle: -.pi / 3, endAngle: 1.45 * .pi, clockwise: false)
            line((10.4, 1.9), (10.7, 4.4), (13.2, 4.0))
        case .plus:
            line((8, 3.5), (8, 12.5))
            line((3.5, 8), (12.5, 8))
        case .minus:
            line((3.5, 8), (12.5, 8))
        case .check:
            line((3.5, 8.5), (6.8, 11.8), (12.5, 4.5))
        case .more:
            for x in [4.0, 8.0, 12.0] as [CGFloat] { circle(x, 8, 0.6) }
        case .settings:
            circle(8, 8, 2.0)
            circle(8, 8, 4.3)
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let c = cos(angle), s = sin(angle)
                line((8 + 4.4 * c, 8 + 4.4 * s), (8 + 6.2 * c, 8 + 6.2 * s))
            }
        }
        return path
    }

    /// The stroke width for a glyph drawn in `rect`: `weight` on the 16-point grid.
    public static func lineWidth(for rect: CGRect, weight: CGFloat = 1.6) -> CGFloat {
        weight * min(rect.width, rect.height) / 16
    }

    /// Strokes the glyph into the current AppKit graphics context (a flipped view).
    @MainActor public func draw(in rect: NSRect, color: NSColor, weight: CGFloat = 1.6) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(path(in: rect))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(Self.lineWidth(for: rect, weight: weight))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}

/// A non-interactive glyph (the lock of an info line). Hidden from accessibility.
@MainActor public final class GlyphView: NSView {
    public var glyph: Glyph { didSet { needsDisplay = true } }
    public var color: NSColor { didSet { needsDisplay = true } }
    public var weight: CGFloat = 1.4 { didSet { needsDisplay = true } }

    public init(glyph: Glyph, color: NSColor = .secondaryLabelColor) {
        self.glyph = glyph
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        glyph.draw(in: bounds, color: color, weight: weight)
    }
}

/// The same glyph in SwiftUI.
public struct GlyphImage: View {
    private let glyph: Glyph
    private let size: CGFloat
    private let weight: CGFloat

    public init(_ glyph: Glyph, size: CGFloat = 12, weight: CGFloat = 1.6) {
        self.glyph = glyph
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        GlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: Glyph.lineWidth(for: CGRect(x: 0, y: 0, width: size, height: size), weight: weight),
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

public struct GlyphShape: Shape {
    public let glyph: Glyph
    public init(glyph: Glyph) { self.glyph = glyph }
    public func path(in rect: CGRect) -> Path { Path(glyph.path(in: rect)) }
}
