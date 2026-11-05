import Foundation

/// Selection uses the same attention-first order as the visible inbox.
public struct KeyboardSelection: Equatable, Sendable {
    public private(set) var key: String?
    private var indexHint = 0

    public init() {}

    /// Keep selection on the same notification across updates and reordering.
    /// If it was removed, select the item now occupying its previous position.
    public mutating func reconcile(keys: [String]) {
        guard !keys.isEmpty else { key = nil; indexHint = 0; return }
        if let key, let index = keys.firstIndex(of: key) { indexHint = index; return }
        indexHint = min(indexHint, keys.count - 1)
        key = keys[indexHint]
    }

    public mutating func move(_ direction: Int, keys: [String]) {
        reconcile(keys: keys)
        guard !keys.isEmpty else { return }
        indexHint = min(max(indexHint + direction.signum(), 0), keys.count - 1)
        key = keys[indexHint]
    }
}

public enum PanelKeyAction: Equatable, Sendable {
    case snooze, clearAll, previous, next, open

    /// macOS virtual key codes. Modifier chords and other apps are not handled.
    public static func from(keyCode: UInt16, hasCommandModifiers: Bool, isRepeat: Bool) -> Self? {
        guard !hasCommandModifiers else { return nil }
        switch keyCode {
        case 53: return isRepeat ? nil : .snooze       // Escape
        case 51: return isRepeat ? nil : .clearAll     // Backspace (not forward Delete)
        case 126: return .previous                     // Up
        case 125: return .next                         // Down
        case 36, 76: return isRepeat ? nil : .open     // Return or keypad Enter
        default: return nil
        }
    }
}
