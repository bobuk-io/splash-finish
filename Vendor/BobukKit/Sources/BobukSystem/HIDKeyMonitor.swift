// Extended key capture: keys that macOS never turns into key events (Stop, Again, Undo, Cut, Copy,
// Paste, Find, F21…F24, `KeyCodes.extended`), read straight from the keyboards through IOHID.
// Opt-in: it needs Input Monitoring, which Carbon hotkeys do not. Listen-only: the keys still reach
// macOS, which ignores them. Keys that macOS reads itself never come through here, so nothing doubles.
import AppKit
import BobukCore
import CoreGraphics
import IOKit.hid
import OSLog

/// A press or release of an extended key.
public struct ExtendedKeyEvent: Equatable, Sendable {
    /// A code of `KeyCodes.extended`.
    public var keyCode: UInt16
    public var pressed: Bool
    /// The modifiers held at that moment (never `.function`).
    public var modifiers: ModifierSet
    /// Seconds since system start.
    public var time: TimeInterval

    public init(keyCode: UInt16, pressed: Bool, modifiers: ModifierSet = [], time: TimeInterval = 0) {
        self.keyCode = keyCode
        self.pressed = pressed
        self.modifiers = modifiers
        self.time = time
    }

    /// The hotkey this press means: the key with the held modifiers.
    public var hotkey: Hotkey { .combo(keyCode: keyCode, modifiers: modifiers) }
}

/// Where `GlobalHotkeyCenter` reads extended keys from: `HIDKeyMonitor`, or a fake in tests.
@MainActor
public protocol ExtendedKeySource: AnyObject {
    /// nil while keys can be read; otherwise why not, ready to show.
    var problem: String? { get }
    /// Every press and release of an extended key.
    var onKey: ((ExtendedKeyEvent) -> Void)? { get set }
    /// `problem` changed, for example after Input Monitoring was allowed.
    var onProblemChange: (() -> Void)? { get set }
}

/// Reads `KeyCodes.extended` keys from every keyboard through `IOHIDManager`, without seizing them.
/// With Karabiner-Elements, keys it leaves alone come through its virtual keyboard.
@MainActor
public final class HIDKeyMonitor: ExtendedKeySource {
    public enum Access: Equatable, Sendable { case granted, denied, undetermined }

    /// Input Monitoring for this app.
    public static var access: Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .undetermined
        }
    }

    /// System Settings › Privacy & Security › Input Monitoring.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    public static let deniedProblem = "Input Monitoring is not allowed. Allow this app in System Settings › Privacy & Security › Input Monitoring."

    public private(set) var problem: String? {
        didSet { if problem != oldValue { onProblemChange?() } }
    }
    public var onKey: ((ExtendedKeyEvent) -> Void)?
    public var onProblemChange: (() -> Void)?

    private var manager: IOHIDManager?
    private var accessTimer: Timer?
    /// Presses per key across keyboards: a key reported by two devices is one press.
    private var down: [UInt16: Int] = [:]
    private let log = BobukLog.logger("hid-keys")

    /// `connect: false` reads nothing and asks for nothing (tests feed `receive`).
    /// Otherwise asks for Input Monitoring once if macOS has not asked yet, and starts reading as
    /// soon as it is allowed, also when that happens later in System Settings.
    public init(connect: Bool = true) {
        guard connect else { return }
        if Self.access == .undetermined { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        connectIfAllowed()
    }

    deinit {
        let manager = manager
        let timer = accessTimer
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        }
    }

    /// Stops reading. Keys that are down report their release.
    public func stop() {
        accessTimer?.invalidate()
        accessTimer = nil
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        releaseAll()
    }

    /// One HID value: `usage` on the keyboard page, down or up. Public for tests.
    public func receive(hidUsage usage: UInt32, pressed: Bool, modifiers: ModifierSet, time: TimeInterval) {
        guard let code = KeyCodes.extendedCode(hidUsage: usage) else { return }
        let count = down[code, default: 0]
        if pressed {
            down[code] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            down[code] = count == 1 ? nil : count - 1
            guard count == 1 else { return }
        }
        onKey?(ExtendedKeyEvent(keyCode: code, pressed: pressed, modifiers: modifiers.subtracting(.function), time: time))
    }

    private func releaseAll() {
        let held = down.keys.sorted()
        down = [:]
        for code in held {
            onKey?(ExtendedKeyEvent(keyCode: code, pressed: false, modifiers: Self.currentModifiers,
                                    time: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func connectIfAllowed() {
        guard Self.access == .granted else {
            problem = Self.deniedProblem
            // Allowing it in System Settings sends no notification; look again every two seconds.
            if accessTimer == nil {
                accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, Self.access == .granted else { return }
                        self.accessTimer?.invalidate()
                        self.accessTimer = nil
                        self.connectIfAllowed()
                    }
                }
            }
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboards: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboards as CFArray)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The closure captures nothing, so it converts to the C function pointer IOKit needs.
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
            let usage = IOHIDElementGetUsage(element)
            guard KeyCodes.extendedCode(hidUsage: usage) != nil else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            let time = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                let monitor = Unmanaged<HIDKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(hidUsage: usage, pressed: pressed, modifiers: HIDKeyMonitor.currentModifiers, time: time)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            log.error("IOHIDManagerOpen failed: \(result, privacy: .public)")
            problem = result == kIOReturnNotPermitted ? Self.deniedProblem
                : "Cannot read the keyboards (IOKit error \(String(format: "0x%08x", result)))."
            return
        }
        self.manager = manager
        problem = nil
        log.info("Reading extended keys")
    }

    /// The modifiers held now, from the combined session state (also those Karabiner remapped).
    static var currentModifiers: ModifierSet {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        return set
    }
}
