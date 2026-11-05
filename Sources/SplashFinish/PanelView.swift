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

private struct NotificationRow: View {
    let event: AgentEvent
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var hovered = false
    @State private var dismissHovered = false
    private let muted = Color(hex: 0xA4AFB3)
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Deliberately separate from dismiss, never nested buttons.
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 8) {
                        Image(systemName: event.status == .attention ? "exclamationmark" : "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(event.status == .attention ? Color(hex: 0xF0C37A) : Color(hex: 0x9CC9AE))
                            .frame(width: 23, height: 23)
                            .background(event.status == .attention ? Color(hex: 0x51442F) : Color(hex: 0x2E403A), in: .circle)
                        Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 39)
                    }
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
                        }
                        Text(event.title).font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(hex: 0xEEF1EC)).lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            if !event.detail.isEmpty { Text(event.detail).lineLimit(1) }
                            if !event.detail.isEmpty { Text("·") }
                            Text(event.date, style: .relative).lineLimit(1).fixedSize()
                        }.font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(.top, 3)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 12))
                        .foregroundStyle(hovered ? Color.white : muted).padding(.top, 25)
                }.padding(.vertical, 4).contentShape(.rect)
            }.buttonStyle(.plain).onHover { hovered = $0 }
                .help("Open source · \(event.title)")
                .accessibilityLabel("Open \(event.agent): \(event.title)")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(dismissHovered ? Color.white : muted)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(dismissHovered ? 0.14 : 0.035), in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
            }.buttonStyle(.plain).padding(.top, 22)
                .onHover { dismissHovered = $0 }
                .help("Dismiss notification")
                .accessibilityLabel("Dismiss \(event.agent): \(event.title)")
        }.padding(.horizontal, 4)
            .background(.white.opacity(hovered ? 0.025 : 0), in: .rect(cornerRadius: 6))
            .contextMenu {
                Button("Open Source", action: onOpen)
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
    private var subtitle: String {
        if model.items.isEmpty { return "We'll let you know when an agent needs you." }
        return "\(model.attention.count) \(model.attention.count == 1 ? "needs" : "need") attention · \(model.completed.count) completed"
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
                    NotificationRow(event: event, onOpen: { onOpen(event) }, onDismiss: { model.dismiss(event) })
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
            Text(model.items.isEmpty ? "You're all caught up." : "Your agents are back.")
                .font(.system(size: 27, weight: .medium)).tracking(-0.7).padding(.top, 18)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(muted).padding(.top, 7)
            if !model.items.isEmpty {
                // viewThatFits keeps a short inbox intrinsically sized; only long lists scroll.
                ViewThatFits(in: .vertical) {
                    groups.fixedSize(horizontal: false, vertical: true)
                    ScrollView { groups }.scrollIndicators(.automatic)
                }.frame(maxHeight: model.maxListHeight).padding(.top, 22)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                    Text("Nothing waiting. You're free to focus.")
                }.font(.system(size: 12)).foregroundStyle(muted).padding(.vertical, 28)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.top, 17)
            HStack {
                Button(action: model.snooze) {
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
                    .help("Clear all notifications and hide · ⌘W")
            }.padding(.top, 17)
            Text(model.message ?? "Snooze for 15 minutes or until the next update")
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
