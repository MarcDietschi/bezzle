import Foundation
import CBezzleHost

// Convert to Path, as the Mac's (Store/PathOperations.swift's convertToPath, and for texts
// Canvas/TextOutlines.swift, copied): rectangles, ellipses and lines become paths, and texts the
// outlines of their letters, from Skia's own (host.cpp's bz_text_outline and bz_glyph_outline),
// where the canvas draws them.

extension WindowsCore {
    /// What a text draws in one colour (the Mac's TextOutlines.Part): its letters' own colour, or
    /// nil for those the text's fill paints, and their outlines in the text's own coordinates, its
    /// frame's top left at zero, before it is turned.
    struct OutlinePart {
        let color: RGBA?
        let outline: CGPath
    }

    /// What a text draws, by colour, the text's own first; the markers of its lists and the lines
    /// under and through its letters with them. Nil for a layer that is not a text, or a text some
    /// of whose letters are pictures, as emoji are, with no outlines to take.
    static func outlineParts(of node: Node) -> [OutlinePart]? {
        guard node.kind == .text else { return nil }
        var colors: [RGBA?] = []
        var paths: [RGBA?: CGMutablePath] = [:]
        func add(_ path: CGPath, _ color: RGBA?, _ t: CGAffineTransform) {
            if paths[color] == nil {
                paths[color] = CGMutablePath()
                colors.append(color)
            }
            paths[color]?.addPath(path, transform: t)
        }
        if let curved = CurvedText.laid(node) {
            // Letter by letter, where each stands on the curve.
            for letter in curved.letters {
                guard let glyph = outline(glyph: letter.index, of: letter.line) else { return nil }
                let color = letter.own ? rgba(letter.color) : nil
                add(glyph, color, letter.place)
                let rules = CurvedText.rules(of: letter)
                if !rules.isEmpty {
                    let lines = CGMutablePath()
                    for rule in rules { lines.addRect(rule) }
                    add(lines, color, letter.place)
                }
            }
        } else {
            let laid = TextLayout.layout(node)
            guard laid.id != 0 else { return nil }
            let down = CGAffineTransform(translationX: 0, y: TextLayout.offset(node))
            // Each run's letters by the colour it has of its own, as the page lays its words.
            let spans = node.runs
            var at = 0
            for (k, run) in TextLayout.runs(node).enumerated() {
                let n = (run["text"] as? String ?? "").utf16.count
                if n > 0 {
                    guard let letters = outline(text: laid.id, from: at, to: at + n) else { return nil }
                    add(letters, spans.indices.contains(k) ? spans[k].look.color : nil, down)
                }
                at += n
            }
            // The lists' markers, in their items' first letters' colours.
            for marker in laid.markers {
                guard let letters = outline(text: marker.id, from: 0, to: marker.text.utf16.count) else { return nil }
                add(letters, marker.look.color, CGAffineTransform(translationX: marker.at.x, y: TextLayout.offset(node)))
            }
        }
        let order = colors.filter { $0 == nil } + colors.filter { $0 != nil }
        return order.compactMap { color in
            guard let path = paths[color], !path.isEmpty else { return nil }
            return OutlinePart(color: color, outline: path)
        }
    }

    /// The outlines of letters `from` to `to` of a text the host set, and the lines under and
    /// through them; nil where some are pictures.
    private static func outline(text id: Int, from start: Int, to end: Int) -> CGPath? {
        taken(bz_text_outline(Int32(id), Int32(start), Int32(end)))
    }

    /// The outline of one letter of a line set for a curve; nil where it is a picture.
    private static func outline(glyph index: Int, of line: Int) -> CGPath? {
        taken(bz_glyph_outline(Int32(line), Int32(index)))
    }

    private static func taken(_ count: Int32) -> CGPath? {
        guard count >= 0 else { return nil }
        guard count > 0 else { return CGMutablePath() }
        var numbers = [Double](repeating: 0, count: Int(count) / MemoryLayout<Double>.size)
        numbers.withUnsafeMutableBytes { bz_host_take($0.baseAddress) }
        return Skia.decode(numbers[...])
    }

