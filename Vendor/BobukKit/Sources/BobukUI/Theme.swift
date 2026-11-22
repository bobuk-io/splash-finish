// AppKit/SwiftUI theme bindings, live ThemeStore with per-app persistence and surface helpers.
import AppKit
import BobukCore
import Observation
import SwiftUI

public extension NSColor {
    convenience init(_ rgb: RGB, alpha: CGFloat = 1) {
        self.init(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    var rgb: RGB? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return RGB(r: Double(color.redComponent), g: Double(color.greenComponent), b: Double(color.blueComponent))
    }
}

public extension Color {
    init(_ rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }
}

public extension ThemeTokens {
    var panelNSColor: NSColor { NSColor(panel) }
    var accentNSColor: NSColor { NSColor(accent) }
    var inkNSColor: NSColor { NSColor(ink) }
    var mutedNSColor: NSColor { NSColor(muted) }
    var lineNSColor: NSColor { NSColor(line) }
    var strokeNSColor: NSColor { NSColor(stroke) }
    var elevatedNSColor: NSColor { NSColor(elevated) }
    var selectionNSColor: NSColor { NSColor(selection) }
    var hoverNSColor: NSColor { NSColor(hover) }
    var fieldNSColor: NSColor { NSColor(field) }
    var keyInkNSColor: NSColor { NSColor(keyInk) }
    var linkNSColor: NSColor { NSColor(link) }
    var successNSColor: NSColor { NSColor(success) }
    var successSurfaceNSColor: NSColor { NSColor(successSurface) }
    var accentSurfaceNSColor: NSColor { NSColor(accentSurface) }
    var dangerNSColor: NSColor { NSColor(danger) }

    var panelColor: Color { Color(panel) }
    var accentColor: Color { Color(accent) }
    var inkColor: Color { Color(ink) }
    var mutedColor: Color { Color(muted) }
    var lineColor: Color { Color(line) }
    var strokeColor: Color { Color(stroke) }
    var elevatedColor: Color { Color(elevated) }
    var selectionColor: Color { Color(selection) }
    var hoverColor: Color { Color(hover) }
    var fieldColor: Color { Color(field) }
    var keyInkColor: Color { Color(keyInk) }
    var linkColor: Color { Color(link) }
    var successColor: Color { Color(success) }
    var successSurfaceColor: Color { Color(successSurface) }
    var accentSurfaceColor: Color { Color(accentSurface) }
    var dangerColor: Color { Color(danger) }

    /// Native appearance matching the luminance of `panel`, so controls drawn on it remain legible.
    var chromeAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func pickerPalette(increasedContrast: Bool = false) -> PickerPalette {
        PickerPalette(
            surface: panelNSColor,
            text: inkNSColor,
            secondary: mutedNSColor,
            accent: accentNSColor,
            border: NSColor(border(increasedContrast: increasedContrast)),
            badgeInk: keyInkNSColor,
            selection: selectionNSColor,
            link: linkNSColor
        )
    }

    func chromeStyle(separator: NSColor? = nil,
                     destructiveHover: NSColor? = nil,
                     appearance: NSAppearance? = nil) -> ChromeStyle {
        ChromeStyle(
            panel: panelNSColor,
            ink: inkNSColor,
            muted: mutedNSColor,
            accent: accentNSColor,
            separator: separator ?? strokeNSColor,
            destructiveHover: isTinted ? nil : (destructiveHover ?? dangerNSColor),
            appearance: appearance ?? chromeAppearance
        )
    }
}

/// Live, persisted per-app theme store.
/// Apps create one store configured with their own UserDefaults keys and defaults.
@MainActor @Observable public final class ThemeStore {
    public struct StorageKeys: Equatable, Sendable {
        /// Key for `AppearanceChoice` (`"system"`, `"light"`, `"dark"`).
        public var appearance: String
        /// Key for JSON-encoded `ThemePaletteConfig`.
        public var palette: String

        public init(appearance: String = "appearance", palette: String = "themePalette") {
            self.appearance = appearance
            self.palette = palette
        }
    }

    /// Posted whenever appearance, palette, system dark mode or contrast setting changes.
    public static let didChangeNotification = Notification.Name("io.bobuk.BobukUI.ThemeDidChange")

    public let keys: StorageKeys
    public let defaultAppearance: AppearanceChoice
    public let defaultPreset: ThemePreset
    /// When true, changing `appearance` updates `NSApp.appearance`. Keep false in tests or apps
    /// that manage per-window appearance (like lowkey).
    public let appliesToApplication: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var contrastObserver: NSObjectProtocol?

