import Testing
import AppKit
@testable import Bezzle

/// What the canvas tools and offers moved into shared code for Windows do, written down step by
/// step through the canvas and the store as a person uses them, into a log
/// (`$TMPDIR/bezzle-parity.txt`). Run on the Mac app as it was and as it is, the two logs must
/// be the same: the move changed nothing. Each test only checks that the log could be written.
@MainActor
@Suite(.serialized)
struct ParityTests {
    /// Begun afresh in each run of the tests.
    private static let url: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-parity.txt")
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    private static func log(_ test: String, _ line: String) {
        let text = "\(test) | \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private static func n(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    private static func r(_ f: CGRect?) -> String {
        guard let f else { return "nil" }
        return "\(n(f.minX)),\(n(f.minY)) \(n(f.width))x\(n(f.height))"
    }

    private func said(_ bench: Bench) -> String { bench.store.measurement?.0 ?? "-" }

    /// Guides and grids showing while `body` runs, as the user had them after.
    private func showing(_ body: () -> Void) {
        let h = Helpers.shared
        let was = (h.guides, h.grids)
        if !h.guides { h.guides = true }
        if !h.grids { h.grids = true }
        defer {
            if h.guides != was.0 { h.guides = was.0 }
            if h.grids != was.1 { h.grids = was.1 }
        }
        body()
    }

    // MARK: Repeat grids on the canvas

