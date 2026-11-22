// Pure color-theme primitives, curated multi-color presets and derived UI tokens shared by
// bobuk-io apps. Foundation only: safe for *Core targets and CLI companions without AppKit.
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

/// Identifies each customizable color slot in `ThemeColors`.
public enum ThemeColorRole: String, CaseIterable, Identifiable, Sendable {
    case panel, accent, ink, surface, muted, border, selection, link, success, danger

    public var id: String { rawValue }
}

/// One appearance's saved colors: a preset id (or `"custom"`), required `panel` & `accent`, and
/// optional semantic overrides (`nil` means automatically derived from `panel`/`accent`).
/// Fully backward-compatible with older 2-color JSON (`preset`, `panel`, `accent`).
public struct ThemeColors: Codable, Equatable, Hashable, Sendable {
    public static let customPresetID = "custom"

    /// Preset id, or `"custom"` after a manual color change.
    public var preset: String
    public var panel: String
    public var accent: String
    public var ink: String?
    public var muted: String?
    public var surface: String?
    public var border: String?
    public var selection: String?
    public var link: String?
    public var success: String?
    public var danger: String?

    public init(preset: String,
                panel: String,
                accent: String,
                ink: String? = nil,
                muted: String? = nil,
                surface: String? = nil,
                border: String? = nil,
                selection: String? = nil,
                link: String? = nil,
                success: String? = nil,
                danger: String? = nil) {
        self.preset = preset
        self.panel = panel
        self.accent = accent
        self.ink = ink
        self.muted = muted
        self.surface = surface
        self.border = border
        self.selection = selection
        self.link = link
        self.success = success
        self.danger = danger
    }

    public var isValid: Bool {
        guard RGB(hex: panel) != nil, RGB(hex: accent) != nil else { return false }
        let optionals = [ink, muted, surface, border, selection, link, success, danger]
        return optionals.allSatisfy { value in value.map { RGB(hex: $0) != nil } ?? true }
    }

    /// Reads the explicit hex override (or required value) for `role`; nil means auto-derived.
    public func hex(for role: ThemeColorRole) -> String? {
        switch role {
        case .panel: panel
        case .accent: accent
        case .ink: ink
        case .muted: muted
        case .surface: surface
        case .border: border
        case .selection: selection
        case .link: link
        case .success: success
        case .danger: danger
        }
    }

    /// Updates a single color role; passing `nil` resets an optional role back to automatic derivation.
    public mutating func set(_ hex: String?, for role: ThemeColorRole) {
        if let hex {
            guard let normalized = RGB(hex: hex)?.hex else { return }
            switch role {
            case .panel: panel = normalized
            case .accent: accent = normalized
            case .ink: ink = normalized
            case .muted: muted = normalized
            case .surface: surface = normalized
            case .border: border = normalized
            case .selection: selection = normalized
            case .link: link = normalized
            case .success: success = normalized
            case .danger: danger = normalized
            }
            preset = Self.customPresetID
        } else {
            switch role {
            case .panel, .accent: return
            case .ink: ink = nil
            case .muted: muted = nil
            case .surface: surface = nil
            case .border: border = nil
            case .selection: selection = nil
            case .link: link = nil
            case .success: success = nil
            case .danger: danger = nil
            }
            preset = Self.customPresetID
        }
    }
}

/// Curated light/dark theme preset shared across bobuk-io apps.
public struct ThemePreset: Identifiable, Equatable, Hashable, Sendable {
    public struct Palette: Equatable, Hashable, Sendable {
        public let panel: String
        public let accent: String
        public let ink: String?
        public let muted: String?
        public let surface: String?
        public let border: String?
        public let selection: String?
        public let link: String?
        public let success: String?
        public let danger: String?

        public init(panel: String,
                    accent: String,
                    ink: String? = nil,
                    muted: String? = nil,
                    surface: String? = nil,
                    border: String? = nil,
                    selection: String? = nil,
                    link: String? = nil,
                    success: String? = nil,
                    danger: String? = nil) {
            self.panel = panel
            self.accent = accent
            self.ink = ink
            self.muted = muted
            self.surface = surface
            self.border = border
            self.selection = selection
            self.link = link
            self.success = success
            self.danger = danger
        }
    }

