import AppKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Reads Photoshop documents, made with mockups in mind: a photo of a phone, a laptop or a
/// poster, with the place for a design kept as a smart object. Every layer comes across as a
/// layer of its own, mixed as it was, so a shadow or a glare can still be hidden or changed; each
/// smart object becomes a picture pinned by its corners where the smart object was, seen at the
/// same angle, into which another picture can be put.
///
/// What Photoshop draws that Bezzle has nothing for is drawn into the layer's own pixels when the
/// result is the same (masks, clipping, a colour laid over), and counted in the report when it is
/// not (adjustment layers, warps, most layer styles).
nonisolated enum PhotoshopImporter {
    static let fileExtensions = ["psd", "psb"]

    /// What a document makes, read away from the main thread, which a mockup's photos would hold up.
    struct Reading: Sendable {
        var document: BezzleDocument
        /// The pictures made, by their file names in the design.
        var held: [String: Data]
        /// What was approximated, in the user's language, and how often.
        var notes: [String: Int]
        var artboards: Int
        var layers: Int
    }

    /// How far reading has got, 0 to 1, and the name of the layer it is on; told from the thread reading.
    typealias Progress = @Sendable (Double, String) -> Void

    static func reading(_ url: URL, progress: Progress? = nil) throws -> Reading {
        try reading(Data(contentsOf: url, options: .alwaysMapped), named: url.deletingPathExtension().lastPathComponent, progress: progress)
    }

    static func reading(_ data: Data, named name: String, progress: Progress? = nil) throws -> Reading {
        let file = try PhotoshopFile(data: data)
        guard [.rgb, .cmyk, .gray, .duotone, .indexed, .bitmap, .multichannel].contains(file.mode) else {
            throw PhotoshopFile.Failure.colorMode
        }
        var converter = PSDConverter(file: file, name: name)
        converter.progress = progress
        let doc = converter.document()
        converter.encode()
        return Reading(document: doc, held: converter.held, notes: converter.notes, artboards: converter.artboards, layers: converter.layers)
    }

    @MainActor static func read(_ url: URL) throws -> Imported { imported(try reading(url)) }

    @MainActor static func read(_ data: Data, named name: String) throws -> Imported { imported(try reading(data, named: name)) }

    /// The design read, as every importer hands it over.
    @MainActor static func imported(_ r: Reading) -> Imported {
        var report = ImportReport(source: "Photoshop")
        report.notes = r.notes
        report.artboards = r.artboards
        report.layers = r.layers
        return Imported(document: r.document, report: report, archive: nil, held: r.held)
    }
}

nonisolated extension BlendMode {
    /// The two modes other apps call linear, which Bezzle calls plus.
    static func linear(_ name: String) -> BlendMode? {
        switch name {
        case "linearBurn": .plusDarker
        case "linearDodge", "linearDodgeAdd", "add": .plusLighter
        default: nil
        }
    }
}

// MARK: - Pixels

/// A rectangle of a document's pixels: red, green, blue and how solid, not multiplied together.
nonisolated private struct Bitmap {
    var x: Int, y: Int, w: Int, h: Int
    var rgba: [UInt8]

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    // The loops over pixels are plain loops over pointers, which stay quick in a build made
    // for debugging too, where ranges and array subscripts cost many times the work.

    /// How solid each pixel is, as something else can be cut by.
    var coverage: Coverage {
        var alpha = [UInt8](repeating: 0, count: w * h)
        rgba.withUnsafeBufferPointer { p in
            alpha.withUnsafeMutableBufferPointer { a in
                var i = 0
                while i < a.count { a[i] = p[i * 4 + 3]; i += 1 }
            }
        }
        return Coverage(x: x, y: y, w: w, h: h, alpha: alpha, outside: 0)
    }

    /// Only what shows of it: `cut` takes away what it does not show.
    mutating func cut(by c: Coverage) {
        let x0 = x, y0 = y, w = w, h = h
        rgba.withUnsafeMutableBufferPointer { p in
            c.alpha.withUnsafeBufferPointer { m in
                var row = 0
                while row < h {
                    let v = y0 + row - c.y
                    let line = p.baseAddress! + row * w * 4
                    if v < 0 || v >= c.h {
                        // A row wholly outside what cuts it.
                        if c.outside != 255 {
                            var col = 0
                            while col < w { line[col * 4 + 3] = UInt8((Int(line[col * 4 + 3]) * Int(c.outside) + 127) / 255); col += 1 }
                        }
                    } else {
                        let cutting = m.baseAddress! + v * c.w
                        var col = 0
                        while col < w {
                            let u = x0 + col - c.x
                            let k = u >= 0 && u < c.w ? cutting[u] : c.outside
                            if k != 255 { line[col * 4 + 3] = UInt8((Int(line[col * 4 + 3]) * Int(k) + 127) / 255) }
                            col += 1
                        }
                    }
                    row += 1
                }
            }
        }
    }

    mutating func fade(_ k: Double) {
        guard k < 1 else { return }
        let f = Int((k * 255).rounded())
        rgba.withUnsafeMutableBufferPointer { p in
            var i = 3
            while i < p.count { p[i] = UInt8((Int(p[i]) * f + 127) / 255); i += 4 }
        }
    }

    /// A colour laid over it, as Photoshop's Colour Overlay is, where it shows.
    mutating func overlay(_ color: RGBA, opacity: Double) {
        let k = Int((min(max(opacity, 0), 1) * 256).rounded())
        let r = Int(color.r * 255), g = Int(color.g * 255), b = Int(color.b * 255)
        rgba.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                p[i] = UInt8((Int(p[i]) * (256 - k) + r * k) >> 8)
                p[i + 1] = UInt8((Int(p[i + 1]) * (256 - k) + g * k) >> 8)
                p[i + 2] = UInt8((Int(p[i + 2]) * (256 - k) + b * k) >> 8)
                i += 4
            }
        }
    }

    /// A gradient laid over it where it shows, placed in `box` of the document, as Photoshop's
    /// Gradient Overlay is.
    mutating func overlay(_ g: Gradient, box: CGRect, opacity: Double) {
        guard w > 0, h > 0, let shade = Self.drawn(g, box: box, over: rect) else { return }
        let k = min(max(opacity, 0), 1)
        rgba.withUnsafeMutableBufferPointer { p in
            shade.withUnsafeBufferPointer { q in
                var i = 0
                while i < p.count {
                    let a = Double(q[i + 3]) / 255 * k
                    if p[i + 3] != 0, a > 0 {
                        let ga = max(Double(q[i + 3]), 1)
                        var c = 0
                        while c < 3 {
                            let top = Double(q[i + c]) * 255 / ga
                            p[i + c] = UInt8(min(255, max(0, (Double(p[i + c]) * (1 - a) + top * a).rounded())))
                            c += 1
                        }
                    }
                    i += 4
                }
            }
        }
    }

    /// A gradient placed in `box` of the document, drawn over `area` of it: premultiplied, top row first.
    static func drawn(_ g: Gradient, box: CGRect, over area: CGRect) -> [UInt8]? {
        let w = Int(area.width), h = Int(area.height)
        guard w > 0, h > 0, box.width > 0, box.height > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = g.stops.map { CGColor(colorSpace: space, components: [$0.color.r, $0.color.g, $0.color.b, $0.color.a])! } as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: g.stops.map { CGFloat($0.offset) }) else { return nil }
        let ok = out.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: box.minX - area.minX, y: box.minY - area.minY)
            let size = box.size
            switch g.kind {
            case .linear:
                ctx.drawLinearGradient(gradient, start: CGPoint(x: g.start.x * size.width, y: g.start.y * size.height),
                                       end: CGPoint(x: g.end.x * size.width, y: g.end.y * size.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial:
                ctx.concatenate(g.spread(in: size))
                ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
            }
            return true
        }
        return ok ? out : nil
    }

    /// The same, grown by `n` clear pixels all round.
    func grown(by n: Int) -> Bitmap {
        guard n > 0 else { return self }
        let nw = w + 2 * n, nh = h + 2 * n
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    (dst.baseAddress! + ((row + n) * nw + n) * 4).update(from: src.baseAddress! + row * w * 4, count: w * 4)
                }
            }
        }
        return Bitmap(x: x - n, y: y - n, w: nw, h: nh, rgba: out)
    }

    private static let imaging = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// How solid each pixel is, widened by `radius` (or narrowed, below 0), as a round pen would.
    private func alpha(spread radius: CGFloat) -> [UInt8] {
        let plane = coverage.alpha
        guard abs(radius) >= 0.5 else { return plane }
        let image = CIImage(bitmapData: Data(plane), bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
        let spread = image.applyingFilter(radius > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: ["inputRadius": abs(radius)])
        // Narrowed, what lies outside the picture counts as clear.
        let source = radius > 0 ? spread : spread.cropped(to: image.extent)
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { b in
            Self.imaging.render(source, toBitmap: b.baseAddress!, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
        }
        return out
    }

    /// With Photoshop's Stroke round where it shows: outside its edge, inside it, or across it.
    func stroked(_ b: Border) -> Bitmap {
        let width = max(b.width, 0)
        guard width >= 0.5 else { return self }
        var big = grown(by: b.position == .inside ? 0 : Int(width.rounded(.up)) + 1)
        let outer = b.position == .outside ? width : b.position == .center ? width / 2 : 0
        let inner = b.position == .inside ? width : b.position == .center ? width / 2 : 0
        let wide = big.alpha(spread: outer), narrow = big.alpha(spread: -inner)
        let r = b.color.r * 255, g = b.color.g * 255, bl = b.color.b * 255, k = b.color.a
        let n = big.w * big.h
        big.rgba.withUnsafeMutableBufferPointer { p in
            wide.withUnsafeBufferPointer { wide in
                narrow.withUnsafeBufferPointer { narrow in
                    var i = 0
                    while i < n {
                        defer { i += 1 }
                        let s = Double(max(0, Int(wide[i]) - Int(narrow[i]))) / 255 * k
                        guard s > 0 else { continue }
                        let a = Double(p[i * 4 + 3]) / 255
                        let out = s + a * (1 - s)
                        guard out > 0 else { continue }
                        p[i * 4] = UInt8(min(255, ((r * s + Double(p[i * 4]) * a * (1 - s)) / out).rounded()))
                        p[i * 4 + 1] = UInt8(min(255, ((g * s + Double(p[i * 4 + 1]) * a * (1 - s)) / out).rounded()))
                        p[i * 4 + 2] = UInt8(min(255, ((bl * s + Double(p[i * 4 + 2]) * a * (1 - s)) / out).rounded()))
                        p[i * 4 + 3] = UInt8(min(255, (out * 255).rounded()))
                    }
                }
            }
        }
        return big
    }

    /// Only the part inside `bounds`, and of that only as far as anything shows. Nil when nothing does.
    func trimmed(to bounds: CGRect) -> Bitmap? {
        let inside = rect.intersection(bounds)
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return nil }
        var minX = Int(inside.maxX), minY = Int(inside.maxY), maxX = Int(inside.minX) - 1, maxY = Int(inside.minY) - 1
        let left = Int(inside.minX), right = Int(inside.maxX), top = Int(inside.minY), bottom = Int(inside.maxY)
        rgba.withUnsafeBufferPointer { p in
            var py = top
            while py < bottom {
                defer { py += 1 }
                let row = (py - y) * w
                var px = left
                while px < right, p[(row + px - x) * 4 + 3] == 0 { px += 1 }
                guard px < right else { continue }
                if px < minX { minX = px }
                if py < minY { minY = py }
                maxY = py
                px = right - 1
                while px >= left, p[(row + px - x) * 4 + 3] == 0 { px -= 1 }
                if px > maxX { maxX = px }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        if minX == x, minY == y, maxX == x + w - 1, maxY == y + h - 1 { return self }
        let nw = maxX - minX + 1, nh = maxY - minY + 1
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<nh {
                    let from = ((minY - y + row) * w + (minX - x)) * 4
                    (dst.baseAddress! + row * nw * 4).update(from: src.baseAddress! + from, count: nw * 4)
                }
            }
        }
        return Bitmap(x: minX, y: minY, w: nw, h: nh, rgba: out)
    }

    var opaque: Bool {
        rgba.withUnsafeBufferPointer { p in
            var i = 3
            while i < p.count { if p[i] != 255 { return false }; i += 4 }
            return true
        }
    }

    func image(in space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A picture's pixels, as `rgba` keeps them, in sRGB.
    init?(_ image: CGImage, at origin: (Int, Int) = (0, 0)) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h < 400_000_000 else { return nil }
        var premultiplied = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = premultiplied.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        premultiplied.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a > 0, a < 255 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
        self.init(x: origin.0, y: origin.1, w: w, h: h, rgba: premultiplied)
    }

    init(x: Int, y: Int, w: Int, h: Int, rgba: [UInt8]) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rgba = rgba
    }
}

