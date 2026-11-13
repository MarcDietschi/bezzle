import AppKit
import CoreGraphics

/// What a page's pictures came to, once fetched: each in the design's images folder by name, the
/// SVGs taken apart into outlines, and the parts of the page that could only be photographed.
struct WebAssets {
    struct Picture {
        var asset: String
        /// Its own size, in pixels.
        var size: CGSize
    }

    /// A photograph of part of the page, and where on the page it was taken.
    struct Shot {
        var asset: String
        var size: CGSize
        var frame: CGRect
    }

    /// By the picture's place in the page's list.
    var pictures: [Int: Picture] = [:]
    var vectors: [Int: [WebPath]] = [:]
    /// By the element photographed: all of it, or only its own background.
    var shots: [Int: Shot] = [:]
    var backgrounds: [Int: Shot] = [:]
    /// By the canvas: what its WebGL draws, kept to be drawn again (WebPageGL.js).
    var scenes: [Int: ShaderFill] = [:]
    /// By the canvas: why what its WebGL draws could not be kept, and it is a picture only.
    var stills: [Int: String] = [:]
}

/// One width of a page as it was read, and what its pictures came to.
struct WebRead {
    /// What its artboard is called.
    var name: String
    var page: WebPage
    var assets: WebAssets
}

/// Takes a page read at one or more widths to a design: an artboard a width, side by side, each
/// holding the page's boxes, words, pictures and outlines as Bezzle's layers, grouped as the
/// page's elements hold one another and in the order the browser paints them.
struct WebConverter {
    var report: ImportReport
    private var fonts = FontMatch()
    private var assets = WebAssets()
    private var pageSize = CGSize.zero

    init(source: String) {
        report = ImportReport(source: source)
    }

    /// The design: the artboards side by side, a gap apart.
    static func document(_ reads: [WebRead], source: String) -> (BezzleDocument, ImportReport) {
        var converter = WebConverter(source: source)
        var doc = BezzleDocument()
        var x: CGFloat = 0
        for read in reads {
            let board = converter.artboard(read, at: x)
            x = board.frame.maxX + 400
            doc.nodes.append(board)
        }
        doc.fitGroups()
        converter.report.layers = doc.allNodes.filter { !$0.isArtboard && !$0.isGroup }.count
        return (doc, converter.report)
    }

    // MARK: Artboards

    mutating func artboard(_ read: WebRead, at x: CGFloat) -> Node {
        let page = read.page
        assets = read.assets
        pageSize = CGSize(width: page.w, height: page.h)
        var board = Node(kind: .artboard, name: read.name, frame: CGRect(x: x, y: 0, width: page.w, height: page.h))
        report.artboards += 1
        for (what, count) in page.notes { for _ in 0..<count { noteFromReader(what) } }
        if let full = page.fullHeight, full > page.h + 1 { report.note("Pages longer than Bezzle reads, cut off at the bottom") }
        // The page's colour, laid on white as the browser lays it.
        let color = CSS.color(page.bg.c) ?? .white
        board.fill = Fill(color: color.a >= 0.999 ? color : ImportText.composite([.white, color]) ?? .white)
        board.clips = true
        var kids: [Node] = []
        if let layers = page.bg.layers {
            let box = CGRect(x: 0, y: 0, width: page.w, height: max(page.h, page.vh))
            var back = Node(kind: .rectangle, name: String(localized: "Background"), frame: box)
            back.fills = fills(layers, color: nil, box: box, item: nil)
            if !back.fills.isEmpty { kids.append(back) }
        }
        if let root = page.root { kids += nodes(Self.restacked(root)) }
        board.children = prune(kids, in: CGRect(origin: .zero, size: pageSize))
        return board
    }

    /// Takes away what lies off the page, at any depth: menus slid out of view, slides of a
    /// carousel past its edge. A mask keeps its shape, whatever it holds.
    private func prune(_ nodes: [Node], in area: CGRect) -> [Node] {
        nodes.compactMap { n in
            guard visible(n, in: area) else { return nil }
            guard n.isGroup else { return n }
            var g = n
            if g.isMask, let holder = g.children.first {
                let held = prune(Array(g.children.dropFirst()), in: area)
                guard !held.isEmpty else { return nil }
                g.children = [holder] + held
            } else {
                g.children = prune(g.children, in: area)
                guard !g.children.isEmpty else { return nil }
            }
            return g
        }
    }

    private mutating func noteFromReader(_ what: String) {
        switch what {
        case "3d": report.note("3D transforms, drawn flat")
        case "counter": report.note("Counters in generated words, left out")
        case "list-image": report.note("Pictures as list bullets, left out")
        case "scroller": report.note("Pages scrolling inside a box, let out to their full height")
        default: break
        }
    }

    /// Whether a layer shows anything of itself in `area`: it lies there, at least in part.
    private func visible(_ n: Node, in area: CGRect) -> Bool {
        guard let b = Self.extent(n) else { return false }
        // Flat, a shape shows only its border, as a straight stroke does.
        if n.kind != .line && n.kind != .text && !n.isGroup && n.borders.isEmpty && (b.width < 0.01 || b.height < 0.01) { return false }
        return b.insetBy(dx: -1, dy: -1).intersects(area)
    }

    /// Where a layer lies in its parent. Groups are not fitted round what they hold until the
    /// design is whole, so theirs is worked out from what they hold, or the shape cutting it.
    static func extent(_ n: Node) -> CGRect? {
        if n.isGroup {
            if let cut = n.cutBy { return extent(cut)?.offsetBy(dx: n.frame.minX, dy: n.frame.minY) }
            let boxes = n.children.compactMap(extent)
            guard var u = boxes.first else { return nil }
            for b in boxes.dropFirst() { u = u.union(b) }
            return u.offsetBy(dx: n.frame.minX, dy: n.frame.minY)
        }
        let b = Geometry.bounds(of: n)
        guard !b.isNull, b.width.isFinite, b.height.isFinite, b.minX.isFinite, b.minY.isFinite else { return nil }
        return b
    }

    // MARK: Items

    private mutating func nodes(_ item: WebItem) -> [Node] {
        switch item.t {
        case "text": return text(item)
        case "deco": return backing(item).map { [$0] } ?? []
        default: return element(item)
        }
    }

