import Foundation

/// Turns a picture into shapes.
///
/// 1. The picture is made ready: its noise taken out with its edges left, and pixel art told
///    from drawn and photographed pictures (`Raster`).
/// 2. Its colours are found from where it is calm, so that the mixed pixels of soft edges make
///    no colours of their own (`Palette`).
/// 3. It is read at several samples to the pixel, each given its colour, and the slivers soft
///    edges would leave are taken away; the samples of one colour that hang together are a
///    region (`Labels`, `Regions`).
/// 4. The regions are stacked, broad ones under thin ones, each reaching a little under those
///    over it (`Stack`).
/// 5. Each region's outline is walked along its samples' edges, brought down to the fewest
///    straight sides, and from those to lines, sharp corners and smooth curves; rectangles and
///    ellipses are known for what they are (`Polygon`, `Fitter`).
public enum Vectorizer {
    /// Traces `bitmap`. `progress` is told how far along it is, 0…1, from whatever thread the
    /// work is on, and stops the work by answering false; nil is returned then.
    public static func trace(_ bitmap: Bitmap, settings: Settings = Settings(), progress: (@Sendable (Double) -> Bool)? = nil) -> Tracing? {
        @Sendable func going(_ done: Double) -> Bool { progress?(done) ?? true }
        let reading: Reading
        switch read(bitmap, settings: settings, going: going) {
        case .stopped: return nil
        case .nothing(let pixelArt): return Tracing(width: bitmap.width, height: bitmap.height, shapes: [], palette: [], pixelArt: pixelArt)
        case .done(let read): reading = read
        }
        let raster = reading.raster, tints = reading.tints, labels = reading.labels, regions = reading.regions
        let scale = reading.scale, pixelArt = reading.pixelArt, clean = reading.clean, shrink = reading.shrink, detail = reading.detail
        let wavers = reading.wavers && !pixelArt
        let running = reading.blends

        var stack = Stack.make(regions, clear: labels.clear, lap: scale)
        guard going(0.65) else { return nil }

        let smoothing = min(max(settings.smoothing, 0), 1)
        var fitter = Fitter(scale: Double(scale), tolerance: max(Double(scale) * (0.06 + 0.2 * smoothing), 0.6),
                            sharpness: 0.85 + 0.3 * smoothing, slack: 1 + 0.15 * Double(scale - 1),
                            pointed: Double(scale) * (1.4 - 0.6 * smoothing), exact: pixelArt,
                            near: pixelArt ? nil : labels.near, W: labels.W, H: labels.H)
        let count = stack.order.count
        let kept = regions

        // Every region's walks, and how unsteady the picture's edges are.
        let walked = UnsafeMutablePointer<[Walk]>.allocate(capacity: max(count, 1))
        walked.initialize(repeating: [], count: max(count, 1))
        defer {
            walked.deinitialize(count: max(count, 1))
            walked.deallocate()
        }
        let walks = Sent(walked)
        let wobbles = Tally(bins: 256)
        let measuring = fitter
        let first = stack
        parallel(count, atLeast: 4) { range in
            var own = [Int](repeating: 0, count: 256)
            for k in range {
                walks.value[k] = first.walks(of: Int(first.order[k]), in: kept)
                guard !pixelArt else { continue }
                for walk in walks.value[k] {
                    for w in measuring.wobbles(walk) { own[min(Int(w * 64), 255)] += 1 }
                }
            }
            wobbles.add(own)
        }
        guard going(0.7) else { return nil }
        // How far its edges waver, in pixels: for a picture drawn with clean edges about 0.004,
        // for one kept coarsely or scaled ten times that. An outline is let stray as much more
        // from a wavering edge as it takes to run through the wavering, not along it. A clean
        // picture is taken at its word, however small its letters.
        let wobble = pixelArt ? 0 : wobbles.quantile(0.7) / 64 / Double(scale)
        var loose = clean ? 1 : min(max(wobble / 0.008, 1.5), 3)
        // Made smaller, a picture's wavering went with its size: its outlines stray by so much
        // less in its own pixels.
        if shrink >= 1.3 { loose = max(1, loose / shrink) }
        // With little detail wanted the outlines run calmer still.
        loose *= 1 + 1.6 * max(0, 0.5 - detail)
        fitter.tolerance *= loose
        fitter.slack *= loose
        fitter.loose = loose
        if loose > 1.2 {
            // An outline that runs through the wavering of its edge leaves the samples by more:
            // the shapes under it reach further under, so nothing opens between them.
            stack = Stack.make(regions, clear: labels.clear, lap: Int((Double(scale) * (0.6 + 0.4 * loose)).rounded(.up)))
            let again = stack
            parallel(count, atLeast: 4) { range in
                for k in range { walks.value[k] = again.walks(of: Int(again.order[k]), in: kept) }
            }
        }
        let stacked = stack
        fitter.cover = Fitter.Cover(id: kept.id, rank: stacked.rank, under: stacked.under, lap: stacked.lap)
        let made = UnsafeMutablePointer<Shape?>.allocate(capacity: max(count, 1))
        made.initialize(repeating: nil, count: max(count, 1))
        defer {
            made.deinitialize(count: max(count, 1))
            made.deallocate()
        }
        let out = Sent(made)
        let stopped = Flag()
        let finished = Counter()
        let scaleBy = 1 / Double(scale), offsetX = Double(bitmap.width) / Double(raster.w), offsetY = Double(bitmap.height) / Double(raster.h)
        let fitting = fitter
        let wide = Double(bitmap.width), high = Double(bitmap.height)
        parallel(count, atLeast: 4) { range in
            for k in range {
                if stopped.isSet { return }
                let r = Int(stacked.order[k])
                let walks = walks.value[k]
                var outlines: [Outline] = []
                var figure: Figure?
                // The outside first, then its holes.
                // Something thin, by its area and how far it is round: a line, most likely.
                var round = 0.0
                for walk in walks {
                    let c = walk.corners
                    for i in 0..<c.count {
                        let d = c[(i + 1) % c.count] &- c[i]
                        round += Double(abs(d.x) + abs(d.y))
                    }
                }
                var own = fitting
                if fitting.loose > 1, round > 0, 2 * Double(kept.area[r]) / round < 2.5 * Double(scale) { own.calmer = 3 * scale }
                // And in any picture that wavers, as thick all along as it is on the whole.
                if wavers, round > 0, 2 * Double(kept.area[r]) / round < 4.5 * Double(scale) {
                    let even = own.evened(walks, of: Int32(r))
                    own.shifts = even.shifts
                    if even.line {
                        // A line's two edges are each other's measure, and calm once it is
                        // even: its outline keeps to them. Let stray as far as from any
                        // wavering edge, and straightened where it nearly is, each edge would
                        // go its own way and the line be thick here and thin there.
                        own.tolerance /= fitting.loose.squareRoot()
                        own.slack /= fitting.loose
                        own.loose = 1
                    }
                }
                for walk in walks.sorted(by: { $0.area2 > $1.area2 }) {
                    guard let fitted = own.outline(walk, of: Int32(r)) else { continue }
                    // Never outside the picture: every point lies in it, and a curve's handles
                    // too where the curve would bulge over the picture's edge otherwise. A long
                    // arc's handles lie outside by rights, the arc itself within.
                    func free(_ p: V2) -> Spot { Spot(p.x * scaleBy * offsetX, p.y * scaleBy * offsetY) }
                    func spot(_ p: V2) -> Spot {
                        let s = free(p)
                        return Spot(min(max(s.x, 0), wide), min(max(s.y, 0), high))
                    }
                    var from = spot(fitted.start)
                    let stretches: [Stretch] = fitted.parts.map {
                        switch $0 {
                        case .line(let p):
                            from = spot(p)
                            return .line(from)
                        case .curve(let c):
                            let a = free(c.c1), b = free(c.c2), to = spot(c.to)
                            var within = true
                            for k in 1..<16 {
                                let t = Double(k) / 16, s = 1 - t
                                let x = s * s * s * from.x + 3 * s * s * t * a.x + 3 * s * t * t * b.x + t * t * t * to.x
                                let y = s * s * s * from.y + 3 * s * s * t * a.y + 3 * s * t * t * b.y + t * t * t * to.y
                                if x < -0.02 || y < -0.02 || x > wide + 0.02 || y > high + 0.02 { within = false; break }
                            }
                            from = to
                            return within ? .curve(a, b, to) : .curve(spot(c.c1), spot(c.c2), to)
                        }
                    }
                    outlines.append(Outline(start: spot(fitted.start), stretches: stretches))
                    if walks.count == 1 { figure = fitted.figure.flatMap { scaled($0, offsetX, offsetY) } }
                }
                guard !outlines.isEmpty else { continue }
                // Colours that run across it, at the picture's own size; its one colour is then
                // the one halfway along.
                let blend = r < running.count ? running[r].map {
                    Blend(kind: $0.kind, start: Spot($0.start.x * offsetX, $0.start.y * offsetY), end: Spot($0.end.x * offsetX, $0.end.y * offsetY), stops: $0.stops)
                } : nil
                out.value[k] = Shape(color: blend?.color(at: 0.5) ?? tints[Int(kept.label[r])], outlines: outlines, figure: figure, blend: blend,
                                     area: Double(kept.area[r]) * scaleBy * scaleBy * offsetX * offsetY)
                if finished.add() % 64 == 0, !going(0.7 + 0.3 * Double(finished.value) / Double(max(count, 1))) { stopped.set() }
            }
        }
        if stopped.isSet { return nil }
        var shapes: [Shape] = []
        shapes.reserveCapacity(count)
        for k in 0..<count {
            if let shape = made[k] { shapes.append(shape) }
        }
        _ = going(1)
        return Tracing(width: bitmap.width, height: bitmap.height, shapes: shapes, palette: tints, pixelArt: pixelArt)
    }

