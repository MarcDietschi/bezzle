import CoreGraphics
import Foundation
import Vectorizer

// Drawings for what the engine finds hard, each with its own measure beside how far the edges lie
// from the truth: thin lines in a picture that wavers (how even their thickness comes out), a
// textured picture (how many shapes it becomes), colours running across shapes (whether they are
// found as gradients, and how far the colours are off), and small text (how many of its pieces
// are kept, and how many of its counters stay open).

/// A line of one thickness along a path, `at` giving the path's place for 0…1.
struct Stroke {
    let width: Double
    let color: UInt32
    let at: (Double) -> CGPoint

    func draw(_ ctx: CGContext) {
        ctx.setStrokeColor(rgb(color)); ctx.setLineWidth(CGFloat(width)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.move(to: at(0))
        for k in 1...600 { ctx.addLine(to: at(Double(k) / 600)) }
        ctx.strokePath()
    }
}

/// A line from `a` to `b` drawn as by hand: it wanders a few pixels to both sides on its way.
func wobbly(_ a: CGPoint, _ b: CGPoint, sway: Double = 3, seed: Double) -> (Double) -> CGPoint {
    let d = CGPoint(x: b.x - a.x, y: b.y - a.y), l = hypot(d.x, d.y)
    let n = CGPoint(x: -d.y / l, y: d.x / l)
    return { s in
        let off = sway * sin(2 * .pi * 2.3 * s + seed) + 0.4 * sway * sin(2 * .pi * 6.1 * s + 2.7 * seed)
        return CGPoint(x: a.x + d.x * s + n.x * off, y: a.y + d.y * s + n.y * off)
    }
}

let wobblyStrokes: [Stroke] = [
    Stroke(width: 1, color: 0x1E2A3A, at: wobbly(CGPoint(x: 18, y: 26.3), CGPoint(x: 302, y: 40.6), seed: 0.4)),
    Stroke(width: 1.5, color: 0x1E2A3A, at: wobbly(CGPoint(x: 18, y: 58.7), CGPoint(x: 302, y: 78.2), seed: 1.9)),
    Stroke(width: 2, color: 0x1E2A3A, at: wobbly(CGPoint(x: 18, y: 96.2), CGPoint(x: 302, y: 112.9), seed: 3.1)),
    Stroke(width: 3, color: 0x1E2A3A, at: wobbly(CGPoint(x: 18, y: 134.4), CGPoint(x: 302, y: 150.1), seed: 4.6)),
    Stroke(width: 1.5, color: 0xC8341F, at: wobbly(CGPoint(x: 40.5, y: 206), CGPoint(x: 150.2, y: 168), sway: 2, seed: 0.9)),
    Stroke(width: 1, color: 0xC8341F, at: wobbly(CGPoint(x: 170.5, y: 168), CGPoint(x: 296.2, y: 208), sway: 2, seed: 2.2)),
]

let wobblyLines: (CGContext) -> Void = { ctx in
    ctx.setFillColor(rgb(0xF6F1E7)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 220))
    for stroke in wobblyStrokes { stroke.draw(ctx) }
}

/// Numbers that come the same every time, 0…1.
struct Dice {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) % 1_000_000) / 1_000_000
    }
}

/// Flat shapes under a grain and a weave, as a printed or painted picture has them: the shapes
/// are what it is made of, eight of them, the texture is not.
let textured: (CGContext) -> Void = { ctx in
    ctx.setFillColor(rgb(0xEADFC8)); ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 260))
    ctx.setFillColor(rgb(0x2F5D50)); ctx.fill(CGRect(x: 0, y: 170, width: 360, height: 90))
    ctx.setFillColor(rgb(0xD9642B)); ctx.fillEllipse(in: CGRect(x: 40.5, y: 30.5, width: 120, height: 120))
    ctx.setFillColor(rgb(0x1F3A5F))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 190.5, y: 40.5, width: 130, height: 90), cornerWidth: 16, cornerHeight: 16, transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0xF2C14E)); ctx.addPath(star(CGPoint(x: 255, y: 85), 34, 14)); ctx.fillPath()
    ctx.setFillColor(rgb(0xB23A48))
    ctx.move(to: CGPoint(x: 60, y: 240)); ctx.addLine(to: CGPoint(x: 130, y: 185)); ctx.addLine(to: CGPoint(x: 200, y: 240)); ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(rgb(0xEADFC8)); ctx.fillEllipse(in: CGRect(x: 240, y: 190, width: 80, height: 50))
    ctx.setFillColor(rgb(0x1F3A5F)); ctx.fillEllipse(in: CGRect(x: 262, y: 203, width: 36, height: 24))
    // The grain: specks a little darker or lighter than what they lie on, all over.
    var dice = Dice(seed: 0xB5AD_4ECE_DA1C_E2A9)
    for _ in 0..<5200 {
        let x = dice.next() * 360, y = dice.next() * 260, r = 0.35 + 0.6 * dice.next()
        let dark = dice.next() < 0.5
        ctx.setFillColor(CGColor(srgbRed: dark ? 0 : 1, green: dark ? 0 : 1, blue: dark ? 0 : 1, alpha: 0.06 + 0.12 * dice.next()))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    // The weave: faint threads across the lower half.
    ctx.setLineWidth(0.7)
    for k in 0..<45 {
        let y = 172.0 + Double(k) * 2.0 + dice.next()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05 + 0.06 * dice.next()))
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: 360, y: y + 3 * (dice.next() - 0.5))); ctx.strokePath()
    }
}

