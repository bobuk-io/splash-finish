// Reusable SwiftUI theming modifiers, section cards, preview swatch and Settings controls for bobuk-io apps.
import AppKit
import BobukCore
import SwiftUI

public extension View {
    /// Applies a theme's panel surface, primary text color and accent tint across the view hierarchy,
    /// hiding default scroll backgrounds so the panel color fills the window.
    func themedSurface(_ tokens: ThemeTokens) -> some View {
        self
            .scrollContentBackground(.hidden)
            .foregroundStyle(tokens.inkColor)
            .tint(tokens.accentColor)
            .background(tokens.panelColor)
    }

    /// Convenience overload reading live tokens from a `ThemeStore`.
    @MainActor func themedSurface(_ theme: ThemeStore) -> some View {
        themedSurface(theme.tokens)
    }
}

/// A themed settings/content card: tracked mono header over an elevated surface with a hairline border.
public struct ThemedSection<Content: View>: View {
    private let title: String?
    private let tokens: ThemeTokens
    private let content: Content

    public init(_ title: String? = nil, tokens: ThemeTokens, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tokens = tokens
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                MonoLabel(title, size: 10, tracking: 1.4)
                    .foregroundStyle(tokens.mutedColor)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tokens.elevatedColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tokens.strokeColor, lineWidth: 1))
        }
    }
}

/// Compact swatch showing how a theme's accent bar, panel surface, ink, muted text and badge look.
public struct ThemePreview: View {
    public let tokens: ThemeTokens

    public init(tokens: ThemeTokens) {
        self.tokens = tokens
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(tokens.accentColor)
                .frame(height: 3)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Panel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.inkColor)
                    Text("Secondary")
                        .font(.system(size: 9))
                        .foregroundStyle(tokens.mutedColor)
                }
                Spacer(minLength: 8)
                Text("ACCENT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.keyInkColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(tokens.accentColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tokens.panelColor)
        }
        .frame(width: 210)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tokens.lineColor, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Form rows for apps that embed theme controls inside a native macOS grouped `Form` `Section`.
/// Shares the exact same presets, custom color pickers, live preview, contrast warning and reset
/// behavior as `ThemeSettingsSection`.
@MainActor public struct ThemeSettingsFormRows: View {
    @Bindable private var theme: ThemeStore
    private let offeredAppearances: [AppearanceChoice]
    private let presets: [ThemePreset]
    private let showsCustomColors: Bool
    @State private var editingDark: Bool

    public init(theme: ThemeStore,
                offeredAppearances: [AppearanceChoice] = AppearanceChoice.allCases,
                presets: [ThemePreset] = ThemePreset.all,
                showsCustomColors: Bool = true) {
        self.theme = theme
        self.offeredAppearances = offeredAppearances
        self.presets = presets
        self.showsCustomColors = showsCustomColors
        _editingDark = State(initialValue: theme.isDark)
    }

    private var activeEditingDark: Bool {
        switch theme.appearance {
        case .light: false
        case .dark: true
        case .system: editingDark
        }
    }

    private var editedColors: ThemeColors { theme.colors(dark: activeEditingDark) }
    private var editedTokens: ThemeTokens { theme.tokens(dark: activeEditingDark) }

    private var presetSelection: Binding<String> {
        Binding(
            get: {
                let id = editedColors.preset
                return presets.contains(where: { $0.id == id }) ? id : ThemeColors.customPresetID
            },
            set: { id in
                guard id != ThemeColors.customPresetID else { return }
                theme.applyPreset(id: id, in: presets)
            }
        )
    }

