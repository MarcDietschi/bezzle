import SwiftUI
import AppKit

/// The panel on the right: everything about the selected layers that can be set, and nothing
/// that does not apply to them. With nothing selected it offers artboard sizes and the tools' keys.
struct Inspector: View {
    let store: DocumentStore
    static let width: CGFloat = 280
    static let gutter: CGFloat = 16
    /// A card's width, between the gutters: the whole way a card's dial turns.
    static let card = width - gutter * 2
    /// Between a card's edges and what it holds.
    static let cardInset: CGFloat = 12
    /// What lies inside a card.
    static let content = card - cardInset * 2
    /// Two fields side by side, with room between them for the lock that ties width to height. A
    /// named row's control starts where the second of them does, so the two line up down the panel.
    static let columnGap: CGFloat = 20
    static let column = (content - columnGap) / 2
    /// A narrow field at the end of a row, such as a corner's radius, and the colours offered
    /// beside a colour: as wide as the last of three fields side by side, and in line with it.
    static let endField = (content - 16) / 3

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
                        KeyCap(.verbatim(tool.key))
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
    let key: LocalizedStringResource
    init(_ key: LocalizedStringResource) { self.key = key }

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
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Preset.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.ink3)
                            .padding(.bottom, 2)
                        ForEach(Preset.all(in: group)) { preset in
                            PresetRow(name: preset.title, size: preset.size) { store.addArtboard(preset) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Carousels")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Slides side by side, designed as one and exported a picture each.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            VStack(spacing: 2) {
                ForEach(Carousel.formats) { format in
                    PresetRow(name: format.title, size: format.size, slides: Carousel.startingCount) { store.addCarousel(format) }
                        .help(format.platforms)
                }
            }
        }
        .padding(.horizontal, Inspector.gutter)
        .padding(.top, 14)
    }
}

/// A size to add, as a small sheet of its proportions; for a carousel, a few of its slides.
struct PresetRow: View {
    let name: LocalizedStringResource
    /// The artboard's size, or a carousel's slide's.
    let size: CGSize
    var slides = 1
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FrameGlyph(size: CGSize(width: size.width * CGFloat(slides), height: size.height), box: 22, slides: slides)
            Text(name)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer()
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
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

/// A sheet of the given proportions, fitted into a square box; cut into `slides` for a carousel.
struct FrameGlyph: View {
    let size: CGSize
    var box: CGFloat = 22
    var slides = 1

    var body: some View {
        let s = box / max(size.width, size.height)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.card)
            .overlay {
                if slides > 1 {
                    GeometryReader { g in
                        Path { p in
                            for i in 1..<slides {
                                let x = g.size.width * CGFloat(i) / CGFloat(slides)
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: g.size.height))
                            }
                        }
                        .stroke(Theme.ink3, lineWidth: 1)
                    }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.ink2, lineWidth: 1.2) }
            .frame(width: max(size.width * s, 6), height: max(size.height * s, 6))
            .frame(width: box, height: box)
    }
}

extension DocumentStore {
    /// Adds an artboard of a preset size to the right of the others, and brings it into view.
    func addArtboard(_ preset: Preset) {
        let board = Node(kind: .artboard, name: doc.artboards.isEmpty ? String(localized: preset.title) : doc.nextName(for: .artboard),
                         frame: CGRect(origin: nextArtboardOrigin, size: preset.size))
        add(board, onto: nil)
        lastPreset = preset.size
        tool = .select
        if !visibleCanvasRect.contains(board.frame) { zoomToFit() }
    }

    /// Adds a carousel of a few slides of a format to the right of the others, and brings it into view.
    func addCarousel(_ format: Carousel.Format) {
        let taken = Set(doc.allNodes.map(\.name))
        var name = String(localized: "Carousel"), i = 2
        while taken.contains(name) {
            name = String(localized: "Carousel \(i)")
            i += 1
        }
        var board = Node(kind: .artboard, name: name, frame: CGRect(origin: nextArtboardOrigin, size: format.size))
        board.slideSize = format.size
        board.frame.size = board.carouselSize(count: Carousel.startingCount)
        add(board, onto: nil, action: "Add Carousel")
        tool = .select
        if !visibleCanvasRect.contains(board.frame) { zoomToFit() }
    }