func gradient(_ colors: [UInt32], _ places: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors.map { rgb($0) } as CFArray, locations: places)!
}

/// Colours running across the paper and across shapes, with flat shapes on top of them.
let gradients: (CGContext) -> Void = { ctx in
    let all: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    // The paper: from one corner to the other.
    ctx.drawLinearGradient(gradient([0x1B3B6F, 0x7B4B94], [0, 1]), start: CGPoint(x: 20, y: 10), end: CGPoint(x: 340, y: 230), options: all)
    // A ball, lit from the upper left.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 30.5, y: 40.5, width: 120, height: 120)); ctx.clip()
    ctx.drawRadialGradient(gradient([0xFFE9A8, 0xF08A24, 0x9C2F0B], [0, 0.55, 1]), startCenter: CGPoint(x: 72, y: 80), startRadius: 0,
                           endCenter: CGPoint(x: 72, y: 80), endRadius: 95, options: all)
    ctx.restoreGState()
    // A card, three colours from top to bottom, with a flat star and a flat line on it.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 190.5, y: 30.5, width: 140, height: 110), cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(gradient([0x9BE7C4, 0x2FA39A, 0x135E6B], [0, 0.5, 1]), start: CGPoint(x: 0, y: 30.5), end: CGPoint(x: 0, y: 140.5), options: all)
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.addPath(star(CGPoint(x: 260, y: 82), 30, 12)); ctx.fillPath()
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: 206, y: 124)); ctx.addLine(to: CGPoint(x: 314, y: 124)); ctx.strokePath()
    // A flat bar across the paper, and a pill whose colours run level.
    ctx.setFillColor(rgb(0x101820)); ctx.fill(CGRect(x: 0, y: 196, width: 360, height: 12))
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 60.5, y: 170.5, width: 240, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(gradient([0xFF5F6D, 0xFFC371], [0, 1]), start: CGPoint(x: 60.5, y: 0), end: CGPoint(x: 300.5, y: 0), options: all)
    ctx.restoreGState()
}

func tinyText(_ ctx: CGContext, ink: UInt32) {
    text(ctx, "Sphinx of black quartz, judge my vow.", at: CGPoint(x: 8, y: 16), size: 10, font: "Helvetica", color: rgb(ink))
    text(ctx, "Pack my box with five dozen liquor jugs:", at: CGPoint(x: 8, y: 32), size: 10, font: "Times-Roman", color: rgb(ink))
    text(ctx, "How vexingly quick daft zebras jump; 0123456789", at: CGPoint(x: 8, y: 48), size: 10, font: "Helvetica-Bold", color: rgb(ink))
    text(ctx, "àéîõü ß & @ fi fl (i.j) 1/4 #", at: CGPoint(x: 8, y: 64), size: 10, font: "Georgia", color: rgb(ink))
}

