// Pure color-theme primitives, curated presets and derived UI tokens shared by bobuk-io apps.
// Foundation only: safe for *Core targets and command-line companions without AppKit.
import Foundation

/// An sRGB color in 0...1 channel range, with hex parsing, mixing and WCAG contrast helpers.
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    /// An sRGB color from `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 255) / 255,
            g: Double((hex >> 8) & 255) / 255,
            b: Double(hex & 255) / 255
        )
    }

    /// Parses `#RRGGBB`, case-insensitive, ignoring surrounding whitespace.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// Lower-case `#rrggbb` string.
    public var hex: String {
        String(format: "#%02x%02x%02x",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()))
    }

    /// Linearly mixes this color toward `other` by `amount` (clamped to `0...1`).
    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// Relative luminance per WCAG 2.x.
    public var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio in `1...21`.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// One appearance's saved colors: a preset id (or `"custom"`) plus `#rrggbb` panel and accent.
public struct ThemeColors: Codable, Equatable, Hashable, Sendable {
    public static let customPresetID = "custom"

    /// Preset id, or `"custom"` after a manual color change.
    public var preset: String
    public var panel: String
    public var accent: String

    public init(preset: String, panel: String, accent: String) {
        self.preset = preset
        self.panel = panel
        self.accent = accent
    }

    public var isValid: Bool {
        RGB(hex: panel) != nil && RGB(hex: accent) != nil
    }
}

/// Curated light/dark theme preset shared across bobuk-io apps.
public struct ThemePreset: Identifiable, Equatable, Hashable, Sendable {
    public struct Pair: Equatable, Hashable, Sendable {
        public let panel: String
        public let accent: String

        public init(panel: String, accent: String) {
            self.panel = panel
            self.accent = accent
        }
    }

    public let id: String
    public let title: String
    public let light: Pair
    public let dark: Pair

    public init(id: String, title: String, light: (panel: String, accent: String), dark: (panel: String, accent: String)) {
        self.id = id
        self.title = title
        self.light = Pair(panel: light.panel, accent: light.accent)
        self.dark = Pair(panel: dark.panel, accent: dark.accent)
    }

    public func colors(dark isDark: Bool) -> ThemeColors {
        let pair = isDark ? dark : light
        return ThemeColors(preset: id, panel: pair.panel, accent: pair.accent)
    }

    /// The shared bobuk-io graphite-and-amber palette.
    public static let amber = ThemePreset(
        id: "amber",
        title: "Amber",
        light: ("#f7f8f5", "#885500"),
        dark: ("#222a2e", "#e7bb74")
    )

    /// Generalized catalog of built-in themes: the bobuk-io house palettes first, followed by
    /// popular editor and terminal palettes adapted for native chrome and panels.
    public static let all: [ThemePreset] = [
        amber,
        ThemePreset(id: "sage", title: "Sage", light: ("#f1f4ee", "#42664e"), dark: ("#242d27", "#a4c69c")),
        ThemePreset(id: "ocean", title: "Ocean", light: ("#eef4f6", "#286887"), dark: ("#1d2b34", "#8ec5df")),
        ThemePreset(id: "clay", title: "Terracotta", light: ("#f8f1ec", "#9c4e32"), dark: ("#302724", "#e6a58a")),
        ThemePreset(id: "catppuccin", title: "Catppuccin", light: ("#eff1f5", "#8839ef"), dark: ("#1e1e2e", "#cba6f7")),
        ThemePreset(id: "tokyo-night", title: "Tokyo Night", light: ("#e1e2e7", "#2e7de9"), dark: ("#1a1b26", "#7aa2f7")),
        ThemePreset(id: "kanagawa", title: "Kanagawa", light: ("#f2ecbc", "#4d699b"), dark: ("#1f1f28", "#7e9cd8")),
        ThemePreset(id: "everforest", title: "Everforest", light: ("#fdf6e3", "#5d7b2a"), dark: ("#2d353b", "#a7c080")),
        ThemePreset(id: "rose-pine", title: "Rosé Pine", light: ("#faf4ed", "#907aa9"), dark: ("#191724", "#c4a7e7")),
        ThemePreset(id: "flexoki", title: "Flexoki", light: ("#fffcf0", "#af3029"), dark: ("#100f0f", "#d14d41")),
        ThemePreset(id: "nord", title: "Nord", light: ("#eceff4", "#5e81ac"), dark: ("#2e3440", "#88c0d0")),
        ThemePreset(id: "dracula", title: "Dracula", light: ("#f8f8f2", "#7544a6"), dark: ("#282a36", "#bd93f9")),
        ThemePreset(id: "gruvbox", title: "Gruvbox", light: ("#fbf1c7", "#af3a03"), dark: ("#282828", "#fe8019")),
        ThemePreset(id: "solarized", title: "Solarized", light: ("#fdf6e3", "#268bd2"), dark: ("#002b36", "#2aa198")),
        ThemePreset(id: "one", title: "One Light / One Dark", light: ("#fafafa", "#4078f2"), dark: ("#282c34", "#61afef")),
        ThemePreset(id: "ayu", title: "Ayu", light: ("#fafafa", "#c46200"), dark: ("#1f2430", "#ffcc66")),
        ThemePreset(id: "monokai", title: "Monokai", light: ("#fafafa", "#c72566"), dark: ("#272822", "#f92672")),
        ThemePreset(id: "github", title: "GitHub", light: ("#ffffff", "#0969da"), dark: ("#0d1117", "#58a6ff")),
    ]