    public var appearance: AppearanceChoice {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: keys.appearance)
            applyApplicationAppearance()
            refreshSystemState()
            notify()
        }
    }

    public var palette: ThemePaletteConfig {
        didSet {
            guard palette != oldValue else { return }
            persistPalette()
            notify()
        }
    }

    public private(set) var systemIsDark: Bool
    public private(set) var increasedContrast: Bool

    public init(defaults: UserDefaults = .standard,
                keys: StorageKeys = StorageKeys(),
                defaultAppearance: AppearanceChoice = .system,
                defaultPreset: ThemePreset = .amber,
                appliesToApplication: Bool = true) {
        self.defaults = defaults
        self.keys = keys
        self.defaultAppearance = defaultAppearance
        self.defaultPreset = defaultPreset
        self.appliesToApplication = appliesToApplication

        let storedAppearance = AppearanceChoice.stored(in: defaults, key: keys.appearance, fallback: defaultAppearance)
        let storedPalette = Self.loadPalette(from: defaults, key: keys.palette, fallback: defaultPreset)
        self.appearance = storedAppearance
        self.palette = storedPalette
        self.systemIsDark = Self.readSystemIsDark()
        self.increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        if appliesToApplication {
            startObservingSystem()
        }
    }

    deinit {
        if let observer = contrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// True when the active appearance resolves to dark mode.
    public var isDark: Bool {
        switch appearance {
        case .dark: true
        case .light: false
        case .system: systemIsDark
        }
    }

    public var colors: ThemeColors { palette.colors(dark: isDark) }
    public var tokens: ThemeTokens { ThemeTokens(colors: colors) }
    public var pickerPalette: PickerPalette { tokens.pickerPalette(increasedContrast: increasedContrast) }
    public var chromeAppearance: NSAppearance? { tokens.chromeAppearance }
    public var chromeStyle: ChromeStyle { tokens.chromeStyle(appearance: chromeAppearance) }
    public var isDefaultPalette: Bool { palette == ThemePaletteConfig(preset: defaultPreset) }

    public func colors(dark isDark: Bool) -> ThemeColors { palette.colors(dark: isDark) }
    public func tokens(dark isDark: Bool) -> ThemeTokens { palette.tokens(dark: isDark) }

    /// Applies `NSApp.appearance` (if enabled) and synchronizes system dark/contrast flags.
    public func apply() {
        applyApplicationAppearance()
        refreshSystemState()
        notify()
    }

    /// Applies a preset to both light and dark modes.
    public func applyPreset(_ preset: ThemePreset) {
        var next = palette
        next.applyPreset(preset)
        palette = next
    }

    /// Applies a preset by id if it exists in `presets`.
    public func applyPreset(id: String, in presets: [ThemePreset] = ThemePreset.all) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        applyPreset(preset)
    }

    /// Sets a custom color for any role on one appearance side; passing `nil` resets an optional role to Auto.
    public func setColor(_ rgb: RGB?, for role: ThemeColorRole, dark isDark: Bool) {
        var next = palette
        next.set(rgb?.hex, for: role, dark: isDark)
        palette = next
    }

    /// Sets a custom panel color for one appearance side.
    public func setPanel(_ rgb: RGB, dark isDark: Bool) {
        setColor(rgb, for: .panel, dark: isDark)
    }

    /// Sets a custom accent color for one appearance side.
    public func setAccent(_ rgb: RGB, dark isDark: Bool) {
        setColor(rgb, for: .accent, dark: isDark)
    }

    /// Resets both light and dark palettes to `defaultPreset`.
    public func resetPalette() {
        palette = ThemePaletteConfig(preset: defaultPreset)
    }

    /// Updates `increasedContrast` explicitly (useful in tests or SwiftUI contrast environments).
    public func setIncreasedContrast(_ value: Bool) {
        guard increasedContrast != value else { return }
        increasedContrast = value
        notify()
    }

    private func applyApplicationAppearance() {
        guard appliesToApplication, NSApp != nil else { return }
        appearance.apply()
    }

    private func startObservingSystem() {
        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handleSystemChange() }
                }
            }
        }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemChange() }
        }
    }

    private func handleSystemChange() {
        let newDark = Self.readSystemIsDark()
        let newContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var changed = false
        if appearance == .system, systemIsDark != newDark {
            systemIsDark = newDark
            changed = true
        }
        if increasedContrast != newContrast {
            increasedContrast = newContrast
            changed = true
        }
        if changed { notify() }
    }

    private func refreshSystemState() {
        if appearance == .system {
            systemIsDark = Self.readSystemIsDark()
        }
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func readSystemIsDark() -> Bool {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private func persistPalette() {
        guard let data = try? JSONEncoder().encode(palette) else { return }
        defaults.set(data, forKey: keys.palette)
    }

    private static func loadPalette(from defaults: UserDefaults, key: String, fallback: ThemePreset) -> ThemePaletteConfig {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ThemePaletteConfig.self, from: data) else {
            return ThemePaletteConfig(preset: fallback)
        }
        return decoded
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
