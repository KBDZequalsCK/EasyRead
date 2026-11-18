import AppKit
import CoreFoundation
import CryptoKit
import Foundation
import PDFKit
import Security
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

enum BookSource: String, Codable, CaseIterable {
    case iCloud
    case jianguoyun
    case local

    var title: String {
        switch self {
        case .iCloud:
            return "iCloud"
        case .jianguoyun:
            return L("WebDAV", "WebDAV")
        case .local:
            return L("本地", "Local")
        }
    }

    var libraryTitle: String {
        switch self {
        case .iCloud:
            return L("iCloud 书库", "iCloud Library")
        case .jianguoyun:
            return L("WebDAV 书库", "WebDAV Library")
        case .local:
            return L("本地书库", "Local Library")
        }
    }

    var symbolName: String {
        switch self {
        case .iCloud:
            return "icloud"
        case .jianguoyun:
            return "arrow.triangle.2.circlepath"
        case .local:
            return "folder"
        }
    }

    var summary: String {
        switch self {
        case .iCloud:
            return L("读取 iCloud“极简阅读”文件夹中的书籍",
                     "Reads the books in your iCloud “极简阅读” folder")
        case .jianguoyun:
            return L("书籍文件与阅读进度都和 iPhone、iPad 同步",
                     "Syncs book files and reading positions with iPhone and iPad")
        case .local:
            return L("只使用这台 Mac 上的书籍文件",
                     "Uses only book files on this Mac")
        }
    }
}

/// The library picker shows two shelves. iCloud and a plain folder are both
/// just "scan this folder", so they share one shelf and one folder choice;
/// WebDAV keeps its own cached shelf because it uploads and downloads books.
enum LibraryShelf: String, CaseIterable {
    case folder
    case webdav

    var title: String {
        switch self {
        case .folder:
            return L("书库", "Library")
        case .webdav:
            return L("WebDAV 书库", "WebDAV Library")
        }
    }

    var symbolName: String {
        switch self {
        case .folder:
            return "folder"
        case .webdav:
            return "arrow.triangle.2.circlepath"
        }
    }

    var summary: String {
        switch self {
        case .folder:
            return L("扫描所选文件夹中的书籍；默认使用 iCloud“极简阅读”",
                     "Reads one folder of books; the iCloud “极简阅读” folder by default")
        case .webdav:
            return L("书籍文件与阅读进度都通过 WebDAV 同步",
                     "Syncs books and reading positions through WebDAV")
        }
    }

    func contains(_ source: BookSource) -> Bool {
        switch self {
        case .folder:
            return source != .jianguoyun
        case .webdav:
            return source == .jianguoyun
        }
    }
}

enum ZenBookCache {
    static var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("IntelReader", isDirectory: true)
            .appendingPathComponent("ZenReaderBooks", isDirectory: true)
    }

    static func contains(_ path: String) -> Bool {
        let folder = directoryURL.standardizedFileURL.path
        let item = URL(fileURLWithPath: path).standardizedFileURL.path
        return item == folder || item.hasPrefix(folder + "/")
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}

struct LibraryBook: Codable, Equatable {
    let id: UUID
    let path: String
    var title: String
    let format: String
    var author: String
    /// Local reading anchor used to reopen the rendered page: for PDFs this is
    /// the page fraction, for HTML books it is the scroll fraction of the
    /// rendered page (which is not proportional to the amount of text).
    var progress: Double
    /// Character fraction of the book's extracted text — the same metric the
    /// ZenReader sync converts to and from the phone's chapter-weighted
    /// percent. Web pages scroll by rendered height, so this is kept apart
    /// from `progress`; nil for PDFs and books last read by an older build.
    var textProgress: Double?
    let addedAt: Date
    var progressUpdatedAt: Date?
    /// When this Mac last opened the book. The shelf keeps recently read books
    /// at the top, so opening one is an activity even before progress moves.
    var lastOpenedAt: Date?
    /// The one library this book belongs to. A book is never shown in two libraries.
    var source: BookSource
    /// ZenReader's own percent for Jianguoyun books (0...1). Phone positions are
    /// chapter-weighted, so this number can differ from `progress`, which is the
    /// local character/page ratio. The shelf shows this value after a sync so
    /// the Mac and the phone report the same percentage.
    var zenProgress: Double?
    /// The phone's `readText` anchor (the sentence at its current position).
    /// It is only valid while `progress` still equals `zenLocatorAnchor`; once
    /// this Mac reads further the percentage no longer matches and the stale
    /// anchor is ignored.
    var zenLocatorText: String?
    var zenLocatorAnchor: Double?
    /// A short text anchor at the top of this Mac's reader while scrolling.
    /// Uploads use it to find the same sentence in the chapter table so the
    /// phone lands on the exact passage instead of a re-interpreted percent.
    var localTextAnchor: String?
    var localTextAnchorProgress: Double?

    private enum CodingKeys: String, CodingKey {
        case id, path, title, format, author, progress, textProgress, addedAt, progressUpdatedAt, lastOpenedAt,
             source, zenProgress, zenLocatorText, zenLocatorAnchor, localTextAnchor, localTextAnchorProgress
    }

    init(
        id: UUID,
        path: String,
        title: String,
        format: String,
        author: String = "",
        progress: Double,
        textProgress: Double? = nil,
        addedAt: Date,
        progressUpdatedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        source: BookSource? = nil,
        zenProgress: Double? = nil,
        zenLocatorText: String? = nil,
        zenLocatorAnchor: Double? = nil,
        localTextAnchor: String? = nil,
        localTextAnchorProgress: Double? = nil
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.format = format
        self.author = author
        self.progress = progress
        self.textProgress = textProgress
        self.addedAt = addedAt
        self.progressUpdatedAt = progressUpdatedAt
        self.lastOpenedAt = lastOpenedAt
        self.source = source ?? Self.inferredSource(for: path)
        self.zenProgress = zenProgress
        self.zenLocatorText = zenLocatorText
        self.zenLocatorAnchor = zenLocatorAnchor
        self.localTextAnchor = localTextAnchor
        self.localTextAnchorProgress = localTextAnchorProgress
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        title = try values.decode(String.self, forKey: .title)
        format = try values.decode(String.self, forKey: .format)
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? ""
        progress = try values.decode(Double.self, forKey: .progress)
        textProgress = try values.decodeIfPresent(Double.self, forKey: .textProgress)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        progressUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .progressUpdatedAt)
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        // Shelf records created before libraries were separated have no source;
        // derive it once from where the file lives.
        source = try values.decodeIfPresent(BookSource.self, forKey: .source)
            ?? Self.inferredSource(for: path)
        zenProgress = try values.decodeIfPresent(Double.self, forKey: .zenProgress)
        zenLocatorText = try values.decodeIfPresent(String.self, forKey: .zenLocatorText)
        zenLocatorAnchor = try values.decodeIfPresent(Double.self, forKey: .zenLocatorAnchor)
        localTextAnchor = try values.decodeIfPresent(String.self, forKey: .localTextAnchor)
        localTextAnchorProgress = try values.decodeIfPresent(Double.self, forKey: .localTextAnchorProgress)
    }

    static func inferredSource(for path: String) -> BookSource {
        if ZenBookCache.contains(path) {
            return .jianguoyun
        }
        let cloudPath = CloudFolderSync.shared.folderURL.standardizedFileURL.path
        let itemPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if itemPath == cloudPath || itemPath.hasPrefix(cloudPath + "/") {
            return .iCloud
        }
        return .local
    }

    /// The position ZenReader should receive: the extracted-text fraction for
    /// web books, or the page fraction for PDFs. Falls back to the legacy
    /// scroll fraction for books read before `textProgress` existed.
    var syncedPosition: Double {
        min(max(textProgress ?? progress, 0), 1)
    }

    /// When the book last entered the reading flow on any device. The shelf
    /// sorts by this date so recently read books stay on top; a freshly
    /// imported book starts there too, then drifts down once others are read.
    var lastActivityAt: Date {
        max(addedAt, max(lastOpenedAt ?? .distantPast, progressUpdatedAt ?? .distantPast))
    }
}

/// One row in the reader's table of contents.
struct ReaderChapter {
    let title: String
    /// Character/page fraction used by the existing reader jump path.
    let progress: Double?
    /// HTML anchor for formats without a text model (Markdown, comics, FB2).
    let anchorID: String?
    let pageIndex: Int?
    let level: Int
    /// First line of a text-model chapter. Chapter progress is a character
    /// ratio of the plain text, which drifts from the rendered paragraph
    /// index; jumping by this exact line keeps the TOC on the heading.
    var locatorText: String? = nil
    /// Nested entries from the book's own navigation (an EPUB NCX/nav file
    /// or a MOBI guide TOC). Collections use the top level for each included
    /// book, so the contents list can fold the books that are not being read.
    var children: [ReaderChapter] = []

    var isGroup: Bool { !children.isEmpty }
}

final class LibraryStore {
    private(set) var books: [LibraryBook] = []

    private let fileManager = FileManager.default
    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "EasyRead.LibraryStore.save", qos: .utility)
    private let saveLock = NSLock()
    private var pendingData: Data?
    private var saveScheduled = false

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

    /// Removes every bookshelf record on this Mac. Book files on disk are never touched.
    func removeAll() {
        guard !books.isEmpty else { return }
        books.removeAll()
        save()
    }

    func update(_ book: LibraryBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save()
    }

    /// Reading progress changes every few percent. Encoding is cheap, but
    /// rewriting library.json at that rate puts avoidable disk I/O on the main
    /// thread, so progress snapshots are coalesced into one write.
    func updateProgress(_ book: LibraryBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save(immediately: false)
    }

    func flushPendingSave() {
        saveQueue.sync { flush() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LibraryBook].self, from: data) else {
            return
        }
        books = decoded
    }

    private func save(immediately: Bool = true) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        saveLock.lock()
        pendingData = data
        let needsSchedule = !saveScheduled
        if needsSchedule { saveScheduled = true }
        saveLock.unlock()

        if immediately {
            saveQueue.sync { flush() }
            return
        }
        guard needsSchedule else { return }
        saveQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        saveLock.lock()
        let data = pendingData
        pendingData = nil
        saveScheduled = false
        saveLock.unlock()
        guard let data else { return }
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
    var properties: [String: String] = [:]
    var mediaTypes: [String: String] = [:]
    var spine: [String] = []
    var spineTOC: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href.removingPercentEncoding ?? href
                properties[id] = attributeDict["properties"] ?? ""
                mediaTypes[id] = attributeDict["media-type"] ?? ""
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        case "spine":
            spineTOC = attributeDict["toc"]
        default:
            break
        }
    }
}

/// A node in an EPUB NCX or EPUB 3 navigation document.
private final class EPUBNavNode {
    var title: String
    var href: String?
    var children: [EPUBNavNode] = []

    init(title: String, href: String?) {
        self.title = title
        self.href = href
    }
}

/// Reads the nested `navMap` of an EPUB 2 `toc.ncx`.
private final class EPUBNCXParser: NSObject, XMLParserDelegate {
    private(set) var roots: [EPUBNavNode] = []
    private var stack: [EPUBNavNode] = []
    private var inLabel = false
    private var readingText = false
    private var labelText = ""

    private func localName(_ elementName: String, _ qName: String?) -> String {
        ((qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName)
            .lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName, qName) {
        case "navpoint":
            stack.append(EPUBNavNode(title: "", href: nil))
        case "navlabel":
            inLabel = true
        case "text":
            if inLabel {
                readingText = true
                labelText = ""
            }
        case "content":
            if let src = attributeDict["src"], !stack.isEmpty {
                stack[stack.count - 1].href = src
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingText {
            labelText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName, qName) {
        case "text":
            if readingText, !stack.isEmpty {
                let value = labelText
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !value.isEmpty {
                    stack[stack.count - 1].title = value
                }
            }
            readingText = false
        case "navlabel":
            inLabel = false
        case "navpoint":
            guard let node = stack.popLast() else { break }
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        default:
            break
        }
    }
}

/// Reads the nested `<ol>` list of an EPUB 3 navigation document.
private final class EPUBHTMLNavParser: NSObject, XMLParserDelegate {
    private(set) var roots: [EPUBNavNode] = []
    private var navDepth = 0
    private var tocNavDepth = 0
    private var listDepth = 0
    private var readingLink = false
    private var linkText = ""
    private var linkHref: String?
    private var insertionStack: [(depth: Int, node: EPUBNavNode)] = []

    private func localName(_ elementName: String, _ qName: String?) -> String {
        ((qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName)
            .lowercased()
    }

    private func isTableOfContents(_ attributes: [String: String]) -> Bool {
        for (key, value) in attributes {
            let name = key.lowercased()
            guard name == "epub:type" || name == "type" || name == "role" else { continue }
            let type = value.lowercased()
            if type.contains("toc") || type.contains("doc-toc") {
                return true
            }
        }
        return false
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName, qName) {
        case "nav":
            navDepth += 1
            if tocNavDepth == 0, isTableOfContents(attributeDict) {
                tocNavDepth = navDepth
            }
        case "ol":
            if tocNavDepth > 0 { listDepth += 1 }
        case "a":
            if tocNavDepth > 0 {
                readingLink = true
                linkText = ""
                linkHref = attributeDict["href"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingLink {
            linkText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName, qName) {
        case "a":
            if readingLink {
                let title = linkText
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !title.isEmpty {
                    let depth = max(listDepth, 1)
                    while let last = insertionStack.last, last.depth >= depth {
                        insertionStack.removeLast()
                    }
                    let node = EPUBNavNode(title: title, href: linkHref)
                    if let parent = insertionStack.last?.node {
                        parent.children.append(node)
                    } else {
                        roots.append(node)
                    }
                    insertionStack.append((depth, node))
                }
            }
            readingLink = false
        case "ol":
            if tocNavDepth > 0 {
                listDepth = max(0, listDepth - 1)
            }
        case "nav":
            if tocNavDepth == navDepth {
                tocNavDepth = 0
            }
            navDepth = max(0, navDepth - 1)
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
    case mobiInvalid
    case mobiDRMProtected
    case mobiUnsupportedCompression(Int)
    case fb2Invalid
    case comicInvalid
    case rtfInvalid
    case docxInvalid

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L("这个文件格式暂时只能加入书架，尚未提供本地解码器。",
                     "This format can be added to the library, but no local decoder is available yet.")
        case .invalidEPUB:
            return L("EPUB 文件结构无法识别。", "The EPUB file structure could not be recognized.")
        case .extractionFailed:
            return L("无法解压这个 EPUB 文件。", "This EPUB file could not be extracted.")
        case .mobiInvalid:
            return L("MOBI/AZW 文件结构无法识别，可能已损坏。",
                     "The MOBI/AZW file could not be recognized; it may be damaged.")
        case .mobiDRMProtected:
            return L("这本书带有 Kindle DRM 加密，EasyRead 无法直接解码。\n请在已授权的设备上阅读，或先移除 DRM 再导入。",
                     "This book is protected by Kindle DRM and cannot be decoded directly.\nRead it on an authorized device, or remove the DRM first.")
        case .mobiUnsupportedCompression(let type):
            return L("不支持这种 MOBI 压缩方式（\(type)）。",
                     "This MOBI compression type is not supported (\(type)).")
        case .fb2Invalid:
            return L("FB2 文件结构无法识别，可能已损坏。",
                     "The FB2 file could not be recognized; it may be damaged.")
        case .comicInvalid:
            return L("没有在压缩包中找到漫画图片。",
                     "No comic page images were found in the archive.")
        case .rtfInvalid:
            return L("RTF 文件结构无法识别，可能已损坏。",
                     "The RTF file could not be recognized; it may be damaged.")
        case .docxInvalid:
            return L("DOCX 文件结构无法识别，可能已损坏。",
                     "The DOCX file could not be recognized; it may be damaged.")
        }
    }
}

enum BookImporter {
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    /// Formats the iPhone reader understands. Markdown is intentionally not in
    /// this list: it stays readable on the Mac without adding an entry the
    /// phone cannot open.
    static let phoneSyncExtensions: Set<String> = ["txt", "epub", "pdf", "mobi", "azw", "azw3"]

    static func formatName(forExtension ext: String) -> String {
        let lower = ext.lowercased()
        if markdownExtensions.contains(lower) {
            return "MD"
        }
        return lower.isEmpty ? "FILE" : lower.uppercased()
    }

    static func isPhoneSyncable(format: String) -> Bool {
        phoneSyncExtensions.contains(format.lowercased())
    }

    static func book(from url: URL, source: BookSource? = nil) -> LibraryBook {
        let ext = url.pathExtension.lowercased()
        return LibraryBook(
            id: UUID(),
            path: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            format: formatName(forExtension: ext),
            author: inferredAuthor(from: url),
            progress: 0,
            addedAt: Date(),
            source: source
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
        if isEPUBPackage(at: url) {
            guard let containerData = try? Data(
                    contentsOf: url.appendingPathComponent("META-INF/container.xml")
                  ),
                  let rootFilePath = epubContainerRootFilePath(from: containerData),
                  let opfData = try? Data(contentsOf: url.appendingPathComponent(rootFilePath)) else {
                return nil
            }
            return epubAuthor(fromOPF: opfData)
        }

        guard let archive = try? ZipArchive(url: url),
              let containerData = try? archive.contents(of: "META-INF/container.xml"),
              let rootFilePath = epubContainerRootFilePath(from: containerData),
              let opfData = try? archive.contents(of: rootFilePath) else {
            return nil
        }
        return epubAuthor(fromOPF: opfData)
    }

    static func epubContainerRootFilePath(from data: Data) -> String? {
        let parser = ContainerParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), let rootFilePath = parser.rootFilePath else { return nil }
        return rootFilePath.removingPercentEncoding ?? rootFilePath
    }

    static func epubPackage(from data: Data) -> (
        manifest: [String: String],
        spine: [String],
        properties: [String: String],
        mediaTypes: [String: String],
        spineTOC: String?
    )? {
        let parser = EPUBParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), !parser.spine.isEmpty else { return nil }
        return (
            parser.manifest,
            parser.spine,
            parser.properties,
            parser.mediaTypes,
            parser.spineTOC
        )
    }

    private static func epubAuthor(fromOPF data: Data) -> String? {
        let parser = EPUBMetadataParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        return parser.author
    }

    /// Collapses `.` and `..` components so archive paths can be compared and
    /// used as extraction destinations safely.
    static func normalizedEPUBPath(_ path: String) -> String {
        var parts: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return parts.joined(separator: "/")
    }

    static func decodeEPUBText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Chapters are merged into one reader page, so a relative image such as
    /// `../images/00001.jpeg` would otherwise resolve outside the reader
    /// folder. Rewrite `src` / `xlink:href` to the extracted workspace path.
    static func rewriteEPUBResourceURLs(
        in html: String,
        chapterPath: String,
        resolve: (String) -> String?
    ) -> String {
        let pattern = #"(?i)\b(src|xlink:href)\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }
        let chapterDirectory = (chapterPath as NSString).deletingLastPathComponent
        var result = html
        for match in matches.reversed() {
            let doubleQuoted = match.range(at: 3)
            let singleQuoted = match.range(at: 4)
            let valueRange = doubleQuoted.location != NSNotFound ? doubleQuoted
                : singleQuoted.location != NSNotFound ? singleQuoted : NSRange(location: NSNotFound, length: 0)
            guard valueRange.location != NSNotFound else { continue }
            let raw = nsHTML.substring(with: valueRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  !raw.hasPrefix("#"),
                  !raw.hasPrefix("data:"),
                  !raw.contains("://") else { continue }
            let withoutFragment = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
            let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
            let combined = chapterDirectory.isEmpty ? decoded : "\(chapterDirectory)/\(decoded)"
            let normalized = normalizedEPUBPath(combined)
            guard let replacement = resolve(normalized) else { continue }
            result = (result as NSString).replacingCharacters(in: valueRange, with: replacement)
        }
        return result
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

    static func epubHTML(
        from url: URL,
        fontSize: CGFloat = 19,
        isDark: Bool = false,
        publisherStyles: Bool = false
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

        let bodies: [String]
        if isEPUBPackage(at: url) {
            // iCloud and Apple Books may expose EPUBs as directory packages.
            // Work on a temporary copy so generated HTML never enters iCloud.
            let copiedRoot = workspace.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: url, to: copiedRoot)
            guard let containerData = try? Data(
                    contentsOf: copiedRoot.appendingPathComponent("META-INF/container.xml")
                  ),
                  let rootFilePath = epubContainerRootFilePath(from: containerData),
                  let opfData = try? Data(contentsOf: copiedRoot.appendingPathComponent(rootFilePath)),
                  let package = epubPackage(from: opfData) else {
                throw ReaderError.invalidEPUB
            }
            let opfDirectory = (rootFilePath as NSString).deletingLastPathComponent
            let rootName = copiedRoot.lastPathComponent
            bodies = package.spine.compactMap { idref -> String? in
                guard let href = package.manifest[idref] else { return nil }
                let chapterPath = normalizedEPUBPath(
                    opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
                )
                guard let source = try? String(
                        contentsOf: copiedRoot.appendingPathComponent(chapterPath),
                        encoding: .utf8
                      ) else { return nil }
                return rewriteEPUBResourceURLs(
                    in: bodyContents(from: source),
                    chapterPath: chapterPath
                ) { candidate in
                    let resourceURL = copiedRoot.appendingPathComponent(candidate)
                    return fileManager.fileExists(atPath: resourceURL.path)
                        ? "\(rootName)/\(candidate)"
                        : nil
                }
            }
        } else {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: url)
            } catch {
                throw ReaderError.invalidEPUB
            }
            guard let containerData = try? archive.contents(of: "META-INF/container.xml"),
                  let rootFilePath = epubContainerRootFilePath(from: containerData),
                  let opfData = try? archive.contents(of: rootFilePath),
                  let package = epubPackage(from: opfData) else {
                throw ReaderError.invalidEPUB
            }
            let opfDirectory = (rootFilePath as NSString).deletingLastPathComponent
            bodies = package.spine.compactMap { idref -> String? in
                guard let href = package.manifest[idref] else { return nil }
                let chapterPath = normalizedEPUBPath(
                    opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
                )
                guard let chapterData = try? archive.contents(of: chapterPath),
                      let source = decodeEPUBText(chapterData) else { return nil }
                return rewriteEPUBResourceURLs(
                    in: bodyContents(from: source),
                    chapterPath: chapterPath
                ) { candidate in
                    archive.contains(candidate) ? candidate : nil
                }
            }
            // Only images, fonts and other non-document entries need to reach
            // the reader folder; chapters are already read from memory.
            try? archive.extract(to: workspace) { name in
                guard ZipArchive.isSafePath(name), !name.hasSuffix("/") else { return false }
                let ext = (name as NSString).pathExtension.lowercased()
                return !["html", "xhtml", "htm", "opf", "ncx", "xml", "css", "js"].contains(ext)
            }
        }

        guard !bodies.isEmpty else {
            throw ReaderError.invalidEPUB
        }
        var extraCSS = ""
        if publisherStyles {
            if isEPUBPackage(at: url) {
                let copiedRoot = workspace.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                extraCSS = epubStyleBlocks(
                    from: copiedRoot,
                    workspacePrefix: copiedRoot.lastPathComponent,
                    fontSize: fontSize
                )
            } else if let archive = try? ZipArchive(url: url) {
                extraCSS = epubStyleBlocks(from: archive, fontSize: fontSize)
            }
        }
        let body = bodies.joined(separator: "\n<hr class=\"chapter-break\">\n")
        let html = readerDocument(
            body: body,
            fontSize: fontSize,
            isDark: isDark,
            extraCSS: extraCSS
        )
        let htmlURL = workspace.appendingPathComponent("intel-reader.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, workspace)
    }

    private static func epubStyleBlocks(
        from archive: ZipArchive,
        fontSize: CGFloat
    ) -> String {
        let cssNames = archive.names
            .filter { $0.lowercased().hasSuffix(".css") && ZipArchive.isSafePath($0) }
            .sorted()
        guard !cssNames.isEmpty else { return "" }
        var combined = ""
        for name in cssNames {
            guard let data = try? archive.contents(of: name),
                  let css = decodeEPUBText(data) else { continue }
            let rewritten = rewriteCSSURLs(in: css, cssPath: name) { candidate in
                archive.contains(candidate) ? candidate : nil
            }
            combined += "\n/* \(name) */\n\(rewritten)\n"
        }
        return publisherStyleTag(combined, fontSize: fontSize)
    }

    private static func epubStyleBlocks(
        from root: URL,
        workspacePrefix: String,
        fontSize: CGFloat
    ) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }
        var cssFiles: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            if file.pathExtension.lowercased() == "css" {
                cssFiles.append(file)
            }
        }
        guard !cssFiles.isEmpty else { return "" }
        var combined = ""
        for file in cssFiles.sorted(by: { $0.path < $1.path }) {
            guard let css = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relative = file.path
                .replacingOccurrences(of: root.path + "/", with: "")
            let chapterPath = relative
            let rewritten = rewriteCSSURLs(in: css, cssPath: chapterPath) { candidate in
                let resource = root.appendingPathComponent(candidate)
                return fileManager.fileExists(atPath: resource.path)
                    ? "\(workspacePrefix)/\(candidate)"
                    : nil
            }
            combined += "\n/* \(relative) */\n\(rewritten)\n"
        }
        return publisherStyleTag(combined, fontSize: fontSize)
    }

    private static func publisherStyleTag(_ css: String, fontSize: CGFloat) -> String {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        <style>
        \(trimmed)
        html body { font-size: \(Int(fontSize))px !important; }
        </style>
        """
    }

    static func rewriteCSSURLs(
        in css: String,
        cssPath: String,
        resolve: (String) -> String?
    ) -> String {
        var working = css
        // Imported sheets are all inlined too, so drop @import statements.
        working = working.replacingOccurrences(
            of: #"(?i)@import\s+(?:url\()?['"]?[^'")\s]+['"]?\)?\s*;"#,
            with: "",
            options: .regularExpression
        )
        let pattern = #"(?i)url\(\s*['"]?([^'")]+)['"]?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return working }
        let nsCSS = working as NSString
        let matches = regex.matches(
            in: working,
            options: [],
            range: NSRange(location: 0, length: nsCSS.length)
        )
        guard !matches.isEmpty else { return working }
        let cssDirectory = (cssPath as NSString).deletingLastPathComponent
        var result = working
        for match in matches.reversed() {
            let raw = nsCSS.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  !raw.hasPrefix("#"),
                  !raw.hasPrefix("data:"),
                  !raw.contains("://") else { continue }
            let withoutFragment = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
            let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
            let combined = cssDirectory.isEmpty ? decoded : "\(cssDirectory)/\(decoded)"
            let normalized = normalizedEPUBPath(combined)
            guard let replacement = resolve(normalized) else { continue }
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: "url(\"\(replacement)\")"
            )
        }
        return result
    }

    /// Shared wrapper for every WebKit-rendered book. MOBI/AZW/AZW3 and EPUB
    /// share it so all text formats keep the same margins, font size, theme
    /// and chapter separators.
    static func readerDocument(
        body: String,
        fontSize: CGFloat,
        isDark: Bool,
        extraCSS: String = ""
    ) -> String {
        let background = isDark ? "#1b1c1a" : "#f6f5f0"
        let foreground = isDark ? "#e7e4dc" : "#2c302d"
        let linkColor = isDark ? "#8db6a0" : "#3f7560"
        let ruleColor = isDark ? "#3a3b36" : "#d9d8d0"
        let scheme = isDark ? "dark" : "light"
        let lazyBody = addingLazyImageAttributes(to: body)

        return """
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
          \(extraCSS)
        </head>
        <body>\(lazyBody)</body>
        </html>
        """
    }

    /// Images in long illustrated books and comics should not decode until
    /// they approach the viewport. `loading="lazy"` is a no-op on engines that
    /// do not understand it.
    static func addingLazyImageAttributes(to html: String) -> String {
        let pattern = #"<img\b[^>]*>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return html
        }
        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHTML.length)
        )
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            var tag = nsHTML.substring(with: match.range)
            let lower = tag.lowercased()
            var additions = ""
            if !lower.contains("loading=") {
                additions += " loading=\"lazy\""
            }
            if !lower.contains("decoding=") {
                additions += " decoding=\"async\""
            }
            guard !additions.isEmpty, tag.hasSuffix(">") else { continue }
            if tag.hasSuffix("/>") {
                tag = String(tag.dropLast(2)) + additions + "/>"
            } else {
                tag = String(tag.dropLast()) + additions + ">"
            }
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: tag
            )
        }
        return result
    }

    /// Renders a MOBI, AZW or AZW3 book with the built-in parser. No external
    /// converter is involved, so the app works on a Mac without Calibre.
    static func mobiHTML(from url: URL, fontSize: CGFloat, isDark: Bool) throws -> (htmlURL: URL, accessRoot: URL) {
        let book: MOBIBook
        do {
            book = try MOBIParser.parse(url: url)
        } catch MOBIParseError.encrypted {
            throw ReaderError.mobiDRMProtected
        } catch MOBIParseError.notMOBI {
            throw ReaderError.mobiInvalid
        } catch MOBIParseError.unsupportedCompression(let type) {
            throw ReaderError.mobiUnsupportedCompression(type)
        } catch {
            throw ReaderError.mobiInvalid
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-MOBI-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        if !book.images.isEmpty {
            let imagesDirectory = workspace.appendingPathComponent("Images", isDirectory: true)
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            for (name, data) in book.images {
                try? data.write(to: imagesDirectory.appendingPathComponent(name))
            }
        }

        let body = book.parts
            .map { MOBIParser.bodyContents(of: $0) }
            .joined(separator: "\n<hr class=\"chapter-break\">\n")
        let html = readerDocument(body: body, fontSize: fontSize, isDark: isDark)
        let htmlURL = workspace.appendingPathComponent("intel-reader.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, workspace)
    }

    static func fb2HTML(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        do {
            return try FB2Renderer.html(from: url, fontSize: fontSize, isDark: isDark)
        } catch {
            throw ReaderError.fb2Invalid
        }
    }

    static func cbzHTML(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        do {
            return try ComicRenderer.html(from: url, fontSize: fontSize, isDark: isDark)
        } catch {
            throw ReaderError.comicInvalid
        }
    }

    static func rtfHTML(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        do {
            return try RTFRenderer.html(from: url, fontSize: fontSize, isDark: isDark)
        } catch {
            throw ReaderError.rtfInvalid
        }
    }

    static func docxHTML(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        do {
            return try DOCXRenderer.html(from: url, fontSize: fontSize, isDark: isDark)
        } catch {
            throw ReaderError.docxInvalid
        }
    }

    // MARK: - Rendered-book cache

    /// Opening a book used to unzip its EPUB or convert a MOBI/AZW/AZW3 file
    /// for every open. The finished reader HTML is kept in Application Support
    /// and reused until the source file changes, so only the first open is
    /// slow. The entry is keyed by path, size and modification date, which is
    /// enough to notice updated or replaced book files without hashing the
    /// whole book on every click.
    /// Version 3 rebuilds EPUB caches created by 0.5.0, whose merged chapters
    /// kept `../images/...` URLs and therefore showed no illustrations.
    private static let contentCacheVersion = "5"
    private static let contentCacheLock = NSLock()
    private static let contentCacheLimit = 40

    private static var contentCacheRoot: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntelReader/BookCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Returns the previously rendered reader page for this exact file
    /// version, or nil when the book was never opened or has changed since.
    static func cachedReaderHTML(for url: URL) -> (htmlURL: URL, accessRoot: URL)? {
        let directory = readerCacheDirectory(for: url)
        let fileManager = FileManager.default
        for name in ["intel-reader.html", "intel-reader-text.html"] {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return (candidate, directory)
            }
        }
        return nil
    }

    /// Moves a freshly rendered page into the persistent cache and returns
    /// its new location. When the move fails the caller still gets the
    /// temporary result, so the book opens either way.
    @discardableResult
    static func storeReaderHTML(
        _ result: (htmlURL: URL, accessRoot: URL),
        for url: URL
    ) -> (htmlURL: URL, accessRoot: URL) {
        contentCacheLock.lock()
        defer { contentCacheLock.unlock() }

        let fileManager = FileManager.default
        let source = url.standardizedFileURL
        let directory = readerCacheDirectory(for: source)
        let htmlName = result.htmlURL.lastPathComponent
        let cachedHTML = directory.appendingPathComponent(htmlName)

        if fileManager.fileExists(atPath: cachedHTML.path) {
            // Another open won the race; reuse its entry.
            try? fileManager.removeItem(at: result.accessRoot)
            return (cachedHTML, directory)
        }

        do {
            try fileManager.createDirectory(at: contentCacheRoot, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: directory)
            try fileManager.moveItem(at: result.accessRoot, to: directory)
            try? source.path.write(
                to: directory.appendingPathComponent("source-path.txt"),
                atomically: true,
                encoding: .utf8
            )
            pruneReaderCaches(keeping: directory, sourcePath: source.path)
            return (directory.appendingPathComponent(htmlName), directory)
        } catch {
            return result
        }
    }

    private static func readerCacheDirectory(for url: URL) -> URL {
        let source = url.standardizedFileURL
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        // Publisher styles produce different HTML, so keep a separate cache
        // entry. Plain mode deliberately keeps the old identity so existing
        // caches from 0.6.0 remain valid.
        let styleMode = UserDefaults.standard.bool(forKey: "ReaderPublisherStyles") ? "|pub" : ""
        let identity = "\(contentCacheVersion)|\(source.path)|\(size)|\(modified)\(styleMode)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return contentCacheRoot.appendingPathComponent(String(digest.prefix(40)), isDirectory: true)
    }

    /// Drops older renderings of the same book and trims the whole cache to a
    /// sensible number of entries. Must be called with the lock held.
    private static func pruneReaderCaches(keeping directory: URL, sourcePath: String) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: contentCacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var kept: [(url: URL, modified: Date)] = []
        for entry in entries {
            if entry.standardizedFileURL == directory.standardizedFileURL {
                kept.append((entry, Date()))
                continue
            }
            let marker = entry.appendingPathComponent("source-path.txt")
            if let existing = try? String(contentsOf: marker, encoding: .utf8),
               existing.trimmingCharacters(in: .whitespacesAndNewlines) == sourcePath {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            kept.append((entry, modified))
        }

        guard kept.count > contentCacheLimit else { return }
        for entry in kept.sorted(by: { $0.modified < $1.modified }).prefix(kept.count - contentCacheLimit) {
            if entry.url.standardizedFileURL != directory.standardizedFileURL {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }

    static func plainTextHTML(title: String, text: String, fontSize: CGFloat, isDark: Bool) throws -> (htmlURL: URL, accessRoot: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntelReader-TXT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let escapedTitle = escapeHTML(title)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // A whole novel in one text node makes WebKit's multi-column layout
        // pathological (12 s for a 1 MB TXT). Split at blank lines so the
        // pager lays out many ordinary paragraphs instead.
        var blocks: [String] = []
        var currentLines: [String] = []
        let flushBlock = {
            guard !currentLines.isEmpty else { return }
            blocks.append("<p>" + currentLines.joined(separator: "<br>") + "</p>")
            currentLines.removeAll()
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushBlock()
            } else {
                currentLines.append(escapeHTML(line))
            }
        }
        flushBlock()
        let bodyHTML = blocks.joined(separator: "\n")
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
              white-space: normal;
              overflow-wrap: break-word;
              word-break: break-word;
            }
            .title {
              font-size: 15px;
              opacity: 0.7;
              margin-bottom: 24px;
            }
            p {
              margin: 0 0 1.1em;
              white-space: pre-wrap;
            }
          </style>
        </head>
        <body>
          <main class="page txt">
            <div class="title">\(escapedTitle)</div>
            <article>\(bodyHTML)</article>
          </main>
        </body>
        </html>
        """

        let htmlURL = root.appendingPathComponent("intel-reader-text.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, root)
    }

    static func markdownHTML(
        title: String,
        text: String,
        fontSize: CGFloat,
        isDark: Bool,
        sourceURL: URL
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntelReader-MD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let body = MarkdownRenderer.bodyHTML(from: text, sourceURL: sourceURL)
        let escapedTitle = escapeHTML(title)
        let background = isDark ? "#1b1c1a" : "#f6f5f0"
        let foreground = isDark ? "#e7e4dc" : "#2c302d"
        let muted = isDark ? "#9b9b92" : "#70756f"
        let link = isDark ? "#9cc7b0" : "#3f7560"
        let rule = isDark ? "#3a3b36" : "#d9d8d0"
        let codeBackground = isDark ? "rgba(255,255,255,0.075)" : "rgba(35,40,35,0.055)"
        let quoteBackground = isDark ? "rgba(255,255,255,0.035)" : "rgba(35,40,35,0.03)"
        let scheme = isDark ? "dark" : "light"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          <style>
            :root {
              color-scheme: \(scheme);
              --reader-link: \(link);
              --reader-muted: \(muted);
              --reader-rule: \(rule);
              --reader-code-bg: \(codeBackground);
              --reader-quote-bg: \(quoteBackground);
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; padding: 0; }
            body {
              background: \(background);
              color: \(foreground);
              font-family: Georgia, "Songti SC", "STSong", "Times New Roman", serif;
              font-size: \(Int(fontSize))px;
              line-height: 1.85;
            }
            .page {
              max-width: 760px;
              margin: 0 auto;
              padding: 44px 44px 96px;
              overflow-wrap: break-word;
              word-break: break-word;
            }
            .page > :first-child { margin-top: 0; }
            p { margin: 0 0 1.05em; }
            h1, h2, h3, h4, h5, h6 {
              font-weight: 700;
              line-height: 1.35;
              margin: 1.7em 0 0.65em;
            }
            h1 {
              font-size: 1.9em;
              padding-bottom: 0.25em;
              border-bottom: 1px solid var(--reader-rule);
            }
            h2 { font-size: 1.5em; }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1.1em; }
            h5, h6 { font-size: 1em; color: var(--reader-muted); }
            a { color: var(--reader-link); text-decoration: none; }
            a:hover { text-decoration: underline; }
            del { color: var(--reader-muted); }
            code {
              font-family: "SF Mono", Menlo, "PingFang SC", monospace;
              font-size: 0.88em;
              background: var(--reader-code-bg);
              border-radius: 4px;
              padding: 0.12em 0.32em;
            }
            pre {
              background: var(--reader-code-bg);
              border: 1px solid var(--reader-rule);
              border-radius: 6px;
              padding: 14px 16px;
              margin: 0 0 1.2em;
              overflow-x: auto;
              line-height: 1.6;
            }
            pre code {
              background: none;
              padding: 0;
              border-radius: 0;
              font-size: 0.86em;
              white-space: pre;
            }
            blockquote {
              margin: 0 0 1.2em;
              padding: 0.2em 1em;
              border-left: 3px solid var(--reader-rule);
              background: var(--reader-quote-bg);
              color: var(--reader-muted);
            }
            blockquote > :last-child { margin-bottom: 0; }
            ul, ol { margin: 0 0 1.05em; padding-left: 1.7em; }
            li { margin: 0.25em 0; }
            li > ul, li > ol { margin-top: 0.3em; margin-bottom: 0.3em; }
            li p { margin-bottom: 0.5em; }
            .task-list { list-style: none; padding-left: 1.2em; }
            .task-list-item { list-style: none; }
            .task-list-item input { margin-right: 0.45em; vertical-align: -0.05em; }
            hr { border: 0; border-top: 1px solid var(--reader-rule); margin: 2em 0; }
            .table-wrap { overflow-x: auto; margin: 0 0 1.2em; }
            table { border-collapse: collapse; width: 100%; font-size: 0.94em; }
            th, td { border: 1px solid var(--reader-rule); padding: 7px 10px; vertical-align: top; }
            th { text-align: left; font-weight: 700; background: var(--reader-code-bg); }
            img {
              display: block;
              max-width: 100%;
              height: auto;
              margin: 1.1em auto;
              border-radius: 4px;
            }
            .missing-image { color: var(--reader-muted); font-style: italic; }
          </style>
        </head>
        <body>
          <main class="page">\(body)</main>
        </body>
        </html>
        """

        let htmlURL = root.appendingPathComponent("intel-reader.html")
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
        let contents = String(source[startEnd.upperBound..<endTag.lowerBound])
        // EPUB NCX/nav files often point at `file.html#body-id` instead of an
        // element inside the body (Calibre writes body ids this way). The
        // reader only keeps the body's inner HTML, so preserve that id as an
        // empty anchor or those table-of-contents entries cannot jump.
        let startTagText = String(source[startTag.lowerBound..<startEnd.upperBound])
        if let idRange = startTagText.range(
            of: #"(?i)\bid\s*=\s*("([^"]*)"|'([^']*)')"#,
            options: .regularExpression
        ) {
            var value = String(startTagText[idRange])
            if let equals = value.firstIndex(of: "=") {
                value = String(value[value.index(after: equals)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty {
                let escaped = value
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<a id=\"\(escaped)\"></a>" + contents
            }
        }
        return contents
    }
}

final class CloudFolderSync {
    static let shared = CloudFolderSync()

    private(set) var folderURL: URL
    private let fileManager = FileManager.default

    private init() {
        let defaultURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/极简阅读", isDirectory: true)
        if let savedURL = UserDefaults.standard.url(forKey: "CloudFolderURL") {
            folderURL = savedURL
        } else if let savedPath = UserDefaults.standard.string(forKey: "CloudFolderURL"), !savedPath.isEmpty {
            let expanded = (savedPath as NSString).expandingTildeInPath
            folderURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            folderURL = Self.discoverFolder(fallback: defaultURL)
        }
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
        let standardized = url.standardizedFileURL
        folderURL = standardized
        // 保存为普通路径字符串，重启后仍能准确回到上次选择的文件夹。
        UserDefaults.standard.set(standardized.path, forKey: "CloudFolderURL")
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
        guard isAvailable else { return [] }
        return FolderBookScanner.bookURLs(in: folderURL)
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

    /// Copies an imported book into the selected library folder. This keeps
    /// the folder self-contained so a later Scan can find the book again.
    func copy(_ url: URL, into folder: URL) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL != url.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                return destination
            }
            try fileManager.copyItem(at: url, to: destination)
        }
        return destination
    }

    /// True for folders inside iCloud Drive, regardless of which subfolder was
    /// chosen. Used to decide whether an imported book should be copied into
    /// the library folder so the phone can see it too.
    static func isICloudDriveFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/")
            || path.contains("/Library/CloudStorage/iCloud Drive/")
            || path.contains("/Library/CloudStorage/iCloud 云盘/")
    }
}

enum FolderBookScanner {
    static let supportedExtensions = Set([
        "txt", "epub", "pdf", "mobi", "azw", "azw3", "md", "markdown",
        "fb2", "cbz", "rtf", "docx"
    ])

    static func bookURLs(in folderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
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
}

/// The folder shelf reads one plain folder on this Mac. iCloud Drive folders
/// (including the original “极简阅读” folder) are just folders too, so the
/// app no longer keeps a second folder library for them.
final class FolderLibraryStore {
    static let shared = FolderLibraryStore()

    private let defaults = UserDefaults.standard
    private let folderKey = "LibraryFolderPath"
    private let legacyLocalFolderKey = "LocalLibraryFolderPath"
    private let legacyActiveLibraryKey = "ActiveLibrarySource"
    private let fileManager = FileManager.default

    private init() {
        guard defaults.string(forKey: folderKey)?.isEmpty != false else { return }
        // One-time migration: keep the folder the user was actually reading
        // from in the old three-library layout.
        let legacyActive = defaults.string(forKey: legacyActiveLibraryKey) ?? ""
        let legacyLocal = defaults.string(forKey: legacyLocalFolderKey) ?? ""
        if legacyActive == BookSource.local.rawValue, !legacyLocal.isEmpty {
            defaults.set(legacyLocal, forKey: folderKey)
        } else {
            defaults.set(CloudFolderSync.shared.folderURL.path, forKey: folderKey)
        }
    }

    var folderURL: URL {
        let path = defaults.string(forKey: folderKey) ?? CloudFolderSync.shared.folderURL.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var folderName: String {
        folderURL.lastPathComponent
    }

    var displayPath: String {
        folderURL.path.replacingOccurrences(
            of: fileManager.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func setFolder(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: folderKey)
    }

    func contains(_ url: URL) -> Bool {
        let folderPath = folderURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return itemPath == folderPath || itemPath.hasPrefix(folderPath + "/")
    }

    func bookURLs() -> [URL] {
        guard isAvailable else { return [] }
        return FolderBookScanner.bookURLs(in: folderURL)
    }
}

// MARK: - 极简阅读 / ZenReader progress sync

enum ZenReaderSyncError: LocalizedError {
    case invalidServer
    case insecureServer
    case missingCredentials
    case keychainReentryRequired
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case http(Int)
    case network(String)
    case invalidSnapshot
    case snapshotMissing
    case keychain

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return L("WebDAV 服务器地址无效。请填写账号根目录，例如 https://dav.jianguoyun.com/dav/。",
                     "The WebDAV server address is invalid. Enter the account root, such as https://dav.jianguoyun.com/dav/.")
        case .insecureServer:
            return L("为了保护密码，只允许使用 https:// 地址（本机测试可用 localhost）。",
                     "For password safety, only https:// addresses are allowed (localhost is allowed for testing).")
        case .missingCredentials:
            return L("请先填写 WebDAV 账号和密码。", "Enter your WebDAV account and password first.")
        case .keychainReentryRequired:
            return L("这个版本需要再输入一次 WebDAV 密码（最后一次）。保存后会使用稳定的钥匙串标识，以后修改或重建 EasyRead 都不再需要重新输入。",
                     "This build needs your WebDAV password one last time. After saving, the keychain identity stays stable and later EasyRead rebuilds no longer ask for it.")
        case .unauthorized:
            return L("服务器拒绝登录。请确认账号和密码正确；部分服务商需要使用单独生成的「应用密码」而不是网页登录密码。",
                     "The server rejected the sign-in. Check the account and password; some providers require a generated app password instead of your website password.")
        case .forbidden:
            return L("这个账号没有访问该同步目录的权限。", "This account cannot access the sync folder.")
        case .notFound:
            return L("服务器上没有找到 WebDAV 同步文件夹，或当前账号无权访问。",
                     "The WebDAV sync folder was not found, or this account cannot access it.")
        case .conflict:
            return L("创建同步快照时发生冲突，请稍后重试。", "A conflict occurred while creating the snapshot. Try again shortly.")
        case .http(let code):
            return L("WebDAV 服务器返回了 HTTP \(code)。", "The WebDAV server returned HTTP \(code).")
        case .network(let detail):
            return L("无法连接 WebDAV 服务器：\(detail)", "Could not reach the WebDAV server: \(detail)")
        case .invalidSnapshot:
            return L("服务器上的进度快照格式无法识别。为避免覆盖数据，本次同步已停止。",
                     "The progress snapshot on the server has an unknown format. Sync stopped to avoid overwriting data.")
        case .snapshotMissing:
            return L("服务器上没有找到可读的 readerzen.json 快照。",
                     "No readable readerzen.json snapshot was found on the server.")
        case .keychain:
            return L("无法把应用密码保存到系统钥匙串。", "The app password could not be saved to the macOS Keychain.")
        }
    }
}

enum KeychainStore {
    private static let interactionLock = NSLock()

    /// Reads the password with optional keychain UI disabled. It never shows a
    /// system authorization dialog: if this build is not trusted by the item,
    /// the lookup simply fails and the caller asks the user to type the
    /// password again in EasyRead's own settings window.
    static func readSilently(service: String, account: String) -> String? {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        return withoutInteraction {
            readWithoutInteractionLock(service: service, account: account)
        }
    }

    private static func readWithoutInteractionLock(service: String, account: String) -> String? {
        var passwordLength: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?
        let status = service.withCString { servicePointer in
            account.withCString { accountPointer in
                SecKeychainFindGenericPassword(
                    nil,
                    UInt32(service.utf8.count), servicePointer,
                    UInt32(account.utf8.count), accountPointer,
                    &passwordLength, &passwordData, nil
                )
            }
        }
        guard status == errSecSuccess, let passwordData else { return nil }
        defer { SecKeychainItemFreeContent(nil, passwordData) }
        let data = Data(bytes: passwordData, count: Int(passwordLength))
        return String(data: data, encoding: .utf8)
    }

    /// Saves the dedicated Jianguoyun password and verifies that the stored
    /// item really has an open ACL. The build is unsigned, so the item's
    /// keychain partition is the stable "unsigned:" value; an accidentally
    /// signed build would pin it to a cdhash that changes on the next rebuild.
    /// This check makes such a failure visible instead of silently degrading
    /// on the next launch.
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        return withoutInteraction {
            saveWithoutInteractionLock(value, service: service, account: account)
        }
    }

    private static func saveWithoutInteractionLock(_ value: String, service: String, account: String) -> Bool {
        guard let access = makeOpenAccess(descriptor: "EasyRead · WebDAV 密码") else {
            return false
        }

        let createStatus = createItem(value, service: service, account: account, access: access)
        if createStatus == errSecSuccess {
            return readWithoutInteractionLock(service: service, account: account) == value
        }
        guard createStatus == errSecDuplicateItem,
              let item = itemReference(service: service, account: account),
              ensureOpenAccess(item: item, access: access) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]
        guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
            return false
        }
        return readWithoutInteractionLock(service: service, account: account) == value
    }

    /// Creates the item through the legacy Keychain API so the supplied
    /// `SecAccess` is honoured. `SecItemAdd` silently ignored the access
    /// object on macOS 13, leaving an item that only its creator build could
    /// read after ad-hoc re-signing.
    private static func createItem(
        _ value: String,
        service: String,
        account: String,
        access: SecAccess
    ) -> OSStatus {
        var item: SecKeychainItem?
        let status = service.withCString { servicePointer in
            account.withCString { accountPointer in
                value.withCString { passwordPointer in
                    var attributes = [
                        SecKeychainAttribute(
                            tag: 0x73766365, // 'svce'
                            length: UInt32(service.utf8.count),
                            data: UnsafeMutableRawPointer(mutating: servicePointer)
                        ),
                        SecKeychainAttribute(
                            tag: 0x61636374, // 'acct'
                            length: UInt32(account.utf8.count),
                            data: UnsafeMutableRawPointer(mutating: accountPointer)
                        )
                    ]
                    var attributeList = SecKeychainAttributeList(
                        count: UInt32(attributes.count),
                        attr: &attributes
                    )
                    return SecKeychainItemCreateFromContent(
                        SecItemClass(rawValue: 0x67656e70)!, // 'genp'
                        &attributeList,
                        UInt32(value.utf8.count),
                        passwordPointer,
                        nil,
                        access,
                        &item
                    )
                }
            }
        }
        guard status == errSecSuccess, let item else { return status }
        guard ensureOpenAccess(item: item, access: access) else {
            // Never leave an item behind that would prompt on a later rebuild.
            SecKeychainItemDelete(item)
            return errSecAuthFailed
        }
        return status
    }

    private static func itemReference(service: String, account: String) -> SecKeychainItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result else {
            return nil
        }
        return unsafeBitCast(result, to: SecKeychainItem.self)
    }

    private static func ensureOpenAccess(item: SecKeychainItem, access: SecAccess) -> Bool {
        if itemHasOpenAccess(item) { return true }
        guard SecKeychainItemSetAccess(item, access) == errSecSuccess else { return false }
        return itemHasOpenAccess(item)
    }

    private static func itemHasOpenAccess(_ item: SecKeychainItem) -> Bool {
        var storedAccess: SecAccess?
        guard SecKeychainItemCopyAccess(item, &storedAccess) == errSecSuccess,
              let storedAccess else {
            return false
        }
        return accessIsOpen(storedAccess)
    }

    private static func accessIsOpen(_ access: SecAccess) -> Bool {
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let aclList,
              CFArrayGetCount(aclList) > 0 else {
            return false
        }
        for index in 0..<CFArrayGetCount(aclList) {
            let acl = unsafeBitCast(CFArrayGetValueAtIndex(aclList, index), to: SecACL.self)
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else {
                return false
            }
            if let applications, CFArrayGetCount(applications) > 0 { return false }
            if prompt.contains(.requirePassphase) { return false }
        }
        return true
    }

    private static func withoutInteraction<T>(_ body: () -> T) -> T {
        var previousState = DarwinBoolean(false)
        let hadPreviousState = SecKeychainGetUserInteractionAllowed(&previousState) == errSecSuccess
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            SecKeychainSetUserInteractionAllowed(hadPreviousState ? previousState.boolValue : true)
        }
        return body()
    }

    static func delete(service: String, account: String) {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        withoutInteraction {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Builds a SecAccess whose simple ACLs have no trusted-application list,
    /// which is exactly what Keychain Access calls "allow all applications to
    /// access this item". It is used only for the dedicated Jianguoyun app
    /// password so future EasyRead builds can read it without a dialog.
    private static func makeOpenAccess(descriptor: String) -> SecAccess? {
        var access: SecAccess?
        let name = descriptor as CFString
        guard SecAccessCreate(name, nil, &access) == errSecSuccess, let access else {
            return nil
        }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess, let aclList else {
            return access
        }
        for index in 0..<CFArrayGetCount(aclList) {
            let acl = unsafeBitCast(CFArrayGetValueAtIndex(aclList, index), to: SecACL.self)
            var applicationList: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applicationList, &description, &promptSelector) == errSecSuccess else {
                continue
            }
            promptSelector = SecKeychainPromptSelector(
                rawValue: promptSelector.rawValue & ~SecKeychainPromptSelector.requirePassphase.rawValue
            )
            _ = SecACLSetContents(acl, nil, description ?? name, promptSelector)
        }
        return access
    }
}

final class WebDAVHrefParser: NSObject, XMLParserDelegate {
    private(set) var hrefs: [String] = []
    private var currentText = ""
    private var isInsideHref = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local.lowercased() == "href" {
            isInsideHref = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideHref { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard local.lowercased() == "href" else { return }
        isInsideHref = false
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { hrefs.append(value) }
    }
}

/// Where inside the WebDAV account the sync data lives. EasyRead keeps its own
/// folder so it never assumes a ZenReader installation; the compatibility
/// folder is only used when the user explicitly wants to share data with
/// ZenReader on the phone.
enum ZenRemoteLayout: String, CaseIterable {
    case easyread
    case zenreader

    var folderPath: String {
        switch self {
        case .easyread: return "EasyRead"
        case .zenreader: return "ZenReader/v1"
        }
    }

    var shortTitle: String {
        switch self {
        case .easyread: return L("EasyRead（默认）", "EasyRead (Default)")
        case .zenreader: return L("ZenReader（兼容）", "ZenReader (Compatible)")
        }
    }

    var hint: String {
        switch self {
        case .easyread:
            return L(
                "在云端使用独立的 EasyRead 文件夹，不存在时首次同步会自动创建。切换只影响之后的同步，不会移动或删除另一个文件夹里的文件。",
                "Uses a separate EasyRead folder in the cloud and creates it automatically on the first sync. Switching only affects later syncs; files in the other folder are never moved or deleted."
            )
        case .zenreader:
            return L(
                "使用 ZenReader/v1 文件夹，与 iPhone 上的极简阅读同步书籍和进度。切换只影响之后的同步，不会移动或删除 EasyRead 文件夹里的文件。",
                "Uses the ZenReader/v1 folder to share books and positions with ZenReader on iPhone. Switching only affects later syncs; files in the EasyRead folder are never moved or deleted."
            )
        }
    }
}

/// The provider choice only supplies a server template, help text and password
/// guidance. Any standards-compliant WebDAV server can be used through the
/// custom option; sync itself always talks plain WebDAV.
enum ZenWebDAVProvider: String, CaseIterable {
    case jianguoyun
    case nextcloud
    case infinicloud
    case synology
    case custom

    var title: String {
        switch self {
        case .jianguoyun: return L("坚果云", "Jianguoyun")
        case .nextcloud: return "Nextcloud"
        case .infinicloud: return "InfiniCLOUD"
        case .synology: return L("群晖 Synology", "Synology")
        case .custom: return L("自定义 WebDAV", "Custom WebDAV")
        }
    }

    var serverPlaceholder: String {
        switch self {
        case .jianguoyun: return "https://dav.jianguoyun.com/dav/"
        case .nextcloud: return "https://cloud.example.com/remote.php/dav/files/yourname/"
        case .infinicloud: return "https://yourname.teracloud.jp/dav/"
        case .synology: return "https://nas.example.com:5006/"
        case .custom: return "https://dav.example.com/"
        }
    }

    var serverHint: String {
        switch self {
        case .jianguoyun:
            return L(
                "只填账号根目录 https://dav.jianguoyun.com/dav/；EasyRead 或 ZenReader/v1 会自动加在末尾。",
                "Enter only the account root https://dav.jianguoyun.com/dav/; EasyRead or ZenReader/v1 is appended automatically."
            )
        case .nextcloud:
            return L(
                "填 Nextcloud 的 WebDAV 根地址，通常包含 /remote.php/dav/files/用户名/；不要手动追加 EasyRead 或 ZenReader/v1。",
                "Enter the Nextcloud WebDAV root, usually /remote.php/dav/files/yourname/; do not append EasyRead or ZenReader/v1 yourself."
            )
        case .infinicloud:
            return L(
                "填 InfiniCLOUD 的 WebDAV 根地址 https://用户名.teracloud.jp/dav/；不要手动追加 EasyRead 或 ZenReader/v1。",
                "Enter the InfiniCLOUD WebDAV root https://yourname.teracloud.jp/dav/; do not append EasyRead or ZenReader/v1 yourself."
            )
        case .synology:
            return L(
                "填群晖 WebDAV 的根地址（例如 https://主机:5006/）；EasyRead 或 ZenReader/v1 会自动加在末尾。",
                "Enter the Synology WebDAV root (for example https://host:5006/); EasyRead or ZenReader/v1 is appended automatically."
            )
        case .custom:
            return L(
                "填服务商提供的 WebDAV 账号根地址；EasyRead 或 ZenReader/v1 会自动加在末尾，不要手动追加。",
                "Enter the WebDAV account root from your provider; EasyRead or ZenReader/v1 is appended automatically."
            )
        }
    }

    var passwordHint: String {
        switch self {
        case .jianguoyun:
            return L(
                "请在坚果云「账户信息 → 安全选项」中生成「第三方应用密码」，不要使用登录密码。",
                "Create an app password under Jianguoyun → Account Info → Security; do not use your login password."
            )
        case .nextcloud:
            return L(
                "请在 Nextcloud「设置 → 安全 → 应用密码」中生成应用密码，不要使用登录密码。",
                "Create an app password under Nextcloud → Settings → Security; do not use your login password."
            )
        case .infinicloud:
            return L(
                "请使用 InfiniCLOUD 账户设置里显示的 WebDAV 连接密码。",
                "Use the WebDAV connection password shown in your InfiniCLOUD account settings."
            )
        case .synology:
            return L(
                "请使用群晖账号密码；若开启了双重验证，请先在 DSM 中创建应用专用密码。",
                "Use your Synology account password; if two-factor authentication is enabled, create an app-specific password in DSM first."
            )
        case .custom:
            return L(
                "请填写服务商提供的 WebDAV 密码或应用密码。",
                "Enter the WebDAV or app password provided by your service."
            )
        }
    }

    static func inferred(from server: String) -> ZenWebDAVProvider {
        let lower = server.lowercased()
        if lower.contains("jianguoyun.com") { return .jianguoyun }
        if lower.contains("teracloud.jp") || lower.contains("infini.cloud") { return .infinicloud }
        if lower.contains("/remote.php/dav") || lower.contains("nextcloud") { return .nextcloud }
        if lower.contains("synology") || lower.contains(":5005") || lower.contains(":5006") {
            return .synology
        }
        if lower.contains("dav.jianguoyun") { return .jianguoyun }
        return .custom
    }
}

final class ZenReaderWebDAVClient {
    private let serverRootURL: URL
    private let rootURL: URL
    private let rootPath: String
    private let remoteFolderComponents: [String]
    private let username: String
    private let password: String
    private let session: URLSession

    init(serverURL: String, username: String, password: String, remoteFolder: String) throws {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !password.isEmpty else {
            throw ZenReaderSyncError.missingCredentials
        }

        var server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { throw ZenReaderSyncError.invalidServer }
        while server.hasSuffix("/") { server.removeLast() }
        guard var components = URLComponents(string: server),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            throw ZenReaderSyncError.invalidServer
        }
        let localHost = host.lowercased()
        if scheme == "http", localHost != "127.0.0.1", localHost != "localhost", localHost != "::1" {
            throw ZenReaderSyncError.insecureServer
        }

        var folder = remoteFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        while folder.hasPrefix("/") { folder.removeFirst() }
        while folder.hasSuffix("/") { folder.removeLast() }
        let folderComponents = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard !folderComponents.isEmpty,
              folderComponents.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              }) else {
            throw ZenReaderSyncError.invalidServer
        }

        let serverComponents = components
        guard let serverRoot = serverComponents.url else { throw ZenReaderSyncError.invalidServer }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        path += "/" + folder
        path += "/"
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let root = components.url else { throw ZenReaderSyncError.invalidServer }

        self.serverRootURL = serverRoot
        self.rootURL = root
        self.rootPath = path
        self.remoteFolderComponents = folderComponents.map(String.init)
        self.username = trimmedUser
        self.password = password

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        configuration.httpAdditionalHeaders = ["User-Agent": "EasyRead/0.4"]
        self.session = URLSession(configuration: configuration)
    }

    private func url(relativePath: String) -> URL {
        url(base: rootURL, relativePath: relativePath)
    }

    private func url(base: URL, relativePath: String) -> URL {
        var baseString = base.absoluteString
        if !baseString.hasSuffix("/") { baseString += "/" }
        return URL(string: baseString + relativePath) ?? base
    }

    private func request(relativePath: String, method: String) -> URLRequest {
        request(base: rootURL, relativePath: relativePath, method: method)
    }

    private func request(base: URL, relativePath: String, method: String) -> URLRequest {
        var request = URLRequest(url: url(base: base, relativePath: relativePath))
        request.httpMethod = method
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest, timeout: TimeInterval = 45) throws -> (Data, HTTPURLResponse) {
        do {
            return try performOnce(request, timeout: timeout)
        } catch {
            guard Self.isConnectionLoss(error) else { throw Self.networkError(error) }
            // Pooled keep-alive sockets are sometimes closed by the server
            // without a notice. One retry opens a fresh connection.
            do {
                return try performOnce(request, timeout: timeout)
            } catch {
                throw Self.networkError(error)
            }
        }
    }

    private func performOnce(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData = Data()
        var resultResponse: HTTPURLResponse?
        var resultError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            resultData = data ?? Data()
            resultResponse = response as? HTTPURLResponse
            resultError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw ZenReaderSyncError.network(L("请求超时", "The request timed out"))
        }
        if let resultError { throw resultError }
        guard let resultResponse else {
            throw ZenReaderSyncError.network(L("服务器没有返回有效响应", "The server returned no usable response"))
        }
        return (resultData, resultResponse)
    }

    private static func isConnectionLoss(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNetworkConnectionLost {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSURLErrorDomain
                && underlying.code == NSURLErrorNetworkConnectionLost
        }
        return false
    }

    private static func networkError(_ error: Error) -> Error {
        if error is ZenReaderSyncError { return error }
        return ZenReaderSyncError.network(error.localizedDescription)
    }

    private func validate(_ response: HTTPURLResponse, allowed: Set<Int>) throws {
        if allowed.contains(response.statusCode) { return }
        switch response.statusCode {
        case 401: throw ZenReaderSyncError.unauthorized
        case 403: throw ZenReaderSyncError.forbidden
        case 404: throw ZenReaderSyncError.notFound
        case 409: throw ZenReaderSyncError.conflict
        default: throw ZenReaderSyncError.http(response.statusCode)
        }
    }

    func snapshotNames() throws -> [String] {
        var request = request(relativePath: "snapshots/", method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>
        """.utf8)
        let (data, response) = try perform(request)
        if response.statusCode == 404 { return [] }
        try validate(response, allowed: [200, 207])

        let hrefParser = WebDAVHrefParser()
        let parser = XMLParser(data: data)
        parser.delegate = hrefParser
        guard parser.parse() else { throw ZenReaderSyncError.invalidSnapshot }

        let parent = rootPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/snapshots"
        var names: Set<String> = []
        for href in hrefParser.hrefs {
            let decoded = href.removingPercentEncoding ?? href
            let path: String
            if let url = URL(string: decoded) {
                path = url.path
            } else {
                path = decoded
            }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = trimmed.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let name = components[components.count - 1]
            let parentPath = components.dropLast().joined(separator: "/")
            guard parentPath == parent else { continue }
            guard name.range(of: #"^\d{8}-\d{6}-\d{3}$"#, options: .regularExpression) != nil else { continue }
            names.insert(name)
        }
        return Array(names)
    }

    func snapshotData(named name: String) throws -> Data {
        let request = request(relativePath: "snapshots/\(name)/readerzen.json", method: "GET")
        let (data, response) = try perform(request)
        try validate(response, allowed: [200])
        return data
    }

    /// The newest readable snapshot, or nil when this remote folder has never
    /// been synced. A folder whose snapshot names exist but none can be read
    /// is an error: treating it as empty would overwrite real progress with a
    /// brand-new snapshot.
    func latestSnapshotIfExists() throws -> (name: String, data: Data)? {
        let names = try snapshotNames().sorted(by: >)
        guard !names.isEmpty else { return nil }
        for name in names {
            do {
                let data = try snapshotData(named: name)
                return (name, data)
            } catch ZenReaderSyncError.notFound {
                continue
            }
        }
        throw ZenReaderSyncError.snapshotMissing
    }

    /// Lists file names inside a WebDAV folder such as `objects/books`.
    /// A missing folder is treated as empty so the first sync can create it.
    func fileNames(folder: String) throws -> [String] {
        try fileNamesIfExists(folder: folder) ?? []
    }

    /// Same listing, but nil means the collection itself does not exist yet.
    /// Callers use that to create it once instead of sending MKCOL on every
    /// sync just to be told it already exists.
    func fileNamesIfExists(folder: String) throws -> [String]? {
        var request = request(relativePath: "\(folder)/", method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>
        """.utf8)
        let (data, response) = try perform(request)
        if response.statusCode == 404 { return nil }
        try validate(response, allowed: [200, 207])

        let hrefParser = WebDAVHrefParser()
        let parser = XMLParser(data: data)
        parser.delegate = hrefParser
        guard parser.parse() else { throw ZenReaderSyncError.invalidSnapshot }

        let parent = rootPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + folder
        var names: Set<String> = []
        for href in hrefParser.hrefs {
            let decoded = href.removingPercentEncoding ?? href
            let path: String
            if let url = URL(string: decoded) {
                path = url.path
            } else {
                path = decoded
            }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = trimmed.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let name = components[components.count - 1]
            let parentPath = components.dropLast().joined(separator: "/")
            guard parentPath == parent else { continue }
            names.insert(name)
        }
        return Array(names)
    }

    func objectData(folder: String, name: String) throws -> Data {
        try objectData(relativePath: "\(folder)/\(name)")
    }

    func downloadObject(folder: String, name: String, to destination: URL) throws {
        try downloadObject(relativePath: "\(folder)/\(name)", to: destination)
    }

    /// Downloads an object through a path recorded in the snapshot, e.g.
    /// `objects/books/<sha256>.txt`. The iPhone app stores book files under
    /// content-addressed names, so this path is the reliable lookup.
    func objectData(relativePath: String) throws -> Data {
        let request = request(relativePath: relativePath, method: "GET")
        let (data, response) = try perform(request, timeout: 600)
        try validate(response, allowed: [200])
        return data
    }

    /// Downloads a book straight into a file. `dataTask` keeps the whole
    /// response in memory, which is wasteful for large PDFs and makes the
    /// network wait on copying. `downloadTask` streams to a temporary file and
    /// this method moves the finished bytes into the book cache.
    func downloadObject(relativePath: String, to destination: URL) throws {
        do {
            try downloadObjectOnce(relativePath: relativePath, to: destination)
        } catch {
            guard Self.isConnectionLoss(error) else { throw Self.networkError(error) }
            do {
                try downloadObjectOnce(relativePath: relativePath, to: destination)
            } catch {
                throw Self.networkError(error)
            }
        }
    }

    private func downloadObjectOnce(relativePath: String, to destination: URL) throws {
        let request = request(relativePath: relativePath, method: "GET")
        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        let task = session.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                resultError = error
                return
            }
            guard let response = response as? HTTPURLResponse else {
                resultError = ZenReaderSyncError.network(
                    L("服务器没有返回有效响应", "The server returned no usable response")
                )
                return
            }
            do {
                try self.validate(response, allowed: [200])
                guard let location else {
                    throw ZenReaderSyncError.network(
                        L("服务器没有返回文件内容", "The server returned no file content")
                    )
                }
                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: location, to: destination)
            } catch {
                resultError = error
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            task.cancel()
            throw ZenReaderSyncError.network(L("请求超时", "The request timed out"))
        }
        if let resultError { throw resultError }
    }

    /// Creates a collection and every missing parent. WebDAV MKCOL refuses to
    /// create a child when its parent does not exist (409), so a fresh
    /// `EasyRead` folder needs `EasyRead`, `EasyRead/objects`,
    /// `EasyRead/objects/books`, and so on to be created in order.
    func ensureCollection(_ relativePath: String) throws {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return }
        var current = ""
        for component in remoteFolderComponents + components {
            if !current.isEmpty { current += "/" }
            current += component
            let request = request(base: serverRootURL, relativePath: "\(current)/", method: "MKCOL")
            let (_, response) = try perform(request)
            if response.statusCode == 405 { continue }
            try validate(response, allowed: [200, 201, 204])
        }
    }

    func putObject(folder: String, name: String, data: Data) throws {
        var request = request(relativePath: "\(folder)/\(name)", method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try perform(request, timeout: 600)
        try validate(response, allowed: [200, 201, 204])
    }

    /// Uploads a book from its file on disk. `httpBody` would copy the whole
    /// book into memory first; an upload task reads it in chunks instead.
    func putObject(folder: String, name: String, fileURL: URL) throws {
        do {
            try putObjectOnce(folder: folder, name: name, fileURL: fileURL)
        } catch {
            guard Self.isConnectionLoss(error) else { throw Self.networkError(error) }
            // The object name is content-addressed, so resending the same
            // bytes after a dropped response is safe.
            do {
                try putObjectOnce(folder: folder, name: name, fileURL: fileURL)
            } catch {
                throw Self.networkError(error)
            }
        }
    }

    private func putObjectOnce(folder: String, name: String, fileURL: URL) throws {
        var request = request(relativePath: "\(folder)/\(name)", method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        let task = session.uploadTask(with: request, fromFile: fileURL) { _, response, error in
            defer { semaphore.signal() }
            if let error {
                resultError = error
                return
            }
            guard let response = response as? HTTPURLResponse else {
                resultError = ZenReaderSyncError.network(
                    L("服务器没有返回有效响应", "The server returned no usable response")
                )
                return
            }
            do {
                try self.validate(response, allowed: [200, 201, 204])
            } catch {
                resultError = error
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            task.cancel()
            throw ZenReaderSyncError.network(L("请求超时", "The request timed out"))
        }
        if let resultError { throw resultError }
    }

    func putObject(relativePath: String, data: Data, contentType: String) throws {
        var request = request(relativePath: relativePath, method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try perform(request, timeout: 600)
        try validate(response, allowed: [200, 201, 204])
    }

    /// Root manifest at `ZenReader/v1/manifest.json`. The phone writes it on
    /// every sync and points it at the newest snapshot.
    func rootManifest() throws -> [String: Any]? {
        let request = request(relativePath: "manifest.json", method: "GET")
        let (data, response) = try perform(request)
        if response.statusCode == 404 { return nil }
        try validate(response, allowed: [200])
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Creates a brand-new snapshot folder. Returns false when the folder already exists
    /// so the caller can pick another name instead of overwriting another device's snapshot.
    func createSnapshot(named name: String, data: Data) throws -> Bool {
        // A brand-new remote folder has neither the chosen root nor
        // `snapshots/`, so make both before asking for the snapshot folder.
        try ensureCollection("snapshots")
        let folderPath = "snapshots/\(name)/"
        let makeRequest = request(relativePath: folderPath, method: "MKCOL")
        let (_, makeResponse) = try perform(makeRequest)
        if makeResponse.statusCode == 405 {
            return false
        }
        try validate(makeResponse, allowed: [200, 201, 204])
        var putRequest = request(relativePath: "\(folderPath)readerzen.json", method: "PUT")
        putRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = data
        let (_, putResponse) = try perform(putRequest)
        try validate(putResponse, allowed: [200, 201, 204])
        return true
    }
}

struct ZenTextChapter {
    let text: NSString
    let start: Int
    let length: Int
}

struct ZenReaderTextModel {
    let chapters: [ZenTextChapter]
    let totalLength: Int
}

/// Building a text book's chapter table is expensive: EPUBs are unzipped and
/// parsed, and MOBI/AZW/AZW3 files are decoded by the built-in parser, which
/// can take a second for a long book. Sync needs the table on every launch to
/// translate the phone's chapter-weighted percentage, so the finished table is
/// kept on disk and reused until the source file changes. Without this cache
/// every sync paid the extraction cost again before touching the network,
/// which made uploads and downloads look slower than they were.
enum ZenTextModelStore {
    private static let version = "2"
    private static let limit = 24
    private static let lock = NSLock()

    private static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntelReader/TextModelCache", isDirectory: true)
    }

    /// Stable identity for the source file. The key changes when the book is
    /// replaced or edited, so a stale chapter table is never served.
    private static func identity(for url: URL) -> (key: String, size: Int64, modified: Int64)? {
        let source = url.standardizedFileURL
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize else { return nil }
        let modified = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let identity = "\(version)|\(source.path)|\(size)|\(modified)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (String(digest.prefix(40)), Int64(size), modified)
    }

    static func load(for url: URL) -> ZenReaderTextModel? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = identity(for: url) else { return nil }
        let directory = rootURL.appendingPathComponent(identity.key, isDirectory: true)
        let metaURL = directory.appendingPathComponent("chapters.json")
        let textURL = directory.appendingPathComponent("text.txt")
        guard let metaData = try? Data(contentsOf: metaURL, options: .mappedIfSafe),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
              (meta["version"] as? String) == version,
              let totalLength = (meta["totalLength"] as? NSNumber)?.intValue,
              let chapterValues = meta["chapters"] as? [[String: Any]],
              let textData = try? Data(contentsOf: textURL, options: .mappedIfSafe),
              let text = String(data: textData, encoding: .utf8) else {
            return nil
        }
        let nsText = text as NSString
        guard nsText.length == totalLength, !chapterValues.isEmpty else { return nil }
        var chapters: [ZenTextChapter] = []
        chapters.reserveCapacity(chapterValues.count)
        for value in chapterValues {
            guard let start = (value["start"] as? NSNumber)?.intValue,
                  let length = (value["length"] as? NSNumber)?.intValue,
                  start >= 0, length >= 0,
                  start + length <= nsText.length else {
                return nil
            }
            let slice = nsText.substring(with: NSRange(location: start, length: length)) as NSString
            chapters.append(ZenTextChapter(text: slice, start: start, length: length))
        }
        return ZenReaderTextModel(chapters: chapters, totalLength: totalLength)
    }

    static func store(_ model: ZenReaderTextModel, for url: URL) {
        guard model.totalLength > 0, !model.chapters.isEmpty,
              let identity = identity(for: url) else { return }
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        let directory = rootURL.appendingPathComponent(identity.key, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let textURL = directory.appendingPathComponent("text.txt")
            try? fileManager.removeItem(at: textURL)
            guard fileManager.createFile(atPath: textURL.path, contents: nil) else { return }
            let handle = try FileHandle(forWritingTo: textURL)
            do {
                for chapter in model.chapters {
                    let data = (chapter.text as String).data(using: .utf8) ?? Data()
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fileManager.removeItem(at: directory)
                return
            }
            // Write the metadata last: a half-written entry then simply looks
            // like a cache miss instead of serving truncated chapter data.
            let meta: [String: Any] = [
                "version": version,
                "totalLength": model.totalLength,
                "chapters": model.chapters.map { ["start": $0.start, "length": $0.length] }
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [])
            try metaData.write(
                to: directory.appendingPathComponent("chapters.json"),
                options: .atomic
            )
            prune(keeping: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Cached tables hold a whole book's text, so keep the cache bounded by
    /// entry count and drop the oldest tables first.
    private static func prune(keeping directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var ordered: [(url: URL, modified: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            ordered.append((entry, values?.contentModificationDate ?? .distantPast))
        }
        guard ordered.count > limit else { return }
        ordered.sort { $0.modified < $1.modified }
        for entry in ordered.prefix(ordered.count - limit) {
            if entry.url.standardizedFileURL != directory.standardizedFileURL {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }
}

struct ZenPositionPayload {
    let percent: Double
    let readPage: Int
    let readChapter: Int?
    let readText: String?
}

struct ZenProgressUpdate {
    let progress: Double
    let updatedAt: Date
    /// The phone's text anchor for this position, when the snapshot has one.
    var locatorText: String? = nil
    /// False for positions this Mac just uploaded. Those keep the local
    /// reading position untouched; only cloud positions move the reader.
    var fromCloud: Bool = true
}

struct ZenSyncResult {
    var remoteSnapshot = ""
    var totalRemoteBooks = 0
    var matched = 0
    var pulled = 0
    var pushed = 0
    var positionWarnings = 0
    var uploadedSnapshot: String?
    var downloadedBooks = 0
    var uploadedBooks = 0
    var transferSkipped = 0
    var transferFailures: [String] = []
    var importedBooks: [LibraryBook] = []
    /// ZenReader's raw `progress` percent for matched books. This keeps the
    /// shelf label in the same metric as the phone instead of the Mac's local
    /// character ratio.
    var zenProgressByBookID: [UUID: Double] = [:]
    /// Local shelf books that the latest cloud snapshot marks as removed.
    var removedBookIDs: [UUID] = []
    /// Non-fatal problem while refreshing `manifest.json` after a snapshot.
    var manifestWarning: String?
}

enum ZenSyncMode {
    /// Exchange positions in both directions, newest timestamp wins.
    case bidirectional
    /// Upload every matched local position, even when the cloud copy looks newer.
    case uploadLocal
    /// Apply every matched cloud position locally, even when the local copy looks newer.
    case downloadRemote
}

/// Book files always travel together with their reading position.
/// `.both` is the normal user-facing action: download missing cloud books,
/// exchange matched positions, and upload missing local books in one pass
/// that produces one new snapshot.
enum ZenBookTransfer {
    case none
    case download
    case upload
    case both

    var downloadsBooks: Bool {
        self == .download || self == .both
    }

    var uploadsBooks: Bool {
        self == .upload || self == .both
    }
}

struct ZenSyncPlan {
    var downloadCount = 0
    var downloadTitles: [String] = []
    var uploadCount = 0
    var uploadBytes: Int64 = 0
    var uploadTitles: [String] = []
    var matched = 0
    var transferSkipped = 0
}

enum ZenTextLocator {
    static func model(for book: LibraryBook) -> ZenReaderTextModel? {
        let url = URL(fileURLWithPath: book.path)
        switch book.format {
        case "TXT":
            return try? model(forTXTAt: url)
        case "EPUB":
            return try? model(forEPUBAt: url)
        case "MOBI", "AZW", "AZW3":
            return try? model(forMobiAt: url)
        default:
            return nil
        }
    }

    static func locate(progress: Double, model: ZenReaderTextModel) -> ZenPositionPayload? {
        guard model.totalLength > 0, !model.chapters.isEmpty else { return nil }
        let clamped = min(max(progress, 0), 1)
        let target = min(
            max(Int((clamped * Double(model.totalLength)).rounded()), 0),
            model.totalLength - 1
        )
        var chapterIndex = 0
        for (index, chapter) in model.chapters.enumerated() {
            if target >= chapter.start {
                chapterIndex = index
            } else {
                break
            }
        }
        let chapter = model.chapters[chapterIndex]
        let offsetInChapter = min(max(target - chapter.start, 0), max(chapter.length - 1, 0))
        let chapterLength = max(chapter.length, 1)
        let percent = (Double(chapterIndex) + Double(offsetInChapter) / Double(chapterLength))
            / Double(max(model.chapters.count, 1)) * 100
        return ZenPositionPayload(
            percent: min(max(percent, 0), 100),
            readPage: offsetInChapter,
            readChapter: chapterIndex,
            readText: snippet(from: chapter.text, offset: offsetInChapter)
        )
    }

    /// Finds a text anchor in the chapter table and returns the
    /// chapter-weighted position ZenReader understands. When a short sentence
    /// occurs more than once, the occurrence closest to the expected local
    /// fraction wins, so uploads keep the phone on the same passage.
    static func locate(readText: String, near progress: Double, model: ZenReaderTextModel) -> ZenPositionPayload? {
        let needle = readText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, model.totalLength > 0, !model.chapters.isEmpty else { return nil }
        let target = min(max(progress, 0), 1) * Double(model.totalLength)
        var bestChapter = 0
        var bestOffset = 0
        var bestDistance = Double.greatestFiniteMagnitude

        func consider(chapterIndex: Int, offset: Int) {
            let absolute = Double(model.chapters[chapterIndex].start + offset)
            let distance = abs(absolute - target)
            if distance < bestDistance {
                bestDistance = distance
                bestChapter = chapterIndex
                bestOffset = offset
            }
        }

        for (index, chapter) in model.chapters.enumerated() {
            let nsChapter = chapter.text as NSString
            guard nsChapter.length > 0 else { continue }
            var searchLocation = 0
            while searchLocation < nsChapter.length {
                let range = nsChapter.range(
                    of: needle,
                    options: [],
                    range: NSRange(location: searchLocation, length: nsChapter.length - searchLocation)
                )
                guard range.location != NSNotFound else { break }
                consider(chapterIndex: index, offset: range.location)
                searchLocation = range.location + max(range.length, 1)
            }
        }

        // Whitespace between words differs between the phone's chapter table,
        // this Mac's extracted text and the rendered HTML. Retry once with
        // every whitespace run collapsed to a single space.
        if bestDistance == .greatestFiniteMagnitude {
            let collapsedNeedle = collapseWhitespace(needle).text
            if !collapsedNeedle.isEmpty {
                for (index, chapter) in model.chapters.enumerated() {
                    let collapsed = collapseWhitespace(chapter.text as String)
                    let nsText = collapsed.text as NSString
                    guard nsText.length > 0 else { continue }
                    var searchLocation = 0
                    while searchLocation < nsText.length {
                        let range = nsText.range(
                            of: collapsedNeedle,
                            options: [],
                            range: NSRange(location: searchLocation, length: nsText.length - searchLocation)
                        )
                        guard range.location != NSNotFound else { break }
                        if range.location < collapsed.offsets.count {
                            consider(chapterIndex: index, offset: collapsed.offsets[range.location])
                        }
                        searchLocation = range.location + max(range.length, 1)
                    }
                }
            }
        }

        guard bestDistance != .greatestFiniteMagnitude else { return nil }
        let chapter = model.chapters[bestChapter]
        let chapterLength = max(chapter.length, 1)
        let percent = (Double(bestChapter) + Double(bestOffset) / Double(chapterLength))
            / Double(max(model.chapters.count, 1)) * 100
        return ZenPositionPayload(
            percent: min(max(percent, 0), 100),
            readPage: bestOffset,
            readChapter: bestChapter,
            readText: needle
        )
    }

    /// Collapses every whitespace run into one space and keeps a map from
    /// each resulting UTF-16 offset back to the original text offset.
    private static func collapseWhitespace(_ text: String) -> (text: String, offsets: [Int]) {
        var result = ""
        var offsets: [Int] = []
        var pendingSpace = false
        var utf16Offset = 0
        for character in text {
            let length = String(character).utf16.count
            if character.isWhitespace || character.isNewline {
                if !result.isEmpty {
                    pendingSpace = true
                }
                utf16Offset += length
                continue
            }
            if pendingSpace {
                result.append(" ")
                offsets.append(max(utf16Offset - 1, 0))
                pendingSpace = false
            }
            result.append(character)
            for _ in 0..<length { offsets.append(utf16Offset) }
            utf16Offset += length
        }
        return (result, offsets)
    }

    static func progress(
        fromZenPercent percent: Double,
        readText: String?,
        searchNeighborChapters: Bool = false,
        model: ZenReaderTextModel
    ) -> Double? {
        guard model.totalLength > 0, !model.chapters.isEmpty else { return nil }
        let clamped = min(max(percent, 0), 100)
        let chapterPosition = clamped / 100 * Double(model.chapters.count)
        var chapterIndex = min(max(Int(chapterPosition.rounded(.down)), 0), model.chapters.count - 1)
        if chapterPosition >= Double(model.chapters.count) {
            chapterIndex = model.chapters.count - 1
        }
        let fraction = min(max(chapterPosition - Double(chapterIndex), 0), 1)
        var chapter = model.chapters[chapterIndex]
        var offsetInChapter = min(
            Int((fraction * Double(max(chapter.length, 1))).rounded()),
            chapter.length
        )
        if let readText, !readText.isEmpty {
            let snippet = readText as NSString
            let range = chapter.text.range(of: snippet as String)
            if range.location != NSNotFound {
                offsetInChapter = range.location
            } else if searchNeighborChapters {
                let deltas = [-3, -2, -1, 1, 2, 3]
                for delta in deltas {
                    let neighborIndex = chapterIndex + delta
                    guard neighborIndex >= 0, neighborIndex < model.chapters.count else { continue }
                    let neighbor = model.chapters[neighborIndex]
                    let neighborRange = neighbor.text.range(of: snippet as String)
                    if neighborRange.location != NSNotFound {
                        chapter = neighbor
                        offsetInChapter = neighborRange.location
                        break
                    }
                }
            }
        }
        let offset = min(chapter.start + offsetInChapter, model.totalLength - 1)
        return min(max(Double(offset) / Double(model.totalLength), 0), 1)
    }

    private static func model(forTXTAt url: URL) throws -> ZenReaderTextModel {
        let text = try BookImporter.plainText(from: url)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let pattern = #"(?m)^[\t \x{3000}]*(?:第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷]|Chapter\s+\d+)[^\n]{0,60}$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex.matches(in: text, options: [], range: fullRange)

        var starts: [Int] = []
        if let first = matches.first {
            let prefix = nsText.substring(to: first.range.location)
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                starts.append(0)
            }
        }
        starts.append(contentsOf: matches.map { $0.range.location })
        if starts.isEmpty { starts = [0] }

        var chapters: [ZenTextChapter] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : nsText.length
            let length = max(0, end - start)
            let slice = nsText.substring(with: NSRange(location: start, length: length)) as NSString
            chapters.append(ZenTextChapter(text: slice, start: start, length: length))
        }
        return ZenReaderTextModel(chapters: chapters, totalLength: nsText.length)
    }

    private static func model(forEPUBAt url: URL) throws -> ZenReaderTextModel {
        let extraction = try spineTexts(fromEPUBAt: url)
        defer {
            if let cleanup = extraction.cleanupURL {
                try? FileManager.default.removeItem(at: cleanup)
            }
        }
        var chapters: [ZenTextChapter] = []
        var cursor = 0
        for text in extraction.texts {
            let nsText = text as NSString
            chapters.append(ZenTextChapter(text: nsText, start: cursor, length: nsText.length))
            cursor += nsText.length
        }
        if chapters.isEmpty {
            return ZenReaderTextModel(chapters: [], totalLength: 0)
        }
        return ZenReaderTextModel(chapters: chapters, totalLength: cursor)
    }

    /// Chapter table for MOBI/AZW/AZW3, built by the built-in parser. The
    /// parts are the same documents the reader shows, so character positions
    /// and synced anchors stay aligned with what is on screen.
    private static func model(forMobiAt url: URL) throws -> ZenReaderTextModel {
        let book = try MOBIParser.parseTextOnly(url: url)
        var chapters: [ZenTextChapter] = []
        var cursor = 0
        for part in book.parts {
            let body = MOBIParser.bodyContents(of: part)
            let text = plainText(fromHTML: body)
            let nsText = text as NSString
            guard nsText.length > 0 else { continue }
            chapters.append(ZenTextChapter(text: nsText, start: cursor, length: nsText.length))
            cursor += nsText.length
        }
        return ZenReaderTextModel(chapters: chapters, totalLength: cursor)
    }

    /// Character offset of every decoded MOBI part in the text model.
    /// `nil` marks an image-only part that contributed no text. Used by the
    /// table of contents to place a `filepos` anchor on the same character
    /// scale as `textProgress`.
    static func mobiPartStarts(at url: URL) -> (starts: [Int?], totalLength: Int)? {
        guard let book = try? MOBIParser.parseTextOnly(url: url) else { return nil }
        var starts: [Int?] = []
        starts.reserveCapacity(book.parts.count)
        var cursor = 0
        for part in book.parts {
            let text = plainText(fromHTML: MOBIParser.bodyContents(of: part))
            let length = (text as NSString).length
            if length > 0 {
                starts.append(cursor)
                cursor += length
            } else {
                starts.append(nil)
            }
        }
        return (starts, cursor)
    }

    private static func spineTexts(fromEPUBAt url: URL) throws -> (texts: [String], cleanupURL: URL?) {
        if BookImporter.isEPUBPackage(at: url) {
            guard let containerData = try? Data(
                    contentsOf: url.appendingPathComponent("META-INF/container.xml")
                  ),
                  let rootFilePath = BookImporter.epubContainerRootFilePath(from: containerData),
                  let opfData = try? Data(contentsOf: url.appendingPathComponent(rootFilePath)),
                  let package = BookImporter.epubPackage(from: opfData) else {
                throw ReaderError.invalidEPUB
            }
            let baseURL = url.appendingPathComponent(
                (rootFilePath as NSString).deletingLastPathComponent
            )
            var texts: [String] = []
            for idref in package.spine {
                guard let href = package.manifest[idref] else { continue }
                let chapterURL = baseURL.appendingPathComponent(href)
                let source = (try? String(contentsOf: chapterURL, encoding: .utf8))
                    ?? (try? String(contentsOf: chapterURL, encoding: .isoLatin1))
                guard let source else {
                    texts.append("")
                    continue
                }
                texts.append(plainText(fromHTML: source))
            }
            return (texts, nil)
        }

        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            throw ReaderError.invalidEPUB
        }
        guard let containerData = try? archive.contents(of: "META-INF/container.xml"),
              let rootFilePath = BookImporter.epubContainerRootFilePath(from: containerData),
              let opfData = try? archive.contents(of: rootFilePath),
              let package = BookImporter.epubPackage(from: opfData) else {
            throw ReaderError.invalidEPUB
        }
        let opfDirectory = (rootFilePath as NSString).deletingLastPathComponent
        var texts: [String] = []
        for idref in package.spine {
            guard let href = package.manifest[idref] else { continue }
            let chapterPath = BookImporter.normalizedEPUBPath(
                opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
            )
            guard let chapterData = try? archive.contents(of: chapterPath),
                  let source = BookImporter.decodeEPUBText(chapterData) else {
                texts.append("")
                continue
            }
            texts.append(plainText(fromHTML: source))
        }
        return (texts, nil)
    }

    static func plainText(fromHTML source: String) -> String {
        var text = source
        // The reader renders only <body>; leaving <head> text and indentation
        // in the sync model would inflate every character position and make
        // the phone's percent land a few paragraphs past the real sentence.
        text = text.replacingOccurrences(
            of: #"(?is)<head[^>]*>.*?</head>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<br\s*/?>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)</(p|div|h[1-6]|li|tr)\s*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeHTMLEntities(text)
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&amp;", with: "&")

        guard text.contains("&#") else { return text }
        let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#)
        guard let regex else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let raw = nsText.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if raw.lowercased().hasPrefix("x") {
                scalarValue = UInt32(raw.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(raw, radix: 10)
            }
            guard let value = scalarValue,
                  let scalar = Unicode.Scalar(value) else { continue }
            text = (text as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
        }
        return text
    }

    private static func snippet(from chapter: NSString, offset: Int) -> String {
        guard chapter.length > 0 else { return "" }
        let start = min(max(offset, 0), chapter.length - 1)
        let windowLength = min(64, chapter.length - start)
        let range = chapter.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: windowLength)
        )
        let window = chapter.substring(with: range)
        let trimmed = window.drop(while: { $0.isWhitespace || $0.isNewline })
        return String(trimmed.prefix(12))
    }
}

/// Caches content digests by path, size and modification date. Syncs used to
/// re-read and re-hash every upload candidate on each run; a large PDF made
/// that visible even when nothing had changed.
final class FileDigestCache {
    static let shared = FileDigestCache()

    private struct Entry: Codable {
        let size: Int64
        let modified: Int64
        let digest: String
        let usedAt: TimeInterval
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "EasyRead.FileDigestCache", qos: .utility)
    private let fileURL: URL
    private var entries: [String: Entry] = [:]

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntelReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("file-digests.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func digest(for url: URL) throws -> String {
        let source = url.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let key = source.path

        lock.lock()
        if let entry = entries[key], entry.size == size, entry.modified == modified {
            let digest = entry.digest
            lock.unlock()
            return digest
        }
        lock.unlock()

        let digest = try ZenReaderSync.sha256Hex(fileURL: source)
        lock.lock()
        entries[key] = Entry(
            size: size,
            modified: modified,
            digest: digest,
            usedAt: Date().timeIntervalSince1970
        )
        if entries.count > 400 {
            let excess = entries.count - 400
            for item in entries.sorted(by: { $0.value.usedAt < $1.value.usedAt }).prefix(excess) {
                entries.removeValue(forKey: item.key)
            }
        }
        lock.unlock()
        scheduleSave()
        return digest
    }

    private func scheduleSave() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.entries
            self.lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }
}

final class ZenReaderSync {
    static let shared = ZenReaderSync()
    static let defaultServer = "https://dav.jianguoyun.com/dav/"

    private let defaults = UserDefaults.standard
    private let serverKey = "ZenReaderSyncServer"
    private let usernameKey = "ZenReaderSyncUsername"
    private let providerKey = "ZenReaderSyncProvider"
    private let remoteLayoutKey = "ZenReaderSyncRemoteLayout"
    private let deviceKey = "ZenReaderSyncDeviceID"
    private let autoSyncKey = "ZenReaderSyncAutoEnabled"
    private let lastCompletedKey = "ZenReaderSyncLastCompletedAt"
    // The app is built unsigned on purpose (see build.sh). macOS gives
    // unsigned code the stable keychain partition "unsigned:", while every
    // ad-hoc-signed build gets its own "cdhash:<hash>" partition. The old
    // cdhash entry is why the password became unreadable after each rebuild
    // and had to be typed again. 0.4.15 stores the password under a new v4
    // service created by the unsigned build, so its partition stays valid for
    // all later rebuilds. v3/v2 are still read as a fallback for older items.
    private let keychainService = "EasyRead.ZenReaderWebDAV.v4"
    private let legacyKeychainServices = [
        "EasyRead.ZenReaderWebDAV.v3",
        "EasyRead.ZenReaderWebDAV.v2"
    ]
    private let keychainAccount = "webdav"
    private let passwordLock = NSLock()
    private var cachedPassword: String?

    private struct CachedTextModel {
        let size: Int64
        let modified: Date
        let model: ZenReaderTextModel
    }

    private var textModelCache: [String: CachedTextModel] = [:]
    private let textModelLock = NSLock()

    /// Page counts are shared between the sync (background) and the shelf
    /// label (main thread) so the PDF percentage can use the same
    /// `(page + 1) / pageCount` formula as the phone.
    private static let pdfPageCacheLock = NSLock()
    private static var pdfPageCache: [String: Int] = [:]

    private init() {}

    var serverURL: String {
        get { Self.normalizedServerRoot(defaults.string(forKey: serverKey) ?? Self.defaultServer) }
        set { defaults.set(Self.normalizedServerRoot(newValue), forKey: serverKey) }
    }

    var username: String {
        get { defaults.string(forKey: usernameKey) ?? "" }
        set { defaults.set(newValue, forKey: usernameKey) }
    }

    var provider: ZenWebDAVProvider {
        get {
            if let raw = defaults.string(forKey: providerKey),
               let stored = ZenWebDAVProvider(rawValue: raw) {
                return stored
            }
            // Versions before the provider picker only talked to Jianguoyun.
            return ZenWebDAVProvider.inferred(from: serverURL)
        }
        set { defaults.set(newValue.rawValue, forKey: providerKey) }
    }

    /// Existing installs had their data hardcoded under `ZenReader/v1`; keep
    /// them there so an update never points at an empty folder. New installs
    /// start with EasyRead's own folder.
    var remoteLayout: ZenRemoteLayout {
        get {
            if let raw = defaults.string(forKey: remoteLayoutKey),
               let stored = ZenRemoteLayout(rawValue: raw) {
                return stored
            }
            return hasServerAndAccount ? .zenreader : .easyread
        }
        set { defaults.set(newValue.rawValue, forKey: remoteLayoutKey) }
    }

    /// Strips a previously entered EasyRead / ZenReader suffix so the server
    /// field always means the account root. The chosen folder is appended by
    /// the WebDAV client.
    static func normalizedServerRoot(_ raw: String) -> String {
        var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return server }
        while server.hasSuffix("/") { server.removeLast() }
        guard var components = URLComponents(string: server) else {
            return server + "/"
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let lowerPath = path.lowercased()
        for suffix in ["/zenreader/v1", "/zenreader", "/easyread"] {
            if lowerPath.hasSuffix(suffix) {
                path = String(path.dropLast(suffix.count))
                break
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return server + "/" }
        var result = url.absoluteString
        while result.hasSuffix("/") { result.removeLast() }
        return result + "/"
    }

    var hasServerAndAccount: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Password from this launch's cache or a silent Keychain lookup. This
    /// property never causes the macOS "wants to use your confidential
    /// information" dialog.
    var password: String? {
        passwordIfAvailable
    }

    var isConfigured: Bool {
        hasServerAndAccount && passwordIfAvailable != nil
    }

    private var passwordIfAvailable: String? {
        passwordLock.lock()
        defer { passwordLock.unlock() }
        if let cachedPassword { return cachedPassword }
        var stored: String?
        for service in [keychainService] + legacyKeychainServices {
            if let value = KeychainStore.readSilently(service: service, account: keychainAccount) {
                stored = value
                break
            }
        }
        cachedPassword = stored
        return stored
    }

    private func cachePassword(_ value: String) {
        passwordLock.lock()
        cachedPassword = value
        passwordLock.unlock()
    }

    private func requirePassword() throws -> String {
        guard hasServerAndAccount else { throw ZenReaderSyncError.missingCredentials }
        guard let value = passwordIfAvailable, !value.isEmpty else {
            throw ZenReaderSyncError.keychainReentryRequired
        }
        return value
    }

    var autoSyncEnabled: Bool {
        get {
            guard defaults.object(forKey: autoSyncKey) != nil else { return true }
            return defaults.bool(forKey: autoSyncKey)
        }
        set { defaults.set(newValue, forKey: autoSyncKey) }
    }

    var lastCompletedAt: Date? {
        get { defaults.object(forKey: lastCompletedKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: lastCompletedKey)
            } else {
                defaults.removeObject(forKey: lastCompletedKey)
            }
        }
    }

    var deviceID: String {
        if let existing = defaults.string(forKey: deviceKey), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: deviceKey)
        return value
    }

    func saveSettings(
        server: String,
        username: String,
        password newPassword: String?,
        provider: ZenWebDAVProvider,
        remoteLayout: ZenRemoteLayout
    ) throws {
        let trimmedServer = Self.normalizedServerRoot(server)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedPassword = newPassword ?? ""
        guard !trimmedUser.isEmpty else { throw ZenReaderSyncError.missingCredentials }
        let currentAccount = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePassword: String
        if !typedPassword.isEmpty {
            effectivePassword = typedPassword
        } else if let stored = passwordIfAvailable, currentAccount == trimmedUser {
            effectivePassword = stored
        } else {
            throw ZenReaderSyncError.keychainReentryRequired
        }
        _ = try ZenReaderWebDAVClient(
            serverURL: trimmedServer,
            username: trimmedUser,
            password: effectivePassword,
            remoteFolder: remoteLayout.folderPath
        )
        // Always persist under the current service. The app is unsigned, so the
        // new v4 item gets the stable "unsigned:" partition and keeps working
        // for every later rebuild instead of asking for the password again.
        guard KeychainStore.save(effectivePassword, service: keychainService, account: keychainAccount) else {
            throw ZenReaderSyncError.keychain
        }
        serverURL = trimmedServer
        self.username = trimmedUser
        self.provider = provider
        self.remoteLayout = remoteLayout
        cachePassword(effectivePassword)
    }

    func testConnection(
        server: String,
        username: String,
        password newPassword: String,
        remoteLayout: ZenRemoteLayout
    ) throws -> Int {
        let trimmedServer = Self.normalizedServerRoot(server)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { throw ZenReaderSyncError.missingCredentials }
        let effectivePassword: String
        if !newPassword.isEmpty {
            effectivePassword = newPassword
        } else if let stored = passwordIfAvailable,
                  self.username.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedUser {
            effectivePassword = stored
        } else {
            throw ZenReaderSyncError.keychainReentryRequired
        }
        let client = try ZenReaderWebDAVClient(
            serverURL: trimmedServer,
            username: trimmedUser,
            password: effectivePassword,
            remoteFolder: remoteLayout.folderPath
        )
        do {
            return try client.snapshotNames().count
        } catch ZenReaderSyncError.notFound {
            // Credentials are valid; the progress folder simply has not been created yet.
            return 0
        }
    }

    func clearSettings() {
        defaults.removeObject(forKey: serverKey)
        defaults.removeObject(forKey: usernameKey)
        defaults.removeObject(forKey: providerKey)
        defaults.removeObject(forKey: remoteLayoutKey)
        for service in [keychainService] + legacyKeychainServices {
            KeychainStore.delete(service: service, account: keychainAccount)
        }
        passwordLock.lock()
        cachedPassword = nil
        passwordLock.unlock()
    }

    func sync(
        books: [LibraryBook],
        mode: ZenSyncMode = .bidirectional,
        transfer: ZenBookTransfer = .none,
        progress: ((ZenSyncStage) -> Void)? = nil
    ) throws -> (ZenSyncResult, [UUID: ZenProgressUpdate]) {
        let password = try requirePassword()
        let client = try ZenReaderWebDAVClient(
            serverURL: serverURL,
            username: username,
            password: password,
            remoteFolder: remoteLayout.folderPath
        )
        progress?(.checking)
        let latest = try client.latestSnapshotIfExists()
        let isFirstSync = latest == nil
        let latestDate: Date
        var object: [String: Any]
        var files: [[String: Any]]
        if let latest {
            guard var parsed = try JSONSerialization.jsonObject(with: latest.data) as? [String: Any],
                  let parsedFiles = parsed["files"] as? [[String: Any]] else {
                throw ZenReaderSyncError.invalidSnapshot
            }
            parsed["files"] = parsedFiles
            object = parsed
            files = parsedFiles
            latestDate = Self.date(fromSnapshotName: latest.name) ?? .distantPast
        } else {
            // A fresh EasyRead folder has no snapshot yet. Build an empty
            // ZenReader-compatible payload so the first download/upload can
            // create one without requiring the phone to sync first.
            object = [
                "app": "readerZen",
                "formatVersion": 1,
                "files": [[String: Any]]()
            ]
            files = []
            latestDate = .distantPast
        }

        var result = ZenSyncResult()
        if let latest {
            result.remoteSnapshot = latest.name
        }
        result.totalRemoteBooks = files.count
        var pulledUpdates: [UUID: ZenProgressUpdate] = [:]
        var pushedUpdates: [UUID: ZenProgressUpdate] = [:]
        var dirty = false
        var pdfPageCounts: [String: Int] = [:]
        // The download phase may already list objects/books; hand that
        // listing to the upload phase instead of asking the server twice.
        var objectNames: [String]?
        let now = Date()
        let pushDate = max(now, latestDate.addingTimeInterval(0.002))

        if transfer.downloadsBooks {
            downloadMissingBooks(
                books: books,
                files: files,
                client: client,
                result: &result,
                pdfPageCounts: &pdfPageCounts,
                objectNames: &objectNames,
                progress: progress
            )
        }

        progress?(.preparing)

        // A deletion made on the phone or another device wins over this Mac's
        // shelf: collect matches marked removed so the UI can drop them too.
        var removedIDSet: Set<UUID> = []
        for book in books where book.source == .jianguoyun {
            let localBytes = Self.fileSize(at: book.path)
            guard let index = matchIndex(for: book, in: files, localBytes: localBytes) else { continue }
            guard (Self.parseInteger(files[index]["isRemove"]) ?? 0) != 0 else { continue }
            removedIDSet.insert(book.id)
        }
        if !removedIDSet.isEmpty {
            result.removedBookIDs = Array(removedIDSet)
        }

        for book in books {
            guard !removedIDSet.contains(book.id) else { continue }
            let localBytes = Self.fileSize(at: book.path)
            guard let index = matchIndex(for: book, in: files, localBytes: localBytes) else { continue }
            result.matched += 1

            var entry = files[index]
            let remoteDate = Self.dateFromMilliseconds(entry["updatedAt"])
            // Compare and push the text fraction, never the rendered scroll
            // fraction: the phone measures characters, the WebView measures
            // pixels, and the two drift apart in a long book.
            let localProgress = book.syncedPosition
            let remotePosition = remoteProgress(for: book, entry: entry, pdfPageCounts: &pdfPageCounts)
            let remoteReadText = ((entry["readText"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `progress` is the exact percentage the phone shows. Keep it for
            // the shelf label even though `remotePosition` is converted into
            // this Mac's own character/page ratio for opening the book.
            if let zenPercent = Self.parseNumber(entry["progress"]) {
                result.zenProgressByBookID[book.id] = min(max(zenPercent / 100, 0), 1)
            }

            enum Decision {
                case none
                case pull
                case push
            }
            var decision: Decision = .none
            switch mode {
            case .bidirectional:
                if let remotePosition {
                    if let localDate = book.progressUpdatedAt {
                        if remoteDate.timeIntervalSince1970 > localDate.timeIntervalSince1970 + 1 {
                            decision = .pull
                        } else if localDate.timeIntervalSince1970 > remoteDate.timeIntervalSince1970 + 1 {
                            // Never let a book this Mac has no position for
                            // overwrite a real position from the phone just
                            // because the local timestamp is newer.
                            if localProgress > 0.0001 || remotePosition <= 0.0001 {
                                decision = .push
                            }
                        }
                    } else if remotePosition > localProgress + 0.0001 {
                        decision = .pull
                    } else if localProgress > remotePosition + 0.0001 {
                        decision = .push
                    }
                } else if localProgress > 0.0001 {
                    decision = .push
                }
            case .uploadLocal:
                // Only books with a real local position are uploaded, so untouched
                // books never reset progress that exists on the phone.
                if localProgress > 0.0001
                    || (book.progressUpdatedAt != nil && (remotePosition ?? 0) <= 0.0001) {
                    decision = .push
                }
            case .downloadRemote:
                if remotePosition != nil {
                    decision = .pull
                }
            }

            switch decision {
            case .none:
                continue
            case .pull:
                guard let remotePosition else { continue }
                pulledUpdates[book.id] = ZenProgressUpdate(
                    progress: remotePosition,
                    updatedAt: remoteDate,
                    locatorText: remoteReadText.isEmpty ? nil : remoteReadText
                )
                if abs(remotePosition - localProgress) > 0.0001 {
                    result.pulled += 1
                }
            case .push:
                let payload = positionPayload(for: book, progress: localProgress, pdfPageCounts: &pdfPageCounts)
                if let payload {
                    entry["progress"] = Self.formatPercent(payload.percent)
                    if book.format == "PDF" {
                        entry["readPage"] = payload.readPage
                    } else {
                        entry["readChapter"] = payload.readChapter ?? 0
                        entry["readPage"] = payload.readPage
                        if let text = payload.readText, !text.isEmpty {
                            entry["readText"] = text
                        }
                    }
                } else {
                    entry["progress"] = Self.formatPercent(localProgress * 100)
                    if book.format != "PDF" {
                        result.positionWarnings += 1
                    }
                }
                entry["updatedAt"] = Self.milliseconds(from: pushDate)
                entry["lastOpenDate"] = Self.milliseconds(from: pushDate)
                entry["isReadOver"] = localProgress >= 0.995 ? 1 : 0
                files[index] = entry
                dirty = true
                result.pushed += 1
                let pushedPercent = min(
                    max((Self.parseNumber(entry["progress"]) ?? (localProgress * 100)) / 100, 0),
                    1
                )
                result.zenProgressByBookID[book.id] = pushedPercent
                // Keep the local position untouched: it is the real place this
                // Mac is reading, and the next open must return to it.
                pushedUpdates[book.id] = ZenProgressUpdate(
                    progress: localProgress,
                    updatedAt: pushDate,
                    fromCloud: false
                )
            }
        }

        if transfer.uploadsBooks {
            uploadMissingBooks(
                books: books,
                files: &files,
                client: client,
                result: &result,
                now: pushDate,
                pdfPageCounts: &pdfPageCounts,
                knownObjectNames: objectNames,
                progress: progress
            )
            if result.uploadedBooks > 0 {
                dirty = true
            }
        }

        // A folder that has never been synced gets its first snapshot even
        // when there is nothing to transfer yet. This creates the selected
        // EasyRead / ZenReader root on the server so a later device can see
        // it without waiting for the first book.
        guard dirty || isFirstSync else {
            return (result, pulledUpdates)
        }

        progress?(.writingSnapshot)
        object["files"] = files
        object["deviceId"] = deviceID
        if object["app"] == nil { object["app"] = "readerZen" }
        if object["formatVersion"] == nil { object["formatVersion"] = 1 }

        var uploadDate = pushDate
        var uploadedName: String?
        for _ in 0..<6 {
            let candidate = Self.snapshotName(from: uploadDate)
            object["createdAt"] = Self.milliseconds(from: uploadDate)
            let data: Data
            do {
                // ZenReader writes its own readerzen.json as pretty-printed,
                // alphabetically sorted JSON (`"key" : value`, two spaces).
                // Use the same shape so Mac snapshots look native to the
                // phone. The manifest checksum is computed over the canonical
                // re-serialization, so this does not affect validation.
                data = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
            } catch {
                throw ZenReaderSyncError.invalidSnapshot
            }
            if try client.createSnapshot(named: candidate, data: data) {
                uploadedName = candidate
                break
            }
            uploadDate = uploadDate.addingTimeInterval(0.01)
        }
        guard let uploadName = uploadedName else {
            throw ZenReaderSyncError.conflict
        }
        result.uploadedSnapshot = uploadName
        do {
            try publishManifest(
                client: client,
                object: object,
                snapshotName: uploadName,
                createdAt: uploadDate,
                previousSnapshotName: latest?.name
            )
        } catch {
            // The snapshot itself is safely on the server; only the shared
            // manifest pointer is stale, so keep the sync successful.
            result.manifestWarning = error.localizedDescription
        }

        var updates = pulledUpdates
        for book in books {
            guard pushedUpdates[book.id] != nil else { continue }
            // This echo only advances the local "already known by the cloud"
            // timestamp. It must stay a local update: pretending it came from
            // the cloud would overwrite `textProgress` with the scroll
            // fraction and clear anchors, wiping positions of books that were
            // pushed but never scrolled on this Mac.
            updates[book.id] = ZenProgressUpdate(
                progress: min(max(book.progress, 0), 1),
                updatedAt: uploadDate,
                fromCloud: false
            )
        }
        return (result, updates)
    }

    /// Deletes one book from the cloud library by writing a new snapshot in
    /// which the book is marked removed (`isRemove = 1`, `deleteDate`) and a
    /// `file` tombstone is appended. Older snapshots and the cached book file
    /// on the server are left untouched, so nothing can be lost by accident.
    /// Returns the new snapshot name, or nil when the cloud has no matching book.
    func deleteBook(_ book: LibraryBook) throws -> String? {
        let password = try requirePassword()
        let client = try ZenReaderWebDAVClient(
            serverURL: serverURL,
            username: username,
            password: password,
            remoteFolder: remoteLayout.folderPath
        )
        guard let latest = try client.latestSnapshotIfExists() else { return nil }
        guard var object = try JSONSerialization.jsonObject(with: latest.data) as? [String: Any],
              var files = object["files"] as? [[String: Any]] else {
            throw ZenReaderSyncError.invalidSnapshot
        }

        let localBytes = Self.fileSize(at: book.path)
        guard let index = matchIndex(for: book, in: files, localBytes: localBytes) else {
            return nil
        }

        let now = Date()
        let nowMilliseconds = Self.milliseconds(from: now)
        var entry = files[index]
        let objectID = ((entry["objectID"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        entry["isRemove"] = 1
        entry["deleteDate"] = nowMilliseconds
        entry["updatedAt"] = nowMilliseconds
        files[index] = entry
        object["files"] = files

        if !objectID.isEmpty {
            var tombstones = object["tombstones"] as? [[String: Any]] ?? []
            let alreadyRecorded = tombstones.contains { tombstone in
                ((tombstone["entity"] as? String) ?? "") == "file" &&
                    ((tombstone["objectID"] as? String) ?? "") == objectID
            }
            if !alreadyRecorded {
                tombstones.append([
                    "deletedAt": nowMilliseconds,
                    "entity": "file",
                    "objectID": objectID
                ])
            }
            object["tombstones"] = tombstones
        }

        object["deviceId"] = deviceID
        if object["app"] == nil { object["app"] = "readerZen" }
        if object["formatVersion"] == nil { object["formatVersion"] = 1 }

        let latestDate = Self.date(fromSnapshotName: latest.name) ?? .distantPast
        var uploadDate = max(now, latestDate.addingTimeInterval(0.002))
        var uploadedName: String?
        for _ in 0..<6 {
            let candidate = Self.snapshotName(from: uploadDate)
            object["createdAt"] = Self.milliseconds(from: uploadDate)
            let data: Data
            do {
                // ZenReader writes its own readerzen.json as pretty-printed,
                // alphabetically sorted JSON (`"key" : value`, two spaces).
                // Use the same shape so Mac snapshots look native to the
                // phone. The manifest checksum is computed over the canonical
                // re-serialization, so this does not affect validation.
                data = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
            } catch {
                throw ZenReaderSyncError.invalidSnapshot
            }
            if try client.createSnapshot(named: candidate, data: data) {
                uploadedName = candidate
                break
            }
            uploadDate = uploadDate.addingTimeInterval(0.01)
        }
        guard let uploadName = uploadedName else {
            throw ZenReaderSyncError.conflict
        }
        // Best effort: the deletion snapshot is already written, so a stale
        // manifest pointer must not turn the local removal into an error.
        try? publishManifest(
            client: client,
            object: object,
            snapshotName: uploadName,
            createdAt: uploadDate,
            previousSnapshotName: latest.name
        )
        lastCompletedAt = Date()
        return uploadName
    }

    /// Writes `snapshots/<name>/manifest.json` and refreshes the shared root
    /// `manifest.json` so other ZenReader devices can discover the snapshot,
    /// list its books and verify its payload. Only the root pointer is
    /// overwritten; every older snapshot folder is untouched.
    private func publishManifest(
        client: ZenReaderWebDAVClient,
        object: [String: Any],
        snapshotName: String,
        createdAt: Date,
        previousSnapshotName: String? = nil
    ) throws {
        guard let payloadDigest = Self.manifestPayloadDigest(from: object) else {
            throw ZenReaderSyncError.invalidSnapshot
        }
        var manifest = (try? client.rootManifest()) ?? [:]
        let snapshotRoot = "snapshots/\(snapshotName)"
        let createdAtMilliseconds = Self.milliseconds(from: createdAt)
        let createdAtText = Self.manifestDateText(from: createdAt)

        // Keep the phone's own book metadata where we can. ZenReader's
        // manifests carry the user-facing `originalName` (often with an
        // "作者：…" suffix) and the book's `contentUpdatedAt` from its local
        // database; both differ from what can be derived from the payload.
        // Rewriting them on every Mac upload makes Mac snapshots look unlike
        // anything the phone ever wrote, so prefer the previous manifest's
        // values whenever the same book is still present.
        var previousBooks: [String: [String: Any]] = [:]
        for case let entry as [String: Any] in (manifest["books"] as? [Any]) ?? [] {
            guard let objectID = entry["objectID"] as? String else { continue }
            previousBooks[objectID] = entry
        }

        var books: [[String: Any]] = []
        for entry in (object["files"] as? [[String: Any]]) ?? [] {
            guard let info = Self.webdavInfo(from: entry),
                  let objectID = (entry["objectID"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !objectID.isEmpty,
                  let size = Self.rawByteSize(entry["fileSize"]) else { continue }
            let remoteName = (info.path as NSString).lastPathComponent
            guard !remoteName.isEmpty else { continue }
            let sha256 = (info.sha256?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0.lowercased()
            } ?? (remoteName as NSString).deletingPathExtension.lowercased()
            let previous = previousBooks[objectID]
            let originalName = ((previous?["originalName"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contentUpdatedAt = Self.parseInteger(previous?["contentUpdatedAt"])
                ?? Self.parseInteger(entry["contentUpdatedAt"])
                ?? Self.parseInteger(entry["createDate"])
                ?? Self.parseInteger(entry["updatedAt"])
                ?? Int(createdAtMilliseconds)
            books.append([
                "available": true,
                "contentUpdatedAt": contentUpdatedAt,
                "objectID": objectID,
                "originalName": originalName.isEmpty
                    ? Self.manifestOriginalName(for: entry, remoteName: remoteName)
                    : originalName,
                "remoteName": remoteName,
                "remotePath": info.path,
                "sha256": sha256,
                "size": Int(size)
            ])
        }

        var history = (manifest["snapshots"] as? [[String: Any]] ?? []).filter {
            (($0["snapshotRoot"] as? String) ?? "") != snapshotRoot
        }
        if let previousSnapshotName,
           !previousSnapshotName.isEmpty,
           previousSnapshotName != snapshotName,
           !history.contains(where: {
               (($0["snapshotRoot"] as? String) ?? "") == "snapshots/\(previousSnapshotName)"
           }) {
            let previousDate = Self.date(fromSnapshotName: previousSnapshotName)
                ?? createdAt.addingTimeInterval(-1)
            history.append([
                "createdAt": Self.milliseconds(from: previousDate),
                "createdAtText": Self.manifestDateText(from: previousDate),
                "manifestPath": "snapshots/\(previousSnapshotName)/manifest.json",
                "snapshotRoot": "snapshots/\(previousSnapshotName)"
            ])
        }
        history.append([
            "createdAt": createdAtMilliseconds,
            "createdAtText": createdAtText,
            "manifestPath": "\(snapshotRoot)/manifest.json",
            "snapshotRoot": snapshotRoot
        ])
        // ZenReader always trims its backup history to the newest 20 entries
        // (it starts growing 2, 3, … and stays at 20 from then on). Mac
        // uploads used to append without a cap, so roots written by EasyRead
        // carried 21–23 entries — unlike anything the phone ever writes.
        // Match the phone exactly: sort oldest → newest, drop duplicates and
        // keep only the newest 20.
        history.sort {
            (Self.parseInteger($0["createdAt"]) ?? 0) < (Self.parseInteger($1["createdAt"]) ?? 0)
        }
        var dedupedHistory: [[String: Any]] = []
        for entry in history {
            let root = (entry["snapshotRoot"] as? String) ?? ""
            dedupedHistory.removeAll { (($0["snapshotRoot"] as? String) ?? "") == root }
            dedupedHistory.append(entry)
        }
        history = Array(dedupedHistory.suffix(20))

        manifest["app"] = (manifest["app"] as? String) ?? "readerZen"
        manifest["books"] = books
        if manifest["covers"] == nil { manifest["covers"] = [Any]() }
        manifest["createdAt"] = createdAtMilliseconds
        manifest["createdAtText"] = createdAtText
        manifest["dataPath"] = "\(snapshotRoot)/readerzen.json"
        manifest["dataSha256"] = payloadDigest.sha256
        manifest["dataSize"] = payloadDigest.size
        manifest["formatVersion"] = 3
        manifest["snapshotRoot"] = snapshotRoot
        manifest["snapshots"] = history

        // ZenReader writes manifests pretty-printed with sorted keys; match
        // that byte shape. (The checksum fields above describe the canonical
        // compact payload, not this file.)
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try client.putObject(
            relativePath: "\(snapshotRoot)/manifest.json",
            data: data,
            contentType: "application/json; charset=utf-8"
        )
        try client.putObject(
            relativePath: "manifest.json",
            data: data,
            contentType: "application/json; charset=utf-8"
        )
    }

    /// ZenReader verifies a snapshot by taking the `readerzen.json` object,
    /// removing its top-level `createdAt` (the manifest carries the timestamp
    /// separately), re-serializing it with sorted keys and Foundation's
    /// default JSON escaping, then hashing that compact payload. Hashing the
    /// uploaded bytes instead makes the phone reject every Mac snapshot with
    /// "WebDAV数据校验失败", even though the manifest is self-consistent.
    /// Both `dataSize` and `dataSha256` must therefore describe this canonical
    /// payload, not the file on the server.
    private static func manifestPayloadDigest(from object: [String: Any]) -> (size: Int, sha256: String)? {
        var payload = object
        payload.removeValue(forKey: "createdAt")
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return (data.count, sha256Hex(data))
    }

    private static func manifestOriginalName(for entry: [String: Any], remoteName: String) -> String {
        if let name = entry["originalName"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        let display = ((entry["displayName"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = ((entry["fileType"] as? String) ?? "").lowercased()
        guard !display.isEmpty else { return remoteName }
        if !type.isEmpty, !display.lowercased().hasSuffix(".\(type)") {
            return "\(display).\(type)"
        }
        return display
    }

    private func remoteProgress(
        for book: LibraryBook,
        entry: [String: Any],
        pdfPageCounts: inout [String: Int]
    ) -> Double? {
        let remotePercent = Self.parseNumber(entry["progress"])
        if book.format == "PDF" {
            if let page = Self.parseInteger(entry["readPage"]),
               let count = Self.pdfPageCount(for: book, cache: &pdfPageCounts), count > 1 {
                return min(max(Double(page) / Double(count - 1), 0), 1)
            }
            if let percent = remotePercent {
                return min(max(percent / 100, 0), 1)
            }
            return nil
        }
        guard let percent = remotePercent else { return nil }
        if percent <= 0 { return 0 }
        if percent >= 100 { return 1 }
        if let model = textModel(for: book),
           let converted = ZenTextLocator.progress(
               fromZenPercent: percent,
               readText: entry["readText"] as? String,
               searchNeighborChapters: ["MOBI", "AZW", "AZW3"].contains(book.format),
               model: model
           ) {
            return converted
        }
        return min(max(percent / 100, 0), 1)
    }

    private static let booksFolder = "objects/books"
    /// Three connections hide WebDAV round-trip latency without flooding
    /// Jianguoyun; more parallel books tend to make its server slower.
    private static let maxConcurrentBookTransfers = 3

    /// Downloads every remote book that is not on this Mac's shelf yet.
    /// The remote progress is imported into the same shelf record at the same time,
    /// so a downloaded book opens exactly where the phone left off.
    private struct PendingBookDownload {
        let entry: [String: Any]
        let objectID: String
        let displayName: String
        let fileType: String
        let webdavPath: String?
        let url: URL
        let needsDownload: Bool
    }

    /// Downloads every remote book that is not on this Mac's shelf yet.
    /// Transfers run a few at a time: WebDAV round-trip latency is the real
    /// cost for normal book sizes, and a serial loop paid it once per book.
    private func downloadMissingBooks(
        books: [LibraryBook],
        files: [[String: Any]],
        client: ZenReaderWebDAVClient,
        result: inout ZenSyncResult,
        pdfPageCounts: inout [String: Int],
        objectNames: inout [String]?,
        progress: ((ZenSyncStage) -> Void)? = nil
    ) {
        var matchedIndices: Set<Int> = []
        let shelfPaths = Set(books.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        for book in books {
            let localBytes = Self.fileSize(at: book.path)
            if let index = matchIndex(for: book, in: files, localBytes: localBytes) {
                matchedIndices.insert(index)
            }
        }

        let supportedFormats = ["txt", "epub", "pdf", "mobi", "azw", "azw3", "md", "markdown"]
        var seenObjects: Set<String> = []
        var reservedPaths: Set<String> = []
        var prepared: [PendingBookDownload] = []

        for (index, entry) in files.enumerated() {
            guard !matchedIndices.contains(index) else { continue }
            guard (Self.parseInteger(entry["isRemove"]) ?? 0) == 0 else { continue }
            let objectID = ((entry["objectID"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objectID.isEmpty, seenObjects.insert(objectID).inserted else { continue }
            let fileType = ((entry["fileType"] as? String) ?? "").lowercased()
            guard supportedFormats.contains(fileType) else {
                result.transferSkipped += 1
                continue
            }
            let displayName = (entry["displayName"] as? String) ?? objectID
            let expectedSize = (entry["fileSize"] as? String) ?? ""

            do {
                let cached = try Self.cachedBookFile(
                    displayName: displayName,
                    fileType: fileType,
                    objectID: objectID,
                    expectedSize: expectedSize,
                    reservedPaths: reservedPaths
                )
                if !cached.exists {
                    reservedPaths.insert(cached.url.standardizedFileURL.path)
                }
                prepared.append(PendingBookDownload(
                    entry: entry,
                    objectID: objectID,
                    displayName: displayName,
                    fileType: fileType,
                    webdavPath: Self.webdavObjectPath(from: entry),
                    url: cached.url,
                    needsDownload: !cached.exists
                ))
            } catch {
                result.transferFailures.append("\(displayName)：\(error.localizedDescription)")
            }
        }

        let downloads = prepared.filter(\.needsDownload)
        if !downloads.isEmpty, objectNames == nil {
            // Only needed by older snapshots that have no extraJSON.webdav.path.
            // A failed listing must not block direct path downloads.
            objectNames = try? client.fileNames(folder: Self.booksFolder)
        }

        var failures: [String: Error] = [:]
        if !downloads.isEmpty {
            let names = objectNames ?? []
            let total = downloads.count
            let failureLock = NSLock()
            let progressLock = NSLock()
            var finished = 0
            let gate = DispatchSemaphore(value: Self.maxConcurrentBookTransfers)
            let group = DispatchGroup()
            let queue = DispatchQueue(
                label: "EasyRead.ZenBookDownloads",
                attributes: .concurrent
            )
            progress?(.downloading(done: 0, total: total))
            for item in downloads {
                gate.wait()
                group.enter()
                let destination = item.url
                queue.async {
                    defer {
                        gate.signal()
                        group.leave()
                    }
                    do {
                        try Self.downloadedObjectFile(
                            client: client,
                            webdavPath: item.webdavPath,
                            objectID: item.objectID,
                            fileType: item.fileType,
                            displayName: item.displayName,
                            names: names,
                            destination: destination
                        )
                    } catch {
                        failureLock.lock()
                        failures[destination.standardizedFileURL.path] = error
                        failureLock.unlock()
                    }
                    progressLock.lock()
                    finished += 1
                    let completed = finished
                    progressLock.unlock()
                    progress?(.downloading(done: completed, total: total))
                }
            }
            group.wait()
        }

        for item in prepared {
            if item.needsDownload,
               let failure = failures[item.url.standardizedFileURL.path] {
                result.transferFailures.append("\(item.displayName)：\(failure.localizedDescription)")
                continue
            }
            // Never import a cloud entry whose file already belongs to a shelf
            // record. Importing would replace that record by path and could
            // reset a newer local position to the cloud's older one.
            guard !shelfPaths.contains(item.url.standardizedFileURL.path) else { continue }
            let entry = item.entry
            let createdDate = Self.dateFromMilliseconds(entry["createDate"])
            var book = LibraryBook(
                id: UUID(),
                path: item.url.path,
                title: item.displayName,
                format: BookImporter.formatName(forExtension: item.fileType),
                author: (entry["author"] as? String) ?? "",
                progress: 0,
                addedAt: createdDate > .distantPast ? createdDate : Date(),
                source: .jianguoyun,
                zenProgress: Self.parseNumber(entry["progress"]).map {
                    min(max($0 / 100, 0), 1)
                }
            )
            if let position = remoteProgress(for: book, entry: entry, pdfPageCounts: &pdfPageCounts) {
                book.progress = position
                if book.format != "PDF" {
                    book.textProgress = position
                }
                let updatedAt = Self.dateFromMilliseconds(entry["updatedAt"])
                book.progressUpdatedAt = updatedAt > .distantPast ? updatedAt : nil
                let readText = ((entry["readText"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if book.format != "PDF", !readText.isEmpty {
                    // The snapshot carries the sentence at the phone's
                    // position. Remember it so opening this fresh download
                    // lands on that sentence, not on a percentage of the
                    // scroll height.
                    book.zenLocatorText = readText
                    book.zenLocatorAnchor = position
                    book.localTextAnchor = readText
                    book.localTextAnchorProgress = position
                }
            }
            result.downloadedBooks += 1
            result.importedBooks.append(book)
        }
    }

    private static func downloadedObjectFile(
        client: ZenReaderWebDAVClient,
        webdavPath: String?,
        objectID: String,
        fileType: String,
        displayName: String,
        names: [String],
        destination: URL
    ) throws {
        // The phone stores the real content-addressed path in extraJSON.
        // Snapshots written by older EasyRead builds only carry an objectID,
        // so keep those naming candidates as a fallback.
        if let webdavPath {
            do {
                try client.downloadObject(relativePath: webdavPath, to: destination)
                return
            } catch ZenReaderSyncError.notFound {
                // Fall through to the legacy objectID lookup.
            }
        }
        var candidates = [objectID, "\(objectID).\(fileType)", "\(objectID).\(fileType.uppercased())"]
        if displayName.lowercased().hasSuffix(".\(fileType)") {
            candidates.append(displayName)
        } else {
            candidates.append("\(displayName).\(fileType)")
        }
        if let name = candidates.first(where: { names.contains($0) }) {
            try client.downloadObject(folder: Self.booksFolder, name: name, to: destination)
            return
        }
        for name in candidates {
            do {
                try client.downloadObject(folder: Self.booksFolder, name: name, to: destination)
                return
            } catch ZenReaderSyncError.notFound {
                continue
            }
        }
        throw ZenReaderSyncError.notFound
    }

    private static func cachedBookFile(
        displayName: String,
        fileType: String,
        objectID: String,
        expectedSize: String,
        reservedPaths: Set<String> = []
    ) throws -> (url: URL, exists: Bool) {
        try ZenBookCache.ensureDirectory()
        let ext = fileType.lowercased()
        var base = displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = objectID }
        if base.count > 120 { base = String(base.prefix(120)) }
        if !base.lowercased().hasSuffix(".\(ext)") {
            base += ".\(ext)"
        }

        let fileManager = FileManager.default
        let directory = ZenBookCache.directoryURL
        let primary = directory.appendingPathComponent(base)
        if fileManager.fileExists(atPath: primary.path) {
            if expectedSize.isEmpty || remoteSizeMatches(expectedSize, localBytes: fileSize(at: primary.path)) {
                return (primary, true)
            }
        } else if !reservedPaths.contains(primary.standardizedFileURL.path) {
            return (primary, false)
        }

        let stem = (base as NSString).deletingPathExtension
        let extensionPart = (base as NSString).pathExtension
        var counter = 2
        while counter < 1000 {
            let numbered = extensionPart.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(extensionPart)"
            let candidate = directory.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: candidate.path) {
                if reservedPaths.contains(candidate.standardizedFileURL.path) {
                    counter += 1
                    continue
                }
                return (candidate, false)
            }
            if expectedSize.isEmpty || remoteSizeMatches(expectedSize, localBytes: fileSize(at: candidate.path)) {
                return (candidate, true)
            }
            counter += 1
        }
        throw ZenReaderSyncError.conflict
    }

    private func uploadCandidates(books: [LibraryBook], files: [[String: Any]]) -> [LibraryBook] {
        books.filter { book in
            guard book.source == .jianguoyun else { return false }
            // Markdown is a Mac-only addition; uploading it would create a
            // snapshot entry the phone cannot open.
            guard BookImporter.isPhoneSyncable(format: book.format) else { return false }
            guard !ZenBookCache.contains(book.path) else { return false }
            guard FileManager.default.fileExists(atPath: book.path) else { return false }
            let size = Self.fileSize(at: book.path)
            guard size > 0 else { return false }
            return matchIndex(for: book, in: files, localBytes: size) == nil
        }
    }

    /// Preflight for the single “sync books and positions” confirmation.
    /// The operation itself always re-reads the latest snapshot, so a phone
    /// that synced meanwhile is never overwritten.
    func syncPlan(books: [LibraryBook]) throws -> ZenSyncPlan {
        let password = try requirePassword()
        let client = try ZenReaderWebDAVClient(
            serverURL: serverURL,
            username: username,
            password: password,
            remoteFolder: remoteLayout.folderPath
        )
        let latest = try client.latestSnapshotIfExists()
        let files: [[String: Any]]
        if let latest {
            guard let object = try JSONSerialization.jsonObject(with: latest.data) as? [String: Any],
                  let parsedFiles = object["files"] as? [[String: Any]] else {
                throw ZenReaderSyncError.invalidSnapshot
            }
            files = parsedFiles
        } else {
            files = []
        }

        var plan = ZenSyncPlan()
        var matchedIndices: Set<Int> = []
        for book in books {
            let localBytes = Self.fileSize(at: book.path)
            if let index = matchIndex(for: book, in: files, localBytes: localBytes) {
                matchedIndices.insert(index)
                plan.matched += 1
            }
        }

        let supportedFormats = ["txt", "epub", "pdf", "mobi", "azw", "azw3", "md", "markdown"]
        var seenObjects: Set<String> = []
        for (index, entry) in files.enumerated() {
            guard !matchedIndices.contains(index),
                  (Self.parseInteger(entry["isRemove"]) ?? 0) == 0 else { continue }
            let objectID = ((entry["objectID"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objectID.isEmpty, seenObjects.insert(objectID).inserted else { continue }
            let fileType = ((entry["fileType"] as? String) ?? "").lowercased()
            guard supportedFormats.contains(fileType) else {
                plan.transferSkipped += 1
                continue
            }
            plan.downloadCount += 1
            plan.downloadTitles.append((entry["displayName"] as? String) ?? objectID)
        }

        let candidates = uploadCandidates(books: books, files: files)
        plan.uploadCount = candidates.count
        plan.uploadBytes = candidates.reduce(Int64(0)) { $0 + Self.fileSize(at: $1.path) }
        plan.uploadTitles = candidates.map(\.title)
        return plan
    }

    /// Uploads books that exist only on this Mac, adding their current reading
    /// position to the new snapshot entry in the same operation.
    private struct PendingBookUpload {
        let book: LibraryBook
        let size: Int64
        let digest: String
        let remoteName: String
        let objectID: String
    }

    private func uploadMissingBooks(
        books: [LibraryBook],
        files: inout [[String: Any]],
        client: ZenReaderWebDAVClient,
        result: inout ZenSyncResult,
        now: Date,
        pdfPageCounts: inout [String: Int],
        knownObjectNames: [String]?,
        progress: ((ZenSyncStage) -> Void)? = nil
    ) {
        let candidates = uploadCandidates(books: books, files: files)
        guard !candidates.isEmpty else { return }
        var existingNames: Set<String>
        do {
            if let knownObjectNames {
                // Reuse the listing from the download phase of this sync.
                existingNames = Set(knownObjectNames)
            } else if let names = try client.fileNamesIfExists(folder: Self.booksFolder) {
                existingNames = Set(names)
            } else {
                try client.ensureCollection(Self.booksFolder)
                existingNames = []
            }
        } catch {
            result.transferFailures.append(error.localizedDescription)
            return
        }
        let accountKey = webdavAccountKey()

        var prepared: [PendingBookUpload] = []
        for book in candidates {
            let size = Self.fileSize(at: book.path)
            guard size > 0 else { continue }
            do {
                // Hash by streaming the file so a large PDF never has to be
                // held in memory just to name its content-addressed object.
                let digest = try FileDigestCache.shared.digest(
                    for: URL(fileURLWithPath: book.path)
                )
                prepared.append(PendingBookUpload(
                    book: book,
                    size: size,
                    digest: digest,
                    remoteName: "\(digest).\(book.format.lowercased())",
                    objectID: UUID().uuidString.lowercased()
                ))
            } catch {
                result.transferFailures.append("\(book.title)：\(error.localizedDescription)")
            }
        }
        guard !prepared.isEmpty else { return }

        var failures: [String: Error] = [:]
        let failureLock = NSLock()
        let progressLock = NSLock()
        var finished = 0
        let gate = DispatchSemaphore(value: Self.maxConcurrentBookTransfers)
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "EasyRead.ZenBookUploads",
            attributes: .concurrent
        )
        var queuedNames: Set<String> = []
        var queued: [(name: String, fileURL: URL)] = []
        for item in prepared {
            guard !existingNames.contains(item.remoteName),
                  queuedNames.insert(item.remoteName).inserted else { continue }
            queued.append((item.remoteName, URL(fileURLWithPath: item.book.path)))
        }
        let total = queued.count
        if total > 0 {
            progress?(.uploading(done: 0, total: total))
        }
        for item in queued {
            gate.wait()
            group.enter()
            queue.async {
                defer {
                    gate.signal()
                    group.leave()
                }
                do {
                    try client.putObject(
                        folder: Self.booksFolder,
                        name: item.name,
                        fileURL: item.fileURL
                    )
                } catch {
                    failureLock.lock()
                    failures[item.name] = error
                    failureLock.unlock()
                }
                progressLock.lock()
                finished += 1
                let completed = finished
                progressLock.unlock()
                progress?(.uploading(done: completed, total: total))
            }
        }
        group.wait()

        var reportedFailures: Set<String> = []
        for item in prepared {
            let available = existingNames.contains(item.remoteName)
                || (queuedNames.contains(item.remoteName) && failures[item.remoteName] == nil)
            guard available else {
                if let failure = failures[item.remoteName],
                   reportedFailures.insert(item.remoteName).inserted {
                    result.transferFailures.append(
                        "\(item.book.title)：\(failure.localizedDescription)"
                    )
                }
                continue
            }
            files.append(uploadedEntry(
                for: item.book,
                objectID: item.objectID,
                fileSize: item.size,
                sha256: item.digest,
                remoteName: item.remoteName,
                accountKey: accountKey,
                now: now,
                pdfPageCounts: &pdfPageCounts
            ))
            result.uploadedBooks += 1
        }
    }

    private func uploadedEntry(
        for book: LibraryBook,
        objectID: String,
        fileSize size: Int64,
        sha256: String,
        remoteName: String,
        accountKey: String,
        now: Date,
        pdfPageCounts: inout [String: Int]
    ) -> [String: Any] {
        let progress = book.syncedPosition
        let payload = positionPayload(for: book, progress: progress, pdfPageCounts: &pdfPageCounts)
        let percent = payload?.percent ?? progress * 100
        var displayName = book.title
        if !book.author.isEmpty,
           !Self.normalizeName(book.title).contains(Self.normalizeName(book.author)) {
            displayName += " (\(book.author))"
        }
        let created = Self.milliseconds(from: book.addedAt)
        let syncedAt = Self.milliseconds(from: now)
        let extra: [String: Any] = [
            "schemaVersion": 1,
            "webdav": [
                "accountKey": accountKey,
                "path": "objects/books/\(remoteName)",
                "sha256": sha256,
                "syncedAt": syncedAt
            ]
        ]
        let extraData = (try? JSONSerialization.data(withJSONObject: extra)) ?? Data()
        let extraJSON = String(data: extraData, encoding: .utf8) ?? ""
        var entry: [String: Any] = [
            "author": book.author,
            "createDate": created,
            "displayName": displayName,
            "extraJSON": extraJSON,
            "fileSize": "\(size)",
            "fileType": book.format.lowercased(),
            "fromType": "",
            "isLock": 0,
            "isReadOver": progress >= 0.995 ? 1 : 0,
            "isRemove": 0,
            "isTop": 0,
            "lastOpenDate": syncedAt,
            "objectID": objectID,
            "parentId": "",
            "picModel": 0,
            "pinYinName": Self.normalizeName(displayName),
            "progress": Self.formatPercent(percent),
            "readChapter": payload?.readChapter ?? 0,
            "readPage": payload?.readPage ?? 0,
            "score": 0,
            "updatedAt": Self.milliseconds(from: now)
        ]
        if let text = payload?.readText, !text.isEmpty {
            entry["readText"] = text
        }
        return entry
    }

    private func matchIndex(for book: LibraryBook, in files: [[String: Any]], localBytes: Int64) -> Int? {
        let format = BookImporter.formatName(forExtension: book.format).lowercased()
        var candidates: [(index: Int, score: Int, removed: Bool, updatedAt: Int)] = []
        for (index, entry) in files.enumerated() {
            let rawFormat = (entry["fileType"] as? String) ?? ""
            let entryFormat = BookImporter.formatName(forExtension: rawFormat).lowercased()
            guard entryFormat == format else { continue }
            let displayName = (entry["displayName"] as? String) ?? ""
            let nameScore = Self.nameScore(local: book.title, remote: displayName)
            // The phone stores raw byte counts ("266656"); older snapshots and
            // mock fixtures may use a formatted size ("260.41 KB").
            let sizeMatches = Self.remoteSizeMatches(entry["fileSize"], localBytes: localBytes)
            guard nameScore > 0 || sizeMatches else { continue }
            var score = 10 + nameScore
            if sizeMatches { score += 25 }
            if Self.authorMatches(local: book.author, remote: (entry["author"] as? String) ?? "") {
                score += 8
            }
            candidates.append((
                index,
                score,
                (Self.parseInteger(entry["isRemove"]) ?? 0) != 0,
                Self.parseInteger(entry["updatedAt"]) ?? 0
            ))
        }
        guard let bestScore = candidates.map(\.score).max(), bestScore >= 30 else {
            return nil
        }
        let top = candidates.filter { $0.score == bestScore }
        // ZenReader keeps a removed duplicate behind for some books (the same
        // name/size as the live entry, only `isRemove = 1`). A strict
        // "exactly one best candidate" rule made such books unmatchable: their
        // positions were never uploaded, and the download phase re-imported
        // them as "missing", replacing the shelf record with the older cloud
        // position. Prefer the live entry, then the most recently updated one.
        if let live = top.filter({ !$0.removed }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return live.index
        }
        return top.max(by: { $0.updatedAt < $1.updatedAt })?.index
    }

    private static func remoteSizeMatches(_ remoteValue: Any?, localBytes: Int64) -> Bool {
        guard localBytes > 0 else { return false }
        if let number = remoteValue as? NSNumber {
            return number.int64Value == localBytes
        }
        guard let string = remoteValue as? String else { return false }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let bytes = Int64(trimmed) {
            return bytes == localBytes
        }
        return trimmed == formatFileSize(localBytes)
    }

    /// The phone records both the local database object ID and the real
    /// content-addressed path inside `extraJSON`; the path is what the object
    /// store can be downloaded by.
    private static func webdavInfo(from entry: [String: Any]) -> (path: String, sha256: String?)? {
        let payload: [String: Any]?
        if let raw = entry["extraJSON"] as? String {
            payload = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        } else {
            payload = entry["extraJSON"] as? [String: Any]
        }
        guard let webdav = payload?["webdav"] as? [String: Any],
              let path = webdav["path"] as? String else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("objects/"), !trimmed.contains("..") else { return nil }
        return (trimmed, (webdav["sha256"] as? String))
    }

    private static func webdavObjectPath(from entry: [String: Any]) -> String? {
        webdavInfo(from: entry)?.path
    }

    private static func rawByteSize(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        guard let string = value as? String else { return nil }
        return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func manifestDateText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The iPhone app hashes "<server with trailing slash>|<account>" and
    /// stores the result in `extraJSON.webdav.accountKey`.
    private func webdavAccountKey() -> String {
        var server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while server.hasSuffix("/") { server.removeLast() }
        server += "/"
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.sha256Hex(Data("\(server)|\(user)".utf8))
    }

    private static func nameScore(local: String, remote: String) -> Int {
        let a = normalizeName(local)
        let b = normalizeName(remote)
        guard !b.isEmpty else { return 0 }
        if a == b { return 60 }
        if b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return 45 }
        if b.count >= 4, a.contains(b) || b.contains(a) { return 35 }
        return 0
    }

    private static func authorMatches(local: String, remote: String) -> Bool {
        let a = normalizeName(local)
        let b = normalizeName(remote)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func normalizeName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{3000}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "　", with: "")
            .lowercased()
    }

    private static func fileSize(at path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let value = Double(bytes)
        if value >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", locale: Locale(identifier: "en_US_POSIX"), value / (1024 * 1024 * 1024))
        }
        if value >= 1024 * 1024 {
            return String(format: "%.2f MB", locale: Locale(identifier: "en_US_POSIX"), value / (1024 * 1024))
        }
        if value >= 1024 {
            return String(format: "%.2f KB", locale: Locale(identifier: "en_US_POSIX"), value / 1024)
        }
        return "\(bytes) B"
    }

    private static func parseNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Double(trimmed)
        }
        return nil
    }

    private static func parseInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date {
        let milliseconds = parseNumber(value) ?? 0
        guard milliseconds > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func formatPercent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        return "\(clamped)"
    }

    private func positionPayload(
        for book: LibraryBook,
        progress: Double,
        pdfPageCounts: inout [String: Int]
    ) -> ZenPositionPayload? {
        if book.format == "PDF" {
            guard let count = Self.pdfPageCount(for: book, cache: &pdfPageCounts), count > 1 else {
                return nil
            }
            let index = min(
                max(Int((progress * Double(count - 1)).rounded()), 0),
                count - 1
            )
            let percent = Double(index + 1) / Double(count) * 100
            return ZenPositionPayload(percent: percent, readPage: index, readChapter: nil, readText: nil)
        }
        // Reuse the sync's shared chapter cache. Calling ZenTextLocator
        // directly here re-parsed the book for every MOBI pushed during upload,
        // even when the same table had just been built for the download phase.
        guard let model = textModel(for: book) else { return nil }
        // A snippet captured while scrolling is the exact sentence at the top
        // of this Mac's viewport. Locating it beats converting a percentage,
        // because the phone's chapter-weighted percent and this Mac's scroll
        // fraction drift apart.
        if let anchor = book.localTextAnchor,
           !anchor.isEmpty,
           let anchorProgress = book.localTextAnchorProgress,
           abs(anchorProgress - progress) <= 0.01,
           let payload = ZenTextLocator.locate(readText: anchor, near: progress, model: model) {
            return payload
        }
        // The phone's own anchor is equally exact and stays valid until this
        // Mac reads somewhere else.
        if let anchor = book.zenLocatorText,
           !anchor.isEmpty,
           let anchorProgress = book.zenLocatorAnchor,
           abs(anchorProgress - progress) <= 0.01,
           let payload = ZenTextLocator.locate(readText: anchor, near: progress, model: model) {
            return payload
        }
        return ZenTextLocator.locate(progress: progress, model: model)
    }

    private static func pdfPageCount(for book: LibraryBook, cache: inout [String: Int]) -> Int? {
        if let cached = cache[book.path] { return cached }
        pdfPageCacheLock.lock()
        let shared = pdfPageCache[book.path]
        pdfPageCacheLock.unlock()
        if let shared {
            cache[book.path] = shared
            return shared
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: book.path)) else { return nil }
        cache[book.path] = document.pageCount
        pdfPageCacheLock.lock()
        pdfPageCache[book.path] = document.pageCount
        pdfPageCacheLock.unlock()
        return document.pageCount
    }

    private static func cachedPDFPageCount(for book: LibraryBook) -> Int? {
        pdfPageCacheLock.lock()
        defer { pdfPageCacheLock.unlock() }
        return pdfPageCache[book.path]
    }

    private func textModel(for book: LibraryBook) -> ZenReaderTextModel? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: book.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        textModelLock.lock()
        if let cached = textModelCache[book.path],
           cached.size == size,
           cached.modified == modified {
            let model = cached.model
            textModelLock.unlock()
            return model
        }
        textModelLock.unlock()

        let sourceURL = URL(fileURLWithPath: book.path)
        if let stored = ZenTextModelStore.load(for: sourceURL) {
            storeTextModel(stored, path: book.path, size: size, modified: modified)
            return stored
        }
        guard let model = ZenTextLocator.model(for: book) else { return nil }
        ZenTextModelStore.store(model, for: sourceURL)
        storeTextModel(model, path: book.path, size: size, modified: modified)
        return model
    }

    /// Builds the table of contents for the reader. Text books reuse the same
    /// cached chapter table as sync, so repeated opens are cheap.
    func chapters(for book: LibraryBook) -> [ReaderChapter] {
        switch book.format {
        case "PDF":
            return Self.pdfChapters(for: book)
        case "MD":
            return Self.markdownChapters(for: book)
        case "FB2":
            return (try? FB2Renderer.chapters(for: URL(fileURLWithPath: book.path))) ?? []
        case "CBZ":
            return (try? ComicRenderer.chapters(for: URL(fileURLWithPath: book.path))) ?? []
        case "RTF":
            return (try? RTFRenderer.chapters(for: URL(fileURLWithPath: book.path))) ?? []
        case "DOCX":
            return (try? DOCXRenderer.chapters(for: URL(fileURLWithPath: book.path))) ?? []
        case "EPUB", "MOBI", "AZW", "AZW3":
            let model = textModel(for: book)
            // Prefer the book's own navigation tree. Collections expose one
            // top-level group per included book there, which is what lets the
            // contents popover fold the volumes that are not being read.
            let nav: [ReaderChapter]
            if book.format == "EPUB" {
                nav = Self.epubNavChapters(for: book, model: model)
            } else {
                nav = Self.mobiNavChapters(for: book, model: model)
            }
            if !nav.isEmpty { return nav }
            guard let model else { return [] }
            return Self.textChapters(from: model)
        default:
            guard let model = textModel(for: book) else { return [] }
            return Self.textChapters(from: model)
        }
    }

    /// Builds the nested table of contents from an EPUB NCX file or EPUB 3
    /// navigation document. Href fragments become anchors in the merged
    /// reader page; entries without a fragment fall back to the character
    /// progress of their spine document.
    private static func epubNavChapters(
        for book: LibraryBook,
        model: ZenReaderTextModel?
    ) -> [ReaderChapter] {
        let url = URL(fileURLWithPath: book.path)
        let parsedPackage: (
            manifest: [String: String],
            spine: [String],
            properties: [String: String],
            mediaTypes: [String: String],
            spineTOC: String?
        )
        let opfDirectory: String
        let readData: (String) -> Data?
        if BookImporter.isEPUBPackage(at: url) {
            guard let containerData = try? Data(
                    contentsOf: url.appendingPathComponent("META-INF/container.xml")
                  ),
                  let rootFilePath = BookImporter.epubContainerRootFilePath(from: containerData),
                  let opfData = try? Data(contentsOf: url.appendingPathComponent(rootFilePath)),
                  let package = BookImporter.epubPackage(from: opfData) else {
                return []
            }
            parsedPackage = package
            opfDirectory = (rootFilePath as NSString).deletingLastPathComponent
            readData = { path in try? Data(contentsOf: url.appendingPathComponent(path)) }
        } else {
            guard let archive = try? ZipArchive(url: url),
                  let containerData = try? archive.contents(of: "META-INF/container.xml"),
                  let rootFilePath = BookImporter.epubContainerRootFilePath(from: containerData),
                  let opfData = try? archive.contents(of: rootFilePath),
                  let package = BookImporter.epubPackage(from: opfData) else {
                return []
            }
            parsedPackage = package
            opfDirectory = (rootFilePath as NSString).deletingLastPathComponent
            readData = { path in try? archive.contents(of: path) }
        }

        // Prefer the EPUB 3 navigation document, then the NCX declared by the
        // spine, then any NCX in the manifest.
        var navHref: String?
        var prefersHTMLNav = false
        if let id = parsedPackage.manifest.keys.first(where: { id in
            (parsedPackage.properties[id] ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .contains("nav")
        }) {
            navHref = parsedPackage.manifest[id]
            prefersHTMLNav = true
        }
        if navHref == nil, let tocID = parsedPackage.spineTOC {
            navHref = parsedPackage.manifest[tocID]
        }
        if navHref == nil,
           let ncxID = parsedPackage.mediaTypes.first(where: {
               $0.value.lowercased() == "application/x-dtbncx+xml"
           })?.key {
            navHref = parsedPackage.manifest[ncxID]
        }
        guard let navHref, !navHref.isEmpty else { return [] }

        func archivePath(for href: String, relativeTo baseDirectory: String) -> String {
            var value = href.removingPercentEncoding ?? href
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash])
            }
            if let query = value.firstIndex(of: "?") {
                value = String(value[..<query])
            }
            if value.hasPrefix("/") {
                value.removeFirst()
            } else if !baseDirectory.isEmpty {
                value = baseDirectory + "/" + value
            }
            return BookImporter.normalizedEPUBPath(value)
        }

        let navPath = archivePath(for: navHref, relativeTo: opfDirectory)
        guard let navData = readData(navPath) else { return [] }
        let navDirectory = (navPath as NSString).deletingLastPathComponent
        let isHTMLNav = prefersHTMLNav || ["html", "xhtml", "htm"].contains(
            (navPath as NSString).pathExtension.lowercased()
        )

        var roots: [EPUBNavNode] = []
        if isHTMLNav {
            let parser = EPUBHTMLNavParser()
            let xml = XMLParser(data: navData)
            xml.delegate = parser
            _ = xml.parse()
            roots = parser.roots
        }
        if roots.isEmpty {
            let parser = EPUBNCXParser()
            let xml = XMLParser(data: navData)
            xml.delegate = parser
            _ = xml.parse()
            roots = parser.roots
        }
        guard !roots.isEmpty else { return [] }

        var spineIndexByPath: [String: Int] = [:]
        for (index, idref) in parsedPackage.spine.enumerated() {
            guard let href = parsedPackage.manifest[idref] else { continue }
            let path = archivePath(for: href, relativeTo: opfDirectory)
            if spineIndexByPath[path] == nil {
                spineIndexByPath[path] = index
            }
        }
        let totalLength = model?.totalLength ?? 0

        func progress(forSpineIndex index: Int) -> Double? {
            guard let model, totalLength > 0,
                  index >= 0, index < model.chapters.count else { return nil }
            return min(
                max(Double(model.chapters[index].start) / Double(totalLength), 0),
                1
            )
        }

        func convert(_ nodes: [EPUBNavNode]) -> [ReaderChapter] {
            nodes.compactMap { node in
                let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let children = convert(node.children)
                guard !title.isEmpty || !children.isEmpty else { return nil }
                var anchorID: String?
                var progressValue: Double?
                if let href = node.href, !href.isEmpty {
                    var target = href
                    if let hash = href.firstIndex(of: "#") {
                        let fragment = String(href[href.index(after: hash)...])
                        target = String(href[..<hash])
                        if !fragment.isEmpty {
                            anchorID = fragment.removingPercentEncoding ?? fragment
                        }
                    }
                    if !target.isEmpty {
                        let path = archivePath(for: target, relativeTo: navDirectory)
                        if let index = spineIndexByPath[path] {
                            progressValue = progress(forSpineIndex: index)
                        }
                    }
                }
                let resolvedTitle = title.isEmpty
                    ? (children.first?.title ?? L("未命名章节", "Untitled chapter"))
                    : title
                return ReaderChapter(
                    title: resolvedTitle,
                    progress: progressValue,
                    anchorID: anchorID,
                    pageIndex: nil,
                    level: 0,
                    locatorText: nil,
                    children: children
                )
            }
        }
        return convert(roots)
    }

    /// Builds a nested table of contents from the HTML table-of-contents page
    /// of a MOBI/AZW book. Mobipocket collections put one book per top-level
    /// paragraph and their chapters in nested `<blockquote>` blocks, all
    /// linked to exact `filepos` anchors.
    private static func mobiNavChapters(
        for book: LibraryBook,
        model: ZenReaderTextModel?
    ) -> [ReaderChapter] {
        let url = URL(fileURLWithPath: book.path)
        guard let mobi = try? MOBIParser.parseTextOnly(url: url), !mobi.parts.isEmpty,
              let tocIndex = mobiTOCPartIndex(in: mobi.parts) else {
            return []
        }
        let tocHTML = mobi.parts[tocIndex]
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<(/?)(blockquote)\b[^>]*>|<a\b[^>]*?href\s*=\s*["']#(filepos\d+)["'][^>]*>(.*?)</a>"#
        ) else { return [] }

        let nsTOC = tocHTML as NSString
        let matches = regex.matches(in: tocHTML, range: NSRange(location: 0, length: nsTOC.length))
        var roots: [EPUBNavNode] = []
        var stack: [EPUBNavNode?] = []
        var depth = 0
        var linkedAnchors = Set<String>()
        for match in matches {
            if match.range(at: 2).location != NSNotFound {
                let closing = nsTOC.substring(with: match.range(at: 1)) == "/"
                depth = closing ? max(0, depth - 1) : depth + 1
                continue
            }
            guard match.range(at: 3).location != NSNotFound,
                  match.range(at: 4).location != NSNotFound else { continue }
            let anchor = nsTOC.substring(with: match.range(at: 3))
            let title = mobiNavTitle(nsTOC.substring(with: match.range(at: 4)))
            guard !title.isEmpty else { continue }
            linkedAnchors.insert(anchor)
            let node = EPUBNavNode(title: title, href: "#\(anchor)")
            var parent: EPUBNavNode?
            var parentDepth = depth - 1
            while parentDepth >= 0 {
                if parentDepth < stack.count, let candidate = stack[parentDepth] {
                    parent = candidate
                    break
                }
                parentDepth -= 1
            }
            if let parent {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            while stack.count <= depth { stack.append(nil) }
            stack[depth] = node
            if stack.count > depth + 1 {
                stack.removeSubrange((depth + 1)...)
            }
        }
        guard !roots.isEmpty else { return [] }

        var anchorProgress: [String: Double] = [:]
        if !linkedAnchors.isEmpty,
           let partStarts = ZenTextLocator.mobiPartStarts(at: url),
           partStarts.totalLength > 0,
           let anchorRegex = try? NSRegularExpression(
               pattern: #"(?i)<a\b[^>]*\bid\s*=\s*["'](filepos\d+)["'][^>]*>"#
           ) {
            for (index, part) in mobi.parts.enumerated() {
                guard partStarts.starts.indices.contains(index),
                      let partStart = partStarts.starts[index] else { continue }
                let nsPart = part as NSString
                let anchorMatches = anchorRegex.matches(
                    in: part,
                    range: NSRange(location: 0, length: nsPart.length)
                )
                for match in anchorMatches {
                    let name = nsPart.substring(with: match.range(at: 1))
                    guard linkedAnchors.contains(name), anchorProgress[name] == nil else { continue }
                    let prefix = nsPart.substring(to: match.range.location)
                    let offset = (ZenTextLocator.plainText(fromHTML: prefix) as NSString).length
                    let value = Double(partStart + offset) / Double(partStarts.totalLength)
                    anchorProgress[name] = min(max(value, 0), 1)
                }
            }
        }

        func convert(_ nodes: [EPUBNavNode]) -> [ReaderChapter] {
            nodes.map { node in
                let anchor = node.href.flatMap { href -> String? in
                    href.hasPrefix("#") ? String(href.dropFirst()) : nil
                }
                return ReaderChapter(
                    title: node.title,
                    progress: anchor.flatMap { anchorProgress[$0] },
                    anchorID: anchor,
                    pageIndex: nil,
                    level: 0,
                    locatorText: nil,
                    children: convert(node.children)
                )
            }
        }
        return convert(roots)
    }

    /// Locates the table-of-contents document in a decoded MOBI. The guide's
    /// `type="toc"` reference is authoritative; without one, the part with
    /// the most `filepos` links is used so a chapter's previous/next links
    /// are not mistaken for contents.
    private static func mobiTOCPartIndex(in parts: [String]) -> Int? {
        let linkRegex = try? NSRegularExpression(
            pattern: #"(?i)href\s*=\s*["']#filepos\d+["']"#
        )
        func linkCount(_ text: String) -> Int {
            guard let linkRegex else { return 0 }
            let ns = text as NSString
            return linkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).count
        }
        func partContaining(anchor: String) -> Int? {
            let doubleQuoted = "id=\"\(anchor)\""
            let singleQuoted = "id='\(anchor)'"
            for (index, part) in parts.enumerated() {
                if part.contains(doubleQuoted) || part.contains(singleQuoted) {
                    return index
                }
            }
            return nil
        }

        let referenceRegex = try? NSRegularExpression(
            pattern: #"(?is)<reference\b[^>]*\btype\s*=\s*["']toc["'][^>]*>"#
        )
        let hrefRegex = try? NSRegularExpression(
            pattern: #"(?i)\bhref\s*=\s*["']#(filepos\d+)["']"#
        )
        if let referenceRegex, let hrefRegex {
            for part in parts {
                let nsPart = part as NSString
                let references = referenceRegex.matches(
                    in: part,
                    range: NSRange(location: 0, length: nsPart.length)
                )
                for reference in references {
                    let tag = nsPart.substring(with: reference.range)
                    let nsTag = tag as NSString
                    guard let href = hrefRegex.firstMatch(
                            in: tag,
                            range: NSRange(location: 0, length: nsTag.length)
                          ) else { continue }
                    let anchor = nsTag.substring(with: href.range(at: 1))
                    if let index = partContaining(anchor: anchor), linkCount(parts[index]) >= 4 {
                        return index
                    }
                }
            }
        }

        var best: (index: Int, count: Int)?
        for (index, part) in parts.enumerated() {
            let count = linkCount(part)
            guard count >= 8 else { continue }
            if best == nil || count > best!.count {
                best = (index, count)
            }
        }
        return best?.index
    }

    private static func mobiNavTitle(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        text = ZenTextLocator.decodeHTMLEntities(text)
        text = text.replacingOccurrences(
            of: #"[\t\r\n ]+"#,
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textChapters(from model: ZenReaderTextModel) -> [ReaderChapter] {
        guard model.totalLength > 0, !model.chapters.isEmpty else { return [] }
        return model.chapters.enumerated().map { index, chapter in
            let progress = min(
                max(Double(chapter.start) / Double(model.totalLength), 0),
                1
            )
            let fullText = (chapter.text as String)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let firstLine = fullText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            return ReaderChapter(
                title: chapterTitle(from: fullText, index: index),
                progress: progress,
                anchorID: nil,
                pageIndex: nil,
                level: 0,
                locatorText: firstLine.count > 0 && firstLine.count <= 60 ? firstLine : nil
            )
        }
    }

    private static func chapterTitle(from text: String, index: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > 64 {
                return String(trimmed.prefix(64)) + "…"
            }
            return trimmed
        }
        return L("第 \(index + 1) 节", "Section \(index + 1)")
    }

    private static func markdownChapters(for book: LibraryBook) -> [ReaderChapter] {
        guard let text = try? BookImporter.plainText(from: URL(fileURLWithPath: book.path)) else {
            return []
        }
        return MarkdownRenderer.outline(from: text).map { heading in
            ReaderChapter(
                title: heading.title.isEmpty ? L("未命名标题", "Untitled") : heading.title,
                progress: nil,
                anchorID: heading.identifier,
                pageIndex: nil,
                level: max(heading.level - 1, 0)
            )
        }
    }

    private static func pdfChapters(for book: LibraryBook) -> [ReaderChapter] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: book.path)),
              let root = document.outlineRoot else {
            return []
        }
        var chapters: [ReaderChapter] = []

        func walk(_ outline: PDFOutline, level: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                var page: PDFPage?
                if let destination = child.destination {
                    page = destination.page
                }
                if page == nil, let action = child.action as? PDFActionGoTo {
                    page = action.destination.page
                }
                if let page {
                    let pageIndex = document.index(for: page)
                    if pageIndex >= 0, pageIndex < document.pageCount {
                        let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let progress = document.pageCount > 1
                            ? Double(pageIndex) / Double(document.pageCount - 1)
                            : 0
                        chapters.append(ReaderChapter(
                            title: title.isEmpty
                                ? L("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)")
                                : title,
                            progress: progress,
                            anchorID: nil,
                            pageIndex: pageIndex,
                            level: level
                        ))
                    }
                }
                walk(child, level: level + 1)
            }
        }

        walk(root, level: 0)
        return chapters
    }

    private func storeTextModel(
        _ model: ZenReaderTextModel,
        path: String,
        size: Int64,
        modified: Date
    ) {
        textModelLock.lock()
        if textModelCache.count >= 8 {
            textModelCache.removeAll()
        }
        textModelCache[path] = CachedTextModel(size: size, modified: modified, model: model)
        textModelLock.unlock()
    }

    /// The percentage ZenReader itself would report for this local position.
    /// It only uses a chapter table that this launch has already built (during
    /// a sync), so shelf refreshes never block on parsing a MOBI book.
    func cachedZenPercent(for book: LibraryBook, progress: Double) -> Double? {
        let clamped = min(max(progress, 0), 1)
        if book.format == "PDF" {
            guard let count = Self.cachedPDFPageCount(for: book), count > 1 else { return nil }
            let index = min(max(Int((clamped * Double(count - 1)).rounded()), 0), count - 1)
            return min(max(Double(index + 1) / Double(count), 0), 1)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: book.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        textModelLock.lock()
        guard let cached = textModelCache[book.path],
              cached.size == size,
              cached.modified == modified else {
            textModelLock.unlock()
            return nil
        }
        let model = cached.model
        textModelLock.unlock()

        if let anchor = book.localTextAnchor,
           !anchor.isEmpty,
           let anchorProgress = book.localTextAnchorProgress,
           abs(anchorProgress - clamped) <= 0.01,
           let payload = ZenTextLocator.locate(readText: anchor, near: clamped, model: model) {
            return min(max(payload.percent / 100, 0), 1)
        }
        if let anchor = book.zenLocatorText,
           !anchor.isEmpty,
           let anchorProgress = book.zenLocatorAnchor,
           abs(anchorProgress - clamped) <= 0.01,
           let payload = ZenTextLocator.locate(readText: anchor, near: clamped, model: model) {
            return min(max(payload.percent / 100, 0), 1)
        }
        guard let payload = ZenTextLocator.locate(progress: clamped, model: model) else {
            return nil
        }
        return min(max(payload.percent / 100, 0), 1)
    }

    private static func snapshotName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func date(fromSnapshotName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.date(from: name)
    }
}

enum ShelfDisplayMode: String {
    case list
    case covers
}

/// Shared behavior for both shelf presentations: selection, hover, context
/// menu and theming. The list row and the cover cell only contribute their
/// own content views.
class ShelfBookButton: NSButton {
    private(set) var book: LibraryBook
    var onSelect: ((LibraryBook) -> Void)?
    var onEditMetadata: ((LibraryBook) -> Void)?
    var onRemove: ((LibraryBook) -> Void)?
    var onRemoveFromCloud: ((LibraryBook) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var isHovered = false
    var isDark = false

    var hoverBackgroundColor: NSColor {
        isDark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.89, alpha: 1)
    }

    init(book: LibraryBook) {
        self.book = book
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
        menu.addItem(withTitle: L("在访达中显示", "Show in Finder"), action: #selector(revealInFinderRequested), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("从书架移除", "Remove from Library"), action: #selector(removeRequested), keyEquivalent: "")
        if book.source == .jianguoyun {
            menu.addItem(withTitle: L("从 WebDAV 删除并移出书架", "Delete from WebDAV & Remove"), action: #selector(removeFromCloudRequested), keyEquivalent: "")
        } else if FolderLibraryStore.shared.contains(URL(fileURLWithPath: book.path)) {
            if book.source == .iCloud {
                menu.addItem(withTitle: L("从 iCloud 删除并移出书架", "Delete from iCloud & Remove"), action: #selector(removeFromCloudRequested), keyEquivalent: "")
            } else {
                menu.addItem(withTitle: L("从书库文件夹删除并移出书架", "Delete from Library Folder & Remove"), action: #selector(removeFromCloudRequested), keyEquivalent: "")
            }
        }
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func editMetadataRequested() {
        onEditMetadata?(book)
    }

    @objc private func revealInFinderRequested() {
        let url = URL(fileURLWithPath: book.path)
        guard FileManager.default.fileExists(atPath: book.path) else {
            let alert = NSAlert()
            alert.messageText = L("找不到书籍文件", "Book file not found")
            alert.informativeText = L(
                "文件可能已被移动或删除：\n\(book.path)",
                "The file may have been moved or deleted:\n\(book.path)"
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("好", "OK"))
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
        updateAppearance()
        layer?.backgroundColor = isHovered
            ? hoverBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }

    /// Subclasses recolor their own content.
    func updateAppearance() {}

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
        NSSize(width: NSView.noIntrinsicMetric, height: 72)
    }

    func update(book: LibraryBook) {
        self.book = book
        updateContent()
    }

    func updateContent() {}

    static func progressText(_ progress: Double) -> String {
        progress <= 0 ? L("未开始", "Not started") : "\(Int(progress * 100))%"
    }

    static func authorText(for book: LibraryBook) -> String {
        book.author.isEmpty ? L("作者未设置", "Author not set") : book.author
    }
}

final class BookRowButton: ShelfBookButton {
    static let rowHeight: CGFloat = 72

    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    override init(book: LibraryBook) {
        titleLabel = NSTextField(labelWithString: book.title)
        detailLabel = NSTextField(labelWithString: Self.detailText(for: book))
        super.init(book: book)

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
        updateContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateAppearance() {
        titleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.18, alpha: 1)
        detailLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.58, alpha: 1)
            : NSColor(calibratedWhite: 0.44, alpha: 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    override func updateContent() {
        titleLabel.stringValue = book.title
        detailLabel.stringValue = Self.detailText(for: book)
    }

    private static func detailText(for book: LibraryBook) -> String {
        let author = book.author.isEmpty
            ? L("作者未设置", "Author not set")
            : L("作者：\(book.author)", "By \(book.author)")
        // Jianguoyun books show ZenReader's own percentage after a sync so the
        // Mac and the phone report the same number. The local anchor stays in
        // `progress` and is still used to open the book at the right place.
        let shown = book.source == .jianguoyun ? (book.zenProgress ?? book.progress) : book.progress
        return "\(author)\n\(book.source.title)  ·  \(book.format)  ·  \(progressText(shown))"
    }
}

/// Grid cell of the cover shelf. Each cell reads top to bottom as cover,
/// title with author, then reading progress. Covers are requested only after
/// the cell scrolls into view, so a large library does not extract every
/// cover at once.
final class BookCoverButton: ShelfBookButton {
    private let coverBackground = NSView()
    private let formatBadge = NSView()
    private let formatLabel = NSTextField(labelWithString: "")
    private let coverImageView = NSImageView()
    private let titleLabel: NSTextField
    private let authorLabel: NSTextField
    private let progressLabel: NSTextField
    private var isLoadingCover = false
    private var hasLoadedCover = false

    private static let titleHeight: CGFloat = 30
    private static let authorHeight: CGFloat = 13
    private static let progressHeight: CGFloat = 13
    private static let textSpacing: CGFloat = 5
    private static let coverAspect: CGFloat = 1.5
    private static let badgeHeight: CGFloat = 19
    private static let badgeInset: CGFloat = 8

    override init(book: LibraryBook) {
        titleLabel = NSTextField(wrappingLabelWithString: book.title)
        authorLabel = NSTextField(labelWithString: Self.authorText(for: book))
        progressLabel = NSTextField(labelWithString: Self.progressLine(for: book))
        super.init(book: book)
        layer?.cornerRadius = 8

        coverBackground.wantsLayer = true
        coverBackground.layer?.cornerRadius = 5
        coverBackground.layer?.masksToBounds = true
        addSubview(coverBackground)

        coverImageView.imageScaling = .scaleProportionallyUpOrDown
        coverImageView.imageAlignment = .alignCenter
        coverImageView.wantsLayer = true
        coverImageView.layer?.cornerRadius = 5
        coverImageView.layer?.masksToBounds = true
        coverImageView.layer?.borderWidth = 1
        coverImageView.alphaValue = 1
        addSubview(coverImageView)

        // Every cover carries the same format badge in its bottom-left
        // corner, so plain title cards and real artwork read alike.
        formatBadge.wantsLayer = true
        formatBadge.layer?.cornerRadius = 4
        formatBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.66).cgColor
        formatLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        formatLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        formatLabel.alignment = .center
        formatLabel.isSelectable = false
        formatLabel.isEditable = false
        formatLabel.isBezeled = false
        formatLabel.isBordered = false
        formatLabel.drawsBackground = false
        formatBadge.addSubview(formatLabel)
        addSubview(formatBadge)

        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.usesSingleLineMode = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.isSelectable = false
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        authorLabel.font = NSFont.systemFont(ofSize: 9.5)
        authorLabel.alignment = .center
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.isSelectable = false
        authorLabel.isEditable = false
        authorLabel.isBezeled = false
        authorLabel.isBordered = false
        authorLabel.drawsBackground = false
        addSubview(authorLabel)

        progressLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        progressLabel.alignment = .center
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.maximumNumberOfLines = 1
        progressLabel.isSelectable = false
        progressLabel.isEditable = false
        progressLabel.isBezeled = false
        progressLabel.isBordered = false
        progressLabel.drawsBackground = false
        addSubview(progressLabel)

        updateContent()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func height(forWidth width: CGFloat) -> CGFloat {
        let cover = max(width * coverAspect, 1)
        return cover + textSpacing + titleHeight + 1 + authorHeight + 1 + progressHeight + 4
    }

    override func layout() {
        super.layout()
        // NSButton is flipped, so y grows downward from the top edge.
        let coverHeight = max(bounds.width * Self.coverAspect, 1)
        let coverRect = NSRect(x: 0, y: 0, width: bounds.width, height: coverHeight)
        coverBackground.frame = coverRect
        coverImageView.frame = coverRect
        let badgeWidth = max(ceil(formatLabel.intrinsicContentSize.width) + 12, 26)
        formatBadge.frame = NSRect(
            x: Self.badgeInset,
            y: coverRect.maxY - Self.badgeInset - Self.badgeHeight,
            width: badgeWidth,
            height: Self.badgeHeight
        )
        formatLabel.frame = NSRect(
            x: 6,
            y: (Self.badgeHeight - 14) / 2,
            width: max(badgeWidth - 12, 1),
            height: 14
        )
        let titleY = coverRect.maxY + Self.textSpacing
        titleLabel.frame = NSRect(
            x: 2,
            y: titleY,
            width: max(bounds.width - 4, 1),
            height: Self.titleHeight
        )
        let authorY = titleY + Self.titleHeight + 1
        authorLabel.frame = NSRect(
            x: 2,
            y: authorY,
            width: max(bounds.width - 4, 1),
            height: Self.authorHeight
        )
        progressLabel.frame = NSRect(
            x: 2,
            y: authorY + Self.authorHeight + 1,
            width: max(bounds.width - 4, 1),
            height: Self.progressHeight
        )
    }

    override func updateAppearance() {
        coverBackground.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.9, alpha: 1)).cgColor
        coverImageView.layer?.borderColor = (isDark
            ? NSColor(calibratedWhite: 0.31, alpha: 1)
            : NSColor(calibratedWhite: 0.83, alpha: 1)).cgColor
        titleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.18, alpha: 1)
        authorLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.58, alpha: 1)
            : NSColor(calibratedWhite: 0.44, alpha: 1)
        progressLabel.textColor = shownProgress > 0
            ? (isDark
                ? NSColor(calibratedRed: 0.56, green: 0.78, blue: 0.66, alpha: 1)
                : NSColor(calibratedRed: 0.22, green: 0.46, blue: 0.36, alpha: 1))
            : (isDark
                ? NSColor(calibratedWhite: 0.5, alpha: 1)
                : NSColor(calibratedWhite: 0.52, alpha: 1))
    }

    override func updateContent() {
        titleLabel.stringValue = book.title
        authorLabel.stringValue = Self.authorText(for: book)
        progressLabel.stringValue = Self.progressLine(for: book)
        formatLabel.stringValue = book.format.uppercased()
        toolTip = "\(book.title)\n\(Self.authorText(for: book))\n\(book.source.title) · \(book.format) · \(Self.progressLine(for: book))"
        updateAppearance()
    }

    override func update(book newBook: LibraryBook) {
        let needsNewCover = book.title != newBook.title
            || book.path != newBook.path
            || book.format != newBook.format
        super.update(book: newBook)
        if needsNewCover {
            hasLoadedCover = false
            isLoadingCover = false
            coverImageView.image = nil
            loadCoverIfNeeded()
        }
    }

    /// Called by the sidebar once the cell is inside the visible scroll area.
    func loadCoverIfNeeded() {
        guard !hasLoadedCover, !isLoadingCover else { return }
        isLoadingCover = true
        let requestedBook = book
        BookCoverLoader.cover(for: requestedBook) { [weak self] image in
            guard let self, self.book.id == requestedBook.id else { return }
            self.isLoadingCover = false
            self.hasLoadedCover = image != nil
            guard let image else { return }
            self.coverImageView.image = image
            self.coverImageView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.coverImageView.animator().alphaValue = 1
            }
        }
    }

    private var shownProgress: Double {
        book.source == .jianguoyun ? (book.zenProgress ?? book.progress) : book.progress
    }

    private static func progressLine(for book: LibraryBook) -> String {
        let shown = book.source == .jianguoyun ? (book.zenProgress ?? book.progress) : book.progress
        let percent = Int((shown * 100).rounded())
        if percent <= 0 {
            return L("未开始", "Not started")
        }
        return L("已读 \(percent)%", "\(percent)% read")
    }
}

enum FolderLibraryStatus {
    case ready
    case scanning
    case scanned(count: Int, folderName: String, path: String)
    case folderMissing(path: String?)
    case folderChosen(name: String, path: String)
    case booksAdded(count: Int)

    var text: String {
        switch self {
        case .ready:
            return L("书库：准备扫描", "Library: Ready to scan")
        case .scanning:
            return L("书库：正在扫描文件夹…", "Library: Scanning folder…")
        case .scanned(let count, let folderName, _):
            if count == 0 {
                return L("书库：\(folderName) 里没有找到书",
                         "Library: No books found in \(folderName)")
            }
            return count == 1
                ? L("书库：\(folderName) · 1 本", "Library: \(folderName) · 1 book")
                : L("书库：\(folderName) · \(count) 本", "Library: \(folderName) · \(count) books")
        case .folderMissing(let path):
            if let path {
                return L("书库：文件夹不存在（\(path)），请重新选择",
                         "Library: Folder not found (\(path)). Choose it again.")
            }
            return L("书库：文件夹不存在，请重新选择",
                     "Library: Folder not found. Choose it again.")
        case .folderChosen(let name, _):
            return L("书库：已选择 \(name)", "Library: Selected \(name)")
        case .booksAdded(let count):
            return count == 1
                ? L("书库：已加入 1 本书", "Library: Added 1 book")
                : L("书库：已加入 \(count) 本书", "Library: Added \(count) books")
        }
    }

    var shortText: String {
        switch self {
        case .ready:
            return L("准备扫描", "Ready to scan")
        case .scanning:
            return L("正在扫描…", "Scanning…")
        case .scanned(let count, let folderName, _):
            if count == 0 {
                return L("\(folderName)：没有书", "\(folderName): No books")
            }
            return count == 1
                ? L("\(folderName) · 1 本", "\(folderName) · 1 book")
                : L("\(folderName) · \(count) 本", "\(folderName) · \(count) books")
        case .folderMissing:
            return L("文件夹不存在", "Folder not found")
        case .folderChosen(let name, _):
            return L("已选择 \(name)", "Selected \(name)")
        case .booksAdded(let count):
            return count == 1
                ? L("已加入 1 本", "1 book added")
                : L("已加入 \(count) 本", "\(count) books added")
        }
    }

    var detail: String? {
        switch self {
        case .scanned(_, _, let path), .folderChosen(_, let path):
            return path
        case .folderMissing(let path):
            return path
        case .ready, .scanning, .booksAdded:
            return nil
        }
    }
}

/// Fine-grained phase of a Jianguoyun sync. The sidebar and settings window
/// show this while work is running, so “syncing” is distinguishable from a
/// finished sync at a glance.
enum ZenSyncStage {
    case checking
    case downloading(done: Int, total: Int)
    case preparing
    case uploading(done: Int, total: Int)
    case writingSnapshot

    var shortText: String {
        switch self {
        case .checking:
            return L("正在检查云端…", "Checking the cloud…")
        case .downloading(let done, let total):
            if total <= 0 { return L("正在下载…", "Downloading…") }
            if done <= 0 { return L("正在下载 \(total) 本书…", "Downloading \(total) books…") }
            return L("正在下载 \(done)/\(total)…", "Downloading \(done)/\(total)…")
        case .preparing:
            return L("正在整理阅读进度…", "Preparing reading positions…")
        case .uploading(let done, let total):
            if total <= 0 { return L("正在上传…", "Uploading…") }
            if done <= 0 { return L("正在上传 \(total) 本书…", "Uploading \(total) books…") }
            return L("正在上传 \(done)/\(total)…", "Uploading \(done)/\(total)…")
        case .writingSnapshot:
            return L("正在写入云端快照…", "Writing cloud snapshot…")
        }
    }

    var text: String {
        L("书籍与进度：\(shortText)", "Books & progress: \(shortText)")
    }
}

enum ZenSyncStatus {
    case notConfigured
    case needsPassword
    case ready(lastSync: Date?)
    case syncing(stage: ZenSyncStage)
    case upToDate(matched: Int)
    case completed(pulled: Int, pushed: Int, matched: Int)
    case notice(String)
    case warning(summary: String, detail: String)
    case failed(String)

    private static func lastSyncText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    var text: String {
        switch self {
        case .notConfigured:
            return L("书籍与进度：未设置", "Books & progress: Not set")
        case .needsPassword:
            return L("书籍与进度：需要在设置里填写应用密码",
                     "Books & progress: Enter the app password in settings")
        case .ready(let lastSync):
            if let lastSync {
                return L("书籍与进度：上次同步 \(Self.lastSyncText(lastSync))",
                         "Books & progress: Last synced \(Self.lastSyncText(lastSync))")
            }
            return L("书籍与进度：准备同步", "Books & progress: Ready")
        case .syncing(let stage):
            return stage.text
        case .upToDate(let matched):
            if matched == 0 {
                return L("书籍与进度：没有匹配到书", "Books & progress: No matching books")
            }
            return L("书籍与进度：已是最新（\(matched) 本）", "Books & progress: Up to date (\(matched) books)")
        case .completed(let pulled, let pushed, let matched):
            if pulled == 0 && pushed == 0 {
                return L("书籍与进度：已是最新（\(matched) 本）", "Books & progress: Up to date (\(matched) books)")
            }
            if matched == 0 {
                return L("书籍与进度：没有匹配到书", "Books & progress: No matching books")
            }
            var parts: [String] = []
            if pulled > 0 {
                parts.append(L("更新 \(pulled) 本", "\(pulled) updated"))
            }
            if pushed > 0 {
                parts.append(L("上传 \(pushed) 本", "\(pushed) uploaded"))
            }
            return L("书籍与进度：\(parts.joined(separator: "，"))", "Books & progress: \(parts.joined(separator: ", "))")
        case .notice(let message):
            return message
        case .warning(let summary, _):
            return summary
        case .failed:
            return L("书籍与进度：同步失败", "Books & progress: Sync failed")
        }
    }

    var shortText: String {
        switch self {
        case .notConfigured:
            return L("未设置", "Not set")
        case .needsPassword:
            return L("需要应用密码", "Password needed")
        case .ready(let lastSync):
            if let lastSync {
                return L("上次同步 \(Self.lastSyncText(lastSync))",
                         "Last sync \(Self.lastSyncText(lastSync))")
            }
            return L("准备同步", "Ready to sync")
        case .syncing(let stage):
            return stage.shortText
        case .upToDate(let matched):
            if matched == 0 {
                return L("同步完成 · 没有匹配到书", "Sync complete · No matching books")
            }
            return L("同步完成 · 已是最新（\(matched) 本）",
                     "Sync complete · Up to date (\(matched) books)")
        case .completed(let pulled, let pushed, let matched):
            if matched == 0 {
                return L("同步完成 · 没有匹配到书", "Sync complete · No matching books")
            }
            var parts: [String] = []
            if pulled > 0 {
                parts.append(L("更新 \(pulled) 本", "\(pulled) updated"))
            }
            if pushed > 0 {
                parts.append(L("上传 \(pushed) 本", "\(pushed) uploaded"))
            }
            if parts.isEmpty {
                return L("同步完成 · 已是最新（\(matched) 本）",
                         "Sync complete · Up to date (\(matched) books)")
            }
            return L("同步完成 · \(parts.joined(separator: "，"))",
                     "Sync complete · \(parts.joined(separator: ", "))")
        case .notice(let message):
            return message
        case .warning(let summary, _):
            return summary
        case .failed:
            return L("同步失败", "Sync failed")
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message):
            return message
        case .warning(_, let detail):
            return detail
        case .needsPassword:
            return L("在同步设置里输入一次 WebDAV 密码并保存即可；EasyRead 只做静默读取，不会再弹出系统钥匙串授权窗口。",
                     "Enter the WebDAV password once in sync settings and save. EasyRead reads it silently and will not show the macOS keychain authorization dialog again.")
        default:
            return nil
        }
    }
}

final class SidebarViewController: NSViewController {
    var books: [LibraryBook] = []
    var onImport: (() -> Void)?
    var onSync: (() -> Void)?
    var onUpload: (() -> Void)?
    var onDownload: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSelect: ((LibraryBook) -> Void)?
    var onDelete: ((LibraryBook) -> Void)?
    var onEditMetadata: ((LibraryBook) -> Void)?
    var onDeleteFromCloud: ((LibraryBook) -> Void)?
    var onZenSettings: (() -> Void)?
    var onClearLibrary: (() -> Void)?
    var onSwitchLibrary: ((LibraryShelf) -> Void)?
    var onShowPro: (() -> Void)?

    private(set) var activeShelf: LibraryShelf = .folder
    private var isProUnlocked = false

    private let scrollView = NSScrollView()
    private let listContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: L("简阅", "EasyRead"))
    private let clearLibraryButton = NSButton()
    private let hideSidebarButton = NSButton()
    private let libraryBar = NSView()
    private let libraryIcon = NSImageView()
    private let libraryTitleLabel = NSTextField(labelWithString: "")
    private let libraryStatusLabel = NSTextField(labelWithString: "")
    private let syncSpinner = NSProgressIndicator()
    private let libraryChevron = NSImageView()
    private let libraryClickButton = NSButton()
    private let syncButton = NSButton()
    private let uploadButton = NSButton()
    private let downloadButton = NSButton()
    private let accessoryButton = NSButton()
    private var syncButtonWidthConstraint: NSLayoutConstraint!
    private var uploadButtonWidthConstraint: NSLayoutConstraint!
    private var downloadButtonWidthConstraint: NSLayoutConstraint!
    private let toolbarDivider = NSView()
    private let libraryCountLabel = NSTextField(labelWithString: "")
    private let importButton = NSButton()
    private let layoutButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "TXT · MD · EPUB · PDF · MOBI · AZW3")
    private let languageButton = NSButton()
    private var rowsByBookID: [UUID: ShelfBookButton] = [:]
    private var hoveredRow: ShelfBookButton?
    private var pendingScrollToTop = false
    private var displayMode: ShelfDisplayMode = {
        let stored = UserDefaults.standard.string(forKey: "ShelfDisplayMode") ?? ""
        return ShelfDisplayMode(rawValue: stored) ?? .list
    }()
    private var scrollObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var isDark = false
    private var hasAppliedTheme = false
    private var folderStatus: FolderLibraryStatus = .ready
    private var zenStatus: ZenSyncStatus = .notConfigured

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
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        clearLibraryButton.title = L("清理书架", "Clear Shelf")
        clearLibraryButton.target = self
        clearLibraryButton.action = #selector(clearLibraryClicked)
        clearLibraryButton.bezelStyle = .rounded
        clearLibraryButton.controlSize = .small
        clearLibraryButton.font = NSFont.systemFont(ofSize: 11)
        clearLibraryButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearLibraryButton.imagePosition = .imageLeading
        clearLibraryButton.toolTip = L("只清理当前书库的书架记录，不删除任何书籍文件",
                                       "Clears only the current library's shelf records; book files are never deleted")

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

        libraryBar.wantsLayer = true
        libraryBar.layer?.cornerRadius = 9
        libraryBar.layer?.borderWidth = 1
        libraryBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.995, alpha: 1).cgColor
        libraryBar.layer?.borderColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor

        libraryIcon.imageScaling = .scaleProportionallyDown
        libraryIcon.contentTintColor = NSColor(calibratedWhite: 0.42, alpha: 1)

        libraryTitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        libraryTitleLabel.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        libraryTitleLabel.lineBreakMode = .byTruncatingTail
        libraryTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        libraryStatusLabel.font = NSFont.systemFont(ofSize: 10)
        libraryStatusLabel.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
        libraryStatusLabel.lineBreakMode = .byTruncatingTail
        libraryStatusLabel.maximumNumberOfLines = 2
        libraryStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false
        syncSpinner.isHidden = true

        libraryChevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        libraryChevron.imageScaling = .scaleProportionallyDown
        libraryChevron.contentTintColor = NSColor(calibratedWhite: 0.48, alpha: 1)

        libraryClickButton.title = ""
        libraryClickButton.isBordered = false
        libraryClickButton.focusRingType = .none
        libraryClickButton.setButtonType(.momentaryChange)
        libraryClickButton.target = self
        libraryClickButton.action = #selector(libraryClicked)

        syncButton.target = self
        syncButton.action = #selector(syncClicked)
        syncButton.bezelStyle = .rounded
        syncButton.controlSize = .small
        syncButton.font = NSFont.systemFont(ofSize: 11)

        uploadButton.title = L("上传", "Upload")
        uploadButton.target = self
        uploadButton.action = #selector(uploadClicked)
        uploadButton.bezelStyle = .rounded
        uploadButton.controlSize = .small
        uploadButton.font = NSFont.systemFont(ofSize: 11)
        uploadButton.toolTip = L("上传本机书籍与阅读进度到 WebDAV",
                                 "Upload local books and reading positions to WebDAV")
        uploadButton.isHidden = true

        downloadButton.title = L("下载", "Download")
        downloadButton.target = self
        downloadButton.action = #selector(downloadClicked)
        downloadButton.bezelStyle = .rounded
        downloadButton.controlSize = .small
        downloadButton.font = NSFont.systemFont(ofSize: 11)
        downloadButton.toolTip = L("下载云端书籍与阅读进度到本机",
                                   "Download cloud books and reading positions to this Mac")
        downloadButton.isHidden = true

        accessoryButton.title = ""
        accessoryButton.isBordered = false
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.target = self
        accessoryButton.action = #selector(accessoryClicked)
        accessoryButton.contentTintColor = NSColor(calibratedWhite: 0.42, alpha: 1)

        toolbarDivider.wantsLayer = true
        toolbarDivider.layer?.backgroundColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor

        libraryCountLabel.font = NSFont.systemFont(ofSize: 11)
        libraryCountLabel.textColor = NSColor(calibratedWhite: 0.46, alpha: 1)
        libraryCountLabel.lineBreakMode = .byTruncatingTail

        importButton.title = L("导入", "Import")
        importButton.target = self
        importButton.action = #selector(importClicked)
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        importButton.font = NSFont.systemFont(ofSize: 11)
        importButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading

        layoutButton.title = ""
        layoutButton.target = self
        layoutButton.action = #selector(toggleDisplayMode)
        layoutButton.bezelStyle = .rounded
        layoutButton.controlSize = .small
        layoutButton.imagePosition = .imageOnly
        updateLayoutButton()

        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = listContainer
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 4
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.usesSingleLineMode = false
        emptyLabel.isHidden = true

        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
        footerLabel.lineBreakMode = .byTruncatingTail

        languageButton.isBordered = false
        languageButton.focusRingType = .none
        languageButton.setButtonType(.momentaryChange)
        languageButton.target = self
        languageButton.action = #selector(toggleLanguage)

        root.addSubview(titleLabel)
        root.addSubview(clearLibraryButton)
        root.addSubview(hideSidebarButton)
        root.addSubview(libraryBar)
        [libraryIcon, libraryTitleLabel, libraryStatusLabel, syncSpinner, libraryChevron,
         libraryClickButton, syncButton, uploadButton, downloadButton, accessoryButton].forEach { libraryBar.addSubview($0) }
        root.addSubview(toolbarDivider)
        root.addSubview(libraryCountLabel)
        root.addSubview(layoutButton)
        root.addSubview(importButton)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footerLabel)
        root.addSubview(languageButton)

        let allViews: [NSView] = [
            titleLabel, clearLibraryButton, hideSidebarButton, libraryBar,
            libraryIcon, libraryTitleLabel, libraryStatusLabel, syncSpinner, libraryChevron,
            libraryClickButton, syncButton, uploadButton, downloadButton, accessoryButton,
            toolbarDivider, libraryCountLabel, layoutButton, importButton, scrollView, emptyLabel,
            footerLabel, languageButton
        ]
        allViews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        syncButtonWidthConstraint = syncButton.widthAnchor.constraint(equalToConstant: 46)
        uploadButtonWidthConstraint = uploadButton.widthAnchor.constraint(equalToConstant: 0)
        downloadButtonWidthConstraint = downloadButton.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            clearLibraryButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            clearLibraryButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearLibraryButton.trailingAnchor.constraint(lessThanOrEqualTo: hideSidebarButton.leadingAnchor, constant: -8),
            hideSidebarButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            hideSidebarButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hideSidebarButton.widthAnchor.constraint(equalToConstant: 26),
            hideSidebarButton.heightAnchor.constraint(equalToConstant: 26),

            libraryBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            libraryBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            libraryBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            libraryBar.heightAnchor.constraint(equalToConstant: 62),

            libraryIcon.leadingAnchor.constraint(equalTo: libraryBar.leadingAnchor, constant: 12),
            libraryIcon.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            libraryIcon.widthAnchor.constraint(equalToConstant: 18),
            libraryIcon.heightAnchor.constraint(equalToConstant: 18),

            libraryTitleLabel.topAnchor.constraint(equalTo: libraryBar.topAnchor, constant: 11),
            libraryTitleLabel.leadingAnchor.constraint(equalTo: libraryIcon.trailingAnchor, constant: 6),
            libraryTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: libraryChevron.leadingAnchor, constant: -2),

            libraryChevron.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            libraryChevron.trailingAnchor.constraint(equalTo: syncButton.leadingAnchor, constant: -6),
            libraryChevron.widthAnchor.constraint(equalToConstant: 10),
            libraryChevron.heightAnchor.constraint(equalToConstant: 10),

            syncSpinner.leadingAnchor.constraint(equalTo: libraryBar.leadingAnchor, constant: 12),
            syncSpinner.centerYAnchor.constraint(equalTo: libraryStatusLabel.centerYAnchor),
            syncSpinner.widthAnchor.constraint(equalToConstant: 12),
            syncSpinner.heightAnchor.constraint(equalToConstant: 12),
            libraryStatusLabel.topAnchor.constraint(equalTo: libraryTitleLabel.bottomAnchor, constant: 4),
            libraryStatusLabel.leadingAnchor.constraint(equalTo: syncSpinner.trailingAnchor, constant: 6),
            libraryStatusLabel.trailingAnchor.constraint(equalTo: libraryBar.trailingAnchor, constant: -12),
            libraryStatusLabel.bottomAnchor.constraint(lessThanOrEqualTo: libraryBar.bottomAnchor, constant: -6),

            libraryClickButton.leadingAnchor.constraint(equalTo: libraryBar.leadingAnchor),
            libraryClickButton.topAnchor.constraint(equalTo: libraryBar.topAnchor),
            libraryClickButton.bottomAnchor.constraint(equalTo: libraryBar.bottomAnchor),
            libraryClickButton.trailingAnchor.constraint(equalTo: libraryBar.trailingAnchor),

            syncButton.trailingAnchor.constraint(equalTo: uploadButton.leadingAnchor, constant: -4),
            syncButton.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            syncButtonWidthConstraint,
            uploadButton.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            uploadButton.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -4),
            uploadButton.heightAnchor.constraint(equalToConstant: 22),
            uploadButtonWidthConstraint,
            downloadButton.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: accessoryButton.leadingAnchor, constant: -4),
            downloadButton.heightAnchor.constraint(equalToConstant: 22),
            downloadButtonWidthConstraint,
            accessoryButton.trailingAnchor.constraint(equalTo: libraryBar.trailingAnchor, constant: -8),
            accessoryButton.centerYAnchor.constraint(equalTo: libraryTitleLabel.centerYAnchor),
            accessoryButton.widthAnchor.constraint(equalToConstant: 22),
            accessoryButton.heightAnchor.constraint(equalToConstant: 22),

            toolbarDivider.topAnchor.constraint(equalTo: libraryBar.bottomAnchor, constant: 12),
            toolbarDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            toolbarDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1),

            libraryCountLabel.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor, constant: 9),
            libraryCountLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            libraryCountLabel.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            libraryCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: layoutButton.leadingAnchor, constant: -8),

            importButton.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor, constant: 7),
            importButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            layoutButton.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            layoutButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -6),

            scrollView.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 7),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -28),

            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: languageButton.leadingAnchor, constant: -8),
            footerLabel.centerYAnchor.constraint(equalTo: languageButton.centerYAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            languageButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            languageButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor)
        ])

        view = root
        setActiveShelf(.folder)
        applyLanguageButtonStyle()

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverFromMouse()
            self?.loadVisibleCovers()
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
        loadVisibleCovers()
        if pendingScrollToTop {
            pendingScrollToTop = false
            scrollToTop()
        }
    }

    // MARK: - Active library

    func setProUnlocked(_ unlocked: Bool) {
        isProUnlocked = unlocked
        if activeShelf == .webdav {
            libraryTitleLabel.stringValue = displayTitle(for: activeShelf)
        }
    }

    private func displayTitle(for shelf: LibraryShelf) -> String {
        if shelf == .webdav && !isProUnlocked {
            return L("WebDAV 书库（Pro）", "WebDAV Library (Pro)")
        }
        return shelf.title
    }

    func setActiveShelf(_ shelf: LibraryShelf) {
        activeShelf = shelf
        libraryIcon.image = NSImage(systemSymbolName: shelf.symbolName, accessibilityDescription: nil)
        libraryTitleLabel.stringValue = displayTitle(for: shelf)
        syncButton.isHidden = false
        syncButtonWidthConstraint?.constant = 46
        accessoryButton.isHidden = false
        uploadButton.isHidden = true
        uploadButtonWidthConstraint?.constant = 0
        downloadButton.isHidden = true
        downloadButtonWidthConstraint?.constant = 0
        switch shelf {
        case .folder:
            syncButton.title = L("扫描", "Scan")
            syncButton.toolTip = L("扫描当前书库文件夹", "Scan the current library folder")
            accessoryButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: L("选择文件夹", "Choose folder"))
            accessoryButton.toolTip = L("选择书库文件夹", "Choose the library folder")
            libraryClickButton.toolTip = L("切换书库；当前为文件夹书库", "Switch library; currently the folder library")
        case .webdav:
            syncButton.isHidden = true
            syncButtonWidthConstraint?.constant = 0
            uploadButton.isHidden = false
            uploadButtonWidthConstraint?.constant = 44
            downloadButton.isHidden = false
            downloadButtonWidthConstraint?.constant = 44
            accessoryButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("同步设置", "Sync settings"))
            accessoryButton.toolTip = L("WebDAV 同步设置…", "WebDAV sync settings…")
            libraryClickButton.toolTip = L("切换书库；当前为 WebDAV 书库", "Switch library; currently WebDAV Library")
        }
        emptyLabel.stringValue = emptyText(for: shelf)
        applyImportButtonStyle()
        updateLibraryCount()
        renderStatus()
    }

    private func emptyText(for shelf: LibraryShelf) -> String {
        switch shelf {
        case .folder:
            return L("书库还是空的\n点文件夹图标选择书库文件夹，或点“导入”加入书籍",
                     "Your library is empty\nChoose a library folder with the folder icon, or press Import")
        case .webdav:
            return L("WebDAV 书库还是空的\n点“下载”获取云端书籍，或点“上传”推送本机书籍",
                     "Your WebDAV library is empty\nPress Download for cloud books, or Upload to push local books")
        }
    }

    @objc private func libraryClicked() {
        let menu = NSMenu()
        for shelf in LibraryShelf.allCases {
            let locked = shelf == .webdav && !isProUnlocked
            let item = NSMenuItem(
                title: displayTitle(for: shelf),
                action: locked ? #selector(proShelfClicked) : #selector(chooseLibrary(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = shelf.rawValue
            item.state = shelf == activeShelf ? .on : .off
            item.image = NSImage(
                systemSymbolName: locked ? "lock.fill" : shelf.symbolName,
                accessibilityDescription: nil
            )
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if isProUnlocked {
            let note = NSMenuItem(
                title: L("书库扫描一个文件夹；WebDAV 书库单独同步",
                        "The Library shelf scans one folder; WebDAV Library syncs separately"),
                action: nil,
                keyEquivalent: ""
            )
            note.isEnabled = false
            menu.addItem(note)
        } else {
            let proItem = NSMenuItem(
                title: L("解锁 EasyRead Pro（¥8）…", "Unlock EasyRead Pro (¥8)…"),
                action: #selector(proShelfClicked),
                keyEquivalent: ""
            )
            proItem.target = self
            proItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.addItem(proItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: libraryBar.bounds.minY - 6), in: libraryBar)
    }

    @objc private func proShelfClicked() {
        onShowPro?()
    }

    @objc private func chooseLibrary(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shelf = LibraryShelf(rawValue: raw) else { return }
        if shelf == .webdav && !isProUnlocked {
            onShowPro?()
            return
        }
        guard shelf != activeShelf else { return }
        onSwitchLibrary?(shelf)
    }

    // MARK: - Book list

    func reload(books: [LibraryBook], scrollToTop: Bool = false) {
        self.books = books
        updateLibraryCount()
        rowsByBookID.removeAll()
        hoveredRow = nil
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        books.forEach { book in
            let row: ShelfBookButton
            switch displayMode {
            case .list:
                row = BookRowButton(book: book)
            case .covers:
                row = BookCoverButton(book: book)
            }
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
            if displayMode == .list {
                row.autoresizingMask = [.width]
            }
            listContainer.addSubview(row)
            rowsByBookID[book.id] = row
        }
        updateListFrame()
        loadVisibleCovers()
        emptyLabel.isHidden = !books.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverFromMouse()
            self?.loadVisibleCovers()
            if scrollToTop {
                self?.pendingScrollToTop = true
                self?.scrollToTop()
            }
        }
    }

    func refresh(book: LibraryBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        rowsByBookID[book.id]?.update(book: book)
    }

    private func updateLibraryCount() {
        if books.isEmpty {
            libraryCountLabel.stringValue = L("还没有书籍", "No books yet")
        } else {
            libraryCountLabel.stringValue = L("共 \(books.count) 本", "\(books.count) books")
        }
        clearLibraryButton.isEnabled = !books.isEmpty
    }

    // MARK: - Status

    func setFolderStatus(_ status: FolderLibraryStatus) {
        folderStatus = status
        if activeShelf == .folder {
            renderStatus()
        }
    }

    func setZenStatus(_ status: ZenSyncStatus) {
        zenStatus = status
        if activeShelf == .webdav {
            renderStatus()
        }
    }

    /// Prevents a second upload/download while one is already running. The
    /// status line and spinner show the live phase.
    func setZenBusy(_ busy: Bool) {
        uploadButton.isEnabled = !busy
        downloadButton.isEnabled = !busy
    }

    private var defaultStatusColor: NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.55, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
    }

    private func renderStatus() {
        switch activeShelf {
        case .folder:
            libraryStatusLabel.stringValue = folderStatus.shortText
            libraryStatusLabel.toolTip = folderStatus.detail ?? folderStatus.text
            if case .folderMissing = folderStatus {
                libraryStatusLabel.textColor = .systemOrange
            } else {
                libraryStatusLabel.textColor = defaultStatusColor
            }
        case .webdav:
            libraryStatusLabel.stringValue = zenStatus.shortText
            libraryStatusLabel.toolTip = zenStatus.detail ?? zenStatus.text
            if case .failed = zenStatus {
                libraryStatusLabel.textColor = .systemOrange
            } else if case .warning = zenStatus {
                libraryStatusLabel.textColor = .systemOrange
            } else {
                libraryStatusLabel.textColor = defaultStatusColor
            }
        }
        if activeShelf == .webdav, let detail = zenStatus.detail {
            libraryClickButton.toolTip = detail
        }
        updateSyncSpinner()
    }

    private var isStatusBusy: Bool {
        switch activeShelf {
        case .folder:
            if case .scanning = folderStatus { return true }
        case .webdav:
            if case .syncing = zenStatus { return true }
        }
        return false
    }

    private func updateSyncSpinner() {
        if isStatusBusy {
            if syncSpinner.isHidden {
                syncSpinner.isHidden = false
                syncSpinner.startAnimation(nil)
            }
        } else {
            syncSpinner.stopAnimation(nil)
            syncSpinner.isHidden = true
        }
    }

    // MARK: - Theme & language

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
        hideSidebarButton.contentTintColor = isDark
            ? NSColor(calibratedWhite: 0.62, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        libraryCountLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.56, alpha: 1)
            : NSColor(calibratedWhite: 0.46, alpha: 1)
        libraryTitleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.9, alpha: 1)
            : NSColor(calibratedWhite: 0.16, alpha: 1)
        let iconColor = isDark
            ? NSColor(calibratedWhite: 0.62, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        libraryIcon.contentTintColor = iconColor
        libraryChevron.contentTintColor = iconColor
        accessoryButton.contentTintColor = iconColor
        libraryBar.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.995, alpha: 1)).cgColor
        libraryBar.layer?.borderColor = (isDark
            ? NSColor(calibratedWhite: 0.28, alpha: 1)
            : NSColor(calibratedWhite: 0.87, alpha: 1)).cgColor
        toolbarDivider.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.26, alpha: 1)
            : NSColor(calibratedWhite: 0.87, alpha: 1)).cgColor
        emptyLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.55, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)
        footerLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.52, alpha: 1)
            : NSColor(calibratedWhite: 0.48, alpha: 1)
        applyLanguageButtonStyle()
        renderStatus()
        listContainer.subviews
            .compactMap { $0 as? ShelfBookButton }
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

    func applyLanguage() {
        titleLabel.stringValue = L("简阅", "EasyRead")
        clearLibraryButton.title = L("清理书架", "Clear Shelf")
        clearLibraryButton.toolTip = L("只清理当前书库的书架记录，不删除任何书籍文件",
                                       "Clears only the current library's shelf records; book files are never deleted")
        hideSidebarButton.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L("隐藏书架", "Hide Library")
        )
        hideSidebarButton.toolTip = L("隐藏左侧书架（⌘⇧S）", "Hide sidebar (⌘⇧S)")
        importButton.title = L("导入", "Import")
        applyImportButtonStyle()
        updateLayoutButton()
        emptyLabel.stringValue = emptyText(for: activeShelf)
        footerLabel.stringValue = "TXT · MD · EPUB · PDF · MOBI · AZW3"
        setActiveShelf(activeShelf)
        applyLanguageButtonStyle()
        reload(books: books)
    }

    private func applyImportButtonStyle() {
        switch activeShelf {
        case .folder:
            if CloudFolderSync.isICloudDriveFolder(FolderLibraryStore.shared.folderURL) {
                importButton.toolTip = L("导入书籍并复制到 iCloud 书库文件夹",
                                         "Import books and copy them into the iCloud library folder")
            } else {
                importButton.toolTip = L("导入本机书籍，不上传", "Import local books; nothing is uploaded")
            }
        case .webdav:
            importButton.toolTip = L("加入 WebDAV 书库；下次同步时确认上传",
                                     "Add to the WebDAV library; upload is confirmed on the next sync")
        }
    }

    private func updateLayoutButton() {
        switch displayMode {
        case .list:
            layoutButton.image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: L("封面书架", "Cover shelf")
            )
            layoutButton.toolTip = L("切换到封面书架", "Switch to cover shelf")
        case .covers:
            layoutButton.image = NSImage(
                systemSymbolName: "list.bullet",
                accessibilityDescription: L("列表书架", "List shelf")
            )
            layoutButton.toolTip = L("切换到列表书架", "Switch to list shelf")
        }
    }

    @objc private func toggleDisplayMode() {
        displayMode = displayMode == .list ? .covers : .list
        UserDefaults.standard.set(displayMode.rawValue, forKey: "ShelfDisplayMode")
        updateLayoutButton()
        reload(books: books, scrollToTop: true)
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

    // MARK: - Layout helpers

    private func updateListFrame() {
        let width = max(scrollView.contentView.bounds.width, 1)
        let viewportHeight = max(scrollView.contentView.bounds.height, 1)
        switch displayMode {
        case .list:
            let rowHeight = BookRowButton.rowHeight
            let rowSpacing: CGFloat = 3
            let rowsHeight = max(books.isEmpty ? 1 : CGFloat(books.count) * (rowHeight + rowSpacing) + 4, viewportHeight)
            listContainer.frame = NSRect(x: 0, y: 0, width: width, height: rowsHeight)
            for (index, row) in listContainer.subviews.enumerated() {
                let y = rowsHeight - 2 - rowHeight - CGFloat(index) * (rowHeight + rowSpacing)
                row.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
            }
        case .covers:
            let inset: CGFloat = 8
            let columnSpacing: CGFloat = 12
            let rowSpacing: CGFloat = 16
            let columns = max(Int((width - inset * 2 + columnSpacing) / 150), 2)
            let cellWidth = max(
                (width - inset * 2 - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns),
                1
            )
            let cellHeight = BookCoverButton.height(forWidth: cellWidth)
            let rowCount = max(Int(ceil(Double(books.count) / Double(columns))), 1)
            let contentHeight = inset * 2
                + CGFloat(rowCount) * cellHeight
                + CGFloat(max(rowCount - 1, 0)) * rowSpacing
            let containerHeight = max(books.isEmpty ? 1 : contentHeight, viewportHeight)
            listContainer.frame = NSRect(x: 0, y: 0, width: width, height: containerHeight)
            for (index, row) in listContainer.subviews.enumerated() {
                let column = index % columns
                let rowIndex = index / columns
                let x = inset + CGFloat(column) * (cellWidth + columnSpacing)
                let y = containerHeight - inset - cellHeight
                    - CGFloat(rowIndex) * (cellHeight + rowSpacing)
                row.frame = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            }
        }
    }

    /// Cover extraction is comparatively expensive, so only cells that are
    /// actually on screen ask for their image. The scroll observer calls this
    /// again as the shelf moves.
    private func loadVisibleCovers() {
        guard displayMode == .covers else { return }
        let visible = scrollView.contentView.bounds
        for case let cell as BookCoverButton in listContainer.subviews {
            if cell.frame.intersects(visible) {
                cell.loadCoverIfNeeded()
            }
        }
    }

    private func scrollToTop() {
        view.layoutSubtreeIfNeeded()
        updateListFrame()
        let maximumY = max(0, listContainer.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        loadVisibleCovers()
    }

    private func setHoveredRow(_ row: ShelfBookButton?) {
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
            .compactMap { $0 as? ShelfBookButton }
            .first { $0.frame.contains(point) }
        setHoveredRow(row)
    }

    // MARK: - Actions

    @objc private func hideSidebarClicked() {
        onToggleSidebar?()
    }

    @objc private func importClicked() {
        onImport?()
    }

    @objc private func syncClicked() {
        onSync?()
    }

    @objc private func uploadClicked() {
        onUpload?()
    }

    @objc private func downloadClicked() {
        onDownload?()
    }

    @objc private func accessoryClicked() {
        switch activeShelf {
        case .webdav:
            onZenSettings?()
        case .folder:
            onChooseFolder?()
        }
    }

    @objc private func clearLibraryClicked() {
        onClearLibrary?()
    }
}

final class ZenSyncSettingsWindowController: NSWindowController {
    var onSaved: (() -> Void)?
    var onCleared: (() -> Void)?
    var onRequestUpload: (() -> Void)?
    var onRequestDownload: (() -> Void)?

    private let sync = ZenReaderSync.shared
    private let serverField = NSTextField()
    private let accountField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let providerPopup = NSPopUpButton()
    private let layoutControl = NSSegmentedControl()
    private let serverHintLabel = NSTextField(wrappingLabelWithString: "")
    private let layoutHintLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordHintLabel = NSTextField(wrappingLabelWithString: "")
    private let autoSyncCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncSpinner = NSProgressIndicator()
    private let lastSyncLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton()
    private let saveButton = NSButton()
    private let clearButton = NSButton()
    private let uploadNowButton = NSButton()
    private let downloadNowButton = NSButton()
    private let closeButton = NSButton()
    private var isTesting = false
    private var isManualSyncing = false
    private var lastSelectedProvider: ZenWebDAVProvider?
    private weak var settingsRootView: NSView?
    private weak var settingsCardView: NSView?
    private weak var settingsDividerView: NSView?
    private weak var settingsActionDividerView: NSView?

    init(appearance: NSAppearance?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("WebDAV 同步", "WebDAV Sync")
        window.isReleasedWhenClosed = false
        // The settings window is a separate NSWindow, so it must follow the
        // reader's day/night appearance explicitly instead of the system theme.
        window.appearance = appearance
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let window, let root = window.contentView else { return }
        root.wantsLayer = true
        settingsRootView = root

        let titleLabel = NSTextField(labelWithString: L("WebDAV 同步", "WebDAV Sync"))
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: L(
            "通过 WebDAV 同步书籍与阅读进度。默认使用 EasyRead 自己的云端文件夹；需要和 iPhone 上的极简阅读互通时，可选择 ZenReader 兼容目录。",
            "Sync books and reading positions over WebDAV. EasyRead uses its own cloud folder by default; choose the ZenReader compatible folder to share data with ZenReader on iPhone."
        ))
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        settingsCardView = card

        let methodLabel = makeFormLabel(L("同步方式", "Mode"))
        let providerLabel = makeFormLabel(L("服务商", "Provider"))
        let serverLabel = makeFormLabel(L("服务器地址", "Server"))
        let accountLabel = makeFormLabel(L("账号", "Account"))
        let passwordLabel = makeFormLabel(L("密码", "Password"))
        let layoutLabel = makeFormLabel(L("云端目录", "Cloud Folder"))
        let labelWidth: CGFloat = 96

        let methodValue = makeReadOnlyValue("WebDAV")

        providerPopup.removeAllItems()
        providerPopup.addItems(withTitles: ZenWebDAVProvider.allCases.map(\.title))
        if let index = ZenWebDAVProvider.allCases.firstIndex(of: sync.provider) {
            providerPopup.selectItem(at: index)
        }
        providerPopup.font = NSFont.systemFont(ofSize: 12)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for field in [serverField, accountField, passwordField] {
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        serverField.stringValue = sync.serverURL
        accountField.stringValue = sync.username
        accountField.placeholderString = L("WebDAV 账号或邮箱", "WebDAV account or email")
        if !sync.isConfigured && sync.hasServerAndAccount {
            passwordField.placeholderString = L("请重新输入密码（只需一次）",
                                               "Re-enter the password (once)")
        } else {
            passwordField.placeholderString = sync.password == nil
                ? L("WebDAV 密码或应用密码", "WebDAV or app password")
                : L("已保存，留空表示不修改", "Saved; leave blank to keep it")
        }

        layoutControl.segmentCount = ZenRemoteLayout.allCases.count
        for (index, layout) in ZenRemoteLayout.allCases.enumerated() {
            layoutControl.setLabel(layout.shortTitle, forSegment: index)
        }
        layoutControl.trackingMode = .selectOne
        layoutControl.selectedSegment = ZenRemoteLayout.allCases.firstIndex(of: sync.remoteLayout) ?? 0
        layoutControl.font = NSFont.systemFont(ofSize: 11.5)
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)

        for hint in [serverHintLabel, layoutHintLabel, passwordHintLabel] {
            hint.font = NSFont.systemFont(ofSize: 10)
            hint.textColor = .secondaryLabelColor
        }
        let initialProvider = ZenWebDAVProvider.allCases[
            max(0, min(providerPopup.indexOfSelectedItem, ZenWebDAVProvider.allCases.count - 1))
        ]
        serverField.placeholderString = initialProvider.serverPlaceholder
        serverHintLabel.stringValue = initialProvider.serverHint
        passwordHintLabel.stringValue = passwordHintText(for: initialProvider)
        lastSelectedProvider = initialProvider
        let initialLayout = ZenRemoteLayout.allCases[
            max(0, min(layoutControl.selectedSegment, ZenRemoteLayout.allCases.count - 1))
        ]
        layoutHintLabel.stringValue = initialLayout.hint

        let divider = NSView()
        divider.wantsLayer = true
        settingsDividerView = divider

        autoSyncCheckbox.title = L("自动同步", "Automatic sync")
        autoSyncCheckbox.font = NSFont.systemFont(ofSize: 12)
        autoSyncCheckbox.state = sync.autoSyncEnabled ? .on : .off
        let autoHint = NSTextField(wrappingLabelWithString: L(
            "打开 App 或切回前台时会自动下载云端新书、上传本机缺少的书籍并交换阅读进度（至少间隔 5 分钟）。\n下方按钮用于立即手动同步。",
            "On launch or when returning to the app, new cloud books are downloaded, missing local books are uploaded, and reading positions are exchanged (at least 5 minutes apart).\nUse the buttons below for an immediate manual sync."
        ))
        autoHint.font = NSFont.systemFont(ofSize: 10)
        autoHint.textColor = .secondaryLabelColor

        lastSyncLabel.font = NSFont.systemFont(ofSize: 11)
        lastSyncLabel.textColor = .secondaryLabelColor
        updateLastSyncLabel()

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false
        syncSpinner.isHidden = true

        let actionDivider = NSView()
        actionDivider.wantsLayer = true
        settingsActionDividerView = actionDivider

        clearButton.title = L("清除配置", "Clear Settings")
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        testButton.title = L("测试连接", "Test Connection")
        testButton.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        saveButton.title = L("保存配置", "Save Settings")
        saveButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        saveButton.keyEquivalent = "\r"

        uploadNowButton.title = L("上传到云端", "Upload to Cloud")
        uploadNowButton.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
        uploadNowButton.bezelColor = .controlAccentColor
        uploadNowButton.keyEquivalent = ""
        downloadNowButton.title = L("从云端下载", "Download from Cloud")
        downloadNowButton.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)

        for button in [clearButton, testButton, saveButton, uploadNowButton, downloadNowButton] {
            button.bezelStyle = .rounded
            button.imagePosition = .imageLeading
            button.target = self
        }
        for button in [clearButton, testButton, saveButton] {
            button.font = NSFont.systemFont(ofSize: 12)
        }
        for button in [uploadNowButton, downloadNowButton] {
            button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        }
        clearButton.action = #selector(clearClicked)
        testButton.action = #selector(testClicked)
        saveButton.action = #selector(saveClicked)
        uploadNowButton.action = #selector(uploadNowClicked)
        downloadNowButton.action = #selector(downloadNowClicked)
        clearButton.contentTintColor = .systemRed

        let footerLabel = NSTextField(wrappingLabelWithString: L(
            "WebDAV 密码仅保存在 macOS 钥匙串。自动同步也会上传本机书籍，只新建快照；手动上传前仍会再次确认；删除书籍请在书库中右键操作。",
            "The WebDAV password lives only in the macOS Keychain. Automatic sync also uploads local books and only creates new snapshots; manual uploads still ask for confirmation; to delete a book, right-click it in the library."
        ))
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = .secondaryLabelColor

        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: L("关闭", "Close")
        )
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        closeButton.toolTip = L("关闭（Esc）", "Close (Esc)")
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        func add(_ view: NSView, to parent: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
        }

        add(titleLabel, to: root)
        add(subtitleLabel, to: root)
        add(closeButton, to: root)
        add(card, to: root)
        [methodLabel, methodValue, providerLabel, providerPopup,
         serverLabel, serverField, serverHintLabel,
         accountLabel, accountField, passwordLabel, passwordField,
         passwordHintLabel, divider, layoutLabel, layoutControl, layoutHintLabel,
         autoSyncCheckbox, autoHint, lastSyncLabel].forEach { add($0, to: card) }
        add(statusLabel, to: root)
        add(syncSpinner, to: root)
        add(testButton, to: root)
        add(saveButton, to: root)
        add(clearButton, to: root)
        add(actionDivider, to: root)
        add(uploadNowButton, to: root)
        add(downloadNowButton, to: root)
        add(footerLabel, to: root)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),
            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),

            methodLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            methodLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            methodLabel.centerYAnchor.constraint(equalTo: methodValue.centerYAnchor),
            methodValue.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            methodValue.leadingAnchor.constraint(equalTo: methodLabel.trailingAnchor, constant: 12),
            methodValue.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),

            providerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            providerLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            providerLabel.centerYAnchor.constraint(equalTo: providerPopup.centerYAnchor),
            providerPopup.topAnchor.constraint(equalTo: methodValue.bottomAnchor, constant: 10),
            providerPopup.leadingAnchor.constraint(equalTo: providerLabel.trailingAnchor, constant: 12),
            providerPopup.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            providerPopup.heightAnchor.constraint(equalToConstant: 26),
            providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            serverLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            serverLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            serverLabel.centerYAnchor.constraint(equalTo: serverField.centerYAnchor),
            serverField.topAnchor.constraint(equalTo: providerPopup.bottomAnchor, constant: 12),
            serverField.leadingAnchor.constraint(equalTo: serverLabel.trailingAnchor, constant: 12),
            serverField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            serverField.heightAnchor.constraint(equalToConstant: 26),

            serverHintLabel.topAnchor.constraint(equalTo: serverField.bottomAnchor, constant: 4),
            serverHintLabel.leadingAnchor.constraint(equalTo: serverField.leadingAnchor),
            serverHintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            accountLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            accountLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            accountLabel.centerYAnchor.constraint(equalTo: accountField.centerYAnchor),
            accountField.topAnchor.constraint(equalTo: serverHintLabel.bottomAnchor, constant: 10),
            accountField.leadingAnchor.constraint(equalTo: accountLabel.trailingAnchor, constant: 12),
            accountField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            accountField.heightAnchor.constraint(equalToConstant: 26),

            passwordLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            passwordLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            passwordLabel.centerYAnchor.constraint(equalTo: passwordField.centerYAnchor),
            passwordField.topAnchor.constraint(equalTo: accountField.bottomAnchor, constant: 10),
            passwordField.leadingAnchor.constraint(equalTo: passwordLabel.trailingAnchor, constant: 12),
            passwordField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            passwordField.heightAnchor.constraint(equalToConstant: 26),

            passwordHintLabel.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 5),
            passwordHintLabel.leadingAnchor.constraint(equalTo: passwordField.leadingAnchor),
            passwordHintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: passwordHintLabel.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            divider.heightAnchor.constraint(equalToConstant: 1),

            layoutLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            layoutLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            layoutLabel.centerYAnchor.constraint(equalTo: layoutControl.centerYAnchor),
            layoutControl.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            layoutControl.leadingAnchor.constraint(equalTo: layoutLabel.trailingAnchor, constant: 12),
            layoutControl.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            layoutControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),

            layoutHintLabel.topAnchor.constraint(equalTo: layoutControl.bottomAnchor, constant: 4),
            layoutHintLabel.leadingAnchor.constraint(equalTo: layoutControl.leadingAnchor),
            layoutHintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            autoSyncCheckbox.topAnchor.constraint(equalTo: layoutHintLabel.bottomAnchor, constant: 12),
            autoSyncCheckbox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            autoHint.topAnchor.constraint(equalTo: autoSyncCheckbox.bottomAnchor, constant: 3),
            autoHint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            autoHint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            lastSyncLabel.topAnchor.constraint(equalTo: autoHint.bottomAnchor, constant: 10),
            lastSyncLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            lastSyncLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            lastSyncLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: syncSpinner.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
            syncSpinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            syncSpinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            syncSpinner.widthAnchor.constraint(equalToConstant: 12),
            syncSpinner.heightAnchor.constraint(equalToConstant: 12),

            testButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            testButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            testButton.heightAnchor.constraint(equalToConstant: 26),
            saveButton.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            saveButton.leadingAnchor.constraint(equalTo: testButton.trailingAnchor, constant: 10),
            saveButton.heightAnchor.constraint(equalToConstant: 26),
            clearButton.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 10),
            clearButton.heightAnchor.constraint(equalToConstant: 26),

            actionDivider.topAnchor.constraint(equalTo: testButton.bottomAnchor, constant: 14),
            actionDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            actionDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            actionDivider.heightAnchor.constraint(equalToConstant: 1),

            uploadNowButton.topAnchor.constraint(equalTo: actionDivider.bottomAnchor, constant: 12),
            uploadNowButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            uploadNowButton.heightAnchor.constraint(equalToConstant: 30),
            uploadNowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 136),
            downloadNowButton.centerYAnchor.constraint(equalTo: uploadNowButton.centerYAnchor),
            downloadNowButton.leadingAnchor.constraint(equalTo: uploadNowButton.trailingAnchor, constant: 10),
            downloadNowButton.heightAnchor.constraint(equalToConstant: 30),
            downloadNowButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 136),
            downloadNowButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -26),

            footerLabel.topAnchor.constraint(equalTo: uploadNowButton.bottomAnchor, constant: 12),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        refreshLayerColors()
        root.layoutSubtreeIfNeeded()
        let fittingHeight = root.fittingSize.height
        if fittingHeight > 300 {
            window.setContentSize(NSSize(width: 600, height: fittingHeight))
        }
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        refreshLayerColors()
    }

    private func refreshLayerColors() {
        let appearance = window?.appearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            self.settingsRootView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            self.settingsCardView?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            self.settingsCardView?.layer?.borderColor = NSColor.separatorColor.cgColor
            self.settingsDividerView?.layer?.backgroundColor = NSColor.separatorColor.cgColor
            self.settingsActionDividerView?.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    func focusInitialField() {
        guard let window else { return }
        // Focus a non-secure field first; macOS otherwise pops up the saved
        // password panel as soon as the settings sheet appears.
        let target: NSView = sync.username.isEmpty ? accountField : serverField
        window.initialFirstResponder = target
        window.makeFirstResponder(target)
    }

    private func makeFormLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func makeReadOnlyValue(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        return label
    }

    private func updateLastSyncLabel() {
        if let date = sync.lastCompletedAt {
            let formatted = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
            lastSyncLabel.stringValue = L("上次同步：\(formatted)", "Last sync: \(formatted)")
        } else {
            lastSyncLabel.stringValue = L("上次同步：尚未同步", "Last sync: never")
        }
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text
    }

    private var selectedProvider: ZenWebDAVProvider {
        let providers = ZenWebDAVProvider.allCases
        let index = providerPopup.indexOfSelectedItem
        guard providers.indices.contains(index) else { return .jianguoyun }
        return providers[index]
    }

    private var selectedLayout: ZenRemoteLayout {
        let layouts = ZenRemoteLayout.allCases
        let index = layoutControl.selectedSegment
        guard layouts.indices.contains(index) else { return .easyread }
        return layouts[index]
    }

    private func passwordHintText(for provider: ZenWebDAVProvider) -> String {
        if !sync.isConfigured && sync.hasServerAndAccount {
            return L(
                "这个版本请再输入一次密码（最后一次）。保存后会改用稳定的钥匙串标识，以后修改或重建 EasyRead 都不再需要重新输入，也不会弹出系统授权窗口。",
                "Enter the password one last time. Saving migrates it to a stable keychain identity, so later EasyRead rebuilds never ask for it again or show the macOS authorization dialog."
            )
        }
        return provider.passwordHint
            + L(" 密码只保存在 macOS 钥匙串，读取时不会弹出系统授权窗口。",
                " The password is stored only in the macOS Keychain and read without a system authorization dialog.")
    }

    @objc private func providerChanged() {
        let provider = selectedProvider
        let previous = lastSelectedProvider
        lastSelectedProvider = provider
        if previous != provider {
            // Do not leave another provider's well-known URL in the field:
            // new installs start with the Jianguoyun root, and switching to
            // Nextcloud or a custom server without editing it would look
            // correct while pointing at the wrong host.
            let current = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let templateValues = Set(
                ZenWebDAVProvider.allCases.map(\.serverPlaceholder)
                    + [ZenReaderSync.defaultServer]
            )
            if current.isEmpty || templateValues.contains(current) {
                serverField.stringValue = provider == .jianguoyun ? ZenReaderSync.defaultServer : ""
            }
        }
        serverField.placeholderString = provider.serverPlaceholder
        serverHintLabel.stringValue = provider.serverHint
        passwordHintLabel.stringValue = passwordHintText(for: provider)
        setStatus(
            L("已切换到 \(provider.title)；保存配置后生效", "Switched to \(provider.title); save to apply"),
            color: .secondaryLabelColor
        )
    }

    @objc private func layoutChanged() {
        layoutHintLabel.stringValue = selectedLayout.hint
        setStatus(
            L("云端目录：\(selectedLayout.folderPath)；保存配置后生效",
              "Cloud folder: \(selectedLayout.folderPath); save to apply"),
            color: .secondaryLabelColor
        )
    }

    private func persistSettings() -> Bool {
        do {
            try sync.saveSettings(
                server: serverField.stringValue,
                username: accountField.stringValue,
                password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue,
                provider: selectedProvider,
                remoteLayout: selectedLayout
            )
            sync.autoSyncEnabled = autoSyncCheckbox.state == .on
            return true
        } catch {
            setStatus(error.localizedDescription, color: .systemOrange)
            return false
        }
    }

    @objc private func closeClicked() {
        closeSheet()
    }

    @objc private func saveClicked() {
        guard persistSettings() else { return }
        closeSheet()
        onSaved?()
    }

    @objc private func uploadNowClicked() {
        startManualAction(
            unavailable: L("上传入口不可用，请关闭窗口后重试。", "The upload handler is unavailable. Close this window and try again."),
            checking: L("正在检查云端与本机的书籍…", "Checking books in the cloud and on this Mac…"),
            request: onRequestUpload
        )
    }

    @objc private func downloadNowClicked() {
        startManualAction(
            unavailable: L("下载入口不可用，请关闭窗口后重试。", "The download handler is unavailable. Close this window and try again."),
            checking: L("正在下载云端书籍与阅读进度…", "Downloading cloud books and positions…"),
            request: onRequestDownload
        )
    }

    private func startManualAction(unavailable: String, checking: String, request: (() -> Void)?) {
        guard !isTesting, !isManualSyncing else { return }
        guard persistSettings() else { return }
        guard let request else {
            setStatus(unavailable, color: .systemOrange)
            return
        }
        isManualSyncing = true
        setManualBusy(true)
        setStatus(checking, color: .secondaryLabelColor)
        request()
    }

    /// Live phase from the background sync. Automatic syncs stay silent here;
    /// only a manual upload/download drives this window's status line.
    func showSyncProgress(_ stage: ZenSyncStage) {
        guard isManualSyncing else { return }
        setStatus(stage.shortText, color: .secondaryLabelColor)
    }

    func finishManualSync(message: String, success: Bool) {
        guard isManualSyncing else { return }
        isManualSyncing = false
        setManualBusy(false)
        if success {
            updateLastSyncLabel()
        }
        let text = success
            ? L("同步完成 · \(message)", "Sync complete · \(message)")
            : message
        setStatus(text, color: success ? .systemGreen : .systemOrange)
    }

    private func setManualBusy(_ busy: Bool) {
        uploadNowButton.isEnabled = !busy
        downloadNowButton.isEnabled = !busy
        testButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        clearButton.isEnabled = !busy
        if busy {
            syncSpinner.isHidden = false
            syncSpinner.startAnimation(nil)
        } else {
            syncSpinner.stopAnimation(nil)
            syncSpinner.isHidden = true
        }
    }

    @objc private func testClicked() {
        guard !isTesting, !isManualSyncing else { return }
        isTesting = true
        testButton.isEnabled = false
        saveButton.isEnabled = false
        setStatus(L("正在测试连接…", "Testing connection…"), color: .secondaryLabelColor)

        let server = serverField.stringValue
        let account = accountField.stringValue
        let password = passwordField.stringValue
        let layout = selectedLayout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let count = try ZenReaderSync.shared.testConnection(
                    server: server,
                    username: account,
                    password: password,
                    remoteLayout: layout
                )
                DispatchQueue.main.async {
                    self.finishTest(
                        status: count == 0
                            ? L("连接成功；云端还没有进度快照，首次同步会自动创建目录",
                                "Connected; no progress snapshots yet. The folder is created on the first sync.")
                            : L("连接成功，发现 \(count) 个进度快照", "Connected; \(count) progress snapshots found"),
                        color: .systemGreen
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishTest(status: error.localizedDescription, color: .systemOrange)
                }
            }
        }
    }

    private func finishTest(status: String, color: NSColor) {
        isTesting = false
        testButton.isEnabled = true
        saveButton.isEnabled = true
        setStatus(status, color: color)
    }

    @objc private func clearClicked() {
        guard !isManualSyncing, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("清除 WebDAV 同步配置？", "Clear WebDAV sync settings?")
        alert.informativeText = L(
            "会移除本机保存的服务器地址、账号、服务商选择和钥匙串中的密码。不会清空书架，也不会删除书籍文件或云端上的快照。",
            "This removes the saved server, account, provider choice, and password from this Mac. It does not clear the bookshelf or delete book files or cloud snapshots."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("清除配置", "Clear"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.sync.clearSettings()
            self.serverField.stringValue = ZenReaderSync.defaultServer
            self.accountField.stringValue = ""
            self.passwordField.stringValue = ""
            self.passwordField.placeholderString = L("WebDAV 密码或应用密码", "WebDAV or app password")
            self.providerPopup.selectItem(at: 0)
            self.lastSelectedProvider = .jianguoyun
            self.layoutControl.selectedSegment = 0
            self.serverField.placeholderString = ZenWebDAVProvider.jianguoyun.serverPlaceholder
            self.serverHintLabel.stringValue = ZenWebDAVProvider.jianguoyun.serverHint
            self.passwordHintLabel.stringValue = self.passwordHintText(for: .jianguoyun)
            self.layoutHintLabel.stringValue = ZenRemoteLayout.easyread.hint
            self.setStatus(L("已清除本机保存的同步配置", "Saved sync settings were cleared"), color: .secondaryLabelColor)
            self.onCleared?()
        }
    }

    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

private final class ReaderChaptersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// One entry of the hierarchical table of contents. `key` is the path of
    /// indices through the tree, so expansion state survives a rebuild.
    private final class TreeItem {
        let chapter: ReaderChapter
        let key: String
        var children: [TreeItem] = []
        var progressMin: Double?
        var progressMax: Double?

        init(chapter: ReaderChapter, key: String) {
            self.chapter = chapter
            self.key = key
        }

        var isGroup: Bool { !children.isEmpty }
    }

    private struct Row {
        let item: TreeItem
        let depth: Int
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var chapters: [ReaderChapter] = []
    private var roots: [TreeItem] = []
    private var rows: [Row] = []
    private var expandedKeys: Set<String> = []
    var onSelect: ((ReaderChapter) -> Void)?
    /// Fraction of the book on screen when the popover opens. The list
    /// starts at that chapter instead of the first row, so a long novel
    /// does not need to be scrolled down from chapter 1 on every open.
    var currentProgress: Double?

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 340, height: 440)
        root.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chapter"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.frame = NSRect(x: 0, y: 0, width: 324, height: 0)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.preferredMaxLayoutWidth = 280
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(spinner)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    func showLoading() {
        chapters = []
        roots = []
        rows = []
        expandedKeys = []
        tableView.reloadData()
        emptyLabel.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func setChapters(_ chapters: [ReaderChapter], emptyMessage: String) {
        self.chapters = chapters
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        roots = makeItems(from: chapters, prefix: "")
        expandedKeys = []
        applyDefaultExpansion()
        rebuildVisibleRows()
        tableView.reloadData()
        emptyLabel.stringValue = emptyMessage
        emptyLabel.isHidden = !chapters.isEmpty
        if !rows.isEmpty {
            scrollToActiveRow(select: true)
        }
    }

    private func makeItems(from chapters: [ReaderChapter], prefix: String) -> [TreeItem] {
        chapters.enumerated().map { index, chapter in
            let key = prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
            let item = TreeItem(chapter: chapter, key: key)
            item.children = makeItems(from: chapter.children, prefix: key)
            var minimum = chapter.progress
            var maximum = chapter.progress
            for child in item.children {
                if let childMin = child.progressMin {
                    minimum = minimum.map { min($0, childMin) } ?? childMin
                }
                if let childMax = child.progressMax {
                    maximum = maximum.map { max($0, childMax) } ?? childMax
                }
            }
            item.progressMin = minimum
            item.progressMax = maximum
            return item
        }
    }

    /// Collections show one top-level group per included book. Open with the
    /// group that contains the reading position expanded (including its
    /// nested sections) and the other books folded away.
    private func applyDefaultExpansion() {
        let groups = roots.filter { $0.isGroup }
        guard !groups.isEmpty else { return }
        var active: TreeItem?
        if let progress = currentProgress {
            // A group's progress range ends at its last chapter's *start*, so
            // a position inside that chapter falls past `progressMax` and a
            // nearest-range search would pick the next book. Pick the last
            // group that starts at or before the reading position instead.
            for group in groups {
                if let low = group.progressMin, low <= progress + 0.000001 {
                    active = group
                }
            }
            if active == nil {
                active = groups.min { lhs, rhs in
                    abs((lhs.progressMin ?? 0) - progress) <
                        abs((rhs.progressMin ?? 0) - progress)
                }
            }
        }
        expandSubtree(active ?? groups[0])
    }

    private func expandSubtree(_ item: TreeItem) {
        guard item.isGroup else { return }
        expandedKeys.insert(item.key)
        for child in item.children {
            expandSubtree(child)
        }
    }

    private func rebuildVisibleRows() {
        var result: [Row] = []
        func append(_ items: [TreeItem], depth: Int) {
            for item in items {
                result.append(Row(item: item, depth: depth))
                if item.isGroup, expandedKeys.contains(item.key) {
                    append(item.children, depth: depth + 1)
                }
            }
        }
        append(roots, depth: 0)
        rows = result
    }

    /// Row of the chapter that contains the reading position. Text and PDF
    /// chapters carry a book fraction; comic chapters are one row per page,
    /// so their position follows from the row index. Group headers are only
    /// used when no leaf row fits.
    private func activeRowIndex() -> Int? {
        guard !rows.isEmpty else { return nil }
        guard let progress = currentProgress else {
            return rows.firstIndex(where: { !$0.item.isGroup }) ?? 0
        }
        var best: Int?
        for (index, row) in rows.enumerated() {
            let chapter = row.item.chapter
            let chapterProgress: Double?
            if let stored = chapter.progress {
                chapterProgress = stored
            } else if row.item.isGroup, let minimum = row.item.progressMin {
                // A container without its own link still starts where its
                // first child starts.
                chapterProgress = minimum
            } else if chapter.anchorID?.hasPrefix("cbz-page-") == true, chapters.count > 1 {
                chapterProgress = Double(index) / Double(chapters.count - 1)
            } else {
                chapterProgress = nil
            }
            guard let chapterProgress, chapterProgress <= progress + 0.000001 else { continue }
            // The last visible row at or before the reading position is the
            // current chapter. When its book group is folded, this is the
            // group header; when expanded, it is the chapter inside it.
            best = index
        }
        return best ?? 0
    }

    /// Both states use the same glyph rotated a quarter turn, because the
    /// separate `chevron.down` symbol is optically smaller than
    /// `chevron.right` at the same point size.
    private func rotatedChevron(_ image: NSImage, angle: CGFloat) -> NSImage {
        let side = max(image.size.width, image.size.height)
        let rotated = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: side / 2, y: side / 2)
            context.rotate(by: angle)
            image.draw(
                in: NSRect(
                    x: -image.size.width / 2,
                    y: -image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                )
            )
            return true
        }
        rotated.isTemplate = true
        return rotated
    }

    private func scrollToActiveRow(select: Bool) {
        guard let row = activeRowIndex(), row >= 0, row < rows.count else { return }
        tableView.scrollRowToVisible(row)
        // Leave some upcoming chapters visible below the current one.
        let rowRect = tableView.rect(ofRow: row)
        let offset = max(0, rowRect.minY - tableView.visibleRect.height * 0.35)
        tableView.scroll(NSPoint(x: 0, y: offset))
        if select {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        let entry = rows[row]
        let chapter = entry.item.chapter
        let isGroup = entry.item.isGroup
        let depth = max(entry.depth + chapter.level, 0)
        let cell = NSTableCellView()

        let chevron = NSImageView()
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        if isGroup {
            let expanded = expandedKeys.contains(entry.item.key)
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            let baseImage = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: expanded
                    ? L("收起目录", "Collapse contents")
                    : L("展开目录", "Expand contents")
            )?.withSymbolConfiguration(configuration)
            chevron.image = expanded
                ? baseImage.map { rotatedChevron($0, angle: -.pi / 2) }
                : baseImage
            chevron.imageScaling = .scaleProportionallyUpOrDown
        }

        let label = NSTextField(labelWithString: chapter.title)
        if isGroup {
            label.font = NSFont.systemFont(ofSize: depth == 0 ? 13 : 12, weight: .medium)
            label.textColor = .labelColor
        } else {
            label.font = NSFont.systemFont(ofSize: depth > 0 ? 12 : 13)
            label.textColor = depth > 0 ? .secondaryLabelColor : .labelColor
        }
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(chevron)
        cell.addSubview(label)
        cell.textField = label
        let indent = 10 + CGFloat(depth) * 18
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
            chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent + 19),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func handleClick() {
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < rows.count else { return }
        let entry = rows[clicked]
        guard entry.item.isGroup else {
            onSelect?(entry.item.chapter)
            return
        }
        if expandedKeys.contains(entry.item.key) {
            expandedKeys.remove(entry.item.key)
        } else {
            expandedKeys.insert(entry.item.key)
        }
        let origin = scrollView.contentView.bounds.origin
        rebuildVisibleRows()
        tableView.reloadData()
        scrollView.contentView.scroll(to: origin)
        if let active = activeRowIndex() {
            tableView.selectRowIndexes(IndexSet(integer: active), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }
}

private final class ReaderBookmarksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let deleteButton = NSButton()
    private let addBookmarkButton = NSButton()
    private let addNoteButton = NSButton()
    private let editButton = NSButton()
    private let closeButton = NSButton()
    private var bookmarks: [ReaderBookmark] = []

    var onOpen: ((ReaderBookmark) -> Void)?
    var onDelete: ((ReaderBookmark) -> Void)?
    var onEdit: ((ReaderBookmark) -> Void)?
    var onAddBookmark: (() -> Void)?
    var onAddNote: (() -> Void)?
    var onClose: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 390, height: 470)
        root.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.frame = NSRect(x: 0, y: 0, width: 374, height: 0)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = L("还没有书签或笔记", "No bookmarks or notes yet")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(addBookmarkButton, title: L("加书签", "Bookmark"), action: #selector(addBookmark))
        configure(addNoteButton, title: L("加笔记", "Note"), action: #selector(addNote))
        configure(editButton, title: L("编辑", "Edit"), action: #selector(editSelected))
        editButton.toolTip = L("编辑所选笔记", "Edit the selected note")
        configure(openButton, title: L("打开", "Open"), action: #selector(openSelected))
        configure(deleteButton, title: L("删除", "Delete"), action: #selector(deleteSelected))
        configure(closeButton, title: L("关闭", "Close"), action: #selector(closePanel))
        editButton.isEnabled = false
        openButton.isEnabled = false
        deleteButton.isEnabled = false

        let buttons = NSStackView(views: [
            addBookmarkButton,
            addNoteButton,
            editButton,
            NSView(),
            openButton,
            deleteButton,
            closeButton
        ])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            buttons.heightAnchor.constraint(equalToConstant: 26)
        ])
        view = root
    }

    func setBookmarks(_ bookmarks: [ReaderBookmark]) {
        self.bookmarks = bookmarks
        tableView.deselectAll(nil)
        tableView.reloadData()
        emptyLabel.isHidden = !bookmarks.isEmpty
        editButton.isEnabled = false
        openButton.isEnabled = false
        deleteButton.isEnabled = false
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.target = self
        button.action = action
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        bookmarks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < bookmarks.count else { return nil }
        let bookmark = bookmarks[row]
        let cell = NSTableCellView()
        let primary = NSTextField(labelWithString: "")
        let secondary = NSTextField(labelWithString: "")

        let note = bookmark.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = bookmark.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            primary.stringValue = note.split(separator: "\n").first.map(String.init) ?? note
            primary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            primary.textColor = .labelColor
            var detail = snippet
            if detail.isEmpty {
                detail = L("位置 \(Int(bookmark.progress * 100))%", "Position \(Int(bookmark.progress * 100))%")
            }
            secondary.stringValue = detail + " · " + Self.dateText(bookmark.createdAt)
            secondary.textColor = .secondaryLabelColor
        } else {
            primary.stringValue = snippet.isEmpty
                ? L("位置 \(Int(bookmark.progress * 100))%", "Position \(Int(bookmark.progress * 100))%")
                : snippet
            primary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            primary.textColor = .labelColor
            secondary.stringValue = Self.dateText(bookmark.createdAt)
            secondary.textColor = .secondaryLabelColor
        }
        primary.lineBreakMode = .byTruncatingTail
        secondary.lineBreakMode = .byTruncatingTail
        secondary.font = NSFont.systemFont(ofSize: 10)

        primary.translatesAutoresizingMaskIntoConstraints = false
        secondary.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(primary)
        cell.addSubview(secondary)
        cell.textField = primary
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            primary.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            primary.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 3)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        openButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    private func selectedBookmark() -> ReaderBookmark? {
        let row = tableView.selectedRow
        guard row >= 0, row < bookmarks.count else { return nil }
        return bookmarks[row]
    }

    @objc private func openSelected() {
        guard let bookmark = selectedBookmark() else { return }
        onOpen?(bookmark)
    }

    @objc private func deleteSelected() {
        guard let bookmark = selectedBookmark() else { return }
        onDelete?(bookmark)
    }

    @objc private func editSelected() {
        guard let bookmark = selectedBookmark() else { return }
        onEdit?(bookmark)
    }

    @objc private func addBookmark() {
        onAddBookmark?()
    }

    @objc private func addNote() {
        onAddNote?()
    }

    @objc private func closePanel() {
        onClose?()
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

final class ReaderViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSSearchFieldDelegate {
    private enum PlaceholderState {
        case empty
        case book
        case removed
    }

    /// How the reading area moves. Scroll keeps the original continuous
    /// layout; the two page modes show one screen at a time. Horizontal uses
    /// CSS columns inside the WebView, vertical steps the normal layout by
    /// one viewport, and PDFs switch PDFKit to single-page display.
    private enum PageMode: String, CaseIterable {
        case scroll
        case horizontal
        case vertical
        case spread

        var buttonTitle: String {
            switch self {
            case .scroll:
                return L("滚动", "Scroll")
            case .horizontal:
                return L("左右", "Pages ↔")
            case .vertical:
                return L("上下", "Pages ↕")
            case .spread:
                return L("双页", "Spread")
            }
        }

        var menuTitle: String {
            switch self {
            case .scroll:
                return L("滚动阅读", "Continuous scroll")
            case .horizontal:
                return L("左右翻页", "Flip pages left/right")
            case .vertical:
                return L("上下翻页", "Flip pages up/down")
            case .spread:
                return L("双页漫画", "Two-page comic spread")
            }
        }

        var menuDetail: String {
            switch self {
            case .scroll:
                return L("像网页一样连续读下去", "Keep reading continuously like a web page")
            case .horizontal:
                return L("一页一页左右翻，正文按栏分页", "One page at a time, text flows into columns")
            case .vertical:
                return L("一页一页上下翻，按屏幕高度移动", "One page at a time, moving by one screen")
            case .spread:
                return L("左右两页并排，适合漫画", "Two pages side by side, ideal for comics")
            }
        }
    }

    private let titleLabel = NSTextField(labelWithString: L("选择一本书开始阅读", "Select a book to start reading"))
    private let subtitleLabel = NSTextField(labelWithString: L("支持拖入本地文件，内容保存在你的 Mac 上", "Drag in local files; content stays on your Mac"))
    private let contentView = NSView()
    private let emptyState = NSView()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let showSidebarButton = NSButton()
    private let themeButton = NSButton()
    private let modeButton = NSButton()
    private let tocButton = NSButton()
    private let searchButton = NSButton()
    private let bookmarkButton = NSButton()
    private let findBar = NSVisualEffectView()
    private let findField = NSSearchField()
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private let findResultLabel = NSTextField(labelWithString: "")
    private var findDebounce: DispatchWorkItem?
    private var lastFindQuery = ""
    private var pdfFindMatches: [PDFSelection] = []
    private var pdfFindIndex = -1
    private var tocPopover: NSPopover?
    private var bookmarkPopover: NSPopover?
    private weak var bookmarksController: ReaderBookmarksViewController?
    private var noticeRestoreWorkItem: DispatchWorkItem?
    private var chapterCache: [UUID: [ReaderChapter]] = [:]
    private let pageIndicator = NSView()
    private let pageIndicatorLabel = NSTextField(labelWithString: "")
    /// Opaque cover placed above the reading area while a book is being
    /// parsed and moved to its saved position, so the first page never
    /// flashes before the reader lands on the stored place.
    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(wrappingLabelWithString: "")
    private var overlayTimeout: DispatchWorkItem?
    private var overlayGeneration = 0
    private let emptyMark = NSTextField(labelWithString: "◌")
    private let emptyTitleLabel = NSTextField(labelWithString: L("安静地读一本书", "Read in peace"))
    private let emptySubtitleLabel = NSTextField(labelWithString: L("从左侧导入书籍，或直接把文件拖进窗口", "Import books from the sidebar, or drag files into the window"))
    private var placeholderState: PlaceholderState = .empty
    private var currentBook: LibraryBook?
    private var textView: NSTextView?
    private var pdfView: PDFView?
    private var webView: WKWebView?
    private var comicView: ComicReaderView?
    private var pageMode: PageMode = {
        guard let raw = UserDefaults.standard.string(forKey: "ReaderPageMode"),
              let mode = PageMode(rawValue: raw),
              mode != .spread else {
            return .scroll
        }
        return mode
    }()
    private var comicPageMode: PageMode = {
        guard let raw = UserDefaults.standard.string(forKey: "ReaderComicPageMode"),
              let mode = PageMode(rawValue: raw) else {
            return .spread
        }
        return mode
    }()
    private var activePageMode: PageMode {
        currentBook?.format == "CBZ" ? comicPageMode : pageMode
    }
    private var lastPageInfo: (page: Int, pages: Int)?
    private var readerKeyMonitor: Any?
    private var readerWheelMonitor: Any?
    private var pdfWheelAccumulator: CGFloat = 0
    private var pdfLastWheelTurn: TimeInterval = 0
    private var comicWheelAccumulator: CGFloat = 0
    private var comicLastWheelTurn: TimeInterval = 0
    private var webUserContentController: WKUserContentController?
    private var epubRoot: URL?
    private var comicSchemeHandler: ComicPageSchemeHandler?
    private var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "ReaderFontSize")
        guard stored >= 12, stored <= 32 else { return 18 }
        return CGFloat(stored)
    }()
    private var isDark = UserDefaults.standard.bool(forKey: "ReaderDarkMode")
    private var publisherStyles = UserDefaults.standard.bool(forKey: "ReaderPublisherStyles")
    private var loadGeneration = 0
    private var currentProgress = 0.0
    private var pdfProgressObserver: NSObjectProtocol?
    /// Page the PDF view is being moved to. Page-change notifications that do
    /// not match it are layout artifacts and must not replace the saved
    /// position.
    private var pdfRestoreTargetPage: Int?
    /// The phone's sentence for the position this WebView should open at.
    private var anchorText: String?
    /// `(bookID, rendered scroll fraction, extracted-text fraction, top-of-viewport snippet, isAnchorApplied, isSettled)`.
    /// The text fraction is the metric the phone understands; the scroll
    /// fraction is only how far down the rendered page the WebView is.
    var onProgress: ((UUID, Double, Double?, String?, Bool, Bool) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onThemeChanged: ((Bool) -> Void)?
    var onChaptersRequested: ((LibraryBook, @escaping ([ReaderChapter]) -> Void) -> Void)?
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

        modeButton.bezelStyle = .texturedRounded
        modeButton.imagePosition = .imageLeading
        modeButton.target = self
        modeButton.action = #selector(showPageModeMenu)
        modeButton.setContentHuggingPriority(.required, for: .horizontal)
        modeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateModeButton()

        tocButton.bezelStyle = .texturedRounded
        tocButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        tocButton.imagePosition = .imageOnly
        tocButton.toolTip = L("目录", "Contents")
        tocButton.target = self
        tocButton.action = #selector(showTableOfContents)
        tocButton.setContentHuggingPriority(.required, for: .horizontal)

        searchButton.bezelStyle = .texturedRounded
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchButton.imagePosition = .imageOnly
        searchButton.toolTip = L("在书中查找（⌘F）", "Find in book (⌘F)")
        searchButton.target = self
        searchButton.action = #selector(showFind(_:))
        searchButton.setContentHuggingPriority(.required, for: .horizontal)

        bookmarkButton.bezelStyle = .texturedRounded
        bookmarkButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        bookmarkButton.imagePosition = .imageOnly
        bookmarkButton.toolTip = L("书签与笔记", "Bookmarks & notes")
        bookmarkButton.target = self
        bookmarkButton.action = #selector(showBookmarksTapped)
        bookmarkButton.setContentHuggingPriority(.required, for: .horizontal)

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
            tocButton,
            searchButton,
            bookmarkButton,
            modeButton,
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

        // Floating page counter for the two page modes. It is only shown
        // while a paged book is open and the pager has reported a position.
        pageIndicator.wantsLayer = true
        pageIndicator.layer?.cornerRadius = 11
        pageIndicator.layer?.borderWidth = 1
        pageIndicator.isHidden = true
        pageIndicatorLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pageIndicatorLabel.alignment = .center
        pageIndicator.addSubview(pageIndicatorLabel)
        root.addSubview(pageIndicator)
        pageIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageIndicatorLabel.leadingAnchor.constraint(equalTo: pageIndicator.leadingAnchor, constant: 10),
            pageIndicatorLabel.trailingAnchor.constraint(equalTo: pageIndicator.trailingAnchor, constant: -10),
            pageIndicatorLabel.topAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: 3),
            pageIndicatorLabel.bottomAnchor.constraint(equalTo: pageIndicator.bottomAnchor, constant: -3)
        ])

        findBar.material = .popover
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 9
        findBar.layer?.masksToBounds = true
        findBar.isHidden = true

        findField.placeholderString = L("在书中查找", "Find in book")
        findField.font = NSFont.systemFont(ofSize: 12)
        findField.controlSize = .small
        findField.target = self
        findField.action = #selector(findNext)
        findField.delegate = self
        findField.translatesAutoresizingMaskIntoConstraints = false

        findResultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        findResultLabel.textColor = .secondaryLabelColor
        findResultLabel.alignment = .right
        findResultLabel.lineBreakMode = .byTruncatingTail

        configureFindButton(
            findPrevButton,
            symbol: "chevron.up",
            action: #selector(findPrevious),
            tooltip: L("上一处", "Previous match")
        )
        configureFindButton(
            findNextButton,
            symbol: "chevron.down",
            action: #selector(findNext),
            tooltip: L("下一处", "Next match")
        )
        configureFindButton(
            findCloseButton,
            symbol: "xmark",
            action: #selector(closeFind),
            tooltip: L("关闭查找", "Close find")
        )

        let findStack = NSStackView(views: [
            findField,
            findResultLabel,
            findPrevButton,
            findNextButton,
            findCloseButton
        ])
        findStack.orientation = .horizontal
        findStack.alignment = .centerY
        findStack.spacing = 6
        findStack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(findStack)
        NSLayoutConstraint.activate([
            findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 10),
            findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -10),
            findStack.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(equalToConstant: 210),
            findResultLabel.widthAnchor.constraint(equalToConstant: 74)
        ])
        root.addSubview(findBar)

        // The overlay is the last root subview so it covers the reading
        // area while the book loads and positions itself.
        loadingOverlay.wantsLayer = true
        loadingOverlay.isHidden = true
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingLabel.font = NSFont.systemFont(ofSize: 12)
        loadingLabel.alignment = .center
        loadingLabel.maximumNumberOfLines = 4
        loadingLabel.lineBreakMode = .byWordWrapping
        let overlayStack = NSStackView(views: [loadingSpinner, loadingLabel])
        overlayStack.orientation = .vertical
        overlayStack.alignment = .centerX
        overlayStack.spacing = 10
        loadingOverlay.addSubview(overlayStack)
        root.addSubview(loadingOverlay)
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlayStack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            overlayStack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        findBar.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
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
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageIndicator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            pageIndicator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            findBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            findBar.widthAnchor.constraint(equalToConstant: 430),
            findBar.heightAnchor.constraint(equalToConstant: 40),
            loadingOverlay.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        applyThemeAppearance()
        showEmptyState()
    }

    private func configureFindButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        tooltip: String
    ) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Contents

    @objc private func showTableOfContents() {
        guard let book = currentBook else { return }
        if let popover = tocPopover, popover.isShown {
            popover.close()
            return
        }

        let controller = ReaderChaptersViewController()
        controller.currentProgress = {
            if let pdfView,
               let document = pdfView.document,
               document.pageCount > 1,
               let page = pdfView.currentPage {
                let index = document.index(for: page)
                if index >= 0 {
                    return Double(index) / Double(document.pageCount - 1)
                }
            }
            if let textProgress = currentBook?.textProgress {
                return textProgress
            }
            return currentProgress
        }()
        controller.onSelect = { [weak self] chapter in
            self?.tocPopover?.close()
            self?.jump(to: chapter)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.contentViewController = controller
        tocPopover = popover
        popover.show(relativeTo: tocButton.bounds, of: tocButton, preferredEdge: .minY)

        let emptyMessage = L("这本书没有可用目录", "No contents available")
        if let cached = chapterCache[book.id] {
            controller.setChapters(cached, emptyMessage: emptyMessage)
            return
        }
        guard let provider = onChaptersRequested else {
            controller.setChapters([], emptyMessage: emptyMessage)
            return
        }
        controller.showLoading()
        provider(book) { [weak self, weak controller] chapters in
            DispatchQueue.main.async {
                guard let self, let controller, self.currentBook?.id == book.id else { return }
                self.chapterCache[book.id] = chapters
                controller.setChapters(chapters, emptyMessage: emptyMessage)
            }
        }
    }

    private func jump(to chapter: ReaderChapter) {
        guard let book = currentBook else { return }
        if let comicView,
           let anchorID = chapter.anchorID,
           anchorID.hasPrefix("cbz-page-"),
           let index = Int(anchorID.dropFirst("cbz-page-".count)) {
            comicView.goToPage(index)
            return
        }
        if let pageIndex = chapter.pageIndex,
           let pdfView,
           let document = pdfView.document,
           pageIndex >= 0,
           pageIndex < document.pageCount,
           let page = document.page(at: pageIndex) {
            contentView.layoutSubtreeIfNeeded()
            pdfRestoreTargetPage = pageIndex
            pdfView.go(to: page)
            if pageMode != .scroll {
                // The page-change notification is ignored while
                // `pdfRestoreTargetPage` is set, so refresh the label here.
                updatePageIndicator(page: pageIndex + 1, pages: document.pageCount)
            }
            let progress = document.pageCount > 1
                ? Double(pageIndex) / Double(document.pageCount - 1)
                : 0
            currentProgress = progress
            onProgress?(book.id, progress, nil, nil, false, true)
            DispatchQueue.main.async { [weak self] in
                self?.pdfRestoreTargetPage = nil
            }
            return
        }
        if let anchorID = chapter.anchorID, let webView {
            let literal = Self.javaScriptStringLiteral(anchorID)
            webView.evaluateJavaScript("""
            (function(){
              var el=document.getElementById(\(literal));
              if(!el){return false;}
              var pager=window.__intelReaderPager;
              var rect=el.getBoundingClientRect();
              // A paged layout only shows whole columns/screens, so an
              // element jump must land on the page that holds it instead
              // of scrolling the element merely into view.
              if(pager && pager.isColumnPaged()){pager.goToRect(rect);}
              else if(pager && pager.isPaged()){
                window.scrollTo(0,pager.snapVertical(rect.top+window.scrollY));
              }
              else{el.scrollIntoView({block:'start'});}
              if(window.__intelReaderPostPosition){window.__intelReaderPostPosition(true);}
              return true;
            })();
            """) { [weak self] value, _ in
                guard (value as? Bool) == true else {
                    guard let self, let progress = chapter.progress else { return }
                    self.applyExternalProgress(
                        bookID: book.id,
                        progress: progress,
                        textProgress: progress
                    )
                    return
                }
            }
            return
        }
        if let needle = chapter.locatorText, !needle.isEmpty, let webView {
            let configuration = WKFindConfiguration()
            configuration.backwards = false
            configuration.wraps = true
            configuration.caseSensitive = false
            webView.find(needle, configuration: configuration) { [weak self] result in
                guard result.matchFound else {
                    webView.evaluateJavaScript("window.getSelection().removeAllRanges();")
                    guard let self, let progress = chapter.progress else { return }
                    self.applyExternalProgress(
                        bookID: book.id,
                        progress: progress,
                        textProgress: progress
                    )
                    return
                }
                // Find-in-page stops as soon as the match is visible, which
                // parks a paged reader between two columns. Use the found
                // range's rect to snap to the page that holds the line.
                webView.evaluateJavaScript("""
                (function(){
                  var pager=window.__intelReaderPager;
                  var selection=window.getSelection();
                  var rect=(selection && selection.rangeCount)
                    ? selection.getRangeAt(0).getBoundingClientRect()
                    : null;
                  if(selection){selection.removeAllRanges();}
                  if(pager && rect){
                    if(pager.isColumnPaged()){pager.goToRect(rect);}
                    else if(pager.isPaged()){
                      window.scrollTo(0,pager.snapVertical(rect.top+window.scrollY));
                    }
                  }
                  if(window.__intelReaderPostPosition){window.__intelReaderPostPosition(true);}
                })();
                """)
            }
            return
        }
        if let progress = chapter.progress {
            applyExternalProgress(
                bookID: book.id,
                progress: progress,
                textProgress: progress,
                locatorText: chapter.locatorText
            )
        }
    }

    // MARK: - Find

    func setPublisherStyles(_ enabled: Bool) {
        publisherStyles = enabled
        guard let book = currentBook, book.format == "EPUB" else { return }
        // Re-rendering with the publisher's CSS changes the page grid, so
        // remember the live text position first; the saved `textProgress`
        // may be stale after a TOC jump or page turn that only updated the
        // page indicator.
        guard let webView else {
            show(book: book)
            return
        }
        webView.evaluateJavaScript(
            "(window.__intelReaderPager && window.__intelReaderPager.capturePosition)"
                + " ? window.__intelReaderPager.capturePosition() : null"
        ) { [weak self] result, _ in
            guard let self else { return }
            var target = self.currentBook ?? book
            if let position = result as? [String: Any] {
                if let progress = position["progress"] as? NSNumber {
                    target.progress = min(max(progress.doubleValue, 0), 1)
                }
                // `capturePosition` falls back to the last known text
                // fraction, which can still be the stale zero from opening.
                // Trust it only when it actually moved.
                if let textProgress = position["textFraction"] as? NSNumber,
                   textProgress.doubleValue > 0 {
                    target.textProgress = min(max(textProgress.doubleValue, 0), 1)
                } else {
                    target.textProgress = nil
                }
            } else {
                target.progress = min(max(self.currentProgress, 0), 1)
                target.textProgress = nil
            }
            self.currentBook = target
            self.show(book: target)
        }
    }

    // MARK: - Bookmarks and notes

    @objc private func showBookmarksTapped() {
        showBookmarks()
    }

    func showBookmarks() {
        guard let book = currentBook else { return }
        if let popover = bookmarkPopover, popover.isShown {
            popover.close()
            return
        }

        let controller = ReaderBookmarksViewController()
        controller.onOpen = { [weak self] bookmark in
            self?.bookmarkPopover?.close()
            self?.jump(to: bookmark)
        }
        controller.onDelete = { [weak self] bookmark in
            BookmarkStore.shared.remove(id: bookmark.id)
            self?.refreshBookmarkList()
        }
        controller.onEdit = { [weak self] bookmark in
            self?.editNote(bookmark)
        }
        controller.onAddBookmark = { [weak self] in
            self?.addBookmark()
        }
        controller.onAddNote = { [weak self] in
            self?.addNote()
        }
        controller.onClose = { [weak self] in
            self?.bookmarkPopover?.close()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 470)
        popover.contentViewController = controller
        bookmarkPopover = popover
        bookmarksController = controller
        controller.setBookmarks(BookmarkStore.shared.bookmarks(for: book.path))
        popover.show(
            relativeTo: bookmarkButton.bounds,
            of: bookmarkButton,
            preferredEdge: .minY
        )
    }

    func addBookmark() {
        addBookmark(note: "", snippetOverride: nil)
    }

    private func addBookmark(note: String, snippetOverride: String?) {
        guard let book = currentBook, let location = bookmarkLocation() else { return }
        BookmarkStore.shared.add(
            bookPath: book.path,
            progress: location.progress,
            textProgress: location.textProgress,
            pageIndex: location.pageIndex,
            snippet: snippetOverride ?? location.snippet,
            note: note
        )
        refreshBookmarkList()
        showReaderNotice(
            note.isEmpty
                ? L("已添加书签", "Bookmark added")
                : L("已保存笔记", "Note saved")
        )
    }

    func addNote() {
        guard let book = currentBook else { return }
        bookmarkPopover?.close()
        let bookPath = book.path
        if let pdfView,
           let rawSelection = pdfView.currentSelection?.string {
            let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selection.isEmpty {
                presentNoteEditor(quote: selection, bookPath: bookPath)
                return
            }
        }
        if let webView {
            webView.evaluateJavaScript(
                "window.getSelection ? window.getSelection().toString() : ''"
            ) { [weak self] result, _ in
                guard let self, self.currentBook?.path == bookPath else { return }
                let quote = (result as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    self.presentNoteEditor(quote: quote, bookPath: bookPath)
                }
            }
            return
        }
        presentNoteEditor(quote: "", bookPath: bookPath)
    }

    private func bookmarkLocation() -> (
        progress: Double,
        textProgress: Double?,
        pageIndex: Int?,
        snippet: String
    )? {
        guard let book = currentBook else { return nil }
        if let comicView, book.format == "CBZ" {
            let pageIndex = comicView.currentPage
            return (
                comicView.pageFraction,
                nil,
                pageIndex,
                L("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)")
            )
        }
        if let pdfView, let document = pdfView.document, document.pageCount > 0 {
            // Read the visible page directly: a 265-page document moves only
            // ~0.4% per page, below the progress-report throttle, so
            // `currentProgress` can still describe an older page.
            let fallbackIndex = min(
                max(
                    Int((min(max(currentProgress, 0), 0.999)
                        * Double(max(document.pageCount - 1, 1))).rounded()),
                    0
                ),
                document.pageCount - 1
            )
            let pageIndex = pdfView.currentPage.map { document.index(for: $0) }
                .flatMap { $0 >= 0 ? $0 : nil } ?? fallbackIndex
            let progress = document.pageCount > 1
                ? Double(pageIndex) / Double(document.pageCount - 1)
                : 0
            let selection = (pdfView.currentSelection?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = selection.isEmpty
                ? L("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)")
                : selection
            return (progress, nil, pageIndex, snippet)
        }
        let snippet = (book.localTextAnchor ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let percent = Int(min(max(currentProgress, 0), 1) * 100)
        let fallback = L("位置 \(percent)%", "Position \(percent)%")
        return (
            min(max(currentProgress, 0), 1),
            book.textProgress,
            nil,
            snippet.isEmpty ? fallback : snippet
        )
    }

    private func editNote(_ bookmark: ReaderBookmark) {
        guard let book = currentBook, bookmark.bookPath == book.path else { return }
        let updated = presentNoteEditor(
            quote: bookmark.snippet,
            bookPath: book.path,
            existing: bookmark
        )
        if updated, bookmarkPopover?.isShown != true {
            showBookmarks()
        }
    }

    @discardableResult
    private func presentNoteEditor(
        quote: String,
        bookPath: String,
        existing: ReaderBookmark? = nil
    ) -> Bool {
        let displayQuote = quote.count > 180
            ? String(quote.prefix(180)) + "…"
            : quote
        let alert = NSAlert()
        alert.messageText = existing == nil
            ? L("添加笔记", "Add note")
            : L("编辑笔记", "Edit note")
        alert.informativeText = displayQuote.isEmpty
            ? L("笔记会保存在当前阅读位置。", "The note is saved at the current reading position.")
            : L("“\(displayQuote)”", "“\(displayQuote)”")
        alert.alertStyle = .informational

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = existing?.note ?? ""
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = textView

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let note = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            guard note != existing.note else { return false }
            guard !note.isEmpty else {
                showReaderNotice(L("笔记内容不能为空", "A note cannot be empty"))
                return false
            }
            BookmarkStore.shared.updateNote(id: existing.id, note: note)
            refreshBookmarkList()
            showReaderNotice(L("笔记已更新", "Note updated"))
            return true
        }
        guard !note.isEmpty, currentBook?.path == bookPath else { return false }
        addBookmark(note: note, snippetOverride: quote.isEmpty ? nil : quote)
        return true
    }

    private func refreshBookmarkList() {
        guard let book = currentBook else { return }
        bookmarksController?.setBookmarks(
            BookmarkStore.shared.bookmarks(for: book.path)
        )
    }

    private func jump(to bookmark: ReaderBookmark) {
        guard let book = currentBook, bookmark.bookPath == book.path else { return }
        if let comicView, book.format == "CBZ" {
            if let pageIndex = bookmark.pageIndex {
                comicView.goToPage(pageIndex)
            } else {
                let pageIndex = comicView.pageCount > 1
                    ? Int((min(max(bookmark.progress, 0), 0.999)
                        * Double(comicView.pageCount - 1)).rounded())
                    : 0
                comicView.goToPage(pageIndex)
            }
            return
        }
        if let pageIndex = bookmark.pageIndex,
           let pdfView,
           let document = pdfView.document,
           pageIndex >= 0,
           pageIndex < document.pageCount,
           let page = document.page(at: pageIndex) {
            contentView.layoutSubtreeIfNeeded()
            pdfRestoreTargetPage = pageIndex
            pdfView.go(to: page)
            if pageMode != .scroll {
                // The page-change notification is ignored while
                // `pdfRestoreTargetPage` is set, so refresh the label here.
                updatePageIndicator(page: pageIndex + 1, pages: document.pageCount)
            }
            let progress = document.pageCount > 1
                ? Double(pageIndex) / Double(document.pageCount - 1)
                : 0
            currentProgress = progress
            onProgress?(book.id, progress, nil, nil, false, true)
            DispatchQueue.main.async { [weak self] in
                self?.pdfRestoreTargetPage = nil
            }
            return
        }
        applyExternalProgress(
            bookID: book.id,
            progress: bookmark.progress,
            textProgress: bookmark.textProgress
        )
    }

    private func showReaderNotice(_ message: String) {
        noticeRestoreWorkItem?.cancel()
        let original = subtitleLabel.stringValue
        subtitleLabel.stringValue = message
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.subtitleLabel.stringValue == message else { return }
            self.subtitleLabel.stringValue = original
        }
        noticeRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    @objc func showFind(_ sender: Any?) {
        guard currentBook != nil else { return }
        if comicView != nil {
            showReaderNotice(L("漫画模式不支持文字查找", "Text search is not available for comics"))
            return
        }
        findBar.isHidden = false
        view.window?.makeFirstResponder(findField)
        if let editor = findField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: findField.stringValue.utf16.count)
        }
    }

    @objc private func closeFind() {
        findBar.isHidden = true
        findDebounce?.cancel()
        findResultLabel.stringValue = ""
        pdfFindMatches = []
        pdfFindIndex = -1
        lastFindQuery = ""
        pdfView?.highlightedSelections = nil
        findField.stringValue = ""
        if let webView {
            view.window?.makeFirstResponder(webView)
        } else if let pdfView {
            view.window?.makeFirstResponder(pdfView)
        }
    }

    @objc private func findNext() {
        performFind(forward: true)
    }

    @objc private func findPrevious() {
        performFind(forward: false)
    }

    private func performFind(forward: Bool) {
        let query = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            findResultLabel.stringValue = ""
            pdfView?.highlightedSelections = nil
            return
        }

        if let pdfView, let document = pdfView.document {
            if query != lastFindQuery || pdfFindMatches.isEmpty {
                pdfFindMatches = document.findString(query, withOptions: [.caseInsensitive])
                pdfFindIndex = -1
                lastFindQuery = query
                pdfView.highlightedSelections = pdfFindMatches.isEmpty ? nil : pdfFindMatches
            }
            guard !pdfFindMatches.isEmpty else {
                findResultLabel.stringValue = L("无结果", "No match")
                return
            }
            if pdfFindIndex < 0 {
                pdfFindIndex = forward ? 0 : pdfFindMatches.count - 1
            } else {
                pdfFindIndex = (pdfFindIndex + (forward ? 1 : -1) + pdfFindMatches.count)
                    % pdfFindMatches.count
            }
            pdfView.go(to: pdfFindMatches[pdfFindIndex])
            findResultLabel.stringValue = "\(pdfFindIndex + 1) / \(pdfFindMatches.count)"
            return
        }

        guard let webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { [weak self] result in
            DispatchQueue.main.async {
                self?.findResultLabel.stringValue = result.matchFound
                    ? L("已找到", "Found")
                    : L("无结果", "No match")
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === findField else { return }
        findDebounce?.cancel()
        lastFindQuery = ""
        pdfFindMatches = []
        pdfFindIndex = -1
        let work = DispatchWorkItem { [weak self] in
            self?.performFind(forward: true)
        }
        findDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func sourceLabel(for book: LibraryBook) -> String {
        switch book.source {
        case .iCloud:
            return "iCloud"
        case .jianguoyun:
            return L("WebDAV", "WebDAV")
        case .local:
            return L("本地文件", "Local file")
        }
    }

    /// The phone's sentence is only trusted while this Mac's saved position is
    /// still the one it belongs to. As soon as the user reads further the sync
    /// layer clears it.
    private static func anchorText(for book: LibraryBook) -> String? {
        guard book.format != "PDF" else { return nil }
        guard let text = book.zenLocatorText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let anchor = book.zenLocatorAnchor,
              abs(anchor - (book.textProgress ?? book.progress)) <= 0.02 else {
            return nil
        }
        return text
    }

    func show(book: LibraryBook) {
        loadGeneration += 1
        let generation = loadGeneration
        currentBook = book
        comicSchemeHandler = nil
        updateModeButton()
        tocPopover?.close()
        bookmarkPopover?.close()
        findDebounce?.cancel()
        findBar.isHidden = true
        findField.stringValue = ""
        findResultLabel.stringValue = ""
        lastFindQuery = ""
        pdfFindMatches = []
        pdfFindIndex = -1
        placeholderState = .book
        // Web books open at the extracted-text fraction when a sync has stored
        // one; it is the metric the phone's position was converted into.
        // Books read by older builds fall back to the rendered scroll fraction.
        let webProgress = book.textProgress ?? book.progress
        currentProgress = min(max(webProgress, 0), 0.999)
        anchorText = Self.anchorText(for: book)
        titleLabel.stringValue = book.title
        subtitleLabel.stringValue = "\(book.format) · \(sourceLabel(for: book))"
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
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let text = try BookImporter.plainText(from: url)
                        let html = try BookImporter.plainTextHTML(
                            title: book.title,
                            text: text,
                            fontSize: fontSize,
                            isDark: isDark
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: result, progress: webProgress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "MD":
            showLoading(message: L("正在打开 Markdown…", "Opening Markdown…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let text = try BookImporter.plainText(from: url)
                        let html = try BookImporter.markdownHTML(
                            title: book.title,
                            text: text,
                            fontSize: fontSize,
                            isDark: isDark,
                            sourceURL: url
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: result, progress: webProgress)
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
            showLoading(message: L("正在打开 EPUB…", "Opening EPUB…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            let publisherStyles = self.publisherStyles
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let html = try BookImporter.epubHTML(
                            from: url,
                            fontSize: fontSize,
                            isDark: isDark,
                            publisherStyles: publisherStyles
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showEPUB(result: result, progress: webProgress)
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
                "正在打开 \(book.format)…\n首次打开需要解析，之后会直接打开",
                "Opening \(book.format)…\nThe first open parses the book; later opens are immediate"
            ))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let html = try BookImporter.mobiHTML(
                            from: url,
                            fontSize: fontSize,
                            isDark: isDark
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showEPUB(result: result, progress: webProgress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "FB2":
            showLoading(message: L("正在打开 FB2…", "Opening FB2…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let html = try BookImporter.fb2HTML(
                            from: url,
                            fontSize: fontSize,
                            isDark: isDark
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: result, progress: webProgress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "CBZ":
            if comicPageMode == .scroll {
                showLoading(message: L("正在打开漫画…", "Opening comic…"))
                let url = URL(fileURLWithPath: book.path)
                let fontSize = self.fontSize
                let isDark = self.isDark
                guard let handler = try? ComicPageSchemeHandler(url: url) else {
                    showUnsupported(message: ReaderError.comicInvalid.localizedDescription)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let result: (htmlURL: URL, accessRoot: URL)
                        if let cached = BookImporter.cachedReaderHTML(for: url) {
                            result = cached
                        } else {
                            let html = try BookImporter.cbzHTML(
                                from: url,
                                fontSize: fontSize,
                                isDark: isDark
                            )
                            result = BookImporter.storeReaderHTML(html, for: url)
                        }
                        DispatchQueue.main.async {
                            guard let self, self.loadGeneration == generation else { return }
                            self.comicSchemeHandler = handler
                            self.showTextHTML(result: result, progress: webProgress)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            guard let self, self.loadGeneration == generation else { return }
                            self.showUnsupported(message: error.localizedDescription)
                        }
                    }
                }
            } else {
                showNativeComic(book: book, url: URL(fileURLWithPath: book.path))
            }
        case "RTF":
            showLoading(message: L("正在打开 RTF…", "Opening RTF…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let html = try BookImporter.rtfHTML(
                            from: url,
                            fontSize: fontSize,
                            isDark: isDark
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: result, progress: webProgress)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showUnsupported(message: error.localizedDescription)
                    }
                }
            }
        case "DOCX":
            showLoading(message: L("正在打开 DOCX…", "Opening DOCX…"))
            let url = URL(fileURLWithPath: book.path)
            let fontSize = self.fontSize
            let isDark = self.isDark
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let result: (htmlURL: URL, accessRoot: URL)
                    if let cached = BookImporter.cachedReaderHTML(for: url) {
                        result = cached
                    } else {
                        let html = try BookImporter.docxHTML(
                            from: url,
                            fontSize: fontSize,
                            isDark: isDark
                        )
                        result = BookImporter.storeReaderHTML(html, for: url)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        self.showTextHTML(result: result, progress: webProgress)
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

    private func showNativeComic(book: LibraryBook, url: URL) {
        do {
            let view = try ComicReaderView(url: url, spread: comicPageMode == .spread)
            view.isDark = isDark
            let saved = min(max(book.progress, 0), 0.999)
            let start = view.pageCount > 1
                ? Int((saved * Double(view.pageCount - 1)).rounded())
                : 0
            view.onPageChanged = { [weak self] first, last, total in
                self?.comicPageDidChange(
                    book: book,
                    first: first,
                    last: last,
                    total: total
                )
            }
            clearContent()
            emptyState.isHidden = true
            contentView.isHidden = false
            addContent(view)
            comicView = view
            showPositioningOverlay(hasSavedPosition: start > 0)
            view.goToPage(start)
            // Let the first page render before the cover is lifted, so the
            // comic never flashes an earlier page on the way to the saved one.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.comicView === view else { return }
                self.hideLoadingOverlay()
            }
        } catch {
            showUnsupported(message: ReaderError.comicInvalid.localizedDescription)
        }
    }

    private func comicPageDidChange(
        book: LibraryBook,
        first: Int,
        last: Int,
        total: Int
    ) {
        guard currentBook?.id == book.id else { return }
        let fraction = total > 1
            ? Double(first) / Double(total - 1)
            : 0
        currentProgress = fraction
        if var updated = currentBook {
            updated.progress = fraction
            currentBook = updated
        }
        updateComicPageIndicator(first: first, last: last, total: total)
        onProgress?(
            book.id,
            fraction,
            nil,
            L("第 \(first + 1) 页", "Page \(first + 1)"),
            false,
            true
        )
    }

    private func updateComicPageIndicator(first: Int, last: Int, total: Int) {
        guard total > 0 else {
            hidePageIndicator()
            return
        }
        let start = min(max(first + 1, 1), total)
        let end = min(max(last + 1, start), total)
        lastPageInfo = (start, total)
        pageIndicatorLabel.stringValue = end > start
            ? "\(start)–\(end) / \(total)"
            : "\(start) / \(total)"
        pageIndicator.toolTip = end > start
            ? L("第 \(start)–\(end) 页，共 \(total) 页", "Pages \(start)–\(end) of \(total)")
            : L("第 \(start) 页，共 \(total) 页", "Page \(start) of \(total)")
        pageIndicator.isHidden = false
    }

    private func showPDF(document: PDFDocument, progress: Double) {
        clearContent()
        let viewer = PDFView()
        viewer.autoScales = true
        viewer.displayMode = pageMode == .scroll ? .singlePageContinuous : .singlePage
        viewer.backgroundColor = isDark ? NSColor(calibratedWhite: 0.1, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        viewer.document = document
        let click = NSClickGestureRecognizer(target: self, action: #selector(handlePDFClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        viewer.addGestureRecognizer(click)
        addContent(viewer)
        pdfView = viewer
        showPositioningOverlay(hasSavedPosition: progress > 0.0005)
        guard document.pageCount > 0 else {
            hideLoadingOverlay()
            return
        }
        // `progress` is the zero-based page fraction (page / (count - 1)),
        // the same metric the sync uses, so round rather than floor to
        // avoid opening one page early.
        let pageIndex = min(
            document.pageCount - 1,
            max(0, Int((min(max(progress, 0), 0.999) * Double(document.pageCount - 1)).rounded()))
        )
        // PDFView silently clips `go(to:)` while its scroll view still has a
        // zero size: the jump lands near the top of the document instead, and
        // that page change would then overwrite the saved position (the
        // "46% shelf, 4% after clicking" bug). Lay out first, then jump.
        contentView.layoutSubtreeIfNeeded()
        pdfRestoreTargetPage = pageIndex
        viewer.go(to: document.page(at: pageIndex) ?? document.page(at: 0)!)
        if pageMode != .scroll {
            updatePageIndicator(page: pageIndex + 1, pages: document.pageCount)
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
            if let target = self.pdfRestoreTargetPage {
                // The first layout pass can report an intermediate page before
                // the requested page is reached; never save that transient one.
                if pageIndex == target {
                    self.pdfRestoreTargetPage = nil
                    self.hideLoadingOverlay()
                }
                return
            }
            self.updatePageIndicator(page: pageIndex + 1, pages: document.pageCount)
            self.reportProgress(Double(pageIndex) / Double(document.pageCount - 1))
        }
        // If the window was not laid out yet, retry once on the next turn.
        DispatchQueue.main.async { [weak self, weak viewer] in
            guard let self, let viewer, self.pdfView === viewer,
                  let document = viewer.document,
                  let target = self.pdfRestoreTargetPage else {
                self?.hideLoadingOverlay()
                return
            }
            if let current = viewer.currentPage, document.index(for: current) == target {
                self.pdfRestoreTargetPage = nil
                self.hideLoadingOverlay()
                return
            }
            self.contentView.layoutSubtreeIfNeeded()
            if let page = document.page(at: target) {
                viewer.go(to: page)
            }
            self.pdfRestoreTargetPage = nil
            self.hideLoadingOverlay()
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
        controller.add(self, name: "readerPageInfo")
        controller.add(self, name: "readerReady")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        if let comicSchemeHandler {
            configuration.setURLSchemeHandler(
                comicSchemeHandler,
                forURLScheme: ComicPageSchemeHandler.scheme
            )
        }
        let browser = WKWebView(frame: .zero, configuration: configuration)
        // Keep the WebView on a fixed appearance. When it inherited the
        // app's light/dark appearance, WebKit deferred its next paint for
        // seconds on a long book, so the reading page trailed the shelf
        // during a theme switch. The page is themed entirely through CSS.
        browser.appearance = NSAppearance(named: .aqua)
        browser.navigationDelegate = self
        browser.setValue(false, forKey: "drawsBackground")
        browser.loadFileURL(result.htmlURL, allowingReadAccessTo: result.accessRoot)
        addContent(browser)
        webView = browser
        webUserContentController = controller
        currentProgress = min(max(progress, 0), 0.999)
        showPositioningOverlay(hasSavedPosition: progress > 0.0005)
    }

    private var secondaryTextColor: NSColor {
        isDark ? NSColor(calibratedWhite: 0.64, alpha: 1) : NSColor.secondaryLabelColor
    }

    private func showLoading(message: String) {
        showMessage(message, color: secondaryTextColor)
        showLoadingOverlay(message)
    }

    /// Shows the opaque loading cover. Parsing stages call it with their own
    /// message; once a viewer exists it switches to the positioning message
    /// and waits for the page to report that the saved place is on screen.
    private func showLoadingOverlay(_ message: String) {
        overlayGeneration += 1
        overlayTimeout?.cancel()
        loadingLabel.stringValue = message
        loadingOverlay.layer?.removeAllAnimations()
        loadingOverlay.alphaValue = 1
        loadingOverlay.isHidden = false
        loadingSpinner.startAnimation(nil)
        let work = DispatchWorkItem { [weak self] in
            // Safety net: a broken book must not leave the reader covered.
            self?.hideLoadingOverlay(animated: false)
        }
        overlayTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func showPositioningOverlay(hasSavedPosition: Bool) {
        showLoadingOverlay(
            hasSavedPosition
                ? L("正在回到上次阅读的位置…", "Returning to where you left off…")
                : L("正在排版…", "Laying out pages…")
        )
    }

    private func hideLoadingOverlay(animated: Bool = true) {
        overlayTimeout?.cancel()
        overlayTimeout = nil
        guard !loadingOverlay.isHidden else { return }
        overlayGeneration += 1
        let generation = overlayGeneration
        guard animated else {
            loadingOverlay.isHidden = true
            loadingOverlay.alphaValue = 1
            loadingSpinner.stopAnimation(nil)
            return
        }
        // A short fade hides the switch from the overlay to the positioned
        // page without letting the first page flash through.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            self.loadingOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.overlayGeneration == generation else { return }
            self.loadingOverlay.isHidden = true
            self.loadingOverlay.alphaValue = 1
            self.loadingSpinner.stopAnimation(nil)
        })
    }

    private func showUnsupported(message: String) {
        showMessage(message, color: secondaryTextColor)
    }

    private func showMessage(_ message: String, color: NSColor) {
        hideLoadingOverlay(animated: false)
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
        pdfRestoreTargetPage = nil
        webUserContentController?.removeScriptMessageHandler(forName: "readerProgress")
        webUserContentController?.removeScriptMessageHandler(forName: "readerPageInfo")
        webUserContentController?.removeScriptMessageHandler(forName: "readerReady")
        webUserContentController = nil
        contentView.subviews.forEach { $0.removeFromSuperview() }
        textView = nil
        pdfView = nil
        webView = nil
        comicView = nil
        epubRoot = nil
        findBar.isHidden = true
        tocPopover?.close()
        bookmarkPopover?.close()
        hidePageIndicator()
    }

    private func showEmptyState() {
        comicSchemeHandler = nil
        placeholderState = .empty
        titleLabel.stringValue = L("选择一本书开始阅读", "Select a book to start reading")
        subtitleLabel.stringValue = L("支持拖入本地文件，内容保存在你的 Mac 上", "Drag in local files; content stays on your Mac")
        clearContent()
        hideLoadingOverlay(animated: false)
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

    func handleLibraryCleared() {
        currentBook = nil
        currentProgress = 0
        placeholderState = .removed
        titleLabel.stringValue = L("书架已清空", "Library cleared")
        subtitleLabel.stringValue = L("书籍文件仍然保留在原来的文件夹中", "Book files remain in their original folders")
        emptyState.isHidden = true
        contentView.isHidden = false
        showMessage(
            L("只清除了 EasyRead 的书架记录\n没有删除任何书籍文件或云端进度",
              "Only EasyRead's bookshelf records were cleared\nNo book files or cloud positions were deleted"),
            color: secondaryTextColor
        )
    }

    /// When the user switches to another library, a book from the previous
    /// library must not stay open behind the new shelf.
    func closeBookIfNotInLibrary(_ bookIDs: Set<UUID>) {
        guard let currentBook, !bookIDs.contains(currentBook.id) else { return }
        self.currentBook = nil
        currentProgress = 0
        loadGeneration += 1
        showEmptyState()
    }

    func applyLanguage() {
        showSidebarButton.title = L("显示书架", "Show Library")
        showSidebarButton.toolTip = L("显示左侧书架（⌘⇧S）", "Show sidebar (⌘⇧S)")
        themeButton.title = isDark ? L("日间", "Day") : L("夜间", "Night")
        themeButton.toolTip = isDark
            ? L("切换到浅色阅读", "Switch to light reading")
            : L("切换到夜间阅读", "Switch to night reading")
        updateModeButton()
        if let lastPageInfo {
            updatePageIndicator(page: lastPageInfo.page, pages: lastPageInfo.pages)
        }
        emptyTitleLabel.stringValue = L("安静地读一本书", "Read in peace")
        emptySubtitleLabel.stringValue = L(
            "从左侧导入书籍，或直接把文件拖进窗口",
            "Import books from the sidebar, or drag files into the window"
        )

        switch placeholderState {
        case .book:
            if let currentBook {
                subtitleLabel.stringValue = "\(currentBook.format) · \(sourceLabel(for: currentBook))"
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
        loadingOverlay.layer?.backgroundColor = background.cgColor
        loadingLabel.textColor = isDark ? NSColor(calibratedWhite: 0.62, alpha: 1) : NSColor.secondaryLabelColor
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
        comicView?.isDark = isDark
        pageIndicator.layer?.backgroundColor = isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 0.92).cgColor
            : NSColor(calibratedWhite: 0.98, alpha: 0.94).cgColor
        pageIndicator.layer?.borderColor = isDark
            ? NSColor(calibratedWhite: 0.32, alpha: 0.9).cgColor
            : NSColor(calibratedWhite: 0.72, alpha: 0.7).cgColor
        pageIndicatorLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.78, alpha: 1)
            : NSColor(calibratedWhite: 0.34, alpha: 1)
        themeButton.title = isDark ? L("日间", "Day") : L("夜间", "Night")
        themeButton.image = NSImage(systemSymbolName: isDark ? "sun.max" : "moon", accessibilityDescription: nil)
        themeButton.toolTip = isDark
            ? L("切换到浅色阅读", "Switch to light reading")
            : L("切换到夜间阅读", "Switch to night reading")
        applyWebViewReaderStyle(reflow: false)
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
        let muted = isDark ? "#9b9b92" : "#70756f"
        let link = isDark ? "#9cc7b0" : "#3f7560"
        let rule = isDark ? "#3a3b36" : "#d9d8d0"
        let codeBackground = isDark ? "rgba(255,255,255,0.075)" : "rgba(35,40,35,0.055)"
        let quoteBackground = isDark ? "rgba(255,255,255,0.035)" : "rgba(35,40,35,0.03)"
        return """
        document.body.style.background='\(background)';
        document.body.style.color='\(foreground)';
        document.body.style.fontSize='\(Int(fontSize))px';
        var readerRoot = document.documentElement;
        readerRoot.style.setProperty('color-scheme', '\(isDark ? "dark" : "light")');
        readerRoot.style.setProperty('--reader-link', '\(link)');
        readerRoot.style.setProperty('--reader-muted', '\(muted)');
        readerRoot.style.setProperty('--reader-rule', '\(rule)');
        readerRoot.style.setProperty('--reader-code-bg', '\(codeBackground)');
        readerRoot.style.setProperty('--reader-quote-bg', '\(quoteBackground)');
        var page = document.querySelector('.page');
        if (page) { page.style.fontSize='\(Int(fontSize))px'; }
        """
    }

    private func applyWebViewReaderStyle(reflow: Bool = true) {
        guard let webView else { return }
        // A font-size change must re-paginate, so capture the text position
        // and let `afterStyleChange` lay the book out again. A theme change
        // only swaps colors: re-paginating a long book here kept the reader
        // seconds behind the shelf.
        let script = reflow
            ? """
            (function() {
              var pager = window.__intelReaderPager;
              if (pager && pager.applyFontSize) {
                // The pager resizes immediately and coalesces the expensive
                // re-pagination, so rapid A+/A- clicks stay responsive.
                pager.applyFontSize(\(Int(fontSize)));
                return;
              }
              var position = (pager && pager.capturePosition)
                ? pager.capturePosition()
                : null;
              \(webReaderStyleScript)
              if (pager && pager.afterStyleChange) {
                pager.afterStyleChange(position);
              }
            })();
            """
            : """
            (function() {
              \(webReaderStyleScript)
              if (window.__intelReaderPager && window.__intelReaderPager.refreshTheme) {
                window.__intelReaderPager.refreshTheme();
              }
            })();
            """
        webView.evaluateJavaScript(script)
    }

    private func updateModeButton() {
        let mode = activePageMode
        modeButton.title = mode.buttonTitle
        let symbol = mode == .scroll ? "book" : "book.pages"
        modeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        modeButton.toolTip = "\(mode.menuTitle) · \(mode.menuDetail)"
    }

    @objc private func showPageModeMenu() {
        let menu = NSMenu()
        let modes: [PageMode] = currentBook?.format == "CBZ"
            ? [.scroll, .spread, .horizontal, .vertical]
            : [.scroll, .horizontal, .vertical]
        for mode in modes {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(choosePageMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == activePageMode ? .on : .off
            item.toolTip = mode.menuDetail
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(
            title: L("翻页键：← → ↑ ↓ · PageUp/PageDown · 空格",
                     "Page keys: ← → ↑ ↓ · PageUp/PageDown · Space"),
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: modeButton.bounds.height + 4),
            in: modeButton
        )
    }

    @objc private func choosePageMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PageMode(rawValue: raw) else { return }
        setPageMode(mode)
    }

    private func setPageMode(_ mode: PageMode) {
        if currentBook?.format == "CBZ" {
            guard mode != comicPageMode else { return }
            comicPageMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "ReaderComicPageMode")
        } else {
            guard mode != pageMode, mode != .spread else { return }
            pageMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "ReaderPageMode")
        }
        updateModeButton()
        applyPageModeToContent()
        if activePageMode == .scroll {
            hidePageIndicator()
        } else if let pdfView, let document = pdfView.document, document.pageCount > 0 {
            let index = pdfView.currentPage.map { document.index(for: $0) } ?? 0
            updatePageIndicator(page: index + 1, pages: document.pageCount)
        }
    }

    /// Applies the current mode to the content already on screen. New web
    /// books receive the mode with their `didFinish` script and new PDFs when
    /// `showPDF` picks the display mode.
    private func applyPageModeToContent() {
        if currentBook?.format == "CBZ" {
            guard let book = currentBook else { return }
            var updated = book
            if let comicView {
                updated.progress = comicView.pageFraction
            }
            currentBook = updated
            show(book: updated)
            return
        }
        if let webView {
            webView.evaluateJavaScript(
                "window.__intelReaderSetMode && window.__intelReaderSetMode('\(pageMode.rawValue)');"
            )
        }
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        pdfView.displayMode = pageMode == .scroll ? .singlePageContinuous : .singlePage
        contentView.layoutSubtreeIfNeeded()
        if let page = document.page(at: current) {
            // Same page in a different display mode: the page-change
            // notification that follows reports nothing new.
            pdfView.go(to: page)
        }
    }

    private func updatePageIndicator(page: Int, pages: Int) {
        guard pageMode != .scroll, pages > 0, currentBook != nil else {
            hidePageIndicator()
            return
        }
        let clampedPage = min(max(page, 1), pages)
        lastPageInfo = (clampedPage, pages)
        pageIndicatorLabel.stringValue = "\(clampedPage) / \(pages)"
        pageIndicator.toolTip = L(
            "第 \(clampedPage) 页，共 \(pages) 页",
            "Page \(clampedPage) of \(pages)"
        )
        pageIndicator.isHidden = false
    }

    private func hidePageIndicator() {
        lastPageInfo = nil
        pageIndicator.isHidden = true
    }

    // MARK: Paged navigation

    @objc private func handlePDFClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, pageMode != .scroll,
              let viewer = pdfView, viewer.bounds.width > 0 else { return }
        let x = gesture.location(in: viewer).x
        if x < viewer.bounds.width * 0.15 {
            turnPDFPage(-1)
        } else if x > viewer.bounds.width * 0.85 {
            turnPDFPage(1)
        }
    }

    private func turnPDFPage(_ delta: Int) {
        guard pageMode != .scroll,
              let viewer = pdfView,
              let document = viewer.document,
              document.pageCount > 1 else { return }
        let current = viewer.currentPage.map { document.index(for: $0) } ?? 0
        let target = min(document.pageCount - 1, max(0, current + delta))
        guard target != current, let page = document.page(at: target) else { return }
        viewer.go(to: page)
        updatePageIndicator(page: target + 1, pages: document.pageCount)
    }

    private func turnPage(_ delta: Int) {
        if let comicView {
            if delta < 0 {
                comicView.previousPage()
            } else {
                comicView.nextPage()
            }
            return
        }
        if currentBook?.format == "PDF" {
            turnPDFPage(delta)
            return
        }
        webView?.evaluateJavaScript(
            "window.__intelReaderTurnPage && window.__intelReaderTurnPage(\(delta));"
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if readerKeyMonitor == nil {
            readerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleReaderKey(event) ? nil : event
            }
        }
        if readerWheelMonitor == nil {
            readerWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleReaderWheel(event) ? nil : event
            }
        }
    }

    private func handleReaderKey(_ event: NSEvent) -> Bool {
        guard currentBook != nil, event.window === view.window,
              activePageMode != .scroll else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        // Never steal keystrokes from a text field, such as the sidebar
        // search box while the shelf is visible.
        if let editor = view.window?.firstResponder as? NSTextView, editor.isEditable {
            return false
        }
        let delta: Int
        switch event.keyCode {
        case 123, 126, 116:
            delta = -1
        case 124, 125, 121:
            delta = 1
        case 49:
            delta = flags.contains(.shift) ? -1 : 1
        default:
            return false
        }
        turnPage(delta)
        return true
    }

    private func handleReaderWheel(_ event: NSEvent) -> Bool {
        if let comicView {
            return handleComicWheel(event, comic: comicView)
        }
        return handlePDFWheel(event)
    }

    private func handleComicWheel(_ event: NSEvent, comic: ComicReaderView) -> Bool {
        guard activePageMode != .scroll, event.window === view.window else { return false }
        let point = comic.convert(event.locationInWindow, from: nil)
        guard comic.bounds.contains(point) else { return false }
        if event.phase == .began { comicWheelAccumulator = 0 }
        let travel = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        comicWheelAccumulator += travel
        guard abs(comicWheelAccumulator) >= 40 else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - comicLastWheelTurn > 0.35 else { return false }
        if comicWheelAccumulator > 0 {
            comic.previousPage()
        } else {
            comic.nextPage()
        }
        comicWheelAccumulator = 0
        comicLastWheelTurn = now
        return true
    }

    private func handlePDFWheel(_ event: NSEvent) -> Bool {
        guard pageMode != .scroll,
              let viewer = pdfView,
              event.window === view.window else { return false }
        let point = viewer.convert(event.locationInWindow, from: nil)
        guard viewer.bounds.contains(point) else { return false }
        if event.phase == .began { pdfWheelAccumulator = 0 }
        let travel = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        pdfWheelAccumulator += travel
        guard abs(pdfWheelAccumulator) >= 40 else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - pdfLastWheelTurn > 0.55 else { return false }
        // Scrolling up shows the previous page, like any paged reader.
        let delta = pdfWheelAccumulator > 0 ? -1 : 1
        pdfWheelAccumulator = 0
        pdfLastWheelTurn = now
        turnPDFPage(delta)
        return true
    }

    deinit {
        if let readerKeyMonitor { NSEvent.removeMonitor(readerKeyMonitor) }
        if let readerWheelMonitor { NSEvent.removeMonitor(readerWheelMonitor) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "readerReady" {
            // The page applies the stored position before posting this; only
            // a message from the live WebView may lift the loading cover.
            if message.webView === webView {
                hideLoadingOverlay()
            }
            return
        }
        if message.name == "readerPageInfo" {
            if let payload = message.body as? [String: Any],
               let page = payload["page"] as? NSNumber,
               let pages = payload["pages"] as? NSNumber {
                updatePageIndicator(page: page.intValue, pages: pages.intValue)
            }
            return
        }
        guard message.name == "readerProgress" else { return }
        if let value = message.body as? NSNumber {
            reportProgress(value.doubleValue)
            return
        }
        guard let payload = message.body as? [String: Any],
              let value = payload["progress"] as? NSNumber else { return }
        if let page = payload["page"] as? NSNumber,
           let pages = payload["pages"] as? NSNumber {
            updatePageIndicator(page: page.intValue, pages: pages.intValue)
        }
        let snippet = (payload["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textProgress = (payload["textProgress"] as? NSNumber)?.doubleValue
        let anchored = (payload["anchored"] as? Bool) ?? false
        let settled = (payload["settled"] as? Bool) ?? false
        reportProgress(
            value.doubleValue,
            textProgress: textProgress,
            snippet: (snippet?.isEmpty ?? true) ? nil : snippet,
            anchored: anchored,
            settled: settled
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Markdown notes often point at web pages. Opening them in the system
        // browser keeps the book from being replaced by the linked page inside
        // the reader.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let progress = min(max(currentProgress, 0), 0.999)
        let currentTextFraction: Double? = {
            guard let book = currentBook, book.format != "PDF" else { return nil }
            return book.textProgress.map { min(max($0, 0), 1) }
        }()
        let needle = anchorText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let script = ReaderPagerScript.didFinishScript(
            styleScript: webReaderStyleScript,
            fallbackProgress: progress,
            textFraction: currentTextFraction,
            needleLiteral: Self.javaScriptStringLiteral(needle),
            hasAnchor: !needle.isEmpty,
            pageMode: pageMode.rawValue
        )
        webView.evaluateJavaScript(script)
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    func applyExternalProgress(
        bookID: UUID,
        progress: Double,
        textProgress: Double? = nil,
        locatorText: String? = nil
    ) {
        guard currentBook?.id == bookID else { return }
        let value = min(max(progress, 0), 1)
        currentProgress = value
        currentBook?.progress = value
        if let textProgress, var book = currentBook, book.format != "PDF" {
            book.textProgress = min(max(textProgress, 0), 1)
            currentBook = book
        }
        let needle = (locatorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        anchorText = needle.isEmpty ? nil : needle
        if let pdfView, let document = pdfView.document, document.pageCount > 1 {
            let index = min(
                document.pageCount - 1,
                max(0, Int((value * Double(document.pageCount - 1)).rounded()))
            )
            if let page = document.page(at: index) {
                // This jump carries the cloud timestamp; the page-change
                // notification it causes must not rewrite the position with a
                // fresh local timestamp.
                pdfRestoreTargetPage = index
                pdfView.go(to: page)
                DispatchQueue.main.async { [weak self] in
                    self?.pdfRestoreTargetPage = nil
                }
            }
            return
        }
        if let webView {
            let needleLiteral = Self.javaScriptStringLiteral(needle)
            let textFractionLiteral = currentBook?.textProgress.map {
                "\(min(max($0, 0), 1))"
            } ?? "null"
            let script = """
            if (window.__intelReaderGoTo) {
              window.__intelReaderGoTo(\(needleLiteral), \(value), \(textFractionLiteral));
            } else {
              var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
              window.scrollTo(0, max * \(value));
            }
            """
            webView.evaluateJavaScript(script)
        }
    }

    private func reportProgress(
        _ progress: Double,
        textProgress: Double? = nil,
        snippet: String? = nil,
        anchored: Bool = false,
        settled: Bool = false
    ) {
        let value = min(max(progress, 0), 1)
        let textValue = textProgress.map { min(max($0, 0), 1) }
        if anchored {
            currentProgress = value
            if var book = currentBook {
                book.progress = value
                if let textValue, book.format != "PDF" {
                    book.textProgress = textValue
                }
                currentBook = book
                onProgress?(book.id, value, textValue, snippet, true, true)
            }
            return
        }
        // Regular scroll reports are throttled to one percent so the library
        // file is not written on every frame. A settled report always lands,
        // which keeps the upload anchor on the exact line the user stopped at.
        // PDFs are page-driven: one page of a long document is well under one
        // percent, so throttle them by the page instead.
        let threshold = (settled || currentBook?.format == "PDF") ? 0.0005 : 0.01
        let textMoved = textValue.map {
            abs($0 - (currentBook?.textProgress ?? -1)) >= threshold
        } ?? false
        guard abs(value - currentProgress) >= threshold || textMoved else { return }
        currentProgress = value
        if var book = currentBook {
            book.progress = value
            if let textValue, book.format != "PDF" {
                book.textProgress = textValue
            }
            currentBook = book
        }
        if let id = currentBook?.id {
            onProgress?(id, value, textValue, snippet, false, settled)
        }
    }
}

final class MainViewController: NSViewController, NSMenuItemValidation {
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
    private let zenAutoSyncMinimumInterval: TimeInterval = 300
    private static let activeShelfKey = "ActiveLibraryShelf"
    private static let legacyActiveLibraryKey = "ActiveLibrarySource"
    private var isSyncing = false
    private var isScanningFolder = false
    private var lastSyncDate: Date?
    private var isZenSyncing = false
    private var lastZenSyncDate: Date?
    private var zenSettingsController: ZenSyncSettingsWindowController?
    private var proUnlockController: ProUnlockWindowController?
    private var activationObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var isDark: Bool { reader.isDarkMode }
    private var activeShelf: LibraryShelf = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: MainViewController.activeShelfKey),
           let saved = LibraryShelf(rawValue: raw) {
            if saved == .webdav && !ProLicenseManager.shared.isPro {
                return .folder
            }
            return saved
        }
        // Migrate the old three-way choice: anything that was not WebDAV is
        // now simply the folder shelf.
        if let raw = defaults.string(forKey: MainViewController.legacyActiveLibraryKey),
           let saved = BookSource(rawValue: raw) {
            let shelf: LibraryShelf = saved == .jianguoyun ? .webdav : .folder
            if shelf == .webdav && !ProLicenseManager.shared.isPro {
                return .folder
            }
            defaults.set(shelf.rawValue, forKey: MainViewController.activeShelfKey)
            return shelf
        }
        if ZenReaderSync.shared.isConfigured && ProLicenseManager.shared.isPro {
            return .webdav
        }
        return .folder
    }()

    private var activeBooks: [LibraryBook] {
        store.books
            .filter { activeShelf.contains($0.source) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.lastActivityAt != rhs.element.lastActivityAt {
                    return lhs.element.lastActivityAt > rhs.element.lastActivityAt
                }
                // Same activity date (for example books imported together):
                // keep their existing shelf order instead of shuffling them.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
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
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: 300)
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
        sidebar.onSync = { [weak self] in self?.syncCurrentLibrary() }
        sidebar.onUpload = { [weak self] in self?.performZenUpload() }
        sidebar.onDownload = { [weak self] in self?.performZenDownload() }
        sidebar.onChooseFolder = { [weak self] in self?.chooseLibraryFolder() }
        sidebar.onClearLibrary = { [weak self] in self?.clearLibraryRecords() }
        sidebar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebar.onSelect = { [weak self] book in self?.openBook(book) }
        sidebar.onSwitchLibrary = { [weak self] library in self?.switchLibrary(to: library) }
        sidebar.onShowPro = { [weak self] in self?.showProUnlock() }
        reader.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        reader.onThemeChanged = { [weak self] isDark in self?.applyTheme(isDark: isDark) }
        reader.onChaptersRequested = { [weak self] book, completion in
            self?.loadChapters(for: book, completion: completion)
        }
        reader.onProgress = { [weak self] bookID, progress, textProgress, snippet, anchored, settled in
            self?.recordProgress(
                bookID: bookID,
                progress: progress,
                textProgress: textProgress,
                snippet: snippet,
                anchored: anchored,
                settled: settled
            )
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
        sidebar.onZenSettings = { [weak self] in
            self?.showZenSyncSettings(startSync: false)
        }
        sidebar.setProUnlocked(ProLicenseManager.shared.isPro)
        sidebar.setActiveShelf(activeShelf)
        refreshSidebar(scrollToTop: true)
        sidebar.setFolderStatus(.ready)
        // The Jianguoyun password is only read silently from this launch's
        // cache or the Keychain; launch never shows a keychain dialog.
        refreshZenStatusForCurrentConfiguration()
        refreshFolderStatus()
        sidebarVisible = !UserDefaults.standard.bool(forKey: "SidebarHidden")
        reader.setSidebarVisible(sidebarVisible)
        applySidebarVisibility(animated: false)
        applyTheme(isDark: isDark)

        DispatchQueue.main.async { [weak self] in
            self?.activateCurrentLibraryOnLaunch()
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncOnActivation()
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.store.flushPendingSave()
            self?.syncZenOnResignActive()
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
        view.window?.title = "EasyRead"
        sidebar.applyLanguage()
        reader.applyLanguage()
    }

    private func refreshSidebar(scrollToTop: Bool = false) {
        sidebar.reload(books: activeBooks, scrollToTop: scrollToTop)
        reader.closeBookIfNotInLibrary(Set(activeBooks.map(\.id)))
    }

    /// Opening a book counts as reading activity, so the shelf re-sorts and
    /// the book the user just picked moves to the top immediately.
    private func openBook(_ book: LibraryBook) {
        var updated = store.books.first(where: { $0.id == book.id }) ?? book
        updated.lastOpenedAt = Date()
        store.update(updated)
        // Start parsing before the shelf rebuilds, so the book is already on
        // its way to the saved page when the sidebar finishes.
        reader.show(book: updated)
        refreshSidebar()
    }

    private func loadChapters(for book: LibraryBook, completion: @escaping ([ReaderChapter]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let chapters = ZenReaderSync.shared.chapters(for: book)
            DispatchQueue.main.async {
                completion(chapters)
            }
        }
    }

    @objc func showFindFromMenu(_ sender: Any?) {
        reader.showFind(nil)
    }

    @objc func togglePublisherStyles(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "ReaderPublisherStyles")
        UserDefaults.standard.set(enabled, forKey: "ReaderPublisherStyles")
        sender.state = enabled ? .on : .off
        reader.setPublisherStyles(enabled)
    }

    @objc func addBookmarkFromMenu(_ sender: Any?) {
        reader.addBookmark()
    }

    @objc func addNoteFromMenu(_ sender: Any?) {
        reader.addNote()
    }

    @objc func showBookmarksFromMenu(_ sender: Any?) {
        reader.showBookmarks()
    }

    private func activateCurrentLibraryOnLaunch() {
        switch activeShelf {
        case .folder:
            scanFolderLibrary(showStatus: false)
        case .webdav:
            maybeAutoSyncZen()
        }
    }

    private func switchLibrary(to shelf: LibraryShelf) {
        guard shelf != .webdav || ProLicenseManager.shared.isPro else {
            showProUnlock()
            return
        }
        guard shelf != activeShelf else { return }
        activeShelf = shelf
        UserDefaults.standard.set(shelf.rawValue, forKey: Self.activeShelfKey)
        sidebar.setActiveShelf(shelf)
        refreshSidebar(scrollToTop: true)

        switch shelf {
        case .folder:
            sidebar.setFolderStatus(.ready)
            scanFolderLibrary(showStatus: true)
        case .webdav:
            refreshZenStatusForCurrentConfiguration()
            maybeAutoSyncZen()
        }
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
        zenSettingsController?.applyAppearance(appearance)
        proUnlockController?.applyAppearance(appearance)
        rootView.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor.white).cgColor
        divider.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.24, alpha: 1)
            : NSColor(calibratedWhite: 0.83, alpha: 1)).cgColor
        sidebar.applyTheme(isDark: isDark)
    }

    private func syncOnActivation() {
        switch activeShelf {
        case .folder:
            guard !isSyncing else { return }
            if let lastSyncDate, Date().timeIntervalSince(lastSyncDate) < autoSyncMinimumInterval {
                return
            }
            scanFolderLibrary(showStatus: false)
        case .webdav:
            maybeAutoSyncZen()
        }
    }

    private func refreshZenStatusForCurrentConfiguration() {
        guard ProLicenseManager.shared.isPro else { return }
        // `sidebar.setActiveLibrary` already rendered the stored live stage.
        // Replacing it with “ready” here would hide a running sync.
        guard !isZenSyncing else { return }
        let sync = ZenReaderSync.shared
        if sync.isConfigured {
            sidebar.setZenStatus(.ready(lastSync: sync.lastCompletedAt))
        } else if sync.hasServerAndAccount {
            sidebar.setZenStatus(.needsPassword)
        } else {
            sidebar.setZenStatus(.notConfigured)
        }
    }

    private func syncZenOnResignActive() {
        guard ProLicenseManager.shared.isPro else { return }
        guard activeShelf == .webdav else { return }
        guard ZenReaderSync.shared.autoSyncEnabled else { return }
        guard ZenReaderSync.shared.isConfigured, !isZenSyncing else { return }
        if let lastZenSyncDate, Date().timeIntervalSince(lastZenSyncDate) < 60 {
            return
        }
        performZenSync(automatic: true, transfer: .both)
    }

    private func maybeAutoSyncZen() {
        guard ProLicenseManager.shared.isPro else { return }
        guard activeShelf == .webdav else { return }
        guard ZenReaderSync.shared.hasServerAndAccount else {
            sidebar.setZenStatus(.notConfigured)
            return
        }
        guard ZenReaderSync.shared.isConfigured else {
            sidebar.setZenStatus(.needsPassword)
            return
        }
        guard ZenReaderSync.shared.autoSyncEnabled else { return }
        guard !isZenSyncing else { return }
        if let lastZenSyncDate, Date().timeIntervalSince(lastZenSyncDate) < zenAutoSyncMinimumInterval {
            return
        }
        performZenSync(automatic: true, transfer: .both)
    }

    private func syncCurrentLibrary() {
        switch activeShelf {
        case .folder:
            scanFolderLibrary(showStatus: true)
        case .webdav:
            guard ProLicenseManager.shared.isPro else {
                showProUnlock()
                return
            }
            showZenSyncSettings(startSync: false)
        }
    }

    @objc func syncCurrentLibraryFromMenu() {
        syncCurrentLibrary()
    }

    @objc func chooseLibraryFolderFromMenu() {
        chooseLibraryFolder()
    }

    @objc func switchLibraryFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shelf = LibraryShelf(rawValue: raw) else { return }
        switchLibrary(to: shelf)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(syncCurrentLibraryFromMenu):
            menuItem.title = activeShelf == .folder
                ? L("扫描书库文件夹", "Scan Library Folder")
                : L("同步当前书库", "Sync Current Library")
            return true
        case #selector(chooseLibraryFolderFromMenu):
            menuItem.isHidden = activeShelf == .webdav
            return activeShelf != .webdav
        case #selector(clearLibraryFromMenu):
            return !activeBooks.isEmpty
        case #selector(zenSettingsFromMenu):
            return activeShelf == .webdav
        case #selector(showProUnlockFromMenu(_:)):
            menuItem.title = ProLicenseManager.shared.isPro
                ? L("EasyRead Pro（已解锁）…", "EasyRead Pro (Unlocked)…")
                : L("解锁 EasyRead Pro（¥8）…", "Unlock EasyRead Pro (¥8)…")
            return true
        case #selector(switchLibraryFromMenu(_:)):
            if let raw = menuItem.representedObject as? String,
               let shelf = LibraryShelf(rawValue: raw) {
                let locked = shelf == .webdav && !ProLicenseManager.shared.isPro
                menuItem.title = locked
                    ? L("WebDAV 书库（Pro）", "WebDAV Library (Pro)")
                    : shelf.title
                menuItem.image = NSImage(
                    systemSymbolName: locked ? "lock.fill" : shelf.symbolName,
                    accessibilityDescription: nil
                )
                menuItem.state = shelf == activeShelf ? .on : .off
            }
            return true
        default:
            return true
        }
    }

    @objc func showProUnlockFromMenu(_ sender: Any?) {
        showProUnlock()
    }

    @objc func zenSettingsFromMenu() {
        guard activeShelf == .webdav else { return }
        guard ProLicenseManager.shared.isPro else {
            showProUnlock()
            return
        }
        showZenSyncSettings(startSync: false)
    }

    private func performZenSync(
        automatic: Bool,
        mode: ZenSyncMode = .bidirectional,
        transfer: ZenBookTransfer = .none,
        completion: ((String, Bool) -> Void)? = nil
    ) {
        guard ProLicenseManager.shared.isPro else {
            if !automatic {
                showProUnlock()
            }
            completion?(L("WebDAV 书库需要 EasyRead Pro 授权。",
                          "The WebDAV library requires an EasyRead Pro license."), false)
            return
        }
        guard activeShelf == .webdav else {
            completion?(L("请先切换到 WebDAV 书库。", "Switch to the WebDAV library first."), false)
            return
        }
        guard !isZenSyncing else {
            completion?(L("正在同步，请稍后再试。", "A sync is already running. Try again shortly."), false)
            return
        }
        guard ZenReaderSync.shared.hasServerAndAccount else {
            sidebar.setZenStatus(.notConfigured)
            if !automatic {
                showZenSyncSettings(startSync: true)
            }
            completion?(L("请先在同步设置里填写 WebDAV 账号和密码。",
                          "Enter your WebDAV account and password in sync settings first."), false)
            return
        }
        guard ZenReaderSync.shared.isConfigured else {
            sidebar.setZenStatus(.needsPassword)
            if !automatic {
                showZenSyncSettings(startSync: true)
            }
            completion?(ZenReaderSyncError.keychainReentryRequired.localizedDescription, false)
            return
        }

        isZenSyncing = true
        lastZenSyncDate = Date()
        sidebar.setZenStatus(.syncing(stage: .checking))
        sidebar.setZenBusy(true)
        let books = activeBooks

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let (result, updates) = try ZenReaderSync.shared.sync(
                    books: books,
                    mode: mode,
                    transfer: transfer,
                    progress: { [weak self] stage in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.sidebar.setZenStatus(.syncing(stage: stage))
                            self.zenSettingsController?.showSyncProgress(stage)
                        }
                    }
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyZenRemovals(result.removedBookIDs)
                    self.applyZenUpdates(updates)
                    self.importZenBooks(result.importedBooks)
                    self.applyZenProgressDisplay(result.zenProgressByBookID)
                    self.isZenSyncing = false
                    self.sidebar.setZenBusy(false)
                    ZenReaderSync.shared.lastCompletedAt = Date()
                    var message = self.transferMessage(transfer: transfer, result: result)
                        ?? self.syncMessage(for: mode, result: result)
                    if let warning = result.manifestWarning {
                        message += L("（云端清单未更新：\(warning)）",
                                     " (cloud manifest not updated: \(warning))")
                    }
                    if transfer == .none {
                        if let warning = result.manifestWarning {
                            self.sidebar.setZenStatus(.warning(summary: message, detail: warning))
                        } else {
                            self.sidebar.setZenStatus(self.syncStatus(for: mode, result: result))
                        }
                    } else if result.transferFailures.isEmpty && result.manifestWarning == nil {
                        self.sidebar.setZenStatus(.notice(
                            L("同步完成 · \(message)", "Sync complete · \(message)")
                        ))
                    } else {
                        self.sidebar.setZenStatus(.warning(
                            summary: self.transferSummary(transfer: transfer, result: result),
                            detail: message
                        ))
                    }
                    completion?(message, result.transferFailures.isEmpty)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isZenSyncing = false
                    self.sidebar.setZenBusy(false)
                    self.sidebar.setZenStatus(.failed(error.localizedDescription))
                    if !automatic {
                        self.presentZenSyncError(error)
                    }
                    completion?(error.localizedDescription, false)
                }
            }
        }
    }

    /// Upload action for the Jianguoyun library: adds the local books that the
    /// cloud does not have and pushes this Mac's real reading positions.
    private func performZenUpload(completion: ((String, Bool) -> Void)? = nil) {
        guard ProLicenseManager.shared.isPro else {
            let message = L("WebDAV 书库需要 EasyRead Pro 授权。",
                            "The WebDAV library requires an EasyRead Pro license.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard activeShelf == .webdav else {
            let message = L("请先切换到 WebDAV 书库。", "Switch to the WebDAV library first.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard !isZenSyncing else {
            let message = L("正在同步，请稍后再试。", "A sync is already running. Try again shortly.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard ZenReaderSync.shared.hasServerAndAccount else {
            sidebar.setZenStatus(.notConfigured)
            showZenSyncSettings(startSync: false)
            completion?(L("请先在设置里填写 WebDAV 账号和密码。",
                          "Enter your WebDAV account and password in settings first."), false)
            return
        }
        guard ZenReaderSync.shared.isConfigured else {
            sidebar.setZenStatus(.needsPassword)
            showZenSyncSettings(startSync: false)
            completion?(ZenReaderSyncError.keychainReentryRequired.localizedDescription, false)
            return
        }

        isZenSyncing = true
        lastZenSyncDate = Date()
        sidebar.setZenStatus(.syncing(stage: .checking))
        sidebar.setZenBusy(true)
        let books = activeBooks

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let plan = try ZenReaderSync.shared.syncPlan(books: books)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isZenSyncing = false
                    guard self.confirmZenUpload(plan) else {
                        self.sidebar.setZenBusy(false)
                        self.sidebar.setZenStatus(.ready(
                            lastSync: ZenReaderSync.shared.lastCompletedAt
                        ))
                        completion?(L("已取消上传", "Upload canceled"), false)
                        return
                    }
                    self.performZenSync(
                        automatic: false,
                        mode: .uploadLocal,
                        transfer: .upload,
                        completion: completion
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isZenSyncing = false
                    self.sidebar.setZenBusy(false)
                    self.sidebar.setZenStatus(.failed(error.localizedDescription))
                    self.presentZenSyncError(error)
                    completion?(error.localizedDescription, false)
                }
            }
        }
    }

    /// Download action: pulls cloud books missing on this Mac and applies newer
    /// cloud reading positions. It never uploads or modifies cloud data.
    private func performZenDownload(completion: ((String, Bool) -> Void)? = nil) {
        guard ProLicenseManager.shared.isPro else {
            let message = L("WebDAV 书库需要 EasyRead Pro 授权。",
                            "The WebDAV library requires an EasyRead Pro license.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard activeShelf == .webdav else {
            let message = L("请先切换到 WebDAV 书库。", "Switch to the WebDAV library first.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard !isZenSyncing else {
            let message = L("正在同步，请稍后再试。", "A sync is already running. Try again shortly.")
            sidebar.setZenStatus(.notice(message))
            completion?(message, false)
            return
        }
        guard ZenReaderSync.shared.hasServerAndAccount else {
            sidebar.setZenStatus(.notConfigured)
            showZenSyncSettings(startSync: false)
            completion?(L("请先在设置里填写 WebDAV 账号和密码。",
                          "Enter your WebDAV account and password in settings first."), false)
            return
        }
        guard ZenReaderSync.shared.isConfigured else {
            sidebar.setZenStatus(.needsPassword)
            showZenSyncSettings(startSync: false)
            completion?(ZenReaderSyncError.keychainReentryRequired.localizedDescription, false)
            return
        }
        performZenSync(
            automatic: false,
            mode: .downloadRemote,
            transfer: .download,
            completion: completion
        )
    }

    private func confirmZenUpload(_ plan: ZenSyncPlan) -> Bool {
        if plan.uploadCount == 0 && plan.matched == 0 {
            sidebar.setZenStatus(.notice(L("本机书库是空的，没有可上传的内容。",
                                           "The local library is empty; nothing to upload.")))
            return false
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeText = formatter.string(fromByteCount: plan.uploadBytes)
        let preview = plan.uploadTitles.prefix(5).joined(separator: "、")
        let more = plan.uploadTitles.count > 5 ? "…" : ""

        var summary: [String] = []
        if plan.uploadCount > 0 {
            summary.append(L("上传 \(plan.uploadCount) 本云端还没有的本机书籍（共 \(sizeText)）：\(preview)\(more)",
                             "Upload \(plan.uploadCount) local book(s) not yet in the cloud (\(sizeText)): \(preview)\(more)"))
        }
        if plan.matched > 0 {
            summary.append(L("检查 \(plan.matched) 本两边都有的书，上传其中这台 Mac 读过的进度",
                             "Check \(plan.matched) matched book(s) and upload positions read on this Mac"))
        }

        let alert = NSAlert()
        alert.messageText = L("上传本机书籍与进度到 WebDAV？",
                              "Upload local books and positions to WebDAV?")
        alert.informativeText = summary.joined(separator: "\n") + "\n\n" + L(
            "会写入一个新快照；不会删除云端书籍或旧快照。只会上传这台 Mac 真正读过的书，其他书的云端进度保持原样。",
            "A new snapshot is written; cloud books and older snapshots are never deleted. Only books read on this Mac are pushed; other cloud positions stay unchanged."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("上传到云端", "Upload to Cloud"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func importZenBooks(_ books: [LibraryBook]) {
        guard !books.isEmpty else { return }
        var shelfPaths = Set(store.books.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        var added = false
        for book in books {
            let path = URL(fileURLWithPath: book.path).standardizedFileURL.path
            // Re-importing a file that already has a shelf record must not
            // replace that record: `store.add` removes by path, which used to
            // reset a newer local position to the cloud's older one.
            guard !shelfPaths.contains(path) else { continue }
            store.add(book)
            shelfPaths.insert(path)
            added = true
        }
        guard added else { return }
        if activeShelf == .webdav {
            refreshSidebar(scrollToTop: true)
        }
    }

    /// A one-line summary for the sidebar. Failure details stay in the tooltip
    /// and in the sync settings window so the library bar never gets cut off.
    private func transferSummary(transfer: ZenBookTransfer, result: ZenSyncResult) -> String {
        var parts: [String] = []
        if result.downloadedBooks > 0 {
            parts.append(L("下载 \(result.downloadedBooks) 本", "\(result.downloadedBooks) downloaded"))
        }
        if result.uploadedBooks > 0 {
            parts.append(L("上传 \(result.uploadedBooks) 本", "\(result.uploadedBooks) uploaded"))
        }
        if result.pulled > 0 {
            parts.append(L("更新 \(result.pulled) 本进度", "\(result.pulled) positions updated"))
        }
        if result.pushed > 0 {
            parts.append(L("上传 \(result.pushed) 本进度", "\(result.pushed) positions uploaded"))
        }
        if !result.removedBookIDs.isEmpty {
            parts.append(L("移除云端已删除 \(result.removedBookIDs.count) 本",
                           "\(result.removedBookIDs.count) cloud-deleted books removed locally"))
        }
        if !result.transferFailures.isEmpty {
            parts.append(L("\(result.transferFailures.count) 本失败", "\(result.transferFailures.count) failed"))
        }
        if parts.isEmpty {
            switch transfer {
            case .download:
                return L("云端没有需要下载的书籍", "No new books in the cloud")
            case .upload:
                return L("没有需要上传的本机书籍", "No new books on this Mac to upload")
            case .both:
                return L("书籍与进度已是最新", "Books and positions are up to date")
            case .none:
                return ""
            }
        }
        return parts.joined(separator: L("，", ", "))
    }

    private func transferMessage(transfer: ZenBookTransfer, result: ZenSyncResult) -> String? {
        guard transfer != .none else { return nil }
        var parts: [String] = []
        if result.downloadedBooks > 0 {
            parts.append(L("下载 \(result.downloadedBooks) 本书及阅读进度",
                           "\(result.downloadedBooks) books and positions downloaded"))
        }
        if result.uploadedBooks > 0 {
            parts.append(L("上传 \(result.uploadedBooks) 本书及阅读进度",
                           "\(result.uploadedBooks) books and positions uploaded"))
        }
        if result.pulled > 0 {
            parts.append(L("更新 \(result.pulled) 本进度", "\(result.pulled) positions updated"))
        }
        if result.pushed > 0 {
            parts.append(L("上传 \(result.pushed) 本进度", "\(result.pushed) positions uploaded"))
        }
        if !result.removedBookIDs.isEmpty {
            parts.append(L("移除云端已删除 \(result.removedBookIDs.count) 本",
                           "\(result.removedBookIDs.count) cloud-deleted books removed locally"))
        }
        if parts.isEmpty {
            switch transfer {
            case .download:
                parts.append(L("云端没有需要下载的书籍", "No new books in the cloud"))
            case .upload:
                parts.append(L("没有需要上传的本机书籍", "No new books on this Mac to upload"))
            case .both:
                parts.append(L("书籍与进度已是最新", "Books and positions are up to date"))
            case .none:
                break
            }
        }
        if !result.transferFailures.isEmpty {
            parts.append(L("\(result.transferFailures.count) 本失败",
                           "\(result.transferFailures.count) failed"))
        }
        let message = parts.joined(separator: L("，", ", "))
        if let firstFailure = result.transferFailures.first {
            return message + L("（\(firstFailure)）", " (\(firstFailure))")
        }
        return message
    }

    private func syncStatus(for mode: ZenSyncMode, result: ZenSyncResult) -> ZenSyncStatus {
        switch mode {
        case .bidirectional:
            if result.pulled == 0 && result.pushed == 0 {
                return .upToDate(matched: result.matched)
            }
            return .completed(pulled: result.pulled, pushed: result.pushed, matched: result.matched)
        case .uploadLocal:
            if result.pushed == 0 {
                return .notice(L("没有可上传的本机进度", "No local positions to upload"))
            }
            return .completed(pulled: 0, pushed: result.pushed, matched: result.matched)
        case .downloadRemote:
            if result.pulled == 0 {
                return .notice(L("云端没有新的阅读进度", "No newer positions in the cloud"))
            }
            return .completed(pulled: result.pulled, pushed: 0, matched: result.matched)
        }
    }

    private func syncMessage(for mode: ZenSyncMode, result: ZenSyncResult) -> String {
        switch mode {
        case .bidirectional:
            if result.pulled == 0 && result.pushed == 0 {
                return L("阅读进度已是最新（匹配 \(result.matched) 本）",
                         "Reading positions are up to date (\(result.matched) matched)")
            }
            return L("已更新 \(result.pulled) 本，上传 \(result.pushed) 本",
                     "Updated \(result.pulled), uploaded \(result.pushed)")
        case .uploadLocal:
            if result.pushed == 0 {
                if result.matched == 0 {
                    return L("没有匹配到可上传的书", "No matching books to upload")
                }
                return L("没有可上传的本机进度（已匹配 \(result.matched) 本）",
                         "No local positions to upload (\(result.matched) matched)")
            }
            return L("已上传 \(result.pushed) 本书的阅读进度",
                     "Uploaded reading positions for \(result.pushed) books")
        case .downloadRemote:
            if result.pulled == 0 {
                if result.matched == 0 {
                    return L("没有匹配到可下载的书", "No matching books to download")
                }
                return L("云端没有新的阅读进度（已匹配 \(result.matched) 本）",
                         "No newer positions in the cloud (\(result.matched) matched)")
            }
            return L("已从云端更新 \(result.pulled) 本书的阅读进度",
                     "Applied cloud positions for \(result.pulled) books")
        }
    }

    private func applyZenUpdates(_ updates: [UUID: ZenProgressUpdate]) {
        guard !updates.isEmpty else { return }
        for (id, update) in updates {
            guard var book = store.books.first(where: { $0.id == id }) else { continue }
            let clamped = min(max(update.progress, 0), 1)
            book.progress = clamped
            if update.fromCloud && book.format != "PDF" {
                // Cloud positions are converted to the extracted-text metric;
                // opening the book must use that, not the pixel fraction.
                book.textProgress = clamped
            }
            book.progressUpdatedAt = update.updatedAt
            if update.fromCloud {
                // The new position comes with the sentence the phone shows.
                // Keep it so opening the book scrolls to that sentence instead
                // of reinterpreting a percentage of the scroll height.
                let locator = update.locatorText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if book.format != "PDF", let locator, !locator.isEmpty {
                    book.zenLocatorText = locator
                    book.zenLocatorAnchor = clamped
                    book.localTextAnchor = locator
                    book.localTextAnchorProgress = clamped
                } else {
                    book.zenLocatorText = nil
                    book.zenLocatorAnchor = nil
                    book.localTextAnchor = nil
                    book.localTextAnchorProgress = nil
                }
            }
            store.update(book)
            sidebar.refresh(book: book)
            // Uploads keep the reader where the user already is; only cloud
            // positions should move an open book.
            if update.fromCloud {
                reader.applyExternalProgress(
                    bookID: id,
                    progress: book.progress,
                    textProgress: book.format == "PDF" ? nil : book.textProgress,
                    locatorText: book.zenLocatorText
                )
            }
        }
    }

    /// Stores the phone-style percentage exactly as the latest snapshot reports
    /// it. `applyZenUpdates` has already put the converted local anchor into
    /// `progress`; this only changes the number shown on the shelf.
    private func applyZenProgressDisplay(_ values: [UUID: Double]) {
        guard !values.isEmpty else { return }
        for (id, value) in values {
            guard var book = store.books.first(where: { $0.id == id }),
                  book.source == .jianguoyun else { continue }
            let clamped = min(max(value, 0), 1)
            guard book.zenProgress != clamped else { continue }
            book.zenProgress = clamped
            store.update(book)
            sidebar.refresh(book: book)
        }
    }

    private func applyZenRemovals(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let removed = store.books.filter { idSet.contains($0.id) && $0.source == .jianguoyun }
        guard !removed.isEmpty else { return }
        store.remove(removed)
        reader.closeBookIfNotInLibrary(Set(store.books.map(\.id)))
        for book in removed where ZenBookCache.contains(book.path) {
            try? FileManager.default.removeItem(atPath: book.path)
        }
        refreshSidebar(scrollToTop: false)
    }

    private func showProUnlock() {
        let appearance = NSAppearance(named: reader.isDarkMode ? .darkAqua : .aqua)
        if let existing = proUnlockController {
            existing.applyAppearance(appearance)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ProUnlockWindowController(appearance: appearance)
        controller.onUnlocked = { [weak self] in
            self?.proLicenseDidUnlock()
        }
        proUnlockController = controller
        guard let parent = view.window, let proWindow = controller.window else {
            controller.showWindow(nil)
            return
        }
        parent.beginSheet(proWindow) { [weak self] _ in
            if self?.proUnlockController === controller {
                self?.proUnlockController = nil
            }
        }
    }

    private func proLicenseDidUnlock() {
        sidebar.setProUnlocked(true)
        NSApp.mainMenu?.update()
        if activeShelf == .webdav {
            refreshZenStatusForCurrentConfiguration()
        }
    }

    private func showZenSyncSettings(startSync: Bool) {
        guard ProLicenseManager.shared.isPro else {
            showProUnlock()
            return
        }
        let appearance = NSAppearance(named: reader.isDarkMode ? .darkAqua : .aqua)
        if let existing = zenSettingsController {
            existing.applyAppearance(appearance)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ZenSyncSettingsWindowController(appearance: appearance)
        controller.onSaved = { [weak self] in
            guard let self, !self.isZenSyncing else { return }
            self.sidebar.setZenStatus(.ready(
                lastSync: ZenReaderSync.shared.lastCompletedAt
            ))
        }
        controller.onCleared = { [weak self] in
            guard let self, !self.isZenSyncing else { return }
            self.sidebar.setZenStatus(.notConfigured)
        }
        controller.onRequestUpload = { [weak self, weak controller] in
            guard let self else {
                controller?.finishManualSync(
                    message: L("上传入口不可用。", "The upload handler is unavailable."),
                    success: false
                )
                return
            }
            self.performZenUpload { message, success in
                controller?.finishManualSync(message: message, success: success)
            }
        }
        controller.onRequestDownload = { [weak self, weak controller] in
            guard let self else {
                controller?.finishManualSync(
                    message: L("下载入口不可用。", "The download handler is unavailable."),
                    success: false
                )
                return
            }
            self.performZenDownload { message, success in
                controller?.finishManualSync(message: message, success: success)
            }
        }
        zenSettingsController = controller
        guard let parent = view.window, let settingsWindow = controller.window else {
            controller.showWindow(nil)
            return
        }
        parent.beginSheet(settingsWindow) { [weak self] _ in
            if self?.zenSettingsController === controller {
                self?.zenSettingsController = nil
            }
        }
        controller.focusInitialField()
    }

    private func presentZenSyncError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("WebDAV 同步失败", "WebDAV sync failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("好", "OK"))
        alert.runModal()
    }

    @objc func importBooksFromMenu() {
        importBooks()
    }

    @objc func toggleSidebarFromMenu() {
        toggleSidebar()
    }

    private func recordProgress(
        bookID: UUID,
        progress: Double,
        textProgress: Double?,
        snippet: String?,
        anchored: Bool,
        settled: Bool
    ) {
        guard let book = store.books.first(where: { $0.id == bookID }) else { return }
        var updated = book
        let clamped = min(max(progress, 0), 1)
        updated.progress = clamped
        let clampedText: Double? = updated.format == "PDF"
            ? nil
            : textProgress.map { min(max($0, 0), 1) }
        if let clampedText {
            // Always keep the extracted-text fraction; it is the position the
            // phone understands and the one uploads are converted from.
            updated.textProgress = clampedText
        }
        // Anchors live in text coordinates, not in rendered scroll height.
        let position = clampedText ?? clamped
        if anchored {
            // Opening at the phone's sentence is not reading further. Keep the
            // phone timestamp so the next automatic sync does not bounce the
            // position back and forth.
            if updated.progressUpdatedAt == nil {
                updated.progressUpdatedAt = Date()
            }
            if updated.zenLocatorText != nil {
                updated.zenLocatorAnchor = position
            }
            if let snippet, snippet.count >= 4 {
                updated.localTextAnchor = snippet
                updated.localTextAnchorProgress = position
            }
        } else {
            updated.progressUpdatedAt = Date()
            if let anchor = updated.zenLocatorAnchor, abs(position - anchor) > 0.01 {
                // The user read away from the phone's passage, so its sentence
                // no longer describes the top of this viewport.
                updated.zenLocatorText = nil
                updated.zenLocatorAnchor = nil
            }
            if let snippet, snippet.count >= 4 {
                updated.localTextAnchor = snippet
                updated.localTextAnchorProgress = position
            } else if let anchorProgress = updated.localTextAnchorProgress,
                      abs(anchorProgress - position) > 0.01 {
                updated.localTextAnchor = nil
                updated.localTextAnchorProgress = nil
            }
        }
        if !anchored,
           updated.source == .jianguoyun,
           settled || updated.zenProgress == nil,
           let zenProgress = ZenReaderSync.shared.cachedZenPercent(
               for: updated,
               progress: position
           ) {
            // Keep the shelf label in ZenReader's metric while reading on the
            // Mac. This search walks the book's chapter table, so only run it
            // when scrolling has settled instead of on every percent change.
            updated.zenProgress = zenProgress
        }
        store.updateProgress(updated)
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
            self.sidebarWidthConstraint.constant = self.sidebarVisible ? 300 : 0
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

    @objc func clearLibraryFromMenu() {
        clearLibraryRecords()
    }

    private func clearLibraryRecords() {
        let removedBooks = activeBooks
        let count = removedBooks.count
        guard count > 0 else { return }
        let detail: String
        switch activeShelf {
        case .folder:
            let folderName = FolderLibraryStore.shared.folderName
            detail = L(
                "会移除书库中的 \(count) 条书架记录。不会删除“\(folderName)”文件夹里的原书；之后点“扫描”可以重新加入。",
                "This removes \(count) shelf records. Originals in “\(folderName)” are kept; press Scan to add them back."
            )
        case .webdav:
            detail = L(
                "会移除 WebDAV 书库中的 \(count) 条书架记录，并删除本机下载缓存。不会删除云端上的原书、旧快照或其他设备的数据；之后点“同步”可以重新下载。",
                "This removes \(count) shelf records from the WebDAV library and deletes this Mac's downloaded copies. Cloud books, older snapshots, and other devices' data are kept; press Sync to download them again."
            )
        }
        let alert = NSAlert()
        alert.messageText = L("清理\(activeShelf.title)的书架？",
                              "Clear the \(activeShelf.title) shelf?")
        alert.informativeText = detail + L("\n\n只会影响当前书库，其他书库保持原样。",
                                            "\n\nOnly the current library is affected; other libraries stay as they are.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("清理书架", "Clear Shelf"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        reader.handleLibraryCleared()
        store.remove(removedBooks)
        if activeShelf == .webdav {
            for book in removedBooks where ZenBookCache.contains(book.path) {
                try? FileManager.default.removeItem(atPath: book.path)
            }
        }
        refreshSidebar(scrollToTop: true)
    }

    private func removeBook(_ book: LibraryBook) {
        let alert = NSAlert()
        alert.messageText = L("从书架移除这本书？", "Remove this book from the library?")
        let detail: String
        switch book.source {
        case .jianguoyun:
            detail = L(
                "只会从这台 Mac 的 WebDAV 书库移除，云端上的原书仍在。以后同步时它可能重新出现；要同时从云端删除，请右键选择“从云端删除并移出书架”。",
                "This only removes the book from this Mac's WebDAV library; the original in the cloud remains. Syncing later may bring it back. To delete it from the cloud too, choose “Delete from Cloud & Remove”."
            )
        case .iCloud, .local:
            detail = L(
                "只会从这台 Mac 的书库移除，不会删除书库文件夹里的原书；下次扫描时它可能重新出现。",
                "This only removes the book from this Mac's library; the original in the library folder remains. Scanning again may bring it back."
            )
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L("从书架移除", "Remove"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.remove(book)
        refreshSidebar(scrollToTop: true)
    }

    private func editBookMetadata(_ book: LibraryBook) {
        let alert = NSAlert()
        alert.messageText = L("编辑书名和作者", "Edit Title & Author")
        alert.informativeText = L(
            "只修改书架显示信息，不修改原书文件。",
            "This only changes how the book appears in your library. The original book file is untouched."
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
        switch book.source {
        case .iCloud, .local:
            removeFolderBookFromDisk(book)
        case .jianguoyun:
            removeJianguoyunBookFromCloud(book)
        }
    }

    private func removeFolderBookFromDisk(_ book: LibraryBook) {
        let folderStore = FolderLibraryStore.shared
        guard folderStore.contains(URL(fileURLWithPath: book.path)) else {
            let alert = NSAlert()
            alert.messageText = L("这本书不在当前书库文件夹中", "This book is not in the current library folder")
            alert.informativeText = L(
                "它只能从 Mac 书架移除，无法通过此选项删除。",
                "It can only be removed from the Mac library; this option cannot delete it."
            )
            alert.addButton(withTitle: L("好", "OK"))
            alert.runModal()
            return
        }

        let isICloud = CloudFolderSync.isICloudDriveFolder(folderStore.folderURL)
        let alert = NSAlert()
        alert.messageText = L("从书库文件夹删除这本书？", "Delete this book from the library folder?")
        alert.informativeText = isICloud
            ? L(
                "这会从 iCloud 书库文件夹中删除原文件，并可能同步删除其他设备上的对应文件。此操作无法通过本 App 撤销。",
                "This deletes the original file from the iCloud library folder and may also delete the matching file on your other devices. This cannot be undone from this app."
            )
            : L(
                "这会从书库文件夹中删除原文件。此操作无法通过本 App 撤销。",
                "This deletes the original file from the library folder. This cannot be undone from this app."
            )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("删除", "Delete"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(atPath: book.path)
            store.remove(book)
            refreshSidebar(scrollToTop: true)
            sidebar.setFolderStatus(.scanned(
                count: activeBooks.count,
                folderName: folderStore.folderName,
                path: folderStore.displayPath
            ))
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.messageText = L("无法删除这本书", "Could not delete this book")
            errorAlert.runModal()
        }
    }

    private func removeJianguoyunBookFromCloud(_ book: LibraryBook) {
        guard ZenReaderSync.shared.hasServerAndAccount else {
            sidebar.setZenStatus(.notConfigured)
            showZenSyncSettings(startSync: false)
            return
        }
        guard ZenReaderSync.shared.isConfigured else {
            sidebar.setZenStatus(.needsPassword)
            showZenSyncSettings(startSync: false)
            return
        }
        guard !isZenSyncing else {
            sidebar.setZenStatus(.notice(L("正在同步，请稍后再试。",
                                           "A sync is already running. Try again shortly.")))
            return
        }

        let alert = NSAlert()
        alert.messageText = L("从 WebDAV 删除这本书？", "Delete this book from WebDAV?")
        let cacheNote = ZenBookCache.contains(book.path)
            ? L("这台 Mac 上下载的缓存副本也会一并删除。",
                "The downloaded cache copy on this Mac is removed as well.")
            : L("这本书的本机文件会保留。", "The local book file on this Mac is kept.")
        alert.informativeText = L(
            "会向 WebDAV 写入一次新的删除快照；使用同一同步目录的其他设备下次同步后，书架里也不再显示这本书。\n\n"
                + cacheNote
                + "\n旧快照不会被修改或删除，所以数据仍可从历史快照找回。",
            "A new deletion snapshot is written to WebDAV; after the next sync the book also disappears from shelves on other devices using the same sync folder.\n\n"
                + cacheNote
                + "\nOlder snapshots are never modified or deleted, so the data can still be recovered from history."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("从 WebDAV 删除", "Delete from WebDAV"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isZenSyncing = true
        sidebar.setZenStatus(.syncing(stage: .writingSnapshot))
        sidebar.setZenBusy(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let snapshot = try ZenReaderSync.shared.deleteBook(book)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isZenSyncing = false
                    self.sidebar.setZenBusy(false)
                    self.store.remove(book)
                    if ZenBookCache.contains(book.path) {
                        try? FileManager.default.removeItem(atPath: book.path)
                    }
                    self.refreshSidebar(scrollToTop: true)
                    if snapshot != nil {
                        self.sidebar.setZenStatus(.notice(L("已写入删除快照，手机会在下次同步后移除这本书。",
                                                            "A deletion snapshot was written; the phone removes the book after its next sync.")))
                    } else {
                        self.sidebar.setZenStatus(.notice(L("云端没有这本书，只移除了本机书架记录。",
                                                            "The cloud did not contain this book; only the local shelf record was removed.")))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isZenSyncing = false
                    self.sidebar.setZenBusy(false)
                    self.sidebar.setZenStatus(.failed(error.localizedDescription))
                    self.presentZenSyncError(error)
                }
            }
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

    func flushLibraryStore() {
        store.flushPendingSave()
    }

    func importURLs(_ urls: [URL]) {
        // The same Finder open can arrive through both `open urls` and
        // `openFiles`; importing it twice leaves the shelf record and the
        // opened book with different IDs, so the next shelf refresh closes it.
        var seenPaths = Set<String>()
        let validURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) &&
            seenPaths.insert(url.standardizedFileURL.path).inserted
        }
        guard !validURLs.isEmpty else { return }
        let targetShelf = activeShelf
        let targetFolder = FolderLibraryStore.shared.folderURL
        let folderIsICloud = CloudFolderSync.isICloudDriveFolder(targetFolder)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var importedBooks: [LibraryBook] = []
            for url in validURLs {
                var finalURL = url
                var source: BookSource
                switch targetShelf {
                case .folder:
                    CloudFolderSync.shared.prepareForReading(url)
                    if folderIsICloud,
                       !FolderLibraryStore.shared.contains(url) {
                        guard let copied = try? CloudFolderSync.shared.copy(url, into: targetFolder) else {
                            continue
                        }
                        finalURL = copied
                    }
                    source = CloudFolderSync.isICloudDriveFolder(finalURL.deletingLastPathComponent())
                        ? .iCloud
                        : .local
                case .webdav:
                    CloudFolderSync.shared.prepareForReading(url)
                    source = .jianguoyun
                }
                importedBooks.append(BookImporter.book(from: finalURL, source: source))
            }

            DispatchQueue.main.async {
                guard let self else { return }
                importedBooks.forEach { self.store.add($0) }
                self.refreshSidebar(scrollToTop: true)
                switch targetShelf {
                case .folder:
                    self.sidebar.setFolderStatus(.booksAdded(count: importedBooks.count))
                case .webdav:
                    if !importedBooks.isEmpty {
                        let localOnlyCount = importedBooks.filter {
                            !BookImporter.isPhoneSyncable(format: $0.format)
                        }.count
                        if localOnlyCount == importedBooks.count {
                            self.sidebar.setZenStatus(.notice(L(
                                "已加入本机书架；手机端暂不支持这种格式，不会上传到云端",
                                "Added to this Mac's shelf; the phone cannot read this format, so it will not be uploaded"
                            )))
                        } else if localOnlyCount > 0 {
                            self.sidebar.setZenStatus(.notice(L(
                                "已加入 WebDAV 书库；Markdown / FB2 / CBZ / RTF / DOCX 仅在本机阅读，同步时会跳过",
                                "Added to the WebDAV library; Markdown / FB2 / CBZ / RTF / DOCX stay on this Mac and are skipped during sync"
                            )))
                        } else {
                            self.sidebar.setZenStatus(.notice(L(
                                "已加入 WebDAV 书库；点“同步”确认上传",
                                "Added to the WebDAV library; press Sync to confirm upload"
                            )))
                        }
                    }
                }
                if self.activeShelf == targetShelf, let first = importedBooks.first {
                    self.reader.show(book: first)
                }
            }
        }
    }

    private func scanFolderLibrary(showStatus: Bool) {
        guard activeShelf == .folder else { return }
        guard !isScanningFolder else { return }
        let folderStore = FolderLibraryStore.shared
        guard folderStore.isAvailable else {
            sidebar.setFolderStatus(.folderMissing(path: folderStore.displayPath))
            if showStatus {
                chooseLibraryFolder()
            }
            return
        }

        isScanningFolder = true
        lastSyncDate = Date()
        if showStatus {
            sidebar.setFolderStatus(.scanning)
        }

        let folder = folderStore.folderURL
        let folderSource: BookSource = CloudFolderSync.isICloudDriveFolder(folder) ? .iCloud : .local
        let existingPaths = Set(store.books.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let authorCandidatePaths = Set(
            store.books
                .filter { $0.source != .jianguoyun && $0.author.isEmpty }
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let urls = folderStore.bookURLs()
            urls.forEach { CloudFolderSync.shared.prepareForReading($0) }
            let urlsByPath = Dictionary(
                urls.map { ($0.standardizedFileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let newBooks = urls
                .filter { !existingPaths.contains($0.standardizedFileURL.path) }
                .map { BookImporter.book(from: $0, source: folderSource) }
            let inferredAuthors: [(path: String, author: String)] = authorCandidatePaths.compactMap { path in
                guard let url = urlsByPath[path] else { return nil }
                let author = BookImporter.inferredAuthor(from: url)
                return author.isEmpty ? nil : (path, author)
            }

            DispatchQueue.main.async {
                let folderPaths = Set(urlsByPath.keys)
                let staleBooks = self.store.books.filter { book in
                    book.source != .jianguoyun &&
                    folderStore.contains(URL(fileURLWithPath: book.path)) &&
                    !folderPaths.contains(URL(fileURLWithPath: book.path).standardizedFileURL.path)
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

                self.refreshSidebar(scrollToTop: addedCount > 0)
                self.sidebar.setFolderStatus(.scanned(
                    count: urls.count,
                    folderName: folderStore.folderName,
                    path: folderStore.displayPath
                ))
                self.isScanningFolder = false
            }
        }
    }

    private func refreshFolderStatus() {
        let folderStore = FolderLibraryStore.shared
        guard folderStore.isAvailable else {
            sidebar.setFolderStatus(.folderMissing(path: folderStore.displayPath))
            return
        }
        sidebar.setFolderStatus(
            .folderChosen(name: folderStore.folderName, path: folderStore.displayPath)
        )
    }

    private func chooseLibraryFolder() {
        guard activeShelf == .folder else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let currentFolder = FolderLibraryStore.shared.folderURL
        if FileManager.default.fileExists(atPath: currentFolder.path) {
            panel.directoryURL = currentFolder
        }
        panel.prompt = L("使用此文件夹", "Use Folder")
        panel.message = L(
            "选择用作书库的文件夹，默认是 iCloud Drive 中的“极简阅读”；点“扫描”可随时更新其中的书籍",
            "Choose a folder as the library; the “极简阅读” folder in iCloud Drive by default. Press Scan to refresh its books at any time"
        )
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            FolderLibraryStore.shared.setFolder(folder)
            self?.sidebar.setActiveShelf(.folder)
            self?.sidebar.setFolderStatus(.folderChosen(
                name: FolderLibraryStore.shared.folderName,
                path: FolderLibraryStore.shared.displayPath
            ))
            self?.scanFolderLibrary(showStatus: true)
        }
    }

    private func importBooks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["txt", "epub", "pdf", "mobi", "azw", "azw3", "md", "markdown"].compactMap {
            UTType(filenameExtension: $0)
        }
        switch activeShelf {
        case .folder:
            if CloudFolderSync.isICloudDriveFolder(FolderLibraryStore.shared.folderURL) {
                panel.message = L("选择要复制到 iCloud 书库文件夹的书籍",
                                  "Choose books to copy into the iCloud library folder")
            } else {
                panel.message = L("选择要加入书库的本机文件；不会上传",
                                  "Choose files to add to the library; nothing is uploaded")
            }
        case .webdav:
            panel.message = L("选择要加入 WebDAV 书库的本机书籍；上传前会再次确认",
                              "Choose books to add to the WebDAV library; uploading is confirmed first")
        }
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
        window.title = "EasyRead"
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
        mainViewController?.flushLibraryStore()
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
        let appName = "EasyRead"

        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(
            title: L("关于 EasyRead", "About EasyRead"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        let proItem = NSMenuItem(
            title: L("解锁 EasyRead Pro（¥8）…", "Unlock EasyRead Pro (¥8)…"),
            action: #selector(MainViewController.showProUnlockFromMenu(_:)),
            keyEquivalent: ""
        )
        proItem.target = mainViewController
        appMenu.addItem(proItem)
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

        let hideItem = NSMenuItem(title: L("隐藏 EasyRead", "Hide EasyRead"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
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

        let quitItem = NSMenuItem(title: L("退出 EasyRead", "Quit EasyRead"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(
            title: L("关闭窗口", "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let libraryMenuItem = NSMenuItem(title: L("书库", "Library"), action: nil, keyEquivalent: "")
        let libraryMenu = NSMenu(title: L("书库", "Library"))
        for (index, shelf) in LibraryShelf.allCases.enumerated() {
            let item = NSMenuItem(
                title: shelf.title,
                action: #selector(MainViewController.switchLibraryFromMenu(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.target = mainViewController
            item.representedObject = shelf.rawValue
            libraryMenu.addItem(item)
        }
        libraryMenu.addItem(.separator())

        let syncItem = NSMenuItem(
            title: L("同步当前书库", "Sync Current Library"),
            action: #selector(MainViewController.syncCurrentLibraryFromMenu),
            keyEquivalent: "r"
        )
        syncItem.target = mainViewController
        libraryMenu.addItem(syncItem)

        let folderItem = NSMenuItem(
            title: L("选择当前书库文件夹…", "Choose Current Library Folder…"),
            action: #selector(MainViewController.chooseLibraryFolderFromMenu),
            keyEquivalent: ""
        )
        folderItem.target = mainViewController
        libraryMenu.addItem(folderItem)

        let clearLibraryItem = NSMenuItem(
            title: L("清理当前书库记录…", "Clear Current Library…"),
            action: #selector(MainViewController.clearLibraryFromMenu),
            keyEquivalent: ""
        )
        clearLibraryItem.target = mainViewController
        libraryMenu.addItem(clearLibraryItem)

        libraryMenu.addItem(.separator())
        let zenSettingsItem = NSMenuItem(
            title: L("WebDAV 同步设置…", "WebDAV Sync Settings…"),
            action: #selector(MainViewController.zenSettingsFromMenu),
            keyEquivalent: ""
        )
        zenSettingsItem.target = mainViewController
        libraryMenu.addItem(zenSettingsItem)
        libraryMenuItem.submenu = libraryMenu
        mainMenu.addItem(libraryMenuItem)

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
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: L("在书中查找…", "Find in Book…"),
            action: #selector(MainViewController.showFindFromMenu(_:)),
            keyEquivalent: "f"
        )
        findItem.target = mainViewController
        editMenu.addItem(findItem)
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
        viewMenu.addItem(.separator())
        let publisherItem = NSMenuItem(
            title: L("使用出版方排版（EPUB）", "Use Publisher Layout (EPUB)"),
            action: #selector(MainViewController.togglePublisherStyles(_:)),
            keyEquivalent: ""
        )
        publisherItem.target = mainViewController
        publisherItem.state = UserDefaults.standard.bool(forKey: "ReaderPublisherStyles")
            ? .on
            : .off
        viewMenu.addItem(publisherItem)
        viewMenu.addItem(.separator())

        let addBookmarkItem = NSMenuItem(
            title: L("添加书签", "Add Bookmark"),
            action: #selector(MainViewController.addBookmarkFromMenu(_:)),
            keyEquivalent: "d"
        )
        addBookmarkItem.target = mainViewController
        viewMenu.addItem(addBookmarkItem)

        let addNoteItem = NSMenuItem(
            title: L("添加笔记…", "Add Note…"),
            action: #selector(MainViewController.addNoteFromMenu(_:)),
            keyEquivalent: "n"
        )
        addNoteItem.keyEquivalentModifierMask = [.command, .shift]
        addNoteItem.target = mainViewController
        viewMenu.addItem(addNoteItem)

        let showBookmarksItem = NSMenuItem(
            title: L("书签与笔记", "Bookmarks & Notes"),
            action: #selector(MainViewController.showBookmarksFromMenu(_:)),
            keyEquivalent: "b"
        )
        showBookmarksItem.keyEquivalentModifierMask = [.command, .shift]
        showBookmarksItem.target = mainViewController
        viewMenu.addItem(showBookmarksItem)

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
