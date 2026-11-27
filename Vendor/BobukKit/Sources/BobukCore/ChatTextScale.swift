import Foundation

/// How much larger or smaller the text of `AgentChatView` is drawn: the transcript (with
/// headings and code in proportion) and the composer. 1 is the kit's own size.
public enum ChatTextScale {
    public static let range: ClosedRange<Double> = 0.8...2.0
    public static let step = 0.1
    public static let standard = 1.0

    /// Snaps to the step and keeps the value in `range`.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        let snapped = (value / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// One step larger (⌘+) or smaller (⌘−).
    public static func stepped(_ value: Double, by steps: Int) -> Double {
        clamped(clamped(value) + Double(steps) * step)
    }

    /// For a settings label: `"120%"`.
    public static func percent(_ value: Double) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }
}

/// The key that sends a message from the composer of `AgentChatView`.
public enum ChatSendKey: String, CaseIterable, Codable, Sendable {
    /// ⌘↩ sends; ↩ starts a new line.
    case commandReturn
    /// ↩ sends; ⇧↩ or ⌥↩ starts a new line. ⌘↩ sends too.
    case `return`

    /// The hint shown next to the send button.
    public var label: String {
        switch self {
        case .commandReturn: "⌘↩"
        case .return: "↩"
        }
    }
}
