import AppKit

/// Apps own their palette, including per-window appearance. The kit owns geometry.
public struct PickerPalette {
    public var surface: NSColor
    public var text: NSColor
    public var secondary: NSColor
    public var accent: NSColor
    public var border: NSColor
    public var badgeInk: NSColor
    public var selection: NSColor
    public var link: NSColor

    public init(surface: NSColor, text: NSColor, secondary: NSColor,
                accent: NSColor, border: NSColor, badgeInk: NSColor,
                selection: NSColor? = nil, link: NSColor? = nil) {
        self.surface = surface
        self.text = text
        self.secondary = secondary
        self.accent = accent
        self.border = border
        self.badgeInk = badgeInk
        self.selection = selection ?? accent.withAlphaComponent(0.18)
        self.link = link ?? accent
    }
}

public enum PickerMetrics {
    public static let rowHeight: CGFloat = 40
    public static let searchFieldHeight: CGFloat = 30
    public static let rowInset: CGFloat = 8
    public static let rowRadius: CGFloat = 6
    public static let columnSpacing: CGFloat = 10
    public static let panelRadius: CGFloat = 14
    public static let borderWidth: CGFloat = 1
    public static let accentHeight: CGFloat = 3
    public static let badgeHeight: CGFloat = 22
    public static let footerFontSize: CGFloat = 10
    public static let footerSpacing: CGFloat = 12
    public static let footerLineSpacing: CGFloat = 6

    /// Compute once per list, not per row. All badges, including history, use this width.
    /// Long aliases truncate rather than pushing labels off-screen; the full alias is a tooltip.
    @MainActor public static func badgeWidth(for labels: [String]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(96, max(44, ceil(widest) + 12))
    }
}

/// Shared non-wrapping navigation; callers still own selection and keyboard events.
public enum PickerSelection {
    public static func move(_ current: Int?, by delta: Int, count: Int, allowsEmpty: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 || !allowsEmpty ? 0 : nil }
        // Clamp inputs before addition and avoid integer overflow for arbitrary callers.
        let base = min(max(current, allowsEmpty ? -1 : 0), count - 1)
        if delta < 0 {
            if delta < -base { return allowsEmpty ? nil : 0 }
        } else if delta > count - 1 - base { return count - 1 }
        let result = base + delta
        return result < 0 ? nil : result
    }
}
