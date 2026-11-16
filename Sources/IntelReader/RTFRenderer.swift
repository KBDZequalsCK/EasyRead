import Foundation

enum RTFError: Error {
    case invalid
}

struct RTFHeading {
    let title: String
    let anchorID: String
}

/// Lightweight RTF reader. RTF is a stream of groups and control words; this
/// parser keeps paragraphs, basic emphasis, and Chinese/English headings. Tables,
/// images and fields are intentionally rendered as plain readable text.
enum RTFRenderer {
    struct Document {
        let body: String
        let headings: [RTFHeading]
    }

    static func parse(url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        var parser = RTFParser(bytes: [UInt8](data))
        let document = parser.parse()
        guard !document.body.isEmpty else { throw RTFError.invalid }
        return document
    }

    static func html(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let document = try parse(url: url)
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-RTF-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let html = BookImporter.readerDocument(
            body: document.body,
            fontSize: fontSize,
            isDark: isDark
        )
        let htmlURL = workspace.appendingPathComponent("intel-reader.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, workspace)
    }

    static func chapters(for url: URL) throws -> [ReaderChapter] {
        try parse(url: url).headings.map { heading in
            ReaderChapter(
                title: heading.title,
                progress: nil,
                anchorID: heading.anchorID,
                pageIndex: nil,
                level: 0
            )
        }
    }
}

private struct RTFParser {
    private struct State {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var skipped = false
    }

    private struct RunStyle: Equatable {
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let strike: Bool
    }

    private struct Run {
        var text: String
        let style: RunStyle
    }

    private let bytes: [UInt8]
    private var index = 0
    private var state = State()
    private var stack: [State] = []
    private var encoding: String.Encoding = .windowsCP1252
    private var pendingBytes: [UInt8] = []