    private static func rgba(_ c: CGColor) -> RGBA? {
        guard let p = c.components, p.count >= 3 else { return nil }
        return RGBA(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]), a: Double(p.count > 3 ? p[3] : 1))
    }

    // MARK: Convert to Path

    /// Whether a text can become the outlines of its letters: one with letters to draw, whose
    /// words are its own alone. Those of a repeat grid's cell, a component's copy or a deck's
    /// post would take every other cell's, copy's or post's words with them.
    private static func outlinable(_ id: UUID, in doc: BezzleDocument) -> Bool {
        guard let n = doc.node(id), n.kind == .text, !n.locked, !(n.text ?? "").allSatisfy(\.isWhitespace) else { return false }
        return !doc.inCopy(id) && !doc.ancestors(of: id).contains(where: \.isRepeatGrid) && doc.artboard(of: id)?.isDeck != true
    }

    /// Whether any of `ids` becomes a path: a shape not locked, or a text that can be outlined.
    public static func canConvertToPath(_ ids: [UUID]) -> Bool {
        guard let doc = design else { return false }
        return ids.contains { id in doc.node(id).map { !$0.locked && $0.asPath() != nil } == true || outlinable(id, in: doc) }
    }

    /// What Convert to Path makes of `ids` in `doc`: rectangles, ellipses and lines become paths,
    /// and texts the outlines of their letters. The change to make, nil for none, and whether a
    /// text was refused for letters that are pictures (the Mac beeps then).
    static func pathConversion(_ ids: [UUID], in doc: BezzleDocument) -> (change: ((inout BezzleDocument) -> Void)?, refused: Bool) {
        let shapes = ids.filter { doc.node($0)?.locked == false && doc.node($0)?.asPath() != nil }
        let texts = ids.filter { outlinable($0, in: doc) }
        guard !shapes.isEmpty || !texts.isEmpty else { return (nil, false) }
        var outlined: [(UUID, Node)] = []
        for id in texts {
            // The shape a mask holds the rest in is one path, whatever colours its letters have.
            let holds = doc.parent(of: id)?.holder?.id == id
            if let node = doc.node(id), let made = outlinedText(node, onePath: holds) { outlined.append((id, made)) }
        }
        let refused = outlined.count < texts.count
        guard !shapes.isEmpty || !outlined.isEmpty else { return (nil, refused) }
        return ({ doc in
            for id in shapes {
                doc.update(id) { n in
                    if let path = n.asPath() { n = path }
                }
            }
            // Not `update`, which keeps where each layer is known: a group holds new layers.
            for (id, made) in outlined {
                if let at = doc.path(of: id) { doc[at] = made }
            }
        }, refused)
    }

    /// Convert to Path on the design, as one step. Whether anything changed, and whether a text
    /// was refused for letters that are pictures.
    @discardableResult
    public static func convertToPath(_ ids: [UUID]) -> (changed: Bool, refused: Bool) {
        guard let doc = design else { return (false, false) }
        let made = pathConversion(ids, in: doc)
        guard let change = made.change else { return (false, made.refused) }
        edit(change)
        return (true, made.refused)
    }

    /// A text as the outlines of its letters, looking as it did (the Mac's Node.outlinedText): one
    /// path filled as the text was or, when some of its letters have colours of their own, a
    /// group of one path for each colour, the text's own at the back. It keeps the text's id,
    /// name, place and turn, its shadows, opacity, blend and blur. `onePath` makes it one path
    /// whatever colours its letters have, as the shape of a mask has to be. Nil for a layer that
    /// is not a text, a text that draws nothing, or one with letters that are pictures.
    static func outlinedText(_ text: Node, onePath: Bool = false) -> Node? {
        guard text.kind == .text, var parts = outlineParts(of: text), !parts.isEmpty else { return nil }
        if onePath, parts.count > 1 {
            let all = CGMutablePath()
            for part in parts { all.addPath(part.outline) }
            parts = [OutlinePart(color: nil, outline: all)]
        }
        var look = text
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
        look.moreShadows = text.moreShadows?.map { s in
            var s = s
            s.spread = nil
            return s
        }
        if look.blur?.background == true { look.blur = nil }
        if parts.count == 1 { return shaped(look, parts[0], from: text) }

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
        plain.hidden = false
        var words: [RGBA?: String] = [:]
        for run in text.runs { words[run.look.color, default: ""] += run.text }
        group.children = parts.compactMap { part in
            guard var path = shaped(plain, part, from: text) else { return nil }
            path.id = UUID()
            let named = (words[part.color] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            path.name = named.isEmpty ? Node.Kind.path.title : String(named.prefix(40))
            // In the group, which lies where the text did until it is fitted round them.
            path.frame = path.frame.offsetBy(dx: -text.frame.minX, dy: -text.frame.minY)
            return path
        }
        return group.children.isEmpty ? nil : group
    }

    /// `layer` as a path of `part`, which lies in `text`'s own coordinates, filled with the text's
    /// fill where it fills it, lying where it did, or with the letters' own colour.
    private static func shaped(_ layer: Node, _ part: OutlinePart, from text: Node) -> Node? {
        let box = part.outline.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return nil }
        var n = layer
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

extension WindowsCore {
    /// For comparing with the Mac (bezzle-render's BEZZLE_OUTLINE; Web/tools/OutlineTruthTests.swift
    /// on the Mac's side): every text of the open design made the outlines of its letters, as
    /// Convert to Path makes them, and what each became, as JSON by the text's id: its kind,
    /// frame, fill and, for a group, its paths' names, frames and fills; "refused" for one left a text.
    public static func outlineEveryText() -> String {
        guard let doc = design else { return "{}" }
        var texts: [UUID] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if n.kind == .text { texts.append(n.id) }
                walk(n.children)
            }
        }
        walk(doc.nodes)
        var report: [String: Any] = [:]
        func describe(_ n: Node) -> [String: Any] {
            var d: [String: Any] = ["kind": n.kind.rawValue, "name": n.name,
                                    "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height].map { Double($0) },
                                    "fill": n.fill.on ? n.fill.color.hex : "none", "gradient": n.fill.gradient != nil]
            if !n.children.isEmpty { d["children"] = n.children.map(describe) }
            return d
        }
        for id in texts {
            guard let before = design else { break }
            let made = pathConversion([id], in: before)
            if let change = made.change {
                edit(change)
                if let n = design?.node(id) { report[id.uuidString] = describe(n) }
            } else {
                report[id.uuidString] = "refused"
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// From Bezzle/Canvas/TextOutlines.swift, which the Mac alone compiles.
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
