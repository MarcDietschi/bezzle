import Testing
import AppKit
@testable import Bezzle

/// Adaptive layout put through everything a design can hold and every way an artboard's size can
/// change: each kind of layer and artboard, hand-made designs and a few hundred made at random,
/// every preset size and some no preset has, drags back and forth, the canvas, the inspector, the
/// AI's tools, undo, files and sharing. `problems` says, in words, everything that must hold of a
/// design laid out at a new size; most tests make designs and sizes and expect none.
@MainActor
struct AdaptSuiteTests {
    typealias A = AdaptTests

    // MARK: - What must always hold

    /// Whether a layer is part of the design's flow on `page`: shown, inside it, not covering it,
    /// not bleeding off it. Only those are held to staying apart and on the page.
    static func flows(_ n: Node, on page: CGRect) -> Bool {
        let b = Geometry.bounds(of: n)
        let inside = b.minX >= page.minX - 1 && b.minY >= page.minY - 1 && b.maxX <= page.maxX + 1 && b.maxY <= page.maxY + 1
        return !n.hidden && inside && b.intersection(page).area < page.area * 0.85
    }

    /// Everything wrong with `laid`, `design` laid out at `size`, in words; nothing when all is well.
    static func problems(_ design: Node, _ laid: Node, size: CGSize, roomy: Bool = true, shapes: [String: CGRect] = [:],
                         cores: [String: CGRect] = [:]) -> [String] {
        // What a layer shows: a cut-out picture, the part of its box its subject covers; its body, with `body`.
        func shown(_ n: Node, body: Bool = false) -> CGRect {
            let b = Geometry.bounds(of: n)
            guard let image = n.fill.image, n.rotation == 0, let shape = body ? cores[image.asset] ?? shapes[image.asset] : shapes[image.asset] else { return b }
            let d = Renderer.imageRect(image, in: n.frame.size).offsetBy(dx: n.frame.minX, dy: n.frame.minY)
            let r = CGRect(x: d.minX + shape.minX * d.width, y: d.minY + shape.minY * d.height, width: shape.width * d.width, height: shape.height * d.height).intersection(b)
            return r.isNull ? b : r
        }
        var out: [String] = []
        func say(_ s: String) { out.append("\(design.name) at \(Int(size.width))×\(Int(size.height)): \(s)") }
        if laid.frame.size != size { say("the artboard is \(laid.frame.size)") }
        if laid.frame.origin != design.frame.origin { say("the artboard moved to \(laid.frame.origin)") }
        if laid.id != design.id || laid.name != design.name || laid.fill != design.fill || laid.pinsLayers != design.pinsLayers {
            say("the artboard itself changed")
        }
        let a = design.children, b = laid.children
        guard a.map(\.id) == b.map(\.id) else {
            say("its layers are not the same ones in the same order")
            return out
        }
        let page0 = CGRect(origin: .zero, size: design.frame.size), page1 = CGRect(origin: .zero, size: size)

        func sound(_ n: Node, in path: String) {
            let f = n.frame
            if ![f.minX, f.minY, f.width, f.height].allSatisfy(\.isFinite) || f.width < 0 || f.height < 0 { say("\(path)\(n.name) is at \(f)") }
            if let s = n.style?.size, !(s.isFinite && s >= 1) { say("\(path)\(n.name) has type of \(s)") }
            if !n.cornerRadius.isFinite || n.cornerRadius < 0 { say("\(path)\(n.name) has corners of \(n.cornerRadius)") }
            for c in n.children { sound(c, in: path + n.name + " › ") }
        }
        func same(_ x: Node, _ y: Node, in path: String, band: Bool = false) {
            if x.id != y.id || x.kind != y.kind || x.name != y.name { say("\(path)\(x.name) became \(y.name)") ; return }
            if x.text != y.text || x.spans?.map(\.text) != y.spans?.map(\.text) { say("\(path)\(x.name): its words changed") }
            if x.hidden != y.hidden || x.locked != y.locked || x.post != y.post || x.own != y.own || x.rotation != y.rotation
                || x.blend != y.blend || x.opacity != y.opacity || x.clipsToFirst != y.clipsToFirst || x.exports != y.exports {
                say("\(path)\(x.name): changed more than its place and size")
            }
            if x.fill.color != y.fill.color || x.fill.gradient != y.fill.gradient || x.fill.on != y.fill.on || x.fill.image?.asset != y.fill.image?.asset
                || x.fill.image?.mode != y.fill.image?.mode || x.moreFills?.count != y.moreFills?.count {
                say("\(path)\(x.name): its fill changed")
            }
            if x.border.color != y.border.color || x.border.on != y.border.on || x.shadow.on != y.shadow.on || x.shadow.color != y.shadow.color {
                say("\(path)\(x.name): its border or shadow changed colour")
            }
            if x.grid?.columns != y.grid?.columns || x.grid?.rows != y.grid?.rows { say("\(path)\(x.name): its grid changed") }
            // A hairline scaled down may be thinner than half a point; what had a size of its own does not vanish.
            if path.isEmpty || roomy, x.frame.width >= 2 && y.frame.width < 0.05 || x.frame.height >= 2 && y.frame.height < 0.05 {
                say("\(path)\(x.name) collapsed to \(y.frame)")
            }
            if !band, [.ellipse, .path].contains(x.kind), x.frame.width > 2, x.frame.height > 2, y.frame.width > 2, y.frame.height > 2 {
                let r0 = x.frame.width / x.frame.height, r1 = y.frame.width / y.frame.height
                if abs(r1 / r0 - 1) > 0.03 { say("\(path)\(x.name) was stretched from \(x.frame.size) to \(y.frame.size)") }
            }
            // A picture that covered its layer still does.
            if let was = x.fill.image, was.mode == .cover, x.frame.width > 1, x.frame.height > 1,
               Renderer.imageRect(was, in: x.frame.size).insetBy(dx: -0.75, dy: -0.75).contains(CGRect(origin: .zero, size: x.frame.size)),
               let image = y.fill.image, y.frame.width > 1, y.frame.height > 1 {
                let r = Renderer.imageRect(image, in: y.frame.size)
                if !r.insetBy(dx: -0.75, dy: -0.75).contains(CGRect(origin: .zero, size: y.frame.size)) { say("\(path)\(x.name)'s picture no longer covers it: \(r) in \(y.frame.size)") }
            }
            guard x.children.count == y.children.count else { say("\(path)\(x.name) holds \(y.children.count) layers, not \(x.children.count)"); return }
            for (cx, cy) in zip(x.children, y.children) { same(cx, cy, in: path + x.name + " › ", band: band) }
        }
        // A band running along an edge, from side to side, stretches with the page.
        func isBand(_ n: Node) -> Bool {
            let b = Geometry.bounds(of: n)
            return n.kind != .text && b.minX <= 2.5 && b.maxX >= page0.maxX - 2.5 && (b.minY <= 2.5) != (b.maxY >= page0.maxY - 2.5) && b.height < page0.height * 0.6
        }
        for (x, y) in zip(a, b) {
            sound(y, in: "")
            same(x, y, in: "", band: isBand(x))
        }

        // One scale for all type, so its hierarchy holds.
        var ratios: [(CGFloat, CGFloat, String)] = []
        func type(_ x: Node, _ y: Node) {
            if let s0 = x.style?.size, let s1 = y.style?.size, s1 > 1 { ratios.append((s1 / s0, s0, x.name)) }
            // A copy of a component keeps its component's type, as it does when its handles resize it.
            guard !y.isCopy else { return }
            for (cx, cy) in zip(x.children, y.children) { type(cx, cy) }
        }
        for (x, y) in zip(a, b) { type(x, y) }
        // Sizes are kept to a tenth of a point, so each may be that far from its exact scale.
        if let largest = ratios.max(by: { $0.1 < $1.1 }) {
            for (r, s0, name) in ratios where abs(r - largest.0) > 0.051 / s0 + 0.051 / largest.1 + largest.0 * 0.004 {
                say("\(name)'s type grew by \(r), \(largest.2)'s by \(largest.0)")
            }
        }

        guard roomy else { return out }
        // What lay on the page still does; what lay apart still does; what lay in another still does.
        let flowing = a.indices.filter { flows(a[$0], on: page0) && !isBand(a[$0]) }
        func inside(_ r: CGRect, _ page: CGRect) -> Bool { r.minX >= page.minX && r.minY >= page.minY && r.maxX <= page.maxX && r.maxY <= page.maxY }
        for i in flowing where !inside(shown(b[i]), page1.insetBy(dx: -1.5, dy: -1.5)) {
            say("\(b[i].name) left the artboard: \(shown(b[i]))")
        }
        // Layers that lay over one another, however far it reaches, are one block.
        var block = Array(a.indices)
        func root(_ i: Int) -> Int { var r = i; while block[r] != r { r = block[r] }; return r }
        for i in flowing {
            for j in flowing where j > i && shown(a[i], body: true).insetBy(dx: 0.5, dy: 0.5).intersects(shown(a[j], body: true).insetBy(dx: 0.5, dy: 0.5)) {
                block[root(j)] = root(i)
            }
        }
        for i in flowing {
            for j in flowing where j > i && root(i) != root(j) || j > i && Geometry.bounds(of: a[i]).insetBy(dx: -1, dy: -1).contains(Geometry.bounds(of: a[j])) {
                let x0 = shown(a[i], body: true), y0 = shown(a[j], body: true)
                let x1 = shown(b[i], body: true), y1 = shown(b[j], body: true)
                if !x0.insetBy(dx: -1, dy: -1).intersects(y0), x1.insetBy(dx: 1, dy: 1).intersects(y1.insetBy(dx: 1, dy: 1)) {
                    say("\(b[i].name) \(x1.integral) now lies over \(b[j].name) \(y1.integral)")
                }
                if x0.insetBy(dx: -1, dy: -1).contains(y0), y1.width > 1, y1.height > 1, y1.intersection(x1).area < y1.area * 0.9 {
                    say("\(b[j].name) came out of \(b[i].name)")
                }
            }
        }
        return out
    }

    /// The design laid out at each size, and everything wrong with it.
    static func check(_ design: Node, at sizes: [CGSize], roomy: Bool = true) -> [String] {
        let plan = Adapt.plan(design)
        return sizes.flatMap { s in problems(design, Adapt.compose(plan, to: s).board, size: s, roomy: roomy && roomyEnough(design, s)) }
    }

    /// Sizes the design can be held to: at a sliver of its size, type bottoms out at a point and
    /// what cannot shrink further need not fit.
    static func roomyEnough(_ design: Node, _ s: CGSize) -> Bool {
        min(s.width / design.frame.width, s.height / design.frame.height) > 0.12 && min(s.width, s.height) >= 60
    }

    // MARK: - Designs of every kind

    static let ink = A.ink, accent = A.accent

