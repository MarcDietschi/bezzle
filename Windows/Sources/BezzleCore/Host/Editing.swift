import Foundation

// Editing a design on Windows the way the Mac's DocumentStore edits one, from the browser editor
// that was (WebEditing.swift in 8f0b773): every change goes through the same steps after it
// (repeat grids, decks, components, styles, masks, notes, groups fitted), a drag is one gesture
// measured from where it began, and undo takes back only what was done here, leaving what others
// changed since (`FlatDesign.apply`).

enum Editing {
    /// The design as the gesture going on began.
    static var gestureStart: BezzleDocument?
    /// What the gesture's changes are made again from, when that is not where it began: the
    /// design as it began with something done to it partway, which stays as the gesture goes on
    /// (a shape opened under a drag, holding what is moved). Its undo still goes back to the start.
    static var gestureBase: BezzleDocument?
    /// Each step, and the posts in front of its decks as it was made, which undoing it shows again.
    static var undos: [(before: BezzleDocument, after: BezzleDocument, fronts: [UUID: Int])] = []
    /// What the last change made through `edited` did to copies of components.
    static var lastEcho: ComponentEcho?
    /// The last step made at once (not a gesture), and what it did to copies: what the canvas may
    /// offer to make of it, as the Mac's store does after such a step (considerComponentOffer).
    static var lastStep: (before: BezzleDocument, echo: ComponentEcho?)?
    static var redos: [(before: BezzleDocument, after: BezzleDocument, fronts: [UUID: Int])] = []
    /// The design before the last step settled, whether that step was dragged in, and whether it
    /// was made from the design's list of styles: for the wave a change to a style runs.
    static var lastSettled: (before: BezzleDocument, dragged: Bool, fromList: Bool)?

    /// `change` made to `doc`, followed as DocumentStore.edit follows every change.
    static func edited(_ doc: BezzleDocument, start: BezzleDocument?, _ change: (inout BezzleDocument) -> Void) -> BezzleDocument {
        var next = doc
        change(&next)
        next.syncGrids(since: doc, start: start)
        next.syncDecks(since: doc, fronts: WindowsCore.fronts)
        lastEcho = next.syncComponents(since: doc, start: start)
        next.syncStyles(since: doc)
        next.keepMasks(since: doc)
        next.keepNotes(since: doc)
        next.fitGroups(since: doc)
        next.fitCarousels()
        return next
    }

    /// One step of the history, or, inside a gesture, the gesture as it stands, made again from
    /// where it began.
    static func apply(to doc: BezzleDocument, _ change: (inout BezzleDocument) -> Void) -> BezzleDocument {
        let base = gestureBase ?? gestureStart ?? doc
        let next = edited(base, start: gestureStart, change)
        guard next != doc else { return doc }
        if gestureStart == nil {
            record(before: doc, after: next)
            lastStep = (doc, lastEcho)
            lastSettled = (doc, false, WindowsCore.stylesFromList)
        }
        return next
    }

    static func begin(_ doc: BezzleDocument) { if gestureStart == nil { gestureStart = doc } }

    /// The gesture is done: cells settle, copies are made again, groups fit, and it is one step.
    static func end(_ doc: BezzleDocument) -> BezzleDocument {
        guard let start = gestureStart else { return doc }
        gestureStart = nil
        gestureBase = nil
        var settled = doc
        settled.relayoutGrids(since: start)
        settled.remakeCopies(since: doc)
        settled.fitGroups(since: doc)
        if settled != start {
            record(before: start, after: settled)
            lastSettled = (start, true, WindowsCore.stylesFromList)
        }
        return settled
    }

    private static func record(before: BezzleDocument, after: BezzleDocument) {
        undos.append((before, after, WindowsCore.fronts))
        if undos.count > 200 { undos.removeFirst() }
        redos = []
    }

    /// Takes back the last step done here; others' changes since stay.
    static func undo(_ now: BezzleDocument) -> BezzleDocument? {
        guard gestureStart == nil, let step = undos.popLast() else { return nil }
        lastStep = nil
        let back = now == step.after ? step.before : FlatDesign.apply(from: step.after, to: step.before, onto: now)
        redos.append((before: back, after: now, fronts: WindowsCore.fronts))
        // A deck the step changed shows the post it showed then: undoing a post added or taken
        // away shows the one that was in front, as on the Mac.
        for id in decks(changedFrom: step.before, to: step.after) { WindowsCore.fronts[id] = step.fronts[id] }
        return back
    }

