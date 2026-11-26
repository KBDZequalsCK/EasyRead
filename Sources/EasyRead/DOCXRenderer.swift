import Foundation

enum DOCXError: Error {
    case invalid
}

struct DOCXHeading {
    let title: String
    let anchorID: String
}

/// Dependency-free DOCX reader. DOCX is a ZIP containing WordprocessingML:
/// paragraphs, runs, heading styles, tables and media. The renderer keeps the
/// reading content (paragraphs, emphasis, headings, inline images) and ignores
/// page layout, headers/footers and fields that only matter to Word.
enum DOCXRenderer {
    struct Document {
        let body: String
        let images: [String: Data]
        let headings: [DOCXHeading]
    }

    static func parse(url: URL) throws -> Document {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            throw DOCXError.invalid
        }
        guard let documentData = try? archive.contents(of: "word/document.xml") else {
            throw DOCXError.invalid
        }

        var relationships: [String: String] = [:]
        if let relData = try? archive.contents(of: "word/_rels/document.xml.rels") {
            let parser = XMLParser(data: relData)
            let delegate = DOCXRelationshipsDelegate()
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            _ = parser.parse()
            relationships = delegate.targets
        }

        var styles: [String: String] = [:]
        if let styleData = try? archive.contents(of: "word/styles.xml") {
            let parser = XMLParser(data: styleData)
            let delegate = DOCXStylesDelegate()
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            _ = parser.parse()
            styles = delegate.names
        }

        let parser = XMLParser(data: documentData)
        let delegate = DOCXDocumentDelegate(
            archive: archive,
            relationships: relationships,
            styles: styles
        )
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawParagraph else {
            throw DOCXError.invalid
        }
        let result = delegate.finish()
        guard !result.body.isEmpty else { throw DOCXError.invalid }
        return result
    }

    static func html(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let document = try parse(url: url)
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-DOCX-\(UUID().uuidString)", isDirectory: true)
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
}

private func docxLocalName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
}

private func docxAttribute(_ attributes: [String: String], _ name: String) -> String? {
    if let value = attributes[name] { return value }
    let wanted = name.lowercased()
    for (key, value) in attributes {
        if docxLocalName(key) == wanted { return value }
    }
    return nil
}

private final class DOCXRelationshipsDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard docxLocalName(elementName) == "relationship" else { return }
        guard let identifier = docxAttribute(attributeDict, "Id"),
              let target = docxAttribute(attributeDict, "Target"),
              !target.lowercased().hasPrefix("http") else {
            return
        }
        targets[identifier] = target
    }
}

private final class DOCXStylesDelegate: NSObject, XMLParserDelegate {
    var names: [String: String] = [:]
    private var currentIdentifier: String?
    private var currentType: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = docxLocalName(elementName)
        if name == "style" {
            currentIdentifier = docxAttribute(attributeDict, "styleId")
            currentType = docxAttribute(attributeDict, "type")
        } else if name == "name",
                  currentType == "paragraph",
                  let identifier = currentIdentifier,
                  let value = docxAttribute(attributeDict, "val") {
            names[identifier] = value
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if docxLocalName(elementName) == "style" {
            currentIdentifier = nil
            currentType = nil
        }
    }
}

private final class DOCXDocumentDelegate: NSObject, XMLParserDelegate {
    let archive: ZipArchive
    let relationships: [String: String]
    let styles: [String: String]

    var sawParagraph = false
    private(set) var body = ""
    private(set) var images: [String: Data] = [:]
    private(set) var headings: [DOCXHeading] = []

    private var paragraphHTML = ""
    private var paragraphPlain = ""
    private var paragraphHasContent = false
    private var paragraphHeadingLevel = 0
    private var inParagraph = false
    private var inParagraphProperties = false
    private var inRunProperties = false
    private var inText = false
    private var runBold = false
    private var runItalic = false
    private var runUnderline = false
    private var headingIndex = 0
    private var usedImages: [String: String] = [:]

    init(archive: ZipArchive, relationships: [String: String], styles: [String: String]) {
        self.archive = archive
        self.relationships = relationships
        self.styles = styles
    }

