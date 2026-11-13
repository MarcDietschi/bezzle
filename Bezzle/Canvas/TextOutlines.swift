import AppKit
import CoreText

/// A text's letters as outlines, for Convert to Path: everything it draws, its letters, the
/// markers of its lists and the lines under and through them, gathered by colour, where it is
/// drawn. Straight text is laid out and drawn by Text Kit as the canvas draws it, with the
/// drawing caught rather than done; text on a curve is drawn letter by letter as `CurvedText`
/// draws it.
nonisolated enum TextOutlines {
    /// What a text draws in one colour.
    struct Part {
        /// The letters' own colour, or nil for those the text's fill paints.
        let color: RGBA?
        /// Their outlines, in the text's own coordinates: its frame's top left at zero, before it
        /// is turned. Nothing in it crosses anything else, so it fills as drawn either way.
        let outline: CGPath
    }

    /// The colour of their own letters of this look have, if any.
    static func color(_ look: Any?) -> RGBA? { (look as? LookBox)?.look.color }

    /// What a text draws, by colour, the text's own first. Nil for a layer that is not a text,
    /// or a text some of whose letters are pictures, as emoji are, with no outlines to take.
    static func parts(of node: Node) -> [Part]? {
        guard node.kind == .text else { return nil }
        let collector: Collector
        if let curved = CurvedText.laid(node) {
            collector = Collector(space: .identity)
            let words = CurvedText.words(of: node)
            for letter in curved.letters {
                if CTFontGetSymbolicTraits(letter.font).contains(.traitColorGlyphs) { return nil }
                let color = words.length > 0
                    ? Self.color(words.attribute(.bezzleLook, at: min(letter.characters.location, words.length - 1), effectiveRange: nil))
                    : nil
                var place = letter.place
                if let glyph = CTFontCreatePathForGlyph(letter.font, letter.glyph, &place) { collector.letters(color).addPath(glyph) }
                for rule in CurvedText.rules(of: letter) { collector.lines(color).addRect(rule, transform: letter.place) }
            }
        } else {
            let laid = TextLayout.layout(node)
            // Drawn as the canvas draws it, its y running down, into a context that keeps nothing.
            guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            collector = Collector(space: ctx.ctm)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            laid.manager.collecting = collector
            laid.manager.drawGlyphs(forGlyphRange: laid.manager.glyphRange(for: laid.container), at: CGPoint(x: 0, y: TextLayout.offset(node)))
            laid.manager.collecting = nil
            NSGraphicsContext.current = previous
        }
        return collector.pictures ? nil : collector.parts
    }

    /// Gathers the outlines of what is drawn, by colour, in the space the drawing began in.
    final class Collector {
        let space: CGAffineTransform
        /// The colours met, in the order they were.
        private var colors: [RGBA?] = []
        private var letters: [RGBA?: CGMutablePath] = [:]
        private var lines: [RGBA?: CGMutablePath] = [:]
        /// Whether some letters were pictures, as emoji are, which have no outlines.
        private(set) var pictures = false

        init(space: CGAffineTransform) { self.space = space }

        private func meet(_ color: RGBA?) {
            guard letters[color] == nil else { return }
            letters[color] = CGMutablePath()
            lines[color] = CGMutablePath()
            colors.append(color)
        }

        /// The outlines of the letters of a colour, so far.
        func letters(_ color: RGBA?) -> CGMutablePath {
            meet(color)
            return letters[color]!
        }

        /// The lines under and through letters of a colour, so far.
        func lines(_ color: RGBA?) -> CGMutablePath {
            meet(color)
            return lines[color]!
        }

        /// Letters as Text Kit would draw them in `ctx`.
        func add(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count: Int, font: NSFont,
                 textMatrix: CGAffineTransform, color: RGBA?, in ctx: CGContext) {
            let font = font as CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                pictures = true
                return
            }
            let path = letters(color)
            let toSpace = ctx.ctm.concatenating(space.inverted())
            for i in 0..<count {
                var place = CGAffineTransform(a: textMatrix.a, b: textMatrix.b, c: textMatrix.c, d: textMatrix.d,
                                              tx: positions[i].x, ty: positions[i].y).concatenating(toSpace)
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[i], &place) { path.addPath(glyph) }
            }
        }

        /// A list item's marker, its baseline's left end at `at`.
        func add(_ line: CTLine, at: CGPoint, color: RGBA?, in ctx: CGContext) {
            TextLayout.addOutlines(of: line, at: at, to: letters(color), transform: ctx.ctm.concatenating(space.inverted()))
        }

        /// What `draw` would draw into the current graphics context, taken as outlines: how the
        /// lines under and through letters are taken, exactly where and as thick as Text Kit
        /// draws them, broken round the letters that hang through them.
        func capture(color: RGBA?, _ draw: () -> Void) {
            guard let current = NSGraphicsContext.current, let drawn = Drawn.outlines(flipped: current.isFlipped, draw) else { return }
            var toSpace = current.cgContext.ctm.concatenating(space.inverted())
            if let placed = drawn.copy(using: &toSpace) { lines(color).addPath(placed) }
        }

        /// What was drawn, by colour, the text's own first. The lines are made one with the
        /// letters they cross, so that where they overlap is filled however each winds.
        var parts: [Part] {
            let order = colors.filter { $0 == nil } + colors.filter { $0 != nil }
            return order.compactMap { color in
                let shapes = letters[color]!, rules = lines[color]!
                let outline: CGPath = rules.isEmpty ? shapes : shapes.isEmpty ? rules.normalized() : shapes.union(rules)
                return outline.isEmpty ? nil : Part(color: color, outline: outline)
            }
        }
    }
}