    private var html = ""
    private var paragraphRuns: [Run] = []
    private var paragraphPlain = ""
    private var headings: [RTFHeading] = []
    private var headingIndex = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() -> RTFRenderer.Document {
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x7B: // {
                stack.append(state)
                index += 1
            case 0x7D: // }
                flushPending()
                if let previous = stack.popLast() {
                    state = previous
                }
                index += 1
            case 0x5C: // backslash
                index += 1
                parseControl()
            default:
                if byte == 0x0D || byte == 0x0A {
                    // Line breaks are RTF source formatting, not text.
                    index += 1
                    continue
                }
                if state.skipped {
                    index += 1
                    continue
                }
                flushPending()
                appendText(String(UnicodeScalar(byte)))
                index += 1
            }
        }
        flushPending()
        finishParagraph()
        return RTFRenderer.Document(body: html, headings: headings)
    }

    private mutating func parseControl() {
        guard index < bytes.count else { return }
        let byte = bytes[index]

        if byte == 0x27 { // \'hh
            index += 1
            guard index + 2 <= bytes.count,
                  let high = hexValue(bytes[index]),
                  let low = hexValue(bytes[index + 1]) else {
                return
            }
            pendingBytes.append(UInt8(high << 4 | low))
            index += 2
            return
        }

        if byte == 0x5C || byte == 0x7B || byte == 0x7D {
            flushPending()
            if !state.skipped {
                appendText(String(UnicodeScalar(byte)))
            }
            index += 1
            return
        }

        if byte == 0x2A { // \*
            flushPending()
            state.skipped = true
            index += 1
            return
        }

        // Control word: letters, optional parameter, optional delimiter.
        var cursor = index
        var word = ""
        while cursor < bytes.count {
            let value = bytes[cursor]
            guard (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) else { break }
            word.append(Character(UnicodeScalar(value)))
            cursor += 1
        }
        guard !word.isEmpty else {
            index += 1
            return
        }

        var parameter: Int?
        var sign = 1
        if cursor < bytes.count, bytes[cursor] == 0x2D {
            sign = -1
            cursor += 1
        }
        var digits = ""
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            digits.append(Character(UnicodeScalar(bytes[cursor])))
            cursor += 1
        }
        if !digits.isEmpty, let value = Int(digits) {
            parameter = value * sign
        }
        if cursor < bytes.count, bytes[cursor] == 0x20 {
            cursor += 1
        }
        index = cursor

        let lower = word.lowercased()
        if lower == "ansicpg", let parameter {
            encoding = encoding(for: parameter)
            return
        }
        if state.skipped { return }

        switch lower {
        case "par", "pard":
            finishParagraph()
        case "line":
            appendText("\n")
        case "tab":
            appendText("\t")
        case "b":
            bold(parameter != 0)
        case "i":
            italic(parameter != 0)
        case "ul":
            underline(parameter != 0)
        case "ulnone":
            underline(false)
        case "plain":
            state.bold = false
            state.italic = false
            state.underline = false
            state.strike = false
        case "strike":
            strike(parameter != 0)
        case "u":
            flushPending()
            if let parameter {
                let value = parameter < 0 ? parameter + 65_536 : parameter
                if let scalar = Unicode.Scalar(UInt32(max(value, 0))) {
                    appendText(String(Character(scalar)))
                }
            }
            if index < bytes.count, bytes[index] == 0x3F { index += 1 }
        case "bin":
            if let parameter, parameter > 0 {
                index = min(index + parameter, bytes.count)
            }
        case "fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
             "header", "footer", "footnote", "annotation", "generator":
            state.skipped = true
        default:
            break
        }
    }

    private mutating func bold(_ enabled: Bool) {
        state.bold = enabled
    }

    private mutating func italic(_ enabled: Bool) {
        state.italic = enabled
    }

    private mutating func underline(_ enabled: Bool) {
        state.underline = enabled
    }

    private mutating func strike(_ enabled: Bool) {
        state.strike = enabled
    }

    private mutating func appendText(_ string: String) {
        guard !state.skipped, !string.isEmpty else { return }
        paragraphPlain += string
        let style = RunStyle(
            bold: state.bold,
            italic: state.italic,
            underline: state.underline,
            strike: state.strike
        )
        if let last = paragraphRuns.last, last.style == style {
            paragraphRuns[paragraphRuns.count - 1].text += string
        } else {
            paragraphRuns.append(Run(text: string, style: style))
        }
    }

    private mutating func flushPending() {
        guard !pendingBytes.isEmpty else { return }
        let bytes = pendingBytes
        pendingBytes.removeAll(keepingCapacity: true)
        if let text = String(bytes: bytes, encoding: encoding) {
            appendText(text)
        } else if let text = String(bytes: bytes, encoding: .isoLatin1) {
            appendText(text)
        }
    }

    private mutating func finishParagraph() {
        flushPending()
        let plain = paragraphPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        let markup = paragraphRuns.map { run -> String in
            var text = escapeHTML(run.text)
            text = text.replacingOccurrences(of: "\n", with: "<br>")
            text = text.replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")
            if run.style.strike { text = "<s>\(text)</s>" }
            if run.style.underline { text = "<u>\(text)</u>" }
            if run.style.italic { text = "<em>\(text)</em>" }
            if run.style.bold { text = "<strong>\(text)</strong>" }
            return text
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        paragraphRuns.removeAll(keepingCapacity: true)
        paragraphPlain = ""
        guard !plain.isEmpty || !markup.isEmpty else { return }
        if !plain.isEmpty, ChapterHeading.looksLikeHeading(plain) {
            headingIndex += 1
            let anchor = "rtf-h-\(headingIndex)"
            html += "<h2 id=\"\(anchor)\">\(markup)</h2>"
            headings.append(RTFHeading(title: plain, anchorID: anchor))
        } else {
            html += "<p>\(markup)</p>"
        }
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41) + 10
        case 0x61...0x66: return Int(byte - 0x61) + 10
        default: return nil
        }
    }

    private func encoding(for codePage: Int) -> String.Encoding {
        switch codePage {
        case 65001:
            return .utf8
        case 936:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case 950:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            )
        case 1250:
            return .windowsCP1250
        case 1251:
            return .windowsCP1251
        case 1254:
            return .windowsCP1254
        default:
            return .windowsCP1252
        }
    }
}
