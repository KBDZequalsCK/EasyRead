import Foundation

/// A saved reading position, optionally carrying a note. Bookmarks and notes
/// share one record so the reader can show them in a single list.
struct ReaderBookmark: Codable, Identifiable {
    let id: UUID
    let bookPath: String
    var progress: Double
    var textProgress: Double?
    var pageIndex: Int?
    var snippet: String
    var note: String
    let createdAt: Date
}

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var items: [ReaderBookmark] = []

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntelReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("bookmarks.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ReaderBookmark].self, from: data) {
            items = decoded
        }
    }

    func bookmarks(for bookPath: String) -> [ReaderBookmark] {
        lock.lock()
        defer { lock.unlock() }
        return items
            .filter { $0.bookPath == bookPath }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(
        bookPath: String,
        progress: Double,
        textProgress: Double?,
        pageIndex: Int?,
        snippet: String,
        note: String
    ) -> ReaderBookmark {
        let bookmark = ReaderBookmark(
            id: UUID(),
            bookPath: bookPath,
            progress: min(max(progress, 0), 1),
            textProgress: textProgress.map { min(max($0, 0), 1) },
            pageIndex: pageIndex,
            snippet: snippet,
            note: note,
            createdAt: Date()
        )
        lock.lock()
        items.append(bookmark)
        let snapshot = items
        lock.unlock()
        persist(snapshot)
        return bookmark
    }

    func updateNote(id: UUID, note: String) {
        lock.lock()
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].note = note
        }
        let snapshot = items
        lock.unlock()
        persist(snapshot)
    }

    func remove(id: UUID) {
        lock.lock()
        items.removeAll { $0.id == id }
        let snapshot = items
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [ReaderBookmark]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
