import SwiftUI
import AppKit

/// The panel on the right: everything about the selected layers that can be set, and nothing
/// that does not apply to them. With nothing selected it offers artboard sizes and the tools' keys.
struct Inspector: View {
    let store: DocumentStore
    static let gutter: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.selectedNodes.isEmpty {
                    if store.tool == .artboard || store.doc.artboards.isEmpty {
                        PresetList(store: store)
                    } else {
                        NothingSelected(store: store)
                    }
                } else {
                    // Updated in place as the selection changes: making it anew each time is slow
                    // in a large design.
                    SelectionInspector(store: store)
                }
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 20)
    }
}

// MARK: - Nothing selected

private struct NothingSelected: View {
    let store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing selected")
                    .font(Theme.serif(19, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("Click a layer to change it, or draw something new.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    HStack(spacing: 10) {
                        ToolGlyph(tool: tool, size: 15)
                            .foregroundStyle(Theme.ink2)
                        Text(tool.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        KeyCap(tool.key)
                    }
                    .frame(height: 30)
                }
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 15)
                    Text("Move around")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    KeyCap("Space")
                }
                .frame(height: 30)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .card(radius: 12)
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 14)
    }
}

/// A key on the keyboard, pressed into the paper.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .well(radius: 5)
    }
}

/// Artboard sizes to add: a click puts one beside the others.
private struct PresetList: View {
    let store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Artboards")
                    .font(Theme.serif(19, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("Drag on the canvas for a size of your own, or pick one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 2) {
                ForEach(Preset.all) { preset in
                    PresetRow(preset: preset) { store.addArtboard(preset) }
                }
            }
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 14)
    }
}

struct PresetRow: View {
    let preset: Preset
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FrameGlyph(size: preset.size, box: 22)
            Text(preset.name)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(verbatim: "\(Int(preset.size.width)) × \(Int(preset.size.height))")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(Theme.quick, value: hovering)
    }
}

/// A sheet of the given proportions, fitted into a square box.
struct FrameGlyph: View {
    let size: CGSize
    var box: CGFloat = 22

    var body: some View {
        let s = box / max(size.width, size.height)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.card)
            .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.ink2, lineWidth: 1.2) }
            .frame(width: max(size.width * s, 6), height: max(size.height * s, 6))
            .frame(width: box, height: box)
    }
}

extension DocumentStore {
    /// Adds an artboard of a preset size to the right of the others, and brings it into view.
    func addArtboard(_ preset: Preset) {
        let right = doc.artboards.map(\.frame.maxX).max()
        let top = doc.artboards.map(\.frame.minY).min() ?? 0
        let origin = right.map { CGPoint(x: $0 + 80, y: top) } ?? .zero
        let board = Node(kind: .artboard, name: doc.artboards.isEmpty ? preset.name : doc.nextName(for: .artboard),
                         frame: CGRect(origin: origin, size: preset.size))
        add(board, onto: nil)
        lastPreset = preset.size
        tool = .select
        if !visibleCanvasRect.contains(board.frame) { zoomToFit() }
    }
}

// MARK: - Selection

private struct SelectionInspector: View {
    let store: DocumentStore
    @State private var lockAspect = false

    private var nodes: [Node] { store.selectedNodes }

    /// The value all the selected layers share, or nil when they differ.
    private func common<T: Equatable>(_ value: (Node) -> T) -> T? {
        guard let first = nodes.first.map(value) else { return nil }
        return nodes.allSatisfy { value($0) == first } ? first : nil
    }

    var body: some View {
        let nodes = nodes
        // On its way out after a delete, the panel can be asked once more for layers that are gone.
        if let first = nodes.first {
            content(nodes, first: first)
                .onChange(of: store.selection) { lockAspect = false }
        }
    }

