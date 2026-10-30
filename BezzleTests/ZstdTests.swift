import Testing
import Foundation
@testable import Bezzle

/// Inputs the tests rebuild instead of embedding: the same bytes on every run, from a seeded generator.
enum ZstdSamples {
    /// SplitMix64, written out so that no change to the standard library can change the samples.
    struct Seeded {
        var state: UInt64

        mutating func below(_ n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ z >> 31) % UInt64(n))
        }
    }

    static let words = ["frame", "layer", "board", "grid", "pixel", "vector", "shadow", "blur",
                        "corner", "stroke", "fill", "text", "the", "a", "of", "and"]

    /// `count` words in an order the generator picks, with a full stop and a new line now and then.
    static func text(_ count: Int, seed: UInt64) -> [UInt8] {
        var g = Seeded(state: seed), out: [UInt8] = []
        for _ in 0..<count {
            out += words[g.below(words.count)].utf8
            out += g.below(12) == 0 ? [46, 10] : [32]
        }
        return out
    }

    /// Over 128 KB, so it takes several blocks: pieces of a short text copied over and over, with a byte
    /// between pieces that cannot be matched. First the bytes between are digits, so blocks can reuse the
    /// last block's Huffman table; then they are all one byte, so a block's literals can be stored as one.
    static func blocks() -> [UInt8] {
        let base = text(400, seed: 99)
        var g = Seeded(state: 7), out = base
        for (between, total) in [(Array("0123456789".utf8), 300_000), (Array("Q".utf8), 450_000)] {
            while out.count < total {
                out.append(between[g.below(between.count)])
                let n = 500 + g.below(1000), at = g.below(base.count - n)
                out += base[at..<(at + n)]
            }
        }
        return out
    }

    /// A text and then the same text with a byte left out every so often. An encoder can write each
    /// piece after a gap as a match without literals at one less than the last offset.
    static func trimmed() -> [UInt8] {
        let base = text(300, seed: 5)
        var g = Seeded(state: 11), out = base, i = 0
        while i < base.count {
            let n = min(20 + g.below(60), base.count - i)
            out += base[i..<(i + n)]
            i += n + 1
        }
        return out
    }

    /// Low bytes, small ones more often than large: few enough symbols that an encoder writes the
    /// Huffman weights directly rather than compressing them.
    static func lowBytes() -> [UInt8] {
        var g = Seeded(state: 3)
        return (0..<600).map { _ in UInt8(min(g.below(8), g.below(8))) }
    }
}

