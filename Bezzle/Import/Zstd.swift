import Foundation

/// Unpacks Zstandard data, which Figma uses for the main part of a .fig file and which the
/// Compression framework cannot read. It follows RFC 8878 and reads every frame an encoder
/// writes, except frames made with a dictionary.
nonisolated enum Zstd {
    enum Failure: Error, LocalizedError {
        case notZstd
        /// What is damaged, or not understood, in words.
        case damaged(LocalizedStringResource)
        case unsupported(LocalizedStringResource)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notZstd: String(localized: "This data is not Zstandard compressed.")
            case .damaged(let what): String(localized: "The compressed data is damaged: \(String(localized: what)).")
            case .unsupported(let what): String(localized: "The compressed data uses something Bezzle cannot read: \(String(localized: what)).")
            case .tooLarge: String(localized: "The compressed data unpacks to more than there is memory for.")
            }
        }
    }

    /// What all the frames in `data` unpack to, one after the other. Skippable frames are skipped.
    static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            var unpacker = try Unpacker(base, raw.count)
            defer { unpacker.release() }
            try unpacker.run()
            return unpacker.take()
        }
    }

    /// The most a block may hold, before and after it is unpacked.
    private static let maxBlock = 1 << 17

    /// One state of an FSE decoding table: the value it stands for, how many extra bits of
    /// the value follow, and how to find the next state.
    private struct Cell {
        var base: UInt32 = 0
        var next: UInt16 = 0
        var bits: UInt8 = 0
        var extra: UInt8 = 0
    }

    /// One entry of a Huffman decoding table, found by the next few bits of a stream.
    private struct Code {
        var symbol: UInt8 = 0
        var bits: UInt8 = 0
    }

    /// What an FSE table decodes to, which sets its limits and what its symbols mean.
    private enum Kind {
        case lengths, offsets, matches, weights

        var maxSymbol: Int {
            switch self {
            case .lengths: 35
            case .offsets: 31
            case .matches: 52
            case .weights: 15
            }
        }

        var maxLog: Int {
            switch self {
            case .lengths, .matches: 9
            case .offsets: 8
            case .weights: 6
            }
        }
    }

    private static let lengthBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536,
    ]
    private static let lengthExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    private static let matchBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539,
    ]
    private static let matchExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    /// The distributions a block uses when it says "predefined", from the RFC.
    private static let defaultLengths = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    private static let defaultMatches = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    private static let defaultOffsets = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]

    /// Reads a bitstream from its end towards its start, the way Huffman codes and sequences
    /// are written. The highest set bit of the last byte only marks where the stream ends.
    private struct Backward {
        let base: UnsafePointer<UInt8>
        /// Where the eight bytes in `box` start.
        var at: Int
        var box = 0
        /// How many bits of `box`, from the top, have been read.
        var used: Int

        init(_ base: UnsafePointer<UInt8>, _ count: Int) throws {
            guard count > 0, base[count - 1] != 0 else { throw Failure.damaged("a bitstream") }
            self.base = base
            let marker = base[count - 1].leadingZeroBitCount + 1
            if count >= 8 {
                at = count - 8
                box = Int(littleEndian: UnsafeRawPointer(base + at).loadUnaligned(as: Int.self))
                used = marker
            } else {
                at = 0
                var i = 0
                while i < count { box |= Int(base[i]) << (8 * i); i += 1 }
                used = (8 - count) * 8 + marker
            }
        }

        /// How many bits are still unread; below zero once more have been read than there are.
        var left: Int { at * 8 + 64 - used }

        /// The next `n` bits, at most 56, without reading them. Past the start of the stream they are zeros.
        mutating func peek(_ n: Int) -> Int {
            if used + n > 64 {
                refill()
                if used + n > 64 {
                    let have = 64 - used
                    return have > 0 ? (box & ((1 &<< have) &- 1)) &<< (n - have) : 0
                }
            }
            return (box &>> (64 - used - n)) & ((1 &<< n) &- 1)
        }

        mutating func read(_ n: Int) -> Int {
            if used + n > 64 {
                refill()
                if used + n > 64 { used += n; return 0 }
            }
            used += n
            return (box &>> (64 - used)) & ((1 &<< n) &- 1)
        }

        mutating func refill() {
            let step = min(used >> 3, at)
            guard step > 0 else { return }
            at -= step
            used -= step * 8
            box = Int(littleEndian: UnsafeRawPointer(base + at).loadUnaligned(as: Int.self))
        }
    }

    /// The state of one call to `decompress`: where it is in the input, what it has unpacked,
    /// and the tables and repeated offsets that the blocks of a frame share.
    private struct Unpacker {
        let src: UnsafePointer<UInt8>
        let end: Int
        var p = 0

        var out: UnsafeMutablePointer<UInt8>
        var count = 0
        var capacity = 64
        var handedOver = false

        let literals = UnsafeMutablePointer<UInt8>.allocate(capacity: maxBlock)
        let codes = UnsafeMutablePointer<Code>.allocate(capacity: 1 << 11)
        var codeBits = 0
        let lengths = UnsafeMutablePointer<Cell>.allocate(capacity: 1 << 9)
        let offsets = UnsafeMutablePointer<Cell>.allocate(capacity: 1 << 8)
        let matches = UnsafeMutablePointer<Cell>.allocate(capacity: 1 << 9)
        let weightCells = UnsafeMutablePointer<Cell>.allocate(capacity: 1 << 6)
        var lengthsLog = -1, offsetsLog = -1, matchesLog = -1
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 64)
        let next = UnsafeMutablePointer<Int>.allocate(capacity: 64)
        let weights = UnsafeMutablePointer<Int>.allocate(capacity: 256)
        var reps = (1, 4, 8)

        init(_ src: UnsafePointer<UInt8>, _ end: Int) throws {
            guard let start = malloc(64) else { throw Failure.tooLarge }
            self.src = src
            self.end = end
            out = start.assumingMemoryBound(to: UInt8.self)
            for t in [lengths, matches] { t.initialize(repeating: Cell(), count: 1 << 9) }
            offsets.initialize(repeating: Cell(), count: 1 << 8)
            weightCells.initialize(repeating: Cell(), count: 1 << 6)
            codes.initialize(repeating: Code(), count: 1 << 11)
        }

        func release() {
            if !handedOver { free(out) }
            literals.deallocate()
            codes.deallocate()
            for t in [lengths, offsets, matches, weightCells] { t.deallocate() }
            for t in [counts, next, weights] { t.deallocate() }
        }

        /// The output, handed over to a `Data` that frees it.
        mutating func take() -> Data {
            guard count > 0 else { return Data() }
            if capacity > count, let kept = realloc(out, count) { out = kept.assumingMemoryBound(to: UInt8.self) }
            handedOver = true
            return Data(bytesNoCopy: out, count: count, deallocator: .free)
        }

        mutating func reserve(_ total: Int, exactly: Bool = false) throws {
            guard total > capacity else { return }
            let size = exactly ? total : max(total, capacity * 2)
            guard let grown = realloc(out, size) else { throw Failure.tooLarge }
            out = grown.assumingMemoryBound(to: UInt8.self)
            capacity = size
        }

        func byte(_ i: Int) -> Int { Int(src[i]) }

        /// A little-endian number of `n` bytes, at most eight, that the caller has checked are there.
        func number(_ i: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(src[i + k]) << (8 * k) }
            return v
        }

        mutating func run() throws {
            var frames = 0
            while p < end {
                let magic = end - p >= 4 ? number(p, 4) : 0
                if magic == 0xFD2F_B528 {
                    p += 4
                    try frame()
                } else if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                    let size = end - p >= 8 ? Int(number(p + 4, 4)) : Int.max
                    guard size <= end - p - 8 else { throw Failure.damaged("a skippable frame") }
                    p += 8 + size
                } else {
                    throw frames == 0 ? Failure.notZstd : Failure.damaged("something after the last frame")
                }
                frames += 1
            }
        }

        /// One frame, from just after its magic number.
        mutating func frame() throws {
            guard p < end else { throw Failure.damaged("a frame header") }
            let flags = byte(p)
            let single = flags & 0x20 != 0
            let idSize = flags & 3 == 3 ? 4 : flags & 3
            let sizeSize = flags >> 6 == 0 ? (single ? 1 : 0) : 1 << (flags >> 6)
            guard flags & 8 == 0 else { throw Failure.damaged("a reserved bit in a frame header") }
            guard end - p > (single ? 0 : 1) + idSize + sizeSize else { throw Failure.damaged("a frame header") }
            // The window size does not matter, since all the output is kept.
            p += single ? 1 : 2
            guard number(p, idSize) == 0 else { throw Failure.unsupported("a dictionary") }
            p += idSize
            var known: Int?
            if sizeSize > 0 {
                guard let size = Int(exactly: number(p, sizeSize) + (sizeSize == 2 ? 256 : 0)) else { throw Failure.tooLarge }
                known = size
                p += sizeSize
            }
            let checksum = flags & 4 != 0

            codeBits = 0
            lengthsLog = -1; offsetsLog = -1; matchesLog = -1
            reps = (1, 4, 8)
            let start = count
            let most = known ?? Int.max
            if let known { try reserve(count + min(known, 1 << 28), exactly: true) }

            var last = false
            while !last {
                guard end - p >= 3 else { throw Failure.damaged("a block header") }
                let header = Int(number(p, 3))
                p += 3
                last = header & 1 != 0
                let size = header >> 3
                let room = min(maxBlock, most - (count - start))
                guard size <= maxBlock else { throw Failure.damaged("a block larger than 128 KB") }
                switch (header >> 1) & 3 {
                case 0:
                    guard size <= end - p, size <= room else { throw Failure.damaged("an uncompressed block") }
                    try reserve(count + size)
                    memcpy(out + count, src + p, size)
                    count += size
                    p += size
                case 1:
                    guard p < end, size <= room else { throw Failure.damaged("a block of one repeated byte") }
                    try reserve(count + size)
                    memset(out + count, Int32(src[p]), size)
                    count += size
                    p += 1
                case 2:
                    guard size <= end - p else { throw Failure.damaged("a compressed block") }
                    try block(p, p + size, start: start, limit: count + room)
                    p += size
                default:
                    throw Failure.damaged("a block of a reserved type")
                }
            }
            if let known, count - start != known { throw Failure.damaged("the frame is not the size it says") }
            if checksum {
                guard end - p >= 4 else { throw Failure.damaged("the checksum is missing") }
                guard UInt32(truncatingIfNeeded: Zstd.xxh64(out + start, count - start)) == UInt32(number(p, 4)) else {
                    throw Failure.damaged("the checksum does not match")
                }
                p += 4
            }
        }

        /// A compressed block in `src[from..<to]`, unpacking to at most `limit` bytes of output in all.
        mutating func block(_ from: Int, _ to: Int, start: Int, limit: Int) throws {
            var q = from
            let (lits, litCount) = try literalsSection(&q, to)
            guard q < to else { throw Failure.damaged("a block without sequences") }
            var n = byte(q)
            q += 1
            if n == 255 {
                guard to - q >= 2 else { throw Failure.damaged("the number of sequences") }
                n = byte(q) + byte(q + 1) << 8 + 0x7F00
                q += 2
            } else if n >= 128 {
                guard q < to else { throw Failure.damaged("the number of sequences") }
                n = (n - 128) << 8 + byte(q)
                q += 1
            }
            try reserve(limit)
            if n == 0 {
                guard q == to, litCount <= limit - count else { throw Failure.damaged("a block without sequences") }
                memcpy(out + count, lits, litCount)
                count += litCount
                return
            }
            guard q < to, byte(q) & 3 == 0 else { throw Failure.damaged("the sequence tables") }
            let modes = byte(q)
            q += 1
            lengthsLog = try table(modes >> 6, .lengths, lengths, lengthsLog, &q, to)
            offsetsLog = try table((modes >> 4) & 3, .offsets, offsets, offsetsLog, &q, to)
            matchesLog = try table((modes >> 2) & 3, .matches, matches, matchesLog, &q, to)
            try sequences(q, to, n, lits, litCount, start: start, limit: limit)
        }

        /// The literals of a compressed block: where they are and how many.
        mutating func literalsSection(_ q: inout Int, _ to: Int) throws -> (UnsafePointer<UInt8>, Int) {
            guard q < to else { throw Failure.damaged("a literals section") }
            let first = byte(q), type = first & 3, format = (first >> 2) & 3
            if type < 2 {
                let header = format & 1 == 0 ? 1 : format == 1 ? 2 : 3
                guard header + type <= to - q else { throw Failure.damaged("a literals section") }
                let size = switch header {
                case 1: first >> 3
                case 2: first >> 4 + byte(q + 1) << 4
                default: first >> 4 + byte(q + 1) << 4 + byte(q + 2) << 12
                }
                q += header
                guard size <= maxBlock else { throw Failure.damaged("more literals than a block holds") }
                if type == 0 {
                    guard size <= to - q else { throw Failure.damaged("the literals") }
                    defer { q += size }
                    return (src + q, size)
                }
                memset(literals, Int32(src[q]), size)
                q += 1
                return (UnsafePointer(literals), size)
            }

            let header = format < 2 ? 3 : format + 2
            guard to - q >= header else { throw Failure.damaged("a literals section") }
            let fields = Int(number(q, header))
            let width = format < 2 ? 10 : format == 2 ? 14 : 18
            let size = (fields >> 4) & ((1 << width) - 1), packed = fields >> (4 + width)
            q += header
            guard size <= maxBlock, packed <= to - q else { throw Failure.damaged("the literals") }
            var s = q
            q += packed
            if type == 2 {
                s = try huffmanTree(s, q)
            } else if codeBits == 0 {
                throw Failure.damaged("literals that reuse a Huffman table there is none of")
            }
            if format == 0 {
                try huffman(s, q - s, literals, size)
            } else {
                guard q - s >= 6 else { throw Failure.damaged("the literals") }
                let a = byte(s) | byte(s + 1) << 8, b = byte(s + 2) | byte(s + 3) << 8, c = byte(s + 4) | byte(s + 5) << 8
                let d = q - s - 6 - a - b - c, quarter = (size + 3) / 4
                guard d > 0, size - 3 * quarter >= 0 else { throw Failure.damaged("the literals") }
                s += 6
                try huffman(s, a, literals, quarter)
                try huffman(s + a, b, literals + quarter, quarter)
                try huffman(s + a + b, c, literals + 2 * quarter, quarter)
                try huffman(s + a + b + c, d, literals + 3 * quarter, size - 3 * quarter)
            }
            return (UnsafePointer(literals), size)
        }

        /// Reads a Huffman tree description from `src[from..<to]` into `codes`, and says where it ends.
        mutating func huffmanTree(_ from: Int, _ to: Int) throws -> Int {
            guard from < to else { throw Failure.damaged("a Huffman table") }
            let header = byte(from)
            var q = from + 1, n: Int
            if header >= 128 {
                n = header - 127
                guard (n + 1) / 2 <= to - q else { throw Failure.damaged("a Huffman table") }
                for i in 0..<n {
                    let pair = byte(q + i / 2)
                    weights[i] = i & 1 == 0 ? pair >> 4 : pair & 15
                }
                q += (n + 1) / 2
            } else {
                guard header > 0, header <= to - q else { throw Failure.damaged("a Huffman table") }
                n = try packedWeights(q, q + header)
                q += header
            }

            // The last weight is left out, as the one that makes the code lengths add up.
            var total = 0
            for i in 0..<n {
                guard weights[i] <= 11 else { throw Failure.damaged("a Huffman table") }
                if weights[i] > 0 { total += 1 << (weights[i] - 1) }
            }
            guard total > 0 else { throw Failure.damaged("a Huffman table") }
            let bits = Int.bitWidth - total.leadingZeroBitCount
            let rest = (1 << bits) - total
            guard bits <= 11, rest & (rest - 1) == 0 else { throw Failure.damaged("a Huffman table") }
            weights[n] = Int.bitWidth - rest.leadingZeroBitCount
            n += 1

            // Codes go out by weight, lightest first, and by symbol within a weight.
            var starts = [Int](repeating: 0, count: 13)
            for i in 0..<n where weights[i] > 0 { starts[weights[i]] += 1 << (weights[i] - 1) }
            var at = 0
            for w in 1...12 { (starts[w], at) = (at, at + starts[w]) }
            for i in 0..<n where weights[i] > 0 {
                let w = weights[i], length = 1 << (w - 1)
                codes.advanced(by: starts[w]).update(repeating: Code(symbol: UInt8(i), bits: UInt8(bits + 1 - w)), count: length)
                starts[w] += length
            }
            codeBits = bits
            return q
        }

        /// Huffman weights compressed with FSE, in `src[from..<to]`, into `weights`. Says how many there are.
        func packedWeights(_ from: Int, _ to: Int) throws -> Int {
            var q = from
            let (log, symbols) = try readCounts(&q, to, .weights)
            try build(weightCells, log, symbols, .weights)
            var r = try Backward(src + q, to - q)
            var one = r.read(log), two = r.read(log)
            var n = 0
            // Two states take turns, until the stream runs out; then the other state has one symbol left.
            while true {
                guard n <= 253 else { throw Failure.damaged("a Huffman table") }
                let a = weightCells[one]
                weights[n] = Int(a.base)
                n += 1
                one = Int(a.next) + r.read(Int(a.bits))
                if r.left < 0 {
                    weights[n] = Int(weightCells[two].base)
                    return n + 1
                }
                let b = weightCells[two]
                weights[n] = Int(b.base)
                n += 1
                two = Int(b.next) + r.read(Int(b.bits))
                if r.left < 0 {
                    weights[n] = Int(weightCells[one].base)
                    return n + 1
                }
            }
        }

        /// Decodes one Huffman stream of `size` bytes at `from` into `n` literals at `dest`.
        func huffman(_ from: Int, _ size: Int, _ dest: UnsafeMutablePointer<UInt8>, _ n: Int) throws {
            var r = try Backward(src + from, size)
            let table = codes, bits = codeBits
            var i = 0
            while i < n {
                let c = table[r.peek(bits)]
                dest[i] = c.symbol
                r.used += Int(c.bits)
                i += 1
            }
            guard r.left == 0 else { throw Failure.damaged("the literals") }
        }

        /// Sets up one of the sequence tables as the block's modes say, and gives its new accuracy.
        func table(_ mode: Int, _ kind: Kind, _ cells: UnsafeMutablePointer<Cell>, _ log: Int, _ q: inout Int, _ to: Int) throws -> Int {
            switch mode {
            case 0:
                let defaults = kind == .lengths ? defaultLengths : kind == .offsets ? defaultOffsets : defaultMatches
                for (s, c) in defaults.enumerated() { counts[s] = c }
                let log = kind == .offsets ? 5 : 6
                try build(cells, log, defaults.count, kind)
                return log
            case 1:
                guard q < to, byte(q) <= kind.maxSymbol else { throw Failure.damaged("a sequence table") }
                build(one: byte(q), cells, kind)
                q += 1
                return 0
            case 2:
                let (log, symbols) = try readCounts(&q, to, kind)
                try build(cells, log, symbols, kind)
                return log
            default:
                guard log >= 0 else { throw Failure.damaged("a sequence table that reuses one there is none of") }
                return log
            }
        }

        /// Reads an FSE table description at `q` into `counts`: its accuracy, and how many symbols it covers.
        func readCounts(_ q: inout Int, _ to: Int, _ kind: Kind) throws -> (Int, Int) {
            guard q < to else { throw Failure.damaged("an FSE table") }
            let log = byte(q) & 15 + 5
            guard log <= kind.maxLog else { throw Failure.damaged("an FSE table that is too large") }
            var bit = 4, remaining = (1 << log) + 1, threshold = 1 << log, width = log + 1, symbol = 0
            while remaining > 1 {
                guard symbol <= kind.maxSymbol else { throw Failure.damaged("an FSE table") }
                let most = 2 * threshold - 1 - remaining
                let v = bits(q, to, bit, width)
                var c: Int
                if v & (threshold - 1) < most {
                    c = v & (threshold - 1)
                    bit += width - 1
                } else {
                    c = v
                    if c >= threshold { c -= most }
                    bit += width
                }
                c -= 1
                remaining -= c < 0 ? 1 : c
                counts[symbol] = c
                symbol += 1
                if c == 0 {
                    // Two-bit flags say how many more symbols have no count; three means read another flag.
                    var flag = 3
                    while flag == 3 {
                        flag = bits(q, to, bit, 2)
                        bit += 2
                        for _ in 0..<flag {
                            guard symbol <= kind.maxSymbol else { throw Failure.damaged("an FSE table") }
                            counts[symbol] = 0
                            symbol += 1
                        }
                    }
                }
                if remaining <= 1 { break }
                while remaining < threshold { width -= 1; threshold >>= 1 }
            }
            guard remaining == 1, (bit + 7) / 8 <= to - q else { throw Failure.damaged("an FSE table") }
            q += (bit + 7) / 8
            return (log, symbol)
        }

        /// `n` bits, at most 24, that start `bit` bits into `src[q..<to]`; zeros past its end.
        func bits(_ q: Int, _ to: Int, _ bit: Int, _ n: Int) -> Int {
            var v = 0
            let first = q + bit >> 3
            for k in 0..<4 where first + k < to { v |= byte(first + k) << (8 * k) }
            return (v >> (bit & 7)) & ((1 << n) - 1)
        }

        /// Spreads the symbols counted in `counts` over a decoding table of `1 << log` states.
        func build(_ cells: UnsafeMutablePointer<Cell>, _ log: Int, _ symbols: Int, _ kind: Kind) throws {
            let size = 1 << log, mask = size - 1, step = (size >> 1) + (size >> 3) + 3
            var high = size - 1
            for s in 0..<symbols {
                if counts[s] == -1 {
                    cells[high].base = UInt32(s)
                    high -= 1
                    next[s] = 1
                } else {
                    next[s] = counts[s]
                }
            }
            var at = 0
            for s in 0..<symbols where counts[s] > 0 {
                for _ in 0..<counts[s] {
                    cells[at].base = UInt32(s)
                    repeat { at = (at + step) & mask } while at > high
                }
            }
            guard at == 0 else { throw Failure.damaged("an FSE table") }
            for u in 0..<size {
                let s = Int(cells[u].base), x = next[s]
                next[s] = x + 1
                let bits = log - (Int.bitWidth - 1 - x.leadingZeroBitCount)
                cells[u].bits = UInt8(bits)
                cells[u].next = UInt16((x << bits) - size)
                (cells[u].base, cells[u].extra) = meaning(s, kind)
            }
        }

        /// A table of one state, for a block whose sequences all share one symbol.
        func build(one symbol: Int, _ cells: UnsafeMutablePointer<Cell>, _ kind: Kind) {
            let (base, extra) = meaning(symbol, kind)
            cells[0] = Cell(base: base, next: 0, bits: 0, extra: extra)
        }

        /// The baseline value of a symbol, and how many extra bits are added to it.
        func meaning(_ s: Int, _ kind: Kind) -> (UInt32, UInt8) {
            switch kind {
            case .lengths: (lengthBase[s], lengthExtra[s])
            case .matches: (matchBase[s], matchExtra[s])
            case .offsets: (1 << UInt32(s), UInt8(s))
            case .weights: (UInt32(s), 0)
            }
        }

        /// Decodes and carries out the block's `n` sequences, each some literals and then a match.
        mutating func sequences(_ from: Int, _ to: Int, _ n: Int, _ lits: UnsafePointer<UInt8>, _ litCount: Int, start: Int, limit: Int) throws {
            var r = try Backward(src + from, to - from)
            let lt = lengths, ot = offsets, mt = matches, o = out
            var ls = r.read(lengthsLog), os = r.read(offsetsLog), ms = r.read(matchesLog)
            var (r1, r2, r3) = reps
            var pos = count, used = 0, i = 0
            while i < n {
                let lc = lt[ls], oc = ot[os], mc = mt[ms]
                var offset = Int(oc.base) + r.read(Int(oc.extra))
                let match = Int(mc.base) + r.read(Int(mc.extra))
                let length = Int(lc.base) + r.read(Int(lc.extra))
                if offset > 3 {
                    (r1, r2, r3) = (offset - 3, r1, r2)
                    offset = r1
                } else {
                    // Values 1 to 3 repeat a recent offset, shifted by one when there are no literals.
                    switch length == 0 ? offset + 1 : offset {
                    case 1: offset = r1
                    case 2: (offset, r1, r2) = (r2, r2, r1)
                    case 3: (offset, r1, r2, r3) = (r3, r3, r1, r2)
                    default: (offset, r1, r2, r3) = (r1 - 1, r1 - 1, r1, r2)
                    }
                }
                i += 1
                if i < n {
                    ls = Int(lc.next) + r.read(Int(lc.bits))
                    ms = Int(mc.next) + r.read(Int(mc.bits))
                    os = Int(oc.next) + r.read(Int(oc.bits))
                }

                guard length <= litCount - used, length + match <= limit - pos else { throw Failure.damaged("a sequence") }
                memcpy(o + pos, lits + used, length)
                pos += length
                used += length
                guard offset > 0, offset <= pos - start else { throw Failure.damaged("a match before the start of the data") }
                let m = o + pos
                if offset >= match {
                    memcpy(m, m - offset, match)
                } else if offset == 1 {
                    memset(m, Int32(m[-1]), match)
                } else {
                    // The match overlaps itself, so it is copied in runs that double in length.
                    var done = 0
                    while done < match {
                        let run = min(match - done, done + offset)
                        memcpy(m + done, m - offset, run)
                        done += run
                    }
                }
                pos += match
            }
            guard r.left == 0 else { throw Failure.damaged("the sequences") }
            let rest = litCount - used
            guard rest <= limit - pos else { throw Failure.damaged("a block larger than 128 KB") }
            memcpy(o + pos, lits + used, rest)
            count = pos + rest
            reps = (r1, r2, r3)
        }
    }

    /// The XXH64 hash, seed 0, whose low 32 bits a frame may carry as its checksum.
    static func xxh64(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        let p1: UInt64 = 0x9E37_79B1_85EB_CA87, p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F, p3: UInt64 = 0x1656_67B1_9E37_79F9
        let p4: UInt64 = 0x85EB_CA77_C2B2_AE63, p5: UInt64 = 0x27D4_EB2F_1656_67C5
        func rotate(_ x: UInt64, _ r: UInt64) -> UInt64 { x &<< r | x &>> (64 - r) }
        func round(_ acc: UInt64, _ v: UInt64) -> UInt64 { rotate(acc &+ v &* p2, 31) &* p1 }
        func word(_ i: Int) -> UInt64 { UInt64(littleEndian: UnsafeRawPointer(p + i).loadUnaligned(as: UInt64.self)) }
        var i = 0, h: UInt64
        if n >= 32 {
            var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
            while n - i >= 32 {
                v1 = round(v1, word(i))
                v2 = round(v2, word(i + 8))
                v3 = round(v3, word(i + 16))
                v4 = round(v4, word(i + 24))
                i += 32
            }
            h = rotate(v1, 1) &+ rotate(v2, 7) &+ rotate(v3, 12) &+ rotate(v4, 18)
            for v in [v1, v2, v3, v4] { h = (h ^ round(0, v)) &* p1 &+ p4 }
        } else {
            h = p5
        }
        h &+= UInt64(n)
        while n - i >= 8 {
            h = rotate(h ^ round(0, word(i)), 27) &* p1 &+ p4
            i += 8
        }
        if n - i >= 4 {
            let w = UInt64(UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self).littleEndian)
            h = rotate(h ^ w &* p1, 23) &* p2 &+ p3
            i += 4
        }
        while i < n {
            h = rotate(h ^ UInt64(p[i]) &* p5, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }
}
