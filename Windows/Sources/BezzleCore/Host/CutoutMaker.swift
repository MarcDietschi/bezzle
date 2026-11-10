import Foundation
import CBezzleHost

// From Bezzle/Canvas/CutoutMaker.swift, as Windows cuts a picture out: the Mac's way with the
// learned matte, number for number (the matte kept to the subject and fading out just past it,
// specks left out, the background's colour taken out of the see-through edge, the edge drawn at
// the picture's own size), and the same outlines traced. What differs is how the subject is found:
// the Mac asks Apple's Vision, which Windows lacks, what stands out and where each person is; here
// the matte itself says, by its own regions, each apart from the others (`Scene`). So people who
// touch are one part to keep or drop where the Mac's Vision tells them apart, and whatever the
// matte keeps beside the subject stays unless it is dropped. Without the matte there is no older
// way to fall back on (the Mac's guided filter round Vision's subject): Remove Background needs it.
// So the steps come in another order too: the Mac knows roughly where the subject is before the
// matte is made (`look`), Windows once it is (`finish` begins with it found).
//
// Keep this in step with the Mac's file: a change to the steps there is made here.

/// Takes the background away from a picture, leaving its subject as if it had been shot on
/// nothing: hair strand by strand, and no trace of the old background's colour round the edge.
///
/// 1. The learned matte (`SubjectMatte`, BiRefNet) says how solid each pixel is.
/// 2. Its regions are what stands out; all of them, or those picked, are the subject, and the
///    matte is kept to them, fading out just past their outline.
/// 3. The background's colour is taken out of the see-through edge (Forte & Pitié's blur fusion),
///    so the cutout shows no fringe over whatever it is put on.
///
/// The work is done with the picture at about 2,000 pixels across; the edge is then drawn at the
/// picture's own size, from the photo's own pixels, so nothing is lost of a large one.
nonisolated enum CutoutMaker {
    /// What stands out in a picture, as a learned matte has it.
    protocol Matting: Sendable {
        /// 0…1 a pixel, at any size, of the picture as it is worked on.
        func matte(of picture: Pixels) throws -> Plane
    }

    enum Failure: Swift.Error, Equatable {
        /// The picture could not be read.
        case unreadable
        /// Nothing in it stands out from the rest.
        case noSubject
        /// Nothing stands out where it was picked.
        case nothingPicked
    }

    /// How the work is done. The defaults are the Mac's.
    struct Tuning {
        /// The longest side the picture is worked on at.
        var workSide = 2048
        /// How far past the subject's outline a learned matte fades out, as a share of the longer side.
        var matteReach = 0.02
    }

    /// A step of a cut beginning, told as it does. See `CutoutPace`.
    struct Progress: @unchecked Sendable {
        var step: CutoutPace.Step
        /// How many seconds steps from here on are expected to take, where that is known better now.
        var expecting: [CutoutPace.Step: Double] = [:]
        /// Once what stands out has been found, where it is: 0…1 a pixel, 1 on the subject, as
        /// large as the work is done at.
        var found: Plane?
        /// When it was told, on the clock animations run by.
        var at = WindowsCore.now
    }

    /// `picture` with only its subjects left: the parts at `picks`, 0…1 across and down it from
    /// its top left, or everything that stands out. As large as the picture, its edges soft where
    /// they were in the photo, its colours multiplied by how solid it is. `told` hears how it is going.
    static func cut(_ picture: Pixels, picks: [CGPoint]? = nil, matting: any Matting, tuning: Tuning = Tuning(),
                    told: (Progress) -> Void = { _ in }) throws -> Pixels {
        let w = picture.w, h = picture.h
        guard w > 0, h > 0, picture.bytes.count >= w * h * 4 else { throw Failure.unreadable }
        let shrink = min(1, Double(tuning.workSide) / Double(max(w, h)))
        let ww = max(1, Int((Double(w) * shrink).rounded())), wh = max(1, Int((Double(h) * shrink).rounded()))
        guard let work = shrink < 1 ? picture.scaled(ww, wh) : picture else { throw Failure.unreadable }
        let seen = work.overWhite()
        let long = max(ww, wh)
        let photo = seen.planes()

        // How solid each pixel is, as the learned matte has it (which tells of loading the model
        // and of making the matte itself, `SubjectModel`), and what stands out in it.
        let learned = try matting.matte(of: seen)
        let finishing = Progress(step: .finish)
        told(finishing)
        let matte = learned.w == ww && learned.h == wh ? learned : resample(learned, ww, wh)
        let smallest = ww * wh / 2000
        let scene = Scene(matte, smallest: smallest)
        guard !scene.sizes.isEmpty else { throw Failure.noSubject }
        let subject: Plane
        if let picks, !picks.isEmpty {
            let kept = Set(picks.compactMap { scene.part(at: $0) })
            guard !kept.isEmpty else { throw Failure.nothingPicked }
            subject = scene.mask(of: kept)
        } else {
            subject = scene.mask(of: Set(scene.sizes.indices))
        }
        // Told as of the step it belongs to, which began a moment ago.
        told(Progress(step: .finish, found: subject, at: finishing.at))

        // Only what was picked: the matte fades out past the subject's outline, gone `matteReach`
        // past it, so whatever else stands out stays behind.
        let near = boxMean(subject, max(1, Int(Double(long) * tuning.matteReach)))
        let alpha = withoutSpecks(zip2(matte, near) { a, n in min(max(a, 0), 1) * min(1, n * 2) }, smallest: smallest)
        let colours = foreground(photo, alpha, long: long)
        let shift = (0..<3).map { k in zip2(colours[k], photo[k]) { $0 - $1 } }

        // At the picture's own size: the learned matte spread out, the colours shifted as they were
        // worked out, multiplied out as the picture is kept.
        var out = picture
        let seeThrough = picture.alpha
        withExtendedLifetime((alpha, shift)) {
            let soft = alpha.grid
            let dr = shift[0].grid, dg = shift[1].grid, db = shift[2].grid
            out.bytes.withUnsafeMutableBufferPointer { px in
                par(h) { rows in
                    for y in rows {
                        let sy = sample(y, h, wh)
                        for x in 0..<w {
                            let i = (y * w + x) * 4
                            // The photo's own colours over white where it was see-through, as the Mac draws it.
                            let a0 = Float(px[i + 3]), white = 255 - a0
                            let r = (Float(px[i]) + white) / 255, g = (Float(px[i + 1]) + white) / 255, b = (Float(px[i + 2]) + white) / 255
                            let sx = sample(x, w, ww)
                            var a = min(max(soft.at(sx, sy), 0), 1)
                            if seeThrough != nil { a *= a0 / 255 }
                            let fr = min(max(r + dr.at(sx, sy), 0), 1), fg = min(max(g + dg.at(sx, sy), 0), 1)
                            let fb = min(max(b + db.at(sx, sy), 0), 1)
                            px[i] = UInt8(fr * a * 255 + 0.5)
                            px[i + 1] = UInt8(fg * a * 255 + 0.5)
                            px[i + 2] = UInt8(fb * a * 255 + 0.5)
                            px[i + 3] = UInt8(a * 255 + 0.5)
                        }
                    }
                }
            }
        }
        return out
    }

    /// Round what is at least half solid in a picture with see-through parts: SVG path data across
    /// and down it from 0 to 1, filled even-odd. See `Cutout.outline`.
    static func outline(of image: Pixels) -> String {
        let alpha = Plane(image.w, image.h)
        image.bytes.withUnsafeBufferPointer { px in
            for i in 0..<alpha.count { alpha.p[i] = Float(px[i * 4 + 3]) / 255 }
        }
        return pathData(trace(alpha, side: 800))
    }

    /// The parts of a picture a click keeps or drops, as `cut` takes picks, from its matte at the
    /// size the picture is worked on (`ww` × `wh`): the matte's regions, each apart from the others.
    static func subjects(of matte: Plane, _ ww: Int, _ wh: Int) -> Subjects {
        // At about 1,024 pixels, as the Mac finds them.
        let shrink = min(1, 1024 / Double(max(ww, wh)))
        let w = max(1, Int((Double(ww) * shrink).rounded())), h = max(1, Int((Double(wh) * shrink).rounded()))
        let small = resample(matte, w, h)
        let scene = Scene(small, smallest: w * h / 2000)
        let reach = max(1, max(w, h) / 30)
        return Subjects(parts: scene.sizes.indices.map { k in
            let mask = scene.mask(of: [k])
            // A point well inside it: where most of the square round it is solid.
            let inner = boxMean(mask, reach)
            var best: Float = -1, at = 0
            for i in 0..<inner.count where inner.p[i] > best && mask.p[i] >= 0.5 { best = inner.p[i]; at = i }
            return Subjects.Part(point: CGPoint(x: (Double(at % w) + 0.5) / Double(w), y: (Double(at / w) + 0.5) / Double(h)),
                                 person: false, outline: path(trace(mask, side: 400)))
        })
    }

    /// The parts of a picture a click keeps or drops. See `subjects(of:)`.
    struct Subjects: @unchecked Sendable {
        struct Part {
            /// A point well inside it, 0…1 across and down the picture: what picks it.
            let point: CGPoint
            /// Whether it is a person, or something else that stands out: the Mac's Vision says,
            /// Windows cannot (always false here).
            let person: Bool
            /// Round it, 0…1 across and down the picture, filled even-odd.
            let outline: CGPath
        }
        let parts: [Part]

        /// The part at `point`, 0…1 across and down the picture; the smallest, where they overlap.
        func part(at point: CGPoint) -> Int? {
            parts.indices.filter { parts[$0].outline.contains(point, using: .evenOdd) }
                .min { area(parts[$0].outline) < area(parts[$1].outline) }
        }

        private func area(_ path: CGPath) -> CGFloat { path.boundingBoxOfPath.width * path.boundingBoxOfPath.height }
    }

    /// What stands out in a picture as its matte has it: each region at least half solid, apart
    /// from the others (touching across a side, not only at a corner), of at least `smallest`
    /// pixels. In place of the Mac's Vision, which finds the same and tells people apart.
    private struct Scene {
        let w: Int, h: Int
        /// Which region each pixel is in, from 1; 0 for none.
        let labels: [Int32]
        /// How many pixels each region has, by its label less one.
        let sizes: [Int]

        init(_ matte: Plane, smallest: Int) {
            w = matte.w
            h = matte.h
            var labels = [Int32](repeating: 0, count: matte.count)
            var sizes: [Int] = []
            var stack: [Int] = [], region: [Int] = []
            for start in 0..<matte.count where matte.p[start] >= 0.5 && labels[start] == 0 {
                let label = Int32(sizes.count + 1)
                labels[start] = label
                stack = [start]
                region.removeAll(keepingCapacity: true)
                while let i = stack.popLast() {
                    region.append(i)
                    let x = i % w
                    for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w] where j >= 0 && j < matte.count && labels[j] == 0 && matte.p[j] >= 0.5 {
                        labels[j] = label
                        stack.append(j)
                    }
                }
                if region.count < smallest {
                    for i in region { labels[i] = -1 }
                } else {
                    sizes.append(region.count)
                }
            }
            for i in labels.indices where labels[i] < 0 { labels[i] = 0 }
            self.labels = labels
            self.sizes = sizes
        }

        /// The regions `kept` (by index), 1 in them and 0 elsewhere.
        func mask(of kept: Set<Int>) -> Plane {
            let out = Plane(w, h)
            let on = Set(kept.map { Int32($0 + 1) })
            labels.withUnsafeBufferPointer { l in
                par(out.count) { r in for i in r where on.contains(l[i]) { out.p[i] = 1 } }
            }
            return out
        }

        /// The region at `point`, 0…1 across and down, if any.
        func part(at point: CGPoint) -> Int? {
            guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
            let i = min(h - 1, Int(point.y * CGFloat(h))) * w + min(w - 1, Int(point.x * CGFloat(w)))
            return labels[i] > 0 ? Int(labels[i]) - 1 : nil
        }
    }

    /// `mask` without the bits of it, apart from the rest, smaller than `smallest` pixels.
    private static func withoutSpecks(_ mask: Plane, smallest: Int) -> Plane {
        let w = mask.w, out = Plane(w, mask.h)
        out.p.update(from: mask.p, count: mask.count)
        var seen = [Bool](repeating: false, count: mask.count), stack: [Int] = [], bit: [Int] = []
        for start in 0..<mask.count where mask.p[start] >= 0.5 && !seen[start] {
            seen[start] = true
            stack = [start]
            bit.removeAll(keepingCapacity: true)
            while let i = stack.popLast() {
                bit.append(i)
                let x = i % w
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w] where j >= 0 && j < mask.count && !seen[j] && mask.p[j] >= 0.5 {
                    seen[j] = true
                    stack.append(j)
                }
            }
            if bit.count < smallest { for i in bit { out.p[i] = 0 } }
        }
        return out
    }

    // MARK: Outlines

    /// Where `mask` is half solid and more, traced square by square (marching squares) with it at
    /// about `side` pixels across, and straightened where it hardly bends: closed lines across and
    /// down from 0 to 1, specks left out.
    static func trace(_ mask: Plane, side: Int) -> [[CGPoint]] {
        let step = max(1, Int((Double(max(mask.w, mask.h)) / Double(side)).rounded()))
        let g = downsample(mask, step), gw = g.w, gh = g.h
        // Nothing beyond the edge, so every line closes.
        let pw = gw + 2
        @inline(__always) func v(_ x: Int, _ y: Int) -> Float { x < 1 || y < 1 || x > gw || y > gh ? 0 : g.p[(y - 1) * gw + (x - 1)] }
        let across = (gw + 1) * (gh + 2)
        func hEdge(_ x: Int, _ y: Int) -> Int { y * (gw + 1) + x }
        func vEdge(_ x: Int, _ y: Int) -> Int { across + y * pw + x }
        var points: [Int: CGPoint] = [:], links: [Int: [Int]] = [:]
        func crossing(_ id: Int, _ a: CGPoint, _ va: Float, _ b: CGPoint, _ vb: Float) {
            guard points[id] == nil else { return }
            let t = CGFloat(min(max((0.5 - va) / (vb - va), 0), 1))
            points[id] = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func link(_ a: Int, _ b: Int) {
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        for y in 0...gh {
            for x in 0...gw {
                let tl = v(x, y), tr = v(x + 1, y), br = v(x + 1, y + 1), bl = v(x, y + 1)
                let c = (tl >= 0.5 ? 8 : 0) | (tr >= 0.5 ? 4 : 0) | (br >= 0.5 ? 2 : 0) | (bl >= 0.5 ? 1 : 0)
                guard c != 0 && c != 15 else { continue }
                let top = hEdge(x, y), bottom = hEdge(x, y + 1), left = vEdge(x, y), right = vEdge(x + 1, y)
                let p = { (x: Int, y: Int) in CGPoint(x: x, y: y) }
                if (tl >= 0.5) != (tr >= 0.5) { crossing(top, p(x, y), tl, p(x + 1, y), tr) }
                if (bl >= 0.5) != (br >= 0.5) { crossing(bottom, p(x, y + 1), bl, p(x + 1, y + 1), br) }
                if (tl >= 0.5) != (bl >= 0.5) { crossing(left, p(x, y), tl, p(x, y + 1), bl) }
                if (tr >= 0.5) != (br >= 0.5) { crossing(right, p(x + 1, y), tr, p(x + 1, y + 1), br) }
                let middle = (tl + tr + br + bl) / 4 >= 0.5
                switch c {
                case 1, 14: link(left, bottom)
                case 2, 13: link(bottom, right)
                case 3, 12: link(left, right)
                case 4, 11: link(top, right)
                case 6, 9: link(top, bottom)
                case 7, 8: link(left, top)
                case 5: if middle { link(left, top); link(bottom, right) } else { link(left, bottom); link(top, right) }
                case 10: if middle { link(left, bottom); link(top, right) } else { link(left, top); link(bottom, right) }
                default: break
                }
            }
        }
        // Each crossing joins two others: walked round, they make the closed lines.
        var lines: [[CGPoint]] = [], walked = Set<Int>()
        for start in links.keys.sorted() where !walked.contains(start) {
            var line: [CGPoint] = [], previous = -1, at = start
            while !walked.contains(at) {
                walked.insert(at)
                line.append(points[at]!)
                guard let next = links[at]?.first(where: { $0 != previous && !walked.contains($0) }) ?? links[at]?.first(where: { $0 != previous }) else { break }
                previous = at
                at = next
            }
            var area: CGFloat = 0
            for i in line.indices { let a = line[i], b = line[(i + 1) % line.count]; area += a.x * b.y - b.x * a.y }
            guard abs(area) / 2 >= 6, line.count >= 4 else { continue }
            // Corner points are in the grid with its border of nothing: pixel x's middle is at x + 1.
            // A closed line begins and ends at one point, from which nothing is far: it is
            // straightened in two halves, from there to the point furthest from it and back.
            let far = line.indices.max { hypot(line[$0].x - line[0].x, line[$0].y - line[0].y) < hypot(line[$1].x - line[0].x, line[$1].y - line[0].y) } ?? 0
            let out = straightened(Array(line[0...far]), tolerance: 0.6), back = straightened(Array(line[far...]) + [line[0]], tolerance: 0.6)
            let fitted = (out + back.dropFirst().dropLast()).map { CGPoint(x: ($0.x - 0.5) / CGFloat(gw), y: ($0.y - 0.5) / CGFloat(gh)) }
            guard fitted.count >= 3 else { continue }
            lines.append(fitted)
        }
        return lines
    }

    /// The points of `line` that keep it within `tolerance` of where it ran (Ramer, Douglas and Peucker).
    private static func straightened(_ line: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard line.count > 2 else { return line }
        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var spans = [(0, line.count - 1)]
        while let (a, b) = spans.popLast() {
            guard b > a + 1 else { continue }
            let p = line[a], q = line[b], dx = q.x - p.x, dy = q.y - p.y, length = max(hypot(dx, dy), 1e-9)
            var far: CGFloat = -1, at = a
            for i in (a + 1)..<b {
                let d = abs((line[i].x - p.x) * dy - (line[i].y - p.y) * dx) / length
                if d > far { far = d; at = i }
            }
            if far > tolerance {
                keep[at] = true
                spans.append((a, at))
                spans.append((at, b))
            }
        }
        return line.indices.filter { keep[$0] }.map { line[$0] }
    }

    /// Closed lines as SVG path data, to four places.
    static func pathData(_ lines: [[CGPoint]]) -> String {
        func n(_ v: CGFloat) -> String {
            var s = String(format: "%.4f", Double(v))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        return lines.map { line in
            "M" + line.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: "L") + "Z"
        }.joined()
    }

    static func path(_ lines: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for line in lines where !line.isEmpty {
            path.addLines(between: line)
            path.closeSubpath()
        }
        return path
    }

    // MARK: Colours under the edge

    /// Forte & Pitié's blur fusion: the subject's own colours where it is see-through, worked out
    /// from the nearby colours of the subject and of the background, once widely and once closely.
    private static func foreground(_ photo: [Plane], _ alpha: Plane, long: Int) -> [Plane] {
        let wide = max(2, Int(Double(long) * 0.03)), close = max(1, Int(Double(long) * 0.002))
        let clear = map(alpha) { 1 - $0 }
        let alphaWide = boxMean(alpha, wide), alphaClose = boxMean(alpha, close)
        return photo.map { c in
            let (f, back) = fuse(c, c, c, alpha, clear, alphaWide, wide)
            return fuse(c, f, back, alpha, clear, alphaClose, close).0
        }
    }

    private static func fuse(_ photo: Plane, _ fore: Plane, _ back: Plane, _ alpha: Plane, _ clear: Plane, _ alphaBlurred: Plane,
                             _ radius: Int) -> (Plane, Plane) {
        let foreBlurred = boxMean(zip2(fore, alpha, *), radius), backBlurred = boxMean(zip2(back, clear, *), radius)
        let f = Plane(photo.w, photo.h), bg = Plane(photo.w, photo.h)
        par(photo.count) { r in
            for i in r {
                let a = alpha.p[i], ab = alphaBlurred.p[i]
                let fb = foreBlurred.p[i] / (ab + 1e-5), bb = backBlurred.p[i] / (1 - ab + 1e-5)
                bg.p[i] = bb
                f.p[i] = min(max(fb + a * (photo.p[i] - a * fb - (1 - a) * bb), 0), 1)
            }
        }
        return (f, bg)
    }

    // MARK: Pictures as numbers

    /// One value a pixel, 0…1.
    final class Plane: @unchecked Sendable {
        let w: Int, h: Int
        let p: UnsafeMutablePointer<Float>

        init(_ w: Int, _ h: Int) {
            self.w = w; self.h = h
            p = .allocate(capacity: w * h)
            p.initialize(repeating: 0, count: w * h)
        }

        deinit { p.deallocate() }
        var count: Int { w * h }
        /// Its values, looked at without holding on to it: for loops run once a pixel, which keep it themselves.
        var grid: Grid { Grid(p: p, w: w, h: h) }
    }

    /// A plane's values, without holding on to it.
    struct Grid {
        let p: UnsafeMutablePointer<Float>, w: Int, h: Int

        /// The value between pixels at x, y, as `sample` gives them.
        @inline(__always) func at(_ x: (Int, Int, Float), _ y: (Int, Int, Float)) -> Float {
            let top = p[y.0 * w + x.0] * (1 - x.2) + p[y.0 * w + x.1] * x.2
            let bottom = p[y.1 * w + x.0] * (1 - x.2) + p[y.1 * w + x.1] * x.2
            return top * (1 - y.2) + bottom * y.2
        }
    }

    /// The two pixels of `size` either side of pixel `i` of `from`, centres lined up, and how far
    /// it is from the first to the second.
    @inline(__always) static func sample(_ i: Int, _ from: Int, _ size: Int) -> (Int, Int, Float) {
        let f = min(max((Float(i) + 0.5) * Float(size) / Float(from) - 0.5, 0), Float(size - 1))
        let lo = Int(f)
        return (lo, min(lo + 1, size - 1), f - Float(lo))
    }

    /// A picture's pixels, RGBA, 8 bits each, colours multiplied by how solid they are (as Skia
    /// reads them), rows top first: in place of the Mac's CGImage drawn into a context.
    struct Pixels: @unchecked Sendable {
        let w: Int, h: Int
        var bytes: [UInt8]
        /// The colours its numbers are in, as an ICC profile, where they are not sRGB's: the
        /// picture's own, as the Mac's `Pixels` keeps its CGImage's colour space.
        var colors: Data?

        init(w: Int, h: Int, bytes: [UInt8], colors: Data? = nil) {
            self.w = w
            self.h = h
            self.bytes = bytes
            self.colors = colors
        }

        /// A picture file's picture at its own size, upright as its orientation turns it, in its
        /// own colours as the Mac's CutoutMaker takes them: its colour space when that is RGB
        /// (an iPhone's Display P3), sRGB otherwise. Nil if it cannot be read.
        init?(file data: Data) {
            var w: Int32 = 0, h: Int32 = 0
            guard data.withUnsafeBytes({ bz_image_size($0.baseAddress, Int32(clamping: $0.count), &w, &h) }) != 0, w > 0, h > 0 else { return nil }
            let longest = Int(max(w, h))
            // As large as its longer side square, which the reading asks room for.
            var bytes = [UInt8](repeating: 0, count: longest * longest * 4)
            // Room for its colour profile; a larger one is read again with room enough.
            var icc = [UInt8](repeating: 0, count: 64 * 1024)
            var size: Int32 = -1
            for _ in 0..<2 {
                size = data.withUnsafeBytes { d in
                    bytes.withUnsafeMutableBytes { b in
                        icc.withUnsafeMutableBytes { bz_image_thumbnail_own(d.baseAddress, Int64(d.count), Int32(longest), &w, &h, b.baseAddress, $0.baseAddress, Int32($0.count)) }
                    }
                }
                guard Int(size) > icc.count else { break }
                icc = [UInt8](repeating: 0, count: Int(size))
            }
            guard size >= 0, Int(size) <= icc.count, w > 0, h > 0 else { return nil }
            bytes.removeSubrange(Int(w) * Int(h) * 4..<bytes.count)
            self.init(w: Int(w), h: Int(h), bytes: bytes, colors: size > 0 ? Data(icc.prefix(Int(size))) : nil)
        }

        /// A picture file's picture made small, its longer side `longest` at most, upright, for
        /// tracing an outline round it (the Mac's thumbnail of 1,024).
        init?(file data: Data, longest: Int) {
            var w: Int32 = 0, h: Int32 = 0
            var bytes = [UInt8](repeating: 0, count: longest * longest * 4)
            let read = data.withUnsafeBytes { d in
                bytes.withUnsafeMutableBytes { bz_image_thumbnail(d.baseAddress, Int64(d.count), Int32(longest), &w, &h, $0.baseAddress) }
            }
            guard read != 0, w > 0, h > 0 else { return nil }
            bytes.removeSubrange(Int(w) * Int(h) * 4..<bytes.count)
            self.init(w: Int(w), h: Int(h), bytes: bytes)
        }

        /// How solid each pixel is, when the picture has see-through parts of its own.
        var alpha: [UInt8]? {
            var any = false
            for i in 0..<(w * h) where bytes[i * 4 + 3] != 255 { any = true; break }
            return any ? (0..<(w * h)).map { bytes[$0 * 4 + 3] } : nil
        }

        /// The picture at `width` × `height`, drawn smoothly.
        func scaled(_ width: Int, _ height: Int) -> Pixels? {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            let done = bytes.withUnsafeBytes { from in
                out.withUnsafeMutableBytes { bz_pixels_scale(from.baseAddress, Int32(w), Int32(h), $0.baseAddress, Int32(width), Int32(height)) }
            }
            return done == 0 ? Pixels(w: width, h: height, bytes: out, colors: colors) : nil
        }

        /// The same in sRGB, as the Mac draws a picture for the learned matte to see.
        func inSRGB() -> Pixels? {
            guard let colors else { return self }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            let done = bytes.withUnsafeBytes { from in
                colors.withUnsafeBytes { icc in
                    out.withUnsafeMutableBytes { bz_pixels_convert(from.baseAddress, Int32(w), Int32(h), icc.baseAddress, Int32(icc.count), nil, 0, $0.baseAddress) }
                }
            }
            return done == 0 ? Pixels(w: w, h: h, bytes: out) : nil
        }

        /// Over white where it is see-through, as the Mac draws it to work on, solid all over.
        func overWhite() -> Pixels {
            var out = bytes
            out.withUnsafeMutableBufferPointer { px in
                for i in stride(from: 0, to: w * h * 4, by: 4) where px[i + 3] != 255 {
                    let white = 255 - px[i + 3]
                    px[i] &+= white
                    px[i + 1] &+= white
                    px[i + 2] &+= white
                    px[i + 3] = 255
                }
            }
            return Pixels(w: w, h: h, bytes: out, colors: colors)
        }

        /// Its colours, 0…1, red, green and blue.
        func planes() -> [Plane] {
            let planes = (0..<3).map { _ in Plane(w, h) }
            bytes.withUnsafeBufferPointer { px in
                par(w * h) { r in for i in r { for k in 0..<3 { planes[k].p[i] = Float(px[i * 4 + k]) / 255 } } }
            }
            return planes
        }
    }

    // MARK: Planes

    /// Work split across the cores, in about as many pieces as there are.
    static func par(_ n: Int, _ body: (Range<Int>) -> Void) {
        let pieces = min(n, 64)
        guard pieces > 0 else { return }
        // Each piece touches only its own part of what it writes to.
        withoutActuallyEscaping(body) { body in
            let work = Unchecked(value: body)
            DispatchQueue.concurrentPerform(iterations: pieces) { c in work.value(n * c / pieces ..< n * (c + 1) / pieces) }
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    static func map(_ a: Plane, _ f: (Float) -> Float) -> Plane {
        let o = Plane(a.w, a.h)
        par(a.count) { r in for i in r { o.p[i] = f(a.p[i]) } }
        return o
    }

    static func zip2(_ a: Plane, _ b: Plane, _ f: (Float, Float) -> Float) -> Plane {
        let o = Plane(a.w, a.h)
        par(a.count) { r in for i in r { o.p[i] = f(a.p[i], b.p[i]) } }
        return o
    }

    /// The mean over a square `2r + 1` pixels wide, cut off at the edges and divided by as much as
    /// is inside: across each row, then down each column, a running sum each way.
    static func boxMean(_ src: Plane, _ r: Int) -> Plane {
        let w = src.w, h = src.h
        let across = Plane(w, h), out = Plane(w, h)
        par(h) { rows in
            for y in rows {
                let s = src.p + y * w, t = across.p + y * w
                var sum = 0.0
                for x in 0...min(r, w - 1) { sum += Double(s[x]) }
                for x in 0..<w {
                    t[x] = Float(sum / Double(min(w - 1, x + r) - max(0, x - r) + 1))
                    if x + r + 1 < w { sum += Double(s[x + r + 1]) }
                    if x - r >= 0 { sum -= Double(s[x - r]) }
                }
            }
        }
        let strip = 128
        par((w + strip - 1) / strip) { strips in
            for c in strips {
                let x0 = c * strip, n = min(w, x0 + strip) - x0
                let sum = UnsafeMutablePointer<Double>.allocate(capacity: n)
                defer { sum.deallocate() }
                sum.initialize(repeating: 0, count: n)
                for y in 0...min(r, h - 1) { let row = across.p + y * w + x0; for i in 0..<n { sum[i] += Double(row[i]) } }
                for y in 0..<h {
                    let inverse = 1 / Double(min(h - 1, y + r) - max(0, y - r) + 1)
                    let d = out.p + y * w + x0
                    for i in 0..<n { d[i] = Float(sum[i] * inverse) }
                    if y + r + 1 < h { let row = across.p + (y + r + 1) * w + x0; for i in 0..<n { sum[i] += Double(row[i]) } }
                    if y - r >= 0 { let row = across.p + (y - r) * w + x0; for i in 0..<n { sum[i] -= Double(row[i]) } }
                }
            }
        }
        return out
    }

    /// Each square of `step` × `step` pixels as one, their mean.
    private static func downsample(_ a: Plane, _ step: Int) -> Plane {
        guard step > 1 else { return a }
        let w = (a.w + step - 1) / step, h = (a.h + step - 1) / step
        let o = Plane(w, h)
        par(h) { rows in
            for y in rows {
                for x in 0..<w {
                    var sum: Float = 0, n = 0
                    for yy in y * step ..< min(a.h, y * step + step) {
                        for xx in x * step ..< min(a.w, x * step + step) { sum += a.p[yy * a.w + xx]; n += 1 }
                    }
                    o.p[y * w + x] = sum / Float(n)
                }
            }
        }
        return o
    }

    /// `a` drawn at `w` × `h`, between its pixels in straight lines.
    static func resample(_ a: Plane, _ w: Int, _ h: Int) -> Plane {
        let o = Plane(w, h)
        withExtendedLifetime(a) {
            let from = a.grid
            par(h) { rows in
                for y in rows {
                    let sy = sample(y, h, from.h)
                    for x in 0..<w { o.p[y * w + x] = from.at(sample(x, w, from.w), sy) }
                }
            }
        }
        return o
    }
}