    static func redo(_ now: BezzleDocument) -> BezzleDocument? {
        guard gestureStart == nil, let step = redos.popLast() else { return nil }
        lastStep = nil
        let again = now == step.before ? step.after : FlatDesign.apply(from: step.before, to: step.after, onto: now)
        undos.append((now, again, WindowsCore.fronts))
        for id in decks(changedFrom: step.before, to: step.after) { WindowsCore.fronts[id] = step.fronts[id] }
        return again
    }

    /// The decks that are not the same in two designs, or are a deck in only one of them.
    static func decks(changedFrom a: BezzleDocument, to b: BezzleDocument) -> [UUID] {
        var was: [UUID: Node] = [:]
        for n in a.nodes where n.isDeck { was[n.id] = n }
        var changed: [UUID] = []
        for n in b.nodes {
            if let then = was.removeValue(forKey: n.id) {
                if then != n { changed.append(n.id) }
            } else if n.isDeck {
                changed.append(n.id)
            }
        }
        return changed + was.keys
    }
}

extension WindowsCore {
    /// A layer of an artboard, with its frame on the artboard: for the canvas to pick and put
    /// handles round.
    nonisolated public struct Layer: Sendable {
        public let id: UUID
        public let name: String
        public let parent: UUID?
        public let depth: Int
        public let frame: CGRect
        public let rotation: Double
        public let isContainer: Bool
        public let isText: Bool
        public let hidden: Bool
        public let locked: Bool
        /// artboard, rectangle, ellipse, line, text, group or path (Node.Kind).
        public let kind: String
        /// A linked copy of a component.
        public let isCopy: Bool
        public let opacity: Double
        public let cornerRadius: Double
        /// Corners rounded each its own way.
        public let cornersDiffer: Bool
        public let fill: Paint
        public let border: Paint
        /// Inside, center or outside, and its width.
        public let borderPosition: String
        public let borderWidth: Double
        public let fontFamily: String?
        public let fontFace: String?
        public let fontSize: Double?
        public let text: String?
        /// The shadow: whether it is on, how far down and how blurred.
        public let shadowOn: Bool
        public let shadowY: Double
        public let shadowBlur: Double
    }

    /// A fill or border as the inspector sums it up.
    nonisolated public struct Paint: Sendable {
        public let on: Bool
        /// RGB as six hex digits, and its alpha.
        public let hex: String
        public let alpha: Double
        public let picture: Bool
        public let gradient: Bool
    }

    /// The layers of the artboard at `index`, each before what it holds.
    public static func layers(board index: Int) -> [Layer] {
        guard let doc = design, index >= 0, index < doc.nodes.count else { return [] }
        var out: [Layer] = []
        func walk(_ nodes: [Node], parent: UUID?, origin: CGPoint, depth: Int) {
            for n in nodes {
                let f = n.frame.offsetBy(dx: origin.x, dy: origin.y)
                out.append(layer(n, parent: parent, depth: depth, frame: f))
                walk(n.children, parent: n.id, origin: CGPoint(x: f.minX, y: f.minY), depth: depth + 1)
            }
        }
        // A layer on the canvas is listed itself, before what it holds, its frame on the canvas.
        // A deck, as it is seen: the post in front.
        if doc.nodes[index].isArtboard { walk(doc.nodes[index].seenLayers(fronts: fronts), parent: nil, origin: .zero, depth: 0) } else { walk([doc.nodes[index]], parent: nil, origin: .zero, depth: 0) }
        return out
    }

    /// The artboard at `index` among the design's layers, as a layer itself, its frame on the canvas.
    public static func boardLayer(_ index: Int) -> Layer? {
        guard let doc = design, index >= 0, index < doc.nodes.count, doc.nodes[index].isArtboard else { return nil }
        let n = doc.nodes[index]
        return layer(n, parent: nil, depth: 0, frame: n.frame)
    }

