import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The design's named looks while nothing is picked, as the Mac's StyleKit: its colours as paint
/// chips, its type set in itself, its shadows and corners on small cards. Pointing at one outlines
/// every layer that has it; a click opens it, to change it everywhere at once. Looks several
/// layers have alike without a name wait after them, dashed, each with how many have it: a click
/// names it, and every one of them with it. A design never needs setting up for any of this.
extension Inspector {
    func styleKitCards() -> [UIElement] {
        WindowsCore.styleKit().map { kitCard($0.kind, named: $0.named, found: $0.found) }
    }

    private static let kitGap = 8.0
    private static func kitColumns(_ kind: String) -> Int { kind == "colour" ? 3 : 4 }
    private static func kitWidth(_ kind: String) -> Double {
        let n = Double(kitColumns(kind))
        return ((Theme.cardWidth - 24 - kitGap * (n - 1)) / n).rounded(.down)
    }

    private func kitCard(_ kind: String, named: [WindowsCore.KitEntry], found: [WindowsCore.KitEntry]) -> UIElement {
        let stack = StackPanel()
        stack.spacing = kind == "text" ? 2 : 10
        if kind == "text" {
            for e in named {
                stack.children.append(typeRow(e))
                if let id = e.id, kitOpen == id { stack.children.append(styleEditor(id)) }
            }
            for (k, e) in found.enumerated() { stack.children.append(ghostTypeRow(e, kind: kind, index: k)) }
        } else {
            let all = named.map { ($0, Int?.none) } + found.enumerated().map { ($0.element, Optional($0.offset)) }
            let columns = Self.kitColumns(kind)
            let grid = StackPanel()
            grid.spacing = 10
            var row: StackPanel?
            for (k, item) in all.enumerated() {
                if k % columns == 0 {
                    let r = StackPanel()
                    r.orientation = .horizontal
                    r.spacing = Self.kitGap
                    grid.children.append(r)
                    row = r
                }
                row?.children.append(kind == "colour" ? paintChip(item.0, index: item.1) : tile(item.0, kind: kind, index: item.1))
            }
            stack.children.append(grid)
            if let id = kitOpen, named.contains(where: { $0.id == id }) { stack.children.append(styleEditor(id)) }
        }
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.padding = Theme.inset(12)
        card.child = stack
        return card
    }

    // MARK: Pointing and opening

    private func point(_ e: WindowsCore.KitEntry, kind: String, index: Int?, _ inside: Bool) {
        if let id = e.id {
            if inside { session.pointedStyle = id } else if session.pointedStyle == id { session.pointedStyle = nil }
        } else if let index {
            session.litLayers = inside ? WindowsCore.foundLayers(kind, index) : []
        }
    }

    private func tap(_ e: WindowsCore.KitEntry, kind: String, index: Int?) {
        session.pointedStyle = nil
        session.litLayers = []
        if let id = e.id {
            kitNaming = false
            kitDark = false
            kitOpen = kitOpen == id ? nil : id
            show()
        } else if let index, let made = WindowsCore.nameFound(kind, index) {
            // Named, and opened with its name ready to type.
            kitOpen = made
            kitNaming = true
            kitDark = false
            session.edited(board: nil)
        }
    }