    public let id: String
    public let title: String
    public let light: Palette
    public let dark: Palette

    public init(id: String, title: String, light: Palette, dark: Palette) {
        self.id = id
        self.title = title
        self.light = light
        self.dark = dark
    }

    public init(id: String, title: String, light: (panel: String, accent: String), dark: (panel: String, accent: String)) {
        self.init(id: id, title: title,
                  light: Palette(panel: light.panel, accent: light.accent),
                  dark: Palette(panel: dark.panel, accent: dark.accent))
    }

    public func colors(dark isDark: Bool) -> ThemeColors {
        let p = isDark ? dark : light
        return ThemeColors(
            preset: id,
            panel: p.panel,
            accent: p.accent,
            ink: p.ink,
            muted: p.muted,
            surface: p.surface,
            border: p.border,
            selection: p.selection,
            link: p.link,
            success: p.success,
            danger: p.danger
        )
    }

    /// The shared bobuk-io graphite-and-amber palette.
    public static let amber = ThemePreset(
        id: "amber",
        title: "Amber",
        light: Palette(panel: "#f7f8f5", accent: "#885500", ink: "#222a2e", muted: "#59666c",
                       surface: "#eef0eb", border: "#b3bec1", selection: "#efe5d3", link: "#885500",
                       success: "#286444", danger: "#b53d32"),
        dark: Palette(panel: "#222a2e", accent: "#e7bb74", ink: "#eef1ec", muted: "#a4afb3",
                      surface: "#2a3439", border: "#526064", selection: "#3d3a33", link: "#f0c37a",
                      success: "#9cc9ae", danger: "#e57a6d")
    )

