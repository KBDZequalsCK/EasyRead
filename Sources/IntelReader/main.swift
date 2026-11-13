import AppKit
import CoreFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers
import WebKit

enum AppLanguage: String {
    case chinese = "zh"
    case english = "en"

    var displayName: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "English"
        }
    }
}

enum AppLocalization {
    private static let languageKey = "AppLanguage"

    static var language: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: languageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .chinese
        }
        return language
    }

    static func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        // Let AppKit-provided labels (open panels, standard dialogs) follow the choice too.
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("AppLanguageDidChange")
}

func L(_ chinese: String, _ english: String) -> String {
    AppLocalization.language == .english ? english : chinese
}

struct LibraryBook: Codable, Equatable {
    let id: UUID
    let path: String
    var title: String
    let format: String
    var author: String
    var progress: Double
    let addedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, path, title, format, author, progress, addedAt
    }

    init(id: UUID, path: String, title: String, format: String, author: String = "", progress: Double, addedAt: Date) {
        self.id = id
        self.path = path
        self.title = title
        self.format = format
        self.author = author
        self.progress = progress
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        title = try values.decode(String.self, forKey: .title)
        format = try values.decode(String.self, forKey: .format)
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? ""
        progress = try values.decode(Double.self, forKey: .progress)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
    }
}

final class LibraryStore {
    private(set) var books: [LibraryBook] = []

    private let fileManager = FileManager.default
    private let fileURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("IntelReader", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")
        load()
    }

    func add(_ book: LibraryBook) {
        books.removeAll { $0.path == book.path }
        books.insert(book, at: 0)
        save()
    }

    func remove(_ book: LibraryBook) {
        books.removeAll { $0.id == book.id }
        save()
    }

    func remove(_ removedBooks: [LibraryBook]) {
        guard !removedBooks.isEmpty else { return }
        let removedIDs = Set(removedBooks.map(\.id))
        books.removeAll { removedIDs.contains($0.id) }
        save()
    }

    func update(_ book: LibraryBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LibraryBook].self, from: data) else {
            return
        }
        books = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class ContainerParser: NSObject, XMLParserDelegate {
    var rootFilePath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName.lowercased() == "rootfile" {
            rootFilePath = attributeDict["full-path"]
        }
    }
}

final class EPUBParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href.removingPercentEncoding ?? href
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        default:
            break
        }
    }
}

final class EPUBMetadataParser: NSObject, XMLParserDelegate {
    private var isReadingCreator = false
    private var creatorText = ""
    private(set) var author: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        if localName.lowercased() == "creator" {
            isReadingCreator = true
            creatorText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingCreator {
            creatorText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let localName = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        guard localName.lowercased() == "creator", isReadingCreator else { return }
        let value = creatorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            author = value
        }
        isReadingCreator = false
    }
}

enum ReaderError: LocalizedError {
    case unsupportedFormat
    case invalidEPUB
    case extractionFailed
    case converterUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L("这个文件格式暂时只能加入书架，尚未提供本地解码器。",
                     "This format can be added to the library, but no local decoder is available yet.")
        case .invalidEPUB:
            return L("EPUB 文件结构无法识别。", "The EPUB file structure could not be recognized.")
        case .extractionFailed:
            return L("无法解压这个 EPUB 文件。", "This EPUB file could not be extracted.")
        case .converterUnavailable:
            return L("未找到 Calibre 的 MOBI/AZW 解码器。\n请安装 Calibre 后重新打开这本书。",
                     "Calibre's MOBI/AZW converter was not found.\nInstall Calibre and reopen this book.")
        case .conversionFailed(let detail):
            if detail.isEmpty {
                return L("MOBI/AZW 文件无法转换。\n如果文件带有 DRM，请先解除 DRM 或转换为 EPUB。",
                         "The MOBI/AZW file could not be converted.\nIf it uses DRM, remove the DRM or convert it to EPUB first.")
            }
            return L("MOBI/AZW 文件无法转换：\n\(detail)", "The MOBI/AZW file could not be converted:\n\(detail)")
        }
    }
}

enum BookImporter {
    static func book(from url: URL) -> LibraryBook {
        let ext = url.pathExtension.lowercased()
        let knownFormat = ext.isEmpty ? "FILE" : ext.uppercased()
        return LibraryBook(
            id: UUID(),
            path: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            format: knownFormat,
            author: inferredAuthor(from: url),
            progress: 0,
            addedAt: Date()
        )
    }

    static func inferredAuthor(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "epub", let author = epubAuthor(from: url), !author.isEmpty {
            return author
        }
        if ext == "pdf", let author = PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
            let value = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        let filename = url.deletingPathExtension().lastPathComponent
        for marker in ["作者：", "作者:"] {
            if let range = filename.range(of: marker) {
                let value = filename[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    private static func epubAuthor(from url: URL) -> String? {
        let fileManager = FileManager.default
        let root: URL
        var temporaryRoot: URL?
        if isEPUBPackage(at: url) {
            root = url
        } else {
            let extractedRoot = fileManager.temporaryDirectory
                .appendingPathComponent("IntelReader-Metadata-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-q", url.path, "-d", extractedRoot.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    try? fileManager.removeItem(at: extractedRoot)
                    return nil
                }
            } catch {
                try? fileManager.removeItem(at: extractedRoot)
                return nil
            }
            root = extractedRoot
            temporaryRoot = extractedRoot
        }
        defer {
            if let temporaryRoot {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }

        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        let containerParser = ContainerParser()
        guard let parser = XMLParser(contentsOf: containerURL) else { return nil }
        parser.delegate = containerParser
        guard parser.parse(), let rootFilePath = containerParser.rootFilePath else { return nil }

        let metadataParser = EPUBMetadataParser()
        let opfURL = root.appendingPathComponent(rootFilePath)
        guard let opfParser = XMLParser(contentsOf: opfURL) else { return nil }
        opfParser.delegate = metadataParser
        guard opfParser.parse() else { return nil }
        return metadataParser.author
    }

    static func plainText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let gb2312 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)
            )
        )
        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        )

        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        let zeroCount = data.reduce(into: 0) { count, byte in
            if byte == 0 { count += 1 }
        }
        let looksLikeUTF16 = data.count > 1 && zeroCount > data.count / 20
        if looksLikeUTF16 {
            let utf16Encodings: [String.Encoding] = [.utf16, .utf16BigEndian, .utf16LittleEndian, .unicode]
            for encoding in utf16Encodings {
                if let text = String(data: data, encoding: encoding) {
                    return text
                }
            }
        }

        for encoding in [gb18030, gb2312, big5, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw ReaderError.unsupportedFormat
    }

    static func isEPUBPackage(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard url.pathExtension.lowercased() == "epub",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return false
        }

