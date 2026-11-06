import Foundation

public enum HookEvent {
    /// Observe lifecycle events only. Never return an approval/denial decision.
    public static func parse(agent: String, input: Data, source: EventSource? = nil) throws -> AgentEvent? {
        guard ["claude", "codex"].contains(agent), input.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = json["session_id"] as? String, !session.isEmpty,
              let name = json["hook_event_name"] as? String else { return nil }
        let display = agent == "claude" ? "Claude Code" : "Codex"
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let tool = json["tool_name"] as? String ?? "tool"
        var status: EventStatus
        var title: String
        var detail = ""
        switch name {
        case "Stop":
            // A Stop hook means a response ended, not that its claims were verified.
            status = .done
            let answer = json["last_assistant_message"] as? String ?? ""
            title = MessageText.clean(answer)
            if title.isEmpty { title = "Response completed" }
            detail = "Ready for review"
        case "StopFailure":
            status = .attention; title = "Agent stopped with an error"; detail = "Open the session for details"
        case "PermissionRequest":
            status = .attention; title = "Permission needed: \(tool)"; detail = "Waiting for your approval"
        case "Notification":
            let kind = json["notification_type"] as? String ?? ""
            guard ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(kind) else { return nil }
            status = .attention
            title = json["title"] as? String ?? "Needs your attention"
            detail = json["message"] as? String ?? "Waiting for your input"
        case "UserPromptSubmit", "PostToolUse", "Interrupt", "SessionEnd":
            status = .running; title = "Working"
        default: return nil
        }
        return try AgentEvent(task: session, agent: display, status: status, title: title,
                              detail: detail, project: project, source: source,
                              phase: name == "PostToolUse" ? "progress" : nil).validated()
    }
}
