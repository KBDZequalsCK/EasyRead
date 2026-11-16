import Foundation

enum FB2Error: Error {
    case invalid
}

struct FB2Heading {
    let title: String
    let anchorID: String
}

/// Minimal FictionBook (FB2) renderer. FB2 is XML: sections, titles,
/// paragraphs, poems and base64-embedded images. The app converts the
/// supported subset into the same HTML wrapper used by EPUB and MOBI, so
/// font size, themes, paging and the table of contents work unchanged.
enum FB2Renderer {
    struct Document {
        let body: String
        let images: [String: Data]
        let headings: [FB2Heading]
    }

    static func parse(url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = FB2ParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawBody else {
            throw FB2Error.invalid
        }

        var body = delegate.body
        var images: [String: Data] = [:]
        for (identifier, binary) in delegate.binaries {
            images[binary.fileName] = binary.data
            body = body.replacingOccurrences(
                of: "fb2img:\(identifier)",
                with: "Images/\(binary.fileName)"
            )
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FB2Error.invalid
        }
        return Document(body: body, images: images, headings: delegate.headings)
    }

    static func html(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let document = try parse(url: url)
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-FB2-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

        if !document.images.isEmpty {
            let imagesDirectory = workspace.appendingPathComponent("Images", isDirectory: true)
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            for (name, data) in document.images {
                try? data.write(to: imagesDirectory.appendingPathComponent(name))
            }
        }

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

    /// Returns the image referenced from `<coverpage>`. The shelf only needs
    /// that one binary, but FB2 embeds every image base64-inline, so the
    /// document is parsed once and the requested binary is picked out.
    static func coverData(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = FB2ParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        if let identifier = delegate.coverIdentifier,
           let binary = delegate.binaries[identifier] {
            return binary.data
        }
        // Older files skip <coverpage>; their first illustration is almost
        // always the cover.
        if let identifier = delegate.binaryOrder.first,
           let binary = delegate.binaries[identifier] {
            return binary.data
        }
        return nil
    }
}

private final class FB2ParserDelegate: NSObject, XMLParserDelegate {
    struct Binary {
        let data: Data
        let fileName: String
    }

    var body = ""
    var headings: [FB2Heading] = []
    var binaries: [String: Binary] = [:]
    /// Binary identifiers in document order, for a cover fallback.
    var binaryOrder: [String] = []
    /// Identifier referenced by `<coverpage><image .../></coverpage>`.
    var coverIdentifier: String?
    var sawBody = false

    private var inBody = false
    private var inCoverpage = false
    private var inBinary = false
    private var binaryIdentifier = ""
    private var binaryType = ""
    private var binaryText = ""
    private var sectionDepth = 0
    private var headingIndex = 0
    private var titleBuffer: String?
    private var titleAnchor: String?
    private var stylesInjected = false

    private let styles = """
    <style>
    .fb2-title { font-size: 1.34em; font-weight: 600; line-height: 1.5; margin: 1.5em 0 .8em; }
    .fb2-book-title { font-size: 1.6em; font-weight: 600; text-align: center; margin: 1.2em 0 1.6em; }
    .fb2-subtitle { font-weight: 600; margin: 1.1em 0 .5em; }
    .fb2-epigraph, .fb2-cite { margin: 1em 0; padding-left: 1em; border-left: 3px solid rgba(127,127,127,.35); opacity: .9; }
    .fb2-poem { margin: 1em 0; }
    .fb2-stanza { margin: .8em 0; }
    .fb2-verse { margin: 0 0 .2em; }
    .fb2-text-author { text-align: right; font-style: italic; opacity: .8; }
    .fb2-annotation { margin: 1em 0; padding: .8em 1em; background: rgba(127,127,127,.08); border-radius: 6px; }
    .fb2-image { max-width: 100%; height: auto; display: block; margin: 1em auto; }
    .fb2-empty { height: .8em; }
    .fb2-table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    .fb2-table td, .fb2-table th { border: 1px solid rgba(127,127,127,.35); padding: .35em .5em; }
    </style>
    """

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()

        if name == "body" {
            inBody = true
            sawBody = true
            if !stylesInjected {
                body += styles
                stylesInjected = true
            }
            return
        }
        if !inBody {
            if name == "coverpage" {
                inCoverpage = true
                return
            }
            if name == "image", inCoverpage, coverIdentifier == nil {
                coverIdentifier = imageIdentifier(attributeDict)
            }
            if name == "binary" {
                inBinary = true
                binaryIdentifier = attributeDict["id"] ?? ""
                binaryType = attributeDict["content-type"] ?? ""
                binaryText = ""
            }
            return
        }

