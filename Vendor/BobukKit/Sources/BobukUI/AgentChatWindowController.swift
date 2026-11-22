import AppKit
import BobukCore
import SwiftUI

/// Turnkey `ChromeWindow` controller for an ACP agent chat.
/// Wires the `+` (New chat) strip button, `ShortcutFooter(..., onSettings:)`, automatic
/// `disconnect()` on window close, and `await shutdown()` on app termination.
@MainActor public final class AgentChatWindowController {
    public let session: AgentChatSession
    public let preferences: AgentChatPreferences
    private let theme: ThemeStore
    private var controller: HostedWindowController?
    private let windowTitle: String
    private let frameName: String
    private let bodySize: NSSize
    private let intro: String
    private let emptyTitle: String
    private let starters: [String]
    private let agents: [ACPAgentPreset]
    private let workingDirectory: () -> URL?
    private let onSettings: (() -> Void)?
    private var sandboxed = true

    public init(
        title: String = "Assistant",
        frameName: String = "AgentChat",
        bodySize: NSSize = NSSize(width: 480, height: 580),
        intro: String = "Ask anything or drop files here.",
        emptyTitle: String = "How can I help?",
        starters: [String] = [],
        agents: [ACPAgentPreset] = ACPAgentPreset.all,
        preferences: AgentChatPreferences? = nil,
        theme: ThemeStore,
        session: AgentChatSession,
        workingDirectory: @escaping () -> URL? = { nil },
        onSettings: (() -> Void)? = nil
    ) {
        self.windowTitle = title
        self.frameName = frameName
        self.bodySize = bodySize
        self.intro = intro
        self.emptyTitle = emptyTitle
        self.starters = starters
        self.agents = agents
        self.preferences = preferences ?? AgentChatPreferences()
        self.theme = theme
        self.session = session
        self.workingDirectory = workingDirectory
        self.onSettings = onSettings
    }

    public func show() {
        if controller == nil {
            let hosted = HostedWindowController(
                frameName: frameName,
                releasesContentOnClose: false,
                window: { [unowned self] in
                    let size = ChromeMetrics.windowSize(forBody: bodySize)
                    let newChatButton = StripButton(glyph: .plus, label: "New chat · ⌘N") { [weak self] _ in
                        self?.session.disconnect()
                    }
                    let win = ChromeWindow(
                        contentRect: NSRect(origin: .zero, size: size),
                        theme: theme,
                        trailing: [newChatButton],
                        showsTitle: true
                    )
                    win.title = windowTitle
                    win.contentMinSize = ChromeMetrics.windowSize(forBody: NSSize(width: 380, height: 380))
                    return win
                },
                rootView: { [unowned self] in
                    AgentChatWindowBody(
                        session: session,
                        preferences: preferences,
                        theme: theme,
                        intro: intro,
                        emptyTitle: emptyTitle,
                        starters: starters,
                        agents: agents,
                        workingDirectory: workingDirectory(),
                        onSettings: onSettings
                    )
                }
            )
            hosted.onClose = { [weak self] in
                guard let self else { return }
                self.preferences.record(from: self.session)
                self.session.disconnect()
            }
            controller = hosted
        }
        controller?.show()
    }

    public func close() {
        controller?.close()
    }

    public func shutdown() async {
        preferences.record(from: session)
        await session.shutdown()
    }
}

private struct AgentChatWindowBody: View {
    let session: AgentChatSession
    @Bindable var preferences: AgentChatPreferences
    let theme: ThemeStore
    let intro: String
    let emptyTitle: String
    let starters: [String]
    let agents: [ACPAgentPreset]
    let workingDirectory: URL?
    let onSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            AgentChatView(
                session: session,
                agent: preferences.agent.name,
                intro: intro,
                emptyTitle: emptyTitle,
                starters: starters,
                agents: agents,
                selectedAgent: $preferences.agent,
                workingDirectory: workingDirectory,
                tokens: theme.tokens
            )

            Divider()

            ShortcutFooter(
                [.init("⌘↩", "send"), .init("esc", "stop"), .init("↑", "history")],
                palette: theme.pickerPalette,
                settingsHelp: "Settings · ⌘,",
                onSettings: onSettings
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.tokens.elevatedColor.opacity(0.35))
        }
        .themedSurface(theme)
        .onChange(of: session.models?.current) { _, _ in
            preferences.record(from: session)
        }
        .onChange(of: session.efforts?.current) { _, _ in
            preferences.record(from: session)
        }
    }
}
