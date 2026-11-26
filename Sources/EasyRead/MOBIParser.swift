import Foundation

/// Native reader for PalmDOC / Mobipocket 6 / KF8 (AZW3) containers.
///
/// EasyRead used to shell out to Calibre's `ebook-convert` for MOBI, AZW and
/// AZW3 books. That made the app depend on a second 300 MB installation. This
/// parser decodes the container itself: PalmDOC and HUFF/CDIC decompression,
/// KF8 skeleton/fragment reconstruction, resource images, and the old
/// Mobipocket `filepos`/`recindex` markup. Nothing outside macOS is required.
enum MOBIParseError: Error {
    case notMOBI
    case encrypted
    case unsupportedCompression(Int)
    case corrupted
}

struct MOBIBook {
    let title: String
    let author: String
    /// Body-level HTML of every spine document, in reading order.
    let parts: [String]
    /// Resource images keyed by the file name referenced from `parts`.
    let images: [String: Data]
    let isKF8: Bool
}

enum MOBIParser {
    private final class PartsCacheEntry {
        let title: String
        let author: String
        let parts: [String]
        let isKF8: Bool

        init(title: String, author: String, parts: [String], isKF8: Bool) {
            self.title = title
            self.author = author
            self.parts = parts
            self.isKF8 = isKF8
        }
    }

    /// Opening a MOBI renders it, and the first sync then needs the same text
    /// to build a chapter table. Keeping the decoded parts for the last couple
    /// of books avoids decompressing the whole container twice.
    private static let partsCache: NSCache<NSString, PartsCacheEntry> = {
        let cache = NSCache<NSString, PartsCacheEntry>()
        cache.countLimit = 2
        return cache
    }()

    static func parse(url: URL) throws -> MOBIBook {
        let book = try parseContainer(url: url)
        storePartsCache(book, for: url)
        return book
    }

    /// Text-only variant used by the sync chapter table. Images are not needed
    /// there, so a cache hit can return without touching resources at all.
    static func parseTextOnly(url: URL) throws -> MOBIBook {
        if let key = cacheKey(for: url),
           let cached = partsCache.object(forKey: key as NSString) {
            return MOBIBook(
                title: cached.title,
                author: cached.author,
                parts: cached.parts,
                images: [:],
                isKF8: cached.isKF8
            )
        }
        let book = try parseContainer(url: url)
        storePartsCache(book, for: url)
        return MOBIBook(
            title: book.title,
            author: book.author,
            parts: book.parts,
            images: [:],
            isKF8: book.isKF8
        )
    }