    /// A picture read: its colours, which of them every sample is, and the regions those make.
    struct Reading {
        /// The picture as it was read: calmed, and made smaller when its edges were soft.
        var raster: Raster
        var palette: Palette
        var tints: [Tint]
        var labels: Labels
        var regions: Regions
        /// For each region, the colours that run across it, in `raster`'s pixels; nil for a
        /// region of one colour, and empty when none has any (`blended`).
        var blends: [Blend?]
        /// Samples across a pixel of `raster`.
        var scale: Int
        var pixelArt: Bool
        /// Whether the picture can be taken at its word, pixel by pixel: drawn, and kept as drawn.
        var clean: Bool
        /// Whether its edges waver: not clean, or kept as a JPEG that left its flat places calm.
        var wavers: Bool
        /// How many times smaller than the picture `raster` is.
        var shrink: Double
        var noise: Double
        var detail: Double
        var mixing: Mixing
    }

    enum Read {
        case stopped
        /// Nothing in the picture shows.
        case nothing(pixelArt: Bool)
        case done(Reading)
    }

    /// Steps 1 to 3: the picture made ready, its colours found, its samples given their colours
    /// and gathered into regions.
    static func read(_ bitmap: Bitmap, settings: Settings, going: (Double) -> Bool) -> Read {
        // How much of the picture's small things is wanted: with little, few colours, nothing
        // small or faint, and outlines that run calmer; with much, every colour and small thing
        // the picture has, its edges as calm as ever.
        let detail = min(max(settings.detail, 0), 1)
        var raster = Raster.prepare(bitmap, cap: settings.draft ? 700_000 : 4_000_000)
        var noise = raster.noise()
        let hard = noise < 1 && raster.hardEdged()
        let pixelArt = hard && max(raster.w, raster.h) / raster.blockSize() <= 192
        // A picture kept as a JPEG is calm where it is flat and restless along its edges, where
        // its colour is coarse too: read as a noisy one.
        let known = hard ? false : raster.colorCoarse()
        let coarse = known ?? false
        // One that is mostly flat paper with thin lines on it has too few edges between colours
        // to tell how coarse its colour is, but rings beside its lines as a JPEG does: its
        // colour is then no finer than any JPEG's, though the picture is taken at its word.
        let rings = !hard && known == nil && (raster.ringing(0.9) ?? 0) >= 0.6
        // A picture scaled up or blurred holds nothing finer than its edges are soft: it is
        // traced at the size its edges would be a drawn picture's, where they are found as
        // exactly, and what wavers along them is evened out.
        let softness = hard ? 1 : raster.softness(0.25)
        let shrink = min(softness / 1.15, 4, Double(min(raster.w, raster.h)) / 48)
        var mixing = Mixing(coarse: coarse || rings)
        if shrink >= 1.3 {
            raster = raster.resized(Int((Double(raster.w) / shrink).rounded()), Int((Double(raster.h) / shrink).rounded()))
            noise = raster.noise()
            // Made much smaller, its colour is as fine as its light again.
            if shrink >= 1.8 { mixing = Mixing(coarse: false) }
        }
        if coarse { noise = max(noise, 4) }
        if !hard, noise >= 1.2 { raster = raster.calmed(noise: noise) }
        guard going(0.08) else { return .stopped }

        let palette = Palette.find(raster, settings: settings, noise: noise, exact: pixelArt, mixing: mixing)
        let tints = palette.drawn.map { Tint(r: UInt8(clamping: $0.x), g: UInt8(clamping: $0.y), b: UInt8(clamping: $0.z)) }
        guard !palette.colors.isEmpty else { return .nothing(pixelArt: pixelArt) }
        guard going(0.16) else { return .stopped }

        let pixels = Double(raster.w * raster.h)
        let scale: Int
        if pixelArt {
            scale = 1
        } else if settings.draft {
            scale = pixels <= 300_000 ? 2 : 1
        } else {
            scale = max(1, min(4, Int((6_500_000 / pixels).squareRoot())))
        }
        let sampler = Sampler(raster, scale: scale)
        let nearest = Nearest(palette.colors)
        // Whether the picture can be taken at its word, pixel by pixel: drawn, and kept as drawn.
        let clean = !coarse && noise < 1 && shrink < 1.3
        var labels = Labels.read(sampler, nearest, weights: palette.weights, noise: noise, mixes: !pixelArt, mixing: mixing, worn: !clean)
        if !pixelArt, !clean { labels.withoutSpurs(reach: max(1, Int((0.5 * Double(scale)).rounded())), most: 4 * scale * scale) }
        guard going(0.42) else { return .stopped }

        var regions = Regions.find(labels)
        if !pixelArt, regions.threaded(labels, colors: palette.colors, thin: 2 * scale, worn: !clean) {
            regions = Regions.find(labels)
        }
        if !pixelArt, !clean {
            if regions.withoutFringes(labels, colors: palette.colors, thin: Int((1.5 * Double(scale)).rounded()), scale: scale,
                                      faint: 40 + 120 * (1 - detail)) {
                regions = Regions.find(labels)
            }
        }
        if !pixelArt {
            // The smallest things kept: by how much detail is wanted, and no more shapes than a
            // design can hold.
            let bold = max(0, 0.5 - detail)
            var least = Int(((1 + 10 * (1 - detail) * (1 - detail) + pixels / 375 * bold * bold) * Double(scale * scale)).rounded())
            let most = Int(300 + 12000 * detail * detail)
            let sizes = regions.area.sorted(by: >)
            if sizes.count > most { least = max(least, Int(sizes[most])) }
            labels = regions.withoutSpecks(labels, colors: palette.colors, least: least, faint: clean ? 0 : 40 + 122 * (1 - detail))
            regions = Regions.find(labels)
        }
        // Colours that run into each other were read as bands: each run one region again, and
        // its edges where its own colours put them.
        var blends: [Blend?] = []
        if !pixelArt, let found = blended(regions, labels: labels, raster: raster, colors: palette.colors, scale: scale, noise: noise, mixing: mixing) {
            regions = found.regions
            blends = found.blends
        }
        guard going(0.55) else { return .stopped }
        return .done(Reading(raster: raster, palette: palette, tints: tints, labels: labels, regions: regions, blends: blends, scale: scale, pixelArt: pixelArt,
                             clean: clean, wavers: !clean || rings, shrink: shrink, noise: noise, detail: detail, mixing: mixing))
    }

