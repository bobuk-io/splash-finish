import BobukCore
import Foundation
import Testing

struct ChatTextScaleTests {
    @Test func clampsAndSnapsToSteps() {
        #expect(ChatTextScale.clamped(1) == 1)
        #expect(abs(ChatTextScale.clamped(1.234) - 1.2) < 0.0001)
        #expect(ChatTextScale.clamped(0.1) == ChatTextScale.range.lowerBound)
        #expect(ChatTextScale.clamped(9) == ChatTextScale.range.upperBound)
        #expect(ChatTextScale.clamped(.nan) == ChatTextScale.standard)
        #expect(ChatTextScale.clamped(.infinity) == ChatTextScale.standard)
    }

    @Test func stepsStopAtTheEnds() {
        #expect(abs(ChatTextScale.stepped(1, by: 1) - 1.1) < 0.0001)
        #expect(abs(ChatTextScale.stepped(1, by: -2) - 0.8) < 0.0001)
        #expect(ChatTextScale.stepped(0.8, by: -1) == 0.8)
        #expect(ChatTextScale.stepped(2, by: 1) == 2)
        // Ten steps up from 1 land exactly on 2, without floating-point drift.
        var value = 1.0
        for _ in 0..<10 { value = ChatTextScale.stepped(value, by: 1) }
        #expect(value == 2)
        #expect(ChatTextScale.percent(value) == "200%")
        #expect(ChatTextScale.percent(1.17) == "120%")
    }

    @Test func sendKeysHaveHintsAndStableCoding() throws {
        #expect(ChatSendKey.commandReturn.label == "⌘↩")
        #expect(ChatSendKey.return.label == "↩")
        let data = try JSONEncoder().encode([ChatSendKey.return, .commandReturn])
        #expect(String(decoding: data, as: UTF8.self) == #"["return","commandReturn"]"#)
    }
}
