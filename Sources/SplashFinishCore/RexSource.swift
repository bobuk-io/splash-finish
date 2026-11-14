import Foundation

/// Full server-assigned IDs only. Labels, positions and suffixes can select a
/// different resource after a terminal closes.
public struct RexSource: Codable, Equatable, Sendable {
    public static let bundleID = "com.superlogical.rex"
    public var session: String
    public var block: String

    public init(session: String, block: String) {
        self.session = session; self.block = block
    }

    public static func isID(_ value: String, kind: String) -> Bool {
        guard value.hasPrefix(kind + ":"), value.utf8.count == kind.utf8.count + 37 else { return false }
        let uuid = String(value.dropFirst(kind.count + 1))
        return UUID(uuidString: uuid) != nil
    }

    public func validated() throws -> Self {
        guard Self.isID(session, kind: "session"), Self.isID(block, kind: "block") else {
            throw EventError.invalid("Rex source requires full session and block IDs")
        }
        return self
    }

    public static func capture(environment: [String: String]) -> Self? {
        guard environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil,
              environment["REX_SERVER"].map({ $0.hasPrefix("unix:///") }) ?? true,
              let session = environment["REX_SESSION"], let block = environment["REX_BLOCK"] else { return nil }
        return try? Self(session: session, block: block).validated()
    }

    public var inspectArguments: [String] { ["block", "inspect", "-s", session, block, "--json"] }
    public var focusArguments: [String] { ["focus", "-s", session, block] }
    public func selectArguments(client: String, window: String) throws -> [String] {
        _ = try validated()
        guard Self.isID(client, kind: "client"), Self.isID(window, kind: "window") else {
            throw EventError.invalid("Invalid Rex client or window ID")
        }
        return ["-C", client, "do", "session.select", "session_id=" + session, "window_id=" + window, "--json"]
    }

    public func window(from data: Data) throws -> String {
        struct Reply: Decodable {
            struct Block: Decodable { var block_id: String; var window_id: String; var placement: String }
            var session_id: String; var block: Block
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.session_id == session, reply.block.block_id == block,
              reply.block.placement == "placed", Self.isID(reply.block.window_id, kind: "window") else {
            throw EventError.invalid("The original Rex pane is closed or is not placed in a tab")
        }
        return reply.block.window_id
    }

    public func focused(in data: Data, window: String) -> Bool {
        struct Reply: Decodable {
            struct Window: Decodable { var window_id: String; var focused_block_id: String? }
            var session_id: String; var active_window_id: String?; var windows: [Window]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return false }
        return reply.session_id == session && reply.active_window_id == window &&
            reply.windows.contains { $0.window_id == window && $0.focused_block_id == block }
    }
}