    private static func cacheKey(for url: URL) -> String? {
        let source = url.standardizedFileURL
        guard let values = try? source.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return nil
        }
        let size = values.fileSize ?? -1
        let modified = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(source.path)|\(size)|\(modified)"
    }

    private static func storePartsCache(_ book: MOBIBook, for url: URL) {
        guard let key = cacheKey(for: url) else { return }
        partsCache.setObject(
            PartsCacheEntry(
                title: book.title,
                author: book.author,
                parts: book.parts,
                isKF8: book.isKF8
            ),
            forKey: key as NSString
        )
    }

    /// A "combo" book stores an old Mobipocket part and a KF8 part in the same
    /// Palm database. Prefer the KF8 part, which has the modern layout.
    private static func preferredHeader(palm: PalmDatabase) throws -> MOBIHeader {
        var header = try MOBIHeader(palm: palm, index: 0)
        if header.version < 8 {
            for index in 1..<max(palm.count - 1, 1) {
                guard palm.length(of: index) == 8 else { continue }
                let record = palm.record(index)
                let isBoundary = record == [0xE9, 0x8E, 0x0D, 0x0A] ||
                    Array("BOUNDARY".utf8) == record
                guard isBoundary else { continue }
                let next = palm.record(index + 1)
                guard next.count > 20,
                      Array(next[16..<20]) == Array("MOBI".utf8) else { continue }
                if let candidate = try? MOBIHeader(palm: palm, index: index + 1),
                   candidate.version >= 8 {
                    header = candidate
                }
            }
        }
        return header
    }

    private static func parseContainer(url: URL) throws -> MOBIBook {
        let data = [UInt8](try Data(contentsOf: url))
        let palm = try PalmDatabase(data: data)
        let header = try preferredHeader(palm: palm)

        guard header.compression == 1 || header.compression == 2 || header.compression == 17480 else {
            throw MOBIParseError.unsupportedCompression(header.compression)
        }
        guard header.cryptoType == 0 else {
            throw MOBIParseError.encrypted
        }

        let raw = try rawMarkup(palm: palm, header: header)
        guard !raw.isEmpty else { throw MOBIParseError.corrupted }

        let resources = resources(palm: palm, header: header)
        let isKF8 = header.version >= 8

        var parts: [String]
        if isKF8 {
            let documents = kf8Documents(raw: raw, palm: palm, header: header)
            parts = documents.map {
                cleanKF8HTML(decode($0, codepage: header.codepage), slotNames: resources.slotNames)
            }
        } else {
            let html = cleanMobi6HTML(raw, header: header, slotNames: resources.slotNames)
            parts = splitMobi6HTML(html)
        }

        parts = parts.filter { part in
            !bodyContents(of: part).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !parts.isEmpty else { throw MOBIParseError.corrupted }

        return MOBIBook(
            title: header.title.isEmpty ? url.deletingPathExtension().lastPathComponent : header.title,
            author: header.author,
            parts: parts,
            images: resources.images,
            isKF8: isKF8
        )
    }

    /// Locates the producer-declared cover record. The shelf only needs the
    /// image, so this skips text decompression entirely.
    static func coverData(url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              let palm = try? PalmDatabase(data: [UInt8](data)),
              let header = try? preferredHeader(palm: palm) else { return nil }
        let resources = resources(palm: palm, header: header)
        if let offset = header.coverOffset,
           offset >= 0, offset < resources.records.count,
           imageExtension(Array(resources.records[offset].prefix(16))) != nil {
            return resources.records[offset]
        }
        if let offset = header.thumbnailOffset,
           offset >= 0, offset < resources.records.count,
           imageExtension(Array(resources.records[offset].prefix(16))) != nil {
            return resources.records[offset]
        }
        return resources.orderedImages.first
    }

    // MARK: - Palm database

    private struct PalmDatabase {
        let bytes: [UInt8]
        let ranges: [Range<Int>]

        init(data: [UInt8]) throws {
            guard data.count >= 78 else { throw MOBIParseError.notMOBI }
            let count = Int(data[76]) << 8 | Int(data[77])
            guard count > 0 else { throw MOBIParseError.notMOBI }
            var starts: [Int] = []
            starts.reserveCapacity(count + 1)
            for index in 0..<count {
                let offset = 78 + index * 8
                guard offset + 4 <= data.count else { throw MOBIParseError.corrupted }
                starts.append(
                    Int(data[offset]) << 24 |
                    Int(data[offset + 1]) << 16 |
                    Int(data[offset + 2]) << 8 |
                    Int(data[offset + 3])
                )
            }
            starts.append(data.count)
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(count)
            var previous = 78
            for index in 0..<count {
                let start = starts[index]
                let end = starts[index + 1]
                guard start >= previous, start <= end, end <= data.count else {
                    throw MOBIParseError.corrupted
                }
                ranges.append(start..<end)
                previous = start
            }
            self.bytes = data
            self.ranges = ranges
        }

        var count: Int { ranges.count }

        func length(of index: Int) -> Int {
            guard index >= 0, index < ranges.count else { return 0 }
            return ranges[index].count
        }

        func record(_ index: Int) -> [UInt8] {
            guard index >= 0, index < ranges.count else { return [] }
            return Array(bytes[ranges[index]])
        }
    }

    // MARK: - Header

    private struct MOBIHeader {
        let recordIndex: Int
        let compression: Int
        let textLength: Int
        let textRecordCount: Int
        let cryptoType: Int
        let headerLength: Int
        let codepage: Int
        let version: Int
        let minVersion: Int
        let firstResource: Int
        let huffOffset: Int
        let huffCount: Int
        let fdst: Int
        let fdstCount: Int
        let fragIndex: Int
        let skelIndex: Int
        let trailFlags: Int
        let title: String
        let author: String
        /// EXTH 201 / 202: resource-record index of the cover and its thumbnail.
        let coverOffset: Int?
        let thumbnailOffset: Int?

        init(palm: PalmDatabase, index: Int) throws {
            let record = palm.record(index)
            guard record.count > 40,
                  Array(record[16..<20]) == Array("MOBI".utf8) else {
                throw MOBIParseError.notMOBI
            }

            func u16(_ offset: Int) -> Int {
                guard offset >= 0, offset + 2 <= record.count else { return 0 }
                return Int(record[offset]) << 8 | Int(record[offset + 1])
            }
            func u32(_ offset: Int) -> Int {
                guard offset >= 0, offset + 4 <= record.count else { return 0 }
                return Int(record[offset]) << 24 |
                    Int(record[offset + 1]) << 16 |
                    Int(record[offset + 2]) << 8 |
                    Int(record[offset + 3])
            }

            recordIndex = index
            compression = u16(0x00)
            textLength = u32(0x04)
            textRecordCount = u16(0x08)
            cryptoType = u16(0x0C)
            headerLength = u32(0x14)
            let page = u32(0x1C)
            codepage = page
            version = u32(0x24)
            minVersion = u32(0x68)
            firstResource = u32(0x6C)
            huffOffset = u32(0x70)
            huffCount = u32(0x74)
            fdst = u32(0xC0)
            fdstCount = u32(0xC4)
            fragIndex = u32(0xF8)
            skelIndex = u32(0xFC)
            trailFlags = headerLength + 16 >= 0xF4 ? u16(0xF2) : 0

            // EXTH metadata
            var metadata: [Int: [UInt8]] = [:]
            let exthOffset = 16 + headerLength
            if u32(0x80) & 0x40 != 0,
               exthOffset + 12 <= record.count,
               Array(record[exthOffset..<exthOffset + 4]) == Array("EXTH".utf8) {
                let count = Int(
                    Int(record[exthOffset + 8]) << 24 |
                    Int(record[exthOffset + 9]) << 16 |
                    Int(record[exthOffset + 10]) << 8 |
                    Int(record[exthOffset + 11])
                )
                var position = exthOffset + 12
                for _ in 0..<max(count, 0) {
                    guard position + 8 <= record.count else { break }
                    let type = Int(record[position]) << 24 |
                        Int(record[position + 1]) << 16 |
                        Int(record[position + 2]) << 8 |
                        Int(record[position + 3])
                    let size = Int(record[position + 4]) << 24 |
                        Int(record[position + 5]) << 16 |
                        Int(record[position + 6]) << 8 |
                        Int(record[position + 7])
                    guard size >= 8, position + size <= record.count else { break }
                    metadata[type] = Array(record[(position + 8)..<(position + size)])
                    position += size
                }
            }

            let titleOffset = u32(0x54)
            let titleLength = u32(0x58)
            let titleBytes: [UInt8]
            if titleOffset > 0, titleLength > 0, titleOffset + titleLength <= record.count {
                titleBytes = Array(record[titleOffset..<(titleOffset + titleLength)])
            } else {
                titleBytes = []
            }
            title = MOBIParser.decode(titleBytes, codepage: page)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            author = (metadata[100].map { MOBIParser.decode($0, codepage: page) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            func metadataInteger(_ type: Int) -> Int? {
                guard let bytes = metadata[type], bytes.count >= 4 else { return nil }
                return Int(bytes[0]) << 24 |
                    Int(bytes[1]) << 16 |
                    Int(bytes[2]) << 8 |
                    Int(bytes[3])
            }
            coverOffset = metadataInteger(201)
            thumbnailOffset = metadataInteger(202)
        }
    }

    // MARK: - Text extraction

    private static func rawMarkup(palm: PalmDatabase, header: MOBIHeader) throws -> [UInt8] {
        var decompressor = try makeDecompressor(palm: palm, header: header)
        var output: [UInt8] = []
        output.reserveCapacity(max(header.textLength, 1 << 16))
        for index in 1...max(header.textRecordCount, 1) {
            let recordIndex = header.recordIndex + index
            guard recordIndex < palm.count else { break }
            var record = palm.record(recordIndex)
            record = trimTrailingEntries(record, header: header)
            output.append(contentsOf: try decompressor.decompress(record))
        }
        if header.version < 8, header.textLength > 0, output.count > header.textLength {
            output.removeLast(output.count - header.textLength)
        }
        return output
    }

    private static func trimTrailingEntries(_ record: [UInt8], header: MOBIHeader) -> [UInt8] {
        guard header.headerLength >= 0xE4, header.minVersion >= 5, header.trailFlags > 0 else {
            return record
        }
        var data = record
        let flags = header.trailFlags
        let trailers = (flags >> 1).nonzeroBitCount
        for _ in 0..<trailers {
            guard data.count >= 4 else { break }
            var size = 0
            for byte in data.suffix(4) {
                if byte & 0x80 != 0 { size = 0 }
                size = (size << 7) | Int(byte & 0x7F)
            }
            guard size > 0, size <= data.count else { break }
            data.removeLast(size)
        }
        if flags & 1 != 0, let last = data.last {
            let count = Int(last & 3) + 1
            if count <= data.count {
                data.removeLast(count)
            }
        }
        return data
    }

    private static func makeDecompressor(
        palm: PalmDatabase,
        header: MOBIHeader
    ) throws -> MOBIDecompressor {
        switch header.compression {
        case 1:
            return PassthroughDecompressor()
        case 2:
            return PalmDOCDecompressor()
        case 17480:
            let huffRecord = header.huffOffset + header.recordIndex
            guard header.huffOffset > 0,
                  header.huffOffset < 0xFFFF,
                  huffRecord >= 0,
                  huffRecord < palm.count,
                  header.huffCount > 0 else {
                throw MOBIParseError.corrupted
            }
            var cdics: [[UInt8]] = []
            for index in 1..<header.huffCount {
                let record = huffRecord + index
                guard record < palm.count else { break }
                cdics.append(palm.record(record))
            }
            return try HuffCDICDecompressor(huff: palm.record(huffRecord), cdics: cdics)
        default:
            throw MOBIParseError.unsupportedCompression(header.compression)
        }
    }

    // MARK: - KF8 documents

    private static func kf8Documents(
        raw: [UInt8],
        palm: PalmDatabase,
        header: MOBIHeader
    ) -> [[UInt8]] {
        let flows = fdstFlows(raw: raw, palm: palm, header: header)
        let text = flows.first ?? raw

        guard header.skelIndex != 0xFFFF, header.fragIndex != 0xFFFF,
              header.skelIndex != 0xFFFFFFFF, header.fragIndex != 0xFFFFFFFF,
              let skeletons = try? indexEntries(palm: palm, at: header.skelIndex),
              let fragments = try? indexEntries(palm: palm, at: header.fragIndex),
              !skeletons.isEmpty else {
            // Damaged or unusual KF8 file without usable indexes: the raw flow
            // is still an XHTML document and reads better than nothing.
            return [text]
        }

        struct Skeleton {
            let fragmentCount: Int
            let start: Int
            let length: Int
        }
        struct Fragment {
            let insert: Int
            let start: Int
            let length: Int
        }

        let skeletonTable: [Skeleton] = skeletons.compactMap { entry in
            guard let range = entry.tags[6], range.count >= 2 else { return nil }
            return Skeleton(
                fragmentCount: entry.tags[1]?.first ?? 0,
                start: range[0],
                length: range[1]
            )
        }
        let fragmentTable: [Fragment] = fragments.compactMap { entry in
            guard let range = entry.tags[6], range.count >= 2,
                  let insert = entry.textValue else { return nil }
            return Fragment(insert: insert, start: range[0], length: range[1])
        }

        var documents: [[UInt8]] = []
        var fragmentPointer = 0
        for skeleton in skeletonTable {
            guard skeleton.start >= 0,
                  skeleton.length >= 0,
                  skeleton.start + skeleton.length <= text.count else { continue }
            var basePointer = skeleton.start + skeleton.length
            var document = Array(text[skeleton.start..<basePointer])
            for _ in 0..<max(skeleton.fragmentCount, 0) {
                guard fragmentPointer < fragmentTable.count else { break }
                let fragment = fragmentTable[fragmentPointer]
                fragmentPointer += 1
                guard fragment.start >= 0,
                      fragment.length >= 0,
                      basePointer + fragment.length <= text.count else { break }
                var insert = fragment.insert - skeleton.start
                insert = min(max(insert, 0), document.count)
                document.insert(
                    contentsOf: text[basePointer..<(basePointer + fragment.length)],
                    at: insert
                )
                basePointer += fragment.length
            }
            documents.append(document)
        }
        if documents.isEmpty {
            documents = [text]
        }
        return documents
    }

    private static func fdstFlows(
        raw: [UInt8],
        palm: PalmDatabase,
        header: MOBIHeader
    ) -> [[UInt8]] {
        guard header.fdst > 0,
              header.fdst < 0xFFFF,
              header.fdstCount > 1,
              header.fdst + header.recordIndex < palm.count else {
            return [raw]
        }
        let data = palm.record(header.fdst + header.recordIndex)
        guard data.count >= 12, Array(data[0..<4]) == Array("FDST".utf8) else {
            return [raw]
        }
        let sectionCount = Int(
            Int(data[8]) << 24 | Int(data[9]) << 16 | Int(data[10]) << 8 | Int(data[11])
        )
        guard sectionCount > 0 else { return [raw] }
        var starts: [Int] = []
        for index in 0..<sectionCount {
            let offset = 12 + index * 8
            guard offset + 4 <= data.count else { return [raw] }
            starts.append(
                Int(data[offset]) << 24 |
                Int(data[offset + 1]) << 16 |
                Int(data[offset + 2]) << 8 |
                Int(data[offset + 3])
            )
        }
        starts.append(raw.count)
        var flows: [[UInt8]] = []
        for index in 0..<sectionCount {
            let start = min(max(starts[index], 0), raw.count)
            let end = min(max(starts[index + 1], start), raw.count)
            flows.append(Array(raw[start..<end]))
        }
        return flows
    }

    private struct IndexEntry {
        let text: [UInt8]
        let tags: [Int: [Int]]

        var textValue: Int? {
            var value = 0
            for byte in text {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
    }

    private struct TagDefinition {
        let tag: Int
        let valuesPerEntry: Int
        let mask: Int
        let endFlag: Int
    }

    private static func indexEntries(
        palm: PalmDatabase,
        at index: Int
    ) throws -> [IndexEntry] {
        guard index >= 0, index < palm.count else { throw MOBIParseError.corrupted }
        let main = palm.record(index)
        guard main.count >= 56, Array(main[0..<4]) == Array("INDX".utf8) else {
            throw MOBIParseError.corrupted
        }
        func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
            return Int(bytes[offset]) << 24 |
                Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 |
                Int(bytes[offset + 3])
        }

        let headerLength = u32(main, 4)
        let sectionCount = u32(main, 24)
        let tagSectionStart = headerLength
        guard tagSectionStart + 12 <= main.count,
              Array(main[tagSectionStart..<(tagSectionStart + 4)]) == Array("TAGX".utf8) else {
            throw MOBIParseError.corrupted
        }
        let tagTableEnd = u32(main, tagSectionStart + 4)
        let controlByteCount = u32(main, tagSectionStart + 8)
        var tagTable: [TagDefinition] = []
        if tagTableEnd > 12 {
            var offset = tagSectionStart + 12
            while offset + 4 <= tagSectionStart + tagTableEnd && offset + 4 <= main.count {
                tagTable.append(TagDefinition(
                    tag: Int(main[offset]),
                    valuesPerEntry: Int(main[offset + 1]),
                    mask: Int(main[offset + 2]),
                    endFlag: Int(main[offset + 3])
                ))
                offset += 4
            }
        }
        guard controlByteCount > 0, !tagTable.isEmpty else {
            throw MOBIParseError.corrupted
        }

        var entries: [IndexEntry] = []
        for sectionIndex in 0..<max(sectionCount, 1) {
            let recordIndex = index + 1 + sectionIndex
            guard recordIndex < palm.count else { break }
            let section = palm.record(recordIndex)
            guard section.count >= 24 else { continue }
            let entryCount = u32(section, 24)
            let positionsStart = u32(section, 20)
            guard entryCount > 0, positionsStart >= 0, positionsStart + 4 + entryCount * 2 <= section.count else {
                continue
            }
            var positions: [Int] = []
            positions.reserveCapacity(entryCount + 1)
            for entryIndex in 0..<entryCount {
                let offset = positionsStart + 4 + entryIndex * 2
                positions.append(Int(section[offset]) << 8 | Int(section[offset + 1]))
            }
            positions.append(positionsStart)
            for entryIndex in 0..<entryCount {
                let start = positions[entryIndex]
                let end = positions[entryIndex + 1]
                guard start >= 0, start < section.count, end <= section.count, start < end else {
                    continue
                }
                let textLength = Int(section[start])
                let textStart = start + 1
                let tagStart = textStart + textLength
                guard tagStart <= end, tagStart + controlByteCount <= end else { continue }
                let tags = parseTags(
                    bytes: section,
                    tagStart: tagStart,
                    controlByteCount: controlByteCount,
                    tagTable: tagTable
                )
                var textBytes: [UInt8] = []
                if textLength > 0, textStart + textLength <= section.count {
                    textBytes = Array(section[textStart..<(textStart + textLength)])
                }
                entries.append(IndexEntry(text: textBytes, tags: tags))
            }
        }
        return entries
    }

    private static func parseTags(
        bytes: [UInt8],
        tagStart: Int,
        controlByteCount: Int,
        tagTable: [TagDefinition]
    ) -> [Int: [Int]] {
        var dataStart = tagStart + controlByteCount
        var controlIndex = 0
        var pending: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []

        for definition in tagTable {
            if definition.endFlag == 1 {
                controlIndex += 1
                continue
            }
            guard tagStart + controlIndex < bytes.count else { break }
            let controlByte = Int(bytes[tagStart + controlIndex])
            let value = controlByte & definition.mask
            if value == 0 { continue }
            if value == definition.mask {
                if definition.mask.nonzeroBitCount > 1 {
                    guard let (consumed, byteCount) = variableWidth(bytes, dataStart) else { continue }
                    dataStart += consumed
                    pending.append((definition.tag, nil, byteCount, definition.valuesPerEntry))
                } else {
                    pending.append((definition.tag, 1, nil, definition.valuesPerEntry))
                }
            } else {
                var shifted = value
                var mask = definition.mask
                while mask & 1 == 0 {
                    mask >>= 1
                    shifted >>= 1
                }
                pending.append((definition.tag, shifted, nil, definition.valuesPerEntry))
            }
        }

        var map: [Int: [Int]] = [:]
        for item in pending {
            var values: [Int] = []
            if let count = item.count {
                // Each tag may define more than one value per entry; the table
                // entry carries that number, so read it from the definition.
                for _ in 0..<(count * max(item.perEntry, 1)) {
                    guard let (consumed, value) = variableWidth(bytes, dataStart) else { break }
                    dataStart += consumed
                    values.append(value)
                }
            } else if let byteCount = item.bytes {
                var consumedTotal = 0
                while consumedTotal < byteCount {
                    guard let (consumed, value) = variableWidth(bytes, dataStart) else { break }
                    dataStart += consumed
                    consumedTotal += consumed
                    values.append(value)
                }
            }
            map[item.tag] = values
        }
        return map
    }

    private static func variableWidth(_ bytes: [UInt8], _ offset: Int) -> (Int, Int)? {
        var value = 0
        var consumed = 0
        while offset + consumed < bytes.count {
            let byte = bytes[offset + consumed]
            consumed += 1
            if byte & 0x80 != 0 {
                return (consumed, value << 7 | Int(byte & 0x7F))
            }
            value = value << 7 | Int(byte & 0x7F)
            if consumed > 4 { break }
        }
        return nil
    }

    // MARK: - Resources

    private struct Resources {
        let images: [String: Data]
        /// 1-based resource slot -> image file name.
        let slotNames: [Int: String]
        /// Every resource record in order; EXTH cover offsets index this list.
        let records: [Data]
        /// Image records in order, used when the cover offset is missing.
        let orderedImages: [Data]
    }

    private static func resources(palm: PalmDatabase, header: MOBIHeader) -> Resources {
        let fallback = header.recordIndex + header.textRecordCount + 1
        let start: Int
        if header.firstResource <= 0 || header.firstResource >= 0xFFFF {
            start = fallback
        } else {
            start = header.firstResource + header.recordIndex
        }
        guard start > 0, start < palm.count else {
            return Resources(images: [:], slotNames: [:], records: [], orderedImages: [])
        }
        var images: [String: Data] = [:]
        var slotNames: [Int: String] = [:]
        var records: [Data] = []
        var orderedImages: [Data] = []
        for recordIndex in start..<palm.count {
            let slot = recordIndex - start + 1
            let bytes = palm.record(recordIndex)
            let payload = Data(bytes)
            records.append(payload)
            guard let ext = imageExtension(bytes) else { continue }
            let name = "img\(slot).\(ext)"
            slotNames[slot] = name
            images[name] = payload
            orderedImages.append(payload)
        }
        return Resources(
            images: images,
            slotNames: slotNames,
            records: records,
            orderedImages: orderedImages
        )
    }

    private static func imageExtension(_ bytes: [UInt8]) -> String? {
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            return "jpg"
        }
        if bytes.count >= 8,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 6, Array(bytes[0..<4]) == Array("GIF8".utf8) {
            return "gif"
        }
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D {
            return "bmp"
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "webp"
        }
        return nil
    }

    // MARK: - Mobi6 markup

    private static func cleanMobi6HTML(
        _ raw: [UInt8],
        header: MOBIHeader,
        slotNames: [Int: String]
    ) -> String {
        let bytes = insertFilePositionAnchors(in: raw)
        var html = decode(bytes, codepage: header.codepage)
        html = html.replacingOccurrences(
            of: #"(?i)<mbp:pagebreak\s*/?>"#,
            with: "<hr class=\"chapter-break\">",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?i)filepos\s*=\s*["']?0*(\d+)["']?"#,
            with: "href=\"#filepos$1\"",
            options: .regularExpression
        )
        html = replaceImageReferences(html, slotNames: slotNames, attribute: "recindex")
        return html
    }

    /// Mobipocket 6 books link with byte offsets (`filepos="12345"`). The
    /// reader needs real anchors, so insert them into the raw byte stream
    /// before decoding; the ASCII marker is valid in every MOBI encoding.
    private static func insertFilePositionAnchors(in raw: [UInt8]) -> [UInt8] {
        var positions: [Int] = []
        let needle = Array("filepos".utf8)
        var index = 0
        while index + needle.count <= raw.count {
            if raw[index] == needle[0],
               Array(raw[index..<(index + needle.count)]) == needle {
                var cursor = index + needle.count
                while cursor < raw.count, raw[cursor] == 0x20 || raw[cursor] == 0x09 { cursor += 1 }
                if cursor < raw.count, raw[cursor] == 0x3D {
                    cursor += 1
                    while cursor < raw.count, raw[cursor] == 0x20 || raw[cursor] == 0x09 { cursor += 1 }
                    if cursor < raw.count, raw[cursor] == 0x22 || raw[cursor] == 0x27 { cursor += 1 }
                    var value = 0
                    var digits = 0
                    while cursor < raw.count, raw[cursor] >= 0x30, raw[cursor] <= 0x39 {
                        value = value * 10 + Int(raw[cursor] - 0x30)
                        digits += 1
                        cursor += 1
                    }
                    if digits > 0 { positions.append(value) }
                }
                index = cursor
            } else {
                index += 1
            }
        }
        let unique = Array(Set(positions)).sorted()
        guard !unique.isEmpty else { return raw }
        var result = raw
        for position in unique.reversed() {
            guard position > 0, position < result.count else { continue }
            let marker = Array("<a id=\"filepos\(position)\"></a>".utf8)
            result.insert(contentsOf: marker, at: position)
        }
        return result
    }

    private static func splitMobi6HTML(_ html: String) -> [String] {
        guard html.contains("chapter-break"),
              let bodyStart = html.range(of: "<body", options: .caseInsensitive) else {
            return [html]
        }
        _ = bodyStart
        let pieces = html.components(separatedBy: "<hr class=\"chapter-break\">")
        if pieces.count > 1 {
            return pieces.map { piece in
                piece.contains("<body") ? piece : "<html><body>\(piece)</body></html>"
            }
        }
        return [html]
    }

    // MARK: - KF8 markup

    private static func cleanKF8HTML(_ html: String, slotNames: [Int: String]) -> String {
        var text = html.replacingOccurrences(
            of: #"(?i)kindle:pos:fid:[0-9A-V]+:off:[0-9A-V]+"#,
            with: "#",
            options: .regularExpression
        )
        text = replaceKindleEmbeds(text, slotNames: slotNames)
        return text
    }

    private static func replaceKindleEmbeds(_ html: String, slotNames: [Int: String]) -> String {
        let pattern = #"(?i)kindle:embed:([0-9A-V]+)[^"'\s)]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let nsText = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range(at: 1))
            let slot = base32(token)
            let replacement: String
            if let name = slotNames[slot] {
                replacement = "Images/\(name)"
            } else {
                replacement = ""
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func replaceImageReferences(
        _ html: String,
        slotNames: [Int: String],
        attribute: String
    ) -> String {
        let pattern = #"(?i)"# + attribute + #"\s*=\s*["']?(\d+)["']?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let nsText = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range(at: 1))
            let slot = Int(token) ?? 0
            let replacement: String
            if let name = slotNames[slot] {
                replacement = "src=\"Images/\(name)\""
            } else {
                replacement = "src=\"\""
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func base32(_ value: String) -> Int {
        var result = 0
        for character in value.uppercased() {
            let digit: Int
            if let number = character.wholeNumberValue {
                digit = number
            } else if let ascii = character.asciiValue, ascii >= 0x41, ascii <= 0x56 {
                digit = Int(ascii - 0x41) + 10
            } else {
                continue
            }
            result = result * 32 + digit
        }
        return result
    }

    // MARK: - Text

    /// Returns the inner HTML of `<body>`, or the whole document when the
    /// book stores bare fragments.
    static func bodyContents(of source: String) -> String {
        guard let startTag = source.range(of: "<body", options: .caseInsensitive),
              let startEnd = source.range(of: ">", range: startTag.upperBound..<source.endIndex),
              let endTag = source.range(of: "</body", options: .caseInsensitive,
                                       range: startEnd.upperBound..<source.endIndex) else {
            return source
        }
        return String(source[startEnd.upperBound..<endTag.lowerBound])
    }

    static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        guard !bytes.isEmpty else { return "" }
        var payload = bytes
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
            payload.removeFirst(3)
            return String(decoding: payload, as: UTF8.self)
        }
        if codepage == 1252 {
            // Some producers declare 1252 but store UTF-8. Valid UTF-8 wins;
            // genuine Windows-1252 fails that check and uses the fallback.
            if let text = String(bytes: payload, encoding: .utf8) {
                return text
            }
            if let text = String(bytes: payload, encoding: .windowsCP1252) {
                return text
            }
        }
        if let text = String(bytes: payload, encoding: .utf8) {
            return text
        }
        if let text = String(bytes: payload, encoding: .windowsCP1252) {
            return text
        }
        return String(decoding: payload, as: UTF8.self)
    }
}

// MARK: - Decompressors

private protocol MOBIDecompressor {
    mutating func decompress(_ input: [UInt8]) throws -> [UInt8]
}

private struct PassthroughDecompressor: MOBIDecompressor {
    mutating func decompress(_ input: [UInt8]) throws -> [UInt8] { input }
}

/// PalmDOC LZ77, used by nearly every MOBI/AZW file.
private struct PalmDOCDecompressor: MOBIDecompressor {
    mutating func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var position = 0
        while position < input.count {
            let control = Int(input[position])
            position += 1
            switch control {
            case 0x01...0x08:
                let count = min(control, input.count - position)
                output.append(contentsOf: input[position..<(position + count)])
                position += count
            case 0x00, 0x09...0x7F:
                output.append(UInt8(control))
            case 0x80...0xBF:
                if position < input.count {
                    let pair = (control << 8) | Int(input[position])
                    position += 1
                    let distance = (pair >> 3) & 0x07FF
                    let length = (pair & 0x07) + 3
                    guard distance > 0, distance <= output.count else { continue }
                    if distance > length {
                        let start = output.count - distance
                        output.append(contentsOf: output[start..<(start + length)])
                    } else {
                        for _ in 0..<length {
                            output.append(output[output.count - distance])
                        }
                    }
                }
            default:
                output.append(0x20)
                output.append(UInt8(control ^ 0x80))
            }
        }
        return output
    }
}

/// HUFF/CDIC dictionary compression used by older high-compression MOBI files.
private final class HuffCDICDecompressor: MOBIDecompressor {
    private struct Code {
        let length: Int
        let terminal: Bool
        let maxCode: UInt32
    }

    private struct Phrase {
        let bytes: [UInt8]
        let literal: Bool
    }

    private var firstTable: [Code] = []
    private var minCode = [UInt32](repeating: 0, count: 33)
    private var maxCode = [UInt32](repeating: 0, count: 33)
    private var phrases: [Phrase?] = []

    init(huff: [UInt8], cdics: [[UInt8]]) throws {
        guard huff.count >= 24, Array(huff[0..<4]) == Array("HUFF".utf8) else {
            throw MOBIParseError.corrupted
        }
        func u32(_ offset: Int) -> Int {
            guard offset >= 0, offset + 4 <= huff.count else { return 0 }
            return Int(huff[offset]) << 24 |
                Int(huff[offset + 1]) << 16 |
                Int(huff[offset + 2]) << 8 |
                Int(huff[offset + 3])
        }
        let firstOffset = u32(8)
        let secondOffset = u32(12)
        guard firstOffset + 256 * 4 <= huff.count, secondOffset + 64 * 4 <= huff.count else {
            throw MOBIParseError.corrupted
        }
        for index in 0..<256 {
            let value = UInt32(u32(firstOffset + index * 4))
            let length = Int(value & 0x1F)
            guard length > 0, length <= 32 else { throw MOBIParseError.corrupted }
            let terminal = value & 0x80 != 0
            let codeMax = UInt32(truncatingIfNeeded:
                ((UInt64(value >> 8) + 1) << (32 - length)) - 1
            )
            firstTable.append(Code(length: length, terminal: terminal, maxCode: codeMax))
        }
        for length in 1...32 {
            let offset = secondOffset + (length - 1) * 8
            guard offset + 8 <= huff.count else { break }
            let minimum = u32(offset)
            let maximum = u32(offset + 4)
            minCode[length] = UInt32(truncatingIfNeeded: UInt64(minimum) << (32 - length))
            maxCode[length] = UInt32(truncatingIfNeeded:
                ((UInt64(maximum) + 1) << (32 - length)) - 1
            )
        }

        for cdic in cdics {
            guard cdic.count >= 16, Array(cdic[0..<4]) == Array("CDIC".utf8) else {
                throw MOBIParseError.corrupted
            }
            func u32c(_ offset: Int) -> Int {
                guard offset + 4 <= cdic.count else { return 0 }
                return Int(cdic[offset]) << 24 |
                    Int(cdic[offset + 1]) << 16 |
                    Int(cdic[offset + 2]) << 8 |
                    Int(cdic[offset + 3])
            }
            let phraseCount = u32c(8)
            let bits = u32c(12)
            guard bits > 0, bits < 16 else { throw MOBIParseError.corrupted }
            let capacity = min(1 << bits, max(phraseCount - phrases.count, 0))
            guard capacity > 0, 16 + capacity * 2 <= cdic.count else { continue }
            for index in 0..<capacity {
                let offset = 16 + index * 2
                let phraseOffset = Int(cdic[offset]) << 8 | Int(cdic[offset + 1])
                let headerPosition = 16 + phraseOffset
                guard headerPosition + 2 <= cdic.count else {
                    phrases.append(Phrase(bytes: [], literal: true))
                    continue
                }
                let header = Int(cdic[headerPosition]) << 8 | Int(cdic[headerPosition + 1])
                let length = header & 0x7FFF
                let start = headerPosition + 2
                let end = min(start + length, cdic.count)
                let bytes = start <= end ? Array(cdic[start..<end]) : []
                phrases.append(Phrase(bytes: bytes, literal: header & 0x8000 != 0))
            }
        }
    }

    func decompress(_ input: [UInt8]) throws -> [UInt8] {
        try unpack(input, depth: 0)
    }

    private func unpack(_ input: [UInt8], depth: Int) throws -> [UInt8] {
        guard depth < 32 else { throw MOBIParseError.corrupted }
        var data = input
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        var bitsLeft = input.count * 8
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)
        var position = 0
        var window = readUInt64(data, position)
        var bitCount = 32

        while true {
            if bitCount <= 0 {
                position += 4
                window = readUInt64(data, position)
                bitCount += 32
            }
            let code = UInt32(truncatingIfNeeded: window >> UInt64(bitCount))
            var entry = firstTable[Int(code >> 24)]
            var length = entry.length
            if !entry.terminal {
                while length < 32, code < minCode[length] {
                    length += 1
                }
                entry = Code(length: length, terminal: true, maxCode: maxCode[length])
            }
            bitCount -= length
            bitsLeft -= length
            if bitsLeft < 0 { break }
            guard length > 0, length <= 32 else { break }
            let index = Int((entry.maxCode &- code) >> UInt32(32 - length))
            guard index >= 0, index < phrases.count, let phrase = phrases[index] else { break }
            if phrase.literal {
                output.append(contentsOf: phrase.bytes)
            } else {
                let expanded = try unpack(phrase.bytes, depth: depth + 1)
                phrases[index] = Phrase(bytes: expanded, literal: true)
                output.append(contentsOf: expanded)
            }
        }
        return output
    }

    private func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8
            if offset + index < bytes.count {
                value |= UInt64(bytes[offset + index])
            }
        }
        return value
    }
}
