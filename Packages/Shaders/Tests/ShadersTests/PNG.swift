import Foundation

/// PNG files of pixels as they are, for the pictures one platform draws and another compares
/// with: RGBA, 8 bits, the bytes kept as drawn (premultiplied, so a viewer shows half-transparent
/// pixels a little dark), deflated without compression so both platforms read them with this alone.
enum PNG {
    static func data(_ pixels: Pixels) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((pixels.width * 4 + 1) * pixels.height)
        for y in 0..<pixels.height {
            raw.append(0) // no filter
            raw += pixels.bytes[(y * pixels.width * 4)..<((y + 1) * pixels.width * 4)]
        }
        var zlib: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let count = min(65535, raw.count - at)
            let last = at + count == raw.count
            zlib += [last ? 1 : 0, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            zlib += raw[at..<(at + count)]
            at += count
        } while at < raw.count
        zlib += bigEndian(adler32(raw))
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", bigEndian(UInt32(pixels.width)) + bigEndian(UInt32(pixels.height)) + [8, 6, 0, 0, 0])
        file += chunk("IDAT", zlib)
        file += chunk("IEND", [])
        return Data(file)
    }

    /// A file `data(_:)` wrote; nil for any other.
    static func pixels(_ data: Data) -> Pixels? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var at = 8, width = 0, height = 0
        var zlib: [UInt8] = []
        while at + 8 <= bytes.count {
            let length = Int(number(bytes, at))
            let kind = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
            guard at + 12 + length <= bytes.count else { return nil }
            let body = bytes[(at + 8)..<(at + 8 + length)]
            if kind == "IHDR" {
                width = Int(number(bytes, at + 8))
                height = Int(number(bytes, at + 12))
                guard Array(body.dropFirst(8).prefix(5)) == [8, 6, 0, 0, 0] else { return nil }
            } else if kind == "IDAT" {
                zlib += body
            }
            at += 12 + length
        }
        guard width > 0, height > 0, zlib.count > 2 else { return nil }
        var raw: [UInt8] = []
        var i = 2
        while i + 5 <= zlib.count {
            let last = zlib[i] & 1 == 1
            guard zlib[i] & 6 == 0 else { return nil } // compressed: not one of these
            let count = Int(zlib[i + 1]) | Int(zlib[i + 2]) << 8
            guard i + 5 + count <= zlib.count else { return nil }
            raw += zlib[(i + 5)..<(i + 5 + count)]
            i += 5 + count
            if last { break }
        }
        guard raw.count == (width * 4 + 1) * height else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)
        for y in 0..<height {
            let row = y * (width * 4 + 1)
            guard raw[row] == 0 else { return nil }
            out += raw[(row + 1)..<(row + 1 + width * 4)]
        }
        return Pixels(width: width, height: height, bytes: out)
    }

    private static func chunk(_ kind: String, _ body: [UInt8]) -> [UInt8] {
        let named = Array(kind.utf8) + body
        return bigEndian(UInt32(body.count)) + named + bigEndian(crc32(named))
    }

    private static func number(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for byte in bytes[chunk..<min(bytes.count, chunk + 5552)] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }
}
