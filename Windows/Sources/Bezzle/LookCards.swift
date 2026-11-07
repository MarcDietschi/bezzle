import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The cards for how the selected layers look, as the Mac's LookCards: their corners, how much of
/// them shows, and their fills, borders and shadows, several of each one over another, the top one
/// first. Each one's sideways drag sets what it has most of; open, the presets (shown on the
/// canvas while pointed at), the colour and the exact numbers. What none of them has yet waits
/// below as dashed chips.
extension Inspector {
    typealias Colour = WindowsCore.Colour

    func lookCards(_ ids: [UUID], board: Int, kinds: Set<String>) -> [UIElement] {
        guard let looks = WindowsCore.looks(ids) else { return [] }
        @MainActor func change(_ c: WindowsCore.LookChange) {
            WindowsCore.change(ids, c)
            session.edited(board: board)
        }
        @MainActor func preview(_ c: WindowsCore.LookChange?) {
            WindowsCore.preview(ids, c)
            session.previewed(board: board)
        }
        let onlyArtboards = kinds == ["artboard"]
        // Lines are all border and text is all colour, so those cannot be taken away from them.
        let fills = kinds.isDisjoint(with: ["artboard", "line", "group"]), borders = kinds.isDisjoint(with: ["artboard", "text", "group"])
        var cards: [UIElement] = []
        if kinds == ["rectangle"] { cards.append(cornersCard(looks, change: change, preview: preview)) }
        // An artboard: its background, then being marked for export.
        guard !onlyArtboards else {
            if ids.count == 1 {
                cards.append(backgroundCard(looks, ids: ids, board: board, change: change, preview: preview))
                let id = ids[0]
                if let layout = layoutCard(id, change: { [self] c in
                    WindowsCore.changeLayout(id, c)
                    session.edited(board: nil)
                }) { cards.append(layout) }
                if let guides = guidesCard(id) { cards.append(guides) }
            }
            if WindowsCore.exportMarked(ids) != false, let export = exportCard(ids, board: board) { cards.append(export) }
            // What an artboard can gain: a layout grid, and being marked for export.
            var more: [(String, String, () -> Void)] = []
            if ids.count == 1, WindowsCore.layoutLook(ids[0]) == nil { more.append(("Layout Grid", "Layout Grid", { WindowsCore.addLayout(ids[0]) })) }
            if WindowsCore.exportMarked(ids) == false { more.append(("Export", "Export", { WindowsCore.markForExport(ids) })) }
            if !more.isEmpty { cards.append(chips(more, board: board)) }
            return cards
        }
        cards.append(opacityCard(looks, change: change, preview: preview))
        let firstFill = kinds.contains("text") || looks.fillOn != false
        if fills && (firstFill || looks.fills.count > 1) {
            cards.append(pile(looks.fills.indices.filter { $0 > 0 || firstFill }.reversed().map { slot in
                fillCard(looks, slot: slot, ids: ids, board: board, change: change, preview: preview)
            }))
        }
        // What the pictures have of light, colour and detail, when every layer shows one.
        if let photo = photoCard(ids, board: board) { cards.append(photo) }
        let firstBorder = kinds.contains("line") || looks.borderOn != false
        if borders && (firstBorder || looks.borders.count > 1) {
            cards.append(pile(looks.borders.indices.filter { $0 > 0 || firstBorder }.reversed().map { slot in
                borderCard(looks, slot: slot, ids: ids, board: board, lineOnly: kinds == ["line"], change: change, preview: preview)
            }))
        }
        let firstShadow = looks.shadowOn != false
        if firstShadow || looks.shadows.count > 1 {
            let canSpread = kinds.isSubset(of: ["rectangle", "ellipse", "path", "line"])
            cards.append(pile(looks.shadows.indices.filter { $0 > 0 || firstShadow }.reversed().map { slot in
                shadowCard(looks, slot: slot, canInset: !kinds.contains("line"), canSpread: canSpread, change: change, preview: preview)
            }))
        }
        // Only shapes have an outline to show what is behind them through.
        if looks.blurOn != false, let blur = blurCard(looks, canBlurBehind: kinds.isSubset(of: ["rectangle", "ellipse", "path"]), change: change, preview: preview) {
            cards.append(blur)
        }
        if looks.depthOn != false, let depth = depthCard(looks, change: change) { cards.append(depth) }
        if WindowsCore.exportMarked(ids) != false, let export = exportCard(ids, board: board) { cards.append(export) }
        // What the layers have not got yet, as the Mac's AddBar offers it.
        var missing: [(String, String, () -> Void)] = []
        // Straight texts can be bent, offered first.
        if kinds == ["text"], WindowsCore.canCurve(ids) { missing.append(("Curve", "Curve", { WindowsCore.bend(ids, to: 0.25) })) }
        if fills && !kinds.contains("text") && looks.fillOn == false { missing.append(("Fill", "Fill", { change(.addFill) })) }
        if borders && !kinds.contains("line") && looks.borderOn == false { missing.append(("Border", "Border", { change(.addBorder) })) }
        // A shadow under the layers; once they have one, a shadow inside them as well, so that
        // the chips offer what comes next rather than growing.
        let next = looks.shadowOn == true ? looks.shadows.count : 0
        if looks.shadowUnder == false {
            missing.append(("Shadow", Self.cardID("Shadow", next), { change(.addShadow) }))
        } else if looks.shadowUnder == true, looks.shadowWithin == false, !kinds.contains("line") {
            missing.append(("Inner shadow", Self.cardID("Shadow", next), { change(.addInnerShadow) }))
        }
        if looks.blurOn == false { missing.append(("Blur", "Blur", { change(.addBlur) })) }
        if looks.depthOn == false { missing.append(("3D", "3D", { change(.addDepth) })) }
        // Marking them for export, as a 1× PNG to begin with, when none of them is.
        if WindowsCore.exportMarked(ids) == false { missing.append(("Export", "Export", { WindowsCore.markForExport(ids) })) }
        // Repeated into a grid of cells, once pulled out.
        if WindowsCore.canRepeat(ids) {
            missing.append(("Repeat", "Repeat Grid", { [self] in
                if let made = WindowsCore.makeRepeatGrid(ids) { session.select([made], on: board) }
            }))
        }
        if !missing.isEmpty { cards.append(chips(missing, board: board)) }
        return cards
    }

