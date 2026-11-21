import AppKit
import SwiftUI
import Testing
@testable import BobukUI

struct PickerSelectionTests {
    @Test func clampsWithoutWrapping() {
        #expect(PickerSelection.move(0, by: -1, count: 3) == 0)
        #expect(PickerSelection.move(2, by: 1, count: 3) == 2)
        #expect(PickerSelection.move(1, by: -1, count: 3) == 0)
        #expect(PickerSelection.move(1, by: 1, count: 3) == 2)
        #expect(PickerSelection.move(0, by: 1, count: 0) == nil)
    }

    @Test func optionalSelectionReturnsToTypedInput() {
        #expect(PickerSelection.move(nil, by: -1, count: 2, allowsEmpty: true) == nil)
        #expect(PickerSelection.move(nil, by: 1, count: 2, allowsEmpty: true) == 0)
        #expect(PickerSelection.move(0, by: -1, count: 2, allowsEmpty: true) == nil)
        #expect(PickerSelection.move(1, by: 1, count: 2, allowsEmpty: true) == 1)
        #expect(PickerSelection.move(20, by: 0, count: 2) == 1)
    }

    @Test func extremeInputDoesNotOverflow() {
        #expect(PickerSelection.move(Int.max, by: Int.max, count: 3) == 2)
        #expect(PickerSelection.move(Int.min, by: Int.min, count: 3) == 0)
    }
}

@MainActor struct PickerGeometryTests {
    @Test func badgeColumnUsesOneMeasuredWidthAndCapsLongAliases() {
        #expect(PickerMetrics.badgeWidth(for: []) == 44)
        #expect(PickerMetrics.badgeWidth(for: ["HA", "NOCLAWS"]) >= 54)
        #expect(PickerMetrics.badgeWidth(for: [String(repeating: "W", count: 200)]) == 96)
    }

    @Test func footerWrapsWholeGroupsWithoutOverlap() {
        let frames = HintPacking.frames(sizes: [.init(width: 120, height: 12), .init(width: 100, height: 12),
                                               .init(width: 90, height: 24)], width: 240)
        #expect(frames[0].minY == frames[1].minY)
        #expect(frames[2].minY >= frames[0].maxY + PickerMetrics.footerLineSpacing)
        #expect(frames[0].maxX + PickerMetrics.footerSpacing <= frames[1].minX)
        #expect(frames.allSatisfy { $0.maxX <= 240 })
        #expect(HintPacking.frames(sizes: [], width: 0).isEmpty)
    }

    @Test func hostingSizesAgreeForDifferentBadgeLengths() {
        _ = NSApplication.shared
        let palette = PickerPalette(surface: .white, text: .black, secondary: .gray,
                                    accent: .blue, border: .gray, badgeInk: .white)
        let width = PickerMetrics.badgeWidth(for: ["HA", "NOCLAWS"])
        for text in ["HA", "NOCLAWS", String(repeating: "long", count: 20)] {
            let badge = NSHostingView(rootView: PickerBadge(text, width: width, palette: palette))
            #expect(abs(badge.fittingSize.width - width) < 0.01)
            #expect(abs(badge.fittingSize.height - PickerMetrics.badgeHeight) < 0.01)
        }
        let row = NSHostingView(rootView: PickerRow(selected: true, palette: palette) {
            Text("A row").frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 300))
        #expect(abs(row.fittingSize.height - PickerMetrics.rowHeight) < 0.01)
    }
}

struct FuzzyHighlightTests {
    @Test func marksMatchedCharactersInRuns() {
        let text = AttributedString.highlighting("1Password", query: "1pwd", color: .orange)
        let runs = text.runs.map { (String(text[$0.range].characters), $0.inlinePresentationIntent == .stronglyEmphasized) }
        #expect(runs.map(\.0) == ["1P", "ass", "w", "or", "d"])
        #expect(runs.map(\.1) == [true, false, true, false, true])
        #expect(text.runs.first?.foregroundColor == .orange)
    }

    @Test func plainWithoutMatch() {
        let text = AttributedString.highlighting("Safari", query: "xyz")
        #expect(text.runs.count == 1)
        #expect(String(text.characters) == "Safari")
    }
}