    private static func layer(_ n: Node, parent: UUID?, depth: Int, frame f: CGRect) -> Layer {
        let style = n.kind == .text ? n.style : nil
        return Layer(id: n.id, name: n.name, parent: parent, depth: depth, frame: f, rotation: n.rotation,
                     isContainer: n.isContainer, isText: n.kind == .text, hidden: n.hidden, locked: n.locked,
                     kind: n.kind.rawValue, isCopy: n.isCopy, opacity: n.opacity, cornerRadius: Double(n.cornerRadius),
                     cornersDiffer: n.corners != nil,
                     fill: Paint(on: n.fill.on, hex: hex(n.fill.color), alpha: n.fill.color.a, picture: n.fill.image != nil, gradient: n.fill.gradient != nil),
                     border: Paint(on: n.border.on, hex: hex(n.border.color), alpha: n.border.color.a, picture: n.border.image != nil, gradient: n.border.gradient != nil),
                     borderPosition: n.border.position.rawValue, borderWidth: Double(n.border.width),
                     fontFamily: style.map { $0.family == TextStyle.system ? "SF Pro" : $0.family }, fontFace: style?.face,
                     fontSize: style.map { Double($0.size) }, text: n.kind == .text ? n.text : nil,
                     shadowOn: n.shadow.on, shadowY: Double(n.shadow.y), shadowBlur: Double(n.shadow.blur))
    }

    private static func hex(_ c: RGBA) -> String {
        func two(_ v: Double) -> String {
            let n = Int((min(max(v, 0), 1) * 255).rounded())
            return String(n, radix: 16, uppercase: true).count == 1 ? "0" + String(n, radix: 16, uppercase: true) : String(n, radix: 16, uppercase: true)
        }
        return two(c.r) + two(c.g) + two(c.b)
    }

    /// The artboards as they are now: their frames move as the design is edited.
    public static func boards() -> [Board] {
        guard let doc = design else { return [] }
        return doc.nodes.enumerated().filter { $0.element.isArtboard }.map {
            var board = Board(index: $0.offset, name: $0.element.name, frame: $0.element.frame)
            board.id = $0.element.id
            board.hidden = $0.element.hidden
            board.drawn = drawn(seen($0.element))
            if $0.element.isCarousel {
                board.slide = $0.element.slideSize
                board.slides = $0.element.slideCount
            }
            if $0.element.fill.on { board.fill = (hex($0.element.fill.color), Double($0.element.fill.color.a)) }
            return board
        }
    }

    public static func beginGesture() {
        beginChange()
        // While typing, a drag in a card goes on from the words as they are, as one change of the typing.
        if let t = typing { typingGestureBegins(t); return }
        if let doc = design { Editing.begin(doc) }
    }

    /// Moves layers by `dx`, `dy` points; inside a gesture, from where they were when it began.
    public static func move(_ ids: [UUID], dx: Double, dy: Double) {
        edit { d in for id in ids { d.update(id) { $0.frame.origin.x += CGFloat(dx); $0.frame.origin.y += CGFloat(dy) } } }
    }

    /// Gives a layer a new frame on its artboard (as `layers` measures frames); inside a gesture,
    /// from where it was when it began. As on the Mac, a text made wider wraps there, and one
    /// given a height keeps that height.
    public static func setFrame(_ id: UUID, board: Int, to frame: CGRect) {
        guard let doc = design, board >= 0, board < doc.nodes.count else { return }
        // On an artboard, counted from its corner; a layer on the canvas, from the canvas's.
        let origin = doc.nodes[board].isArtboard ? doc.nodes[board].frame.origin : .zero
        edit { d in
            guard let was = d.absoluteFrame(of: id) else { return }
            let to = CGRect(x: frame.minX + origin.x, y: frame.minY + origin.y, width: max(1, frame.width), height: max(1, frame.height))
            d.update(id) { n in
                n.frame = CGRect(x: n.frame.minX + to.minX - was.minX, y: n.frame.minY + to.minY - was.minY, width: to.width, height: to.height)
                if n.kind == .text, var style = n.style {
                    let wider = abs(to.width - was.width) > 0.01, taller = abs(to.height - was.height) > 0.01
                    if wider || taller { style.sizing = taller ? .fixed : .autoHeight }
                    n.style = style
                    n.refit()
                }
            }
        }
    }

    public static func delete(_ ids: [UUID]) {
        edit { d in for id in ids { _ = d.detach(id) } }
    }

    public static func endGesture() {
        if let t = typing { typingGestureEnds(t); return }
        if let doc = design { design = Editing.end(doc) }
    }

    /// The gesture taken back: the design as it was when it began, and no step made.
    public static func cancelGesture() {
        if let t = typing { typingGestureCancelled(t); return }
        Editing.gestureBase = nil
        guard let start = Editing.gestureStart else { return }
        design = start
        Editing.gestureStart = nil
    }