    /// Several cards of one kind close together, 4 apart, so they read as one.
    private func pile(_ cards: [UIElement]) -> UIElement {
        if cards.count == 1 { return cards[0] }
        let stack = StackPanel()
        stack.spacing = 4
        for c in cards { stack.children.append(c) }
        return stack
    }

    private func said(_ v: Double) -> String { number(v) }

    /// Which card of a pile is open: the first by its kind, those over it by their place too.
    static func cardID(_ kind: String, _ slot: Int) -> String { slot == 0 ? kind : "\(kind) \(slot)" }

    // MARK: Corners

    /// How round the corners are, and whether they are plain arcs or squircles. The drag rounds
    /// them, clicking at each preset up to a pill.
    private func cornersCard(_ l: WindowsCore.Looks, change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                             preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let presets = WindowsCore.cornerPresets
        var summary: String
        if l.radius == nil {
            summary = "Several"
        } else if l.pill > 0, l.firstRadius >= l.pill - 0.5 {
            summary = "Pill"
        } else if let named = presets.first(where: { $0.radius == l.firstRadius }) {
            summary = "\(named.name) · \(said(l.firstRadius))"
        } else {
            summary = said(l.firstRadius)
        }
        if l.smooth { summary = "Squircle · \(summary)" }
        let pill = l.pill
        let dial = pill > 0 ? Dial(fraction: l.firstRadius / pill, set: { WindowsCore.change(self.session.selection, .corners(($0 * pill).rounded())) },
                                   summary: { f in let r = (f * pill).rounded(); return r >= pill - 0.5 ? "Pill" : self.said(r) },
                                   stops: [0, 4, 12, 24, pill].map { $0 / pill }) : nil
        let glyph = Glyphs.corner(pill > 0 && l.firstRadius >= pill - 0.5 ? nil : l.firstRadius)
        return card("Corners", summary, glyph: glyph, dial: dial, style: "corners", body: { [self] in
            let strip = Controls.presetStrip(presets.enumerated().map { k, p in
                (Glyphs.view(Glyphs.corner(p.radius), size: 16, brush: Theme.ink(l.cornerPreset == k ? 1 : 2)), l.cornerPreset == k)
            }, point: { k in preview(k.map { .cornerPreset($0) }) }, choose: { change(.cornerPreset($0)) })
            let radius = field("R", l.radius, range: 0...10_000, width: Self.endField) { change(.corners($0)) }
            let smooth = Controls.segmented(l.smooth, [(false, "Round"), (true, "Squircle")]) { change(.smooth($0)) }
            let smoothing = field("", l.smoothing, unit: "%", range: 0...100, scrub: 0.5, width: Self.endField) { change(.smoothing($0)) }
            return [Controls.line([strip, radius]), Controls.line([smooth, smoothing])]
        })
    }