        return fileManager.fileExists(atPath: url.appendingPathComponent("mimetype").path) &&
            fileManager.fileExists(atPath: url.appendingPathComponent("META-INF/container.xml").path)
    }

    static func epubHTML(from url: URL, fontSize: CGFloat = 19, isDark: Bool = false) throws -> (htmlURL: URL, accessRoot: URL) {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let root: URL

        if isEPUBPackage(at: url) {
            // iCloud and Apple Books may expose EPUBs as directory packages.
            // Work on a temporary copy so generated HTML never enters iCloud.
            let copiedRoot = workspace.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: url, to: copiedRoot)
            root = copiedRoot
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", url.path, "-d", workspace.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ReaderError.extractionFailed
            }
            root = workspace
        }

        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        let containerParser = ContainerParser()
        guard let parser = XMLParser(contentsOf: containerURL) else {
            throw ReaderError.invalidEPUB
        }
        parser.delegate = containerParser
        guard parser.parse(), let rootFilePath = containerParser.rootFilePath else {
            throw ReaderError.invalidEPUB
        }

        let opfURL = root.appendingPathComponent(rootFilePath)
        let epubParser = EPUBParser()
        guard let opfParser = XMLParser(contentsOf: opfURL) else {
            throw ReaderError.invalidEPUB
        }
        opfParser.delegate = epubParser
        guard opfParser.parse() else {
            throw ReaderError.invalidEPUB
        }

        let baseURL = opfURL.deletingLastPathComponent()
        let chapters = epubParser.spine.compactMap { idref -> URL? in
            guard let href = epubParser.manifest[idref] else { return nil }
            return baseURL.appendingPathComponent(href)
        }
        guard !chapters.isEmpty else {
            throw ReaderError.invalidEPUB
        }

        let body = chapters.compactMap { chapter -> String? in
            guard let source = try? String(contentsOf: chapter, encoding: .utf8) else { return nil }
            return bodyContents(from: source)
        }.joined(separator: "\n<hr class=\"chapter-break\">\n")

        let background = isDark ? "#1b1c1a" : "#f6f5f0"
        let foreground = isDark ? "#e7e4dc" : "#2c302d"
        let linkColor = isDark ? "#8db6a0" : "#3f7560"
        let ruleColor = isDark ? "#3a3b36" : "#d9d8d0"
        let scheme = isDark ? "dark" : "light"

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: \(scheme); }
            body {
              margin: 0 auto;
              max-width: 760px;
              padding: 60px 44px 120px;
              color: \(foreground);
              background: \(background);
              font-family: Georgia, "Times New Roman", serif;
              font-size: \(Int(fontSize))px;
              line-height: 1.82;
            }
            img { max-width: 100%; height: auto; }
            a { color: \(linkColor); }
            .chapter-break { border: 0; border-top: 1px solid \(ruleColor); margin: 64px 0; }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """

        let htmlURL = workspace.appendingPathComponent("intel-reader.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, workspace)
    }

    static func convertedEPUBHTML(from url: URL, fontSize: CGFloat, isDark: Bool) throws -> (htmlURL: URL, accessRoot: URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntelReader-Converted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let convertedURL = workspace.appendingPathComponent("converted.epub")

        guard let converter = calibreConverterURL() else {
            try? FileManager.default.removeItem(at: workspace)
            throw ReaderError.converterUnavailable
        }

        let process = Process()
        process.executableURL = converter
        process.arguments = [url.path, convertedURL.path, "--no-default-epub-cover"]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw ReaderError.conversionFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: convertedURL.path) else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            try? FileManager.default.removeItem(at: workspace)
            throw ReaderError.conversionFailed(detail)
        }

        do {
            let result = try epubHTML(from: convertedURL, fontSize: fontSize, isDark: isDark)
            try? FileManager.default.removeItem(at: workspace)
            return result
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    private static func calibreConverterURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "\(home)/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "/usr/local/bin/ebook-convert",
            "/opt/homebrew/bin/ebook-convert"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func plainTextHTML(title: String, text: String, fontSize: CGFloat, isDark: Bool) throws -> (htmlURL: URL, accessRoot: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntelReader-TXT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let escapedTitle = escapeHTML(title)
        let escapedText = escapeHTML(text)
        let background = isDark ? "#1b1c1a" : "#f6f5f0"
        let foreground = isDark ? "#e7e4dc" : "#2c302d"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light; }
            body {
              margin: 0;
              background: \(background);
              color: \(foreground);
              font-family: Georgia, "Times New Roman", serif;
              font-size: \(Int(fontSize))px;
              line-height: 1.82;
            }
            .page {
              max-width: 760px;
              margin: 0 auto;
              padding: 48px 44px 96px;
              white-space: pre-wrap;
              overflow-wrap: break-word;
              word-break: break-word;
            }
            .title {
              font-size: 15px;
              opacity: 0.7;
              margin-bottom: 24px;
            }
          </style>
        </head>
        <body>
          <main class="page">
            <div class="title">\(escapedTitle)</div>
            <article>\(escapedText)</article>
          </main>
        </body>
        </html>
        """

        let htmlURL = root.appendingPathComponent("intel-reader-text.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, root)
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func bodyContents(from source: String) -> String {
        let lowercased = source.lowercased()
        guard let startTag = lowercased.range(of: "<body"),
              let startEnd = lowercased.range(of: ">", range: startTag.upperBound..<lowercased.endIndex),
              let endTag = lowercased.range(of: "</body>", range: startEnd.upperBound..<lowercased.endIndex) else {
            return source
        }
        return String(source[startEnd.upperBound..<endTag.lowerBound])
    }
}

final class CloudFolderSync {
    static let shared = CloudFolderSync()

    private(set) var folderURL: URL
    private let fileManager = FileManager.default
    private let supportedExtensions = Set(["txt", "epub", "pdf", "mobi", "azw", "azw3"])

    private init() {
        let defaultURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/极简阅读", isDirectory: true)
        folderURL = UserDefaults.standard.url(forKey: "CloudFolderURL") ?? Self.discoverFolder(fallback: defaultURL)
    }

    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var displayPath: String {
        folderURL.path.replacingOccurrences(of: fileManager.homeDirectoryForCurrentUser.path, with: "~")
    }

    func contains(_ url: URL) -> Bool {
        guard isAvailable else { return false }
        let folderPath = folderURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return itemPath == folderPath || itemPath.hasPrefix(folderPath + "/")
    }

    func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url, forKey: "CloudFolderURL")
    }

    private static func discoverFolder(fallback: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            fallback,
            // “极简阅读”原 App 使用自己的 iCloud 容器，Finder 中对应为该 App 的 Documents 目录。
            home.appendingPathComponent("Library/Mobile Documents/iCloud~com~photon~reader/Documents", isDirectory: true),
            home.appendingPathComponent("Library/CloudStorage/iCloud Drive/极简阅读", isDirectory: true),
            home.appendingPathComponent("Library/CloudStorage/iCloud 云盘/极简阅读", isDirectory: true)
        ]
        if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return match
        }

        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let roots = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fallback
        }
        for root in roots {
            let candidate = root.appendingPathComponent("极简阅读", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return fallback
    }

    func ensureFolder() throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func bookURLs() -> [URL] {
        guard isAvailable,
              let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.pathComponents.contains(".Trash") {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let extensionName = item.pathExtension.lowercased()
            if extensionName == "epub", values?.isDirectory == true {
                if BookImporter.isEPUBPackage(at: item) {
                    results.append(item)
                }
                enumerator.skipDescendants()
                continue
            }

            if supportedExtensions.contains(extensionName), values?.isRegularFile == true {
                results.append(item)
            }
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func prepareForReading(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
              values.isUbiquitousItem == true else {
            return
        }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
    }

    func copyIntoFolder(_ url: URL) throws -> URL {
        try ensureFolder()
        let destination = folderURL.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL != url.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                return destination
            } else {
                try fileManager.copyItem(at: url, to: destination)
            }
        }
        return destination
    }
}

final class BookRowButton: NSButton {
    static let rowHeight: CGFloat = 72

    private(set) var book: LibraryBook
    var onSelect: ((LibraryBook) -> Void)?
    var onEditMetadata: ((LibraryBook) -> Void)?
    var onRemove: ((LibraryBook) -> Void)?
    var onRemoveFromCloud: ((LibraryBook) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private var isHovered = false
    private var isDark = false

    private var hoverBackgroundColor: NSColor {
        isDark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.89, alpha: 1)
    }