    /// A 100 × 60 rectangle at 50,50 on artboard A (150,150 on the canvas), made a repeat grid
    /// and selected.
    private func gridBench() -> (Bench, UUID) {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 50, y: 50, width: 100, height: 60))])
        bench.store.selection = [bench.node("R")!.id]
        bench.step { bench.store.makeRepeatGrid() }
        return (bench, bench.store.selection[0])
    }

    private func gridLine(_ bench: Bench, _ id: UUID) -> String {
        guard let g = bench.store.node(id), let spec = g.grid else { return "no grid" }
        return "\(spec.columns)x\(spec.rows) gaps \(Self.n(spec.columnGap)),\(Self.n(spec.rowGap)) turn \(Self.n(CGFloat(spec.turn))) frame \(Self.r(bench.store.doc.absoluteFrame(of: id))) cells \(g.children.count)"
    }

    @Test func gridHandles() {
        let t = "grid"
        let (bench, id) = gridBench()
        Self.log(t, "made " + gridLine(bench, id))
        // The pull on its right edge, out past two more cells, held.
        bench.move(CGPoint(x: 250, y: 180))
        bench.drag(CGPoint(x: 250, y: 180), CGPoint(x: 490, y: 180), release: false)
        Self.log(t, "columns held: \(said(bench)) " + gridLine(bench, id))
        bench.release(CGPoint(x: 490, y: 180))
        Self.log(t, "columns let go: \(said(bench)) " + gridLine(bench, id))
        // The pull on its bottom edge, down past one more row.
        let f = bench.store.doc.absoluteFrame(of: id)!
        bench.drag(CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY + 70), release: false)
        Self.log(t, "rows held: \(said(bench)) " + gridLine(bench, id))
        bench.release(CGPoint(x: f.midX, y: f.maxY + 70))
        Self.log(t, "rows let go: " + gridLine(bench, id))
        // The corner's dot, back in.
        let g = bench.store.doc.absoluteFrame(of: id)!
        bench.drag(CGPoint(x: g.maxX, y: g.maxY), CGPoint(x: g.maxX - 130, y: g.maxY - 10))
        Self.log(t, "both: " + gridLine(bench, id))
        // The first gap between columns, wider by 30, then both ways with Shift.
        let spec = bench.store.node(id)!.grid!
        let x = 150 + 100 + spec.columnGap / 2
        bench.move(CGPoint(x: x, y: 170))
        bench.drag(CGPoint(x: x, y: 170), CGPoint(x: x + 30, y: 170), release: false)
        Self.log(t, "gap held: \(said(bench)) " + gridLine(bench, id))
        bench.release(CGPoint(x: x + 30, y: 170))
        Self.log(t, "gap let go: " + gridLine(bench, id))
        let x2 = 150 + 100 + bench.store.node(id)!.grid!.columnGap / 2
        bench.drag(CGPoint(x: x2, y: 170), CGPoint(x: x2 - 20, y: 170), flags: .shift)
        Self.log(t, "gaps with shift: " + gridLine(bench, id))
        // Just outside its top right corner, turned a little.
        let h = bench.store.doc.absoluteFrame(of: id)!
        bench.drag(CGPoint(x: h.maxX + 12, y: h.minY - 12), CGPoint(x: h.maxX + 40, y: h.minY + 30), release: false)
        Self.log(t, "turn held: \(said(bench)) " + gridLine(bench, id))
        bench.release(CGPoint(x: h.maxX + 40, y: h.minY + 30))
        Self.log(t, "turn let go: " + gridLine(bench, id))
        // Escape while pulling: back as it was.
        let k = bench.store.doc.absoluteFrame(of: id)!
        bench.drag(CGPoint(x: k.maxX, y: k.maxY), CGPoint(x: k.maxX + 300, y: k.maxY + 200), release: false)
        bench.key(53)
        bench.release(CGPoint(x: k.maxX + 300, y: k.maxY + 200))
        Self.log(t, "escaped: \(said(bench)) " + gridLine(bench, id))
        for i in 1...6 {
            bench.undoLast()
            Self.log(t, "undo \(i): " + gridLine(bench, id))
        }
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Layout grids on the canvas

    private func layoutLine(_ bench: Bench) -> String {
        guard let l = bench.a.layout else { return "no layout" }
        let c = l.columns.map { "cols \($0.count) gutter \(Self.n($0.gutter)) margin \(Self.n($0.margin))" } ?? "no cols"
        let b = l.baseline.map { "base \(Self.n($0.step)) off \(Self.n($0.offset))" } ?? "no base"
        return c + " " + b
    }

    @Test func layoutHandles() { showing { layoutHandlesShowing() } }

    private func layoutHandlesShowing() {
        let t = "layout"
        let bench = Bench()
        let board = bench.a.id
        bench.step { bench.store.edit("Layout") { $0.update(board) { $0.layout = LayoutGrid(columns: .init(count: 4, gutter: 20, margin: 30)) } } }
        bench.step { bench.store.edit("Baseline") { $0.update(board) { $0.layout?.baseline = .init(step: 20, offset: 0) } } }
        bench.store.selection = [board]
        bench.store.openAspect = .layout
        Self.log(t, "start " + layoutLine(bench))
        let area = LayoutGrid.areas(of: bench.a).first!
        let rects = bench.a.layout!.columnRects(in: area)
        let o = bench.a.frame.origin
        // The first gutter, from its middle, 10 further right: all open by 20.
        let gx = o.x + (rects[0].maxX + rects[1].minX) / 2
        bench.move(CGPoint(x: gx, y: o.y + 150))
        bench.drag(CGPoint(x: gx, y: o.y + 150), CGPoint(x: gx + 10, y: o.y + 150), release: false)
        Self.log(t, "gutter held: \(said(bench)) " + layoutLine(bench))
        bench.release(CGPoint(x: gx + 10, y: o.y + 150))
        Self.log(t, "gutter let go: " + layoutLine(bench))
        // The left margin, 15 in.
        let mx = o.x + 10
        bench.drag(CGPoint(x: mx, y: o.y + 150), CGPoint(x: mx + 15, y: o.y + 150))
        Self.log(t, "margin: " + layoutLine(bench))
        // The right margin, 12 in.
        let rx = o.x + bench.a.frame.width - 10
        bench.drag(CGPoint(x: rx, y: o.y + 150), CGPoint(x: rx - 12, y: o.y + 150))
        Self.log(t, "right margin: " + layoutLine(bench))
        // The third baseline, between two columns' middles, pulled down 6.
        let lines = bench.a.layout!.baselines(in: area)
        let cols = bench.a.layout!.columnRects(in: area)
        let bx = o.x + cols[0].midX, by = o.y + lines[2]
        bench.drag(CGPoint(x: bx, y: by), CGPoint(x: bx, y: by + 6))
        Self.log(t, "baseline: " + layoutLine(bench))
        // Escape while dragging the gutter: back as it was.
        let now = bench.a.layout!.columnRects(in: area)
        let gx2 = o.x + (now[1].maxX + now[2].minX) / 2
        bench.drag(CGPoint(x: gx2, y: o.y + 150), CGPoint(x: gx2 + 40, y: o.y + 150), release: false)
        bench.key(53)
        bench.release(CGPoint(x: gx2 + 40, y: o.y + 150))
        Self.log(t, "escaped: " + layoutLine(bench))
        for i in 1...4 {
            bench.undoLast()
            Self.log(t, "undo \(i): " + layoutLine(bench))
        }
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Guides

    private func guideLine(_ bench: Bench) -> String {
        (bench.a.guides ?? [:]).sorted { $0.key < $1.key }.map { "\($0.value.vertical ? "v" : "h") \($0.value.edge) \(Self.n($0.value.offset))" }.joined(separator: "; ")
    }

    @Test func guides() { showing { guidesShowing() } }

    private func guidesShowing() {
        let t = "guides"
        let bench = Bench()
        let board = bench.a.id
        bench.step { bench.store.edit("Guides") { $0.update(board) { $0.guides = ["g1": Guideline(vertical: true, edge: .start, offset: 120), "g2": Guideline(vertical: false, edge: .start, offset: 80)] } } }
        Self.log(t, "start " + guideLine(bench))
        // The vertical one, by its line where nothing lies, 37 right.
        bench.move(CGPoint(x: 220, y: 300))
        bench.drag(CGPoint(x: 220, y: 300), CGPoint(x: 257, y: 300))
        Self.log(t, "moved: " + guideLine(bench))
        // The horizontal one, 23 down, with Shift (to tens).
        bench.drag(CGPoint(x: 400, y: 180), CGPoint(x: 400, y: 203), flags: .shift)
        Self.log(t, "shift: " + guideLine(bench))
        // The vertical one dragged off the artboard: it goes.
        bench.drag(CGPoint(x: 257, y: 300), CGPoint(x: 257, y: 600))
        Self.log(t, "off: " + guideLine(bench))
        for i in 1...3 {
            bench.undoLast()
            Self.log(t, "undo \(i): " + guideLine(bench))
        }
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Masks

    private func tree(_ bench: Bench) -> String {
        func line(_ n: Node) -> String {
            n.children.isEmpty ? n.name : n.name + (n.isMask ? "[mask " : "[") + n.children.map(line).joined(separator: " ") + "]"
        }
        return bench.a.children.map(line).joined(separator: " ") + " | frames " + bench.a.children.map { Self.r($0.frame) }.joined(separator: " ")
    }

    @Test func dragsOutOfAndIntoMasks() {
        let t = "masks"
        var shape = Node(kind: .ellipse, name: "S", frame: CGRect(x: 20, y: 20, width: 150, height: 150))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 0.8)
        let held = CanvasTests.rect("R", CGRect(x: 60, y: 60, width: 200, height: 100))
        let bench = Bench(extra: [shape, held])
        let s = bench.node("S")!.id, r = bench.node("R")!.id
        bench.step { bench.store.mask(MaskPlan(shape: s, held: [r])) }
        Self.log(t, "masked: " + tree(bench) + " selected \(bench.store.selection.compactMap { bench.store.node($0)?.name })")
        // The held rectangle, picked in it, dragged wholly off the shape: it comes out.
        bench.store.selection = [r]
        let f = bench.store.doc.absoluteFrame(of: r)!
        bench.drag(CGPoint(x: f.midX, y: f.midY), CGPoint(x: f.midX + 260, y: f.midY + 120))
        Self.log(t, "dragged off: " + tree(bench))
        bench.undoLast()
        Self.log(t, "undone: " + tree(bench))
        // A new rectangle held still over a shape for a moment goes into it.
        var other = Node(kind: .rectangle, name: "O", frame: CGRect(x: 240, y: 150, width: 120, height: 80))
        other.fill.color = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.edit("Add") { $0.attach(other, to: bench.a.id) } }
        bench.store.selection = [other.id]
        let o = bench.store.doc.absoluteFrame(of: other.id)!
        // Over the mask's shape, where it reaches past it, held still a moment.
        bench.drag(CGPoint(x: o.midX, y: o.midY), CGPoint(x: 150, y: 150), release: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        bench.release(CGPoint(x: 150, y: 150))
        Self.log(t, "dipped: " + tree(bench) + " selected \(bench.store.selection.compactMap { bench.store.node($0)?.name })")
        bench.undoLast()
        Self.log(t, "dip undone: " + tree(bench))
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Component offers

    private func button() -> Node {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 0.8)
        var label = Node(kind: .text, name: "Label", frame: CGRect(x: 10, y: 10, width: 0, height: 0))
        label.text = "Go"
        label.refit()
        var button = Node(kind: .group, name: "Button", frame: CGRect(x: 40, y: 40, width: 120, height: 40))
        button.children = [shape, label]
        return button
    }

    /// A component made of "Button", and a second copy of it 100 points lower; `variant`, the
    /// first copy showing a second variant first.
    private func copies(variant: Bool = false) -> (Bench, UUID, UUID) {
        let bench = Bench(extra: [button()])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let first = bench.store.selection[0]
        if variant { bench.step { bench.store.addVariant(from: first) } }
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        return (bench, first, bench.store.selection[0])
    }

    private func layer(_ name: String, in copy: UUID, _ bench: Bench) -> Node? {
        func find(_ n: Node) -> Node? { n.name == name ? n : n.children.lazy.compactMap(find).first }
        return bench.store.node(copy).flatMap(find)
    }

    private func copyLine(_ bench: Bench, _ ids: [UUID]) -> String {
        ids.map { id in
            let shape = layer("Shape", in: id, bench), label = layer("Label", in: id, bench)
            // Variants by their place, as their numbers are new each time.
            let all = bench.store.doc.masters.first?.master?.variants ?? []
            let v = bench.store.node(id)?.instance?.variant.map { all.firstIndex(of: $0).map { "#\($0 + 2)" } ?? "?" } ?? "first"
            return "opacity \(Self.n(CGFloat(shape?.opacity ?? -1))) own \(shape?.own ?? []) text \(label?.text ?? "-") variant \(v)"
        }.joined(separator: " / ") + " variants \((bench.store.doc.masters.first?.master?.variants ?? []).count + 1)"
    }

    private func offerLine(_ bench: Bench) -> String {
        guard let o = bench.store.componentOffer else { return "no offer" }
        return "\(o.words) [\(o.buttons.map(\.title).joined(separator: ", "))]"
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func componentOffers(way: Int) {
        let t = "offers \(way)"
        let (bench, first, second) = copies(variant: way >= 3)
        // A change to the shape in the first copy, made at once, as the Opacity card makes it.
        let shape = layer("Shape", in: first, bench)!.id
        bench.store.selection = [shape]
        bench.step { bench.store.edit("Opacity") { $0.update(shape) { $0.opacity = 0.5 } } }
        Self.log(t, "after change: " + offerLine(bench) + " | " + copyLine(bench, [first, second]))
        guard let offer = bench.store.componentOffer else { return }
        switch way {
        case 0: bench.step { bench.store.take(offer, .onlyHere) }
        case 1: bench.step { bench.store.take(offer, .newVariant) }
        case 3: bench.step { bench.store.take(offer, offer.buttons.first { $0.action == .allVariants }?.action ?? .allVariants) }
        case 4: bench.step { bench.store.take(offer, .onlyHere) }
        default: break
        }
        Self.log(t, "taken: " + offerLine(bench) + " | " + copyLine(bench, [first, second]))
        bench.undoLast()
        Self.log(t, "undone: " + copyLine(bench, [first, second]))
        // Words changed in one copy: offered to all of them.
        let label = layer("Label", in: second, bench)!.id
        bench.step { bench.store.edit("Typing") { $0.update(label) { $0.text = "Stop"; $0.refit() } } }
        Self.log(t, "words: " + offerLine(bench) + " | " + copyLine(bench, [first, second]))
        if let words = bench.store.componentOffer, way == 2 {
            bench.step { bench.store.take(words, .everywhere) }
            Self.log(t, "words everywhere: " + copyLine(bench, [first, second]))
        }
        // In a variant, only that variant; then in all of them.
        if way == 3, let v = bench.store.componentOffer, v.buttons.contains(where: { $0.action == .onlyVariant }) {
            bench.step { bench.store.take(v, .onlyVariant) }
            Self.log(t, "only variant: " + copyLine(bench, [first, second]))
        }
        // Look like the others, and follow the component.
        bench.step { bench.store.resetCopy(first) }
        Self.log(t, "reset: " + copyLine(bench, [first, second]))
        bench.step { bench.store.followComponent([label]) }
        Self.log(t, "followed: " + copyLine(bench, [first, second]))
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    @Test func makingAComponentOffersItsLookAlikes() {
        let t = "lookalikes"
        var second = button()
        second.name = "Button 2"
        second.frame.origin = CGPoint(x: 40, y: 160)
        let bench = Bench(extra: [button(), second])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        Self.log(t, "made: " + offerLine(bench) + " copies \(bench.store.doc.copies(of: bench.store.doc.masters.first!.id).count)")
        if let offer = bench.store.componentOffer { bench.step { bench.store.take(offer, .link) } }
        Self.log(t, "linked: copies \(bench.store.doc.copies(of: bench.store.doc.masters.first!.id).count)")
        bench.step { bench.store.setVariant(nil, for: nil) }
        bench.store.selection = [bench.store.doc.copiesInOrderForParity(of: bench.store.doc.masters.first!.id).first!]
        bench.step { bench.store.addVariant() }
        Self.log(t, "variant: variants \((bench.store.doc.masters.first?.master?.variants ?? []).count + 1) names \(Components.variants(of: bench.store.doc.masters.first!).map { Components.name(of: $0, in: bench.store.doc.masters.first!) })")
        bench.step { bench.store.renameVariant(bench.store.doc.masters.first!.master!.variants.first, of: bench.store.doc.masters.first!.id, to: "Pressed") }
        bench.step { bench.store.setVariant(nil) }
        Self.log(t, "renamed and back: " + Components.variants(of: bench.store.doc.masters.first!).map { Components.name(of: $0, in: bench.store.doc.masters.first!) }.joined(separator: ","))
        bench.step { bench.store.unlinkComponent() }
        Self.log(t, "unlinked: copies \(bench.store.doc.copies(of: bench.store.doc.masters.first!.id).count)")
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }
}

extension ParityTests {
    // MARK: Words riding a shape

    /// Texts laid on a ring and taken off again, through the store as the canvas and the
    /// assistant do, and what could and could not ride: a mask's shape, a locked one, a grid's cell.
    @Test func ridingShapes() {
        func words(_ name: String, _ text: String, at: CGPoint) -> Node {
            var n = Node(kind: .text, name: name, frame: CGRect(origin: at, size: CGSize(width: 10, height: 10)))
            n.text = text
            n.style?.size = 24
            n.refit()
            return n
        }
        var locked = CanvasTests.rect("Locked", CGRect(x: 300, y: 300, width: 80, height: 40))
        locked.locked = true
        let bench = Bench(extra: [words("Words", "ROUND AND ROUND", at: CGPoint(x: 40, y: 40)), words("More", "and again", at: CGPoint(x: 40, y: 300)),
                                  Node(kind: .ellipse, name: "Ring", frame: CGRect(x: 100, y: 80, width: 160, height: 160)), locked,
                                  CanvasTests.rect("Cut", CGRect(x: 400, y: 80, width: 80, height: 80)),
                                  CanvasTests.rect("Held", CGRect(x: 410, y: 90, width: 40, height: 40))])
        let id = { (name: String) in bench.node(name)!.id }
        bench.store.selection = [id("Cut"), id("Held")]
        bench.step { bench.store.maskSelection() }
        let doc = { bench.store.doc }
        func line(_ what: String) { Self.log("riding", what) }
        func tree(_ ids: [UUID]) -> String {
            ids.compactMap { doc().node($0) }.map { n in
                let parent = doc().parent(of: n.id)
                return "\(n.name) in \(parent?.name ?? "-") [\(parent?.children.map(\.name).joined(separator: ",") ?? "")] frame \(Self.r(n.frame)) curve \(n.curve.map { "\($0)" } ?? "nil") path \(n.curvePath ?? "nil") rotation \(Self.n(n.rotation))"
            }.joined(separator: " ; ")
        }
        for shape in ["Ring", "Locked", "Cut", "Held", "Words"] {
            line("can ride \(shape): \(DocumentStore.canRide(id("Words"), on: id(shape), in: doc()))")
        }
        var curve = TextCurve(rides: true)
        curve.at = 0.3
        bench.step { bench.store.edit(DocumentStore.riding) { doc in line("rode into \(DocumentStore.ride(id("Words"), on: id("Ring"), curve: curve, in: &doc).flatMap { doc.node($0)?.name } ?? "nil")") } }
        line("after riding: " + tree([id("Words"), id("Ring")]))
        if let group = doc().parent(of: id("Words")) { line("group \(group.name) frame \(Self.r(group.frame))") }
        bench.step { bench.store.edit(DocumentStore.riding) { doc in line("second rode into \(DocumentStore.ride(id("More"), on: id("Ring"), curve: TextCurve(reversed: true, hangs: true), in: &doc).flatMap { doc.node($0)?.name } ?? "nil")") } }
        line("after the second: " + tree([id("Words"), id("More"), id("Ring")]))
        bench.step { bench.store.edit(DocumentStore.takingOffPath) { doc in DocumentStore.takeOffPath([id("Words")], in: &doc) } }
        line("one off: " + tree([id("Words"), id("More"), id("Ring")]))
        bench.step { bench.store.edit(DocumentStore.takingOffPath) { doc in DocumentStore.takeOffPath([id("More")], in: &doc) } }
        line("both off: " + tree([id("Words"), id("More"), id("Ring")]))
        line("artboard holds: " + (doc().parent(of: id("Ring"))?.children.map(\.name).joined(separator: ",") ?? "-"))
        bench.undoLast()
        line("one undone: " + tree([id("Words"), id("More"), id("Ring")]))
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    /// A design for comparing what the canvas draws, written to `$TMPDIR/bezzle-parity-scene.bezzle`:
    /// one artboard with four columns and a guide, a repeat grid, two overlapping rectangles, a
    /// triangle, and a rectangle alone.
    @Test func writesTheScene() throws {
        var board = Node(kind: .artboard, name: "Scene", frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        board.layout = LayoutGrid(columns: .init(count: 4, gutter: 24, margin: 40))
        board.guides = ["g": Guideline(vertical: true, edge: .start, offset: 700)]
        var cell = CanvasTests.rect("Cell", CGRect(x: 60, y: 60, width: 100, height: 60))
        cell.fill.color = RGBA(r: 0.85, g: 0.5, b: 0.3)
        var one = CanvasTests.rect("One", CGRect(x: 520, y: 80, width: 120, height: 80))
        one.fill.color = RGBA(r: 0.3, g: 0.5, b: 0.85)
        var two = CanvasTests.rect("Two", CGRect(x: 580, y: 120, width: 120, height: 80))
        two.fill.color = RGBA(r: 0.4, g: 0.7, b: 0.4)
        var triangle = Node.path(BezierPath("M 0 120 L 70 0 L 140 120 Z"), name: "Tri")
        triangle.frame = CGRect(x: 80, y: 380, width: 140, height: 120)
        triangle.fill.color = RGBA(r: 0.6, g: 0.4, b: 0.7)
        var alone = CanvasTests.rect("Alone", CGRect(x: 420, y: 420, width: 160, height: 110))
        alone.fill.color = RGBA(r: 0.9, g: 0.8, b: 0.3)
        board.children = [cell, one, two, triangle, alone]
        var doc = BezzleDocument()
        doc.nodes = [board]
        _ = DocumentStore.makeRepeatGrid(of: [doc.nodes[0].children[0].id], in: &doc, columns: 3, rows: 2)
        doc.fitGroups()
        doc.viewport = Viewport(origin: CGPoint(x: -40, y: -40), zoom: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-parity-scene.bezzle")
        try? FileManager.default.removeItem(at: url)
        try DesignFile.write(doc, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

extension BezzleDocument {
    /// The copies of a component, as they are read: by where they lie, the same in both versions.
    func copiesInOrderForParity(of master: UUID) -> [UUID] {
        copies(of: master).compactMap { c in absoluteFrame(of: c.id).map { (c.id, $0) } }
            .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
            .map(\.0)
    }
}
