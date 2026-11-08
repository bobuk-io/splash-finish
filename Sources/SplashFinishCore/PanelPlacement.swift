import CoreGraphics
import Foundation

/// Where the inbox appears. The user can drag the panel; its top-left corner is
/// remembered and reused while it still lies on a connected screen, clamped so
/// the whole panel stays visible. Otherwise the panel centers on the active screen.
public enum PanelPlacement {
    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        /// Visible area of the screen that hosts the panel; sizes the scrolling list.
        public var area: CGRect
        public init(frame: CGRect, area: CGRect) { self.frame = frame; self.area = area }
    }

    public static func place(size: CGSize, remembered topLeft: CGPoint?, screens: [CGRect], active: CGRect,
                             margin: CGFloat = 16) -> Result {
        if let topLeft, let area = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(topLeft) }) {
            let x = clamp(topLeft.x, area.minX, area.maxX - size.width)
            let top = clamp(topLeft.y, area.minY + size.height, area.maxY)
            return Result(frame: CGRect(x: x, y: top - size.height, width: size.width, height: size.height), area: area)
        }
        let area = active
        let y = clamp(area.midY - size.height / 2 - 55, area.minY + margin, area.maxY - size.height - margin)
        return Result(frame: CGRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height), area: area)
    }

    /// Lower bound wins when the panel is taller or wider than the screen.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(upper, value))
    }
}
