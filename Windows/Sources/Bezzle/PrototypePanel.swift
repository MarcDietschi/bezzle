import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The inspector while the design is seen as a prototype, as the Mac's PrototypeInspector: with a
/// layer picked, where it goes (every screen as a small picture, or back), what is said of it and
/// how the screen comes on; with a screen picked, its own part (going on by itself, starting
/// there); with nothing picked, where the prototype starts and the ways through it.
extension Inspector {
    func showPrototype() {
        let ids = session.selection
        let screens = WindowsCore.prototypeScreens()
        if ids.isEmpty {
            cards.children.append(startCard(screens))
            return
        }
        guard let look = WindowsCore.flowLook(ids) else { return }
        // Where a picked layer goes is what there is to see of it: its card opens by itself, once.
        if ids != prototypePicked {
            prototypePicked = ids
            opened = ids.count == 1 && look.screen != nil ? "Screen" : "Goes To"
        }
        if ids.count == 1, let board = look.screen {
            cards.children.append(screenCard(board, look: look, screens: screens))
            if look.after == nil {
                cards.children.append(Controls.caption("Drag the card sideways and the screen goes on by itself, as a splash screen does."))
            }
        } else {
            cards.children.append(goesToCard(look, screens: screens))
        }
    }

    private func edited() { session.edited(board: nil) }

    /// Where a layer goes: every screen to go to as a small picture with its name, and the hook to
    /// go back; what is said of it; and how the screen comes on.
    private func goesToCard(_ look: WindowsCore.FlowLook, screens: [(id: UUID, name: String, starts: Bool)]) -> UIElement {
        let ids = look.sources
        let leads = look.to != nil || look.back
        let summary = !look.alike ? Words.t("Mixed") : look.back ? Words.t("Back")
            : look.to.flatMap { to in screens.first { $0.id == to }?.name } ?? Words.t("Nowhere")
        var remove: (@MainActor () -> Void)?
        if leads { remove = { [weak self] in WindowsCore.linkFlow(ids, to: nil); self?.edited() } }
        return card("Goes To", summary, glyph: Glyphs.thread(), remove: remove, removal: "Remove Link", body: { [self] in
            var rows: [UIElement] = []
            rows.append(screenGrid(screens.filter { $0.id != look.home }, chosen: look.alike ? look.to : nil, back: look.alike && look.back, offersBack: true) { [weak self] to, back in
                WindowsCore.linkFlow(ids, to: to, back: back)
                self?.edited()
            })
            if leads {
                rows.append(noteField(ids, note: look.note ?? ""))
                rows.append(Controls.segmented(look.motion, WindowsCore.flowMotions.map { ($0.name, $0.title) }, width: Theme.cardWidth - 24) { [weak self] m in
                    WindowsCore.setFlowMotion(m, for: ids)
                    self?.edited()
                })
            }
            return rows
        })
    }

    /// A screen's own part: its drag sets how long it waits before going on by itself, as a splash
    /// screen does; open, whether the prototype starts there, and where it goes on to.
    private func screenCard(_ board: UUID, look: WindowsCore.FlowLook, screens: [(id: UUID, name: String, starts: Bool)]) -> UIElement {
        let after = look.after ?? 0
        let starts = screens.first { $0.id == board }?.starts == true || screens.first?.id == board && !screens.contains { $0.starts }
        let ins = WindowsCore.waysIn(board)
        let summary = after > 0 ? Words.t("On after %@ s", String(format: "%.1f", after))
            : starts ? Words.t("Starts here") : ins == 1 ? Words.t("1 way in") : Words.t("%lld ways in", ins)
        // From nothing to ten seconds, in halves, catching at the usual waits.
        let dial = Dial(fraction: after / 10, set: { f in
            let v = (f * 20).rounded() / 2
            WindowsCore.setGoesOn(after: v < 0.05 ? nil : v, board: board)
        }, summary: { f in
            let v = (f * 20).rounded() / 2
            return v < 0.05 ? Words.t("Off") : "\(String(format: "%.1f", v)) s"
        }, stops: [0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5])
        return card("Screen", summary, glyph: Glyphs.kind("artboard"), dial: dial, body: { [self] in
            var rows: [UIElement] = []
            rows.append(Controls.row("Starts here", Controls.toggle(starts) { [weak self] on in
                WindowsCore.setStart(on ? board : nil)
                self?.edited()
            }))
            if after > 0 {
                rows.append(Controls.caption("Then goes on by itself to"))
                rows.append(screenGrid(screens.filter { $0.id != board }, chosen: look.to, back: false, offersBack: false) { [weak self] to, _ in
                    WindowsCore.linkFlow([board], to: to)
                    self?.edited()
                })
            }
            rows.append(Controls.cardButton(Words.t("Play from Here"), height: 28) { [weak self] in self?.session.play?(board) })
            return rows
        })
    }

