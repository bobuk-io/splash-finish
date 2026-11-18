import Foundation
import CoreFoundation

public enum HookEvent {
    /// Observe lifecycle events only. Never return an approval/denial decision.
    public static func parse(agent: String, input: Data, source: EventSource? = nil, event: String? = nil) throws -> AgentEvent? {
        if agent == "copilot" {
            return try parseCopilot(input: input, source: source, event: event)
        }
        guard ["claude", "codex"].contains(agent), input.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = json["session_id"] as? String, !session.isEmpty,
              let name = json["hook_event_name"] as? String else { return nil }
        // Codex ephemeral threads have no transcript. Hosts use these for titles
        // and suggestions; their lifecycle must not create or clear inbox entries.
        // Keep accepting older payloads that do not include transcript_path.
        if agent == "codex", let transcript = json["transcript_path"] {
            if transcript is NSNull { return nil }
            if let path = transcript as? String,
               path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        }
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

    private static func parseCopilot(input: Data, source: EventSource?, event: String?) throws -> AgentEvent? {
        guard input.count <= 1_048_576,
              let name = event, ["Stop", "UserPromptSubmit", "PostToolUse", "SessionEnd", "notification"].contains(name),
              let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = (json["session_id"] as? String) ?? (json["sessionId"] as? String), !session.isEmpty,
              json["agent_id"] == nil, json["agentId"] == nil,
              json["parent_agent_id"] == nil, json["parentAgentId"] == nil else { return nil }
        if let payloadName = json["hook_event_name"] as? String,
           payloadName != (name == "notification" ? "Notification" : name) { return nil }
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let status: EventStatus
        let title: String
        let detail: String
        switch name {
        case "Stop":
            status = .done; title = "Agent turn ended"; detail = "Background work may continue"
        case "notification":
            guard let kind = json["notification_type"] as? String,
                  ["permission_prompt", "elicitation_dialog"].contains(kind) else { return nil }
            status = .attention
            title = json["title"] as? String ?? "Needs your attention"
            detail = json["message"] as? String ?? "Waiting for your input"
        default:
            status = .running; title = "Working"; detail = ""
        }
        var timestamp: Int64?
        if let number = json["timestamp"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite && value >= 0 && value < Double(Int64.max) {
                timestamp = Int64(value)
            }
        } else if let value = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            if let seconds = date?.timeIntervalSince1970, seconds >= 0, seconds < Double(Int64.max) / 1000 {
                timestamp = Int64((seconds * 1000).rounded())
            }
        }
        let phase = name == "PostToolUse" ? "copilot-progress" : name == "Stop" ? "copilot-stop" : nil
        return try AgentEvent(task: session, agent: "GitHub Copilot CLI", status: status, title: title,
                              detail: detail, project: project, source: source,
                              phase: phase, hookTimestamp: timestamp).validated()
    }
}