/// Some drawing read back as outlines: drawn into a PDF, whose page is then read for the paths
/// it fills and strokes, each stroke as the band it covers.
private nonisolated enum Drawn {
    static func outlines(flipped: Bool, _ draw: () -> Void) -> CGPath? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        pdf.beginPDFPage(nil)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: flipped)
        draw()
        NSGraphicsContext.current = previous
        pdf.endPDFPage()
        pdf.closePDF()
        guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1),
              let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        Reader.register(in: table)
        let reader = Reader()
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(reader).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        return reader.out
    }

    /// Follows a page's drawing: where it is placed, how wide its lines are, and what it paints.
    private final class Reader {
        var ctm = CGAffineTransform.identity
        var width: CGFloat = 1
        var cap = CGLineCap.butt
        var saved: [(CGAffineTransform, CGFloat, CGLineCap)] = []
        var path = CGMutablePath()
        let out = CGMutablePath()

        func fill() {
            out.addPath(path, transform: ctm)
        }

        func stroke() {
            guard !path.isEmpty else { return }
            out.addPath(path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10), transform: ctm)
        }

        func end() { path = CGMutablePath() }

        static func of(_ info: UnsafeMutableRawPointer?) -> Reader { Unmanaged<Reader>.fromOpaque(info!).takeUnretainedValue() }

        /// The numbers an operator takes, in the order they were written.
        static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
            var out = [CGFloat](repeating: 0, count: count)
            for i in stride(from: count - 1, through: 0, by: -1) {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
                out[i] = v
            }
            return out
        }

        static func register(in table: CGPDFOperatorTableRef) {
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                let r = Reader.of(info)
                r.saved.append((r.ctm, r.width, r.cap))
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                let r = Reader.of(info)
                if let last = r.saved.popLast() { (r.ctm, r.width, r.cap) = last }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { s, info in
                guard let n = Reader.numbers(s, 6) else { return }
                let r = Reader.of(info)
                r.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(r.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "w") { s, info in
                if let n = Reader.numbers(s, 1) { Reader.of(info).width = n[0] }
            }
            CGPDFOperatorTableSetCallback(table, "J") { s, info in
                var v: CGPDFInteger = 0
                guard CGPDFScannerPopInteger(s, &v) else { return }
                Reader.of(info).cap = v == 1 ? .round : v == 2 ? .square : .butt
            }
            CGPDFOperatorTableSetCallback(table, "m") { s, info in
                if let n = Reader.numbers(s, 2) { Reader.of(info).path.move(to: CGPoint(x: n[0], y: n[1])) }
            }
            CGPDFOperatorTableSetCallback(table, "l") { s, info in
                if let n = Reader.numbers(s, 2) { Reader.of(info).path.addLine(to: CGPoint(x: n[0], y: n[1])) }
            }
            CGPDFOperatorTableSetCallback(table, "c") { s, info in
                guard let n = Reader.numbers(s, 6) else { return }
                Reader.of(info).path.addCurve(to: CGPoint(x: n[4], y: n[5]), control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
            }
            CGPDFOperatorTableSetCallback(table, "v") { s, info in
                guard let n = Reader.numbers(s, 4) else { return }
                let path = Reader.of(info).path
                path.addCurve(to: CGPoint(x: n[2], y: n[3]), control1: path.currentPoint, control2: CGPoint(x: n[0], y: n[1]))
            }
            CGPDFOperatorTableSetCallback(table, "y") { s, info in
                guard let n = Reader.numbers(s, 4) else { return }
                Reader.of(info).path.addCurve(to: CGPoint(x: n[2], y: n[3]), control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
            }
            CGPDFOperatorTableSetCallback(table, "h") { _, info in Reader.of(info).path.closeSubpath() }
            CGPDFOperatorTableSetCallback(table, "re") { s, info in
                if let n = Reader.numbers(s, 4) { Reader.of(info).path.addRect(CGRect(x: n[0], y: n[1], width: n[2], height: n[3])) }
            }
            CGPDFOperatorTableSetCallback(table, "n") { _, info in Reader.of(info).end() }
            CGPDFOperatorTableSetCallback(table, "S") { _, info in
                let r = Reader.of(info)
                r.stroke()
                r.end()
            }
            CGPDFOperatorTableSetCallback(table, "s") { _, info in
                let r = Reader.of(info)
                r.path.closeSubpath()
                r.stroke()
                r.end()
            }
            for op in ["f", "F", "f*"] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in
                    let r = Reader.of(info)
                    r.fill()
                    r.end()
                }
            }
            for op in ["B", "B*"] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in
                    let r = Reader.of(info)
                    r.fill()
                    r.stroke()
                    r.end()
                }
            }
            for op in ["b", "b*"] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in
                    let r = Reader.of(info)
                    r.path.closeSubpath()
                    r.fill()
                    r.stroke()
                    r.end()
                }
            }
        }
    }
}