/// How much of each pixel of a rectangle of the document something lets show, 0 to 255; outside
/// it, `outside`.
nonisolated private struct Coverage {
    var x: Int, y: Int, w: Int, h: Int
    var alpha: [UInt8]
    var outside: UInt8

    @inline(__always) func at(_ px: Int, _ py: Int) -> UInt8 {
        let u = px - x, v = py - y
        return u >= 0 && v >= 0 && u < w && v < h ? alpha[v * w + u] : outside
    }

    /// What either lets show, as layers lying one over another do.
    func union(_ other: Coverage) -> Coverage {
        if w == 0 || h == 0, outside == 0 { return other }
        if other.w == 0 || other.h == 0, other.outside == 0 { return self }
        let box = CGRect(x: x, y: y, width: w, height: h).union(CGRect(x: other.x, y: other.y, width: other.w, height: other.h))
        let nx = Int(box.minX), ny = Int(box.minY), nw = Int(box.width), nh = Int(box.height)
        var out = [UInt8](repeating: 0, count: nw * nh)
        out.withUnsafeMutableBufferPointer { o in
            for c in [self, other] {
                c.alpha.withUnsafeBufferPointer { a in
                    var row = 0
                    while row < c.h {
                        let line = o.baseAddress! + (c.y - ny + row) * nw + (c.x - nx), from = a.baseAddress! + row * c.w
                        var col = 0
                        while col < c.w {
                            let p = Int(line[col]), q = Int(from[col])
                            line[col] = UInt8(p + q - (p * q + 127) / 255)
                            col += 1
                        }
                        row += 1
                    }
                }
            }
        }
        return Coverage(x: nx, y: ny, w: nw, h: nh, alpha: out, outside: max(outside, other.outside))
    }

    /// The outline round where this lets half or more show, in the document's pixels, as closed
    /// loops to fill by the even-odd rule: what Bezzle's masks, which cut by outlines, can cut by.
    /// Traced along the pixels' middles by marching squares, then pared down to as few points
    /// as stay within a third of a pixel. Nil when it lets nothing show, or all of the document
    /// round it.
    func outline() -> CGPath? {
        guard w > 0, h > 0, outside == 0 else { return nil }
        // Padded with what lies outside it, so every loop closes.
        let W = w + 2, H = h + 2
        var v = [UInt8](repeating: outside, count: W * H)
        v.withUnsafeMutableBufferPointer { d in
            alpha.withUnsafeBufferPointer { a in
                var row = 0
                while row < h { (d.baseAddress! + (row + 1) * W + 1).update(from: a.baseAddress! + row * w, count: w); row += 1 }
            }
        }
        var points: [Int: CGPoint] = [:]
        var links: [Int: [Int]] = [:]
        let ox = CGFloat(x) - 0.5, oy = CGFloat(y) - 0.5
        func point(_ id: Int, _ a: Int, _ b: Int, _ ax: Int, _ ay: Int, horizontal: Bool) -> Int {
            if points[id] == nil {
                let va = CGFloat(v[a]), vb = CGFloat(v[b])
                let t = va == vb ? 0.5 : min(max((127.5 - va) / (vb - va), 0), 1)
                points[id] = CGPoint(x: ox + CGFloat(ax) + (horizontal ? t : 0), y: oy + CGFloat(ay) + (horizontal ? 0 : t))
            }
            return id
        }
        func link(_ a: Int, _ b: Int) {
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        v.withUnsafeBufferPointer { q in
            var row = 0
            while row < H - 1 {
                defer { row += 1 }
                var col = -1
                while col < W - 2 {
                    col += 1
                    let i = row * W + col
                    let a = q[i] >= 128, b = q[i + 1] >= 128, c = q[i + W + 1] >= 128, d = q[i + W] >= 128
                    if a == b && b == c && c == d { continue }
                    // Edges by the node they start at: across from it (even), or down (odd).
                    let top = i * 2, bottom = (i + W) * 2, left = i * 2 + 1, right = (i + 1) * 2 + 1
                    var crossing: [Int] = []
                    if a != b { crossing.append(point(top, i, i + 1, col, row, horizontal: true)) }
                    if b != c { crossing.append(point(right, i + 1, i + W + 1, col + 1, row, horizontal: false)) }
                    if c != d { crossing.append(point(bottom, i + W, i + W + 1, col, row + 1, horizontal: true)) }
                    if d != a { crossing.append(point(left, i, i + W, col, row, horizontal: false)) }
                    if crossing.count == 2 {
                        link(crossing[0], crossing[1])
                    } else if crossing.count == 4 {
                        // Two corners across from each other show: whether they meet in the middle.
                        let middle = (Int(q[i]) + Int(q[i + 1]) + Int(q[i + W + 1]) + Int(q[i + W])) / 4 >= 128
                        if middle == a {
                            link(crossing[0], crossing[1])
                            link(crossing[2], crossing[3])
                        } else {
                            link(crossing[0], crossing[3])
                            link(crossing[1], crossing[2])
                        }
                    }
                }
            }
        }
        let path = CGMutablePath()
        var seen = Set<Int>()
        for start in points.keys where !seen.contains(start) {
            var loop: [CGPoint] = []
            var previous = -1, current = start
            while true {
                seen.insert(current)
                loop.append(points[current]!)
                guard let next = links[current]?.first(where: { $0 != previous && !seen.contains($0) }) else { break }
                previous = current
                current = next
            }
            guard loop.count >= 3 else { continue }
            // A loop ends where it starts, so it is pared as two lines: to the point furthest from
            // its start, and back.
            let far = loop.indices.max { hypot(loop[$0].x - loop[0].x, loop[$0].y - loop[0].y) < hypot(loop[$1].x - loop[0].x, loop[$1].y - loop[0].y) } ?? 0
            guard far > 0 else { continue }
            let kept = Self.pared(Array(loop[0...far]), within: 0.33) + Self.pared(Array(loop[far...]) + [loop[0]], within: 0.33).dropFirst().dropLast()
            guard kept.count >= 3 else { continue }
            path.addLines(between: kept)
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }

    /// The fewest of a line's points that keep it within `within` of where it went: Ramer, Douglas and Peucker's.
    private static func pared(_ line: [CGPoint], within: CGFloat) -> [CGPoint] {
        guard line.count > 2 else { return line }
        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var spans = [(0, line.count - 1)]
        while let (a, b) = spans.popLast() {
            guard b > a + 1 else { continue }
            let p = line[a], q = line[b]
            let dx = q.x - p.x, dy = q.y - p.y, length = max(hypot(dx, dy), 1e-9)
            var far = a, distance: CGFloat = 0
            for k in (a + 1)..<b {
                let d = abs(dy * line[k].x - dx * line[k].y + q.x * p.y - q.y * p.x) / length
                if d > distance { distance = d; far = k }
            }
            if distance > within {
                keep[far] = true
                spans.append((a, far))
                spans.append((far, b))
            }
        }
        return line.indices.filter { keep[$0] }.map { line[$0] }
    }

    /// The pixels inside an outline in the document's pixels.
    static func of(_ path: VectorPath, in box: CGRect) -> Coverage? {
        guard !box.isNull, !box.isInfinite, box.width.isFinite, box.height.isFinite else { return nil }
        let x = Int(box.minX.rounded(.down)), y = Int(box.minY.rounded(.down))
        let w = Int(box.maxX.rounded(.up)) - x, h = Int(box.maxY.rounded(.up)) - y
        guard w > 0, h > 0, w * h < 400_000_000 else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        let ok = alpha.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // The document's pixels, y down, onto the context's rows, the first of which is its top.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(-x), y: CGFloat(-y))
            let all = CGRect(x: x, y: y, width: w, height: h)
            ctx.setFillColor(gray: path.startsFilled ? 1 : 0, alpha: 1)
            ctx.fill(all)
            for sub in path.subpaths {
                ctx.saveGState()
                switch sub.operation {
                case 2:
                    ctx.setFillColor(gray: 0, alpha: 1)
                    ctx.addPath(sub.path)
                    ctx.fillPath()
                case 3:
                    ctx.setFillColor(gray: 0, alpha: 1)
                    ctx.addRect(all.insetBy(dx: -2, dy: -2))
                    ctx.addPath(sub.path)
                    ctx.fillPath(using: .evenOdd)
                case 0:
                    ctx.setBlendMode(.difference)
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.addPath(sub.path)
                    ctx.fillPath()
                default:
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.addPath(sub.path)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
            return true
        }
        guard ok else { return nil }
        if path.inverted { for i in alpha.indices { alpha[i] = 255 - alpha[i] } }
        return Coverage(x: x, y: y, w: w, h: h, alpha: alpha, outside: path.inverted != path.startsFilled ? 255 : 0)
    }
}

/// A vector mask, or a shape layer's outline: Photoshop's path records, in the document's pixels.
nonisolated private struct VectorPath {
    struct Subpath {
        var path: CGPath
        /// How it is put together with those before it: 0 either but not both, 1 both, 2 the
        /// first without it, 3 only where both are.
        var operation: Int
        var closed: Bool
    }

    var subpaths: [Subpath] = []
    var inverted = false
    var disabled = false
    /// Everything is inside until outlines take it away.
    var startsFilled = false

    /// One outline of all of it, when it can be drawn as one: each part added to the rest.
    var outline: CGPath? {
        guard !inverted, !startsFilled, !subpaths.isEmpty else { return nil }
        guard subpaths.count == 1 || subpaths.allSatisfy({ $0.operation == 1 || $0.operation < 0 }) else { return nil }
        let out = CGMutablePath()
        for s in subpaths { out.addPath(s.path) }
        return out
    }

    var bounds: CGRect { subpaths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) } }

    init?(_ data: Data, width: Int, height: Int) {
        var c = PSDCursor(data)
        guard (try? c.u32()) != nil, let flags = try? c.u32() else { return nil }
        inverted = flags & 1 != 0
        disabled = flags & 4 != 0
        let W = CGFloat(width), H = CGFloat(height)
        func point(_ c: inout PSDCursor) throws -> CGPoint {
            let y = CGFloat(try c.i32()) / 16_777_216, x = CGFloat(try c.i32()) / 16_777_216
            return CGPoint(x: x * W, y: y * H)
        }
        var knots: [(CGPoint, CGPoint, CGPoint)] = []
        var left = 0, closed = true, operation = 1
        func finish() {
            guard !knots.isEmpty else { return }
            let p = CGMutablePath()
            p.move(to: knots[0].1)
            for k in 1..<knots.count { p.addCurve(to: knots[k].1, control1: knots[k - 1].2, control2: knots[k].0) }
            if closed {
                p.addCurve(to: knots[0].1, control1: knots[knots.count - 1].2, control2: knots[0].0)
                p.closeSubpath()
            }
            subpaths.append(Subpath(path: p, operation: operation, closed: closed))
            knots = []
        }
        while c.left >= 26 {
            let start = c.at
            guard let selector = try? c.u16() else { break }
            switch selector {
            case 0, 3:
                finish()
                left = Int((try? c.u16()) ?? 0)
                operation = Int((try? c.i16()) ?? 1)
                closed = selector == 0
            case 1, 2, 4, 5:
                if let a = try? point(&c), let b = try? point(&c), let d = try? point(&c), left > 0 {
                    knots.append((a, b, d))
                    left -= 1
                }
            case 8:
                startsFilled = ((try? c.u16()) ?? 0) == 1
            default:
                break
            }
            c.at = start + 26
        }
        finish()
    }
}

// MARK: - Gradients

/// A gradient as Photoshop keeps it, in a fill layer or a Gradient Overlay: colours and how
/// solid it is, each along it with midpoints, and how it lies on the layer.
nonisolated private struct PSGradient {
    var stops: [GradientStop]
    var style: String
    var angle: Double
    var reversed: Bool
    var scale: Double
    var offset: CGPoint
    /// Placed on the layer's own bounds, rather than the canvas.
    var aligned: Bool
    var opacity: Double

    init?(_ d: PSDValue) {
        guard let g = d["Grad"], g["GrdF"]?.choice != "ClNs" else { return nil }
        let colors: [(at: Double, mid: Double, value: RGBA)] = g["Clrs"]?.items.compactMap { c in
            guard let l = c["Lctn"]?.double else { return nil }
            let color = c["Clr "]?.color ?? (c["Type"]?.choice == "BckC" ? .white : .black)
            return (l / 4096, (c["Mdpn"]?.double ?? 50) / 100, color)
        }.sorted { $0.at < $1.at } ?? []
        var alphas: [(at: Double, mid: Double, value: Double)] = g["Trns"]?.items.compactMap { t in
            guard let l = t["Lctn"]?.double else { return nil }
            return (l / 4096, (t["Mdpn"]?.double ?? 50) / 100, (t["Opct"]?.double ?? 100) / 100)
        }.sorted { $0.at < $1.at } ?? []
        if alphas.isEmpty { alphas = [(0, 0.5, 1), (1, 0.5, 1)] }
        guard !colors.isEmpty else { return nil }
        /// Along a run of stops, each eased towards the next by its midpoint.
        func along<V>(_ list: [(at: Double, mid: Double, value: V)], _ p: Double, _ mix: (V, V, Double) -> V) -> V {
            guard let first = list.first, let last = list.last else { fatalError() }
            if p <= first.at { return first.value }
            if p >= last.at { return last.value }
            let i = list.lastIndex { $0.at <= p } ?? 0
            let a = list[i], b = list[min(i + 1, list.count - 1)]
            guard b.at > a.at else { return b.value }
            var t = (p - a.at) / (b.at - a.at)
            let m = min(max(b.mid, 0.01), 0.99)
            if abs(m - 0.5) > 0.001 { t = pow(t, log(0.5) / log(m)) }
            return mix(a.value, b.value, t)
        }
        var at = Set(colors.map(\.at) + alphas.map(\.at))
        for list in [colors.map(\.at), alphas.map(\.at)] {
            for (a, b) in zip(list, list.dropFirst()) where b > a {
                for k in 1...3 { at.insert(a + (b - a) * Double(k) / 4) }
            }
        }
        stops = at.sorted().map { p in
            var c = along(colors, p) { a, b, t in RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t) }
            c.a = along(alphas, p) { a, b, t in a + (b - a) * t }
            return GradientStop(offset: min(max(p, 0), 1), color: c)
        }
        style = d["Type"]?.choice ?? "Lnr "
        angle = d["Angl"]?.double ?? 90
        reversed = d["Rvrs"]?.bool ?? false
        scale = (d["Scl "]?.double ?? 100) / 100
        offset = CGPoint(x: (d["Ofst"]?["Hrzn"]?.double ?? 0) / 100, y: (d["Ofst"]?["Vrtc"]?.double ?? 0) / 100)
        aligned = d["Algn"]?.bool ?? true
        opacity = (d["Opct"]?.double ?? 100) / 100
    }

    /// As Bezzle's gradient across `frame`, laid out on `box` as Photoshop lays it, both in the document.
    func gradient(box: CGRect, in frame: CGRect) -> Gradient {
        let theta = angle * .pi / 180
        let c = CGPoint(x: box.midX + offset.x * box.width, y: box.midY + offset.y * box.height)
        let d = CGPoint(x: cos(theta), y: -sin(theta))
        func unit(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - frame.minX) / max(frame.width, 1), y: (p.y - frame.minY) / max(frame.height, 1))
        }
        var stops = self.stops
        if reversed { stops = stops.reversed().map { GradientStop(offset: 1 - $0.offset, color: $0.color) } }
        switch style {
        case "Rdl ", "Dmnd", "Angl":
            let radius = hypot(box.width, box.height) / 2 * scale
            return Gradient(kind: .radial, stops: stops, start: unit(c), end: unit(CGPoint(x: c.x + radius, y: c.y)),
                            radius: radius / max(frame.width, 1), across: unit(CGPoint(x: c.x, y: c.y + radius)))
        default:
            if style == "Rflc" {
                stops = stops.reversed().map { GradientStop(offset: 0.5 - $0.offset / 2, color: $0.color) }
                    + stops.map { GradientStop(offset: 0.5 + $0.offset / 2, color: $0.color) }
            }
            let length = (abs(box.width * d.x) + abs(box.height * d.y)) * scale * (style == "Rflc" ? 2 : 1)
            let a = CGPoint(x: c.x - d.x * length / 2, y: c.y - d.y * length / 2), b = CGPoint(x: c.x + d.x * length / 2, y: c.y + d.y * length / 2)
            return Gradient(kind: .linear, stops: stops, start: unit(a), end: unit(b))
        }
    }
}