    /// Generalized catalog of 18 built-in themes: the bobuk-io house palettes first, followed by
    /// popular editor and terminal palettes with authentic surfaces, text, selection and status colors.
    public static let all: [ThemePreset] = [
        amber,
        ThemePreset(
            id: "sage", title: "Sage",
            light: Palette(panel: "#f1f4ee", accent: "#42664e", ink: "#202b23", muted: "#536358",
                           surface: "#e6ebe1", border: "#b0beb3", selection: "#dce6dc", link: "#326856",
                           success: "#2b6b46", danger: "#b34237"),
            dark: Palette(panel: "#242d27", accent: "#a4c69c", ink: "#e9f0ea", muted: "#9fb0a4",
                          surface: "#2d3830", border: "#4f6054", selection: "#344338", link: "#90c4b2",
                          success: "#8fc99e", danger: "#e07e73")
        ),
        ThemePreset(
            id: "ocean", title: "Ocean",
            light: Palette(panel: "#eef4f6", accent: "#286887", ink: "#1b2a32", muted: "#4c616c",
                           surface: "#e1ecef", border: "#aabdc6", selection: "#d4e4ec", link: "#1f648e",
                           success: "#236a52", danger: "#b43f3c"),
            dark: Palette(panel: "#1d2b34", accent: "#8ec5df", ink: "#e8f1f5", muted: "#98aeb9",
                          surface: "#253642", border: "#48606e", selection: "#2c4250", link: "#7cc6e8",
                          success: "#84cbb0", danger: "#e67c78")
        ),
        ThemePreset(
            id: "clay", title: "Terracotta",
            light: Palette(panel: "#f8f1ec", accent: "#9c4e32", ink: "#2d2320", muted: "#685852",
                           surface: "#efe5dd", border: "#c6b6ac", selection: "#eddcd2", link: "#9c4e32",
                           success: "#396944", danger: "#b53830"),
            dark: Palette(panel: "#302724", accent: "#e6a58a", ink: "#f4ece7", muted: "#b8a69e",
                          surface: "#3b302c", border: "#63524c", selection: "#4a3a34", link: "#ebb096",
                          success: "#9cc499", danger: "#ec7e76")
        ),
        ThemePreset(
            id: "catppuccin", title: "Catppuccin",
            light: Palette(panel: "#eff1f5", accent: "#8839ef", ink: "#3c3f58", muted: "#64677d",
                           surface: "#e6e9ef", border: "#bcc0cc", selection: "#dfd8f2", link: "#1e66f5",
                           success: "#387a24", danger: "#d20f39"),
            dark: Palette(panel: "#1e1e2e", accent: "#cba6f7", ink: "#cdd6f4", muted: "#a6adc8",
                          surface: "#313244", border: "#585b70", selection: "#393552", link: "#89b4fa",
                          success: "#a6e3a1", danger: "#f38ba8")
        ),
        ThemePreset(
            id: "tokyo-night", title: "Tokyo Night",
            light: Palette(panel: "#e1e2e7", accent: "#2e7de9", ink: "#2e3552", muted: "#525770",
                           surface: "#d5d6db", border: "#a8aecb", selection: "#c8d3ec", link: "#00698c",
                           success: "#336860", danger: "#aa3035"),
            dark: Palette(panel: "#1a1b26", accent: "#7aa2f7", ink: "#c0caf5", muted: "#9aa5ce",
                          surface: "#24283b", border: "#414868", selection: "#2e3c64", link: "#7dcfff",
                          success: "#9ece6a", danger: "#f7768e")
        ),
        ThemePreset(
            id: "kanagawa", title: "Kanagawa",
            light: Palette(panel: "#f2ecbc", accent: "#4d699b", ink: "#393836", muted: "#545464",
                           surface: "#e7dba0", border: "#b8b08a", selection: "#d8d6b2", link: "#436b66",
                           success: "#476a3c", danger: "#b83648"),
            dark: Palette(panel: "#1f1f28", accent: "#7e9cd8", ink: "#dcd7ba", muted: "#a6a69c",
                          surface: "#2a2a37", border: "#54546d", selection: "#2d4f67", link: "#7fb4ca",
                          success: "#98bb6c", danger: "#e46876")
        ),
        ThemePreset(
            id: "everforest", title: "Everforest",
            light: Palette(panel: "#fdf6e3", accent: "#5d7b2a", ink: "#3c4841", muted: "#5c6a72",
                           surface: "#f4f0d9", border: "#bdc3af", selection: "#e6ebd3", link: "#2f7d5b",
                           success: "#4f7730", danger: "#bf3f42"),
            dark: Palette(panel: "#2d353b", accent: "#a7c080", ink: "#d3c6aa", muted: "#9da9a0",
                          surface: "#343f44", border: "#56635f", selection: "#425047", link: "#7fbbb3",
                          success: "#a7c080", danger: "#e67e80")
        ),
        ThemePreset(
            id: "rose-pine", title: "Rosé Pine",
            light: Palette(panel: "#faf4ed", accent: "#7e6899", ink: "#474363", muted: "#686480",
                           surface: "#f2e9e1", border: "#cecacd", selection: "#e9dfec", link: "#286983",
                           success: "#356862", danger: "#a64c66"),
            dark: Palette(panel: "#191724", accent: "#c4a7e7", ink: "#e0def4", muted: "#908caa",
                          surface: "#26233a", border: "#524f67", selection: "#393552", link: "#9ccfd8",
                          success: "#9ccfd8", danger: "#eb6f92")
        ),
        ThemePreset(
            id: "flexoki", title: "Flexoki",
            light: Palette(panel: "#fffcf0", accent: "#af3029", ink: "#100f0f", muted: "#575653",
                           surface: "#f2f0e5", border: "#cecdc3", selection: "#f5e2dc", link: "#24837b",
                           success: "#536907", danger: "#af3029"),
            dark: Palette(panel: "#100f0f", accent: "#d14d41", ink: "#cecdc3", muted: "#878580",
                          surface: "#1c1b1a", border: "#403e3c", selection: "#38201e", link: "#3aa99f",
                          success: "#879a39", danger: "#df5f52")
        ),
        ThemePreset(
            id: "nord", title: "Nord",
            light: Palette(panel: "#eceff4", accent: "#4c749c", ink: "#2e3440", muted: "#4c566a",
                           surface: "#e5e9f0", border: "#c2cad8", selection: "#d4dfec", link: "#466e96",
                           success: "#476e43", danger: "#b0404c"),
            dark: Palette(panel: "#2e3440", accent: "#88c0d0", ink: "#eceff4", muted: "#adb6c7",
                          surface: "#3b4252", border: "#4c566a", selection: "#3d4f5e", link: "#81a1c1",
                          success: "#a3be8c", danger: "#e68690")
        ),
        ThemePreset(
            id: "dracula", title: "Dracula",
            light: Palette(panel: "#f8f8f2", accent: "#7544a6", ink: "#282a36", muted: "#5b5f75",
                           surface: "#eeeee6", border: "#c5c4ce", selection: "#e6dcf0", link: "#4565b8",
                           success: "#247a3f", danger: "#c73636"),
            dark: Palette(panel: "#282a36", accent: "#bd93f9", ink: "#f8f8f2", muted: "#a8b2d1",
                          surface: "#343746", border: "#6272a4", selection: "#44475a", link: "#8be9fd",
                          success: "#50fa7b", danger: "#ff6e6e")
        ),
        ThemePreset(
            id: "gruvbox", title: "Gruvbox",
            light: Palette(panel: "#fbf1c7", accent: "#af3a03", ink: "#282828", muted: "#665c54",
                           surface: "#ebdbb2", border: "#bdae93", selection: "#f2dcb4", link: "#076678",
                           success: "#5b610c", danger: "#9d0006"),
            dark: Palette(panel: "#282828", accent: "#fe8019", ink: "#ebdbb2", muted: "#bdae93",
                          surface: "#3c3836", border: "#665c54", selection: "#4d3b2b", link: "#83a598",
                          success: "#b8bb26", danger: "#ff634f")
        ),
        ThemePreset(
            id: "solarized", title: "Solarized",
            light: Palette(panel: "#fdf6e3", accent: "#268bd2", ink: "#073642", muted: "#586e75",
                           surface: "#eee8d5", border: "#c4beab", selection: "#dcebf2", link: "#1e76b4",
                           success: "#586e00", danger: "#c9302c"),
            dark: Palette(panel: "#002b36", accent: "#2aa198", ink: "#eee8d5", muted: "#93a1a1",
                          surface: "#073642", border: "#3b5d66", selection: "#0e4752", link: "#53a7e4",
                          success: "#93a61c", danger: "#f26764")
        ),
        ThemePreset(
            id: "one", title: "One Light / One Dark",
            light: Palette(panel: "#fafafa", accent: "#4078f2", ink: "#383a42", muted: "#696c77",
                           surface: "#f0f0f1", border: "#c8c8cc", selection: "#dbe6fb", link: "#2b65e0",
                           success: "#397b39", danger: "#c83c36"),
            dark: Palette(panel: "#282c34", accent: "#61afef", ink: "#c8ccd4", muted: "#959ca8",
                          surface: "#323842", border: "#4b5263", selection: "#324457", link: "#56b6c2",
                          success: "#98c379", danger: "#e87880")
        ),
        ThemePreset(
            id: "ayu", title: "Ayu",
            light: Palette(panel: "#fafafa", accent: "#c46200", ink: "#34393e", muted: "#686d73",
                           surface: "#f0f1f3", border: "#cacdd2", selection: "#f7e6d4", link: "#2577b8",
                           success: "#507b1a", danger: "#cf3b3b"),
            dark: Palette(panel: "#1f2430", accent: "#ffcc66", ink: "#cbccc6", muted: "#949ca8",
                          surface: "#282e3d", border: "#465066", selection: "#36393c", link: "#73d0ff",
                          success: "#bae67e", danger: "#f28779")
        ),
        ThemePreset(
            id: "monokai", title: "Monokai",
            light: Palette(panel: "#fafafa", accent: "#c72566", ink: "#272822", muted: "#66675e",
                           surface: "#efefef", border: "#cbccc4", selection: "#f5d8e4", link: "#1e7898",
                           success: "#497a16", danger: "#c7254e"),
            dark: Palette(panel: "#272822", accent: "#f92672", ink: "#f8f8f2", muted: "#a6a59a",
                          surface: "#34352d", border: "#5c5d52", selection: "#4b2f38", link: "#66d9ef",
                          success: "#a6e22e", danger: "#ff6188")
        ),
        ThemePreset(
            id: "github", title: "GitHub",
            light: Palette(panel: "#ffffff", accent: "#0969da", ink: "#1f2328", muted: "#59636e",
                           surface: "#f6f8fa", border: "#d0d7de", selection: "#ddf4ff", link: "#0969da",
                           success: "#1a7f37", danger: "#cf222e"),
            dark: Palette(panel: "#0d1117", accent: "#58a6ff", ink: "#e6edf3", muted: "#8b949e",
                          surface: "#161b22", border: "#30363d", selection: "#1f324a", link: "#58a6ff",
                          success: "#3fb950", danger: "#f85149")
        ),
    ]