    /// Where a new artboard goes: to the right of the others, along their top.
    private var nextArtboardOrigin: CGPoint {
        let right = doc.artboards.map(\.frame.maxX).max()
        let top = doc.artboards.map(\.frame.minY).min() ?? 0
        return right.map { CGPoint(x: $0 + 80, y: top) } ?? .zero
    }
}

// MARK: - Path

/// What a path is, and while its points are being edited, where the picked ones are and how
/// the outline runs through them.
struct PathCard: View {
    let store: DocumentStore
    let nodes: [Node]

    var body: some View {
        let single = nodes.count == 1 && !nodes[0].locked ? nodes[0] : nil
        let editing = single != nil && store.editingPath == single?.id
        AspectCard(aspect: .path, title: "Path", summary: summary(editing: editing)) {
            KindGlyph(kind: .path)
        } picks: {
            SegmentedWell(selection: Binding(get: { store.selectedPathsClosed ?? false }, set: { closed in store.setClosed(closed) }),
                          options: [(false, LocalizedStringResource("path.open", defaultValue: "Open", comment: "An open path, as opposed to a closed one.")), (true, "Closed")])
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
                // Return on a path filled with a picture places the picture instead.
                .help(editing ? "Stop editing points  ↩" : store.canEditPicture ? "Move, add and take away points" : "Move, add and take away points  ↩")
            }
            if editing { points.transition(.unfold) }
        }
    }

    /// Open or closed, and whether its points are being edited.
    private func summary(editing: Bool) -> String {
        var said = switch store.selectedPathsClosed {
        case true?: String(localized: "Closed")
        case false?: String(localized: LocalizedStringResource("path.open", defaultValue: "Open", comment: "An open path, as opposed to a closed one."))
        case nil: SelectionInspector.several
        }
        if editing { said += " · \(String(localized: "Editing points"))" }
        return said
    }

    @ViewBuilder private var points: some View {
        if store.livePoints.isEmpty {
            Caption("Drag a point or its handles. Click the outline to add a point, and double-click a point to make it smooth or sharp.")
                .transition(.unfold)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Pair(pointField(x: true), pointField(x: false))
                SegmentedWell(selection: Binding(get: { store.pickedSmooth ?? false }, set: { smooth in store.setSmooth(smooth) }),
                              options: [(false, "Corner"), (true, "Smooth")])
            }
            .transition(.unfold)
        }
    }

    /// Where the picked points are, across or down.
    private func pointField(x: Bool) -> NumberField {
        NumberField(label: x ? "X" : "Y", value: store.pickedPosition(x: x), action: "Move Points") { v in
            store.movePicked(x: x) { _ in v }
        } each: { f in store.movePicked(x: x) { f($0) } }
    }
}

// MARK: - Text

struct TextCard: View {
    @Environment(MenuHost.self) private var menus
    let store: DocumentStore
    let nodes: [Node]
    var live = false

    private func common<T: Equatable>(_ value: (TextStyle) -> T) -> T? {
        let styles = nodes.map { $0.style ?? TextStyle() }
        guard let first = styles.first.map(value) else { return nil }
        return styles.allSatisfy { value($0) == first } ? first : nil
    }

