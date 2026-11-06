import Foundation

/// Compact notification previews use inline Markdown, never HTML or remote images.
/// Keep a bounded raw payload for parsing; shorten only the rendered characters.
public enum MessageText {
    public static let maximumBytes = 4096

    public static func clean(_ text: String) -> String {
        var result = ""
        var bytes = 0
        var pendingSpace = false
        for character in text {
            let printable = String(character.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0 == "\u{200D}" || $0 == "\u{200C}" // emoji/script joiners are not terminal controls
            })
            if printable.isEmpty { continue }
            if printable.allSatisfy(\.isWhitespace) { pendingSpace = !result.isEmpty; continue }
            let added = printable.utf8.count + (pendingSpace ? 1 : 0)
            guard bytes + added <= maximumBytes else { break }
            if pendingSpace { result += " " }
            result += printable
            bytes += added
            pendingSpace = false
        }
        return result
    }

    public static func render(_ text: String, limit: Int? = nil) -> AttributedString {
        let source = clean(text)
        var result = (try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // Agent output is untrusted. Do not turn file/custom-scheme URLs into
        // actions, even when the originating terminal supports those schemes.
        for run in Array(result.runs) {
            if let url = run.link, !isSafeLink(url) { result[run.range].link = nil }
        }
        if let limit, result.characters.count > max(0, limit) {
            let end = result.characters.index(result.startIndex, offsetBy: max(0, limit))
            result = AttributedString(result[..<end])
            result.append(AttributedString("…"))
        }
        return result
    }

    public static func plain(_ text: String, limit: Int? = nil) -> String {
        String(render(text, limit: limit).characters)
    }

    public static func isSafeLink(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2048,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return !url.absoluteString.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
