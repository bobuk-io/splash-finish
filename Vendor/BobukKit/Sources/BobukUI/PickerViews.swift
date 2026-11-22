import SwiftUI

/// Layout/highlight only. Apps retain native Button semantics, context menus and actions.
public struct PickerRow<Content: View>: View {
    private let selected: Bool
    private let palette: PickerPalette
    private let content: Content
    @State private var hovering = false

    public init(selected: Bool, palette: PickerPalette, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.palette = palette
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, PickerMetrics.rowInset)
            .frame(maxWidth: .infinity, minHeight: PickerMetrics.rowHeight, alignment: .center)
            .background(RoundedRectangle(cornerRadius: PickerMetrics.rowRadius)
                .fill(Color(nsColor: selected ? palette.selection
                             : palette.text.withAlphaComponent(hovering ? 0.06 : 0))))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A fixed column, not an NSTextField whose cell insets shift the glyphs upwards.
public struct PickerBadge: View {
    private let title: String
    private let width: CGFloat
    private let palette: PickerPalette
    private let emphasized: Bool

    public init(_ title: String, width: CGFloat, palette: PickerPalette, emphasized: Bool = true) {
        self.title = title
        self.width = width
        self.palette = palette
        self.emphasized = emphasized
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .lineLimit(1).truncationMode(.tail)
            .foregroundStyle(Color(nsColor: emphasized ? palette.badgeInk : palette.secondary))
            .frame(width: width, height: PickerMetrics.badgeHeight, alignment: .center)
            .background(Color(nsColor: emphasized ? palette.accent : palette.text.withAlphaComponent(0.07)),
                        in: RoundedRectangle(cornerRadius: 4))
            .help(title)
    }
}

public extension View {
    /// Same AppKit surface renderer as native NSPanel consumers. Window shadows stay with the app.
    func pickerPanel(palette: PickerPalette) -> some View {
        background(PickerSurface(palette: palette))
            .clipShape(RoundedRectangle(cornerRadius: PickerMetrics.panelRadius))
    }
}

private struct PickerSurface: NSViewRepresentable {
    let palette: PickerPalette
    func makeNSView(context: Context) -> PickerSurfaceView { PickerSurfaceView(palette: palette) }
    func updateNSView(_ nsView: PickerSurfaceView, context: Context) { nsView.palette = palette }
}
