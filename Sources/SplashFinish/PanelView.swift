import AppKit
import SwiftUI
import SplashFinishCore

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct FinishMark: View {
    var color = Color(hex: 0xE9BE78)
    var body: some View {
        HStack(spacing: 3) {
            Capsule().frame(width: 4, height: 11).offset(y: 4)
            Capsule().frame(width: 4, height: 19)
            Capsule().frame(width: 4, height: 11).offset(y: -4)
        }.foregroundStyle(color).frame(width: 24, height: 26).accessibilityHidden(true)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.045), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.08)))
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
    @State private var hovered = false
    @State private var dismissHovered = false
    private let muted = Color(hex: 0xA4AFB3)
    private var sourceAction: String {
        if event.source?.url != nil { return "Open source session" }
        if event.source?.orca?.targets.first == .chat { return "Open original Orca chat" }
        if event.source?.orca != nil { return "Open original Orca project and terminal" }
        if event.source?.weztermPane != nil { return "Open WezTerm pane if available" }
        if event.source?.bundleID == "com.github.wez.wezterm" { return "Activate WezTerm" }
        if event.source?.bundleID != nil { return "Activate source app" }
        return "Source unavailable"
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Links, source navigation and dismiss have separate hit targets.
            HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 8) {
                        Image(systemName: event.status == .attention ? "exclamationmark" : "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(event.status == .attention ? Color(hex: 0xF0C37A) : Color(hex: 0x9CC9AE))
                            .frame(width: 23, height: 23)
                            .background(event.status == .attention ? Color(hex: 0x51442F) : Color(hex: 0x2E403A), in: .circle)
                        Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 39)
                    }.allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Text(event.agent.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                                .foregroundStyle(Color(hex: 0xC1C9CD))
                                .lineLimit(1)
                            if !event.project.isEmpty {
                                Text("/ " + event.project).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                            }
                        }.allowsHitTesting(false)
                        MessagePreview(text: event.title, size: 16,
                            color: NSColor(srgbRed: 0.933, green: 0.945, blue: 0.925, alpha: 1),
                            lines: 2, characterLimit: 160, onOpenSource: onOpen)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            if !event.detail.isEmpty {
                                MessagePreview(text: event.detail, size: 11,
                                    color: NSColor(srgbRed: 0.643, green: 0.686, blue: 0.702, alpha: 1),
                                    lines: 1, characterLimit: 400, onOpenSource: onOpen)
                                Text("·").allowsHitTesting(false)
                            }
                            AgeText(date: event.date).allowsHitTesting(false)
                        }.font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(.top, 3)
                    Spacer(minLength: 0)
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.right").font(.system(size: 12))
                            .foregroundStyle(hovered ? Color.white : muted)
                    }.buttonStyle(.plain).padding(.top, 25).accessibilityLabel(sourceAction)
                }.padding(.vertical, 4)
                .background {
                    Button(action: onOpen) { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(sourceAction): \(event.agent), \(MessageText.plain(event.title, limit: 160))")
                }
                .onHover { hovered = $0 }
                .help("\(sourceAction) · \(MessageText.plain(event.title)) · \(event.date.formatted(date: .abbreviated, time: .shortened))")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(dismissHovered ? Color.white : muted)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(dismissHovered ? 0.14 : 0.035), in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
            }.buttonStyle(.plain).padding(.top, 22)
                .onHover { dismissHovered = $0 }
                .help("Dismiss notification")
                .accessibilityLabel("Dismiss \(event.agent): \(MessageText.plain(event.title, limit: 160))")
        }.padding(.horizontal, 4)
            .background(.white.opacity(selected ? 0.09 : hovered ? 0.025 : 0), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(selected ? 0.17 : 0)))
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