    @discardableResult public static func undo() -> Bool {
        beginChange()
        guard let doc = design, let back = Editing.undo(doc) else { return false }
        design = back
        return true
    }

    @discardableResult public static func redo() -> Bool {
        beginChange()
        guard let doc = design, let again = Editing.redo(doc) else { return false }
        design = again
        return true
    }

    static func edit(_ change: (inout BezzleDocument) -> Void) {
        // Someone else's design no longer shared is kept as it last was.
        guard !isReadOnly else { return }
        beginChange()
        guard let doc = design else { return }
        // While typing, each change goes on from the words as they are, not from where the typing
        // began, as the Mac's store edits; the typing is one step all the same.
        if let t = typing, t.nested == 0 { Editing.gestureBase = doc }
        design = Editing.apply(to: doc, change)
    }
}

// MARK: - Tools and cards

extension WindowsCore {
    /// Draws a new layer as the Mac's tools do (CanvasView.createNode and finishCreating), inside
    /// the drag's gesture: made again each time from where the gesture began, so the whole drag is
    /// one step. `from` and `to` are on the canvas; `board` is the artboard it lands on (an artboard
    /// itself lies on the canvas). A click (`click`) makes a sensible size: the standard artboard,
    /// a line 100 long, text set where its first baseline begins, 100 × 100 for the rest.
    public static func draw(_ id: UUID, kind name: String, from a: CGPoint, to b: CGPoint, board: Int?, click: Bool, like: UUID? = nil) {
        guard let kind = Node.Kind(rawValue: name), let doc = Editing.gestureStart ?? design else { return }
        let boardID = kind == .artboard ? nil : board.flatMap { $0 < doc.nodes.count ? doc.nodes[$0].id : nil }
        let title = doc.nextName(for: kind)
        edit { d in
            var n = Node(kind: kind, name: title, frame: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            n.id = id
            switch kind {
            case .artboard where click:
                n.frame = CGRect(origin: a, size: Preset.standard.size)
            case .line:
                n.setLineEnds(a, click ? CGPoint(x: a.x + 100, y: a.y) : b)
            case .text:
                n.text = ""
                // New text looks as the text that was selected, as XD and the Mac have it.
                if let like, let l = doc.node(like), l.kind == .text, var style = l.style {
                    style.vertical = nil
                    n.style = style
                    n.fill = l.fill
                }
                if click {
                    n.style?.sizing = .autoWidth
                    n.frame = CGRect(origin: a, size: .zero)
                    n.refit()
                    var probe = n
                    probe.text = "X"
                    n.frame.origin.y -= TextLayout.firstBaseline(probe).rounded()
                } else {
                    n.style?.sizing = .autoHeight
                    n.frame.size.width = max(n.frame.width, 20)
                    n.refit()
                }
            default:
                if click { n.frame = CGRect(origin: a, size: CGSize(width: 100, height: 100)) }
            }
            d.attach(n, to: boardID)
        }
    }

    /// Types into a text: its words, its spans (letter styles) kept with the letters they were on,
    /// and its frame fitted to them, as the web editor did (WebEditing's "text").
    public static func setText(_ id: UUID, _ words: String) {
        edit { d in
            d.update(id) { n in
                guard n.kind == .text else { return }
                n.text = words
                n.spans = n.spans.flatMap { TextSpan.stored(TextSpan.aligned($0, onto: words)) }
                n.refit()
            }
        }
    }

    public static func text(of id: UUID) -> String? { design?.node(id)?.text }

    public static func setOpacity(_ ids: [UUID], _ value: Double) {
        edit { d in for id in ids { d.update(id) { $0.opacity = min(max(value, 0), 1) } } }
    }

    public static func setCornerRadius(_ ids: [UUID], _ value: Double) {
        edit { d in for id in ids { d.update(id) { $0.cornerRadius = CGFloat(max(0, value)); $0.corners = nil } } }
    }

    /// The frame the Frame card shows (the shared `selectionFrame`): one layer's own (a group's
    /// as it is seen turned), the box round several in what they share.
    public static func selectionFrame(_ ids: [UUID]) -> CGRect? { design?.selectionFrame(ids) }

    /// The frame a change starts from: inside a gesture, as it was when the gesture began, since
    /// each step is made again from there.
    private static func startFrame(_ ids: [UUID]) -> CGRect? {
        (Editing.gestureStart ?? design)?.selectionFrame(ids)
    }

    /// Layers at a new width or height, as the Mac's Frame card sizes them (SelectionInspector
    /// setSize): in proportion when asked; one by the shared `Node.resize`, several stretched
    /// together in their box (`BezzleDocument.place`). An artboard's design is laid out again for
    /// its new size (the shared Adapting).
    public static func setSize(_ ids: [UUID], width: Double? = nil, height: Double? = nil, keepingProportions: Bool = false) {
        guard let f = startFrame(ids), f.width >= 0, f.height >= 0 else { return }
        var w = width.map { CGFloat($0) } ?? f.width, h = height.map { CGFloat($0) } ?? f.height
        if keepingProportions, f.width > 0, f.height > 0 {
            if width != nil { h = (w * f.height / f.width).rounded() } else { w = (h * f.width / f.height).rounded() }
        }
        let size = CGSize(width: max(0, w), height: max(0, h)), byHeight = height != nil
        // An artboard's design is laid out again for its new size, as the Mac's Frame card does
        // (SelectionInspector.resize); a carousel keeps whole slides.
        if ids.count == 1 {
            edit { d in
                d.update(ids[0]) { n in
                    if n.isArtboard, !n.isCarousel { n = Adapting.resized(n, to: size) } else { n.resize(to: size, byHeight: byHeight) }
                }
            }
        } else {
            edit { $0.place(ids, from: f, to: CGRect(origin: f.origin, size: size)) { Adapting.resized($0, to: $1) } }
        }
    }

    /// Layers moved so their frame's corner is at `x`, `y` (the Mac's Frame card's X and Y).
    public static func setPlace(_ ids: [UUID], x: Double? = nil, y: Double? = nil) {
        guard let f = startFrame(ids) else { return }
        let dx = x.map { CGFloat($0) - f.minX } ?? 0, dy = y.map { CGFloat($0) - f.minY } ?? 0
        edit { d in for id in ids { d.update(id) { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) } } }
    }

