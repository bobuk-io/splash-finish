// Fuzzy matching of short names: launchers, pickers, choice lists and filters.
import Foundation

/// How a query matches a text. Smaller is better.
public enum FuzzyMatchKind: Int, Comparable, Sendable, CaseIterable {
    /// The whole text, ignoring case, diacritics, spaces and punctuation.
    case exact
    /// The start of the text.
    case prefix
    /// The start of a later word, or each query word starts a text word in order.
    case wordStart
    /// The first letters of the text words, in order ("vsc" → "Visual Studio Code").
    case initials
    /// Anywhere in the text, in one piece.
    case substring
    /// Every query letter in order, with gaps ("1pwd" → "1Password").
    case scattered
    /// Like `scattered`, with typos: a wrong or an extra query letter ("1pvd" → "1Password").
    case typo

    /// `exact` … `substring`: the query appears in the text as typed.
    public var isContiguous: Bool { self <= .substring }

    public static func < (lhs: FuzzyMatchKind, rhs: FuzzyMatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One match of a query in a text.
public struct FuzzyMatch: Sendable, Equatable {
    public let kind: FuzzyMatchKind
    /// Alignment score, higher is better. Compare scores of one query only.
    public let score: Int
    /// Wrong or extra query letters: 0 unless `kind` is `.typo`.
    public let typos: Int
    /// Offsets of the matched characters (`Character`s of the text), ascending. For highlighting.
    public let positions: [Int]

    /// Better kind first, then the higher score.
    public func isBetter(than other: FuzzyMatch) -> Bool {
        kind != other.kind ? kind < other.kind : score > other.score
    }
}

/// A query prepared once for many texts.
///
/// Matching is an fzf-style alignment: query letters in order, with bonuses for word starts,
/// camel case humps and consecutive letters, and penalties for gaps. A query of 4 or more letters
/// may also have one typo (8 or more: two): a wrong letter or an extra letter. The first letter
/// never is a typo. Case, diacritics and width are ignored, and the query is also tried as typed
/// on the wrong keyboard layout (`KeyboardLayoutSwap`).
public struct FuzzyQuery: Sendable {
    struct Variant: Sendable {
        /// Folded query words.
        let words: [String]
        /// The words joined.
        let compact: [Character]
    }

    let variants: [Variant]
    let allowsTypos: Bool

    /// - Parameters:
    ///   - layoutSwap: also try the query as typed on the wrong keyboard layout.
    ///   - typos: allow wrong and extra letters in longer queries.
    public init(_ query: String, layoutSwap: Bool = true, typos: Bool = true) {
        let texts = layoutSwap ? KeyboardLayoutSwap.variants(of: query) : [query]
        variants = texts.map { FuzzyMatcher.words(in: $0) }.filter { !$0.isEmpty }
            .map { Variant(words: $0, compact: Array($0.joined())) }
        allowsTypos = typos
    }

    /// No letters or digits: the query matches nothing (callers usually list everything).
    public var isEmpty: Bool { variants.isEmpty }

    /// The best match in `text`, or nil.
    public func match(_ text: String) -> FuzzyMatch? {
        guard !variants.isEmpty else { return nil }
        let target = FuzzyText(text)
        guard !target.words.isEmpty else { return nil }
        var best: FuzzyMatch?
        for variant in variants {
            guard let found = FuzzyMatcher.match(variant, in: target, typos: allowsTypos) else { continue }
            if best.map({ found.isBetter(than: $0) }) ?? true { best = found }
        }
        return best
    }

    /// The best match in any of `texts`, with the index of that text.
    public func bestMatch(in texts: [String]) -> (index: Int, match: FuzzyMatch)? {
        var best: (index: Int, match: FuzzyMatch)?
        for (index, text) in texts.enumerated() {
            guard let found = match(text) else { continue }
            if best.map({ found.isBetter(than: $0.match) }) ?? true { best = (index, found) }
        }
        return best
    }
}

public enum FuzzyMatcher {
    /// Alignment scores, after fzf (`src/algo/algo.go`).
    static let scoreMatch = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let bonusBoundaryWhite = 10
    static let bonusBoundary = 8
    static let bonusCamel = 7
    static let bonusConsecutive = 4
    static let firstCharMultiplier = 2
    /// A wrong or extra query letter.
    static let typoPenalty = -14
    /// Longer texts get only contiguous matches: alignment cost grows with length × query.
    static let maxAlignedLength = 512
    static let maxAlignedQuery = 64

    /// Typos allowed for a query of `length` letters and digits.
    public static func allowedTypos(forQueryLength length: Int) -> Int {
        length >= 8 ? 2 : length >= 4 ? 1 : 0
    }

    /// The best match of `query` in `text`, or nil. See `FuzzyQuery`.
    public static func match(_ query: String, in text: String, layoutSwap: Bool = true, typos: Bool = true) -> FuzzyMatch? {
        FuzzyQuery(query, layoutSwap: layoutSwap, typos: typos).match(text)
    }

    /// The items that match `query` in any of their texts: better kind first, then higher score,
    /// then the given order. A query without letters or digits keeps every item in order.
    public static func filter<Item>(_ items: [Item], matching query: String, layoutSwap: Bool = true,
                                    typos: Bool = true, texts: (Item) -> [String]) -> [Item] {
        let prepared = FuzzyQuery(query, layoutSwap: layoutSwap, typos: typos)
        guard !prepared.isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in prepared.bestMatch(in: texts(item)).map { (offset, item, $0.match) } }
            .sorted { lhs, rhs in
                if lhs.2.kind != rhs.2.kind { return lhs.2.kind < rhs.2.kind }
                if lhs.2.score != rhs.2.score { return lhs.2.score > rhs.2.score }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    /// Lower case without diacritics: "Café" → "cafe", "Ёлка" → "елка".
    public static func fold(_ text: String) -> String {
        // ASCII fast path: most names are plain ASCII, and Foundation folding is the slow part.
        let utf8 = text.utf8
        if utf8.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Folded words of a query: split at every character that is not a letter or a digit.
    public static func words(in query: String) -> [String] {
        fold(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: Matching

    static func match(_ query: FuzzyQuery.Variant, in target: FuzzyText, typos: Bool) -> FuzzyMatch? {
        let kind = contiguousKind(query, target)
        let allowed = typos ? allowedTypos(forQueryLength: query.compact.count) : 0
        if kind == nil {
            if allowed == 0 {
                guard isSubsequence(query.compact, of: target.chars) else { return nil }
            } else {
                // Every query letter absent from the text is a typo.
                let present = target.charSet
                guard query.compact.lazy.filter({ !present.contains($0) }).count <= allowed else { return nil }
            }
        }
        guard query.compact.count <= maxAlignedQuery, target.chars.count <= maxAlignedLength,
              let alignment = align(query.compact, target, maxTypos: kind == nil ? allowed : 0) else {
            // Too long to align: report contiguous matches without positions.
            return kind.map { FuzzyMatch(kind: $0, score: 0, typos: 0, positions: []) }
        }
        let resolved = kind ?? (alignment.typos == 0 ? .scattered : .typo)
        return FuzzyMatch(kind: resolved, score: alignment.score, typos: alignment.typos, positions: alignment.positions)
    }

    private static func contiguousKind(_ query: FuzzyQuery.Variant, _ target: FuzzyText) -> FuzzyMatchKind? {
        let compact = String(query.compact)
        if target.compact == compact { return .exact }
        if target.compact.hasPrefix(compact) { return .prefix }
        if target.tails.dropFirst().contains(where: { $0.hasPrefix(compact) }) { return .wordStart }
        if query.words.count > 1, startsWordsInOrder(query.words, target.words) { return .wordStart }
        if compact.count > 1, isSubsequence(Array(compact), of: Array(target.initials)) { return .initials }
        if target.compact.contains(compact) { return .substring }
        return nil
    }

    private static func startsWordsInOrder(_ query: [String], _ words: [String]) -> Bool {
        var index = words.startIndex
        for token in query {
            guard let found = words[index...].firstIndex(where: { $0.hasPrefix(token) }) else { return false }
            index = words.index(after: found)
        }
        return true
    }

    static func isSubsequence(_ text: [Character], of other: [Character]) -> Bool {
        var index = other.startIndex
        for character in text {
            guard let found = other[index...].firstIndex(of: character) else { return false }
            index = other.index(after: found)
        }
        return true
    }

    // MARK: Alignment

    private struct Alignment {
        let score: Int
        let typos: Int
        /// Character offsets in the original text.
        let positions: [Int]
    }

    /// Where a cell came from: the previous query letter at `column` (or this column for an extra
    /// letter) with `typos` used.
    private struct Step {
        var column: Int32 = -1
        var typos: Int8 = 0
        var aligned = false
    }

    /// Best alignment of `query` in `target` with the fewest typos (at most `maxTypos`).
    /// Cell (i, j, k): query[0...i] used, query[i] on text column j, k typos. O(query × text × typos).
    private static func align(_ query: [Character], _ target: FuzzyText, maxTypos: Int) -> Alignment? {
        let m = query.count, n = target.chars.count, layers = maxTypos + 1
        guard m > 0, n > 0 else { return nil }
        let none = Int.min / 4
        func cell(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * n + j) * layers + k }
        var score = [Int](repeating: none, count: m * n * layers)
        var steps = [Step](repeating: Step(), count: m * n * layers)
        let bonus = target.bonus, chars = target.chars

        for j in 0..<n where chars[j] == query[0] {
            score[cell(0, j, 0)] = scoreMatch + bonus[j] * firstCharMultiplier
        }
        if m > 1 {
            for i in 1..<m {
                let letter = query[i]
                for k in 0..<layers {
                    // Best previous cell at least two columns back, as score + column (see gap below).
                    var farBest = none, farColumn = -1
                    var farTypoBest = none, farTypoColumn = -1
                    for j in 0..<n {
                        if j >= 2 {
                            let p = j - 2
                            let s = score[cell(i - 1, p, k)]
                            if s > none, s + p > farBest { farBest = s + p; farColumn = p }
                            if k > 0 {
                                let t = score[cell(i - 1, p, k - 1)]
                                if t > none, t + p > farTypoBest { farTypoBest = t + p; farTypoColumn = p }
                            }
                        }
                        var top = none, step = Step()
                        func consider(_ value: Int, from column: Int, typos: Int, aligned: Bool) {
                            guard value > top else { return }
                            top = value
                            step = Step(column: Int32(column), typos: Int8(typos), aligned: aligned)
                        }
                        // A gap of g columns costs gapStart + (g - 1) × gapExtension = p - j - 1.
                        if chars[j] == letter {
                            if j >= 1, score[cell(i - 1, j - 1, k)] > none {
                                consider(score[cell(i - 1, j - 1, k)] + scoreMatch + max(bonus[j], bonusConsecutive),
                                         from: j - 1, typos: k, aligned: true)
                            }
                            if farColumn >= 0 {
                                consider(farBest - j - 1 + scoreMatch + bonus[j], from: farColumn, typos: k, aligned: true)
                            }
                        } else if k > 0 {
                            // A wrong letter on this column.
                            if j >= 1, score[cell(i - 1, j - 1, k - 1)] > none {
                                consider(score[cell(i - 1, j - 1, k - 1)] + typoPenalty, from: j - 1, typos: k - 1, aligned: true)
                            }
                            if farTypoColumn >= 0 {
                                consider(farTypoBest - j - 1 + typoPenalty, from: farTypoColumn, typos: k - 1, aligned: true)
                            }
                        }
                        // An extra letter: stays on the column of the previous one.
                        if k > 0, score[cell(i - 1, j, k - 1)] > none {
                            consider(score[cell(i - 1, j, k - 1)] + typoPenalty, from: j, typos: k - 1, aligned: false)
                        }
                        if top > none {
                            score[cell(i, j, k)] = top
                            steps[cell(i, j, k)] = step
                        }
                    }
                }
            }
        }

        for k in 0..<layers {
            var bestColumn = -1, bestScore = none
            for j in 0..<n where score[cell(m - 1, j, k)] > bestScore {
                bestScore = score[cell(m - 1, j, k)]
                bestColumn = j
            }
            guard bestColumn >= 0 else { continue }
            var columns: [Int] = []
            var i = m - 1, j = bestColumn, typos = k
            while true {
                let step = steps[cell(i, j, typos)]
                let isExtra = i > 0 && !step.aligned
                let isWrong = i > 0 && step.aligned && chars[j] != query[i]
                if !isExtra, !isWrong, columns.last != j { columns.append(j) }
                guard i > 0 else { break }
                j = Int(step.column)
                typos = Int(step.typos)
                i -= 1
            }
            var positions: [Int] = []
            for column in columns.reversed() where positions.last != target.owner[column] {
                positions.append(target.owner[column])
            }
            return Alignment(score: bestScore, typos: k, positions: positions)
        }
        return nil
    }
}

/// A text prepared for matching.
struct FuzzyText {
    /// Folded words. Split at non-letters/digits and at camel case ("FaceTime" → face, time).
    let words: [String]
    let compact: String
    /// words[i...].joined() for every i.
    let tails: [String]
    let initials: String
    /// Folded characters of the whole text, for alignment.
    let chars: [Character]
    /// The original character offset of each folded character.
    let owner: [Int]
    /// Bonus of a match on each folded character.
    let bonus: [Int]

    private enum Class {
        case white, nonWord, lower, upper, number
        var isWord: Bool { self == .lower || self == .upper || self == .number }
    }

    private static func classify(_ character: Character) -> Class {
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x61...0x7A: return .lower
            case 0x41...0x5A: return .upper
            case 0x30...0x39: return .number
            case 0x20, 0x09...0x0D: return .white
            default: return .nonWord
            }
        }
        if character.isWhitespace { return .white }
        if character.isNumber { return .number }
        if character.isLetter { return character.isUppercase ? .upper : .lower }
        return .nonWord
    }

    private static func bonus(after previous: Class, on current: Class) -> Int {
        switch (previous, current) {
        case (.white, .lower), (.white, .upper), (.white, .number): return FuzzyMatcher.bonusBoundaryWhite
        case (.nonWord, .lower), (.nonWord, .upper), (.nonWord, .number): return FuzzyMatcher.bonusBoundary
        case (.lower, .upper), (.lower, .number), (.upper, .number), (.number, .lower), (.number, .upper):
            return FuzzyMatcher.bonusCamel
        default: return 0
        }
    }

    /// Every folded character, for the typo prefilter.
    let charSet: Set<Character>

    init(_ text: String) {
        let original = Array(text)
        // Fold the whole text at once; per character only when folding changes the length ("ß" → "ss").
        let whole = Array(FuzzyMatcher.fold(text))
        var chars: [Character] = []
        var owner: [Int] = []
        if whole.count == original.count {
            chars = whole
            owner = Array(original.indices)
        } else {
            for (offset, character) in original.enumerated() {
                let folded = FuzzyMatcher.fold(String(character))
                for piece in folded.isEmpty ? String(character) : folded {
                    chars.append(piece)
                    owner.append(offset)
                }
            }
        }
        var bonus = [Int](repeating: 0, count: chars.count)
        // Words: runs of letters and digits, split at camel case ("FaceTime" → face, time).
        var words: [String] = []
        var wordStart: Int?
        var previousClass = Class.white
        var index = 0
        for offset in original.indices {
            let kind = Self.classify(original[offset])
            let first = index
            while index < chars.count, owner[index] == offset { index += 1 }
            if first < chars.count { bonus[first] = Self.bonus(after: previousClass, on: kind) }
            let splitsCamel = previousClass == .lower && kind == .upper
            previousClass = kind
            if let start = wordStart, !kind.isWord || splitsCamel {
                if first > start { words.append(String(chars[start..<first])) }
                wordStart = nil
            }
            if kind.isWord, wordStart == nil { wordStart = first }
        }
        if let start = wordStart, chars.count > start { words.append(String(chars[start...])) }
        self.words = words
        compact = words.joined()
        tails = words.indices.map { words[$0...].joined() }
        initials = String(words.compactMap(\.first))
        self.chars = chars
        self.owner = owner
        self.bonus = bonus
        charSet = Set(chars)
    }
}
