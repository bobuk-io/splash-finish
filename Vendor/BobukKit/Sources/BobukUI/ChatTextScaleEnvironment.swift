import BobukCore
import SwiftUI

private struct ChatTextScaleKey: EnvironmentKey {
    static let defaultValue = ChatTextScale.standard
}

private struct ChatSendKeyKey: EnvironmentKey {
    static let defaultValue = ChatSendKey.commandReturn
}

extension EnvironmentValues {
    var chatTextScale: Double {
        get { self[ChatTextScaleKey.self] }
        set { self[ChatTextScaleKey.self] = ChatTextScale.clamped(newValue) }
    }

    var chatSendKey: ChatSendKey {
        get { self[ChatSendKeyKey.self] }
        set { self[ChatSendKeyKey.self] = newValue }
    }
}

extension View {
    /// Scales the text of the `AgentChatView`s inside; see `ChatTextScale`.
    public func chatTextScale(_ scale: Double) -> some View {
        environment(\.chatTextScale, scale)
    }

    /// Chooses the key that sends from the composer of the `AgentChatView`s inside.
    public func chatSendKey(_ key: ChatSendKey) -> some View {
        environment(\.chatSendKey, key)
    }
}
