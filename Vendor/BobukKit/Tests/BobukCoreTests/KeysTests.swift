import Foundation
import Testing
@testable import BobukCore

@Suite struct SequenceKeyTests {
    static let names = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + ["space", "return"] + (1...20).map { "f\($0)" }

    @Test(arguments: names) func validNames(_ name: String) {
        #expect(SequenceKey.isValid(name))
        #expect(SequenceKey.normalize(name.uppercased()) == name)
        if name != name.uppercased() { #expect(!SequenceKey.isValid(name.uppercased())) }
        let label = name == "space" ? "␣" : name == "return" ? "↩" : name.uppercased()
        #expect(SequenceKey.display(name) == label)
        #expect(SequenceKey.spoken(name) == (name == "space" ? "Space" : name == "return" ? "Return" : name.uppercased()))
    }

    @Test(arguments: ["", "ab", "f0", "f25", "ф", " a", "a ", " ", "escape", "delete", "forwarddelete",
                      "left", "up", "keypad1", "keypadenter", "key0", "key53", "key57", "key123", "pause"])
    func invalidNames(_ name: String) {
        #expect(!SequenceKey.isValid(name))
        #expect(SequenceKey.normalize(name) == nil)
    }

    @Test func specialPhysicalKeysIgnoreLatin() {
        let pairs: [(UInt16, String)] = [(49, "space"), (36, "return"), (76, "return")] + SequenceKey.functionKeyCodes.map { ($0.key, $0.value) }
        #expect(SequenceKey.functionKeyCodes.count == 20)
        for (code, name) in pairs {
            #expect(SequenceKey.name(keyCode: code, latin: nil) == name)
            #expect(SequenceKey.name(keyCode: code, latin: "ф") == name)
        }
    }

    @Test(arguments: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init))
    func latinInput(_ latin: String) {
        #expect(SequenceKey.name(keyCode: 0, latin: latin) == latin.lowercased())
    }

    /// A key whose character is not one printable ASCII character takes its physical name.
    @Test(arguments: [nil, "", "ab", "é", "ф", "İ", " ", "\n"] as [String?])
    func physicalNameWithoutLatin(_ latin: String?) {
        #expect(SequenceKey.name(keyCode: 0, latin: latin) == "a")
        #expect(SequenceKey.name(keyCode: 33, latin: latin) == "[")
        #expect(SequenceKey.name(keyCode: 10, latin: latin) == "key10")
    }

    @Test(arguments: ["-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`", "§", "~", "+"])
    func punctuationNames(_ name: String) {
        let printable = name.unicodeScalars.first!.isASCII
        #expect(SequenceKey.isValid(name) == printable)
        #expect(SequenceKey.normalize(name) == (printable ? name : nil))
        if printable {
            #expect(SequenceKey.name(keyCode: 27, latin: name) == name)
            #expect(SequenceKey.display(name) == name)
        }
    }

    @Test(arguments: [("tab", 48, "\t", "⇥", "Tab"), ("home", 115, "\u{1}", "Home", "Home"), ("end", 119, "\u{4}", "End", "End"),
                      ("pageup", 116, "\u{b}", "PgUp", "Page Up"), ("pagedown", 121, "\u{c}", "PgDn", "Page Down"),
                      ("help", 114, "\u{5}", "Help", "Help"), ("keypadclear", 71, "\u{1b}", "Clear", "Clear"),
                      ("key10", 10, "§", "#10", "Key 10"), ("key110", 110, "\u{10}", "#110", "Key 110")] as [(String, UInt16, String, String, String)])
    func namedKeys(_ name: String, _ code: UInt16, _ latin: String, _ label: String, _ spoken: String) {
        #expect(SequenceKey.isValid(name))
        #expect(SequenceKey.normalize(name.uppercased()) == name)
        #expect(SequenceKey.name(keyCode: code, latin: latin) == name)
        #expect(SequenceKey.display(name) == label)
        #expect(SequenceKey.spoken(name) == spoken)
    }