    init(book: LibraryBook) {
        self.book = book
        titleLabel = NSTextField(labelWithString: book.title)
        detailLabel = NSTextField(labelWithString: Self.detailText(for: book))
        super.init(frame: .zero)

        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.clear.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false

        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = NSColor(calibratedWhite: 0.44, alpha: 1)
        detailLabel.isSelectable = false
        detailLabel.isEditable = false
        detailLabel.isBezeled = false
        detailLabel.isBordered = false
        detailLabel.drawsBackground = false
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 2

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        addSubview(labels)
        labels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func clicked() {
        onSelect?(book)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: L("编辑书名和作者", "Edit Title & Author"), action: #selector(editMetadataRequested), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("从书架移除", "Remove from Library"), action: #selector(removeRequested), keyEquivalent: "")
        menu.addItem(withTitle: L("从 iCloud 删除并移出书架", "Delete from iCloud & Remove"), action: #selector(removeFromCloudRequested), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func editMetadataRequested() {
        onEditMetadata?(book)
    }

    @objc private func removeRequested() {
        onRemove?(book)
    }

    @objc private func removeFromCloudRequested() {
        onRemoveFromCloud?(book)
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        layer?.backgroundColor = hovered
            ? hoverBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }

    func applyTheme(isDark: Bool) {
        self.isDark = isDark
        titleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.18, alpha: 1)
        detailLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.58, alpha: 1)
            : NSColor(calibratedWhite: 0.44, alpha: 1)
        layer?.backgroundColor = isHovered
            ? hoverBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    func update(book: LibraryBook) {
        self.book = book
        titleLabel.stringValue = book.title
        detailLabel.stringValue = Self.detailText(for: book)
    }

    private static func detailText(for book: LibraryBook) -> String {
        let author = book.author.isEmpty
            ? L("作者未设置", "Author not set")
            : L("作者：\(book.author)", "By \(book.author)")
        return "\(author)\n\(book.format)  ·  \(progressText(book.progress))"
    }

    private static func progressText(_ progress: Double) -> String {
        progress <= 0 ? L("未开始", "Not started") : "\(Int(progress * 100))%"
    }
}

enum CloudSyncStatus {
    case checking
    case ready
    case syncing
    case synced(bookCount: Int)
    case syncCompleted(added: Int, removed: Int)
    case folderMissing
    case folderChosen(path: String)
    case booksAdded(count: Int)
    case bookDeleted

    var text: String {
        switch self {
        case .checking:
            return L("正在检查 iCloud…", "Checking iCloud…")
        case .ready:
            return L("iCloud：准备同步", "iCloud: Ready to sync")
        case .syncing:
            return L("iCloud：正在同步…", "iCloud: Syncing…")
        case .synced(let count):
            return count == 1
                ? L("iCloud：已同步 · 1 本", "iCloud: Synced · 1 book")
                : L("iCloud：已同步 · \(count) 本", "iCloud: Synced · \(count) books")
        case .syncCompleted(let added, let removed):
            var parts: [String] = []
            if added > 0 {
                parts.append(added == 1 ? L("新增 1 本", "1 added") : L("新增 \(added) 本", "\(added) added"))
            }
            if removed > 0 {
                parts.append(removed == 1 ? L("移除 1 本", "1 removed") : L("移除 \(removed) 本", "\(removed) removed"))
            }
            return L("iCloud：同步完成，\(parts.joined(separator: "，"))",
                     "iCloud: Sync complete, \(parts.joined(separator: ", "))")
        case .folderMissing:
            return L("iCloud：未找到文件夹，请点击“位置”选择", "iCloud: Folder not found. Click “Location” to choose one.")
        case .folderChosen(let path):
            return L("iCloud：已选择 \(path)", "iCloud: Selected \(path)")
        case .booksAdded(let count):
            return count == 1
                ? L("iCloud：已加入 1 本书", "iCloud: Added 1 book")
                : L("iCloud：已加入 \(count) 本书", "iCloud: Added \(count) books")
        case .bookDeleted:
            return L("iCloud：已删除 1 本书", "iCloud: Deleted 1 book")
        }
    }
}

final class SidebarViewController: NSViewController {
    var books: [LibraryBook] = []
    var onImport: (() -> Void)?
    var onSync: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSelect: ((LibraryBook) -> Void)?
    var onDelete: ((LibraryBook) -> Void)?
    var onEditMetadata: ((LibraryBook) -> Void)?
    var onDeleteFromCloud: ((LibraryBook) -> Void)?

