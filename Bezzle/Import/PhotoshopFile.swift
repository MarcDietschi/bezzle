import Foundation
import Accelerate
import Compression
import CoreGraphics

/// A Photoshop document, .psd or the large kind, .psb, read as its file lays it out: Adobe's
/// "Photoshop File Formats Specification", and what that leaves out as Photoshop writes it. Only
/// what Bezzle uses is read; the rest is stepped over by its length. Pixels are read only when
/// they are asked for, since a mockup's photos are large.
nonisolated struct PhotoshopFile {
    enum Failure: Error, LocalizedError {
        case notPhotoshop
        case damaged
        case colorMode
        case compression

        var errorDescription: String? {
            switch self {
            case .notPhotoshop: String(localized: "This is not a Photoshop file Bezzle can read.")
            case .damaged: String(localized: "This Photoshop file is damaged.")
            case .colorMode: String(localized: "Bezzle cannot read Photoshop files in this colour mode yet.")
            case .compression: String(localized: "This Photoshop file is packed in a way Bezzle cannot read yet.")
            }
        }
    }

    enum Mode: Int {
        case bitmap = 0, gray = 1, indexed = 2, rgb = 3, cmyk = 4, multichannel = 7, duotone = 8, lab = 9
    }

    /// A layer as the file keeps it. Groups are two of these: where one ends, below what it holds,
    /// and where it begins, above it, which carries its name and how it looks.
    struct Layer {
        var top = 0, left = 0, bottom = 0, right = 0
        /// Its channels: 0, 1, 2 (and 3) the colours, -1 how solid it is, -2 its mask, -3 its mask
        /// when it has a vector mask too; and where each lies in the file, its compression first.
        var channels: [(id: Int, range: Range<Int>)] = []
        /// How it mixes with what is under it, as Photoshop's four letters: "norm", "mul ", "pass".
        var blend = "norm"
        var opacity: UInt8 = 255
        /// Shown only where the layer under it is.
        var clipping = false
        var flags: UInt8 = 0
        var mask: Mask?
        var realMask: Mask?
        var name = ""
        /// What else it keeps, each by its four letters, as where it lies in the file.
        var blocks: [String: Range<Int>] = [:]

        var visible: Bool { flags & 2 == 0 }
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
        var rect: CGRect { CGRect(x: left, y: top, width: width, height: height) }
        func channel(_ id: Int) -> Range<Int>? { channels.first { $0.id == id }?.range }

        /// Where a group begins (1, 2), ends (3), or 0 for any other layer.
        var section: Int = 0
        /// A group's own way of mixing, when it has one other than passing through.
        var sectionBlend: String?
    }

    struct Mask {
        var top = 0, left = 0, bottom = 0, right = 0
        /// What lies outside its rectangle: 0, hidden, or 255, shown.
        var color: UInt8 = 0
        var flags: UInt8 = 0

        var disabled: Bool { flags & 2 != 0 }
        /// Made by Photoshop from the vector mask, which is drawn from its outline instead.
        var fromVector: Bool { flags & 8 != 0 }
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
    }

    /// A file kept inside the document, as a smart object's content is.
    struct Linked {
        var id: String
        var name: String
        /// Its kind, as Photoshop's four letters: "8BPB", "png ", "PDF ".
        var type: String
        var range: Range<Int>
    }

    let data: Data
    private(set) var large = false
    private(set) var width = 0
    private(set) var height = 0
    private(set) var channelCount = 0
    private(set) var depth = 8
    private(set) var mode = Mode.rgb
    private(set) var palette: Data?
    /// The colour profile the colours are in.
    private(set) var profile: Data?
    /// Where the light falls from in effects that share it, in degrees.
    private(set) var globalAngle: Double = 120
    /// Whether the file keeps a picture of all of it, as "Maximise compatibility" makes it.
    private(set) var hasComposite = true
    /// Bottom first, as the file keeps them.
    private(set) var layers: [Layer] = []
    private(set) var linked: [String: Linked] = [:]
    private(set) var globalBlocks: [String: Range<Int>] = [:]
    /// The count of layers was negative: the composite's first extra channel is how solid it is.
    private var transparentComposite = false
    private var compositeStart = 0

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data input: Data) throws {
        data = input.startIndex == 0 ? input : Data(input)
        var c = PSDCursor(data)
        guard data.count >= 26, try c.key() == "8BPS" else { throw Failure.notPhotoshop }
        let version = try c.u16()
        guard version == 1 || version == 2 else { throw Failure.notPhotoshop }
        large = version == 2
        try c.skip(6)
        channelCount = Int(try c.u16())
        height = Int(try c.u32())
        width = Int(try c.u32())
        depth = Int(try c.u16())
        guard let m = Mode(rawValue: Int(try c.u16())) else { throw Failure.colorMode }
        mode = m
        guard [1, 8, 16, 32].contains(depth), width > 0, height > 0 else { throw Failure.damaged }

        let colorLength = Int(try c.u32())
        if colorLength > 0 { palette = try c.bytes(colorLength) }

        let resourceLength = Int(try c.u32())
        let resourceEnd = c.at + resourceLength
        while c.at + 12 <= resourceEnd {
            guard try c.key() == "8BIM" else { break }
            let id = try c.u16()
            _ = try c.pascal(pad: 2)
            let size = Int(try c.u32())
            let start = c.at
            guard start + size <= resourceEnd else { break }
            var r = PSDCursor(data, start, start + size)
            switch id {
            case 1039: profile = data[start..<(start + size)]
            case 1037: if size >= 4 { globalAngle = Double(try r.i32()) }
            case 1057: if size >= 5 { _ = try r.u32(); hasComposite = try r.u8() != 0 }
            default: break
            }
            c.at = start + size + size % 2
        }
        c.at = resourceEnd

        let sectionLength = try c.length(large)
        let sectionEnd = min(c.at + sectionLength, data.count)
        if sectionLength > 0 {
            let infoLength = try c.length(large)
            let infoEnd = c.at + infoLength
            if infoLength > 0 { layers = try readLayers(&c, end: infoEnd) }
            c.at = infoEnd
            if c.at + 4 <= sectionEnd {
                let global = Int(try c.u32())
                c.at += global
            }
            globalBlocks = readBlocks(&c, end: sectionEnd)
        }
        c.at = sectionEnd
        compositeStart = c.at

        // Deeper documents keep their layers among the blocks instead.
        if layers.isEmpty, let r = globalBlocks["Lr16"] ?? globalBlocks["Lr32"] ?? globalBlocks["Layr"] {
            var lc = PSDCursor(data, r.lowerBound, r.upperBound)
            layers = (try? readLayers(&lc, end: r.upperBound)) ?? []
        }
        for key in ["lnk2", "lnk3", "lnkD", "lnkE", "lnkA"] {
            if let r = globalBlocks[key] { readLinked(r) }
        }
        // Older files keep them with a layer.
        for layer in layers {
            for key in ["lnk2", "lnk3", "lnkD"] { if let r = layer.blocks[key] { readLinked(r) } }
        }
    }

    // MARK: Layers

    private static let largeKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2",
                                                 "FEid", "FXid", "PxSD", "lnkE", "extn", "cinf"]

    private mutating func readLayers(_ c: inout PSDCursor, end: Int) throws -> [Layer] {
        var count = Int(try c.i16())
        if count < 0 {
            transparentComposite = true
            count = -count
        }
        var records: [Layer] = []
        var lengths: [[(Int, Int)]] = []
        for _ in 0..<count {
            var l = Layer()
            l.top = Int(try c.i32())
            l.left = Int(try c.i32())
            l.bottom = Int(try c.i32())
            l.right = Int(try c.i32())
            let n = Int(try c.u16())
            guard n < 64 else { throw Failure.damaged }
            var lens: [(Int, Int)] = []
            for _ in 0..<n {
                let id = Int(try c.i16())
                lens.append((id, try c.length(large)))
            }
            guard try c.key() == "8BIM" else { throw Failure.damaged }
            l.blend = try c.key()
            l.opacity = try c.u8()
            l.clipping = try c.u8() != 0
            l.flags = try c.u8()
            try c.skip(1)
            let extra = Int(try c.u32())
            let extraEnd = c.at + extra
            guard extraEnd <= end else { throw Failure.damaged }

            let maskLength = Int(try c.u32())
            let maskEnd = c.at + maskLength
            if maskLength >= 18 { (l.mask, l.realMask) = try Self.readMasks(&c, length: maskLength) }
            c.at = maskEnd
            let ranges = Int(try c.u32())
            c.at += ranges
            l.name = try c.pascal(pad: 4)
            l.blocks = readBlocks(&c, end: extraEnd)
            c.at = extraEnd

            if let r = l.blocks["luni"] {
                var u = PSDCursor(data, r.lowerBound, r.upperBound)
                if let name = try? u.unicode(), !name.isEmpty { l.name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
            }
            if let r = l.blocks["lsct"] ?? l.blocks["lsdk"] {
                var s = PSDCursor(data, r.lowerBound, r.upperBound)
                l.section = Int((try? s.u32()) ?? 0)
                if r.count >= 12, (try? s.key()) == "8BIM", let key = try? s.key(), key != "pass" { l.sectionBlend = key }
            }
            records.append(l)
            lengths.append(lens)
        }
        for i in records.indices {
            var channels: [(id: Int, range: Range<Int>)] = []
            for (id, length) in lengths[i] {
                guard c.at + length <= data.count else { throw Failure.damaged }
                channels.append((id, c.at..<(c.at + length)))
                c.at += length
            }
            records[i].channels = channels
        }
        return records
    }

    /// A layer's mask, and the one drawn by hand when there is a vector mask besides. Photoshop
    /// writes the second before the mask's settings, whatever the specification says.
    private static func readMasks(_ c: inout PSDCursor, length: Int) throws -> (Mask?, Mask?) {
        let end = c.at + length
        var m = Mask()
        m.top = Int(try c.i32())
        m.left = Int(try c.i32())
        m.bottom = Int(try c.i32())
        m.right = Int(try c.i32())
        m.color = try c.u8()
        m.flags = try c.u8()
        var real: Mask?
        if end - c.at >= 18 {
            var r = Mask()
            r.flags = try c.u8()
            r.color = try c.u8()
            r.top = Int(try c.i32())
            r.left = Int(try c.i32())
            r.bottom = Int(try c.i32())
            r.right = Int(try c.i32())
            if r.top <= r.bottom, r.left <= r.right, r.color == 0 || r.color == 255 { real = r }
        }
        c.at = end
        return (m, real)
    }

    /// The blocks of what else a layer, or the document, keeps, up to `end`. Writers pad them to
    /// two or four bytes, so a block that does not start where the last ended is looked for a
    /// few bytes on.
    private func readBlocks(_ c: inout PSDCursor, end: Int) -> [String: Range<Int>] {
        var blocks: [String: Range<Int>] = [:]
        func signed(at i: Int) -> Bool {
            guard i + 4 <= end else { return false }
            let s = String(decoding: data[i..<(i + 4)], as: UTF8.self)
            return s == "8BIM" || s == "8B64"
        }
        while c.at + 12 <= end {
            if !signed(at: c.at) {
                guard let k = (1...3).first(where: { signed(at: c.at + $0) }) else { break }
                c.at += k
            }
            guard let sig = try? c.key(), let key = try? c.key() else { break }
            let wide = sig == "8B64" || (large && Self.largeKeys.contains(key))
            guard let length = try? c.length(wide), length >= 0, c.at + length <= end else { break }
            if blocks[key] == nil { blocks[key] = c.at..<(c.at + length) }
            c.at += length
            if c.at % 2 != 0 { c.at += 1 }
        }
        return blocks
    }

    private mutating func readLinked(_ range: Range<Int>) {
        var c = PSDCursor(data, range.lowerBound, range.upperBound)
        while c.left > 8 {
            guard let length = try? c.length(true), length > 0 else { break }
            let start = c.at
            defer { c.at = start + length + (4 - length % 4) % 4 }
            guard start + length <= range.upperBound,
                  let type = try? c.key(), let version = try? c.u32(), let id = try? c.pascal(pad: 1),
                  let name = try? c.unicode(), let fileType = try? c.key(), (try? c.key()) != nil,
                  let size = try? c.length(true), let described = try? c.u8() else { break }
            if described != 0 {
                guard (try? c.u32()) != nil, (try? PSDDescriptor.read(&c)) != nil else { continue }
            }
            guard type == "liFD", version >= 1, c.at + size <= start + length else { continue }
            linked[id] = Linked(id: id, name: name, type: fileType, range: c.at..<(c.at + size))
        }
    }

    /// A block's descriptor, after the four letters and version numbers that come first in most.
    func descriptor(_ key: String, in layer: Layer, skipping skip: Int = 4) -> PSDValue? {
        guard let r = layer.blocks[key] else { return nil }
        var c = PSDCursor(data, r.lowerBound, r.upperBound)
        guard (try? c.skip(skip)) != nil else { return nil }
        return PSDDescriptor.readAll(&c)
    }

    func bytes(_ range: Range<Int>) -> Data { data[range] }

    // MARK: Pixels

    /// How many colour channels the mode has.
    var colorChannels: Int {
        switch mode {
        case .rgb, .lab: 3
        case .cmyk: 4
        default: 1
        }
    }

    /// One channel, eight bits a sample, row after row. 16-bit samples are rounded, and 32-bit
    /// ones, which are linear light, are brought into the gamma of the rest when `color`.
    func samples(_ range: Range<Int>, width w: Int, height h: Int, color: Bool) throws -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        guard range.count >= 2 else { throw Failure.damaged }
        let compression = Int(data[range.lowerBound]) << 8 | Int(data[range.lowerBound + 1])
        return try Self.decode(data, from: range.lowerBound + 2, to: range.upperBound, compression: compression,
                               width: w, height: h, depth: depth, large: large, rowCounts: nil, color: color)
    }

    /// Unpacks one plane of samples.
    private static func decode(_ data: Data, from start: Int, to end: Int, compression: Int, width w: Int, height h: Int,
                               depth: Int, large: Bool, rowCounts: [Int]?, color: Bool) throws -> [UInt8] {
        let bps = max(depth / 8, 1)
        let rowBytes = depth == 1 ? (w + 7) / 8 : w * bps
        let size = rowBytes * h
        var raw = [UInt8](repeating: 0, count: size)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), end <= buffer.count, start <= end else { throw Failure.damaged }
            let src = base + start, available = end - start
            switch compression {
            case 0:
                guard available >= size else { throw Failure.damaged }
                raw.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: src, count: size) }
            case 1:
                var counts = rowCounts ?? []
                var at = 0
                if rowCounts == nil {
                    let width = large ? 4 : 2
                    guard available >= h * width else { throw Failure.damaged }
                    counts.reserveCapacity(h)
                    for y in 0..<h {
                        var n = 0
                        for k in 0..<width { n = n << 8 | Int(src[y * width + k]) }
                        counts.append(n)
                    }
                    at = h * width
                }
                raw.withUnsafeMutableBufferPointer { out in
                    let dst = out.baseAddress!
                    for y in 0..<h {
                        let n = counts[y]
                        guard at + n <= available else { break }
                        unpackBits(src + at, n, into: dst + y * rowBytes, rowBytes)
                        at += n
                    }
                }
            case 2, 3:
                guard available > 2 else { throw Failure.damaged }
                let written = raw.withUnsafeMutableBufferPointer { out in
                    compression_decode_buffer(out.baseAddress!, size, src + 2, available - 2, nil, COMPRESSION_ZLIB)
                }
                guard written > 0 else { throw Failure.damaged }
                if compression == 3 { unpredict(&raw, width: w, height: h, depth: depth) }
            default:
                throw Failure.compression
            }
        }
        return eightBit(raw, depth: depth, width: w, height: h, color: color)
    }

    private static func unpackBits(_ src: UnsafePointer<UInt8>, _ count: Int, into dst: UnsafeMutablePointer<UInt8>, _ size: Int) {
        var i = 0, o = 0
        while i < count, o < size {
            let n = Int(Int8(bitPattern: src[i]))
            i += 1
            if n >= 0 {
                let k = min(n + 1, size - o, count - i)
                guard k > 0 else { break }
                (dst + o).update(from: src + i, count: k)
                i += n + 1
                o += k
            } else if n != -128 {
                guard i < count else { break }
                let k = min(1 - n, size - o)
                (dst + o).update(repeating: src[i], count: k)
                i += 1
                o += k
            }
        }
    }

    /// Undoes ZIP's prediction: each sample was kept as how far it is from the one before it.
    private static func unpredict(_ raw: inout [UInt8], width w: Int, height h: Int, depth: Int) {
        raw.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress!
            // Plain loops over pointers, which stay quick in a build made for debugging too.
            var y = 0
            switch depth {
            case 16:
                while y < h {
                    let row = p + y * w * 2
                    var last = UInt16(row[0]) << 8 | UInt16(row[1])
                    var x = 1
                    while x < w {
                        let v = (UInt16(row[x * 2]) << 8 | UInt16(row[x * 2 + 1])) &+ last
                        row[x * 2] = UInt8(v >> 8)
                        row[x * 2 + 1] = UInt8(v & 0xFF)
                        last = v
                        x += 1
                    }
                    y += 1
                }
            case 32:
                let row = UnsafeMutablePointer<UInt8>.allocate(capacity: w * 4)
                defer { row.deallocate() }
                while y < h {
                    let r = p + y * w * 4
                    var i = 1
                    while i < w * 4 { r[i] = r[i] &+ r[i - 1]; i += 1 }
                    // Each row keeps the first bytes of all its samples, then the second, and so on.
                    var x = 0
                    while x < w {
                        row[x * 4] = r[x]
                        row[x * 4 + 1] = r[w + x]
                        row[x * 4 + 2] = r[2 * w + x]
                        row[x * 4 + 3] = r[3 * w + x]
                        x += 1
                    }
                    r.update(from: row, count: w * 4)
                    y += 1
                }
            default:
                while y < h {
                    let row = p + y * w
                    var x = 1
                    while x < w { row[x] = row[x] &+ row[x - 1]; x += 1 }
                    y += 1
                }
            }
        }
    }

    private static func eightBit(_ raw: [UInt8], depth: Int, width w: Int, height h: Int, color: Bool) -> [UInt8] {
        switch depth {
        case 8:
            return raw
        case 16:
            var out = [UInt8](repeating: 0, count: w * h)
            raw.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let a = src.baseAddress!, o = dst.baseAddress!
                    var i = 0
                    while i < w * h {
                        let v = Int(a[i * 2]) << 8 | Int(a[i * 2 + 1])
                        o[i] = UInt8((v * 255 + 32767) / 65535)
                        i += 1
                    }
                }
            }
            return out
        case 32:
            var out = [UInt8](repeating: 0, count: w * h)
            raw.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let a = src.baseAddress!, o = dst.baseAddress!
                    var i = 0
                    while i < w * h {
                        let bits = UInt32(a[i * 4]) << 24 | UInt32(a[i * 4 + 1]) << 16 | UInt32(a[i * 4 + 2]) << 8 | UInt32(a[i * 4 + 3])
                        var v = Double(Float(bitPattern: bits))
                        v = v.isFinite ? min(max(v, 0), 1) : 0
                        if color { v = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
                        o[i] = UInt8((v * 255).rounded())
                        i += 1
                    }
                }
            }
            return out
        default:
            // One bit a sample, 1 black.
            var out = [UInt8](repeating: 255, count: w * h)
            let rowBytes = (w + 7) / 8
            for y in 0..<h {
                for x in 0..<w where raw[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 { out[y * w + x] = 0 }
            }
            return out
        }
    }

    /// The colours of a rectangle of samples, as Bezzle's pictures keep them: red, green, blue
    /// and how solid, not multiplied together, in `space`. `planes` are the colour channels in
    /// the document's mode.
    func rgba(_ planes: [[UInt8]], alpha: [UInt8]?, width w: Int, height h: Int) -> [UInt8] {
        let n = w * h
        var out = [UInt8](repeating: 255, count: n * 4)
        let solid = alpha.flatMap { $0.count == n ? $0 : nil } ?? [UInt8](repeating: 255, count: n)
        switch mode {
        case .rgb:
            guard planes.count >= 3, planes.allSatisfy({ $0.count == n }) else { break }
            return Self.interleaved(planes[0], planes[1], planes[2], solid, width: w, height: h)
        case .gray, .duotone, .multichannel, .bitmap:
            guard let p = planes.first, p.count == n else { break }
            return Self.interleaved(p, p, p, solid, width: w, height: h)
        case .cmyk:
            guard planes.count >= 4 else { break }
            out = cmykToRGB(planes, width: w, height: h)
        case .indexed:
            guard let palette, palette.count >= 768, let p = planes.first else { break }
            let bytes = [UInt8](palette)
            for i in 0..<n {
                let k = Int(p[i])
                out[i * 4] = bytes[k]
                out[i * 4 + 1] = bytes[256 + k]
                out[i * 4 + 2] = bytes[512 + k]
            }
        default:
            break
        }
        if let alpha, alpha.count == n {
            out.withUnsafeMutableBufferPointer { o in
                alpha.withUnsafeBufferPointer { a in
                    var i = 0
                    while i < n { o[i * 4 + 3] = a[i]; i += 1 }
                }
            }
        }
        return out
    }

    /// Four planes of samples as pixels, the first plane's sample first in each: vImage's
    /// interleaving, which is quick however the app was built.
    static func interleaved(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8], _ d: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in c.withUnsafeBufferPointer { pc in d.withUnsafeBufferPointer { pd in
            out.withUnsafeMutableBufferPointer { po in
                func plane(_ p: UnsafeBufferPointer<UInt8>) -> vImage_Buffer {
                    vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.baseAddress!), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                }
                var first = plane(pa), second = plane(pb), third = plane(pc), fourth = plane(pd)
                var dest = vImage_Buffer(data: po.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                // Named for ARGB, it writes the four planes in the order given.
                _ = vImageConvert_Planar8toARGB8888(&first, &second, &third, &fourth, &dest, vImage_Flags(kvImageNoFlags))
            }
        } } } }
        return out
    }

    /// Ink, through the file's own profile when it has one, as the Mac shows it in sRGB.
    private func cmykToRGB(_ planes: [[UInt8]], width w: Int, height h: Int) -> [UInt8] {
        let n = w * h
        // Photoshop keeps how much paper shows: 255 is no ink.
        var ink = Self.interleaved(planes[0], planes[1], planes[2], planes[3], width: w, height: h)
        ink.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count { p[i] = 255 - p[i]; i += 1 }
        }
        var out = [UInt8](repeating: 255, count: n * 4)
        let space = profile.flatMap { CGColorSpace(iccData: $0 as CFData) }.flatMap { $0.model == .cmyk ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.genericCMYK)!
        guard let provider = CGDataProvider(data: Data(ink) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return out }
        out.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        out.withUnsafeMutableBufferPointer { p in
            var i = 3
            while i < p.count { p[i] = 255; i += 4 }
        }
        return out
    }

    /// The colour space a picture made by `rgba` is in.
    var space: CGColorSpace {
        if mode == .rgb, let profile, let s = CGColorSpace(iccData: profile as CFData), s.model == .rgb { return s }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Whether the picture of all of it the file keeps shows what is see-through, as its layers do.
    var compositeShowsTransparency: Bool {
        let colors = min(colorChannels, channelCount)
        return channelCount > colors && (transparentComposite || !hasBackground)
    }

    /// Whether the layer at the bottom is a background, which is never see-through.
    var hasBackground: Bool {
        guard let first = layers.first else { return true }
        return first.channel(-1) == nil
    }

    /// The picture of the whole document the file keeps, as Photoshop drew it; nil when it was
    /// saved without one.
    func composite() throws -> (pixels: [UInt8], width: Int, height: Int)? {
        guard hasComposite, compositeStart + 2 <= data.count else { return nil }
        let compression = Int(data[compositeStart]) << 8 | Int(data[compositeStart + 1])
        let colors = min(colorChannels, channelCount)
        let alphaToo = channelCount > colors && (transparentComposite || !hasBackground)
        let wanted = colors + (alphaToo ? 1 : 0)
        let w = width, h = height
        var planes: [[UInt8]] = []
        var at = compositeStart + 2
        switch compression {
        case 0:
            let bps = max(depth / 8, 1)
            let plane = depth == 1 ? (w + 7) / 8 * h : w * h * bps
            for k in 0..<wanted {
                planes.append(try Self.decode(data, from: at, to: min(at + plane, data.count), compression: 0, width: w, height: h,
                                              depth: depth, large: large, rowCounts: nil, color: k < colors))
                at += plane
            }
        case 1:
            let width = large ? 4 : 2
            let rows = channelCount * h
            guard at + rows * width <= data.count else { throw Failure.damaged }
            var counts: [Int] = []
            counts.reserveCapacity(rows)
            try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                guard let p = b.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw Failure.damaged }
                for r in 0..<rows {
                    var n = 0
                    for k in 0..<width { n = n << 8 | Int(p[at + r * width + k]) }
                    counts.append(n)
                }
            }
            at += rows * width
            for k in 0..<wanted {
                let mine = Array(counts[(k * h)..<((k + 1) * h)])
                let total = mine.reduce(0, +)
                planes.append(try Self.decode(data, from: at, to: min(at + total, data.count), compression: 1, width: w, height: h,
                                              depth: depth, large: large, rowCounts: mine, color: k < colors))
                at += total
            }
        default:
            throw Failure.compression
        }
        let alpha = alphaToo ? planes.last : nil
        var pixels = rgba(Array(planes.prefix(colors)), alpha: alpha, width: w, height: h)
        // Photoshop keeps a see-through composite's colours mixed with white.
        if alphaToo {
            pixels.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < w * h {
                    let a = Int(p[i * 4 + 3])
                    if a > 0, a < 255 {
                        var k = 0
                        while k < 3 {
                            let c = Int(p[i * 4 + k])
                            p[i * 4 + k] = UInt8(min(255, max(0, (c - (255 - a)) * 255 / a)))
                            k += 1
                        }
                    }
                    i += 1
                }
            }
        }
        return (pixels, w, h)
    }
}

