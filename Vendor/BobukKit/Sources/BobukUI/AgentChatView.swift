import BobukCore
import SwiftUI

/// Text-only chat state shared by apps; the app owns the prompt and interprets complete replies.
@MainActor @Observable public final class AgentChatSession {
    public enum Phase: Equatable { case disconnected, connecting, ready, switching, replying, stopping }
    public enum ToolAccessChoice: Equatable, Sendable {
        case allowAlways
        case allowForSession
        case deny
    }
    public struct PendingToolApproval: Equatable, Sendable {
        public let toolName: String?
        public let promptText: String
    }
    public struct Message: Identifiable {
        public let id = UUID()
        public let isUser: Bool
        public fileprivate(set) var text: String
    }

    public private(set) var phase = Phase.disconnected
    public private(set) var models: ACPModels?
    public private(set) var efforts: ACPModels?
    public private(set) var messages: [Message] = []
    public private(set) var lastReply: String?
    public private(set) var activeTool: String?
    public private(set) var error: String?
    /// Non-nil when the agent tried to call a tool while tools were disabled and the app wants
    /// to ask the user whether to allow tools always, for this session, or not at all.
    public private(set) var pendingToolApproval: PendingToolApproval?
    /// True when the subprocess was closed automatically after `idleTimeout` of inactivity.
    public private(set) var disconnectedForInactivity = false
    /// When set to a positive duration, closes the idle agent subprocess after that much inactivity
    /// in `.ready` state while keeping the visible transcript and draft intact. `nil` disables it.
    public var idleTimeout: Duration? {
        didSet { rescheduleIdleTimer() }
    }
    /// Called after the agent subprocess is closed due to `idleTimeout`.
    @ObservationIgnored public var onIdleDisconnect: (() -> Void)?
    public var draft = ""

    private var client: ACPClient?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChunks = ""
    @ObservationIgnored private var pendingReplyID: UUID?
    @ObservationIgnored private var declinedToolsInSession = false
    private var generation = 0
    private let makeClient: () throws -> ACPClient
    private let preparePrompt: (String) -> String
    private let displayReply: (String) -> String
    private let missingModelsMessage: String?
    private let requiresModelCatalog: () -> Bool
    private let onToolAccessChoice: ((ToolAccessChoice) -> Void)?
    public var initialModel: String?
    public var initialEffort: String?

    /// Supply `missingModelsMessage` for agents that cannot answer without a model catalog.
    /// Pass `requiresModelCatalog` when switching between agents with different catalog behavior.
    /// Pass `initialModel` / `initialEffort` to pre-select a model and reasoning effort on connect.
    /// Pass `idleTimeout` to automatically terminate an idle agent subprocess after inactivity.
    /// Pass `onToolAccessChoice` to show an inline Allow Always / This Session / Don't Allow prompt
    /// the first time an agent attempts to call a tool in a text-only session.
    public init(makeClient: @escaping () throws -> ACPClient, preparePrompt: @escaping (String) -> String = { $0 },
                displayReply: @escaping (String) -> String = { $0 }, missingModelsMessage: String? = nil,
                requiresModelCatalog: (() -> Bool)? = nil,
                initialModel: String? = nil, initialEffort: String? = nil,
                idleTimeout: Duration? = nil,
                onToolAccessChoice: ((ToolAccessChoice) -> Void)? = nil) {
        self.makeClient = makeClient
        self.preparePrompt = preparePrompt
        self.displayReply = displayReply
        self.missingModelsMessage = missingModelsMessage
        self.requiresModelCatalog = requiresModelCatalog ?? { missingModelsMessage != nil }
        self.initialModel = initialModel
        self.initialEffort = initialEffort
        self.idleTimeout = idleTimeout
        self.onToolAccessChoice = onToolAccessChoice
    }

