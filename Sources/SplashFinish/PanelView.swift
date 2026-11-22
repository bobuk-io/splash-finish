import AppKit
import BobukCore
import BobukUI
import SplashFinishCore
import SwiftUI

struct FinishMark: View {
    var color: Color
    var body: some View {
        HStack(spacing: 3) {
            Capsule().frame(width: 4, height: 11).offset(y: 4)
            Capsule().frame(width: 4, height: 19)
            Capsule().frame(width: 4, height: 11).offset(y: -4)
        }.foregroundStyle(color).frame(width: 24, height: 26).accessibilityHidden(true)
    }
}

/// "5 min ago" instead of a ticking "5 min, 11 sec": the panel should not draw the
/// eye every second. The row tooltip carries the exact time.
private struct AgeText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(RelativeTime.describe(date, now: context.date))
        }.lineLimit(1).fixedSize()
    }
}

private struct NotificationRow: View {
    let event: AgentEvent
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let selected: Bool
    let tokens: ThemeTokens
    let palette: PickerPalette
    @State private var hovered = false
    private var sourceAction: String {
        if event.source?.url != nil { return "Open source session" }
        if event.source?.rex != nil { return "Open original Rex terminal pane" }
        if event.source?.orca?.targets.first == .chat { return "Open original Orca chat" }
        if event.source?.orca != nil { return "Open original Orca project and terminal" }
        if event.source?.weztermPane != nil { return "Open WezTerm pane if available" }
        if event.source?.bundleID == "com.github.wez.wezterm" { return "Activate WezTerm" }
        if event.source?.bundleID != nil { return "Activate source app" }
        return "Source unavailable"
    }
    var body: some View {
        let muted = tokens.mutedColor
        let ink = tokens.inkColor
        HStack(alignment: .top, spacing: 9) {
            // Links, source navigation and dismiss have separate hit targets.
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    Image(systemName: event.status == .attention ? "exclamationmark" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(event.status == .attention ? tokens.accentColor : tokens.successColor)
                        .frame(width: 23, height: 23)
                        .background(event.status == .attention ? tokens.accentSurfaceColor : tokens.successSurfaceColor, in: .circle)
                    Rectangle().fill(ink.opacity(0.09)).frame(width: 1, height: 39)
                }.allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        MonoLabel(event.agent, size: 10, tracking: 1)
                            .foregroundStyle(ink.opacity(0.82))
                            .lineLimit(1)
                        if !event.project.isEmpty {
                            Text("/ " + event.project).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                        }
                    }.allowsHitTesting(false)
                    MessagePreview(text: event.title, size: 16,
                        color: tokens.inkNSColor, linkColor: tokens.linkNSColor,
                        lines: 2, characterLimit: 160, onOpenSource: onOpen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if !event.detail.isEmpty {
                            MessagePreview(text: event.detail, size: 11,
                                color: tokens.mutedNSColor, linkColor: tokens.linkNSColor,
                                lines: 1, characterLimit: 400, onOpenSource: onOpen)
                            Text("·").allowsHitTesting(false)
                        }
                        AgeText(date: event.date).allowsHitTesting(false)
                    }.font(.system(size: 11)).foregroundStyle(muted)
                }.padding(.top, 3)
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right").font(.system(size: 12))
                        .foregroundStyle(hovered ? ink : muted)
                }.buttonStyle(.plain).padding(.top, 25).accessibilityLabel(sourceAction)
            }.padding(.vertical, 4)
            .background {
                Button(action: onOpen) { Color.clear.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(sourceAction): \(event.agent), \(MessageText.plain(event.title, limit: 160))")
            }
            .onHover { hovered = $0 }
            .help("\(sourceAction) · \(MessageText.plain(event.title)) · \(event.date.formatted(date: .abbreviated, time: .shortened))")
            GlyphButton(.close, label: "Dismiss \(event.agent): \(MessageText.plain(event.title, limit: 160))",
                        help: "Dismiss notification", palette: palette, size: 24, action: onDismiss)
                .padding(.top, 22)
        }.padding(.horizontal, 4)
            .background(selected ? tokens.selectionColor : (hovered ? ink.opacity(0.035) : .clear), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? tokens.lineColor.opacity(0.6) : .clear))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("Open Source", action: onOpen)
                Button("Copy Text") {
                    let text = [MessageText.plain(event.title), MessageText.plain(event.detail)]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Divider()
                Button("Dismiss Notification", action: onDismiss)
            }
    }
}

/// Keep one live row tree when a question closes or the inbox starts/stops scrolling.
/// Measure the scroll content instead of switching between two ViewThatFits
/// candidates that each own AppKit-backed previews.
struct InboxList<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                        contentHeight = height
                    }
                })
        }
        .scrollIndicators(.automatic)
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
    }
}

