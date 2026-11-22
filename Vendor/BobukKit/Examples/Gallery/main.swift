import AppKit
import BobukCore
import SwiftUI
import BobukUI
import BobukUpdates

// Offline, invisible windows: no activation, live websites, key presses or user settings.
@MainActor func render(width: CGFloat, dark: Bool, output: URL) throws {
    let palette = PickerPalette(surface: dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1),
        text: dark ? .white : .black, secondary: dark ? .lightGray : .darkGray,
        accent: dark ? NSColor.systemOrange : NSColor.systemBlue, border: .gray,
        badgeInk: dark ? .black : .white)
    let aliases = ["HA", "NOTES", "A-VERY-LONG-ALIAS"]
    let badgeWidth = PickerMetrics.badgeWidth(for: aliases)
    let content = VStack(alignment: .leading, spacing: 0) {
        PickerSearchField(text: .constant("notes"), placeholder: "Alias or address",
                          accessibilityLabel: "Search demo items", palette: palette).padding(16)
        Divider()
        VStack(spacing: 0) {
            ForEach(Array(aliases.enumerated()), id: \.element) { index, alias in
                PickerRow(selected: index == 1, palette: palette) {
                    HStack(spacing: PickerMetrics.columnSpacing) {
                        PickerBadge(alias, width: badgeWidth, palette: palette)
                        Text(AttributedString.highlighting(["Home Control", "Project Notes", "Long labels stay inside the row"][index],
                                                            query: "notes", color: Color(nsColor: palette.accent)))
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            PickerRow(selected: false, palette: palette) {
                HStack(spacing: PickerMetrics.columnSpacing) {
                    PickerBadge("↺", width: badgeWidth, palette: palette, emphasized: false)
                    Text("https://example.com/demo").font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }.padding(.horizontal, 6).padding(.vertical, 4)
        Divider()
        ShortcutFooter([.init("↩", "open in this profile"), .init("⌘↩", "new window"),
                        .init("↑↓", "choose"), .init("⌘C", "copy URL"), .init("esc", "close")],
                       palette: palette, onSettings: {})
            .padding(16)
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .padding(.top, PickerMetrics.accentHeight)
    .frame(width: width)
    .pickerPanel(palette: palette)
    let hosting = NSHostingView(rootView: content)
    let size = hosting.fittingSize
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    hosting.setFrameSize(size)
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output)
    window.close()
    print(output.path)
}

/// A window in the shared shell: accent, strip with close (left) and app buttons (right), body.
@MainActor func renderWindow(dark: Bool, output: URL) throws {
    let palette = PickerPalette.bobukAmber
    let back = StripButton(glyph: .back, label: "Back · ⌘←")
    let start = StripButton(glyph: .start, label: "Start page")
    let forward = StripButton(glyph: .forward, label: "Forward · ⌘→")
    forward.isEnabled = false
    let window = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), style: palette.chromeStyle,
                              trailing: [back, start, forward], showsTitle: true)
    window.title = "Demo Settings"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.setContent(VStack(alignment: .leading, spacing: 12) {
        MonoLabel("General").foregroundStyle(Color(nsColor: palette.secondary))
        Text("Window controls live in the strip. Content never draws its own close button.")
            .foregroundStyle(Color(nsColor: palette.text))
        HStack(spacing: 4) {
            ForEach(Glyph.allCases, id: \.self) { glyph in
                GlyphImage(glyph, size: 14).foregroundStyle(Color(nsColor: palette.text)).frame(width: 24, height: 24)
            }
        }
        HStack {
            Button("Cancel") {}.buttonStyle(QuietButtonStyle(palette: palette))
            Button("Save") {}.buttonStyle(QuietButtonStyle(palette: palette, prominent: true))
            GlyphButton(.close, label: "Dismiss", palette: palette) {}
        }
        Spacer()
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: palette.surface)))
    guard let view = window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output)
    window.close()
    print(output.path)
}

/// A themed settings window built with `ChromeWindow(theme:)`, `ThemeSettingsSection` and `.themedSurface`.
@MainActor func renderThemedSettings(preset: ThemePreset, dark: Bool, output: URL) throws {
    let suite = UserDefaults(suiteName: "bobukkit-gallery-\(UUID().uuidString)")!
    let store = ThemeStore(defaults: suite, defaultAppearance: dark ? .dark : .light,
                           defaultPreset: preset, appliesToApplication: false)
    let window = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), theme: store,
                              resizable: false, showsTitle: true)
    window.title = "Settings — \(preset.title)"
    window.setContent(
        VStack(alignment: .leading, spacing: 14) {
            ThemeSettingsSection(theme: store)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedSurface(store)
    )
    guard let view = window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output)
    window.close()
    print(output.path)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/bobukkit-gallery", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try MainActor.assumeIsolated {
    _ = NSApplication.shared
    for dark in [false, true] {
        for width in [CGFloat(340), 560] {
            try render(width: width, dark: dark, output: output.appendingPathComponent("picker-\(dark ? "dark" : "light")-\(Int(width)).png"))
        }
        try renderWindow(dark: dark, output: output.appendingPathComponent("window-\(dark ? "dark" : "light").png"))
    }
    for id in ["amber", "catppuccin", "kanagawa", "flexoki"] {
        if let preset = ThemePreset.named(id) {
            try renderThemedSettings(preset: preset, dark: true, output: output.appendingPathComponent("theme-\(id)-dark.png"))
            try renderThemedSettings(preset: preset, dark: false, output: output.appendingPathComponent("theme-\(id)-light.png"))
        }
    }
}
