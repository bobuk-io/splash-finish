import Foundation

/// Stable inherited coordinates only; never infer a replacement session or pane.
public struct AgtermSource: Codable, Equatable, Sendable {
    public static let bundleID = "com.umputun.agterm"
    public var session: String
    public var window: String
    public var pane: String?
    public var socket: String

    public init(session: String, window: String, pane: String? = nil, socket: String) {
        self.session = session; self.window = window; self.pane = pane; self.socket = socket
    }

    public func validated() throws -> Self {
        func isID(_ value: String) -> Bool {
            value.utf8.count == 36 && UUID(uuidString: value) != nil
        }
        guard isID(session), isID(window), pane.map(isID) ?? true else {
            throw EventError.invalid("Agterm source requires full session, window and optional pane UUIDs")
        }
        guard socket.hasPrefix("/"), socket.utf8.count <= 103,
              !socket.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !socket.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw EventError.invalid("Agterm source requires an absolute local Unix socket path of at most 103 bytes")
        }
        return self
    }

    public static func capture(environment: [String: String]) -> Self? {
        guard environment["AGTERM_ENABLED"] == "1",
              environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil,
              environment["SSH_CLIENT"] == nil,
              let session = environment["AGTERM_SESSION_ID"], let window = environment["AGTERM_WINDOW_ID"],
              let socket = environment["AGTERM_SOCKET"] else { return nil }
        return try? Self(session: session, window: window, pane: environment["AGTERM_PANE_ID"], socket: socket).validated()
    }
}
