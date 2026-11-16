import Foundation

struct MarkdownHeading {
    let title: String
    let identifier: String
    let level: Int
}

/// A small, dependency-free Markdown renderer for the reader. It intentionally
/// covers the constructs that appear in notes and README-style documents:
/// headings, paragraphs, lists, task lists, blockquotes, fenced code, tables,
/// links, images, emphasis, strikethrough and inline code.
///
/// Raw HTML is escaped rather than passed through, so opening a local Markdown
/// file cannot inject markup into the reader page.
enum MarkdownRenderer {
    static let hardBreakMarker = "\u{E00F}"

    static func bodyHTML(from markdown: String, sourceURL: URL?) -> String {
        var normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        let lines = strippingFrontMatter(normalized.components(separatedBy: "\n"))
        return MarkdownBuilder(sourceURL: sourceURL).renderBlocks(lines, tight: false)
    }

    /// Reuses the real block parser so the table of contents matches the
    /// rendered document exactly, including fenced code and setext headings.
    static func outline(from markdown: String) -> [MarkdownHeading] {
        var normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        let lines = strippingFrontMatter(normalized.components(separatedBy: "\n"))
        let builder = MarkdownBuilder(sourceURL: nil)
        _ = builder.renderBlocks(lines, tight: false)
        return builder.headings
    }

    static func headingIdentifier(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "md-h-\(String(hash, radix: 16))"
    }

    static func plainHeadingTitle(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"[*_`~]"#,
            with: "",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// YAML front matter is metadata, not reading material. Only strip it when
    /// the opening fence is followed by a key/value line before the closing
    /// fence, so a document that merely starts with a horizontal rule is left
    /// alone.
    private static func strippingFrontMatter(_ lines: [String]) -> [String] {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == "---" else {
            return lines
        }
        let limit = min(lines.count, 80)
        guard limit > 1 else { return lines }
        for index in 1..<limit {
            let marker = lines[index].trimmingCharacters(in: .whitespaces)
            guard marker == "---" || marker == "..." else { continue }
            let metadata = lines[1..<index]
            let looksLikeMetadata = metadata.contains { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                return !value.isEmpty && (value.contains(":") || value.hasPrefix("- "))
            }
            if looksLikeMetadata {
                if index + 1 < lines.count {
                    return Array(lines[(index + 1)...])
                }
                return []
            }
            return lines
        }
        return lines
    }
}

private final class MarkdownBuilder {
    private struct FenceStart {
        let character: Character
        let length: Int
        let info: String
    }

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let start: Int
        let content: String
        let contentIndent: Int
    }

    private let sourceURL: URL?
    private(set) var headings: [MarkdownHeading] = []

    init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    func renderBlocks(_ lines: [String], tight: Bool) -> String {
        var output: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fenceStart(line) {
                var codeLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    if isFenceClose(lines[cursor], fence: fence) {
                        cursor += 1
                        break
                    }
                    codeLines.append(lines[cursor])
                    cursor += 1
                }
                output.append(codeBlockHTML(codeLines.joined(separator: "\n"), info: fence.info))
                index = cursor
                continue
            }

