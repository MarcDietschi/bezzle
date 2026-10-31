import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Takes the background away from a picture, leaving its subject as if it had been shot on
/// nothing: hair strand by strand, and no trace of the old background's colour round the edge.
///
/// How, as measured against cutouts whose true edges were known:
/// 1. Vision finds what stands out (its foreground instances), all of it or what was picked. Its
///    mask is generous and soft: a plain "remove background" stops here, and leaves a halo.
/// 2. Round people, Apple's person matte, made for hair, is taken instead: kept to the subject
///    and to the people picked, so a bystander behind them never comes along. Whatever the
///    subject holds that is no part of a person, a violin or a wheelchair, is wide where the
///    background left round hair is thin, and the subject's own mask keeps it.
/// 3. The edge is fitted to the photo with a guided filter (He, Sun & Tang): within a narrow band
///    either side, see-through follows the photo's own colours, so it finds the strands.
/// 4. The background's colour is taken out of the see-through edge (Forte & Pitié's blur
///    fusion), so the cutout shows no fringe over whatever it is put on.
///
/// Given a learned matte (`SubjectMatte`), steps 2 and 3 are its instead: it finds hair, held
/// things and see-through edges better than all of them (edge error 5.1% against 8.7%, measured
/// the same way), and is kept to the subject Vision found, fading out just past it.
///
/// The work is done with the picture at about 2,000 pixels across; the edge is then drawn at the
/// picture's own size, from the photo's own pixels, so nothing is lost of a large one.
nonisolated enum CutoutMaker {
    /// What stands out in a picture, as a learned matte has it.
    protocol Matting: Sendable {
        /// 0…1 a pixel, at any size.
        func matte(of picture: CGImage) throws -> Plane
    }

    enum Failure: Error, Equatable {
        /// The picture could not be read.
        case unreadable
        /// Nothing in it stands out from the rest.
        case noSubject
        /// Nothing stands out where it was picked.
        case nothingPicked
    }

    /// How the work is done. The defaults are what measured best.
    struct Tuning {
        /// The longest side the picture is worked on at.
        var workSide = 2048
        /// The guided filter's reach, as a share of the longer side, and how smooth its fit is.
        var reach = 0.01
        var smoothness: Float = 1e-5
        /// How far either side of the outline the edge is worked out, as a share of the longer side.
        var band = 0.01
        /// How far past the subject's and the people's outlines the person matte may reach, in
        /// pixels worked on.
        var gate = 2
        /// Whether people's edges are taken from Apple's person matte.
        var personMatte = true
        /// How wide a part of the subject the person matte leaves out must be for the subject to
        /// keep it as something held, as a share of the longer side; 0 keeps nothing.
        var held = 0.0075
        /// How far past the subject's outline a learned matte fades out, as a share of the longer side.
        var matteReach = 0.02
    }

    /// What has been done of a cut so far, told as it goes.
    struct Progress: @unchecked Sendable {
        /// How far along, 0…1.
        var done: Double
        /// Once what stands out has been found, roughly where it is: grey, white on the subject,
        /// as large as the work is done at.
        var found: CGImage?
    }

    /// `picture` with only its subjects left: the parts at `picks`, 0…1 across and down it from
    /// its top left, or everything that stands out. As large as the picture and in its colours,
    /// its edges soft where they were in the photo. Its edges come from `matting` when there is
    /// one. `told` hears how it is going.
    static func cut(_ picture: CGImage, picks: [CGPoint]? = nil, matting: (any Matting)? = nil, tuning: Tuning = Tuning(),
                    told: (Progress) -> Void = { _ in }) throws -> CGImage {
        let w = picture.width, h = picture.height
        guard w > 0, h > 0 else { throw Failure.unreadable }
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard var full = Pixels(picture, width: w, height: h, space: space) else { throw Failure.unreadable }
        let shrink = min(1, Double(tuning.workSide) / Double(max(w, h)))
        let ww = max(1, Int((Double(w) * shrink).rounded())), wh = max(1, Int((Double(h) * shrink).rounded()))
        guard let work = shrink < 1 ? Pixels(picture, width: ww, height: wh, space: space) : full, let seen = work.image() else {
            throw Failure.unreadable
        }
        let long = max(ww, wh)
        let photo = work.planes()
        told(Progress(done: 0.08))

        // What stands out, and of it, what was picked.
        let handler = VNImageRequestHandler(cgImage: seen, options: [:])
        let scene = try Scene(handler, ww, wh)
        var subject: Plane, people: Plane?
        if let picks, !picks.isEmpty {
            let kept = Set(picks.compactMap { scene.part(at: $0) })
            guard !kept.isEmpty else { throw Failure.nothingPicked }
            subject = Plane(ww, wh)
            for k in kept { subject = zip2(subject, scene.parts[k].mask, max) }
            let who = Set(kept.flatMap { scene.parts[$0].people })
            people = scene.people.filter { who.contains($0.key) }.values.reduce(Plane?.none) { sum, p in sum.map { zip2($0, p, max) } ?? p }
        } else {
            subject = scene.parts.dropFirst().reduce(scene.parts[0].mask) { zip2($0, $1.mask, max) }
            people = scene.people.values.reduce(Plane?.none) { sum, p in sum.map { zip2($0, p, max) } ?? p }
        }
        told(Progress(done: 0.3, found: grey(subject)))

        // How see-through each pixel is, worked out at this size; either straight from the learned
        // matte or, without one, fitted to the photo within a band either side of the outline.
        let alpha: Plane, band: Plane?, fit: Fit?
        if let matting {
            // Only what was picked: the matte fades out past the subject's outline, gone
            // `matteReach` past it, so whatever else stands out stays behind.
            let learned = try matting.matte(of: seen)
            let matte = learned.w == ww && learned.h == wh ? learned : resample(learned, ww, wh)
            let near = boxMean(map(subject) { $0 >= 0.5 ? 1 : 0 }, max(1, Int(Double(long) * tuning.matteReach)))
            alpha = withoutSpecks(zip2(matte, near) { a, n in min(max(a, 0), 1) * min(1, n * 2) }, smallest: ww * wh / 2000)
            band = nil
            fit = nil
        } else {
            let edges = tuning.personMatte ? people.flatMap { peopleEdges(subject, $0, handler: handler, long: long, tuning: tuning) } ?? subject : subject
            let base = withoutSpecks(edges, smallest: ww * wh / 2000)
            told(Progress(done: 0.45))

            // The edge fitted to the photo, and the photo's own colours under it.
            let edgeBand = boxMean(map(base) { $0 >= 0.5 ? 1 : 0 }, max(2, Int(Double(long) * tuning.band)))
            let fitted = Fit(photo, base, radius: max(2, Int(Double(long) * tuning.reach)), smoothness: tuning.smoothness,
                             step: max(1, Int((Double(long) / 1000).rounded())))
            let worked = Plane(ww, wh)
            withExtendedLifetime((photo, edgeBand, fitted)) {
                let r = photo[0].grid, g = photo[1].grid, b = photo[2].grid, edge = edgeBand.grid, fit = fitted.grids, out = worked.grid
                par(wh) { rows in
                    for y in rows {
                        for x in 0..<ww {
                            let i = y * ww + x
                            out.p[i] = edged(edge.p[i], fit.value(x, y, ww, wh, r.p[i], g.p[i], b.p[i]))
                        }
                    }
                }
            }
            alpha = worked
            band = edgeBand
            fit = fitted
        }
        told(Progress(done: 0.55))
        let colours = foreground(photo, alpha, long: long)
        let shift = (0..<3).map { k in zip2(colours[k], photo[k]) { $0 - $1 } }
        told(Progress(done: 0.65))

        // At the picture's own size: the fit drawn from its own pixels (or the learned matte
        // spread out), the colours shifted as they were worked out, multiplied out as the picture
        // is kept.
        let seeThrough = full.alpha
        withExtendedLifetime((alpha, band, fit, shift)) {
            let soft = alpha.grid, edge = band?.grid, fitted = fit?.grids
            let dr = shift[0].grid, dg = shift[1].grid, db = shift[2].grid
            full.bytes.withUnsafeMutableBufferPointer { px in
                par(h) { rows in
                    for y in rows {
                        let sy = sample(y, h, wh)
                        for x in 0..<w {
                            let i = (y * w + x) * 4
                            let r = Float(px[i]) / 255, g = Float(px[i + 1]) / 255, b = Float(px[i + 2]) / 255
                            let sx = sample(x, w, ww)
                            var a: Float
                            if let edge, let fitted {
                                a = edged(edge.at(sx, sy), fitted.value(x, y, w, h, r, g, b))
                            } else {
                                a = min(max(soft.at(sx, sy), 0), 1)
                            }
                            if let seeThrough { a *= Float(seeThrough[y * w + x]) / 255 }
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
        guard let cut = full.image(opaque: false) else { throw Failure.unreadable }
        told(Progress(done: 0.85))
        return cut
    }

    /// Round what is at least half solid in a picture with see-through parts: SVG path data across
    /// and down it from 0 to 1, filled even-odd. See `Cutout.outline`.
    static func outline(of image: CGImage) -> String {
        let w = image.width, h = image.height
        var clear = [UInt8](repeating: 0, count: w * h * 4)
        clear.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let alpha = Plane(w, h)
        for i in 0..<alpha.count { alpha.p[i] = Float(clear[i * 4 + 3]) / 255 }
        return pathData(trace(alpha, side: 800))
    }

    /// The parts of `picture` a click keeps or drops, as `cut` takes picks: what stands out in it,
    /// but a subject that is several people is each of them, and what is left of it.
    static func subjects(of picture: CGImage) throws -> Subjects {
        let shrink = min(1, 1024 / Double(max(picture.width, picture.height)))
        let w = max(1, Int((Double(picture.width) * shrink).rounded())), h = max(1, Int((Double(picture.height) * shrink).rounded()))
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let seen = Pixels(picture, width: w, height: h, space: space)?.image() else { throw Failure.unreadable }
        let scene = try Scene(VNImageRequestHandler(cgImage: seen, options: [:]), w, h)
        let reach = max(1, max(w, h) / 30)
        return Subjects(parts: scene.parts.map { part in
            // A point well inside it: where most of the square round it is solid.
            let inner = boxMean(map(part.mask) { $0 >= 0.5 ? 1 : 0 }, reach)
            var best: Float = -1, at = 0
            for i in 0..<inner.count where inner.p[i] > best && part.mask.p[i] >= 0.5 { best = inner.p[i]; at = i }
            return Subjects.Part(point: CGPoint(x: (Double(at % w) + 0.5) / Double(w), y: (Double(at / w) + 0.5) / Double(h)),
                                 person: !part.people.isEmpty, outline: path(trace(part.mask, side: 400)))
        })
    }

    /// The parts of a picture a click keeps or drops. See `subjects(of:)`.
    struct Subjects: @unchecked Sendable {
        struct Part {
            /// A point well inside it, 0…1 across and down the picture: what picks it.
            let point: CGPoint
            /// Whether it is a person, or something else that stands out.
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

    /// What Vision finds standing out in a picture, in the parts a click keeps or drops.
    private struct Scene {
        struct Part {
            let mask: Plane
            /// Vision's people in it, by their number: a person apart is one, a subject that is
            /// one person and what they hold is them.
            let people: [Int]
        }
        let parts: [Part]
        /// Each of the people, a mask of their own.
        let people: [Int: Plane]

        init(_ handler: VNImageRequestHandler, _ w: Int, _ h: Int) throws {
            let subjects = VNGenerateForegroundInstanceMaskRequest()
            do { try handler.perform([subjects]) } catch { throw Failure.unreadable }
            guard let found = subjects.results?.first, !found.allInstances.isEmpty else { throw Failure.noSubject }
            var people: [Int: Plane] = [:]
            let persons = VNGeneratePersonInstanceMaskRequest()
            if (try? handler.perform([persons])) != nil, let seen = persons.results?.first {
                for k in seen.allInstances {
                    if let b = try? seen.generateScaledMaskForImage(forInstances: [k], from: handler) { people[k] = CutoutMaker.plane(b, w, h) }
                }
            }
            let margin = max(2, max(w, h) / 50)
            var parts: [Part] = []
            for i in found.allInstances {
                guard let b = try? found.generateScaledMaskForImage(forInstances: [i], from: handler) else { continue }
                let s = CutoutMaker.plane(b, w, h)
                // The people mostly inside it.
                let inside = people.keys.sorted().filter { k in
                    let p = people[k]!
                    var both = 0, all = 0
                    for j in stride(from: 0, to: p.count, by: 2) where p.p[j] >= 0.5 {
                        all += 1
                        if s.p[j] >= 0.5 { both += 1 }
                    }
                    return all > 0 && both * 2 > all
                }
                guard inside.count >= 2 else {
                    parts.append(Part(mask: s, people: inside))
                    continue
                }
                // Several people Vision saw as one: each of them, with a little round them for
                // their hair and what they hold, but nothing of the others; then what is left.
                let solid = inside.map { k in CutoutMaker.map(people[k]!) { $0 >= 0.5 ? 1 : 0 } }
                for (n, k) in inside.enumerated() {
                    let near = boxMean(solid[n], margin)
                    let others = solid.indices.filter { $0 != n }.map { solid[$0] }
                    let part = Plane(w, h)
                    for j in 0..<part.count where near.p[j] > 0 && !others.contains(where: { $0.p[j] >= 0.5 }) { part.p[j] = s.p[j] }
                    parts.append(Part(mask: part, people: [k]))
                }
                let anyone = boxMean(solid.dropFirst().reduce(solid[0]) { CutoutMaker.zip2($0, $1, max) }, margin)
                let rest = Plane(w, h)
                var left = 0, all = 0
                for j in 0..<rest.count where s.p[j] >= 0.5 {
                    all += 1
                    if anyone.p[j] == 0 { rest.p[j] = s.p[j]; left += 1 }
                }
                if left * 30 > all { parts.append(Part(mask: rest, people: [])) }
            }
            guard !parts.isEmpty else { throw Failure.noSubject }
            self.parts = parts
            self.people = people
        }

        /// The part at `point`, 0…1 across and down: the most solid there, or the smallest of those.
        func part(at point: CGPoint) -> Int? {
            guard let first = parts.first, point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
            let w = first.mask.w, h = first.mask.h
            let i = min(h - 1, Int(point.y * CGFloat(h))) * w + min(w - 1, Int(point.x * CGFloat(w)))
            return parts.indices.filter { parts[$0].mask.p[i] >= 0.5 }.max { parts[$0].mask.p[i] < parts[$1].mask.p[i] }
        }
    }

    /// How see-through the edge is where `band` says how much of the outline lies around: solid
    /// well inside it, clear well outside, and in between as the fit has it.
    @inline(__always) private static func edged(_ band: Float, _ fitted: Float) -> Float {
        band >= 0.9999 ? 1 : band <= 0.0001 ? 0 : min(max(fitted, 0), 1)
    }

    /// The subject, the edges of `people` in it taken from the person matte; nil when Vision
    /// makes none.
    private static func peopleEdges(_ subject: Plane, _ people: Plane, handler: VNImageRequestHandler, long: Int, tuning: Tuning) -> Plane? {
        let w = subject.w, h = subject.h
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        guard (try? handler.perform([request])) != nil, let matte = request.results?.first?.pixelBuffer else { return nil }
        let fine = plane(matte, w, h)

        // Only within a hair of both the subject and the people picked.
        let near = max(1, tuning.gate)
        let inSubject = boxMean(map(subject) { $0 >= 0.5 ? 1 : 0 }, near), inPeople = boxMean(map(people) { $0 >= 0.5 ? 1 : 0 }, near)
        let hair = Plane(w, h)
        par(w * h) { r in for i in r { hair.p[i] = inSubject.p[i] > 0 && inPeople.p[i] > 0 ? min(max(fine.p[i], 0), 1) : 0 } }
        guard tuning.held > 0 else { return hair }

        // What the subject holds and the matte leaves out stands wide of its outline, unlike the
        // background round hair: what is left of it narrowed and widened again by `held`.
        let reach = max(1, Int(Double(long) * tuning.held))
        let left = Plane(w, h)
        par(w * h) { r in for i in r { left.p[i] = subject.p[i] >= 0.5 && hair.p[i] < 0.5 ? 1 : 0 } }
        let narrowed = map(boxMean(left, reach)) { $0 >= 0.999 ? 1 : 0 }
        let held = boxMean(narrowed, reach)
        let edges = Plane(w, h)
        par(w * h) { r in for i in r { edges.p[i] = held.p[i] > 0.001 ? subject.p[i] : hair.p[i] } }
        return edges
    }

    /// `mask` without the bits of it, apart from the rest, smaller than `smallest` pixels.
    private static func withoutSpecks(_ mask: Plane, smallest: Int) -> Plane {
        let w = mask.w, h = mask.h, out = Plane(w, h)
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
            var s = String(format: "%.4f", v)
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

    /// A mask as a grey picture, white where it is: for drawing through.
    private static func grey(_ mask: Plane) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: mask.count)
        for i in 0..<mask.count { bytes[i] = UInt8(min(max(mask.p[i], 0), 1) * 255 + 0.5) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: mask.w, height: mask.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: The guided filter

    /// He, Sun & Tang's guided filter with the photo's colours as its guide: in each small square
    /// of it, see-through is fitted as a sum of the colours. The fit is worked out `step` times
    /// smaller and can be drawn at any size, from the colours there.
    private struct Fit {
        let a: [Plane], b: Plane

        init(_ guide: [Plane], _ p: Plane, radius: Int, smoothness: Float, step: Int) {
            let g = guide.map { downsample($0, step) }, q = downsample(p, step)
            let r = max(1, radius / step), n = q.count
            let mg = g.map { boxMean($0, r) }, mq = boxMean(q, r)
            let mgq = (0..<3).map { k in boxMean(zip2(g[k], q, *), r) }
            let mgg = [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)].map { pair in boxMean(zip2(g[pair.0], g[pair.1], *), r) }
            let a = (0..<3).map { _ in Plane(q.w, q.h) }, b = Plane(q.w, q.h)
            let e = Double(smoothness)
            withExtendedLifetime((mg, mq, mgq, mgg, a, b)) {
                let g0 = mg[0].p, g1 = mg[1].p, g2 = mg[2].p, mp = mq.p, gq0 = mgq[0].p, gq1 = mgq[1].p, gq2 = mgq[2].p
                let gg = mgg.map(\.p), a0 = a[0].p, a1 = a[1].p, a2 = a[2].p, bp = b.p
                par(n) { range in
                    for k in range {
                        let m0 = Double(g0[k]), m1 = Double(g1[k]), m2 = Double(g2[k]), m = Double(mp[k])
                        let c0 = Double(gq0[k]) - m0 * m, c1 = Double(gq1[k]) - m1 * m, c2 = Double(gq2[k]) - m2 * m
                        let s00 = Double(gg[0][k]) - m0 * m0 + e, s01 = Double(gg[1][k]) - m0 * m1, s02 = Double(gg[2][k]) - m0 * m2
                        let s11 = Double(gg[3][k]) - m1 * m1 + e, s12 = Double(gg[4][k]) - m1 * m2, s22 = Double(gg[5][k]) - m2 * m2 + e
                        let i00 = s11 * s22 - s12 * s12, i01 = s02 * s12 - s01 * s22, i02 = s01 * s12 - s02 * s11
                        let i11 = s00 * s22 - s02 * s02, i12 = s01 * s02 - s00 * s12, i22 = s00 * s11 - s01 * s01
                        let det = s00 * i00 + s01 * i01 + s02 * i02
                        let x0 = (i00 * c0 + i01 * c1 + i02 * c2) / det
                        let x1 = (i01 * c0 + i11 * c1 + i12 * c2) / det
                        let x2 = (i02 * c0 + i12 * c1 + i22 * c2) / det
                        a0[k] = Float(x0); a1[k] = Float(x1); a2[k] = Float(x2)
                        bp[k] = Float(m - x0 * m0 - x1 * m1 - x2 * m2)
                    }
                }
            }
            self.a = a.map { boxMean($0, r) }
            self.b = boxMean(b, r)
        }

        /// The fit to look at once a pixel, while the fit is held on to.
        var grids: Grids { Grids(a0: a[0].grid, a1: a[1].grid, a2: a[2].grid, b: b.grid) }

        struct Grids {
            let a0: Grid, a1: Grid, a2: Grid, b: Grid

            /// The fit at pixel x, y of a picture `w` × `h`, whose colours there are r, g, bl.
            @inline(__always) func value(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ r: Float, _ g: Float, _ bl: Float) -> Float {
                let sx = CutoutMaker.sample(x, w, b.w), sy = CutoutMaker.sample(y, h, b.h)
                return a0.at(sx, sy) * r + a1.at(sx, sy) * g + a2.at(sx, sy) * bl + b.at(sx, sy)
            }
        }
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

    /// A mask Vision made, at `w` × `h` however large Vision made it.
    private static func plane(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int) -> Plane {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer), floats = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let made = Plane(bw, bh)
        for y in 0..<bh {
            let line = base + y * row
            for x in 0..<bw {
                made.p[y * bw + x] = floats ? line.assumingMemoryBound(to: Float.self)[x] : Float(line.assumingMemoryBound(to: UInt8.self)[x]) / 255
            }
        }
        return bw == w && bh == h ? made : resample(made, w, h)
    }

    /// The two pixels of `size` either side of pixel `i` of `from`, centres lined up, and how far
    /// it is from the first to the second.
    @inline(__always) static func sample(_ i: Int, _ from: Int, _ size: Int) -> (Int, Int, Float) {
        let f = min(max((Float(i) + 0.5) * Float(size) / Float(from) - 0.5, 0), Float(size - 1))
        let lo = Int(f)
        return (lo, min(lo + 1, size - 1), f - Float(lo))
    }

    /// A picture's pixels, colours multiplied by how solid they are, over white where it was
    /// see-through; that is kept apart.
    private struct Pixels {
        let w: Int, h: Int
        let space: CGColorSpace
        var bytes: [UInt8]
        /// How solid each pixel was, when the picture had see-through parts of its own.
        var alpha: [UInt8]?

        init?(_ picture: CGImage, width: Int, height: Int, space: CGColorSpace) {
            w = width; h = height
            self.space = space
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
            switch picture.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: alpha = nil
            default:
                // Drawn again over nothing, for how solid it is.
                var clear = [UInt8](repeating: 0, count: width * height * 4)
                clear.withUnsafeMutableBytes { buffer in
                    let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    ctx?.interpolationQuality = .high
                    ctx?.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                let a = (0..<(width * height)).map { clear[$0 * 4 + 3] }
                alpha = a.allSatisfy { $0 == 255 } ? nil : a
            }
        }

        /// Its colours, 0…1, red, green and blue.
        func planes() -> [Plane] {
            let planes = (0..<3).map { _ in Plane(w, h) }
            bytes.withUnsafeBufferPointer { px in
                par(w * h) { r in for i in r { for k in 0..<3 { planes[k].p[i] = Float(px[i * 4 + k]) / 255 } } }
            }
            return planes
        }

        func image(opaque: Bool = true) -> CGImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    // MARK: Planes

    /// Work split across the cores, in about as many pieces as there are.
    private static func par(_ n: Int, _ body: (Range<Int>) -> Void) {
        let pieces = min(n, 64)
        guard pieces > 0 else { return }
        // Each piece touches only its own part of what it writes to.
        withoutActuallyEscaping(body) { body in
            let work = Unchecked(value: body)
            DispatchQueue.concurrentPerform(iterations: pieces) { c in work.value(n * c / pieces ..< n * (c + 1) / pieces) }
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private static func map(_ a: Plane, _ f: (Float) -> Float) -> Plane {
        let o = Plane(a.w, a.h)
        par(a.count) { r in for i in r { o.p[i] = f(a.p[i]) } }
        return o
    }

    private static func zip2(_ a: Plane, _ b: Plane, _ f: (Float, Float) -> Float) -> Plane {
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