    @Test func reservedKeysAreNeverSequenceKeys() {
        for code in SequenceKey.reservedKeyCodes {
            #expect(SequenceKey.name(keyCode: code, latin: nil) == nil)
            #expect(SequenceKey.name(keyCode: code, latin: "a") == nil)
        }
        for key in ModifierKey.allCases { #expect(SequenceKey.name(keyCode: key.keyCode, latin: nil) == nil) }
        #expect(SequenceKey.name(keyCode: 57, latin: nil) == nil)
    }

    @Test func keypadKeysKeepTheirCharacter() {
        #expect(SequenceKey.name(keyCode: 83, latin: "1") == "1")
        #expect(SequenceKey.name(keyCode: 67, latin: "*") == "*")
        #expect(SequenceKey.name(keyCode: 83, latin: nil) == nil)
    }

    @Test func extendedKeys() throws {
        for (name, code) in KeyCodes.extended {
            #expect(SequenceKey.isValid(name))
            #expect(SequenceKey.normalize(name.uppercased()) == name)
            #expect(SequenceKey.name(keyCode: code, latin: nil) == name)
            #expect(SequenceKey.name(keyCode: code, latin: "a") == name)
        }
        #expect(SequenceKey.display("stop") == "Stop")
        #expect(SequenceKey.spoken("again") == "Again")
        #expect(SequenceKey.display("f21") == "F21")
    }
}

@Suite struct ExtendedKeyCodeTests {
    @Test func table() {
        #expect(KeyCodes.extended.count == 14)
        #expect(KeyCodes.extended["stop"] == 0x1078)
        #expect(KeyCodes.extended["again"] == 0x1079)
        #expect(KeyCodes.extended["f24"] == 0x1073)
        for (name, code) in KeyCodes.extended {
            #expect(code > 0x1000)
            #expect(KeyCodes.isExtended(code))
            #expect(KeyCodes.code(for: name) == code)
            #expect(KeyCodes.name(for: code) == name)
            let usage = KeyCodes.hidUsage(of: code)!
            #expect(KeyCodes.extendedCode(hidUsage: usage) == code)
        }
    }

