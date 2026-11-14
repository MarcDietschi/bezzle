import SwiftUI
import AppKit

/// The selected layers as a stack of cards, one for each thing they have: where they are first,
/// then what they are, then how they look. What they could have and do not waits below as dashed
/// cards. See `AspectCard`.
struct SelectionInspector: View {
    let store: DocumentStore
    @State var lockAspect = false
    /// Names for the cards of a pile of fills, borders or shadows, and the one picked up off it.
    @State var lookKeys = LookKeys()
    @State var restacking: Restacking?
    @State var cardHeights: [Int: CGFloat] = [:]

    /// In Animate: only the cards for how the layers look, showing them as they look at the
    /// playhead and keying there what they change (`filmLooks`).
    var filming = false

    var nodes: [Node] { filming ? store.lookedSelection : store.selectedNodes }

    /// The value all the selected layers share, or nil when they differ.
    func common<T: Equatable>(_ value: (Node) -> T) -> T? {
        guard let first = nodes.first.map(value) else { return nil }
        return nodes.allSatisfy { value($0) == first } ? first : nil
    }

    var body: some View {
        let nodes = nodes
        // On its way out after a delete, the panel can be asked once more for layers that are gone.
        if filming {
            if !nodes.isEmpty { filmLooks(nodes) }
        } else if let first = nodes.first {
            content(nodes, first: first)
                .onChange(of: store.selection) { lockAspect = false }
                // What is being worked on, on the canvas, opens the card that works it.
                .onChange(of: store.editingPath) { _, id in if id != nil { open(.path) } }
                .onChange(of: store.editingPicture) { _, id in if id != nil { open(.fill(0)) } }
                .onChange(of: store.building != nil) { _, on in if on { open(.arrange) } }
        }
    }

    private func open(_ aspect: Aspect) {
        withAnimation(Theme.unfold) { store.openAspect = aspect }
    }

