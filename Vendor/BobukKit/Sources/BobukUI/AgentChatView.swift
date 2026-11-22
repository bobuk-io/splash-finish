import BobukCore
import SwiftUI

/// Text-only chat state shared by apps; the app owns the prompt and interprets complete replies.
@MainActor @Observable public final class AgentChatSession {
    public enum Phase: Equatable { case disconnected, connecting, ready, switching, replying, stopping }
    public struct Message: Identifiable {
        public let id = UUID()
        public let isUser: Bool
        public fileprivate(set) var text: String
    }

    public private(set) var phase = Phase.disconnected
    public private(set) var models: ACPModels?
    public private(set) var messages: [Message] = []
    public private(set) var lastReply: String?
    public private(set) var error: String?
    public var draft = ""

    private var client: ACPClient?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    private var generation = 0
    private let makeClient: () throws -> ACPClient
    private let preparePrompt: (String) -> String
    private let displayReply: (String) -> String
    private let missingModelsMessage: String?

    /// Supply `missingModelsMessage` for agents that cannot answer without a model catalog.
    public init(makeClient: @escaping () throws -> ACPClient, preparePrompt: @escaping (String) -> String = { $0 },
                displayReply: @escaping (String) -> String = { $0 }, missingModelsMessage: String? = nil) {
        self.makeClient = makeClient
        self.preparePrompt = preparePrompt
        self.displayReply = displayReply
        self.missingModelsMessage = missingModelsMessage
    }

    public var canSend: Bool {
        phase == .ready && modelProblem == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate var needsModelCatalog: Bool { missingModelsMessage != nil && models?.choices.isEmpty != false }

    fileprivate var modelProblem: String? {
        if needsModelCatalog { return missingModelsMessage }
        return missingModelsMessage != nil && models?.current.isEmpty == true ? "Choose a model before sending." : nil
    }

    public func connect() {
        guard phase == .disconnected else { return }
        error = nil
        phase = .connecting
        generation += 1
        let serial = generation
        do {
            let client = try makeClient()
            self.client = client
            Task {
                do {
                    let models = try await client.connect { [weak self] models in await self?.update(models, serial: serial) }
                    guard serial == generation else { return }
                    self.models = models
                    phase = .ready
                } catch { await failed(error, serial: serial) }
            }
        } catch {
            phase = .disconnected
            self.error = error.localizedDescription
        }
    }

    public func selectModel(_ id: String) {
        guard phase == .ready, let client, id != models?.current else { return }
        let serial = generation
        phase = .switching
        error = nil
        Task {
            do {
                let models = try await client.selectModel(id)
                guard serial == generation else { return }
                self.models = models
                phase = .ready
            } catch { await failed(error, serial: serial) }
        }
    }

    public func send() {
        guard canSend, let client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = preparePrompt(text)
        guard prompt.utf8.count <= ACPClient.maxPromptBytes else {
            error = ACPError.promptTooLarge.localizedDescription
            return
        }
        let serial = generation
        phase = .replying
        error = nil
        lastReply = nil
        draft = ""
        messages.append(Message(isUser: true, text: text))
        messages.append(Message(isUser: false, text: ""))
        let replyID = messages[messages.count - 1].id
        replyTask = Task {
            do {
                let reason = try await client.prompt(prompt) { [weak self] chunk in
                    await self?.append(chunk, to: replyID, serial: serial)
                }
                guard serial == generation else { return }
                let reply = messages.last?.text ?? ""
                if phase != .stopping {
                    if reason == "end_turn", !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastReply = reply
                        messages[messages.count - 1].text = displayReply(reply)
                    } else if reason != "cancelled" {
                        error = reply.isEmpty ? "The agent did not return a reply. Try again." : "The agent stopped before completing its reply."
                    }
                }
                discardEmptyReply()
                phase = .ready
            } catch is CancellationError {
                guard serial == generation else { return }
                discardEmptyReply()
                phase = .ready
            } catch {
                if serial == generation { discardEmptyReply() }
                await failed(error, serial: serial)
            }
        }
    }

    public func stop() {
        guard phase == .replying, let client else { return }
        phase = .stopping
        replyTask?.cancel()
        Task { await client.cancel() }
    }

    /// Dismiss the connection without sending or retaining any more chat data.
    public func disconnect() {
        if let client = reset() { Task { await client.close() } }
    }

    fileprivate func reconnect() {
        let message = draft
        let previous = reset()
        draft = message
        let serial = generation
        phase = .connecting
        Task {
            await previous?.close()
            guard generation == serial else { return }
            phase = .disconnected
            connect()
        }
    }

    public func shutdown() async {
        if let client = reset() { await client.close() }
    }

    private func reset() -> ACPClient? {
        generation += 1
        replyTask?.cancel()
        replyTask = nil
        let old = client
        client = nil
        models = nil
        phase = .disconnected
        error = nil
        draft = ""
        messages.removeAll()
        lastReply = nil
        return old
    }

    private func update(_ models: ACPModels?, serial: Int) {
        if serial == generation { self.models = models }
    }