    /// The order the browser paints an element's children in: those behind it, the blocks, the
    /// floats, the words and inline boxes, then those positioned, by how far forward they are.
    static func paintOrder(_ items: [WebItem]) -> [WebItem] {
        func rank(_ i: WebItem) -> (Int, Int) {
            if i.t == "text" || i.t == "deco" { return (3, 0) }
            let positioned = i.pos != nil && i.pos != "static"
            var own: (Int, Int) = (1, 0)
            if positioned || i.z != nil {
                let z = i.z ?? 0
                if z < 0 { return (0, z) }
                if z > 0 { return (5, z) }
                own = (4, 0)
            } else if i.sc == true {
                own = (4, 0)
            } else if i.fl == true {
                own = (2, 0)
            } else if i.inl == true {
                own = (3, 0)
            }
            return own
        }
        return items.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            // A ::before goes before what its element holds, an ::after after.
            let ba = a.element.before == true, bb = b.element.before == true
            if ba != bb { return ba }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Whether an element keeps the z-indexes of what it holds among themselves.
    static func isStackingContext(_ i: WebItem) -> Bool {
        i.sc == true || i.z != nil || i.pos == "fixed" || i.pos == "sticky" || i.tag == "html"
    }

    /// The page with what a z-index brings forward or sends back taken out of the elements that
    /// do not keep it among themselves, up to the nearest that does, a stacking context, and
    /// painted in order there, as the browser paints it. Places are the page's throughout, so
    /// nothing moves. An element cutting off what it holds keeps it, cut off as it was.
    static func restacked(_ item: WebItem) -> WebItem {
        var item = item
        guard var kids = item.kids else { return item }
        kids = kids.map(restacked)
        if isStackingContext(item) || item.clip == true || item.clipPath != nil {
            var lifted: [WebItem] = []
            kids = kids.map { pull($0, into: &lifted) }
            kids += lifted
        }
        item.kids = kids
        return item
    }

    /// What an element holds that its z-index takes past it, taken out into `lifted`.
    private static func pull(_ item: WebItem, into lifted: inout [WebItem]) -> WebItem {
        guard item.t == "el", !isStackingContext(item), item.clip != true, item.clipPath == nil, let kids = item.kids else { return item }
        var item = item, kept: [WebItem] = []
        for k in kids {
            if k.t == "el", let z = k.z, z != 0 {
                lifted.append(k)
            } else {
                kept.append(pull(k, into: &lifted))
            }
        }
        item.kids = kept
        return item
    }

    /// The layers an element becomes: one, a group of them, or, for an element that only holds
    /// others and is nothing to look at itself, those it holds, loose.
    private mutating func element(_ item: WebItem) -> [Node] {
        if item.contents == true { return Self.paintOrder(item.kids ?? []).flatMap { nodes($0) } }
        // What it says it is, or what Bezzle calls a layer of its kind.
        let label = self.label(of: item)
        let name = label ?? Node.Kind.group.title
        if let id = item.id, let shot = assets.shots[id] {
            noteShot(item.shot ?? "filter")
            return live([picture(shot, name: label ?? String(localized: "Image"))], item)
        }
        // A box shaped by a picture's outline that could not be photographed would be a box of
        // its colour, which it is not: it is left out.
        if item.shot == "mask" { return [] }
        var under: [Node] = [], over: [Node] = []
        var back = backing(item)
        if var b = back { b.name = label ?? b.kind.title; back = b }
        under += back.map { [$0] } ?? []
        over += sideBorders(item) + outline(item)

        var held: [Node] = []
        if let img = item.img { held += live(picture(img, item: item, name: label ?? String(localized: "Image")), item) }
        if let vec = item.vec { held += vectors(vec, item: item, name: label ?? String(localized: "Vector")) }
        for kid in Self.paintOrder(item.kids ?? []) { held += nodes(kid) }

        // Cut off at its edge, or at the shape it is clipped to.
        var clipped = false
        let cutsHeld = item.clip == true && !held.isEmpty
        if let clipPath = item.clipPath, let holder = clipHolder(clipPath, item: item) {
            var all = under + held + over
            let cut = Self.extent(holder) ?? item.box
            all = all.filter { visible($0, in: cut.insetBy(dx: -2, dy: -2)) }
            if let mask = ImportMask.mask(holder, holding: all, name: name) {
                under = []
                held = [mask]
                over = []
                clipped = true
            }
        } else if item.clipPath != nil {
            report.note("Shapes boxes are cut to, left out")
        }
        if !clipped, cutsHeld {
            let edge = edgeShape(item)
            let cut = Self.extent(edge) ?? item.box
            held = held.filter { visible($0, in: cut.insetBy(dx: -1, dy: -1)) }
            if !held.isEmpty, ImportMask.reaches(held, outside: edge) {
                let b = item.borders
                let bordered = b.0 > 0 || b.1 > 0 || b.2 > 0 || b.3 > 0
                if let first = under.first, under.count == 1, !bordered, first.kind == .rectangle || first.kind == .ellipse, first.blur?.background != true {
                    // The box's own background holds what it cuts off.
                    if let mask = ImportMask.mask(first, holding: held, name: name) {
                        under = []
                        held = [mask]
                    }
                } else {
                    var holder = edge
                    ImportMask.clear(&holder)
                    holder.name = String(localized: "Edge")
                    if let mask = ImportMask.mask(holder, holding: held, name: name) { held = [mask] }
                }
            }
        }

        var out = under + held + over
        guard !out.isEmpty else { return [] }

        // A filter or blend over the whole of it.
        var blur: Blur?, drop: [Shadow] = [], opacity = item.op ?? 1
        if let filter = item.filter {
            for f in CSS.filters(filter) {
                switch f {
                case .blur(let r): if r > 0 { blur = Blur(radius: r) }
                case .dropShadow(let s): drop.append(s)
                case .opacity(let o): opacity *= o
                default:
                    if !developed(&out, f) { report.note("Colour filters, left out") }
                }
            }
        }
        let blend = item.blend.flatMap(Self.blend)
        let grouped = item.tag != "html" && item.tag != "body" && out.count > 1 &&
            (back != nil || item.label != nil || clipped || cutsHeld || Self.sections.contains(item.tag ?? "") ||
             opacity < 1 || blend != nil || blur != nil || !drop.isEmpty)
        if grouped || ((opacity < 1 || blend != nil || blur != nil || !drop.isEmpty) && out.count > 1) {
            var g = Node(kind: .group, name: name, frame: .zero)
            g.children = out
            // The box's own fill, under what it holds, is its background, as an imported frame's is.
            if let back, let i = g.children.firstIndex(where: { $0.id == back.id }) {
                g.children[i].name = String(localized: "Background")
            } else if let back, g.children.first?.isMask == true, g.children[0].children.first?.id == back.id {
                g.children[0].children[0].name = String(localized: "Background")
            }
            if opacity < 1 { g.opacity = opacity }
            g.blend = blend
            g.blur = blur
            if !drop.isEmpty { g.shadows = drop }
            return [g]
        }
        if out.count == 1 {
            if opacity < 1 { out[0].opacity *= opacity }
            if let blend { out[0].blend = blend }
            if let blur { out[0].blur = blur }
            if !drop.isEmpty { out[0].shadows += drop }
            if out[0].isGroup, let label { out[0].name = label }
        }
        return out
    }

    /// Elements that are parts of a page in their own right, and so stay a group.
    private static let sections: Set<String> = ["header", "nav", "main", "footer", "section", "article", "aside", "form", "figure",
                                                 "ul", "ol", "li", "table", "button", "a", "dialog", "menu", "details", "blockquote", "picture", "label"]

    /// A colour filter on pictures alone, worked into how they are developed. Says whether it could be.
    private func developed(_ nodes: inout [Node], _ f: CSS.Filter) -> Bool {
        guard nodes.allSatisfy({ $0.fill.image != nil && $0.children.isEmpty }) else { return false }
        for i in nodes.indices {
            var d = nodes[i].fill.image?.develop ?? Develop()
            switch f {
            case .grayscale(let g): d[.saturation] = max(-100, d[.saturation] - 100 * min(g, 1))
            case .saturate(let s): d[.saturation] = min(100, max(-100, d[.saturation] + (s - 1) * 100))
            case .brightness(let b): d[.exposure] = min(4, max(-4, d[.exposure] + log2(max(b, 0.01))))
            case .contrast(let c): d[.contrast] = min(100, max(-100, d[.contrast] + (c - 1) * 100))
            default: return false
            }
            nodes[i].fill.image?.develop = d
        }
        return true
    }

    static func blend(_ css: String) -> BlendMode? {
        switch css {
        case "multiply": .multiply
        case "screen": .screen
        case "overlay": .overlay
        case "darken": .darken
        case "lighten": .lighten
        case "color-dodge": .colorDodge
        case "color-burn": .colorBurn
        case "hard-light": .hardLight
        case "soft-light": .softLight
        case "difference": .difference
        case "exclusion": .exclusion
        case "hue": .hue
        case "saturation": .saturation
        case "color": .color
        case "luminosity": .luminosity
        default: nil
        }
    }

    /// A canvas's picture, drawn by what its WebGL drew when that could be kept (`ShaderFill`),
    /// the picture staying as it looked, for what cannot draw it.
    private mutating func live(_ nodes: [Node], _ item: WebItem) -> [Node] {
        guard item.tag == "canvas", let id = item.id else { return nodes }
        if assets.stills[id] != nil {
            report.note("WebGL drawings Bezzle cannot draw again, as pictures")
            return nodes
        }
        guard let scene = assets.scenes[id] else { return nodes }
        var done = false
        func give(_ n: Node) -> Node {
            guard !done else { return n }
            var n = n
            if n.fill.image != nil {
                n.fill.shader = scene
                done = true
                return n
            }
            n.children = n.children.map(give)
            return n
        }
        return nodes.map(give)
    }

    private mutating func noteShot(_ why: String) {
        switch why {
        case "icon": report.note("Icons from icon fonts, as pictures")
        case "mask": report.note("Boxes masked by a picture, as pictures")
        case "control": report.note("Form controls, as pictures")
        case "embed": report.note("Embedded pages and media, as pictures")
        case "video": report.note("Videos, as a picture of their first frame")
        case "canvas": report.note("Drawings on a canvas, as pictures")
        case "svg": report.note("SVGs with text, pictures or filters, as pictures")
        case "filter": report.note("Boxes with colour filters, as pictures")
        default: report.note("Parts of the page that could only be photographed, as pictures")
        }
    }

    // MARK: What is photographed

    /// The parts of a page that can only be photographed: the elements whose picture is all of
    /// them, and those whose own background is a picture, because Bezzle cannot draw it.
    static func photographs(in page: WebPage, assets: WebAssets) -> [(id: Int, own: Bool)] {
        photographed(in: page, assets: assets).map { ($0.id, $0.own) }
    }

    /// The same, and whether each is photographed solid, on what lies behind it: what moves
    /// while it is photographed, such as a canvas or a video, cannot be told from its background.
    static func photographed(in page: WebPage, assets: WebAssets) -> [(id: Int, own: Bool, solid: Bool)] {
        var out: [(Int, Bool, Bool)] = []
        func visit(_ item: WebItem) {
            guard item.t == "el", let id = item.id else { return }
            if let why = item.shot {
                out.append((id, false, ["canvas", "video", "embed"].contains(why)))
                return
            }
            if let src = item.img?.src, assets.pictures[src] == nil, assets.vectors[src] == nil {
                out.append((id, false, false))
                return
            }
            if let filter = item.filter, Self.needsPhotograph(filter, item: item) {
                out.append((id, false, false))
                return
            }
            if item.hidden != true, item.textClip != true, let layers = item.layers,
               layers.contains(where: { !drawable($0, item: item, assets: assets) }) {
                out.append((id, true, false))
            }
            for kid in item.kids ?? [] { visit(kid) }
        }
        if let root = page.root { visit(root) }
        return out
    }

    /// Whether a filter changes colours in a way that only a photograph keeps: on anything small
    /// but a picture, whose development can take a few of them.
    private static func needsPhotograph(_ filter: String, item: WebItem) -> Bool {
        let colours = CSS.filters(filter).filter {
            switch $0 {
            case .blur, .dropShadow, .opacity: return false
            default: return true
            }
        }
        guard !colours.isEmpty else { return false }
        let picture = item.img != nil && (item.kids ?? []).isEmpty
        if picture, colours.allSatisfy({
            switch $0 {
            case .grayscale, .saturate, .brightness, .contrast: return true
            default: return false
            }
        }) { return false }
        return item.box.width * item.box.height <= 600 * 600
    }

    // MARK: Names

    /// What an element is called: what it says it is, or the part of a page it is; nil for a box
    /// that is only a box, which is called as Bezzle calls a layer of its kind.
    private func label(of item: WebItem) -> String? {
        if let label = item.label, !label.isEmpty, item.pseudo == nil { return Self.humanized(label) }
        switch item.tag ?? "" {
        case "header": return String(localized: "Header")
        case "nav": return String(localized: "Navigation")
        case "footer": return String(localized: "Footer")
        case "main": return String(localized: "Main")
        case "section": return String(localized: "Section")
        case "article": return String(localized: "Article")
        case "aside": return String(localized: "Sidebar")
        case "form": return String(localized: "Form")
        case "button": return String(localized: "Button")
        case "a": return String(localized: "web.layer.link", defaultValue: "Link", comment: "A layer brought in from a web page: a link.")
        case "ul", "ol", "menu": return String(localized: "List")
        case "li": return String(localized: "List Item")
        case "img", "picture": return String(localized: "Image")
        case "svg": return String(localized: "Vector")
        case "input", "textarea", "select": return String(localized: "Field")
        case "video": return String(localized: "Video")
        case "iframe", "embed", "object": return String(localized: "Embed")
        case "figure": return String(localized: "Figure")
        case "table": return String(localized: "Table")
        case "blockquote": return String(localized: "Quote")
        case "dialog": return String(localized: "Dialog")
        case "label": return String(localized: "Label")
        case "hr": return String(localized: "Rule")
        case "bz-pseudo": return item.pseudo == "::before" ? String(localized: "Before") : String(localized: "After")
        default: return nil
        }
    }

    /// A class or id written as words: "hero-banner" and "heroBanner" are "Hero banner".
    static func humanized(_ label: String) -> String {
        guard !label.contains(" "), label.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return label }
        var words: [String] = []
        var current = ""
        for ch in label {
            if ch == "-" || ch == "_" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return label }
        let rest = words.dropFirst().map { $0.allSatisfy(\.isUppercase) ? $0 : $0.lowercased() }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + rest).joined(separator: " ")
    }

    // MARK: Boxes

    /// A box in the page's coordinates placed as a layer: turned and moved as its transforms say.
    private func placed(_ n: inout Node, _ box: CGRect, _ m: CGAffineTransform?) {
        guard let m else {
            n.frame = box
            return
        }
        if let p = ImportGeometry.place(box, m) {
            n.frame = p.frame
            n.rotation = p.rotation
            if p.flipped { n.fills = n.fills.map { $0.flipped(horizontally: false) } }
        } else {
            n.frame = box.applying(m)
        }
    }

    /// How much a transform grows what it moves, for widths, radii and blurs.
    private static func growth(_ m: CGAffineTransform?) -> CGFloat {
        guard let m else { return 1 }
        return sqrt(abs(m.a * m.d - m.b * m.c))
    }

    /// The radii, one a corner, as Bezzle rounds them: each corner's smaller radius when they differ.
    private mutating func corners(_ item: WebItem, inset: CGFloat = 0) -> [CGFloat] {
        guard let r = item.rad, r.count == 8 else { return [0, 0, 0, 0] }
        var out: [CGFloat] = []
        var oval = false
        for i in 0..<4 {
            let rx = CGFloat(r[2 * i]), ry = CGFloat(r[2 * i + 1])
            if abs(rx - ry) > 1 { oval = true }
            out.append(max(min(rx, ry) - inset, 0))
        }
        if oval, !isEllipse(item) { report.note("Oval corners, made round") }
        return out
    }

    /// Whether the box's corners make it an ellipse: each as wide as half the box and as tall.
    private func isEllipse(_ item: WebItem) -> Bool {
        guard let r = item.rad, r.count == 8, let w = item.w, let h = item.h, w > 0, h > 0 else { return false }
        for i in 0..<4 where r[2 * i] < w / 2 - 0.5 || r[2 * i + 1] < h / 2 - 0.5 { return false }
        return true
    }

    /// The shape of an element's box, to hold or cut off what it holds: its padding box, rounded.
    private mutating func edgeShape(_ item: WebItem) -> Node {
        let b = item.borders
        let inner = item.paddingBox
        var n = Node(kind: isEllipse(item) ? .ellipse : .rectangle, name: String(localized: "Edge"), frame: inner)
        if n.kind == .rectangle { n.radii = corners(item, inset: max(b.0, b.1, b.2, b.3)) }
        placed(&n, inner, item.matrix)
        return n
    }

    /// The shape an element's box is drawn with: its fills, its border when every side has the
    /// same, its shadows and the blur of what lies behind it. Nil for a box with none of these.
    private mutating func backing(_ item: WebItem) -> Node? {
        guard item.hidden != true else { return nil }
        let box = item.box
        guard box.width > 0 || box.height > 0 else { return nil }
        let m = item.matrix, k = Self.growth(m)
        var n = Node(kind: isEllipse(item) ? .ellipse : .rectangle, name: label(of: item), frame: box)
        if n.kind == .rectangle { n.radii = corners(item).map { $0 * k } }
        var fills: [Fill] = []
        if item.textClip != true {
            if let id = item.id, let shot = assets.backgrounds[id], item.t == "el" {
                fills = [Fill(color: .white, image: ImageFill(asset: shot.asset, mode: .stretch, size: shot.size))]
            } else {
                fills = self.fills(item.layers ?? [], color: CSS.color(item.bg), box: box, item: item)
            }
        }
        n.fills = fills
        if let sides = item.bd, let border = uniformBorder(sides, k: k) { n.borders = [border] }
        if let sh = item.sh {
            let current = CSS.color(item.bg) ?? .black
            n.shadows = CSS.shadows(sh, current: current).map { s in
                var s = s
                s.x *= k; s.y *= k; s.blur *= k
                s.spread = s.spread.map { $0 * k }
                return s
            }
        }
        if let backdrop = item.backdrop {
            for f in CSS.filters(backdrop) {
                if case .blur(let r) = f, r > 0 {
                    n.blur = Blur(radius: r * k, background: true, fillOpacity: 1)
                } else if case .blur = f {
                } else {
                    report.note("Filters on what lies behind a box, left out")
                }
            }
        }
        guard !n.fills.isEmpty || !n.borders.isEmpty || !n.shadows.isEmpty || n.blur != nil else { return nil }
        placed(&n, box, m)
        if box.width <= 0 || box.height <= 0 { return nil }
        return n
    }

    /// The one border all four sides have alike, as Bezzle draws it inside the box; nil when they
    /// differ, as `sideBorders` then draws each.
    private mutating func uniformBorder(_ sides: [WebSide?], k: CGFloat) -> Border? {
        guard sides.count == 4, let first = sides[0] else { return nil }
        for s in sides {
            guard let s, abs(s.w - first.w) < 0.01, s.s == first.s, s.c == first.c else { return nil }
        }
        return border(first, k: k)
    }

    private mutating func border(_ s: WebSide, k: CGFloat) -> Border {
        let w = CGFloat(s.w) * k
        var b = Border(on: true, color: CSS.color(s.c) ?? .black, width: w, position: .inside)
        switch s.s {
        case "dashed":
            b.dash = 3 * w
            b.gap = 3 * w
        case "dotted":
            b.dash = w
            b.gap = w
        case "solid": break
        default: report.note("Double, grooved and bevelled borders, drawn solid")
        }
        return b
    }

    /// Borders that differ from side to side, each a bar along its side, over what the box holds.
    private mutating func sideBorders(_ item: WebItem) -> [Node] {
        guard item.hidden != true, let sides = item.bd, sides.count == 4, uniformBorder(sides, k: 1) == nil else { return [] }
        let box = item.box
        var out: [Node] = []
        for (i, side) in sides.enumerated() {
            guard let side else { continue }
            let w = CGFloat(side.w)
            let r: CGRect
            switch i {
            case 0: r = CGRect(x: box.minX, y: box.minY, width: box.width, height: w)
            case 1: r = CGRect(x: box.maxX - w, y: box.minY, width: w, height: box.height)
            case 2: r = CGRect(x: box.minX, y: box.maxY - w, width: box.width, height: w)
            default: r = CGRect(x: box.minX, y: box.minY, width: w, height: box.height)
            }
            var n = Node(kind: .rectangle, name: String(localized: "Border"), frame: r)
            n.fills = [Fill(color: CSS.color(side.c) ?? .black)]
            if side.s == "dashed" || side.s == "dotted" { report.note("Dashed borders on some sides only, drawn solid") }
            placed(&n, r, item.matrix)
            out.append(n)
        }
        if item.rad?.contains(where: { $0 > 0 }) == true { report.note("Borders different on each side of a round box, drawn straight") }
        return out
    }

    private mutating func outline(_ item: WebItem) -> [Node] {
        guard item.hidden != true, let ol = item.ol, ol.w > 0 else { return [] }
        let o = CGFloat(ol.o)
        let r = item.box.insetBy(dx: -o, dy: -o)
        var n = Node(kind: isEllipse(item) ? .ellipse : .rectangle, name: String(localized: "Outline"), frame: r)
        if n.kind == .rectangle { n.radii = corners(item).map { $0 > 0 ? $0 + o : 0 } }
        n.fills = []
        n.borders = [Border(on: true, color: CSS.color(ol.c) ?? .black, width: CGFloat(ol.w), position: .outside)]
        placed(&n, r, item.matrix)
        return [n]
    }

    // MARK: Backgrounds

    /// A box's fills, bottom first: its colour, then its layers from the last listed up.
    private mutating func fills(_ layers: [WebLayer], color: RGBA?, box: CGRect, item: WebItem?) -> [Fill] {
        var out: [Fill] = []
        if let color, color.a > 0 { out.append(Fill(color: color)) }
        for layer in layers.reversed() {
            if let f = fill(layer, box: box, item: item) { out.append(f) }
        }
        return out
    }

    /// The area a layer is laid out in, in the box's own coordinates.
    private static func area(_ origin: String?, item: WebItem?, box: CGRect) -> CGRect {
        guard let item else { return CGRect(origin: .zero, size: box.size) }
        let b = item.borders, p = item.paddings
        switch origin ?? "padding-box" {
        case "border-box": return CGRect(origin: .zero, size: box.size)
        case "content-box":
            return CGRect(x: b.3 + p.3, y: b.0 + p.0, width: max(box.width - b.1 - b.3 - p.1 - p.3, 0), height: max(box.height - b.0 - b.2 - p.0 - p.2, 0))
        default:
            return CGRect(x: b.3, y: b.0, width: max(box.width - b.1 - b.3, 0), height: max(box.height - b.0 - b.2, 0))
        }
    }

    /// Whether Bezzle can draw a background layer as a fill of its own, or the box's background
    /// must be photographed instead.
    static func drawable(_ layer: WebLayer, item: WebItem?, assets: WebAssets?) -> Bool {
        if layer.other != nil { return false }
        if let blend = layer.blend, blend != "normal" { return false }
        if let grad = layer.grad {
            let size = item.map { CGSize(width: max($0.box.width, 1), height: max($0.box.height, 1)) } ?? CGSize(width: 100, height: 100)
            if CSS.gradient(grad, size: size) == nil { return false }
            return !tiles(layer, item: item, natural: nil)
        }
        if let img = layer.img {
            // An SVG background is photographed with the rest of the box's background.
            if let assets, assets.pictures[img] == nil { return false }
            let natural = assets?.pictures[img]?.size
            return !tiles(layer, item: item, natural: natural)
        }
        return true
    }

    /// Whether a layer is laid side by side, smaller than its box, as one fill cannot be.
    private static func tiles(_ layer: WebLayer, item: WebItem?, natural: CGSize?) -> Bool {
        let rep = layer.rep ?? "repeat"
        guard rep.contains("repeat") && !rep.contains("no-repeat") || rep == "space" || rep == "round" || rep.hasPrefix("repeat") else { return false }
        if rep == "no-repeat" { return false }
        guard let item else { return false }
        let box = item.box
        let size = drawnSize(layer, area: area(layer.origin, item: item, box: box).size, natural: natural ?? box.size)
        let repeatsX = rep == "repeat" || rep == "repeat-x" || rep == "round" || rep == "space" || rep.hasPrefix("repeat repeat") || rep.hasPrefix("repeat ")
        let repeatsY = rep == "repeat" || rep == "repeat-y" || rep == "round" || rep == "space" || rep.hasSuffix(" repeat")
        return (repeatsX && size.width < box.width - 1) || (repeatsY && size.height < box.height - 1)
    }

    /// How big a background picture is drawn in an area, as background-size says.
    private static func drawnSize(_ layer: WebLayer, area: CGSize, natural: CGSize) -> CGSize {
        let nat = CGSize(width: max(natural.width, 1), height: max(natural.height, 1))
        let words = CSS.words(layer.size ?? "auto")
        switch words.first ?? "auto" {
        case "cover":
            let s = max(area.width / nat.width, area.height / nat.height)
            return CGSize(width: nat.width * s, height: nat.height * s)
        case "contain":
            let s = min(area.width / nat.width, area.height / nat.height)
            return CGSize(width: nat.width * s, height: nat.height * s)
        default:
            let w = words.first.flatMap { $0 == "auto" ? nil : CSS.length($0, of: area.width) }
            let h = words.count > 1 ? (words[1] == "auto" ? nil : CSS.length(words[1], of: area.height)) : nil
            switch (w, h) {
            case let (w?, h?): return CGSize(width: w, height: h)
            case let (w?, nil): return CGSize(width: w, height: w * nat.height / nat.width)
            case let (nil, h?): return CGSize(width: h * nat.width / nat.height, height: h)
            default: return nat
            }
        }
    }

    /// One background layer as a fill of the box.
    private mutating func fill(_ layer: WebLayer, box: CGRect, item: WebItem?) -> Fill? {
        let size = CGSize(width: max(box.width, 1), height: max(box.height, 1))
        if let grad = layer.grad {
            let area = Self.area(layer.origin, item: item, box: box)
            guard var g = CSS.gradient(grad, size: area.size == .zero ? size : area.size) else {
                report.note("Conic and other gradients, left out")
                return nil
            }
            // Laid in its area, which may be smaller than the box.
            if area.size != size, area.width > 0, area.height > 0 {
                func move(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (area.minX + p.x * area.width) / size.width, y: (area.minY + p.y * area.height) / size.height)
                }
                g.start = move(g.start)
                g.end = move(g.end)
                g.across = g.across.map(move)
                g.radius = g.radius * area.width / size.width
            }
            if Self.tiles(layer, item: item, natural: nil) { report.note("Repeating backgrounds, drawn once") }
            return Fill(color: g.stops.first?.color ?? .black, gradient: g)
        }
        guard let index = layer.img, let picture = assets.pictures[index] else {
            if layer.img != nil, assets.vectors[layer.img!] != nil { report.note("SVG backgrounds, as pictures") }
            return nil
        }
        let area = Self.area(layer.origin, item: item, box: box)
        let drawn = Self.drawnSize(layer, area: area.size, natural: picture.size)
        let x = CSS.offset(layer.x ?? "0%", room: area.width - drawn.width, horizontal: true)
        let y = CSS.offset(layer.y ?? "0%", room: area.height - drawn.height, horizontal: false)
        let rect = CGRect(x: area.minX + x, y: area.minY + y, width: drawn.width, height: drawn.height)
        if Self.tiles(layer, item: item, natural: picture.size) { report.note("Repeating backgrounds, drawn once") }
        return Fill(color: .white, image: Self.imageFill(picture, drawn: rect, in: size))
    }

    /// A picture drawn in `drawn`, a rectangle in a box of `size`, as a fill of that box: it
    /// covers the box scaled by how much bigger or smaller it is drawn, and moved to its place.
    static func imageFill(_ picture: WebAssets.Picture, drawn: CGRect, in size: CGSize) -> ImageFill {
        let w = max(picture.size.width, 1), h = max(picture.size.height, 1)
        let aspect = (drawn.width / max(drawn.height, 0.0001)) / (w / h)
        // Squeezed to a shape of its own, it is stretched; filling the box exactly, too.
        if abs(aspect - 1) > 0.02 {
            if abs(drawn.minX) < 0.5, abs(drawn.minY) < 0.5, abs(drawn.width - size.width) < 0.5, abs(drawn.height - size.height) < 0.5 {
                return ImageFill(asset: picture.asset, mode: .stretch, size: picture.size)
            }
        }
        let cover = max(size.width / w, size.height / h)
        var fill = ImageFill(asset: picture.asset, mode: .cover, size: picture.size)
        let scale = drawn.width / (w * cover)
        if abs(scale - 1) > 0.001 { fill.scale = scale }
        let shownW = w * cover * scale, shownH = h * cover * scale
        let ox = (drawn.minX - (size.width - shownW) / 2) / size.width
        let oy = (drawn.minY - (size.height - shownH) / 2) / size.height
        fill.offset = CGPoint(x: abs(ox) < 0.0001 ? 0 : ox, y: abs(oy) < 0.0001 ? 0 : oy)
        return fill
    }

    // MARK: Pictures

    /// A photograph of part of the page, where it was taken.
    private func picture(_ shot: WebAssets.Shot, name: String) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: shot.frame)
        n.fills = [Fill(color: .white, image: ImageFill(asset: shot.asset, mode: .stretch, size: shot.size))]
        return n
    }

    /// An <img>, <video> poster or canvas drawn in its box as object-fit and object-position say.
    private mutating func picture(_ img: WebImage, item: WebItem, name: String) -> [Node] {
        guard let index = img.src else { return [] }
        let content = item.contentBox
        guard content.width > 0, content.height > 0 else { return [] }
        if let paths = assets.vectors[index] {
            return vectors(paths, item: item, name: name, cutTo: content)
        }
        guard var picture = assets.pictures[index] else { return [] }
        if picture.size.width <= 0 || picture.size.height <= 0, let nat = img.nat, nat.count == 2 { picture.size = CGSize(width: nat[0], height: nat[1]) }
        let size = content.size
        let nat = picture.size
        var drawn: CGSize
        switch img.fit ?? "fill" {
        case "contain":
            let s = min(size.width / nat.width, size.height / nat.height)
            drawn = CGSize(width: nat.width * s, height: nat.height * s)
        case "cover":
            let s = max(size.width / nat.width, size.height / nat.height)
            drawn = CGSize(width: nat.width * s, height: nat.height * s)
        case "none":
            let css = img.nat.map { CGSize(width: $0[0], height: $0[1]) } ?? nat
            drawn = css
        case "scale-down":
            let s = min(1, min(size.width / nat.width, size.height / nat.height))
            drawn = CGSize(width: nat.width * s, height: nat.height * s)
        default:
            drawn = size
        }
        let pos = CSS.position(CSS.words(img.pos ?? "50% 50%"), in: size, object: drawn)
        let rect = CGRect(origin: pos, size: drawn)
        var n = Node(kind: isEllipse(item) ? .ellipse : .rectangle, name: name, frame: content)
        if n.kind == .rectangle {
            let b = item.borders, p = item.paddings
            n.radii = corners(item, inset: max(b.0 + p.0, b.3 + p.3)).map { $0 * Self.growth(item.matrix) }
        }
        n.fills = [Fill(color: .white, image: Self.imageFill(picture, drawn: rect, in: size))]
        placed(&n, content, item.matrix)
        return [n]
    }

    // MARK: Outlines

    /// An SVG's outlines as paths, grouped when there are several.
    private mutating func vectors(_ paths: [WebPath], item: WebItem, name: String, cutTo: CGRect? = nil) -> [Node] {
        let outer = item.matrix
        var out: [Node] = []
        for p in paths {
            var m = p.matrix
            if let outer { m = m.concatenating(outer) }
            guard var n = ImportGeometry.outline(p.d, m) else { continue }
            n.name = name
            let k = Self.growth(m)
            n.fills = []
            if let fill = p.fill, let f = svgFill(fill, node: n, path: p, m: m) { n.fills = [f] }
            if p.rule == "evenodd" { n.evenOdd = true }
            if let stroke = p.stroke {
                let color = stroke.paint.c.flatMap { CSS.color($0) } ?? stroke.paint.g.flatMap { CSS.color($0.stops.first?.c) } ?? .black
                if stroke.paint.g != nil { report.note("Gradient strokes, in their first colour") }
                var b = Border(on: true, color: color, width: CGFloat(stroke.w) * k, position: .center)
                if let dash = stroke.dash, dash.count == 2, dash[0] > 0 {
                    b.dash = CGFloat(dash[0]) * k
                    b.gap = CGFloat(dash[1]) * k
                }
                n.borders = [b]
            }
            if let op = p.op, op < 1 { n.opacity = op }
            if n.fills.isEmpty && n.borders.isEmpty { continue }
            if n.frame.width < 0.001 && n.frame.height < 0.001 { continue }
            out.append(n)
        }
        guard !out.isEmpty else { return [] }
        if let cutTo {
            var edge = Node(kind: .rectangle, name: String(localized: "Edge"), frame: cutTo)
            placed(&edge, cutTo, outer)
            if ImportMask.reaches(out, outside: edge) {
                ImportMask.clear(&edge)
                if let mask = ImportMask.mask(edge, holding: out, name: name) { return [mask] }
            }
        }
        if out.count == 1 { return out }
        var g = Node(kind: .group, name: name, frame: .zero)
        g.children = out
        return [g]
    }

    /// An SVG paint as a fill of the path it paints, its gradient carried from the shape's own
    /// coordinates onto the layer's frame.
    private mutating func svgFill(_ paint: WebSVGPaint, node: Node, path: WebPath, m: CGAffineTransform) -> Fill? {
        if let c = paint.c { return CSS.color(c).map { Fill(color: $0) } }
        guard let g = paint.g, g.a.count == 2, g.b.count == 2 else { return nil }
        let stops = g.stops.compactMap { s in CSS.color(s.c).map { GradientStop(offset: s.o, color: $0) } }.sorted { $0.offset < $1.offset }
        guard !stops.isEmpty else { return nil }
        // Into the page, then into the layer's own frame, upright.
        let turn = CGAffineTransform(rotationAngle: -node.rotation * .pi / 180)
        let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
        func unit(_ p: [Double]) -> CGPoint {
            let onPage = CGPoint(x: p[0], y: p[1]).applying(m)
            let upright = CGPoint(x: onPage.x - center.x, y: onPage.y - center.y).applying(turn)
            let local = CGPoint(x: upright.x + node.frame.width / 2, y: upright.y + node.frame.height / 2)
            return CGPoint(x: local.x / max(node.frame.width, 0.001), y: local.y / max(node.frame.height, 0.001))
        }
        let gradient: Gradient
        if g.k == "linear" {
            gradient = Gradient(kind: .linear, stops: stops, start: unit(g.a), end: unit(g.b))
        } else {
            let e = g.e ?? [g.a[0], g.a[1] + (g.b[0] - g.a[0])]
            let c = unit(g.a), x = unit(g.b), y = unit(e)
            gradient = Gradient(kind: .radial, stops: stops, start: c, end: x, radius: abs(x.x - c.x), across: y)
        }
        return Fill(color: stops[0].color, gradient: gradient)
    }

    // MARK: Cutting to a shape

    private mutating func clipHolder(_ value: String, item: WebItem) -> Node? {
        let box = item.box
        guard let shape = CSS.clipShape(value, size: box.size) else { return nil }
        var n: Node
        switch shape {
        case .rect(let r, let radius):
            let rect = r.offsetBy(dx: box.minX, dy: box.minY)
            n = Node(kind: .rectangle, name: String(localized: "Edge"), frame: rect)
            n.cornerRadius = radius
            placed(&n, rect, item.matrix)
        case .ellipse(let r):
            let rect = r.offsetBy(dx: box.minX, dy: box.minY)
            n = Node(kind: .ellipse, name: String(localized: "Edge"), frame: rect)
            placed(&n, rect, item.matrix)
        case .path(let d, let evenOdd):
            var m = CGAffineTransform(translationX: box.minX, y: box.minY)
            if let outer = item.matrix { m = m.concatenating(outer) }
            guard var p = ImportGeometry.outline(d, m) else { return nil }
            p.name = String(localized: "Edge")
            if evenOdd { p.evenOdd = true }
            n = p
        }
        ImportMask.clear(&n)
        return n
    }

    // MARK: Words

    /// Words as text layers: a paragraph wrapped in its box as the browser wrapped it, or, where
    /// it shares its lines with boxes or runs round them, a text a line.
    private mutating func text(_ item: WebItem) -> [Node] {
        guard let words = item.text, let runs = item.runs, let styles = item.styles, let lines = item.lines, !lines.isEmpty, let cont = item.cont else { return [] }
        let utf16 = Array(words.utf16)
        // Letters no one sees, and nothing painted through them, are left out.
        let painting = item.paint.flatMap { textPaint($0) }
        if painting == nil, styles.allSatisfy({ $0.c.count < 4 || $0.c[3] <= 0.001 }) { return [] }
        // Letters clear but for what shows through them are painted with it.
        let looks = styles.map { s -> Letters in
            var l = letters(s)
            if let painting, l.color.a < 0.01 { l.color = painting.color }
            return l
        }
        if styles.contains(where: { $0.stroke != nil }) { report.note("Texts with a border, shown without it") }
        if styles.contains(where: { $0.va != nil }) { report.note("Raised and lowered letters, set on the line") }

        // Runs between two places in the words, as UTF-16 counts them.
        func pieces(_ from: Int, _ to: Int) -> [(text: String, letters: Letters, style: Int)] {
            var out: [(String, Letters, Int)] = []
            var at = 0
            for run in runs where run.count == 2 {
                let length = run[0], style = run[1]
                let lo = max(at, from), hi = min(at + length, to)
                if lo < hi, lo < utf16.count {
                    let slice = String(decoding: utf16[lo..<min(hi, utf16.count)], as: UTF16.self)
                    if style < looks.count { out.append((slice, looks[style], style)) }
                }
                at += length
            }
            return out
        }

        let mainStyle: WebLetters = {
            var counts: [Int: Int] = [:]
            for run in runs where run.count == 2 { counts[run[1], default: 0] += run[0] }
            let most = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
            return styles[min(most, styles.count - 1)]
        }()
        let m = item.matrix
        let align = Self.align(cont.align, rtl: cont.dir == "rtl")
        let name = Self.textName(words)

        func make(_ from: Int, _ to: Int, sizing: TextSizing) -> Node? {
            let parts = pieces(from, to)
            guard !parts.isEmpty else { return nil }
            var n = Node(kind: .text, name: name, frame: .zero)
            var ts = TextStyle()
            ts.sizing = sizing
            ts.align = align
            if let lh = mainStyle.lh, lh > 0 { ts.lineSpacing = (lh * 10).rounded() / 10 }
            ts.features = Self.features(mainStyle)
            ts.axes = Self.axes(mainStyle)
            let cases = parts.map { Self.letterCase($0.style < styles.count ? styles[$0.style] : mainStyle) }
            let cased = ImportText.cased(parts.map { ($0.text, $0.letters) }, cases, report: &report)
            ts.letterCase = cased.letterCase
            n.style = ts
            n.setImportedRuns(cased.runs, painting: painting)
            if let tsh = mainStyle.tsh {
                n.shadows = CSS.shadows(tsh, current: CSS.color(mainStyle.c) ?? .black)
            }
            return n
        }

        let multi = lines.count > 1
        let room = Self.room(lines, cont: cont, align: align)
        let paragraph = item.clean == true && cont.wrap && cont.w > 0 && item.marker != true && (cont.indent ?? 0) == 0 && Self.stacked(lines) && room != nil
        if paragraph || (item.field == true && cont.wrap) {
            if var n = make(0, utf16.count, sizing: .autoHeight) {
                n.frame = CGRect(x: cont.x, y: lines[0].y, width: max(room ?? CGFloat(cont.w), 1), height: 10)
                n.refit()
                if !multi && item.field != true && Self.lineCount(n) > 1 {
                    // One line in the browser stays one line here, however wide its letters are.
                    if let single = singleLine(item, lines[0], make: { make($0, $1, sizing: .autoWidth) }) { return [single].map { place($0, m) } }
                } else if item.field != true {
                    fit(&n, lines: lines, cont: cont, align: align)
                }
                n.frame.origin.y = CGFloat(lines[0].base) - TextLayout.firstBaseline(n)
                return [place(n, m)]
            }
            return []
        }
        if !multi || item.marker == true || cont.wrap == false && !multi {
            guard let single = singleLine(item, lines[0], make: { make($0, $1, sizing: .autoWidth) }) else { return [] }
            return [place(single, m)]
        }
        // A text a line, each where the browser set it.
        var out: [Node] = []
        for line in lines {
            var from = line.from
            while from < min(line.to, utf16.count), utf16[from] == 32 || utf16[from] == 10 { from += 1 }
            guard var n = make(from, line.to, sizing: .autoWidth) else { continue }
            n.style?.align = .left
            n.refit()
            n.frame.origin = CGPoint(x: CGFloat(line.x), y: CGFloat(line.base) - TextLayout.firstBaseline(n))
            if cont.dir == "rtl" { n.frame.origin.x = CGFloat(line.x + line.w) - n.frame.width }
            n.name = Self.textName(n.text ?? "")
            out.append(place(n, m))
        }
        if out.count > 1 {
            report.note("Texts wrapped round other boxes, a text a line")
            var g = Node(kind: .group, name: name, frame: .zero)
            g.children = out
            return [g]
        }
        return out
    }

    /// One line of words, at its natural width, held where the browser put it by its alignment.
    private func singleLine(_ item: WebItem, _ line: WebLine, make: (Int, Int) -> Node?) -> Node? {
        guard var n = make(0, Array((item.text ?? "").utf16).count) else { return nil }
        n.refit()
        let cont = item.cont!
        let width = n.frame.width
        var x = CGFloat(line.x)
        switch n.style?.align ?? .left {
        case .center: x = CGFloat(line.x + line.w / 2) - width / 2
        case .right: x = CGFloat(line.x + line.w) - width
        default: break
        }
        if item.marker == true {
            // A list's bullet or number ends where the item's words begin.
            x = cont.align == "right" ? CGFloat(cont.x) - width : CGFloat(cont.x)
        }
        n.frame.origin = CGPoint(x: x, y: CGFloat(line.base) - TextLayout.firstBaseline(n))
        return n
    }

    /// How wide a paragraph's lines had to lie in: its box, or less, all along, where a float
    /// lies beside the whole of it. Nil where a float lies beside only some of its lines, or to
    /// its left, which lines of their own show and a paragraph cannot.
    static func room(_ lines: [WebLine], cont: WebBlock, align: TextAlign) -> CGFloat? {
        let width = CGFloat(cont.w)
        guard lines.count > 1, align == .left || align == .justify, cont.dir != "rtl" else { return width }
        let left = CGFloat(lines.map(\.x).min() ?? cont.x)
        if lines.contains(where: { abs(CGFloat($0.x) - left) > 2 }) { return nil }
        let rights = lines.map { CGFloat($0.x + $0.w) }
        let reach = rights.max() ?? left + width
        // A line well short of the others, where a word would have fitted, ran beside something.
        let short = max(80, (reach - left) * 0.25)
        if rights.dropLast().contains(where: { $0 < reach - short }) { return nil }
        let end = CGFloat(cont.x) + width
        if reach < end - max(60, width * 0.15) { return reach - CGFloat(cont.x) + 1 }
        return width
    }

    /// Whether lines lie one under another, as a paragraph's do.
    private static func stacked(_ lines: [WebLine]) -> Bool {
        for (a, b) in zip(lines, lines.dropFirst()) where b.base <= a.base + 0.5 { return false }
        return true
    }

    /// Lets a paragraph out or in a little, until Bezzle wraps it into as many lines as the
    /// browser did: the same font sets a hair wider or narrower in another engine.
    private func fit(_ n: inout Node, lines: [WebLine], cont: WebBlock, align: TextAlign) {
        let want = lines.count
        var have = Self.lineCount(n)
        guard have != want else { return }
        let base = n.frame.width
        let longest = CGFloat(lines.map(\.w).max() ?? Double(base))
        var tries: [CGFloat] = []
        if have > want {
            tries = [1.005, 1.01, 1.02, 1.035, 1.05, 1.075, 1.1].map { base * $0 }
        } else {
            tries = stride(from: 0.99, through: 0.8, by: -0.01).map { base * $0 }.filter { $0 >= longest - 1 }
        }
        let original = n
        for w in tries {
            var t = original
            t.frame.size.width = w
            t.refit()
            have = Self.lineCount(t)
            if have == want {
                switch align {
                case .center: t.frame.origin.x = original.frame.midX - w / 2
                case .right: t.frame.origin.x = original.frame.maxX - w
                default: break
                }
                n = t
                return
            }
        }
    }

    /// How many lines Bezzle lays a text out in.
    static func lineCount(_ n: Node) -> Int {
        let laid = TextLayout.layout(n)
        let range = laid.manager.glyphRange(for: laid.container)
        guard range.length > 0 else { return 1 }
        var count = 0
        laid.manager.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, _ in count += 1 }
        return count
    }

    private func place(_ n: Node, _ m: CGAffineTransform?) -> Node {
        guard let m else { return n }
        var n = n
        guard let p = ImportGeometry.place(n.frame, m) else { return n }
        n.frame = p.frame
        n.rotation = p.rotation
        if abs(p.scale.height - 1) > 0.01 { n.scaleType(by: p.scale.height) }
        return n
    }

    static func textName(_ words: String) -> String {
        let flat = words.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 40 ? String(flat.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    static func align(_ css: String, rtl: Bool) -> TextAlign {
        switch css {
        case "center", "-webkit-center": .center
        case "right", "-webkit-right": .right
        case "justify": .justify
        case "end": rtl ? .left : .right
        case "start": rtl ? .right : .left
        default: rtl && css == "match-parent" ? .right : .left
        }
    }

    static func letterCase(_ s: WebLetters) -> LetterCase? {
        if s.sc == true { return .smallCaps }
        switch s.tt {
        case "uppercase": return .upper
        case "lowercase": return .lower
        case "capitalize": return .title
        default: return nil
        }
    }

    static func features(_ s: WebLetters) -> [String: Int]? {
        var out: [String: Int] = [:]
        if let ff = s.ff {
            for part in CSS.split(ff) {
                let words = CSS.words(part)
                guard let tag = words.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), tag.count == 4 else { continue }
                let value: Int = words.count > 1 ? (words[1] == "off" ? 0 : words[1] == "on" ? 1 : Int(words[1]) ?? 1) : 1
                out[tag] = value
            }
        }
        if let n = s.fvn {
            let map = ["tabular-nums": "tnum", "oldstyle-nums": "onum", "lining-nums": "lnum", "proportional-nums": "pnum",
                       "slashed-zero": "zero", "diagonal-fractions": "frac", "ordinal": "ordn"]
            for word in CSS.words(n) { if let tag = map[word] { out[tag] = 1 } }
        }
        return out.isEmpty ? nil : out
    }

    static func axes(_ s: WebLetters) -> [String: Double]? {
        guard let fv = s.fv else { return nil }
        var out: [String: Double] = [:]
        for part in CSS.split(fv) {
            let words = CSS.words(part)
            guard words.count == 2, let v = Double(words[1]) else { continue }
            let tag = words[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if tag.count == 4 { out[tag] = v }
        }
        return out.isEmpty ? nil : out
    }

    /// What letters with a background showing through them are painted with.
    private mutating func textPaint(_ p: WebPaintBox) -> Fill? {
        let box = CGRect(x: p.x, y: p.y, width: max(p.w, 1), height: max(p.h, 1))
        let fills = self.fills(p.layers ?? [], color: CSS.color(p.bg), box: box, item: nil)
        guard let top = fills.last(where: \.paints) ?? fills.last else { return nil }
        return top
    }

    // MARK: Fonts

    /// How letters look in Bezzle: the first family asked for that this Mac has, or that the
    /// page drew with, its face nearest in weight and slant.
    private mutating func letters(_ s: WebLetters) -> Letters {
        let (family, face) = font(s)
        let color = CSS.color(s.c) ?? .black
        return Letters(family: family, face: face, size: CGFloat(s.size), color: color, underline: s.u ?? false,
                       strikethrough: s.st ?? false, tracking: s.size > 0 ? CGFloat((s.ls / s.size * 1000 * 10).rounded() / 10) : 0, list: nil)
    }

    private static let installed: [String: String] = {
        var out: [String: String] = [:]
        for f in NSFontManager.shared.availableFontFamilies where !f.hasPrefix(".") { out[f.lowercased()] = f }
        return out
    }()

    /// The family by the name this Mac knows it by, as CSS names it in any case. Some, such as
    /// Courier, are there to draw with without being listed.
    static func installedFamily(_ name: String) -> String? {
        if let found = installed[name.lowercased()] { return found }
        if NSFontManager.shared.availableMembers(ofFontFamily: name)?.isEmpty == false { return name }
        return nil
    }

    private static let systemNames: Set<String> = ["-apple-system", "blinkmacsystemfont", "system-ui", "ui-sans-serif", "ui-rounded",
                                                   "sf pro", "sf pro text", "sf pro display", "san francisco", ".sf ns", ".applesystemuifont"]
    private static let generics: [String: String] = ["serif": "Times", "sans-serif": "Helvetica", "monospace": "Courier", "ui-monospace": "Menlo",
                                                     "ui-serif": "Times", "cursive": "Apple Chancery", "fantasy": "Papyrus", "emoji": "Apple Color Emoji",
                                                     "math": "STIX Two Math", "fangsong": "STSong"]

    private mutating func font(_ s: WebLetters) -> (String, String) {
        for family in s.fam {
            let lower = family.lowercased()
            if Self.systemNames.contains(lower) { return (TextStyle.system, Self.systemFace(weight: s.wt, italic: s.it)) }
            if let g = Self.generics[lower] {
                let real = Self.installedFamily(g) ?? "Helvetica"
                return (real, Self.face(in: real, weight: s.wt, italic: s.it))
            }
            if let real = Self.installedFamily(family) {
                return (real, Self.face(in: real, weight: s.wt, italic: s.it))
            }
            if family == s.used || lower == s.used.lowercased() {
                // Drawn with a font of the page's own, which this Mac does not have: kept by name.
                let face = Self.faceName(weight: s.wt, italic: s.it)
                return fonts.resolve(postscript: nil, family: family, face: face, report: &report)
            }
        }
        return (TextStyle.system, Self.systemFace(weight: s.wt, italic: s.it))
    }

    static func systemFace(weight: Int, italic: Bool) -> String {
        let names = [(100, "Ultralight"), (200, "Thin"), (300, "Light"), (400, "Regular"), (500, "Medium"), (600, "Semibold"), (700, "Bold"), (800, "Heavy"), (900, "Black")]
        let name = names.min { abs($0.0 - weight) < abs($1.0 - weight) }?.1 ?? "Regular"
        return italic ? "\(name) Italic" : name
    }

    /// A face's name as fonts from the web are mostly named, for a font this Mac does not have.
    static func faceName(weight: Int, italic: Bool) -> String {
        let names = [(100, "Thin"), (200, "ExtraLight"), (300, "Light"), (400, "Regular"), (500, "Medium"), (600, "SemiBold"), (700, "Bold"), (800, "ExtraBold"), (900, "Black")]
        let name = names.min { abs($0.0 - weight) < abs($1.0 - weight) }?.1 ?? "Regular"
        if italic { return name == "Regular" ? "Italic" : "\(name) Italic" }
        return name
    }

    /// The face of an installed family nearest a CSS weight, leaning as asked.
    static func face(in family: String, weight: Int, italic: Bool) -> String {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        guard !members.isEmpty else { return faceName(weight: weight, italic: italic) }
        // The font manager's weights, 5 regular and 9 bold, for CSS's hundreds.
        let table: [(Int, Double)] = [(100, 2), (200, 3), (300, 4), (400, 5), (500, 6), (600, 8), (700, 9), (800, 10), (900, 11)]
        let want: Double = {
            let w = min(max(weight, 100), 900)
            let lo = table.last { $0.0 <= w }!, hi = table.first { $0.0 >= w }!
            if lo.0 == hi.0 { return lo.1 }
            return lo.1 + (hi.1 - lo.1) * Double(w - lo.0) / Double(hi.0 - lo.0)
        }()
        var best: (String, Double)?
        for member in members {
            guard member.count >= 4, let face = member[1] as? String else { continue }
            let w = Double((member[2] as? Int) ?? 5)
            let traits = NSFontTraitMask(rawValue: UInt((member[3] as? Int) ?? 0))
            let leans = traits.contains(.italicFontMask)
            var cost = abs(w - want) + (leans == italic ? 0 : 20)
            if traits.contains(.condensedFontMask) || traits.contains(.narrowFontMask) || traits.contains(.expandedFontMask) { cost += 3 }
            if face.range(of: "Condensed|Compressed|Expanded|Wide|Narrow|Display|Caption|Text", options: .regularExpression) != nil { cost += 0.5 }
            if best == nil || cost < best!.1 { best = (face, cost) }
        }
        return best?.0 ?? faceName(weight: weight, italic: italic)
    }
}