    public static func named(_ id: String) -> ThemePreset? {
        all.first { $0.id == id }
    }
}

/// Saved light and dark color pairs for one app.
public struct ThemePaletteConfig: Codable, Equatable, Hashable, Sendable {
    public var light: ThemeColors
    public var dark: ThemeColors

    public init(preset: ThemePreset = .amber) {
        self.light = preset.colors(dark: false)
        self.dark = preset.colors(dark: true)
    }

    public init(light: ThemeColors, dark: ThemeColors) {
        self.light = light.isValid ? light : ThemePreset.amber.colors(dark: false)
        self.dark = dark.isValid ? dark : ThemePreset.amber.colors(dark: true)
    }

    enum CodingKeys: String, CodingKey { case light, dark }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLight = try container.decodeIfPresent(ThemeColors.self, forKey: .light)
        let decodedDark = try container.decodeIfPresent(ThemeColors.self, forKey: .dark)
        self.light = decodedLight.flatMap { $0.isValid ? $0 : nil } ?? ThemePreset.amber.colors(dark: false)
        self.dark = decodedDark.flatMap { $0.isValid ? $0 : nil } ?? ThemePreset.amber.colors(dark: true)
    }

    public func colors(dark isDark: Bool) -> ThemeColors {
        isDark ? dark : light
    }

    public func tokens(dark isDark: Bool) -> ThemeTokens {
        ThemeTokens(colors: colors(dark: isDark))
    }

    /// Applies a preset to both light and dark pairs.
    public mutating func applyPreset(_ preset: ThemePreset) {
        light = preset.colors(dark: false)
        dark = preset.colors(dark: true)
    }

    /// Applies a preset to only one appearance side.
    public mutating func applyPreset(_ preset: ThemePreset, dark isDark: Bool) {
        if isDark {
            dark = preset.colors(dark: true)
        } else {
            light = preset.colors(dark: false)
        }
    }

    /// Updates the panel hex color for one appearance side and marks that side as custom.
    public mutating func setPanel(_ hex: String, dark isDark: Bool) {
        guard let normalized = RGB(hex: hex)?.hex else { return }
        if isDark {
            dark.panel = normalized
            dark.preset = ThemeColors.customPresetID
        } else {
            light.panel = normalized
            light.preset = ThemeColors.customPresetID
        }
    }

    /// Updates the accent hex color for one appearance side and marks that side as custom.
    public mutating func setAccent(_ hex: String, dark isDark: Bool) {
        guard let normalized = RGB(hex: hex)?.hex else { return }
        if isDark {
            dark.accent = normalized
            dark.preset = ThemeColors.customPresetID
        } else {
            light.accent = normalized
            light.preset = ThemeColors.customPresetID
        }
    }
}