    /// An artboard whose layers were made through the store, as a person makes them: grouped,
    /// gridded or masked by selecting and choosing.
    static func made(_ size: CGSize, _ layers: [Node], name: String, _ build: (DocumentStore, (String) -> UUID) -> Void) -> Node {
        let bench = Bench()
        var board = A.board(size, layers)
        board.name = name
        board.frame.origin = CGPoint(x: 100, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [board] } }
        func id(_ name: String) -> UUID { bench.store.doc.allNodes.first { $0.name == name }!.id }
        bench.step { build(bench.store, id) }
        return bench.store.doc.nodes[0]
    }

    static func words() -> Node {
        var b = A.board(CGSize(width: 1080, height: 1350), [
            A.text("A field guide to slow travel", 84, face: "Bold", at: CGPoint(x: 90, y: 120), width: 860, color: ink),
            A.text("Trains over planes, long lunches over checklists, and never more than one bag. What we learned in a year of going nowhere fast.",
                   34, at: CGPoint(x: 90, y: 460), width: 860, color: ink.with(alpha: 0.75)),
            A.text("ISSUE 12 · SPRING", 22, face: "Semibold", at: CGPoint(x: 90, y: 1240), color: ink),
        ])
        b.name = "Words"
        return b
    }

    static func cardGrid() -> Node {
        made(CGSize(width: 1440, height: 1024), [
            A.text("Destinations", 48, face: "Bold", at: CGPoint(x: 80, y: 80), color: ink),
            A.rect(CGRect(x: 80, y: 200, width: 400, height: 300), RGBA(r: 0.95, g: 0.94, b: 0.92), radius: 20, name: "Card"),
            A.text("Lisbon", 28, face: "Bold", at: CGPoint(x: 110, y: 230), color: ink),
        ], name: "Grid") { store, id in
            store.selection = [id("Card"), id("Lisbon")]
            store.makeRepeatGrid()
            if let grid = store.selection.first { store.changeGrid(grid, "Grid") { $0.columns = 3; $0.rows = 2; $0.columnGap = 40; $0.rowGap = 40 } }
        }
    }

    static func profile() -> Node {
        var circle = Node(kind: .ellipse, name: "Circle", frame: CGRect(x: 340, y: 160, width: 400, height: 400))
        circle.fill.color = .shape
        return made(CGSize(width: 1080, height: 1080), [
            circle,
            A.photo(CGRect(x: 300, y: 120, width: 480, height: 480)),
            A.text("Mara Lind", 64, face: "Bold", at: CGPoint(x: 540, y: 660), align: .center, color: ink),
            A.text("Photographer, Zürich", 34, at: CGPoint(x: 540, y: 760), align: .center, color: ink.with(alpha: 0.6)),
        ], name: "Profile") { store, id in
            store.selection = [id("Circle"), id("Photo")]
            store.maskSelection()
        }
    }

    static func navGroups() -> Node {
        made(CGSize(width: 1440, height: 900), [
            A.rect(CGRect(x: 0, y: 0, width: 1440, height: 88), ink, name: "Nav"),
            A.text("Atlas", 28, face: "Bold", at: CGPoint(x: 64, y: 28), color: .white),
            A.text("Docs", 18, at: CGPoint(x: 1180, y: 34), color: .white),
            A.text("Blog", 18, at: CGPoint(x: 1260, y: 34), color: .white),
            A.text("Ship design systems in days", 72, face: "Bold", at: CGPoint(x: 64, y: 300), width: 900, color: ink),
            A.rect(CGRect(x: 0, y: 820, width: 1440, height: 80), RGBA(r: 0.95, g: 0.95, b: 0.95), name: "Footer"),
            A.text("© Atlas", 16, at: CGPoint(x: 64, y: 850), color: ink),
        ], name: "Nav") { store, id in
            store.selection = [id("Nav"), id("Atlas"), id("Docs"), id("Blog")]
            store.group()
            store.selection = [id("Footer"), id("© Atlas")]
            store.group()
        }
    }

    static func sticker() -> Node {
        var tag = A.rect(CGRect(x: 700, y: 120, width: 260, height: 120), accent, radius: 60, name: "Tag")
        tag.rotation = 12
        var depth = A.rect(CGRect(x: 120, y: 700, width: 500, height: 320), RGBA(r: 0.2, g: 0.3, b: 0.6), radius: 24, name: "Tilted")
        depth.transform3D = Transform3D(x: 12, y: -18, z: 0)
        var note = A.text("NEW", 40, face: "Bold", at: CGPoint(x: 760, y: 150), color: .white)
        note.rotation = 12
        var line = Node(kind: .line, name: "Slash", frame: CGRect(x: 120, y: 420, width: 400, height: 160))
        line.border.width = 6
        return A.board(CGSize(width: 1080, height: 1350), [
            A.text("Fresh drop", 120, face: "Black", at: CGPoint(x: 120, y: 160), color: ink),
            tag, note, line, depth,
        ])
    }

    static func dividers() -> Node {
        var rule = Node(kind: .line, name: "Rule", frame: CGRect(x: 80, y: 220, width: 1280, height: 0))
        rule.border.width = 2
        var post = Node(kind: .line, name: "Post", frame: CGRect(x: 720, y: 280, width: 0, height: 520))
        post.border.width = 2
        return A.board(CGSize(width: 1440, height: 900), [
            A.text("Two columns", 64, face: "Bold", at: CGPoint(x: 80, y: 100), color: ink),
            rule,
            A.text("Left words that run on for a while, wrapping a few times inside their column.", 24, at: CGPoint(x: 80, y: 280), width: 580, color: ink),
            post,
            A.text("Right words that also run on, so the two sides are balanced across the rule.", 24, at: CGPoint(x: 780, y: 280), width: 580, color: ink),
        ])
    }

    static func rich() -> Node {
        var t = A.text("placeholder", 48, at: CGPoint(x: 100, y: 200), width: 880, color: ink)
        t.setRuns([TextSpan(text: "Bold words, "), TextSpan(text: "then light ones that go on", look: TextLook(face: "Light", size: 36))])
        t.refit()
        var fixed = A.text("A box of fixed size, its words in the middle.", 30, at: CGPoint(x: 100, y: 600), width: 500, color: ink)
        fixed.style?.sizing = .fixed
        fixed.style?.vertical = .middle
        fixed.frame.size.height = 300
        var right = A.text("Right aligned", 30, at: CGPoint(x: 980, y: 1100), align: .right, color: ink)
        right.frame.origin.x = 980 - right.frame.width
        return A.board(CGSize(width: 1080, height: 1350), [t, fixed, right])
    }

    static func pictures() -> Node {
        var fit = A.photo(CGRect(x: 80, y: 80, width: 440, height: 600))
        fit.name = "Fit"
        fit.fill.image?.mode = .fit
        var stretch = A.photo(CGRect(x: 560, y: 80, width: 440, height: 600))
        stretch.name = "Stretch"
        stretch.fill.image?.mode = .stretch
        var zoomed = A.photo(CGRect(x: 80, y: 760, width: 920, height: 500))
        zoomed.name = "Zoomed"
        zoomed.fill.image?.scale = 1.6
        zoomed.fill.image?.offset = CGPoint(x: 0.12, y: -0.08)
        return A.board(CGSize(width: 1080, height: 1350), [fit, stretch, zoomed])
    }

    static func looks() -> Node {
        var card = A.rect(CGRect(x: 140, y: 300, width: 800, height: 500), .white, radius: 32, name: "Card")
        card.corners = [32, 32, 8, 8]
        card.moreFills = [Fill(color: RGBA(r: 1, g: 0.9, b: 0.8, a: 0.4))]
        card.border = Border(on: true, color: ink, width: 4, position: .inside, dash: 12, gap: 6)
        card.moreBorders = [Border(on: true, color: accent, width: 2, position: .outside)]
        card.shadow = Shadow(on: true, x: 0, y: 20, blur: 40)
        card.moreShadows = [Shadow(on: true, color: .shadow, x: 0, y: 2, blur: 4, inset: true)]
        card.blur = Blur(radius: 12, background: true)
        return A.board(CGSize(width: 1080, height: 1080), [card, A.text("On glass", 60, face: "Bold", at: CGPoint(x: 540, y: 500), align: .center, color: ink)], color: RGBA(r: 0.3, g: 0.4, b: 0.7))
    }

    static func states() -> Node {
        var hidden = A.rect(CGRect(x: 100, y: 100, width: 300, height: 300), accent, name: "Hidden")
        hidden.hidden = true
        var locked = A.text("Locked words", 48, at: CGPoint(x: 100, y: 600), color: ink)
        locked.locked = true
        return A.board(CGSize(width: 1080, height: 1080), [hidden, locked, A.rect(CGRect(x: 600, y: 600, width: 300, height: 300), .shape, name: "Shown")])
    }

    static func overflowing() -> Node {
        A.board(CGSize(width: 1080, height: 1080), [
            A.text("WIDER THAN THE PAGE", 260, face: "Black", at: CGPoint(x: -120, y: 380), color: ink),
            A.rect(CGRect(x: 1400, y: 200, width: 300, height: 300), accent, name: "Away"),
            A.text("Small print", 24, at: CGPoint(x: 80, y: 980), color: ink),
        ])
    }

    static func deepGroups() -> Node {
        made(CGSize(width: 800, height: 600), [
            A.rect(CGRect(x: 100, y: 100, width: 200, height: 100), accent, name: "R1"),
            A.text("One", 24, at: CGPoint(x: 120, y: 130), color: .white),
            A.rect(CGRect(x: 100, y: 260, width: 200, height: 100), accent, name: "R2"),
            A.text("Two", 24, at: CGPoint(x: 120, y: 290), color: .white),
            A.rect(CGRect(x: 500, y: 100, width: 200, height: 260), ink, name: "R3"),
        ], name: "Deep") { store, id in
            store.selection = [id("R1"), id("One")]; store.group()
            store.selection = [id("R2"), id("Two")]; store.group()
            let a = store.doc.nodes[0].children.filter(\.isGroup).map(\.id)
            store.selection = a; store.group()
            store.selection = [store.selection[0], id("R3")]; store.group()
        }
    }

    /// Grounds that cannot stretch: a circle and a group covering the page; a word bleeding off one side.
    static func grounds() -> Node {
        var disc = Node(kind: .ellipse, name: "Disc", frame: CGRect(x: -100, y: -100, width: 1280, height: 1280))
        disc.fill.color = RGBA(r: 0.9, g: 0.88, b: 0.84)
        var word = A.text("BIG", 400, face: "Black", at: CGPoint(x: 700, y: 500), color: accent.with(alpha: 0.3))
        word.name = "Bleeding"
        return made(CGSize(width: 1080, height: 1080), [
            disc,
            A.rect(CGRect(x: 0, y: 0, width: 540, height: 1080), RGBA(r: 0.2, g: 0.2, b: 0.25, a: 0.2), name: "Left half"),
            A.rect(CGRect(x: 540, y: 0, width: 540, height: 1080), RGBA(r: 0.25, g: 0.2, b: 0.2, a: 0.2), name: "Right half"),
            word,
            A.text("Over it all", 80, face: "Bold", at: CGPoint(x: 100, y: 200), color: ink),
        ], name: "Grounds") { store, id in
            store.selection = [id("Left half"), id("Right half")]
            store.group()
        }
    }

    /// A group whose layers are turned together.
    static func turnedGroup() -> Node {
        made(CGSize(width: 1080, height: 1080), [
            A.rect(CGRect(x: 600, y: 600, width: 300, height: 200), accent, radius: 20, name: "Back"),
            A.text("Sale", 80, face: "Bold", at: CGPoint(x: 650, y: 640), color: .white),
            A.text("Turned things", 70, face: "Bold", at: CGPoint(x: 100, y: 100), color: ink),
        ], name: "Turned") { store, id in
            store.selection = [id("Back"), id("Sale")]
            store.group()
            store.updateSelection("Rotate") { SelectionInspector.rotate(&$0, to: -14) }
        }
    }

    /// A booklet's page: a chapter's opening with its number in a ring, words in a column, notes
    /// in the margin beside them, the page number at the foot.
    static func bookPage() -> Node {
        var outer = Node(kind: .ellipse, name: "Ring outside", frame: CGRect(x: 70, y: 106, width: 84, height: 84))
        outer.fill.on = false
        outer.border = Border(on: true, color: accent, width: 1, position: .inside)
        var inner = Node(kind: .ellipse, name: "Ring inside", frame: CGRect(x: 73.5, y: 109.5, width: 77, height: 77))
        inner.fill.on = false
        inner.border = Border(on: true, color: accent, width: 0.5, position: .inside)
        var gold = Node(kind: .path, name: "Gold line", frame: CGRect(x: 190, y: 193.5, width: 36, height: 1))
        gold.path = "M 0 0 L 36 0 L 36 1 L 0 1 Z"
        gold.pathBox = CGRect(x: 0, y: 0, width: 36, height: 1)
        gold.fill.color = accent
        return made(CGSize(width: 595, height: 842), [
            outer, inner,
            A.text("I", 28, at: CGPoint(x: 112, y: 129.5), align: .center, color: accent),
            A.text("CHAPTER ONE", 7.5, at: CGPoint(x: 190, y: 118), width: 349, color: accent),
            A.text("Welcome", 36, at: CGPoint(x: 190, y: 136), width: 349, color: ink),
            gold,
            A.text("Dear Janine, dear Erik, dear family and friends, I would like to welcome you all to this special day.", 13, at: CGPoint(x: 190, y: 212), width: 349, color: ink),
            A.text("Looking around this room, I see a very international gathering. Swiss, Liechtensteiners, Germans, half a Viennese, Greeks, Mexicans, Japanese and New Zealanders. And I would especially like to extend a warm welcome to the guests who have travelled the furthest to be here today.",
                   11.5, at: CGPoint(x: 190, y: 308), width: 349, color: ink),
            A.text("Ελλάδα\nAotearoa\nMéxico", 10.5, at: CGPoint(x: 56, y: 416), width: 112, align: .right, color: accent),
            A.text("01", 15, at: CGPoint(x: 56, y: 778), width: 112, align: .right, color: accent),
        ], name: "Page") { store, id in
            store.selection = [id("Ring outside"), id("Ring inside"), id("I")]; store.group()
            let ring = store.selection[0]
            store.selection = [ring, id("CHAPTER ONE"), id("Welcome"), id("Gold line")]; store.group()
            let lead = store.doc.nodes[0].children.first { $0.name.hasPrefix("Dear Janine") }!.id
            let body = store.doc.nodes[0].children.first { $0.name.hasPrefix("Looking around") }!.id
            store.selection = [lead, body]; store.group()
            store.selection = [store.doc.nodes[0].children.first { $0.name.hasPrefix("Ελλάδα") }!.id]; store.group()
            store.selection = [id("01")]; store.group()
        }
    }

    /// A booklet's cover: a night sky, mountains along its foot, the names in a ring over them.
    static func cover() -> Node {
        var night = A.rect(CGRect(x: 0, y: 0, width: 595, height: 842), RGBA(r: 0.06, g: 0.1, b: 0.08), name: "Night")
        night.fill.gradient = Gradient(kind: .radial, stops: [GradientStop(offset: 0, color: RGBA(r: 0.1, g: 0.18, b: 0.14)), GradientStop(offset: 1, color: RGBA(r: 0.04, g: 0.07, b: 0.05))],
                                       start: CGPoint(x: 0.5, y: 0.35), end: CGPoint(x: 1, y: 0.35))
        func ridge(_ name: String, _ y: CGFloat, _ h: CGFloat, _ shade: Double) -> Node {
            var p = Node(kind: .path, name: name, frame: CGRect(x: -4, y: y, width: 600, height: h))
            p.path = "M 0 \(h) L 0 \(h * 0.4) L 80 \(h * 0.1) L 160 \(h * 0.45) L 260 0 L 360 \(h * 0.5) L 460 \(h * 0.15) L 600 \(h * 0.55) L 600 \(h) Z"
            p.pathBox = CGRect(x: 0, y: 0, width: 600, height: h)
            p.fill.color = RGBA(r: 0.12 * shade, g: 0.2 * shade, b: 0.16 * shade)
            return p
        }
        var ring = Node(kind: .ellipse, name: "Ring", frame: CGRect(x: 121.5, y: 196, width: 352, height: 352))
        ring.fill.on = false
        ring.border = Border(on: true, color: RGBA(r: 0.8, g: 0.65, b: 0.35), width: 1, position: .inside)
        return made(CGSize(width: 595, height: 842), [
            night,
            ridge("Far", 540, 302, 1.6), ridge("Middle", 623, 219, 1.2), ridge("Near", 737, 105, 0.8),
            ring,
            A.text("Janine", 64, at: CGPoint(x: 297.5, y: 300), align: .center, color: RGBA(r: 0.95, g: 0.92, b: 0.85)),
            A.text("&", 36, at: CGPoint(x: 297.5, y: 370), align: .center, color: RGBA(r: 0.8, g: 0.65, b: 0.35)),
            A.text("Erik", 64, at: CGPoint(x: 297.5, y: 405), align: .center, color: RGBA(r: 0.95, g: 0.92, b: 0.85)),
            A.text("Being the tale of a dreamer and a globetrotter", 12, at: CGPoint(x: 197, y: 529), width: 200, align: .center, color: RGBA(r: 0.8, g: 0.65, b: 0.35)),
        ], name: "Cover") { store, id in
            store.selection = [id("Far"), id("Middle"), id("Near")]; store.group()
        }
    }

    static func empty() -> Node { var b = A.board(CGSize(width: 800, height: 600), []); b.name = "Empty"; return b }
    static func single() -> Node { A.board(CGSize(width: 800, height: 600), [A.rect(CGRect(x: 300, y: 200, width: 200, height: 200), accent, radius: 20, name: "Alone")]) }
    static func onlyBackdrop() -> Node { A.board(CGSize(width: 800, height: 600), [A.photo(CGRect(x: 0, y: 0, width: 800, height: 600))]) }
    static func onlyDecor() -> Node {
        var c = Node(kind: .ellipse, name: "Blob", frame: CGRect(x: 600, y: -200, width: 400, height: 400))
        c.fill.color = accent
        return A.board(CGSize(width: 800, height: 600), [c])
    }

    /// A screen of many layers, as a real one has.
    static func many() -> Node {
        var kids: [Node] = [A.rect(CGRect(x: 0, y: 0, width: 1440, height: 72), ink, name: "Bar")]
        for row in 0..<12 {
            for col in 0..<6 {
                let x = 40 + CGFloat(col) * 230, y = 100 + CGFloat(row) * 150
                kids.append(A.rect(CGRect(x: x, y: y, width: 210, height: 130), RGBA(r: 0.95, g: 0.95, b: 0.96), radius: 12, name: "Tile"))
                kids.append(A.text("Item \(row * 6 + col)", 16, face: "Semibold", at: CGPoint(x: x + 14, y: y + 14), color: ink))
                kids.append(A.text("Two lines of detail under it", 12, at: CGPoint(x: x + 14, y: y + 44), width: 180, color: ink.with(alpha: 0.6)))
            }
        }
        var b = A.board(CGSize(width: 1440, height: 1960), kids)
        b.name = "Many"
        return b
    }

    static var designs: [(String, Node)] {
        A.designs + [("words", words()), ("grid", cardGrid()), ("profile", profile()), ("nav", navGroups()), ("sticker", sticker()),
                     ("dividers", dividers()), ("rich", rich()), ("pictures", pictures()), ("looks", looks()), ("states", states()),
                     ("overflowing", overflowing()), ("deep", deepGroups()), ("empty", empty()), ("single", single()),
                     ("backdrop", onlyBackdrop()), ("decor", onlyDecor()), ("grounds", grounds()), ("turned", turnedGroup()),
                     ("page", bookPage()), ("cover", cover())]
    }

    /// Every preset's size, and some none has: thin strips, tiny and huge.
    static var everySize: [CGSize] {
        Array(Set(Preset.all.map(\.size)).sorted { ($0.width, $0.height) < ($1.width, $1.height) })
            + [CGSize(width: 5000, height: 5000), CGSize(width: 3000, height: 120), CGSize(width: 120, height: 3000), CGSize(width: 64, height: 64)]
    }

    // MARK: - Every design at every size

    @Test(arguments: 0..<25) func everyDesignAtEverySize(_ i: Int) {
        let (_, design) = Self.designs[i]
        let problems = Self.check(design, at: Self.everySize)
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
    }

    @Test(arguments: 0..<25) func everyDesignComesBackExactly(_ i: Int) {
        var (_, b) = Self.designs[i]
        b.id = UUID()
        let original = b
        var random = Random(seed: UInt64(i + 1))
        for _ in 0..<6 { b = Adapting.resized(b, to: Self.everySize[random.int(Self.everySize.count)]) }
        b = Adapting.resized(b, to: original.frame.size)
        #expect(b == original)
    }

    @Test(arguments: 0..<25) func theSameInputGivesTheSameDesign(_ i: Int) {
        let (_, design) = Self.designs[i]
        for s in [CGSize(width: 1200, height: 627), CGSize(width: 390, height: 844)] {
            let a = Adapt.compose(Adapt.plan(design), to: s).board, b = Adapt.compose(Adapt.plan(design), to: s).board
            #expect(a == b)
        }
    }

    /// Nothing at all, even at sizes no one would choose.
    @Test func noSizeBreaksIt() {
        for (_, design) in Self.designs {
            let plan = Adapt.plan(design)
            for s in [CGSize(width: 1, height: 1), CGSize(width: 2, height: 9000), CGSize(width: 9000, height: 2), CGSize(width: 0.5, height: 0.5),
                      CGSize(width: 100_000, height: 100_000)] {
                let laid = Adapt.compose(plan, to: s).board
                let problems = Self.problems(design, laid, size: CGSize(width: max(s.width, 1), height: max(s.height, 1)), roomy: false)
                #expect(problems.isEmpty, "\(problems.prefix(6).joined(separator: "\n"))")
            }
        }
    }

    // MARK: - Designs made at random

    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> CGFloat { CGFloat(next() % 10_000) / 10_000 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
        mutating func chance(_ p: CGFloat) -> Bool { unit() < p }
    }

    /// A design as people make them: a ground perhaps, rows of blocks down the page with margins
    /// and gaps tight and loose, some blocks holding words, a shape bleeding off a corner.
    static func randomDesign(_ seed: Int) -> Node {
        var r = Random(seed: UInt64(seed))
        let sizes = Preset.all.map(\.size)
        let size = sizes[r.int(sizes.count)]
        let w = size.width, h = size.height
        let unit = min(w, h)
        var kids: [Node] = []
        if r.chance(0.4) {
            var ground = A.rect(CGRect(origin: .zero, size: size), RGBA(r: r.unit(), g: r.unit(), b: r.unit()), name: "Ground")
            if r.chance(0.5) { ground.fill.image = ImageFill(asset: "lake.jpg", mode: .cover, size: WelcomePhoto.size) }
            kids.append(ground)
        }
        let margin = unit * r.range(0.03, 0.12)
        let rows = 1 + r.int(5)
        var y = margin + (r.chance(0.3) ? h * r.range(0, 0.2) : 0)
        let left = margin, right = w - margin
        var n = 0
        for _ in 0..<rows {
            let count = r.chance(0.5) ? 1 : 2 + r.int(3)
            let tall = h * r.range(0.04, 0.6 / CGFloat(rows))
            let gapX = unit * r.range(0.01, 0.06)
            let full = right - left
            let width = (full - gapX * CGFloat(count - 1)) / CGFloat(count) * r.range(0.4, 1)
            let align = r.int(3)
            let rowWidth = width * CGFloat(count) + gapX * CGFloat(count - 1)
            var x = align == 0 ? left : align == 1 ? (w - rowWidth) / 2 : right - rowWidth
            guard y + tall < h - margin else { break }
            for _ in 0..<count {
                n += 1
                let box = CGRect(x: x, y: y, width: width, height: tall)
                switch r.int(5) {
                case 0:
                    var t = A.text("Words number \(n) that run on a little", max(8, tall * r.range(0.15, 0.5)), at: box.origin, width: box.width, color: ink)
                    t.name = "Text \(n)"
                    if t.frame.maxY < h - margin { kids.append(t) }
                case 1:
                    var t = A.text("Label \(n)", max(8, min(tall * 0.6, width / 6)), at: box.origin, color: ink)
                    t.name = "Label \(n)"
                    if t.frame.maxX < w, t.frame.maxY < h { kids.append(t) }
                case 2:
                    var p = A.photo(box, radius: r.chance(0.5) ? unit * 0.02 : 0)
                    p.name = "Photo \(n)"
                    kids.append(p)
                case 3:
                    var card = A.rect(box, RGBA(r: 0.95, g: 0.94, b: 0.92), radius: unit * 0.02, name: "Card \(n)")
                    card.shadow = Shadow(on: r.chance(0.5), x: 0, y: 4, blur: 12)
                    kids.append(card)
                    let pad = min(box.width, box.height) * 0.12
                    var t = A.text("Inside \(n)", max(8, min(box.height * 0.25, box.width / 8)), at: CGPoint(x: box.minX + pad, y: box.minY + pad), color: ink)
                    t.name = "Inside \(n)"
                    if box.insetBy(dx: 1, dy: 1).contains(t.frame) { kids.append(t) }
                default:
                    var e = Node(kind: .ellipse, name: "Dot \(n)", frame: CGRect(x: box.minX, y: box.minY, width: min(box.width, box.height), height: min(box.width, box.height)))
                    e.fill.color = accent
                    kids.append(e)
                }
                x += width + gapX
            }
            y += tall + (r.chance(0.5) ? unit * r.range(0.01, 0.04) : unit * r.range(0.08, 0.25))
        }
        if r.chance(0.35) {
            let d = unit * r.range(0.2, 0.5)
            let corner = r.int(4)
            var blob = Node(kind: .ellipse, name: "Blob", frame: CGRect(x: corner % 2 == 0 ? -d / 2 : w - d / 2, y: corner < 2 ? -d / 2 : h - d / 2, width: d, height: d))
            blob.fill.color = RGBA(r: 1, g: 0.85, b: 0.4)
            kids.insert(blob, at: kids.first?.name == "Ground" ? 1 : 0)
        }
        // Whatever the rules made that overlaps by chance, as people do not, is left out.
        var kept: [Node] = []
        for k in kids {
            let b = Geometry.bounds(of: k)
            let page = CGRect(origin: .zero, size: size)
            let clash = flows(k, on: page) && kept.contains { o in
                flows(o, on: page) && Geometry.bounds(of: o).insetBy(dx: -1, dy: -1).intersects(b) && !(o.name.hasPrefix("Card") && k.name.hasPrefix("Inside"))
            }
            if !clash { kept.append(k) }
        }
        var board = A.board(size, kept)
        board.name = "Random \(seed)"
        return board
    }

    @Test(arguments: 0..<12) func designsMadeAtRandom(_ batch: Int) {
        let sizes = [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 1200, height: 627), CGSize(width: 1500, height: 500),
                     CGSize(width: 402, height: 874), CGSize(width: 1920, height: 1080), CGSize(width: 768, height: 1024), CGSize(width: 595, height: 842)]
        var all: [String] = []
        for seed in (batch * 25)..<(batch * 25 + 25) {
            let design = Self.randomDesign(seed)
            all += Self.check(design, at: sizes)
            // And back exactly.
            var b = design
            b.id = UUID()
            let original = b
            for s in sizes.prefix(3) { b = Adapting.resized(b, to: s) }
            if Adapting.resized(b, to: original.frame.size) != original { all.append("\(design.name) did not come back") }
        }
        #expect(all.isEmpty, "\(all.count) problems:\n\(all.prefix(15).joined(separator: "\n"))")
    }

    // MARK: - Dragging back and forth

    /// The steps a drag takes along one side: layers move with it, nearly as far as the edge does
    /// at most, except when the design is arranged another way.
    @Test(arguments: 0..<25) func aDragNeverJumps(_ i: Int) throws {
        let (_, design) = Self.designs[i]
        guard !design.children.isEmpty else { return }
        let plan = Adapt.plan(design)
        var current = Adapt.Arrangement.original
        var last = design
        var jumps: [String] = []
        let w0: CGFloat = design.frame.width
        let by: CGFloat = max(2, w0 / 300)
        let narrower: [CGFloat] = Array(stride(from: w0, through: w0 * 0.45, by: -by))
        let wider: [CGFloat] = Array(stride(from: w0 * 0.45, through: w0 * 1.8, by: by))
        for step in narrower + wider {
            let size = CGSize(width: step.rounded(), height: design.frame.height)
            let r = Adapt.compose(plan, to: size, keeping: current)
            defer { current = r.arrangement; last = r.board }
            guard r.arrangement == current else { continue }
            let moved: CGFloat = abs(size.width - last.frame.width)
            // Words wrapping onto one more line, or one fewer, move what lies under them by a line.
            let biggest: CGFloat = r.board.children.compactMap { $0.style?.size }.max() ?? 0
            for (x, y) in zip(last.children, r.board.children) where !y.hidden {
                let dx = max(abs(x.frame.minX - y.frame.minX), abs(x.frame.maxX - y.frame.maxX))
                let dy = max(abs(x.frame.minY - y.frame.minY), abs(x.frame.maxY - y.frame.maxY))
                let d: CGFloat = max(dx, dy)
                let line: CGFloat = biggest * 1.6
                if d > moved * 3 + 4 + line { jumps.append("\(design.name) at \(Int(size.width)): \(y.name) jumped \(Int(d)) for \(Int(moved))") }
            }
        }
        #expect(jumps.isEmpty, "\(jumps.prefix(8).joined(separator: "\n"))")
    }

    /// A pointer wavering about where the design turns does not flick it back and forth.
    @Test(arguments: 0..<25) func aWaveringDragDoesNotFlicker(_ i: Int) {
        let (_, design) = Self.designs[i]
        let plan = Adapt.plan(design)
        var current = Adapt.Arrangement.original, last: CGFloat?
        // Where it first turns as the artboard gets shorter.
        let h0 = design.frame.height
        for h in stride(from: h0, through: h0 * 0.3, by: -4) {
            let r = Adapt.compose(plan, to: CGSize(width: design.frame.width, height: h), keeping: current)
            if r.arrangement != current { last = h; current = r.arrangement; break }
        }
        guard let edge = last else { return }
        var changes = 0
        for k in 0..<40 {
            let h = edge + (k % 2 == 0 ? 3 : -3)
            let r = Adapt.compose(plan, to: CGSize(width: design.frame.width, height: h), keeping: current)
            if r.arrangement != current { changes += 1; current = r.arrangement }
        }
        #expect(changes <= 1, "\(design.name) changed \(changes) times")
    }

    // MARK: - Kinds of artboard

    @Test func aCarouselIsNeverLaidOutAgain() {
        var c = A.photoPost()
        c.slideSize = CGSize(width: 1080, height: 1350)
        #expect(!Adapting.adapts(c))
        #expect(Adapting.resized(c, to: CGSize(width: 2160, height: 1350)).children == c.children)
        #expect(Adapting.Session(c, assets: nil) == nil)
    }

    @Test func aPinnedArtboardKeepsItsLayers() {
        var p = A.webHero()
        p.pinsLayers = true
        #expect(Adapting.resized(p, to: CGSize(width: 400, height: 900)).children == p.children)
        #expect(Adapting.Session(p, assets: nil) == nil)
    }

    @Test func anEmptyArtboardJustTakesItsSize() {
        let e = Self.empty()
        let r = Adapting.resized(e, to: CGSize(width: 100, height: 50))
        #expect(r.frame.size == CGSize(width: 100, height: 50))
        #expect(r.children.isEmpty)
    }

    @Test func aRepeatGridStaysWhole() throws {
        let design = Self.cardGrid()
        for s in [CGSize(width: 768, height: 1024), CGSize(width: 1920, height: 1080), CGSize(width: 402, height: 874)] {
            let laid = Adapting.resized(design, to: s, remembering: false)
            let grid = try #require(laid.children.first { $0.isRepeatGrid })
            var healed = grid
            RepeatGrid.heal(&healed)
            for (h, g) in zip(healed.children, grid.children) {
                #expect(abs(h.frame.minX - g.frame.minX) < 0.001 && abs(h.frame.minY - g.frame.minY) < 0.001
                        && abs(h.frame.width - g.frame.width) < 0.001 && abs(h.frame.height - g.frame.height) < 0.001, "at \(s)")
            }
            #expect(grid.children.count == 6)
        }
    }

    @Test func aMaskStaysAMask() throws {
        let design = Self.profile()
        let laid = Adapting.resized(design, to: CGSize(width: 1600, height: 900), remembering: false)
        let mask = try #require(laid.children.first { $0.clipsToFirst == true })
        let held = try #require(mask.children.last)
        // The picture still fills the circle that holds it.
        let circle = mask.children[0].frame
        #expect(held.frame.insetBy(dx: -1, dy: -1).contains(circle) || circle.insetBy(dx: -1, dy: -1).contains(held.frame))
        #expect(abs(circle.width - circle.height) < 1)
    }

    @Test func aDeckPostWithAPlaceOfItsOwnStillFollows() throws {
        var deck = A.photoPost()
        deck.frame.origin = CGPoint(x: 100, y: 100)
        let bench = Bench()
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [deck] } }
        bench.step { bench.store.addPost(to: deck.id) }
        bench.step { bench.store.addPost(to: deck.id) }
        let board = try #require(bench.store.doc.node(deck.id))
        let post = try #require(board.posts.last)
        // In one post the heading says more, and the button keeps a place of its own.
        let heading = try #require(board.layers(of: post).first { $0.name == "Lakeside weekends" })
        bench.step { bench.store.update([heading.id], "Type") { $0.text = "Lakeside weekends, long and slow, all summer" } }
        let button = try #require(board.layers(of: post).first { $0.name == "Button" })
        bench.step { bench.store.update([button.id], "Just Here") { $0.own = ["frame"]; $0.frame.origin.x += 40 } }
        bench.step { bench.store.resizeArtboards([deck.id]) { _ in CGSize(width: 1200, height: 627) } }
        let after = try #require(bench.store.doc.node(deck.id))
        #expect(after.frame.size == CGSize(width: 1200, height: 627))
        for p in after.posts {
            let layers = after.layers(of: p)
            #expect(layers.count == after.layers(of: nil).count)
            for l in layers {
                #expect(CGRect(origin: .zero, size: after.frame.size).insetBy(dx: -2, dy: -2).intersects(l.frame), "\(l.name) in post \(p) is off the artboard")
            }
        }
        // The post's own words, as they were.
        #expect(after.layers(of: post).contains { $0.text == "Lakeside weekends, long and slow, all summer" })
        bench.undo.undo()
        #expect(bench.store.doc.node(deck.id)?.frame.size == CGSize(width: 1080, height: 1350))
    }

    // MARK: - Every way to change an artboard's size

    private func photoBench() -> (Bench, Node) {
        let bench = Bench()
        var post = A.photoPost()
        post.frame.origin = CGPoint(x: 100, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [post, bench.b] } }
        bench.store.selection = [post.id]
        return (bench, post)
    }

    /// Each of the artboard's eight handles, pulled outward, and every layer kept sound.
    @Test(arguments: 0..<8) func everyHandleLaysTheDesignOut(_ h: Int) throws {
        let (bench, post) = photoBench()
        let f = post.frame
        let points = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.midY),
                      CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.minX, y: f.midY)]
        let pulls = [CGPoint(x: -200, y: -100), CGPoint(x: 0, y: -300), CGPoint(x: 300, y: -100), CGPoint(x: 400, y: 0),
                     CGPoint(x: 300, y: -500), CGPoint(x: 0, y: -600), CGPoint(x: -200, y: -500), CGPoint(x: -500, y: 0)]
        let from = points[h], to = from + pulls[h]
        bench.drag(from, to)
        let laid = try #require(bench.store.doc.node(post.id))
        #expect(laid.frame != f)
        var expected = post
        expected.frame.origin = laid.frame.origin
        let problems = Self.problems(expected, laid, size: laid.frame.size)
        #expect(problems.isEmpty, "\(problems.prefix(6).joined(separator: "\n"))")
        bench.undo.undo()
        #expect(bench.store.doc.node(post.id) == post)
    }

    @Test func dragsFromTheMiddleAndKeepingProportionsLayItOutToo() throws {
        let (bench, post) = photoBench()
        bench.drag(CGPoint(x: post.frame.maxX, y: post.frame.midY), CGPoint(x: post.frame.maxX + 300, y: post.frame.midY), flags: [.option])
        let wide = try #require(bench.store.doc.node(post.id))
        #expect(abs(wide.frame.midX - post.frame.midX) <= 1)
        #expect(wide.frame.width == 1680)
        #expect(Self.problems({ var e = post; e.frame.origin = wide.frame.origin; return e }(), wide, size: wide.frame.size).isEmpty)
        bench.drag(CGPoint(x: wide.frame.maxX, y: wide.frame.maxY), CGPoint(x: wide.frame.maxX - 400, y: wide.frame.maxY), flags: [.shift])
        let kept = try #require(bench.store.doc.node(post.id))
        #expect(abs(kept.frame.width / kept.frame.height - wide.frame.width / wide.frame.height) < 0.01)
    }

    @Test func escapePutsEverythingBack() throws {
        let (bench, post) = photoBench()
        bench.drag(CGPoint(x: post.frame.midX, y: post.frame.maxY), CGPoint(x: post.frame.midX, y: post.frame.maxY - 700), release: false)
        #expect(bench.store.doc.node(post.id)?.frame.height == 650)
        bench.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        #expect(bench.store.doc.node(post.id) == post)
        bench.release(CGPoint(x: post.frame.midX, y: post.frame.maxY - 700))
        #expect(bench.store.doc.node(post.id) == post)
        // And the next drag starts from the design as it is.
        bench.drag(CGPoint(x: post.frame.maxX, y: post.frame.midY), CGPoint(x: post.frame.maxX + 120, y: post.frame.midY))
        #expect(bench.store.doc.node(post.id)?.frame.width == 1200)
    }

    @Test func undoAndRedoGoBackAndForthExactly() throws {
        let (bench, post) = photoBench()
        bench.drag(CGPoint(x: post.frame.midX, y: post.frame.maxY), CGPoint(x: post.frame.midX, y: post.frame.maxY - 700))
        let short = try #require(bench.store.doc.node(post.id))
        bench.drag(CGPoint(x: short.frame.maxX, y: short.frame.midY), CGPoint(x: short.frame.maxX + 500, y: short.frame.midY))
        let wide = try #require(bench.store.doc.node(post.id))
        bench.undo.undo()
        #expect(bench.store.doc.node(post.id) == short)
        bench.undo.undo()
        #expect(bench.store.doc.node(post.id) == post)
        bench.undo.redo()
        #expect(bench.store.doc.node(post.id) == short)
        bench.undo.redo()
        #expect(bench.store.doc.node(post.id) == wide)
        // Resized back to where it began, after all that, it is the design as made.
        bench.step { bench.store.resizeArtboards([post.id]) { _ in post.frame.size } }
        #expect(bench.store.doc.node(post.id)?.children == post.children)
    }

    @Test func severalArtboardsDraggedTogetherEachLayOut() throws {
        let bench = Bench()
        var one = A.photoPost(), two = A.centredPost()
        one.frame.origin = CGPoint(x: 100, y: 100)
        two.frame.origin = CGPoint(x: 1300, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [one, two] } }
        bench.store.selection = [one.id, two.id]
        // The box round both, pulled down by its bottom edge.
        let bottom = CGPoint(x: (100 + 2380) / 2, y: 1450)
        bench.drag(bottom, bottom + CGPoint(x: 0, y: 400))
        for (design, id) in [(one, one.id), (two, two.id)] {
            let laid = try #require(bench.store.doc.node(id))
            #expect(laid.frame.height > design.frame.height)
            var e = design
            e.frame.origin = laid.frame.origin
            let problems = Self.problems(e, laid, size: laid.frame.size)
            #expect(problems.isEmpty, "\(problems.prefix(4).joined(separator: "\n"))")
            // Laid out, not left where it was.
            #expect(laid.children != design.children)
        }
    }

    @Test func thePresetsAndTheFieldsLayItOut() throws {
        let (bench, post) = photoBench()
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1080, height: 1920) } }
        let story = try #require(bench.store.doc.node(post.id))
        #expect(Self.problems({ var e = post; e.frame.origin = story.frame.origin; return e }(), story, size: story.frame.size).isEmpty)
        // A width typed in, as the Frame card's field does.
        bench.step { bench.store.update([post.id], "Resize") { SelectionInspector.resize(&$0, to: CGSize(width: 1200, height: 1920), byHeight: false) } }
        let typed = try #require(bench.store.doc.node(post.id))
        #expect(typed.frame.size == CGSize(width: 1200, height: 1920))
        #expect(typed.children != story.children)
        // Several artboards given one box, as the fields do with more than one selected.
        var other = A.centredPost()
        other.frame.origin = CGPoint(x: 2600, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes.append(other) } }
        var both = bench.store.doc
        SelectionInspector.place(&both, [post.id, other.id], from: CGRect(x: 100, y: 100, width: 3580, height: 1920), to: CGRect(x: 100, y: 100, width: 1790, height: 960))
        for id in [post.id, other.id] {
            let n = try #require(both.node(id))
            let was = try #require(bench.store.doc.node(id))
            #expect(n.frame.width < was.frame.width)
            #expect(n.children != was.children)
        }
    }

    @Test func pointingAtPresetsChangesNothing() throws {
        let (bench, post) = photoBench()
        let before = bench.store.doc
        for p in Preset.all.prefix(20) {
            if let change = bench.store.adaptedPreview(of: post.id, to: p.size) {
                bench.store.showPreview("artboard-size", reshaping: change)
                #expect(bench.store.shownDoc.node(post.id)?.frame.size == p.size)
            }
        }
        bench.store.showPreview("artboard-size", reshaping: nil)
        #expect(bench.store.doc == before)
        #expect(bench.store.shownDoc == before)
        // Remembering was left alone: going there and back still gives the design back exactly.
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1500, height: 500) } }
        bench.step { bench.store.resizeArtboards([post.id]) { _ in post.frame.size } }
        #expect(bench.store.doc.node(post.id)?.children == post.children)
        // A pinned artboard's preview only takes the size.
        bench.step { bench.store.update([post.id], "Keep") { $0.pinsLayers = true } }
        let change = try #require(bench.store.adaptedPreview(of: post.id, to: CGSize(width: 500, height: 500)))
        bench.store.showPreview("artboard-size", reshaping: change)
        #expect(bench.store.shownDoc.node(post.id)?.children == bench.store.doc.node(post.id)?.children)
    }

    @Test func aChangeMadeAfterwardsIsKept() throws {
        let (bench, post) = photoBench()
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1200, height: 627) } }
        let heading = try #require(bench.node("Lakeside weekends"))
        bench.step { bench.store.update([heading.id], "Type") { $0.text = "Lakeside" } }
        bench.step { bench.store.resizeArtboards([post.id]) { _ in post.frame.size } }
        // Back at its size, it is laid out from the design as it now is, the new words in it.
        #expect(bench.node("Lakeside weekends")?.text == "Lakeside")
    }

    @Test func theSwitchIsOneStepThatUndoes() {
        let (bench, post) = photoBench()
        bench.step { bench.store.update([post.id], "Keep Layers in Place") { $0.pinsLayers = true } }
        #expect(bench.store.doc.node(post.id)?.pinsLayers == true)
        bench.undo.undo()
        #expect(bench.store.doc.node(post.id)?.pinsLayers == nil)
    }

    /// Cards across a page widen with it; a button beside words keeps its size.
    @Test func cardsTakeTheRoomAndButtonsKeepTheirSize() throws {
        let wide = Adapt.compose(Adapt.plan(A.webHero()), to: CGSize(width: 1920, height: 1080)).board
        let features = wide.children.filter { $0.name == "Feature" }
        #expect(features.count == 3)
        #expect((features.map(\.frame.maxX).max() ?? 0) > 1920 - 160)
        #expect(features.allSatisfy { $0.frame.width > 450 })
        let banner = Adapt.compose(Adapt.plan(A.centredPost()), to: CGSize(width: 1600, height: 900)).board
        let button = try #require(banner.children.first { $0.name == "Button" })
        #expect(button.frame.width / button.frame.height < 300.0 / 90 * 1.05)
    }

    @Test func aSlashKeepsItsSlantAndARuleRunsAlong() throws {
        for s in [CGSize(width: 1500, height: 500), CGSize(width: 402, height: 874)] {
            let laid = Adapt.compose(Adapt.plan(Self.sticker()), to: s).board
            let slash = try #require(laid.children.first { $0.name == "Slash" })
            #expect(abs(slash.frame.width / slash.frame.height - 400.0 / 160) < 0.05, "at \(s): \(slash.frame)")
            let rules = Adapt.compose(Adapt.plan(Self.dividers()), to: s).board
            let rule = try #require(rules.children.first { $0.name == "Rule" })
            #expect(rule.frame.height == 0 && rule.frame.width > 0)
        }
    }

    @Test func aDeckDraggedByItsEdgeKeepsItsPostsWithItsDesign() throws {
        var deck = A.photoPost()
        deck.frame.origin = CGPoint(x: 100, y: 100)
        let bench = Bench()
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [deck] } }
        bench.step { bench.store.addPost(to: deck.id) }
        bench.step { bench.store.addPost(to: deck.id) }
        bench.store.selection = [deck.id]
        // By its side: under its foot lie the posts behind it.
        bench.drag(CGPoint(x: deck.frame.maxX, y: deck.frame.midY), CGPoint(x: deck.frame.maxX + 920, y: deck.frame.midY))
        let board = try #require(bench.store.doc.node(deck.id))
        #expect(board.frame.width == 2000)
        let design = board.layers(of: nil)
        #expect(design != deck.children)
        for post in board.posts {
            for layer in board.layers(of: post) {
                let twin = try #require(design.first { $0.id.mixed(Deck.key(post)) == layer.id })
                #expect(layer.frame == twin.frame, "\(layer.name) in post \(post)")
            }
        }
        bench.undo.undo()
        #expect(bench.store.doc.node(deck.id)?.frame.width == 1080)
    }

    /// What iCloud keeps of each layer gives the design back as it was laid out, groups, grids,
    /// masks and decks and all.
    @Test func whatIsSharedGivesTheLaidOutDesignBack() throws {
        for design in [Self.cardGrid(), Self.profile(), Self.navGroups(), Self.deepGroups(), Self.grounds(), Self.turnedGroup()] {
            let bench = Bench()
            var d = design
            d.frame.origin = CGPoint(x: 100, y: 100)
            bench.step { bench.store.edit("Add") { doc in doc.nodes = [d] } }
            bench.step { bench.store.resizeArtboards([d.id]) { _ in CGSize(width: 820, height: 1180) } }
            let doc = bench.store.doc
            let back = FlatDesign(doc).document()
            #expect(back.nodes.map(\.id) == doc.nodes.map(\.id))
            let a = try #require(back.node(d.id)), b = try #require(doc.node(d.id))
            #expect(a.children.count == b.children.count)
            for (x, y) in zip(a.children, b.children) {
                #expect(abs(x.frame.minX - y.frame.minX) < 0.01 && abs(x.frame.minY - y.frame.minY) < 0.01
                        && abs(x.frame.width - y.frame.width) < 0.01 && abs(x.frame.height - y.frame.height) < 0.01, "\(design.name): \(x.name)")
            }
        }
    }

    @Test func onlySoManyArtboardsAreRemembered() {
        for _ in 0..<(Adapting.kept + 30) {
            var b = A.photoPost()
            b.id = UUID()
            _ = Adapting.resized(b, to: CGSize(width: 1200, height: 627))
        }
        #expect(Adapting.remembered <= Adapting.kept)
    }

    /// A booklet's page as a deck of languages, one post's words and type and place of its own:
    /// a drag reaches the same design, step by step, as choosing its last size at once does.
    static func bookDeck(_ bench: Bench) throws -> UUID {
        var page = bookPage()
        page.frame.origin = CGPoint(x: 100, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [page] } }
        bench.step { bench.store.addPost(to: page.id) }
        bench.step { bench.store.addPost(to: page.id) }
        let board = try #require(bench.store.doc.node(page.id))
        let post = try #require(board.posts.last)
        // In the last post, the lead has its own type, and the margin notes their own place.
        let words = try #require(board.layers(of: post).first { $0.isGroup && $0.children.contains { ($0.text ?? "").hasPrefix("Dear Janine") } })
        let lead = try #require(words.children.first { ($0.text ?? "").hasPrefix("Dear Janine") })
        bench.step { bench.store.update([lead.id], "Type") { $0.text = "Liebe Janine, lieber Erik, liebe Familie und Freunde, ich heisse euch willkommen."; $0.style?.size = 14; $0.own = ["style"] } }
        let notes = try #require(board.layers(of: post).first { $0.isGroup && $0.children.contains { ($0.text ?? "").hasPrefix("Ελλάδα") } })
        bench.step { bench.store.update([notes.id], "Move") { $0.frame.origin.y += 30; $0.own = ["frame"] } }
        return page.id
    }

    @Test(arguments: [CGSize(width: 842, height: 595), CGSize(width: 420, height: 595), CGSize(width: 595, height: 1000), CGSize(width: 400, height: 842)])
    func aDraggedDeckEndsWhereChoosingTheSizeDoes(_ size: CGSize) throws {
        let dragged = Bench(), chosen = Bench()
        let id = try Self.bookDeck(dragged)
        _ = try Self.bookDeck(chosen)
        let start = try #require(dragged.store.doc.node(id))
        // Its id differs on the second bench; the same design, all the same.
        let other = chosen.store.doc.nodes[0].id
        chosen.step { chosen.store.resizeArtboards([other]) { _ in size } }
        dragged.store.selection = [id]
        // By the bottom right corner, in many steps, past the size and back.
        let corner = CGPoint(x: start.frame.maxX, y: start.frame.maxY)
        let end = CGPoint(x: start.frame.minX + size.width, y: start.frame.minY + size.height)
        dragged.step {
            dragged.canvas.mouseDown(with: Self.event(.leftMouseDown, corner, dragged))
            for i in 1...24 {
                let t = CGFloat(i) / 20
                let p = CGPoint(x: corner.x + (end.x - corner.x) * t, y: corner.y + (end.y - corner.y) * t)
                dragged.canvas.mouseDragged(with: Self.event(.leftMouseDragged, p, dragged))
            }
            dragged.canvas.mouseDragged(with: Self.event(.leftMouseDragged, end, dragged))
            dragged.canvas.mouseUp(with: Self.event(.leftMouseUp, end, dragged))
        }
        let a = try #require(dragged.store.doc.node(id)), b = try #require(chosen.store.doc.node(other))
        #expect(a.frame.size == size)
        #expect(a.children.map(\.frame) == b.children.map(\.frame))
        #expect(a.children.map { $0.style?.size } == b.children.map { $0.style?.size })
        func all(_ n: Node) -> [Node] { [n] + n.children.flatMap(all) }
        #expect(a.children.flatMap(all).map(\.frame) == b.children.flatMap(all).map(\.frame))
        // Every post holds its design's layers, where the design put them, and keeps on the page.
        for post in a.posts {
            var shown = a.showing(post)
            shown.frame.origin = .zero
            var was = start.showing(post)
            was.frame.origin = .zero
            let problems = Self.problems(was, shown, size: size)
            #expect(problems.isEmpty, "post \(post): \(problems.prefix(5).joined(separator: "\n"))")
        }
        // And back to where it began, exactly.
        dragged.step { dragged.store.resizeArtboards([id]) { _ in start.frame.size } }
        #expect(dragged.store.doc.node(id)?.children == start.children)
    }

    static func event(_ type: NSEvent.EventType, _ p: CGPoint, _ bench: Bench) -> NSEvent {
        let view = bench.store.viewport.toView(p)
        return NSEvent.mouseEvent(with: type, location: bench.canvas.convert(view, to: nil), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aRingOfCirclesStaysRoundAndMountainsRunAcross() throws {
        for s in [CGSize(width: 842, height: 595), CGSize(width: 1080, height: 1920), CGSize(width: 420, height: 595)] {
            let page = Adapt.compose(Adapt.plan(Self.bookPage()), to: s).board
            func circles(_ n: Node) -> [Node] { (n.kind == .ellipse ? [n] : []) + n.children.flatMap(circles) }
            for c in page.children.flatMap(circles) { #expect(abs(c.frame.width - c.frame.height) < 0.5, "\(c.name) at \(s): \(c.frame)") }
            let cover = Adapt.compose(Adapt.plan(Self.cover()), to: s).board
            let hills = try #require(cover.children.first { $0.isGroup })
            #expect(hills.frame.minX <= 0 && hills.frame.maxX >= s.width, "at \(s): \(hills.frame)")
            #expect(abs(hills.frame.maxY - s.height) <= 1, "at \(s): \(hills.frame)")
            // The names stay over the hills, in the ring.
            let ring = try #require(cover.children.first { $0.name == "Ring" })
            #expect(abs(ring.frame.width - ring.frame.height) < 0.5)
            for name in ["Janine", "Erik"] {
                let t = try #require(cover.children.first { $0.name == name })
                #expect(ring.frame.insetBy(dx: -1, dy: -1).contains(t.frame), "\(name) at \(s)")
            }
        }
    }

    /// A real design, BEZZLE_ADAPT_DOC, each artboard dragged by its corner as a person would.
    @Test func aRealDesignDragged() throws {
        guard let path = ProcessInfo.processInfo.environment["BEZZLE_ADAPT_DOC"] else { return }
        let doc = try DesignFile.read(URL(fileURLWithPath: path))
        var problems: [String] = []
        for board in doc.nodes.prefix(8) where board.isArtboard {
            for size in [CGSize(width: 842, height: 595), CGSize(width: 420, height: 595), CGSize(width: 595, height: 1000)] {
                let bench = Bench()
                var d = doc
                d.viewport = Viewport(origin: CGPoint(x: board.frame.minX - 100, y: board.frame.minY - 100), zoom: 0.5)
                bench.step { bench.store.edit("Open") { $0 = d } }
                bench.store.viewport = d.viewport!
                bench.store.selection = [board.id]
                let corner = CGPoint(x: board.frame.maxX, y: board.frame.maxY), end = CGPoint(x: board.frame.minX + size.width, y: board.frame.minY + size.height)
                bench.step {
                    bench.canvas.mouseDown(with: Self.event(.leftMouseDown, corner, bench))
                    for i in 1...20 {
                        let t = CGFloat(i) / 20
                        bench.canvas.mouseDragged(with: Self.event(.leftMouseDragged, CGPoint(x: corner.x + (end.x - corner.x) * t, y: corner.y + (end.y - corner.y) * t), bench))
                    }
                    bench.canvas.mouseUp(with: Self.event(.leftMouseUp, end, bench))
                }
                guard let laid = bench.store.doc.node(board.id) else { continue }
                if laid.frame.size != size { problems.append("\(board.name): dragged to \(laid.frame.size), not \(size)") ; continue }
                for post in laid.isDeck ? laid.posts : [0] {
                    var shown = laid.isDeck ? laid.showing(post) : laid
                    var was = board.isDeck ? board.showing(post) : board
                    shown.frame.origin = .zero; was.frame.origin = .zero
                    problems += Self.problems(was, shown, size: size).map { "post \(post): " + $0 }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count):\n\(problems.prefix(30).joined(separator: "\n"))")
    }

    /// A real design's artboards, each swept narrower and wider, shorter and taller, a few points a
    /// step as a drag goes: nothing leaps but when the design is arranged anew or words rewrap.
    @Test func aRealDesignNeverJumps() throws {
        guard let path = ProcessInfo.processInfo.environment["BEZZLE_ADAPT_DOC"] else { return }
        let doc = try DesignFile.read(URL(fileURLWithPath: path))
        var jumps: [String] = []
        for board in doc.nodes.prefix(10) where board.isArtboard && Adapting.adapts(board) {
            let plan = Adapt.plan(board)
            for vertical in [false, true] {
                var current = Adapt.Arrangement.original, last = plan.board
                let l0 = vertical ? board.frame.height : board.frame.width
                let steps = Array(stride(from: l0, through: l0 * 0.5, by: -3)) + Array(stride(from: l0 * 0.5, through: l0 * 1.6, by: 3))
                for l in steps {
                    let size = vertical ? CGSize(width: board.frame.width, height: l.rounded()) : CGSize(width: l.rounded(), height: board.frame.height)
                    let r = Adapt.compose(plan, to: size, keeping: current)
                    defer { current = r.arrangement; last = r.board }
                    guard r.arrangement == current else { continue }
                    let biggest: CGFloat = r.board.children.flatMap { n -> [CGFloat] in
                        func sizes(_ n: Node) -> [CGFloat] { (n.style.map { [$0.size] } ?? []) + n.children.flatMap(sizes) }
                        return sizes(n)
                    }.max() ?? 0
                    for (x, y) in zip(last.layers(of: nil), r.board.layers(of: nil)) where !y.hidden {
                        let d = max(abs(x.frame.minX - y.frame.minX), abs(x.frame.minY - y.frame.minY), abs(x.frame.maxX - y.frame.maxX), abs(x.frame.maxY - y.frame.maxY))
                        if d > 3 * 3 + 4 + biggest * 1.6 { jumps.append("\(board.name) at \(Int(size.width))×\(Int(size.height)): \(y.name) jumped \(Int(d))") }
                    }
                }
            }
        }
        #expect(jumps.isEmpty, "\(jumps.count):\n\(jumps.prefix(20).joined(separator: "\n"))")
    }

    /// Real designs from other apps, BEZZLE_ADAPT_FILES (paths, colon apart), each artboard laid
    /// out at sizes it might be given: what is wrong, by kind and in full, and how long it took,
    /// into BEZZLE_ADAPT_SHEETS/files.txt; a sheet of a few artboards of each file to look at.
    @Test func realFilesFromOtherApps() throws {
        guard let list = ProcessInfo.processInfo.environment["BEZZLE_ADAPT_FILES"], let out = AdaptTests.sheets else { return }
        var lines: [String] = [], kinds: [String: Int] = [:]
        var boards = 0, laid = 0, troubled = 0, slowest: (Double, String) = (0, "")
        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let started = CACurrentMediaTime()
            // Brought in as the app does, pictures and all, once.
            let imports = out.appendingPathComponent("imports", isDirectory: true)
            try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
            let made = imports.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".bezzle")
            if !FileManager.default.fileExists(atPath: made.path) {
                guard let (at, _) = try? Importer.importFile(url, into: imports) else { lines.append("\(url.lastPathComponent): could not be read"); continue }
                if at != made { try? FileManager.default.moveItem(at: at, to: made) }
            }
            guard let document = try? DesignFile.read(made) else { lines.append("\(url.lastPathComponent): could not be read"); continue }
            let assets = Assets(design: made)
            let all = document.nodes.filter { $0.isArtboard && !$0.isCarousel && !$0.children.isEmpty }
            // An even spread of its artboards, as many as are worth looking at.
            let step = max(1, all.count / 40)
            let picked = stride(from: 0, to: all.count, by: step).map { all[$0] }
            lines.append("\(url.lastPathComponent): \(all.count) artboards, \(picked.count) tried, read in \(Int(CACurrentMediaTime() - started)) s")
            var sheet: [Node] = []
            for (n, board) in picked.enumerated() {
                boards += 1
                let w = board.frame.width, h = board.frame.height
                let sizes = [CGSize(width: (w * 0.6).rounded(), height: h), CGSize(width: (w * 1.5).rounded(), height: h),
                             CGSize(width: w, height: (h * 0.7).rounded()), CGSize(width: w, height: (h * 1.4).rounded()),
                             CGSize(width: h, height: w), CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1920),
                             CGSize(width: 1920, height: 1080), CGSize(width: 402, height: 874)]
                var origin = board
                origin.frame.origin = .zero
                let t0 = CACurrentMediaTime()
                let shapes = Adapting.shapes(of: origin, assets: assets), cores = Adapting.cores(of: origin, assets: assets)
                let plan = Adapt.plan(origin, focus: Adapting.focus(of: origin, assets: assets, now: true), shapes: shapes, cores: cores)
                var problems: [String] = []
                for size in sizes {
                    let r = Adapt.compose(plan, to: size)
                    laid += 1
                    problems += Self.problems(origin, r.board, size: size, roomy: Self.roomyEnough(origin, size), shapes: shapes, cores: cores)
                    if n < 4, size == sizes[4] || size == sizes[1] { sheet.append(r.board) }
                }
                if n < 4 { sheet.insert(origin, at: max(0, sheet.count - 2)) }
                let each = (CACurrentMediaTime() - t0) / Double(sizes.count)
                if each > slowest.0 { slowest = (each, "\(board.name) (\(BezzleDocument.layerCount(board.children)) layers)") }
                if !problems.isEmpty { troubled += 1 }
                for p in problems {
                    let kind = p.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                        .replacingOccurrences(of: "[0-9.-]+", with: "#", options: .regularExpression)
                    let short = kind.contains("lies over") ? "lies over" : kind.contains("left the artboard") ? "left the artboard"
                        : kind.contains("type grew") ? "type grew unevenly" : kind.contains("stretched") ? "stretched" : kind.contains("collapsed") ? "collapsed"
                        : kind.contains("came out of") ? "came out of its holder" : kind.contains("no longer covers") ? "picture no longer covers" : kind
                    kinds[short, default: 0] += 1
                }
                lines += problems.prefix(6).map { "  \(url.lastPathComponent) · " + $0 }
            }
            if !sheet.isEmpty {
                try AdaptTests.sheet(Array(sheet.prefix(12)), assets: assets, to: out.appendingPathComponent("file-\(url.deletingPathExtension().lastPathComponent).png"))
            }
        }
        lines.insert("\(boards) artboards at \(laid) sizes; \(troubled) with any problem. Slowest: \(Int(slowest.0 * 1000)) ms, \(slowest.1)", at: 0)
        lines.insert("By kind: " + kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "), at: 1)
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("files.txt"), atomically: true, encoding: .utf8)
    }

    /// What was understood of the artboards of BEZZLE_ADAPT_LOOK (a .bezzle) whose names hold any
    /// of BEZZLE_ADAPT_NAMES (comma apart), into BEZZLE_ADAPT_SHEETS/look.txt.
    @Test func looksAtArtboards() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BEZZLE_ADAPT_LOOK"], let names = env["BEZZLE_ADAPT_NAMES"], let out = AdaptTests.sheets else { return }
        let doc = try DesignFile.read(URL(fileURLWithPath: path))
        let assets = Assets(design: URL(fileURLWithPath: path))
        var lines: [String] = []
        for board in doc.nodes where board.isArtboard && names.split(separator: ",").contains(where: { board.name.contains($0) }) {
            var b = board
            b.frame.origin = .zero
            let shapes = Adapting.shapes(of: b, assets: assets)
            let plan = Adapt.plan(b, focus: Adapting.focus(of: b, assets: assets, now: true), shapes: shapes, cores: Adapting.cores(of: b, assets: assets))
            lines.append("shapes \(shapes) cutouts \(plan.layers.cutouts) boxes \(plan.layers.boxes.map(\.integral))")
            for (a, k, sc) in Adapt.options(plan, to: CGSize(width: board.frame.height, height: board.frame.width)).map({ ($0.0, $0.2, $0.3) }) {
                lines.append("  option turned \(String(describing: a.turned)) columns \(String(describing: a.columns)) k \(k) score \(sc)")
            }
            lines.append("== \(board.name) \(board.frame.size) mode \(plan.mode)")
            for (i, n) in b.children.enumerated() {
                lines.append("  [\(i)] \(n.kind) \(n.name.prefix(30)) \(Geometry.bounds(of: n).integral) image \(n.fill.image != nil) children \(n.children.count)")
            }
            lines.append("  backdrops \(plan.root.backdrops) loose \(plan.root.loose.map(\.0)) bands \(plan.root.bands.map(\.0))")
            lines.append(plan.root.flow.map { Adapt.describe(.stack($0)) } ?? "no flow")
            for size in [CGSize(width: board.frame.height, height: board.frame.width), CGSize(width: board.frame.width * 1.5, height: board.frame.height),
                         CGSize(width: board.frame.width * 0.6, height: board.frame.height)] {
                let r = Adapt.compose(plan, to: size)
                lines.append("  at \(size): k \(r.scale) turned \(String(describing: r.arrangement.turned))")
                for n in r.board.children { lines.append("    \(n.name.prefix(30)) \(Geometry.bounds(of: n).integral)") }
            }
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("look.txt"), atomically: true, encoding: .utf8)
    }

    /// A thumbnail as YouTube's are made: a person cut out of their photo, cut off by the foot of
    /// the frame, the photo's empty part reaching under the title beside them.
    static func thumbnail() -> Node {
        var person = A.rect(CGRect(x: -67, y: -457, width: 1059, height: 1588), .shape, name: "Person")
        person.fill.image = ImageFill(asset: "person.png", mode: .cover, size: CGSize(width: 1181, height: 1771))
        person.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 30, blur: 50)
        var b = A.board(CGSize(width: 1280, height: 720), [
            person,
            A.text("METAVERSE", 92, at: CGPoint(x: 624, y: 151), color: .white),
            A.rect(CGRect(x: 623, y: 275, width: 524, height: 122), .white, name: "Label"),
        ], color: RGBA(r: 0.4, g: 0.2, b: 0.5))
        b.name = "Thumbnail"
        return b
    }

    /// Where the person is in their picture: its left half, from a little below its top to its foot.
    static let personShape = CGRect(x: 0.06, y: 0.3, width: 0.5, height: 0.45)

    @Test func aCutOutPersonStandsOnTheFootAndTheTitleGoesAbove() throws {
        let plan = Adapt.plan(Self.thumbnail(), shapes: ["person.png": Self.personShape])
        // The person and the title are two blocks, not one.
        #expect(plan.layers.cutouts.contains(0))
        let r = Adapt.compose(plan, to: CGSize(width: 720, height: 1280))
        #expect(r.arrangement.turned != nil)
        let person = r.board.children[0], title = r.board.children[1]
        // What the person shows reaches the foot, as it did, and the title lies above them.
        let shown = plan.layers.boxes[0]
        let k = person.frame.width / plan.layers.nodes[0].frame.width
        let shownNow = CGRect(x: person.frame.minX + (shown.minX - plan.layers.nodes[0].frame.minX) * k,
                              y: person.frame.minY + (shown.minY - plan.layers.nodes[0].frame.minY) * k,
                              width: shown.width * k, height: shown.height * k)
        #expect(abs(shownNow.maxY - 1280) < 2, "\(shownNow)")
        #expect(title.frame.maxY <= shownNow.minY + 1, "\(title.frame) over \(shownNow)")
        // Wider, it is the thumbnail it was, a little bigger.
        let wide = Adapt.compose(plan, to: CGSize(width: 1920, height: 720))
        #expect(wide.arrangement == .original)
    }

    /// A cut-out whose picture runs far past the page, as a laptop's does, is no reason to shrink
    /// the design: what shows of it is what must fit.
    @Test func aCutOutRunningPastThePageDoesNotShrinkTheDesign() throws {
        var laptop = A.rect(CGRect(x: -21, y: 170, width: 1532, height: 1149), .shape, name: "Laptop")
        laptop.fill.image = ImageFill(asset: "laptop.png", mode: .cover, size: CGSize(width: 1532, height: 1149))
        let post = A.board(CGSize(width: 900, height: 900), [
            laptop,
            A.text("Tailored to every department, it becomes a tool for productivity and innovation.", 30, at: CGPoint(x: 74, y: 182), width: 589, color: .white),
            A.text("weblaw", 20, face: "Bold", at: CGPoint(x: 74, y: 785), color: .white),
        ], color: RGBA(r: 0.1, g: 0.3, b: 0.35))
        let plan = Adapt.plan(post, shapes: ["laptop.png": CGRect(x: 0.234, y: 0.135, width: 0.516, height: 0.719)],
                              cores: ["laptop.png": CGRect(x: 0.27, y: 0.25, width: 0.45, height: 0.55)])
        for s in [CGSize(width: 540, height: 900), CGSize(width: 900, height: 1260), CGSize(width: 1080, height: 1920)] {
            let r = Adapt.compose(plan, to: s)
            #expect(r.scale > 0.45, "at \(s): \(r.scale)")
            let words = r.board.children[1].frame, mark = r.board.children[2].frame
            #expect(!words.intersects(mark), "at \(s): \(words) \(mark)")
        }
    }

    @Test func aPhotoTheArtboardCropsIsAPanelOfIt() throws {
        var poster = A.board(CGSize(width: 1080, height: 1920), [
            A.text("Exclusive workshops", 72, face: "Bold", at: CGPoint(x: 70, y: 234), width: 900, color: .white),
            { var p = A.photo(CGRect(x: -432, y: 880, width: 1860, height: 1298)); p.name = "Photo"; return p }(),
            { var q = A.photo(CGRect(x: 70, y: 1651, width: 195, height: 195)); q.name = "Code"; return q }(),
        ], color: RGBA(r: 0.05, g: 0.2, b: 0.3))
        poster.name = "Poster"
        let plan = Adapt.plan(poster)
        // Cut down to what shows, it looks as it did.
        let photo = plan.layers.nodes[1]
        #expect(photo.frame == CGRect(x: 0, y: 880, width: 1080, height: 1040))
        let before = Renderer.imageRect(poster.children[1].fill.image!, in: poster.children[1].frame.size).offsetBy(dx: -432, dy: 880)
        let after = Renderer.imageRect(photo.fill.image!, in: photo.frame.size).offsetBy(dx: 0, dy: 880)
        #expect(abs(before.midX - after.midX) < 2 && abs(before.midY - after.midY) < 2 && abs(before.width - after.width) < before.width * 0.003)
        let wide = Adapt.compose(plan, to: CGSize(width: 1920, height: 1080)).board
        let words = try #require(wide.children.first { $0.name == "Exclusive workshops" }), shown = try #require(wide.children.first { $0.name == "Photo" })
        // Side by side on a wide page, nothing over the words.
        #expect(!words.frame.intersects(shown.frame), "\(words.frame) \(shown.frame)")
        // A code to scan keeps its square.
        let code = try #require(wide.children.first { $0.name == "Code" })
        #expect(abs(code.frame.width - code.frame.height) < 1)
    }

    // MARK: - The AI's tools

    @Test func anArtboardTheAIMakesAtAPresetHoldsItsLayersWhereItSaid() async throws {
        let bench = Bench()
        MCPTools.opened(bench.store)
        let tools = MCPTools()
        _ = await tools.call("add_layers", ["design": bench.store.name, "layers": [
            ["kind": "artboard", "name": "Made", "preset": "Instagram story & reel", "children": [
                ["kind": "rectangle", "name": "Corner", "x": 10, "y": 10, "width": 100, "height": 100],
            ]],
        ]])
        let made = try #require(bench.store.doc.nodes.first { $0.name == "Made" })
        #expect(made.frame.size == CGSize(width: 1080, height: 1920))
        #expect(made.children.first?.frame == CGRect(x: 10, y: 10, width: 100, height: 100))
    }


    @Test func theAIsToolsLayItOutAndSayWhenItIsNot() async throws {
        let (bench, post) = photoBench()
        MCPTools.opened(bench.store)
        let tools = MCPTools()
        func call(_ name: String, _ args: [String: Any]) async -> String {
            var args = args
            args["design"] = bench.store.name
            let result = await tools.call(name, args)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            return ((object?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        _ = await call("update_layers", ["updates": [["layer": "Board", "preset": "Instagram story & reel"]]])
        let story = try #require(bench.store.doc.node(post.id))
        #expect(story.frame.size == CGSize(width: 1080, height: 1920))
        #expect(story.children != post.children)
        _ = await call("update_layers", ["updates": [["layer": "Board", "height": 1350]]])
        #expect(bench.store.doc.node(post.id)?.children == post.children)
        _ = await call("update_layers", ["updates": [["layer": "Board", "adapts": false]]])
        let described = await call("get_layers", ["layers": ["Board"]])
        #expect(described.contains("\"adapts\""))
        _ = await call("update_layers", ["updates": [["layer": "Board", "width": 300]]])
        #expect(bench.store.doc.node(post.id)?.children == post.children)
        let warned = await call("update_layers", ["updates": [["layer": "Photo", "adapts": true]]])
        #expect(warned.contains("adapts is for artboards"))
    }

    // MARK: - Files and sharing

    @Test func keepingLayersInPlaceIsSavedAndShared() throws {
        var board = A.photoPost()
        board.pinsLayers = true
        var doc = BezzleDocument()
        doc.nodes = [board]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Adapt-\(UUID().uuidString).bezzle")
        try DesignFile.write(doc, to: url)
        #expect(try DesignFile.read(url).nodes[0].pinsLayers == true)
        // Shared, it is a property of its own, merged on its own.
        #expect(LayerField.all.contains { $0.name == "pinsLayers" })
        let values = try #require(LayerField.values(of: board))
        #expect(LayerField.node(board.id, from: values).pinsLayers == true)
        // A design from before it, without it, reads as laying out again.
        var plain = A.photoPost()
        plain.pinsLayers = nil
        #expect(Adapting.adapts(plain))
    }

    // MARK: - Motion

    @Test func movesSettleExactlyEvenWhenTheyChangeOnTheWay() throws {
        let post = A.photoPost()
        let tool = AdaptTool()
        var a = BezzleDocument(), b = BezzleDocument(), c = BezzleDocument()
        a.nodes = [post]
        b.nodes = [Adapting.resized(post, to: CGSize(width: 1200, height: 627), remembering: false)]
        c.nodes = [Adapting.resized(post, to: CGSize(width: 1080, height: 1920), remembering: false)]
        var t = 0.0
        _ = tool.frame(of: a, at: t)
        tool.move([post.id], withBoard: true)
        for _ in 0..<10 { t += 1.0 / 120; _ = tool.frame(of: b, at: t) }
        // Sent somewhere else halfway.
        tool.move([post.id], withBoard: true)
        var last = b
        for _ in 0..<300 { t += 1.0 / 120; last = tool.frame(of: c, at: t) }
        #expect(!tool.isAnimating)
        #expect(last == c)
    }

    @Test func nothingMovesWithoutBeingAsked() {
        let post = A.photoPost()
        let tool = AdaptTool()
        var a = BezzleDocument(), b = BezzleDocument()
        a.nodes = [post]
        b.nodes = [Adapting.resized(post, to: CGSize(width: 1200, height: 627), remembering: false)]
        _ = tool.frame(of: a, at: 0)
        #expect(tool.frame(of: b, at: 0.01) == b)
        #expect(!tool.isMoving)
        // Asked about an artboard that is not there, or one that went away on the way.
        tool.move([UUID()], withBoard: true)
        #expect(tool.frame(of: b, at: 0.02) == b)
        tool.move([post.id], withBoard: true)
        _ = tool.frame(of: a, at: 0.03)
        #expect(tool.frame(of: BezzleDocument(), at: 0.04) == BezzleDocument())
        #expect(!tool.isMoving)
    }

    @Test func aLaidOutArtboardIsAnnouncedToTheCanvas() throws {
        let (bench, post) = photoBench()
        _ = bench.canvas.adaptTool.frame(of: bench.store.doc, at: 1)
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1500, height: 500) } }
        _ = bench.canvas.adaptTool.frame(of: bench.store.doc, at: 1.008)
        #expect(bench.canvas.adaptTool.isMoving)
    }

    @Test func theSkeletonLiesOnTheArtboard() {
        for (_, design) in Self.designs where !design.children.isEmpty {
            for s in [CGSize(width: 1200, height: 627), CGSize(width: 402, height: 874)] {
                let r = Adapt.compose(Adapt.plan(design), to: s)
                let page = CGRect(origin: .zero, size: s).insetBy(dx: -2, dy: -2)
                for rect in r.skeleton.blocks + r.skeleton.springs.map(\.rect) + r.skeleton.bonds.map(\.rect) {
                    #expect(rect.minX.isFinite && rect.width >= 0 && rect.height >= 0 && page.intersects(rect.insetBy(dx: -1, dy: -1)), "\(design.name): \(rect)")
                }
            }
        }
    }

    // MARK: - Pictures

    @Test func visionFindsWhatAPhotoShows() throws {
        let photo = try #require(WelcomePhoto.paint())
        let p = try #require(PictureFocus.point(in: photo))
        #expect((0...1).contains(p.x) && (0...1).contains(p.y))
        // A blank picture draws the eye nowhere in particular: no crash, whatever it says.
        let blank = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        _ = PictureFocus.point(in: blank)
    }

    @Test func aPictureCroppedAgainStillCovers() {
        var random = Random(seed: 42)
        for _ in 0..<300 {
            var image = ImageFill(asset: "x", mode: .cover, size: CGSize(width: random.range(10, 4000), height: random.range(10, 4000)))
            image.scale = random.range(1, 3)
            let old = CGSize(width: random.range(1, 2000), height: random.range(1, 2000)), new = CGSize(width: random.range(1, 2000), height: random.range(1, 2000))
            image.offset = .zero
            let r0 = Renderer.imageRect(image, in: old)
            image.offset = CGPoint(x: random.range(-1, 1) * max(0, r0.width - old.width) / old.width / 2, y: random.range(-1, 1) * max(0, r0.height - old.height) / old.height / 2)
            let focus: CGPoint? = random.chance(0.5) ? CGPoint(x: random.unit(), y: random.unit()) : nil
            let r = Adapt.recropped(image, from: old, to: new, focus: focus)
            let rect = Renderer.imageRect(r, in: new)
            #expect(rect.insetBy(dx: -0.01 * new.width - 0.01, dy: -0.01 * new.height - 0.01).contains(CGRect(origin: .zero, size: new)), "\(image) \(old) → \(new)")
            // The same size gives it back.
            let same = Adapt.recropped(image, from: old, to: old, focus: nil)
            #expect(abs(same.offset.x - image.offset.x) < 0.0001 && abs(same.offset.y - image.offset.y) < 0.0001)
        }
        // Pictures fitted or stretched are not cropped.
        let fit = ImageFill(asset: "x", mode: .fit, size: CGSize(width: 100, height: 50))
        #expect(Adapt.recropped(fit, from: CGSize(width: 10, height: 10), to: CGSize(width: 50, height: 10), focus: nil) == fit)
    }

    // MARK: - Telling screens from posters

    @Test func screensAndPostersAreToldApart() {
        #expect(Adapt.mode(of: A.phoneScreen()) == .interface)
        #expect(Adapt.mode(of: A.webHero()) == .interface)
        #expect(Adapt.mode(of: A.photoPost()) == .composition)
        #expect(Adapt.mode(of: A.centredPost()) == .composition)
        #expect(Adapt.mode(of: A.spreadPoster()) == .composition)
        // A design of no preset's size, given a phone's, is laid out as a screen there; one of a
        // post's size stays a composition whatever it is given.
        var custom = A.photoPost()
        custom.frame.size = CGSize(width: 1000, height: 1250)
        #expect(Adapt.mode(of: custom, to: CGSize(width: 402, height: 874)) == .interface)
        #expect(Adapt.mode(of: A.photoPost(), to: CGSize(width: 402, height: 874)) == .composition)
        #expect(Adapt.mode(of: Self.empty()) == .composition)
    }

    // MARK: - Speed

    @Test func aLargeScreenLaysOutQuickly() {
        let design = Self.many()
        let plan = Adapt.plan(design)
        let start = CACurrentMediaTime()
        for i in 0..<10 { _ = Adapt.compose(plan, to: CGSize(width: 1000 + CGFloat(i) * 40, height: 1960)) }
        let each = (CACurrentMediaTime() - start) / 10
        // A Debug build, unoptimised: a release build is several times quicker.
        #expect(each < 0.25, "\(Int(each * 1000)) ms for \(design.children.count) layers")
        #expect(Self.check(design, at: [CGSize(width: 1024, height: 1366), CGSize(width: 402, height: 1960)]).isEmpty)
    }
}

extension Array {
    subscript(at i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
