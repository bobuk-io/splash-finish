import BobukCore
import Foundation
import Testing
@testable import BobukSystem

/// No test registers a real global shortcut: the center gets a fake backend.
@MainActor @Suite struct GlobalHotkeyCenterTests {
    @Test func registersReportsAndReleases() throws {
        let center = GlobalHotkeyCenter(signature: OSType(fourCharacterCode: "TEST"), register: { _, _ in .active })
        var events: [String] = []
        let key = try #require(Hotkey(string: "option+cmd+s"))
        #expect(center.register(key, id: 1, onPress: { _ in events.append("press") }, onRelease: { events.append("release") }) == .active)
        center.receive(1, pressed: true)
        center.receive(1, pressed: true)
        center.receive(1, pressed: false)
        #expect(events == ["press", "press", "release"])
        // A key that is down when it goes away reports a release.
        center.unregister(1)
        #expect(events.last == "release")
        #expect(center.status(1) == .inactive)
    }

    @Test func applicationShortcutsFireOncePerHold() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .active })
        var presses = 0
        center.register(try #require(Hotkey(string: "ctrl+f13")), id: 7, repeats: false, onPress: { _ in presses += 1 })
        center.receive(7, pressed: true)
        center.receive(7, pressed: true)
        center.receive(7, pressed: false)
        center.receive(7, pressed: true)
        #expect(presses == 2)
    }

    @Test func refusesModifiersAndDuplicates() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .active })
        let tap = try #require(Hotkey(string: "right-option"))
        guard case .failed = center.register(tap, id: 1, onPress: { _ in }) else { Issue.record("modifier accepted"); return }
        let key = try #require(Hotkey(string: "cmd+f15"))
        center.register(key, id: 2, onPress: { _ in })
        #expect(center.register(key, id: 3, onPress: { _ in }) == .failed("⌘F15 is already used here."))
        #expect(OSType(fourCharacterCode: "TING") == 0x5449_4E47)
    }

    @Test func availabilityProbeLeavesNoRegistration() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .failed("taken") })
        #expect(center.checkAvailable(try #require(Hotkey(string: "cmd+f1"))) == "taken")
        #expect(center.registeredIDs.isEmpty)
    }
}

@MainActor final class FakeExtendedKeys: ExtendedKeySource {
    var problem: String? { didSet { onProblemChange?() } }
    var onKey: ((ExtendedKeyEvent) -> Void)?
    var onProblemChange: (() -> Void)?
    func press(_ name: String, _ modifiers: ModifierSet = []) {
        onKey?(ExtendedKeyEvent(keyCode: KeyCodes.extended[name]!, pressed: true, modifiers: modifiers))
    }
    func release(_ name: String, _ modifiers: ModifierSet = []) {
        onKey?(ExtendedKeyEvent(keyCode: KeyCodes.extended[name]!, pressed: false, modifiers: modifiers))
    }
}

/// Extended keys (Stop, Again…) come from an `ExtendedKeySource`, never from Carbon.
@MainActor @Suite struct ExtendedHotkeyTests {
    @Test func failsWithoutASource() throws {
        var carbon = 0
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in carbon += 1; return .active })
        let stop = try #require(Hotkey(string: "stop"))
        #expect(center.register(stop, id: 1, onPress: { _ in }) == .failed(GlobalHotkeyCenter.extendedKeysOff("Stop")))
        #expect(carbon == 0)
    }

    @Test func pressAndReleaseThroughTheSource() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .active })
        let source = FakeExtendedKeys()
        center.extendedKeys = source
        var events: [String] = []
        var unclaimed: [ExtendedKeyEvent] = []
        center.onUnclaimedExtendedKey = { unclaimed.append($0) }
        #expect(center.register(try #require(Hotkey(string: "stop")), id: 1,
                                onPress: { _ in events.append("stop") }, onRelease: { events.append("stop up") }) == .active)
        #expect(center.register(try #require(Hotkey(string: "cmd+stop")), id: 2, repeats: false,
                                onPress: { _ in events.append("cmd+stop") }) == .active)
        source.press("stop")
        // The modifiers may change before the release: it still goes to the press's registration.
        source.release("stop", .shift)
        source.press("stop", .command)
        source.release("stop")
        #expect(events == ["stop", "stop up", "cmd+stop"])
        #expect(unclaimed.isEmpty)
        source.press("again")
        source.press("stop", .option)
        source.release("again")
        #expect(unclaimed.map(\.keyCode) == [KeyCodes.extended["again"]!, KeyCodes.extended["stop"]!, KeyCodes.extended["again"]!])
    }

    @Test func problemsFollowTheSource() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .active })
        var events: [String] = []
        center.register(try #require(Hotkey(string: "stop")), id: 1, onPress: { _ in events.append("press") },
                        onRelease: { events.append("release") })
        let source = FakeExtendedKeys()
        source.problem = "Not allowed."
        center.extendedKeys = source
        #expect(center.status(1) == .failed("Not allowed."))
        source.problem = nil
        #expect(center.status(1) == .active)
        source.press("stop")
        // Losing access while the key is down reports its release.
        source.problem = "Not allowed."
        #expect(events == ["press", "release"])
        #expect(center.status(1) == .failed("Not allowed."))
        center.extendedKeys = nil
        #expect(center.status(1) == .failed(GlobalHotkeyCenter.extendedKeysOff("Stop")))
        #expect(source.onKey == nil)
    }

    @Test func refusedRegistrationsStayRefused() throws {
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in .active })
        let source = FakeExtendedKeys()
        source.problem = "Not allowed."
        center.extendedKeys = source
        let stop = try #require(Hotkey(string: "stop"))
        center.register(stop, id: 1, onPress: { _ in })
        center.register(stop, id: 2, onPress: { _ in })
        source.problem = nil
        #expect(center.status(1) == .active)
        #expect(center.status(2) == .failed("Stop is already used here."))
    }

    @Test func carbonKeysIgnoreTheSource() throws {
        var carbon = 0
        let center = GlobalHotkeyCenter(signature: 1, register: { _, _ in carbon += 1; return .active })
        center.extendedKeys = FakeExtendedKeys()
        center.register(try #require(Hotkey(string: "cmd+f1")), id: 1, onPress: { _ in })
        #expect(carbon == 1)
    }
}