// MARK: - The design

nonisolated private struct PSDConverter {
    let file: PhotoshopFile
    let name: String
    /// What was approximated, in the user's language, and how often, for the report.
    var notes: [String: Int] = [:]
    var artboards = 0
    var layers = 0
    /// The pictures made, by their file names in the design, once `encode` has made their files.
    var held: [String: Data] = [:]
    /// The pictures made and not yet written as PNGs, which is done for all of them at once.
    var pending: [(name: String, image: CGImage)] = []
    private var named: Set<String> = []
    /// Told how far it has got, the last tenth for writing the pictures.
    var progress: PhotoshopImporter.Progress?
    private var read = 0
    /// Where what is drawn is kept: the canvas, or the artboard being made.
    private var bounds: CGRect
    /// Colours the groups being made lay over all they hold, the outermost first.
    private var tints: [(color: RGBA, opacity: Double)] = []

    init(file: PhotoshopFile, name: String) {
        self.file = file
        self.name = name
        bounds = CGRect(x: 0, y: 0, width: file.width, height: file.height)
    }

    private mutating func note(_ what: LocalizedStringResource) { notes[String(localized: what), default: 0] += 1 }

    /// A path layer of an outline in the document's pixels.
    private static func pathNode(_ outline: CGPath) -> Node? {
        let data = PathData.string(outline)
        let box = PathData.bounds(data)
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return nil }
        var n = Node(kind: .path, frame: box)
        n.path = data
        n.pathBox = box
        return n
    }

    /// The colour one lying over another comes to.
    private static func over(_ top: RGBA, _ under: RGBA) -> RGBA {
        let a = top.a + under.a * (1 - top.a)
        guard a > 0 else { return RGBA(r: top.r, g: top.g, b: top.b, a: 0) }
        func mix(_ t: Double, _ b: Double) -> Double { (t * top.a + b * under.a * (1 - top.a)) / a }
        return RGBA(r: mix(top.r, under.r), g: mix(top.g, under.g), b: mix(top.b, under.b), a: a)
    }

    /// The layers in the file as a tree, bottom first.
    private indirect enum Item {
        case layer(Int)
        case group(Int, [Item])

        var index: Int {
            switch self {
            case .layer(let i), .group(let i, _): i
            }
        }
    }

    private func tree() -> [Item] {
        var stack: [[Item]] = [[]]
        for (i, r) in file.layers.enumerated() {
            switch r.section {
            case 3:
                stack.append([])
            case 1, 2:
                let children = stack.count > 1 ? stack.removeLast() : []
                stack[stack.count - 1].append(.group(i, children))
            default:
                stack[stack.count - 1].append(.layer(i))
            }
        }
        while stack.count > 1 {
            let rest = stack.removeLast()
            stack[stack.count - 1] += rest
        }
        return stack[0]
    }

    mutating func document() -> BezzleDocument {
        var doc = BezzleDocument()
        let items = tree()
        let canvas = CGRect(x: 0, y: 0, width: file.width, height: file.height)

        // Photoshop's own artboards, each an artboard here, and what lies outside them on the canvas.
        let boards = items.filter { item in
            if case .group(let i, _) = item { return artboardRect(file.layers[i]) != nil }
            return false
        }
        if !boards.isEmpty {
            var loose: [Item] = []
            for item in items {
                guard case .group(let i, let children) = item, let rect = artboardRect(file.layers[i]) else {
                    loose.append(item)
                    continue
                }
                let r = file.layers[i]
                bounds = rect
                var board = Node(kind: .artboard, name: r.name, frame: rect)
                board.fill = Fill(color: artboardColor(r) ?? .white)
                board.hidden = !r.visible
                board.children = convert(children, cut: []).nodes.map { moved($0, by: CGPoint(x: -rect.minX, y: -rect.minY)) }
                artboards += 1
                doc.nodes.append(board)
            }
            bounds = canvas.insetBy(dx: -CGFloat(file.width), dy: -CGFloat(file.height))
            doc.nodes += convert(loose, cut: []).nodes
        } else {
            var board = Node(kind: .artboard, name: name, frame: canvas)
            board.children = convert(items, cut: []).nodes
            artboards += 1
            doc.nodes.append(board)
        }
        if file.layers.isEmpty, let composite = try? file.composite() {
            // A flattened file: its one picture.
            let bmp = Bitmap(x: 0, y: 0, w: composite.width, h: composite.height, rgba: composite.pixels)
            if let picture = picture(bmp, named: name), !doc.nodes.isEmpty { doc.nodes[0].children = [picture] }
        }
        doc.nodes.sort { $0.isArtboard && !$1.isArtboard }
        doc.fitGroups()
        return doc
    }

    private func moved(_ n: Node, by d: CGPoint) -> Node {
        var n = n
        n.frame = n.frame.offsetBy(dx: d.x, dy: d.y)
        return n
    }

    // MARK: Layers one after another

    /// Bezzle's layers for some of Photoshop's, bottom first, and, when `covering`, how much of each
    /// pixel they cover together, for what is clipped to them.
    private mutating func convert(_ items: [Item], cut: [Coverage], covering: Bool = false) -> (nodes: [Node], coverage: Coverage?) {
        var out: [Node] = []
        var covered: Coverage?
        var i = 0
        while i < items.count {
            var j = i + 1
            while j < items.count, file.layers[items[j].index].clipping { j += 1 }
            let base = file.layers[items[i].index]
            let clipped = items[(i + 1)..<j]
            let wanted = !clipped.isEmpty || covering
            let made = item(items[i], cut: cut, covering: wanted)
            out += made.nodes
            if covering, base.visible, let c = made.coverage { covered = covered.map { $0.union(c) } ?? c }
            for item in clipped {
                // Clipped layers show only where the one they are clipped to does, and as faded as it is.
                let into = made.coverage ?? Coverage(x: 0, y: 0, w: 0, h: 0, alpha: [], outside: 0)
                for var n in self.item(item, cut: cut + [into], covering: false).nodes {
                    n.opacity *= Double(base.opacity) / 255
                    if !base.visible { n.hidden = true }
                    out.append(n)
                }
            }
            i = j
        }
        return (out, covered)
    }

    private mutating func item(_ item: Item, cut: [Coverage], covering: Bool) -> (nodes: [Node], coverage: Coverage?) {
        switch item {
        case .layer(let i):
            return layer(file.layers[i], cut: cut, covering: covering)
        case .group(let i, let children):
            let r = file.layers[i]
            var cuts = cut
            if let m = pixelMask(r) { cuts.append(m) }
            let vector = vectorMask(r)
            if let v = vector, !v.disabled, v.outline == nil, let c = Coverage.of(v, in: bounds) {
                cuts.append(c)
                note("Vector masks on groups drawn into the pictures they hold")
            }
            var fx = effects(r)
            // A colour laid over a group is laid over each of its layers, which looks the same.
            let tinted = fx.overlay != nil
            if let o = fx.overlay {
                tints.append(o)
                fx.overlay = nil
            }
            let made = convert(children, cut: cuts, covering: covering)
            if tinted { tints.removeLast() }
            var g = Node(kind: .group, name: r.name, frame: .zero)
            g.children = made.nodes
            g.hidden = !r.visible
            g.opacity = Double(r.opacity) / 255
            if let key = r.sectionBlend { g.blend = blend(key) }
            if let v = vector, !v.disabled, let outline = v.outline, !g.children.isEmpty {
                g = masked(g, by: outline)
            }
            if fx.any { note("Layer styles on groups left out") }
            layers += 1
            return ([g], made.coverage)
        }
    }

    /// A group cut off at an outline, as Bezzle's masks are, the outline itself clear.
    private mutating func masked(_ group: Node, by outline: CGPath, evenOdd: Bool = false) -> Node {
        guard var holder = Self.pathNode(outline) else { return group }
        if evenOdd { holder.evenOdd = true }
        holder.name = String(localized: "Mask")
        // Clear: it only cuts.
        holder.fill = Fill(on: false, color: .shape)
        holder.borders = []
        holder.shadows = []
        var g = group
        g.children.insert(holder, at: 0)
        g.clipsToFirst = true
        return g
    }

    // MARK: One layer

    private static let adjustments: Set<String> = ["levl", "curv", "brit", "blnc", "blwh", "hue ", "hue2", "selc", "mixr", "grdm", "phfl",
                                                   "expA", "vibA", "thrs", "post", "nvrt", "clrL", "CgEd"]

    private mutating func layer(_ r: PhotoshopFile.Layer, cut: [Coverage], covering: Bool) -> (nodes: [Node], coverage: Coverage?) {
        if let progress {
            read += 1
            progress(0.9 * Double(read) / Double(max(file.layers.count { $0.section == 0 }, 1)), r.name)
        }
        if r.blocks.keys.contains(where: Self.adjustments.contains) {
            note("Adjustment layers left out")
            return ([], nil)
        }
        if r.blocks["SoLd"] != nil || r.blocks["SoLE"] != nil || r.blocks["PlLd"] != nil,
           let made = smartObject(r, cut: cut, covering: covering) {
            return made
        }
        if r.blocks["SoCo"] != nil || r.blocks["GdFl"] != nil, cut.isEmpty, pixelMask(r) == nil, let made = shape(r, covering: covering) {
            return made
        }
        if r.blocks["TySh"] != nil { note("Text came in as pictures of its letters") }
        if r.blocks["PtFl"] != nil, r.channels.allSatisfy({ $0.range.count <= 2 }) {
            note("Pattern fills left out")
            return ([], nil)
        }
        return pixels(r, cut: cut, covering: covering)
    }

    /// A layer as the picture of its own pixels, cut by its masks and whatever it lies in.
    private mutating func pixels(_ r: PhotoshopFile.Layer, cut: [Coverage], covering: Bool) -> (nodes: [Node], coverage: Coverage?) {
        guard var bmp = bitmap(r) else { return ([], nil) }
        if let m = pixelMask(r) { bmp.cut(by: m) }
        if let v = vectorMask(r), !v.disabled, let c = Coverage.of(v, in: bmp.rect) { bmp.cut(by: c) }
        for c in cut { bmp.cut(by: c) }
        let coverage = covering ? bmp.coverage : nil
        let fx = effects(r)
        if let g = fx.gradient {
            let box = g.aligned ? r.rect : CGRect(x: 0, y: 0, width: file.width, height: file.height)
            bmp.overlay(g.gradient(box: box, in: box), box: box, opacity: g.opacity)
        }
        if let o = fx.overlay { bmp.overlay(o.color, opacity: o.opacity) }
        for t in tints.reversed() { bmp.overlay(t.color, opacity: t.opacity) }
        if let fill = fillOpacity(r) { bmp.fade(fill) }
        if let stroke = fx.stroke { bmp = bmp.stroked(stroke) }
        guard let trimmed = bmp.trimmed(to: bounds), var n = picture(trimmed, named: r.name) else { return ([], coverage) }
        look(&n, r, fx, outlined: false)
        layers += 1
        return ([n], coverage)
    }

    /// The layer's own pixels as the file keeps them, or a fill layer's colour where it has none.
    private mutating func bitmap(_ r: PhotoshopFile.Layer) -> Bitmap? {
        // A fill layer with nothing of its own fills all the canvas.
        let filling = r.blocks["SoCo"] != nil || r.blocks["GdFl"] != nil
        let canvas = CGRect(x: 0, y: 0, width: file.width, height: file.height)
        let rect = filling && (r.width == 0 || r.height == 0) ? canvas : r.rect
        var r = r
        (r.left, r.top, r.right, r.bottom) = (Int(rect.minX), Int(rect.minY), Int(rect.maxX), Int(rect.maxY))
        let w = r.width, h = r.height
        guard w > 0, h > 0, w * h < 400_000_000 else { return nil }
        do {
            var planes: [[UInt8]] = []
            var stored = false
            for k in 0..<file.colorChannels {
                if let ch = r.channel(k), ch.count > 2 {
                    planes.append(try file.samples(ch, width: w, height: h, color: true))
                    stored = true
                } else {
                    planes.append([UInt8](repeating: 0, count: w * h))
                }
            }
            // A fill layer keeps its channels empty: solid all over.
            let alpha = try r.channel(-1).flatMap { $0.count > 2 ? try file.samples($0, width: w, height: h, color: false) : nil }
            var rgba = file.rgba(planes, alpha: alpha, width: w, height: h)
            if !stored, let color = solidColor(r) {
                let cr = UInt8((color.r * 255).rounded()), cg = UInt8((color.g * 255).rounded()), cb = UInt8((color.b * 255).rounded())
                rgba.withUnsafeMutableBufferPointer { p in
                    var i = 0
                    while i < p.count { p[i] = cr; p[i + 1] = cg; p[i + 2] = cb; i += 4 }
                }
            }
            var bmp = Bitmap(x: r.left, y: r.top, w: w, h: h, rgba: rgba)
            if !stored, let g = file.descriptor("GdFl", in: r).flatMap(PSGradient.init) {
                let box = g.aligned ? rect : canvas
                bmp.overlay(g.gradient(box: box, in: box), box: box, opacity: 1)
            }
            return bmp
        } catch {
            note("Layers that could not be read")
            return nil
        }
    }

    /// A picture layer showing `bmp` where it lies.
    private mutating func picture(_ bmp: Bitmap, named: String) -> Node? {
        guard let image = bmp.image(in: file.space), let (asset, _) = keep(image) else { return nil }
        var n = Node(kind: .rectangle, name: named, frame: bmp.rect)
        n.fill = Fill(on: true, color: .shape, image: ImageFill(asset: asset, mode: .stretch, size: CGSize(width: bmp.w, height: bmp.h)))
        return n
    }

    /// Keeps a picture with the design, named by what is in it, and says its name and size. Its
    /// PNG is made by `encode`, with all the others at once.
    private mutating func keep(_ image: CGImage) -> (String, CGSize)? {
        guard let pixels = image.dataProvider?.data as Data? else { return nil }
        var hasher = SHA256()
        hasher.update(data: pixels)
        hasher.update(data: Data("\(image.width)x\(image.height)x\(image.bitsPerPixel)".utf8))
        let asset = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        if named.insert(asset).inserted { pending.append((asset, image)) }
        return (asset, CGSize(width: image.width, height: image.height))
    }

    /// Writes every picture kept as a PNG, as many at once as the Mac has cores for.
    mutating func encode() {
        let work = pending
        guard !work.isEmpty else { return }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var files: [String: Data] = [:]
            var done = 0
        }
        let results = Results(), progress = progress, total = Double(work.count)
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let (asset, image) = work[i]
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return }
            results.lock.lock()
            results.files[asset] = data as Data
            results.done += 1
            let done = Double(results.done)
            results.lock.unlock()
            progress?(0.9 + 0.1 * done / total, "")
        }
        held.merge(results.files) { $1 }
        pending = []
    }

    /// How the layer looks besides its pixels: hidden, faded, mixed, its shadows and border.
    private mutating func look(_ n: inout Node, _ r: PhotoshopFile.Layer, _ fx: Effects, outlined: Bool) {
        n.hidden = !r.visible
        n.opacity = Double(r.opacity) / 255
        n.blend = blend(r.blend)
        if !fx.shadows.isEmpty { n.shadows = fx.shadows }
        if outlined, let stroke = fx.stroke { n.borders = [stroke] }
        for kind in fx.missing { note(kind) }
    }

    // MARK: Shapes and fills

    /// A fill layer of one colour, as a shape: its vector mask's outline, or all the canvas.
    private mutating func shape(_ r: PhotoshopFile.Layer, covering: Bool) -> (nodes: [Node], coverage: Coverage?)? {
        let filling = file.descriptor("GdFl", in: r).flatMap(PSGradient.init)
        guard let color = solidColor(r) ?? filling?.stops.first?.color else { return nil }
        let vector = vectorMask(r).flatMap { $0.disabled ? nil : $0 }
        var n: Node
        if let vector {
            guard let outline = vector.outline, var path = Self.pathNode(outline) else { return nil }
            path.name = r.name
            n = path
        } else {
            let rect = r.width > 0 && r.height > 0 ? r.rect.intersection(bounds) : bounds
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
            n = Node(kind: .rectangle, name: r.name, frame: rect)
        }
        let canvas = CGRect(x: 0, y: 0, width: file.width, height: file.height)
        var fill = Fill(color: color)
        if let filling {
            fill.gradient = filling.gradient(box: filling.aligned ? n.frame : canvas, in: n.frame)
        }
        let fx = effects(r)
        if let g = fx.gradient {
            // Laid over one colour, a gradient comes to a gradient of its own.
            var over = g.gradient(box: g.aligned ? n.frame : canvas, in: n.frame)
            if fill.gradient == nil {
                over.stops = over.stops.map { s in
                    var top = s.color
                    top.a *= g.opacity
                    return GradientStop(offset: s.offset, color: Self.over(top, color))
                }
            }
            fill.gradient = over
        }
        if let k = fillOpacity(r) {
            fill.color.a *= k
            if fill.gradient != nil { for i in fill.gradient!.stops.indices { fill.gradient!.stops[i].color.a *= k } }
        }
        // A colour laid over it, over its gradient too.
        func tinted(_ c: RGBA, _ o: (color: RGBA, opacity: Double)) -> RGBA {
            let k = o.opacity
            return RGBA(r: c.r + (o.color.r - c.r) * k, g: c.g + (o.color.g - c.g) * k, b: c.b + (o.color.b - c.b) * k, a: c.a)
        }
        for o in [fx.overlay].compactMap({ $0 }) + tints.reversed() {
            fill.color = tinted(fill.color, o)
            if fill.gradient != nil { for i in fill.gradient!.stops.indices { fill.gradient!.stops[i].color = tinted(fill.gradient!.stops[i].color, o) } }
        }
        n.fill = fill
        look(&n, r, fx, outlined: true)
        if let stroke = vectorStroke(r) {
            n.borders = [stroke.border]
            if !stroke.filled { n.fill.on = false }
        }
        layers += 1
        var coverage: Coverage?
        if covering {
            if let vector { coverage = Coverage.of(vector, in: vector.bounds.intersection(bounds).insetBy(dx: -1, dy: -1)) }
            else { coverage = Coverage(x: Int(n.frame.minX), y: Int(n.frame.minY), w: Int(n.frame.width), h: Int(n.frame.height),
                                       alpha: [UInt8](repeating: 255, count: Int(n.frame.width) * Int(n.frame.height)), outside: 0) }
        }
        return ([n], coverage)
    }

    private func solidColor(_ r: PhotoshopFile.Layer) -> RGBA? {
        file.descriptor("SoCo", in: r)?["Clr "]?.color
    }

    /// A shape layer's own stroke, and whether it is filled inside.
    private func vectorStroke(_ r: PhotoshopFile.Layer) -> (border: Border, filled: Bool)? {
        guard let d = file.descriptor("vstk", in: r) else { return nil }
        let filled = d["fillEnabled"]?.bool ?? true
        guard d["strokeEnabled"]?.bool == true, let width = d["strokeStyleLineWidth"]?.double, width > 0 else {
            return filled ? nil : (Border(), false)
        }
        var b = Border(on: true, color: d["strokeStyleContent"]?["Clr "]?.color ?? .black, width: width)
        b.color.a = (d["strokeStyleOpacity"]?.double ?? 100) / 100
        switch d["strokeStyleLineAlignment"]?.choice {
        case "strokeStyleAlignCenter": b.position = .center
        case "strokeStyleAlignOutside": b.position = .outside
        default: b.position = .inside
        }
        return (b, filled)
    }

    // MARK: Smart objects

    /// A smart object as the picture it holds, pinned by its corners where it shows, so that
    /// something else can be put into it. Nil when it is drawn as its pixels instead.
    private mutating func smartObject(_ r: PhotoshopFile.Layer, cut: [Coverage], covering: Bool) -> (nodes: [Node], coverage: Coverage?)? {
        guard let d = file.descriptor("SoLd", in: r, skipping: 12) ?? file.descriptor("SoLE", in: r, skipping: 12) else { return nil }
        let numbers = (d["nonAffineTransform"]?.doubles).flatMap { $0.count == 8 ? $0 : nil } ?? d["Trnf"]?.doubles ?? []
        guard numbers.count == 8 else { return nil }
        let quad = stride(from: 0, to: 8, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
        if warped(d) {
            note("Warped smart objects came in as pictures")
            return nil
        }
        // Masked, or clipped to the layer under it, it is cut off at the outline of what shows,
        // so that it stays a screen a picture can go into.
        var outlines: [CGPath] = []
        for c in cut + [pixelMask(r)].compactMap({ $0 }) {
            guard let outline = c.outline() else {
                note("Smart objects that are masked or clipped came in as pictures")
                return nil
            }
            outlines.append(outline)
        }
        let size = d["Sz  "].flatMap { s -> CGSize? in
            guard let w = s["Wdth"]?.double, let h = s["Hght"]?.double, w > 0, h > 0 else { return nil }
            return CGSize(width: w, height: h)
        }
        let shown = shownSize(of: quad)
        guard let id = d["Idnt"]?.text, let linked = file.linked[id],
              var content = contents(of: linked, size: size, shown: shown) else {
            // Square to the page, its own pixels are the picture it shows, and look no different.
            if !Self.square(quad) { note("Smart objects that could not be opened came in as pictures") }
            return nil
        }
        let fx = effects(r)
        let overlays = [fx.overlay].compactMap { $0 } + tints.reversed()
        if !overlays.isEmpty || fx.gradient != nil, var bmp = Bitmap(content) {
            if let g = fx.gradient { bmp.overlay(g.gradient(box: bmp.rect, in: bmp.rect), box: bmp.rect, opacity: g.opacity) }
            for o in overlays { bmp.overlay(o.color, opacity: o.opacity) }
            if let image = bmp.image(in: CGColorSpace(name: CGColorSpace.sRGB)!) { content = image }
        }
        if let fill = fillOpacity(r), var bmp = Bitmap(content) {
            bmp.fade(fill)
            if let image = bmp.image(in: CGColorSpace(name: CGColorSpace.sRGB)!) { content = image }
        }
        guard let (asset, pixels) = keep(content) else { return nil }
        let aspect = size.map { $0.width / $0.height } ?? pixels.width / max(pixels.height, 1)
        var n = Node(kind: .rectangle, name: r.name, frame: .zero)
        n.screen = true
        Self.pin(&n, to: quad, aspect: aspect)
        n.fill = Fill(on: true, color: .shape, image: ImageFill(asset: asset, mode: .stretch, size: pixels))
        look(&n, r, fx, outlined: true)
        layers += 1
        if let v = vectorMask(r), !v.disabled {
            if let outline = v.outline { outlines.append(outline) } else { note("Vector masks Bezzle cannot cut by, left out") }
        }
        // Each outline a mask round the one inside it.
        var nodes = [n]
        for outline in outlines {
            var g = Node(kind: .group, name: r.name, frame: .zero)
            g.children = nodes
            nodes = [masked(g, by: outline, evenOdd: true)]
        }
        var coverage: Coverage?
        if covering, var own = bitmap(r) {
            if let v = vectorMask(r), !v.disabled, let c = Coverage.of(v, in: own.rect) { own.cut(by: c) }
            coverage = own.coverage
        }
        return (nodes, coverage)
    }

    /// Whether a smart object is bent by a warp, rather than only pinned by its corners.
    private func warped(_ d: PSDValue) -> Bool {
        guard let warp = d["warp"], let style = warp["warpStyle"]?.choice, style != "warpNone" else { return false }
        if style == "warpCustom" {
            // A custom warp left as it was made is none.
            guard let mesh = warp["customEnvelopeWarp"]?["meshPoints"] else { return true }
            let h = mesh["Hrzn"]?.doubles ?? [], v = mesh["Vrtc"]?.doubles ?? []
            guard h.count == 16, v.count == 16 else { return true }
            let left = h[0], right = h[3], top = v[0], bottom = v[12]
            for row in 0..<4 {
                for col in 0..<4 {
                    let x = left + (right - left) * Double(col) / 3, y = top + (bottom - top) * Double(row) / 3
                    if abs(h[row * 4 + col] - x) > 0.5 || abs(v[row * 4 + col] - y) > 0.5 { return true }
                }
            }
            return false
        }
        return (warp["warpValue"]?.double ?? 0) != 0 || (warp["warpPerspective"]?.double ?? 0) != 0 || (warp["warpPerspectiveOther"]?.double ?? 0) != 0
    }

    /// How big a quadrilateral shows, at its widest and tallest.
    private func shownSize(of q: [CGPoint]) -> CGSize {
        CGSize(width: max(hypot(q[1].x - q[0].x, q[1].y - q[0].y), hypot(q[2].x - q[3].x, q[2].y - q[3].y)),
               height: max(hypot(q[3].x - q[0].x, q[3].y - q[0].y), hypot(q[2].x - q[1].x, q[2].y - q[1].y)))
    }

    private static func square(_ q: [CGPoint]) -> Bool {
        abs(q[0].y - q[1].y) < 0.5 && abs(q[2].y - q[3].y) < 0.5 && abs(q[0].x - q[3].x) < 0.5 && abs(q[1].x - q[2].x) < 0.5
    }

    /// Lays a layer where a quadrilateral is, top left, top right, bottom right, bottom left: a
    /// frame as big as it, as wide for its height as the picture, and its corners pinned to the
    /// quadrilateral's. One that is a rectangle in the page lies there as it is.
    static func pin(_ n: inout Node, to q: [CGPoint], aspect: CGFloat) {
        let center = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        // As much area as the quadrilateral, by the shoelace.
        var area: CGFloat = 0
        for i in 0..<4 { area += q[i].x * q[(i + 1) % 4].y - q[(i + 1) % 4].x * q[i].y }
        area = max(abs(area) / 2, 1)
        let h = sqrt(area / max(aspect, 0.0001)), w = h * aspect
        var frame = CGRect(center: center, size: CGSize(width: w, height: h))
        if square(q) {
            frame = CGRect(x: min(q[0].x, q[1].x), y: min(q[0].y, q[3].y), width: abs(q[1].x - q[0].x), height: abs(q[3].y - q[0].y))
            n.frame = frame
            // Turned over, as a reflection under a device is.
            if q[1].x < q[0].x { n.fill = n.fill.flipped(horizontally: true) }
            if q[3].y < q[0].y { n.fill = n.fill.flipped(horizontally: false) }
            return
        }
        n.frame = frame
        var t = Transform3D()
        t.corners = q.map { CGPoint(x: (($0.x - frame.minX) / frame.width * 10_000).rounded() / 10_000,
                                    y: (($0.y - frame.minY) / frame.height * 10_000).rounded() / 10_000) }
        n.transform3D = t
    }

    /// What a smart object holds, as a picture, made big enough for where it shows.
    private mutating func contents(of linked: PhotoshopFile.Linked, size: CGSize?, shown: CGSize) -> CGImage? {
        let data = file.bytes(linked.range)
        guard data.count > 4 else { return nil }
        let head = [UInt8](data.prefix(4))
        if head == [0x38, 0x42, 0x50, 0x53] {
            // Another Photoshop document, as most are.
            guard let inner = try? PhotoshopFile(data: Data(data)) else { return nil }
            return Self.picture(of: inner, name: linked.name)
        }
        if head == [0x25, 0x50, 0x44, 0x46] || linked.type.hasPrefix("PDF") || linked.name.lowercased().hasSuffix(".ai") {
            return pdfPicture(data, size: size, shown: shown)
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        if linked.name.lowercased().hasSuffix(".svg"), let image = NSImage(data: data), image.size.width > 0 {
            let scale = max(1, max(shown.width / image.size.width, shown.height / image.size.height) * 2)
            var rect = CGRect(origin: .zero, size: CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded()))
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// A Photoshop document held in another, as a picture: the one it keeps of all of it, or,
    /// saved without one, as smart objects' contents mostly are, its layers drawn as Bezzle draws them.
    private static func picture(of inner: PhotoshopFile, name: String) -> CGImage? {
        // Kept flat on white, it is no picture of a see-through document, which Photoshop draws from its layers too.
        let flattened = !inner.hasBackground && !inner.compositeShowsTransparency && !inner.layers.isEmpty
        if !flattened, let composite = try? inner.composite() {
            let bmp = Bitmap(x: 0, y: 0, w: composite.width, h: composite.height, rgba: composite.pixels)
            return bmp.image(in: inner.space)
        }
        guard !inner.layers.isEmpty else { return nil }
        var converter = PSDConverter(file: inner, name: name)
        let doc = converter.document()
        guard var board = doc.artboards.first else { return nil }
        // See-through where nothing is drawn: an artboard with no fill would be drawn on white.
        board.fill = Fill(on: true, color: RGBA(r: 1, g: 1, b: 1, a: 0))
        let assets = Assets(folder: nil)
        // Drawn from the pictures as they are, which need no files: only this picture is kept.
        for (asset, image) in converter.pending { assets.standIn(asset, image) }
        let scale = min(1, 4096 / max(board.frame.width, board.frame.height, 1))
        return Renderer.image(of: board, scale: scale, opaque: false, assets: assets)
    }

    /// The first page of a PDF, or of an Illustrator file that keeps one, drawn at twice the size it shows.
    private func pdfPicture(_ data: Data, size: CGSize?, shown: CGSize) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(max(shown.width / box.width, shown.height / box.height, 1) * 2, 8000 / max(box.width, box.height))
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Masks

    /// The mask painted by hand, when there is one that is on.
    private func pixelMask(_ r: PhotoshopFile.Layer) -> Coverage? {
        let vector = r.blocks["vmsk"] != nil || r.blocks["vsms"] != nil
        var found: (PhotoshopFile.Mask, Range<Int>)?
        if let m = r.realMask, let ch = r.channel(-3) { found = (m, ch) }
        else if let m = r.mask, let ch = r.channel(-2), !(vector && m.fromVector) { found = (m, ch) }
        guard let (m, ch) = found, !m.disabled else { return nil }
        guard m.width > 0, m.height > 0 else { return m.color == 255 ? nil : Coverage(x: 0, y: 0, w: 0, h: 0, alpha: [], outside: 0) }
        guard let alpha = try? file.samples(ch, width: m.width, height: m.height, color: false) else { return nil }
        // A mask that hides nothing is none.
        if m.color == 255, !alpha.contains(where: { $0 != 255 }) { return nil }
        return Coverage(x: m.left, y: m.top, w: m.width, h: m.height, alpha: alpha, outside: m.color)
    }

    private func vectorMask(_ r: PhotoshopFile.Layer) -> VectorPath? {
        guard let range = r.blocks["vmsk"] ?? r.blocks["vsms"] else { return nil }
        return VectorPath(file.bytes(range), width: file.width, height: file.height)
    }

    private func fillOpacity(_ r: PhotoshopFile.Layer) -> Double? {
        guard let range = r.blocks["iOpa"], !range.isEmpty else { return nil }
        let v = Double(file.bytes(range).first ?? 255) / 255
        return v < 1 ? v : nil
    }

    // MARK: Looks

    private func blend(_ key: String) -> BlendMode? {
        switch key {
        case "mul ": .multiply
        case "scrn": .screen
        case "over": .overlay
        case "dark", "dkCl": .darken
        case "lite", "lgCl": .lighten
        case "div ", "fdiv": .colorDodge
        case "idiv": .colorBurn
        case "lbrn": .plusDarker
        case "lddg": .plusLighter
        case "hLit", "vLit", "lLit", "pLit", "hMix": .hardLight
        case "sLit": .softLight
        case "diff", "fsub": .difference
        case "smud": .exclusion
        case "hue ": .hue
        case "sat ": .saturation
        case "colr": .color
        case "lum ": .luminosity
        default: nil
        }
    }

    /// A layer's style, as far as Bezzle has it.
    private struct Effects {
        var shadows: [Shadow] = []
        var overlay: (color: RGBA, opacity: Double)?
        var gradient: PSGradient?
        var stroke: Border?
        /// What it has that Bezzle has nothing for, as notes for the report.
        var missing: [LocalizedStringResource] = []

        var any: Bool { !shadows.isEmpty || overlay != nil || gradient != nil || stroke != nil || !missing.isEmpty }
    }

    private func effects(_ r: PhotoshopFile.Layer) -> Effects {
        var fx = Effects()
        // Photoshop keeps a layer's style under one of three names, by version and how many of each effect it has.
        guard let d = ["lfx2", "lfxs", "lmfx"].lazy.compactMap({ file.descriptor($0, in: r, skipping: 8) }).first,
              d["masterFXSwitch"]?.bool != false else { return fx }
        let scale = (d["Scl "]?.double ?? 100) / 100
        func all(_ one: String, _ many: String) -> [PSDValue] {
            (d[many]?.items ?? d[one].map { [$0] } ?? []).filter { $0["enab"]?.bool != false }
        }
        for (e, inner) in all("DrSh", "dropShadowMulti").map({ ($0, false) }) + all("IrSh", "innerShadowMulti").map({ ($0, true) }) {
            let angle = (e["uglg"]?.bool ?? true ? file.globalAngle : e["lagl"]?.double ?? 120) * .pi / 180
            let distance = (e["Dstn"]?.double ?? 5) * scale, size = (e["blur"]?.double ?? 5) * scale
            let spread = min(max((e["Ckmt"]?.double ?? 0) / 100, 0), 1)
            var color = e["Clr "]?.color ?? .black
            color.a = (e["Opct"]?.double ?? 75) / 100
            fx.shadows.append(Shadow(on: true, color: color, x: CGFloat(-cos(angle) * distance), y: CGFloat(sin(angle) * distance),
                                     blur: CGFloat(size * (1 - spread)), inset: inner ? true : nil,
                                     spread: spread > 0 ? CGFloat(size * spread) : nil))
        }
        if let e = all("SoFi", "solidFillMulti").last, let color = e["Clr "]?.color {
            fx.overlay = (color, (e["Opct"]?.double ?? 100) / 100)
        }
        if let e = all("FrFX", "frameFXMulti").last, e["PntT"]?.choice ?? "SClr" == "SClr", let width = e["Sz  "]?.double {
            var b = Border(on: true, color: e["Clr "]?.color ?? .black, width: CGFloat(width * scale))
            b.color.a = (e["Opct"]?.double ?? 100) / 100
            switch e["Styl"]?.choice {
            case "InsF": b.position = .inside
            case "CtrF": b.position = .center
            default: b.position = .outside
            }
            fx.stroke = b
        }
        if !all("OrGl", "outerGlowMulti").isEmpty || !all("IrGl", "innerGlowMulti").isEmpty { fx.missing.append("Glows left out") }
        if let e = all("GrFl", "gradientFillMulti").last {
            if let g = PSGradient(e) { fx.gradient = g } else { fx.missing.append("Noise gradients left out") }
        }
        if !all("patternFill", "patternFillMulti").isEmpty { fx.missing.append("Pattern overlays left out") }
        if !all("ebbl", "bevelEmbossMulti").isEmpty || !all("ChFX", "satinMulti").isEmpty { fx.missing.append("Bevels and satins left out") }
        return fx
    }

    // MARK: Artboards

    private func artboardRect(_ r: PhotoshopFile.Layer) -> CGRect? {
        guard let d = file.descriptor("artb", in: r) ?? file.descriptor("artd", in: r) ?? file.descriptor("abdd", in: r),
              let rect = d["artboardRect"], let top = rect["Top "]?.double, let left = rect["Left"]?.double,
              let bottom = rect["Btom"]?.double, let right = rect["Rght"]?.double, right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func artboardColor(_ r: PhotoshopFile.Layer) -> RGBA? {
        guard let d = file.descriptor("artb", in: r) ?? file.descriptor("artd", in: r) ?? file.descriptor("abdd", in: r) else { return nil }
        // 1 white, 2 black, 3 transparent, 4 other.
        switch d["artboardBackgroundType"]?.double {
        case 2: return .black
        case 4: return d["Clr "]?.color
        default: return .white
        }
    }
}