    private let scrollView = NSScrollView()
    private let listContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: L("简阅", "EasyRead"))
    private let subtitleLabel = NSTextField(labelWithString: L("你的本地阅读空间", "Your local reading space"))
    private let hideSidebarButton = NSButton()
    private let importButton = NSButton()
    private let syncButton = NSButton()
    private let chooseFolderButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: L("书架还是空的\n把你的第一本书放进来吧", "Your library is empty\nAdd your first book to get started"))
    private let cloudStatusLabel = NSTextField(labelWithString: CloudSyncStatus.checking.text)
    private let footerLabel = NSTextField(labelWithString: L("支持 TXT · EPUB · PDF\nIntel 原生运行", "TXT · EPUB · PDF\nNative on Intel"))
    private let languageButton = NSButton()
    private var rowsByBookID: [UUID: BookRowButton] = [:]
    private var hoveredRow: BookRowButton?
    private var scrollObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var isDark = false
    private var hasAppliedTheme = false
    private var cloudStatus: CloudSyncStatus = .checking
    private var cloudStatusColor: NSColor?

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 25, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.14, alpha: 1)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.36, alpha: 1)

        hideSidebarButton.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L("隐藏书架", "Hide Library")
        )
        hideSidebarButton.imagePosition = .imageOnly
        hideSidebarButton.isBordered = false
        hideSidebarButton.contentTintColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        hideSidebarButton.target = self
        hideSidebarButton.action = #selector(hideSidebarClicked)
        hideSidebarButton.toolTip = L("隐藏左侧书架（⌘⇧S）", "Hide sidebar (⌘⇧S)")

        importButton.title = L("导入书籍", "Import")
        importButton.target = self
        importButton.action = #selector(importClicked)
        importButton.bezelStyle = .rounded
        importButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.toolTip = L("导入本地书籍", "Import local books")

        syncButton.title = L("同步", "Sync")
        syncButton.target = self
        syncButton.action = #selector(syncClicked)
        syncButton.bezelStyle = .texturedRounded
        syncButton.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
        syncButton.imagePosition = .imageLeading
        syncButton.toolTip = L("从 iCloud 文件夹同步", "Sync from the iCloud folder")

        chooseFolderButton.title = L("位置", "Folder")
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolderClicked)
        chooseFolderButton.bezelStyle = .texturedRounded
        chooseFolderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        chooseFolderButton.imagePosition = .imageLeading
        chooseFolderButton.toolTip = L("选择 iCloud 文件夹位置", "Choose the iCloud folder location")

        let actions = NSStackView(views: [syncButton, chooseFolderButton, importButton])
        actions.orientation = .horizontal
        actions.spacing = 6

        let header = NSStackView(views: [titleLabel, subtitleLabel, actions])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.setCustomSpacing(16, after: subtitleLabel)

        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = listContainer
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true

        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
        footerLabel.maximumNumberOfLines = 2

        cloudStatusLabel.font = NSFont.systemFont(ofSize: 10)
        cloudStatusLabel.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
        cloudStatusLabel.lineBreakMode = .byTruncatingTail

        languageButton.isBordered = false
        languageButton.focusRingType = .none
        languageButton.setButtonType(.momentaryChange)
        languageButton.target = self
        languageButton.action = #selector(toggleLanguage)
        applyLanguageButtonStyle()

        root.addSubview(header)
        root.addSubview(hideSidebarButton)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(cloudStatusLabel)
        root.addSubview(footerLabel)
        root.addSubview(languageButton)
        header.translatesAutoresizingMaskIntoConstraints = false
        hideSidebarButton.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        languageButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            hideSidebarButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            hideSidebarButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hideSidebarButton.widthAnchor.constraint(equalToConstant: 26),
            hideSidebarButton.heightAnchor.constraint(equalToConstant: 26),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: cloudStatusLabel.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -12),
            cloudStatusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            cloudStatusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            cloudStatusLabel.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -7),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: languageButton.leadingAnchor, constant: -8),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            languageButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            languageButton.bottomAnchor.constraint(equalTo: footerLabel.bottomAnchor)
        ])

        view = root

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverFromMouse()
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, note.object as? NSWindow === self.view.window else { return }
            self.setHoveredRow(nil)
        }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, note.object as? NSWindow === self.view.window else { return }
            self.refreshHoverFromMouse()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateListFrame()
    }

    func reload(books: [LibraryBook], scrollToTop: Bool = false) {
        self.books = books
        rowsByBookID.removeAll()
        hoveredRow = nil
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        books.forEach { book in
            let row = BookRowButton(book: book)
            row.applyTheme(isDark: isDark)
            row.onSelect = { [weak self] book in
                self?.onSelect?(book)
            }
            row.onEditMetadata = { [weak self] book in
                self?.onEditMetadata?(book)
            }
            row.onRemove = { [weak self] book in
                self?.onDelete?(book)
            }
            row.onRemoveFromCloud = { [weak self] book in
                self?.onDeleteFromCloud?(book)
            }
            row.onHoverChanged = { [weak self, weak row] isHovered in
                guard let self, let row else { return }
                if isHovered {
                    self.setHoveredRow(row)
                } else if self.hoveredRow === row {
                    self.refreshHoverFromMouse()
                }
            }
            row.autoresizingMask = [.width]
            listContainer.addSubview(row)
            rowsByBookID[book.id] = row
        }
        updateListFrame()
        emptyLabel.isHidden = !books.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverFromMouse()
            if scrollToTop {
                self?.scrollToTop()
            }
        }
    }

    func refresh(book: LibraryBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        rowsByBookID[book.id]?.update(book: book)
    }

    func applyTheme(isDark: Bool) {
        self.isDark = isDark
        let shouldRestoreScroll = hasAppliedTheme
        hasAppliedTheme = true
        let scrollOrigin = scrollView.contentView.bounds.origin
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.135, alpha: 1)
            : NSColor(calibratedWhite: 0.965, alpha: 1)).cgColor
        titleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.92, alpha: 1)
            : NSColor(calibratedWhite: 0.14, alpha: 1)
        subtitleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.6, alpha: 1)
            : NSColor(calibratedWhite: 0.36, alpha: 1)
        hideSidebarButton.contentTintColor = isDark
            ? NSColor(calibratedWhite: 0.62, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        emptyLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.55, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        footerLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.52, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
        cloudStatusLabel.textColor = cloudStatusColor ?? defaultCloudStatusColor
        applyLanguageButtonStyle()
        listContainer.subviews
            .compactMap { $0 as? BookRowButton }
            .forEach { $0.applyTheme(isDark: isDark) }
        guard shouldRestoreScroll else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let maximumY = max(0, self.listContainer.bounds.height - self.scrollView.contentView.bounds.height)
            let origin = NSPoint(x: 0, y: min(max(scrollOrigin.y, 0), maximumY))
            self.scrollView.contentView.scroll(to: origin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    private var defaultCloudStatusColor: NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.55, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
    }

    func setCloudStatus(_ status: CloudSyncStatus, color: NSColor? = nil) {
        cloudStatus = status
        cloudStatusColor = color
        renderCloudStatus()
    }

    func applyLanguage() {
        titleLabel.stringValue = L("简阅", "EasyRead")
        subtitleLabel.stringValue = L("你的本地阅读空间", "Your local reading space")
        hideSidebarButton.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L("隐藏书架", "Hide Library")
        )
        hideSidebarButton.toolTip = L("隐藏左侧书架（⌘⇧S）", "Hide sidebar (⌘⇧S)")
        importButton.title = L("导入书籍", "Import")
        syncButton.title = L("同步", "Sync")
        chooseFolderButton.title = L("位置", "Folder")
        importButton.toolTip = L("导入本地书籍", "Import local books")
        syncButton.toolTip = L("从 iCloud 文件夹同步", "Sync from the iCloud folder")
        chooseFolderButton.toolTip = L("选择 iCloud 文件夹位置", "Choose the iCloud folder location")
        emptyLabel.stringValue = L(
            "书架还是空的\n把你的第一本书放进来吧",
            "Your library is empty\nAdd your first book to get started"
        )
        footerLabel.stringValue = L(
            "支持 TXT · EPUB · PDF\nIntel 原生运行",
            "TXT · EPUB · PDF\nNative on Intel"
        )
        applyLanguageButtonStyle()
        renderCloudStatus()
        reload(books: books)
    }

    private func renderCloudStatus() {
        cloudStatusLabel.stringValue = cloudStatus.text
        cloudStatusLabel.textColor = cloudStatusColor ?? defaultCloudStatusColor
    }

    private func applyLanguageButtonStyle() {
        let color = isDark
            ? NSColor(calibratedWhite: 0.62, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        let title = AppLocalization.language == .chinese ? "English" : "中文"
        languageButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        languageButton.toolTip = AppLocalization.language == .chinese
            ? "Switch to English"
            : "切换到中文"
    }

    @objc private func toggleLanguage() {
        AppLocalization.setLanguage(AppLocalization.language == .chinese ? .english : .chinese)
    }

    private func updateListFrame() {
        let width = max(scrollView.contentView.bounds.width, 1)
        let viewportHeight = max(scrollView.contentView.bounds.height, 1)
        let rowHeight = BookRowButton.rowHeight
        let rowSpacing: CGFloat = 3
        let rowsHeight = max(books.isEmpty ? 1 : CGFloat(books.count) * (rowHeight + rowSpacing) + 4, viewportHeight)
        listContainer.frame = NSRect(x: 0, y: 0, width: width, height: rowsHeight)
        for (index, row) in listContainer.subviews.enumerated() {
            let y = rowsHeight - 2 - rowHeight - CGFloat(index) * (rowHeight + rowSpacing)
            row.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
        }
    }

    private func scrollToTop() {
        view.layoutSubtreeIfNeeded()
        updateListFrame()
        let maximumY = max(0, listContainer.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setHoveredRow(_ row: BookRowButton?) {
        guard hoveredRow !== row else { return }
        hoveredRow?.setHovered(false)
        hoveredRow = row
        row?.setHovered(true)
    }

    private func refreshHoverFromMouse() {
        guard let window = view.window, window.isKeyWindow else {
            setHoveredRow(nil)
            return
        }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let point = listContainer.convert(pointInWindow, from: nil)
        guard listContainer.bounds.contains(point) else {
            setHoveredRow(nil)
            return
        }
        let row = listContainer.subviews
            .compactMap { $0 as? BookRowButton }
            .first { $0.frame.contains(point) }
        setHoveredRow(row)
    }

    @objc private func hideSidebarClicked() {
        onToggleSidebar?()
    }

    @objc private func importClicked() {
        onImport?()
    }

    @objc private func syncClicked() {
        onSync?()
    }

    @objc private func chooseFolderClicked() {
        onChooseFolder?()
    }

}

final class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private enum PlaceholderState {
        case empty
        case book
        case removed
    }

    private let titleLabel = NSTextField(labelWithString: L("选择一本书开始阅读", "Select a book to start reading"))
    private let subtitleLabel = NSTextField(labelWithString: L("支持拖入本地文件，内容保存在你的 Mac 上", "Drag in local files; content stays on your Mac"))
    private let contentView = NSView()
    private let emptyState = NSView()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let showSidebarButton = NSButton()
    private let themeButton = NSButton()
    private let emptyMark = NSTextField(labelWithString: "◌")
    private let emptyTitleLabel = NSTextField(labelWithString: L("安静地读一本书", "Read in peace"))
    private let emptySubtitleLabel = NSTextField(labelWithString: L("从左侧导入书籍，或直接把文件拖进窗口", "Import books from the sidebar, or drag files into the window"))
    private var placeholderState: PlaceholderState = .empty
    private var currentBook: LibraryBook?
    private var textView: NSTextView?
    private var pdfView: PDFView?
    private var webView: WKWebView?
    private var webUserContentController: WKUserContentController?
    private var epubRoot: URL?
    private var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "ReaderFontSize")
        guard stored >= 12, stored <= 32 else { return 18 }
        return CGFloat(stored)
    }()
    private var isDark = UserDefaults.standard.bool(forKey: "ReaderDarkMode")
    private var loadGeneration = 0
    private var currentProgress = 0.0
    private var pdfProgressObserver: NSObjectProtocol?
    var onProgress: ((UUID, Double) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onThemeChanged: ((Bool) -> Void)?
    var isDarkMode: Bool { isDark }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let decrease = NSButton(title: "A−", target: self, action: #selector(decreaseFont))
        let increase = NSButton(title: "A+", target: self, action: #selector(increaseFont))
        decrease.bezelStyle = .texturedRounded
        increase.bezelStyle = .texturedRounded
        fontSizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fontSizeLabel.alignment = .center
        fontSizeLabel.stringValue = "\(Int(fontSize))"
        fontSizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        themeButton.title = L("夜间", "Night")
        themeButton.bezelStyle = .texturedRounded
        themeButton.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)
        themeButton.imagePosition = .imageLeading
        themeButton.target = self
        themeButton.action = #selector(toggleTheme)

        showSidebarButton.title = L("显示书架", "Show Library")
        showSidebarButton.bezelStyle = .texturedRounded
        showSidebarButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        showSidebarButton.imagePosition = .imageLeading
        showSidebarButton.toolTip = L("显示左侧书架（⌘⇧S）", "Show sidebar (⌘⇧S)")
        showSidebarButton.isHidden = true
        showSidebarButton.target = self
        showSidebarButton.action = #selector(toggleSidebarRequested)

        let toolbar = NSStackView(views: [
            showSidebarButton,
            titleLabel,
            subtitleLabel,
            NSView(),
            decrease,
            fontSizeLabel,
            increase,
            themeButton
        ])
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 18)

        emptyState.wantsLayer = true
        emptyMark.font = NSFont.systemFont(ofSize: 54, weight: .ultraLight)
        emptyMark.textColor = NSColor(calibratedRed: 0.25, green: 0.46, blue: 0.37, alpha: 0.42)
        emptyTitleLabel.font = NSFont.systemFont(ofSize: 26, weight: .medium)
        emptyTitleLabel.textColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        emptySubtitleLabel.font = NSFont.systemFont(ofSize: 13)
        emptySubtitleLabel.textColor = NSColor.secondaryLabelColor
        let emptyStack = NSStackView(views: [emptyMark, emptyTitleLabel, emptySubtitleLabel])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 9
        emptyState.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor)
        ])

        root.addSubview(toolbar)
        root.addSubview(contentView)
        root.addSubview(emptyState)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 70),
            contentView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        applyThemeAppearance()
        showEmptyState()
    }

    func show(book: LibraryBook) {
        loadGeneration += 1
        let generation = loadGeneration
        currentBook = book
        placeholderState = .book
        currentProgress = min(max(book.progress, 0), 0.999)
        titleLabel.stringValue = book.title
        subtitleLabel.stringValue = L("\(book.format) · 本地文件", "\(book.format) · Local file")
        clearContent()
        emptyState.isHidden = true
        contentView.isHidden = false

        switch book.format {
        case "TXT":
            showLoading(message: L("正在打开 TXT…", "Opening TXT…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let text = try BookImporter.plainText(from: url)
                    let html = try BookImporter.plainTextHTML(
                        title: book.title,
                        text: text,
                        fontSize: fontSize,
                        isDark: isDark
                    )
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: html, progress: book.progress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "PDF":
            showLoading(message: L("正在打开 PDF…", "Opening PDF…"))
            let url = URL(fileURLWithPath: book.path)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let document = PDFDocument(url: url)
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    guard let document else {
                        self.showUnsupported(message: ReaderError.unsupportedFormat.localizedDescription)
                        return
                    }
                    self.showPDF(document: document, progress: book.progress)
                }
            }
        case "EPUB":
            showLoading(message: L("正在解压 EPUB…", "Extracting EPUB…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result = try BookImporter.epubHTML(from: url, fontSize: fontSize, isDark: isDark)
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showEPUB(result: result, progress: book.progress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "MOBI", "AZW", "AZW3":
            showLoading(message: L(
                "正在解析 \(book.format)…\n首次打开可能需要一点时间",
                "Parsing \(book.format)…\nThe first open may take a moment"
            ))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result = try BookImporter.convertedEPUBHTML(
                        from: url,
                        fontSize: fontSize,
                        isDark: isDark
                    )
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showEPUB(result: result, progress: book.progress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        default:
            showUnsupported(message: L("暂不支持 \(book.format) 格式", "\(book.format) format is not supported yet"))
        }
    }

    private func showTextHTML(result: (htmlURL: URL, accessRoot: URL), progress: Double) {
        clearContent()
        epubRoot = result.accessRoot
        addWebReader(result: result, progress: progress)
    }

    private func showPDF(document: PDFDocument, progress: Double) {
        clearContent()
        let viewer = PDFView()
        viewer.autoScales = true
        viewer.displayMode = .singlePageContinuous
        viewer.backgroundColor = isDark ? NSColor(calibratedWhite: 0.1, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        viewer.document = document
        addContent(viewer)
        pdfView = viewer
        if document.pageCount > 0 {
            let pageIndex = min(
                document.pageCount - 1,
                max(0, Int((min(max(progress, 0), 0.999) * Double(document.pageCount)).rounded(.down)))
            )
            viewer.go(to: document.page(at: pageIndex) ?? document.page(at: 0)!)
        }
        pdfProgressObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewPageChanged,
            object: viewer,
            queue: .main
        ) { [weak self, weak viewer] _ in
            guard let self, let viewer, let document = viewer.document,
                  let page = viewer.currentPage,
                  document.pageCount > 1 else { return }
            let pageIndex = document.index(for: page)
            self.reportProgress(Double(pageIndex) / Double(document.pageCount - 1))
        }
    }

    private func showEPUB(result: (htmlURL: URL, accessRoot: URL), progress: Double) {
        clearContent()
        epubRoot = result.accessRoot
        addWebReader(result: result, progress: progress)
    }

    private func addWebReader(result: (htmlURL: URL, accessRoot: URL), progress: Double) {
        let controller = WKUserContentController()
        controller.add(self, name: "readerProgress")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        browser.setValue(false, forKey: "drawsBackground")
        browser.loadFileURL(result.htmlURL, allowingReadAccessTo: result.accessRoot)
        addContent(browser)
        webView = browser
        webUserContentController = controller
        currentProgress = min(max(progress, 0), 0.999)
    }

    private var secondaryTextColor: NSColor {
        isDark ? NSColor(calibratedWhite: 0.64, alpha: 1) : NSColor.secondaryLabelColor
    }

    private func showLoading(message: String) {
        showMessage(message, color: secondaryTextColor)
    }

    private func showUnsupported(message: String) {
        showMessage(message, color: secondaryTextColor)
    }

    private func showMessage(_ message: String, color: NSColor) {
        clearContent()
        let unsupportedView = NSView()
        unsupportedView.wantsLayer = true
        unsupportedView.layer?.backgroundColor = NSColor.clear.cgColor

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.maximumNumberOfLines = 6
        label.font = NSFont.systemFont(ofSize: 15)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        unsupportedView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: unsupportedView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: unsupportedView.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: unsupportedView.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: unsupportedView.trailingAnchor, constant: -32)
        ])
        addContent(unsupportedView)
    }

    private func addContent(_ content: NSView) {
        contentView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func clearContent() {
        if let pdfProgressObserver {
            NotificationCenter.default.removeObserver(pdfProgressObserver)
            self.pdfProgressObserver = nil
        }
        webUserContentController?.removeScriptMessageHandler(forName: "readerProgress")
        webUserContentController = nil
        contentView.subviews.forEach { $0.removeFromSuperview() }
        textView = nil
        pdfView = nil
        webView = nil
        epubRoot = nil
    }

    private func showEmptyState() {
        placeholderState = .empty
        titleLabel.stringValue = L("选择一本书开始阅读", "Select a book to start reading")
        subtitleLabel.stringValue = L("支持拖入本地文件，内容保存在你的 Mac 上", "Drag in local files; content stays on your Mac")
        clearContent()
        contentView.isHidden = true
        emptyState.isHidden = false
    }

    func handleBookRemoved(path: String) {
        guard currentBook?.path == path else { return }
        currentBook = nil
        currentProgress = 0
        placeholderState = .removed
        titleLabel.stringValue = L("这本书已从 iCloud 文件夹移除", "This book was removed from the iCloud folder")
        subtitleLabel.stringValue = L("请重新导入文件，或从左侧选择其他书籍", "Import it again or choose another book")
        showMessage(
            L("当前书籍文件已不存在\n同步已将它从书架移除", "The book file no longer exists\nSync removed it from the library"),
            color: secondaryTextColor
        )
    }

    func applyLanguage() {
        showSidebarButton.title = L("显示书架", "Show Library")
        showSidebarButton.toolTip = L("显示左侧书架（⌘⇧S）", "Show sidebar (⌘⇧S)")
        themeButton.title = isDark ? L("日间", "Day") : L("夜间", "Night")
        themeButton.toolTip = isDark
            ? L("切换到浅色阅读", "Switch to light reading")
            : L("切换到夜间阅读", "Switch to night reading")
        emptyTitleLabel.stringValue = L("安静地读一本书", "Read in peace")
        emptySubtitleLabel.stringValue = L(
            "从左侧导入书籍，或直接把文件拖进窗口",
            "Import books from the sidebar, or drag files into the window"
        )

        switch placeholderState {
        case .book:
            if let currentBook {
                subtitleLabel.stringValue = L("\(currentBook.format) · 本地文件", "\(currentBook.format) · Local file")
            }
        case .removed:
            titleLabel.stringValue = L("这本书已从 iCloud 文件夹移除", "This book was removed from the iCloud folder")
            subtitleLabel.stringValue = L("请重新导入文件，或从左侧选择其他书籍", "Import it again or choose another book")
            showMessage(
                L("当前书籍文件已不存在\n同步已将它从书架移除", "The book file no longer exists\nSync removed it from the library"),
                color: secondaryTextColor
            )
        case .empty:
            showEmptyState()
        }
    }

    @objc private func decreaseFont() {
        fontSize = max(12, fontSize - 1)
        UserDefaults.standard.set(Double(fontSize), forKey: "ReaderFontSize")
        fontSizeLabel.stringValue = "\(Int(fontSize))"
        textView?.font = NSFont(name: "Georgia", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        applyWebViewReaderStyle()
    }

    @objc private func increaseFont() {
        fontSize = min(32, fontSize + 1)
        UserDefaults.standard.set(Double(fontSize), forKey: "ReaderFontSize")
        fontSizeLabel.stringValue = "\(Int(fontSize))"
        textView?.font = NSFont(name: "Georgia", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        applyWebViewReaderStyle()
    }

    @objc private func toggleTheme() {
        isDark.toggle()
        UserDefaults.standard.set(isDark, forKey: "ReaderDarkMode")
        applyThemeAppearance()
        onThemeChanged?(isDark)
    }

    private func applyThemeAppearance() {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let background = isDark ? NSColor(calibratedWhite: 0.105, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)
        view.layer?.backgroundColor = background.cgColor
        titleLabel.textColor = isDark ? NSColor(calibratedWhite: 0.9, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)
        subtitleLabel.textColor = isDark ? NSColor(calibratedWhite: 0.62, alpha: 1) : NSColor.secondaryLabelColor
        fontSizeLabel.textColor = isDark ? NSColor(calibratedWhite: 0.78, alpha: 1) : NSColor.labelColor
        emptyMark.textColor = isDark
            ? NSColor(calibratedRed: 0.48, green: 0.7, blue: 0.6, alpha: 0.5)
            : NSColor(calibratedRed: 0.25, green: 0.46, blue: 0.37, alpha: 0.42)
        emptyTitleLabel.textColor = isDark ? NSColor(calibratedWhite: 0.9, alpha: 1) : NSColor(calibratedWhite: 0.2, alpha: 1)
        emptySubtitleLabel.textColor = isDark ? NSColor(calibratedWhite: 0.62, alpha: 1) : NSColor.secondaryLabelColor
        textView?.textColor = isDark ? NSColor(calibratedWhite: 0.88, alpha: 1) : NSColor(calibratedWhite: 0.22, alpha: 1)
        pdfView?.backgroundColor = isDark ? NSColor(calibratedWhite: 0.1, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        themeButton.title = isDark ? L("日间", "Day") : L("夜间", "Night")
        themeButton.image = NSImage(systemSymbolName: isDark ? "sun.max" : "moon", accessibilityDescription: nil)
        themeButton.toolTip = isDark
            ? L("切换到浅色阅读", "Switch to light reading")
            : L("切换到夜间阅读", "Switch to night reading")
        applyWebViewReaderStyle()
    }

    @objc private func toggleSidebarRequested() {
        onToggleSidebar?()
    }

    func setSidebarVisible(_ visible: Bool) {
        showSidebarButton.isHidden = visible
    }

    private var webReaderStyleScript: String {
        let background = isDark ? "#1b1c1a" : "#f6f5f0"
        let foreground = isDark ? "#e7e4dc" : "#2c302d"
        return """
        document.body.style.background='\(background)';
        document.body.style.color='\(foreground)';
        document.body.style.fontSize='\(Int(fontSize))px';
        var page = document.querySelector('.page');
        if (page) { page.style.fontSize='\(Int(fontSize))px'; }
        """
    }

    private func applyWebViewReaderStyle() {
        webView?.evaluateJavaScript(webReaderStyleScript)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readerProgress",
              let value = message.body as? NSNumber else { return }
        reportProgress(value.doubleValue)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let progress = min(max(currentProgress, 0), 0.999)
        let script = """
        (function() {
          \(webReaderStyleScript)
          var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          window.scrollTo(0, max * \(progress));
          if (!window.__intelReaderProgressInstalled) {
            window.__intelReaderProgressInstalled = true;
            var report = function() {
              var currentMax = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
              var value = currentMax <= 0 ? 0 : window.scrollY / currentMax;
              window.webkit.messageHandlers.readerProgress.postMessage(value);
            };
            window.addEventListener('scroll', report, {passive: true});
            report();
          }
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func reportProgress(_ progress: Double) {
        let value = min(max(progress, 0), 1)
        guard abs(value - currentProgress) >= 0.01 else { return }
        currentProgress = value
        if let id = currentBook?.id {
            onProgress?(id, value)
        }
    }
}

final class MainViewController: NSViewController {
    private let store = LibraryStore()
    private let sidebar = SidebarViewController()
    private let reader = ReaderViewController()
    private let rootView = NSView()
    private let divider = NSView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!
    private var sidebarVisible = true
    private let minimumContentSize = NSSize(width: 860, height: 560)
    private let autoSyncMinimumInterval: TimeInterval = 180
    private var isSyncing = false
    private var lastSyncDate: Date?
    private var activationObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var isDark: Bool { reader.isDarkMode }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.white.cgColor

        addChild(sidebar)
        addChild(reader)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(calibratedWhite: 0.83, alpha: 1).cgColor

        rootView.addSubview(sidebar.view)
        rootView.addSubview(divider)
        rootView.addSubview(reader.view)

        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: 280)
        dividerWidthConstraint = divider.widthAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarWidthConstraint,
            divider.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: rootView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            dividerWidthConstraint,
            reader.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onImport = { [weak self] in self?.importBooks() }
        sidebar.onSync = { [weak self] in self?.syncFromCloud(showStatus: true) }
        sidebar.onChooseFolder = { [weak self] in self?.chooseCloudFolder() }
        sidebar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebar.onSelect = { [weak self] book in self?.reader.show(book: book) }
        reader.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        reader.onThemeChanged = { [weak self] isDark in self?.applyTheme(isDark: isDark) }
        reader.onProgress = { [weak self] bookID, progress in
            self?.recordProgress(bookID: bookID, progress: progress)
        }
        sidebar.onDelete = { [weak self] book in
            self?.removeBook(book)
        }
        sidebar.onEditMetadata = { [weak self] book in
            self?.editBookMetadata(book)
        }
        sidebar.onDeleteFromCloud = { [weak self] book in
            self?.removeBookFromCloud(book)
        }
        sidebar.reload(books: store.books, scrollToTop: true)
        sidebar.setCloudStatus(.ready)
        sidebarVisible = !UserDefaults.standard.bool(forKey: "SidebarHidden")
        reader.setSidebarVisible(sidebarVisible)
        applySidebarVisibility(animated: false)
        applyTheme(isDark: isDark)

        DispatchQueue.main.async { [weak self] in
            self?.syncFromCloud(showStatus: false)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncOnActivation()
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyLanguage()
        }
    }

    private func applyLanguage() {
        view.window?.title = L("简阅", "EasyRead")
        sidebar.applyLanguage()
        reader.applyLanguage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let appearance = NSAppearance(named: reader.isDarkMode ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        view.window?.appearance = appearance
        stabilizeWindow()
    }

    private func applyTheme(isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        view.window?.appearance = appearance
        rootView.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor.white).cgColor
        divider.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.24, alpha: 1)
            : NSColor(calibratedWhite: 0.83, alpha: 1)).cgColor
        sidebar.applyTheme(isDark: isDark)
    }

    private func syncOnActivation() {
        guard !isSyncing else { return }
        if let lastSyncDate, Date().timeIntervalSince(lastSyncDate) < autoSyncMinimumInterval {
            return
        }
        syncFromCloud(showStatus: false)
    }

    @objc func importBooksFromMenu() {
        importBooks()
    }

    @objc func syncFromMenu() {
        syncFromCloud(showStatus: true)
    }

    @objc func toggleSidebarFromMenu() {
        toggleSidebar()
    }

    private func recordProgress(bookID: UUID, progress: Double) {
        guard let book = store.books.first(where: { $0.id == bookID }) else { return }
        var updated = book
        updated.progress = min(max(progress, 0), 1)
        store.update(updated)
        sidebar.refresh(book: updated)
    }

    private func toggleSidebar() {
        sidebarVisible.toggle()
        UserDefaults.standard.set(!sidebarVisible, forKey: "SidebarHidden")
        reader.setSidebarVisible(sidebarVisible)
        applySidebarVisibility(animated: true)
    }

    private func applySidebarVisibility(animated: Bool) {
        guard sidebarWidthConstraint != nil, dividerWidthConstraint != nil else { return }
        let update = {
            self.sidebarWidthConstraint.constant = self.sidebarVisible ? 280 : 0
            self.dividerWidthConstraint.constant = self.sidebarVisible ? 1 : 0
            self.sidebar.view.alphaValue = self.sidebarVisible ? 1 : 0
            self.divider.alphaValue = self.sidebarVisible ? 1 : 0
            self.view.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                update()
            }
        } else {
            update()
        }
    }

    private func removeBook(_ book: LibraryBook) {
        let alert = NSAlert()
        alert.messageText = L("从书架移除这本书？", "Remove this book from the library?")
        alert.informativeText = L(
            "只会从这个 Mac 版的书架中移除，不会删除 iCloud 文件夹里的原书。",
            "This only removes the book from the library on this Mac. The original file in your iCloud folder will not be deleted."
        )
        alert.addButton(withTitle: L("从书架移除", "Remove"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.remove(book)
        sidebar.reload(books: store.books, scrollToTop: true)
    }

    private func editBookMetadata(_ book: LibraryBook) {
        let alert = NSAlert()
        alert.messageText = L("编辑书名和作者", "Edit Title & Author")
        alert.informativeText = L(
            "只修改书架显示信息，不修改 iCloud 原文件。",
            "This only changes how the book appears in your library. The original iCloud file is untouched."
        )

        let editorView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        let titleCaption = NSTextField(labelWithString: L("书名", "Title"))
        titleCaption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleCaption.textColor = NSColor.secondaryLabelColor
        titleCaption.frame = NSRect(x: 0, y: 74, width: 360, height: 18)

        let titleField = NSTextField(string: book.title)
        titleField.placeholderString = L("书名", "Title")
        titleField.frame = NSRect(x: 0, y: 48, width: 360, height: 26)

        let authorCaption = NSTextField(labelWithString: L("作者", "Author"))
        authorCaption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        authorCaption.textColor = NSColor.secondaryLabelColor
        authorCaption.frame = NSRect(x: 0, y: 26, width: 360, height: 18)

        let authorField = NSTextField(string: book.author)
        authorField.placeholderString = L("作者（可留空）", "Author (optional)")
        authorField.frame = NSRect(x: 0, y: 0, width: 360, height: 26)

        editorView.addSubview(titleCaption)
        editorView.addSubview(titleField)
        editorView.addSubview(authorCaption)
        editorView.addSubview(authorField)
        alert.accessoryView = editorView
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = titleField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = authorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        var updated = book
        updated.title = title
        updated.author = author
        store.update(updated)
        sidebar.refresh(book: updated)
    }

    private func promptForText(
        title: String,
        message: String,
        initialValue: String,
        allowsEmpty: Bool,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initialValue)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.placeholderString = allowsEmpty ? L("可留空", "Optional") : L("请输入名称", "Enter a name")
        alert.accessoryView = field
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmpty || !value.isEmpty else { return }
        completion(value)
    }

    private func removeBookFromCloud(_ book: LibraryBook) {
        let cloud = CloudFolderSync.shared
        guard cloud.contains(URL(fileURLWithPath: book.path)) else {
            let alert = NSAlert()
            alert.messageText = L("这本书不在当前 iCloud 文件夹中", "This book is not in the current iCloud folder")
            alert.informativeText = L(
                "它只能从 Mac 书架移除，无法通过此选项删除。",
                "It can only be removed from the Mac library; this option cannot delete it."
            )
            alert.addButton(withTitle: L("好", "OK"))
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L("从 iCloud 删除这本书？", "Delete this book from iCloud?")
        alert.informativeText = L(
            "这会从“极简阅读”iCloud 文件夹中删除原文件，并可能同步删除 iPhone 上的对应文件。此操作无法通过本 App 撤销。",
            "This deletes the original file from the “极简阅读” iCloud folder and may also delete the matching file on your iPhone. This cannot be undone from this app."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("从 iCloud 删除", "Delete from iCloud"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(atPath: book.path)
            store.remove(book)
            sidebar.reload(books: store.books, scrollToTop: true)
            sidebar.setCloudStatus(.bookDeleted)
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.messageText = L("无法从 iCloud 删除这本书", "Could not delete this book from iCloud")
            errorAlert.runModal()
        }
    }

    private func stabilizeWindow() {
        guard let window = view.window else { return }

        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        window.contentMinSize = minimumContentSize
        window.minSize = minimumFrameSize

        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let targetContentSize = NSSize(
            width: max(currentContentSize.width, minimumContentSize.width),
            height: max(currentContentSize.height, minimumContentSize.height)
        )
        if targetContentSize != currentContentSize {
            window.setContentSize(targetContentSize)
        }

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let contentSize = window.contentRect(forFrameRect: window.frame).size
            guard contentSize.width < self?.minimumContentSize.width ?? 0 ||
                  contentSize.height < self?.minimumContentSize.height ?? 0 else {
                return
            }
            window.setContentSize(self?.minimumContentSize ?? NSSize(width: 860, height: 560))
        }
    }

    func importURLs(_ urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let importedBooks = validURLs.map { url -> LibraryBook in
                let finalURL: URL
                if CloudFolderSync.shared.isAvailable,
                   !url.path.hasPrefix(CloudFolderSync.shared.folderURL.path + "/") {
                    finalURL = (try? CloudFolderSync.shared.copyIntoFolder(url)) ?? url
                } else {
                    finalURL = url
                }
                CloudFolderSync.shared.prepareForReading(finalURL)
                return BookImporter.book(from: finalURL)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                importedBooks.forEach { self.store.add($0) }
                self.sidebar.reload(books: self.store.books, scrollToTop: true)
                if let first = importedBooks.first {
                    self.reader.show(book: first)
                }
                self.sidebar.setCloudStatus(.booksAdded(count: importedBooks.count))
            }
        }
    }

    private func syncFromCloud(showStatus: Bool) {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncDate = Date()
        if showStatus {
            sidebar.setCloudStatus(.syncing)
        }

        let existingPaths = Set(store.books.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let authorCandidatePaths = Set(
            store.books
                .filter { $0.author.isEmpty }
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let sync = CloudFolderSync.shared
            let urls = sync.bookURLs()
            urls.forEach { sync.prepareForReading($0) }

            let urlsByPath = Dictionary(
                urls.map { ($0.standardizedFileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let newBooks = urls
                .filter { !existingPaths.contains($0.standardizedFileURL.path) }
                .map { BookImporter.book(from: $0) }
            let inferredAuthors: [(path: String, author: String)] = authorCandidatePaths.compactMap { path in
                guard let url = urlsByPath[path] else { return nil }
                let author = BookImporter.inferredAuthor(from: url)
                return author.isEmpty ? nil : (path, author)
            }

            DispatchQueue.main.async {
                let syncAvailable = sync.isAvailable
                let cloudPaths = Set(urlsByPath.keys)
                let staleBooks: [LibraryBook]
                if syncAvailable {
                    staleBooks = self.store.books.filter { book in
                        sync.contains(URL(fileURLWithPath: book.path)) &&
                        !cloudPaths.contains(URL(fileURLWithPath: book.path).standardizedFileURL.path)
                    }
                } else {
                    // Never remove local records while the iCloud folder is unavailable.
                    staleBooks = []
                }

                if !staleBooks.isEmpty {
                    self.store.remove(staleBooks)
                    staleBooks.forEach { self.reader.handleBookRemoved(path: $0.path) }
                }

                var currentPaths = Set(
                    self.store.books.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
                )
                var addedCount = 0
                newBooks.forEach { book in
                    let path = URL(fileURLWithPath: book.path).standardizedFileURL.path
                    guard !currentPaths.contains(path) else { return }
                    self.store.add(book)
                    currentPaths.insert(path)
                    addedCount += 1
                }

                inferredAuthors.forEach { entry in
                    guard let existing = self.store.books.first(where: {
                        URL(fileURLWithPath: $0.path).standardizedFileURL.path == entry.path
                    }), existing.author.isEmpty else {
                        return
                    }
                    var updated = existing
                    updated.author = entry.author
                    self.store.update(updated)
                }
                self.sidebar.reload(books: self.store.books, scrollToTop: addedCount > 0)

                if !syncAvailable {
                    self.sidebar.setCloudStatus(.folderMissing, color: .systemOrange)
                } else if addedCount > 0 || !staleBooks.isEmpty {
                    self.sidebar.setCloudStatus(.syncCompleted(added: addedCount, removed: staleBooks.count))
                } else {
                    self.sidebar.setCloudStatus(.synced(bookCount: urls.count))
                }
                self.isSyncing = false
            }
        }
    }

    private func chooseCloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择此文件夹", "Choose")
        panel.message = L("请选择 iCloud Drive 中的“极简阅读”文件夹", "Choose the “极简阅读” folder in iCloud Drive")
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            CloudFolderSync.shared.setFolder(folder)
            self?.sidebar.setCloudStatus(.folderChosen(path: CloudFolderSync.shared.displayPath))
            self?.syncFromCloud(showStatus: true)
        }
    }

    private func importBooks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["txt", "epub", "pdf", "mobi", "azw", "azw3"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.message = L("选择要加入简阅书架的文件", "Choose files to add to your EasyRead library")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importURLs(panel.urls)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let windowFrameKey = "MainWindowFrame"
    private var window: NSWindow!
    private var mainViewController: MainViewController!
    private var pendingOpenURLs: [URL] = []
    private var isWindowReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialDark = UserDefaults.standard.bool(forKey: "ReaderDarkMode")
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: initialDark ? .darkAqua : .aqua)
        mainViewController = MainViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("简阅", "EasyRead")
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: initialDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentViewController = mainViewController
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.minSize = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 860, height: 560)
        ).size
        restoreWindowFrame()
        isWindowReady = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        buildMainMenu()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        processPendingOpenURLs()
    }

    private func restoreWindowFrame() {
        let minimumFrame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 860, height: 560)
        ).size
        if let raw = UserDefaults.standard.array(forKey: Self.windowFrameKey),
           let stored = Self.frame(from: raw) {
            var frame = NSRect(
                x: stored.origin.x,
                y: stored.origin.y,
                width: max(stored.width, minimumFrame.width),
                height: max(stored.height, minimumFrame.height)
            )
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                window.setFrame(frame, display: false)
                saveWindowFrame()
                return
            }
        }
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        saveWindowFrame()
    }

    private static func frame(from raw: [Any]) -> NSRect? {
        guard raw.count == 4 else { return nil }
        let values: [Double] = raw.compactMap { item in
            if let number = item as? NSNumber {
                return number.doubleValue
            }
            if let string = item as? String {
                return Double(string)
            }
            return nil
        }
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func saveWindowFrame() {
        guard let window else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set(
            [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height)],
            forKey: Self.windowFrameKey
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard isWindowReady else { return }
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard isWindowReady else { return }
        saveWindowFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowFrame()
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpenURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueueOpenURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        enqueueOpenURLs(filenames.map(URL.init(fileURLWithPath:)))
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appName = L("简阅", "EasyRead")

        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(
            title: L("关于简阅", "About EasyRead"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let languageMenuItem = NSMenuItem(title: L("语言 / Language", "Language / 语言"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: L("语言 / Language", "Language / 语言"))
        for language in [AppLanguage.chinese, .english] {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(changeLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = AppLocalization.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageMenuItem.submenu = languageMenu
        appMenu.addItem(languageMenuItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: L("隐藏简阅", "Hide EasyRead"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: L("隐藏其他", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: L("显示全部", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("退出简阅", "Quit EasyRead"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem(title: L("文件", "File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L("文件", "File"))
        let importItem = NSMenuItem(
            title: L("导入书籍…", "Import Books…"),
            action: #selector(MainViewController.importBooksFromMenu),
            keyEquivalent: "o"
        )
        importItem.target = mainViewController
        fileMenu.addItem(importItem)

        let syncItem = NSMenuItem(
            title: L("同步 iCloud", "Sync iCloud"),
            action: #selector(MainViewController.syncFromMenu),
            keyEquivalent: "r"
        )
        syncItem.target = mainViewController
        fileMenu.addItem(syncItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem(title: L("编辑", "Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(withTitle: L("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: L("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切", "Cut"), action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝", "Copy"), action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴", "Paste"), action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选", "Select All"), action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem(title: L("显示", "View"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L("显示", "View"))
        let toggleSidebarItem = NSMenuItem(
            title: L("显示/隐藏书架", "Show/Hide Library"),
            action: #selector(MainViewController.toggleSidebarFromMenu),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .shift]
        toggleSidebarItem.target = mainViewController
        viewMenu.addItem(toggleSidebarItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw),
              language != AppLocalization.language else { return }
        AppLocalization.setLanguage(language)
    }

    @objc private func languageDidChange() {
        buildMainMenu()
    }

    private func enqueueOpenURLs(_ urls: [URL]) {
        let fileURLs = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }
        guard !fileURLs.isEmpty else { return }

        if mainViewController == nil {
            pendingOpenURLs.append(contentsOf: fileURLs)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.mainViewController.importURLs(fileURLs)
        }
    }

    private func processPendingOpenURLs() {
        guard !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        enqueueOpenURLs(urls)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.finishLaunching()
application.run()