    private func append(_ chunk: String, to id: UUID, serial: Int) {
        guard serial == generation, phase == .replying, messages.last?.id == id else { return }
        messages[messages.count - 1].text += chunk
    }

    private func discardEmptyReply() {
        if let last = messages.last, !last.isUser, last.text.isEmpty { messages.removeLast() }
    }

    private func failed(_ error: Error, serial: Int) async {
        guard serial == generation else { return }
        let failedClient = client
        client = nil
        models = nil
        phase = .disconnected
        self.error = error.localizedDescription
        await failedClient?.close()
    }
}

private struct ChatColors {
    let panel: Color
    let elevated: Color
    let field: Color
    let ink: Color
    let muted: Color
    let accent: Color
    let accentSurface: Color
    let keyInk: Color
    let line: Color
    let stroke: Color
    let success: Color
    let danger: Color
    let isDark: Bool
    let palette: PickerPalette

    init(tokens: ThemeTokens) {
        panel = tokens.panelColor
        elevated = tokens.elevatedColor
        field = tokens.fieldColor
        ink = tokens.inkColor
        muted = tokens.mutedColor
        accent = tokens.accentColor
        accentSurface = tokens.accentSurfaceColor
        keyInk = tokens.keyInkColor
        line = tokens.lineColor
        stroke = tokens.strokeColor
        success = tokens.successColor
        danger = tokens.dangerColor
        isDark = tokens.isDark
        palette = tokens.pickerPalette()
    }

    init(palette: PickerPalette) {
        let surface = Color(nsColor: palette.surface)
        let accent = Color(nsColor: palette.accent)
        let border = Color(nsColor: palette.border)
        panel = surface
        elevated = border.opacity(0.18)
        field = surface
        ink = Color(nsColor: palette.text)
        muted = Color(nsColor: palette.secondary)
        self.accent = accent
        accentSurface = accent.opacity(0.12)
        keyInk = Color(nsColor: palette.badgeInk)
        line = border.opacity(0.55)
        stroke = border
        success = Color(nsColor: .systemGreen)
        danger = Color(nsColor: .systemRed)
        isDark = false
        self.palette = palette
    }
}

/// Minimalist, editorial text-only chat surface backed by `AgentChatSession`.
public struct AgentChatView: View {
    @Bindable private var session: AgentChatSession
    @FocusState private var composerFocused: Bool
    private let emptyTitle: String
    private let agent: String
    private let intro: String
    private let placeholder: String
    private let starters: [String]
    private let sandboxed: Binding<Bool>?
    private let colors: ChatColors

    public init(
        session: AgentChatSession,
        agent: String,
        intro: String,
        emptyTitle: String = "How can I help?",
        placeholder: String = "Message…",
        starters: [String] = [],
        sandboxed: Binding<Bool>? = nil,
        tokens: ThemeTokens
    ) {
        self.session = session
        self.agent = agent
        self.intro = intro
        self.emptyTitle = emptyTitle
        self.placeholder = placeholder
        self.starters = starters
        self.sandboxed = sandboxed
        self.colors = ChatColors(tokens: tokens)
    }

    public init(
        session: AgentChatSession,
        title: String,
        agent: String,
        intro: String,
        starters: [String] = [],
        sandboxed: Binding<Bool>? = nil,
        palette: PickerPalette
    ) {
        self.session = session
        self.agent = agent
        self.intro = intro
        self.emptyTitle = title
        self.placeholder = "Message…"
        self.starters = starters
        self.sandboxed = sandboxed
        self.colors = ChatColors(palette: palette)
    }

    private var isStreaming: Bool { session.phase == .replying || session.phase == .stopping }
    private var activeError: String? { session.error ?? (session.phase == .ready ? session.modelProblem : nil) }

