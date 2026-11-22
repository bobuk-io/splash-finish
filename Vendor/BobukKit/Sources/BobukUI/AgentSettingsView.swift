import AppKit
import BobukCore
import SwiftUI

/// Reusable Settings controls for choosing an ACP agent, model, reasoning effort, and sandbox mode.
/// Drop inside a `ThemedSection("AI Agent", tokens:)` or host standalone via `AgentSettingsWindowController`.
public struct AgentSettingsSection: View {
    @Bindable private var preferences: AgentChatPreferences
    private let tokens: ThemeTokens
    private let agents: [ACPAgentPreset]
    private let showsSandbox: Bool
    private let autoProbe: Bool

    @State private var statuses: [ACPAgentStatus] = []
    @State private var probedModels: ACPModels?
    @State private var probedEfforts: ACPModels?
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var isInstallingAdapter = false
    @State private var installError: String?

    private static let fallbackEfforts: [(id: String, name: String)] = [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
    ]

    public init(
        preferences: AgentChatPreferences,
        tokens: ThemeTokens,
        agents: [ACPAgentPreset] = ACPAgentPreset.all,
        showsSandbox: Bool = true,
        autoProbe: Bool = true
    ) {
        self.preferences = preferences
        self.tokens = tokens
        self.agents = agents
        self.showsSandbox = showsSandbox
        self.autoProbe = autoProbe
    }

    private var palette: PickerPalette { tokens.pickerPalette() }

    private var selectedStatus: ACPAgentStatus? {
        statuses.first(where: { $0.id == preferences.agent.id })
    }

