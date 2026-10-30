import Foundation
import Compression

/// Reads files out of a ZIP archive, such as an Adobe XD file, without unpacking it to disk.
/// Stored and deflated entries are understood, and the 64-bit sizes of large archives.
struct ZipArchive {
    enum Failure: Error, LocalizedError {
        case notAnArchive
        case damaged(String)
        case unsupported(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: "This file is not a ZIP archive."
            case .damaged(let what): "The archive is damaged: \(what)."
            case .unsupported(let what): "The archive uses something Bezzle cannot read: \(what)."
            case .missing(let name): "The archive has no \(name)."
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let data: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        // The end record is in the last 22 bytes, or further back if the archive has a comment.
        let end = data.count
        guard end >= 22 else { throw Failure.notAnArchive }
        var eocd: Int?
        var i = end - 22
        let earliest = max(0, end - 22 - 65_535)
        while i >= earliest {
            if data.u32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw Failure.notAnArchive }
        var count = Int(data.u16(at: eocd + 10))
        var directory = Int(data.u32(at: eocd + 16))
        if count == 0xFFFF || directory == 0xFFFF_FFFF {
            // A ZIP64 end record, found through the locator just before the usual one.
            guard eocd >= 20, data.u32(at: eocd - 20) == 0x0706_4B50 else { throw Failure.unsupported("a 64-bit archive without its locator") }
            let record = Int(data.u64(at: eocd - 12))
            guard record + 56 <= end, data.u32(at: record) == 0x0606_4B50 else { throw Failure.damaged("the 64-bit end record") }
            count = Int(data.u64(at: record + 32))
            directory = Int(data.u64(at: record + 48))
        }

        var entries: [String: Entry] = [:]
        var p = directory
        for _ in 0..<count {
            guard p + 46 <= end, data.u32(at: p) == 0x0201_4B50 else { throw Failure.damaged("the list of files") }
            let method = data.u16(at: p + 10)
            var compressed = Int(data.u32(at: p + 20)), size = Int(data.u32(at: p + 24))
            let nameLength = Int(data.u16(at: p + 28)), extraLength = Int(data.u16(at: p + 30)), commentLength = Int(data.u16(at: p + 32))
            var offset = Int(data.u32(at: p + 42))
            guard p + 46 + nameLength + extraLength <= end else { throw Failure.damaged("a file name") }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            // Sizes too large for 32 bits are in the ZIP64 extra field, in this order.
            var extra = p + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.u16(at: extra), length = Int(data.u16(at: extra + 2))
                if id == 0x0001 {
                    var q = extra + 4
                    if size == 0xFFFF_FFFF { size = Int(data.u64(at: q)); q += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = Int(data.u64(at: q)); q += 8 }
                    if offset == 0xFFFF_FFFF { offset = Int(data.u64(at: q)) }
                }
                extra += 4 + length
            }
            entries[name] = Entry(name: name, method: method, compressedSize: compressed, size: size, headerOffset: offset)
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    var names: [String] { Array(entries.keys) }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// The contents of one file in the archive.
    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw Failure.missing(name) }
        let h = entry.headerOffset
        guard h + 30 <= data.count, data.u32(at: h) == 0x0403_4B50 else { throw Failure.damaged(name) }
        let start = h + 30 + Int(data.u16(at: h + 26)) + Int(data.u16(at: h + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged(name) }
        let packed = data[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(packed)
        case 8:
            return try Self.inflate(packed, size: entry.size, name: name)
        default:
            throw Failure.unsupported("compression method \(entry.method) for \(name)")
        }
    }

    /// Raw deflate, which is what the Compression framework's zlib means.
    private static func inflate(_ packed: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) -> Int in
            packed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dest.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.damaged(name) }
        return out
    }
}

private extension Data {
    func u16(at i: Int) -> UInt16 {
        let b = index(startIndex, offsetBy: i)
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func u32(at i: Int) -> UInt32 {
        let b = index(startIndex, offsetBy: i)
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    func u64(at i: Int) -> UInt64 {
        UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32
    }
}
