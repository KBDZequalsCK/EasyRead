import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds small cover images for the shelf's cover view.
///
/// Real covers are read from the book itself (EPUB cover item, PDF first page,
/// first CBZ page, MOBI/AZW3 cover record, FB2 coverpage, DOCX thumbnail).
/// Formats without a cover get a designed title card, so every shelf cell has a
/// stable visual even for plain TXT notes. Extracted covers are cached on disk
/// and downscaled once; placeholders are cheap and stay in memory only.
enum BookCoverLoader {
    private static let cacheVersion = "2"
    private static let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        return cache
    }()
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EasyRead.BookCover"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff"
    ]

    private static var cacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support
            .appendingPathComponent("IntelReader", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func cover(for book: LibraryBook, completion: @escaping (NSImage?) -> Void) {
        let identity = identity(for: book)
        let memoryKey = "\(identity)|\(book.title)|\(book.author)"
        if let cached = memoryCache.object(forKey: memoryKey as NSString) {
            completion(cached)
            return
        }

        queue.addOperation {
            let extracted = loadCachedCover(identity: identity) ?? extractCover(for: book)
            DispatchQueue.main.async {
                let image: NSImage
                if let extracted {
                    image = NSImage(cgImage: extracted, size: NSSize(
                        width: extracted.width,
                        height: extracted.height
                    ))
                } else {
                    image = placeholder(for: book)
                }
                memoryCache.setObject(image, forKey: memoryKey as NSString)
                completion(image)
            }
        }
    }

    // MARK: - Identity and disk cache

    private static func identity(for book: LibraryBook) -> String {
        let url = URL(fileURLWithPath: book.path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(cacheVersion)|\(book.format)|\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    private static func cacheURL(for identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).png")
    }

    private static func loadCachedCover(identity: String) -> CGImage? {
        let url = cacheURL(for: identity)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return thumbnail(from: data)
    }

    private static func saveCachedCover(_ image: CGImage, identity: String) {
        guard let data = encodedPNG(image) else { return }
        let url = cacheURL(for: identity)
        try? data.write(to: url, options: .atomic)
        pruneCacheIfNeeded()
    }

    private static func pruneCacheIfNeeded() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), entries.count > 200 else { return }
        let sorted = entries.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left < right
        }
        for url in sorted.prefix(entries.count - 200) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func encodedPNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Cover extraction

    private static func extractCover(for book: LibraryBook) -> CGImage? {
        let url = URL(fileURLWithPath: book.path)
        guard FileManager.default.fileExists(atPath: book.path) else { return nil }
        let image: CGImage?
        switch book.format.uppercased() {
        case "PDF":
            image = pdfCover(url)
        case "EPUB":
            image = epubCover(url)
        case "CBZ":
            image = comicCover(url)
        case "MOBI", "AZW", "AZW3":
            image = MOBIParser.coverData(url: url).flatMap(thumbnail(from:))
        case "FB2":
            image = FB2Renderer.coverData(url: url).flatMap(thumbnail(from:))
        case "DOCX":
            image = docxCover(url)
        default:
            image = nil
        }
        if let image {
            saveCachedCover(image, identity: identity(for: book))
        }
        return image
    }

    private static func pdfCover(_ url: URL) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let maxSize = CGSize(width: 600, height: 900)
        let scale = min(maxSize.width / box.width, maxSize.height / box.height)
        let width = max(Int((box.width * scale).rounded()), 1)
        let height = max(Int((box.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        // `getDrawingTransform` maps the PDF page into the bitmap upright and
        // honours the page's own rotation; the previous hand-built flip left
        // every PDF cover upside down.
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = page.getDrawingTransform(
            .cropBox,
            rect: target,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
        return context.makeImage()
    }

    private static func comicCover(_ url: URL) -> CGImage? {
        guard let archive = try? ZipArchive(url: url) else { return nil }
        guard let names = try? ComicRenderer.pageNames(from: url),
              let first = names.first,
              let data = try? archive.contents(of: first) else { return nil }
        return thumbnail(from: data)
    }

    private static func docxCover(_ url: URL) -> CGImage? {
        guard let archive = try? ZipArchive(url: url) else { return nil }
        for name in ["docProps/thumbnail.jpeg", "docProps/thumbnail.jpg", "docProps/thumbnail.png"] {
            if let data = zipData(archive, path: name) {
                return thumbnail(from: data)
            }
        }
        return nil
    }

    private static func epubCover(_ url: URL) -> CGImage? {
        guard let archive = try? ZipArchive(url: url),
              let containerData = zipData(archive, path: "META-INF/container.xml"),
              let rootPath = BookImporter.epubContainerRootFilePath(from: containerData),
              let opfData = zipData(archive, path: rootPath) else { return nil }

        let parser = EPUBCoverParser()
        let xml = XMLParser(data: opfData)
        xml.delegate = parser
        guard xml.parse() else { return nil }

        let opfDirectory = (rootPath as NSString).deletingLastPathComponent
        var candidates: [String] = []
        if let coverID = parser.coverID,
           let item = parser.manifest[coverID] {
            candidates.append(item.href)
        }
        if let item = parser.manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            candidates.append(item.href)
        }
        if let item = parser.manifest.values.first(where: {
            ($0.properties.contains("cover") || $0.href.lowercased().contains("cover"))
                && imageExtensions.contains(($0.href as NSString).pathExtension.lowercased())
        }) {
            candidates.append(item.href)
        }
        if let guide = parser.guideCoverHref {
            candidates.append(guide)
        }

        var seen = Set<String>()
        for candidate in candidates {
            let resolved = resolveEPUBPath(candidate, relativeTo: opfDirectory)
            guard seen.insert(resolved).inserted else { continue }
            if imageExtensions.contains((resolved as NSString).pathExtension.lowercased()) {
                if let data = zipData(archive, path: resolved) {
                    return thumbnail(from: data)
                }
                continue
            }
            // A cover page is often an XHTML wrapper around the actual image.
            guard let pageData = zipData(archive, path: resolved),
                  let imageHref = firstImageReference(in: pageData) else { continue }
            let imagePath = resolveEPUBPath(
                imageHref,
                relativeTo: (resolved as NSString).deletingLastPathComponent
            )
            if let data = zipData(archive, path: imagePath) {
                return thumbnail(from: data)
            }
        }
        return nil
    }

    private static func resolveEPUBPath(_ href: String, relativeTo directory: String) -> String {
        let withoutFragment = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        return BookImporter.normalizedEPUBPath(
            directory.isEmpty ? decoded : "\(directory)/\(decoded)"
        )
    }

    private static func firstImageReference(in data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let pattern = #"(?i)<(?:img|image)\b[^>]*?\b(?:src|xlink:href|href)\s*=\s*(?:"([^"]+)"|'([^']+)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(location: 0, length: (html as NSString).length)
              ) else { return nil }
        for index in [1, 2] {
            let range = match.range(at: index)
            if range.location != NSNotFound {
                return (html as NSString).substring(with: range)
            }
        }
        return nil
    }

    private static func zipData(_ archive: ZipArchive, path: String) -> Data? {
        if let data = try? archive.contents(of: path) {
            return data
        }
        let lowered = path.lowercased()
        guard let name = archive.names.first(where: { $0.lowercased() == lowered }) else { return nil }
        return try? archive.contents(of: name)
    }

    private static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Generated covers

    private static let palettes: [(NSColor, NSColor)] = [
        (NSColor(calibratedRed: 0.31, green: 0.42, blue: 0.36, alpha: 1),
         NSColor(calibratedRed: 0.18, green: 0.27, blue: 0.23, alpha: 1)),
        (NSColor(calibratedRed: 0.44, green: 0.35, blue: 0.27, alpha: 1),
         NSColor(calibratedRed: 0.25, green: 0.19, blue: 0.16, alpha: 1)),
        (NSColor(calibratedRed: 0.28, green: 0.36, blue: 0.45, alpha: 1),
         NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.29, alpha: 1)),
        (NSColor(calibratedRed: 0.42, green: 0.38, blue: 0.28, alpha: 1),
         NSColor(calibratedRed: 0.24, green: 0.22, blue: 0.16, alpha: 1)),
        (NSColor(calibratedRed: 0.38, green: 0.31, blue: 0.42, alpha: 1),
         NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.28, alpha: 1))
    ]

    private static func placeholder(for book: LibraryBook) -> NSImage {
        let size = NSSize(width: 240, height: 360)
        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            drawPlaceholder(book: book, size: size)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func drawPlaceholder(book: LibraryBook, size: NSSize) {
        let rect = NSRect(origin: .zero, size: size)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in book.title.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let palette = palettes[Int(hash % UInt64(palettes.count))]
        NSGradient(starting: palette.0, ending: palette.1)?.draw(in: rect, angle: -90)

        let ink = NSColor.white.withAlphaComponent(0.92)
        let softInk = NSColor.white.withAlphaComponent(0.62)

        // A thin "spine" line and a top rule keep flat title cards from looking
        // like a plain colored rectangle. The format itself is drawn by the
        // shelf cell as a shared corner badge, for extracted covers too.
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(rect: NSRect(x: 15, y: 16, width: 1.5, height: size.height - 32)).fill()
        NSBezierPath(rect: NSRect(x: 24, y: size.height - 34, width: size.width - 48, height: 1)).fill()

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byTruncatingTail
        titleStyle.lineSpacing = 3
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: ink,
            .paragraphStyle: titleStyle
        ]
        let titleBox = NSRect(x: 24, y: 132, width: size.width - 48, height: 122)
        let measured = (book.title as NSString).boundingRect(
            with: NSSize(width: titleBox.width, height: titleBox.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: titleAttributes
        )
        let titleHeight = min(measured.height, titleBox.height)
        let titleRect = NSRect(
            x: titleBox.minX,
            y: titleBox.minY + (titleBox.height - titleHeight) / 2,
            width: titleBox.width,
            height: titleHeight
        )
        (book.title as NSString).draw(
            with: titleRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes
        )

        guard !book.author.isEmpty else { return }
        let authorStyle = NSMutableParagraphStyle()
        authorStyle.alignment = .center
        authorStyle.lineBreakMode = .byTruncatingTail
        let authorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: softInk,
            .paragraphStyle: authorStyle
        ]
        (book.author as NSString).draw(
            with: NSRect(x: 24, y: 96, width: size.width - 48, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: authorAttributes
        )
    }
}

/// Reads just enough of the EPUB package document to locate its cover image.
private final class EPUBCoverParser: NSObject, XMLParserDelegate {
    struct Item {
        let href: String
        let properties: String
    }

    var manifest: [String: Item] = [:]
    var coverID: String?
    var guideCoverHref: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "meta":
            if (attributeDict["name"] ?? "").lowercased() == "cover",
               let content = attributeDict["content"] {
                coverID = content
            }
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = Item(
                    href: href.removingPercentEncoding ?? href,
                    properties: (attributeDict["properties"] ?? "").lowercased()
                )
            }
        case "reference":
            if (attributeDict["type"] ?? "").lowercased() == "cover" {
                guideCoverHref = attributeDict["href"]?.removingPercentEncoding
            }
        default:
            break
        }
    }
}