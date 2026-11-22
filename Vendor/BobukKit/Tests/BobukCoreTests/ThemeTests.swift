import Foundation
import Testing
@testable import BobukCore

@Suite struct ThemeCoreTests {
    @Test func rgbParsesFormatsMixesAndMeasuresContrast() {
        #expect(RGB(hex: "#f7f8f5") == RGB(hex: 0xF7F8F5))
        #expect(RGB(hex: " #222A2E \n")?.hex == "#222a2e")
        #expect(RGB(hex: "222a2e") == nil)
        #expect(RGB(hex: "#fff") == nil)
        #expect(RGB(hex: "#gggggg") == nil)

        let white = RGB(hex: 0xFFFFFF)
        let black = RGB(hex: 0x000000)
        #expect(abs(white.contrast(with: black) - 21) < 0.01)
        #expect(white.mixed(with: black, 0.5).hex == "#808080")
        #expect(white.mixed(with: black, -1) == white)
        #expect(white.mixed(with: black, 2) == black)
    }

    @Test func everyBuiltinPresetIsUniqueValidAndHighContrast() {
        #expect(ThemePreset.all.first == .amber)
        #expect(ThemePreset.all.count == 18)

        let ids = ThemePreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        for preset in ThemePreset.all {
            #expect(ThemePreset.named(preset.id) == preset)
            for isDark in [false, true] {
                let colors = preset.colors(dark: isDark)
                #expect(colors.isValid, "\(preset.id) dark=\(isDark)")
                // Every curated preset supplies its full authentic palette.
                for role in ThemeColorRole.allCases {
                    #expect(colors.hex(for: role) != nil, "\(preset.id) dark=\(isDark) missing \(role)")
                }
                let tokens = ThemeTokens(colors: colors)
                #expect(tokens.isDark == isDark, "\(preset.id) dark=\(isDark)")
                #expect(!tokens.lowAccentContrast, "\(preset.id) dark=\(isDark) accent contrast \(tokens.panel.contrast(with: tokens.accent))")
                #expect(!tokens.lowInkContrast, "\(preset.id) dark=\(isDark) ink contrast \(tokens.panel.contrast(with: tokens.ink))")
                #expect(tokens.panel.contrast(with: tokens.ink) >= 7.0, "\(preset.id) dark=\(isDark) ink contrast \(tokens.panel.contrast(with: tokens.ink))")
                #expect(tokens.panel.contrast(with: tokens.muted) >= 4.5, "\(preset.id) dark=\(isDark) muted contrast \(tokens.panel.contrast(with: tokens.muted))")
                #expect(tokens.panel.contrast(with: tokens.link) >= 3.5, "\(preset.id) dark=\(isDark) link contrast \(tokens.panel.contrast(with: tokens.link))")
                #expect(tokens.panel.contrast(with: tokens.success) >= 4.5, "\(preset.id) dark=\(isDark) success contrast \(tokens.panel.contrast(with: tokens.success))")
                #expect(tokens.panel.contrast(with: tokens.danger) >= 4.5, "\(preset.id) dark=\(isDark) danger contrast \(tokens.panel.contrast(with: tokens.danger))")
                #expect(tokens.accent.contrast(with: tokens.keyInk) >= 3.0, "\(preset.id) dark=\(isDark) keyInk contrast \(tokens.accent.contrast(with: tokens.keyInk))")
                #expect(tokens.selection != tokens.panel, "\(preset.id) dark=\(isDark) selection distinct")
                #expect(tokens.elevated != tokens.panel, "\(preset.id) dark=\(isDark) surface distinct")
            }
        }
    }

    @Test func tokensDetectLowContrastAndSupportAutoFallback() {
        let low = ThemeTokens(panel: RGB(hex: 0x222A2E), accent: RGB(hex: 0x2B3338), ink: RGB(hex: 0x333C40))
        #expect(low.lowAccentContrast)
        #expect(low.lowInkContrast)
        #expect(low.isDark)
        #expect(!low.isTinted)

        let tinted = ThemeTokens(tint: RGB(hex: 0xFFFFFF), colors: ThemePreset.amber.colors(dark: true))
        #expect(tinted.isTinted)
        #expect(!tinted.isDark)
        #expect(tinted.accent == RGB(hex: 0xE7BB74))
        #expect(tinted.panel.contrast(with: tinted.border(increasedContrast: true))
                > tinted.panel.contrast(with: tinted.border(increasedContrast: false)))
    }

    @Test func paletteConfigPersistsAllRolesAndRemainsBackwardCompatible() throws {
        var config = ThemePaletteConfig(preset: ThemePreset.named("kanagawa")!)
        #expect(config.dark.ink == "#dcd7ba")
        #expect(config.dark.link == "#7fb4ca")

        // Editing a single role marks that side as custom without losing other roles.
        config.set("#ff5500", for: .link, dark: true)
        #expect(config.dark.preset == ThemeColors.customPresetID)
        #expect(config.dark.link == "#ff5500")
        #expect(config.dark.ink == "#dcd7ba")
        #expect(config.light.preset == "kanagawa")

        // Resetting an optional role to nil falls back to auto derivation.
        config.set(nil, for: .link, dark: true)
        #expect(config.dark.link == nil)
        #expect(config.tokens(dark: true).link == config.tokens(dark: true).accent)

        // Invalid hex is ignored.
        config.set("not-a-color", for: .surface, dark: true)
        #expect(config.dark.surface == "#2a2a37")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ThemePaletteConfig.self, from: data)
        #expect(decoded == config)

        // Legacy 2-color JSON (without ink/surface/muted/etc.) decodes cleanly and derives all tokens.
        let legacy = Data(##"{"light":{"preset":"custom","panel":"#f7f8f5","accent":"#885500"},"dark":{"preset":"nord","panel":"#2e3440","accent":"#88c0d0"}}"##.utf8)
        let fromLegacy = try JSONDecoder().decode(ThemePaletteConfig.self, from: legacy)
        #expect(fromLegacy.dark.panel == "#2e3440")
        #expect(fromLegacy.dark.ink == nil)
        #expect(fromLegacy.tokens(dark: true).ink == ThemeTokens.lightInk)

        // Corrupt colors fall back to Amber without throwing.
        let corrupt = Data(##"{"light":{"preset":"bad","panel":"nope","accent":"#123"},"dark":{"preset":"nord","panel":"#2e3440","accent":"#88c0d0","ink":"bad"}}"##.utf8)
        let recovered = try JSONDecoder().decode(ThemePaletteConfig.self, from: corrupt)
        #expect(recovered.light == ThemePreset.amber.colors(dark: false))
        #expect(recovered.dark == ThemePreset.amber.colors(dark: true))
    }
}