/// Compressed by the zstd command-line tool, version 1.5.7, from inputs the tests rebuild. Between
/// them they hold every kind of block, literals section, Huffman table, sequence table and repeated offset.
enum ZstdVectors {
    /// `zstd` of an empty file.
    static let empty = "KLUv/SQAAQAAmenYUQ=="
    /// "Hello, Bezzle!", which zstd keeps as an uncompressed block.
    static let hello = "KLUv/SQOcQAASGVsbG8sIEJlenpsZSEyvS8o"
    /// `sentence` at `-19`: one block, literals in a single Huffman stream.
    static let sentence = """
        KLUv/SSahQMAcggYFaCrAyQJ2QKatrsmdmctVT/0b/R/1YENdkfR9rgp7FqIcoJvWR+tzIfT5Qldy97sWJxZRAEH0x3ZYyvc9Kqw
        yw+yFLobV0jIjV4ZNtMPiSZ2zRu6VSCt3FXTuad6RZGHBAA6xVDqQlBGLd+qKNuYwcY=
        """
    /// 300,000 zero bytes: blocks of one repeated byte.
    static let zeros = "KLUv/aTgkwQAVAAAEAAAAQD7/znAAgIAEAADnwQALSjeJg=="
    /// "abc" 4,000 times and then "xyz" 4,000 times: long matches that overlap themselves.
    static let abc = "KLUv/WTAXI0AADBhYmN4eXoCANoO8EPbybshElpRkw=="
    /// Runs of 300 bytes, A to D in turn: sequence tables of a single symbol.
    static let runs = """
        KLUv/aTA1AEAjRAAFtkcBeAPaUAIGgAaABoAGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbGwRsbGxsbGxsbGxsbGxsbGxsbGxsbGxs
        bGxsBLGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbEFGxsbGxsbGxsbGxsbGxsbGxsbGxsbGxsbG4GQlBHgHwAsKCgoKCgoKCgoKCgo
        KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQoKCg
        oKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgQEFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB
        QUFBQUFBgYKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCAgUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUF
        BQUFBQUFBQUFBQUFBQUFBQoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKChQUFBQUFBQUFBQUFBQUFBQU
        FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKFBQUFBQUFBQ
        UFBQUFBQUFBQUFBQUKiTKkxsCRw=
        """
    /// `ZstdSamples.lowBytes()` at `-1`: Huffman weights written directly, four bits each.
    static let low = """
        KLUv/WRYAZUHAJbhMoZEMzIQMAAxADAAyZPAKOuAkiBAEfrovkD2as57EtsDcgKNO9YMZ0rL3vydCAgQEa/CBZxt3O0Y0SL4eQGW
        C40UzB5d9DfVnAORUimOCjMGIJIyqPkWHMluEs02kSJaAko0Q3sAxAIuhthJTCuRzItxcYqHAukfAUEA+gzM86mpCiOY2nNJbDcE
        P20GwPgRMgEgPtqC8i6TBA3n8Ip4wpIv255wf6hyRSJxVAD4xjBzOiOGWsQpTfxJZKBbEVNeosZ6R2R7AZSQWhcUDAAqGV+ctrPW
        mLn4cKyxZOvawSKzR9sOD7IkjtCDLw19rsAOUbpAkw==
        """
    /// `ZstdSamples.text(1500, seed: 1)` at `-1`.
    static let text1 = """
        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
        """
    /// The same text at `-3 --no-check`.
    static let text3 = """
        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
        TG7B70KYaKH5WWQcPkSJxcB7sH219kAzUHyt
        """
    /// The same text at `-19 --check`.
    static let text19 = """
        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
        """
    /// `ZstdSamples.blocks()` at `--ultra -22 --no-content-size`.
    static let blocks = """
        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
        """
    /// `ZstdSamples.trimmed()` at `-19`.
    static let trimmed = """
        KLUv/WRtC70PABKIFhSgqQ3t/25uIV/31CLtVFXPZ782YViWyi5fls9fHk8+X3a2rOzK8OQRMsRRlk9X5rsyvQPGs84L6bxcuINY
        IHQwGqdpLK6LLIOrmPSBFZtD1m+AijVBgBEiMoDlqGHrQnb2DiCMzJgZNyIQXFDDIgQlTCATJ4GIBCKhBCIyUu2kGAF2PB231o5x
        5uKNmzOCVHfa7rWQ5OHiNt1pTcgl9MYqsn/eO5wdT9dzNmdX034quyclE82nUFdiJjGg7/NpMWrSJrrrXtosltlKC39wWubFvBNw
        oMMcSK0ejisyteDyETuo+mpWSEheElFMZHZbKI2DLAa5tOOF+eIpsGv4iXsuwu7EmHsfoS+keJeQiOTdw6YmPCdimgPwKxcXHNz+
        NUXcd7JLV3BA8KZ+sQ/pIsQ28YETTPy2ZRHP+B2lERWOpHI4PJRuTftJ8ypi41VbuYzB4XgOSTmMgoyAl+7PiWkdkJMec2UkFATM
        hSOwiYC69P3+EfcHrDbQ71XpstC2IIwJTUa2Gdy1q9VdHxAcia+dwVVkTMWGUXCkTiP5LuRYga9RR2GKVPHU48cNSmK/XzwAtAHS
        HcDtU7cWXsV5vjGXO+sDiPDNClEhGEQ4F6x9RhbNuUxx1AYyXxtlIdtqlVRJBPIaWYPoYSUzCyWlqhgV914VfXqjlw==
        """
    /// The same, piped through `zstd -19`, which then leaves out the content size.
    static let piped = """
        KLUv/QRovQ8AEogWFKCpDe3/bm4hX/fUIu1UVc9nvzZhWJbKLl+Wz18eTz5fdras7Mrw5BEyxFGWT1fmuzK9A8azzgvpvFy4g1gg
        dDAap2ksrossg6uY9IEVm0PWb4CKNUGAESIygOWoYetCdvYOIIzMmBk3IhBcUMMiBCVMIBMngYgEIqEEIjJS7aQYAXY8HbfWjnHm
        4o2bM4JUd9rutZDk4eI23WlNyCX0xiqyf947nB1P13M2Z1fTfiq7JyUTzadQV2ImMaDv82kxatImuute2iyW2UoLf3Ba5sW8E3Cg
        wxxIrR6OKzK14PIRO6j6alZISF4SUUxkdlsojYMsBrm044X54imwa/iJey7C7sSYex+hL6R4l5CI5N3DpiY8J2KaA/ArFxcc3P41
        Rdx3sktXcEDwpn6xD+kixDbxgRNM/LZlEc/4HaURFY6kcjg8lG5N+0nzKmLjVVu5jMHheA5JOYyCjICX7s+JaR2Qkx5zZSQUBMyF
        I7CJgLr0/f4R9wesNtDvVemy0LYgjAlNRrYZ3LWr1V0fEByJr53BVWRMxYZRcKROI/ku5FiBr1FHYYpU8dTjxw1KYr9fPAC0AdId
        wO1TtxZexXm+MZc76wOI8M0KUSEYRDgXrH1GFs25THHUBjJfG2Uh22qVVEkE8hpZg+hhJTMLJaWqGBX3XhV9eqOX
        """
}

struct ZstdTests {
    let sentence = Data("""
        Bezzle draws frames, layers and boards on a grid; every pixel of a vector shadow, blur and corner \
        stays sharp when the stroke and fill of the text change.
        """.utf8)

    func packed(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
    }

    func unpack(_ base64: String) throws -> Data {
        try Zstd.decompress(packed(base64))
    }

