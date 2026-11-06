import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut registered through the Carbon hot key API, which works
/// without accessibility permissions or a helper app. Registration failure must not
/// be fatal: the app simply keeps its menu item and stays fully usable.
@MainActor final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Defaults to ⌥⌘S, matching the "Show Inbox" menu item.
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_S), modifiers: UInt32 = UInt32(cmdKey | optionKey),
          action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The closure captures nothing, so it converts to the required C function pointer.
        let callback: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, context, &handlerRef) == noErr else {
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x7346484B), id: 1) // 'sFHK'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
