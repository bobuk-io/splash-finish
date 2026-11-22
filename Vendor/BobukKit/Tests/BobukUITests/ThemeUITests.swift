import AppKit
import BobukCore
import BobukTestSupport
import SwiftUI
import Testing
@testable import BobukUI

@MainActor @Suite(.serialized) struct ThemeUITests {
    @Test func themeStorePersistsAppearanceAndPalettePerApp() {
        let (defaults, suite) = IsolatedDefaults.make()
        defer { IsolatedDefaults.remove(suite) }
        let keys = ThemeStore.StorageKeys(appearance: "appTheme", palette: "appThemePalette")

        let first = ThemeStore(defaults: defaults, keys: keys, defaultAppearance: .dark,
                               defaultPreset: .amber, appliesToApplication: false)
        #expect(first.appearance == .dark)
        #expect(first.isDark)
        #expect(first.colors == ThemePreset.amber.colors(dark: true))
        #expect(first.isDefaultPalette)

        first.applyPreset(ThemePreset.named("kanagawa")!)
        #expect(!first.isDefaultPalette)
        #expect(first.colors.preset == "kanagawa")
        #expect(first.colors(dark: false).preset == "kanagawa")

        first.appearance = .light
        #expect(!first.isDark)
        #expect(first.colors == ThemePreset.named("kanagawa")!.colors(dark: false))

        first.setAccent(RGB(hex: 0xC72566), dark: false)
        #expect(first.colors.preset == ThemeColors.customPresetID)
        #expect(first.colors.accent == "#c72566")

        // Reloading from the same defaults preserves both appearance and custom palette.
        let reloaded = ThemeStore(defaults: defaults, keys: keys, defaultAppearance: .dark,
                                  defaultPreset: .amber, appliesToApplication: false)
        #expect(reloaded.appearance == .light)
        #expect(reloaded.colors.preset == ThemeColors.customPresetID)
        #expect(reloaded.colors.accent == "#c72566")
        #expect(reloaded.colors(dark: true).preset == "kanagawa")

        reloaded.resetPalette()
        #expect(reloaded.isDefaultPalette)
        #expect(reloaded.colors == ThemePreset.amber.colors(dark: false))
    }

    @Test func themeStoreHonorsLegacyAppearanceKey() {
        let (defaults, suite) = IsolatedDefaults.make()
        defer { IsolatedDefaults.remove(suite) }
        defaults.set("light", forKey: "appTheme")
        let store = ThemeStore(defaults: defaults,
                               keys: .init(appearance: "appTheme", palette: "appThemePalette"),
                               defaultAppearance: .dark,
                               appliesToApplication: false)
        #expect(store.appearance == .light)
        #expect(store.colors == ThemePreset.amber.colors(dark: false))
    }

    @Test func chromeWindowAndPanelFollowLiveThemeChanges() {
        _ = NSApplication.shared
        let (defaults, suite) = IsolatedDefaults.make()
        defer { IsolatedDefaults.remove(suite) }
        let store = ThemeStore(defaults: defaults, defaultAppearance: .dark, appliesToApplication: false)
        let window = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), theme: store)
        let panel = BobukPanel(kind: .floating)
        panel.bindTheme(store)

        #expect(window.chromeStyle.accent.rgb == RGB(hex: 0xE7BB74))
        #expect(window.appearance?.name == .darkAqua)
        #expect(panel.appearance?.name == .darkAqua)

        store.applyPreset(ThemePreset.named("catppuccin")!)
        #expect(window.chromeStyle.accent.rgb == RGB(hex: 0xCBA6F7))
        #expect(window.chromeStyle.panel.rgb == RGB(hex: 0x1E1E2E))

        store.appearance = .light
        #expect(window.chromeStyle.panel.rgb == RGB(hex: 0xEFF1F5))
        #expect(window.appearance?.name == .aqua)
        #expect(panel.appearance?.name == .aqua)

        // A dark custom panel in Light mode flips chromeAppearance to darkAqua so controls stay readable.
        store.setPanel(RGB(hex: 0x100F0F), dark: false)
        #expect(window.appearance?.name == .darkAqua)
        #expect(panel.appearance?.name == .darkAqua)
    }

    @Test func themeSettingsSectionHostsCleanly() {
        _ = NSApplication.shared
        let (defaults, suite) = IsolatedDefaults.make()
        defer { IsolatedDefaults.remove(suite) }
        let store = ThemeStore(defaults: defaults, defaultAppearance: .dark, appliesToApplication: false)
        let view = VStack {
            ThemeSettingsSection(theme: store)
        }
        .padding(16)
        .themedSurface(store)
        .frame(width: 440, height: 340)

        let host = ChromeWindow.hosting(view)
        host.setFrameSize(NSSize(width: 440, height: 340))
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width == 440)
        #expect(host.frame.height == 340)
    }
}