    private func set(_ action: LocalizedStringResource, _ change: @escaping (inout TextStyle) -> Void) {
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
    private func styleField(_ label: LocalizedStringResource, unit: String = "", range: ClosedRange<Double>, scrub: Double, decimals: Int = 1,
                            action: LocalizedStringResource, value: Double?, get: @escaping (TextStyle) -> Double,
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
        let first = nodes.first?.style ?? TextStyle()
        let summary = [family.map { Fonts.displayName($0) } ?? String(localized: "Several fonts"),
                       size.map { "\(SelectionInspector.said($0)) pt" } ?? SelectionInspector.several].joined(separator: " · ")
        let dial = Dial(value: Double(first.size), range: 1...max(200, Double(first.size) * 1.5), stops: Presets.textSizes.map(Double.init),
                        step: 1, action: "Change Size") { v in set("Change Size") { $0.size = CGFloat(v.rounded()) } }
        AspectCard(aspect: .text, title: "Text", summary: summary, dial: dial, live: live) {
            Text(verbatim: "Aa")
                .font(family.flatMap { $0 != TextStyle.system && Fonts.showsOwnName($0) ? Font.custom($0, size: 12.5) : nil } ?? .system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        } picks: {
            MenuButton(id: "font-family", title: family.map { .verbatim(Fonts.displayName($0)) } ?? "Several fonts", width: Inspector.content, fills: true) {
                familyEntries(current: family)
            }
            HStack(spacing: 8) {
                MenuButton(id: "font-face", title: face.map { .verbatim($0) } ?? "Several", width: 200, fills: true) {
                    Fonts.faces(of: family ?? TextStyle.system).map { f in
                        MenuEntry.item(.verbatim(f), checked: f == face, preview: { on in preview(on ? { $0.face = f } : nil) }) {
                            set("Change Font") { $0.face = f }
                        }
                    }
                }
                styleField("", unit: "pt", range: 1...2000, scrub: 0.25, action: "Change Size", value: size,
                           get: { Double($0.size) }, set: { $0.size = CGFloat($1) })
                    .frame(width: Inspector.endField)
            }
            PresetStrip(action: "Change Size", items: Presets.textSizes.map { points in
                PresetItem(id: "text-size-\(Int(points))", name: "\(Int(points)) points", active: size == Double(points)) { n in
                    var style = n.style ?? TextStyle()
                    style.size = points
                    n.style = style
                }
            }) { item in
                let points = Presets.textSizes.first { "text-size-\(Int($0))" == item.id } ?? 12
                Text(verbatim: "\(Int(points))")
                    .font(.system(size: 9.5 + CGFloat(Presets.textSizes.firstIndex(of: points) ?? 0) * 0.75, weight: .medium).monospacedDigit())
            }
            HStack(spacing: 8) {
                IconChoice(selection: common(\.align), options: [
                    (.left, "text.alignleft", "Align left"),
                    (.center, "text.aligncenter", LocalizedStringResource("text.align-centre", defaultValue: "Centre", comment: "Centres the text, beside Align left and Align right.")),
                    (.right, "text.alignright", "Align right"),
                ]) { a in set("Align Text") { $0.align = a } }
                IconChoice(selection: common(\.underline), options: [(true, "underline", "Underline")]) { _ in
                    let on = common(\.underline) ?? false
                    set(on ? "Remove Underline" : "Underline") { $0.underline = !on }
                }
                .frame(width: Inspector.endField)
            }
            SegmentedWell(selection: Binding(get: { common(\.sizing) ?? .autoWidth }, set: { v in
                let action: LocalizedStringResource = switch v {
                case .autoWidth: "Auto Size"
                case .autoHeight: "Fixed Width"
                case .fixed: "Fixed Size"
                }
                set(action) { $0.sizing = v }
            }), options: [(.autoWidth, "Auto size"), (.autoHeight, "Fixed width"), (.fixed, "Fixed size")])
        } exact: {
            Pair(styleField(LocalizedStringResource("text.line-spacing", defaultValue: "Line", comment: "The distance between lines of text, beside the letter spacing."), range: 0...4000, scrub: 0.25, action: "Change Line Spacing", value: lineSpacing,
                            get: { Double($0.lineSpacing ?? Self.naturalLineHeight($0)) }, set: { $0.lineSpacing = CGFloat($1) }),
                 styleField("Letter", range: -500...2000, scrub: 1, decimals: 0, action: "Change Letter Spacing",
                            value: common { Double($0.tracking) }, get: { Double($0.tracking) }, set: { $0.tracking = CGFloat($1) }))
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
            return MenuEntry.item(.verbatim(Fonts.displayName(f)), checked: f == current,
                                  font: f != TextStyle.system && Fonts.showsOwnName(f) ? .custom(f, size: 13) : .system(size: 13),
                                  preview: { on in preview(on ? choose : nil) }) {
                set("Change Font", choose)
            }
        }
    }
}

// MARK: - Pieces

/// A way of making shapes one, drawn as what it does to two overlapping squares: what is left
/// of them shaded, their outlines over it. With no `how`, building with the pieces: a stroke
/// across all three, as the drag that joins them goes.
struct CombineButton: View {
    let how: DocumentStore.Combine?
    var on = false
    let action: () -> Void
    @State private var hovering = false

    private var help: LocalizedStringResource {
        switch how {
        case .union: "Union: join the shapes into one  ⌥⌘U"
        case .subtract: "Subtract: cut the front shapes out of the back one  ⌥⌘S"
        case .intersect: "Intersect: keep only where the shapes overlap  ⌥⌘I"
        case .exclude: "Exclude overlap: cut out where the shapes overlap  ⌥⌘X"
        case nil: on ? "Done building  ↩" : "Build: drag across the pieces the shapes make to join them, or wipe them away with ⌥  ⌥⌘B"
        }
    }

    var body: some View {
        Canvas { ctx, size in
            // On whole points, so the 1-point outlines fall on whole pixels.
            let side: CGFloat = 9, step: CGFloat = 5
            let x = ((size.width - side - step) / 2).rounded(), y = ((size.height - side - step) / 2).rounded()
            let back = CGPath(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            let front = CGPath(roundedRect: CGRect(x: x + step, y: y + step, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            let ink = hovering || on ? Theme.ink : Theme.ink2
            guard let how else {
                ctx.fill(Path(back.intersection(front)), with: .color(ink.opacity(0.3)))
                for outline in [back, front] { ctx.stroke(Path(outline), with: .color(ink), lineWidth: 1) }
                var swipe = Path()
                swipe.move(to: CGPoint(x: x + 2.5, y: y + 3.5))
                swipe.addQuadCurve(to: CGPoint(x: x + step + side - 2.5, y: y + step + side - 3.5), control: CGPoint(x: x + 9.5, y: y + 4.5))
                ctx.stroke(swipe, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                return
            }
            let left = switch how {
            case .union: back.union(front)
            case .subtract: back.subtracting(front)
            case .intersect: back.intersection(front)
            case .exclude: back.symmetricDifference(front)
            }
            ctx.fill(Path(left), with: .color(ink.opacity(0.3)))
            for outline in how == .union ? [left] : [back, front] {
                ctx.stroke(Path(outline), with: .color(ink), lineWidth: 1)
            }
        }
        .frame(width: 28, height: 28)
        .background(Circle().fill(Theme.ink.opacity(on ? 0.12 : hovering ? 0.08 : 0)))
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(Text(help))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: on)
        .accessibilityLabel(how?.title ?? "Build")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A name on the left, quieter than a block's title, and its control where the second of two
/// fields side by side begins, so that it lines up with them.
struct Row<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .frame(width: Inspector.column + Inspector.columnGap, alignment: .leading)
            HStack(spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Theme.controlHeight)
    }
}

/// Two controls side by side, each in one of the inspector's two columns, and what goes between
/// them, such as the lock between width and height.
struct Pair<First: View, Second: View, Between: View>: View {
    let first: First
    let second: Second
    let between: Between

    init(_ first: First, _ second: Second, between: Between) {
        self.first = first
        self.second = second
        self.between = between
    }

    var body: some View {
        HStack(spacing: 0) {
            first.frame(width: Inspector.column)
            between.frame(width: Inspector.columnGap)
            second.frame(width: Inspector.column)
        }
    }
}

extension Pair where Between == Color {
    init(_ first: First, _ second: Second) {
        self.init(first, second, between: Color.clear)
    }
}

/// A line or two that says how something works, under its controls.
struct Caption: View {
    let text: LocalizedStringResource
    init(_ text: LocalizedStringResource) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The aspect lock between width and height: two links that close when on.
struct AspectLock: View {
    @Binding var locked: Bool
    @State private var hovering = false

    var body: some View {
        Image(systemName: locked ? "lock.fill" : "lock.open")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(locked ? Theme.ink : hovering ? Theme.ink2 : Theme.ink3)
            .frame(width: 18, height: Theme.controlHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { locked.toggle() }
            .help(locked ? "Width and height change together" : "Keep the proportions")
    }
}

/// A row of small symbol buttons, one of them chosen, in a well.
struct IconChoice<Value: Hashable>: View {
    let selection: Value?
    /// Each value, its symbol, and what it is called.
    let options: [(Value, String, LocalizedStringResource)]
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
                    .help(Text(help))
            }
        }
        .padding(2)
        .well(radius: 8)
    }
}