    // MARK: Opacity

    /// How much of the layers shows: the drag fades them, clicking at each quarter.
    private func opacityCard(_ l: WindowsCore.Looks, change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                             preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let quarters = [0.25, 0.5, 0.75, 1.0]
        let dial = Dial(fraction: l.firstOpacity, set: { WindowsCore.change(self.session.selection, .opacity(($0 * 20).rounded() / 20)) },
                        summary: { "\(Int((($0 * 20).rounded() * 5)))%" }, stops: quarters)
        return card("Opacity", l.opacity.map { "\(Int(($0 * 100).rounded()))%" } ?? "Several", glyph: Glyphs.level(l.firstOpacity), dial: dial, body: { [self] in
            let strip = Controls.presetStrip(quarters.map { q in
                let on = l.opacity.map { abs($0 - q) < 0.005 } ?? false
                return (Glyphs.view(Glyphs.level(q), size: 14, brush: Theme.ink(on ? 1 : 2)), on)
            }, point: { k in preview(k.map { .opacity(quarters[$0]) }) }, choose: { change(.opacity(quarters[$0])) })
            let percent = field("", l.opacity.map { $0 * 100 }, unit: "%", range: 0...100, scrub: 0.5, width: Self.endField) { change(.opacity($0 / 100)) }
            return [Controls.line([strip, percent])]
        })
    }

    // MARK: Fill

    /// One of what fills the layers. For one colour, the drag sets how much of it shows. Its
    /// swatch opens the fill menu; text takes one fill for its letters.
    /// An artboard's background, as the Mac's backgroundCard: the fill's controls, without the
    /// design's colours offered first, and how it blends.
    private func backgroundCard(_ l: WindowsCore.Looks, ids: [UUID], board: Int,
                                change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                                preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let paint = l.fills[0]
        return card("Background", paint.summary, mark: Colours.swatch(paint, size: 15, radius: 4), style: "fill:0", body: { [self] in
            [paintField(paint, target: .fill(0), ids: ids, board: board, suggest: false, change: change, preview: preview),
             blendRow(l, change: change, preview: preview)]
        })
    }

    private func fillCard(_ l: WindowsCore.Looks, slot: Int, ids: [UUID], board: Int,
                          change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                          preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let paint = l.fills[slot]
        let dial = paint.kind == "solid" ? Dial(fraction: paint.first.a, set: { WindowsCore.change(ids, .fillAlpha(slot, ($0 * 20).rounded() / 20)) },
                                                summary: { "#\(paint.first.hex) · \(Int((($0 * 20).rounded() * 5)))%" }, stops: [1]) : nil
        // Text is all colour, so its first fill stays.
        var remove: (@MainActor () -> Void)?
        if !l.isText || slot > 0 { remove = { change(.remove("fill", slot)) } }
        let next = Self.cardID("Fill", l.fills.count)
        // Text's letters take one fill alone.
        var more: (help: String, preview: @MainActor (Bool) -> Void, add: @MainActor () -> Void)?
        if !l.isText {
            more = ("Add another fill", { on in preview(on ? .moreFill : nil) }, { [self] in self.opened = next; change(.moreFill) })
        }
        return card("Fill", paint.summary, id: Self.cardID("Fill", slot), mark: Colours.swatch(paint, size: 15, radius: 4), dial: dial,
                    remove: remove, removal: l.isText ? "Remove colour" : "Remove fill", more: more, style: "fill:\(slot)", body: { [self] in
            var rows: [UIElement] = [paintField(paint, target: .fill(slot), ids: ids, board: board, suggest: true, change: change, preview: preview)]
            if !l.isText && slot == 0 { rows.append(blendRow(l, change: change, preview: preview)) }
            return rows
        })
    }

