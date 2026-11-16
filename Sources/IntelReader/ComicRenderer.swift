import Foundation
import WebKit

enum ComicError: Error {
    case invalid
}

/// Serves CBZ pages on demand through a custom WKWebView scheme. A large comic
/// can be opened without inflating every page to disk; WebKit asks for the
/// pages near the viewport, and a small cache handles scrolling back.
final class ComicPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "easyread-comic"

    private let archive: ZipArchive
    private let names: [String]
    private let cache = NSCache<NSNumber, NSData>()
    private let lock = NSLock()
    private var cancelledTasks: Set<ObjectIdentifier> = []

    init(url: URL) throws {
        archive = try ZipArchive(url: url)
        names = try ComicRenderer.pageNames(from: url)
        super.init()
        cache.countLimit = 12
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme?.lowercased() == Self.scheme,
              url.host == "page" else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let rawIndex = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let index = Int(rawIndex), index >= 0, index < names.count else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let cacheKey = NSNumber(value: index)
        if let cached = cache.object(forKey: cacheKey) {
            respond(task, url: url, data: cached as Data, name: names[index])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.isCancelled(task) else { return }
            guard let data = try? self.archive.contents(of: self.names[index]) else {
                DispatchQueue.main.async {
                    guard !self.isCancelled(task) else { return }
                    task.didFailWithError(URLError(.fileDoesNotExist))
                }
                return
            }
            self.cache.setObject(data as NSData, forKey: cacheKey)
            DispatchQueue.main.async {
                guard !self.isCancelled(task) else { return }
                self.respond(task, url: url, data: data, name: self.names[index])
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        cancelledTasks.insert(ObjectIdentifier(task))
        lock.unlock()
    }

    private func isCancelled(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledTasks.contains(ObjectIdentifier(task))
    }

    private func respond(
        _ task: WKURLSchemeTask,
        url: URL,
        data: Data,
        name: String
    ) {
        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: name),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }
}

/// CBZ comic books are ZIP archives of page images. Pages are served on demand
/// through `ComicPageSchemeHandler`, so opening a very large comic does not
/// inflate every image to disk; the table of contents lists every page and
/// jumps with an HTML anchor.
enum ComicRenderer {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff"
    ]

    static func pageNames(from url: URL) throws -> [String] {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            throw ComicError.invalid
        }
        let names = archive.names
            .filter { name in
                guard ZipArchive.isSafePath(name), !name.hasSuffix("/") else { return false }
                let ext = (name as NSString).pathExtension.lowercased()
                return imageExtensions.contains(ext)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { throw ComicError.invalid }
        return names
    }

    static func pages(from url: URL) throws -> [(name: String, data: Data)] {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            throw ComicError.invalid
        }
        let names = try pageNames(from: url)
        var result: [(name: String, data: Data)] = []
        result.reserveCapacity(names.count)
        for name in names {
            guard let data = try? archive.contents(of: name) else { continue }
            result.append((name: name, data: data))
        }
        guard !result.isEmpty else { throw ComicError.invalid }
        return result
    }

    static func html(
        from url: URL,
        fontSize: CGFloat,
        isDark: Bool
    ) throws -> (htmlURL: URL, accessRoot: URL) {
        let pageNames = try pageNames(from: url)
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("IntelReader-CBZ-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

        var body = """
        <style>
        body { max-width: 100%; margin: 0; padding: 0; background: transparent; }
        .comic-page { margin: 0; padding: 0; text-align: center; }
        .comic-page img { display: block; margin: 0 auto; max-width: 100%; height: auto; }
        .comic-page + .comic-page { margin-top: 2px; }
        </style>
        """
        for index in pageNames.indices {
            body += """
            <div class="comic-page" id="cbz-page-\(index)"><img loading="lazy" decoding="async" src="\(ComicPageSchemeHandler.scheme)://page/\(index)" alt="\(index + 1)"></div>
            """
        }

        let html = BookImporter.readerDocument(body: body, fontSize: fontSize, isDark: isDark)
        let htmlURL = workspace.appendingPathComponent("intel-reader.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (htmlURL, workspace)
    }

    static func chapters(for url: URL) throws -> [ReaderChapter] {
        let names = try pageNames(from: url)
        return names.enumerated().map { index, name in
            let displayName = (name as NSString).lastPathComponent
            return ReaderChapter(
                title: String(format: L("第 %d 页", "Page %d"), index + 1) + " · " + displayName,
                progress: nil,
                anchorID: "cbz-page-\(index)",
                pageIndex: nil,
                level: 0
            )
        }
    }
}