    private var effortOptions: [(id: String, name: String)] {
        if let probedEfforts, !probedEfforts.choices.isEmpty {
            return probedEfforts.choices.map { ($0.id, $0.name) }
        }
        return Self.fallbackEfforts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            agentRow

            if let status = selectedStatus, status.needsACPAdapter, let cmd = preferences.agent.adapterInstallCommand {
                adapterBanner(command: cmd)
            }

            modelRow
            effortRow

            if let probeError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.dangerColor)
                        .padding(.top, 1)
                    Text(probeError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.dangerColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsSandbox {
                Divider()
                Toggle(isOn: $preferences.sandboxed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run agent in sandbox")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Restricts filesystem access outside the opened folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedColor)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .task(id: agents.map(\.id)) {
            await refreshStatuses()
            if autoProbe { await probeSelectedAgent() }
        }
        .onChange(of: preferences.agent) { _, _ in
            probedModels = nil
            probedEfforts = nil
            probeError = nil
            installError = nil
            if autoProbe {
                Task { await probeSelectedAgent() }
            }
        }
    }

    // MARK: - Rows

    private var agentRow: some View {
        HStack(spacing: 10) {
            Text("Agent")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tokens.mutedColor)
                .frame(width: 64, alignment: .leading)

            Menu {
                let ready = statuses.filter(\.isReady)
                let needsAdapter = statuses.filter(\.needsACPAdapter)
                let unavailable = statuses.filter { !$0.isReady && !$0.needsACPAdapter }

                if !ready.isEmpty {
                    Section("Available") {
                        ForEach(ready) { status in
                            agentChoiceButton(status.preset, suffix: nil)
                        }
                    }
                }
                if !needsAdapter.isEmpty {
                    Section("Needs ACP Adapter") {
                        ForEach(needsAdapter) { status in
                            agentChoiceButton(status.preset, suffix: "install adapter")
                        }
                    }
                }
                if !unavailable.isEmpty {
                    Section("Not Installed") {
                        ForEach(unavailable) { status in
                            agentChoiceButton(status.preset, suffix: "not installed")
                        }
                    }
                }
                if statuses.isEmpty {
                    ForEach(agents) { preset in
                        agentChoiceButton(preset, suffix: nil)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(preferences.agent.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.inkColor)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.mutedColor)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(tokens.fieldColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tokens.strokeColor, lineWidth: 1)
                }
            }
            .menuStyle(.borderlessButton)

            Button {
                Task {
                    await refreshStatuses()
                    await probeSelectedAgent()
                }
            } label: {
                if isProbing {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                } else {
                    GlyphImage(.reload, size: 12)
                        .foregroundStyle(tokens.mutedColor)
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.plain)
            .disabled(isProbing)
            .help("Refresh available agents and models")
            .accessibilityLabel("Refresh models")
        }
    }

    private func agentChoiceButton(_ preset: ACPAgentPreset, suffix: String?) -> some View {
        Button {
            preferences.agent = preset
        } label: {
            let title = suffix.map { "\(preset.name) (\($0))" } ?? preset.name
            if preset == preferences.agent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var modelRow: some View {
        HStack(spacing: 10) {
            Text("Model")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tokens.mutedColor)
                .frame(width: 64, alignment: .leading)

            if let choices = probedModels?.choices, !choices.isEmpty {
                Menu {
                    Button {
                        preferences.model = nil
                    } label: {
                        if preferences.model == nil {
                            Label("CLI default", systemImage: "checkmark")
                        } else {
                            Text("CLI default")
                        }
                    }
                    Divider()
                    ForEach(choices) { choice in
                        Button {
                            preferences.model = choice.id
                        } label: {
                            if preferences.model == choice.id {
                                Label(choice.name, systemImage: "checkmark")
                            } else {
                                Text(choice.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentModelDisplayName(choices: choices))
                            .font(.system(size: 12.5))
                            .foregroundStyle(tokens.inkColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tokens.mutedColor)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(tokens.fieldColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tokens.strokeColor, lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
            } else {
                HStack(spacing: 6) {
                    Text(isProbing ? "Loading models…" : (preferences.model ?? "CLI default"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(tokens.mutedColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(tokens.fieldColor.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tokens.lineColor, lineWidth: 1)
                }
            }
        }
    }

    private var effortRow: some View {
        HStack(spacing: 10) {
            Text("Effort")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tokens.mutedColor)
                .frame(width: 64, alignment: .leading)

            HStack(spacing: 4) {
                let activeEffort = (preferences.effort ?? probedEfforts?.current ?? "medium").lowercased()
                ForEach(effortOptions, id: \.id) { option in
                    let isSelected = option.id.lowercased() == activeEffort
                    Button {
                        preferences.effort = option.id
                    } label: {
                        Text(option.name)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? tokens.keyInkColor : tokens.inkColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(
                                isSelected ? tokens.accentColor : tokens.fieldColor,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay {
                                if !isSelected {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(tokens.lineColor, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func adapterBanner(command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(preferences.agent.name) needs its ACP adapter:")
                .font(.system(size: 11.5, weight: .medium))
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.mutedColor)
                .textSelection(.enabled)
            if let installError {
                Text(installError)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.dangerColor)
            }
            HStack(spacing: 8) {
                if isInstallingAdapter {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.system(size: 11.5)).foregroundStyle(tokens.mutedColor)
                } else {
                    Button("Install ACP Adapter") {
                        isInstallingAdapter = true
                        installError = nil
                        let preset = preferences.agent
                        Task {
                            do {
                                _ = try await preset.installACPAdapter()
                                await MainActor.run { isInstallingAdapter = false }
                                await refreshStatuses()
                                await probeSelectedAgent()
                            } catch {
                                await MainActor.run {
                                    isInstallingAdapter = false
                                    installError = error.localizedDescription
                                }
                            }
                        }
                    }
                    .buttonStyle(QuietButtonStyle(palette: palette, prominent: true, height: 24))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.accentSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        guard let status = selectedStatus else { return tokens.mutedColor }
        if status.isReady { return tokens.successColor }
        if status.needsACPAdapter { return tokens.accentColor }
        return tokens.dangerColor
    }

    private func currentModelDisplayName(choices: [ACPModels.Choice]) -> String {
        if let selected = preferences.model,
           let match = choices.first(where: { $0.id == selected }) {
            return match.name
        }
        if let selected = preferences.model { return selected }
        if let current = probedModels?.current,
           let match = choices.first(where: { $0.id == current }) {
            return "\(match.name) (default)"
        }
        return "CLI default"
    }

    private func refreshStatuses() async {
        let list = agents
        let detected = await Task.detached(priority: .utility) {
            ACPAgentPreset.detectAll(in: list)
        }.value
        statuses = detected
    }

    private func probeSelectedAgent() async {
        let preset = preferences.agent
        let sandboxed = preferences.sandboxed
        let installed = await Task.detached(priority: .utility) {
            preset.isInstalled()
        }.value
        guard installed else {
            probedModels = nil
            probedEfforts = nil
            probeError = nil
            return
        }
        isProbing = true
        probeError = nil
        do {
            let result = try await preset.probeCapabilities(sandboxed: sandboxed)
            guard preferences.agent == preset else { return }
            probedModels = result.models
            probedEfforts = result.efforts
            if preferences.model == nil, let current = result.models?.current, !current.isEmpty {
                preferences.model = current
            }
            if preferences.effort == nil, let current = result.efforts?.current, !current.isEmpty {
                preferences.effort = current
            }
            isProbing = false
        } catch {
            guard preferences.agent == preset else { return }
            isProbing = false
            probeError = error.localizedDescription
        }
    }
}

/// Standalone `ChromeWindow` picker for configuring ACP agent, model, effort, and sandbox mode.
@MainActor public final class AgentSettingsWindowController {
    public let preferences: AgentChatPreferences
    private let theme: ThemeStore
    private let title: String
    private let frameName: String
    private let agents: [ACPAgentPreset]
    private let showsSandbox: Bool
    private var controller: HostedWindowController?

    public init(
        title: String = "AI Agent",
        frameName: String = "AgentSettings",
        agents: [ACPAgentPreset] = ACPAgentPreset.all,
        showsSandbox: Bool = true,
        preferences: AgentChatPreferences? = nil,
        theme: ThemeStore
    ) {
        self.title = title
        self.frameName = frameName
        self.agents = agents
        self.showsSandbox = showsSandbox
        self.preferences = preferences ?? AgentChatPreferences(agents: agents)
        self.theme = theme
    }

    public func show() {
        if controller == nil {
            controller = HostedWindowController(
                frameName: frameName,
                releasesContentOnClose: true,
                window: { [unowned self] in
                    let size = ChromeMetrics.windowSize(forBody: NSSize(width: 440, height: 280))
                    let win = ChromeWindow(
                        contentRect: NSRect(origin: .zero, size: size),
                        theme: theme,
                        resizable: false,
                        showsTitle: true
                    )
                    win.title = title
                    return win
                },
                rootView: { [unowned self] in
                    VStack(alignment: .leading, spacing: 14) {
                        ThemedSection("AI Agent", tokens: theme.tokens) {
                            AgentSettingsSection(
                                preferences: preferences,
                                tokens: theme.tokens,
                                agents: agents,
                                showsSandbox: showsSandbox
                            )
                        }
                    }
                    .padding(20)
                    .frame(width: 440)
                    .fixedSize(horizontal: false, vertical: true)
                    .themedSurface(theme)
                }
            )
            controller?.sizesToFitContent = true
        }
        controller?.show()
    }

    public func close() {
        controller?.close()
    }
}
