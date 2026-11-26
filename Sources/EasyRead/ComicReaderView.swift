import AppKit
import ImageIO

/// Loads CBZ pages directly from the archive for the native comic view.
final class ComicPageProvider {
    let archive: ZipArchive
    let names: [String]

    private let dataCache = NSCache<NSNumber, NSData>()
    private let wideCache = NSCache<NSNumber, NSNumber>()

    init(url: URL) throws {
        archive = try ZipArchive(url: url)
        names = try ComicRenderer.pageNames(from: url)
        dataCache.countLimit = 6
        wideCache.countLimit = 128
    }

    var pageCount: Int { names.count }

    func data(at index: Int) -> Data? {
        guard index >= 0, index < names.count else { return nil }
        let key = NSNumber(value: index)
        if let cached = dataCache.object(forKey: key) {
            return cached as Data
        }
        guard let data = try? archive.contents(of: names[index]) else { return nil }
        dataCache.setObject(data as NSData, forKey: key)
        return data
    }

    func image(at index: Int) -> NSImage? {
        guard let data = data(at: index) else { return nil }
        return NSImage(data: data)
    }

    /// Landscape pages are usually a single two-page spread; pairing them with
    /// another page would shrink them to a quarter of the width.
    func isWide(at index: Int) -> Bool {
        guard index >= 0, index < names.count else { return false }
        let key = NSNumber(value: index)
        if let cached = wideCache.object(forKey: key) {
            return cached.boolValue
        }
        guard let data = data(at: index),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              height.doubleValue > 0 else {
            return false
        }
        let wide = width.doubleValue / height.doubleValue > 1.12
        wideCache.setObject(NSNumber(value: wide), forKey: key)
        return wide
    }
}

/// Native two-page (or single-page) comic reader. It intentionally bypasses
/// WKWebView so page pairing, wide spreads, click zones and page counts are
/// deterministic and do not depend on CSS column measurement.
final class ComicReaderView: NSView {
    private let provider: ComicPageProvider
    private let leftImageView = NSImageView()
    private let rightImageView = NSImageView()
    private let loadQueue = DispatchQueue(label: "EasyRead.ComicReader", qos: .userInitiated)
    private var loadGeneration = 0
    private var spreadEnabled: Bool
    private var displayedPages: [Int] = []

    private(set) var currentPage = 0
    var pageCount: Int { provider.pageCount }
    var isSpreadEnabled: Bool { spreadEnabled }

    /// (firstPage, lastPage, totalPages), zero-based.
    var onPageChanged: ((Int, Int, Int) -> Void)?
    var isDark: Bool = false {
        didSet { applyTheme() }
    }

    init(url: URL, spread: Bool) throws {
        provider = try ComicPageProvider(url: url)
        spreadEnabled = spread
        super.init(frame: .zero)
        wantsLayer = true

        for imageView in [leftImageView, rightImageView] {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(imageView)
        }
        rightImageView.isHidden = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func goToPage(_ page: Int) {
        let clamped = min(max(page, 0), max(pageCount - 1, 0))
        currentPage = clamped
        loadPages(anchor: clamped, preferPrevious: false)
    }

    func nextPage() {
        let anchor = (displayedPages.last ?? currentPage) + 1
        guard anchor < pageCount else { return }
        currentPage = anchor
        loadPages(anchor: anchor, preferPrevious: false)
    }

    func previousPage() {
        let first = displayedPages.first ?? currentPage
        let anchor = max(first - 1, 0)
        guard anchor < first else { return }
        currentPage = anchor
        loadPages(anchor: anchor, preferPrevious: true)
    }

    var pageFraction: Double {
        pageCount > 1 ? Double(currentPage) / Double(pageCount - 1) : 0
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let gap: CGFloat = 8
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 1, rect.height > 1 else { return }
        if displayedPages.count > 1 {
            let width = max((rect.width - gap) / 2, 1)
            leftImageView.frame = NSRect(
                x: rect.minX,
                y: rect.minY,
                width: width,
                height: rect.height
            )
            rightImageView.frame = NSRect(
                x: rect.minX + width + gap,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        } else {
            leftImageView.frame = rect
            rightImageView.frame = .zero
        }
    }

    private func loadPages(anchor: Int, preferPrevious: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadQueue.async { [weak self] in
            guard let self else { return }
            let pages = self.spreadEnabled
                ? self.spreadPages(anchor: anchor, preferPrevious: preferPrevious)
                : [anchor]
            let images: [NSImage?] = pages.map { self.provider.image(at: $0) }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.displayedPages = pages
                self.leftImageView.image = images.first ?? nil
                self.rightImageView.image = images.count > 1 ? images[1] : nil
                self.rightImageView.isHidden = images.count < 2
                self.needsLayout = true
                self.onPageChanged?(
                    pages.first ?? anchor,
                    pages.last ?? anchor,
                    self.pageCount
                )
            }
        }
    }

    private func spreadPages(anchor: Int, preferPrevious: Bool) -> [Int] {
        guard spreadEnabled else { return [anchor] }
        guard !provider.isWide(at: anchor) else { return [anchor] }
        if preferPrevious {
            if anchor > 0, !provider.isWide(at: anchor - 1) {
                return [anchor - 1, anchor]
            }
            return [anchor]
        }
        let next = anchor + 1
        if next < pageCount, !provider.isWide(at: next) {
            return [anchor, next]
        }
        return [anchor]
    }

    private func applyTheme() {
        layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : NSColor(calibratedWhite: 0.9, alpha: 1)).cgColor
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        if point.x < bounds.midX {
            previousPage()
        } else {
            nextPage()
        }
    }
}