    public var canSend: Bool {
        phase == .ready && modelProblem == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate var needsModelCatalog: Bool {
        missingModelsMessage != nil && requiresModelCatalog() && models?.choices.isEmpty != false
    }

    fileprivate var modelProblem: String? {
        if needsModelCatalog { return missingModelsMessage }
        return missingModelsMessage != nil && requiresModelCatalog() && models?.current.isEmpty == true
            ? "Choose a model before sending." : nil
    }

    public func connect() {
        guard phase == .disconnected else { return }
        cancelIdleTimer()
        disconnectedForInactivity = false
        error = nil
        phase = .connecting
        generation += 1
        let serial = generation
        do {
            let client = try makeClient()
            self.client = client
            Task {
                do {
                    var models = try await client.connect(
                        onModels: { [weak self] models in await self?.update(models, serial: serial) },
                        onEfforts: { [weak self] efforts in await self?.updateEfforts(efforts, serial: serial) }
                    )
                    if let initialModel, !initialModel.isEmpty {
                        models = try await client.selectModel(initialModel)
                    }
                    if let initialEffort, !initialEffort.isEmpty {
                        _ = try await client.selectEffort(initialEffort)
                    }
                    let efforts = await client.effortOptions()
                    guard serial == generation else { return }
                    self.models = models
                    self.efforts = efforts
                    phase = .ready
                    rescheduleIdleTimer()
                } catch { await failed(error, serial: serial) }
            }
        } catch {
            phase = .disconnected
            self.error = error.localizedDescription
        }
    }

    /// Resets the inactivity countdown while the session is `.ready`.
    public func noteActivity() {
        guard phase == .ready else { return }
        rescheduleIdleTimer()
    }

    public func selectModel(_ id: String) {
        guard phase == .ready, let client, id != models?.current else { return }
        cancelIdleTimer()
        let serial = generation
        phase = .switching
        error = nil
        Task {
            do {
                let models = try await client.selectModel(id)
                let efforts = await client.effortOptions()
                guard serial == generation else { return }
                self.models = models
                self.efforts = efforts
                phase = .ready
                rescheduleIdleTimer()
            } catch { await failed(error, serial: serial) }
        }
    }

    public func selectEffort(_ id: String) {
        guard phase == .ready, let client, id != efforts?.current else { return }
        cancelIdleTimer()
        let serial = generation
        phase = .switching
        error = nil
        Task {
            do {
                _ = try await client.selectEffort(id)
                let efforts = await client.effortOptions()
                guard serial == generation else { return }
                self.efforts = efforts
                phase = .ready
                rescheduleIdleTimer()
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
        cancelIdleTimer()
        let serial = generation
        phase = .replying
        error = nil
        pendingToolApproval = nil
        lastReply = nil
        draft = ""
        messages.append(Message(isUser: true, text: text))
        startReply(userText: text, prompt: prompt, client: client, serial: serial)
    }

    private func startReply(userText: String, prompt: String, client: ACPClient, serial: Int) {
        messages.append(Message(isUser: false, text: ""))
        let replyID = messages[messages.count - 1].id
        replyTask = Task {
            do {
                let reason = try await client.prompt(prompt, onTool: { [weak self] tool in
                    await self?.setActiveTool(tool, serial: serial)
                }, onChunk: { [weak self] chunk in
                    await self?.append(chunk, to: replyID, serial: serial)
                })
                guard serial == generation else { return }
                flushChunks(serial: serial)
                activeTool = nil
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
                rescheduleIdleTimer()
            } catch is CancellationError {
                guard serial == generation else { return }
                flushChunks(serial: serial)
                activeTool = nil
                discardEmptyReply()
                phase = .ready
                rescheduleIdleTimer()
            } catch {
                let observedTool = activeTool
                if serial == generation {
                    flushChunks(serial: serial)
                    activeTool = nil
                    discardEmptyReply()
                }
                if let acpError = error as? ACPError,
                   acpError == .unexpectedTool,
                   onToolAccessChoice != nil,
                   !declinedToolsInSession {
                    await requestToolApproval(toolName: observedTool, promptText: userText, serial: serial)
                } else {
                    await failed(error, serial: serial)
                }
            }
        }
    }

    private func requestToolApproval(toolName: String?, promptText: String, serial: Int) async {
        guard serial == generation else { return }
        cancelIdleTimer()
        let failedClient = client
        client = nil
        models = nil
        phase = .disconnected
        disconnectedForInactivity = false
        activeTool = nil
        error = nil
        pendingToolApproval = PendingToolApproval(toolName: toolName, promptText: promptText)
        if let last = messages.last, !last.isUser {
            messages.removeLast()
        }
        await failedClient?.close()
    }

    /// Resolves a pending tool-access prompt. Allowing reconnects with updated capabilities and
    /// automatically retries the interrupted user message without duplicating it in the transcript.
    public func resolveToolApproval(_ choice: ToolAccessChoice) {
        guard let pending = pendingToolApproval else { return }
        pendingToolApproval = nil
        switch choice {
        case .allowAlways, .allowForSession:
            onToolAccessChoice?(choice)
            reconnectAndRetry(userText: pending.promptText)
        case .deny:
            declinedToolsInSession = true
            onToolAccessChoice?(.deny)
            connect()
        }
    }

    private func reconnectAndRetry(userText: String) {
        cancelIdleTimer()
        disconnectedForInactivity = false
        error = nil
        phase = .connecting
        generation += 1
        let serial = generation
        let previous = client
        client = nil
        models = nil
        Task {
            await previous?.close()
            guard serial == generation else { return }
            do {
                let nextClient = try makeClient()
                self.client = nextClient
                var models = try await nextClient.connect { [weak self] models in await self?.update(models, serial: serial) }
                if let initialModel, !initialModel.isEmpty {
                    models = try await nextClient.selectModel(initialModel)
                }
                if let initialEffort, !initialEffort.isEmpty {
                    _ = try await nextClient.selectEffort(initialEffort)
                }
                guard serial == generation else { return }
                self.models = models
                let prompt = preparePrompt(userText)
                guard prompt.utf8.count <= ACPClient.maxPromptBytes else {
                    phase = .ready
                    error = ACPError.promptTooLarge.localizedDescription
                    rescheduleIdleTimer()
                    return
                }
                phase = .replying
                lastReply = nil
                startReply(userText: userText, prompt: prompt, client: nextClient, serial: serial)
            } catch {
                await failed(error, serial: serial)
            }
        }
    }

    /// Reconnects with fresh launch capabilities (for example after toggling tools) while keeping
    /// the visible transcript and draft intact.
    public func reconnectKeepingTranscript() {
        cancelIdleTimer()
        replyTask?.cancel()
        replyTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingChunks.removeAll(keepingCapacity: false)
        pendingReplyID = nil
        let previous = client
        client = nil
        models = nil
        activeTool = nil
        error = nil
        pendingToolApproval = nil
        disconnectedForInactivity = false
        generation += 1
        let serial = generation
        phase = .connecting
        Task {
            await previous?.close()
            guard generation == serial else { return }
            phase = .disconnected
            connect()
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
        cancelIdleTimer()
        replyTask?.cancel()
        replyTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingChunks.removeAll(keepingCapacity: false)
        pendingReplyID = nil
        let old = client
        client = nil
        models = nil
        efforts = nil
        phase = .disconnected
        disconnectedForInactivity = false
        declinedToolsInSession = false
        pendingToolApproval = nil
        error = nil
        draft = ""
        messages.removeAll()
        lastReply = nil
        activeTool = nil
        return old
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func rescheduleIdleTimer() {
        cancelIdleTimer()
        guard phase == .ready, let timeout = idleTimeout, timeout > .zero else { return }
        let serial = generation
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expireIdle(serial: serial)
        }
    }

    private func expireIdle(serial: Int) async {
        guard serial == generation, phase == .ready else { return }
        idleTask = nil
        generation += 1
        let idleClient = client
        client = nil
        models = nil
        efforts = nil
        phase = .disconnected
        activeTool = nil
        disconnectedForInactivity = true
        onIdleDisconnect?()
        await idleClient?.close()
    }

    private func setActiveTool(_ tool: String?, serial: Int) {
        if serial == generation { activeTool = tool }
    }

    private func update(_ models: ACPModels?, serial: Int) {
        if serial == generation { self.models = models }
    }

    private func updateEfforts(_ efforts: ACPModels?, serial: Int) {
        if serial == generation { self.efforts = efforts }
    }

    private func append(_ chunk: String, to id: UUID, serial: Int) {
        guard serial == generation, phase == .replying, messages.last?.id == id else { return }
        pendingChunks += chunk
        pendingReplyID = id
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flushChunks(serial: serial)
        }
    }

    private func flushChunks(serial: Int) {
        flushTask?.cancel()
        flushTask = nil
        guard serial == generation, !pendingChunks.isEmpty else {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingReplyID = nil
            return
        }
        let delta = pendingChunks
        let id = pendingReplyID
        pendingChunks.removeAll(keepingCapacity: true)
        pendingReplyID = nil
        if messages.last?.id == id {
            messages[messages.count - 1].text += delta
        }
    }

    private func discardEmptyReply() {
        if let last = messages.last, !last.isUser, last.text.isEmpty { messages.removeLast() }
    }

    private func failed(_ error: Error, serial: Int) async {
        guard serial == generation else { return }
        cancelIdleTimer()
        let failedClient = client
        client = nil
        models = nil
        efforts = nil
        phase = .disconnected
        disconnectedForInactivity = false
        activeTool = nil
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

/// Minimalist, editorial Markdown chat surface backed by `AgentChatSession`.
/// Double-clicking any message copies its raw Markdown as plain text.
public struct AgentChatView: View {
    @Bindable private var session: AgentChatSession
    @FocusState private var composerFocused: Bool
    @State private var copiedMessageID: UUID?
    @State private var hoveredMessageID: UUID?
    @State private var autoScrollPinned = true
    @State private var agentStatuses: [ACPAgentStatus] = []
    @State private var installingAdapterForID: String?
    @State private var adapterInstallError: String?
    @State private var copiedInstallCommand = false
    private let emptyTitle: String
    private let agent: String
    private let intro: String
    private let placeholder: String
    private let starters: [String]
    private let sandboxed: Binding<Bool>?
    private let agents: [ACPAgentPreset]
    private let selectedAgent: Binding<ACPAgentPreset>?
    private let workingDirectory: URL?
    private let colors: ChatColors

    public init(
        session: AgentChatSession,
        agent: String,
        intro: String,
        emptyTitle: String = "How can I help?",
        placeholder: String = "Message…",
        starters: [String] = [],
        sandboxed: Binding<Bool>? = nil,
        agents: [ACPAgentPreset] = [],
        selectedAgent: Binding<ACPAgentPreset>? = nil,
        workingDirectory: URL? = nil,
        tokens: ThemeTokens
    ) {
        self.session = session
        self.agent = agent
        self.intro = intro
        self.emptyTitle = emptyTitle
        self.placeholder = placeholder
        self.starters = starters
        self.sandboxed = sandboxed
        self.agents = agents
        self.selectedAgent = selectedAgent
        self.workingDirectory = workingDirectory
        self.colors = ChatColors(tokens: tokens)
    }

    public init(
        session: AgentChatSession,
        title: String,
        agent: String,
        intro: String,
        starters: [String] = [],
        sandboxed: Binding<Bool>? = nil,
        agents: [ACPAgentPreset] = [],
        selectedAgent: Binding<ACPAgentPreset>? = nil,
        workingDirectory: URL? = nil,
        palette: PickerPalette
    ) {
        self.session = session
        self.agent = agent
        self.intro = intro
        self.emptyTitle = title
        self.placeholder = "Message…"
        self.starters = starters
        self.sandboxed = sandboxed
        self.agents = agents
        self.selectedAgent = selectedAgent
        self.workingDirectory = workingDirectory
        self.colors = ChatColors(palette: palette)
    }

    private var isStreaming: Bool { session.phase == .replying || session.phase == .stopping }
    private var activeError: String? { session.error ?? (session.phase == .ready ? session.modelProblem : nil) }

    private var resolvedAgentStatuses: [ACPAgentStatus] {
        agentStatuses
    }

    private var selectedAgentMissingAdapter: ACPAgentPreset? {
        guard session.phase == .disconnected, let current = selectedAgent?.wrappedValue else { return nil }
        guard let status = resolvedAgentStatuses.first(where: { $0.id == current.id }),
              status.needsACPAdapter,
              current.adapterInstallCommand != nil else { return nil }
        return current
    }

    private func refreshAgentStatuses() {
        guard !agents.isEmpty else { return }
        let presets = agents
        Task {
            let detected = await Task.detached(priority: .utility) {
                ACPAgentPreset.detectAll(in: presets)
            }.value
            agentStatuses = detected
        }
    }

    private func installAdapter(for preset: ACPAgentPreset) {
        guard installingAdapterForID == nil else { return }
        installingAdapterForID = preset.id
        adapterInstallError = nil
        Task {
            do {
                _ = try await preset.installACPAdapter()
                await MainActor.run {
                    installingAdapterForID = nil
                    adapterInstallError = nil
                    refreshAgentStatuses()
                    if selectedAgent?.wrappedValue == preset && session.phase == .disconnected {
                        session.connect()
                    }
                }
            } catch {
                await MainActor.run {
                    installingAdapterForID = nil
                    adapterInstallError = error.localizedDescription
                    refreshAgentStatuses()
                }
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.messages.isEmpty {
                emptyCanvas
            } else {
                transcript
            }

            if let preset = selectedAgentMissingAdapter {
                adapterInstallBanner(preset)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else if let pending = session.pendingToolApproval {
                toolApprovalBanner(pending)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else if let message = activeError {
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
        .onAppear {
            refreshAgentStatuses()
        }
        .onChange(of: selectedAgent?.wrappedValue) { _, _ in
            adapterInstallError = nil
            copiedInstallCommand = false
            refreshAgentStatuses()
        }
        .onChange(of: session.phase) { _, new in
            if new == .ready { composerFocused = true }
        }
        .onChange(of: session.draft) { _, _ in
            session.noteActivity()
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
            let scroll = ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
            .onChange(of: session.messages.count) { oldCount, newCount in
                if newCount > oldCount {
                    autoScrollPinned = true
                    reader.scrollTo("chat-end", anchor: .bottom)
                }
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if autoScrollPinned {
                    reader.scrollTo("chat-end", anchor: .bottom)
                }
            }

            if #available(macOS 15.0, *) {
                scroll.onScrollGeometryChange(for: Bool.self) { geo in
                    let distanceFromBottom = geo.contentSize.height - (geo.contentOffset.y + geo.visibleRect.height)
                    return distanceFromBottom <= 48
                } action: { _, nearBottom in
                    autoScrollPinned = nearBottom
                }
            } else {
                scroll
            }
        }
    }

    private func copyRawMarkdown(_ message: AgentChatSession.Message) {
        guard !message.text.isEmpty else { return }
        PlainPasteboard.copy(message.text)
        copiedMessageID = message.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            if copiedMessageID == message.id { copiedMessageID = nil }
        }
    }

    private func userTurn(_ message: AgentChatSession.Message) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 4) {
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
                    .onTapGesture(count: 2) { copyRawMarkdown(message) }
                    .contextMenu {
                        Button("Copy Markdown") { copyRawMarkdown(message) }
                    }
                    .help("Double-click to copy raw Markdown")

                if copiedMessageID == message.id {
                    copiedPill
                } else if hoveredMessageID == message.id {
                    hoverCopyButton(message)
                }
            }
            Spacer(minLength: 36)
        }
        .onHover { hovering in
            if hovering { hoveredMessageID = message.id }
            else if hoveredMessageID == message.id { hoveredMessageID = nil }
        }
    }

    private func assistantTurn(_ message: AgentChatSession.Message, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.text.isEmpty {
                Text("…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(colors.muted)
            } else {
                ChatMarkdownView(
                    rawMarkdown: message.text,
                    ink: colors.ink,
                    muted: colors.muted,
                    accent: colors.accent,
                    elevated: colors.elevated,
                    line: colors.line
                )
                .equatable()
            }

            if streaming {
                StreamingStatusView(
                    text: streamingStatus,
                    accent: colors.accent,
                    ink: colors.ink,
                    muted: colors.muted
                )
                .padding(.top, 2)
            } else if copiedMessageID == message.id {
                copiedPill
            } else if hoveredMessageID == message.id, !message.text.isEmpty {
                hoverCopyButton(message)
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredMessageID = message.id }
            else if hoveredMessageID == message.id { hoveredMessageID = nil }
        }
        .onTapGesture(count: 2) { copyRawMarkdown(message) }
        .contextMenu {
            Button("Copy Markdown") { copyRawMarkdown(message) }
        }
        .help("Double-click to copy raw Markdown")
    }

    private func hoverCopyButton(_ message: AgentChatSession.Message) -> some View {
        Button { copyRawMarkdown(message) } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5))
                Text("Copy Markdown")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(colors.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colors.elevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var copiedPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .semibold))
            Text("Copied Markdown")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(colors.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(colors.accentSurface, in: Capsule())
    }

    private var streamingStatus: String {
        if session.phase == .stopping { return "STOPPING" }
        if let tool = session.activeTool, !tool.isEmpty { return tool.uppercased() }
        if let name = currentModelName { return "GENERATING · \(name.uppercased())" }
        return "GENERATING"
    }

    // MARK: - Recovery & adapter install banners

    private func adapterInstallBanner(_ preset: ACPAgentPreset) -> some View {
        let isInstalling = installingAdapterForID == preset.id
        let command = preset.adapterInstallCommand ?? preset.installHint
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: adapterInstallError == nil ? "puzzlepiece.extension.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(adapterInstallError == nil ? colors.accent : colors.danger)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(preset.name) CLI is installed, but needs its ACP adapter to chat here.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.muted)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    if let installError = adapterInstallError {
                        Text(installError)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.danger)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                if isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing ACP adapter…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(colors.muted)
                } else {
                    Button(adapterInstallError == nil ? "Install ACP Adapter" : "Retry Install") {
                        installAdapter(for: preset)
                    }
                    .buttonStyle(QuietButtonStyle(palette: colors.palette, prominent: true, height: 24))

                    Button(copiedInstallCommand ? "Copied" : "Copy Command") {
                        PlainPasteboard.copy(command)
                        copiedInstallCommand = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.3))
                            copiedInstallCommand = false
                        }
                    }
                    .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 24))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            (adapterInstallError == nil ? colors.accent : colors.danger).opacity(colors.isDark ? 0.14 : 0.08),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder((adapterInstallError == nil ? colors.accent : colors.danger).opacity(0.32), lineWidth: 1)
        }
    }

    private func toolApprovalBanner(_ pending: AgentChatSession.PendingToolApproval) -> some View {
        let heading: String = if let name = pending.toolName, !name.isEmpty {
            "\(activeAgentName) wants to use “\(name)”"
        } else {
            "\(activeAgentName) wants to use a tool"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.accent)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(heading)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tools are off by default in Chat mode. Allow built-in tools (such as web search) to run inside the sandbox?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                Button("Allow Always") {
                    session.resolveToolApproval(.allowAlways)
                }
                .buttonStyle(QuietButtonStyle(palette: colors.palette, prominent: true, height: 24))

                Button("This Session") {
                    session.resolveToolApproval(.allowForSession)
                }
                .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 24))

                Button("Don't Allow") {
                    session.resolveToolApproval(.deny)
                }
                .buttonStyle(QuietButtonStyle(palette: colors.palette, height: 24))

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colors.accent.opacity(colors.isDark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(colors.accent.opacity(0.32), lineWidth: 1)
        }
    }

    private func recoveryBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(colors.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(colors.ink)
                .lineLimit(6)
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

                if let workingDirectory {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                        Text(workingDirectory.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(colors.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .help(workingDirectory.path)
                }

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

    private var activeAgentName: String {
        selectedAgent?.wrappedValue.name ?? agent
    }

    private var canSwitchAgent: Bool {
        selectedAgent != nil && !agents.isEmpty && (session.phase == .disconnected || session.phase == .ready)
    }

    @ViewBuilder private var agentModelControl: some View {
        let isConnected = session.phase != .disconnected && session.phase != .connecting
        if !isConnected && !canSwitchAgent {
            agentPillLabel(showChevron: false)
        } else {
            Menu {
                if let selectedAgent, !agents.isEmpty {
                    let statuses = resolvedAgentStatuses
                    let ready = statuses.filter(\.isReady)
                    let needsAdapter = statuses.filter(\.needsACPAdapter)
                    let unavailable = statuses.filter { !$0.isReady && !$0.needsACPAdapter }
                    if !ready.isEmpty {
                        Section("Available Agents") {
                            ForEach(ready) { status in
                                agentMenuItem(status.preset, selectedAgent: selectedAgent, suffix: nil)
                            }
                        }
                    }
                    if !needsAdapter.isEmpty {
                        Section("Needs ACP Adapter") {
                            ForEach(needsAdapter) { status in
                                agentMenuItem(status.preset, selectedAgent: selectedAgent, suffix: "install ACP adapter")
                            }
                        }
                    }
                    if !unavailable.isEmpty {
                        Section("Not Installed") {
                            ForEach(unavailable) { status in
                                agentMenuItem(status.preset, selectedAgent: selectedAgent, suffix: "not installed")
                            }
                        }
                    }
                }
                if isConnected, let models = session.models, !models.choices.isEmpty {
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
                }
                if isConnected, let efforts = session.efforts, !efforts.choices.isEmpty {
                    Section("Effort") {
                        ForEach(efforts.choices) { choice in
                            Button { session.selectEffort(choice.id) } label: {
                                if choice.id == efforts.current {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                    }
                }
                if isConnected {
                    Divider()
                    Button("Disconnect", role: .destructive) { session.disconnect() }
                }
            } label: {
                agentPillLabel(showChevron: true)
            }
            .menuStyle(.borderlessButton)
            .layoutPriority(0)
            .disabled(session.phase != .ready && session.phase != .disconnected)
            .accessibilityLabel(currentModelName.map { "\(activeAgentName), model \($0)" } ?? activeAgentName)
        }
    }

    private func agentMenuItem(_ preset: ACPAgentPreset, selectedAgent: Binding<ACPAgentPreset>, suffix: String?) -> some View {
        Button {
            guard preset != selectedAgent.wrappedValue else { return }
            if session.phase != .disconnected { session.disconnect() }
            selectedAgent.wrappedValue = preset
        } label: {
            let label = suffix.map { "\(preset.name) (\($0))" } ?? preset.name
            if preset == selectedAgent.wrappedValue {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func agentPillLabel(showChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(activeAgentName)
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
        if selectedAgentMissingAdapter != nil {
            return adapterInstallError == nil ? colors.accent : colors.danger
        }
        if session.pendingToolApproval != nil { return colors.accent }
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

    private var currentEffortName: String? {
        guard let efforts = session.efforts else { return nil }
        if let found = efforts.choices.first(where: { $0.id == efforts.current }) { return found.name }
        return efforts.current.isEmpty ? nil : efforts.current
    }

    private var pillSubtitle: String? {
        switch session.phase {
        case .disconnected: return session.disconnectedForInactivity ? "Idle" : nil
        case .connecting: return "Connecting…"
        case .switching: return "Switching…"
        case .ready, .replying, .stopping:
            if let name = currentModelName {
                if let effort = currentEffortName { return "\(name) · \(effort)" }
                return name
            }
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

/// Subtle shimmer sweep across the streaming status label with a gently pulsing accent dot.
private struct StreamingStatusView: View {
    let text: String
    let accent: Color
    let ink: Color
    let muted: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycleSeconds: TimeInterval = 1.7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let raw = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cycleSeconds) / Self.cycleSeconds
            let cycle = raw < 0 ? raw + 1 : raw
            let sweep = -0.35 + cycle * 1.70
            let pulse = 0.5 - 0.5 * cos(cycle * 2.0 * .pi)

            HStack(spacing: 6) {
                ZStack {
                    if !reduceMotion {
                        Circle()
                            .fill(accent.opacity(0.32 * (1.0 - cycle)))
                            .frame(width: 6, height: 6)
                            .scaleEffect(1.0 + cycle * 1.35)
                    }
                    Circle()
                        .fill(accent.opacity(reduceMotion ? 1.0 : 0.55 + 0.45 * pulse))
                        .frame(width: 6, height: 6)
                }
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

                MonoLabel(text)
                    .foregroundStyle(muted.opacity(0.75))
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { proxy in
                                let width = max(proxy.size.width, 1)
                                let band = max(width * 0.36, 44)
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: accent.opacity(0.75), location: 0.35),
                                        .init(color: ink, location: 0.5),
                                        .init(color: accent.opacity(0.75), location: 0.65),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: band, height: proxy.size.height)
                                .offset(x: sweep * width - band * 0.5)
                            }
                            .clipped()
                            .mask(MonoLabel(text))
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
    }
}

/// Compact row for Settings screens that offers one-click installation of a missing ACP adapter
/// when an agent's base CLI (e.g. `codex`, `claude`, `pi`) is installed without its `-acp` bridge.
public struct ACPAdapterInstallRow: View {
    public let preset: ACPAgentPreset
    public var onInstalled: (() -> Void)?

    @State private var installing = false
    @State private var copied = false
    @State private var errorMessage: String?

    public init(preset: ACPAgentPreset, onInstalled: (() -> Void)? = nil) {
        self.preset = preset
        self.onInstalled = onInstalled
    }

    public var body: some View {
        let command = preset.adapterInstallCommand ?? preset.installHint
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(preset.name) CLI found — ACP adapter not installed")
                        .font(.callout.weight(.medium))
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if installing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(copied ? "Copied" : "Copy") {
                        PlainPasteboard.copy(command)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.3))
                            copied = false
                        }
                    }
                    .controlSize(.small)

                    if preset.adapterNPMPackage != nil {
                        Button(errorMessage == nil ? "Install Adapter" : "Retry") {
                            runInstall()
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func runInstall() {
        guard !installing else { return }
        installing = true
        errorMessage = nil
        Task {
            do {
                _ = try await preset.installACPAdapter()
                await MainActor.run {
                    installing = false
                    errorMessage = nil
                    onInstalled?()
                }
            } catch {
                await MainActor.run {
                    installing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
