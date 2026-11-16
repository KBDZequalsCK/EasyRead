import Foundation
import zlib

/// In-process ZIP reader used for EPUB books.
///
/// EasyRead previously ran `/usr/bin/unzip` in a subprocess for every EPUB.
/// The system tool is always present on macOS, but spawning it makes opening a
/// book slower and leaves the app with an external dependency. This reader
/// walks the central directory itself and inflates entries with the system
/// zlib that ships with macOS, so EPUB text can be parsed straight from the
/// archive and only real resources (images, fonts) are written to disk.
enum ZipArchiveError: Error {
    case invalidArchive
    case encryptedEntry
    case unsupportedCompression(UInt16)
    case entryNotFound
    case decompressionFailed
}

struct ZipArchive {
    struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    private(set) var entries: [String: Entry] = [:]

    var names: [String] { Array(entries.keys) }

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
        guard !entries.isEmpty else { throw ZipArchiveError.invalidArchive }
    }

    func contains(_ name: String) -> Bool {
        entries[name] != nil
    }

    /// Returns the decompressed bytes of one entry.
    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipArchiveError.entryNotFound }
        guard entry.flags & 0x0001 == 0 else { throw ZipArchiveError.encryptedEntry }
        let offset = entry.localHeaderOffset
        guard offset >= 0, offset + 30 <= data.count,
              Self.u32(data, offset) == 0x0403_4B50 else {
            throw ZipArchiveError.invalidArchive
        }
        let nameLength = Self.u16(data, offset + 26)
        let extraLength = Self.u16(data, offset + 28)
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else {
            throw ZipArchiveError.invalidArchive
        }
        let payload = data.subdata(in: start..<end)
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try Self.inflateRaw(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipArchiveError.unsupportedCompression(entry.method)
        }
    }

    /// Writes matching entries below `directory`, preserving archive paths.
    func extract(to directory: URL, including filter: (String) -> Bool = { _ in true }) throws {
        let fileManager = FileManager.default
        for name in entries.keys.sorted() where filter(name) {
            guard Self.isSafePath(name), !name.hasSuffix("/") else { continue }
            let payload = try contents(of: name)
            let destination = directory.appendingPathComponent(name)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: destination, options: .atomic)
        }
    }

    /// Rejects absolute paths and `..` components so a malicious archive
    /// cannot write outside the extraction directory.
    static func isSafePath(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\") else {
            return false
        }
        return !name.split(separator: "/").contains("..")
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard let eocd = endOfCentralDirectory(data) else {
            throw ZipArchiveError.invalidArchive
        }
        var entryCount = u16(data, eocd + 10)
        var directorySize = u32(data, eocd + 12)
        var directoryOffset = u32(data, eocd + 16)

        // Zip64 archives move the real values into a separate end record.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            if let values = zip64DirectoryValues(data, eocd: eocd) {
                entryCount = values.count
                directorySize = values.size
                directoryOffset = values.offset
            }
        }
        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= data.count else {
            throw ZipArchiveError.invalidArchive
        }

        var entries: [String: Entry] = [:]
        entries.reserveCapacity(entryCount)
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4B50 else { break }
            let flags = UInt16(u16(data, offset + 8))
            let method = UInt16(u16(data, offset + 10))
            var compressedSize = u32(data, offset + 20)
            var uncompressedSize = u32(data, offset + 24)
            let nameLength = u16(data, offset + 28)
            let extraLength = u16(data, offset + 30)
            let commentLength = u16(data, offset + 32)
            var localOffset = u32(data, offset + 42)

            guard offset + 46 + nameLength + extraLength + commentLength <= data.count else {
                break
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF ||
                localOffset == 0xFFFF_FFFF {
                var extra = offset + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let identifier = u16(data, extra)
                    let size = u16(data, extra + 2)
                    if identifier == 0x0001 {
                        var cursor = extra + 4
                        if uncompressedSize == 0xFFFF_FFFF, cursor + 8 <= extra + 4 + size {
                            uncompressedSize = u64(data, cursor)
                            cursor += 8
                        }
                        if compressedSize == 0xFFFF_FFFF, cursor + 8 <= extra + 4 + size {
                            compressedSize = u64(data, cursor)
                            cursor += 8
                        }
                        if localOffset == 0xFFFF_FFFF, cursor + 8 <= extra + 4 + size {
                            localOffset = u64(data, cursor)
                        }
                        break
                    }
                    extra += 4 + size
                }
            }

            let name = decodeName(nameData, utf8: flags & 0x0800 != 0)
            entries[name] = Entry(
                name: name,
                flags: flags,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func endOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let earliest = max(0, data.count - 65_535 - 22)
        var offset = data.count - 22
        while offset >= earliest {
            if u32(data, offset) == 0x0605_4B50 {
                let commentLength = u16(data, offset + 20)
                if offset + 22 + commentLength <= data.count {
                    return offset
                }
            }
            offset -= 1
        }
        return nil
    }

    private static func zip64DirectoryValues(
        _ data: Data,
        eocd: Int
    ) -> (count: Int, size: Int, offset: Int)? {
        let locator = eocd - 20
        guard locator >= 0, u32(data, locator) == 0x0706_4B50 else { return nil }
        let zip64Offset = u64(data, locator + 8)
        guard zip64Offset >= 0, zip64Offset + 56 <= data.count,
              u32(data, zip64Offset) == 0x0606_4B50 else { return nil }
        return (
            count: u64(data, zip64Offset + 32),
            size: u64(data, zip64Offset + 40),
            offset: u64(data, zip64Offset + 48)
        )
    }

    private static func decodeName(_ data: Data, utf8: Bool) -> String {
        if utf8, let name = String(data: data, encoding: .utf8) {
            return name
        }
        if let name = String(data: data, encoding: .utf8) {
            return name
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Deflate

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !input.isEmpty else { throw ZipArchiveError.decompressionFailed }

        var output = [UInt8](repeating: 0, count: expectedSize)
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw ZipArchiveError.decompressionFailed }
        defer { inflateEnd(&stream) }

        let outputCount = output.count
        let status: Int32 = input.withUnsafeBytes { inputBuffer in
            guard let inputPointer = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputPointer)
            stream.avail_in = uInt(input.count)
            return output.withUnsafeMutableBytes { outputBuffer in
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_FINISH)
            }
        }
        let produced = output.count - Int(stream.avail_out)
        guard status == Z_STREAM_END, produced == expectedSize else {
            throw ZipArchiveError.decompressionFailed
        }
        return Data(output)
    }

    // MARK: - Little-endian helpers

    private static func u16(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return Int(data[offset]) |
            Int(data[offset + 1]) << 8 |
            Int(data[offset + 2]) << 16 |
            Int(data[offset + 3]) << 24
    }

    private static func u64(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = value << 8 | UInt64(data[offset + index])
        }
        return Int(truncatingIfNeeded: value)
    }
}
