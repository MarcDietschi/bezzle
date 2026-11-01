import AppKit
import CoreText

/// Laying a text's letters along a curve (see `TextCurve`): its words set as one line, each
/// letter then placed on its own where it falls along the curve, its baseline the chord between
/// where its two sides touch it, so that letters sit as snugly on a tight bend as on a corner.
///
/// Not tied to the main thread: tiles are drawn on several threads at once, so what is kept
/// between layouts is behind a lock, and every layout, once made, is never changed.
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
        let font: CTFont
        let glyph: CGGlyph
        let color: CGColor
        /// Whether its colour is its own, rather than the text's, which a gradient or a picture paints.
        let own: Bool
        /// From the letter's own space, its baseline's left end at zero and y running up, as fonts
        /// have it, into the layer's.
        let place: CGAffineTransform
        let advance: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let underline: Bool
        let strikethrough: Bool
        /// The letters of the words it draws: more than one for a ligature.
        let characters: NSRange
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
        /// The words as one line, as they are laid.
        let string: String
        /// The main font's height above and below the baseline.
        let ascent: CGFloat
        let descent: CGFloat

        init(letters: [Letter], box: CGRect, anchor: CGPoint, anchorAngle: CGFloat, alignK: CGFloat, walk: Walk, reversed: Bool,
             string: String, ascent: CGFloat, descent: CGFloat) {
            self.letters = letters
            self.box = box
            self.anchor = anchor
            self.anchorAngle = anchorAngle
            self.alignK = alignK
            self.walk = walk
            self.reversed = reversed
            self.string = string
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

    /// A text on a curve laid along it, as it is drawn; nil for a straight one.
    static func laid(_ node: Node) -> Laid? {
        guard node.kind == .text, let data = node.curvePath, let curve = node.curve else { return nil }
        let key = Key(text: node.text ?? "", spans: node.spans, style: node.style ?? TextStyle(), color: node.letterColor, path: data, curve: curve)
        if let kept = laidOut.with({ $0[key] }) { return kept }
        let laid = lay(node, along: PathData.cgPath(data), curve: curve)
        laidOut.with {
            if $0.count > 3000 { $0.removeAll() }
            $0[key] = laid
        }
        return laid
    }

    /// The words of a text as one line: breaks between lines and paragraphs become spaces.
    static func words(of node: Node) -> NSAttributedString {
        let words = NSMutableAttributedString(attributedString: TextLayout.attributed(node))
        let string = words.string as NSString
        for i in 0..<string.length {
            if let scalar = Unicode.Scalar(string.character(at: i)), CharacterSet.newlines.contains(scalar) {
                words.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            }
        }
        return words
    }

    static func line(of node: Node) -> CTLine {
        CTLineCreateWithAttributedString(words(of: node))
    }

    /// How long a text's words are set as one line.
    static func width(of node: Node) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(of: node), nil, nil, nil))
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
        let words = words(of: node)
        let line = CTLineCreateWithAttributedString(words)
        let string = words.string
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let main = Fonts.font(node.style ?? TextStyle()) as CTFont
        let k = alignK(node, closed: walk.closed)
        let reversed = curve.reversed == true && curve.bend == nil
        let hang: CGFloat = curve.hangs == true && curve.bend == nil ? CTFontGetCapHeight(main) : 0
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
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary as? [NSAttributedString.Key: Any] ?? [:]
            let font = (attrs[.font] as? NSFont).map { $0 as CTFont } ?? main
            let color = (attrs[.foregroundColor] as? NSColor)?.cgColor ?? CGColor(gray: 0, alpha: 0)
            let own = (attrs[.bezzleLook] as? LookBox)?.look.color != nil
            let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            let strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count), indices = [CFIndex](repeating: 0, count: count)
            let all = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, all, &glyphs)
            CTRunGetPositions(run, all, &positions)
            CTRunGetAdvances(run, all, &advances)
            CTRunGetStringIndices(run, all, &indices)
            let runEnd = CTRunGetStringRange(run).location + CTRunGetStringRange(run).length
            for i in 0..<count {
                let x = positions[i].x, advance = advances[i].width
                let middle = start + x + advance / 2
                let p = spot(middle).point
                let angle = advance > 0.01 ? chord(start + x, start + x + advance) : spot(middle).angle
                let place = CGAffineTransform(scaleX: 1, y: -1)
                    .concatenating(CGAffineTransform(translationX: -advance / 2, y: hang - positions[i].y))
                    .concatenating(CGAffineTransform(rotationAngle: angle))
                    .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
                let next = i + 1 < count ? indices[i + 1] : runEnd
                let characters = NSRange(location: indices[i], length: max(next - indices[i], 1))
                letters.append(Letter(font: font, glyph: glyphs[i], color: color, own: own, place: place, advance: advance,
                                      ascent: ascent, descent: descent, underline: underline, strikethrough: strikethrough, characters: characters))
                box = box.union(CGRect(x: 0, y: -descent, width: max(advance, 0.01), height: ascent + descent).applying(place))
            }
        }
        let (anchor, _) = spot(read)
        let anchorAngle = chord(read - 1, read + 1)
        let ascent = CTFontGetAscent(main), descent = CTFontGetDescent(main)
        if box.isNull {
            // No words: as tall as a line, where they would begin.
            box = CGRect(x: 0, y: -descent, width: 1, height: ascent + descent).applying(
                CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: hang))
                    .concatenating(CGAffineTransform(rotationAngle: anchorAngle)).concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
        }
        return Laid(letters: letters, box: box, anchor: anchor, anchorAngle: anchorAngle, alignK: k, walk: walk, reversed: reversed,
                    string: string, ascent: ascent, descent: descent)
    }

    // MARK: Drawing

    /// Draws the letters in the layer's own coordinates, those of the text's own colour painted
    /// by `painting` when that is a gradient or a picture. See `TextLayout.Manager.painting`.
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
        if ctx.width == 0 {
            // A PDF keeps the paint sharp cut to the letters' outlines.
            let outlines = CGMutablePath()
            for letter in painted { add(letter, to: outlines, transform: .identity) }
            guard !outlines.isEmpty else { return }
            ctx.addPath(outlines)
            ctx.clip()
            painting(ctx)
            return
        }
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
            ctx.textMatrix = .identity
            ctx.setFillColor(letter.color)
            var glyph = letter.glyph, origin = CGPoint.zero
            CTFontDrawGlyphs(letter.font, &glyph, &origin, 1, ctx)
            for rule in rules(of: letter) { ctx.fill(rule) }
            ctx.restoreGState()
        }
    }

    /// The bits of the line under the letter, and through it, in its own space.
    private static func rules(of letter: Letter) -> [CGRect] {
        var out: [CGRect] = []
        let thickness = max(CTFontGetUnderlineThickness(letter.font), 0.5)
        if letter.underline {
            out.append(CGRect(x: 0, y: CTFontGetUnderlinePosition(letter.font) - thickness / 2, width: letter.advance, height: thickness))
        }
        if letter.strikethrough {
            out.append(CGRect(x: 0, y: CTFontGetXHeight(letter.font) / 2 - thickness / 2, width: letter.advance, height: thickness))
        }
        return out
    }

    /// Adds a letter's outline to `path`, placed as it is drawn and then carried by `transform`.
    static func add(_ letter: Letter, to path: CGMutablePath, transform: CGAffineTransform) {
        var place = letter.place.concatenating(transform)
        if let glyph = CTFontCreatePathForGlyph(letter.font, letter.glyph, &place) { path.addPath(glyph) }
        for rule in rules(of: letter) { path.addRect(rule, transform: place) }
    }

    /// The outlines of all the letters, in the layer's own coordinates.
    static func outlines(_ laid: Laid) -> CGPath {
        let path = CGMutablePath()
        for letter in laid.letters { add(letter, to: path, transform: .identity) }
        return path
    }

    // MARK: Picking

    /// Whether a point of the layer's own coordinates falls on one of the letters, as a line of
    /// type holds it, give or take `tolerance`.
    static func hits(_ laid: Laid, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        laid.letters.contains { letter in
            let g = p.applying(letter.place.inverted())
            return g.x >= -tolerance && g.x <= letter.advance + tolerance && g.y >= -letter.descent - tolerance && g.y <= letter.ascent + tolerance
        }
    }

    // MARK: Straight

    /// A straight text's letters as it is drawn, each placed as those along a curve are, in its
    /// own coordinates: for letters going onto a curve and coming off it.
    static func straightLetters(_ node: Node) -> [Letter] {
        let laid = TextLayout.layout(node)
        let manager = laid.manager, storage = laid.storage
        guard storage.length > 0 else { return [] }
        let down = TextLayout.offset(node)
        let glyphs = manager.glyphRange(for: laid.container)
        var letters: [Letter] = []
        letters.reserveCapacity(glyphs.length)
        for g in glyphs.location..<NSMaxRange(glyphs) {
            let property = manager.propertyForGlyph(at: g)
            if property.contains(.controlCharacter) || property.contains(.null) || property.contains(.elastic) { continue }
            let at = manager.characterIndexForGlyph(at: g)
            guard at < storage.length, let font = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont else { continue }
            let attrs = storage.attributes(at: at, effectiveRange: nil)
            let fragment = manager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let place = manager.location(forGlyphAt: g)
            let lift = attrs[.baselineOffset] as? CGFloat ?? 0
            var glyph = manager.cgGlyph(at: g)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let origin = CGPoint(x: fragment.minX + place.x, y: fragment.minY + place.y + down - lift)
            let ctFont = font as CTFont
            letters.append(Letter(font: ctFont, glyph: glyph, color: (attrs[.foregroundColor] as? NSColor)?.cgColor ?? CGColor(gray: 0, alpha: 0),
                                  own: (attrs[.bezzleLook] as? LookBox)?.look.color != nil,
                                  place: CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)),
                                  advance: advance.width, ascent: CTFontGetAscent(ctFont), descent: CTFontGetDescent(ctFont),
                                  underline: (attrs[.underlineStyle] as? Int ?? 0) != 0, strikethrough: (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
                                  characters: NSRange(location: at, length: 1)))
        }
        return letters
    }

    // MARK: Typing

    /// A text on a curve as it is typed into: straight, in a frame of the size its words take,
    /// placed and turned so that the point its words are placed from stays where it is and the
    /// words run as the curve does there. `frame` is the layer's frame where it is wanted, such
    /// as on the canvas. The text as it is, for one that is straight.
    static func straight(_ node: Node, frame: CGRect) -> (node: Node, frame: CGRect) {
        guard node.isCurved, let laid = laid(node) else { return (node, frame) }
        var flat = node
        flat.curve = nil
        flat.curvePath = nil
        flat.frame = frame
        let fitted = TextLayout.fittedFrame(flat)
        let v = Geometry.rotate(CGPoint(x: laid.anchor.x - frame.width / 2, y: laid.anchor.y - frame.height / 2), by: node.rotation)
        let page = CGPoint(x: frame.midX + v.x, y: frame.midY + v.y)
        var turn = node.rotation + Double(laid.anchorAngle * 180 / .pi)
        turn = turn.truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn -= 360 }
        if turn <= -180 { turn += 360 }
        flat.rotation = (turn * 100).rounded() / 100
        let rest = CGPoint(x: laid.alignK * fitted.width, y: TextLayout.firstBaseline(Node.with(flat, frame: fitted)))
        let w = Geometry.rotate(CGPoint(x: rest.x - fitted.width / 2, y: rest.y - fitted.height / 2), by: flat.rotation)
        let placed = CGRect(x: page.x - w.x - fitted.width / 2, y: page.y - w.y - fitted.height / 2, width: fitted.width, height: fitted.height)
        flat.frame = placed
        return (flat, placed)
    }
}