    @ViewBuilder private func content(_ nodes: [Node], first: Node) -> some View {
        let kinds = Set(nodes.map(\.kind))
        let onlyArtboards = kinds == [.artboard]
        // Lines are all border and text is all colour, so those cannot be taken away from them.
        let fills = kinds.isDisjoint(with: [.artboard, .line, .group]), borders = kinds.isDisjoint(with: [.artboard, .text, .group])
        let live = liveAspects(nodes)
        VStack(alignment: .leading, spacing: 8) {
            if nodes.count > 1 && !onlyArtboards {
                arrangeCard(count: nodes.count, shapes: kinds.isSubset(of: [.rectangle, .ellipse, .path]))
            }
            frameCard(first: first, live: live.contains(.frame))
            if onlyArtboards && nodes.count == 1 {
                artboardCard(first)
                backgroundCard(first, live: live.contains(.fill(0)))
                if DocumentStore.develops(first) { PhotoCard(store: store, nodes: [first], live: live.contains(.photo)) }
                if first.isDeck { DeckCard(store: store, board: first) }
                if first.layout != nil {
                    LayoutCard(store: store, board: first, live: live.contains(.layout))
                        .transition(.card)
                }
                if first.guides?.isEmpty == false {
                    GuidesCard(store: store, board: first)
                        .transition(.card)
                }
                if first.dark != nil {
                    DarkCard(store: store, board: first)
                        .transition(.card)
                }
            }
            if nodes.count == 1, let copy = store.doc.copy(holding: first.id) {
                ComponentCard(store: store, copy: copy, whole: copy.id == first.id)
                if copy.id != first.id, first.own?.isEmpty == false { CopyLayerCard(store: store, node: first) }
            }
            if nodes.count == 1, first.isRepeatGrid {
                RepeatGridCard(store: store, grid: first, live: live.contains(.grid))
            } else if nodes.count == 1, let grid = store.grid(holding: first.id) {
                GridCellCard(store: store, node: first, grid: grid)
            }
            if nodes.count == 1, first.isMask {
                MaskCard(store: store, group: first)
            } else if nodes.count == 1, let mask = store.doc.parent(of: first.id), mask.isMask, mask.children.first?.id != first.id {
                MaskedLayerCard(store: store, node: first, group: mask)
            }
            if nodes.count == 1, store.vector(of: first.id) != nil {
                VectorCard(store: store, group: first)
                    .transition(.card)
            }
            if nodes.count == 1, store.doc.post(of: first.id)?.post != nil, first.own?.isEmpty == false {
                PostLayerCard(store: store, node: first)
            }
            if kinds == [.text] { TextCard(store: store, nodes: nodes, live: live.contains(.text)) }
            // Words along a curve: bent ones, or ones riding a shape, but not both at once.
            if kinds == [.text], nodes.allSatisfy({ $0.curve != nil }), nodes.allSatisfy(\.rides) || !nodes.contains(where: \.rides) {
                CurveCard(store: store, nodes: nodes, live: live.contains(.curve))
                    .transition(.card)
            }
            if kinds == [.path] { PathCard(store: store, nodes: nodes) }
            if kinds == [.rectangle] { cornersCard(live: live.contains(.corners)) }
            if !onlyArtboards {
                opacityCard(live: live.contains(.opacity))
                // Only what the layers have; the rest waits below as dashed cards.
                // A pile of each kind there is several of, the top one first.
                let firstFill = kinds.contains(.text) || common { $0.fill.on } != false
                if fills && (firstFill || topSlot(.fill) > 0) {
                    pile(.fill, first: firstFill) { slot, restack in
                        fillCard(slot: slot, removable: !kinds.contains(.text), live: live.contains(.fill(slot)), restack: restack)
                    }
                    .transition(.card)
                }
                // What the pictures have of light, colour and detail, when every layer shows one.
                if nodes.allSatisfy(DocumentStore.develops) {
                    PhotoCard(store: store, nodes: nodes, live: live.contains(.photo))
                        .transition(.card)
                }
                let firstBorder = kinds.contains(.line) || common { $0.border.on } != false
                if borders && (firstBorder || topSlot(.border) > 0) {
                    pile(.border, first: firstBorder) { slot, restack in
                        borderCard(slot: slot, lineOnly: kinds == [.line], removable: !kinds.contains(.line), live: live.contains(.border(slot)), restack: restack)
                    }
                    .transition(.card)
                }
                let firstShadow = common { $0.shadow.on } != false
                if firstShadow || topSlot(.shadow) > 0 {
                    pile(.shadow, first: firstShadow) { slot, restack in
                        shadowCard(slot: slot, canInset: !kinds.contains(.line), canSpread: kinds.isSubset(of: [.rectangle, .ellipse, .path, .line]),
                                   live: live.contains(.shadow(slot)), restack: restack)
                    }
                    .transition(.card)
                }
                if common({ $0.blur?.on == true }) != false {
                    blurCard(canBlurBehind: kinds.isSubset(of: [.rectangle, .ellipse, .path]), live: live.contains(.blur))
                        .transition(.card)
                }
                if common({ $0.transform3D != nil }) != false {
                    depthCard(live: live.contains(.depth))
                        .transition(.card)
                }
                if common({ $0.exports?.isEmpty == false }) != false {
                    ExportCard(store: store, nodes: nodes)
                        .transition(.card)
                }
                let missing = curveOffer(nodes, kinds: kinds) + vectorOffer(nodes)
                    + addable(fill: fills && !kinds.contains(.text), border: borders && !kinds.contains(.line), inset: !kinds.contains(.line))
                if !missing.isEmpty {
                    AddBar(items: missing)
                        .padding(.top, 6)
                        .transition(.unfold)
                }
            } else {
                if common({ $0.exports?.isEmpty == false }) != false {
                    ExportCard(store: store, nodes: nodes)
                        .transition(.card)
                }
                // What an artboard can gain: a layout grid, and being marked for export.
                let more = [addLayout(nodes), addDark(nodes)].compactMap { $0 } + [markForExport].compactMap { $0 }
                if !more.isEmpty {
                    AddBar(items: more)
                        .padding(.top, 6)
                        .transition(.unfold)
                }
            }
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 14)
        .animation(Theme.unfold, value: nodes.map(\.fill.on))
        .animation(Theme.unfold, value: nodes.map { $0.curve != nil })
        .animation(Theme.unfold, value: nodes.map(\.border.on))
        .animation(Theme.unfold, value: nodes.map { $0.layout != nil })
        .animation(Theme.unfold, value: nodes.map { $0.guides?.isEmpty == false })
        .animation(Theme.unfold, value: nodes.map(\.dark))
        .animation(Theme.unfold, value: nodes.map(\.shadow.on))
        .animation(Theme.unfold, value: nodes.map { Look.allCases.map($0.slots) })
        .animation(Theme.unfold, value: nodes.map { $0.blur?.on == true })
        .animation(Theme.unfold, value: nodes.map { $0.blur?.ramp != nil })
        .animation(Theme.unfold, value: nodes.map { $0.transform3D != nil })
        .animation(Theme.unfold, value: nodes.map { $0.exports != nil })
        .animation(Theme.unfold, value: store.editingPath)
        .animation(Theme.unfold, value: store.building != nil)
        .animation(Theme.unfold, value: store.editingPicture)
        .animation(Theme.unfold, value: store.livePoints.isEmpty)
    }