/// Complete set of derived UI colors computed from a panel surface and an accent color.
public struct ThemeTokens: Equatable, Hashable, Sendable {
    public let panel: RGB
    public let accent: RGB
    public let ink: RGB
    public let muted: RGB
    public let line: RGB
    public let stroke: RGB
    /// Subtle card/group surface lifted from `panel`.
    public let elevated: RGB
    public let hover: RGB
    public let field: RGB
    /// High-contrast ink on `accent` (badges, prominent buttons).
    public let keyInk: RGB
    /// Readable positive/completed status ink adapted to the surface luminance.
    public let success: RGB
    /// Soft background tint for positive/completed badges.
    public let successSurface: RGB
    /// Soft background tint for accent/attention badges.
    public let accentSurface: RGB
    /// Readable destructive/error ink adapted to the surface luminance.
    public let danger: RGB
    /// True when `accent` has less than 3:1 contrast against `panel`.
    public let lowAccentContrast: Bool
    /// True when the surface comes from an external tint (such as a web page in lowkey).
    public let isTinted: Bool

    public static let darkInk = RGB(hex: 0x222A2E)
    public static let lightInk = RGB(hex: 0xEEF1EC)

    public static func ink(on color: RGB) -> RGB {
        color.contrast(with: darkInk) >= color.contrast(with: lightInk) ? darkInk : lightInk
    }

    public init(colors: ThemeColors) {
        self.init(
            panel: RGB(hex: colors.panel) ?? RGB(hex: 0xF7F8F5),
            accent: RGB(hex: colors.accent) ?? RGB(hex: 0x885500),
            isTinted: false
        )
    }

    /// A panel tinted with an external color: the accent comes from the palette, the rest from the tint.
    public init(tint: RGB, colors: ThemeColors) {
        self.init(panel: tint, accent: ThemeTokens(colors: colors).accent, isTinted: true)
    }

    public init(panel: RGB, accent: RGB, isTinted: Bool = false) {
        self.isTinted = isTinted
        let ink = Self.ink(on: panel)
        let darkSurface = ink == Self.lightInk
        self.panel = panel
        self.accent = accent
        self.ink = ink
        self.muted = panel.mixed(with: ink, 0.72)
        self.line = panel.mixed(with: ink, 0.30)
        self.stroke = panel.mixed(with: ink, 0.15)
        self.elevated = panel.mixed(with: ink, darkSurface ? 0.06 : 0.045)
        self.hover = panel.mixed(with: ink, 0.07)
        self.field = panel.mixed(with: Self.ink(on: ink), 0.15)
        self.keyInk = Self.ink(on: accent)

        let rawSuccess = darkSurface ? RGB(hex: 0x9CC9AE) : RGB(hex: 0x286444)
        self.success = Self.ensureContrast(rawSuccess, on: panel, fallbackInk: ink, minimum: 4.5)
        self.successSurface = panel.mixed(with: self.success, darkSurface ? 0.20 : 0.14)
        self.accentSurface = panel.mixed(with: accent, darkSurface ? 0.24 : 0.16)

        let rawDanger = darkSurface ? RGB(hex: 0xE57A6D) : RGB(hex: 0xB53D32)
        self.danger = Self.ensureContrast(rawDanger, on: panel, fallbackInk: ink, minimum: 4.5)

        self.lowAccentContrast = panel.contrast(with: accent) < 3
    }

    /// Whether the panel reads as a dark surface (for native controls drawn on it).
    public var isDark: Bool { ink == Self.lightInk }

    /// Panel border color, strengthened when macOS Increase Contrast is enabled.
    public func border(increasedContrast: Bool) -> RGB {
        increasedContrast ? panel.mixed(with: ink, 0.52) : line
    }

    /// Nudges a semantic color toward `fallbackInk` until it reaches readable contrast on `panel`.
    private static func ensureContrast(_ candidate: RGB, on panel: RGB, fallbackInk: RGB, minimum: Double) -> RGB {
        if panel.contrast(with: candidate) >= minimum { return candidate }
        for step in 1...10 {
            let mixed = candidate.mixed(with: fallbackInk, Double(step) / 10)
            if panel.contrast(with: mixed) >= minimum { return mixed }
        }
        return fallbackInk
    }
}