nonisolated extension Node {
    /// A text as the outlines of its letters, looking as it did, for Convert to Path: one path
    /// filled as the text was or, when some of its letters have colours of their own, a group
    /// of one path for each colour, the text's own at the back. It keeps the text's id, name,
    /// place and turn, its shadows, opacity, blend and blur. `onePath` makes it one path
    /// whatever colours its letters have, as the shape of a mask has to be. Nil for a layer that
    /// is not a text, a text that draws nothing, or one with letters that are pictures, as emoji
    /// are, which have no outlines.
    func outlinedText(onePath: Bool = false) -> Node? {
        guard kind == .text, var parts = TextOutlines.parts(of: self), !parts.isEmpty else { return nil }
        if onePath, parts.count > 1 {
            let all = CGMutablePath()
            for part in parts { all.addPath(part.outline) }
            parts = [TextOutlines.Part(color: nil, outline: all)]
        }
        var look = self
        look.text = nil
        look.style = nil
        look.spans = nil
        look.curve = nil
        look.curvePath = nil
        // What a text never draws, and a path would: borders, more fills than the first,
        // shadows spread, and a blur of what lies behind.
        look.border.on = false
        look.moreBorders = nil
        look.moreFills = nil
        look.shadow.spread = nil
        look.moreShadows = moreShadows?.map { s in
            var s = s
            s.spread = nil
            return s
        }
        if look.blur?.background == true { look.blur = nil }
        if parts.count == 1 { return look.shaped(parts[0], from: self) }

        // A group is never turned: each of its paths is, about the text's middle.
        var group = look
        group.kind = .group
        group.fill = Fill(on: false, color: .shape)
        group.rotation = 0
        var plain = look
        plain.opacity = 1
        plain.blend = nil
        plain.shadows = []
        plain.blur = nil
        plain.transform3D = nil
        plain.exports = nil
        plain.flow = nil
        // How the text moves in its film is the group's, as its opacity is: its paths move with it.
        plain.motion = nil
        plain.hidden = false
        var words: [RGBA?: String] = [:]
        for run in runs { words[run.look.color, default: ""] += run.text }
        group.children = parts.compactMap { part in
            guard var path = plain.shaped(part, from: self) else { return nil }
            path.id = UUID()
            let named = (words[part.color] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            path.name = named.isEmpty ? Kind.path.title : String(named.prefix(40))
            // In the group, which lies where the text did until it is fitted round them.
            path.frame = path.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            return path
        }
        return group.children.isEmpty ? nil : group
    }

    /// This layer as a path of `part`, which lies in `text`'s own coordinates, filled with the
    /// text's fill where it fills it, lying where it did, or with the letters' own colour.
    private func shaped(_ part: TextOutlines.Part, from text: Node) -> Node? {
        let box = part.outline.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return nil }
        var n = self
        n.kind = .path
        n.path = PathData.string(part.outline)
        n.pathBox = box
        n.evenOdd = nil
        n.frame = CGRect(center: CGPoint(x: box.midX, y: box.midY).applying(text.placement), size: box.size)
        if let color = part.color {
            n.fill = Fill(on: text.fill.on, color: color)
        } else {
            n.fill.gradient = text.fill.gradient?.moved(from: text.frame.size, to: box)
            n.fill.image = text.fill.image?.moved(from: text.frame.size, to: box)
        }
        return n
    }
}

nonisolated extension ImageFill {
    /// The same picture lying where it did on the canvas, as big, after its layer's frame,
    /// `size` before, became `box`, measured from its old top left. A picture squeezed to its
    /// layer is squeezed to the new frame.
    func moved(from size: CGSize, to box: CGRect) -> ImageFill {
        guard mode != .stretch, size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return self }
        let was = Renderer.imageRect(self, in: size)
        var moved = self
        moved.scale = 1
        moved.offset = .zero
        let base = Renderer.imageRect(moved, in: box.size)
        guard base.width > 0 else { return self }
        moved.scale = was.width / base.width
        moved.offset = CGPoint(x: (was.minX - box.minX - (box.width - was.width) / 2) / box.width,
                               y: (was.minY - box.minY - (box.height - was.height) / 2) / box.height)
        return moved
    }
}