    /// Which of the layers' paints a field or the fill menu is on.
    enum Target: Equatable { case fill(Int), border(Int) }

    /// The paint's field: one colour as a colour field, a gradient or a picture by its swatch and
    /// name; either opens the fill menu.
    private func paintField(_ paint: WindowsCore.PaintLook, target: Target, ids: [UUID], board: Int, suggest: Bool,
                            change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                            preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> FrameworkElement {
        let open: @MainActor (FrameworkElement) -> Void = { [weak self] anchor in self?.openFillMenu(below: anchor, target: target, ids: ids, board: board) }
        guard paint.kind != "solid" else {
            let colour: (Colour) -> WindowsCore.LookChange = { c in
                switch target {
                case .fill(let slot): .fillColour(slot, c)
                case .border(let slot): .borderColour(slot, c)
                }
            }
            let used = suggest ? WindowsCore.designColours.filter { $0.hex != paint.colour?.hex } : []
            return Colours.field(paint.colour, suggestions: Array(used.prefix(12)), open: open,
                                 preview: { c in preview(c.map(colour)) }, apply: { change(colour($0)) })
        }
        let row = Grid()
        row.columnSpacing = 8
        for w in [GridLength(value: Controls.height, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = w
            row.columnDefinitions.append(column)
        }
        let swatch = Colours.swatch(paint)
        row.children.append(swatch)
        let well = Theme.well(radius: 7)
        well.height = Controls.height
        let name = Theme.text(Words.t(paint.kind == "linear" ? "Linear gradient" : paint.kind == "radial" ? "Radial gradient" : "Picture"), size: 12)
        name.verticalAlignment = .center
        name.margin = Theme.inset(9, 0, 9, 0)
        well.child = name
        try? Grid.setColumn(well, 1)
        row.children.append(well)
        row.background = Theme.clear
        row.pointerPressed.addHandler { _, args in args?.handled = true }
        row.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { open(swatch) } }
        }
        return row
    }