    @Test(arguments: [0x04, 0x28, 0x68, 0x75, 0x7F, 0xE0, 0x1078] as [UInt32])
    func usagesMacOSReads(_ usage: UInt32) { #expect(KeyCodes.extendedCode(hidUsage: usage) == nil) }

    @Test func notExtended() {
        #expect(!KeyCodes.isExtended(0))
        #expect(!KeyCodes.isExtended(0x1000))
        #expect(KeyCodes.hidUsage(of: 0x78) == nil)
        #expect(KeyCodes.extendedDisplay("a") == nil)
    }

    @Test func extendedHotkeys() throws {
        let stop = try #require(Hotkey(string: "stop"))
        #expect(stop == .combo(keyCode: 0x1078, modifiers: []))
        #expect(stop.isValid)
        #expect(stop.display == "Stop")
        #expect(stop.string == "stop")
        let again = try #require(Hotkey(string: "Shift+Cmd+Again"))
        #expect(again.string == "shift+cmd+again")
        #expect(again.display == "⇧⌘Again")
        #expect(Hotkey(string: "f21")?.display == "F21")
        #expect(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(again)) == again)
        #expect(Hotkey(string: "stop+again") == nil)
    }
}

@Suite struct ModifierKeyTests {
    @Test func physicalMappings() {
        let cases: [(ModifierKey, UInt16, ModifierSet, String)] = [
            (.leftCommand, 55, .command, "Left ⌘"), (.rightCommand, 54, .command, "Right ⌘"),
            (.leftShift, 56, .shift, "Left ⇧"), (.rightShift, 60, .shift, "Right ⇧"),
            (.leftOption, 58, .option, "Left ⌥"), (.rightOption, 61, .option, "Right ⌥"),
            (.leftControl, 59, .control, "Left ⌃"), (.rightControl, 62, .control, "Right ⌃"),
            (.function, 63, .function, "fn")]
        #expect(cases.count == ModifierKey.allCases.count)
        for (key, code, flag, label) in cases {
            #expect(key.keyCode == code)
            #expect(ModifierKey(keyCode: code) == key)
            #expect(key.flag == flag)
            #expect(key.display == label)
        }
        #expect(ModifierKey(keyCode: 0) == nil)
        #expect(ModifierKey(keyCode: UInt16.max) == nil)
    }
    @Test func symbols() {
        #expect(ModifierSet().symbols == "")
        #expect(ModifierSet.function.symbols == "")
        #expect(ModifierSet([.command, .shift, .option, .control, .function]).symbols == "⌃⌥⇧⌘")
        #expect(ModifierSet([.command, .option]).symbols == "⌥⌘")
    }
}

@Suite struct KeyCodesTests {
    @Test func ansiRoundTrips() {
        #expect(KeyCodes.ansi.count == 100)
        for (name, code) in KeyCodes.ansi {
            #expect(KeyCodes.code(for: name) == code)
            #expect(KeyCodes.name(for: code) == name)
        }
        #expect(KeyCodes.code(for: "unknown") == nil)
        #expect(KeyCodes.code(for: "") == nil)
        #expect(KeyCodes.name(for: UInt16.max) == nil)
    }
}

@Suite struct HotkeyTests {
    @Test(arguments: ["pause", "PAUSE", "Pause"])
    func pauseAlias(_ text: String) throws {
        let h = try #require(Hotkey(string: text))
        #expect(h == .combo(keyCode: 113, modifiers: []))
        #expect(h.isValid)
        #expect(h.string == "f15")
        #expect(h.display == "F15")
        #expect(KeyCodes.name(for: 113) == "f15")
    }
    @Test func pauseAliasWithModifiers() {
        let h = Hotkey(string: "shift+pause")
        #expect(h == .combo(keyCode: 113, modifiers: .shift))
        #expect(h?.string == "shift+f15")
    }
    @Test(arguments: ["option+shift+cmd+f", "Cmd+Shift+Option+F", "f+COMMAND+alt+SHIFT", "shift+opt+command+f"])
    func realLeader(_ text: String) throws {
        let h = try #require(Hotkey(string: text))
        #expect(h == .combo(keyCode: 3, modifiers: [.option, .shift, .command]))
        #expect(h.string == "option+shift+cmd+f")
        #expect(h.display == "⌥⇧⌘F")
        #expect(h.isValid)
    }
    @Test func displaysAndCanonicalOrder() {
        let cases: [(String, Hotkey, String)] = [
            ("shift+f15", .combo(keyCode: 113, modifiers: .shift), "⇧F15"),
            ("f13", .combo(keyCode: 105, modifiers: []), "F13"),
            ("control+space", .combo(keyCode: 49, modifiers: .control), "⌃Space"),
            ("right-option", .modifierTap(.rightOption), "Right ⌥"),
            ("cmd+return", .combo(keyCode: 36, modifiers: .command), "⌘↩"),
            ("cmd+tab", .combo(keyCode: 48, modifiers: .command), "⌘⇥"),
            ("cmd+escape", .combo(keyCode: 53, modifiers: .command), "⌘⎋"),
            ("cmd+delete", .combo(keyCode: 51, modifiers: .command), "⌘⌫")]
        for (text, h, label) in cases {
            #expect(Hotkey(string: text) == h)
            #expect(h.display == label)
            if case .modifierTap = h { #expect(!h.isValid) } else { #expect(h.isValid) }
        }
        #expect(Hotkey.combo(keyCode: 0, modifiers: [.command, .shift, .control, .option]).string == "ctrl+option+shift+cmd+a")
    }
    @Test(arguments: ["", "unknown+a", "cmd+unknown", "cmd+a+b", "cmd+", "+cmd+a"])
    func invalidParsing(_ text: String) { #expect(Hotkey(string: text) == nil) }

    @Test func validity() {
        #expect(Hotkey.combo(keyCode: 0, modifiers: []).isValid)
        #expect(!Hotkey.combo(keyCode: 0, modifiers: [.function, .command]).isValid)
        for code in SequenceKey.functionKeyCodes.keys { #expect(Hotkey.combo(keyCode: code, modifiers: []).isValid) }
        for key in ModifierKey.allCases {
            #expect(!Hotkey.modifierTap(key).isValid)
            #expect(!Hotkey.combo(keyCode: key.keyCode, modifiers: []).isValid)
        }
        #expect(!Hotkey.combo(keyCode: 57, modifiers: []).isValid)
    }
    @Test(arguments: ["home", "end", "pageup", "pagedown", "space", "return", "a", "1", "left", "keypad0", "escape"])
    func bareLeader(_ name: String) throws {
        let hotkey = try #require(Hotkey(string: name))
        #expect(hotkey.isValid)
        #expect(hotkey.string == name)
        #expect(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(hotkey)) == hotkey)
    }
    @Test func homeLeader() {
        #expect(Hotkey(string: "home") == .combo(keyCode: 115, modifiers: []))
        #expect(Hotkey(string: "HOME")?.display == "Home")
        #expect(Hotkey(string: "shift+home")?.isValid == true)
    }
    @Test func roundTripsAndCodable() throws {
        var hotkeys = ModifierKey.allCases.map(Hotkey.modifierTap)
        hotkeys += SequenceKey.functionKeyCodes.keys.map { .combo(keyCode: $0, modifiers: []) }
        for code in KeyCodes.ansi.values {
            for flags: ModifierSet in [.control, .option, .shift, .command, [.control, .option, .shift, .command]] {
                hotkeys.append(.combo(keyCode: code, modifiers: flags))
            }
        }
        for h in hotkeys {
            #expect(Hotkey(string: h.string) == h)
            let data = try JSONEncoder().encode(h)
            #expect(try JSONDecoder().decode(String.self, from: data) == h.string)
            #expect(try JSONDecoder().decode(Hotkey.self, from: data) == h)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Hotkey.self, from: Data("\"nonsense\"".utf8)) }
    }
}

@Suite struct ModifierTapDetectorTests {
    @Test(arguments: ModifierKey.allCases) func consecutiveTaps(_ key: ModifierKey) {
        var d = ModifierTapDetector()
        for time in [0.0, 1.0] {
            #expect(d.flagsChanged(keyCode: key.keyCode, modifiers: key.flag, time: time) == nil)
            #expect(d.flagsChanged(keyCode: key.keyCode, modifiers: [], time: time + 0.1) == key)
        }
    }
    @Test func noCandidate() {
        var d = ModifierTapDetector()
        #expect(d.flagsChanged(keyCode: 61, modifiers: [], time: 0) == nil)
        #expect(d.flagsChanged(keyCode: 61, modifiers: [.option, .shift], time: 1) == nil)
        #expect(d.flagsChanged(keyCode: 61, modifiers: [], time: 1.1) == nil)
    }
    @Test(arguments: ["slow", "second", "normal", "different", "unknown"])
    func cancellations(_ scenario: String) {
        var d = ModifierTapDetector(maxDuration: 0.2)
        #expect(d.flagsChanged(keyCode: 61, modifiers: .option, time: 0) == nil)
        switch scenario {
        case "second": #expect(d.flagsChanged(keyCode: 56, modifiers: [.shift, .option], time: 0.05) == nil)
        case "normal": d.keyDown()
        case "different": #expect(d.flagsChanged(keyCode: 58, modifiers: [], time: 0.1) == nil); return
        case "unknown": #expect(d.flagsChanged(keyCode: 0, modifiers: .option, time: 0.05) == nil)
        default: break
        }
        #expect(d.flagsChanged(keyCode: 61, modifiers: [], time: scenario == "slow" ? 0.3 : 0.15) == nil)
    }
}
