import AppKit
import BobukCore
import BobukUI
import XCTest
@testable import SplashFinish

final class AppearanceTests: XCTestCase {
    @MainActor func testSavedThemeKeepsKeyValuesAndTheDarkDefault() throws {
        let suite = "io.bobuk.splash-finish.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        func stored() -> AppearanceChoice { .stored(in: defaults, key: AppearanceChoice.defaultsKey, fallback: .dark) }
        XCTAssertEqual(AppearanceChoice.defaultsKey, "appTheme")
        XCTAssertEqual(stored(), .dark)
        defaults.set("light", forKey: "appTheme")
        XCTAssertEqual(stored(), .light)
        defaults.set("system", forKey: "appTheme")
        XCTAssertEqual(stored(), .system)
        defaults.set("invalid", forKey: "appTheme")
        XCTAssertEqual(stored(), .dark)
        XCTAssertEqual(AppearanceChoice.offered.map(\.rawValue), ["system", "light", "dark"])

        // ThemeStore preserves legacy "appTheme" key and adds preset/custom palette storage.
        defaults.set("light", forKey: "appTheme")
        let store = ThemeStore(defaults: defaults, keys: ThemeStore.splashKeys,
                               defaultAppearance: .dark, defaultPreset: .amber,
                               appliesToApplication: false)
        XCTAssertEqual(store.appearance, .light)
        XCTAssertEqual(store.colors, ThemePreset.amber.colors(dark: false))

        store.applyPreset(try XCTUnwrap(ThemePreset.named("catppuccin")))
        store.appearance = .dark
        let reloaded = ThemeStore(defaults: defaults, keys: ThemeStore.splashKeys,
                                  defaultAppearance: .dark, defaultPreset: .amber,
                                  appliesToApplication: false)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.colors, ThemePreset.named("catppuccin")?.colors(dark: true))
    }

    @MainActor func testIncreasedContrastStrengthensPanelBorder() throws {
        let suite = "io.bobuk.splash-finish.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeStore(defaults: defaults, keys: ThemeStore.splashKeys,
                               defaultAppearance: .dark, defaultPreset: .amber,
                               appliesToApplication: false)
        let normalBorder = try XCTUnwrap(store.tokens.pickerPalette(increasedContrast: false).border.rgb)
        let strongBorder = try XCTUnwrap(store.tokens.pickerPalette(increasedContrast: true).border.rgb)
        XCTAssertGreaterThan(store.tokens.panel.contrast(with: strongBorder),
                             store.tokens.panel.contrast(with: normalBorder))
    }
}