@MainActor @Suite struct HIDKeyMonitorTests {
    @Test func reportsExtendedKeysOnce() {
        let monitor = HIDKeyMonitor(connect: false)
        #expect(monitor.problem == nil)
        var events: [ExtendedKeyEvent] = []
        monitor.onKey = { events.append($0) }
        // Letters and other keys macOS reads itself never come through.
        monitor.receive(hidUsage: 0x04, pressed: true, modifiers: [], time: 0)
        // The same key from two keyboards (a device and Karabiner's virtual one) is one press.
        monitor.receive(hidUsage: 0x78, pressed: true, modifiers: [.command, .function], time: 1)
        monitor.receive(hidUsage: 0x78, pressed: true, modifiers: [], time: 1)
        monitor.receive(hidUsage: 0x78, pressed: false, modifiers: [], time: 2)
        monitor.receive(hidUsage: 0x78, pressed: false, modifiers: [], time: 2)
        monitor.receive(hidUsage: 0x78, pressed: false, modifiers: [], time: 3)
        #expect(events == [ExtendedKeyEvent(keyCode: 0x1078, pressed: true, modifiers: .command, time: 1),
                           ExtendedKeyEvent(keyCode: 0x1078, pressed: false, modifiers: [], time: 2)])
    }

    @Test func stopReleasesHeldKeys() {
        let monitor = HIDKeyMonitor(connect: false)
        var events: [Bool] = []
        monitor.onKey = { events.append($0.pressed) }
        monitor.receive(hidUsage: 0x79, pressed: true, modifiers: [], time: 0)
        monitor.stop()
        monitor.stop()
        #expect(events == [true, false])
    }
}

@MainActor @Suite(.serialized) struct FileWatcherTests {
    @Test func reportsEditsOfAFileAndOfFilesInAFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bobukkit-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try Data("1".utf8).write(to: file)
        var fileChanges = 0, folderChanges = 0
        let fileWatcher = FileWatcher(url: file, debounce: 0.05) { fileChanges += 1 }
        let folderWatcher = FileWatcher(folder: folder, debounce: 0.05) { folderChanges += 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2".utf8))
        try handle.close()
        for _ in 0..<40 where fileChanges == 0 || folderChanges == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fileChanges >= 1 && folderChanges >= 1)
        let before = folderChanges
        try Data("new".utf8).write(to: folder.appendingPathComponent("other.yaml"))
        for _ in 0..<40 where folderChanges == before { try await Task.sleep(for: .milliseconds(50)) }
        #expect(folderChanges > before)
        withExtendedLifetime((fileWatcher, folderWatcher)) {}
    }
}

@MainActor @Suite struct HotkeyRecordingGateTests {
    final class Owner: HotkeyRecordingOwner {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    @Test func oneOwnerAtATime() {
        var changes: [Bool] = []
        let gate = HotkeyRecordingGate { changes.append($0) }
        let first = Owner(), second = Owner()
        gate.begin(first)
        gate.begin(second)
        #expect(first.cancelled)
        gate.end(first)
        #expect(gate.isActive)
        gate.end(second)
        #expect(!gate.isActive)
        #expect(changes == [true, false])
    }
}

@MainActor @Suite struct KeyTranslatorCacheTests {
    @Test func cachedTranslationMatchesAfterInvalidation() {
        let first = KeyTranslator.latin(0)
        let second = KeyTranslator.latin(0)
        #expect(first == second)
        KeyTranslator.invalidateCache()
        let third = KeyTranslator.latin(0)
        #expect(first == third)
    }
}