    /// A figure found in a picture that was made smaller to be traced, at the picture's own size.
    private static func scaled(_ figure: Figure, _ sx: Double, _ sy: Double) -> Figure? {
        guard abs(sx - 1) > 1e-9 || abs(sy - 1) > 1e-9 else { return figure }
        // Only when it was made smaller alike both ways does a circle stay one.
        guard abs(sx - sy) < 1e-3 else { return nil }
        switch figure {
        case .ellipse(let c, let rx, let ry, let angle):
            return .ellipse(center: Spot(c.x * sx, c.y * sy), radiusX: rx * sx, radiusY: ry * sx, angle: angle)
        case .rectangle(let c, let w, let h, let radius, let angle):
            return .rectangle(center: Spot(c.x * sx, c.y * sy), width: w * sx, height: h * sx, radius: radius * sx, angle: angle)
        }
    }
}

/// Something handed to the threads of `parallel` as it is, each writing its own part of it.
struct Sent<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set() { lock.lock(); on = true; lock.unlock() }
}

/// Counts in bins, added to from many threads.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var bins: [Int]
    init(bins: Int) { self.bins = [Int](repeating: 0, count: bins) }
    func add(_ more: [Int]) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<min(bins.count, more.count) { bins[i] += more[i] }
    }
    var total: Int { bins.reduce(0, +) }
    /// The bin, and how far into it, below which the share `q` of what was counted lies.
    func quantile(_ q: Double) -> Double {
        let all = total
        guard all > 0 else { return 0 }
        let target = q * Double(all)
        var seen = 0.0
        for (i, n) in bins.enumerated() {
            if seen + Double(n) >= target, n > 0 { return Double(i) + (target - seen) / Double(n) }
            seen += Double(n)
        }
        return Double(bins.count)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func add() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

// MARK: - As SVG

public extension Tracing {
    /// The tracing as an SVG file.
    func svg() -> String {
        func n(_ v: Double) -> String {
            let t = (v * 100).rounded() / 100
            return t == t.rounded() ? String(Int(t)) : String(t)
        }
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n"
        func hex(_ c: Tint) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        // The colours that run across shapes, each named by its shape's place.
        var defs = ""
        for (k, shape) in shapes.enumerated() {
            guard let blend = shape.blend else { continue }
            let stops = blend.stops.map { "<stop offset=\"\(n($0.offset))\" stop-color=\"\(hex($0.color))\"/>" }.joined()
            switch blend.kind {
            case .linear:
                defs += "<linearGradient id=\"b\(k)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(blend.start.x))\" y1=\"\(n(blend.start.y))\" x2=\"\(n(blend.end.x))\" y2=\"\(n(blend.end.y))\">\(stops)</linearGradient>\n"
            case .radial:
                let r = ((blend.end.x - blend.start.x) * (blend.end.x - blend.start.x) + (blend.end.y - blend.start.y) * (blend.end.y - blend.start.y)).squareRoot()
                defs += "<radialGradient id=\"b\(k)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(n(blend.start.x))\" cy=\"\(n(blend.start.y))\" r=\"\(n(r))\">\(stops)</radialGradient>\n"
            }
        }
        if !defs.isEmpty { out += "<defs>\n\(defs)</defs>\n" }
        for (k, shape) in shapes.enumerated() {
            var d = ""
            for outline in shape.outlines {
                d += "M\(n(outline.start.x)) \(n(outline.start.y))"
                for stretch in outline.stretches {
                    switch stretch {
                    case .line(let p): d += "L\(n(p.x)) \(n(p.y))"
                    case .curve(let a, let b, let p): d += "C\(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(p.x)) \(n(p.y))"
                    }
                }
                d += "Z"
            }
            out += "<path fill=\"\(shape.blend == nil ? hex(shape.color) : "url(#b\(k))")\" fill-rule=\"evenodd\" d=\"\(d)\"/>\n"
        }
        return out + "</svg>\n"
    }

    /// How many points its outlines have in all.
    var points: Int { shapes.reduce(0) { $0 + $1.outlines.reduce(0) { $0 + $1.stretches.count } } }
}