let gapSamples: [Sample] = [
    Sample(name: "wobbly-lines", size: CGSize(width: 320, height: 220), jpeg: 0.6, strokes: wobblyStrokes, paper: 0xF6F1E7, draw: wobblyLines),
    Sample(name: "wobbly-clean", size: CGSize(width: 320, height: 220), strokes: wobblyStrokes, paper: 0xF6F1E7, draw: wobblyLines),
    Sample(name: "textured", size: CGSize(width: 360, height: 260), jpeg: 0.7, shapes: 8, draw: textured),
    Sample(name: "gradients", size: CGSize(width: 360, height: 240), shapes: 7, blends: 4, draw: gradients),
    Sample(name: "gradients-jpeg", size: CGSize(width: 360, height: 240), jpeg: 0.7, shapes: 7, blends: 4, draw: gradients),
    Sample(name: "text-10pt", size: CGSize(width: 260, height: 74), paper: 0xFFFFFF, letters: 0x14213D) { ctx in
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 260, height: 74))
        tinyText(ctx, ink: 0x14213D)
    },
    Sample(name: "text-10pt@2x", size: CGSize(width: 520, height: 148), paper: 0xFFFFFF, letters: 0x14213D) { ctx in
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 520, height: 148))
        ctx.scaleBy(x: 2, y: 2)
        tinyText(ctx, ink: 0x14213D)
    },
    Sample(name: "text-10pt-light", size: CGSize(width: 260, height: 74), paper: 0x22313F, letters: 0xF4F1DE) { ctx in
        ctx.setFillColor(rgb(0x22313F)); ctx.fill(CGRect(x: 0, y: 0, width: 260, height: 74))
        tinyText(ctx, ink: 0xF4F1DE)
    },
    Sample(name: "text-10pt-jpeg", size: CGSize(width: 260, height: 74), jpeg: 0.8, paper: 0xFFFFFF, letters: 0x14213D) { ctx in
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 260, height: 74))
        tinyText(ctx, ink: 0x14213D)
    },
]

// MARK: Measures

/// Which pixels of a picture are nearer `ink` than `paper`.
func inked(_ b: Bitmap, ink: UInt32, paper: UInt32) -> [Bool] {
    func parts(_ v: UInt32) -> (Int, Int, Int) { (Int((v >> 16) & 255), Int((v >> 8) & 255), Int(v & 255)) }
    let i = parts(ink), p = parts(paper)
    var out = [Bool](repeating: false, count: b.width * b.height)
    for k in 0..<(b.width * b.height) {
        let r = Int(b.pixels[k * 4]), g = Int(b.pixels[k * 4 + 1]), bl = Int(b.pixels[k * 4 + 2])
        let toInk = (r - i.0) * (r - i.0) + (g - i.1) * (g - i.1) + (bl - i.2) * (bl - i.2)
        let toPaper = (r - p.0) * (r - p.0) + (g - p.1) * (g - p.1) + (bl - p.2) * (bl - p.2)
        out[k] = toInk < toPaper
    }
    return out
}

/// How thick a line comes out along its length in a tracing drawn `zoom` times its size: the
/// mean, how much it wavers (the spread about a mean that moves slowly along the line), how far
/// its middle lies from where the line was drawn, and how much of its length is missing.
func thickness(of stroke: Stroke, in traced: Bitmap, zoom: Int, paper: UInt32) -> (mean: Double, wavers: Double, off: Double, missing: Double) {
    let ink = inked(traced, ink: stroke.color, paper: paper)
    let z = Double(zoom)
    func isInk(_ p: CGPoint) -> Bool {
        let x = Int(p.x * z), y = Int(p.y * z)
        guard x >= 0, y >= 0, x < traced.width, y < traced.height else { return false }
        return ink[y * traced.width + x]
    }
    var widths: [Double] = [], offs: [Double] = []
    var missing = 0
    let count = 400, step = 0.5 / z
    for k in 0..<count {
        let s = 0.05 + 0.9 * Double(k) / Double(count - 1)
        let c = stroke.at(s), a = stroke.at(s - 0.002), b = stroke.at(s + 0.002)
        let l = hypot(b.x - a.x, b.y - a.y)
        let n = CGPoint(x: -(b.y - a.y) / l, y: (b.x - a.x) / l)
        func along(_ t: Double) -> CGPoint { CGPoint(x: c.x + n.x * t, y: c.y + n.y * t) }
        // The nearest ink to the middle, a pixel and a half either way.
        var from: Double?
        var t = 0.0
        while t <= 1.5 {
            if isInk(along(t)) { from = t; break }
            if isInk(along(-t)) { from = -t; break }
            t += step
        }
        guard let from else { missing += 1; continue }
        var hi = from, lo = from
        while hi - from < 8, isInk(along(hi + step)) { hi += step }
        while from - lo < 8, isInk(along(lo - step)) { lo -= step }
        widths.append(hi - lo + step)
        offs.append((hi + lo) / 2)
    }
    guard widths.count >= 20 else { return (0, 0, 0, 1) }
    let mean = widths.reduce(0, +) / Double(widths.count)
    // Against the mean of the forty measures round each: the line's own slow changes left out.
    var sum = 0.0
    for i in widths.indices {
        let a = max(0, i - 20), b = min(widths.count - 1, i + 20)
        let near = widths[a...b].reduce(0, +) / Double(b - a + 1)
        sum += (widths[i] - near) * (widths[i] - near)
    }
    let off = (offs.reduce(0) { $0 + $1 * $1 } / Double(offs.count)).squareRoot()
    return (mean, (sum / Double(widths.count)).squareRoot(), off, Double(missing) / Double(count))
}

