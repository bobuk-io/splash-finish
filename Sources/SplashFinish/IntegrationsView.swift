import SwiftUI
import SplashFinishCore

@MainActor struct IntegrationsView: View {
    let model: AppModel
    @State private var statuses: [IntegrationStatus] = []
    @State private var message: String?
    @State private var richPi = false

    private func refresh() {
        do { statuses = try CLI.integrationInstaller().inspect(inbox: model.inbox) }
        catch { message = error.localizedDescription }
    }
    private func install(_ agent: AgentKind) {
        do {
            let result = try CLI.integrationInstaller().run(install: true, agents: [agent], richQuestions: agent == .pi ? richPi : nil)
            message = result.joined(separator: "\n")
            refresh()
        } catch { message = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Integrations").font(.title2.weight(.semibold))
                Text("Check agent connections and update installed skills.").foregroundStyle(.secondary)
            }
            ForEach(statuses) { status in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: status.state == "installed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(status.state == "installed" ? .green : .orange)
                        .frame(width: 20).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(status.agent == .claude ? "Claude Code" : status.agent == .codex ? "Codex" : "pi")
                                .font(.headline)
                            Text(status.state.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(status.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if status.agent == .pi {
                            Toggle("Answer pi-agent-ask questions here", isOn: $richPi).toggleStyle(.checkbox)
                            Text(status.piAskDetected ? "pi-agent-ask detected. Apply changes with Reinstall." : "Not detected globally. Run: pi install npm:pi-agent-ask (project-local installs may still work).")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if let date = status.lastEvent {
                            Text("Last event: \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No event recorded yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(status.state == "not installed" ? "Install" : "Reinstall") { install(status.agent) }
                        .help("Install or update the \(status.agent.rawValue) integration")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
            }
            if let message { Text(message).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack {
                Text("Codex hook trust cannot be checked automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: refresh).keyboardShortcut("r", modifiers: .command)
            }
        }.padding(24).frame(minWidth: 520, minHeight: 400)
            .onAppear {
                refresh()
                if let pi = statuses.first(where: { $0.agent == .pi }) {
                    richPi = pi.richQuestionsEnabled || (pi.state == "not installed" && pi.piAskDetected)
                }
            }
    }
}
