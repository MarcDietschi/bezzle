import Foundation
import AppKit

// Text along a curve, as the Mac lays it (Bezzle/Canvas/CurvedText.swift): its words set as one
// line, each letter then placed on its own where it falls along the curve, its baseline the chord
// between where its two sides touch it. The page sets the line and draws each letter (the text
// call's "glyphs", and the drawing call `drawGlyph`); the placing is the Mac's, in the same
// numbers, but for Skia's letters standing with y running down where Core Text's run up.
//
// A page that cannot set letters one by one leaves the text straight, as it was before.

nonisolated enum CurvedText {
    // MARK: Walking along a curve

    /// A curve as a line of short straight steps, walked along by distance.
    final class Walk: @unchecked Sendable {
        let points: [CGPoint]
        /// How far along the curve each point lies.
        let lengths: [CGFloat]
        let closed: Bool
        var total: CGFloat { lengths.last ?? 0 }

        init(points: [CGPoint], closed: Bool) {
            self.points = points
            self.closed = closed
            var lengths: [CGFloat] = [0]
            lengths.reserveCapacity(points.count)
            for i in points.indices.dropFirst() {
                lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
            }
            self.lengths = lengths
        }

        /// Where the curve is `s` along it, and which way it runs there, in radians with y
        /// running down. Past the ends of an open curve it goes straight on; round a closed one,
        /// round again.
        func at(_ s: CGFloat) -> (point: CGPoint, angle: CGFloat) {
            guard points.count > 1, total > 0 else { return (points.first ?? .zero, 0) }
            var s = s
            if closed {
                s = s.truncatingRemainder(dividingBy: total)
                if s < 0 { s += total }
            }
            var i: Int
            if s <= 0 {
                i = 0
            } else if s >= total {
                i = points.count - 2
            } else {
                var lo = 0, hi = lengths.count - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if lengths[mid] <= s { lo = mid } else { hi = mid }
                }
                i = lo
            }
            let a = points[i], b = points[i + 1]
            let span = lengths[i + 1] - lengths[i]
            let t = span > 0 ? (s - lengths[i]) / span : 0
            return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
        }

        /// Where along the curve lies nearest `p`, and how far off it `p` is, plus which side:
        /// above zero to the left as the curve runs, which is above for a curve running right.
        func nearest(to p: CGPoint) -> (s: CGFloat, distance: CGFloat, side: CGFloat) {
            var best = (s: CGFloat(0), d2: CGFloat.greatestFiniteMagnitude, side: CGFloat(0))
            for i in 0..<max(points.count - 1, 0) {
                let a = points[i], b = points[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
                let t = len2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) : 0
                let q = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                let d2 = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
                if d2 < best.d2 {
                    // y runs down, so the side to the left of the way the curve runs is where
                    // the cross product is below zero.
                    let cross = dx * (p.y - a.y) - dy * (p.x - a.x)
                    best = (lengths[i] + (lengths[i + 1] - lengths[i]) * t, d2, cross <= 0 ? 1 : -1)
                }
            }
            return (best.s, sqrt(best.d2), best.side)
        }
    }

    private static let walks = Shared([String: Walk]())

    /// The first run of a path, walked along. When `oriented`, an open curve runs from its left end
    /// to its right, or up when it stands straight, and a closed one round the way a clock's
    /// hands go, so that words laid on it at first stand upright on its outside.
    static func walk(_ path: CGPath, oriented: Bool) -> Walk {
        let key = (oriented ? "o" : "a") + PathData.string(path)
        if let kept = walks.with({ $0[key] }) { return kept }
        var points: [CGPoint] = []
        var closed = false
        var done = false
        path.flattened(threshold: 0.08).applyWithBlock { element in
            guard !done else { return }
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if points.count > 1 { done = true } else { points = [e.points[0]] }
            case .addLineToPoint:
                let q = e.points[0]
                if let last = points.last, hypot(q.x - last.x, q.y - last.y) < 0.0001 { return }
                points.append(q)
            case .closeSubpath:
                closed = points.count > 2
                if closed, let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) > 0.0001 {
                    points.append(first)
                }
                done = true
            default:
                break
            }
        }
        if oriented, points.count > 1 {
            if closed {
                var area: CGFloat = 0
                for i in points.indices.dropLast() { area += points[i].x * points[i + 1].y - points[i + 1].x * points[i].y }
                if area < 0 { points.reverse() }
            } else {
                let a = points[0], b = points[points.count - 1]
                let dx = b.x - a.x, dy = b.y - a.y
                if abs(dx) > max(abs(dy) * 0.02, 0.0001) ? dx < 0 : dy > 0 { points.reverse() }
            }
        }
        let walk = Walk(points: points, closed: closed)
        walks.with {
            if $0.count > 600 { $0.removeAll() }
            $0[key] = walk
        }
        return walk
    }

    // MARK: Letters

    struct Letter {
        /// The line the page keeps it in, and its place there.
        let line: Int
        let index: Int
        let color: CGColor
        /// Whether its colour is its own, rather than the text's, which a gradient or a picture paints.
        let own: Bool
        /// From the letter's own space, its baseline's left end at zero and y running down, as
        /// Skia draws letters, into the layer's.
        let place: CGAffineTransform
        let advance: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let underline: Bool
        let strikethrough: Bool
        /// Its font's underline, below the baseline, and how thick it is, and its x height.
        let underlinePosition: CGFloat
        let thickness: CGFloat
        let xHeight: CGFloat
    }

    final class Laid: @unchecked Sendable {
        let letters: [Letter]
        /// The box round every letter as a line of type holds it, in the layer's coordinates.
        let box: CGRect
        /// The point the words are placed from, and which way the curve runs there as they read.
        let anchor: CGPoint
        let anchorAngle: CGFloat
        /// Where that point lies in the words set straight: 0 at their start, ½ in their middle, 1 at their end.
        let alignK: CGFloat
        let walk: Walk
        let reversed: Bool
        /// The main font's height above and below the baseline.
        let ascent: CGFloat
        let descent: CGFloat

        init(letters: [Letter], box: CGRect, anchor: CGPoint, anchorAngle: CGFloat, alignK: CGFloat, walk: Walk, reversed: Bool,
             ascent: CGFloat, descent: CGFloat) {
            self.letters = letters
            self.box = box
            self.anchor = anchor
            self.anchorAngle = anchorAngle
            self.alignK = alignK
            self.walk = walk
            self.reversed = reversed
            self.ascent = ascent
            self.descent = descent
        }
    }

    private struct Key: Hashable {
        let text: String
        let spans: [TextSpan]?
        let style: TextStyle
        let color: RGBA?
        let path: String
        let curve: TextCurve
    }

    private static let laidOut = Shared([Key: Laid]())

    /// A text on a curve laid along it, as it is drawn; nil for a straight one, and for one the
    /// page cannot set letter by letter.
    static func laid(_ node: Node) -> Laid? {
        guard node.kind == .text, let data = node.curvePath, let curve = node.curve, line(of: node) != nil else { return nil }
        let key = Key(text: node.text ?? "", spans: node.spans, style: node.style ?? TextStyle(), color: node.letterColor, path: data, curve: curve)
        if let kept = laidOut.with({ $0[key] }) { return kept }
        let laid = lay(node, along: PathData.cgPath(data), curve: curve)
        laidOut.with {
            if $0.count > 3000 { $0.removeAll() }
            $0[key] = laid
        }
        return laid
    }

    // MARK: The words as one line

    /// A text's words set as one line by the page: the line's number there, its width, its
    /// font's ascent, descent and cap height, and its letters.
    struct Line {
        struct Glyph {
            let run: Int
            let x, y, advance, ascent, descent, underline, thickness, xHeight: CGFloat
        }
        let id: Int
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let capHeight: CGFloat
        let glyphs: [Glyph]
        /// The runs the letters are of, as they were given: their colour, underline and strike.
        let runs: [[String: Any]]
    }

    private struct LineKey: Hashable {
        let text: String
        let spans: [TextSpan]?
        let style: TextStyle
        let color: RGBA?
    }

    /// The lines set, and those the page could not set (nil).
    private static let lines = Shared([LineKey: Line?]())

    /// Forgets every line set, as when the page has fonts it had not.
    static func forget() {
        lines.with { $0.removeAll() }
        laidOut.with { $0.removeAll() }
    }

    /// The words of a text as one line, breaks between lines and paragraphs as spaces.
    static func line(of node: Node) -> Line? {
        let key = LineKey(text: node.text ?? "", spans: node.spans, style: node.style ?? TextStyle(), color: node.letterColor)
        if let kept = lines.with({ $0[key] }) { return kept }
        let runs = TextLayout.runs(node).map { run -> [String: Any] in
            var r = run
            if let text = r["text"] as? String {
                r["text"] = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : $0 }))
            }
            return r
        }
        let spec: [String: Any] = ["glyphs": true, "runs": runs]
        let json = (try? JSONSerialization.data(withJSONObject: spec)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let answer = Host.call(.textLayout, string: json)
        var line: Line?
        if let data = answer.data(using: .utf8), let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = reply["id"] as? Int, let metrics = reply["line"] as? [Double], metrics.count >= 4,
           let glyphs = reply["glyphs"] as? [[Double]] {
            // The Mac's fonts' ascent and descent where they are known (MacFonts), which the
            // letters' boxes are made of there, rather than their stand-ins'.
            func mac(_ run: Int) -> (ascent: CGFloat, descent: CGFloat)? {
                guard run >= 0, run < runs.count,
                      let face = MacFonts.face(family: runs[run]["family"] as? String ?? TextStyle.system, face: runs[run]["face"] as? String ?? "") else { return nil }
                let size = CGFloat(runs[run]["size"] as? Double ?? 12)
                return (CGFloat(face.ascent) * size, CGFloat(face.descent) * size)
            }
            line = Line(id: id, width: CGFloat(metrics[0]), ascent: mac(0)?.ascent ?? CGFloat(metrics[1]), descent: mac(0)?.descent ?? CGFloat(metrics[2]),
                        capHeight: CGFloat(metrics[3]),
                        glyphs: glyphs.filter { $0.count >= 10 }.map {
                            let own = mac(Int($0[0]))
                            return Line.Glyph(run: Int($0[0]), x: CGFloat($0[1]), y: CGFloat($0[2]), advance: CGFloat($0[3]),
                                              ascent: own?.ascent ?? CGFloat($0[4]), descent: own?.descent ?? CGFloat($0[5]), underline: CGFloat($0[6]),
                                              thickness: CGFloat($0[7]), xHeight: CGFloat($0[8]))
                        },
                        runs: runs)
        }
        lines.with {
            if $0.count > 3000 { $0.removeAll() }
            $0[key] = .some(line)
        }
        return line
    }

    /// How long a text's words are set as one line.
    static func width(of node: Node) -> CGFloat {
        line(of: node)?.width ?? TextLayout.naturalWidth(node)
    }

    /// The arc a text bent `bend` of the way round a circle lies on: as long as its words, its
    /// middle at `apex`, running left to right.
    static func arc(for node: Node, apex: CGPoint, bend: Double) -> CGPath? {
        let w = width(of: node)
        let theta = CGFloat(min(abs(bend), 1)) * 2 * .pi
        guard w > 0.5, theta > 0 else { return nil }
        let r = w / theta
        let p = CGMutablePath()
        // In two halves, so that the middle is a point of the path exactly, as the arc is made again from it.
        if bend > 0 {
            let c = CGPoint(x: apex.x, y: apex.y + r)
            p.addArc(center: c, radius: r, startAngle: -.pi / 2 - theta / 2, endAngle: -.pi / 2, clockwise: false)
            p.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + theta / 2, clockwise: false)
        } else {
            let c = CGPoint(x: apex.x, y: apex.y - r)
            p.addArc(center: c, radius: r, startAngle: .pi / 2 + theta / 2, endAngle: .pi / 2, clockwise: true)
            p.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - theta / 2, clockwise: true)
        }
        return p
    }

    /// Where along a closed curve its top lies, or its bottom: the middle of its highest or
    /// lowest stretch.
    static func top(of walk: Walk, bottom: Bool) -> CGFloat {
        guard walk.points.count > 1, walk.total > 0 else { return 0 }
        let ys = walk.points.map(\.y)
        let edge = bottom ? ys.max()! : ys.min()!
        let xs = walk.points.map(\.x)
        let mid = (xs.min()! + xs.max()!) / 2
        var best: (s: CGFloat, off: CGFloat)?
        let steps = 720
        for k in 0..<steps {
            let s = walk.total * CGFloat(k) / CGFloat(steps)
            let p = walk.at(s).point
            guard abs(p.y - edge) <= 0.5 else { continue }
            let off = abs(p.x - mid)
            if best == nil || off < best!.off { best = (s, off) }
        }
        return best?.s ?? 0
    }

    /// Where a text is placed from along its curve when nothing says otherwise, as a share of it.
    static func defaultAt(_ walk: Walk, alignK k: CGFloat, curve: TextCurve) -> Double {
        if curve.bend != nil { return 0.5 }
        let reversed = curve.reversed == true
        if walk.closed, walk.total > 0 {
            // Placed upright: at the top, or reading backwards round it, at its bottom.
            return Double(top(of: walk, bottom: reversed) / walk.total)
        }
        return Double(reversed ? 1 - k : k)
    }

    /// Where along its curve a text is placed from, as a share of the curve.
    static func at(of node: Node) -> Double {
        if let at = node.curve?.at { return at }
        guard let laid = laid(node), let curve = node.curve else { return 0 }
        return defaultAt(laid.walk, alignK: laid.alignK, curve: curve)
    }

    /// Where a text is placed from as a share of its words: closed curves and arcs hold them by
    /// their middle; open ones as the text is aligned.
    static func alignK(_ node: Node, closed: Bool) -> CGFloat {
        if node.curve?.bend != nil || closed { return 0.5 }
        switch node.style?.align ?? .left {
        case .left, .justify: return 0
        case .center: return 0.5
        case .right: return 1
        }
    }

    /// Lays a text's letters along `path`, in its own coordinates.
    static func lay(_ node: Node, along path: CGPath, curve: TextCurve) -> Laid {
        let walk = walk(path, oriented: curve.bend == nil)
        guard let line = line(of: node) else {
            // A page that cannot set letters one by one: the text keeps its frame, drawn straight.
            let box = CGRect(origin: .zero, size: node.frame.size)
            return Laid(letters: [], box: box, anchor: CGPoint(x: box.midX, y: box.midY), anchorAngle: 0, alignK: 0.5, walk: walk,
                        reversed: false, ascent: 0, descent: 0)
        }
        let width = line.width
        let k = alignK(node, closed: walk.closed)
        let reversed = curve.reversed == true && curve.bend == nil
        let hang: CGFloat = curve.hangs == true && curve.bend == nil ? line.capHeight : 0
        let total = walk.total
        let at = CGFloat(curve.at ?? defaultAt(walk, alignK: k, curve: curve)) * total
        let read = reversed ? total - at : at
        let start = read - width * k
        func spot(_ s: CGFloat) -> (point: CGPoint, angle: CGFloat) {
            guard reversed else { return walk.at(s) }
            let (p, a) = walk.at(total - s)
            return (p, a + .pi)
        }
        func chord(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let p = spot(a).point, q = spot(b).point
            return hypot(q.x - p.x, q.y - p.y) > 0.0001 ? atan2(q.y - p.y, q.x - p.x) : spot((a + b) / 2).angle
        }

        var letters: [Letter] = []
        var box = CGRect.null
        let runs = line.runs
        let looks = node.runs
        for (i, g) in line.glyphs.enumerated() {
            let run = g.run < runs.count ? runs[g.run] : [:]
            let rgba = (run["color"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            let color = rgba.count == 4 ? CGColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3])) : CGColor(gray: 0, alpha: 0)
            let middle = start + g.x + g.advance / 2
            let p = spot(middle).point
            let angle = g.advance > 0.01 ? chord(start + g.x, start + g.x + g.advance) : spot(middle).angle
            // The Mac's placing, but for the letter standing on its baseline with y running down.
            let place = CGAffineTransform(translationX: -g.advance / 2, y: hang + g.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
            letters.append(Letter(line: line.id, index: i, color: color, own: g.run < looks.count && looks[g.run].look.color != nil,
                                  place: place, advance: g.advance, ascent: g.ascent, descent: g.descent,
                                  underline: run["underline"] as? Bool ?? false, strikethrough: run["strike"] as? Bool ?? false,
                                  underlinePosition: g.underline, thickness: g.thickness, xHeight: g.xHeight))
            box = box.union(CGRect(x: 0, y: -g.ascent, width: max(g.advance, 0.01), height: g.ascent + g.descent).applying(place))
        }
        let (anchor, _) = spot(read)
        let anchorAngle = chord(read - 1, read + 1)
        let ascent = line.ascent, descent = line.descent
        if box.isNull {
            // No words: as tall as a line, where they would begin.
            box = CGRect(x: 0, y: -ascent, width: 1, height: ascent + descent).applying(
                CGAffineTransform(translationX: 0, y: hang)
                    .concatenating(CGAffineTransform(rotationAngle: anchorAngle)).concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
        }
        return Laid(letters: letters, box: box, anchor: anchor, anchorAngle: anchorAngle, alignK: k, walk: walk, reversed: reversed,
                    ascent: ascent, descent: descent)
    }

    // MARK: Drawing

    /// Draws the letters in the layer's own coordinates, those of the text's own colour painted
    /// by `painting` when that is a gradient or a picture.
    static func draw(_ laid: Laid, in ctx: CGContext, painting: ((CGContext) -> Void)? = nil) {
        guard let painting else {
            draw(laid.letters[...], in: ctx)
            return
        }
        draw(laid.letters.filter(\.own)[...], in: ctx)
        let painted = laid.letters.filter { !$0.own }
        guard !painted.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let room = laid.box.insetBy(dx: -max(laid.box.height, 24), dy: -max(laid.box.height, 24))
        ctx.beginTransparencyLayer(in: room, auxiliaryInfo: nil)
        draw(painted[...], in: ctx)
        ctx.setBlendMode(.sourceIn)
        ctx.beginTransparencyLayer(in: room, auxiliaryInfo: nil)
        ctx.saveGState()
        painting(ctx)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.endTransparencyLayer()
    }

    private static func draw(_ letters: ArraySlice<Letter>, in ctx: CGContext) {
        for letter in letters where letter.color.alpha > 0 {
            ctx.saveGState()
            ctx.concatenate(letter.place)
            ctx.drawGlyph(letter.index, of: letter.line, color: letter.color)
            let rules = rules(of: letter)
            if !rules.isEmpty {
                ctx.setFillColor(letter.color)
                for rule in rules { ctx.fill(rule) }
            }
            ctx.restoreGState()
        }
    }

    /// The bits of the line under the letter, and through it, in its own space (y down).
    static func rules(of letter: Letter) -> [CGRect] {
        var out: [CGRect] = []
        let thickness = max(letter.thickness, 0.5)
        if letter.underline {
            out.append(CGRect(x: 0, y: letter.underlinePosition - thickness / 2, width: letter.advance, height: thickness))
        }
        if letter.strikethrough {
            out.append(CGRect(x: 0, y: -letter.xHeight / 2 - thickness / 2, width: letter.advance, height: thickness))
        }
        return out
    }

    // MARK: Picking

    /// Whether a point of the layer's own coordinates falls on one of the letters, as a line of
    /// type holds it, give or take `tolerance`.
    static func hits(_ laid: Laid, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        laid.letters.contains { letter in
            let g = p.applying(letter.place.inverted())
            return g.x >= -tolerance && g.x <= letter.advance + tolerance && g.y >= -letter.ascent - tolerance && g.y <= letter.descent + tolerance
        }
    }
}