@MainActor struct PanelView: View {
    let model: AppModel
    let onOpen: (AgentEvent) -> Void
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let muted = Color(hex: 0xA4AFB3)
    private var headline: String {
        if model.items.isEmpty { return "You're all caught up." }
        return model.completed.isEmpty ? "Your agents need you." : "Your agents are back."
    }
    private var subtitle: String {
        if model.items.isEmpty { return "We'll let you know when an agent needs you." }
        return "\(model.attention.count) \(model.attention.count == 1 ? "needs" : "need") attention · \(model.completed.count) completed"
    }
    private var footnote: String {
        if let message = model.message { return message }
        if model.items.isEmpty { return "⌥⌘S opens this inbox from anywhere" }
        return "↑↓ select · ⏎ open · ⌫ clear all · esc snooze 15 min"
    }
    private func group(_ label: String, items: [AgentEvent], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5)
                Rectangle().fill(color.opacity(0.2)).frame(height: 1)
                Text(String(format: "%02d", items.count)).font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(color).padding(.horizontal, 4)
            VStack(spacing: 10) {
                ForEach(items, id: \.key) { event in
                    if let id = model.questionID(for: event), let question = model.questions[id] {
                        PiQuestionView(question: question, submit: { model.answerQuestion(id: id, value: $0) },
                                       usePi: { model.usePi(id: id) }, submitting: model.submittingQuestions.contains(id),
                                       error: model.questionErrors[id]).id(event.key)
                    } else {
                        NotificationRow(event: event, onOpen: { onOpen(event) }, onDismiss: { model.dismiss(event) },
                                        selected: model.selectedKey == event.key).id(event.key)
                    }
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    FinishMark().scaleEffect(0.8).frame(width: 20)
                    Text("SPLASH FINISH").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2)
                }
                Spacer()
                Circle().fill(Color(hex: 0xE7BB74)).frame(width: 5, height: 5)
                Text(String(format: "%02d / INBOX", model.items.count))
                    .font(.system(size: 10, design: .monospaced)).tracking(1).foregroundStyle(muted)
            }
            Text(headline)
                .font(.system(size: 27, weight: .medium)).tracking(-0.7).padding(.top, 18)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(muted).padding(.top, 7)
            if !model.items.isEmpty {
                // viewThatFits keeps a short inbox intrinsically sized; only long lists scroll.
                ScrollViewReader { proxy in
                    ViewThatFits(in: .vertical) {
                        groups.fixedSize(horizontal: false, vertical: true)
                        ScrollView { groups }.scrollIndicators(.automatic)
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
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.top, 17)
            HStack {
                Button { model.snooze() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz")
                        Text("Snooze")
                        Text("15m").foregroundStyle(muted).padding(.leading, 3)
                    }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(height: 33)
                }.buttonStyle(QuietButtonStyle()).disabled(model.items.isEmpty)
                    .keyboardShortcut(.cancelAction)
                    .help("Hide for 15 minutes or until the next new event · Esc")
                Spacer()
                Button(action: model.clear) {
                    Text("Clear all").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 33)
                }.buttonStyle(QuietButtonStyle()).keyboardShortcut("w", modifiers: .command)
                    .help("Clear notifications; pending questions remain · Backspace or ⌘W")
            }.padding(.top, 17)
            Text(footnote)
                .font(.system(size: 10)).foregroundStyle(model.message == nil ? muted : Color(hex: 0xF0C37A))
                .lineLimit(2).padding(.top, 13)
        }.padding(25).frame(width: 470)
            .foregroundStyle(Color(hex: 0xE9EEE9))
            .background(Color(hex: 0x222A2E), in: .rect(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color(hex: contrast == .increased ? 0xA0B0B4 : 0x526064), lineWidth: 0.75))
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in onSize(size) }
            })
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.items.count)
            .environment(\.colorScheme, .dark)
    }
    private var groups: some View {
        VStack(spacing: 22) {
            if !model.attention.isEmpty { group("NEEDS ATTENTION", items: model.attention, color: Color(hex: 0xE7BB74)) }
            if !model.completed.isEmpty { group("COMPLETED", items: model.completed, color: muted) }
        }
    }
}
