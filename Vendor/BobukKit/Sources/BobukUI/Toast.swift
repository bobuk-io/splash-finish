// A short message near the top of the screen with the pointer ("Safari: app not found"), from Ting.
// Click-through, never activates the app, hides itself.
import AppKit
import SwiftUI
import BobukCore

@MainActor public final class ToastController {
    private var panel: BobukPanel?
    private var hideWork: DispatchWorkItem?
    private let staticPalette: PickerPalette
    private let theme: ThemeStore?
    private let mark: AnyView?

    /// `mark` is the app's small logo before the text.
    public init(palette: PickerPalette, mark: AnyView? = nil) {
        self.staticPalette = palette
        self.theme = nil
        self.mark = mark
    }

    /// Uses live colors from `theme` each time a toast is shown.
    public init(theme: ThemeStore, mark: AnyView? = nil) {
        self.staticPalette = theme.pickerPalette
        self.theme = theme
        self.mark = mark
    }

    public var isVisible: Bool { panel?.isVisible == true }

    public func show(_ message: String, duration: TimeInterval = 3) {
        let panel = self.panel ?? BobukPanel(contentRect: .zero, kind: .hud)
        if let theme { panel.appearance = theme.chromeAppearance }
        self.panel = panel
        let palette = theme?.pickerPalette ?? staticPalette
        let hosting = NSHostingView(rootView: ToastView(message: message, palette: palette, mark: mark))
        panel.contentView = hosting
        panel.place(size: hosting.fittingSize, anchor: .top(inset: 80), margin: 0, display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    public func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }
}

private struct ToastView: View {
    let message: String
    let palette: PickerPalette
    let mark: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            if let mark { mark }
            Text(message).font(.system(size: 12)).foregroundStyle(Color(nsColor: palette.text)).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .background(Color(nsColor: palette.surface), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: palette.border), lineWidth: 0.75))
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}
