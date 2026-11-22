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