    /// With nothing picked: the screen the prototype starts on, standing in its device on a small
    /// stage, lit as on the canvas: a click plays it. Under it the flag names it and offers the
    /// other screens to start on; then the ways through it.
    private func startCard(_ screens: [(id: UUID, name: String, starts: Bool)]) -> UIElement {
        let start = screens.first { $0.starts } ?? screens.first
        let stack = StackPanel()
        let width = Theme.cardWidth
        let top = Grid()
        top.height = 206
        top.cornerRadius = CornerRadius(topLeft: 12, topRight: 12, bottomRight: 0, bottomLeft: 0)
        top.background = Theme.brush(Theme.table)
        let paper = Self.rendered(CGSize(width: width, height: 206)) { scale, fill in
            WindowsCore.playerStage(width: Int((width * scale).rounded()), height: Int((206 * scale).rounded()), scale: scale, table: Theme.table,
                                    dark: Theme.dark, step: 7, fade: (0.5, 30, 190, 0.4), lit: false, into: fill)
        }
        paper.stretch = .fill
        top.children.append(paper)
        if let start, let device = startDevice(start.id) {
            let lift = CompositeTransform()
            device.renderTransform = lift
            device.horizontalAlignment = .center
            device.verticalAlignment = .center
            top.children.append(device)
            let disc = Grid()
            disc.width = 46
            disc.height = 46
            disc.horizontalAlignment = .center
            disc.verticalAlignment = .center
            disc.isHitTestVisible = false
            let round = Ellipse()
            round.fill = Theme.brush(Theme.pencil)
            disc.children.append(round)
            let triangle = Glyphs.view(Glyphs.play(size: 18), size: 18, brush: Theme.brush(0xFFFFFF))
            triangle.horizontalAlignment = .center
            triangle.verticalAlignment = .center
            triangle.margin = Theme.inset(3, 0, 0, 0)
            disc.children.append(triangle)
            let swell = CompositeTransform()
            swell.centerX = 23
            swell.centerY = 23
            disc.renderTransform = swell
            func look(hovering: Bool, pressed: Bool) {
                swell.scaleX = hovering ? 1.1 : 0.92
                swell.scaleY = swell.scaleX
                disc.opacity = hovering ? 1 : 0.88
                lift.translateY = hovering ? -3 : 0
                lift.centerX = device.width / 2
                lift.centerY = device.height / 2
                lift.scaleX = pressed ? 0.97 : 1
                lift.scaleY = lift.scaleX
            }
            look(hovering: false, pressed: false)
            top.children.append(disc)
            top.pointerEntered.addHandler { _, _ in look(hovering: true, pressed: false) }
            top.pointerExited.addHandler { _, _ in look(hovering: false, pressed: false) }
            top.pointerPressed.addHandler { _, args in
                args?.handled = true
                look(hovering: true, pressed: true)
            }
            top.pointerReleased.addHandler { [weak self] _, _ in
                look(hovering: true, pressed: false)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.session.play?(nil) } }
            }
            try? ToolTipService.setToolTip(top, Words.t("Play from %@", start.name) + "  Ctrl+Enter")
        } else {
            // No screen yet: a phone's outline, waiting.
            let outline = Rectangle()
            outline.width = 74
            outline.height = 150
            outline.radiusX = 16
            outline.radiusY = 16
            outline.stroke = Theme.ink(4)
            outline.strokeThickness = 1.2
            let dash = DoubleCollection()
            dash.append(4 / 1.2)
            dash.append(3 / 1.2)
            outline.strokeDashArray = dash
            outline.horizontalAlignment = .center
            outline.verticalAlignment = .center
            top.children.append(outline)
        }
        stack.children.append(top)

        let foot = Grid()
        foot.height = 40
        foot.margin = Theme.inset(12, 0, 12, 0)
        let head = StackPanel()
        head.orientation = .horizontal
        head.spacing = 7
        head.verticalAlignment = .center
        head.children.append(Glyphs.view(Glyphs.flag(), size: 14, brush: Theme.brush(Theme.pencil)))
        head.children.append(Theme.text(start?.name ?? "", size: 12.5, weight: 500))
        foot.children.append(head)
        if screens.count > 1, let start {
            let menu = Controls.menuButton(Words.t("Start"), width: 86, menus: menus, menuWidth: 220) { [weak self] in
                screens.map { s in
                    MenuHost.Entry.item(s.name, checked: s.id == start.id) {
                        WindowsCore.setStart(s.id)
                        self?.edited()
                    }
                }
            }
            menu.horizontalAlignment = .right
            menu.verticalAlignment = .center
            try? ToolTipService.setToolTip(menu, Words.t("Where the prototype starts. On the canvas, drag the flag onto another screen."))
            foot.children.append(menu)
        }
        stack.children.append(foot)
        let card = Theme.card(radius: 12)
        card.width = width
        card.child = stack

        let all = StackPanel()
        all.spacing = 10
        all.children.append(card)
        let story = WindowsCore.flowStory()
        if !story.isEmpty {
            let list = StackPanel()
            list.spacing = 3
            for row in story.prefix(12) {
                let line = Theme.text("\(row.from)  →  \(row.to)" + (row.note.map { "  · \($0)" } ?? ""), size: 11.5, ink: 2)
                line.textTrimming = .characterEllipsis
                list.children.append(line)
            }
            let storyCard = Theme.card(radius: 12)
            storyCard.width = width
            storyCard.padding = Theme.inset(12, 10, 12, 10)
            storyCard.child = list
            all.children.append(storyCard)
        }
        all.children.append(Controls.caption("Pull a thread out of a layer onto a screen to link it, or onto the well beside its screen to go back."))
        return all
    }

    /// The screen the prototype starts on, in its device, as tall as 150 and as wide as 210, its
    /// shadow under it.
    private func startDevice(_ board: UUID) -> FrameworkElement? {
        guard let d = WindowsCore.playDevice(for: board) else { return nil }
        let form = Devices.form(group: d.group, name: d.name, width: Double(d.screen.width), height: Double(d.screen.height))
        let raw = Devices.metrics(form, d.screen)
        let k = min(150 / max(Double(raw.size.height), 1), 210 / max(Double(raw.size.width), 1))
        let (figure, m) = Devices.view(form, screen: CGSize(width: Double(d.screen.width) * k, height: Double(d.screen.height) * k))
        let holder = Grid()
        holder.width = Double(m.size.width)
        holder.height = Double(m.size.height)
        holder.isHitTestVisible = false
        // Standing on the small stage, lit from above.
        let scale = 2.0, inset = min(Double(m.size.width), Double(m.size.height)) * 0.1, pad = 26.0
        let shadow = Self.rendered(CGSize(width: Double(m.size.width) - inset * 2 + pad * 2, height: Double(m.size.height) - inset * 2 + pad * 2)) { _, fill in
            WindowsCore.softShadow(width: Int(((Double(m.size.width) - inset * 2) * scale).rounded()), height: Int(((Double(m.size.height) - inset * 2) * scale).rounded()),
                                   pad: Int(pad * scale), blur: 12 * scale, dy: 0, colour: Theme.shadow, alpha: 0.24, into: fill)
        }
        shadow.stretch = .fill
        shadow.horizontalAlignment = .left
        shadow.verticalAlignment = .top
        shadow.margin = Theme.inset(inset - pad, inset - pad + 8, inset - pad, inset - pad - 8)
        holder.children.append(shadow)
        holder.children.append(figure)
        if let picture = screenPicture(board, width: Double(m.screen.width), height: Double(m.screen.height), radius: m.radius) {
            picture.horizontalAlignment = .left
            picture.verticalAlignment = .top
            picture.margin = Theme.inset(Double(m.screen.minX), Double(m.screen.minY), 0, 0)
            holder.children.append(picture)
        }
        if case .phone(true) = form {
            let w = Double(m.screen.width)
            let island = Border()
            island.background = Theme.brush(0x000000)
            island.width = w * 0.3
            island.height = max(1.5, w * 0.085)
            island.cornerRadius = Theme.corners(island.height / 2)
            island.horizontalAlignment = .left
            island.verticalAlignment = .top
            island.margin = Theme.inset(Double(m.screen.midX) - w * 0.15, Double(m.screen.minY) + max(1.2, w * 0.035), 0, 0)
            holder.children.append(island)
        }
        return holder
    }

    /// A screen in small, the top of it as much as a device shows, `width` points wide.
    private func screenPicture(_ board: UUID, width: Double, height: Double? = nil, radius: Double = 5) -> FrameworkElement? {
        guard let index = WindowsCore.boardIndex(of: board), let frame = WindowsCore.boards().first(where: { $0.index == index })?.frame else { return nil }
        let f = (w: Double(frame.width), h: Double(frame.height))
        let h = height ?? min(f.h, f.w * 2.17) / max(f.w, 1) * width
        let image = Self.rendered(CGSize(width: width, height: h)) { scale, fill in
            WindowsCore.render(board: index, scale: scale * width / max(f.w, 1), into: fill)
        }
        image.stretch = .uniformToFill
        image.verticalAlignment = .top
        let holder = Border()
        holder.width = width
        holder.height = h
        holder.cornerRadius = Theme.corners(radius)
        if height == nil {
            holder.borderBrush = Theme.hairline
            holder.borderThickness = Theme.inset(0.5)
        }
        holder.child = image
        return holder
    }

    /// Every screen to go to, as a small picture with its name, three across; and the hook to go back.
    private func screenGrid(_ screens: [(id: UUID, name: String, starts: Bool)], chosen: UUID?, back: Bool, offersBack: Bool,
                            pick: @escaping @MainActor (UUID?, Bool) -> Void) -> FrameworkElement {
        let wrap = StackPanel()
        wrap.spacing = 12
        var row: StackPanel?
        var tiles: [FrameworkElement] = []
        let tileWidth = (Theme.cardWidth - 24 - 20) / 3
        for s in screens {
            let on = chosen == s.id && !back
            let tile = StackPanel()
            tile.spacing = 5
            tile.width = tileWidth
            let frame = Border()
            frame.cornerRadius = Theme.corners(7)
            frame.padding = Theme.inset(3)
            frame.borderBrush = Theme.brush(Theme.pencil)
            frame.borderThickness = Theme.inset(on ? 2 : 0)
            frame.horizontalAlignment = .center
            if let picture = screenPicture(s.id, width: 52) { frame.child = picture }
            tile.children.append(frame)
            let name = Theme.text(s.name, size: 10.5, weight: on ? 600 : 400, ink: on ? 1 : 2)
            if on { name.foreground = Theme.brush(Theme.pencil) }
            name.textTrimming = .characterEllipsis
            name.horizontalAlignment = .center
            tile.children.append(name)
            let press = Pressable(radius: 8) { pick(on ? nil : s.id, false) }
            press.box.child = tile
            press.box.pointerEntered.addHandler { _, _ in if !on { frame.borderThickness = Theme.inset(1) } }
            press.box.pointerExited.addHandler { _, _ in if !on { frame.borderThickness = Theme.inset(0) } }
            tiles.append(press.box)
        }
        if offersBack {
            let tile = StackPanel()
            tile.spacing = 5
            tile.width = tileWidth
            let well = Ellipse()
            well.width = 42
            well.height = 42
            well.stroke = back ? Theme.brush(Theme.pencil) : Theme.ink(4)
            well.strokeThickness = back ? 2 : 1
            if back { well.fill = Theme.brush(Theme.pencil, Theme.pencilWash) } else {
                let d = DoubleCollection()
                d.append(3)
                d.append(2.5)
                well.strokeDashArray = d
            }
            let ring = Grid()
            ring.width = 42
            ring.height = 42
            ring.margin = Theme.inset(0, 12, 0, 12)
            ring.horizontalAlignment = .center
            ring.children.append(well)
            let hook = Glyphs.view(Glyphs.thread(back: true), size: 18, brush: back ? Theme.brush(Theme.pencil) : Theme.ink(2))
            hook.horizontalAlignment = .center
            hook.verticalAlignment = .center
            ring.children.append(hook)
            tile.children.append(ring)
            let name = Theme.text(Words.t("Back"), size: 10.5, weight: back ? 600 : 400, ink: back ? 1 : 2)
            if back { name.foreground = Theme.brush(Theme.pencil) }
            name.horizontalAlignment = .center
            tile.children.append(name)
            let press = Pressable(radius: 8) { pick(nil, !back) }
            press.box.child = tile
            try? ToolTipService.setToolTip(press.box, Words.t("Goes back to the screen it was come to from"))
            tiles.append(press.box)
        }
        for (k, tile) in tiles.enumerated() {
            if k % 3 == 0 {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 10
                wrap.children.append(r)
                row = r
            }
            row?.children.append(tile)
        }
        return wrap
    }

    /// What is said of where it goes, written on its thread: Enter keeps it.
    private func noteField(_ ids: [UUID], note: String) -> FrameworkElement {
        let box = TextBox()
        box.text = note
        box.placeholderText = Words.t("Write a Note")
        box.fontFamily = FontFamily("Segoe Print")
        box.fontSize = 13
        box.width = Theme.cardWidth - 24
        func keep() {
            guard box.text != note else { return }
            WindowsCore.setFlowNote(box.text, for: ids)
            session.edited(board: nil)
        }
        box.keyDown.addHandler { [weak self] _, args in
            guard let args, args.key == .enter else { return }
            args.handled = true
            keep()
            self?.returnFocus?()
        }
        box.lostFocus.addHandler { _, _ in keep() }
        return box
    }
}

extension Glyphs {
    /// A thread with its arrowhead, or curling back, as the Mac's ThreadGlyph.
    static func thread(back: Bool = false, size s: Double = 16) -> [Part] {
        var p = PathData()
        if back {
            p.move(s * 0.85, s * 0.72)
            p.cubic(s * 0.9, s * 0.25, s * 0.45, s * 0.2, s * 0.15, s * 0.38)
            p.move(s * 0.36, s * 0.18); p.line(s * 0.15, s * 0.38); p.line(s * 0.38, s * 0.55)
        } else {
            p.move(s * 0.08, s * 0.7)
            p.cubic(s * 0.4, s * 0.7, s * 0.5, s * 0.3, s * 0.88, s * 0.3)
            p.move(s * 0.68, s * 0.14); p.line(s * 0.88, s * 0.3); p.line(s * 0.68, s * 0.46)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.5)]
    }

    /// The start flag: a ribbon notched at its end, with the triangle of play.
    static func flag(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.05, s * 0.2); p.line(s * 0.95, s * 0.2); p.line(s * 0.95, s * 0.8); p.line(s * 0.05, s * 0.8); p.line(s * 0.25, s * 0.5); p.close()
        return [Part(data: p.d, mode: .fill)]
    }
}
