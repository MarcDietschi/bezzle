import Testing
import AppKit
@testable import Bezzle

/// Components played through every way they are used: made from all sorts of layers, copied every
/// way there is, changed in every property, placed, turned and flipped, laid out at other sizes,
/// given variants, linked, unlinked and deleted, held in grids, decks, masks and other components,
/// shared with others, undone and redone, driven by the assistant and drawn on the canvas. After
/// each step, `problems` checks everything that must always hold of a design with components.
@MainActor
struct ComponentSuiteTests {
    // MARK: - Benches

    /// A group "Button": a 120 × 40 rectangle "Shape" and the words in its middle, "Label".
    static func button(_ name: String = "Button", at p: CGPoint = CGPoint(x: 40, y: 40), label: String = "Button", width: CGFloat = 120) -> Node {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: p.x, y: p.y, width: width, height: 40))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 1)
        shape.cornerRadius = 8
        var words = Node(kind: .text, name: "Label", frame: .zero)
        words.text = label
        words.style?.size = 16
        words.style?.align = .center
        words.refit()
        words.frame.origin = CGPoint(x: (p.x + width / 2 - words.frame.width / 2).rounded(), y: (p.y + 20 - words.frame.height / 2).rounded())
        var g = Node(kind: .group, name: name, frame: .zero)
        g.children = [shape, words]
        return g
    }

    private func bench(_ extra: [Node]? = nil) -> Bench {
        let bench = Bench(extra: extra ?? [Self.button()])
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        bench.step { bench.store.edit("Fit") { $0.fitGroups() } }
        return bench
    }

    /// A component made of "Button", and `count` copies of it in all, each 60 points under the last.
    private func made(_ count: Int = 3) -> (Bench, UUID, [UUID]) {
        let bench = bench()
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        var copies = [bench.store.selection[0]]
        for _ in 1..<max(count, 1) {
            bench.store.selection = [copies.last!]
            bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 60)) }
            copies.append(bench.store.selection[0])
        }
        return (bench, bench.store.doc.masters[0].id, copies)
    }

    /// The layer of this name in a copy, however deep, but not in copies inside it.
    private func layer(_ name: String, in copy: UUID, _ bench: Bench) -> Node? {
        func find(_ nodes: [Node]) -> Node? {
            for n in nodes {
                if n.name == name { return n }
                if n.instance == nil, let f = find(n.children) { return f }
            }
            return nil
        }
        return bench.store.doc.node(copy).flatMap { find($0.children) }
    }

    private func frame(_ name: String, in copy: UUID, _ bench: Bench) -> CGRect? {
        layer(name, in: copy, bench).flatMap { bench.store.doc.absoluteFrame(of: $0.id) }
    }

    private func check(_ bench: Bench, _ what: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        for p in Self.problems(bench.store.doc) { Issue.record("\(what): \(p)", sourceLocation: sourceLocation) }
    }

    // MARK: - What always holds

    /// Everything that must hold of a design with components, as a list of what does not.
    static func problems(_ doc: BezzleDocument) -> [String] {
        var out: [String] = []
        let byID = doc.mastersByID
        func ids(_ ns: [Node], _ key: RepeatGrid.Key) -> [UUID] {
            ns.flatMap { [$0.id.mixed(key)] + ($0.instance == nil ? ids($0.children, key) : []) }
        }
        for m in doc.masters {
            if m.instance != nil { out.append("component \(m.name) is itself a copy") }
            guard let info = m.master else {
                out.append("component \(m.name) is not marked as one")
                continue
            }
            for p in Set(m.children.compactMap(\.post)) where !info.variants.contains(p) { out.append("\(m.name) holds layers of a variant it does not list") }
            for v in info.variants where !m.children.contains(where: { $0.post == v }) { out.append("\(m.name) lists a variant it holds nothing of") }
            let design = m.children.filter { $0.post == nil }
            if design.isEmpty { out.append("\(m.name) holds nothing") }
            for v in info.variants where ids(m.children.filter { $0.post == v }, Deck.key(v)) != ids(design, .none) {
                out.append("a variant of \(m.name) holds other layers than its first")
            }
            if doc.uses(m.id).contains(m.id) { out.append("\(m.name) holds a copy of itself") }
            func deep(_ n: Node) {
                if n.post != nil { out.append("a layer deep in \(m.name) is marked as in a variant") }
                n.children.forEach(deep)
            }
            m.children.forEach { $0.children.forEach(deep) }
        }
        if doc.nodes.contains(where: { $0.master != nil }) { out.append("a component lies on the canvas") }
        func visit(_ n: Node, in place: String) {
            if let inst = n.instance {
                guard let master = byID[inst.of] else {
                    out.append("\(place): copy \(n.name) of a component that is not there")
                    return
                }
                if !(inst.box.width > 0 && inst.box.height > 0 && inst.box.minX.isFinite && inst.box.minY.isFinite) {
                    out.append("\(place): copy \(n.name) has the box \(inst.box)")
                }
                if inst.variant != nil, Components.variant(inst.variant, of: master) == nil { out.append("\(place): copy \(n.name) shows a variant not there") }
                if let k = Components.key(of: n), ids(n.children, .none) != ids(Components.layers(of: master, variant: inst.variant), k) {
                    out.append("\(place): copy \(n.name) does not hold its component's layers")
                }
            }
            n.children.forEach { visit($0, in: place) }
        }
        doc.nodes.forEach { visit($0, in: "canvas") }
        for m in doc.masters { m.children.forEach { visit($0, in: m.name) } }
        // Made again from its component, a copy is as it is.
        func stable(_ n: Node) {
            if let inst = n.instance, let master = byID[inst.of] {
                var d = BezzleDocument()
                d.nodes = [Components.build(n, master: master, masterWas: nil, masters: byID)]
                d.fitGroups()
                if let why = differs(d.nodes[0], n) { out.append("copy \(n.name) is not as its component makes it: \(why)") }
                return
            }
            n.children.forEach(stable)
        }
        doc.nodes.forEach(stable)
        // Shared and taken back, the same.
        let again = FlatDesign(doc).document()
        if again.masters.count != doc.masters.count { out.append("components lost when shared") }
        for (a, b) in zip(again.masters, doc.masters) { if let why = differs(a, b) { out.append("component changed when shared: \(why)") } }
        if again.nodes.count != doc.nodes.count { out.append("layers lost when shared") }
        for (a, b) in zip(again.nodes, doc.nodes) { if let why = differs(a, b) { out.append("design changed when shared: \(why)") } }
        return out
    }

    /// Where two layers differ, but for frames a hair apart; nil when they do not.
    static func differs(_ a: Node, _ b: Node, at path: String = "") -> String? {
        let here = path + "/" + a.name
        if a.id != b.id { return "\(here) id" }
        for field in LayerField.all where !field.same(a, b) {
            if field.name == "frame", close(a.frame, b.frame) { continue }
            if field.name == "instance", let x = a.instance, let y = b.instance, x.of == y.of, x.variant == y.variant, close(x.box, y.box),
               abs((x.turn ?? 0) - (y.turn ?? 0)) < 0.01, x.flipX == y.flipX, x.flipY == y.flipY { continue }
            if field.name == "mask", a.mask?.count == b.mask?.count { continue }
            return "\(here).\(field.name): \(String(describing: field.name == "frame" ? a.frame : nil)) \(String(describing: field.name == "frame" ? b.frame : nil))"
        }
        guard a.children.count == b.children.count else { return "\(here) holds \(a.children.count) not \(b.children.count)" }
        for (x, y) in zip(a.children, b.children) { if let why = differs(x, y, at: here) { return why } }
        return nil
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.05 && abs(a.minY - b.minY) < 0.05 && abs(a.width - b.width) < 0.05 && abs(a.height - b.height) < 0.05
    }

    // MARK: - Making one

    @Test func everythingThatCanBeMadeAComponentIsAndNothingElse() {
        // One group, one layer alone, several layers.
        var lone = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 250, y: 40, width: 30, height: 30))
        lone.fill.color = .black
        let a = Node(kind: .rectangle, name: "Left", frame: CGRect(x: 40, y: 160, width: 30, height: 30))
        let b = Node(kind: .rectangle, name: "Right", frame: CGRect(x: 80, y: 160, width: 30, height: 30))
        let bench = bench([Self.button(), lone, a, b])
        for ids in [[bench.node("Button")!.id], [bench.node("Dot")!.id], [bench.node("Left")!.id, bench.node("Right")!.id]] {
            bench.store.selection = ids
            #expect(bench.store.canMakeComponent, "\(ids.compactMap { bench.store.doc.node($0)?.name }) locked \(ids.map { bench.store.doc.node($0)?.locked as Any }) inside \(ids.map { bench.store.doc.insideCopy($0) }) groupable \(DocumentStore.groupable(ids, in: bench.store.doc) != nil)")
            bench.step { bench.store.makeComponent() }
            #expect(bench.store.selectedCopy != nil)
        }
        #expect(bench.store.doc.masters.count == 3)
        #expect(bench.store.doc.masters.map(\.name).contains("Dot"))
        check(bench, "made")
        // Not an artboard, nor a copy, nor anything in one, nor anything locked.
        bench.store.selection = [bench.a.id]
        #expect(!bench.store.canMakeComponent)
        let copy = bench.store.doc.copies(of: bench.store.doc.masters[0].id)[0]
        bench.store.selection = [copy.id]
        #expect(!bench.store.canMakeComponent)
        bench.store.selection = [copy.children[0].id]
        #expect(!bench.store.canMakeComponent)
        bench.step { bench.store.setLocked(true, [copy.id]) }
        bench.store.selection = [copy.id]
        #expect(!bench.store.canMakeComponent)
        // Undone, each goes, the layers as they were.
        for _ in 0..<4 { bench.undoLast() }
        #expect(bench.store.doc.masters.isEmpty)
        #expect(bench.node("Dot")?.isCopy != true)
        check(bench, "undone")
    }

    @Test func madeInAPostOrACellEveryPostAndCellIsACopy() {
        // In a deck's post.
        let deck = bench()
        let a = deck.a.id
        deck.step { deck.store.addPost(to: a) }
        deck.step { deck.store.addPost(to: a) }
        let front = deck.store.front(of: deck.a)
        let button = deck.a.layers(of: front).first { $0.name == "Button" }!
        deck.store.selection = [button.id]
        deck.step { deck.store.makeComponent() }
        let master = deck.store.doc.masters[0].id
        #expect(deck.a.posts.allSatisfy { p in deck.a.layers(of: p).contains { $0.instance?.of == master } })
        #expect(deck.a.layers(of: nil).contains { $0.instance?.of == master })
        check(deck, "deck")
        // A change in the post behind reaches every post, and the component.
        let other = deck.a.posts.first { $0 != front }!
        let otherCopy = deck.a.layers(of: other).first { $0.isCopy }!
        let red = RGBA(r: 1, g: 0, b: 0)
        deck.step { deck.store.update([otherCopy.children[0].id], "Fill") { $0.fill.color = red } }
        #expect(deck.store.doc.masters[0].children[0].fill.color == red)
        #expect(deck.a.children.filter(\.isCopy).allSatisfy { $0.children[0].fill.color == red })
        check(deck, "deck changed")

        // In a repeat grid's cell, the grid's other cells too.
        let grid = bench()
        grid.store.selection = [grid.node("Button")!.id]
        grid.step { grid.store.makeRepeatGrid() }
        let g = grid.store.doc.allNodes.first(where: \.isRepeatGrid)!.id
        grid.step { grid.store.edit("Rows") { doc in doc.update(g) { $0.grid?.rows = 3 } } }
        let cell = grid.store.doc.node(g)!.children[2]
        grid.store.selection = [cell.id]
        grid.step { grid.store.makeComponent() }
        #expect(grid.store.doc.node(g)?.children.allSatisfy(\.isCopy) == true, "\(grid.store.doc.node(g)?.children.map { "\($0.name) \($0.isCopy) \($0.id)" } ?? []) selected \(cell.id)")
        check(grid, "grid")
    }

    // MARK: - Copies

    @Test func everyWayOfCopyingMakesCopies() {
        let (bench, master, copies) = made(1)
        let copy = copies[0]
        // Option-drag.
        let f = bench.store.doc.absoluteFrame(of: copy)!
        bench.store.selection = [copy]
        bench.drag(CGPoint(x: f.minX + 20, y: f.midY), CGPoint(x: f.minX + 20, y: f.midY + 100), flags: [.option, .command])
        #expect(bench.store.doc.copies(of: master).count == 2, "\(bench.a.children.map { "\($0.name) \($0.isCopy) \($0.children.count)" }) selected \(bench.store.selection.compactMap { bench.store.doc.node($0)?.name })")
        check(bench, "option-drag")
        // Copy and paste, and cut and paste.
        bench.store.selection = [copy]
        bench.store.copySelection()
        bench.step { bench.store.paste() }
        #expect(bench.store.doc.copies(of: master).count == 3)
        bench.store.selection = [bench.store.selection[0]]
        bench.store.copySelection()
        bench.step { bench.store.cutSelection() }
        bench.step { bench.store.paste() }
        #expect(bench.store.doc.copies(of: master).count == 3)
        #expect(bench.store.doc.masters.count == 1)
        check(bench, "pasted")
        // Every copy changes with the others.
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([bench.store.doc.copies(of: master)[0].children[0].id], "Fill") { $0.fill.color = red } }
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children[0].fill.color == red })
        // Into another design, twice: one component there, both copies of it.
        bench.store.selection = [copy]
        bench.store.copySelection()
        let other = Bench()
        other.step { other.store.paste() }
        other.step { other.store.paste() }
        #expect(other.store.doc.masters.count == 1)
        #expect(other.store.doc.copies(of: master).count == 2)
        check(other, "other design")
    }

    // MARK: - Every change reaches every copy

    @Test func everyKindOfChangeReachesEveryCopyAndUndoes() {
        let changes: [(String, String, (inout Node) -> Void, (Node) -> AnyHashable)] = [
            ("fill", "Shape", { $0.fill.color = RGBA(r: 1, g: 0, b: 0) }, { $0.fill.color }),
            ("border", "Shape", { $0.border = Border(on: true, color: .black, width: 3) }, { $0.border }),
            ("shadow", "Shape", { $0.shadow = Shadow(on: true, color: .shadow, x: 0, y: 4, blur: 8) }, { $0.shadow }),
            ("corners", "Shape", { $0.cornerRadius = 20 }, { $0.cornerRadius }),
            ("opacity", "Shape", { $0.opacity = 0.5 }, { $0.opacity }),
            ("blur", "Shape", { $0.blur = Blur(radius: 4) }, { $0.blur }),
            ("more fills", "Shape", { $0.moreFills = [Fill(color: RGBA(r: 0, g: 1, b: 0, a: 0.3))] }, { $0.moreFills }),
            ("type", "Label", { $0.style?.size = 20 }, { $0.style?.size }),
            ("letter colour", "Label", { $0.fill.color = .black }, { $0.fill.color }),
            ("name", "Label", { $0.name = "Title" }, { $0.name }),
            ("hidden", "Label", { $0.hidden = true }, { $0.hidden }),
            ("turn", "Shape", { $0.rotation = 10 }, { $0.rotation }),
            ("depth", "Shape", { $0.transform3D = Transform3D(x: 20, y: 0, z: 0) }, { $0.transform3D }),
        ]
        for (what, name, change, read) in changes {
            let (bench, _, copies) = made(3)
            let target = layer(name, in: copies[1], bench)!
            let before = read(target)
            bench.store.selection = [target.id]
            bench.step { bench.store.update([target.id], "Change") { change(&$0) } }
            let after = read(layer(what == "name" ? "Title" : name, in: copies[1], bench)!)
            #expect(after != before, "\(what) did not change")
            for c in copies {
                let l = layer(what == "name" ? "Title" : name, in: c, bench)
                #expect(l.map(read) == after, "\(what) did not reach every copy")
            }
            check(bench, what)
            bench.undoLast()
            for c in copies { #expect(layer(name, in: c, bench).map(read) == before, "\(what) not undone in every copy") }
            check(bench, "\(what) undone")
        }
    }

    @Test func layersPutInTakenOutRestackedAndGroupedInOneCopyAreSoInEvery() {
        let (bench, master, copies) = made(3)
        // A layer put into a copy.
        var dot = Node(kind: .ellipse, name: "Dot", frame: .zero)
        let f = bench.store.doc.absoluteFrame(of: copies[1])!
        dot.frame = CGRect(x: f.maxX - 14, y: f.minY + 4, width: 10, height: 10)
        bench.step { bench.store.edit("Add") { doc in doc.attach(dot, to: copies[1]) } }
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children.contains { $0.name == "Dot" } })
        check(bench, "put in")
        // Restacked.
        bench.store.selection = [layer("Dot", in: copies[0], bench)!.id]
        bench.step { bench.store.arrange(.back) }
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children.first?.name == "Dot" })
        check(bench, "restacked")
        // Grouped and ungrouped.
        bench.store.selection = [layer("Shape", in: copies[2], bench)!.id, layer("Label", in: copies[2], bench)!.id]
        bench.step { bench.store.group() }
        #expect(bench.store.doc.copies(of: master).allSatisfy { c in c.children.contains { $0.isGroup && $0.children.count == 2 } })
        check(bench, "grouped")
        bench.store.selection = [bench.store.doc.node(copies[0])!.children.first { $0.isGroup }!.id]
        bench.step { bench.store.ungroup() }
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children.count == 3 })
        check(bench, "ungrouped")
        // Taken out.
        bench.store.selection = [layer("Dot", in: copies[2], bench)!.id]
        bench.step { bench.store.deleteSelection() }
        #expect(bench.store.doc.copies(of: master).allSatisfy { !$0.children.contains { $0.name == "Dot" } })
        check(bench, "taken out")
        // Everything undone.
        for _ in 0..<5 { bench.undoLast() }
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children.map(\.name) == ["Shape", "Label"] })
        check(bench, "undone")
    }

    @Test func deletingACopyOrAllItHoldsLeavesTheOthers() {
        let (bench, master, copies) = made(3)
        bench.store.selection = [copies[0]]
        bench.step { bench.store.deleteSelection() }
        #expect(bench.store.doc.copies(of: master).count == 2)
        // Everything in one copy at once: that copy goes, the component and the others stay whole.
        bench.store.selection = bench.store.doc.node(copies[1])!.children.map(\.id)
        bench.step { bench.store.deleteSelection() }
        #expect(bench.store.doc.node(copies[1]) == nil)
        #expect(bench.store.doc.node(copies[2])?.children.count == 2)
        #expect(Components.layers(of: bench.store.doc.master(master)!, variant: nil).count == 2)
        check(bench, "deleted")
    }

    // MARK: - What a copy keeps of its own

    @Test func wordsPicturesAndWhatAOneCopyKeepsStayItsOwn() {
        let (bench, _, copies) = made(3)
        let label = layer("Label", in: copies[1], bench)!
        bench.store.selection = [label.id]
        bench.step { bench.store.update([label.id], "Type") { $0.text = "Send" } }
        #expect(layer("Label", in: copies[0], bench)?.text == "Button")
        // The component's own words were changed: offered to every copy, and given.
        guard let offer = bench.store.componentOffer, case .kept = offer.kind else {
            Issue.record("No offer to give the words to every copy")
            return
        }
        bench.step { bench.store.take(offer, .everywhere) }
        #expect(copies.allSatisfy { layer("Label", in: $0, bench)?.text == "Send" })
        // Words of its own already: no offer.
        let third = layer("Label", in: copies[2], bench)!
        bench.step { bench.store.update([third.id], "Type") { $0.text = "Cancel" } }
        bench.store.selection = [layer("Label", in: copies[2], bench)!.id]
        bench.step { bench.store.update([layer("Label", in: copies[2], bench)!.id], "Type") { $0.text = "Cancel now" } }
        #expect(bench.store.componentOffer == nil)
        // A picture is its own.
        let pic = ImageFill(asset: "x.png", size: CGSize(width: 10, height: 10))
        bench.step { bench.store.update([layer("Shape", in: copies[0], bench)!.id], "Picture") { $0.fill.image = pic } }
        #expect(layer("Shape", in: copies[0], bench)?.fill.image == pic)
        #expect(layer("Shape", in: copies[1], bench)?.fill.image == nil)
        check(bench, "own content")
        // Kept in one copy, followed again, reset.
        let shape = layer("Shape", in: copies[1], bench)!
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Corners") { $0.cornerRadius = 2 } }
        guard let reached = bench.store.componentOffer, case .reached = reached.kind else {
            Issue.record("No offer after a change every copy followed")
            return
        }
        bench.step { bench.store.take(reached, .onlyHere) }
        #expect(layer("Shape", in: copies[1], bench)?.cornerRadius == 2)
        #expect(layer("Shape", in: copies[0], bench)?.cornerRadius == 8)
        check(bench, "kept in one")
        bench.step { bench.store.followComponent([layer("Shape", in: copies[1], bench)!.id]) }
        #expect(layer("Shape", in: copies[1], bench)?.cornerRadius == 8)
        check(bench, "followed")
        // The offer goes once the copy is left.
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Corners") { $0.cornerRadius = 4 } }
        #expect(!bench.canvas.componentTool.places.offer.isEmpty)
        bench.store.selection = []
        #expect(bench.canvas.componentTool.places.offer.isEmpty)
    }

    // MARK: - Where a copy lies, how big, how turned

    @Test func aCopyMovedResizedTurnedAndFlippedKeepsThatOfItsOwn() {
        let (bench, master, copies) = made(2)
        let red = RGBA(r: 1, g: 0, b: 0)
        // Moved.
        bench.store.selection = [copies[1]]
        bench.step { bench.store.nudge(dx: 30, dy: 0) }
        #expect(Components.box(of: bench.store.doc.master(master)!, variant: nil).width == 120)
        check(bench, "moved")
        // Resized from the inspector's way of doing it, and from the assistant's.
        bench.step {
            bench.store.edit("Resize") { doc in
                doc.update(copies[1]) { n in
                    let old = n.frame.size
                    n.frame.size = CGSize(width: 200, height: 50)
                    n.children = BezzleDocument.scaled(n.children, from: old, to: n.frame.size)
                }
            }
        }
        #expect(abs(frame("Shape", in: copies[1], bench)!.width - 200) < 0.6)
        #expect(abs(frame("Shape", in: copies[1], bench)!.height - 50) < 0.6)
        #expect(layer("Label", in: copies[1], bench)?.style?.size == 16)
        check(bench, "resized")
        // Turned by the canvas's handle.
        let f = bench.store.doc.absoluteFrame(of: copies[1])!
        bench.store.selection = [copies[1]]
        let c = f.center, corner = CGPoint(x: f.maxX + 8, y: f.maxY + 8)
        let r = hypot(corner.x - c.x, corner.y - c.y), a0 = atan2(corner.y - c.y, corner.x - c.x)
        let a1 = a0 + .pi / 6
        bench.drag(corner, CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1)))
        let turn = bench.store.doc.node(copies[1])?.instance?.turn ?? 0
        #expect(abs(turn) > 5, "turned \(turn)")
        check(bench, "turned")
        // The component changed: the turned and resized copy stays so.
        bench.step { bench.store.update([layer("Shape", in: copies[0], bench)!.id], "Fill") { $0.fill.color = red } }
        #expect(layer("Shape", in: copies[1], bench)?.fill.color == red)
        #expect(abs((layer("Shape", in: copies[1], bench)?.rotation ?? 0) - turn) < 0.01)
        #expect(abs((bench.store.doc.node(copies[1])?.instance?.box.width ?? 0) - 200) < 0.6)
        check(bench, "changed while turned")
        // Flipped both ways.
        bench.store.selection = [copies[1]]
        bench.step { bench.store.flip(horizontally: true) }
        bench.step { bench.store.flip(horizontally: false) }
        check(bench, "flipped")
        bench.step { bench.store.update([layer("Shape", in: copies[0], bench)!.id], "Corners") { $0.cornerRadius = 14 } }
        #expect(layer("Shape", in: copies[1], bench)?.cornerRadius == 14)
        check(bench, "changed while flipped")
        // All of it undone.
        for _ in 0..<7 { bench.undoLast() }
        #expect(bench.store.doc.node(copies[1])?.instance?.turn == nil)
        check(bench, "undone")
    }

    @Test func aTurnedCopyResizedOnTheCanvasStaysTurned() {
        let (bench, _, copies) = made(2)
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(copies[1])!
                doc.update(copies[1]) { $0 = BezzleDocument.turned($0, by: 20, about: n.frame.center) }
            }
        }
        bench.store.selection = [copies[1]]
        bench.step {
            bench.store.edit("Resize") { doc in
                let n = doc.node(copies[1])!
                let (box, turn) = BezzleDocument.turnedBox(of: n)
                doc.update(copies[1]) { $0 = BezzleDocument.scaled(n, turned: turn, from: box, to: CGRect(origin: box.origin, size: CGSize(width: box.width + 60, height: box.height))) }
            }
        }
        let inst = bench.store.doc.node(copies[1])?.instance
        #expect(abs((inst?.turn ?? 0) - 20) < 0.01)
        #expect(abs((inst?.box.width ?? 0) - 180) < 1)
        check(bench, "turned and resized")
    }

    // MARK: - Laid out at other sizes

    @Test func aBarLaidOutWiderKeepsItsPartsWhereTheyBelong() {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        back.fill.color = .white
        let left = Node(kind: .rectangle, name: "Left", frame: CGRect(x: 8, y: 10, width: 24, height: 24))
        let right = Node(kind: .rectangle, name: "Right", frame: CGRect(x: 358, y: 10, width: 24, height: 24))
        var title = Node(kind: .text, name: "Title", frame: .zero)
        title.text = "Title"
        title.style?.size = 17
        title.refit()
        title.frame.origin = CGPoint(x: 195 - title.frame.width / 2, y: 22 - title.frame.height / 2)
        let tabs = (0..<4).map { i -> Node in
            let cx = [49.0, 146.0, 244.0, 341.0][i]
            return Node(kind: .ellipse, name: "Tab \(i)", frame: CGRect(x: cx - 12, y: 54, width: 24, height: 24))
        }
        var bar = Node(kind: .group, name: "Bar", frame: .zero)
        bar.children = [back, left, right, title] + tabs
        let bench = bench([bar])
        bench.store.selection = [bench.node("Bar")!.id]
        bench.step { bench.store.makeComponent() }
        let copy = bench.store.selection[0]
        bench.step {
            bench.store.edit("Wider") { doc in
                doc.update(copy) { n in
                    let old = n.frame.size
                    n.frame.size.width = 780
                    n.children = BezzleDocument.scaled(n.children, from: old, to: n.frame.size)
                }
            }
        }
        let o = bench.store.doc.absoluteFrame(of: copy)!
        func f(_ name: String) -> CGRect { frame(name, in: copy, bench)!.offsetBy(dx: -o.minX, dy: -o.minY) }
        #expect(abs(f("Back").width - 780) < 0.6)
        #expect(abs(f("Left").minX - 8) < 0.6)
        #expect(abs(f("Right").maxX - 772) < 0.6)
        #expect(abs(f("Title").midX - 390) < 0.6)
        #expect(abs(f("Title").width - title.frame.width) < 0.6)
        #expect(abs(f("Tab 1").midX - 292) < 1)
        #expect(abs(f("Tab 2").midX - 488) < 1)
        check(bench, "bar")
    }

    @Test func wordsLongerOrShorterGrowOrShrinkTheirShape() {
        let (bench, _, copies) = made(2)
        let label = layer("Label", in: copies[1], bench)!
        bench.step { bench.store.update([label.id], "Type") { $0.text = "OK" } }
        #expect(frame("Shape", in: copies[1], bench)!.width < 100)
        bench.step { bench.store.update([layer("Label", in: copies[1], bench)!.id], "Type") { $0.text = "A label far longer than before" } }
        let shape = frame("Shape", in: copies[1], bench)!, words = frame("Label", in: copies[1], bench)!
        #expect(shape.width > words.width + 40)
        #expect(abs(shape.midX - words.midX) < 0.6)
        check(bench, "words")
        // Words over several lines make a card taller.
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 40, y: 40, width: 240, height: 100))
        back.fill.color = .white
        var body = Node(kind: .text, name: "Body", frame: CGRect(x: 60, y: 60, width: 200, height: 0))
        body.text = "Two lines of words, about as long as this."
        body.style?.size = 16
        body.style?.sizing = .autoHeight
        body.refit()
        var card = Node(kind: .group, name: "Card", frame: .zero)
        card.children = [back, body]
        let cards = self.bench([card])
        cards.store.selection = [cards.node("Card")!.id]
        cards.step { cards.store.makeComponent() }
        cards.step { cards.store.duplicateSelection(offset: CGPoint(x: 0, y: 160)) }
        let second = cards.store.selection[0]
        let before = frame("Back", in: second, cards)!
        cards.step { cards.store.update([layer("Body", in: second, cards)!.id], "Type") { $0.text = String(repeating: "Many more words than fit on two lines. ", count: 4) } }
        #expect(frame("Back", in: second, cards)!.height > before.height + 20)
        check(cards, "card")
    }

    // MARK: - Variants

    @Test func variantsAreMadeShownRenamedAndTakenAway() {
        let (bench, master, copies) = made(3)
        bench.store.selection = [copies[1]]
        bench.step { bench.store.addVariant() }
        let v = bench.store.doc.master(master)!.master!.variants[0]
        let shape = layer("Shape", in: copies[1], bench)!
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = .black } }
        bench.step { bench.store.renameVariant(v, of: master, to: "Dark") }
        #expect(Components.name(of: v, in: bench.store.doc.master(master)!) == "Dark")
        check(bench, "named")
        // Shown in another copy, with its words.
        bench.step { bench.store.update([layer("Label", in: copies[2], bench)!.id], "Type") { $0.text = "Mine" } }
        bench.step { bench.store.setVariant(v, for: [copies[2]]) }
        #expect(layer("Shape", in: copies[2], bench)?.fill.color == .black)
        #expect(layer("Label", in: copies[2], bench)?.text == "Mine")
        check(bench, "shown")
        // A variant of another size: copies of it grow and shrink as they turn into it.
        let wide = layer("Shape", in: copies[1], bench)!
        bench.store.selection = [wide.id]
        bench.step { bench.store.update([wide.id], "Wider") { $0.frame.size.width = 160 } }
        // As much room round its own words as the variant's copies have round theirs.
        func room(_ c: UUID) -> CGFloat { frame("Shape", in: c, bench)!.width - frame("Label", in: c, bench)!.width }
        #expect(abs(frame("Shape", in: copies[1], bench)!.width - 160) < 0.6)
        #expect(abs(room(copies[2]) - room(copies[1])) < 0.6)
        bench.step { bench.store.setVariant(nil, for: [copies[2]]) }
        #expect(abs(room(copies[2]) - room(copies[0])) < 0.6)
        check(bench, "sizes")
        // Taken away: its copies show the first.
        bench.step { bench.store.removeVariant(v, of: master) }
        #expect(bench.store.doc.node(copies[1])?.instance?.variant == nil)
        #expect(layer("Shape", in: copies[1], bench)?.fill.color != .black)
        check(bench, "taken away")
        for _ in 0..<8 { bench.undoLast() }
        #expect(bench.store.doc.master(master)?.master?.variants.isEmpty == true)
        check(bench, "undone")
    }

    // MARK: - Look-alikes and kits

    @Test func lookAlikesOfOtherWordsAndSizesAreLinkedAsTheyAre() {
        let bench = bench([Self.button(), Self.button("Other", at: CGPoint(x: 40, y: 140), label: "A much longer label", width: 220)])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        guard let offer = bench.store.componentOffer, case .lookAlikes(_, let found) = offer.kind else {
            Issue.record("No look-alikes")
            return
        }
        #expect(found.count == 1)
        let before = bench.store.doc.absoluteFrame(of: found[0])!
        bench.step { bench.store.take(offer, .link) }
        let master = bench.store.doc.masters[0].id
        let other = bench.store.doc.copies(of: master).first { $0.children[1].text == "A much longer label" }!
        #expect(Self.close(bench.store.doc.absoluteFrame(of: other.id)!, before))
        check(bench, "linked")
        // A change to the component leaves it as wide as it was.
        bench.step { bench.store.update([bench.store.doc.copies(of: master)[0].children[0].id], "Corners") { $0.cornerRadius = 3 } }
        #expect(abs(bench.store.doc.absoluteFrame(of: other.id)!.width - before.width) < 0.6)
        check(bench, "changed")
    }

    @Test func kitPartsAreComponentsLightAndDark() async {
        let bench = bench()
        var ids: [UUID?] = []
        for p in [CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 300)] {
            bench.step { ids.append(bench.store.place(.component("bezzle.primary-button"), at: p)) }
        }
        #expect(bench.store.doc.masters.count == 1)
        bench.step { bench.store.update([bench.b.id], "Dark") { $0.fill.color = RGBA(r: 0.05, g: 0.05, b: 0.05) } }
        bench.step { _ = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 800, y: 200)) }
        bench.step { _ = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 800, y: 300)) }
        #expect(bench.store.doc.masters.count == 2)
        // The assistant's way.
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        _ = await tools.call("add_resource", ["design": bench.store.name, "resource": "bezzle.primary-button", "artboard": "A"])
        #expect(bench.store.doc.masters.count == 2)
        #expect(bench.store.doc.copies(of: bench.store.doc.masters[0].id).count == 3)
        check(bench, "kits")
    }

    // MARK: - Unlinking and deleting

    @Test func unlinkedAndDeletedComponentsLeaveGroupsThatLookTheSame() {
        let (bench, master, copies) = made(3)
        let look = bench.store.doc.node(copies[0])!
        bench.store.selection = [copies[0]]
        bench.step { bench.store.unlinkComponent() }
        #expect(bench.store.doc.node(copies[0])?.isCopy == false)
        #expect(bench.store.doc.node(copies[0])?.children.map(\.frame) == look.children.map(\.frame))
        check(bench, "unlinked")
        bench.step { bench.store.deleteComponent(master) }
        #expect(bench.store.doc.masters.isEmpty)
        #expect(copies.dropFirst().allSatisfy { bench.store.doc.node($0)?.isCopy == false })
        check(bench, "deleted")
        bench.undoLast()
        #expect(copies.dropFirst().allSatisfy { bench.store.doc.node($0)?.isCopy == true })
        check(bench, "undone")
    }

    // MARK: - Components in components

    /// A button component, and a card component holding one of its copies, with a second card.
    private func cards() -> (Bench, button: UUID, card: UUID, cards: [UUID]) {
        var back = Node(kind: .rectangle, name: "Card back", frame: CGRect(x: 30, y: 30, width: 260, height: 120))
        back.fill.color = .white
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 46, y: 46, width: 0, height: 0))
        title.text = "Card"
        title.refit()
        let bench = bench([back, title, Self.button(at: CGPoint(x: 46, y: 96))])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let buttonCopy = bench.store.selection[0], button = bench.store.doc.masters[0].id
        bench.store.selection = [bench.node("Card back")!.id, bench.node("Title")!.id, buttonCopy]
        bench.step { bench.store.makeComponent() }
        let first = bench.store.selection[0], card = bench.store.doc.node(first)!.instance!.of
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 140)) }
        return (bench, button, card, [first, bench.store.selection[0]])
    }

    private func nested(in card: UUID, _ bench: Bench) -> Node? { bench.store.doc.node(card)?.children.first(where: \.isCopy) }

    @Test func aButtonInACardIsStillThatButton() {
        let (bench, button, card, cards) = cards()
        #expect(bench.store.doc.master(card).map { $0.children.contains { $0.instance?.of == button } } == true)
        #expect(cards.allSatisfy { nested(in: $0, bench)?.instance?.of == button })
        check(bench, "made")
        // A loose button too.
        bench.step { bench.store.place(.design(button), at: CGPoint(x: 400, y: 330)) }
        let loose = bench.store.selection[0]
        // A change to a button in one card reaches every button, in cards or not.
        let red = RGBA(r: 1, g: 0, b: 0)
        let inner = nested(in: cards[1], bench)!.children[0]
        bench.store.selection = [inner.id]
        bench.step { bench.store.update([inner.id], "Fill") { $0.fill.color = red } }
        #expect(cards.allSatisfy { nested(in: $0, bench)?.children[0].fill.color == red })
        #expect(bench.store.doc.node(loose)?.children[0].fill.color == red)
        #expect(bench.store.doc.master(button)?.children[0].fill.color == red)
        check(bench, "button changed")
        // A change to the card reaches every card and no button.
        let back = layer("Card back", in: cards[0], bench)!
        bench.step { bench.store.update([back.id], "Fill") { $0.fill.color = RGBA(r: 0.9, g: 0.9, b: 0.8) } }
        #expect(layer("Card back", in: cards[1], bench)?.fill.color == RGBA(r: 0.9, g: 0.9, b: 0.8))
        #expect(bench.store.doc.node(loose)?.children[0].fill.color == red)
        check(bench, "card changed")
        // Words in a card's button are that card's.
        let words = nested(in: cards[1], bench)!.children[1]
        bench.step { bench.store.update([words.id], "Type") { $0.text = "Read more" } }
        #expect(nested(in: cards[1], bench)?.children[1].text == "Read more")
        #expect(nested(in: cards[0], bench)?.children[1].text == "Button")
        check(bench, "words")
        // Where the button lies in the card is the card's.
        let moved = nested(in: cards[0], bench)!
        bench.store.selection = [moved.id]
        bench.step { bench.store.nudge(dx: 20, dy: 0) }
        let o0 = bench.store.doc.absoluteFrame(of: cards[0])!, o1 = bench.store.doc.absoluteFrame(of: cards[1])!
        let b0 = bench.store.doc.absoluteFrame(of: nested(in: cards[0], bench)!.id)!, b1 = bench.store.doc.absoluteFrame(of: nested(in: cards[1], bench)!.id)!
        // By their middles: the other card's button is wider round its own words, about its middle.
        #expect(abs((b0.midX - o0.minX) - (b1.midX - o1.minX)) < 0.6)
        check(bench, "moved in the card")
        // The card's button shows a variant: in every card.
        bench.store.selection = [loose]
        bench.step { bench.store.addVariant() }
        let v = bench.store.doc.master(button)!.master!.variants[0]
        bench.step { bench.store.setVariant(v, for: [nested(in: cards[0], bench)!.id]) }
        #expect(cards.allSatisfy { nested(in: $0, bench)?.instance?.variant == v })
        check(bench, "variant in the card")
        // Undone, every step.
        for _ in 0..<7 { bench.undoLast() }
        check(bench, "undone")
    }

    @Test func aCardStretchedStretchesTheButtonSpanningIt() {
        var back = Node(kind: .rectangle, name: "Card back", frame: CGRect(x: 30, y: 30, width: 260, height: 120))
        back.fill.color = .white
        let bench = bench([back, Self.button(at: CGPoint(x: 46, y: 96), width: 228)])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let buttonCopy = bench.store.selection[0]
        bench.store.selection = [bench.node("Card back")!.id, buttonCopy]
        bench.step { bench.store.makeComponent() }
        let card = bench.store.selection[0]
        bench.step {
            bench.store.edit("Wider") { doc in
                doc.update(card) { n in
                    let old = n.frame.size
                    n.frame.size.width = 400
                    n.children = BezzleDocument.scaled(n.children, from: old, to: n.frame.size)
                }
            }
        }
        let inner = nested(in: card, bench)!
        #expect(abs(inner.children[0].frame.width - 368) < 1)
        #expect(abs((inner.instance?.box.width ?? 0) - 368) < 1)
        check(bench, "stretched")
    }

    @Test func aTurnedCardKeepsItsButtonsTurned() {
        let (bench, _, _, cards) = cards()
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(cards[1])!
                doc.update(cards[1]) { $0 = BezzleDocument.turned($0, by: 30, about: n.frame.center) }
            }
        }
        check(bench, "turned")
        let inner = nested(in: cards[0], bench)!.children[0]
        bench.step { bench.store.update([inner.id], "Corners") { $0.cornerRadius = 2 } }
        let turned = nested(in: cards[1], bench)!
        #expect(abs(turned.children[0].rotation - 30) < 0.01)
        #expect(turned.children[0].cornerRadius == 2)
        check(bench, "changed while turned")
    }

    @Test func unlinkingADeletingAndPuttingACardInItsOwnButtonKeepItSound() {
        let (bench, button, card, cards) = cards()
        // A card unlinked keeps its button a button.
        bench.store.selection = [cards[0]]
        bench.step { bench.store.unlinkComponent() }
        #expect(nested(in: cards[0], bench)?.instance?.of == button)
        check(bench, "unlinked")
        // A card put inside a button: no button holds a card that holds buttons.
        bench.step { bench.store.place(.design(button), at: CGPoint(x: 400, y: 330)) }
        let loose = bench.store.selection[0]
        bench.step {
            bench.store.edit("Into") { doc in
                guard let c = doc.detach(cards[1]) else { return }
                doc.attach(c, to: loose)
            }
        }
        #expect(!bench.store.doc.uses(button).contains(button))
        check(bench, "card in a button")
        bench.undoLast()
        // The button component deleted: every button, in cards too, a group like any other.
        bench.step { bench.store.deleteComponent(button) }
        #expect(bench.store.doc.master(card)?.children.contains(where: \.isCopy) == false)
        #expect(nested(in: cards[1], bench) == nil)
        check(bench, "button deleted")
    }

    @Test func aCardCopiedIntoAnotherDesignBringsItsButton() {
        let (bench, button, card, cards) = cards()
        bench.store.selection = [cards[0]]
        bench.store.copySelection()
        let other = Bench()
        other.step { other.store.paste() }
        #expect(Set(other.store.doc.masters.map(\.id)) == [button, card])
        check(other, "pasted")
    }

    // MARK: - Shared with others

    @Test func changesMadeOnTwoMacsAtOnceAreBothKept() {
        let (bench, master, copies) = made(3)
        let base = bench.store.doc
        // Here: the fill of one copy, which reaches every copy.
        bench.step { bench.store.update([layer("Shape", in: copies[0], bench)!.id], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        let mine = bench.store.doc
        // There, at the same time: the corners of another.
        let there = Bench()
        there.step { there.store.edit("Same") { $0 = base } }
        there.step { there.store.update([layer("Shape", in: copies[2], there)!.id], "Corners") { $0.cornerRadius = 19 } }
        var merged = FlatDesign.apply(from: base, to: there.store.doc, onto: mine)
        merged.reconcileComponents()
        merged.fitGroups()
        for c in merged.copies(of: master) {
            #expect(c.children[0].fill.color == RGBA(r: 1, g: 0, b: 0))
            #expect(c.children[0].cornerRadius == 19)
        }
        #expect(Self.problems(merged).isEmpty, "\(Self.problems(merged))")
        // There, a copy added while here a layer was put in every copy: the new one gets it too.
        let added = Bench()
        added.step { added.store.edit("Same") { $0 = base } }
        added.store.selection = [copies[0]]
        added.step { added.store.duplicateSelection(offset: CGPoint(x: 0, y: 200)) }
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 150, y: 150, width: 8, height: 8))
        dot.fill.color = .black
        bench.step { bench.store.edit("Add") { doc in doc.attach(dot, to: copies[1]) } }
        var both = FlatDesign.apply(from: base, to: added.store.doc, onto: bench.store.doc)
        both.reconcileComponents()
        both.fitGroups()
        #expect(both.copies(of: master).count == 4)
        #expect(both.copies(of: master).allSatisfy { $0.children.contains { $0.name == "Dot" } })
        #expect(Self.problems(both).isEmpty, "\(Self.problems(both))")
        // There, the component deleted while here a copy was changed: its copies are groups.
        let gone = Bench()
        gone.step { gone.store.edit("Same") { $0 = base } }
        gone.step { gone.store.deleteComponent(master) }
        var after = FlatDesign.apply(from: base, to: gone.store.doc, onto: bench.store.doc)
        after.repairComponents()
        after.reconcileComponents()
        #expect(after.masters.isEmpty)
        #expect(after.allNodes.allSatisfy { !$0.isCopy })
    }

    // MARK: - A long session

    @Test func aLongSessionUndoesAndRedoesExactly() {
        let (bench, master, _) = made(3)
        var rng = SystemRandomNumberGenerator()
        let start = bench.store.doc
        var states = [start]
        for i in 0..<24 {
            let copies = bench.store.doc.copies(of: master)
            guard let copy = copies.randomElement(using: &rng) else { break }
            switch i % 8 {
            case 0: bench.step { bench.store.update([copy.children[0].id], "Fill") { $0.fill.color = RGBA(r: Double(i) / 24, g: 0.3, b: 0.5) } }
            case 1: bench.store.selection = [copy.id]; bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 10, y: 10)) }
            case 2: bench.step { bench.store.update([copy.children[1].id], "Type") { $0.text = "Words \(i)" } }
            case 3: bench.store.selection = [copy.id]; bench.step { bench.store.nudge(dx: 5, dy: 3) }
            case 4:
                bench.step {
                    bench.store.edit("Resize") { doc in
                        doc.update(copy.id) { n in
                            let old = n.frame.size
                            n.frame.size.width += 20
                            n.children = BezzleDocument.scaled(n.children, from: old, to: n.frame.size)
                        }
                    }
                }
            case 5: bench.store.selection = [copy.id]; bench.step { bench.store.addVariant() }
            case 6: bench.step { bench.store.setVariant(nil, for: [copy.id]) }
            default: bench.store.selection = [copy.id]; bench.step { bench.store.flip(horizontally: true) }
            }
            check(bench, "step \(i)")
            states.append(bench.store.doc)
        }
        for i in stride(from: states.count - 2, through: 0, by: -1) {
            bench.undoLast()
            if Self.differs(BezzleDocument.wrap(bench.store.doc), BezzleDocument.wrap(states[i])) != nil || bench.store.doc.masters != states[i].masters {
                Issue.record("Undo to step \(i) is not as it was")
                break
            }
        }
        check(bench, "all undone")
        for _ in 1..<states.count { bench.undo.redo() }
        #expect(bench.store.doc.copies(of: master).count == states.last!.copies(of: master).count)
        check(bench, "all redone")
    }

    // MARK: - Held in other things

    @Test func copiesInMasksAndMasksInComponentsWork() {
        // A mask inside a component.
        var shape = Node(kind: .ellipse, name: "Hole", frame: CGRect(x: 40, y: 40, width: 80, height: 80))
        shape.fill.color = .white
        let inside = Node(kind: .rectangle, name: "Inside", frame: CGRect(x: 30, y: 30, width: 120, height: 60))
        let bench = bench([shape, inside])
        bench.store.selection = [bench.node("Hole")!.id, bench.node("Inside")!.id]
        bench.step { bench.store.maskSelection() }
        let mask = bench.store.selection[0]
        bench.store.selection = [mask]
        bench.step { bench.store.makeComponent() }
        let copy = bench.store.selection[0]
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 150, y: 0)) }
        let other = bench.store.selection[0]
        #expect(bench.store.doc.node(other)?.children.first?.isMask == true)
        check(bench, "mask in component")
        let held = bench.store.doc.node(copy)!.children[0].children[1]
        bench.step { bench.store.update([held.id], "Fill") { $0.fill.color = RGBA(r: 0, g: 0.5, b: 0) } }
        #expect(bench.store.doc.node(other)?.children[0].children[1].fill.color == RGBA(r: 0, g: 0.5, b: 0))
        check(bench, "changed in the mask")
    }

    // MARK: - The assistant

    @Test func theAssistantDoesAllOfItAndSaysWhatIsWrong() async {
        let bench = bench()
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func call(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
            var a = args
            a["design"] = bench.store.name
            let r = await tools.call(name, a)
            let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any]
            let text = (o?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            return (text, o?["isError"] as? Bool == true)
        }
        var (text, failed) = await call("make_component", ["layers": ["A"]])
        #expect(failed, "an artboard made a component: \(text)")
        (text, failed) = await call("make_component", ["layers": ["Button"], "name": "Pill"])
        #expect(!failed, "\(text)")
        let master = bench.store.doc.masters[0].id
        (text, failed) = await call("add_copy", ["component": "Pill", "artboard": "B", "x": 10, "y": 10, "width": 200])
        #expect(!failed, "\(text)")
        (text, failed) = await call("add_copy", ["component": "Nothing"])
        #expect(failed)
        let copies = bench.store.doc.copies(of: master)
        (text, failed) = await call("add_variant", ["layer": copies[1].id.uuidString, "name": "Quiet"])
        #expect(!failed, "\(text)")
        (text, failed) = await call("set_variant", ["layers": [copies[0].id.uuidString], "variant": "quiet"])
        #expect(!failed, "\(text)")
        (text, failed) = await call("set_variant", ["layers": [copies[0].id.uuidString], "variant": "Loud"])
        #expect(failed)
        (text, failed) = await call("update_component", ["component": "Pill", "variant": "Quiet", "variant_name": "Calm"])
        #expect(!failed && text.contains("Calm"), "\(text)")
        let shape = bench.store.doc.node(copies[0].id)!.children[0].id.uuidString
        (text, failed) = await call("keep_in_copy", ["layers": [shape], "properties": ["fill"]])
        #expect(!failed, "\(text)")
        (text, failed) = await call("keep_in_copy", ["layers": [copies[0].id.uuidString], "properties": ["fill"]])
        #expect(failed)
        (text, failed) = await call("keep_in_copy", ["layers": [shape], "properties": ["nonsense"]])
        #expect(failed)
        (text, failed) = await call("list_components", [:])
        #expect(text.contains("Pill") && text.contains("Calm"))
        (text, failed) = await call("unlink_copies", ["layers": [copies[1].id.uuidString]])
        #expect(!failed)
        (text, failed) = await call("update_component", ["component": "Pill", "variant": "Calm", "remove_variant": true])
        #expect(!failed)
        check(bench, "assistant")
        (text, failed) = await call("delete_component", ["component": "Pill"])
        #expect(!failed && bench.store.doc.masters.isEmpty)
        check(bench, "deleted")
    }

    // MARK: - The canvas

    @Test func theCanvasDrawsEveryStateAndItsButtonsWork() {
        let (bench, master, copies) = made(3)
        let tool = bench.canvas.componentTool
        func draw() {
            let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 800)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            tool.draw(ctx, scale: 1, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
            NSGraphicsContext.restoreGraphicsState()
        }
        // A change spreading: lit copies and ghosts.
        bench.store.selection = [layer("Shape", in: copies[0], bench)!.id]
        bench.step { bench.store.update([layer("Shape", in: copies[0], bench)!.id], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        draw()
        #expect(tool.lights.lit == 2)
        #expect(tool.lights.ghosts == 2)
        // The word offered, and its first button pressed.
        let offer = tool.places.offer
        #expect(offer.count == 2)
        var pressed = false
        if let first = offer.first { bench.step { pressed = tool.down(at: CGPoint(x: first.midX, y: first.midY)) } }
        #expect(pressed)
        #expect(layer("Shape", in: copies[1], bench)?.fill.color != RGBA(r: 1, g: 0, b: 0))
        draw()
        // A variant, so the row shows; pointing at a card shows it on the canvas, pressing it shows it.
        bench.store.selection = [copies[2]]
        bench.step { bench.store.addVariant() }
        bench.step { bench.store.update([layer("Shape", in: copies[2], bench)!.id], "Fill") { $0.fill.color = .black } }
        bench.store.selection = [copies[1]]
        let places = tool.places
        #expect(places.cards.count == 2)
        guard places.cards.count == 2, let add = places.add else { return }
        tool.hover(CGPoint(x: places.cards[1].midX, y: places.cards[1].midY))
        #expect(bench.store.preview != nil)
        #expect(bench.store.shownDoc.node(copies[1]).flatMap { layer("Shape", inDoc: $0) }?.fill.color == .black)
        draw()
        bench.step { _ = tool.down(at: CGPoint(x: places.cards[1].midX, y: places.cards[1].midY)) }
        #expect(bench.store.doc.node(copies[1])?.instance?.variant == bench.store.doc.master(master)?.master?.variants.first)
        #expect(bench.store.preview == nil)
        // The round button makes another.
        bench.step { _ = tool.down(at: CGPoint(x: add.midX, y: add.midY)) }
        #expect(bench.store.doc.master(master)?.master?.variants.count == 2)
        draw()
        check(bench, "canvas")
    }

    private func layer(_ name: String, inDoc copy: Node) -> Node? { copy.children.first { $0.name == name } }

    /// The pointer resting on the last card of the row of variants as the row grows shorter
    /// under it, a variant undone: the row is drawn with the cards it has, naming none (it broke
    /// off naming the card the pointer had rested on).
    @Test func theRowDrawnAfterTheCardUnderThePointerWentBreaksNothing() {
        let (bench, master, copies) = made(1)
        let tool = bench.canvas.componentTool
        func draw() {
            let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 800)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            tool.draw(ctx, scale: 1, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
            NSGraphicsContext.restoreGraphicsState()
        }
        bench.store.selection = [copies[0]]
        bench.step { bench.store.addVariant() }
        bench.step { bench.store.addVariant() }
        let cards = tool.places.cards
        #expect(cards.count == 3)
        guard let last = cards.last else { return }
        tool.hover(CGPoint(x: last.midX, y: last.midY))
        draw()
        bench.undo.undo()
        #expect(bench.store.doc.master(master)?.master?.variants.count == 1)
        bench.store.selection = [copies[0]]
        #expect(tool.places.cards.count == 2)
        draw()
    }

    // MARK: - Files

    @Test func aDesignWithComponentsIsSavedAndReadBack() throws {
        let (cardsBench, _, _, _) = cards()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("components-\(UUID().uuidString).bezzle")
        try DesignFile.write(cardsBench.store.doc, to: url)
        let back = try DesignFile.read(url)
        #expect(back.masters == cardsBench.store.doc.masters)
        #expect(back.nodes == cardsBench.store.doc.nodes)
        #expect(Self.problems(back).isEmpty)
        // An old file, with no components, reads as it did.
        var plain = BezzleDocument()
        plain.nodes = [Node(kind: .artboard, frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let old = try JSONEncoder().encode(plain)
        #expect(String(decoding: old, as: UTF8.self).contains("components") == false)
        #expect(try JSONDecoder().decode(BezzleDocument.self, from: old).masters.isEmpty)
    }

    // MARK: - More of what copies do

    @Test func lettersRestyledInOneCopyAreRestyledWhereTheWordsAreTheSame() {
        let (bench, _, copies) = made(3)
        bench.step { bench.store.update([layer("Label", in: copies[2], bench)!.id], "Type") { $0.text = "Other" } }
        let label = layer("Label", in: copies[0], bench)!
        // "But" set in bold, in the first copy's words.
        var look = TextLook.plain
        look.face = "Bold"
        let spans = TextSpan.stored(TextSpan.runs("Button", Array(repeating: look, count: 3) + Array(repeating: .plain, count: 3)))
        bench.step { bench.store.update([label.id], "Bold") { $0.spans = spans } }
        #expect(layer("Label", in: copies[1], bench)?.spans == spans)
        #expect(layer("Label", in: copies[2], bench)?.text == "Other")
        check(bench, "letters")
    }

    @Test func aDesignWithCopiesGoesOutAsItShows() throws {
        let (bench, _, copies) = made(2)
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(copies[1])!
                doc.update(copies[1]) { $0 = BezzleDocument.turned($0, by: 15, about: n.frame.center) }
            }
        }
        let item = ExportItem(artboard: bench.a)
        let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: nil), assets: nil)
        #expect(svg.contains("<svg"))
        #expect(svg.contains("rotate("))
        #expect(Renderer.image(of: bench.a, scale: 1) != nil)
    }

    @Test func groupsHoldingCopiesThatLookTheSameAreLinkedToo() {
        let (bench, button, card, cards) = cards()
        // A card unlinked looks like a card, its button still a button: linked again as one.
        bench.store.selection = [cards[1]]
        bench.step { bench.store.unlinkComponent() }
        #expect(DocumentStore.lookAlikes(of: cards[0], in: bench.store.doc) == [cards[1]])
        bench.step { bench.store.link([cards[1]], to: card) }
        #expect(bench.store.doc.copies(of: card).count == 2)
        #expect(bench.store.doc.copies(of: button).count == 2)
        check(bench, "linked")
    }

    @Test func aTurnedAndFlippedCopyShownAsAnotherVariantStaysTurnedAndFlipped() {
        let (bench, master, copies) = made(2)
        bench.store.selection = [copies[1]]
        bench.step { bench.store.addVariant() }
        bench.step { bench.store.update([layer("Shape", in: copies[1], bench)!.id], "Fill") { $0.fill.color = .black } }
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(copies[0])!
                doc.update(copies[0]) { $0 = BezzleDocument.turned($0, by: 25, about: n.frame.center) }
            }
        }
        bench.store.selection = [copies[0]]
        bench.step { bench.store.flip(horizontally: true) }
        let v = bench.store.doc.master(master)!.master!.variants[0]
        bench.step { bench.store.setVariant(v, for: [copies[0]]) }
        let inst = bench.store.doc.node(copies[0])!.instance!
        #expect(abs((inst.turn ?? 0) + 25) < 0.01)
        #expect(inst.flipX == true)
        #expect(layer("Shape", in: copies[0], bench)?.fill.color == .black)
        check(bench, "turned variant")
    }

    @Test func aCopyOfAVariantPastedIntoAnotherDesignShowsItThere() {
        let (bench, master, copies) = made(2)
        bench.store.selection = [copies[1]]
        bench.step { bench.store.addVariant() }
        bench.step { bench.store.update([layer("Shape", in: copies[1], bench)!.id], "Fill") { $0.fill.color = .black } }
        bench.store.selection = [copies[1]]
        bench.store.copySelection()
        let other = Bench()
        other.step { other.store.paste() }
        let pasted = other.store.doc.node(other.store.selection[0])!
        #expect(pasted.instance?.variant == bench.store.doc.master(master)?.master?.variants.first)
        #expect(pasted.children[0].fill.color == .black)
        check(other, "pasted variant")
    }

    @Test func theAssistantIsToldWhatACopyIs() async {
        let (bench, _, copies) = made(2)
        bench.step { bench.store.keepInCopy([layer("Shape", in: copies[0], bench)!.id: ["fill"]], copy: copies[0], before: bench.store.doc) }
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let r = await tools.call("get_layers", ["design": bench.store.name, "layers": [copies[0].uuidString]])
        #expect(String(decoding: r.data, as: UTF8.self).contains("component"))
        let shape = layer("Shape", in: copies[0], bench)!.id.uuidString
        let inner = await tools.call("get_layers", ["design": bench.store.name, "layers": [shape]])
        #expect(String(decoding: inner.data, as: UTF8.self).contains("onlyInThisCopy"))
    }

    // MARK: - Turning, as the user found it

    /// Three copies of a kit's part, which holds its layers in a group of their own.
    private func kitCopies() -> (Bench, [UUID]) {
        let bench = bench([])
        var ids: [UUID] = []
        for y in [160.0, 230.0, 300.0] {
            bench.step { if let id = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 220, y: y)) { ids.append(id) } }
        }
        return (bench, ids)
    }

    @Test func aTurnedKitPartIsSelectedRoundWhatItShows() {
        let (bench, ids) = kitCopies()
        let size = bench.store.doc.node(ids[1])!.frame.size
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(ids[1])!
                doc.update(ids[1]) { $0 = BezzleDocument.turned($0, by: 30, about: n.frame.center) }
            }
        }
        let (box, turn) = BezzleDocument.turnedBox(of: bench.store.doc.node(ids[1])!)
        #expect(abs(turn - 30) < 0.01)
        #expect(abs(box.width - size.width) < 0.6 && abs(box.height - size.height) < 0.6, "the handles go round \(box.size), not \(size)")
        check(bench, "turned kit part")
    }

    @Test func aCopyTurnedLightsNothingAndLeavesNoGhost() {
        let (bench, ids) = kitCopies()
        bench.store.selection = [ids[1]]
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(ids[1])!
                doc.update(ids[1]) { $0 = BezzleDocument.turned($0, by: 45, about: n.frame.center) }
            }
        }
        #expect(bench.store.componentEcho?.echo.to.isEmpty ?? true)
        let tool = bench.canvas.componentTool
        let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        tool.draw(ctx, scale: 1, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        NSGraphicsContext.restoreGraphicsState()
        #expect(tool.lights.lit == 0 && tool.lights.ghosts == 0)
        #expect(bench.store.componentOffer == nil)
    }

    @Test func aTurnedKitPartStretchedAlongItsTurnGrowsAlongIt() {
        let (bench, ids) = kitCopies()
        bench.step {
            bench.store.edit("Rotate") { doc in
                let n = doc.node(ids[1])!
                doc.update(ids[1]) { $0 = BezzleDocument.turned($0, by: 30, about: n.frame.center) }
            }
        }
        let width = bench.store.doc.node(ids[1])!.instance!.box.width
        bench.step {
            bench.store.edit("Resize") { doc in
                let n = doc.node(ids[1])!
                let (box, turn) = BezzleDocument.turnedBox(of: n)
                doc.update(ids[1]) { $0 = BezzleDocument.scaled(n, turned: turn, from: box, to: CGRect(origin: box.origin, size: CGSize(width: box.width + 30, height: box.height))) }
            }
        }
        let copy = bench.store.doc.node(ids[1])!
        #expect(abs((copy.instance?.turn ?? 0) - 30) < 0.01)
        #expect(abs((copy.instance?.box.width ?? 0) - (width + 30)) < 0.6)
        let back = copy.children[0].children.first { $0.name == "Background" }
        #expect(abs((back?.frame.width ?? 0) - (width + 30)) < 0.6)
        #expect(abs((back?.rotation ?? 0) - 30) < 0.01)
        // The others as they were.
        #expect(bench.store.doc.node(ids[0])?.instance?.turn == nil)
        check(bench, "stretched along its turn")
    }

    @Test func aCopyTurnedTwiceOnTheCanvasTurnsByBoth() {
        let (bench, ids) = kitCopies()
        func turnByHandle(_ degrees: Double) {
            let n = bench.store.doc.node(ids[1])!
            let (box, turn) = BezzleDocument.turnedBox(of: n)
            let o = bench.store.doc.parentOrigin(of: ids[1])
            let c = CGPoint(x: box.midX + o.x, y: box.midY + o.y)
            let corner = Geometry.point(CGPoint(x: 1, y: 1), of: box.offsetBy(dx: o.x, dy: o.y), rotation: turn)
            // Out past the corner, clear of its square handle, which resizes.
            let out = CGPoint(x: corner.x + (corner.x - c.x) / hypot(corner.x - c.x, corner.y - c.y) * 13,
                              y: corner.y + (corner.y - c.y) / hypot(corner.x - c.x, corner.y - c.y) * 13)
            let r = hypot(out.x - c.x, out.y - c.y), a = atan2(out.y - c.y, out.x - c.x) + degrees * .pi / 180
            bench.store.selection = [ids[1]]
            bench.drag(out, CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        turnByHandle(30)
        let first = bench.store.doc.node(ids[1])!.instance?.turn ?? 0
        turnByHandle(40)
        let second = bench.store.doc.node(ids[1])!.instance?.turn ?? 0
        #expect(abs(first) > 10, "turned \(first)")
        #expect(abs(second - first) > 10, "turned again by \(second - first)")
        let (box, turn) = BezzleDocument.turnedBox(of: bench.store.doc.node(ids[1])!)
        #expect(abs(turn - second) < 0.6 || abs(abs(turn - second) - 90) < 0.6 || abs(abs(turn - second) - 180) < 0.6)
        #expect(abs(box.width * box.height - bench.store.doc.node(ids[0])!.frame.width * bench.store.doc.node(ids[0])!.frame.height) < 2)
        check(bench, "turned twice")
    }

    /// A ring as the wedding vows have it: two circles and a numeral in the middle.
    static func ring(at p: CGPoint) -> Node {
        var outer = Node(kind: .ellipse, name: "Ring aussen", frame: CGRect(x: p.x, y: p.y, width: 84, height: 84))
        outer.fill.on = false
        outer.border = Border(on: true, color: RGBA(r: 0.6, g: 0.5, b: 0.3), width: 1.5)
        var inner = Node(kind: .ellipse, name: "Ring innen", frame: CGRect(x: p.x + 3.5, y: p.y + 3.5, width: 77, height: 77))
        inner.fill.on = false
        inner.border = Border(on: true, color: RGBA(r: 0.6, g: 0.5, b: 0.3), width: 0.5)
        var numeral = Node(kind: .text, name: "Ziffer", frame: CGRect(x: p.x, y: p.y + 23.5, width: 84, height: 34))
        numeral.text = "II"
        numeral.style?.size = 28
        numeral.style?.align = .center
        numeral.style?.sizing = .autoHeight
        numeral.refit()
        numeral.frame.origin.y = p.y + 42 - numeral.frame.height / 2
        var g = Node(kind: .group, name: "Ring", frame: .zero)
        g.children = [outer, inner, numeral]
        return g
    }

    /// Turns a layer by its corner on the canvas, as a person does, by about `degrees`.
    private func turnByHandle(_ id: UUID, _ degrees: Double, _ bench: Bench) {
        let n = bench.store.doc.node(id)!
        let (box, turn) = BezzleDocument.turnedBox(of: n)
        let o = bench.store.doc.parentOrigin(of: id)
        let c = CGPoint(x: box.midX + o.x, y: box.midY + o.y)
        let corner = Geometry.point(CGPoint(x: 1, y: 1), of: box.offsetBy(dx: o.x, dy: o.y), rotation: turn)
        let l = hypot(corner.x - c.x, corner.y - c.y)
        let out = CGPoint(x: corner.x + (corner.x - c.x) / l * 13, y: corner.y + (corner.y - c.y) / l * 13)
        let r = hypot(out.x - c.x, out.y - c.y), a = atan2(out.y - c.y, out.x - c.x) + degrees * .pi / 180
        bench.store.selection = [id]
        bench.drag(out, CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
    }

    /// Where the middle of a copy's first layer is on the canvas.
    private func middle(_ id: UUID, _ bench: Bench) -> CGPoint {
        let first = bench.store.doc.node(id)!.children[0]
        return bench.store.doc.absoluteFrame(of: first.id)!.center
    }

    @Test func aRingTurnedStaysWhereItIsLooseInAGroupAndInAStack() {
        for place in ["loose", "group", "stack"] {
            let bench = bench([Self.ring(at: CGPoint(x: 60, y: 60)), Self.ring(at: CGPoint(x: 60, y: 60)),
                               Node(kind: .rectangle, name: "Title", frame: CGRect(x: 180, y: 70, width: 160, height: 30))])
            let rings = bench.a.children.filter { $0.name == "Ring" }.map(\.id)
            bench.store.selection = [rings[0]]
            bench.step { bench.store.makeComponent() }
            let master = bench.store.doc.masters[0].id
            bench.step { bench.store.link([rings[1]], to: master) }
            var copies = bench.store.doc.copies(of: master).map(\.id)
            if place != "loose" {
                bench.store.selection = copies + [bench.node("Title")!.id]
                bench.step { bench.store.group() }
            }
            if place == "stack" {
                let a = bench.a.id
                bench.step { bench.store.addPost(to: a) }
                let front = bench.store.front(of: bench.a)
                copies = bench.store.doc.copies(of: master).filter { bench.store.doc.post(of: $0.id)?.post == front }.map(\.id)
            }
            let start = middle(copies.last!, bench), other = middle(copies.first!, bench)
            turnByHandle(copies.last!, 40, bench)
            let turned = bench.store.doc.node(copies.last!)!
            #expect(abs((turned.instance?.turn ?? 0) - 40) < 3, "\(place): turned \(String(describing: turned.instance?.turn))")
            let now = middle(copies.last!, bench), otherNow = middle(copies.first!, bench)
            #expect(hypot(now.x - start.x, now.y - start.y) < 0.6, "\(place): the turned ring moved from \(start) to \(now)")
            #expect(hypot(otherNow.x - other.x, otherNow.y - other.y) < 0.6, "\(place): the other ring moved from \(other) to \(otherNow)")
            turnByHandle(copies.last!, 30, bench)
            let again = middle(copies.last!, bench)
            #expect(hypot(again.x - start.x, again.y - start.y) < 0.6, "\(place): turned again, it moved to \(again)")
            check(bench, place)
        }
    }

    /// The same for a group that is no copy: a stack carries a turn from the post in front to the
    /// others and to the design behind them, the group and what it holds moved at once.
    @Test func aPlainGroupTurnedInAStackStaysWhereItIs() {
        for place in ["loose", "group"] {
            let bench = bench([Self.ring(at: CGPoint(x: 60, y: 60)), Node(kind: .rectangle, name: "Title", frame: CGRect(x: 180, y: 70, width: 160, height: 30))])
            if place == "group" {
                bench.store.selection = [bench.node("Ring")!.id, bench.node("Title")!.id]
                bench.step { bench.store.group() }
            }
            let a = bench.a.id
            bench.step { bench.store.addPost(to: a) }
            let front = bench.store.front(of: bench.a)
            let ring = bench.store.doc.allNodes.first { $0.name == "Ring" && bench.store.doc.post(of: $0.id)?.post == front }!.id
            let start = middle(ring, bench)
            turnByHandle(ring, 40, bench)
            #expect(abs((bench.store.doc.node(ring)!.children[0].rotation) - 40) < 3, "\(place): turned \(bench.store.doc.node(ring)!.children[0].rotation)")
            let now = middle(ring, bench)
            #expect(hypot(now.x - start.x, now.y - start.y) < 0.6, "\(place): the turned ring moved from \(start) to \(now)")
            turnByHandle(ring, 30, bench)
            let again = middle(ring, bench)
            #expect(hypot(again.x - start.x, again.y - start.y) < 0.6, "\(place): turned again, it moved to \(again)")
            // Every post and the design behind them turned alike, in the same place.
            for other in bench.store.doc.allNodes where other.name == "Ring" {
                let m = middle(other.id, bench)
                #expect(hypot(m.x - start.x, m.y - start.y) < 0.6, "\(place): a ring in post \(String(describing: bench.store.doc.post(of: other.id)?.post)) lies at \(m)")
            }
            check(bench, place)
        }
    }

    // MARK: - Many copies

    @Test func fortyCopiesChangeAtOnceQuickly() {
        let (bench, master, _) = made(40)
        #expect(bench.store.doc.copies(of: master).count == 40)
        let shape = bench.store.doc.copies(of: master)[7].children[0].id
        let t = CACurrentMediaTime()
        bench.step { bench.store.update([shape], "Fill") { $0.fill.color = RGBA(r: 0, g: 0.6, b: 0.3) } }
        let took = CACurrentMediaTime() - t
        #expect(took < 0.5, "40 copies took \(took) s")
        #expect(bench.store.doc.copies(of: master).allSatisfy { $0.children[0].fill.color == RGBA(r: 0, g: 0.6, b: 0.3) })
        check(bench, "forty")
    }
}

private extension BezzleDocument {
    /// The whole design as one group, to compare two at once.
    static func wrap(_ doc: BezzleDocument) -> Node {
        var n = Node(kind: .group, name: "Design", frame: .zero)
        n.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        n.children = doc.nodes
        return n
    }
}
