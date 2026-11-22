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
        #expect(ThemePreset.all.count >= 18)

        let ids = ThemePreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        for preset in ThemePreset.all {
            #expect(ThemePreset.named(preset.id) == preset)
            for isDark in [false, true] {
                let colors = preset.colors(dark: isDark)
                #expect(colors.isValid, "\(preset.id) dark=\(isDark)")
                let tokens = ThemeTokens(colors: colors)
                #expect(tokens.isDark == isDark, "\(preset.id) dark=\(isDark)")
                #expect(!tokens.lowAccentContrast, "\(preset.id) dark=\(isDark) accent contrast \(tokens.panel.contrast(with: tokens.accent))")
                #expect(tokens.panel.contrast(with: tokens.ink) >= 7.0, "\(preset.id) dark=\(isDark) ink contrast")
                #expect(tokens.panel.contrast(with: tokens.muted) >= 4.5, "\(preset.id) dark=\(isDark) muted contrast")
                #expect(tokens.panel.contrast(with: tokens.success) >= 4.5, "\(preset.id) dark=\(isDark) success contrast")
                #expect(tokens.panel.contrast(with: tokens.danger) >= 4.5, "\(preset.id) dark=\(isDark) danger contrast")
                #expect(tokens.accent.contrast(with: tokens.keyInk) >= 3.0, "\(preset.id) dark=\(isDark) keyInk contrast")
            }
        }
    }

    @Test func tokensDetectLowAccentContrastAndTintMode() {
        let low = ThemeTokens(panel: RGB(hex: 0x222A2E), accent: RGB(hex: 0x2B3338))
        #expect(low.lowAccentContrast)
        #expect(low.isDark)
        #expect(!low.isTinted)

        let tinted = ThemeTokens(tint: RGB(hex: 0xFFFFFF), colors: ThemePreset.amber.colors(dark: true))
        #expect(tinted.isTinted)
        #expect(!tinted.isDark)
        #expect(tinted.accent == RGB(hex: 0xE7BB74))
        #expect(tinted.panel.contrast(with: tinted.border(increasedContrast: true))
                > tinted.panel.contrast(with: tinted.border(increasedContrast: false)))
    }

    @Test func paletteConfigPersistsSafelyAndHandlesCustomEdits() throws {
        var config = ThemePaletteConfig(preset: ThemePreset.named("nord")!)
        #expect(config.light.preset == "nord")
        #expect(config.dark.preset == "nord")

        config.setAccent("#ff5500", dark: true)
        #expect(config.dark.preset == ThemeColors.customPresetID)
        #expect(config.dark.accent == "#ff5500")
        #expect(config.light.preset == "nord")

        config.setPanel("#101018", dark: true)
        #expect(config.dark.panel == "#101018")
        // Invalid hex is ignored.
        config.setPanel("not-a-color", dark: true)
        #expect(config.dark.panel == "#101018")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ThemePaletteConfig.self, from: data)
        #expect(decoded == config)

        // Corrupt colors fall back to Amber without throwing.
        let corrupt = Data(##"{"light":{"preset":"bad","panel":"nope","accent":"#123"},"dark":{"preset":"nord","panel":"#2e3440","accent":"#88c0d0"}}"##.utf8)
        let recovered = try JSONDecoder().decode(ThemePaletteConfig.self, from: corrupt)
        #expect(recovered.light == ThemePreset.amber.colors(dark: false))
        #expect(recovered.dark.panel == "#2e3440")
    }
}
