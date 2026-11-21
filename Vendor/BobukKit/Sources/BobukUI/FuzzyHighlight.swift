import BobukCore
import SwiftUI

public extension AttributedString {
    /// `text` with the characters at `positions` (character offsets, as in `FuzzyMatch.positions`)
    /// bold and, when given, in `color`. Use it as `Text(AttributedString.highlighting(...))`;
    /// the row keeps its own font.
    static func highlighting(_ text: String, positions: [Int], color: Color? = nil) -> AttributedString {
        let marked = Set(positions)
        var result = AttributedString()
        var run = ""
        var runMarked = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runMarked {
                piece.inlinePresentationIntent = .stronglyEmphasized
                if let color { piece.foregroundColor = color }
            }
            result += piece
            run = ""
        }
        for (offset, character) in text.enumerated() {
            let isMarked = marked.contains(offset)
            if isMarked != runMarked { flush(); runMarked = isMarked }
            run.append(character)
        }
        flush()
        return result
    }

    /// `text` with the letters that `query` matched highlighted (also by the fallback pass of a
    /// 3-letter query); plain when nothing matched.
    static func highlighting(_ text: String, query: String, color: Color? = nil) -> AttributedString {
        let prepared = FuzzyQuery(query)
        let match = prepared.match(text) ?? prepared.match(text, fallback: true)
        return highlighting(text, positions: match?.positions ?? [], color: color)
    }
}
