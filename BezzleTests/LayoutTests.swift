import Testing
import AppKit
@testable import Bezzle

/// Layout grids and guides: how they are laid out on an artboard, how they keep up with it as it
/// changes size, how what moves catches on them, and how two people working on them at once both
/// keep what they did.
@MainActor
struct LayoutTests {
    private func board(_ size: CGSize = CGSize(width: 1440, height: 1024)) -> Node {
        Node(kind: .artboard, name: "Board", frame: CGRect(origin: CGPoint(x: 100, y: 100), size: size))
    }

    /// Shows guides and grids for the length of `body`, as they are when a design is opened.
    private func showing(_ body: () throws -> Void) rethrows {
        let h = Helpers.shared
        let was = (h.guides, h.grids)
        if !h.guides { h.guides = true }
        if !h.grids { h.grids = true }
        defer {
            if h.guides != was.0 { h.guides = was.0 }
            if h.grids != was.1 { h.grids = was.1 }
        }
        try body()
    }

    // MARK: Laying out

    @Test func columnsStretchBetweenTheMargins() {
        let grid = LayoutGrid(columns: .init(count: 12, gutter: 24, margin: 80))
        let columns = grid.columnRects(in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(columns.count == 12)
        #expect(columns.first?.minX == 80)
        #expect(abs((columns.last?.maxX ?? 0) - 1360) < 0.001)
        let width = (1440 - 160 - 24 * 11) / 12.0
        #expect(columns.allSatisfy { abs($0.width - width) < 0.001 && $0.height == 900 })
        #expect(abs(columns[1].minX - columns[0].maxX - 24) < 0.001)
    }

    @Test func columnsNeverGetNarrowerThanNothing() {
        let grid = LayoutGrid(columns: .init(count: 10, gutter: 100, margin: 400))
        #expect(grid.columnRects(in: CGRect(x: 0, y: 0, width: 600, height: 10)).allSatisfy { $0.width == 0 })
    }

    @Test func baselinesStepDownFromTheirOffset() {
        let lines = LayoutGrid.Baseline(step: 8, offset: 4).lines(along: 30)
        #expect(lines == [4, 12, 20, 28])
        #expect(LayoutGrid.Baseline(step: 8, offset: 20).lines(along: 20) == [4, 12, 20])
    }

    @Test func theSuggestedGridSuitsTheArtboard() {
        #expect(LayoutGrid.suggested(for: CGSize(width: 393, height: 852)).columns == .init(count: 4, gutter: 16, margin: 16))
        #expect(LayoutGrid.suggested(for: CGSize(width: 1080, height: 1080)).columns?.count == 8)
        #expect(LayoutGrid.suggested(for: CGSize(width: 1440, height: 1024)).columns == .init(count: 12, gutter: 24, margin: 80))
        // Rows make square fields with the columns.
        let c = LayoutGrid.Track(count: 4, gutter: 16, margin: 16)
        let rows = LayoutGrid.suggestedRows(for: CGSize(width: 393, height: 852), columns: c)
        let module = c.size(along: 393) + 16
        #expect(abs(rows.size(along: 852) + 16 - module) < module * 0.15)
    }

    @Test func aCarouselsGridRepeatsOnEverySlide() {
        var carousel = board(CGSize(width: 3240, height: 1350))
        carousel.slideSize = CGSize(width: 1080, height: 1350)
        carousel.layout = LayoutGrid(columns: .init(count: 4, gutter: 20, margin: 40))
        let areas = LayoutGrid.areas(of: carousel)
        #expect(areas.count == 3)
        let edges = carousel.layout!.edges(of: carousel).xs
        #expect(edges.count == 3 * 4 * 2)
        #expect(edges.contains(1080 + 40))
        #expect(edges.contains(3240 - 40))
    }

    @Test func aGridLeftWithNothingInItGoes() {
        var n = board()
        DocumentStore.changeLayout(of: &n) { $0.columns = .init(count: 3, gutter: -5, margin: 10.4) }
        #expect(n.layout?.columns == .init(count: 3, gutter: 0, margin: 10))
        DocumentStore.changeLayout(of: &n) { $0.columns = nil }
        #expect(n.layout == nil)
    }

    // MARK: Guides

    @Test func aGuideKeepsToTheEdgeItIsNearer() {
        let size = CGSize(width: 1440, height: 1024)
        let left = Guideline.at(100, vertical: true, in: size)
        let right = Guideline.at(1340, vertical: true, in: size)
        let middle = Guideline.at(720, vertical: true, in: size)
        #expect(left == Guideline(vertical: true, edge: .start, offset: 100))
        #expect(right == Guideline(vertical: true, edge: .end, offset: 100))
        #expect(middle.edge == .middle)
        // The artboard grows by 160: each stays where it keeps to.
        let wider = CGSize(width: 1600, height: 1024)
        #expect(left.position(in: wider) == 100)
        #expect(right.position(in: wider) == 1500)
        #expect(middle.position(in: wider) == 800)
        // An odd width's middle is on a half point.
        #expect(Guideline.at(187.5, vertical: true, in: CGSize(width: 375, height: 812)).edge == .middle)
    }

    @Test func guidesFollowTheirArtboardAsItIsResized() {
        let bench = Bench()
        let id = bench.a.id
        var key: String?
        bench.step { key = bench.store.addGuide(at: 380, vertical: true, to: id) }
        #expect(key != nil)
        bench.step { bench.store.update([id], "Resize") { $0.frame.size.width = 500 } }
        let guide = bench.store.node(id)?.guides?[key!]
        #expect(guide?.edge == .end)
        #expect(guide?.position(in: bench.store.node(id)!.frame.size) == 480)
    }

    @Test func addingMovingAndRemovingAGuideAreEachOneStep() throws {
        let bench = Bench()
        let id = bench.a.id
        var key: String?
        bench.step { key = bench.store.addGuide(at: 40, vertical: false, to: id) }
        let k = try #require(key)
        bench.step { bench.store.moveGuide(k, on: id, to: 260) }
        #expect(bench.store.node(id)?.guides?[k] == Guideline(vertical: false, edge: .end, offset: 40))
        bench.step { bench.store.removeGuide(k, from: id) }
        #expect(bench.store.node(id)?.guides == nil)
        bench.undoLast()
        #expect(bench.store.node(id)?.guides?[k]?.offset == 40)
        bench.undoLast()
        #expect(bench.store.node(id)?.guides?[k] == Guideline(vertical: false, edge: .start, offset: 40))
        bench.undoLast()
        #expect(bench.store.node(id)?.guides == nil)
    }

    @Test func aGuideIsTakenOverABackdropWhileACardItCentresKeepsThePress() throws {
        try showing {
            // A colour laid under the whole page, as on a cover, and a card in its middle.
            let bench = Bench(extra: [CanvasTests.rect("Backdrop", CGRect(x: 0, y: 0, width: 400, height: 300)),
                                      CanvasTests.rect("Card", CGRect(x: 150, y: 100, width: 100, height: 100))])
            let id = bench.a.id
            var key: String?
            bench.step { key = bench.store.addGuide(at: 200, vertical: true, to: id) }
            let k = try #require(key)
            // On the card, the press is the card's.
            bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 320, y: 250))
            #expect(bench.node("Card")?.frame.minX != 150)
            #expect(bench.store.node(id)?.guides?[k]?.position(in: bench.a.frame.size) == 200)
            // On the backdrop alone, the guide's.
            bench.drag(CGPoint(x: 300, y: 130), CGPoint(x: 440, y: 130))
            #expect(abs((bench.store.node(id)?.guides?[k]?.position(in: bench.a.frame.size) ?? 0) - 340) < 0.5)
            #expect(bench.node("Backdrop")?.frame.minX == 0)
        }
    }

    // MARK: Catching on them

    @Test func whatMovesCatchesOnGuidesAndColumns() {
        showing {
            var b = board(CGSize(width: 1200, height: 800))
            b.guides = ["g": Guideline(vertical: true, edge: .start, offset: 300)]
            b.layout = LayoutGrid(columns: .init(count: 4, gutter: 20, margin: 40))
            b.children = [CanvasTests.rect("Box", CGRect(x: 297, y: 500, width: 100, height: 50))]
            var doc = BezzleDocument()
            doc.nodes = [b]
            let box = b.children[0].id
            let targets = SnapTargets(doc: doc, moving: [box])
            // Its left edge 3 from the guide, at 400 on the canvas.
            let (shift, guides) = targets.snap(moving: CGRect(x: 397, y: 600, width: 100, height: 50), threshold: 5)
            #expect(shift.x == 3)
            #expect(guides.contains { $0.from.x == 400 && $0.to.x == 400 })
            // A column's edge: the first starts at 40.
            let (onColumn, _) = targets.snap(moving: CGRect(x: 138, y: 600, width: 50, height: 50), threshold: 5)
            #expect(onColumn.x == 2)
        }
    }

    @Test func aTextSitsOnTheBaselinesByItsFirstLine() {
        showing {
            var b = board(CGSize(width: 800, height: 800))
            b.layout = LayoutGrid(baseline: .init(step: 8, offset: 0))
            var text = Node(kind: .text, name: "Words", frame: CGRect(x: 40, y: 41, width: 200, height: 30))
            text.text = "Hello"
            text.style = TextStyle()
            text.refit()
            b.children = [text]
            var doc = BezzleDocument()
            doc.nodes = [b]
            let targets = SnapTargets(doc: doc, moving: [text.id])
            let first = TextLayout.firstBaseline(text)
            #expect(targets.firstBaseline == first)
            // Nowhere near any edge but a baseline a little off.
            let at = CGRect(x: 140, y: 100 + 203, width: text.frame.width, height: text.frame.height)
            let (shift, _) = targets.snap(moving: at, threshold: 4)
            let baseline = at.minY + shift.y + first - 100
            #expect(abs(baseline / 8 - (baseline / 8).rounded()) < 0.001)
            #expect(targets.sitsOnBaseline(at.offsetBy(dx: 0, dy: shift.y)))
        }
    }

    @Test func hiddenGuidesAreNotCaughtOn() {
        let h = Helpers.shared
        let was = h.guides
        h.guides = false
        defer { h.guides = was }
        var b = board(CGSize(width: 1200, height: 800))
        b.guides = ["g": Guideline(vertical: true, edge: .start, offset: 300)]
        b.children = [CanvasTests.rect("Box", CGRect(x: 297, y: 500, width: 100, height: 50))]
        var doc = BezzleDocument()
        doc.nodes = [b]
        let targets = SnapTargets(doc: doc, moving: [b.children[0].id])
        #expect(targets.snap(moving: CGRect(x: 397, y: 600, width: 100, height: 50), threshold: 5).0.x == 0)
    }

    @Test func controlCommaShowsAndHidesGuidesOnAnyKeyboard() throws {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == "Guides", item.keyEquivalent == "," { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        let item = try #require(find(NSApp.mainMenu))
        #expect(item.keyEquivalentModifierMask == .control)
        // Kept on the comma's own key, as the menus and the tour name it, wherever the keyboard has it.
        #expect(!item.allowsAutomaticKeyEquivalentLocalization)

        let h = Helpers.shared
        let was = h.guides
        defer { h.guides = was }
        func press(_ character: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 43))
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        }
        let before = h.guides
        #expect(try press(",", .control))
        #expect(h.guides != before)
        #expect(try press(",", .control))
        #expect(h.guides == before)
        // On a Swiss or German keyboard the same key with Shift is ";": that is not it.
        #expect(try !press(";", [.control, .shift]))
        #expect(h.guides == before)
    }

    // MARK: Working together

    /// One Mac's copy, kept as `Collaboration` keeps it but without iCloud.
    private struct Mac {
        let name: String
        var state = SharedDesign()
        var base = FlatDesign()
        var doc: BezzleDocument
        var time: Int64 = 1_000

        init(_ name: String, doc: BezzleDocument) {
            self.name = name
            self.doc = doc
            commit()
        }

        mutating func commit() {
            time += 1
            state.absorb(FlatDesign(doc), since: base, by: name, at: time)
            base = FlatDesign(doc)
        }

        mutating func edit(_ change: (inout BezzleDocument) -> Void) {
            change(&doc)
            commit()
        }

        mutating func receive(_ other: SharedDesign) {
            commit()
            state.merge(other)
            base = state.flatDesign()
            doc = base.document()
            commit()
        }
    }

    private func shared() -> (Mac, Mac, UUID) {
        var b = board()
        b.guides = ["first": Guideline(vertical: true, edge: .start, offset: 40)]
        b.layout = LayoutGrid(columns: .init(count: 12, gutter: 24, margin: 80))
        var doc = BezzleDocument()
        doc.nodes = [b]
        let a = Mac("a", doc: doc)
        var other = Mac("b", doc: BezzleDocument())
        other.receive(a.state)
        return (a, other, b.id)
    }

    @Test func aSharedDesignKeepsItsGuidesAndGrid() {
        let (a, b, id) = shared()
        #expect(b.doc.node(id)?.guides == a.doc.node(id)?.guides)
        #expect(b.doc.node(id)?.layout == a.doc.node(id)?.layout)
        // Each guide is shared as a property of its own.
        #expect(a.state.layers[id]?.fields["guides/first"] != nil)
        #expect(a.state.layers[id]?.fields["guides"] == nil)
    }

    @Test func twoPeopleAddingGuidesToOneArtboardBothKeepThem() {
        var (a, b, id) = shared()
        a.edit { $0.update(id) { $0.guides?["left"] = Guideline(vertical: true, edge: .start, offset: 80) } }
        b.edit { $0.update(id) { $0.guides?["right"] = Guideline(vertical: true, edge: .end, offset: 80) } }
        // Meanwhile one moves the guide they both had, and the other changes the grid.
        a.edit { $0.update(id) { $0.guides?["first"]?.offset = 64 } }
        b.edit { $0.update(id) { $0.layout?.columns?.count = 8 } }
        for _ in 0..<3 {
            a.receive(b.state)
            b.receive(a.state)
        }
        #expect(a.doc == b.doc)
        let guides = a.doc.node(id)?.guides
        #expect(Set(guides?.keys.map { $0 } ?? []) == ["first", "left", "right"])
        #expect(guides?["first"]?.offset == 64)
        #expect(a.doc.node(id)?.layout?.columns?.count == 8)
    }

    @Test func aGuideTakenAwayHereStaysAwayWhileOthersAddTheirs() {
        var (a, b, id) = shared()
        a.edit { $0.update(id) { $0.guides = nil } }
        b.edit { $0.update(id) { $0.guides?["more"] = Guideline(vertical: false, edge: .start, offset: 10) } }
        for _ in 0..<3 {
            a.receive(b.state)
            b.receive(a.state)
        }
        #expect(a.doc == b.doc)
        #expect(a.doc.node(id)?.guides == ["more": Guideline(vertical: false, edge: .start, offset: 10)])
    }

    @Test func undoTakesBackOnlyTheGuideAddedHere() {
        var b = board()
        b.guides = ["first": Guideline(vertical: true, edge: .start, offset: 40)]
        var before = BezzleDocument()
        before.nodes = [b]
        var after = before
        after.update(b.id) { $0.guides?["mine"] = Guideline(vertical: false, edge: .start, offset: 10) }
        // Meanwhile someone else added one and moved the first.
        var now = after
        now.update(b.id) {
            $0.guides?["theirs"] = Guideline(vertical: false, edge: .end, offset: 10)
            $0.guides?["first"]?.offset = 50
        }
        let undone = FlatDesign.apply(from: after, to: before, onto: now)
        let guides = undone.node(b.id)?.guides
        #expect(guides?["mine"] == nil)
        #expect(guides?["theirs"] != nil)
        #expect(guides?["first"]?.offset == 50)
    }

    // MARK: The assistant

    @Test func theAssistantLaysOutAnArtboardAndPutsGuidesOnIt() async {
        let bench = Bench()
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let laid = await call("layout_grid", ["layer": "A", "columns": 6, "column_gutter": 12, "column_margin": 20, "baseline": 4])
        #expect(!laid.failed, "\(laid.text)")
        #expect(bench.a.layout == LayoutGrid(columns: .init(count: 6, gutter: 12, margin: 20), baseline: .init(step: 4, offset: 0)))
        #expect(laid.text.contains("layoutGrid"))
        let fewer = await call("layout_grid", ["layer": "A", "columns": 0])
        #expect(!fewer.failed)
        #expect(bench.a.layout == LayoutGrid(baseline: .init(step: 4, offset: 0)))
        let wrong = await call("layout_grid", ["layer": "A", "columns": 99])
        #expect(wrong.failed)

        let added = await call("guides", ["layer": "A", "add": [["direction": "vertical", "at": 24, "from": "end"], ["direction": "horizontal", "at": 150]]])
        #expect(!added.failed, "\(added.text)")
        let guides = bench.a.guides ?? [:]
        #expect(guides.count == 2)
        #expect(guides.values.contains(Guideline(vertical: true, edge: .end, offset: 24)))
        #expect(guides.values.contains(Guideline(vertical: false, edge: .middle, offset: 0)))
        #expect(added.text.contains("\"keptTo\":\"right\""))
        let cleared = await call("guides", ["layer": "A", "remove": ["all"]])
        #expect(!cleared.failed)
        #expect(bench.a.guides == nil)
        MCPTools.closed(bench.store)
    }

    @Test func anArtboardsCopyKeepsItsGuidesAndGrid() {
        let bench = Bench()
        let id = bench.a.id
        bench.step { _ = bench.store.addGuide(at: 40, vertical: true, to: id) }
        bench.step { bench.store.addLayout(to: id) }
        bench.store.selection = [id]
        bench.step { bench.store.duplicateSelection() }
        let copy = bench.store.doc.artboards.first { $0.id != id && $0.name != "B" }
        #expect(copy?.guides?.count == 1)
        #expect(copy?.layout == bench.store.node(id)?.layout)
    }
}