    /// What a drag going on has changed so far, on the canvas or in a field, so the card it
    /// changes lifts while it goes on.
    private func liveAspects(_ nodes: [Node]) -> Set<Aspect> {
        guard let before = store.gestureBefore else { return [] }
        var live = Set<Aspect>()
        for n in nodes {
            guard let was = before.node(n.id), was != n else { continue }
            if was.frame != n.frame || was.rotation != n.rotation { live.insert(.frame) }
            if was.radii != n.radii || was.cornerSmoothing != n.cornerSmoothing { live.insert(.corners) }
            if was.opacity != n.opacity { live.insert(.opacity) }
            for slot in 0..<max(was.slots(.fill), n.slots(.fill)) where was[fill: slot] != n[fill: slot] { live.insert(.fill(slot)) }
            for slot in 0..<max(was.slots(.border), n.slots(.border)) where was[border: slot] != n[border: slot] { live.insert(.border(slot)) }
            for slot in 0..<max(was.slots(.shadow), n.slots(.shadow)) where was[shadow: slot] != n[shadow: slot] { live.insert(.shadow(slot)) }
            if was.blur != n.blur { live.insert(.blur) }
            if was.curve != n.curve { live.insert(.curve) }
            if was.fill.image?.develop != n.fill.image?.develop { live.insert(.photo) }
            if was.transform3D != n.transform3D { live.insert(.depth) }
            if was.style != n.style { live.insert(.text) }
            if was.grid != n.grid { live.insert(.grid) }
            if was.layout != n.layout { live.insert(.layout) }
        }
        return live
    }

    /// A field for one property of every selected layer: it shows the value they share, and
    /// what is typed into it applies to each, so "+2" adds two to every layer's own.
    func layerField(_ label: LocalizedStringResource, unit: String = "", range: ClosedRange<Double> = 0...10_000, scrub: Double = 1,
                    decimals: Int = 1, action: LocalizedStringResource,
                    get: @escaping (Node) -> Double, set: @escaping (inout Node, Double) -> Void) -> NumberField {
        NumberField(label: label, value: common(get), unit: unit, range: range, scrub: scrub, decimals: decimals, action: action) { v in
            store.updateSelection(action) { set(&$0, v) }
        } each: { f in
            store.updateSelection(action) { n in set(&n, f(get(n))) }
        }
    }

