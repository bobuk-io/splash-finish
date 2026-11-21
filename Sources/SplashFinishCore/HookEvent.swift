import BobukCore
import CoreFoundation
import Darwin
import Foundation

public enum HookEvent {
    /// Observe lifecycle events only. Never return an approval/denial decision.
    public static func parse(agent: String, input: Data, source: EventSource? = nil, event: String? = nil) throws -> AgentEvent? {
        if agent == "copilot" {
            return try parseCopilot(input: input, source: source, event: event)
        }
        if agent == "agy" || agent == "antigravity" {
            return try parseAgy(input: input, source: source, event: event)
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
        var phase: String?
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
        case "PostToolUse" where agent == "codex" && tool == "request_user_input_async":
            let response = (json["tool_response"] as? [String: Any]) ?? (json["tool_response"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            guard response?["accepted"] as? Bool == true else { return nil }
            let input = json["tool_input"] as? [String: Any]
            let questions = input?["questions"] as? [[String: Any]]
            let question = questions?.first?["title"] as? String
            status = .attention; title = question ?? "Codex has a question"
            detail = "Waiting for your input"; phase = "question"
        case "UserPromptSubmit", "PostToolUse", "Interrupt", "SessionEnd":
            status = .running; title = "Working"
            if name == "PostToolUse" { phase = "progress" }
        default: return nil
        }
        return try AgentEvent(task: session, agent: display, status: status, title: title,
                              detail: detail, project: project, source: source,
                              phase: phase).validated()
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

    private static func parseAgy(input: Data, source: EventSource?, event: String?) throws -> AgentEvent? {
        guard input.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let conversation = json["conversationId"] as? String, !conversation.isEmpty else { return nil }
        let payloadName = json["hookEventName"] as? String
        if let event, let payloadName, event != payloadName { return nil }
        guard let name = event ?? payloadName,
              ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"].contains(name) else { return nil }
        let workspacePath = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["workspacePaths"] as? [String])?.first(where: { !$0.isEmpty })
        let project = workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let isChild = json["parentConversationId"] != nil || json["parent_conversation_id"] != nil
            || json["subagentId"] != nil || (json["isSubagent"] as? Bool == true)
        let status: EventStatus
        let title: String
        let detail: String
        var phase: String?
        switch name {
        case "PreInvocation":
            guard !isChild else { return nil }
            let invocation = (json["invocationNum"] as? NSNumber).flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue
            }
            status = .running; title = "Working"; detail = ""
            if let invocation, invocation > 1 { phase = "progress" }
        case "PreToolUse":
            let toolCall = json["toolCall"] as? [String: Any]
            guard toolCall?["name"] as? String == "ask_question" else { return nil }
            let args = toolCall?["args"] as? [String: Any]
            let questions = args?["questions"] as? [[String: Any]] ?? []
            let first = (questions.first?["question"] as? String).map(MessageText.clean) ?? ""
            status = .attention
            title = first.isEmpty ? "Antigravity has a question" : first
            let extra = max(0, questions.count - 1)
            detail = extra > 0
                ? "+\(extra) more question\(extra == 1 ? "" : "s") — waiting for your answer"
                : "Waiting for your answer"
            phase = "question"
        case "PostToolUse":
            let toolCall = json["toolCall"] as? [String: Any]
            guard toolCall?["name"] as? String == "ask_question" else { return nil }
            status = .running; title = "Working"; detail = ""
        case "Stop":
            guard !isChild else { return nil }
            let reason = json["terminationReason"] as? String ?? "NO_TOOL_CALL"
            let errorText = (json["error"] as? String).map(MessageText.clean) ?? ""
            let fullyIdle = json["fullyIdle"] as? Bool ?? true
            switch reason {
            case "USER_CANCELED":
                status = .running; title = "Interrupted"; detail = ""
            case "ERROR", "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS", "MAX_TOKEN_BUDGET_EXCEEDED", "TERMINAL_CUSTOM_HOOK":
                status = .attention
                if !errorText.isEmpty {
                    title = errorText
                } else {
                    switch reason {
                    case "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS": title = "Agent reached its step limit"
                    case "MAX_TOKEN_BUDGET_EXCEEDED": title = "Agent exceeded its token budget"
                    case "TERMINAL_CUSTOM_HOOK": title = "Agent stopped by a hook"
                    default: title = "Agent stopped with an error"
                    }
                }
                detail = "Open the session for details"
            default:
                status = .done
                let reply = (json["transcriptPath"] as? String).flatMap(lastAgyTranscriptReply(at:))
                title = reply ?? "Response completed"
                detail = fullyIdle ? "Ready for review" : "Background work may continue"
            }
        default:
            return nil
        }
        return try AgentEvent(task: conversation, agent: "Antigravity", status: status, title: title,
                              detail: detail, project: project, source: source, phase: phase).validated()
    }

    /// Reads only the tail of a local, current-user-owned JSONL transcript to extract
    /// the last assistant response of the current turn without loading whole transcripts.
    private static func lastAgyTranscriptReply(at path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard (try? SafeFile.check(url)) != nil else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_size > 0 else { return nil }
        let tailLimit: Int64 = 65_536
        let offset = info.st_size > tailLimit ? UInt64(info.st_size - tailLimit) : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: offset) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = entry["type"] as? String else { continue }
            if type == "USER_INPUT" { break }
            if type == "PLANNER_RESPONSE",
               (entry["source"] as? String ?? "MODEL") == "MODEL",
               let content = entry["content"] as? String {
                let cleaned = MessageText.clean(content)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }
}
