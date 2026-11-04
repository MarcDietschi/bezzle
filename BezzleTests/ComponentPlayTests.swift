import Testing
import AppKit
@testable import Bezzle

/// Components played with as a person plays with them the first time: buttons of every kind made
/// into components and dropped from the kits, resized by their handles on the canvas (whole, or
/// only the shape in one), from every side and corner, with Shift and Option, in many small steps
/// and back again; resized in the inspector and by the assistant; and typed into on the canvas,
/// letter by letter, deleted, retyped, over two lines, in copies that were resized, turned, shown
/// as a variant or held in a card. After each step, what must hold is checked: the copy changed
/// is as it should be, every other copy is exactly as it was (or changed exactly as much, when the
/// component was changed), nothing grows past any size, and `ComponentSuiteTests.problems` finds
/// nothing wrong with the design.
@MainActor
struct ComponentPlayTests {
    // MARK: - Rigs

    /// A design with three copies of one component, as a test plays with them.
    struct Rig {
        let bench: Bench
        let master: UUID
        var copies: [UUID]
        /// What the words are called in each copy, and what lies round them.
        let label: String
        let shape: String
        /// How the words stay put in their shape as they grow: their left, middle or right.
        let align: TextAlign
        let name: String
        /// Whether its shape grows round its words, as a button's does, or stays as wide as it is,
        /// as a field's much wider than its words.
        var hugs = true
    }