    public static func named(_ id: String) -> ThemePreset? {
        all.first { $0.id == id }
    }
}

/// Saved light and dark color palettes for one app.
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

    /// Updates a single color role on one appearance side and marks that side as custom.
    /// Passing `nil` resets an optional role back to automatic derivation.
    public mutating func set(_ hex: String?, for role: ThemeColorRole, dark isDark: Bool) {
        if isDark {
            dark.set(hex, for: role)
        } else {
            light.set(hex, for: role)
        }
    }

    /// Updates the panel hex color for one appearance side and marks that side as custom.
    public mutating func setPanel(_ hex: String, dark isDark: Bool) {
        set(hex, for: .panel, dark: isDark)
    }

    /// Updates the accent hex color for one appearance side and marks that side as custom.
    public mutating func setAccent(_ hex: String, dark isDark: Bool) {
        set(hex, for: .accent, dark: isDark)
    }
}

/// Complete set of resolved UI colors computed from `ThemeColors`, using explicit preset/user values
/// where supplied and WCAG-checked automatic derivations where omitted.
public struct ThemeTokens: Equatable, Hashable, Sendable {
    public let panel: RGB
    public let accent: RGB
    public let ink: RGB
    public let muted: RGB
    public let line: RGB
    public let stroke: RGB
    /// Card / sidebar / group surface lifted from `panel`.
    public let elevated: RGB
    /// Selected row background fill.
    public let selection: RGB
    public let hover: RGB
    public let field: RGB
    /// High-contrast ink on `accent` (badges, keycaps, prominent buttons).
    public let keyInk: RGB
    /// Hyperlink / secondary highlight ink (defaults to `accent`).
    public let link: RGB
    /// Readable positive/completed status ink.
    public let success: RGB
    /// Soft background tint for positive/completed badges.
    public let successSurface: RGB
    /// Soft background tint for accent/attention badges.
    public let accentSurface: RGB
    /// Readable destructive/error ink.
    public let danger: RGB
    /// True when `accent` has less than 3:1 contrast against `panel`.
    public let lowAccentContrast: Bool
    /// True when `ink` has less than 4.5:1 contrast against `panel`.
    public let lowInkContrast: Bool
    /// True when the surface comes from an external tint (such as a web page in lowkey).
    public let isTinted: Bool
    /// Whether `panel` reads as a dark surface (for native controls drawn on it).
    public let isDark: Bool

