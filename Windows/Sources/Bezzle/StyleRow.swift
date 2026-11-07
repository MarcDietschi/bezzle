import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// How the design's named looks show in the inspector, as the Mac's StyleViews: a card whose look
/// has a name says the name in pencil after its mark, and its picture is ringed. Open, it offers
/// the design's styles of its kind first: a click gives the selection one, pointing at one shows
/// it on the canvas, a double click renames the one it has, × lets go of the name, and the dashed
/// chip names the look it has.
extension Inspector {
    /// What a folded card says of a named look: the mark of a name, and the name, in pencil.
    static func namedSummary(_ name: String) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        row.children.append(nameMark())
        let words = Theme.text(name, size: 12, weight: 500)
        words.foreground = Theme.brush(Theme.pencil)
        words.maxWidth = 130
        row.children.append(words)
        return row
    }

    /// The mark of a name: a small pencil diamond, as a seal pressed into the card.
    static func nameMark(size: Double = 5.5) -> FrameworkElement {
        let holder = Grid()
        holder.width = size * 1.5
        holder.height = size * 1.5
        holder.verticalAlignment = .center
        let diamond = Border()
        diamond.width = size
        diamond.height = size
        diamond.cornerRadius = Theme.corners(size * 0.22)
        diamond.background = Theme.brush(Theme.pencil)
        let turn = CompositeTransform()
        turn.rotation = 45
        turn.centerX = size / 2
        turn.centerY = size / 2
        diamond.renderTransform = turn
        diamond.horizontalAlignment = .center
        diamond.verticalAlignment = .center
        holder.children.append(diamond)
        return holder
    }

    /// The ring round a named card's picture.
    static func nameRing() -> FrameworkElement {
        let ring = Rectangle()
        ring.width = 26
        ring.height = 26
        ring.radiusX = 7.5
        ring.radiusY = 7.5
        ring.stroke = Theme.brush(Theme.pencil, 0.75)
        ring.strokeThickness = 1.2
        ring.isHitTestVisible = false
        ring.horizontalAlignment = .center
        ring.verticalAlignment = .center
        ring.margin = Theme.inset(-2)
        return ring
    }

    /// A style's look in small: its colour, its shadow or its corners (a type says its name in itself).
    static func styleSample(_ s: WindowsCore.StyleSample, size: Double = 13, ink: Brush) -> FrameworkElement? {
        switch s.kind {
        case "colour":
            return s.paint.map { Colours.swatch($0, size: size, radius: size * 0.3) }
        case "shadow":
            guard let sh = s.shadow else { return nil }
            return shadowMark(y: sh.y, blur: sh.blur, inset: sh.inset)
        case "corners":
            return Glyphs.view(Glyphs.corner(s.radius), size: 16, brush: ink)
        default:
            return nil
        }
    }

    /// The design's styles a card's look can be, first in the open card.
    func styleRow(_ key: String) -> UIElement? {
        let ids = session.selection
        guard let row = WindowsCore.styleRow(key, ids, all: stylesAll.contains(key)) else { return nil }
        var items: [FrameworkElement] = row.chips.map { styleChip($0, key: key) }
        if row.hidden > 0 || stylesAll.contains(key) && row.chips.count > WindowsCore.stylesShownCount + 1 {
            items.append(moreChip(hidden: stylesAll.contains(key) ? nil : row.hidden) { [weak self] in
                guard let self else { return }
                if self.stylesAll.contains(key) { self.stylesAll.remove(key) } else { self.stylesAll.insert(key) }
                self.show()
            })
        }
        if let look = row.unnamed { items.append(nameChip(key, look: look)) }
        guard !items.isEmpty else { return nil }
        // A flow of chips, a new row where the next would reach past the card.
        let wrap = StackPanel()
        wrap.spacing = 6
        var line: StackPanel?
        var used = 0.0
        let room = Theme.cardWidth - 24
        for item in items {
            try? item.measure(Size(width: 400, height: 26))
            let w = Double(item.desiredSize.width)
            if line == nil || used + 6 + w > room {
                let l = StackPanel()
                l.orientation = .horizontal
                l.spacing = 6
                wrap.children.append(l)
                line = l
                used = w
            } else {
                used += 6 + w
            }
            line?.children.append(item)
        }
        return wrap
    }

    private func chipFrame(_ active: Bool) -> Border {
        let chip = Border()
        chip.height = 26
        chip.cornerRadius = Theme.corners(8)
        chip.padding = Theme.inset(9, 0, 9, 0)
        chip.background = active ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, 0.04)
        chip.borderBrush = active ? Theme.brush(Theme.pencil, 0.65) : Theme.hairline
        chip.borderThickness = Theme.inset(active ? 1 : 0.5)
        return chip
    }

    /// One of the design's styles, to give the selection.
    private func styleChip(_ c: WindowsCore.StyleChip, key: String) -> FrameworkElement {
        let ids = session.selection
        let chip = chipFrame(c.active)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.verticalAlignment = .center
        let ink: Brush = c.active ? Theme.brush(Theme.pencil) : Theme.ink(2)
        if let sample = Self.styleSample(c.sample, ink: ink) {
            sample.verticalAlignment = .center
            row.children.append(sample)
        }
        if renamingStyle == c.id {
            let field = TextBox()
            field.text = c.name
            field.fontSize = 12
            field.width = 110
            field.minHeight = 22
            field.padding = Theme.inset(4, 2, 4, 0)
            field.allowFocusOnInteraction = true
            var done = false
            func commit(_ keep: Bool) {
                guard !done else { return }
                done = true
                renamingStyle = nil
                if keep { WindowsCore.renameStyle(c.id, to: field.text); edited() }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.show(); self.returnFocus?() } }
            }
            field.keyDown.addHandler { _, args in
                guard let args else { return }
                if args.key == .enter { args.handled = true; commit(true) }
                if args.key == .escape { args.handled = true; commit(false) }
            }
            field.lostFocus.addHandler { _, _ in commit(true) }
            field.loaded.addHandler { _, _ in
                _ = try? field.focus(.programmatic)
                try? field.selectAll()
            }
            row.children.append(field)
        } else {
            let words = Theme.text(c.name, size: 12, weight: c.active ? 500 : 400)
            if c.sample.kind == "type" {
                if let font = Self.font(of: c.sample.family ?? "") { words.fontFamily = font }
                words.fontSize = min(max(c.sample.size * 0.55, 11.5), 15)
                words.fontWeight = FontWeight(weight: UInt16(c.sample.weight))
                if c.sample.italic { words.fontStyle = .italic }
            }
            words.foreground = c.active ? Theme.brush(Theme.pencil) : Theme.ink(1)
            words.maxWidth = 160
            row.children.append(words)
        }
        // × on the style the selection has, while pointed at: the look stays, without its name.
        let cross = Glyphs.view(Glyphs.cross(size: 14), size: 14, brush: Theme.brush(Theme.pencil, 0.8))
        cross.visibility = .collapsed
        cross.verticalAlignment = .center
        if c.active {
            let hit = Border()
            hit.background = Theme.clear
            hit.child = cross
            hit.pointerPressed.addHandler { _, args in args?.handled = true }
            hit.tapped.addHandler { [weak self] _, args in
                args?.handled = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        WindowsCore.unnameStyle(at: key, ids)
                        self?.edited()
                    }
                }
            }
            try? ToolTipService.setToolTip(hit, Words.t("Keep the look, without its name"))
            row.children.append(hit)
        }
        chip.child = row
        let id = c.id, active = c.active
        chip.pointerEntered.addHandler { [weak self] _, _ in
            if active { cross.visibility = .visible } else {
                chip.background = Theme.brush(Theme.ink, 0.075)
                WindowsCore.previewStyle(id, at: key, ids, true)
                self?.session.previewed(board: nil)
            }
            self?.session.pointedStyle = id
        }
        chip.pointerExited.addHandler { [weak self] _, _ in
            cross.visibility = .collapsed
            if !active {
                chip.background = Theme.brush(Theme.ink, 0.04)
                WindowsCore.previewStyle(id, at: key, ids, false)
                self?.session.previewed(board: nil)
            }
            if self?.session.pointedStyle == id { self?.session.pointedStyle = nil }
        }
        chip.pointerPressed.addHandler { _, args in args?.handled = true }
        chip.tapped.addHandler { [weak self] _, _ in
            guard !active else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WindowsCore.useStyle(id, at: key, ids)
                    self?.session.pointedStyle = nil
                    self?.edited()
                }
            }
        }
        chip.doubleTapped.addHandler { [weak self] _, _ in
            guard active, let self else { return }
            self.renamingStyle = id
            self.show()
        }
        try? ToolTipService.setToolTip(chip, Words.t(active ? "Double-click to rename" : "Use this style"))
        return chip
    }

    /// Shows the styles left out of a long row, saying how many; with all of them showing, puts
    /// them away again.
    private func moreChip(hidden: Int?, _ toggle: @escaping @MainActor () -> Void) -> FrameworkElement {
        let chip = Border()
        chip.height = 26
        chip.cornerRadius = Theme.corners(8)
        chip.padding = Theme.inset(9, 0, 9, 0)
        chip.borderBrush = Theme.brush(Theme.ink, 0.16)
        chip.borderThickness = Theme.inset(1)
        chip.background = Theme.clear
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        row.verticalAlignment = .center
        row.children.append(Theme.text(hidden.map { Words.t("%lld more", $0) } ?? Words.t("Fewer"), size: 12, ink: 2))
        let chevron = Glyphs.view(Glyphs.chevron(open: hidden != nil, size: 9), size: 9, brush: Theme.ink(2))
        chevron.verticalAlignment = .center
        row.children.append(chevron)
        chip.child = row
        chip.pointerEntered.addHandler { _, _ in chip.borderBrush = Theme.brush(Theme.ink, 0.28) }
        chip.pointerExited.addHandler { _, _ in chip.borderBrush = Theme.brush(Theme.ink, 0.16) }
        chip.pointerPressed.addHandler { _, args in args?.handled = true }
        chip.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { toggle() } } }
        return chip
    }

    /// The dashed chip that names the look a card shows: a click turns it into a field with a name
    /// already in it, and Enter gives the look that name.
    private func nameChip(_ key: String, look: WindowsCore.StyleSample) -> FrameworkElement {
        let ids = session.selection
        let holder = Grid()
        holder.height = 26
        let edge = Rectangle()
        edge.radiusX = 8
        edge.radiusY = 8
        edge.strokeThickness = 1
        holder.children.append(edge)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.verticalAlignment = .center
        row.margin = Theme.inset(9, 0, 9, 0)
        holder.children.append(row)
        if namingStyle == key {
            let suggested = WindowsCore.suggestedStyleName(at: key, ids)
            edge.stroke = Theme.brush(Theme.pencil, 0.7)
            edge.fill = Theme.brush(Theme.card)
            if let sample = Self.styleSample(look, ink: Theme.brush(Theme.pencil)) {
                sample.verticalAlignment = .center
                row.children.append(sample)
            }
            let field = TextBox()
            field.text = suggested
            field.fontSize = 12
            field.width = 128
            field.minHeight = 22
            field.padding = Theme.inset(4, 2, 4, 0)
            field.allowFocusOnInteraction = true
            var done = false
            func finish(_ keep: Bool) {
                guard !done else { return }
                done = true
                namingStyle = nil
                if keep {
                    WindowsCore.nameLook(at: key, field.text, ids)
                    edited()
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.show(); self.returnFocus?() } }
            }
            field.keyDown.addHandler { _, args in
                guard let args else { return }
                if args.key == .enter { args.handled = true; finish(true) }
                if args.key == .escape { args.handled = true; finish(false) }
            }
            // Clicked away from: kept when a name was typed, let go when the one offered was left.
            field.lostFocus.addHandler { _, _ in finish(field.text != suggested) }
            field.loaded.addHandler { _, _ in
                _ = try? field.focus(.programmatic)
                try? field.selectAll()
            }
            row.children.append(field)
            row.children.append(Self.nameMark(size: 5))
        } else {
            edge.stroke = Theme.brush(Theme.ink, 0.16)
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(2.5)
            edge.strokeDashArray = dashes
            edge.fill = Theme.clear
            let plus = Glyphs.view(Glyphs.plus(size: 14), size: 14, brush: Theme.ink(2))
            plus.verticalAlignment = .center
            row.children.append(plus)
            let words = Theme.text(Words.t("Style"), size: 12, ink: 2)
            row.children.append(words)
            holder.pointerEntered.addHandler { _, _ in
                edge.stroke = Theme.brush(Theme.ink, 0.28)
                words.foreground = Theme.ink(1)
            }
            holder.pointerExited.addHandler { _, _ in
                edge.stroke = Theme.brush(Theme.ink, 0.16)
                words.foreground = Theme.ink(2)
            }
            holder.pointerPressed.addHandler { _, args in args?.handled = true }
            holder.tapped.addHandler { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.namingStyle = key
                        self?.show()
                    }
                }
            }
            try? ToolTipService.setToolTip(holder, Words.t("Give this look a name, to use it on other layers and change it everywhere at once"))
        }
        holder.background = Theme.clear
        return holder
    }

    private func edited() { session.edited(board: nil) }
}