/// The pieces of a picture's ink, and the pieces of its paper that ink goes all the way round
/// (the counters of letters): each sample its piece's number, -1 for none; and how many pieces.
func pieces(_ ink: [Bool], _ w: Int, _ h: Int) -> (ink: [Int32], inks: Int, holes: [Int32], holeCount: Int) {
    func label(_ of: Bool, eight: Bool) -> ([Int32], [Bool], Int) {
        var id = [Int32](repeating: -1, count: w * h)
        var touches: [Bool] = []
        var n = 0
        var stack: [Int] = []
        for first in 0..<(w * h) where ink[first] == of && id[first] < 0 {
            id[first] = Int32(n)
            stack = [first]
            var edge = false
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { edge = true }
                for dy in -1...1 {
                    for dx in -1...1 where (dx != 0 || dy != 0) && (eight || dx == 0 || dy == 0) {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        if ink[j] == of, id[j] < 0 { id[j] = Int32(n); stack.append(j) }
                    }
                }
            }
            touches.append(edge)
            n += 1
        }
        return (id, touches, n)
    }
    let (inkID, _, inks) = label(true, eight: true)
    var (paperID, touches, papers) = label(false, eight: false)
    // Only the paper that does not reach the picture's edge is a hole; numbered anew.
    var renamed = [Int32](repeating: -1, count: papers)
    var holes = 0
    for k in 0..<papers where !touches[k] { renamed[k] = Int32(holes); holes += 1 }
    for i in 0..<(w * h) where paperID[i] >= 0 { paperID[i] = renamed[Int(paperID[i])] }
    return (inkID, inks, paperID, holes)
}

/// How a tracing's letters hold up against the drawn ones, both `zoom` times their size: how
/// many of the drawn pieces of ink are there (at least half of each inked), how many of the
/// counters are open (at least half of each left paper), how many traced pieces run two drawn
/// ones together, and how many traced pieces are where nothing was drawn.
func letters(traced: Bitmap, truth: Bitmap, ink: UInt32, paper: UInt32) -> String {
    let w = truth.width, h = truth.height
    guard traced.width == w, traced.height == h else { return "sizes differ" }
    let was = inked(truth, ink: ink, paper: paper), now = inked(traced, ink: ink, paper: paper)
    let a = pieces(was, w, h), b = pieces(now, w, h)
    var size = [Int](repeating: 0, count: a.inks), covered = [Int](repeating: 0, count: a.inks)
    var holeSize = [Int](repeating: 0, count: a.holeCount), open = [Int](repeating: 0, count: a.holeCount)
    var over = [Set<Int32>](repeating: [], count: b.inks)
    for i in 0..<(w * h) {
        if a.ink[i] >= 0 {
            size[Int(a.ink[i])] += 1
            if now[i] { covered[Int(a.ink[i])] += 1 }
        }
        if a.holes[i] >= 0 {
            holeSize[Int(a.holes[i])] += 1
            if !now[i] { open[Int(a.holes[i])] += 1 }
        }
        if b.ink[i] >= 0, a.ink[i] >= 0 { over[Int(b.ink[i])].insert(a.ink[i]) }
    }
    // A speck of a few samples is the drawing's own soft edge, not a piece.
    let least = 6
    let real = (0..<a.inks).filter { size[$0] >= least }, realHoles = (0..<a.holeCount).filter { holeSize[$0] >= least }
    let kept = real.filter { covered[$0] * 2 >= size[$0] }.count
    let opened = realHoles.filter { open[$0] * 2 >= holeSize[$0] }.count
    let joined = over.filter { $0.filter { size[Int($0)] >= least }.count >= 2 }.count
    var tracedSize = [Int](repeating: 0, count: b.inks)
    for i in 0..<(w * h) where b.ink[i] >= 0 { tracedSize[Int(b.ink[i])] += 1 }
    let stray = (0..<b.inks).filter { over[$0].isEmpty && tracedSize[$0] >= least }.count
    return "pieces \(kept) of \(real.count), counters open \(opened) of \(realHoles.count), run together \(joined), stray \(stray)"
}