    public static let darkInk = RGB(hex: 0x222A2E)
    public static let lightInk = RGB(hex: 0xEEF1EC)

    public static func ink(on color: RGB) -> RGB {
        color.contrast(with: darkInk) >= color.contrast(with: lightInk) ? darkInk : lightInk
    }

    public init(colors: ThemeColors) {
        let panel = RGB(hex: colors.panel) ?? RGB(hex: 0xF7F8F5)
        let accent = RGB(hex: colors.accent) ?? RGB(hex: 0x885500)
        self.init(
            panel: panel,
            accent: accent,
            ink: colors.ink.flatMap(RGB.init(hex:)),
            muted: colors.muted.flatMap(RGB.init(hex:)),
            surface: colors.surface.flatMap(RGB.init(hex:)),
            border: colors.border.flatMap(RGB.init(hex:)),
            selection: colors.selection.flatMap(RGB.init(hex:)),
            link: colors.link.flatMap(RGB.init(hex:)),
            success: colors.success.flatMap(RGB.init(hex:)),
            danger: colors.danger.flatMap(RGB.init(hex:)),
            isTinted: false
        )
    }

    /// A panel tinted with an external color: the accent comes from the palette, the rest from the tint.
    public init(tint: RGB, colors: ThemeColors) {
        self.init(panel: tint, accent: ThemeTokens(colors: colors).accent, isTinted: true)
    }

