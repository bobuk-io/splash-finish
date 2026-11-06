import Foundation

/// Orca's terminal handles are runtime-scoped. Keep the workspace and pane identity
/// too, so a click can re-discover the same pane after an Orca restart.
public struct OrcaSource: Codable, Equatable, Sendable {
    public static let bundleID = "com.stablyai.orca"
    public var terminal: String?
    public var worktree: String?
    public var pane: String?
    /// Structured chat identity. Agents running in Orca's built-in chat have no
    /// terminal handle, so this is the only way back to the exact chat.
    public var session: String?

    public init(terminal: String? = nil, worktree: String? = nil, pane: String? = nil, session: String? = nil) {
        self.terminal = terminal; self.worktree = worktree; self.pane = pane; self.session = session
    }

    /// Orca's own session identifier shape: 8–128 letters, digits, dashes or underscores.
    public static func isSessionID(_ text: String) -> Bool {
        (8...128).contains(text.utf8.count) && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public func validated() throws -> Self {
        func token(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        if let terminal {
            guard terminal.utf8.count <= 128, terminal.hasPrefix("term_"), token(terminal) else {
                throw EventError.invalid("Invalid Orca terminal handle")
            }
        }
        if let pane {
            let parts = pane.split(separator: ":", omittingEmptySubsequences: false)
            guard pane.utf8.count <= 256, parts.count == 2, parts.allSatisfy({ token(String($0)) }) else {
                throw EventError.invalid("Invalid Orca pane identity")
            }
        }
        if let worktree {
            guard !worktree.isEmpty, worktree.utf8.count <= 2048,
                  !worktree.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw EventError.invalid("Invalid Orca workspace identity")
            }
        }
        if let session {
            guard Self.isSessionID(session) else { throw EventError.invalid("Invalid Orca chat identity") }
        }
        guard terminal != nil || session != nil || (pane != nil && worktree != nil) else {
            throw EventError.invalid("Orca source requires a terminal, a chat session, or a workspace and pane")
        }
        return self
    }

    /// Ordered navigation attempts. A terminal pane is exact; the chat is the
    /// fallback for a structured session that has no terminal of its own.
    public var targets: [OrcaTarget] {
        var result: [OrcaTarget] = []
        if terminal != nil || pane != nil { result.append(.terminal) }
        if session != nil { result.append(.chat) }
        return result
    }

    /// No Orca subprocess on the hot hook path: these coordinates are inherited by
    /// every agent/CLI launched in an Orca terminal, regardless of the agent name.
    public static func capture(environment: [String: String]) -> Self? {
        let source = Self(terminal: environment["ORCA_TERMINAL_HANDLE"],
                          worktree: environment["ORCA_WORKTREE_ID"] ?? environment["ORCA_WORKSPACE_ID"],
                          pane: environment["ORCA_PANE_KEY"],
                          session: environment["ORCA_AGENT_SESSION_ID"])
        return try? source.validated()
    }

    /// Resolve only the original pane, never the active tab or a same-name project.
    /// A stale handle is replaced only using stable workspace + pane coordinates.
    public func resolve(in terminals: [OrcaTerminal]) -> String? {
        let local = terminals.filter { $0.executionHostId == "local" && !$0.orphaned && $0.connected }
        let matches = local.filter { item in
            if let worktree, item.worktreeId != worktree { return false }
            if let pane { return item.pane == pane }
            return item.handle == terminal
        }
        guard matches.count == 1 else { return nil }
        return matches[0].handle
    }
}

/// Where a click should try to land inside Orca.
public enum OrcaTarget: String, Equatable, Sendable {
    case terminal, chat
}

public struct OrcaTerminal: Decodable, Sendable {
    public var handle: String
    public var worktreeId: String
    public var tabId: String
    public var leafId: String
    public var executionHostId: String
    public var orphaned: Bool
    public var connected: Bool
    public var pane: String { tabId + ":" + leafId }

    public init(handle: String, worktreeId: String, tabId: String, leafId: String,
                executionHostId: String = "local", orphaned: Bool = false, connected: Bool = true) {
        self.handle = handle; self.worktreeId = worktreeId; self.tabId = tabId; self.leafId = leafId
        self.executionHostId = executionHostId; self.orphaned = orphaned; self.connected = connected
    }
}

public enum OrcaReply {
    public static func terminals(from data: Data) throws -> [OrcaTerminal] {
        struct Reply: Decodable {
            struct Result: Decodable { var terminals: [OrcaTerminal]; var truncated: Bool }
            var ok: Bool
            var result: Result?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok, let result = reply.result, !result.truncated else {
            throw EventError.invalid("Orca terminal discovery was incomplete")
        }
        return result.terminals
    }
    public static func switched(_ data: Data) -> Bool {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] as? Bool == true,
              let result = reply["result"] as? [String: Any] else { return false }
        // A paired/headless runtime can accept the command without navigating a desktop.
        guard let focus = result["focus"] as? [String: Any] else { return false }
        return focus["navigated"] as? Bool == true
    }
    /// The reveal helper answers with two replies: the published chat and the
    /// workspace activation. Both must confirm the session we clicked, because a
    /// published tab can stay behind the workspace Orca currently shows.
    public static func revealed(_ data: Data, session: String) -> Bool {
        let replies = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
        guard replies.count == 2,
              let reveal = success(replies[0]), reveal["ok"] as? Bool == true,
              reveal["sessionId"] as? String == session,
              let workspace = reveal["workspaceId"] as? String, !workspace.isEmpty,
              let activate = success(replies[1]),
              activate["activated"] as? Bool == true,
              activate["worktreeId"] as? String == workspace else { return false }
        return true
    }

    private static func success(_ reply: [String: Any]) -> [String: Any]? {
        guard reply["ok"] as? Bool == true, let result = reply["result"] as? [String: Any] else { return nil }
        return result
    }
}
