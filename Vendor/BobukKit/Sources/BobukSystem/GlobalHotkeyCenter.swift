// System-wide shortcuts through Carbon `RegisterEventHotKey`: no Accessibility or Input Monitoring
// permission, no helper. Carbon reports both press and release. From Ting's HotkeyService; Splash
// Finish's single ⌥⌘S and every future app use the same center. Keys that macOS never reports
// (`KeyCodes.extended`, such as Stop) work only with an `extendedKeys` source such as `HIDKeyMonitor`.
import AppKit
import BobukCore
import Carbon
import OSLog

@MainActor
public final class GlobalHotkeyCenter {
    public enum Status: Equatable, Sendable {
        /// Not registered, or turned off (for example while a new shortcut is recorded).
        case inactive
        case active
        /// Registration failed; the text says why and can be shown as is.
        case failed(String)
    }

    /// One registration. `onPress` receives the event time in seconds since system start.
    private struct Registration {
        var hotkey: Hotkey
        var ref: EventHotKeyRef?
        var onPress: (TimeInterval) -> Void
        var onRelease: (() -> Void)?
        var repeats: Bool
        var held = false
        /// Refused here (not a valid key, or another registration has it); never activated later.
        var refused = false
    }

    private var registrations: [UInt32: Registration] = [:]
    private var statuses: [UInt32: Status] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType
    private let log = BobukLog.logger("hotkey")
    /// Tests supply a backend instead of registering real global shortcuts.
    private let registerOverride: ((Hotkey, UInt32) -> Status)?

    /// Called whenever a registration changes its status.
    public var onStatusChange: ((UInt32, Status) -> Void)?

    /// Reads the hotkeys on `KeyCodes.extended` keys. nil: they fail with `extendedKeysOff`.
    /// Setting it updates the status of every such registration.
    public var extendedKeys: ExtendedKeySource? {
        didSet {
            guard oldValue !== extendedKeys else { return }
            oldValue?.onKey = nil
            oldValue?.onProblemChange = nil
            extendedKeys?.onKey = { [weak self] event in self?.receiveExtended(event) }
            extendedKeys?.onProblemChange = { [weak self] in self?.refreshExtended() }
            refreshExtended()
        }
    }

    /// An extended key press or release that no active registration took, such as a key typed
    /// into an open menu or a recorder while the hotkeys are off.
    public var onUnclaimedExtendedKey: ((ExtendedKeyEvent) -> Void)?

    /// Extended keys that are down → the registration their press went to.
    private var extendedHeld: [UInt16: UInt32] = [:]

    /// Why an extended-key hotkey fails while `extendedKeys` is nil.
    public static func extendedKeysOff(_ display: String) -> String {
        "\(display) can be read only with extended key capture (HID), which is off."
    }

    /// `signature` is a four-letter code unique to the app, such as `'TING'` (0x5449_4E47).
    public init(signature: OSType, register override: ((Hotkey, UInt32) -> Status)? = nil) {
        self.signature = signature
        registerOverride = override
    }

    deinit {
        // Carbon keeps the handler and its userData pointer; remove both with the center.
        let refs = registrations.values.compactMap(\.ref)
        let handler = handlerRef
        MainActor.assumeIsolated {
            for ref in refs { UnregisterEventHotKey(ref) }
            if let handler { RemoveEventHandler(handler) }
        }
    }

    public func status(_ id: UInt32) -> Status { statuses[id] ?? .inactive }
    public func hotkey(_ id: UInt32) -> Hotkey? { registrations[id]?.hotkey }
    public var registeredIDs: [UInt32] { Array(registrations.keys).sorted() }

    /// Registers `hotkey` under `id`, replacing the previous one. `repeats: false` reports a held
    /// key once per press (application shortcuts); `true` passes Carbon's auto-repeat on (a leader).
    /// Returns the new status; a key used by another registration here fails without asking Carbon.
    @discardableResult
    public func register(_ hotkey: Hotkey, id: UInt32, repeats: Bool = true,
                         onPress: @escaping (TimeInterval) -> Void, onRelease: (() -> Void)? = nil) -> Status {
        if let current = registrations[id], current.hotkey == hotkey, status(id) == .active {
            registrations[id]?.onPress = onPress
            registrations[id]?.onRelease = onRelease
            registrations[id]?.repeats = repeats
            return .active
        }
        unregister(id)
        registrations[id] = Registration(hotkey: hotkey, ref: nil, onPress: onPress, onRelease: onRelease, repeats: repeats)
        guard hotkey.isValid, case .combo(let keyCode, let modifiers) = hotkey else {
            registrations[id]?.refused = true
            return setStatus(.failed("\(hotkey.display) cannot be a shortcut. Choose a key that is not a modifier."), for: id)
        }
        if registrations.contains(where: { $0.key != id && $0.value.hotkey == hotkey }) {
            registrations[id]?.refused = true
            return setStatus(.failed("\(hotkey.display) is already used here."), for: id)
        }
        if KeyCodes.isExtended(keyCode) { return setStatus(extendedStatus(hotkey), for: id) }
        if let registerOverride { return setStatus(registerOverride(hotkey, id), for: id) }
        return carbonRegister(keyCode: keyCode, modifiers: modifiers, display: hotkey.display, id: id)
    }