    public init(panel: RGB,
                accent: RGB,
                ink customInk: RGB? = nil,
                muted customMuted: RGB? = nil,
                surface customSurface: RGB? = nil,
                border customBorder: RGB? = nil,
                selection customSelection: RGB? = nil,
                link customLink: RGB? = nil,
                success customSuccess: RGB? = nil,
                danger customDanger: RGB? = nil,
                isTinted: Bool = false) {
        self.isTinted = isTinted
        let autoInk = Self.ink(on: panel)
        let darkSurface = autoInk == Self.lightInk
        self.isDark = darkSurface
        self.panel = panel
        self.accent = accent

        let resolvedInk = customInk ?? autoInk
        self.ink = resolvedInk
        self.muted = customMuted ?? panel.mixed(with: resolvedInk, 0.72)
        let resolvedBorder = customBorder ?? panel.mixed(with: resolvedInk, 0.30)
        self.line = resolvedBorder
        self.stroke = panel.mixed(with: resolvedBorder, 0.55)
        self.elevated = customSurface ?? panel.mixed(with: resolvedInk, darkSurface ? 0.06 : 0.045)
        self.selection = customSelection ?? panel.mixed(with: accent, darkSurface ? 0.22 : 0.16)
        self.hover = panel.mixed(with: resolvedInk, 0.07)
        self.field = customSurface ?? panel.mixed(with: Self.ink(on: resolvedInk), 0.15)
        self.keyInk = Self.ink(on: accent)
        self.link = customLink ?? accent

        if let customSuccess {
            self.success = customSuccess
        } else {
            let rawSuccess = darkSurface ? RGB(hex: 0x9CC9AE) : RGB(hex: 0x286444)
            self.success = Self.ensureContrast(rawSuccess, on: panel, fallbackInk: autoInk, minimum: 4.5)
        }
        self.successSurface = panel.mixed(with: self.success, darkSurface ? 0.20 : 0.14)
        self.accentSurface = panel.mixed(with: accent, darkSurface ? 0.24 : 0.16)

        if let customDanger {
            self.danger = customDanger
        } else {
            let rawDanger = darkSurface ? RGB(hex: 0xE57A6D) : RGB(hex: 0xB53D32)
            self.danger = Self.ensureContrast(rawDanger, on: panel, fallbackInk: autoInk, minimum: 4.5)
        }

        self.lowAccentContrast = panel.contrast(with: accent) < 3
        self.lowInkContrast = panel.contrast(with: resolvedInk) < 4.5
    }

    /// Reads the resolved color for a customizable role.
    public func color(for role: ThemeColorRole) -> RGB {
        switch role {
        case .panel: panel
        case .accent: accent
        case .ink: ink
        case .muted: muted
        case .surface: elevated
        case .border: line
        case .selection: selection
        case .link: link
        case .success: success
        case .danger: danger
        }
    }

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
