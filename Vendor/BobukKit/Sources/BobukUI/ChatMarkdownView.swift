import AppKit
import BobukCore
import SwiftUI

/// Pure Markdown block parser for chat messages: separates fenced code blocks, headings,
/// blockquotes, list items, and paragraphs while preserving raw Markdown for copying.
enum ChatMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case quote(String)
    case bullet(String)
    case ordered(number: String, text: String)
    case rule
    case table(headers: [String], rows: [[String]])

    static func parse(_ raw: String) -> [ChatMarkdownBlock] {
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [ChatMarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces) == "```" {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = parseTableRow(trimmed),
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces), expectedColumns: headers.count) {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty, let cells = parseTableRow(rowTrimmed) else { break }
                    var normalized = cells
                    if normalized.count < headers.count {
                        normalized.append(contentsOf: repeatElement("", count: headers.count - normalized.count))
                    } else if normalized.count > headers.count {
                        normalized = Array(normalized.prefix(headers.count))
                    }
                    rows.append(normalized)
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let qt = lines[index].trimmingCharacters(in: .whitespaces)
                    if qt.hasPrefix("> ") {
                        quoteLines.append(String(qt.dropFirst(2)))
                        index += 1
                    } else if qt == ">" {
                        quoteLines.append("")
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                index += 1
                continue
            }

            if let ordered = parseOrdered(trimmed) {
                flushParagraph()
                blocks.append(ordered)
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> ChatMarkdownBlock? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...4).contains(hashes), line.count > hashes else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return .heading(level: hashes, text: title)
    }

    private static func parseOrdered(_ line: String) -> ChatMarkdownBlock? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = line[line.index(after: afterDot)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .ordered(number: String(prefix), text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { return nil }
        return cells
    }

    private static func isTableSeparator(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = parseTableRow(line), cells.count == expectedColumns else { return false }
        return cells.allSatisfy { cell in
            let cleaned = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return cleaned.count >= 3 && cleaned.allSatisfy { $0 == "-" }
        }
    }
}

/// Copies plain raw text (never RTF/HTML) to the macOS pasteboard.
@MainActor enum PlainPasteboard {
    static func copy(_ raw: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(raw, forType: .string)
    }
}

struct ChatMarkdownView: View, Equatable {
    let rawMarkdown: String
    let ink: Color
    let muted: Color
    let accent: Color
    let elevated: Color
    let line: Color
    @State private var copiedCodeIndex: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawMarkdown == rhs.rawMarkdown
            && lhs.ink == rhs.ink
            && lhs.muted == rhs.muted
            && lhs.accent == rhs.accent
            && lhs.elevated == rhs.elevated
            && lhs.line == rhs.line
    }

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownBlock.parse(rawMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                blockView(block, index: idx)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: ChatMarkdownBlock, index: Int) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(.system(size: level == 1 ? 16 : (level == 2 ? 14.5 : 13.5), weight: .semibold))
                .foregroundStyle(ink)
                .padding(.top, level <= 2 ? 4 : 2)

        case let .paragraph(text):
            inlineText(text)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundStyle(ink)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(0.6))
                    .frame(width: 2)
                inlineText(text)
                    .font(.system(size: 13))
                    .lineSpacing(3.5)
                    .foregroundStyle(muted)
            }
            .padding(.vertical, 2)

        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(muted)
                inlineText(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(ink)
            }
            .padding(.leading, 4)

        case let .ordered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(muted)
                inlineText(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(ink)
            }
            .padding(.leading, 4)

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let language {
                        Text(language.uppercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(muted)
                    }
                    Spacer()
                    Button {
                        PlainPasteboard.copy(code)
                        copiedCodeIndex = index
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            if copiedCodeIndex == index { copiedCodeIndex = nil }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedCodeIndex == index ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedCodeIndex == index ? "Copied" : "Copy")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(copiedCodeIndex == index ? accent : muted)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw code")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3.5)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(line, lineWidth: 1)
            }

        case .rule:
            Rectangle()
                .fill(line)
                .frame(height: 1)
                .padding(.vertical, 4)

        case let .table(headers, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            inlineText(header)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ink)
                                .padding(.vertical, 7)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(ink)
                                    .padding(.vertical, 6)
                            }
                        }
                        if rowIdx < rows.count - 1 {
                            Rectangle()
                                .fill(line.opacity(0.6))
                                .frame(height: 1)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .background(elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(line, lineWidth: 1)
            }
        }
    }

    private func inlineText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let rendered = try? AttributedString(markdown: text, options: options) {
            return Text(rendered)
        }
        return Text(text)
    }
}