    func finish() -> DOCXRenderer.Document {
        DOCXRenderer.Document(body: body, images: images, headings: headings)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = docxLocalName(elementName)
        switch name {
        case "p":
            sawParagraph = true
            inParagraph = true
            paragraphHTML = ""
            paragraphPlain = ""
            paragraphHasContent = false
            paragraphHeadingLevel = 0
        case "ppr":
            inParagraphProperties = true
        case "pstyle":
            if inParagraphProperties,
               let value = docxAttribute(attributeDict, "val") {
                paragraphHeadingLevel = headingLevel(for: value)
            }
        case "r":
            runBold = false
            runItalic = false
            runUnderline = false
        case "rpr":
            inRunProperties = true
        case "b":
            if inRunProperties {
                runBold = boolValue(attributeDict)
            }
        case "i":
            if inRunProperties {
                runItalic = boolValue(attributeDict)
            }
        case "u":
            if inRunProperties {
                runUnderline = boolValue(attributeDict)
            }
        case "t":
            inText = true
        case "br":
            if inParagraph {
                paragraphHTML += "<br>"
                paragraphHasContent = true
            }
        case "tab":
            if inParagraph {
                paragraphHTML += "&nbsp;&nbsp;&nbsp;&nbsp;"
                paragraphPlain += "\t"
                paragraphHasContent = true
            }
        case "blip":
            if inParagraph,
               let relation = docxAttribute(attributeDict, "embed")
                   ?? docxAttribute(attributeDict, "id"),
               let fileName = imageFileName(for: relation) {
                paragraphHTML += "<img class=\"docx-image\" src=\"Images/\(fileName)\">"
                paragraphHasContent = true
            }
        case "imagedata":
            if inParagraph,
               let relation = docxAttribute(attributeDict, "id"),
               let fileName = imageFileName(for: relation) {
                paragraphHTML += "<img class=\"docx-image\" src=\"Images/\(fileName)\">"
                paragraphHasContent = true
            }
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
        let name = docxLocalName(elementName)
        switch name {
        case "t":
            inText = false
        case "rpr":
            inRunProperties = false
        case "ppr":
            inParagraphProperties = false
        case "p":
            finishParagraph()
            inParagraph = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText, inParagraph else { return }
        var escaped = escapeHTML(string)
        if runUnderline { escaped = "<u>\(escaped)</u>" }
        if runItalic { escaped = "<em>\(escaped)</em>" }
        if runBold { escaped = "<strong>\(escaped)</strong>" }
        paragraphHTML += escaped
        paragraphPlain += string
        paragraphHasContent = true
    }

    private func finishParagraph() {
        let plain = paragraphPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        let markup = paragraphHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        paragraphHTML = ""
        paragraphPlain = ""
        paragraphHasContent = false

        guard !markup.isEmpty || !plain.isEmpty else { return }
        var level = paragraphHeadingLevel
        if level == 0, !plain.isEmpty, ChapterHeading.looksLikeHeading(plain) {
            level = 2
        }
        if level > 0, !plain.isEmpty {
            let clamped = min(max(level, 1), 6)
            headingIndex += 1
            let anchor = "docx-h-\(headingIndex)"
            body += "<h\(clamped) id=\"\(anchor)\">\(markup)</h\(clamped)>"
            headings.append(DOCXHeading(title: plain, anchorID: anchor))
        } else {
            body += "<p>\(markup)</p>"
        }
    }

    private func imageFileName(for relation: String) -> String? {
        if let existing = usedImages[relation] {
            return existing
        }
        guard let target = relationships[relation] else { return nil }
        let normalized = normalizedWordPath(target)
        guard let data = try? archive.contents(of: normalized) else { return nil }
        var ext = (normalized as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
        let fileName = "docx-\(usedImages.count + 1).\(ext)"
        usedImages[relation] = fileName
        images[fileName] = data
        return fileName
    }

    private func normalizedWordPath(_ target: String) -> String {
        let path: String
        if target.hasPrefix("/") {
            path = String(target.dropFirst())
        } else if target.hasPrefix("word/") {
            path = target
        } else {
            path = "word/\(target)"
        }
        return BookImporter.normalizedEPUBPath(path)
    }

    private func headingLevel(for style: String) -> Int {
        let resolved = styles[style] ?? style
        let lower = resolved.lowercased()
        if lower == "title" { return 1 }
        if lower == "subtitle" { return 2 }
        if lower.contains("heading") || lower.contains("标题") {
            let digits = lower.filter { $0.isNumber }
            return Int(digits) ?? 1
        }
        return 0
    }

    private func boolValue(_ attributes: [String: String]) -> Bool {
        guard let value = docxAttribute(attributes, "val")?.lowercased() else { return true }
        return value != "0" && value != "false" && value != "none" && value != "off"
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