    private func hookUp(_ view: FrameworkElement, _ e: WindowsCore.KitEntry, kind: String, index: Int?,
                        hovered: @escaping @MainActor (Bool) -> Void) {
        view.pointerEntered.addHandler { [weak self] _, _ in
            hovered(true)
            self?.point(e, kind: kind, index: index, true)
        }
        view.pointerExited.addHandler { [weak self] _, _ in
            hovered(false)
            self?.point(e, kind: kind, index: index, false)
        }
        view.pointerPressed.addHandler { _, args in args?.handled = true }
        view.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tap(e, kind: kind, index: index) } }
        }
        try? ToolTipService.setToolTip(view, e.name ?? Words.t("Give this look a name: all %lld layers that have it take it", e.uses))
    }

    // MARK: Chips

    private static func paintBrush(_ p: WindowsCore.PaintLook) -> Brush {
        if p.kind == "linear" || p.kind == "radial" {
            let stops = p.stops.sorted { $0.offset < $1.offset }.map { ($0.offset, $0.colour) }
            return Colours.gradient(stops, from: Point(x: Float(p.start.x), y: Float(p.start.y)), to: Point(x: Float(p.end.x), y: Float(p.end.y)))
        }
        return Colours.brush(p.colour ?? p.first)
    }

    /// A colour as a paint chip, as a printer's fan deck has them: the colour above (and beside it
    /// the same in the dark, with the moon's mark), its name and hex on the strip below.
    private func paintChip(_ e: WindowsCore.KitEntry, index: Int?) -> FrameworkElement {
        let ghost = e.id == nil, open = e.id != nil && kitOpen == e.id
        let width = Self.kitWidth("colour")
        let holder = Grid()
        holder.width = width
        let stack = StackPanel()
        let colours = Grid()
        colours.height = 40
        colours.cornerRadius = CornerRadius(topLeft: 7, topRight: 7, bottomRight: 0, bottomLeft: 0)
        colours.margin = ghost ? Theme.inset(6, 6, 6, 0) : Theme.inset(3, 3, 3, 0)
        let light = Border()
        if let p = e.sample.paint { light.background = Self.paintBrush(p) }
        colours.children.append(light)
        if let d = e.dark?.paint {
            for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .star)] {
                let c = ColumnDefinition()
                c.width = w
                colours.columnDefinitions.append(c)
            }
            let night = Grid()
            night.background = Self.paintBrush(d)
            let lightness = 0.2126 * d.first.r + 0.7152 * d.first.g + 0.0722 * d.first.b
            let moon = Glyphs.view(Glyphs.moon(size: 9), size: 9, brush: Theme.brush(lightness > 0.6 ? 0x000000 : 0xFFFFFF, 0.55))
            moon.horizontalAlignment = .right
            moon.verticalAlignment = .bottom
            moon.margin = Theme.inset(0, 0, 3, 3)
            night.children.append(moon)
            try? Grid.setColumn(night, 1)
            colours.children.append(night)
        }
        stack.children.append(colours)
        let words = StackPanel()
        words.spacing = 1
        words.margin = ghost ? Theme.inset(8, 5, 8, 6) : Theme.inset(6, 5, 6, 6)
        let title = Theme.text(e.name ?? "×\(e.uses)", size: 10.5, weight: 600, ink: ghost ? 2 : 1)
        if open { title.foreground = Theme.brush(Theme.pencil) }
        words.children.append(title)
        let hex = Theme.text(e.detail, size: 9, weight: 500, ink: 3)
        hex.fontFamily = FontFamily("Consolas")
        words.children.append(hex)
        stack.children.append(words)
        if ghost {
            let edge = Rectangle()
            edge.radiusX = 9
            edge.radiusY = 9
            edge.stroke = Theme.brush(Theme.ink, 0.2)
            edge.strokeThickness = 1
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(2.5)
            edge.strokeDashArray = dashes
            holder.children.append(edge)
        } else {
            let paper = Border()
            paper.cornerRadius = Theme.corners(9)
            paper.background = Theme.brush(Theme.paper)
            paper.borderBrush = open ? Theme.brush(Theme.pencil) : Theme.hairline
            paper.borderThickness = Theme.inset(open ? 1.5 : 0.5)
            holder.children.append(paper)
        }
        holder.children.append(stack)
        let badge = usesBadge(e.uses)
        holder.children.append(badge)
        holder.background = Theme.clear
        let lift = CompositeTransform()
        holder.renderTransform = lift
        hookUp(holder, e, kind: "colour", index: index) { on in
            lift.translateY = on && !ghost ? -2 : 0
            if ghost { title.text = on ? Words.t("Name it") : "×\(e.uses)" } else { badge.visibility = on && e.uses > 0 ? .visible : .collapsed }
        }
        return holder
    }

    /// How many layers use a style, in a pencil capsule at a chip's corner, while it is pointed at.
    private func usesBadge(_ uses: Int) -> FrameworkElement {
        let badge = Border()
        badge.minWidth = 15
        badge.height = 15
        badge.cornerRadius = Theme.corners(7.5)
        badge.background = Theme.brush(Theme.pencil)
        badge.padding = Theme.inset(4.5, 0, 4.5, 0)
        badge.horizontalAlignment = .right
        badge.verticalAlignment = .top
        badge.margin = Theme.inset(0, -6, -5, 0)
        let n = Theme.text("\(uses)", size: 9.5, weight: 600)
        n.foreground = Theme.brush(Theme.onInk)
        n.horizontalAlignment = .center
        badge.child = n
        badge.visibility = .collapsed
        badge.isHitTestVisible = false
        return badge
    }

    /// A shadow or corners on a small card, its name under it; dashed, a look found, with how
    /// many layers have it.
    private func tile(_ e: WindowsCore.KitEntry, kind: String, index: Int?) -> FrameworkElement {
        let ghost = e.id == nil, open = e.id != nil && kitOpen == e.id
        let width = Self.kitWidth(kind)
        let column = StackPanel()
        column.spacing = 5
        column.width = width
        let card = Grid()
        card.width = 46
        card.height = 46
        card.horizontalAlignment = .center
        if ghost {
            let edge = Rectangle()
            edge.radiusX = 12
            edge.radiusY = 12
            edge.stroke = Theme.brush(Theme.ink, 0.22)
            edge.strokeThickness = 1
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(2.5)
            edge.strokeDashArray = dashes
            card.children.append(edge)
        } else {
            let well = Border()
            well.cornerRadius = Theme.corners(12)
            well.background = Theme.brush(Theme.well)
            if open {
                well.borderBrush = Theme.brush(Theme.pencil)
                well.borderThickness = Theme.inset(2)
            }
            card.children.append(well)
        }
        let picture: FrameworkElement
        if kind == "shadow", let s = e.sample.shadow {
            picture = Self.shadowMark(y: s.y, blur: s.blur, inset: s.inset)
        } else {
            picture = Glyphs.view(Glyphs.corner(e.sample.radius), size: 24, brush: Theme.ink(1))
        }
        picture.horizontalAlignment = .center
        picture.verticalAlignment = .center
        card.children.append(picture)
        let badge = ghost ? countBadge(e.uses) : usesBadge(e.uses)
        card.children.append(badge)
        column.children.append(card)
        let name = Theme.text(e.name ?? Words.t("Name it"), size: 10.5, weight: open ? 600 : 400, ink: e.name == nil ? 3 : 2)
        if open { name.foreground = Theme.brush(Theme.pencil) }
        name.horizontalAlignment = .center
        if ghost { name.opacity = 0 }
        column.children.append(name)
        column.background = Theme.clear
        let lift = CompositeTransform()
        lift.centerX = 23
        lift.centerY = 23
        card.renderTransform = lift
        hookUp(column, e, kind: kind, index: index) { on in
            lift.scaleX = on ? 1.07 : 1
            lift.scaleY = lift.scaleX
            lift.translateY = on ? -2 : 0
            if ghost { name.opacity = on ? 1 : 0 } else { badge.visibility = on && e.uses > 0 ? .visible : .collapsed }
        }
        return column
    }

    /// How many layers have a look found, always showing, quiet.
    private func countBadge(_ uses: Int) -> FrameworkElement {
        let badge = Border()
        badge.height = 15
        badge.cornerRadius = Theme.corners(7.5)
        badge.background = Theme.brush(Theme.card)
        badge.borderBrush = Theme.hairline
        badge.borderThickness = Theme.inset(0.5)
        badge.padding = Theme.inset(4.5, 0, 4.5, 0)
        badge.horizontalAlignment = .right
        badge.verticalAlignment = .top
        badge.margin = Theme.inset(0, -5, -6, 0)
        badge.child = Theme.text("×\(uses)", size: 9.5, weight: 600, ink: 2)
        badge.isHitTestVisible = false
        return badge
    }

    /// A named type, set in itself, with its size beside it.
    private func typeRow(_ e: WindowsCore.KitEntry) -> FrameworkElement {
        let open = kitOpen == e.id
        let row = Grid()
        row.minHeight = 32
        row.cornerRadius = Theme.corners(8)
        row.padding = Theme.inset(8, 0, 8, 0)
        row.background = open ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.clear
        let name = Theme.text(e.name ?? "", size: min(max(e.sample.size, 12), 22))
        if let font = Self.font(of: e.sample.family ?? "") { name.fontFamily = font }
        name.fontWeight = FontWeight(weight: UInt16(e.sample.weight))
        if e.sample.italic { name.fontStyle = .italic }
        if open { name.foreground = Theme.brush(Theme.pencil) }
        name.maxWidth = Theme.cardWidth - 100
        name.horizontalAlignment = .left
        row.children.append(name)
        let right = StackPanel()
        right.orientation = .horizontal
        right.spacing = 8
        right.horizontalAlignment = .right
        right.verticalAlignment = .center
        let badge = usesBadge(e.uses)
        badge.margin = Theme.inset(0)
        badge.verticalAlignment = .center
        right.children.append(badge)
        right.children.append(Theme.text(e.detail, size: 11.5, ink: 3))
        row.children.append(right)
        hookUp(row, e, kind: "text", index: nil) { on in
            if !open { row.background = on ? Theme.brush(Theme.ink, 0.05) : Theme.clear }
            badge.visibility = on && e.uses > 0 ? .visible : .collapsed
        }
        return row
    }

    /// A type several text layers have alike without a name, dashed, set in itself.
    private func ghostTypeRow(_ e: WindowsCore.KitEntry, kind: String, index: Int) -> FrameworkElement {
        let row = Grid()
        row.minHeight = 32
        let edge = Rectangle()
        edge.radiusX = 8
        edge.radiusY = 8
        edge.stroke = Theme.brush(Theme.ink, 0.18)
        edge.strokeThickness = 1
        let dashes = DoubleCollection()
        dashes.append(3)
        dashes.append(2.5)
        edge.strokeDashArray = dashes
        row.children.append(edge)
        let name = Theme.text(e.typeName, size: min(max(e.sample.size, 12), 18), ink: 2)
        if let font = Self.font(of: e.sample.family ?? "") { name.fontFamily = font }
        name.fontWeight = FontWeight(weight: UInt16(e.sample.weight))
        if e.sample.italic { name.fontStyle = .italic }
        name.margin = Theme.inset(8, 0, 8, 0)
        name.maxWidth = Theme.cardWidth - 110
        name.horizontalAlignment = .left
        row.children.append(name)
        let right = StackPanel()
        right.orientation = .horizontal
        right.spacing = 8
        right.horizontalAlignment = .right
        right.verticalAlignment = .center
        right.margin = Theme.inset(0, 0, 8, 0)
        let count = countBadge(e.uses)
        count.margin = Theme.inset(0)
        count.verticalAlignment = .center
        right.children.append(count)
        right.children.append(Theme.text(e.detail, size: 11.5, ink: 3))
        row.children.append(right)
        row.background = Theme.clear
        hookUp(row, e, kind: kind, index: index) { on in edge.stroke = Theme.brush(Theme.ink, on ? 0.34 : 0.18) }
        return row
    }

    // MARK: Changing one

    /// The words for light and dark, which the Mac keeps under keys of their own ("Light" is
    /// also a photo's).
    func appearance(_ dark: Bool) -> String {
        let key = dark ? "appearance.dark" : "appearance.light"
        let w = Words.t(key)
        return w == key ? (dark ? "Dark" : "Light") : w
    }

    /// Draws a change to a style at once, and once nothing has changed for a moment, makes the
    /// kit again and keeps the design.
    private func settleKit() {
        session.previewed(board: nil)
        kitChanges += 1
        let mine = kitChanges
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.kitChanges == mine else { return }
                self.session.edited(board: nil)
            }
        }
    }

    /// A style opened in the kit: its name, and what makes its look. Every change goes to every
    /// layer that has it, as they show at once.
    private func styleEditor(_ id: UUID) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 8
        stack.margin = Theme.inset(0, 4, 0, 4)
        guard let e = WindowsCore.styleEdit(id, dark: kitDark) else { return stack }
        func changed() { session.edited(board: nil) }
        // The name, with its mark, and taking the style away.
        let head = Grid()
        head.columnSpacing = 8
        for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 24, gridUnitType: .pixel)] {
            let c = ColumnDefinition()
            c.width = w
            head.columnDefinitions.append(c)
        }
        let well = Theme.well(radius: 7)
        well.height = 28
        let nameRow = Grid()
        let mark = Self.nameMark()
        mark.horizontalAlignment = .left
        mark.margin = Theme.inset(8, 0, 0, 0)
        nameRow.children.append(mark)
        let nameField = TextBox()
        nameField.text = e.name
        nameField.fontSize = 12.5
        nameField.fontWeight = FontWeight(weight: 500)
        nameField.background = Theme.clear
        nameField.borderThickness = Theme.inset(0)
        nameField.margin = Theme.inset(18, 0, 4, 0)
        nameField.minHeight = 26
        nameField.padding = Theme.inset(4, 4, 4, 0)
        nameField.allowFocusOnInteraction = true
        var kept = false
        func keep() {
            guard !kept else { return }
            kept = true
            kitNaming = false
            WindowsCore.renameStyle(id, to: nameField.text)
            changed()
        }
        nameField.keyDown.addHandler { [weak self] _, args in
            guard let args, args.key == .enter else { return }
            args.handled = true
            keep()
            self?.returnFocus?()
        }
        nameField.lostFocus.addHandler { _, _ in keep() }
        if kitNaming {
            nameField.loaded.addHandler { _, _ in
                _ = try? nameField.focus(.programmatic)
                try? nameField.selectAll()
            }
        }
        nameRow.children.append(nameField)
        well.child = nameRow
        head.children.append(well)
        let remove = Controls.iconButton(Glyphs.cross(size: 24), size: 24) { [weak self] in
            WindowsCore.removeStyle(id)
            self?.kitOpen = nil
            self?.session.edited(board: nil)
        }
        try? ToolTipService.setToolTip(remove, Words.t("Remove style"))
        remove.verticalAlignment = .center
        try? Grid.setColumn(remove, 1)
        head.children.append(remove)
        stack.children.append(head)
        // Light or dark, while the design shows anything dark, and following the light again.
        if e.darkens {
            let line = Grid()
            let pick = Controls.segmented(kitDark, [(false, appearance(false)), (true, appearance(true))], width: 150) { [weak self] d in
                self?.kitDark = d
                self?.show()
            }
            pick.horizontalAlignment = .left
            line.children.append(pick)
            if kitDark, e.ownDark {
                let auto = Controls.cardButton(Words.t("Automatic"), height: 28) { [weak self] in
                    WindowsCore.followInTheDark(id)
                    self?.session.edited(board: nil)
                }
                auto.horizontalAlignment = .right
                try? ToolTipService.setToolTip(auto, Words.t("Make it dark by itself again, from its light look"))
                line.children.append(auto)
            }
            stack.children.append(line)
        }
        let dark = kitDark
        switch e.kind {
        case "colour":
            if let c = e.colour, !e.gradient {
                // The panel stays while it is dragged in, its drag one step: what changes is drawn
                // at once, and the kit is made again once the colour has settled.
                let panel = Colours.Panel(start: c, used: Array(WindowsCore.designColours.prefix(18))) { [weak self] next in
                    WindowsCore.changeStyle(id, dark: dark, .colour(next))
                    self?.settleKit()
                }
                kitPanel = panel
                stack.children.append(panel.root)
            } else if let c = e.colour {
                let swatch = Border()
                swatch.height = 44
                swatch.cornerRadius = Theme.corners(8)
                swatch.background = Colours.brush(c)
                stack.children.append(swatch)
            }
        case "text":
            stack.children.append(Controls.menuButton(WindowsCore.displayName(e.family), width: Theme.cardWidth - 24, menus: menus, entries: {
                WindowsCore.fontFamilies.map { f in
                    .item(WindowsCore.displayName(f), checked: f == e.family, font: f == "System" ? Theme.ui : Self.font(of: f)) { [weak self] in
                        WindowsCore.changeStyle(id, dark: false, .family(f))
                        self?.session.edited(board: nil)
                    }
                }
            }))
            let faces = Controls.menuButton(e.face, menus: menus, menuWidth: 200, entries: {
                WindowsCore.faces(of: e.family).map { f in
                    .item(f, checked: f == e.face) { [weak self] in
                        WindowsCore.changeStyle(id, dark: false, .face(f))
                        self?.session.edited(board: nil)
                    }
                }
            })
            let size = field("", e.size, unit: "pt", range: 1...2000, scrub: 0.25, width: Self.endField) { [weak self] v in
                WindowsCore.changeStyle(id, dark: false, .size(v))
                self?.session.edited(board: nil)
            }
            stack.children.append(Controls.line([faces, size]))
            stack.children.append(pair(field(Words.t("text.line-spacing") == "text.line-spacing" ? "Line" : Words.t("text.line-spacing"), e.line, range: 0...4000, scrub: 0.25) { [weak self] v in
                WindowsCore.changeStyle(id, dark: false, .line(v))
                self?.session.edited(board: nil)
            }, field(Words.t("Letter"), e.tracking, range: -500...2000) { [weak self] v in
                WindowsCore.changeStyle(id, dark: false, .tracking(v))
                self?.session.edited(board: nil)
            }))
        case "shadow":
            if let s = e.shadow {
                stack.children.append(Colours.field(s.colour, suggestions: [], open: { [weak self] anchor in
                    self?.openColourPanel(below: anchor, start: s.colour) { c in
                        WindowsCore.changeStyle(id, dark: dark, .shadowColour(c))
                        self?.session.edited(board: nil)
                    }
                }, preview: { _ in }, apply: { [weak self] c in
                    WindowsCore.changeStyle(id, dark: dark, .shadowColour(c))
                    self?.session.edited(board: nil)
                }))
                let third = (Theme.cardWidth - 24 - 16) / 3
                func number(_ label: String, _ v: Double, range: ClosedRange<Double>, _ make: @escaping (Double) -> WindowsCore.StyleChange) -> FrameworkElement {
                    field(label, v, range: range, scrub: 0.5, width: third) { [weak self] next in
                        WindowsCore.changeStyle(id, dark: dark, make(next))
                        self?.session.edited(board: nil)
                    }
                }
                stack.children.append(Controls.line([number("X", s.x, range: -1000...1000) { .shadowX($0) },
                                                     number("Y", s.y, range: -1000...1000) { .shadowY($0) },
                                                     number("B", s.blur, range: 0...1000) { .shadowBlur($0) }]))
                let spread = field("", s.spread, range: -1000...1000, scrub: 0.5, width: Self.endField) { [weak self] v in
                    WindowsCore.changeStyle(id, dark: dark, .shadowSpread(v))
                    self?.session.edited(board: nil)
                }
                stack.children.append(Controls.row("Spread", spread))
            }
        case "corners":
            let shape = Controls.segmented(e.smooth, [(false, "Round"), (true, "Squircle")], width: Theme.cardWidth - 24 - Self.endField - 8) { [weak self] on in
                WindowsCore.changeStyle(id, dark: false, .smooth(on))
                self?.session.edited(board: nil)
            }
            let radius = field("R", e.radius, range: 0...10_000, width: Self.endField) { [weak self] v in
                WindowsCore.changeStyle(id, dark: false, .radius(v))
                self?.session.edited(board: nil)
            }
            stack.children.append(Controls.line([shape, radius]))
        default:
            break
        }
        return stack
    }
}

