import AppKit
import SwiftUI
import ServiceManagement

/// Keep the existing dark appearance until the user chooses another theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark

    static let defaultsKey = "appTheme"
    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }

    @MainActor static func applySaved() {
        let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .dark
        NSApp.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
    }
}

extension NSColor {
    static func theme(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
}

extension Color {
    static func theme(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: .theme(light: light, dark: dark))
    }
    static var panelInk: Color { .theme(light: 0x222A2E, dark: 0xFFFFFF) }
    static var panelMuted: Color { .theme(light: 0x59666C, dark: 0xA4AFB3) }
    static var panelAccent: Color { .theme(light: 0x885500, dark: 0xE7BB74) }
}

struct SettingsView: View {
    let model: AppModel
    let installSkills: () -> Void
    let uninstallSkills: () -> Void
    @AppStorage(AppTheme.defaultsKey) private var theme = AppTheme.dark.rawValue
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Section("General") {
                Toggle("Start at Login", isOn: Binding(
                    get: { startsAtLogin },
                    set: { _ in
                        LoginItem.toggle(model: model)
                        startsAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                Toggle("Respect Do Not Disturb", isOn: Binding(
                    get: { model.respectFocus },
                    set: { value in
                        model.respectFocus = value
                        UserDefaults.standard.set(value, forKey: "respectFocus")
                    }
                ))
            }

            Section("Agent Skills") {
                HStack {
                    Button("Install Agent Skills…", action: installSkills)
                    Button("Uninstall Agent Skills…", action: uninstallSkills)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
        .onChange(of: theme) { _, _ in AppTheme.applySaved() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startsAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