@MainActor struct PanelView: View {
    let model: AppModel
    var theme: ThemeStore = .splash
    let onOpen: (AgentEvent) -> Void
    let onSize: (CGSize) -> Void
    var onSettings: (() -> Void)? = nil
    @Environment(\.colorSchemeContrast) private var contrast
    private var tokens: ThemeTokens { theme.tokens }
    private var pickerPalette: PickerPalette {
        tokens.pickerPalette(increasedContrast: contrast == .increased || theme.increasedContrast)
    }
    private var headline: String {
        if model.items.isEmpty { return "You're all caught up." }
        return model.completed.isEmpty ? "Your agents need you." : "Your agents are back."
    }
    private var subtitle: String {
        if model.items.isEmpty { return "We'll let you know when an agent needs you." }
        return "\(model.attention.count) \(model.attention.count == 1 ? "needs" : "need") attention · \(model.completed.count) completed"
    }
    private func group(_ label: String, items: [AgentEvent], color: Color, tokens: ThemeTokens, palette: PickerPalette) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                MonoLabel(label, size: 9)
                Rectangle().fill(color.opacity(0.2)).frame(height: 1)
                MonoLabel(String(format: "%02d", items.count), weight: .regular, tracking: 0)
            }.foregroundStyle(color).padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(items, id: \.key) { event in
                    if let id = model.questionID(for: event), let question = model.questions[id] {
                        PiQuestionView(question: question, submit: { model.answerQuestion(id: id, value: $0) },
                                       usePi: { model.usePi(id: id) }, submitting: model.submittingQuestions.contains(id),
                                       error: model.questionErrors[id], tokens: tokens, palette: palette).id(event.key)
                    } else {
                        NotificationRow(event: event, onOpen: { onOpen(event) }, onDismiss: { model.dismiss(event) },
                                        selected: model.selectedKey == event.key, tokens: tokens, palette: palette).id(event.key)
                    }
                }
            }
        }
    }
    var body: some View {
        let tokens = self.tokens
        let palette = self.pickerPalette
        let muted = tokens.mutedColor
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    FinishMark(color: tokens.accentColor).scaleEffect(0.8).frame(width: 20)
                    MonoLabel("Splash Finish", size: 11, tracking: 2)
                }
                Spacer()
                Circle().fill(tokens.accentColor).frame(width: 5, height: 5)
                MonoLabel(String(format: "%02d / inbox", model.items.count), weight: .regular, tracking: 1)
                    .foregroundStyle(muted)
            }
            Text(headline)
                .font(.system(size: 27, weight: .medium)).tracking(-0.7).padding(.top, 18)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(muted).padding(.top, 7)
            if !model.items.isEmpty {
                ScrollViewReader { proxy in
                    InboxList(maxHeight: model.maxListHeight) {
                        VStack(spacing: 22) {
                            if !model.attention.isEmpty {
                                group("NEEDS ATTENTION", items: model.attention, color: tokens.accentColor, tokens: tokens, palette: palette)
                            }
                            if !model.completed.isEmpty {
                                group("COMPLETED", items: model.completed, color: muted, tokens: tokens, palette: palette)
                            }
                        }
                    }
                    .onChange(of: model.selectedKey) { _, key in
                        if let key { proxy.scrollTo(key, anchor: .center) }
                    }
                }.frame(maxHeight: model.maxListHeight).padding(.top, 22)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                    Text("Nothing waiting. You're free to focus.")
                }.font(.system(size: 12)).foregroundStyle(muted).padding(.vertical, 28)
            }
            Rectangle().fill(tokens.strokeColor).frame(height: 1).padding(.top, 17)
            HStack {
                Button { model.snooze() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz")
                        Text("Snooze")
                        Text("15m").foregroundStyle(muted).padding(.leading, 3)
                    }
                }.buttonStyle(QuietButtonStyle(palette: palette, height: 33)).disabled(model.items.isEmpty)
                    .keyboardShortcut(.cancelAction)
                    .help("Hide for 15 minutes; new events still collect · Esc")
                Spacer()
                Button("Clear all", action: model.clear)
                    .buttonStyle(QuietButtonStyle(palette: palette, height: 33)).keyboardShortcut("w", modifiers: .command)
                    .help("Clear notifications; pending questions remain · Backspace or ⌘W")
            }.padding(.top, 17)
            if let message = model.message {
                HStack(alignment: .center, spacing: 8) {
                    Text(message).font(.system(size: 10)).foregroundStyle(tokens.accentColor)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let onSettings {
                        GlyphButton(.settings, label: "Settings", help: "Settings · ⌘,", palette: palette,
                                    width: 22, height: 22, glyphSize: 13, action: onSettings)
                    }
                }.padding(.top, 13)
            } else {
                ShortcutFooter(footerHints, palette: palette, settingsHelp: "Settings · ⌘,", onSettings: onSettings)
                    .padding(.top, 13)
            }
        }.padding(25).frame(width: 470)
            .foregroundStyle(tokens.inkColor)
            .tint(tokens.accentColor)
            .pickerPanel(palette: palette)
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in onSize(size) }
            })
            // Native previews must move with their SwiftUI rows, not through a
            // separate removal animation while AppKit resizes the host window.
            .transaction { $0.animation = nil }
    }
    private var footerHints: [ShortcutHint] {
        if model.items.isEmpty { return [.init("⌥⌘S", "opens this inbox from anywhere")] }
        return [.init("↑↓", "select"), .init("⏎", "open"), .init("⌫", "clear all"),
                .init("esc", "snooze 15 min")]
    }
}