    @Test func unpacksNothing() throws {
        #expect(try Zstd.decompress(Data()).isEmpty)
        #expect(try unpack(ZstdVectors.empty).isEmpty)
    }

    @Test func unpacksShortStrings() throws {
        #expect(try unpack(ZstdVectors.hello) == Data("Hello, Bezzle!".utf8))
        #expect(try unpack(ZstdVectors.sentence) == sentence)
    }

    @Test func unpacksRepetitiveData() throws {
        #expect(try unpack(ZstdVectors.zeros) == Data(count: 300_000))
        let abc = String(repeating: "abc", count: 4000) + String(repeating: "xyz", count: 4000)
        #expect(try unpack(ZstdVectors.abc) == Data(abc.utf8))
        let runs = (0..<400).flatMap { [UInt8](repeating: 65 + UInt8($0 % 4), count: 300) }
        #expect(try unpack(ZstdVectors.runs) == Data(runs))
    }

    @Test func unpacksTextAtSeveralLevels() throws {
        let text = Data(ZstdSamples.text(1500, seed: 1))
        #expect(try unpack(ZstdVectors.text1) == text)
        #expect(try unpack(ZstdVectors.text3) == text)
        #expect(try unpack(ZstdVectors.text19) == text)
        #expect(try unpack(ZstdVectors.low) == Data(ZstdSamples.lowBytes()))
    }

    @Test func unpacksManyBlocksWithoutContentSize() throws {
        let blocks = Data(ZstdSamples.blocks())
        #expect(blocks.count > 3 * 128 * 1024)
        #expect(try unpack(ZstdVectors.blocks) == blocks)
    }

    @Test func unpacksRepeatedOffsets() throws {
        let trimmed = Data(ZstdSamples.trimmed())
        #expect(try unpack(ZstdVectors.trimmed) == trimmed)
        #expect(try unpack(ZstdVectors.piped) == trimmed)
    }

    @Test func unpacksFramesOneAfterAnother() throws {
        let skippable = Data([0x53, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 0xAB, 0xCD, 0xEF])
        let frames = packed(ZstdVectors.hello) + skippable + packed(ZstdVectors.text1) + packed(ZstdVectors.empty) + skippable
        #expect(try Zstd.decompress(frames) == Data("Hello, Bezzle!".utf8) + Data(ZstdSamples.text(1500, seed: 1)))
        #expect(try Zstd.decompress(skippable).isEmpty)
    }

    /// Frames made by hand, for headers the command-line tool does not write; zstd reads them the same.
    @Test func readsHandMadeFrames() throws {
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        // An eight-byte content size, and an uncompressed block.
        let wide = Data(magic + [0xE0, 5, 0, 0, 0, 0, 0, 0, 0, 0x29, 0, 0] + Array("hello".utf8))
        #expect(try Zstd.decompress(wide) == Data("hello".utf8))
        // A window descriptor, a two-byte content size that counts from 256, and a block of one repeated byte.
        let repeated = Data(magic + [0x40, 0, 0x2C, 0, 0x63, 0x09, 0, 0x7A])
        #expect(try Zstd.decompress(repeated) == Data(repeating: 0x7A, count: 300))
        // A compressed block whose literals are one repeated byte, with no sequences.
        let literals = Data(magic + [0x20, 20, 0x1D, 0, 0, 0xA1, 0x79, 0])
        #expect(try Zstd.decompress(literals) == Data(repeating: 0x79, count: 20))
    }

    @Test func refusesDictionaries() {
        let frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x21, 7, 5, 0x29, 0, 0] + Array("hello".utf8))
        let error = #expect(throws: Zstd.Failure.self) { try Zstd.decompress(frame) }
        #expect(error?.localizedDescription == "The compressed data uses something Bezzle cannot read: a dictionary.")
    }

    @Test func throwsOnDamage() {
        var damaged = packed(ZstdVectors.text19)
        damaged[800] ^= 0x10
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(damaged) }
        #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Data("This is not compressed.".utf8)) }
        let whole = packed(ZstdVectors.trimmed)
        let unthrown = (1..<whole.count).filter { (try? Zstd.decompress(whole.prefix($0))) != nil }
        #expect(unthrown.isEmpty)
    }

    /// The frame has a checksum, so any changed bit either fails to decode or leaves the output as it was.
    @Test func everyFlippedBitIsCaught() {
        let whole = packed(ZstdVectors.trimmed), expected = Data(ZstdSamples.trimmed())
        var wrong: [Int] = []
        for i in whole.indices {
            for bit in 0..<8 {
                var changed = whole
                changed[i] ^= 1 << bit
                if let out = try? Zstd.decompress(changed), out != expected { wrong.append(i * 8 + bit) }
            }
        }
        #expect(wrong.isEmpty)
    }

    /// The vectors with checksums test longer inputs; this is the one whole 64-bit hash that is well known.
    @Test func hashesNothingLikeXXH64() {
        let hash = [UInt8(0)].withUnsafeBufferPointer { $0.baseAddress.map { Zstd.xxh64($0, 0) } }
        #expect(hash == 0xEF46_DB37_51D8_E999)
    }
}