            if isIndentedCode(line) {
                var codeLines: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        codeLines.append("")
                        cursor += 1
                        continue
                    }
                    guard isIndentedCode(candidate) else { break }
                    codeLines.append(stripIndent(candidate, columns: 4))
                    cursor += 1
                }
                while codeLines.last?.isEmpty == true {
                    codeLines.removeLast()
                }
                output.append(codeBlockHTML(codeLines.joined(separator: "\n"), info: ""))
                index = cursor
                continue
            }

            if let heading = heading(line) {
                output.append(headingHTML(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isThematicBreak(line) {
                output.append("<hr>")
                index += 1
                continue
            }

            if isBlockquoteLine(line) {
                var quoteLines: [String] = []
                var cursor = index
                while cursor < lines.count {
                    if let content = blockquoteContent(lines[cursor]) {
                        quoteLines.append(content)
                        cursor += 1
                        continue
                    }
                    if lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                        var next = cursor + 1
                        while next < lines.count,
                              lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                            next += 1
                        }
                        if next < lines.count, isBlockquoteLine(lines[next]) {
                            quoteLines.append("")
                            cursor += 1
                            continue
                        }
                    }
                    break
                }
                let inner = renderBlocks(quoteLines, tight: false)
                output.append("<blockquote>\n\(inner)\n</blockquote>")
                index = cursor
                continue
            }

            if listMarker(line) != nil {
                output.append(renderList(lines, index: &index))
                continue
            }

            if let table = tableDescriptor(lines, at: index) {
                output.append(tableHTML(headers: table.headers,
                                       alignments: table.alignments,
                                       rows: table.rows))
                index = table.next
                continue
            }

            var paragraphLines: [String] = []
            var setextLevel: Int?
            while index < lines.count {
                let candidate = lines[index]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                if !paragraphLines.isEmpty, let level = setextUnderlineLevel(candidate) {
                    setextLevel = level
                    index += 1
                    break
                }
                if !paragraphLines.isEmpty, beginsBlock(candidate, lines: lines, index: index) {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }

            if let setextLevel, !paragraphLines.isEmpty {
                let text = joinedParagraph(paragraphLines)
                output.append(headingHTML(level: setextLevel, text: text))
            } else if !paragraphLines.isEmpty {
                output.append(paragraphHTML(paragraphLines, tight: tight))
            }
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Blocks

    private func paragraphHTML(_ lines: [String], tight: Bool) -> String {
        let text = joinedParagraph(lines)
        let inline = InlineRenderer(sourceURL: sourceURL).render(text)
        return tight ? inline : "<p>\(inline)</p>"
    }

    private func headingHTML(level: Int, text: String) -> String {
        let identifier = MarkdownRenderer.headingIdentifier(for: text)
        headings.append(MarkdownHeading(
            title: MarkdownRenderer.plainHeadingTitle(text),
            identifier: identifier,
            level: level
        ))
        let inline = InlineRenderer(sourceURL: sourceURL).render(text)
        return "<h\(level) id=\"\(identifier)\">\(inline)</h\(level)>"
    }

    private func codeBlockHTML(_ code: String, info: String) -> String {
        var className = ""
        if let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
            let allowed = language.filter { character in
                character.isLetter || character.isNumber || "-_+#.".contains(character)
            }
            if !allowed.isEmpty {
                className = " class=\"language-\(allowed)\""
            }
        }
        return "<pre><code\(className)>\(MarkdownBuilder.escapeHTML(code))</code></pre>"
    }

    private func joinedParagraph(_ lines: [String]) -> String {
        var result = ""
        var previousWasHardBreak = false
        for (index, rawLine) in lines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            let hardBreak = rawLine.hasSuffix("  ") || trimmedLine.hasSuffix("\\")
            var content = trimmedLine
            if content.hasSuffix("\\") {
                content.removeLast()
            }
            if index > 0, !previousWasHardBreak {
                result += softSeparator(previous: result, next: content)
            }
            result += content
            if hardBreak {
                result += MarkdownRenderer.hardBreakMarker
            }
            previousWasHardBreak = hardBreak
        }
        return result
    }

    /// HTML collapses newlines into spaces. Keep the space for Latin text, but
    /// omit it between CJK characters so Chinese paragraphs do not gain gaps.
    private func softSeparator(previous: String, next: String) -> String {
        isCJK(previous.last) && isCJK(next.first) ? "" : " "
    }

    private func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private func heading(_ line: String) -> (level: Int, text: String)? {
        let indent = leadingColumns(line)
        guard indent < 4 else { return nil }
        let content = stripIndent(line, columns: indent)
        let hashes = content.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = content.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("#") {
            var candidate = text
            while candidate.hasSuffix("#") {
                candidate.removeLast()
            }
            if candidate.isEmpty {
                text = ""
            } else if candidate.last?.isWhitespace == true {
                text = candidate.trimmingCharacters(in: .whitespaces)
            }
        }
        return (hashes.count, text)
    }

    private func setextUnderlineLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) {
            return 1
        }
        if trimmed.allSatisfy({ $0 == "-" }) {
            return 2
        }
        return nil
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let characters = trimmed.filter { $0 != " " && $0 != "\t" }
        guard characters.count >= 3, let first = characters.first,
              "*_-".contains(first) else {
            return false
        }
        return characters.allSatisfy { $0 == first }
    }

    private func fenceStart(_ line: String) -> FenceStart? {
        let indent = leadingColumns(line)
        guard indent < 4 else { return nil }
        let content = stripIndent(line, columns: indent)
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let run = content.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = String(content.dropFirst(run.count))
            .trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") {
            return nil
        }
        return FenceStart(character: first, length: run.count, info: info)
    }

    private func isFenceClose(_ line: String, fence: FenceStart) -> Bool {
        let indent = leadingColumns(line)
        guard indent < 4 else { return false }
        let trimmed = stripIndent(line, columns: indent)
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= fence.length else { return false }
        return trimmed.allSatisfy { $0 == fence.character }
    }

    private func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private func isBlockquoteLine(_ line: String) -> Bool {
        blockquoteContent(line) != nil
    }

    private func blockquoteContent(_ line: String) -> String? {
        let indent = leadingColumns(line)
        guard indent < 4 else { return nil }
        var content = stripIndent(line, columns: indent)
        guard content.first == ">" else { return nil }
        content.removeFirst()
        if content.first == " " {
            content.removeFirst()
        }
        return content
    }

    private func beginsBlock(_ line: String, lines: [String], index: Int) -> Bool {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if fenceStart(line) != nil { return true }
        if heading(line) != nil { return true }
        if isBlockquoteLine(line) { return true }
        if listMarker(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if tableDescriptor(lines, at: index) != nil { return true }
        return false
    }

    // MARK: - Lists

    private func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingColumns(line)
        let content = stripIndent(line, columns: indent)
        guard !content.isEmpty else { return nil }

        var markerWidth = 0
        var ordered = false
        var start = 1

        if let first = content.first, "-+*".contains(first) {
            let after = content.index(after: content.startIndex)
            guard after < content.endIndex,
                  content[after] == " " || content[after] == "\t" else {
                return nil
            }
            markerWidth = 1
        } else {
            let digits = content.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let afterDigits = content.index(content.startIndex, offsetBy: digits.count)
            guard afterDigits < content.endIndex,
                  content[afterDigits] == "." || content[afterDigits] == ")" else {
                return nil
            }
            let afterMarker = content.index(after: afterDigits)
            guard afterMarker < content.endIndex,
                  content[afterMarker] == " " || content[afterMarker] == "\t" else {
                return nil
            }
            ordered = true
            start = Int(digits) ?? 1
            markerWidth = digits.count + 1
        }

        var contentStart = content.index(content.startIndex, offsetBy: markerWidth)
        var whitespaceColumns = 0
        while contentStart < content.endIndex {
            let character = content[contentStart]
            if character == " " {
                whitespaceColumns += 1
            } else if character == "\t" {
                whitespaceColumns += 4
            } else {
                break
            }
            contentStart = content.index(after: contentStart)
        }

        return ListMarker(
            indent: indent,
            ordered: ordered,
            start: start,
            content: String(content[contentStart...]),
            contentIndent: indent + markerWidth + whitespaceColumns
        )
    }

    private func renderList(_ lines: [String], index: inout Int) -> String {
        guard let first = listMarker(lines[index]) else { return "" }
        let baseIndent = first.indent
        let ordered = first.ordered
        let contentIndent = max(first.contentIndent, baseIndent + 2)
        var items: [[String]] = []
        var current: [String] = []
        var started = false
        var cursor = index

        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var next = cursor + 1
                while next < lines.count,
                      lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                    next += 1
                }
                guard next < lines.count else { break }
                let nextMarker = listMarker(lines[next])
                let nextIndent = leadingColumns(lines[next])
                if nextIndent > baseIndent ||
                    (nextMarker != nil && nextMarker?.indent == baseIndent &&
                     nextMarker?.ordered == ordered) {
                    cursor += 1
                    continue
                }
                break
            }

            if let marker = listMarker(line) {
                if marker.indent == baseIndent {
                    guard marker.ordered == ordered else { break }
                    if started {
                        items.append(current)
                    }
                    current = [marker.content]
                    started = true
                    cursor += 1
                    continue
                }
                if marker.indent > baseIndent {
                    current.append(stripIndent(line, columns: min(marker.indent, contentIndent)))
                    cursor += 1
                    continue
                }
                break
            }

            let indent = leadingColumns(line)
            if indent > baseIndent {
                current.append(stripIndent(line, columns: min(indent, contentIndent)))
                cursor += 1
                continue
            }

            if beginsBlock(line, lines: lines, index: cursor) {
                break
            }

            current.append(line.trimmingCharacters(in: .whitespaces))
            cursor += 1
        }

        if started {
            items.append(current)
        }
        index = cursor

        var hasTaskItem = false
        var itemHTML: [String] = []
        for item in items {
            var itemLines = item
            var task: Bool?
            if let firstLine = itemLines.first, let parsed = taskPrefix(firstLine) {
                task = parsed.checked
                itemLines[0] = parsed.content
            }
            let inner = renderBlocks(itemLines, tight: true)
            if let checked = task {
                hasTaskItem = true
                let checkedAttribute = checked ? " checked" : ""
                itemHTML.append(
                    "<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checkedAttribute)> \(inner)</li>"
                )
            } else {
                itemHTML.append("<li>\(inner)</li>")
            }
        }

        let tag = ordered ? "ol" : "ul"
        let classAttribute = hasTaskItem ? " class=\"task-list\"" : ""
        let startAttribute = ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        return "<\(tag)\(classAttribute)\(startAttribute)>\n\(itemHTML.joined(separator: "\n"))\n</\(tag)>"
    }

    private func taskPrefix(_ line: String) -> (checked: Bool, content: String)? {
        let characters = Array(line)
        guard characters.count >= 4,
              characters[0] == "[",
              characters[2] == "]",
              characters[3] == " ",
              characters[1] == " " || characters[1] == "x" || characters[1] == "X" else {
            return nil
        }
        return (characters[1] != " ", String(characters.dropFirst(4)))
    }

    // MARK: - Tables

    private func tableDescriptor(
        _ lines: [String],
        at index: Int
    ) -> (headers: [String], alignments: [String], rows: [[String]], next: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        guard headerLine.contains("|") else { return nil }

        let separatorCells = splitTableRow(lines[index + 1])
        guard !separatorCells.isEmpty else { return nil }

        var alignments: [String] = []
        for cell in separatorCells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else {
                return nil
            }
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right {
                alignments.append("center")
            } else if right {
                alignments.append("right")
            } else if left {
                alignments.append("left")
            } else {
                alignments.append("")
            }
        }

        let headers = splitTableRow(headerLine)
        guard headers.count == separatorCells.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard line.contains("|") else { break }
            if heading(line) != nil || fenceStart(line) != nil ||
                isBlockquoteLine(line) || listMarker(line) != nil ||
                isThematicBreak(line) {
                break
            }
            let cells = splitTableRow(line)
            var padded = Array(cells.prefix(headers.count))
            while padded.count < headers.count {
                padded.append("")
            }
            rows.append(padded)
            cursor += 1
        }

        return (headers, alignments, rows, cursor)
    }

    private func splitTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }

        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|", !inCode {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)

        if trimmed.hasPrefix("|"),
           cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeFirst()
        }
        if trimmed.hasSuffix("|"),
           cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private func tableHTML(headers: [String], alignments: [String], rows: [[String]]) -> String {
        var html = "<div class=\"table-wrap\"><table><thead><tr>"
        for (index, cell) in headers.enumerated() {
            html += tableCell(cell, tag: "th", alignment: alignments[index])
        }
        html += "</tr></thead>"
        if !rows.isEmpty {
            html += "<tbody>"
            for row in rows {
                html += "<tr>"
                for (index, cell) in row.enumerated() {
                    html += tableCell(cell, tag: "td", alignment: alignments[index])
                }
                html += "</tr>"
            }
            html += "</tbody>"
        }
        html += "</table></div>"
        return html
    }

    private func tableCell(_ text: String, tag: String, alignment: String) -> String {
        let style = alignment.isEmpty ? "" : " style=\"text-align: \(alignment)\""
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let inline = InlineRenderer(sourceURL: sourceURL).render(trimmed)
        return "<\(tag)\(style)>\(inline)</\(tag)>"
    }

    // MARK: - Indentation helpers

    private func leadingColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return columns
    }

    private func stripIndent(_ line: String, columns: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            let character = line[index]
            if character == " " {
                removed += 1
            } else if character == "\t" {
                removed += 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    fileprivate static func escapeHTML(_ string: String) -> String {
        var result = string.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }
}

private final class InlineRenderer {
    private enum Patterns {
        static let codeSpan = try! NSRegularExpression(
            pattern: #"(?<!\\)(`+)(.*?)\1"#,
            options: [.dotMatchesLineSeparators]
        )
        static let image = try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(((?:[^()\n]|\([^()\n]*\))*)\)"#,
            options: []
        )
        static let link = try! NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(((?:[^()\n]|\([^()\n]*\))*)\)"#,
            options: []
        )
        static let autolink = try! NSRegularExpression(
            pattern: #"<((?:https?|mailto):[^\s<>]+)>"#,
            options: [.caseInsensitive]
        )
        static let token = try! NSRegularExpression(
            pattern: "\u{E000}([0-9]+)\u{E001}",
            options: []
        )
        static let strongEmStar = try! NSRegularExpression(
            pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#,
            options: []
        )
        static let strongEmUnderscore = try! NSRegularExpression(
            pattern: #"___(?=\S)(.+?)(?<=\S)___"#,
            options: []
        )
        static let strongStar = try! NSRegularExpression(
            pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#,
            options: []
        )
        static let strongUnderscore = try! NSRegularExpression(
            pattern: #"__(?=\S)(.+?)(?<=\S)__"#,
            options: []
        )
        static let strikethrough = try! NSRegularExpression(
            pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#,
            options: []
        )
        static let emphasisStar = try! NSRegularExpression(
            pattern: #"\*(?=\S)(.+?)(?<=\S)\*"#,
            options: []
        )
        static let emphasisUnderscore = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])_(?=\S)(.+?)(?<=\S)_(?![A-Za-z0-9_])"#,
            options: []
        )
    }

    private let sourceURL: URL?
    private var tokens: [String] = []
    private let tokenOpen = "\u{E000}"
    private let tokenClose = "\u{E001}"

    init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    func render(_ text: String) -> String {
        // Code spans are protected before backslash escapes so a backslash
        // inside `code` stays literal, as CommonMark expects.
        var value = extractCodeSpans(text)
        value = protectEscapes(value)
        value = extractImages(value)
        value = extractLinks(value)
        value = extractAutolinks(value)
        value = MarkdownBuilder.escapeHTML(value)
        value = applyEmphasis(value)
        value = value.replacingOccurrences(of: MarkdownRenderer.hardBreakMarker, with: "<br>")
        return restoreTokens(value)
    }

    private func stash(_ html: String) -> String {
        tokens.append(html)
        return "\(tokenOpen)\(tokens.count - 1)\(tokenClose)"
    }

    private func restoreTokens(_ input: String) -> String {
        var result = input
        while true {
            let fullRange = NSRange(result.startIndex..., in: result)
            guard let match = Patterns.token.firstMatch(in: result, options: [], range: fullRange),
                  let range = Range(match.range, in: result) else {
                break
            }
            let numberRange = match.range(at: 1)
            let numberText = (result as NSString).substring(with: numberRange)
            let number = Int(numberText) ?? -1
            let replacement = number >= 0 && number < tokens.count ? tokens[number] : ""
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func protectEscapes(_ text: String) -> String {
        let escapable = "\\`*_{}[]()#+-.!~>|"
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, escapable.contains(text[next]) {
                    result += stash(MarkdownBuilder.escapeHTML(String(text[next])))
                    index = text.index(after: next)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private func extractCodeSpans(_ input: String) -> String {
        var result = input
        let fullRange = NSRange(input.startIndex..., in: input)
        let matches = Patterns.codeSpan.matches(in: input, options: [], range: fullRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let contentRange = match.range(at: 2)
            var content = (input as NSString).substring(with: contentRange)
            if content.hasPrefix(" "), content.hasSuffix(" "), content.count > 2 {
                content = String(content.dropFirst().dropLast())
            }
            result.replaceSubrange(
                range,
                with: stash("<code>\(MarkdownBuilder.escapeHTML(content))</code>")
            )
        }
        return result
    }

    private func extractImages(_ input: String) -> String {
        var result = input
        let fullRange = NSRange(input.startIndex..., in: input)
        let matches = Patterns.image.matches(in: input, options: [], range: fullRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let alt = (input as NSString).substring(with: match.range(at: 1))
            let destination = (input as NSString).substring(with: match.range(at: 2))
            result.replaceSubrange(range, with: stash(imageHTML(alt: alt, destination: destination)))
        }
        return result
    }

    private func extractLinks(_ input: String) -> String {
        var result = input
        let fullRange = NSRange(input.startIndex..., in: input)
        let matches = Patterns.link.matches(in: input, options: [], range: fullRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let label = (input as NSString).substring(with: match.range(at: 1))
            let destination = (input as NSString).substring(with: match.range(at: 2))
            let parsed = parseDestination(destination)
            let labelHTML = render(label)
            let html: String
            if isSafeLink(parsed.url) {
                let title = parsed.title.map {
                    " title=\"\(MarkdownBuilder.escapeHTML($0))\""
                } ?? ""
                html = "<a href=\"\(MarkdownBuilder.escapeHTML(parsed.url))\"\(title)>\(labelHTML)</a>"
            } else {
                html = labelHTML
            }
            result.replaceSubrange(range, with: stash(html))
        }
        return result
    }

    private func extractAutolinks(_ input: String) -> String {
        var result = input
        let fullRange = NSRange(input.startIndex..., in: input)
        let matches = Patterns.autolink.matches(in: input, options: [], range: fullRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let destination = (input as NSString).substring(with: match.range(at: 1))
            let html = "<a href=\"\(MarkdownBuilder.escapeHTML(destination))\">\(MarkdownBuilder.escapeHTML(destination))</a>"
            result.replaceSubrange(range, with: stash(html))
        }
        return result
    }

    private func applyEmphasis(_ input: String) -> String {
        var result = input
        result = replace(Patterns.strongEmStar, in: result, template: "<strong><em>$1</em></strong>")
        result = replace(Patterns.strongEmUnderscore, in: result, template: "<strong><em>$1</em></strong>")
        result = replace(Patterns.strongStar, in: result, template: "<strong>$1</strong>")
        result = replace(Patterns.strongUnderscore, in: result, template: "<strong>$1</strong>")
        result = replace(Patterns.strikethrough, in: result, template: "<del>$1</del>")
        result = replace(Patterns.emphasisStar, in: result, template: "<em>$1</em>")
        result = replace(Patterns.emphasisUnderscore, in: result, template: "<em>$1</em>")
        return result
    }

    private func replace(_ pattern: NSRegularExpression, in text: String, template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private func parseDestination(_ raw: String) -> (url: String, title: String?) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ("", nil) }

        var urlPart = ""
        var rest = ""
        if value.hasPrefix("<") {
            if let end = value.firstIndex(of: ">") {
                urlPart = String(value[value.index(after: value.startIndex)..<end])
                rest = String(value[value.index(after: end)...])
            } else {
                urlPart = value
            }
        } else {
            var escaped = false
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == " " || character == "\t" {
                    break
                }
                index = value.index(after: index)
            }
            urlPart = String(value[..<index])
            rest = String(value[index...])
        }

        var title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count >= 2, title.hasPrefix("\""), title.hasSuffix("\"") {
            title = String(title.dropFirst().dropLast())
        } else if title.count >= 2, title.hasPrefix("'"), title.hasSuffix("'") {
            title = String(title.dropFirst().dropLast())
        } else if title.count >= 2, title.hasPrefix("("), title.hasSuffix(")") {
            title = String(title.dropFirst().dropLast())
        } else {
            title = ""
        }

        urlPart = urlPart.replacingOccurrences(of: "\\ ", with: " ")
        return (urlPart, title.isEmpty ? nil : title)
    }

    private func isSafeLink(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") ||
            lower.hasPrefix("http://") ||
            lower.hasPrefix("mailto:")
    }

    private func imageHTML(alt: String, destination: String) -> String {
        let parsed = parseDestination(destination)
        let escapedAlt = MarkdownBuilder.escapeHTML(alt)
        guard !parsed.url.isEmpty else { return escapedAlt }
        let title = parsed.title.map {
            " title=\"\(MarkdownBuilder.escapeHTML($0))\""
        } ?? ""

        if let dataURL = localImageDataURL(for: parsed.url) {
            return "<img src=\"\(dataURL)\" alt=\"\(escapedAlt)\"\(title) loading=\"lazy\">"
        }

        let lower = parsed.url.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") ||
            lower.hasPrefix("data:image/") {
            return "<img src=\"\(MarkdownBuilder.escapeHTML(parsed.url))\" alt=\"\(escapedAlt)\"\(title) loading=\"lazy\">"
        }

        return "<span class=\"missing-image\">\(escapedAlt)</span>"
    }

    private func localImageDataURL(for source: String) -> String? {
        let lower = source.lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("data:") else {
            return nil
        }

        let fileURL: URL
        if lower.hasPrefix("file://") {
            guard let parsed = URL(string: source) else { return nil }
            fileURL = parsed
        } else {
            let decoded = source.removingPercentEncoding ?? source
            if decoded.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: decoded)
            } else {
                guard let base = sourceURL?.deletingLastPathComponent() else { return nil }
                fileURL = base.appendingPathComponent(decoded)
            }
        }

        guard let mimeType = imageMIMEType(for: fileURL.pathExtension),
              let data = try? Data(contentsOf: fileURL),
              data.count <= 10 * 1024 * 1024 else {
            return nil
        }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func imageMIMEType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "bmp":
            return "image/bmp"
        case "heic", "heif":
            return "image/heic"
        default:
            return nil
        }
    }
}