        switch name {
        case "section":
            sectionDepth += 1
            append("<section>")
        case "title":
            if sectionDepth > 0 {
                headingIndex += 1
                let anchor = "fb2-h-\(headingIndex)"
                titleAnchor = anchor
                titleBuffer = ""
                append("<div class=\"fb2-title\" id=\"\(anchor)\">")
            } else {
                append("<div class=\"fb2-book-title\">")
            }
        case "subtitle":
            append("<p class=\"fb2-subtitle\">")
        case "p":
            append("<p>")
        case "v":
            append("<p class=\"fb2-verse\">")
        case "text-author":
            append("<p class=\"fb2-text-author\">")
        case "epigraph":
            append("<div class=\"fb2-epigraph\">")
        case "cite":
            append("<div class=\"fb2-cite\">")
        case "poem":
            append("<div class=\"fb2-poem\">")
        case "stanza":
            append("<div class=\"fb2-stanza\">")
        case "annotation":
            append("<div class=\"fb2-annotation\">")
        case "strong":
            append("<strong>")
        case "emphasis":
            append("<em>")
        case "code":
            append("<code>")
        case "sup":
            append("<sup>")
        case "sub":
            append("<sub>")
        case "strikethrough":
            append("<s>")
        case "a":
            let href = attributeDict["href"]
                ?? attributeDict["l:href"]
                ?? attributeDict["xlink:href"]
                ?? ""
            if href.isEmpty {
                append("<a>")
            } else {
                append("<a href=\"\(escapeHTML(href))\">")
            }
        case "image":
            let identifier = imageIdentifier(attributeDict)
            if let identifier {
                append("<img class=\"fb2-image\" src=\"fb2img:\(escapeHTML(identifier))\">")
            }
        case "empty-line":
            append("<div class=\"fb2-empty\"></div>")
        case "table":
            append("<table class=\"fb2-table\">")
        case "tr":
            append("<tr>")
        case "td":
            append("<td>")
        case "th":
            append("<th>")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()

        if name == "coverpage" {
            inCoverpage = false
            return
        }
        if name == "binary" {
            finishBinary()
            return
        }
        if name == "body" {
            inBody = false
            return
        }
        guard inBody else { return }

        switch name {
        case "section":
            sectionDepth = max(0, sectionDepth - 1)
            append("</section>")
        case "title":
            append("</div>")
            if let buffer = titleBuffer, let anchor = titleAnchor {
                let title = collapseWhitespace(buffer)
                if !title.isEmpty {
                    headings.append(FB2Heading(title: title, anchorID: anchor))
                }
            }
            titleBuffer = nil
            titleAnchor = nil
        case "subtitle", "p", "v", "text-author":
            append("</p>")
        case "epigraph", "cite", "poem", "stanza", "annotation":
            append("</div>")
        case "strong":
            append("</strong>")
        case "emphasis":
            append("</em>")
        case "code":
            append("</code>")
        case "sup":
            append("</sup>")
        case "sub":
            append("</sub>")
        case "strikethrough":
            append("</s>")
        case "a":
            append("</a>")
        case "table":
            append("</table>")
        case "tr":
            append("</tr>")
        case "td":
            append("</td>")
        case "th":
            append("</th>")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBinary {
            binaryText += string
            return
        }
        guard inBody else { return }
        body += escapeHTML(string)
        if titleBuffer != nil {
            titleBuffer? += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inBody, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        body += escapeHTML(text)
        if titleBuffer != nil {
            titleBuffer? += text
        }
    }

    private func finishBinary() {
        defer {
            inBinary = false
            binaryIdentifier = ""
            binaryType = ""
            binaryText = ""
        }
        guard !binaryIdentifier.isEmpty,
              let data = Data(base64Encoded: binaryText, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            return
        }
        let ext = imageExtension(for: binaryType, data: data)
        let safeIdentifier = binaryIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let baseIdentifier = (safeIdentifier as NSString).deletingPathExtension.isEmpty
            ? safeIdentifier
            : (safeIdentifier as NSString).deletingPathExtension
        let fileName = "fb2-\(baseIdentifier).\(ext)"
        binaries[binaryIdentifier] = Binary(data: data, fileName: fileName)
        binaryOrder.append(binaryIdentifier)
    }

    /// Reads `xlink:href` without namespace processing, which keeps `l:href`
    /// and `xlink:href` both available as plain attributes.
    private func imageIdentifier(_ attributes: [String: String]) -> String? {
        let href = attributes["href"]
            ?? attributes["l:href"]
            ?? attributes["xlink:href"]
            ?? ""
        let identifier = href.replacingOccurrences(of: "#", with: "")
        return identifier.isEmpty ? nil : identifier
    }

    private func append(_ html: String) {
        body += html
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func collapseWhitespace(_ string: String) -> String {
        string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func imageExtension(for type: String, data: Data) -> String {
        let lower = type.lowercased()
        if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
        if lower.contains("png") { return "png" }
        if lower.contains("gif") { return "gif" }
        if lower.contains("svg") { return "svg" }
        if lower.contains("webp") { return "webp" }
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        return "bin"
    }
}
