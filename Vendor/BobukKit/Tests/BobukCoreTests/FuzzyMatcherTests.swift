import Testing
@testable import BobukCore

@Suite struct FuzzyMatcherTests {
    private func kind(_ query: String, _ text: String) -> FuzzyMatchKind? { FuzzyMatcher.match(query, in: text)?.kind }

    @Test func contiguousKinds() {
        #expect(kind("safari", "Safari") == .exact)
        #expect(kind("SAF", "Safari") == .prefix)
        #expect(kind("visual studio code", "Visual Studio Code") == .exact)
        #expect(kind("visualstu", "Visual Studio Code") == .prefix)
        #expect(kind("code", "Visual Studio Code") == .wordStart)
        #expect(kind("studio co", "Visual Studio Code") == .wordStart)
        #expect(kind("vis co", "Visual Studio Code") == .wordStart)
        #expect(kind("vsc", "Visual Studio Code") == .initials)
        #expect(kind("udi", "Visual Studio Code") == .substring)
        #expect(kind("time", "FaceTime") == .wordStart)
        #expect(kind("ft", "FaceTime") == .initials)
        #expect(kind("node.js", "Node.js") == .exact)
        #expect(kind("7", "1Password 7") == .wordStart)
    }

    @Test func scatteredLetters() {
        #expect(kind("1pwd", "1Password") == .scattered)
        #expect(kind("terminl", "Terminal") == .scattered)
        #expect(kind("xcd", "Xcode") == .scattered)
        #expect(kind("code vis", "Visual Studio Code") == nil)
        #expect(kind("xyz", "Visual Studio Code") == nil)
    }

    @Test func typos() {
        let wrong = FuzzyMatcher.match("1pvd", in: "1Password")
        #expect(wrong?.kind == .typo)
        #expect(wrong?.typos == 1)
        #expect(kind("1pasxsword", "1Password") == .typo)
        #expect(kind("setigns", "System Settings") == .typo)
        // Short queries get no typos; the first letter never is one.
        #expect(kind("1pv", "1Password") == nil)
        #expect(kind("xpwd", "1Password") == nil)
        // Two typos only from eight letters.
        #expect(kind("1pazzwrd", "1Password")  == .typo)
        #expect(kind("1pzzd", "1Password") == nil)
        #expect(FuzzyMatcher.match("1pvd", in: "1Password", typos: false) == nil)
    }

    @Test func fallbackTypoForThreeLetters() {
        let query = FuzzyQuery("1pv")
        #expect(query.hasFallback)
        #expect(query.match("1Password") == nil)
        #expect(query.match("1Password", fallback: true)?.kind == .typo)
        #expect(!FuzzyQuery("1p").hasFallback)
        #expect(!FuzzyQuery("1pwd").hasFallback)
        #expect(!FuzzyQuery("1pv", typos: false).hasFallback)
        #expect(FuzzyQuery("xpv").match("1Password", fallback: true) == nil)
        // The filter falls back only when the normal pass matched nothing.
        let apps = ["1Password", "Safari", "Spotify", "Slack"]
        #expect(FuzzyMatcher.filter(apps, matching: "1pv", texts: { [$0] }) == ["1Password"])
        #expect(FuzzyMatcher.filter(apps, matching: "saf", texts: { [$0] }) == ["Safari"])
    }

    @Test func foldingAndLayouts() {
        #expect(kind("cafe", "Café Racer") == .prefix)
        #expect(kind("CAFÉ", "cafe") == .exact)
        #expect(kind("елка", "Ёлка") == .exact)
        #expect(kind("ыфафкш", "Safari") == .exact)
        #expect(kind("ntktuhfv", "Телеграм") == .exact)
        #expect(kind("ьуыыфпуы", "Messages") == .exact)
        #expect(FuzzyMatcher.match("ыфафкш", in: "Safari", layoutSwap: false) == nil)
        #expect(kind("strasse", "Straße") == .exact)
    }

    @Test func emptyInputs() {
        #expect(FuzzyMatcher.match("", in: "Safari") == nil)
        #expect(FuzzyMatcher.match("  -", in: "Safari") == nil)
        #expect(FuzzyMatcher.match("a", in: "") == nil)
        #expect(FuzzyQuery(" - ").isEmpty)
    }

    @Test func positionsForHighlighting() {
        #expect(FuzzyMatcher.match("1pwd", in: "1Password")?.positions == [0, 1, 5, 8])
        #expect(FuzzyMatcher.match("vsc", in: "Visual Studio Code")?.positions == [0, 7, 14])
        #expect(FuzzyMatcher.match("saf", in: "Safari")?.positions == [0, 1, 2])
        // Wrong and extra letters are not highlighted.
        #expect(FuzzyMatcher.match("1pvd", in: "1Password")?.positions.count == 3)
        // Offsets are characters of the original text, also after "ß" folds to "ss".
        #expect(FuzzyMatcher.match("ae", in: "Straße")?.positions == [3, 5])
    }

    @Test func scoresPreferWordStartsAndRuns() {
        let boundary = FuzzyMatcher.match("bm", in: "BatMan")!
        let inside = FuzzyMatcher.match("bm", in: "Batman")!
        #expect(boundary.score > inside.score)
        let safari = FuzzyMatcher.match("sfri", in: "Safari")!
        let info = FuzzyMatcher.match("sfri", in: "System Information")!
        #expect(safari.isBetter(than: info))
    }

    @Test func filterOrdersByKindThenScoreThenInput() {
        let records = ["A", "AAAA", "CNAME", "MX", "TXT"]
        #expect(FuzzyMatcher.filter(records, matching: "", texts: { [$0] }) == records)
        #expect(FuzzyMatcher.filter(records, matching: "m", texts: { [$0] }) == ["MX", "CNAME"])
        #expect(FuzzyMatcher.filter(records, matching: "x", texts: { [$0] }) == ["MX", "TXT"])
        #expect(FuzzyMatcher.filter(records, matching: "q", texts: { [$0] }).isEmpty)
        let apps = ["System Information", "Safari", "Screen Sharing", "Terminal"]
        #expect(FuzzyMatcher.filter(apps, matching: "sfri", texts: { [$0] }).first == "Safari")
        #expect(FuzzyMatcher.filter(apps, matching: "term", texts: { [$0] }) == ["Terminal", "System Information"])
        // Any of the item's texts may match.
        let pairs = [("one", "alpha"), ("two", "beta")]
        #expect(FuzzyMatcher.filter(pairs, matching: "bet", texts: { [$0.0, $0.1] }).map(\.0) == ["two"])
    }

    @Test func longTextsGetContiguousMatchesOnly() {
        let long = String(repeating: "lorem ipsum ", count: 60) + "needle"
        #expect(FuzzyMatcher.match("needle", in: long)?.kind == .wordStart)
        #expect(FuzzyMatcher.match("ndl", in: long) == nil)
    }
}