extension Glyphs {
    /// The moon: a disc with a bite taken out of it.
    static func moon(size s: Double = 12) -> [Part] {
        var p = PathData()
        // An outer arc and an inner one, as short straight steps.
        let c = (x: s * 0.5, y: s * 0.5), r = s * 0.38
        let inner = (x: s * 0.68, y: s * 0.36), ri = s * 0.3
        var first = true
        var a = 0.0
        while a <= 360 {
            let x = c.x + r * cos(a * .pi / 180), y = c.y + r * sin(a * .pi / 180)
            // Only the part of the disc outside the bite.
            if hypot(x - inner.x, y - inner.y) >= ri {
                if first { p.move(x, y); first = false } else { p.line(x, y) }
            }
            a += 10
        }
        var b = 360.0
        while b >= 0 {
            let x = inner.x + ri * cos(b * .pi / 180), y = inner.y + ri * sin(b * .pi / 180)
            if hypot(x - c.x, y - c.y) <= r { p.line(x, y) }
            b -= 10
        }
        p.close()
        return [Part(data: p.d, mode: .fill)]
    }
}

extension Inspector {
    /// An artboard shown dark, or light with its switch kept, as the Mac's DarkCard: its named
    /// looks in their dark looks, made dark by themselves until one is changed there by hand. The
    /// sun and moon on its line flip between the two; taken away, the artboard is light for good.
    func darkCard(_ id: UUID, board: Int) -> UIElement? {
        guard let a = WindowsCore.boardAppearance(id), a.dark != nil else { return nil }
        let dark = a.shows
        let pair = lightDarkPair(dark: dark) { [weak self] d in
            guard let self else { return }
            _ = WindowsCore.showDark(id, d, picked: self.session.selection.contains(id))
            self.session.edited(board: nil)
        }
        let mark = Glyphs.view(dark ? Glyphs.moon(size: 14) : Glyphs.sun(size: 15), size: 15, brush: Theme.ink(2))
        return card(appearance(dark), a.own == 0 ? "" : Words.t("%lld of %lld adjusted", a.own, a.named), id: "Appearance", mark: mark,
                    remove: { [weak self] in
                        WindowsCore.forgetDark(id)
                        self?.session.edited(board: nil)
                    }, removal: "No dark look", accessory: pair, body: { [self] in
            let twin = Controls.cardButton(Words.t("Light One Beside It"), height: 28) { [weak self] in
                guard let self, let made = WindowsCore.addLightTwin(id) else { return }
                self.session.select([made], on: WindowsCore.boardIndex(of: made))
                self.session.edited(board: nil)
            }
            return [twin]
        })
    }