    /// How the layers mix with what lies under them; each mode shows on the canvas while pointed at.
    private func blendRow(_ l: WindowsCore.Looks, change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                          preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let groups = WindowsCore.blendModes
        let title = Words.t(l.blendSeveral ? "Several" : groups.joined().first { $0.raw == l.blend }?.name ?? "Normal")
        let unpreview: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if WindowsCore.endPreview() { self?.session.previewed(board: self?.session.board) } } }
        }
        let button = Controls.menuButton(title, menus: menus, menuWidth: 180, entries: {
            groups.enumerated().flatMap { i, modes in
                (i > 0 ? [MenuHost.Entry.separator] : []) + modes.map { mode in
                    MenuHost.Entry.item(mode.name, checked: !l.blendSeveral && l.blend == mode.raw,
                                        preview: { on in preview(on ? .blend(mode.raw) : nil) }) { change(.blend(mode.raw)) }
                }
            }
        }, closed: unpreview)
        return Controls.row("Blend", button)
    }

    // MARK: Border

    /// One of the borders, or of a line's strokes. The drag sets its weight, clicking at each preset.
    private func borderCard(_ l: WindowsCore.Looks, slot: Int, ids: [UUID], board: Int, lineOnly: Bool,
                            change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                            preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let b = l.borders[slot]
        let floor = lineOnly ? 0.5 : 0, top = max(12, b.firstWidth)
        let dial = Dial(fraction: (b.firstWidth - floor) / (top - floor),
                        set: { WindowsCore.change(ids, .borderWidth(slot, max(((floor + $0 * (top - floor)) * 2).rounded() / 2, floor))) },
                        summary: { "\(self.said(max(((floor + $0 * (top - floor)) * 2).rounded() / 2, floor))) pt" },
                        stops: [1, 2, 4].map { ($0 - floor) / (top - floor) })
        let presets = WindowsCore.borderPresets
        // A line is all border, so its first stays.
        var remove: (@MainActor () -> Void)?
        if !lineOnly || slot > 0 { remove = { change(.remove("border", slot)) } }
        let next = Self.cardID("Border", l.borders.count)
        return card(lineOnly ? "Line" : "Border", b.summary, id: Self.cardID("Border", slot), glyph: Glyphs.border((b.dash ?? 0) > 0 ? nil : b.firstWidth), dial: dial,
                    remove: remove, removal: lineOnly ? "Remove line" : "Remove border",
                    more: (lineOnly ? "Add another line" : "Add another border", { on in preview(on ? .moreBorder : nil) }, { [self] in self.opened = next; change(.moreBorder) }),
                    style: "border:\(slot)", body: { [self] in
            var rows: [UIElement] = []
            rows.append(Controls.presetStrip(presets.enumerated().map { k, p in
                (Glyphs.view(Glyphs.border(p.width), size: 16, brush: Theme.ink(b.preset == k ? 1 : 2)), b.preset == k)
            }, width: Self.content, point: { k in preview(k.map { .borderPreset(slot, $0) }) }, choose: { change(.borderPreset(slot, $0)) }))
            rows.append(paintField(b.paint, target: .border(slot), ids: ids, board: board, suggest: true, change: change, preview: preview))
            let third = (Self.content - 16) / 3
            rows.append(Controls.line([
                field("Size", b.width, range: 0...1000, scrub: 0.25, width: third) { change(.borderWidth(slot, $0)) },
                field("Dash", b.dash, range: 0...1000, scrub: 0.25, width: third) { change(.dash(slot, $0)) },
                field("Gap", b.gap, range: 0...1000, scrub: 0.25, width: third) { change(.gap(slot, $0)) },
            ]))
            if !lineOnly {
                rows.append(Controls.iconChoice(b.position, [
                    ("inside", Glyphs.edge(.inside)), ("center", Glyphs.edge(.center)), ("outside", Glyphs.edge(.outside)),
                ], width: Self.content) { change(.borderPosition(slot, $0)) })
            }
            return rows
        })
    }

    // MARK: Shadow

    /// One of the shadows under the layers, or inside them. The drag lifts them, from none through
    /// each preset to floating.
    private func shadowCard(_ l: WindowsCore.Looks, slot: Int, canInset: Bool, canSpread: Bool,
                            change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                            preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement {
        let s = l.shadows[slot]
        let inset = canInset && s.inset
        let presets = inset ? WindowsCore.innerShadowPresets : WindowsCore.shadowPresets
        let top = WindowsCore.topElevation
        let ids = session.selection
        let dial = Dial(fraction: s.elevation / top, set: { WindowsCore.change(ids, .elevation(slot, ($0 * top).rounded())) },
                        summary: { f in
                            let e = Int((f * top).rounded())
                            return Words.t(e == 0 ? "None" : presets[min(e, presets.count) - 1].name)
                        }, stops: (1...Int(top)).map { Double($0) / top })
        let mark = Self.shadowMark(y: s.first.y, blur: s.first.blur, inset: inset)
        let next = Self.cardID("Shadow", l.shadows.count)
        return card(inset ? "Inner shadow" : "Shadow", s.summary, id: Self.cardID("Shadow", slot), mark: mark, dial: dial,
                    remove: { change(.remove("shadow", slot)) }, removal: "Remove shadow",
                    more: ("Add another shadow", { on in preview(on ? .moreShadow : nil) }, { [self] in self.opened = next; change(.moreShadow) }),
                    style: "shadow:\(slot)", body: { [self] in
            var rows: [UIElement] = []
            if canInset {
                rows.append(Controls.segmented(inset, [(false, "Outside"), (true, "Inside")], width: Self.content) { change(.shadowInset(slot, $0)) })
            }
            rows.append(Controls.presetStrip(presets.enumerated().map { k, p in
                (Self.shadowMark(y: p.y, blur: p.blur, inset: inset), s.preset == k)
            }, width: Self.content, point: { k in preview(k.map { .shadowPreset(slot, $0) }) }, choose: { change(.shadowPreset(slot, $0)) }))
            rows.append(Colours.field(s.colour, suggestions: [], open: { [weak self] anchor in
                self?.openColourPanel(below: anchor, start: s.colour ?? Colour(r: 0, g: 0, b: 0, a: 0.2)) { c in
                    WindowsCore.change(ids, .shadowColour(slot, c))
                    self?.session.edited(board: self?.session.board)
                }
            }, preview: { _ in }, apply: { change(.shadowColour(slot, $0)) }))
            let third = (Self.content - 16) / 3
            rows.append(Controls.line([
                field("X", s.x, range: -1000...1000, scrub: 0.5, width: third) { change(.shadowX(slot, $0)) },
                field("Y", s.y, range: -1000...1000, scrub: 0.5, width: third) { change(.shadowY(slot, $0)) },
                field("B", s.blur, range: 0...1000, scrub: 0.5, width: third) { change(.shadowBlur(slot, $0)) },
            ]))
            if canSpread {
                rows.append(Controls.row("Spread", field("", s.spread, range: -1000...1000, scrub: 0.25) { change(.shadowSpread(slot, $0)) }))
            }
            return rows
        })
    }

    /// A card lifted as far as the shadow lifts it, or pressed as far into the page, as the Mac's
    /// ShadowGlyph: 16 by 13, its shadow under it.
    static func shadowMark(y: Double, blur: Double, inset: Bool) -> FrameworkElement {
        let box = Grid()
        box.width = 22
        box.height = 20
        let card = Border()
        card.width = 16
        card.height = 13
        card.cornerRadius = Theme.corners(3)
        card.background = Theme.brush(Theme.card)
        card.borderBrush = Theme.brush(Theme.ink, 0.12)
        card.borderThickness = Theme.inset(0.5)
        if inset {
            // Pressed in: the shade along the top edge, inside it.
            let shade = Border()
            shade.width = 16
            shade.height = 13
            shade.cornerRadius = Theme.corners(3)
            shade.background = Colours.gradient([(0, Colour(r: 0.23, g: 0.2, b: 0.15, a: min(0.15 + blur / 60, 0.5))), (min(0.25 + y / 20, 0.7), Colour(r: 0.23, g: 0.2, b: 0.15, a: 0))],
                                                from: Point(x: 0.5, y: 0), to: Point(x: 0.5, y: 1))
            for e in [card, shade] { box.children.append(e) }
            return box
        }
        let lift = min(y / 8, 2.5), fall = max(y / 5, 0.5), soft = max(blur / 9, 0.6)
        let shade = Border()
        shade.width = 16 + soft * 2
        shade.height = 13 + soft * 2
        shade.cornerRadius = Theme.corners(3 + soft)
        shade.background = Theme.brush(Theme.shadow, 0.28)
        shade.margin = Theme.inset(0, 2 * fall - 2 * lift, 0, 0)
        card.margin = Theme.inset(0, 0, 0, 2 * lift)
        for e in [shade, card] { box.children.append(e) }
        return box
    }

    // MARK: The fill menu and the colour panel

    /// The chosen colour of a gradient in the fill menu.
    private static var stop = 0

    /// The fill menu, hanging from a paint's swatch: one colour, a gradient along a line or out
    /// from a point, or the picture there is. A gradient lays its colours on a bar, to choose,
    /// move, add and drag off, with the chosen one's colour picked under it.
    func openFillMenu(below anchor: FrameworkElement, target: Target, ids: [UUID], board: Int) {
        Self.stop = 0
        guard let (content, height) = fillMenu(target: target, ids: ids, board: board) else { return }
        menus?.panel(below: anchor, width: Theme.cardWidth, height: height, content: content)
        returnFocus?()
    }

    private func refreshFillMenu(target: Target, ids: [UUID], board: Int) {
        guard let (content, height) = fillMenu(target: target, ids: ids, board: board) else { return }
        menus?.replace(panel: content, width: Theme.cardWidth, height: height)
    }

    private func fillMenu(target: Target, ids: [UUID], board: Int) -> (UIElement, Double)? {
        guard let looks = WindowsCore.looks(ids) else { return nil }
        let paint: WindowsCore.PaintLook
        switch target {
        case .fill(let slot): guard looks.fills.indices.contains(slot) else { return nil }; paint = looks.fills[slot]
        case .border(let slot): guard looks.borders.indices.contains(slot) else { return nil }; paint = looks.borders[slot].paint
        }
        @MainActor func change(_ c: WindowsCore.LookChange) {
            WindowsCore.change(ids, c)
            session.edited(board: board)
        }
        let stack = StackPanel()
        var kinds: [(String, String)] = [("solid", "Solid"), ("linear", "Linear"), ("radial", "Radial")]
        if paint.kind == "picture" { kinds.append(("picture", "Picture")) }
        let well = Controls.segmented(paint.kind, kinds) { [weak self] k in
            switch target {
            case .fill(let slot): change(.fillKind(slot, k))
            case .border(let slot): change(.borderKind(slot, k))
            }
            Self.stop = 0
            self?.refreshFillMenu(target: target, ids: ids, board: board)
        }
        well.margin = Theme.inset(14, 14, 14, 0)
        stack.children.append(well)
        if paint.kind == "picture" {
            let words = Controls.caption("A picture fills this. Choose a colour or a gradient to fill it with that instead.")
            words.margin = Theme.inset(14)
            stack.children.append(words)
            return (stack, 156)
        }
        let gradient = paint.kind == "linear" || paint.kind == "radial"
        let stops = paint.stops
        let chosen = min(Self.stop, max(stops.count - 1, 0))
        // The bar, made again as its colours change in the panel under it.
        let barHolder = Border()
        @MainActor func makeBar(_ stops: [WindowsCore.Stop]) {
            barHolder.child = gradientBar(stops, chosen: min(Self.stop, max(stops.count - 1, 0)), set: { [weak self] next in
                switch target {
                case .fill(let slot): WindowsCore.change(ids, .stops(slot, next))
                case .border(let slot): WindowsCore.change(ids, .borderStops(slot, next))
                }
                self?.session.edited(board: board)
            }, refresh: { [weak self] in self?.refreshFillMenu(target: target, ids: ids, board: board) })
        }
        if gradient, !stops.isEmpty {
            makeBar(stops)
            barHolder.margin = Theme.inset(14, 14, 14, 0)
            stack.children.append(barHolder)
        }
        let start = gradient && !stops.isEmpty ? stops[chosen].colour : paint.first
        let panel = Colours.Panel(start: start, used: Array(WindowsCore.designColours.prefix(18))) { [weak self] c in
            switch target {
            case .fill(let slot): WindowsCore.change(ids, gradient ? .stopColour(slot, stop: chosen, c) : .fillColour(slot, c))
            case .border(let slot): WindowsCore.change(ids, gradient ? .borderStopColour(slot, stop: chosen, c) : .borderColour(slot, c))
            }
            self?.session.edited(board: board)
            guard gradient, let looks = WindowsCore.looks(ids) else { return }
            switch target {
            case .fill(let slot): if looks.fills.indices.contains(slot) { makeBar(looks.fills[slot].stops) }
            case .border(let slot): if looks.borders.indices.contains(slot) { makeBar(looks.borders[slot].paint.stops) }
            }
        }
        stack.children.append(panel.root)
        retained = panel
        return (stack, gradient ? 408 : 374)
    }

    /// The colour panel alone, for a shadow's colour.
    func openColourPanel(below anchor: FrameworkElement, start: Colour, apply: @escaping (Colour) -> Void) {
        let panel = Colours.Panel(start: start, used: Array(WindowsCore.designColours.prefix(18)), apply: apply)
        retained = panel
        menus?.panel(below: anchor, width: Theme.cardWidth, height: Colours.Panel.height, content: panel.root)
        returnFocus?()
    }

    /// The gradient laid out on a bar, its colours on it as pins: a click on the bar adds one
    /// there, a pin dragged along moves its colour, and dragged off the bar takes it away.
    private func gradientBar(_ stops: [WindowsCore.Stop], chosen: Int, set: @escaping @MainActor ([WindowsCore.Stop]) -> Void,
                             refresh: @escaping @MainActor () -> Void) -> FrameworkElement {
        let pin = 16.0, width = Theme.cardWidth - 28, run = width - pin
        let bar = Canvas()
        bar.width = width
        bar.height = pin + 4
        let strip = Grid()
        strip.width = width
        strip.height = 14
        let board = Border()
        board.cornerRadius = Theme.corners(5)
        board.child = Colours.checkerboard(width: width, height: 14)
        strip.children.append(board)
        let colours = Border()
        colours.cornerRadius = Theme.corners(5)
        colours.borderBrush = Theme.brush(Theme.ink, 0.14)
        colours.borderThickness = Theme.inset(0.5)
        // Out past the end stops' centres it keeps their colours, to the bar's ends.
        colours.background = Colours.gradient(stops.sorted { $0.offset < $1.offset }.map { ((pin / 2 + $0.offset * run) / width, $0.colour) })
        strip.children.append(colours)
        try? Canvas.setTop(strip, 3)
        bar.children.append(strip)
        strip.pointerPressed.addHandler { _, args in args?.handled = true }
        strip.tapped.addHandler { _, args in
            guard let p = try? args?.getPosition(strip) else { return }
            let offset = min(max((Double(p.x) - pin / 2) / run, 0), 1)
            // The colour the bar has there, between the stops either side.
            let sorted = stops.sorted { $0.offset < $1.offset }
            let after = sorted.firstIndex { $0.offset >= offset } ?? sorted.count - 1
            let before = max(after - 1, 0)
            let a = sorted[before], b = sorted[after]
            let t = b.offset > a.offset ? (offset - a.offset) / (b.offset - a.offset) : 0
            let c = Colour(r: a.colour.r + (b.colour.r - a.colour.r) * t, g: a.colour.g + (b.colour.g - a.colour.g) * t,
                           b: a.colour.b + (b.colour.b - a.colour.b) * t, a: a.colour.a + (b.colour.a - a.colour.a) * t)
            var next = stops + [WindowsCore.Stop(offset: offset, colour: c)]
            next.sort { $0.offset < $1.offset }
            Self.stop = next.firstIndex { $0.offset == offset } ?? 0
            DispatchQueue.main.async { MainActor.assumeIsolated {
                set(next)
                refresh()
            } }
        }
        for (k, s) in stops.enumerated() {
            let p = Grid()
            p.width = pin
            p.height = pin
            p.children.append(Colours.swatch(s.colour, size: pin, radius: 4))
            let ring = Border()
            ring.cornerRadius = Theme.corners(4)
            ring.borderBrush = k == chosen ? Theme.brush(Theme.pencil) : Theme.brush(Theme.card)
            ring.borderThickness = Theme.inset(k == chosen ? 2 : 1.5)
            p.children.append(ring)
            try? Canvas.setLeft(p, s.offset * run)
            try? Canvas.setTop(p, 2)
            bar.children.append(p)
            var from: (x: Double, offset: Double)?
            var leaving = false
            p.pointerPressed.addHandler { sender, args in
                guard let q = try? args?.getCurrentPoint(bar)?.position else { return }
                args?.handled = true
                from = (Double(q.x), s.offset)
                Self.stop = k
                _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
                WindowsCore.beginGesture()
            }
            p.pointerMoved.addHandler { _, args in
                guard let f = from, let q = try? args?.getCurrentPoint(bar)?.position else { return }
                leaving = stops.count > 2 && abs(Double(q.y) - (pin / 2 + 2)) > 22
                p.opacity = leaving ? 0.3 : 1
                let offset = min(max(f.offset + (Double(q.x) - f.x) / run, 0), 1)
                try? Canvas.setLeft(p, offset * run)
                // In order along the bar, the one moved staying the chosen one as it passes others.
                var next = stops
                next[k] = WindowsCore.Stop(offset: offset, colour: s.colour)
                let order = next.indices.sorted { next[$0].offset < next[$1].offset }
                Self.stop = order.firstIndex(of: k) ?? k
                set(order.map { next[$0] })
            }
            p.pointerReleased.addHandler { sender, args in
                guard from != nil else { return }
                args?.handled = true
                from = nil
                try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
                WindowsCore.endGesture()
                let gone = leaving
                leaving = false
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if gone {
                        // Taken off the bar: the colour goes, the others as they were.
                        var next = stops
                        next.remove(at: k)
                        Self.stop = max(k - 1, 0)
                        set(next)
                    }
                    refresh()
                } }
            }
            p.tapped.addHandler { _, _ in
                Self.stop = k
            }
        }
        return bar
    }
}
