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
    /// The rich question checkbox takes effect immediately for an installed integration.
    /// Before the first install it only preselects the option for the Install button:
    /// opening this window, which sets the initial checkbox state, must never install
    /// an integration on its own.
    private func applyRichToggle(_ value: Bool) {
        guard let pi = statuses.first(where: { $0.agent == .pi }), pi.state != .notInstalled,
              pi.richQuestionsEnabled != value else { return }
        install(.pi)
    }
    private func displayName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "pi"
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Integrations").font(.title2.weight(.semibold))
            Text("Check agent connections and update installed skills.").foregroundStyle(.secondary)
        }
    }
    private func piDetails(_ status: IntegrationStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Answer pi-agent-ask questions here", isOn: $richPi).toggleStyle(.checkbox)
            Text(status.piAskDetected
                 ? "pi-agent-ask detected. Changes apply right away."
                 : "Not detected globally. Run: pi install npm:pi-agent-ask (project-local installs may still work).")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func lastEventText(_ status: IntegrationStatus) -> Text {
        guard let date = status.lastEvent else { return Text("No event recorded yet") }
        return Text("Last event: \(date.formatted(date: .abbreviated, time: .shortened))")
    }
    private func statusRow(_ status: IntegrationStatus) -> some View {
        let installed = status.state == .installed
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(installed ? .green : .orange)
                .frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName(status.agent)).font(.headline)
                    Text(status.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.agent == .pi { piDetails(status) }
                lastEventText(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(status.state == .notInstalled ? "Install" : "Reinstall") { install(status.agent) }
                .help("Install or update the \(status.agent.rawValue) integration")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }
    private var footer: some View {
        HStack {
            Text("Codex hook trust cannot be checked automatically.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Refresh", action: refresh).keyboardShortcut("r", modifiers: .command)
        }
    }
    private func loadInitialState() {
        refresh()
        if let pi = statuses.first(where: { $0.agent == .pi }) {
            richPi = pi.richQuestionsEnabled || (pi.state == .notInstalled && pi.piAskDetected)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ForEach(statuses) { statusRow($0) }
            if let message { Text(message).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 400)
        .onAppear { loadInitialState() }
        // The checkbox applies immediately; Reinstall is not required for it.
        .onChange(of: richPi) { _, value in applyRichToggle(value) }
    }
}