    /// Light or dark, as a sun and a moon in one well, the one chosen raised.
    private func lightDarkPair(dark: Bool, _ choose: @escaping @MainActor (Bool) -> Void) -> FrameworkElement {
        let well = Theme.well(radius: 8)
        well.padding = Theme.inset(2)
        let row = StackPanel()
        row.orientation = .horizontal
        for d in [false, true] {
            let cell = Border()
            cell.width = 28
            cell.height = 20
            cell.cornerRadius = Theme.corners(6)
            cell.background = d == dark ? Theme.brush(Theme.card) : Theme.clear
            let glyph = Glyphs.view(d ? Glyphs.moon(size: 13) : Glyphs.sun(size: 14), size: 14, brush: Theme.ink(d == dark ? 1 : 3))
            glyph.horizontalAlignment = .center
            glyph.verticalAlignment = .center
            cell.child = glyph
            cell.pointerPressed.addHandler { _, args in args?.handled = true }
            cell.tapped.addHandler { _, args in
                args?.handled = true
                guard d != dark else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { choose(d) } }
            }
            try? ToolTipService.setToolTip(cell, appearance(d))
            row.children.append(cell)
        }
        well.child = row
        return well
    }
}

extension Glyphs {
    /// A sun: a disc and its rays.
    static func sun(size s: Double = 14) -> [Part] {
        var disc = PathData(), rays = PathData()
        let c = s / 2, r = s / 2
        disc.ellipse(c - r * 0.42, c - r * 0.42, r * 0.84, r * 0.84)
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            rays.move(c + cos(a) * r * 0.66, c + sin(a) * r * 0.66)
            rays.line(c + cos(a) * r * 0.95, c + sin(a) * r * 0.95)
        }
        return [Part(data: disc.d, mode: .fill), Part(data: rays.d, mode: .stroke, width: max(1, r * 0.17))]
    }
}