    /// Mirrors layers where they are (the shared `BezzleDocument.flip`).
    public static func flip(_ ids: [UUID], horizontally: Bool) {
        edit { $0.flip(ids, horizontally: horizontally) }
    }

    /// Whether flipping them would change them.
    public static func canFlip(_ ids: [UUID]) -> Bool { design?.canFlip(ids) ?? false }

    /// Layers turned to `degrees` (the shared `Node.turn`).
    public static func setRotation(_ ids: [UUID], _ degrees: Double) {
        edit { d in for id in ids { d.update(id) { $0.turn(to: degrees) } } }
    }

    /// A fill of one colour, as six hex digits (with an alpha 0…1), on.
    public static func setFill(_ ids: [UUID], hex: String, alpha: Double) {
        guard let c = rgba(hex, alpha) else { return }
        edit { d in for id in ids { d.update(id) { $0.fill.color = c; $0.fill.on = true; $0.fill.gradient = nil; $0.fill.image = nil } } }
    }

    public static func setFillOn(_ ids: [UUID], _ on: Bool) {
        edit { d in for id in ids { d.update(id) { $0.fill.on = on } } }
    }

    public static func setBorder(_ ids: [UUID], on: Bool? = nil, width: Double? = nil, hex: String? = nil) {
        let c = hex.flatMap { rgba($0, 1) }
        edit { d in
            for id in ids {
                d.update(id) { n in
                    if let on { n.border.on = on }
                    if let width { n.border.width = CGFloat(max(0, width)) }
                    if let c { n.border.color = c }
                }
            }
        }
    }

    public static func setFontSize(_ ids: [UUID], _ size: Double) {
        edit { d in
            for id in ids {
                d.update(id) { n in
                    guard n.kind == .text, var style = n.style, size > 0 else { return }
                    style.size = CGFloat(size)
                    n.style = style
                    n.refit()
                }
            }
        }
    }

    private static func rgba(_ hex: String, _ alpha: Double) -> RGBA? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return RGBA(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: min(max(alpha, 0), 1))
    }
}

extension WindowsCore {
    /// The artboard with this id, by its index among the design's layers.
    public static func boardIndex(of id: UUID) -> Int? { design?.nodes.firstIndex { $0.id == id } }
}

extension WindowsCore {
    public static func setShadow(_ ids: [UUID], on: Bool) {
        edit { d in for id in ids { d.update(id) { $0.shadow.on = on } } }
    }
}
