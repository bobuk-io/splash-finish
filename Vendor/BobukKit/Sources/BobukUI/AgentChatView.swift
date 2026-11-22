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

public struct AgentChatView: View {
    @Bindable private var session: AgentChatSession
    @FocusState private var composerFocused: Bool
    private let title: String
    private let agent: String
    private let intro: String
    private let palette: PickerPalette

    public init(session: AgentChatSession, title: String, agent: String, intro: String, palette: PickerPalette) {
        self.session = session
        self.title = title
        self.agent = agent
        self.intro = intro
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            if session.messages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.title2)
                        .foregroundStyle(Color(nsColor: palette.accent)).accessibilityHidden(true)
                    Text(intro).font(.callout).foregroundStyle(Color(nsColor: palette.secondary))
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                transcript
            }
            if let error = session.error ?? (session.phase == .ready ? session.modelProblem : nil) {
                Label(error, systemImage: "exclamationmark.circle").font(.callout)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            composer.padding(16)
        }
        .background(Color(nsColor: palette.surface))
        .foregroundStyle(Color(nsColor: palette.text))
        .onChange(of: session.phase) { _, new in
            if new == .ready { composerFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Label(agent, systemImage: "point.3.connected.trianglepath.dotted").font(.callout)
                Spacer(minLength: 4)
                if let models = session.models, !models.choices.isEmpty {
                    modelMenu(models)
                } else if session.phase == .ready, session.modelProblem == nil {
                    Text("CLI default model").font(.caption).foregroundStyle(Color(nsColor: palette.secondary))
                }
            }
        }
    }

    private func modelMenu(_ models: ACPModels) -> some View {
        let current = models.choices.first { $0.id == models.current }?.name
            ?? (models.current.isEmpty ? "Choose model" : models.current)
        return Menu {
            ForEach(models.choices) { choice in
                Button { session.selectModel(choice.id) } label: {
                    if choice.id == models.current { Label(choice.name, systemImage: "checkmark") }
                    else { Text(choice.name) }
                }
            }
        } label: {
            Text(current).font(.callout).lineLimit(1)
                .foregroundStyle(Color(nsColor: palette.text))
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 170, alignment: .trailing)
        .accessibilityLabel("Model: \(current)").disabled(session.phase != .ready)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            MonoLabel(message.isUser ? "You" : agent)
                                .foregroundStyle(Color(nsColor: palette.secondary))
                            Text(message.text.isEmpty ? "Waiting for the agent…" : message.text)
                                .font(.body).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(message.isUser ? Color(nsColor: palette.accent).opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    Color.clear.frame(height: 1).id("chat-end").accessibilityHidden(true)
                }.padding(12)
            }
            .onChange(of: session.messages.last?.text) { _, _ in reader.scrollTo("chat-end", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message", text: $session.draft, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                .focused($composerFocused)
            HStack {
                Spacer()
                switch session.phase {
                case .disconnected:
                    Button("Connect") { session.connect() }.buttonStyle(QuietButtonStyle(palette: palette, prominent: true))
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout)
                    Button("Cancel") { session.disconnect() }.buttonStyle(QuietButtonStyle(palette: palette))
                case .switching:
                    ProgressView().controlSize(.small)
                    Text("Switching model…").font(.callout)
                case .ready:
                    if session.needsModelCatalog {
                        Button("Reconnect") { session.reconnect() }
                            .buttonStyle(QuietButtonStyle(palette: palette, prominent: true))
                    } else {
                        Button("Send") { session.send() }.keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(QuietButtonStyle(palette: palette, prominent: true)).disabled(!session.canSend)
                    }
                case .replying, .stopping:
                    Button(session.phase == .stopping ? "Stopping…" : "Stop") { session.stop() }
                        .buttonStyle(QuietButtonStyle(palette: palette)).disabled(session.phase == .stopping)
                }
            }
        }
    }
}
