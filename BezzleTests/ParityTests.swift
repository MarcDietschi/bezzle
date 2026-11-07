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

    // MARK: Developing photos

    /// The colour cube photos are developed through, for each setting at both ends and a few
    /// together, each colour's colour bands and the isolations: every value, bit for bit, hashed.
    @Test func developCubes() {
        var develops: [(String, Develop)] = [("neutral", Develop())]
        for setting in Develop.Setting.allCases {
            for end in [setting.range.lowerBound, setting.range.upperBound / 2, setting.range.upperBound] {
                var d = Develop()
                d[setting] = end
                develops.append(("\(setting) \(end)", d))
            }
        }
        var mixed = Develop()
        mixed[.exposure] = 0.7
        mixed[.contrast] = 35
        mixed[.highlights] = -60
        mixed[.shadows] = 45
        mixed[.temperature] = 30
        mixed[.vibrance] = 40
        develops.append(("mixed", mixed))
        for band in Develop.Band.allCases {
            var d = mixed
            d[band] = Develop.Shift(hue: 40, saturation: -30, luminance: 25)
            develops.append(("band \(band)", d))
            var shown = d
            shown.isolate = .band(band)
            develops.append(("isolated \(band)", shown))
        }
        for setting in [Develop.Setting.blacks, .shadows, .highlights, .whites] {
            var d = mixed
            d.isolate = .tone(setting)
            develops.append(("isolated \(setting)", d))
        }
        for (name, d) in develops {
            let data = Developer.cube(d)
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            Self.log("develop", "\(name): \(data.count) bytes, \(String(hash, radix: 16))")
        }
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: The prototype

    /// Layers linked to a screen, noted, moved, sent back and unlinked; a layer in a copy linking
    /// the copy; a screen going on by itself and stopping; and where the prototype starts.
    @Test func prototypeEditing() {
        let bench = Bench(extra: [CanvasTests.rect("Button", CGRect(x: 40, y: 200, width: 160, height: 44)),
                                  CanvasTests.rect("Card", CGRect(x: 40, y: 300, width: 160, height: 80))])
        let id = { (name: String) in bench.node(name)!.id }
        bench.store.selection = [id("Card")]
        bench.step { bench.store.makeComponent() }
        func line(_ what: String) {
            let doc = bench.store.doc
            let flows = doc.allNodes.filter { $0.flow != nil || $0.starts == true }.sorted { $0.name < $1.name }
                .map { n in
                    let f = n.flow.map { f in "to \(f.to.flatMap { doc.node($0)?.name } ?? "-") back \(f.back ?? false) note \(f.note ?? "-") motion \(f.motion?.rawValue ?? "-") after \(f.after.map { "\($0)" } ?? "-")" }
                    return "\(n.name): \(f ?? "-") starts \(n.starts ?? false)"
                }
            Self.log("prototype", "\(what): " + flows.joined(separator: " ; "))
        }
        let a = bench.a.id, b = bench.b.id
        bench.step { bench.store.linkFlow([id("Button")], to: b) }
        line("linked")
        bench.step { bench.store.setNote("  after signing in ", for: [id("Button")]) }
        line("noted")
        bench.step { bench.store.setMotion(.dissolve, for: [id("Button")]) }
        line("dissolves")
        bench.step { bench.store.setMotion(.auto, for: [id("Button")]) }
        line("auto")
        bench.step { bench.store.linkFlow([id("Button")], to: nil, back: true) }
        line("back")
        bench.step { bench.store.linkFlow([a], to: a) }
        line("a screen to itself")
        if let copy = bench.store.doc.allNodes.first(where: { $0.isCopy }), let inner = copy.children.first {
            bench.step { bench.store.linkFlow([inner.id], to: b) }
            line("a layer in a copy")
        }
        bench.step { bench.store.setGoesOn(after: 2.34, board: a) }
        line("goes on")
        bench.step { bench.store.setGoesOn(after: 0.01, board: a) }
        line("at least a tenth")
        bench.step { bench.store.setGoesOn(after: nil, board: a) }
        line("stops")
        bench.step { bench.store.setStart(b) }
        line("starts on B")
        bench.step { bench.store.unlinkFlow([id("Button")]) }
        line("unlinked")
        bench.undoLast()
        line("undone")
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    /// Naming looks and changing styles, as the store does it, step by step: what each style is
    /// and which layers name it where, written by name.
    @Test func styleEditing() {
        let blue = RGBA(r: 0.2, g: 0.35, b: 0.8), red = RGBA(r: 0.9, g: 0.2, b: 0.1)
        func rect(_ name: String, _ x: CGFloat) -> Node {
            var n = CanvasTests.rect(name, CGRect(x: x, y: 20, width: 60, height: 40))
            n.fill.color = blue
            return n
        }
        var words = Node(kind: .text, name: "Words", frame: CGRect(x: 20, y: 120, width: 0, height: 0))
        words.text = "Hello"
        words.refit()
        let bench = Bench(extra: [rect("One", 20), rect("Two", 120), rect("Three", 220), words])
        let id = { (name: String) in bench.node(name)!.id }
        func look(_ l: StyleLook) -> String {
            switch l {
            case .colour(let c): return "colour \(Inspect.hex(c.color))"
            case .text(let t): return "type \(t.family) \(t.face) \(Self.n(t.size))"
            case .shadow(let s): return "shadow \(Self.n(s.x)),\(Self.n(s.y)) \(Self.n(s.blur))"
            case .corners(let c): return "corners \(Self.n(c.radius))"
            }
        }
        func line(_ what: String) {
            let doc = bench.store.doc
            let styles = (doc.styles ?? []).sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }.map { s in
                "\(s.name) [\(look(s.look))\(s.dark.map { " dark " + look($0) } ?? "")]"
            }
            let uses = doc.allNodes.filter { !$0.isArtboard || $0.dark != nil }.sorted { $0.name < $1.name }.compactMap { n -> String? in
                let named = StylePlace.all(in: n).compactMap { p in p.named(in: n).flatMap { doc.style($0)?.name }.map { "\(p)=\($0)" } }
                let fill = n.fills.first.map { Inspect.hex($0.color) } ?? "-"
                return named.isEmpty && n.dark == nil ? nil : "\(n.name)(\(fill)\(n.dark.map { " dark \($0)" } ?? "")) \(named.joined(separator: ","))"
            }
            Self.log("styles", "\(what): " + styles.joined(separator: " ; ") + " | " + uses.joined(separator: " ; "))
        }
        bench.store.selection = [id("One")]
        var brand: UUID?
        bench.step { brand = bench.store.nameLook(at: .fill(0), "  Brand  ") }
        line("named")
        Self.log("styles", "offer: \(bench.store.styleShow.offer?.words ?? "-") / \(bench.store.styleShow.offer?.button ?? "-")")
        if let offer = bench.store.styleShow.offer { bench.step { bench.store.take(offer) } }
        line("named too")
        bench.store.selection = [id("Words")]
        var body: UUID?
        bench.step { body = bench.store.nameLook(at: .text, "") }
        line("type named")
        Self.log("styles", "suggested: \(bench.store.suggestedName(for: .colour(ColourLook(color: red)))) \(bench.store.suggestedName(for: .corners(CornerLook(radius: 12)))) \(StyleNames.colour(RGBA(hex: "8B4513")!))")
        if let brand {
            bench.step { bench.store.renameStyle(brand, to: "  Primary ") }
            line("renamed")
            bench.step { bench.store.renameStyle(brand, to: "   ") }
            line("not renamed to nothing")
            bench.store.selection = [id("Two")]
            bench.step { bench.store.unname(at: .fill(0)) }
            line("unnamed on Two")
            bench.step { bench.store.use(bench.store.style(brand)!, at: .fill(0)) }
            line("used on Two")
            bench.step { bench.store.changeStyle(brand, "x") { $0 = .colour(ColourLook(color: red)) } }
            line("changed from the list")
            // Changed through a layer: offered to keep it there.
            bench.store.selection = [id("Two")]
            bench.step { bench.store.edit("Fill") { $0.update(id("Two")) { $0.fill.color = blue } } }
            line("changed on Two")
            Self.log("styles", "offer: \(bench.store.styleShow.offer?.words ?? "-") / \(bench.store.styleShow.offer?.button ?? "-")")
            if let offer = bench.store.styleShow.offer { bench.step { bench.store.take(offer) } }
            line("only here")
        }
        // Dark: the artboard made dark, a look changed in the dark, and back to following.
        bench.store.selection = [bench.a.id]
        bench.step { bench.store.show(bench.a.id, dark: true) }
        line("dark")
        if let brand {
            bench.step { bench.store.changeStyle(brand, "x", dark: true) { $0 = .colour(ColourLook(color: RGBA(r: 0.1, g: 0.1, b: 0.3))) } }
            line("changed in the dark")
            bench.step { bench.store.followInTheDark(brand) }
            line("follows again")
        }
        var preview = bench.store.doc
        bench.store.previewing(bench.a.id, dark: false)(&preview)
        Self.log("styles", "previewed light: \(preview.node(bench.a.id)?.showsDark == false) fills \(preview.allNodes.filter { $0.name == "One" }.map { Inspect.hex($0.fill.color) })")
        var made: UUID?
        bench.step { bench.store.edit("x") { made = DocumentStore.lightTwin(of: bench.a.id, in: &$0) } }
        Self.log("styles", "light twin: \(made.flatMap { bench.store.doc.node($0) }.map { "\($0.name) at \(Self.n($0.frame.minX)) dark \($0.dark.map { "\($0)" } ?? "-")" } ?? "-")")
        bench.step { bench.store.forgetDark(bench.a.id) }
        line("dark forgotten")
        // Found looks, named in one go.
        bench.store.selection = []
        if let found = bench.store.doc.foundLooks()[.colour]?.first {
            bench.step { _ = bench.store.name(found) }
            line("found named")
        }
        Self.log("styles", "has dark \(bench.store.hasDark), users \((bench.store.doc.styles ?? []).sorted { $0.name < $1.name }.map { "\($0.name) \(bench.store.layers(using: $0.id).compactMap { bench.store.doc.node($0)?.name }.sorted())" })")
        if let body { bench.step { bench.store.removeStyle(body) } }
        line("type removed")
        bench.undoLast()
        line("undone")
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    /// The look of a few pictures (their tones, colours, what is lost to black and white) and
    /// what Auto makes of them, plain and developed.
    @Test func pictureLooksAndAuto() {
        func picture(_ w: Int, _ h: Int, _ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in 0..<h { for x in 0..<w {
                let (r, g, b) = color(x, y)
                ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }}
            return ctx.makeImage()!
        }
        let pictures: [(String, CGImage)] = [
            ("warm ramp", picture(120, 80) { x, y in (0.3 + Double(x) / 200, 0.25 + Double(x) / 260, 0.15 + Double(y) / 500) }),
            ("dark", picture(100, 100) { x, y in let v = 0.02 + Double((x * 7 + y * 13) % 23) / 120; return (v, v * 0.9, v * 1.1) }),
            ("blocks", picture(96, 64) { x, y in
                let k = (x / 16 + y / 16 * 6) % 8
                return [(0.9, 0.2, 0.2), (0.95, 0.6, 0.1), (0.9, 0.9, 0.2), (0.2, 0.7, 0.3), (0.2, 0.8, 0.8), (0.2, 0.3, 0.9), (0.5, 0.2, 0.8), (0.9, 0.3, 0.7)][k]
            }),
        ]
        var developed = Develop()
        developed[.exposure] = 0.6
        developed[.vibrance] = 40
        developed[.highlights] = -50
        func hash(_ v: [Double]) -> String {
            var h: UInt64 = 0xcbf29ce484222325
            for x in v { for byte in withUnsafeBytes(of: x.bitPattern, Array.init) { h = (h ^ UInt64(byte)) &* 0x100000001b3 } }
            return String(h, radix: 16)
        }
        for (name, image) in pictures {
            for (way, d) in [("plain", nil), ("developed", developed)] as [(String, Develop?)] {
                guard let look = PictureLook(image, d) else { Self.log("looks", "\(name) \(way): none"); continue }
                Self.log("looks", "\(name) \(way): tones \(hash(look.tones)) rgb \(hash(look.reds + look.greens + look.blues)) colours \(hash(look.colors)) crushed \(look.crushed) blown \(look.blown)")
            }
            let auto = Develop.auto(for: image)
            Self.log("looks", "\(name) auto: " + Develop.Setting.allCases.map { "\($0) \(auto[$0])" }.joined(separator: ", "))
        }
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Versions

    /// Looking back at a version, picking, bringing back and going back; and what is worked out
    /// about versions: thinning, the story, the ruler's slots, its motion, the sky, the springs.
    @Test func versionKeeping() throws {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        try DesignFile.write(bench.store.doc, to: bench.store.url)
        bench.store.becamePackage()
        let store = bench.store, shelf = store.versions
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        shelf.clock = { base }
        defer {
            shelf.stop()
            DocumentStore.finishSaving()
            try? FileManager.default.removeItem(at: store.url)
        }
        func names(_ ids: Set<UUID>?) -> String {
            (ids ?? []).compactMap { id in store.doc.node(id)?.name ?? shelf.travel?.doc.node(id)?.name }.sorted().joined(separator: ",")
        }
        func layers(_ what: String) {
            Self.log("versions", what + ": " + store.doc.allNodes.map { "\($0.name) \(Self.r(store.doc.absoluteFrame(of: $0.id)))" }.joined(separator: " ; "))
        }
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        let r = bench.node("R")!.id, s = bench.node("S")!.id
        bench.step { store.update([r], "Move") { $0.frame.origin.x = 200 } }
        store.selection = [s]
        bench.step { store.deleteSelection() }
        bench.step { store.edit("Add") { $0.nodes[0].children.append(CanvasTests.rect("T", CGRect(x: 20, y: 200, width: 80, height: 30))) } }
        layers("now")
        shelf.browse()
        shelf.show(first.id)
        Self.log("versions", "then: changed \(names(shelf.travel?.changed)) gone \(names(shelf.travel?.gone)) added \(names(shelf.travel?.added))")
        for p in [CGPoint(x: 135, y: 135), CGPoint(x: 225, y: 135), CGPoint(x: 400, y: 400)] {
            Self.log("versions", "under \(Self.n(p.x)),\(Self.n(p.y)): \(shelf.layer(at: p).map { names([$0]) } ?? "-")")
        }
        shelf.pick(at: CGPoint(x: 225, y: 135))
        shelf.pick(at: CGPoint(x: 135, y: 135))
        shelf.pick(at: CGPoint(x: 135, y: 135))
        Self.log("versions", "picked \(names(shelf.travel?.picked))")
        bench.step { shelf.bringBack() }
        layers("brought back")
        Self.log("versions", "selected \(names(Set(store.selection))) travel \(shelf.travel == nil ? "none" : "still")")
        bench.step { store.update([r], "Move") { $0.frame.origin.y = 300 } }
        bench.step { shelf.restore(first.id) }
        layers("gone back")
        Self.log("versions", "list: " + shelf.list.map { "\($0.name ?? "auto") \($0.layers)" }.joined(separator: ", "))
        let count = shelf.list.count
        bench.step { shelf.restore(first.id) }
        Self.log("versions", "again: \(shelf.list.count - count) more")

        let packed = try #require(VersionFiles.pack(store.doc))
        var unpacked = try #require(VersionFiles.unpack(packed))
        unpacked.viewport = store.doc.viewport
        // Its layers' ids are new each run, so how small it packs differs a little from run to run.
        var bare = store.doc
        bare.viewport = nil
        let json = try JSONEncoder().encode(bare)
        Self.log("versions", "json \(json.count) bytes, packed smaller \(packed.count < json.count / 2), back whole \(unpacked == store.doc), damaged \(VersionFiles.unpack(Data("no".utf8)) == nil)")
        var fixed = DesignVersion(date: Date(timeIntervalSince1970: 1_800_000_000.123), name: "Named", by: "anna", replica: "r1", layers: 7, shared: true)
        fixed.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var plain = DesignVersion(date: Date(timeIntervalSince1970: 1_799_000_000))
        plain.id = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        let index = store.url.appendingPathComponent("parity-index")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try VersionFiles.writeIndex([fixed, plain], to: index, replica: "r1")
        let written = try Data(contentsOf: VersionFiles.folder(of: index).appendingPathComponent("index.json"))
        let sorted = (try? JSONSerialization.jsonObject(with: written)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        Self.log("versions", "index " + (String(data: sorted, encoding: .utf8) ?? "-"))
        Self.log("versions", "index read " + VersionFiles.index(of: index, replica: "r1").map { "\($0.id.uuidString.prefix(4)) \($0.date.timeIntervalSince1970) \($0.name ?? "-")" }.joined(separator: ", "))

        var list: [DesignVersion] = []
        for k in 0..<400 {
            var v = DesignVersion(date: base.addingTimeInterval(-Double(k) * 1300))
            if k % 37 == 0 { v.name = "N\(k)" }
            list.append(v)
        }
        for k in 0..<40 { list.append(DesignVersion(date: base.addingTimeInterval(-Double(k) * 4.3 * 86_400 - 30 * 86_400))) }
        let kept = VersionFiles.kept(list, now: base)
        Self.log("versions", "kept \(kept.count): " + kept.map { String(Int(base.timeIntervalSince($0.date) / 60)) }.joined(separator: ","))
        let story = VersionShelf.story(of: kept)
        Self.log("versions", "story: " + story.compactMap { id in kept.firstIndex { $0.id == id } }.map(String.init).joined(separator: ","))
        Self.log("versions", "short story: \(VersionShelf.story(of: Array(kept.prefix(12))).count)")

        let dates = (0..<12).map { base.addingTimeInterval(Double($0 * $0) * 1800) }
        let xs = TimeRuler.slots(dates, width: 560, now: base.addingTimeInterval(86_400 * 3))
        Self.log("versions", "slots: " + xs.map { Self.n($0) }.joined(separator: ","))
        Self.log("versions", "one slot: " + TimeRuler.slots([], width: 300, now: base).map { Self.n($0) }.joined(separator: ","))
        Self.log("versions", "nearest: " + [0, 77, 300, 555, 700].map { String(TimeRuler.nearest(CGFloat($0), in: xs)) }.joined(separator: ","))
        let motion = RulerMotion()
        let bases = dates.enumerated().map { $0.offset % 4 == 0 ? 15 : 11 as CGFloat } + [0]
        var t = base
        for f in 0..<90 {
            t = t.addingTimeInterval(1.0 / 60)
            let pointer: CGFloat? = f < 30 ? nil : xs[3] + CGFloat(f - 30)
            let head = f < 45 ? xs[xs.count - 1] : xs[2]
            motion.step(at: t, xs: xs, bases: bases, pointer: pointer, head: head, held: f > 70, width: 560)
            if f % 15 == 14 {
                Self.log("versions", "motion \(f): heights " + motion.heights.map { Self.n(CGFloat($0.value)) }.joined(separator: ",")
                    + " glow " + motion.glow.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    + " head \(Self.n(CGFloat(motion.head.value))) lift \(Self.n(CGFloat(motion.lift.value))) lens \(Self.n(CGFloat(motion.lens.value)))"
                    + " shown \(Self.n(CGFloat(motion.lensShown.value))) wave \(String(format: "%.4f", motion.wave.reduce(0) { $0 + abs($1) }))"
                    + " swell \(Self.n(motion.swell(at: xs[4]))) ripple \(String(format: "%.4f", motion.ripple(at: xs[2]))) settled \(motion.settled)")
            }
        }
        Self.log("versions", "crossed: \(RulerMotion.crossed(from: 90, to: 10, xs: xs)) \(RulerMotion.crossed(from: 10, to: 300, xs: xs)) \(RulerMotion.crossed(from: 50, to: 50, xs: xs))")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        for (month, day) in [(1, 15), (6, 21), (10, 27)] {
            for hour in stride(from: 0, to: 24, by: 3) {
                let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: 20))!
                let sky = Sky.at(date, calendar: calendar)
                Self.log("versions", "sky \(month)/\(day) \(hour)h: x \(f(sky.x)) sun \(f(sky.sun)) warmth \(f(sky.warmth)) night \(f(sky.night)) dusk \(f(sky.dusk))"
                    + " sky \(f(sky.sky.r)),\(f(sky.sky.g)),\(f(sky.sky.b)) light \(f(sky.light.r)),\(f(sky.light.g)),\(f(sky.light.b))")
            }
        }
        var spring = DeckTool.Spring(0)
        spring.target = 100
        var trail: [String] = []
        for k in 0..<30 {
            if k < 20 { spring.step(1.0 / 60) } else { spring.step(1.0 / 30, stiffness: 900, damping: 10) }
            trail.append(Self.n(CGFloat(spring.value)))
        }
        Self.log("versions", "spring: " + trail.joined(separator: ",") + " settled \(spring.settled) moving \(spring.isMoving)")
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Decks

    /// A stack of three posts on A, turned, offered, kept, followed, filled, broken, moved, taken
    /// away, spread out and unstacked.
    @Test func deckEditing() {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        back.fill.color = RGBA(r: 1, g: 1, b: 1)
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        title.text = "Tip 1"
        title.style?.size = 24
        title.refit()
        let bench = Bench(extra: [back, title])
        let store = bench.store, a = bench.a.id
        bench.step { store.addPost(to: a) }
        bench.step { store.addPost(to: a) }
        func layer(_ name: String, in post: Int?) -> Node? { bench.a.layers(of: post).first { $0.name == name } }
        for (i, p) in bench.a.posts.enumerated() {
            let t = layer("Title", in: p)!
            bench.step { store.update([t.id], "Type") { $0.text = "Tip \(i + 1)" } }
        }
        let posts = bench.a.posts
        store.turn(a, to: posts[0])
        // Posts by what their title says, as their numbers are new each run.
        func said(_ p: Int?) -> String { layer("Title", in: p)?.text ?? "design" }
        func named(_ id: UUID) -> String {
            guard let n = store.doc.node(id) else { return "-" }
            return "\(n.name)@\(said(store.doc.post(of: id)?.post ?? nil))"
        }
        func line(_ what: String) {
            let doc = store.doc
            let boards = doc.nodes.map { b -> String in
                guard b.isDeck else { return "\(b.name) \(Self.r(b.frame)) [" + b.children.map { "\($0.name) \(Self.r($0.frame)) \($0.text ?? "")" }.joined(separator: ", ") + "]" }
                let ps = b.posts.map { p in
                    said(p) + ": " + b.layers(of: p).map { n in
                        "\(n.name) \(Self.r(n.frame)) \(n.text ?? "") \(Inspect.hex(n.fill.color))\(n.own.map { " own " + $0.joined(separator: "+") } ?? "")"
                    }.joined(separator: ", ")
                }
                let design = b.layers(of: nil).map { "\($0.name) \(Inspect.hex($0.fill.color))" }.joined(separator: ", ")
                return "\(b.name) deck front \(said(store.front(of: b))) {design \(design)} " + ps.joined(separator: " | ")
            }
            Self.log("decks", "\(what): " + boards.joined(separator: " ;; "))
        }
        line("made")
        store.selection = [layer("Title", in: posts[0])!.id, layer("Back", in: posts[0])!.id]
        store.turn(a, to: posts[1])
        Self.log("decks", "turned: selection " + store.selection.map(named).joined(separator: ", "))
        Self.log("decks", "copies: " + store.copies(acrossPosts: layer("Title", in: posts[1])!.id).map(named).joined(separator: ", "))
        store.turnPage(by: 1)
        Self.log("decks", "paged: front \(said(store.front(of: bench.a))) place \(store.place(in: bench.a))")
        store.turnPage(by: -2)
        Self.log("decks", "paged back: front \(said(store.front(of: bench.a)))")
        // A colour changed in the post in front, which every post follows: offered to keep in it alone.
        let backID = layer("Back", in: store.front(of: bench.a))!.id
        store.selection = [backID]
        bench.step { store.update([backID], "Fill") { $0.fill.color = RGBA(r: 0.9, g: 0.3, b: 0.2) } }
        line("filled")
        Self.log("decks", "offer: \(store.offer?.words ?? "-") / \(store.offer?.button ?? "-") on \(store.offer.map { named($0.anchor) } ?? "-")")
        if let offer = store.offer { bench.step { store.take(offer) } }
        line("kept")
        bench.step { store.followDesign([backID]) }
        line("followed")
        let t2 = layer("Title", in: posts[1])!.id
        bench.step { store.giveEveryPost([t2]) }
        line("given")
        let t1 = layer("Title", in: posts[0])!.id
        bench.step { store.update([t1], "Type") { $0.text = "Tip 1" } }
        let t3 = layer("Title", in: posts[2])!.id
        bench.step { store.update([t3], "Type") { $0.text = String(repeating: "A long tip that runs on ", count: 12); $0.frame.size.width = 120; $0.style?.sizing = .fixed; $0.frame.size.height = 40 } }
        Self.log("decks", "broken: " + store.brokenPosts(of: bench.a).map { said($0).prefix(6) + "" }.sorted().joined(separator: ","))
        bench.step { store.update([t3], "Type") { $0.text = "Tip 3"; $0.style?.sizing = .autoWidth; $0.refit() } }
        bench.step { store.movePost(posts[2], in: a, to: 0) }
        Self.log("decks", "moved: " + bench.a.posts.map(said).joined(separator: ","))
        bench.step { store.movePost(posts[2], in: a, to: 1) }
        Self.log("decks", "moved nowhere: " + bench.a.posts.map(said).joined(separator: ","))
        let table = DataTable("Title,Note\nOne,a\nTwo,b\nThree,c\nFour,d")!
        var filled = 0
        bench.step { filled = store.spread(table: table, from: layer("Title", in: posts[0])!.id) }
        Self.log("decks", "table: \(filled) columns, posts " + bench.a.posts.map(said).joined(separator: ","))
        store.turn(a, to: bench.a.posts[1])
        bench.step { store.removePost(bench.a.posts[1], from: a) }
        line("removed")
        bench.step { store.spreadOut(a) }
        line("spread out")
        Self.log("decks", "selected " + store.selection.compactMap { store.doc.node($0)?.name }.joined(separator: ","))
        bench.undo.undo()
        store.turn(a, to: bench.a.posts.last!)
        bench.step { store.unstack(a) }
        line("unstacked")
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Resources

    /// Parts, icons and the design's own components put onto a light and a dark artboard: bars
    /// along the edges and under each other, a list across, a part far narrower than its artboard,
    /// the same part again as a copy, an icon, an icon onto an icon, a component's copy.
    @Test func resourcePlacing() throws {
        let bench = Bench()
        bench.step {
            bench.store.edit("Setup") { doc in
                var phone = Node(kind: .artboard, name: "Phone", frame: CGRect(x: 0, y: 1000, width: 402, height: 874))
                phone.fill = Fill(color: .white)
                var night = Node(kind: .artboard, name: "Night", frame: CGRect(x: 500, y: 1000, width: 402, height: 874))
                night.fill = Fill(color: .hex("#111111"))
                var wide = Node(kind: .artboard, name: "Wide", frame: CGRect(x: 1000, y: 1000, width: 1440, height: 900))
                wide.fill = Fill(color: .white)
                doc.nodes += [phone, night, wide]
            }
        }
        let store = bench.store
        func line(_ what: String, _ id: UUID?) {
            guard let id, let n = store.doc.node(id) else { Self.log("resources", "\(what): none"); return }
            let master = store.doc.component(of: n).map { "copy of \($0.name) part \($0.master?.part ?? "-")" } ?? (n.isCopy ? "copy" : "plain")
            Self.log("resources", "\(what): \(n.name) \(n.kind) \(Self.r(store.doc.absoluteFrame(of: id))) on \(store.doc.artboard(of: id)?.name ?? "canvas") \(master) children \(n.children.count) fill \(Inspect.hex(n.fill.color))")
        }
        func put(_ what: String, _ r: Resource, at p: CGPoint?, on target: UUID? = nil) -> UUID? {
            var made: UUID?
            bench.step { made = store.place(r, at: p, on: target) }
            line(what, made)
            return made
        }
        _ = put("status", .component("ios.status-bar"), at: CGPoint(x: 200, y: 1500))
        _ = put("status again", .component("ios.status-bar"), at: CGPoint(x: 200, y: 1300))
        _ = put("navigation", .component("ios.navigation-bar"), at: CGPoint(x: 200, y: 1300))
        _ = put("tabs", .component("ios.tab-bar"), at: CGPoint(x: 200, y: 1200))
        _ = put("search", .component("ios.search-bar"), at: CGPoint(x: 200, y: 1400))
        _ = put("toggle", .component("ios.toggle"), at: CGPoint(x: 200, y: 1600))
        _ = put("dark toggle", .component("ios.toggle"), at: CGPoint(x: 700, y: 1600))
        _ = put("dark tabs", .component("ios.tab-bar"), at: CGPoint(x: 700, y: 1200))
        _ = put("wide status", .component("ios.status-bar"), at: CGPoint(x: 1600, y: 1400))
        _ = put("canvas button", .component("ios.button-prominent"), at: CGPoint(x: -400, y: 300))
        Self.log("resources", "edges: top \(Self.n(store.edgeStack(of: bench.node("Phone")!, top: true))) bottom \(Self.n(store.edgeStack(of: bench.node("Phone")!, top: false)))")
        let set = IconSetID.lucide
        let style = Icons.set(set).defaultStyle
        let heart = put("heart", .icon(set, "heart", style), at: CGPoint(x: 200, y: 1700))
        _ = put("star over heart", .icon(set, "star", style), at: CGPoint(x: 200, y: 1700), on: heart)
        _ = put("dark house", .icon(set, "house", style), at: CGPoint(x: 700, y: 1750))
        if let toggle = store.doc.masters.first(where: { $0.master?.part == "ios.toggle" }) {
            _ = put("design copy", .design(toggle.id), at: CGPoint(x: 300, y: 1800))
        }
        let plan = store.placing(.component("ios.tab-bar"), at: nil, into: bench.node("Phone")!.id, dark: true, width: 360)
        Self.log("resources", "planned: \(plan.map { "\($0.node.name) \(Self.r($0.node.frame)) part \($0.part ?? "-") fit \($0.fit)" } ?? "none")")
        Self.log("resources", "keys: " + [Resource.component("ios.toggle"), .icon(set, "heart", style)].map(\.key).joined(separator: ", "))
        #expect(FileManager.default.fileExists(atPath: Self.url.path))
    }

    // MARK: Libraries

    /// Another design's component and colour style taken into a design: a style given to the
    /// selection, with nothing selected only brought in, at an open shadow place and on text;
    /// several components taken at once; news when the other design changes, and the update.
    @Test func libraryTaking() {
        func rect(_ name: String, _ x: CGFloat) -> Node {
            var n = CanvasTests.rect(name, CGRect(x: x, y: 20, width: 60, height: 40))
            n.fill.color = RGBA(r: 0.2, g: 0.35, b: 0.8)
            return n
        }
        // The library: a component "Card" and a style "Brand".
        let source = Bench(extra: [rect("Card", 20), rect("Badge", 120), rect("Swatch", 220)])
        source.store.selection = [source.node("Card")!.id]
        source.step { source.store.makeComponent() }
        source.store.selection = [source.node("Badge")!.id]
        source.step { source.store.makeComponent() }
        source.store.selection = [source.node("Swatch")!.id]
        var brand: UUID?
        source.step { brand = source.store.nameLook(at: .fill(0), "Brand") }
        let url = URL(fileURLWithPath: "/parity/Library.bezzle")
        let library = LibraryContent(url: url, name: "Library", modified: Date(timeIntervalSince1970: 1_800_000_000),
                                     masters: source.store.doc.masters, styles: source.store.doc.styles ?? [])
        Self.log("libraries", "library: masters " + library.ownMasters.map(\.name).sorted().joined(separator: ",") + " styles " + library.ownStyles.map(\.name).joined(separator: ","))

        var words = Node(kind: .text, name: "Words", frame: CGRect(x: 20, y: 120, width: 0, height: 0))
        words.text = "Hello"
        words.refit()
        let bench = Bench(extra: [CanvasTests.rect("Box", CGRect(x: 20, y: 20, width: 80, height: 50)), words])
        let store = bench.store
        func line(_ what: String) {
            let doc = store.doc
            let styles = (doc.styles ?? []).map { "\($0.name) \($0.library.map { "from \($0.design)" } ?? "own")" }.sorted()
            let masters = doc.masters.map { "\($0.name) \($0.master?.library.map { "from \($0.design)" } ?? "own")" }.sorted()
            let layers = doc.allNodes.filter { !$0.isArtboard }.map { n in
                "\(n.name) fill \(Inspect.hex(n.fill.color)) on \(n.fill.on) shadow \(n.shadow.on) styles \(StylePlace.all(in: n).compactMap { p in p.named(in: n).flatMap { doc.style($0)?.name }.map { "\(p)=\($0)" } }.joined(separator: "+"))"
            }.sorted()
            Self.log("libraries", "\(what): styles [\(styles.joined(separator: ", "))] masters [\(masters.joined(separator: ", "))] layers \(layers.joined(separator: " ; "))")
        }
        if let brand {
            store.selection = [bench.node("Box")!.id]
            bench.step { store.use(brand, of: library) }
            line("used on box")
            store.selection = []
            bench.step { store.use(brand, of: library) }
            line("brought alone")
        }
        let take = library.taking(library.ownMasters.map(\.id))
        Self.log("libraries", "taking all: masters \(take.masters.map(\.name).sorted()) styles \(take.styles.map(\.name).sorted()) url \(take.url?.lastPathComponent ?? "-")")
        bench.step { store.edit("Bring") { _ = $0.bring(take) } }
        line("brought components")
        var shown = bench.node("Box")!
        if let s = library.ownStyles.first {
            DocumentStore.give(s, to: &shown, at: .shadow(0), dark: false)
            Self.log("libraries", "given at shadow: fill \(Inspect.hex(shown.fill.color)) shadow \(shown.shadow.on)")
            var text = bench.node("Words")!
            DocumentStore.give(s, to: &text, at: nil, dark: true, naming: false)
            Self.log("libraries", "given to text: fill \(Inspect.hex(text.fill.color)) named \(StylePlace.all(in: text).compactMap { $0.named(in: text) }.count)")
        }
        // The library changes: its style is redder and the card wider; the design has news, and takes it.
        var changed = source.store.doc
        if let i = changed.styles?.firstIndex(where: { $0.name == "Brand" }) { changed.styles?[i].look = .colour(ColourLook(color: RGBA(r: 0.9, g: 0.2, b: 0.1))) }
        if let i = changed.components?.firstIndex(where: { $0.name == "Card" }) { changed.components?[i].frame.size.width = 90 }
        let later = LibraryContent(url: url, name: "Library", modified: Date(timeIntervalSince1970: 1_800_000_100), masters: changed.masters, styles: changed.styles ?? [])
        let news = store.doc.libraryNews(in: [later])
        Self.log("libraries", "news: " + news.map { "\($0.name) masters \($0.masters.compactMap { store.doc.master($0)?.name }.sorted()) styles \($0.styles.compactMap { store.doc.style($0)?.name })" }.joined(separator: "; "))
        if let n = news.first {
            bench.step { store.edit("Update") { $0.update(from: later, masters: n.masters, styles: n.styles) } }
            line("updated")
            Self.log("libraries", "news after: \(store.doc.libraryNews(in: [later]).count)")
        }
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