    /// Removes `id`. A key that is down reports a release, so callers never keep a stale "held" state.
    public func unregister(_ id: UInt32) {
        let wasActive = status(id) == .active
        let release = registrations[id]?.onRelease
        if let ref = registrations[id]?.ref { UnregisterEventHotKey(ref) }
        registrations[id] = nil
        extendedHeld = extendedHeld.filter { $0.value != id }
        setStatus(.inactive, for: id)
        // Carbon sends no release for a hotkey that is gone.
        if wasActive { release?() }
    }

    public func unregisterAll() { for id in registeredIDs { unregister(id) } }

    /// Whether the system would accept `hotkey` now: nil, or the reason it would fail.
    /// Call it while the app's own registrations of that key are off (during recording).
    public func checkAvailable(_ hotkey: Hotkey) -> String? {
        let probe = UInt32.max
        register(hotkey, id: probe, onPress: { _ in })
        defer { unregister(probe) }
        if case .failed(let reason) = status(probe) { return reason }
        return nil
    }

    /// Delivers a press or release, as the Carbon handler does. Public for tests of app wiring.
    public func receive(_ id: UInt32, pressed: Bool, at time: TimeInterval = 0) {
        guard status(id) == .active, let registration = registrations[id] else { return }
        if pressed {
            if !registration.repeats {
                if registration.held { return }
                registrations[id]?.held = true
            }
            registration.onPress(time)
        } else {
            registrations[id]?.held = false
            registration.onRelease?()
        }
    }

    /// Delivers an extended key as the source does. Public for tests of app wiring.
    public func receiveExtended(_ event: ExtendedKeyEvent) {
        if event.pressed {
            let hotkey = event.hotkey
            if let id = registrations.first(where: { $0.value.hotkey == hotkey && status($0.key) == .active })?.key {
                extendedHeld[event.keyCode] = id
                receive(id, pressed: true, at: event.time)
                return
            }
        } else if let id = extendedHeld.removeValue(forKey: event.keyCode) {
            receive(id, pressed: false, at: event.time)
            return
        }
        onUnclaimedExtendedKey?(event)
    }

    private func extendedStatus(_ hotkey: Hotkey) -> Status {
        guard let extendedKeys else { return .failed(Self.extendedKeysOff(hotkey.display)) }
        if let problem = extendedKeys.problem { return .failed(problem) }
        return .active
    }

    /// The source changed or its problem did: every extended-key registration takes the new status.
    private func refreshExtended() {
        for id in registeredIDs {
            guard let registration = registrations[id], !registration.refused,
                  case .combo(let keyCode, _) = registration.hotkey, KeyCodes.isExtended(keyCode) else { continue }
            let next = extendedStatus(registration.hotkey)
            if status(id) == .active, next != .active {
                // A key held through the change reports its release.
                if extendedHeld.values.contains(id) {
                    extendedHeld = extendedHeld.filter { $0.value != id }
                    registrations[id]?.held = false
                    registration.onRelease?()
                }
            }
            setStatus(next, for: id)
        }
    }

    @discardableResult
    private func setStatus(_ status: Status, for id: UInt32) -> Status {
        guard statuses[id] != status else { return status }
        statuses[id] = status
        log.info("Hotkey \(id) \(self.registrations[id]?.hotkey.string ?? "none", privacy: .public): \(String(describing: status), privacy: .public)")
        onStatusChange?(id, status)
        return status
    }

    private func carbonRegister(keyCode: UInt16, modifiers: ModifierSet, display: String, id: UInt32) -> Status {
        installCarbonHandler()
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(keyCode), carbonModifiers, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if result == noErr, let ref {
            registrations[id]?.ref = ref
            return setStatus(.active, for: id)
        } else if result == OSStatus(eventHotKeyExistsErr) {
            return setStatus(.failed("\(display) is already used by another app."), for: id)
        } else {
            return setStatus(.failed("Cannot register \(display) (error \(result))."), for: id)
        }
    }

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The closure captures nothing, so it converts to the C function pointer Carbon needs.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let time = GetEventTime(event)
            let handled = MainActor.assumeIsolated { () -> Bool in
                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == center.signature, center.registrations[hotKeyID.id]?.ref != nil else { return false }
                center.receive(hotKeyID.id, pressed: kind == UInt32(kEventHotKeyPressed), at: time)
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, specs.count, &specs, context, &handlerRef)
    }
}

public extension OSType {
    /// `OSType("TING")`: a four-character code from ASCII text.
    init(fourCharacterCode text: String) {
        self = text.utf8.prefix(4).reduce(0) { $0 << 8 | OSType($1) }
    }
}