// MARK: - Reading

/// Reads a file's numbers, which Photoshop writes most significant byte first.
nonisolated struct PSDCursor {
    let data: Data
    var at: Int
    let end: Int

    /// From `from` to `to` in `data`, counted from its first byte, wherever a slice of it starts.
    init(_ data: Data, _ from: Int = 0, _ to: Int? = nil) {
        self.data = data.startIndex == 0 ? data : Data(data)
        at = from
        end = min(to ?? self.data.count, self.data.count)
    }

    var left: Int { end - at }

    mutating func u8() throws -> UInt8 {
        guard at < end else { throw PhotoshopFile.Failure.damaged }
        defer { at += 1 }
        return data[at]
    }

    mutating func u16() throws -> UInt16 {
        guard at + 2 <= end else { throw PhotoshopFile.Failure.damaged }
        defer { at += 2 }
        return UInt16(data[at]) << 8 | UInt16(data[at + 1])
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        guard at + 4 <= end else { throw PhotoshopFile.Failure.damaged }
        defer { at += 4 }
        return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }

    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    /// A length kept in four bytes, or in eight in large documents.
    mutating func length(_ wide: Bool) throws -> Int {
        let n = wide ? try u64() : UInt64(try u32())
        guard n <= UInt64(Int32.max) * 8 else { throw PhotoshopFile.Failure.damaged }
        return Int(n)
    }

    /// Four letters.
    mutating func key() throws -> String {
        guard at + 4 <= end else { throw PhotoshopFile.Failure.damaged }
        defer { at += 4 }
        return String(decoding: data[at..<(at + 4)], as: UTF8.self)
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, at + n <= end else { throw PhotoshopFile.Failure.damaged }
        defer { at += n }
        return data[at..<(at + n)]
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, at + n <= end else { throw PhotoshopFile.Failure.damaged }
        at += n
    }

    /// A length byte and that many letters, padded to a multiple of `pad` with the length.
    mutating func pascal(pad: Int) throws -> String {
        let n = Int(try u8())
        let text = try bytes(n)
        let used = n + 1
        if used % pad != 0 { try skip(min(pad - used % pad, left)) }
        return String(data: text, encoding: .macOSRoman) ?? String(decoding: text, as: UTF8.self)
    }

    /// A count and that many UTF-16 letters.
    mutating func unicode() throws -> String {
        let n = Int(try u32())
        guard n <= left / 2 else { throw PhotoshopFile.Failure.damaged }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for _ in 0..<n { units.append(try u16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A value in one of Photoshop's descriptors, the way it keeps settings: a class with named
/// items, each a number, a word, a list or another descriptor.
nonisolated indirect enum PSDValue {
    case number(Double)
    /// A number with its unit: "#Pxl", "#Prc", "#Ang".
    case unit(String, Double)
    case numbers(String, [Double])
    case bool(Bool)
    case text(String)
    /// One of a set of named choices, and the name of the set.
    case enumerated(String, String)
    case list([PSDValue])
    case object(String, [String: PSDValue])
    case data(Data)
    case other

    subscript(key: String) -> PSDValue? {
        if case .object(_, let items) = self { return items[key] }
        return nil
    }

    var double: Double? {
        switch self {
        case .number(let v), .unit(_, let v): v
        default: nil
        }
    }

    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var text: String? { if case .text(let s) = self { s } else { nil } }
    var choice: String? { if case .enumerated(_, let v) = self { v } else { nil } }
    var items: [PSDValue] { if case .list(let l) = self { l } else { [] } }
    var className: String? { if case .object(let c, _) = self { c } else { nil } }

    /// A list of plain numbers, as corners are kept.
    var doubles: [Double] {
        switch self {
        case .list(let l): l.compactMap(\.double)
        case .numbers(_, let v): v
        default: []
        }
    }

    /// A colour as Photoshop keeps it, in 0 to 255 or as hue, saturation and brightness.
    var color: RGBA? {
        guard case .object(let cls, let c) = self else { return nil }
        switch cls {
        case "RGBC":
            guard let r = c["Rd  "]?.double ?? c["redFloat"]?.double.map({ $0 * 255 }),
                  let g = c["Grn "]?.double ?? c["greenFloat"]?.double.map({ $0 * 255 }),
                  let b = c["Bl  "]?.double ?? c["blueFloat"]?.double.map({ $0 * 255 }) else { return nil }
            return RGBA(r: r / 255, g: g / 255, b: b / 255)
        case "HSBC":
            guard let h = c["H   "]?.double, let s = c["Strt"]?.double, let b = c["Brgh"]?.double else { return nil }
            return RGBA(h: h / 360, s: s / 100, b: b / 100)
        case "Grsc":
            guard let g = c["Gry "]?.double else { return nil }
            return RGBA(r: 1 - g / 100, g: 1 - g / 100, b: 1 - g / 100)
        default:
            return nil
        }
    }
}

nonisolated enum PSDDescriptor {
    /// Reading stopped partway: what was read up to there.
    struct Partial: Error { let value: PSDValue }

    /// A descriptor, or as much of it as could be read.
    static func readAll(_ c: inout PSDCursor) -> PSDValue? {
        do { return try read(&c) } catch let p as Partial { return p.value } catch { return nil }
    }

    static func read(_ c: inout PSDCursor) throws -> PSDValue {
        _ = try c.unicode()
        let cls = try id(&c)
        let count = Int(try c.u32())
        guard count < 10_000 else { throw PhotoshopFile.Failure.damaged }
        var items: [String: PSDValue] = [:]
        for _ in 0..<count {
            let key: String
            do { key = try id(&c) } catch { throw Partial(value: .object(cls, items)) }
            do {
                let type = try c.key()
                items[key] = try value(type, &c)
            } catch let p as Partial {
                items[key] = p.value
                throw Partial(value: .object(cls, items))
            } catch {
                throw Partial(value: .object(cls, items))
            }
        }
        return .object(cls, items)
    }

    private static func id(_ c: inout PSDCursor) throws -> String {
        let n = Int(try c.u32())
        if n == 0 { return try c.key() }
        guard n < 1000 else { throw PhotoshopFile.Failure.damaged }
        return String(decoding: try c.bytes(n), as: UTF8.self)
    }

    private static func value(_ type: String, _ c: inout PSDCursor) throws -> PSDValue {
        switch type {
        case "Objc", "GlbO":
            return try read(&c)
        case "VlLs":
            let n = Int(try c.u32())
            guard n < 1_000_000 else { throw PhotoshopFile.Failure.damaged }
            var list: [PSDValue] = []
            for _ in 0..<n {
                do { list.append(try value(try c.key(), &c)) } catch { throw Partial(value: .list(list)) }
            }
            return .list(list)
        case "doub":
            return .number(try c.f64())
        case "UntF":
            let unit = try c.key()
            return .unit(unit, try c.f64())
        case "UnFl":
            let unit = try c.key()
            let n = Int(try c.u32())
            guard n < 1_000_000 else { throw PhotoshopFile.Failure.damaged }
            return .numbers(unit, try (0..<n).map { _ in try c.f64() })
        case "TEXT":
            return .text(try c.unicode())
        case "enum":
            let set = try id(&c)
            return .enumerated(set, try id(&c))
        case "long":
            return .number(Double(try c.i32()))
        case "comp":
            return .number(Double(Int64(bitPattern: try c.u64())))
        case "bool":
            return .bool(try c.u8() != 0)
        case "type", "GlbC":
            _ = try c.unicode()
            _ = try id(&c)
            return .other
        case "alis", "tdta", "Pth ":
            let n = Int(try c.u32())
            return .data(try c.bytes(n))
        case "obj ":
            let n = Int(try c.u32())
            for _ in 0..<n {
                switch try c.key() {
                case "prop": _ = try c.unicode(); _ = try id(&c); _ = try id(&c)
                case "Clss": _ = try c.unicode(); _ = try id(&c)
                case "Enmr": _ = try c.unicode(); _ = try id(&c); _ = try id(&c); _ = try id(&c)
                case "rele": _ = try c.unicode(); _ = try id(&c); _ = try c.u32()
                case "Idnt", "indx": _ = try c.u32()
                case "name": _ = try c.unicode(); _ = try id(&c); _ = try c.unicode()
                default: throw PhotoshopFile.Failure.damaged
                }
            }
            return .other
        case "ObAr":
            // A count, then what looks like a descriptor whose items are lists of unit numbers.
            _ = try c.u32()
            _ = try c.unicode()
            let cls = try id(&c)
            let n = Int(try c.u32())
            guard n < 10_000 else { throw PhotoshopFile.Failure.damaged }
            var items: [String: PSDValue] = [:]
            for _ in 0..<n {
                let key = try id(&c)
                items[key] = try value(try c.key(), &c)
            }
            return .object(cls, items)
        default:
            throw PhotoshopFile.Failure.damaged
        }
    }
}