    /// A number as a summary says it: whole when it is, otherwise to a tenth.
    static func said(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : r.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    static func said(_ v: CGFloat) -> String { said(Double(v)) }

    /// Several layers that differ in what a card says.
    static var several: String { String(localized: "Several") }

    // MARK: Arranging several

    private func arrangeCard(count: Int, shapes: Bool) -> some View {
        AspectCard(aspect: .arrange, title: "Arrange", summary: String(localized: "\(count) layers")) {
            Image(systemName: "align.horizontal.left")
                .font(.system(size: 11.5, weight: .medium))
        } picks: {
            ArrangePicks(store: store, count: count, shapes: shapes)
        }
    }

    // MARK: Frame

    /// The selection's frame in its artboard: the layer's own for one (a group seen turned, its
    /// box along the turn), the box around them all for several.
    var frame: CGRect? { store.doc.selectionFrame(nodes.map(\.id)) }

    /// The artboard all the selected layers lie on, when they share one.
    private var board: Node? {
        let parents = Set(nodes.map { store.doc.parent(of: $0.id)?.id })
        guard parents.count == 1, let id = parents.first ?? nil, let parent = store.node(id), parent.isArtboard else { return nil }
        return parent
    }

    private static func turn(of n: Node) -> Double {
        n.grid?.turn ?? (n.isGroup ? BezzleDocument.turn(of: n) : n.rotation)
    }

    /// Where the layers are and how big: folded, its numbers in a line; a sideways drag scales
    /// them, keeping their proportions, and clicks at a quarter, a third, half and all of the
    /// artboard's width. Open, the exact numbers, and for one layer on an artboard, the artboard
    /// in small to drag it into place on.
    private func frameCard(first: Node, live: Bool) -> some View {
        let f = frame
        let single = nodes.count == 1 ? first : nil
        let turn = single?.isArtboard == true ? nil : common(Self.turn)
        var summary = f.map { "\(Self.said($0.width)) × \(Self.said($0.height)) · \(Self.said($0.minX)), \(Self.said($0.minY))" } ?? ""
        if let turn, turn != 0 { summary += " · ↻ \(Self.said(turn))°" }
        let board = board
        return AspectCard(aspect: .frame, title: "Frame", summary: summary, dial: frameDial(f, board: board), live: live) {
            FrameGlyph(size: CGSize(width: max(f?.width ?? 1, 1), height: max(f?.height ?? 1, 1)), box: 15)
        } picks: {
            transform
            if let single, !single.isArtboard, !single.locked, let board, let f {
                PlacePad(board: board, frame: f) { p in move(x: Double(p.x), y: Double(p.y)) }
            }
        }
    }

    private func frameDial(_ f: CGRect?, board: Node?) -> Dial? {
        guard let f, f.width > 0, f.height > 0, nodes.allSatisfy({ !$0.locked && !$0.isArtboard }) else { return nil }
        let whole = board.map { Double($0.frame.width) }
        let stops = whole.map { w in [w / 4, w / 3, w / 2, w].map { $0.rounded() } } ?? []
        let top = max(Double(f.width) * 2, (whole ?? 0) * 1.5, 100)
        return Dial(value: Double(f.width), range: 1...top, stops: stops, step: 1, action: "Resize") { v in
            setSize(width: v.rounded(), keepingProportions: true)
        }
    }

    @ViewBuilder private var transform: some View {
        let f = frame
        let single = nodes.count == 1 ? nodes[0] : nil
        VStack(alignment: .leading, spacing: 8) {
            Pair(sizeField(f, width: true), sizeField(f, width: false), between: AspectLock(locked: $lockAspect))
            Pair(placeField(f, x: true), placeField(f, x: false))
            if single?.isArtboard != true {
                Pair(layerField(.verbatim("↻"), unit: "°", range: -360...360, scrub: 0.5, action: "Rotate",
                                get: Self.turn, set: Self.rotate),
                     flipButtons)
            }
        }
    }

    private func sizeField(_ f: CGRect?, width: Bool) -> NumberField {
        NumberField(label: width ? "W" : "H", value: f.map { Double(width ? $0.width : $0.height) }, range: 0...100_000, action: "Resize") { v in
            if width { setSize(width: v) } else { setSize(height: v) }
        } each: { e in resizeEach(e, width: width) }
    }

    private func placeField(_ f: CGRect?, x: Bool) -> NumberField {
        NumberField(label: x ? "X" : "Y", value: f.map { Double(x ? $0.minX : $0.minY) }, action: "Move") { v in
            if x { move(x: v) } else { move(y: v) }
        } each: { e in moveEach(e, x: x) }
    }

    private var flipButtons: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally", size: Theme.controlHeight) {
                store.flip(horizontally: true)
            }
            IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertically", size: Theme.controlHeight) {
                store.flip(horizontally: false)
            }
        }
        .opacity(store.canFlip ? 1 : 0.35)
        .allowsHitTesting(store.canFlip)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func move(x: Double? = nil, y: Double? = nil) {
        guard let f = frame else { return }
        let dx = x.map { CGFloat($0) - f.minX } ?? 0, dy = y.map { CGFloat($0) - f.minY } ?? 0
        store.updateSelection("Move") { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) }
    }

    /// The size of each selected layer's artboard, for shares such as "50%".
    private var wholes: [UUID: CGSize] {
        Dictionary(uniqueKeysWithValues: store.selection.compactMap { id in store.doc.parent(of: id).map { (id, $0.frame.size) } })
    }

    /// A typed change to each layer's own place: "+10" moves every one by ten, "50%" puts each
    /// halfway across its artboard.
    private func moveEach(_ f: EachValue, x: Bool) {
        let wholes = wholes
        store.updateSelection("Move") { n in
            let whole = wholes[n.id]
            if x {
                n.frame.origin.x = CGFloat(f(Double(n.frame.minX), whole: whole.map { Double($0.width) })).rounded()
            } else {
                n.frame.origin.y = CGFloat(f(Double(n.frame.minY), whole: whole.map { Double($0.height) })).rounded()
            }
        }
    }

    /// A typed change to each layer's own size: "×2" doubles every one, "50%" makes each half as
    /// wide as its artboard. With the proportions kept, the other side follows.
    private func resizeEach(_ f: EachValue, width: Bool) {
        let wholes = wholes, lock = lockAspect
        store.updateSelection("Resize") { n in
            let old = n.frame.size, whole = wholes[n.id]
            var size = old
            if width {
                size.width = CGFloat(f(Double(old.width), whole: whole.map { Double($0.width) })).rounded()
            } else {
                size.height = CGFloat(f(Double(old.height), whole: whole.map { Double($0.height) })).rounded()
            }
            if lock, old.width > 0, old.height > 0 {
                if width { size.height = (size.width * old.height / old.width).rounded() } else { size.width = (size.height * old.width / old.height).rounded() }
            }
            Self.resize(&n, to: size, byHeight: !width)
        }
    }

    /// A layer turned to a new angle (`Node.turn`, shared with the other Bezzles).
    static func rotate(_ n: inout Node, to degrees: Double) {
        n.turn(to: degrees)
    }

    /// A layer at a new size (`Node.resize`, shared). An artboard's design is laid out again for
    /// its new size; a carousel, an artboard too, keeps whole slides instead.
    static func resize(_ n: inout Node, to size: CGSize, byHeight: Bool) {
        if n.isArtboard, !n.isCarousel {
            n = Adapting.resized(n, to: size)
            Adapting.announce([n.id])
            return
        }
        n.resize(to: size, byHeight: byHeight)
    }

    /// Sizes the selection, keeping its proportions when the lock is closed or `keepingProportions`.
    private func setSize(width: Double? = nil, height: Double? = nil, keepingProportions: Bool = false) {
        guard let f = frame, f.width >= 0, f.height >= 0 else { return }
        var w = width.map { CGFloat($0) } ?? f.width, h = height.map { CGFloat($0) } ?? f.height
        if lockAspect || keepingProportions, f.width > 0, f.height > 0 {
            if width != nil { h = (w * f.height / f.width).rounded() } else { w = (h * f.width / f.height).rounded() }
        }
        let target = CGRect(x: f.minX, y: f.minY, width: w, height: h)
        if nodes.count == 1 {
            store.updateSelection("Resize") { Self.resize(&$0, to: CGSize(width: w, height: h), byHeight: height != nil) }
        } else {
            let ids = store.selection
            store.edit("Resize") { doc in Self.place(&doc, ids, from: f, to: target) }
            Adapting.announce(ids.filter { store.doc.node($0)?.isArtboard == true })
        }
    }

    /// Layers given a new box together, each keeping its place in it. The box is in their shared
    /// artboard's coordinates, or on the canvas. An artboard among them has its design laid out
    /// again for its new size.
    static func place(_ doc: inout BezzleDocument, _ ids: [UUID], from f: CGRect, to target: CGRect) {
        doc.place(ids, from: f, to: target) { Adapting.resized($0, to: $1) }
    }

    // MARK: Artboard

    /// What the artboard is: its size, or a carousel's format and slides, and whether it clips.
    private func artboardCard(_ board: Node) -> some View {
        var summary = String(localized: Preset.matching(board.frame.size)?.title ?? "Custom")
        if board.isCarousel {
            let format = board.slideSize.flatMap(Carousel.format(of:))
            let slides = board.slideCount
            summary = [format.map { String(localized: $0.title) } ?? board.slideSize.map { "\(Self.said($0.width)) × \(Self.said($0.height))" },
                       slides == 1 ? String(localized: "\(slides) slide") : String(localized: "\(slides) slides")]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return AspectCard(aspect: .artboard, title: board.isCarousel ? "Carousel" : "Artboard", summary: summary) {
            FrameGlyph(size: board.frame.size, box: 15, slides: board.isCarousel ? board.slideCount : 1)
        } picks: {
            VStack(alignment: .leading, spacing: 8) {
                if board.isCarousel {
                    carouselRows(board)
                } else {
                    Row(title: "Size") {
                        let current = Preset.matching(board.frame.size)
                        MenuButton(id: "artboard-size", title: current?.title ?? "Custom", width: 230, fills: true) {
                            Preset.Group.allCases.enumerated().flatMap { i, group in
                                (i > 0 ? [MenuEntry.separator] : []) + [MenuEntry.note(group.title)]
                                    + Preset.all(in: group).map { p in
                                        MenuEntry.item(p.title, detail: .verbatim("\(Int(p.size.width)) × \(Int(p.size.height))"), checked: p == current,
                                                       preview: { on in showSize(on ? p.size : nil, of: board) }) {
                                            store.showPreview(Self.sizePreview, reshaping: nil)
                                            store.resizeArtboards(store.selection) { _ in p.size }
                                        }
                                    }
                            }
                            + [.separator]
                            // Its layers stay where they are on it.
                            + Carousel.formats.map { f in
                                MenuEntry.item("Carousel, \(f.title)", detail: .verbatim("\(Int(f.size.width)) × \(Int(f.size.height))")) {
                                    store.updateSelection("Make Carousel") { n in
                                        n.slideSize = f.size
                                        n.frame.size = n.carouselSize(count: max(Carousel.startingCount, Int((n.frame.width / f.size.width).rounded())))
                                    }
                                }
                            }
                        }
                    }
                }
                if !board.isCarousel {
                    Row(title: "Adapt layout") {
                        Switch(isOn: Binding(get: { board.pinsLayers != true }, set: { v in
                            store.updateSelection(v ? "Adapt Layout" : "Keep Layers in Place") { $0.pinsLayers = v ? nil : true }
                        }))
                    }
                    .onAppear { Adapting.prepare(board, assets: store.assets) }
                }
                Row(title: "Clip content") {
                    Switch(isOn: Binding(get: { board.clips }, set: { v in store.updateSelection(v ? "Clip Content" : "Show Overflow") { $0.clips = v } }))
                }
            }
        }
    }

    static let sizePreview = "artboard-size"

    /// Shows on the canvas the artboard at a size it could take, its design laid out for it; with
    /// nil, as it is.
    private func showSize(_ size: CGSize?, of board: Node) {
        if let size, let change = store.adaptedPreview(of: board.id, to: size) {
            store.showPreview(Self.sizePreview, reshaping: change)
        } else {
            store.showPreview(Self.sizePreview, reshaping: nil)
        }
        Adapting.announce([board.id])
    }

    /// A carousel's slide size and how many slides it has. Its layers stay where they are on it
    /// when either changes: those past the last slide stay too, out of sight, until it grows again.
    @ViewBuilder private func carouselRows(_ board: Node) -> some View {
        let format = board.slideSize.flatMap(Carousel.format(of:))
        let count = board.slideCount
        Row(title: "Format") {
            MenuButton(id: "carousel-format", title: format?.title ?? LocalizedStringResource("carousel.custom-format", defaultValue: "Custom", comment: "A carousel slide size that is none of the formats."), width: 250, fills: true) {
                Carousel.formats.map { f in
                    MenuEntry.item(f.title, detail: .verbatim("\(Int(f.size.width)) × \(Int(f.size.height))"), checked: f.size == board.slideSize) {
                        store.updateSelection("Change Format") { $0.setSlideSize(f.size) }
                    }
                }
                + [.separator, MenuEntry.item("Plain artboard") { store.updateSelection("Make Artboard") { $0.slideSize = nil } }]
            }
        }
        Pair(slideField(board, width: true), slideField(board, width: false))
        Row(title: "Slides") {
            IconButton(symbol: "minus", help: "One slide fewer", size: Theme.controlHeight) { changeSlides("Remove Slide") { $0 - 1 } }
                .opacity(count > Carousel.counts.lowerBound ? 1 : 0.35)
                .allowsHitTesting(count > Carousel.counts.lowerBound)
            NumberField(label: "", value: Double(count), range: Double(Carousel.counts.lowerBound)...Double(Carousel.counts.upperBound),
                        scrub: 0.05, decimals: 0, action: "Change Slides") { v in
                changeSlides("Change Slides") { _ in Int(v.rounded()) }
            }
            IconButton(symbol: "plus", help: "One slide more", size: Theme.controlHeight) { changeSlides("Add Slide") { $0 + 1 } }
                .opacity(count < Carousel.counts.upperBound ? 1 : 0.35)
                .allowsHitTesting(count < Carousel.counts.upperBound)
        }
        if let format {
            Caption("For \(format.platforms). Up to \(Carousel.counts.upperBound) slides.")
        }
    }

    /// A carousel's slides' width or height, which sets their proportions, whatever the format.
    private func slideField(_ board: Node, width: Bool) -> NumberField {
        let slide = board.slideSize ?? board.frame.size
        return NumberField(label: width ? "W" : "H", value: Double(width ? slide.width : slide.height), range: 1...100_000, action: "Change Format") { v in
            store.updateSelection("Change Format") { n in
                guard let s = n.slideSize else { return }
                n.setSlideSize(width ? CGSize(width: v, height: s.height) : CGSize(width: s.width, height: v))
            }
        }
    }

    /// Adds slides at the right of the selected carousel, or takes them away from there.
    private func changeSlides(_ action: LocalizedStringResource, _ count: @escaping (Int) -> Int) {
        store.updateSelection(action) { n in
            guard n.isCarousel else { return }
            n.frame.size = n.carouselSize(count: count(n.slideCount))
        }
    }

    private func backgroundCard(_ board: Node, live: Bool) -> some View {
        AspectCard(aspect: .background, title: "Background", summary: Self.summary(of: board.fill, blend: nil), live: live) {
            FillSwatch(fill: board.fill, radius: 4)
                .frame(width: 15, height: 15)
        } picks: {
            fillControls(blends: true, action: "Change Background", suggest: false)
        }
    }

    /// A fill in a few words: its colour's hex and how much of it shows, or the kind of gradient,
    /// or a picture; and how it blends, when not as usual.
    static func summary(of fill: Fill?, blend: BlendMode??) -> String {
        guard let fill else { return several }
        var said: [String]
        switch FillKind(fill) {
        case .solid: said = ["#\(fill.color.hex)"] + (fill.color.a < 0.995 ? ["\(Int((fill.color.a * 100).rounded()))%"] : [])
        case .linear: said = [String(localized: "Linear")]
        case .radial: said = [String(localized: "Radial")]
        case .picture: said = [String(localized: "Picture")]
        }
        if let shader = fill.shader {
            said = [shader.moves ? String(localized: "Shader, moving") : String(localized: "Shader")]
        }
        switch blend {
        case .some(.some(let mode)): said.append(mode.title)
        case .some(.none), .none: break
        }
        return said.joined(separator: " · ")
    }
}