    private var panelColorBinding: Binding<Color> {
        Binding(
            get: { editedTokens.panelColor },
            set: { color in
                guard let rgb = NSColor(color).rgb else { return }
                theme.setPanel(rgb, dark: activeEditingDark)
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { editedTokens.accentColor },
            set: { color in
                guard let rgb = NSColor(color).rgb else { return }
                theme.setAccent(rgb, dark: activeEditingDark)
            }
        )
    }

    public var body: some View {
        Group {
            Picker("Mode", selection: $theme.appearance) {
                ForEach(offeredAppearances) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: presetSelection) {
                ForEach(presets) { preset in
                    Text(preset.title).tag(preset.id)
                }
                if editedColors.preset == ThemeColors.customPresetID {
                    Divider()
                    Text("Custom").tag(ThemeColors.customPresetID)
                }
            }

            if showsCustomColors {
                if theme.appearance == .system {
                    Picker("Customize", selection: $editingDark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                ColorPicker("Panel", selection: panelColorBinding, supportsOpacity: false)
                ColorPicker("Accent", selection: accentColorBinding, supportsOpacity: false)
            }

            LabeledContent("Preview") {
                ThemePreview(tokens: editedTokens)
            }

            if editedTokens.lowAccentContrast {
                Label("The accent color is hard to see on this panel.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(editedTokens.dangerColor)
            }

            HStack {
                Spacer()
                Button("Reset to \(theme.defaultPreset.title)") {
                    theme.resetPalette()
                }
                .disabled(theme.isDefaultPalette)
            }
        }
        .onChange(of: theme.appearance) { _, next in
            switch next {
            case .light: editingDark = false
            case .dark: editingDark = true
            case .system: editingDark = theme.isDark
            }
        }
    }
}

/// Drop-in Settings card for Appearance mode, Theme preset selection, custom colors, preview and reset.
@MainActor public struct ThemeSettingsSection: View {
    @Bindable private var theme: ThemeStore
    private let title: String
    private let offeredAppearances: [AppearanceChoice]
    private let presets: [ThemePreset]
    private let showsCustomColors: Bool
    @State private var editingDark: Bool

    public init(theme: ThemeStore,
                title: String = "Appearance",
                offeredAppearances: [AppearanceChoice] = AppearanceChoice.allCases,
                presets: [ThemePreset] = ThemePreset.all,
                showsCustomColors: Bool = true) {
        self.theme = theme
        self.title = title
        self.offeredAppearances = offeredAppearances
        self.presets = presets
        self.showsCustomColors = showsCustomColors
        _editingDark = State(initialValue: theme.isDark)
    }

    private var activeEditingDark: Bool {
        switch theme.appearance {
        case .light: false
        case .dark: true
        case .system: editingDark
        }
    }

    private var editedColors: ThemeColors {
        theme.colors(dark: activeEditingDark)
    }

    private var editedTokens: ThemeTokens {
        theme.tokens(dark: activeEditingDark)
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: {
                let id = editedColors.preset
                return presets.contains(where: { $0.id == id }) ? id : ThemeColors.customPresetID
            },
            set: { id in
                guard id != ThemeColors.customPresetID else { return }
                theme.applyPreset(id: id, in: presets)
            }
        )
    }

    private var panelColorBinding: Binding<Color> {
        Binding(
            get: { editedTokens.panelColor },
            set: { color in
                guard let rgb = NSColor(color).rgb else { return }
                theme.setPanel(rgb, dark: activeEditingDark)
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { editedTokens.accentColor },
            set: { color in
                guard let rgb = NSColor(color).rgb else { return }
                theme.setAccent(rgb, dark: activeEditingDark)
            }
        )
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.tokens.inkColor)
            Spacer(minLength: 12)
            control()
        }
    }

    public var body: some View {
        let tokens = theme.tokens
        let palette = theme.pickerPalette
        ThemedSection(title, tokens: tokens) {
            row("Mode") {
                Picker("Mode", selection: $theme.appearance) {
                    ForEach(offeredAppearances) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            Rectangle().fill(tokens.strokeColor).frame(height: 1)

            row("Theme") {
                Picker("Theme", selection: presetSelection) {
                    ForEach(presets) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                    if editedColors.preset == ThemeColors.customPresetID {
                        Divider()
                        Text("Custom").tag(ThemeColors.customPresetID)
                    }
                }
                .labelsHidden()
                .frame(width: 210, alignment: .trailing)
            }

            if showsCustomColors {
                if theme.appearance == .system {
                    row("Customize") {
                        Picker("Customize", selection: $editingDark) {
                            Text("Light").tag(false)
                            Text("Dark").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                }

                Rectangle().fill(tokens.strokeColor).frame(height: 1)

                HStack(spacing: 16) {
                    ColorPicker("Panel", selection: panelColorBinding, supportsOpacity: false)
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    ColorPicker("Accent", selection: accentColorBinding, supportsOpacity: false)
                        .font(.system(size: 13))
                }
            }

            Rectangle().fill(tokens.strokeColor).frame(height: 1)

            row("Preview") {
                ThemePreview(tokens: editedTokens)
            }

            if editedTokens.lowAccentContrast {
                Label("The accent color is hard to see on this panel.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(editedTokens.dangerColor)
            }

            HStack {
                Spacer()
                Button("Reset to \(theme.defaultPreset.title)") {
                    theme.resetPalette()
                }
                .buttonStyle(QuietButtonStyle(palette: palette, height: 26))
                .disabled(theme.isDefaultPalette)
            }
        }
        .onChange(of: theme.appearance) { _, next in
            switch next {
            case .light: editingDark = false
            case .dark: editingDark = true
            case .system: editingDark = theme.isDark
            }
        }
    }
}