    /// A shape with words in it, grouped, as someone makes a button before making it a component.
    static func button(_ name: String = "Button", at p: CGPoint = CGPoint(x: 40, y: 40), label: String = "Button", width: CGFloat = 120,
                       height: CGFloat = 40, align: TextAlign = .center, icon: Bool = false, sizing: TextSizing = .autoWidth) -> Node {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: p.x, y: p.y, width: width, height: height))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 1)
        shape.cornerRadius = 8
        var words = Node(kind: .text, name: "Label", frame: .zero)
        words.text = label
        words.style?.size = 16
        words.style?.align = align
        words.style?.sizing = sizing
        let inset: CGFloat = icon ? 38 : 16
        if sizing != .autoWidth { words.frame = CGRect(x: p.x + 16, y: p.y, width: width - 32, height: 20) }
        words.refit()
        let y = (p.y + height / 2 - words.frame.height / 2).rounded()
        switch (sizing, align) {
        case (.autoWidth, .center): words.frame.origin = CGPoint(x: (p.x + width / 2 - words.frame.width / 2).rounded(), y: y)
        case (.autoWidth, .right): words.frame.origin = CGPoint(x: p.x + width - 16 - words.frame.width, y: y)
        case (.autoWidth, _): words.frame.origin = CGPoint(x: p.x + inset, y: y)
        default: words.frame.origin = CGPoint(x: p.x + 16, y: y)
        }
        var g = Node(kind: .group, name: name, frame: .zero)
        g.children = [shape, words]
        if icon {
            var dot = Node(kind: .ellipse, name: "Icon", frame: CGRect(x: p.x + 14, y: p.y + height / 2 - 8, width: 16, height: 16))
            dot.fill.color = .white
            g.children.append(dot)
        }
        return g
    }

    /// A button whose words are aligned left, as text is unless told otherwise, and put in the
    /// middle of their shape by hand.
    static func handCentred() -> Node {
        var b = button(width: 140, align: .left)
        let shape = b.children[0].frame
        b.children[1].frame.origin.x = (shape.midX - b.children[1].frame.width / 2).rounded()
        return b
    }

    private static func bench(_ extra: [Node]) -> Bench {
        let bench = Bench(extra: extra)
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        bench.step { bench.store.edit("Fit") { $0.fitGroups() } }
        return bench
    }

    /// A button made a component, and copied twice, each copy 60 points under the last.
    static func made(_ button: Node, name: String, align: TextAlign = .center) -> Rig {
        let bench = bench([button])
        bench.store.selection = [bench.node(button.name)!.id]
        bench.step { bench.store.makeComponent() }
        var copies = [bench.store.selection[0]]
        for _ in 0..<2 {
            bench.store.selection = [copies.last!]
            bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 60)) }
            copies.append(bench.store.selection[0])
        }
        bench.store.selection = []
        return Rig(bench: bench, master: bench.store.doc.masters[0].id, copies: copies, label: "Label", shape: "Shape", align: align, name: name)
    }

    /// Three copies of a part of a kit, dropped from the resources.
    static func kit(_ part: String, align: TextAlign = .left, hugs: Bool = true) -> Rig {
        let bench = bench([])
        var ids: [UUID] = []
        for y in [160.0, 230.0, 300.0] {
            bench.step { if let id = bench.store.place(.component(part), at: CGPoint(x: 260, y: y)) { ids.append(id) } }
        }
        bench.store.selection = []
        guard !bench.store.doc.masters.isEmpty else {
            Issue.record("\(part) made no component")
            return Rig(bench: bench, master: UUID(), copies: [], label: "", shape: "", align: align, name: part)
        }
        return Rig(bench: bench, master: bench.store.doc.masters[0].id, copies: ids, label: "Label", shape: "Background", align: align, name: part, hugs: hugs)
    }

    /// The tour's three pill buttons, each with words of its own, one component as the tour makes it:
    /// made of the first, the others linked to it as they are.
    static func tour() -> Rig {
        var made: [Node] = []
        for (i, label) in ["Continue", "Save", "Share"].enumerated() {
            var text = Node(kind: .text, name: "Label", frame: .zero)
            text.text = label
            text.style = TextStyle(face: "Semibold", size: 16, align: .center)
            text.fill.color = .white
            text.refit()
            let w = max(140, (text.frame.width + 64).rounded())
            var pill = Node(kind: .rectangle, name: "Pill", frame: CGRect(x: 40, y: 20 + CGFloat(i) * 76, width: w, height: 48))
            pill.fill.color = RGBA(r: 0.2, g: 0.35, b: 0.8)
            pill.cornerRadius = 24
            pill.shadow = Shadow(on: true, color: RGBA(r: 0.2, g: 0.27, b: 0.6, a: 0.22), x: 0, y: 6, blur: 14)
            text.frame.origin = CGPoint(x: (pill.frame.midX - text.frame.width / 2).rounded(), y: (pill.frame.midY - text.frame.height / 2).rounded())
            var button = Node(kind: .group, name: "Pill button \(i)", frame: .zero)
            button.children = [pill, text]
            made.append(button)
        }
        let bench = bench(made)
        let ids = (0..<3).map { bench.node("Pill button \($0)")!.id }
        var master: UUID?
        bench.step {
            bench.store.edit("Tour") { doc in
                guard let first = DocumentStore.makeComponent(from: [ids[0]], in: &doc, name: "Pill button"),
                      let m = doc.node(first)?.instance?.of else { return }
                doc.fitGroups()
                for id in ids.dropFirst() { _ = DocumentStore.link(id, to: m, in: &doc) }
                master = m
            }
        }
        let copies = bench.store.doc.copies(of: master!).map(\.id)
        return Rig(bench: bench, master: master!, copies: copies, label: "Label", shape: "Pill", align: .center, name: "tour")
    }

    /// Every kind of button there is to play with, each a fresh design.
    static func everyButton() -> [Rig] {
        [made(button(), name: "centred"),
         made(button(width: 160, align: .left), name: "left", align: .left),
         made(button(width: 160, align: .right), name: "right", align: .right),
         made(button(width: 150, align: .left, icon: true), name: "icon", align: .left),
         made(button(height: 48), name: "tall"),
         made(handCentred(), name: "hand-centred", align: .center),
         tour(),
         kit("bezzle.primary-button"),
         kit("bezzle.secondary-button"),
         kit("ios.button-prominent", align: .center, hugs: false)]
            .filter { !$0.copies.isEmpty }
    }

    // MARK: - Looking

    /// The layer of this name in a copy, however deep, but not in copies inside it.
    static func layer(_ name: String, in copy: UUID, _ doc: BezzleDocument) -> Node? {
        func find(_ nodes: [Node]) -> Node? {
            for n in nodes {
                if n.name == name { return n }
                if n.instance == nil, let f = find(n.children) { return f }
            }
            return nil
        }
        return doc.node(copy).flatMap { find($0.children) }
    }

    static func frame(_ name: String, in copy: UUID, _ doc: BezzleDocument) -> CGRect? {
        layer(name, in: copy, doc).flatMap { doc.absoluteFrame(of: $0.id) }
    }

    /// Where every layer of a copy lies on the canvas, by the names of the layers down to it, so a
    /// copy shown as another variant, whose layers are others, is still compared layer by layer.
    static func frames(of copy: UUID, _ doc: BezzleDocument) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        func visit(_ n: Node, _ path: String) {
            var key = path + "/" + n.name
            while out[key] != nil { key += "'" }
            out[key] = doc.absoluteFrame(of: n.id)
            n.children.forEach { visit($0, key) }
        }
        doc.node(copy).map { visit($0, "") }
        return out
    }

    /// Everything wrong with the design, every frame on the canvas and in the components finite and
    /// of a size anyone would make, as well as everything `problems` checks.
    static func problems(_ doc: BezzleDocument) -> [String] {
        var out = ComponentSuiteTests.problems(doc)
        func sane(_ n: Node, _ place: String) {
            let f = n.frame
            if !(f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite) || f.width > 20_000 || f.height > 20_000 || f.width < 0 || f.height < 0 {
                out.append("\(place): \(n.name) has the frame \(f)")
            }
            if let b = n.instance?.box, b.width > 20_000 || b.height > 20_000 { out.append("\(place): copy \(n.name) has the box \(b)") }
            n.children.forEach { sane($0, place) }
        }
        doc.nodes.forEach { sane($0, "canvas") }
        doc.masters.forEach { sane($0, "component") }
        return out
    }

    private func check(_ rig: Rig, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for p in Self.problems(rig.bench.store.doc) { Issue.record("\(rig.name), \(what): \(p)", sourceLocation: sourceLocation) }
    }

    /// Records where copies other than `except` lie differently from `before`, by more than a hair.
    private func othersStay(_ rig: Rig, except: Set<UUID>, from before: BezzleDocument, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let doc = rig.bench.store.doc
        for c in rig.copies where !except.contains(c) {
            let was = Self.frames(of: c, before), now = Self.frames(of: c, doc)
            for (name, f) in was {
                guard let g = now[name] else {
                    Issue.record("\(rig.name), \(what): \(name) of another copy went", sourceLocation: sourceLocation)
                    return
                }
                if !ComponentSuiteTests.close(f, g) {
                    Issue.record("\(rig.name), \(what): \(name) in another copy moved from \(f) to \(g)", sourceLocation: sourceLocation)
                    return
                }
            }
        }
    }

    /// Records where the component itself changed since `before`.
    private func componentStays(_ rig: Rig, from before: BezzleDocument, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let was = before.master(rig.master), now = rig.bench.store.doc.master(rig.master)
        if let was, let now, let why = ComponentSuiteTests.differs(was, now) {
            Issue.record("\(rig.name), \(what): the component changed: \(why)", sourceLocation: sourceLocation)
        }
    }

    /// Writes where the component's layers and every copy's lie, to read when a step goes wrong.
    static func dump(_ doc: BezzleDocument, _ rig: Rig, _ title: String, file: String, fresh: Bool) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(file).path
        var out = fresh ? "" : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        out += "== \(title)\n"
        func line(_ n: Node, _ pad: String) {
            out += "\(pad)\(n.name) \(n.frame)\(n.text.map { " \"\($0)\"" } ?? "")\(n.instance.map { " box \($0.box) v \(String(describing: $0.variant))" } ?? "")\(n.post.map { " post \($0)" } ?? "")\(n.own.map { " own \($0)" } ?? "")\n"
            n.children.forEach { line($0, pad + "  ") }
        }
        if let m = doc.master(rig.master) { line(m, "M ") }
        for c in rig.copies { doc.node(c).map { line($0, "C ") } }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Records where a copy's words do not lie in what holds them as the component's do, from the
    /// side they stay at: as far from its left as the component's, for words that keep to the left;
    /// as far from its middle, for words in the middle.
    private func wordsStay(_ rig: Rig, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let doc = rig.bench.store.doc
        guard let master = doc.master(rig.master) else { return }
        for c in rig.copies {
            guard let copy = doc.node(c), let plan = Components.plan(copy, master: master), copy.instance?.flipX == nil, copy.instance?.turn == nil else { continue }
            // The words and the box they lie in, in the component and in the copy.
            func find(_ nodes: [Node], in box: CGRect) -> (Node, CGRect)? {
                for n in nodes {
                    if n.name == rig.label, n.kind == .text { return (n, box) }
                    if n.isGroup, n.instance == nil, let f = find(n.children, in: CGRect(origin: .zero, size: n.frame.size)) { return f }
                }
                return nil
            }
            guard let (m, mb) = find(plan.layers, in: plan.from), let (w, wb) = find(copy.children, in: plan.to), let p = plan.pins[m.id] else { continue }
            func side(_ f: CGRect, _ b: CGRect, _ pin: Pin, x: Bool) -> CGFloat {
                switch pin {
                case .start, .stretch: x ? f.minX - b.minX : f.minY - b.minY
                case .end: x ? b.maxX - f.maxX : b.maxY - f.maxY
                case .middle, .spread: x ? f.midX - b.midX : f.midY - b.midY
                }
            }
            let dx = side(w.frame, wb, p.x, x: true) - side(m.frame, mb, p.x, x: true)
            let dy = side(w.frame, wb, p.y, x: false) - side(m.frame, mb, p.y, x: false)
            if p.x != .spread, abs(dx) > 1 || (p.y != .spread && abs(dy) > 1) {
                Issue.record("\(rig.name), \(what): the words in a copy lie \(w.frame) in \(wb), the component's \(m.frame) in \(mb), kept \(p)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: - Driving the canvas

    private func event(_ bench: Bench, _ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        let view = bench.store.viewport.toView(p)
        return NSEvent.mouseEvent(with: type, location: bench.canvas.convert(view, to: nil), modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Presses at the first point, moves through the others one event each, as the pointer reports
    /// them, and lets go at the last. ⌘ keeps it from catching on other layers' edges.
    /// A rig whose every step of a drag is written down, while a test looks into one.
    nonisolated(unsafe) static var tracing: Rig?

    private func drag(_ bench: Bench, _ points: [CGPoint], flags: NSEvent.ModifierFlags = [.command]) {
        bench.step {
            bench.canvas.mouseDown(with: event(bench, .leftMouseDown, points[0], flags: flags))
            if let rig = Self.tracing { Self.dump(bench.store.doc, rig, "down \(points[0]) \(flags)", file: "trace.txt", fresh: true) }
            for p in points.dropFirst() {
                bench.canvas.mouseDragged(with: event(bench, .leftMouseDragged, p, flags: flags))
                if let rig = Self.tracing { Self.dump(bench.store.doc, rig, "dragged \(p)", file: "trace.txt", fresh: false) }
            }
            bench.canvas.mouseUp(with: event(bench, .leftMouseUp, points.last!, flags: flags))
        }
    }

    /// The points a pointer passes going from one to another in `count` even steps.
    private func path(_ a: CGPoint, _ b: CGPoint, _ count: Int = 12) -> [CGPoint] {
        (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Where a selected layer's handle is, on the canvas: (0, 0.5) its left side, (1, 1) its
    /// bottom right corner.
    private func handle(_ unit: CGPoint, of id: UUID, _ bench: Bench) -> CGPoint {
        let n = bench.store.doc.node(id)!
        let (box, turn) = BezzleDocument.turnedBox(of: n)
        let o = bench.store.doc.parentOrigin(of: id)
        return Geometry.point(unit, of: box.offsetBy(dx: o.x, dy: o.y), rotation: turn)
    }

    /// Drags a layer's handle by `by`, through `steps` moves of the pointer.
    private func pull(_ unit: CGPoint, of id: UUID, by d: CGVector, steps: Int = 12, flags: NSEvent.ModifierFlags = [.command], _ bench: Bench) {
        bench.store.selection = [id]
        let from = handle(unit, of: id, bench)
        drag(bench, path(from, CGPoint(x: from.x + d.dx, y: from.y + d.dy), steps), flags: flags)
    }

    /// Types into a text on the canvas as a person does: starts typing into it, puts the caret at
    /// the end (or picks every letter out with `replacing`), types each letter, and stops.
    private func type(_ text: String, into id: UUID, replacing: Bool = false, deleting: Int = 0, _ bench: Bench, each: ((Int) -> Void)? = nil) {
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        guard let editor = bench.editor else {
            Issue.record("No editor for \(bench.store.doc.node(id)?.name ?? "?")")
            return
        }
        if !replacing { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        var i = 0
        for _ in 0..<deleting {
            bench.step { editor.deleteBackward(nil) }
            i += 1
            each?(i)
        }
        for ch in text {
            bench.step {
                if ch == "\n" { editor.insertNewline(nil) } else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
            }
            i += 1
            each?(i)
        }
        bench.step { bench.canvas.endEditing() }
    }

    // MARK: - Resizing a whole copy by its handles

    /// Each handle, and how far it is pulled.
    static let pulls: [(String, CGPoint, CGVector, NSEvent.ModifierFlags)] = [
        ("right side wider", CGPoint(x: 1, y: 0.5), CGVector(dx: 70, dy: 0), [.command]),
        ("right side narrower", CGPoint(x: 1, y: 0.5), CGVector(dx: -30, dy: 0), [.command]),
        ("left side wider", CGPoint(x: 0, y: 0.5), CGVector(dx: -50, dy: 0), [.command]),
        ("bottom taller", CGPoint(x: 0.5, y: 1), CGVector(dx: 0, dy: 24), [.command]),
        ("top shorter", CGPoint(x: 0.5, y: 0), CGVector(dx: 0, dy: 8), [.command]),
        ("corner", CGPoint(x: 1, y: 1), CGVector(dx: 60, dy: 20), [.command]),
        ("corner with Shift", CGPoint(x: 1, y: 1), CGVector(dx: 60, dy: 20), [.command, .shift]),
        ("side with Option", CGPoint(x: 1, y: 0.5), CGVector(dx: 40, dy: 0), [.command, .option]),
        ("with snapping", CGPoint(x: 1, y: 0.5), CGVector(dx: 37, dy: 0), []),
    ]

    @Test func aCopyResizedByAnyHandleChangesAloneAndStaysAsBig() {
        for (what, unit, d, flags) in Self.pulls {
            for rig in Self.everyButton() {
                let bench = rig.bench, copy = rig.copies[1]
                let before = bench.store.doc
                let box = bench.store.doc.absoluteFrame(of: copy)!
                pull(unit, of: copy, by: d, flags: flags, bench)
                let after = bench.store.doc
                let now = after.absoluteFrame(of: copy)!
                let shape = Self.frame(rig.shape, in: copy, after)!
                let was = Self.frame(rig.shape, in: copy, before)!
                // It is as big as it was pulled to, its shape with it: never further.
                if !flags.contains(.shift), !flags.contains(.option), flags.contains(.command) {
                    if d.dx != 0 { #expect(abs(shape.width - (was.width + (unit.x == 0 ? -d.dx : d.dx))) < 1.5, "\(rig.name), \(what): \(was.width) became \(shape.width)") }
                    if d.dy != 0 { #expect(abs(shape.height - (was.height + (unit.y == 0 ? -d.dy : d.dy))) < 1.5, "\(rig.name), \(what): \(was.height) became \(shape.height)") }
                }
                #expect(now.width < box.width + 200 && now.height < box.height + 200, "\(rig.name), \(what): grew to \(now)")
                #expect(shape.width <= now.width + 0.6, "\(rig.name), \(what): its shape is wider than it, \(shape.width)")
                // Every other copy, and the component, as they were.
                othersStay(rig, except: [copy], from: before, what)
                componentStays(rig, from: before, what)
                // Its words are the component's size.
                let type = Self.layer(rig.label, in: copy, after)?.style?.size
                #expect(type == Self.layer(rig.label, in: rig.copies[0], after)?.style?.size, "\(rig.name), \(what): its words became \(type ?? 0) pt")
                check(rig, what)
                // Nothing goes on changing once it is let go: a change elsewhere leaves it as it is.
                let settled = bench.store.doc
                bench.store.selection = [rig.copies[2]]
                bench.step { bench.store.nudge(dx: 1, dy: 0) }
                #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, now), "\(rig.name), \(what): moved on to \(bench.store.doc.absoluteFrame(of: copy)!)")
                othersStay(rig, except: [rig.copies[2]], from: settled, "\(what), then another nudged")
                // Undone, as it was; redone, as it was made.
                bench.undoLast()
                bench.undoLast()
                #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, box), "\(rig.name), \(what): undone to \(bench.store.doc.absoluteFrame(of: copy)!)")
                othersStay(rig, except: [], from: before, "\(what) undone")
                bench.undo.redo()
                #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, now), "\(rig.name), \(what): redone to \(bench.store.doc.absoluteFrame(of: copy)!)")
                check(rig, "\(what) redone")
            }
        }
    }

    @Test func aPullWaveringBackAndForthEndsWhereItIsLetGo() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[0]
            let before = bench.store.doc
            let box = bench.store.doc.absoluteFrame(of: copy)!
            bench.store.selection = [copy]
            let from = handle(CGPoint(x: 1, y: 0.5), of: copy, bench)
            // Out, back past where it began, out again: 40 moves.
            var points = [from]
            for dx in [10.0, 30, 60, 90, 60, 20, -10, -25, 0, 20, 45] {
                points += path(points.last!, CGPoint(x: from.x + dx, y: from.y), 4).dropFirst()
            }
            drag(bench, points)
            let now = bench.store.doc.absoluteFrame(of: copy)!
            #expect(abs(now.width - (box.width + 45)) < 1.5, "\(rig.name): \(box.width) wavered to \(now.width)")
            othersStay(rig, except: [copy], from: before, "wavering")
            componentStays(rig, from: before, "wavering")
            check(rig, "wavering")
        }
    }

    @Test func aCopyResizedAgainAndAgainGrowsByEachPullOnly() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[2]
            let before = bench.store.doc
            let box = bench.store.doc.absoluteFrame(of: copy)!
            var width = box.width
            for d in [40.0, 25, -15, 60, -80] {
                pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: d, dy: 0), bench)
                width += d
                let now = bench.store.doc.absoluteFrame(of: copy)!
                #expect(abs(now.width - width) < 1.5, "\(rig.name): pulled by \(d) to \(now.width), not \(width)")
            }
            othersStay(rig, except: [copy], from: before, "again and again")
            componentStays(rig, from: before, "again and again")
            check(rig, "again and again")
            for _ in 0..<5 { bench.undoLast() }
            #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, box))
            check(rig, "all undone")
        }
    }

    @Test func everyCopyResizedInTurnKeepsItsOwnSize() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            let before = bench.store.doc
            var wanted: [UUID: CGFloat] = [:]
            for (i, c) in rig.copies.enumerated() {
                let w = bench.store.doc.absoluteFrame(of: c)!.width
                pull(CGPoint(x: 1, y: 0.5), of: c, by: CGVector(dx: CGFloat(20 + 30 * i), dy: 0), bench)
                wanted[c] = w + CGFloat(20 + 30 * i)
                othersStay(rig, except: Set(rig.copies.prefix(i + 1)), from: before, "copy \(i) resized")
            }
            for c in rig.copies {
                let w = bench.store.doc.absoluteFrame(of: c)!.width
                #expect(abs(w - wanted[c]!) < 1.5, "\(rig.name): a copy is \(w) wide, not \(wanted[c]!)")
            }
            componentStays(rig, from: before, "each resized")
            check(rig, "each resized")
        }
    }

    @Test func severalCopiesResizedAtOnceOnTheCanvas() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            let before = bench.store.doc
            bench.store.selection = [rig.copies[0], rig.copies[1]]
            let bounds = bench.store.selectionBounds!
            let from = CGPoint(x: bounds.maxX, y: bounds.midY)
            drag(bench, path(from, CGPoint(x: from.x + 50, y: from.y)))
            for c in rig.copies.prefix(2) {
                let was = before.absoluteFrame(of: c)!, now = bench.store.doc.absoluteFrame(of: c)!
                #expect(now.width > was.width + 20 && now.width < was.width + 80, "\(rig.name): \(was.width) became \(now.width)")
            }
            othersStay(rig, except: [rig.copies[0], rig.copies[1]], from: before, "two at once")
            componentStays(rig, from: before, "two at once")
            check(rig, "two at once")
        }
    }

    @Test func aCopyResizedInTheInspectorOrByTheAssistantChangesAlone() async {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let box = bench.store.doc.node(copy)!.frame
            // The W field.
            bench.store.selection = [copy]
            bench.step { bench.store.updateSelection("Resize") { SelectionInspector.resize(&$0, to: CGSize(width: box.width + 44, height: box.height), byHeight: false) } }
            #expect(abs(bench.store.doc.node(copy)!.frame.width - (box.width + 44)) < 1.5, "\(rig.name): W made it \(bench.store.doc.node(copy)!.frame.width)")
            othersStay(rig, except: [copy], from: before, "W field")
            componentStays(rig, from: before, "W field")
            check(rig, "W field")
            // The H field.
            bench.step { bench.store.updateSelection("Resize") { SelectionInspector.resize(&$0, to: CGSize(width: box.width + 44, height: box.height + 10), byHeight: true) } }
            #expect(abs(bench.store.doc.node(copy)!.frame.height - (box.height + 10)) < 1.5, "\(rig.name): H made it \(bench.store.doc.node(copy)!.frame.height)")
            othersStay(rig, except: [copy], from: before, "H field")
            check(rig, "H field")
            // Both copies at once in the inspector, as several layers are given one size.
            let two = [rig.copies[0], rig.copies[2]]
            let f = two.compactMap { bench.store.doc.absoluteFrame(of: $0) }.reduce(CGRect.null) { $0.union($1) }
            let o = bench.store.doc.parentOrigin(of: two[0])
            let shared = f.offsetBy(dx: -o.x, dy: -o.y)
            bench.step { bench.store.edit("Resize") { doc in SelectionInspector.place(&doc, two, from: shared, to: CGRect(origin: shared.origin, size: CGSize(width: shared.width + 30, height: shared.height))) } }
            for c in two {
                let was = before.absoluteFrame(of: c)!.width, now = bench.store.doc.absoluteFrame(of: c)!.width
                #expect(now > was + 10 && now < was + 50, "\(rig.name): several in the inspector made \(was) \(now)")
            }
            check(rig, "several in the inspector")
            // The assistant.
            let tools = MCPTools()
            MCPTools.opened(bench.store)
            let r = await tools.call("update_layers", ["design": bench.store.name, "updates": [["layer": copy.uuidString, "width": box.width + 80]]])
            let text = String(decoding: r.data, as: UTF8.self)
            #expect(!text.contains("\"isError\":true"), "\(rig.name): \(text)")
            #expect(abs(bench.store.doc.node(copy)!.frame.width - (box.width + 80)) < 1.5, "\(rig.name): the assistant made it \(bench.store.doc.node(copy)!.frame.width)")
            othersStay(rig, except: Set([copy] + two), from: before, "assistant")
            componentStays(rig, from: before, "assistant")
            check(rig, "assistant")
        }
    }

    @Test func aCopyPulledPastItsOtherEdgeOrToNothingStaysSound() {
        for (what, d) in [("past its left edge", CGVector(dx: -260, dy: 0)), ("to almost nothing", CGVector(dx: -1000, dy: 0)),
                          ("past its top", CGVector(dx: 0, dy: -90)), ("far out", CGVector(dx: 900, dy: 0))] {
            for rig in Self.everyButton() {
                let bench = rig.bench, copy = rig.copies[1]
                let before = bench.store.doc
                let unit = d.dy != 0 ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
                var d = d
                if what == "to almost nothing" { d.dx = -(before.absoluteFrame(of: copy)!.width - 2) }
                pull(unit, of: copy, by: d, steps: 30, bench)
                othersStay(rig, except: [copy], from: before, what)
                componentStays(rig, from: before, what)
                check(rig, what)
                // Back again, by hand.
                let back = bench.store.doc
                pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: 30, dy: 0), steps: 10, bench)
                othersStay(rig, except: [copy], from: back, "\(what), then pulled again")
                check(rig, "\(what), then pulled again")
            }
        }
    }

    @Test func aCopyScrubbedInTheInspectorChangesAloneAsTheScrubGoes() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let box = before.node(copy)!.frame
            bench.store.selection = [copy]
            // The frame card's dial, which keeps proportions, and the W field's scrub, each a gesture
            // of many small changes, each from where the last left it.
            for keep in [true, false] {
                bench.step { bench.store.beginGesture() }
                for i in 1...30 {
                    let w = (box.width + CGFloat(i) * 2).rounded()
                    bench.step {
                        bench.store.updateSelection("Resize") { n in
                            let h = keep ? (w * n.frame.height / n.frame.width).rounded() : n.frame.height
                            SelectionInspector.resize(&n, to: CGSize(width: w, height: h), byHeight: false)
                        }
                    }
                }
                bench.step { bench.store.endGesture("Resize") }
                let now = bench.store.doc.node(copy)!.frame
                #expect(abs(now.width - (box.width + 60)) < 1.5, "\(rig.name), kept \(keep): scrubbed to \(now.width)")
                othersStay(rig, except: [copy], from: before, "scrubbed, kept \(keep)")
                componentStays(rig, from: before, "scrubbed, kept \(keep)")
                check(rig, "scrubbed, kept \(keep)")
                bench.undoLast()
                #expect(ComponentSuiteTests.close(bench.store.doc.node(copy)!.frame, box), "\(rig.name): undone to \(bench.store.doc.node(copy)!.frame)")
            }
        }
    }

    // MARK: - Resizing what a copy holds

    @Test func theShapeInACopyResizedResizesItInEveryCopyByAsMuch() {
        for (what, unit, d) in [("wider", CGPoint(x: 1, y: 0.5), CGVector(dx: 40, dy: 0)),
                                ("a hair", CGPoint(x: 1, y: 0.5), CGVector(dx: 2, dy: 0)),
                                ("narrower", CGPoint(x: 1, y: 0.5), CGVector(dx: -20, dy: 0)),
                                ("from the left", CGPoint(x: 0, y: 0.5), CGVector(dx: -30, dy: 0)),
                                ("taller", CGPoint(x: 0.5, y: 1), CGVector(dx: 0, dy: 16)),
                                ("corner", CGPoint(x: 1, y: 1), CGVector(dx: 30, dy: 10)),
                                ("with Option", CGPoint(x: 1, y: 0.5), CGVector(dx: 15, dy: 0)),
                                ("corner with Shift", CGPoint(x: 1, y: 1), CGVector(dx: 30, dy: 0)),
                                ("snapping, slowly", CGPoint(x: 1, y: 0.5), CGVector(dx: 37, dy: 0))] {
            let flags: NSEvent.ModifierFlags = what == "with Option" ? [.command, .option] : what == "corner with Shift" ? [.command, .shift] : what.hasPrefix("snapping") ? [] : [.command]
            for rig in Self.everyButton() {
                let bench = rig.bench, copy = rig.copies[1]
                let before = bench.store.doc
                guard let shape = Self.layer(rig.shape, in: copy, before) else {
                    Issue.record("\(rig.name): no \(rig.shape)")
                    continue
                }
                let widths = rig.copies.map { Self.frame(rig.shape, in: $0, before)!.size }
                pull(unit, of: shape.id, by: d, steps: what.hasPrefix("snapping") ? 60 : 12, flags: flags, bench)
                let after = bench.store.doc
                let pulled = Self.frame(rig.shape, in: copy, after)!.size
                for (i, c) in rig.copies.enumerated() {
                    let now = Self.frame(rig.shape, in: c, after)!.size
                    var dw = d.dx * (unit.x == 0 ? -1 : 1), dh = d.dy * (unit.y == 0 ? -1 : 1)
                    // Pulled from its middle, or keeping its proportions, or caught on an edge: as
                    // much as the pulled one grew, in every copy.
                    if !flags.contains(.command) || flags.contains(.option) || flags.contains(.shift) {
                        dw = pulled.width - widths[1].width
                        dh = pulled.height - widths[1].height
                    }
                    #expect(abs(now.width - (widths[i].width + dw)) < 1.5, "\(rig.name), \(what): copy \(i)'s shape is \(now.width) wide, not \(widths[i].width + dw)")
                    #expect(abs(now.height - (widths[i].height + dh)) < 1.5, "\(rig.name), \(what): copy \(i)'s shape is \(now.height) high, not \(widths[i].height + dh)")
                }
                check(rig, what)
                // Settled: a nudge elsewhere changes nothing more.
                let settled = bench.store.doc
                bench.store.selection = [rig.copies[2]]
                bench.step { bench.store.nudge(dx: 1, dy: 0) }
                othersStay(rig, except: [rig.copies[2]], from: settled, "\(what), then another nudged")
                bench.undoLast()
                bench.undoLast()
                othersStay(rig, except: [], from: before, "\(what) undone")
                componentStays(rig, from: before, "\(what) undone")
                check(rig, "\(what) undone")
            }
        }
    }

    @Test func theShapeInAResizedCopyResizedReachesEveryCopy() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[0]
            pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: 60, dy: 0), bench)
            let before = bench.store.doc
            let widths = rig.copies.map { Self.frame(rig.shape, in: $0, before)!.width }
            let shape = Self.layer(rig.shape, in: rig.copies[1], before)!
            pull(CGPoint(x: 1, y: 0.5), of: shape.id, by: CGVector(dx: 30, dy: 0), bench)
            for (i, c) in rig.copies.enumerated() {
                let now = Self.frame(rig.shape, in: c, bench.store.doc)!.width
                #expect(abs(now - (widths[i] + 30)) < 1.5, "\(rig.name): copy \(i)'s shape is \(now), not \(widths[i] + 30)")
            }
            check(rig, "shape in a resized copy")
        }
    }

    @Test func wordsOfACopysOwnMovedThereMoveTheComponentsAsFar() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            // Words of its own, longer than the component's, in one copy; shorter in another.
            type(" and more", into: Self.layer(rig.label, in: rig.copies[0], bench.store.doc)!.id, bench)
            type("", into: Self.layer(rig.label, in: rig.copies[2], bench.store.doc)!.id, deleting: 2, bench)
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: rig.copies[0], before)!
            bench.store.selection = [label.id]
            bench.step { bench.store.nudge(dx: 0, dy: -2) }
            for c in rig.copies {
                let was = Self.frame(rig.label, in: c, before)!, now = Self.frame(rig.label, in: c, bench.store.doc)!
                #expect(abs(now.minY - (was.minY - 2)) < 0.6 && abs(now.midX - was.midX) < 0.6, "\(rig.name): words moved from \(was) to \(now)")
            }
            wordsStay(rig, "own words moved")
            check(rig, "own words moved")
        }
    }

    @Test func wordsMovedInACopyMoveInEveryCopy() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: rig.copies[2], before)!
            let f = before.absoluteFrame(of: label.id)!
            bench.store.selection = [label.id]
            bench.step { bench.store.nudge(dx: 0, dy: -3) }
            for c in rig.copies {
                let was = Self.frame(rig.label, in: c, before)!, now = Self.frame(rig.label, in: c, bench.store.doc)!
                #expect(abs(now.minY - (was.minY - 3)) < 0.6 && abs(now.minX - was.minX) < 0.6, "\(rig.name): words moved from \(was) to \(now)")
            }
            _ = f
            check(rig, "words moved")
        }
    }

    // MARK: - Typing on the canvas

    /// How a copy's words lie in their shape: the room on each side.
    private func room(_ rig: Rig, _ copy: UUID) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        let doc = rig.bench.store.doc
        let s = Self.frame(rig.shape, in: copy, doc)!, w = Self.frame(rig.label, in: copy, doc)!
        return (w.minX - s.minX, s.maxX - w.maxX, w.minY - s.minY, s.maxY - w.maxY)
    }

    /// Records where words being typed no longer lie in their shape as they did when typing began.
    private func hugs(_ rig: Rig, _ copy: UUID, as was: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat), _ what: String,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let now = room(rig, copy)
        var ok: Bool
        if !rig.hugs {
            // The words where they stay in it, which stays as wide as it is.
            switch rig.align {
            case .center: ok = abs(now.left - now.right) < 1.5
            case .right: ok = abs(now.right - was.right) < 1
            default: ok = abs(now.left - was.left) < 1
            }
            if !ok { Issue.record("\(rig.name), \(what): the words have \(now) round them, not \(was)", sourceLocation: sourceLocation) }
            return
        }
        switch rig.align {
        case .left, .justify: ok = abs(now.left - was.left) < 1 && abs(now.right - was.right) < 1.5
        case .right: ok = abs(now.right - was.right) < 1 && abs(now.left - was.left) < 1.5
        case .center: ok = abs((now.left + now.right) - (was.left + was.right)) < 1.5 && abs(now.left - now.right - (was.left - was.right)) < 1.5
        }
        if !ok { Issue.record("\(rig.name), \(what): the words have \(now) round them, not \(was)", sourceLocation: sourceLocation) }
    }

    @Test func wordsTypedLetterByLetterGrowTheirButtonAndNoOther() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: copy, before)!
            let was = room(rig, copy)
            let start = bench.store.doc.absoluteFrame(of: copy)!
            var widths: [CGFloat] = []
            type(" and more words", into: label.id, bench) { i in
                self.hugs(rig, copy, as: was, "letter \(i)")
                widths.append(bench.store.doc.absoluteFrame(of: copy)!.width)
                self.othersStay(rig, except: [copy], from: before, "letter \(i)")
            }
            let words = Self.layer(rig.label, in: copy, bench.store.doc)?.text ?? ""
            #expect(words.hasSuffix(" and more words"), "\(rig.name): typed \(words)")
            // It grew with each letter, never shrank, and not past its words.
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }, "\(rig.name): \(widths)")
            if rig.hugs {
                #expect((widths.last ?? 0) > start.width + 40, "\(rig.name): grew only to \(widths.last ?? 0) from \(start.width)")
            } else {
                #expect(abs((widths.last ?? 0) - start.width) < 0.6, "\(rig.name): grew to \(widths.last ?? 0) from \(start.width)")
            }
            #expect((widths.last ?? 0) < start.width + 200, "\(rig.name): grew to \(widths.last ?? 0) from \(start.width)")
            hugs(rig, copy, as: was, "typed")
            wordsStay(rig, "typed")
            othersStay(rig, except: [copy], from: before, "typed")
            componentStays(rig, from: before, "typed")
            check(rig, "typed")
            // Undone in one step, as it was.
            bench.undoLast()
            #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, start), "\(rig.name): undone to \(bench.store.doc.absoluteFrame(of: copy)!)")
            #expect(Self.layer(rig.label, in: copy, bench.store.doc)?.text == label.text)
            check(rig, "typing undone")
            bench.undo.redo()
            #expect(abs(bench.store.doc.absoluteFrame(of: copy)!.width - (widths.last ?? 0)) < 0.6, "\(rig.name): redone to \(bench.store.doc.absoluteFrame(of: copy)!.width)")
            check(rig, "typing redone")
        }
    }

    @Test func wordsDeletedShrinkTheirButtonAndRetypedGrowItBack() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[0]
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: copy, before)!
            let was = room(rig, copy)
            let start = bench.store.doc.absoluteFrame(of: copy)!
            let count = min(3, (label.text ?? "").count - 1)
            type("", into: label.id, deleting: count, bench) { i in
                self.hugs(rig, copy, as: was, "deleted \(i)")
                self.othersStay(rig, except: [copy], from: before, "deleted \(i)")
            }
            if rig.hugs { #expect(bench.store.doc.absoluteFrame(of: copy)!.width < start.width - 5, "\(rig.name): \(start.width) became \(bench.store.doc.absoluteFrame(of: copy)!.width)") }
            // Typed back as it was: as big as it was.
            let gone = String((label.text ?? "").suffix(count))
            type(gone, into: label.id, bench)
            #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, start), "\(rig.name): retyped to \(bench.store.doc.absoluteFrame(of: copy)!), not \(start)")
            othersStay(rig, except: [], from: before, "retyped")
            componentStays(rig, from: before, "retyped")
            check(rig, "retyped")
        }
    }

    @Test func wordsTypedOverAllTheLettersReplaceThem() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[2]
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: copy, before)!
            let was = room(rig, copy)
            type("OK", into: label.id, replacing: true, bench) { i in
                self.hugs(rig, copy, as: was, "letter \(i)")
            }
            #expect(Self.layer(rig.label, in: copy, bench.store.doc)?.text == "OK")
            hugs(rig, copy, as: was, "replaced")
            othersStay(rig, except: [copy], from: before, "replaced")
            componentStays(rig, from: before, "replaced")
            check(rig, "replaced")
        }
    }

    @Test func aSecondLineMakesTheButtonTaller() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let label = Self.layer(rig.label, in: copy, before)!
            let start = bench.store.doc.absoluteFrame(of: copy)!
            let was = room(rig, copy)
            type("\nsecond", into: label.id, bench)
            let now = bench.store.doc.absoluteFrame(of: copy)!
            #expect(now.height > start.height + 8, "\(rig.name): two lines left it \(now.height) high")
            #expect(abs(room(rig, copy).top - was.top) < 1.5 && abs(room(rig, copy).bottom - was.bottom) < 1.5, "\(rig.name): \(room(rig, copy)) round two lines, not \(was)")
            othersStay(rig, except: [copy], from: before, "two lines")
            componentStays(rig, from: before, "two lines")
            check(rig, "two lines")
        }
    }

    @Test func wordsTypedIntoAResizedCopyKeepTheRoomItWasGiven() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: 60, dy: 0), bench)
            let before = bench.store.doc
            let was = room(rig, copy)
            let label = Self.layer(rig.label, in: copy, before)!
            type(" plus", into: label.id, bench) { i in
                self.hugs(rig, copy, as: was, "letter \(i)")
            }
            hugs(rig, copy, as: was, "typed into a resized copy")
            othersStay(rig, except: [copy], from: before, "typed into a resized copy")
            componentStays(rig, from: before, "typed into a resized copy")
            check(rig, "typed into a resized copy")
            // Resized after: from what it is.
            let w = bench.store.doc.absoluteFrame(of: copy)!.width
            pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: 20, dy: 0), bench)
            #expect(abs(bench.store.doc.absoluteFrame(of: copy)!.width - (w + 20)) < 1.5, "\(rig.name): \(w) pulled to \(bench.store.doc.absoluteFrame(of: copy)!.width)")
            othersStay(rig, except: [copy], from: before, "resized after typing")
            check(rig, "resized after typing")
        }
    }

    @Test func typingByDoubleClickingTheWordsAsTheTourSays() {
        let rig = Self.tour()
        let bench = rig.bench, copy = rig.copies[1]
        let before = bench.store.doc
        let label = Self.layer(rig.label, in: copy, before)!
        let p = before.absoluteFrame(of: label.id)!.center
        bench.click(p)
        #expect(bench.store.selection == [copy])
        bench.click(p, clicks: 2)
        #expect(bench.store.selection == [label.id], "\(bench.store.selection.compactMap { bench.store.doc.node($0)?.name })")
        bench.click(p, clicks: 2)
        #expect(bench.store.editingText == label.id)
        guard let editor = bench.editor else {
            Issue.record("Not typing")
            return
        }
        let was = room(rig, copy)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        for ch in " my work" { bench.step { editor.insertText(String(ch), replacementRange: editor.selectedRange()) } }
        hugs(rig, copy, as: was, "typed")
        bench.step { bench.canvas.endEditing() }
        hugs(rig, copy, as: was, "typed and left")
        othersStay(rig, except: [copy], from: before, "tour")
        componentStays(rig, from: before, "tour")
        check(rig, "tour")
    }

    @Test func wordsTypedInEveryCopyInTurnEachGrowTheirOwn() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            var rooms: [UUID: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)] = [:]
            for c in rig.copies { rooms[c] = room(rig, c) }
            for (i, c) in rig.copies.enumerated() {
                let before = bench.store.doc
                type(String(repeating: "w", count: 2 + 3 * i), into: Self.layer(rig.label, in: c, before)!.id, bench)
                othersStay(rig, except: [c], from: before, "copy \(i) typed")
            }
            for c in rig.copies { hugs(rig, c, as: rooms[c]!, "each typed") }
            check(rig, "each typed")
            // The component changed now: each keeps its own words, and the room round them.
            let shape = Self.layer(rig.shape, in: rig.copies[0], bench.store.doc)!
            bench.step { bench.store.update([shape.id], "Corners") { $0.cornerRadius = 3 } }
            for c in rig.copies { hugs(rig, c, as: rooms[c]!, "changed after typing") }
            check(rig, "changed after typing")
        }
    }

    @Test func typingAndThenEscapingKeepsWhatWasTyped() {
        let rig = Self.made(Self.button(), name: "centred")
        let bench = rig.bench, copy = rig.copies[1]
        let label = Self.layer(rig.label, in: copy, bench.store.doc)!
        let was = room(rig, copy)
        bench.step { bench.canvas.beginEditing(label.id, action: "Typing") }
        let editor = bench.editor!
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        for ch in "s now" { bench.step { editor.insertText(String(ch), replacementRange: editor.selectedRange()) } }
        bench.step { _ = bench.canvas.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) }
        #expect(bench.store.editingText == nil)
        hugs(rig, copy, as: was, "escaped")
        check(rig, "escaped")
    }

    @Test func wordsTypedIntoAWrappingLabelWrapAndMakeItTaller() {
        for sizing in [TextSizing.autoHeight, .fixed] {
            let rig = Self.made(Self.button(width: 160, height: 44, sizing: sizing), name: "\(sizing)")
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let start = before.absoluteFrame(of: copy)!
            let label = Self.layer(rig.label, in: copy, before)!
            type(" with many more words than fit", into: label.id, bench)
            let now = bench.store.doc.absoluteFrame(of: copy)!
            #expect(abs(now.width - start.width) < 0.6, "\(sizing): \(start.width) wide became \(now.width)")
            if sizing == .autoHeight { #expect(now.height > start.height + 10, "\(sizing): \(start.height) high became \(now.height)") }
            othersStay(rig, except: [copy], from: before, "\(sizing)")
            componentStays(rig, from: before, "\(sizing)")
            check(rig, "\(sizing)")
        }
    }

    @Test func wordsTypedIntoACopyShowingAVariantGrowItToo() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            bench.store.selection = [copy]
            bench.step { bench.store.addVariant() }
            let shape = Self.layer(rig.shape, in: copy, bench.store.doc)!
            bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = .black } }
            let before = bench.store.doc
            let was = room(rig, copy)
            type(" variant", into: Self.layer(rig.label, in: copy, before)!.id, bench) { i in
                self.hugs(rig, copy, as: was, "letter \(i)")
            }
            othersStay(rig, except: [copy], from: before, "variant typed")
            componentStays(rig, from: before, "variant typed")
            check(rig, "variant typed")
        }
    }

    @Test func wordsTypedIntoATurnedCopyGrowItAlongItsTurn() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            bench.step {
                bench.store.edit("Rotate") { doc in
                    let n = doc.node(copy)!
                    doc.update(copy) { $0 = BezzleDocument.turned($0, by: 20, about: n.frame.center) }
                }
            }
            let before = bench.store.doc
            let shapeWas = Self.layer(rig.shape, in: copy, before)!.frame.width
            let labelWas = Self.layer(rig.label, in: copy, before)!.frame.width
            type(" turned", into: Self.layer(rig.label, in: copy, before)!.id, bench)
            let shape = Self.layer(rig.shape, in: copy, bench.store.doc)!, label = Self.layer(rig.label, in: copy, bench.store.doc)!
            if rig.hugs {
                #expect(abs((shape.frame.width - label.frame.width) - (shapeWas - labelWas)) < 1.5, "\(rig.name): \(shape.frame.width) round \(label.frame.width)")
            } else {
                #expect(abs(shape.frame.width - shapeWas) < 0.6, "\(rig.name): \(shapeWas) became \(shape.frame.width)")
            }
            #expect(abs(shape.rotation - 20) < 0.1 && abs(label.rotation - 20) < 0.1)
            othersStay(rig, except: [copy], from: before, "turned typed")
            componentStays(rig, from: before, "turned typed")
            check(rig, "turned typed")
        }
    }

    // MARK: - Buttons in cards

    /// A card component holding a copy of a button component, and a second card.
    private func cards() -> (Rig, cards: [UUID], button: UUID) {
        var back = Node(kind: .rectangle, name: "Card back", frame: CGRect(x: 30, y: 20, width: 260, height: 110))
        back.fill.color = .white
        let bench = Self.bench([back, Self.button(at: CGPoint(x: 46, y: 76))])
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let button = bench.store.doc.masters[0].id
        bench.store.selection = [bench.node("Card back")!.id, bench.store.selection[0]]
        bench.step { bench.store.makeComponent() }
        let first = bench.store.selection[0]
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 130)) }
        let card = bench.store.doc.node(first)!.instance!.of
        let rig = Rig(bench: bench, master: card, copies: [first, bench.store.selection[0]], label: "Label", shape: "Shape", align: .center, name: "card")
        return (rig, [first, bench.store.selection[0]], button)
    }

    private func buttonIn(_ card: UUID, _ doc: BezzleDocument) -> Node? { doc.node(card)?.children.first(where: \.isCopy) }

    @Test func wordsTypedIntoAButtonInACardGrowThatButtonOnly() {
        let (rig, cards, _) = cards()
        let bench = rig.bench
        let before = bench.store.doc
        let inner = buttonIn(cards[1], before)!
        let label = inner.children.first { $0.name == "Label" }!
        let start = before.absoluteFrame(of: inner.id)!
        let back = before.absoluteFrame(of: Self.layer("Card back", in: cards[1], before)!.id)!
        type(" more", into: label.id, bench)
        let after = bench.store.doc
        let now = after.absoluteFrame(of: buttonIn(cards[1], after)!.id)!
        #expect(now.width > start.width + 20 && now.width < start.width + 100, "\(start.width) became \(now.width)")
        #expect(ComponentSuiteTests.close(after.absoluteFrame(of: Self.layer("Card back", in: cards[1], after)!.id)!, back))
        othersStay(rig, except: [cards[1]], from: before, "button in a card typed")
        check(rig, "button in a card typed")
    }

    @Test func aButtonInACardResizedThereIsResizedInEveryCard() {
        let (rig, cards, _) = cards()
        let bench = rig.bench
        let before = bench.store.doc
        let inner = buttonIn(cards[0], before)!
        let widths = cards.map { buttonIn($0, before).flatMap { before.absoluteFrame(of: $0.id) }!.width }
        pull(CGPoint(x: 1, y: 0.5), of: inner.id, by: CGVector(dx: 50, dy: 0), bench)
        for (i, c) in cards.enumerated() {
            let now = buttonIn(c, bench.store.doc).flatMap { bench.store.doc.absoluteFrame(of: $0.id) }!.width
            #expect(abs(now - (widths[i] + 50)) < 1.5, "card \(i): the button is \(now), not \(widths[i] + 50)")
        }
        check(rig, "button in a card resized")
    }

    @Test func aCardResizedAloneLeavesTheOtherCard() {
        let (rig, cards, _) = cards()
        let bench = rig.bench
        let before = bench.store.doc
        let box = before.absoluteFrame(of: cards[1])!
        pull(CGPoint(x: 1, y: 0.5), of: cards[1], by: CGVector(dx: 80, dy: 0), bench)
        #expect(abs(bench.store.doc.absoluteFrame(of: cards[1])!.width - (box.width + 80)) < 1.5)
        othersStay(rig, except: [cards[1]], from: before, "card resized")
        componentStays(rig, from: before, "card resized")
        check(rig, "card resized")
    }

    // MARK: - Variants

    /// A rig whose second copy shows a new variant of its own, dark.
    private func withVariant(_ rig: Rig) -> Int? {
        let bench = rig.bench, copy = rig.copies[1]
        bench.store.selection = [copy]
        bench.step { bench.store.addVariant() }
        guard let shape = Self.layer(rig.shape, in: copy, bench.store.doc) else { return nil }
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = .black } }
        bench.store.selection = []
        return bench.store.doc.master(rig.master)?.master?.variants.first
    }

    @Test func aNewVariantLooksAsItsCopyDidAndGrowsRoundItsWords() {
        for rig in Self.everyButton() {
            let bench = rig.bench, copy = rig.copies[1]
            let before = bench.store.doc
            let box = before.absoluteFrame(of: copy)!
            let was = room(rig, copy)
            bench.store.selection = [copy]
            bench.step { bench.store.addVariant() }
            #expect(ComponentSuiteTests.close(bench.store.doc.absoluteFrame(of: copy)!, box), "\(rig.name): made a variant, it went from \(box) to \(bench.store.doc.absoluteFrame(of: copy)!)")
            othersStay(rig, except: [], from: before, "new variant")
            check(rig, "new variant")
            // Shown in another copy, that one keeps its words and grows round them as before.
            let other = rig.copies[2]
            let otherBox = bench.store.doc.absoluteFrame(of: other)!
            let v = bench.store.doc.master(rig.master)!.master!.variants[0]
            bench.step { bench.store.setVariant(v, for: [other]) }
            #expect(abs(bench.store.doc.absoluteFrame(of: other)!.width - otherBox.width) < 1.5, "\(rig.name): shown as the variant, \(otherBox.width) became \(bench.store.doc.absoluteFrame(of: other)!.width)")
            check(rig, "variant shown")
            // Typed into, it grows as a copy of the first does.
            type(" more", into: Self.layer(rig.label, in: copy, bench.store.doc)!.id, bench) { i in
                self.hugs(rig, copy, as: was, "variant, letter \(i)")
            }
            check(rig, "variant typed")
        }
    }

    @Test func aCopyShowingAVariantResizedChangesAlone() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            guard withVariant(rig) != nil else { continue }
            for copy in [rig.copies[1], rig.copies[0]] {
                let before = bench.store.doc
                let box = before.absoluteFrame(of: copy)!
                pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: 50, dy: 0), flags: [], bench)
                let now = bench.store.doc.absoluteFrame(of: copy)!
                #expect(abs(now.width - (box.width + 50)) < 3, "\(rig.name): \(box.width) became \(now.width)")
                othersStay(rig, except: [copy], from: before, "variant copy resized")
                componentStays(rig, from: before, "variant copy resized")
                check(rig, "variant copy resized")
            }
        }
    }

    @Test func theShapeResizedInAVariantsCopyChangesThatVariantOnly() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            guard withVariant(rig) != nil else { continue }
            let before = bench.store.doc
            let shape = Self.layer(rig.shape, in: rig.copies[1], before)!
            let widths = rig.copies.map { Self.frame(rig.shape, in: $0, before)!.width }
            pull(CGPoint(x: 1, y: 0.5), of: shape.id, by: CGVector(dx: 36, dy: 0), bench)
            let after = bench.store.doc
            let now = rig.copies.map { Self.frame(rig.shape, in: $0, after)!.width }
            #expect(abs(now[1] - (widths[1] + 36)) < 3, "\(rig.name): the variant's copy's shape is \(now[1]), not \(widths[1] + 36)")
            othersStay(rig, except: [rig.copies[1]], from: before, "shape in the variant")
            check(rig, "shape in the variant")
            // And the first variant's, in a copy of it: every copy follows, the variant too.
            let first = Self.layer(rig.shape, in: rig.copies[0], after)!
            pull(CGPoint(x: 1, y: 0.5), of: first.id, by: CGVector(dx: 24, dy: 0), bench)
            let last = rig.copies.map { Self.frame(rig.shape, in: $0, bench.store.doc)!.width }
            for i in [0, 2] { #expect(abs(last[i] - (now[i] + 24)) < 3, "\(rig.name): copy \(i)'s shape is \(last[i]), not \(now[i] + 24)") }
            #expect(last.allSatisfy { $0 < 1000 }, "\(rig.name): \(last)")
            check(rig, "shape in the first variant")
        }
    }

    // MARK: - The tour, as it is shipped

    /// The tour's own design, its lesson on components in view.
    private func shippedTour() -> (Rig, offset: CGPoint)? {
        let bench = Bench()
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        let tour = Welcome.design()
        bench.step { bench.store.edit("Tour") { $0 = tour } }
        guard let master = bench.store.doc.masters.first(where: { $0.name == String(localized: "Pill button") }) else {
            Issue.record("The tour has no pill button")
            return nil
        }
        let copies = bench.store.doc.copies(of: master.id).map(\.id)
        let first = bench.store.doc.absoluteFrame(of: copies[0])!
        bench.store.viewport = Viewport(origin: CGPoint(x: first.minX - 300, y: first.minY - 200), zoom: 1)
        return (Rig(bench: bench, master: master.id, copies: copies, label: String(localized: "Pill button") == "Pill button" ? "Label" : "Label",
                    shape: "Pill", align: .center, name: "shipped tour"), .zero)
    }

    @Test func theTourLessonPlayedThroughAsItSays() {
        guard let (rig, _) = shippedTour() else { return }
        let bench = rig.bench
        // The layers of the tour's buttons are named by kind.
        let copy = bench.store.doc.node(rig.copies[0])!
        let shape = copy.children.first { $0.kind == .rectangle }!, label = copy.children.first { $0.kind == .text }!
        let shapeName = shape.name, labelName = label.name
        let r = Rig(bench: bench, master: rig.master, copies: rig.copies, label: labelName, shape: shapeName, align: .center, name: "shipped tour")
        check(r, "as shipped")
        // Click one, then its shape, and give it another colour.
        let start = bench.store.doc
        bench.step { bench.store.update([Self.layer(shapeName, in: rig.copies[1], start)!.id], "Fill") { $0.fill.color = RGBA(r: 0.9, g: 0.3, b: 0.2) } }
        for c in rig.copies { #expect(Self.layer(shapeName, in: c, bench.store.doc)?.fill.color == RGBA(r: 0.9, g: 0.3, b: 0.2)) }
        othersStay(r, except: [], from: start, "recoloured")
        check(r, "recoloured")
        // Double-click a label and type.
        let was = room(r, rig.copies[2])
        let before = bench.store.doc
        type(" it all", into: Self.layer(labelName, in: rig.copies[2], before)!.id, bench) { i in
            self.hugs(r, rig.copies[2], as: was, "letter \(i)")
        }
        othersStay(r, except: [rig.copies[2]], from: before, "typed")
        check(r, "typed")
        // Change a colour again and click New Variant.
        let s = Self.layer(shapeName, in: rig.copies[0], bench.store.doc)!
        bench.store.selection = [s.id]
        let made = bench.store.doc
        bench.step { bench.store.update([s.id], "Fill") { $0.fill.color = RGBA(r: 0.1, g: 0.6, b: 0.3) } }
        if let offer = bench.store.componentOffer {
            bench.step { bench.store.take(offer, .newVariant) }
        } else {
            Issue.record("No offer after a colour changed")
        }
        othersStay(r, except: [], from: made, "new variant")
        check(r, "new variant")
        // Then resize them, each way there is, with the pointer.
        for (i, c) in rig.copies.enumerated() {
            let before = bench.store.doc
            let box = before.absoluteFrame(of: c)!
            pull(CGPoint(x: 1, y: 0.5), of: c, by: CGVector(dx: 30 + CGFloat(i) * 10, dy: 0), steps: 40, flags: [], bench)
            let now = bench.store.doc.absoluteFrame(of: c)!
            #expect(abs(now.width - (box.width + 30 + CGFloat(i) * 10)) < 3, "copy \(i): \(box.width) became \(now.width)")
            othersStay(r, except: [c], from: before, "copy \(i) resized")
            check(r, "copy \(i) resized")
        }
        for (i, c) in rig.copies.enumerated() {
            let before = bench.store.doc
            let widths = rig.copies.map { Self.frame(shapeName, in: $0, before)!.width }
            pull(CGPoint(x: 1, y: 0.5), of: Self.layer(shapeName, in: c, before)!.id, by: CGVector(dx: 20, dy: 0), steps: 40, flags: [], bench)
            let now = rig.copies.map { Self.frame(shapeName, in: $0, bench.store.doc)!.width }
            let grown = now[i] - widths[i]
            #expect(abs(grown - 20) < 3, "copy \(i)'s shape: \(widths[i]) became \(now[i])")
            for j in rig.copies.indices where j != i && bench.store.doc.node(rig.copies[j])?.instance?.variant == bench.store.doc.node(c)?.instance?.variant {
                #expect(abs(now[j] - widths[j] - grown) < 0.6, "copy \(i)'s shape grew by \(grown), copy \(j)'s by \(now[j] - widths[j])")
            }
            #expect(now.allSatisfy { $0 < 600 }, "shape of copy \(i) resized: \(now)")
            check(r, "shape of copy \(i) resized")
        }
    }

    // MARK: - Held in grids and stacks, cancelled, duplicated

    @Test func copiesInTheCellsOfARepeatGridGrowAlone() {
        let rig = Self.made(Self.button(), name: "grid")
        let bench = rig.bench
        // The first copy made into a grid of three cells, one under another.
        bench.store.selection = [rig.copies[0]]
        bench.step { bench.store.makeRepeatGrid() }
        guard let grid = bench.store.doc.allNodes.first(where: \.isRepeatGrid)?.id else {
            Issue.record("No grid")
            return
        }
        bench.step { bench.store.edit("Rows") { doc in doc.update(grid) { $0.grid?.rows = 3 } } }
        let cells = bench.store.doc.node(grid)!.children.map(\.id)
        #expect(cells.count == 3 && cells.allSatisfy { bench.store.doc.node($0)?.isCopy == true })
        let cellRig = Rig(bench: bench, master: rig.master, copies: cells + [rig.copies[1], rig.copies[2]], label: "Label", shape: "Shape", align: .center, name: "grid")
        check(cellRig, "grid made")
        let before = bench.store.doc
        let was = room(cellRig, cells[1])
        type(" in a cell", into: Self.layer("Label", in: cells[1], before)!.id, bench) { i in
            self.hugs(cellRig, cells[1], as: was, "cell, letter \(i)")
        }
        #expect(Self.layer("Label", in: cells[0], bench.store.doc)?.text == "Button")
        othersStay(cellRig, except: [cells[1], grid], from: before, "typed in a cell")
        componentStays(cellRig, from: before, "typed in a cell")
        check(cellRig, "typed in a cell")
        // The shape in a cell resized: the component, and so every cell and every copy.
        let shapes = cellRig.copies.map { Self.frame("Shape", in: $0, bench.store.doc)!.width }
        pull(CGPoint(x: 1, y: 0.5), of: Self.layer("Shape", in: cells[2], bench.store.doc)!.id, by: CGVector(dx: 20, dy: 0), bench)
        let now = cellRig.copies.map { Self.frame("Shape", in: $0, bench.store.doc)!.width }
        for (i, w) in now.enumerated() { #expect(abs(w - shapes[i] - 20) < 1.5, "copy \(i): \(shapes[i]) became \(w)") }
        check(cellRig, "shape in a cell resized")
    }

    @Test func copiesInTheirPostsOfAStackKeepTheirWordsAndSize() {
        let rig = Self.made(Self.button(), name: "stack")
        let bench = rig.bench
        let a = bench.a.id
        bench.step { bench.store.addPost(to: a) }
        bench.step { bench.store.addPost(to: a) }
        let front = bench.store.front(of: bench.a)
        let inFront = bench.store.doc.copies(of: rig.master).filter { bench.store.doc.post(of: $0.id)?.post == front }.map(\.id)
        let others = bench.store.doc.copies(of: rig.master).map(\.id).filter { !inFront.contains($0) }
        let all = Rig(bench: bench, master: rig.master, copies: inFront + others, label: "Label", shape: "Shape", align: .center, name: "stack")
        check(all, "stacked")
        let before = bench.store.doc
        let copy = inFront[1]
        let was = room(all, copy)
        type(" here", into: Self.layer("Label", in: copy, before)!.id, bench) { i in
            self.hugs(all, copy, as: was, "post, letter \(i)")
        }
        othersStay(all, except: [copy], from: before, "typed in a post")
        check(all, "typed in a post")
        pull(CGPoint(x: 1, y: 0.5), of: inFront[0], by: CGVector(dx: 30, dy: 0), bench)
        #expect(bench.store.doc.copies(of: rig.master).allSatisfy { $0.frame.width < 400 })
        check(all, "resized in a post")
    }

    @Test func escapeDuringAResizePutsEverythingBack() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            let before = bench.store.doc
            for id in [rig.copies[1], Self.layer(rig.shape, in: rig.copies[1], before)!.id] {
                bench.store.selection = [id]
                let from = handle(CGPoint(x: 1, y: 0.5), of: id, bench)
                bench.step {
                    bench.canvas.mouseDown(with: event(bench, .leftMouseDown, from, flags: [.command]))
                    for p in path(from, CGPoint(x: from.x + 60, y: from.y)) { bench.canvas.mouseDragged(with: event(bench, .leftMouseDragged, p, flags: [.command])) }
                }
                bench.key(53)
                bench.step { bench.canvas.mouseUp(with: event(bench, .leftMouseUp, CGPoint(x: from.x + 60, y: from.y), flags: [.command])) }
                othersStay(rig, except: [], from: before, "escaped")
                componentStays(rig, from: before, "escaped")
                check(rig, "escaped")
            }
        }
    }

    @Test func aCopyOptionDraggedOffThenResizedChangesAlone() {
        for rig in Self.everyButton() {
            let bench = rig.bench
            let f = Self.frame(rig.shape, in: rig.copies[2], bench.store.doc)!
            bench.store.selection = [rig.copies[2]]
            // Clear of the handle on its left side.
            let grab = CGPoint(x: f.minX + 20, y: f.midY)
            let had = Set(bench.store.doc.copies(of: rig.master).map(\.id))
            drag(bench, path(grab, CGPoint(x: grab.x, y: grab.y + 70), 6), flags: [.option, .command])
            guard let made = bench.store.doc.copies(of: rig.master).map(\.id).first(where: { !had.contains($0) }) else {
                Issue.record("\(rig.name): Option-drag made no copy")
                continue
            }
            let all = Rig(bench: bench, master: rig.master, copies: rig.copies + [made], label: rig.label, shape: rig.shape, align: rig.align, name: rig.name, hugs: rig.hugs)
            let before = bench.store.doc
            pull(CGPoint(x: 1, y: 0.5), of: made, by: CGVector(dx: 44, dy: 0), bench)
            #expect(abs(Self.frame(rig.shape, in: made, bench.store.doc)!.width - (f.width + 44)) < 2, "\(rig.name): \(Self.frame(rig.shape, in: made, bench.store.doc)!.width)")
            othersStay(all, except: [made], from: before, "duplicate resized")
            componentStays(all, from: before, "duplicate resized")
            check(all, "duplicate resized")
        }
    }

    // MARK: - Played with at random

    @Test(arguments: [7, 11, 23] as [UInt64])
    func aMinuteOfPlayingAtRandomKeepsEverythingSound(seed: UInt64) {
        var rng = Seeded(seed)
        for rig in Self.everyButton() {
            let bench = rig.bench
            var log: [String] = []
            for step in 0..<40 {
                let copy = rig.copies[Int(rng.next() % UInt64(rig.copies.count))]
                let doc = bench.store.doc
                let before = doc
                var touched: Set<UUID> = [copy]
                var componentChanged = false
                let which = rig.copies.firstIndex(of: copy)!
                var what = ""
                switch rng.next() % 8 {
                case 0:
                    let d = CGFloat(Int(rng.next() % 90) - 30)
                    what = "copy \(which) pulled right by \(d)"
                    pull(CGPoint(x: 1, y: 0.5), of: copy, by: CGVector(dx: d, dy: 0), bench)
                case 1:
                    let d = CGFloat(Int(rng.next() % 50) - 20)
                    what = "copy \(which) pulled left by \(d)"
                    pull(CGPoint(x: 0, y: 0.5), of: copy, by: CGVector(dx: d, dy: 0), bench)
                case 2:
                    let n = Int(rng.next() % 4) + 1
                    what = "copy \(which) typed \(n)"
                    if let label = Self.layer(rig.label, in: copy, doc) {
                        type(String(repeating: "a", count: n), into: label.id, bench)
                    }
                case 3:
                    what = "copy \(which) deleted 1"
                    if let label = Self.layer(rig.label, in: copy, doc), (label.text ?? "").count > 2 {
                        type("", into: label.id, deleting: 1, bench)
                    }
                case 4:
                    let d = CGFloat(Int(rng.next() % 30) - 10)
                    what = "copy \(which)'s shape pulled by \(d)"
                    if let shape = Self.layer(rig.shape, in: copy, doc) {
                        pull(CGPoint(x: 1, y: 0.5), of: shape.id, by: CGVector(dx: d, dy: 0), bench)
                        componentChanged = true
                        touched = Set(rig.copies)
                    }
                case 5:
                    let d = CGFloat(Int(rng.next() % 30) - 10)
                    what = "copy \(which)'s shape pulled left by \(d)"
                    if let shape = Self.layer(rig.shape, in: copy, doc) {
                        pull(CGPoint(x: 0, y: 0.5), of: shape.id, by: CGVector(dx: -d, dy: 0), flags: rng.next() % 2 == 0 ? [] : [.command], bench)
                        componentChanged = true
                        touched = Set(rig.copies)
                    }
                case 6:
                    let d = CGFloat(Int(rng.next() % 20) - 6)
                    what = "copy \(which) pulled down by \(d)"
                    pull(CGPoint(x: 1, y: 1), of: copy, by: CGVector(dx: d, dy: d / 2), flags: rng.next() % 2 == 0 ? [] : [.command], bench)
                default:
                    what = "copy \(which) recoloured"
                    bench.step { bench.store.update([Self.layer(rig.shape, in: copy, doc)!.id], "Fill") { $0.fill.color = RGBA(r: Double(step) / 18, g: 0.4, b: 0.6) } }
                    componentChanged = true
                }
                log.append("\(step): \(what)")
                Self.dump(bench.store.doc, rig, "\(step): \(what)", file: "play-\(seed)-\(rig.name).txt", fresh: step == 0)
                if !componentChanged { othersStay(rig, except: touched, from: before, "step \(step), \(log.suffix(4))") }
                check(rig, "step \(step), \(log.suffix(4))")
                for c in rig.copies {
                    let w = bench.store.doc.absoluteFrame(of: c)?.width ?? 0
                    #expect(w > 0 && w < 1000, "\(rig.name), step \(step), \(log.suffix(4)): a copy is \(w) wide")
                }
                wordsStay(rig, "step \(step), \(log.suffix(4))")
            }
        }
    }
}

/// Random numbers that are the same every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