/// Lines several layers up with each other, and spaces them evenly; for shapes, the ways to make
/// them one, and building with the pieces they cut each other into.
struct ArrangePicks: View {
    let store: DocumentStore
    let count: Int
    let shapes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                button("align.horizontal.left", "Align left") { store.align(.left) }
                button("align.horizontal.center", "Align centres") { store.align(.centerX) }
                button("align.horizontal.right", "Align right") { store.align(.right) }
                button("align.vertical.top", "Align tops") { store.align(.top) }
                button("align.vertical.center", "Align middles") { store.align(.centerY) }
                button("align.vertical.bottom", "Align bottoms") { store.align(.bottom) }
                Spacer(minLength: 0)
                Group {
                    button("distribute.horizontal", "Space evenly across") { store.distribute(horizontally: true) }
                    button("distribute.vertical", "Space evenly down") { store.distribute(horizontally: false) }
                }
                .opacity(count >= 3 ? 1 : 0.35)
                .allowsHitTesting(count >= 3)
            }
            if shapes {
                HStack(spacing: 0) {
                    ForEach(DocumentStore.Combine.allCases, id: \.self) { how in
                        CombineButton(how: how) { store.combine(how) }
                    }
                    Color.clear.frame(width: 8, height: 1)
                    CombineButton(how: nil, on: store.building != nil) {
                        if store.building != nil { store.building = nil } else { store.startBuilding() }
                    }
                }
                .opacity(store.canCombine ? 1 : 0.35)
                .allowsHitTesting(store.canCombine)
                if store.building != nil {
                    Caption("Drag across pieces to join them into one shape, or click one to make it its own. Hold ⌥ to wipe pieces away.")
                        .padding(.top, 4)
                        .transition(.unfold)
                }
            }
        }
        .padding(.horizontal, -4)
    }

    private func button(_ symbol: String, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, help: help, size: 28, action: action)
    }
}