    public var body: some View {
        VStack(spacing: 0) {
            if session.messages.isEmpty {
                emptyCanvas
            } else {
                transcript
            }

            if let message = activeError {
                recoveryBanner(message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            composer
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.panel)
        .foregroundStyle(colors.ink)
        .onChange(of: session.phase) { _, new in
            if new == .ready { composerFocused = true }
        }
    }

    // MARK: - Empty state

    private var emptyCanvas: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(colors.accent)
                    .frame(width: 36, height: 36)
                    .background(colors.accentSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                Text(emptyTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)

                Text(intro)
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if !starters.isEmpty {
                VStack(spacing: 6) {
                    ForEach(starters, id: \.self) { text in
                        starterChip(text)
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func starterChip(_ text: String) -> some View {
        Button {
            session.draft = text
            composerFocused = true
        } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colors.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 340, minHeight: 32, maxHeight: 32)
            .background(colors.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(colors.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editorial thread

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(session.messages) { message in
                        if message.isUser {
                            userTurn(message)
                        } else {
                            assistantTurn(message, streaming: isStreaming && message.id == session.messages.last?.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("chat-end").accessibilityHidden(true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                reader.scrollTo("chat-end", anchor: .bottom)
            }
        }
    }

    private func userTurn(_ message: AgentChatSession.Message) -> some View {
        HStack(spacing: 0) {
            Text(message.text)
                .font(.system(size: 13.5))
                .lineSpacing(3.5)
                .foregroundStyle(colors.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(colors.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(colors.line, lineWidth: 1)
                }
            Spacer(minLength: 36)
        }
    }

    private func assistantTurn(_ message: AgentChatSession.Message, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 13.5))
                .lineSpacing(4.5)
                .foregroundStyle(colors.ink)
                .textSelection(.enabled)

            if streaming {
                HStack(spacing: 6) {
                    Circle()
                        .fill(colors.accent)
                        .frame(width: 6, height: 6)
                    MonoLabel(streamingStatus)
                        .foregroundStyle(colors.muted)
                }
                .padding(.top, 2)
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var streamingStatus: String {
        if session.phase == .stopping { return "STOPPING" }
        if let name = currentModelName { return "GENERATING · \(name.uppercased())" }
        return "GENERATING"
    }

    // MARK: - Recovery banner

    private func recoveryBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(colors.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if session.phase == .disconnected {
                Button("Retry") { session.connect() }
                    .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 24))
            } else if session.needsModelCatalog {
                Button("Reconnect") { session.reconnect() }
                    .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 24))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(colors.danger.opacity(colors.isDark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(colors.danger.opacity(0.32), lineWidth: 1)
        }
    }

    // MARK: - Unified floating composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(isStreaming ? "Waiting for reply…" : placeholder, text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...5)
                .focused($composerFocused)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)

            HStack(spacing: 8) {
                agentModelControl

                if let sandboxed {
                    sandboxControl(sandboxed)
                }

                Spacer(minLength: 4)

                composerAction
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background(colors.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(session.canSend ? colors.accent.opacity(0.55) : colors.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder private var agentModelControl: some View {
        if session.phase == .disconnected || session.phase == .connecting {
            agentPillLabel(showChevron: false)
        } else {
            Menu {
                if let models = session.models, !models.choices.isEmpty {
                    Section("Model") {
                        ForEach(models.choices) { choice in
                            Button { session.selectModel(choice.id) } label: {
                                if choice.id == models.current {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("Disconnect", role: .destructive) { session.disconnect() }
            } label: {
                agentPillLabel(showChevron: true)
            }
            .menuStyle(.borderlessButton)
            .layoutPriority(0)
            .disabled(session.phase != .ready)
            .accessibilityLabel(currentModelName.map { "\(agent), model \($0)" } ?? agent)
        }
    }

    private func agentPillLabel(showChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(agent)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(colors.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let subtitle = pillSubtitle {
                Text("·")
                    .foregroundStyle(colors.muted)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if showChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(colors.muted)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(colors.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(colors.line, lineWidth: 1)
        }
    }

    private var statusDotColor: Color {
        if activeError != nil { return colors.danger }
        switch session.phase {
        case .disconnected: return colors.muted.opacity(0.6)
        case .connecting, .switching: return colors.accent
        case .ready, .replying, .stopping: return colors.success
        }
    }

    private var currentModelName: String? {
        guard let models = session.models else { return nil }
        if let found = models.choices.first(where: { $0.id == models.current }) { return found.name }
        return models.current.isEmpty ? nil : models.current
    }

    private var pillSubtitle: String? {
        switch session.phase {
        case .disconnected: return nil
        case .connecting: return "Connecting…"
        case .switching: return "Switching…"
        case .ready, .replying, .stopping:
            if let name = currentModelName { return name }
            return session.needsModelCatalog ? "No model" : "CLI default"
        }
    }

    private func sandboxControl(_ binding: Binding<Bool>) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            if binding.wrappedValue {
                HStack(spacing: 4) {
                    GlyphImage(.lock, size: 10.5)
                        .foregroundStyle(colors.muted)
                    Text("Sandbox")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.muted)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                    Text("No sandbox")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(colors.danger)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(colors.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .disabled(session.phase != .disconnected)
        .help(session.phase == .disconnected
              ? (binding.wrappedValue ? "Agent runs in a restricted sandbox." : "Without a sandbox, the agent can access files and run commands as you.")
              : "Disconnect to change sandbox mode.")
        .accessibilityLabel(binding.wrappedValue ? "Sandbox enabled" : "Sandbox disabled")
    }

    @ViewBuilder private var composerAction: some View {
        switch session.phase {
        case .disconnected:
            Button("Connect") { session.connect() }
                .buttonStyle(QuietButtonStyle(palette: colors.palette, prominent: true, height: 26))
        case .connecting:
            ProgressView().controlSize(.small)
            Button("Cancel") { session.disconnect() }
                .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 26))
        case .switching:
            ProgressView().controlSize(.small)
        case .replying, .stopping:
            Text("esc")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.muted.opacity(0.85))
            Button { session.stop() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(colors.danger)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(session.phase == .stopping)
            .accessibilityLabel("Stop generating")
        case .ready:
            Text("⌘↩")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.muted.opacity(0.85))
            Button { session.send() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(session.canSend ? colors.accent : colors.elevated)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.canSend ? colors.keyInk : colors.muted)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!session.canSend)
            .accessibilityLabel("Send message")
        }
    }
}
