import AppKit

/// The shared panel frame for AppKit and SwiftUI. No window/focus policy lives here.
@MainActor public final class PickerSurfaceView: NSView {
    public var palette: PickerPalette {
        didSet { if palette != oldValue { needsDisplay = true } }
    }
    /// 0...1 turns the accent rule into a loading bar; nil draws the solid rule.
    public var accentProgress: Double? {
        didSet { if accentProgress != oldValue { needsDisplay = true } }
    }
    public override var isFlipped: Bool { true }

    public init(palette: PickerPalette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PickerMetrics.panelRadius
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        palette.surface.setFill()
        bounds.fill()
        let rule = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: PickerMetrics.accentHeight)
        if let progress = accentProgress {
            palette.accent.withAlphaComponent(0.3).setFill()
            rule.fill()
            palette.accent.setFill()
            NSRect(x: rule.minX, y: rule.minY, width: rule.width * max(0.05, min(1, progress)), height: rule.height).fill()
        } else {
            palette.accent.setFill()
            rule.fill()
        }
        palette.border.setStroke()
        let inset = PickerMetrics.borderWidth / 2
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                   xRadius: PickerMetrics.panelRadius, yRadius: PickerMetrics.panelRadius)
        outline.lineWidth = PickerMetrics.borderWidth
        outline.stroke()
    }

    // A SwiftUI background must not intercept clicks meant for the card's content.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
