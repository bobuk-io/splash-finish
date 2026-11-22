// Layout-aware key translation, from Ting. Shared with panels that route ⌘C/⌘V by the Latin key.
import AppKit
import Carbon

/// Translates physical key codes through keyboard layouts.
/// Bindings store the character of the user's ASCII-capable layout:
/// with the Russian layout active, the key labelled Ф/A still means "a".
@MainActor
public enum KeyTranslator {
    private struct Layout {
        let id: String
        let data: Data
    }

    private static var latinCodes: (layoutID: String, codes: [String: UInt16])?
    private static var hints: (key: String, hints: [String: String])?
    private static var cachedASCIILayout: Layout?
    private static var cachedCurrentLayout: Layout?
    private static var hasCachedASCII = false
    private static var hasCachedCurrent = false
    private static var observersInstalled = false

    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let reset: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { invalidateCache() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main, using: reset)
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main, using: reset)
    }

    /// Drops the cached Carbon keyboard layouts (called automatically when the input source changes).
    public static func invalidateCache() {
        cachedASCIILayout = nil
        cachedCurrentLayout = nil
        hasCachedASCII = false
        hasCachedCurrent = false
    }

    private static func layout(_ source: TISInputSource?) -> Layout? {
        guard let source,
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        return Layout(id: id, data: data)
    }

    private static var asciiLayout: Layout? {
        installObserversIfNeeded()
        if !hasCachedASCII {
            cachedASCIILayout = layout(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
            hasCachedASCII = true
        }
        return cachedASCIILayout
    }

    private static var currentLayout: Layout? {
        installObserversIfNeeded()
        if !hasCachedCurrent {
            cachedCurrentLayout = layout(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            hasCachedCurrent = true
        }
        return cachedCurrentLayout
    }

    private static func translate(_ keyCode: UInt16, data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).lowercased()
        }
    }

    /// Character of the ASCII-capable layout for a key code.
    public static func latin(_ keyCode: UInt16) -> String? {
        asciiLayout.flatMap { translate(keyCode, data: $0.data) }
    }

    /// Key code that produces `latin` in the ASCII-capable layout.
    public static func keyCode(forLatin latin: String) -> UInt16? {
        guard let ascii = asciiLayout else { return nil }
        if latinCodes?.layoutID != ascii.id {
            var codes: [String: UInt16] = [:]
            for code in (0..<128).map(UInt16.init) {
                if let text = translate(code, data: ascii.data), codes[text] == nil { codes[text] = code }
            }
            latinCodes = (ascii.id, codes)
        }
        return latinCodes?.codes[latin]
    }

    /// The letter printed in the active non-Latin layout for a Latin binding key, e.g. "w" → "ц".
    public static func localHint(forLatin latin: String) -> String? {
        guard latin.count == 1, let ascii = asciiLayout, let current = currentLayout, current.id != ascii.id else { return nil }
        let cacheKey = ascii.id + "|" + current.id
        if hints?.key != cacheKey { hints = (cacheKey, [:]) }
        if let cached = hints?.hints[latin] { return cached.isEmpty ? nil : cached }
        var hint = ""
        if let code = keyCode(forLatin: latin), let local = translate(code, data: current.data), local != latin,
           local.count == 1, let scalar = local.unicodeScalars.first, !scalar.isASCII {
            hint = local
        }
        hints?.hints[latin] = hint
        return hint.isEmpty ? nil : hint
    }
}