    @ViewBuilder private func content(_ nodes: [Node], first: Node) -> some View {
        let kinds = Set(nodes.map(\.kind))
        let onlyArtboards = kinds == [.artboard]
        // Lines are all border and text is all colour, so those cannot be taken away from them.
        let fills = kinds.isDisjoint(with: [.artboard, .line, .group]), borders = kinds.isDisjoint(with: [.artboard, .text, .group])
        VStack(alignment: .leading, spacing: 0) {
            Header(nodes: nodes, store: store)
            if !onlyArtboards {
                AlignBar(store: store, count: nodes.count, onBoard: nodes.count > 1 || store.doc.parent(of: first.id) != nil)
            }
            Block { transform }
            if kinds == [.rectangle] { Block { corners } }
            if kinds == [.text] { TextBlock(store: store, nodes: nodes) }
            if kinds == [.path] { PathBlock(store: store, nodes: nodes) }
            if onlyArtboards && nodes.count == 1 { artboardBlock(nodes[0]) }
            if !onlyArtboards {
                Block {
                    Row(title: "Opacity") {
                        layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Change Opacity",
                                   get: { $0.opacity * 100 }, set: { $0.opacity = $1 / 100 })
                    }
                }
                // Only what the layers have; the rest waits in the bar below.
                if fills && (kinds.contains(.text) || common { $0.fill.on } != false) {
                    fillBlock(removable: !kinds.contains(.text))
                }
                if borders && (kinds.contains(.line) || common { $0.border.on } != false) {
                    borderBlock(lineOnly: kinds == [.line], removable: !kinds.contains(.line))
                }
                if common({ $0.shadow.on }) != false { shadowBlock }
                if common({ $0.blur?.on == true }) != false { blurBlock(canBlurBehind: kinds.isSubset(of: [.rectangle, .ellipse, .path])) }
                let missing = addable(fill: fills && !kinds.contains(.text), border: borders && !kinds.contains(.line))
                if !missing.isEmpty {
                    Block { AddBar(items: missing) }
                        .transition(.unfold)
                }
            }
        }
        .animation(Theme.unfold, value: nodes.map(\.fill.on))
        .animation(Theme.unfold, value: nodes.map(\.border.on))
        .animation(Theme.unfold, value: nodes.map(\.shadow.on))
        .animation(Theme.unfold, value: nodes.map { $0.blur?.on == true })
        .animation(Theme.unfold, value: store.editingPath)
        .animation(Theme.unfold, value: store.livePoints.isEmpty)
    }

    /// A field for one property of every selected layer: it shows the value they share, and
    /// what is typed into it applies to each, so "+2" adds two to every layer's own.
    private func layerField(_ label: String, unit: String = "", range: ClosedRange<Double> = 0...10_000, scrub: Double = 1,
                            decimals: Int = 1, action: String,
                            get: @escaping (Node) -> Double, set: @escaping (inout Node, Double) -> Void) -> NumberField {
        NumberField(label: label, value: common(get), unit: unit, range: range, scrub: scrub, decimals: decimals, action: action) { v in
            store.updateSelection(action) { set(&$0, v) }
        } each: { f in
            store.updateSelection(action) { n in set(&n, f(get(n))) }
        }
    }

    // MARK: Position and size

    /// The selection's frame in its artboard: the layer's own for one, the box around them all for several.
    private var frame: CGRect? {
        if nodes.count == 1 { return nodes[0].frame }
        guard let bounds = store.selectionBounds else { return nil }
        let parents = Set(nodes.map { store.doc.parent(of: $0.id)?.id })
        if parents.count == 1, let p = parents.first ?? nil, let parent = store.doc.absoluteFrame(of: p) {
            return bounds.offsetBy(dx: -parent.minX, dy: -parent.minY)
        }
        return bounds
    }

    @ViewBuilder private var transform: some View {
        let f = frame
        let single = nodes.count == 1 ? nodes[0] : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                NumberField(label: "W", value: f.map { Double($0.width) }, range: 0...100_000, action: "Resize") { v in
                    setSize(width: v)
                } each: { e in resizeEach(e, width: true) }
                AspectLock(locked: $lockAspect)
                NumberField(label: "H", value: f.map { Double($0.height) }, range: 0...100_000, action: "Resize") { v in
                    setSize(height: v)
                } each: { e in resizeEach(e, width: false) }
            }
            HStack(spacing: 8) {
                NumberField(label: "X", value: f.map { Double($0.minX) }, action: "Move") { v in
                    move(x: v)
                } each: { e in moveEach(e, x: true) }
                Color.clear.frame(width: 18)
                NumberField(label: "Y", value: f.map { Double($0.minY) }, action: "Move") { v in
                    move(y: v)
                } each: { e in moveEach(e, x: false) }
            }
            if single?.isArtboard != true {
                HStack(spacing: 8) {
                    layerField("↻", unit: "°", range: -360...360, scrub: 0.5, action: "Rotate",
                               get: { $0.rotation }, set: { $0.rotation = CanvasView.normalized($1) })
                    Color.clear.frame(width: 18)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
    }

    private func move(x: Double? = nil, y: Double? = nil) {
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

    /// A layer at a new size. Text wraps its words to a new width, or grows its letters and lines.
    static func resize(_ n: inout Node, to size: CGSize, byHeight: Bool) {
        let old = n.frame
        if n.kind == .text, old.height > 0, old.width > 0 {
            n.resizeText(to: size, byHeight: byHeight)
        } else {
            // A group's layers stretch with it.
            if n.isGroup {
                n.children = BezzleDocument.scaled(n.children, from: old.size, to: size)
                n.mask = n.mask.map { BezzleDocument.scaled($0, from: old.size, to: size) }
            }
            n.frame.size = size
        }
    }

    private func setSize(width: Double? = nil, height: Double? = nil) {
        guard let f = frame, f.width >= 0, f.height >= 0 else { return }
        var w = width.map { CGFloat($0) } ?? f.width, h = height.map { CGFloat($0) } ?? f.height
        if lockAspect, f.width > 0, f.height > 0 {
            if width != nil { h = (w * f.height / f.width).rounded() } else { w = (h * f.width / f.height).rounded() }
        }
        let target = CGRect(x: f.minX, y: f.minY, width: w, height: h)
        if nodes.count == 1 {
            store.updateSelection("Resize") { Self.resize(&$0, to: CGSize(width: w, height: h), byHeight: height != nil) }
        } else {
            let ids = store.selection
            let parentOrigins = Dictionary(uniqueKeysWithValues: ids.map { ($0, store.doc.parentOrigin(of: $0)) })
            let shared = Set(ids.map { store.doc.parent(of: $0)?.id }).count == 1
            store.updateSelection("Resize") { n in
                // The box is in the shared artboard's coordinates, or on the canvas.
                let o = shared ? .zero : parentOrigins[n.id] ?? .zero
                let own = n.frame.offsetBy(dx: o.x, dy: o.y)
                n.frame = Geometry.snapToPixels(Geometry.map(own, from: f, to: target)).offsetBy(dx: -o.x, dy: -o.y)
            }
        }
    }

    // MARK: Corners

    /// How round the corners are, and whether they are plain arcs or squircles that run smoothly
    /// into the sides, and how smoothly.
    private var corners: some View {
        let smooth = nodes.allSatisfy { ($0.cornerSmoothing ?? 0) > 0 }
        return OptionBlock(title: "Corners") {
            HStack(spacing: 8) {
                PresetStrip(action: "Change Corners", items: Presets.corners.map { preset in
                    PresetItem(id: preset.id, name: preset.name,
                          active: nodes.allSatisfy { abs($0.cornerRadius - Presets.cornerRadius(preset.radius, for: $0)) < 0.5 }) {
                        $0.cornerRadius = Presets.cornerRadius(preset.radius, for: $0)
                    }
                }) { item in
                    CornerGlyph(radius: Presets.corners.first { $0.id == item.id }?.radius, smooth: smooth)
                }
                layerField("R", range: 0...10_000, action: "Change Corners", get: { Double($0.cornerRadius) }, set: { $0.cornerRadius = CGFloat($1) })
                    .frame(width: 66)
            }
            HStack(spacing: 8) {
                SegmentedWell(selection: Binding(get: { smooth }, set: { on in
                    store.updateSelection(on ? "Smooth Corners" : "Round Corners") { $0.cornerSmoothing = on ? Presets.squircle : nil }
                }), options: [(false, "Round"), (true, "Squircle")])
                layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Smooth Corners",
                           get: { Double(($0.cornerSmoothing ?? 0) * 100) }, set: { $0.cornerSmoothing = $1 > 0 ? CGFloat($1 / 100) : nil })
                    .frame(width: 66)
            }
        }
    }

    // MARK: Artboard

    @ViewBuilder private func artboardBlock(_ board: Node) -> some View {
        Block {
            VStack(alignment: .leading, spacing: 10) {
                Text("Background")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                fillControls(blends: true, action: "Change Background", suggest: false)
            }
        }
        Block {
            VStack(alignment: .leading, spacing: 10) {
                Row(title: "Size") {
                    MenuButton(id: "artboard-size", title: Preset.all.first { $0.size == board.frame.size }?.name ?? "Custom", width: 230) {
                        Preset.all.map { p in
                            MenuEntry.item(p.name, detail: "\(Int(p.size.width)) × \(Int(p.size.height))", checked: p.size == board.frame.size) {
                                store.updateSelection("Resize Artboard") { $0.frame.size = p.size }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                Row(title: "Clip content") {
                    Switch(isOn: Binding(get: { board.clips }, set: { v in store.updateSelection(v ? "Clip Content" : "Show Overflow") { $0.clips = v } }))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Fill, border, shadow

    /// What a layer could have and does not yet, as the bar at the foot of the panel offers it.
    private func addable(fill: Bool, border: Bool) -> [AddBar.Item] {
        var items: [AddBar.Item] = []
        if fill && common({ $0.fill.on }) == false {
            items.append(.init(id: "add-fill", title: "Fill") { $0.fill.on = true })
        }
        if border && common({ $0.border.on }) == false {
            items.append(.init(id: "add-border", title: "Border") { n in
                n.border.on = true
                if n.border.width == 0 { n.border.width = 1 }
            })
        }
        if common({ $0.shadow.on }) == false {
            items.append(.init(id: "add-shadow", title: "Shadow") { Presets.applyShadow(Presets.shadows[1], to: &$0) })
        }
        if common({ $0.blur?.on == true }) == false {
            items.append(.init(id: "add-blur", title: "Blur") { Presets.applyBlur(Presets.blurs[1].radius, to: &$0) })
        }
        return items
    }

    /// The design's colours that the selection is not already: one click away beside a colour.
    private func suggestions(besides color: RGBA?) -> [RGBA] {
        // A colour field shows the first few, of what can be hundreds.
        let own = color?.hex
        return Array(store.designColors.lazy.filter { $0.hex != own }.prefix(12))
    }

    private func fillBlock(removable: Bool) -> some View {
        // Text takes one colour; its letters are not drawn with a gradient.
        let blends = !nodes.contains { $0.kind == .text }
        return Block {
            OptionBlock(title: blends ? "Fill" : "Colour",
                        remove: removable ? { store.updateSelection("Remove Fill") { $0.fill.on = false } } : nil) {
                fillControls(blends: blends, action: "Change Fill", suggest: true)
            }
        }
        .transition(.unfold)
    }

    /// What fills the selection, a layer's or an artboard's background. Its swatch opens the fill
    /// menu, where one colour or a gradient is chosen and its colours; text takes one colour.
    @ViewBuilder private func fillControls(blends: Bool, action: String, suggest: Bool) -> some View {
        let color = common { $0.fill.color }
        let suggested = suggest ? suggestions(besides: color) : []
        let preview: (RGBA?) -> Void = { c in store.showPreview("fill-colour", c.map { c in { $0.fill.color = c; $0.fill.on = true } }) }
        let apply: (RGBA) -> Void = { c in store.updateSelection(action) { $0.fill.color = c; $0.fill.on = true } }
        if blends {
            FillField(fill: nodes[0].fill, color: color, action: action, suggestions: suggested, preview: preview, apply: apply)
        } else {
            ColorField(id: "fill", color: color, suggestions: suggested, action: action, preview: preview, apply: apply)
        }
    }

    private func borderBlock(lineOnly: Bool, removable: Bool) -> some View {
        let color = common { $0.border.color }
        return Block {
            OptionBlock(title: lineOnly ? "Line" : "Border",
                        remove: removable ? { store.updateSelection("Remove Border") { $0.border.on = false } } : nil) {
                PresetStrip(action: "Change Border", items: Presets.borders.map { preset in
                    PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { Presets.isBorder(preset.width, $0.border) }) {
                        Presets.applyBorder(preset.width, to: &$0)
                    }
                }) { item in
                    BorderGlyph(width: Presets.borders.first { $0.id == item.id }?.width ?? nil)
                }
                ColorField(id: "border", color: color, suggestions: suggestions(besides: color), action: "Change Border",
                           preview: { c in store.showPreview("border-colour", c.map { c in { $0.border.color = c; $0.border.on = true } }) }) { c in
                    store.updateSelection("Change Border") { $0.border.color = c; $0.border.on = true }
                }
            } exact: {
                HStack(spacing: 8) {
                    layerField("Size", range: 0...1000, scrub: 0.25, action: "Change Border",
                               get: { Double($0.border.width) }, set: { $0.border.width = CGFloat($1); $0.border.on = true })
                    layerField("Dash", range: 0...1000, scrub: 0.25, action: "Change Border", get: { Double($0.border.dash) }) { n, v in
                        n.border.dash = CGFloat(v)
                        if n.border.gap == 0 { n.border.gap = CGFloat(v) }
                    }
                    layerField("Gap", range: 0...1000, scrub: 0.25, action: "Change Border",
                               get: { Double($0.border.gap) }, set: { $0.border.gap = CGFloat($1) })
                }
                if !lineOnly {
                    IconChoice(selection: common { $0.border.position }, options: [
                        (.inside, "square.inset.filled", "Inside"),
                        (.center, "square.dashed", "Centred on the edge"),
                        (.outside, "square.fill", "Outside"),
                    ]) { p in store.updateSelection("Change Border") { $0.border.position = p } }
                }
            }
        }
        .transition(.unfold)
    }

    private var shadowBlock: some View {
        Block {
            OptionBlock(title: "Shadow",
                        remove: { store.updateSelection("Remove Shadow") { $0.shadow.on = false } }) {
                PresetStrip(action: "Change Shadow", items: Presets.shadows.map { preset in
                    PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { Presets.isShadow(preset, $0.shadow) }) {
                        Presets.applyShadow(preset, to: &$0)
                    }
                }) { item in
                    let preset = Presets.shadows.first { $0.id == item.id }
                    ShadowGlyph(y: preset?.y ?? 0, blur: preset?.blur ?? 0)
                }
                ColorField(id: "shadow", color: common { $0.shadow.color }, action: "Change Shadow") { c in
                    store.updateSelection("Change Shadow") { $0.shadow.color = c }
                }
            } exact: {
                HStack(spacing: 8) {
                    layerField("X", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                               get: { Double($0.shadow.x) }, set: { $0.shadow.x = CGFloat($1) })
                    layerField("Y", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                               get: { Double($0.shadow.y) }, set: { $0.shadow.y = CGFloat($1) })
                    layerField("B", range: 0...1000, scrub: 0.5, action: "Change Shadow",
                               get: { Double($0.shadow.blur) }, set: { $0.shadow.blur = CGFloat($1) })
                }
                Text("Or drag the shadow itself on the canvas.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .transition(.unfold)
    }

    /// A blur of the layer itself, or of what lies behind it, as frosted glass does; only shapes
    /// with an outline to show it through can blur what is behind them.
    private func blurBlock(canBlurBehind: Bool) -> some View {
        let behind = canBlurBehind && common { $0.blur?.background == true } == true
        return Block {
            OptionBlock(title: "Blur", remove: { store.updateSelection("Remove Blur") { $0.blur = nil } }) {
                if canBlurBehind {
                    SegmentedWell(selection: Binding(get: { behind }, set: { v in
                        store.updateSelection("Change Blur") { n in
                            Presets.applyBlur(n.blur?.radius ?? Presets.blurs[1].radius, to: &n)
                            n.blur?.background = v
                        }
                    }), options: [(false, "The layer"), (true, "What's behind")])
                }
                PresetStrip(action: "Change Blur", items: Presets.blurs.map { preset in
                    PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { $0.blur?.on == true && $0.blur?.radius == preset.radius }) {
                        Presets.applyBlur(preset.radius, to: &$0)
                    }
                }) { item in
                    let i = Presets.blurs.firstIndex { $0.id == item.id } ?? 0
                    BlurGlyph(amount: CGFloat(i) / CGFloat(max(Presets.blurs.count - 1, 1)), behind: behind)
                }
            } exact: {
                Row(title: "Amount") {
                    layerField("", range: 0...500, scrub: 0.25, action: "Change Blur",
                               get: { Double($0.blur?.radius ?? 0) }, set: { Presets.applyBlur(CGFloat($1), to: &$0) })
                }
                if behind {
                    Row(title: "Light") {
                        layerField("", unit: "%", range: -100...100, scrub: 0.5, decimals: 0, action: "Change Blur",
                                   get: { ($0.blur?.brightness ?? 0) * 100 }, set: { $0.blur?.brightness = $1 / 100 })
                    }
                    Row(title: "Fill") {
                        layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Change Blur",
                                   get: { ($0.blur?.fillOpacity ?? 0) * 100 }, set: { $0.blur?.fillOpacity = $1 / 100 })
                    }
                }
                if behind {
                    Text("Light brightens what shows through, or darkens it below zero. Fill is how much of the layer's own colour lies over it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .transition(.unfold)
    }
}

// MARK: - Path

/// What a path is, and while its points are being edited, where the picked ones are and how
/// the outline runs through them.
private struct PathBlock: View {
    let store: DocumentStore
    let nodes: [Node]

    var body: some View {
        let single = nodes.count == 1 && !nodes[0].locked ? nodes[0] : nil
        let editing = single != nil && store.editingPath == single?.id
        Block {
            OptionBlock(title: "Path") {
                SegmentedWell(selection: Binding(get: { store.selectedPathsClosed ?? false }, set: { closed in store.setClosed(closed) }),
                              options: [(false, "Open"), (true, "Closed")])
                // Where the outline crosses itself, or one part lies inside another: only a fill shows it.
                if nodes.contains(where: \.fill.on) {
                    Row(title: "Overlaps") {
                        SegmentedWell(selection: Binding(get: { nodes.allSatisfy { $0.evenOdd == true } }, set: { cut in
                            store.updateSelection(cut ? "Cut Out Overlaps" : "Fill In Overlaps") { $0.evenOdd = cut ? true : nil }
                        }), options: [(false, "Fill in"), (true, "Cut out")])
                    }
                    .transition(.unfold)
                }
                if single != nil {
                    CardButton(title: editing ? "Done" : "Edit Points", height: 28) {
                        if editing { store.editingPath = nil } else { store.editPoints() }
                    }
                    .help(editing ? "Stop editing points  ↩" : "Move, add and take away points  ↩")
                }
                if editing { points.transition(.unfold) }
            } exact: {
                EmptyView()
            }
        }
    }

    @ViewBuilder private var points: some View {
        if store.livePoints.isEmpty {
            Text("Drag a point or its handles. Click the outline to add a point, and double-click a point to make it smooth or sharp.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.unfold)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    NumberField(label: "X", value: store.pickedPosition(x: true), action: "Move Points") { v in
                        store.movePicked(x: true) { _ in v }
                    } each: { f in store.movePicked(x: true) { f($0) } }
                    Color.clear.frame(width: 18)
                    NumberField(label: "Y", value: store.pickedPosition(x: false), action: "Move Points") { v in
                        store.movePicked(x: false) { _ in v }
                    } each: { f in store.movePicked(x: false) { f($0) } }
                }
                SegmentedWell(selection: Binding(get: { store.pickedSmooth ?? false }, set: { smooth in store.setSmooth(smooth) }),
                              options: [(false, "Corner"), (true, "Smooth")])
            }
            .transition(.unfold)
        }
    }
}

// MARK: - Text

private struct TextBlock: View {
    @Environment(MenuHost.self) private var menus
    let store: DocumentStore
    let nodes: [Node]

    private func common<T: Equatable>(_ value: (TextStyle) -> T) -> T? {
        let styles = nodes.map { $0.style ?? TextStyle() }
        guard let first = styles.first.map(value) else { return nil }
        return styles.allSatisfy { value($0) == first } ? first : nil
    }

    private func set(_ action: String, _ change: @escaping (inout TextStyle) -> Void) {
        store.updateSelection(action) { n in
            var s = n.style ?? TextStyle()
            change(&s)
            n.style = s
        }
    }

    /// Shows a change to the text style on the canvas without making it, such as the font pointed
    /// at in the font menu; nil takes it away.
    private func preview(_ change: ((inout TextStyle) -> Void)?) {
        store.showPreview("font", change.map { change in { n in
            var s = n.style ?? TextStyle()
            change(&s)
            n.style = s
        } })
    }

    /// A field for one part of every selected layer's text style; what is typed applies to each.
    private func styleField(_ label: String, unit: String = "", range: ClosedRange<Double>, scrub: Double, decimals: Int = 1,
                            action: String, value: Double?, get: @escaping (TextStyle) -> Double,
                            set apply: @escaping (inout TextStyle, Double) -> Void) -> NumberField {
        NumberField(label: label, value: value, unit: unit, range: range, scrub: scrub, decimals: decimals, action: action) { v in
            set(action) { apply(&$0, v) }
        } each: { f in
            set(action) { style in apply(&style, f(get(style))) }
        }
    }

    var body: some View {
        let family = common(\.family)
        let face = common(\.face)
        let size = common { Double($0.size) }
        Block {
            OptionBlock(title: "Text") {
                MenuButton(id: "font-family", title: family.map(Fonts.displayName) ?? "Several fonts", width: 244) {
                    familyEntries(current: family)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    MenuButton(id: "font-face", title: face ?? "Several", width: 200) {
                        Fonts.faces(of: family ?? TextStyle.system).map { f in
                            MenuEntry.item(f, checked: f == face, preview: { on in preview(on ? { $0.face = f } : nil) }) {
                                set("Change Font") { $0.face = f }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    styleField("", unit: "pt", range: 1...2000, scrub: 0.25, action: "Change Size", value: size,
                               get: { Double($0.size) }, set: { $0.size = CGFloat($1) })
                        .frame(width: 84)
                }
                PresetStrip(action: "Change Size", items: Presets.textSizes.map { points in
                    PresetItem(id: "text-size-\(Int(points))", name: "\(Int(points)) points", active: size == Double(points)) { n in
                        var style = n.style ?? TextStyle()
                        style.size = points
                        n.style = style
                    }
                }, height: 28) { item in
                    let points = Presets.textSizes.first { "text-size-\(Int($0))" == item.id } ?? 12
                    Text(verbatim: "\(Int(points))")
                        .font(.system(size: 9.5 + CGFloat(Presets.textSizes.firstIndex(of: points) ?? 0) * 0.75, weight: .medium).monospacedDigit())
                }
                HStack(spacing: 8) {
                    IconChoice(selection: common(\.align), options: [
                        (.left, "text.alignleft", "Align left"),
                        (.center, "text.aligncenter", "Centre"),
                        (.right, "text.alignright", "Align right"),
                    ]) { a in set("Align Text") { $0.align = a } }
                    IconChoice(selection: common(\.underline), options: [(true, "underline", "Underline")]) { _ in
                        let on = common(\.underline) ?? false
                        set(on ? "Remove Underline" : "Underline") { $0.underline = !on }
                    }
                    .frame(width: 34)
                }
                SegmentedWell(selection: Binding(get: { common(\.sizing) ?? .autoWidth }, set: { v in
                    let action = switch v {
                    case .autoWidth: "Auto Size"
                    case .autoHeight: "Fixed Width"
                    case .fixed: "Fixed Size"
                    }
                    set(action) { $0.sizing = v }
                }), options: [(.autoWidth, "Auto size"), (.autoHeight, "Fixed width"), (.fixed, "Fixed size")])
            } exact: {
                HStack(spacing: 8) {
                    styleField("Line", range: 0...4000, scrub: 0.25, action: "Change Line Spacing", value: lineSpacing,
                               get: { Double($0.lineSpacing ?? Self.naturalLineHeight($0)) }, set: { $0.lineSpacing = CGFloat($1) })
                    styleField("Letter", range: -500...2000, scrub: 1, decimals: 0, action: "Change Letter Spacing",
                               value: common { Double($0.tracking) }, get: { Double($0.tracking) }, set: { $0.tracking = CGFloat($1) })
                }
            }
        }
    }

    /// The font's own line height, which the text has until one is set.
    private static func naturalLineHeight(_ style: TextStyle) -> CGFloat {
        let font = Fonts.font(style)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The line spacing they share, or the font's own line height until one is set.
    private var lineSpacing: Double? {
        if let set = common(\.lineSpacing) {
            if let set { return Double(set) }
            guard let style = nodes.first?.style else { return nil }
            return Double(Self.naturalLineHeight(style))
        }
        return nil
    }

    private func familyEntries(current: String?) -> [MenuEntry] {
        Fonts.families.map { f in
            // The family, in the face the text has if it has one, else its regular one.
            let choose: (inout TextStyle) -> Void = { s in
                s.family = f
                let faces = Fonts.faces(of: f)
                if !faces.contains(s.face) { s.face = faces.first { $0 == "Regular" } ?? faces.first ?? "Regular" }
            }
            return MenuEntry.item(Fonts.displayName(f), checked: f == current,
                                  font: f != TextStyle.system && Fonts.showsOwnName(f) ? .custom(f, size: 13) : .system(size: 13),
                                  preview: { on in preview(on ? choose : nil) }) {
                set("Change Font", choose)
            }
        }
    }
}

// MARK: - Pieces

/// The selection's name and what it is.
private struct Header: View {
    let nodes: [Node]
    let store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(nodes.count == 1 ? nodes[0].name : "\(nodes.count) layers")
                .font(Theme.serif(17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var detail: String {
        if nodes.count == 1 {
            let n = nodes[0]
            if let parent = store.doc.parent(of: n.id) { return "\(n.kind.title) on \(parent.name)" }
            return n.isArtboard ? "Artboard, \(n.children.count) \(n.children.count == 1 ? "layer" : "layers")" : "\(n.kind.title) on the canvas"
        }
        let kinds = Set(nodes.map(\.kind))
        return kinds.count == 1 ? "All \(nodes[0].kind.title.lowercased())s" : "Mixed layers"
    }
}

/// Lines layers up with each other, or a single one with its artboard.
private struct AlignBar: View {
    let store: DocumentStore
    let count: Int
    let onBoard: Bool

    var body: some View {
        HStack(spacing: 0) {
            Group {
                button("align.horizontal.left", "Align left") { store.align(.left) }
                button("align.horizontal.center", "Align centres") { store.align(.centerX) }
                button("align.horizontal.right", "Align right") { store.align(.right) }
                button("align.vertical.top", "Align tops") { store.align(.top) }
                button("align.vertical.center", "Align middles") { store.align(.centerY) }
                button("align.vertical.bottom", "Align bottoms") { store.align(.bottom) }
            }
            .opacity(onBoard ? 1 : 0.35)
            .allowsHitTesting(onBoard)
            Spacer(minLength: 0)
            Group {
                button("distribute.horizontal", "Space evenly across") { store.distribute(horizontally: true) }
                button("distribute.vertical", "Space evenly down") { store.distribute(horizontally: false) }
            }
            .opacity(count >= 3 ? 1 : 0.35)
            .allowsHitTesting(count >= 3)
        }
        .padding(.horizontal, Inspector.gutter - 4)
        .padding(.bottom, 10)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, help: help, size: 28, action: action)
    }
}

/// A block of the inspector, set off from the next by a hairline.
private struct Block<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            content
                .padding(.horizontal, Inspector.gutter)
                .padding(.vertical, 14)
        }
    }
}

/// A title on the left and its control on the right.
private struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 84, alignment: .leading)
            content
        }
    }
}

/// The aspect lock between width and height: two links that close when on.
private struct AspectLock: View {
    @Binding var locked: Bool
    @State private var hovering = false

    var body: some View {
        Image(systemName: locked ? "lock.fill" : "lock.open")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(locked ? Theme.ink : hovering ? Theme.ink2 : Theme.ink3)
            .frame(width: 18, height: 26)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { locked.toggle() }
            .help(locked ? "Width and height change together" : "Keep the proportions")
    }
}

/// A row of small symbol buttons, one of them chosen, in a well.
struct IconChoice<Value: Hashable>: View {
    let selection: Value?
    let options: [(Value, String, String)]
    let choose: (Value) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, symbol, help in
                let selected = value == selection
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: Theme.shadow.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.spring) { choose(value) } }
                    .help(help)
            }
        }
        .padding(2)
        .well(radius: 8)
    }
}
