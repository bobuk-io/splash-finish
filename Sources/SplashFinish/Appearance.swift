import AppKit
import BobukCore
import BobukSystem
import BobukUI
import SwiftUI

extension AppearanceChoice {
    /// Kept from earlier versions, which saved "light" or "dark" here.
    static let defaultsKey = "appTheme"
    /// Settings offers System, Light and Dark.
    static let offered: [AppearanceChoice] = AppearanceChoice.allCases
    /// The saved choice; the inbox stays dark until the user chooses System or Light.
    static var saved: AppearanceChoice { stored(key: defaultsKey, fallback: .dark) }
}

@MainActor extension ThemeStore {
    static let splashKeys = StorageKeys(appearance: AppearanceChoice.defaultsKey, palette: "appThemePalette")

    /// Shared per-app theme store for Splash Finish: preserves the legacy `appTheme` key,
    /// defaults to Dark + Amber, and persists custom/preset palettes in UserDefaults.
    static let splash = ThemeStore(
        keys: splashKeys,
        defaultAppearance: .dark,
        defaultPreset: .amber
    )
}

extension PickerPalette {
    /// The active inbox palette for Splash Finish, respecting accessibility contrast.
    @MainActor static func splash(increasedContrast: Bool) -> PickerPalette {
        ThemeStore.splash.tokens.pickerPalette(increasedContrast: increasedContrast)
    }

    @MainActor static var splash: PickerPalette { ThemeStore.splash.pickerPalette }
}

extension ChromeStyle {
    /// Window chrome matching Splash Finish's active theme.
    @MainActor static var splashWindow: ChromeStyle { ThemeStore.splash.chromeStyle }
}

@MainActor struct SettingsView: View {
    let model: AppModel
    var theme: ThemeStore = .splash
    let installSkills: () -> Void
    let uninstallSkills: () -> Void
    var onBodyHeight: ((CGFloat) -> Void)? = nil
    @State private var startsAtLogin = LoginItem.isEnabled

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.tokens.inkColor)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    var body: some View {
        let tokens = theme.tokens
        let palette = theme.pickerPalette
        VStack(alignment: .leading, spacing: 14) {
            ThemeSettingsSection(theme: theme, offeredAppearances: AppearanceChoice.offered)

            ThemedSection("General", tokens: tokens) {
                toggleRow("Start at Login", isOn: Binding(
                    get: { startsAtLogin },
                    set: { value in
                        // Opens Login Items in System Settings when macOS asks for approval.
                        do { try LoginItem.set(value) } catch { model.report(error); model.show() }
                        startsAtLogin = LoginItem.isEnabled
                    }
                ))
                Rectangle().fill(tokens.strokeColor).frame(height: 1)
                toggleRow("Respect Do Not Disturb", isOn: Binding(
                    get: { model.respectFocus },
                    set: { value in
                        model.respectFocus = value
                        UserDefaults.standard.set(value, forKey: "respectFocus")
                    }
                ))
            }

            ThemedSection("Agent Skills", tokens: tokens) {
                HStack(spacing: 10) {
                    Button("Install Agent Skills…", action: installSkills)
                        .buttonStyle(QuietButtonStyle(palette: palette, height: 28))
                    Button("Uninstall Agent Skills…", action: uninstallSkills)
                        .buttonStyle(QuietButtonStyle(palette: palette, height: 28))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(width: 480, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onBodyHeight?(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in onBodyHeight?(height) }
            }
        )
        .themedSurface(theme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startsAtLogin = LoginItem.isEnabled
        }
    }
}
