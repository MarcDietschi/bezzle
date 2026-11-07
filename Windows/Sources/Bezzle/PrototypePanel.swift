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
        // The cards are made again: no tile is pointed at now.
        session.flow.preview = nil
        let ids = session.selection
        let screens = WindowsCore.prototypeScreens()
        if ids.isEmpty {
            cards.children.append(startCard(screens))
            cards.children.append(storyCard())
            cards.children.append(handOffCard())
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
            let states = WindowsCore.copyStates(ids)
            if let states { cards.children.append(statesCard(states)) }
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
                rows.append(motionRow(ids, chosen: look.motion))
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

        return card
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

    /// The ways through the prototype, as a story: from which layer of which screen to where, and
    /// why, in the designer's words. A row picks that layer on the canvas. With none yet, a small
    /// drawing shows how one is made.
    private func storyCard() -> UIElement {
        let lines = WindowsCore.flowStory()
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        let stack = StackPanel()
        card.child = stack
        guard !lines.isEmpty else {
            let demo = PullDemo()
            pullDemo = demo
            stack.children.append(demo.view)
            let words = Theme.text(Words.t("Pull a thread from a button onto a screen"), size: 15)
            words.fontFamily = FontFamily("Segoe Print")
            words.foreground = Theme.brush(Theme.pencil)
            words.textWrapping = .wrap
            words.textAlignment = .center
            words.horizontalAlignment = .center
            words.margin = Theme.inset(12, 0, 12, 14)
            stack.children.append(words)
            return card
        }
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let rule = Border()
                rule.height = 0.5
                rule.background = Theme.hairline
                rule.margin = Theme.inset(12, 0, 0, 0)
                stack.children.append(rule)
            }
            let picked = session.selection.contains(line.source)
            let row = StackPanel()
            row.spacing = 2
            row.padding = Theme.inset(12, 8, 12, 8)
            row.background = picked ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.clear
            let head = Grid()
            for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
                let c = ColumnDefinition()
                c.width = w
                head.columnDefinitions.append(c)
            }
            let names = StackPanel()
            names.orientation = .horizontal
            names.spacing = 5
            names.children.append(Theme.text(line.title, size: 12, weight: 500))
            let thread = Glyphs.view(Glyphs.thread(back: line.back, size: 16), size: 16, brush: picked ? Theme.brush(Theme.pencil) : Theme.ink(3))
            names.children.append(thread)
            names.children.append(Theme.text(line.to, size: 12, weight: 500))
            head.children.append(names)
            if let after = line.after {
                let time = Theme.text(String(format: "%.1f s", after), size: 11, ink: 3)
                try? Grid.setColumn(time, 1)
                head.children.append(time)
            }
            row.children.append(head)
            if let from = line.from { row.children.append(Theme.text(from, size: 11, ink: 3)) }
            if let note = line.note, !note.isEmpty {
                let written = Theme.text(note, size: 13)
                written.fontFamily = FontFamily("Segoe Print")
                written.foreground = Theme.brush(Theme.pencil)
                written.textWrapping = .wrap
                written.maxLines = 2
                written.margin = Theme.inset(0, 1, 0, 0)
                row.children.append(written)
            }
            row.pointerEntered.addHandler { _, _ in if !picked { row.background = Theme.brush(Theme.ink, 0.035) } }
            row.pointerExited.addHandler { _, _ in if !picked { row.background = Theme.clear } }
            let source = line.source
            row.tapped.addHandler { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.session.select([source], on: WindowsCore.board(of: source) ?? WindowsCore.boardIndex(of: source))
                        self.session.reveal?(source)
                    }
                }
            }
            stack.children.append(row)
        }
        return card
    }

    /// The design as code: its named looks as tokens, copied in a click; and Inspect, to build it
    /// by hand, a layer at a time (not while it is inspected).
    func handOffCard(showsInspect: Bool = true) -> UIElement {
        let count = WindowsCore.tokenCount
        let stack = StackPanel()
        stack.spacing = 10
        let head = Grid()
        head.height = 22
        let title = StackPanel()
        title.orientation = .horizontal
        title.spacing = 8
        title.children.append(Glyphs.view(Glyphs.code(size: 22), size: 22, brush: Theme.ink(2)))
        title.children.append(Theme.text(Words.t("Code"), size: 12.5, weight: 600))
        head.children.append(title)
        let tokens = Theme.text(count == 1 ? Words.t("1 token") : Words.t("%lld tokens", count), size: 12, ink: 2)
        tokens.horizontalAlignment = .right
        head.children.append(tokens)
        stack.children.append(head)
        let chips = Grid()
        chips.columnSpacing = 6
        let name = session.name
        for (k, format) in [("css", "CSS"), ("swiftui", "SwiftUI"), ("json", "JSON")].enumerated() {
            let c = ColumnDefinition()
            c.width = GridLength(value: 1, gridUnitType: .star)
            chips.columnDefinitions.append(c)
            let chip = Border()
            chip.height = 26
            chip.cornerRadius = Theme.corners(7)
            chip.background = Theme.brush(Theme.ink, 0.04)
            chip.borderBrush = Theme.hairline
            chip.borderThickness = Theme.inset(1)
            let label = Theme.text(format.1, size: 12, weight: 500)
            label.horizontalAlignment = .center
            chip.child = label
            if count > 0 {
                chip.pointerEntered.addHandler { _, _ in chip.background = Theme.brush(Theme.ink, 0.07) }
                chip.pointerExited.addHandler { _, _ in chip.background = Theme.brush(Theme.ink, 0.04) }
                chip.pointerPressed.addHandler { _, args in args?.handled = true }
                chip.tapped.addHandler { _, _ in
                    guard let text = WindowsCore.tokens(format.0, named: name) else { return }
                    Clipboard.copyText(text)
                    // Copied: a tick, for a moment.
                    label.text = "✓ " + format.1
                    label.foreground = Theme.brush(Theme.pencil)
                    chip.borderBrush = Theme.brush(Theme.pencil, 0.6)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        MainActor.assumeIsolated {
                            label.text = format.1
                            label.foreground = Theme.ink(1)
                            chip.borderBrush = Theme.hairline
                        }
                    }
                }
            }
            try? Grid.setColumn(chip, Int32(k))
            chips.children.append(chip)
        }
        chips.opacity = count == 0 ? 0.45 : 1
        try? ToolTipService.setToolTip(chips, Words.t(count == 0 ? "Give colours, type, shadows or corners a name in the design, and they come out here as tokens." : "Copy the design's named looks as tokens"))
        stack.children.append(chips)
        if showsInspect {
            let inspect = Controls.cardButton(Words.t("Inspect"), height: 30) { [weak self] in self?.session.mode = 2 }
            inspect.horizontalAlignment = .stretch
            if let label = (inspect as? Border)?.child as? TextBlock { label.horizontalAlignment = .center }
            stack.children.append(inspect)
        }
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.padding = Theme.inset(12)
        card.child = stack
        return card
    }

    /// What a copy of a component shows as it is used: each variant whose name says a state plays
    /// it in the prototype (Hover while pointed at, Pressed while pressed, Selected turned on by a
    /// tap); another can be made a state by its name, and a missing state added as a new variant.
    private func statesCard(_ states: WindowsCore.CopyStates) -> UIElement {
        card("States", states.summary, glyph: Glyphs.states(), body: { [self] in
            var rows: [UIElement] = []
            let list = StackPanel()
            list.spacing = 2
            for r in states.rows {
                let row = Grid()
                row.minHeight = 34
                for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
                    let c = ColumnDefinition()
                    c.width = w
                    row.columnDefinitions.append(c)
                }
                let dot = Ellipse()
                dot.width = 6
                dot.height = 6
                dot.fill = r.state != nil ? Theme.brush(Theme.pencil) : Theme.ink(4)
                dot.margin = Theme.inset(0, 0, 8, 0)
                dot.verticalAlignment = .center
                row.children.append(dot)
                let words = StackPanel()
                words.spacing = 1
                words.verticalAlignment = .center
                words.children.append(Theme.text(r.name, size: 12, weight: r.state != nil ? 500 : 400))
                if let does = r.does { words.children.append(Theme.text(does, size: 10.5, ink: 3)) }
                else if r.variant == nil { words.children.append(Theme.text(Words.t("As it rests"), size: 10.5, ink: 3)) }
                try? Grid.setColumn(words, 1)
                row.children.append(words)
                if r.variant != nil, r.state == nil, !states.locked {
                    let copy = states.copy, variant = r.variant
                    let menu = Controls.menuButton(Words.t("Use As"), width: 92, menus: menus, menuWidth: 200) { [weak self] in
                        WindowsCore.variantStates.map { s in
                            MenuHost.Entry.item(s.title) {
                                WindowsCore.useAs(s.key, variant: variant, of: copy)
                                self?.edited()
                            }
                        }
                    }
                    menu.verticalAlignment = .center
                    try? Grid.setColumn(menu, 2)
                    row.children.append(menu)
                }
                list.children.append(row)
            }
            rows.append(list)
            if !states.missing.isEmpty, !states.locked {
                let wrap = StackPanel()
                wrap.spacing = 8
                var line: Grid?
                for (k, m) in states.missing.enumerated() {
                    if k % 3 == 0 {
                        let g = Grid()
                        g.columnSpacing = 8
                        for _ in 0..<3 {
                            let c = ColumnDefinition()
                            c.width = GridLength(value: 1, gridUnitType: .star)
                            g.columnDefinitions.append(c)
                        }
                        wrap.children.append(g)
                        line = g
                    }
                    let chip = addStateChip(m.title, does: m.does) { [weak self] in
                        guard let self else { return }
                        let now = WindowsCore.addState(m.key, self.session.selection)
                        self.session.select(now, on: now.first.flatMap(WindowsCore.board(of:)))
                        self.edited()
                    }
                    try? Grid.setColumn(chip, Int32(k % 3))
                    line?.children.append(chip)
                }
                rows.append(wrap)
            }
            return rows
        })
    }

    /// A dashed chip for a state the component has no variant for, adding one.
    private func addStateChip(_ title: String, does: String, _ add: @escaping @MainActor () -> Void) -> FrameworkElement {
        let holder = Grid()
        holder.height = 24
        let edge = Rectangle()
        edge.radiusX = 7
        edge.radiusY = 7
        edge.stroke = Theme.ink(4)
        edge.strokeThickness = 1
        let dash = DoubleCollection()
        dash.append(3)
        dash.append(2.5)
        edge.strokeDashArray = dash
        edge.fill = Theme.clear
        holder.children.append(edge)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 3
        row.horizontalAlignment = .center
        row.verticalAlignment = .center
        let plus = Glyphs.view(Glyphs.plus(size: 14), size: 14, brush: Theme.ink(2))
        row.children.append(plus)
        let label = Theme.text(title, size: 11.5, weight: 500, ink: 2)
        row.children.append(label)
        holder.children.append(row)
        holder.background = Theme.clear
        holder.pointerEntered.addHandler { _, _ in
            edge.stroke = Theme.brush(Theme.pencil)
            edge.fill = Theme.brush(Theme.pencil, Theme.pencilWash)
            label.foreground = Theme.brush(Theme.pencil)
        }
        holder.pointerExited.addHandler { _, _ in
            edge.stroke = Theme.ink(4)
            edge.fill = Theme.clear
            label.foreground = Theme.ink(2)
        }
        holder.pointerPressed.addHandler { _, args in args?.handled = true }
        holder.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { add() } } }
        try? ToolTipService.setToolTip(holder, does)
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
    private func screenGrid(_ screens: [(id: UUID, name: String, starts: Bool)], chosen: UUID?, back: Bool, offersBack: Bool, previews: Bool = true,
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
            let flow = session.flow, id = s.id
            press.box.pointerEntered.addHandler { _, _ in
                if !on { frame.borderThickness = Theme.inset(1) }
                if previews { flow.preview = id }
            }
            press.box.pointerExited.addHandler { _, _ in
                if !on { frame.borderThickness = Theme.inset(0) }
                if flow.preview == id { flow.preview = nil }
            }
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

    /// How the next screen comes on: read from the canvas, or one of three plain ways, as the
    /// Mac's MotionRow. Each choice is its motion in small, played while it is pointed at, its
    /// name in the tip; under them, what the canvas says when it is read from there.
    private func motionRow(_ ids: [UUID], chosen: String) -> FrameworkElement {
        let way = WindowsCore.flowWay(ids)
        let stack = StackPanel()
        stack.spacing = 10
        let row = Grid()
        row.columnSpacing = 10
        for (k, m) in WindowsCore.flowMotions.enumerated() {
            let c = ColumnDefinition()
            c.width = GridLength(value: 1, gridUnitType: .star)
            row.columnDefinitions.append(c)
            let chip = motionChip(m.name, title: m.title, way: m.name == "auto" ? way : nil, chosen: chosen == m.name) { [weak self] in
                WindowsCore.setFlowMotion(m.name, for: ids)
                self?.edited()
            }
            try? Grid.setColumn(chip, Int32(k))
            row.children.append(chip)
        }
        stack.children.append(row)
        if chosen == "auto", let way {
            let words = Theme.text(way.reading, size: 11, ink: 3)
            words.textWrapping = .wrap
            stack.children.append(words)
        }
        return stack
    }

    private func motionChip(_ motion: String, title: String, way: (kind: String, dx: Double, dy: Double, reading: String)?, chosen: Bool,
                            _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let chip = Border()
        chip.height = 40
        chip.cornerRadius = Theme.corners(9)
        chip.background = chosen ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.clear
        chip.borderBrush = chosen ? Theme.brush(Theme.pencil, 0.7) : Theme.hairline
        chip.borderThickness = Theme.inset(chosen ? 1.5 : 1)
        // Two screens in small, the second coming on the way the motion brings it.
        let w = 30.0, h = 24.0
        let frame = (x: w * 0.18, y: 1.0, w: w * 0.64, h: h - 2)
        let window = Border()
        window.width = frame.w
        window.height = frame.h
        window.cornerRadius = Theme.corners(3)
        window.background = Theme.ink(4)
        window.horizontalAlignment = .center
        window.verticalAlignment = .center
        let inside = Canvas()
        inside.width = frame.w
        inside.height = frame.h
        let clip = RectangleGeometry()
        clip.rect = Rect(x: 0, y: 0, width: Float(frame.w), height: Float(frame.h))
        inside.clip = clip
        window.child = inside
        let old = Rectangle(), next = Rectangle()
        old.fill = Theme.brush(Theme.ink, 0.44 * 0.6)
        next.fill = Theme.brush(Theme.pencil)
        inside.children.append(old)
        inside.children.append(next)
        func put(_ r: Rectangle, _ x: Double, _ y: Double, _ rw: Double, _ rh: Double, radius: Double = 0) {
            try? Canvas.setLeft(r, x)
            try? Canvas.setTop(r, y)
            r.width = max(0, rw)
            r.height = max(0, rh)
            r.radiusX = radius
            r.radiusY = radius
        }
        func show(_ t: Double) {
            let u = min(max(t, 0), 1), e = 1 - pow(1 - u, 3)
            old.visibility = .collapsed
            next.opacity = 1
            switch motion {
            case "instant":
                put(next, 0, 0, frame.w, frame.h)
                next.opacity = u > 0.5 ? 1 : 0
            case "dissolve":
                put(next, 0, 0, frame.w, frame.h)
                next.opacity = e
            case "slide":
                put(next, frame.w * (1 - e), 0, frame.w, frame.h)
            default:
                if way?.kind == "sheet" {
                    put(next, 0, frame.h * 0.35 + frame.h * 0.65 * (1 - e), frame.w, frame.h, radius: 2.5)
                } else if way?.kind == "morph" {
                    put(next, 3 + 6 * e, 3 + 4 * e, frame.w * (0.4 + 0.3 * e), frame.h * (0.3 + 0.25 * e), radius: 2)
                } else {
                    let dx = way?.kind == "push" ? way!.dx : 1, dy = way?.kind == "push" ? way!.dy : 0
                    old.visibility = .visible
                    put(old, -frame.w * 0.28 * e * dx, -frame.h * 0.28 * e * dy, frame.w, frame.h)
                    put(next, frame.w * (1 - e) * dx, frame.h * (1 - e) * dy, frame.w, frame.h)
                }
            }
        }
        // At rest, each a moment of its own motion, so the four read apart.
        let rest = motion == "slide" ? 0.32 : motion == "dissolve" ? 0.3 : motion == "instant" ? 0 : 0.4
        show(rest)
        chip.child = window
        final class Playing { var cleanup: EventCleanup?; var began = Date() }
        let playing = Playing()
        chip.pointerEntered.addHandler { _, _ in
            if !chosen { chip.background = Theme.brush(Theme.ink, 0.05) }
            guard playing.cleanup == nil else { return }
            playing.began = Date()
            playing.cleanup = CompositionTarget.rendering.addHandler { _, _ in
                MainActor.assumeIsolated { show(Date().timeIntervalSince(playing.began).truncatingRemainder(dividingBy: 1.6) / 1.2) }
            }
        }
        let stop = { @MainActor in
            if !chosen { chip.background = Theme.clear }
            playing.cleanup?.dispose()
            playing.cleanup = nil
            show(rest)
        }
        chip.pointerExited.addHandler { _, _ in stop() }
        chip.unloaded.addHandler { _, _ in stop() }
        chip.pointerPressed.addHandler { _, args in args?.handled = true }
        chip.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
        try? ToolTipService.setToolTip(chip, title)
        return chip
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

    /// Code: angle brackets round a slash, as the Mac's CodeGlyph.
    static func code(size s: Double = 22) -> [Part] {
        var p = PathData()
        p.move(s * 0.36, s * 0.3); p.line(s * 0.16, s * 0.5); p.line(s * 0.36, s * 0.7)
        p.move(s * 0.64, s * 0.3); p.line(s * 0.84, s * 0.5); p.line(s * 0.64, s * 0.7)
        p.move(s * 0.55, s * 0.24); p.line(s * 0.45, s * 0.76)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }

    /// Two states of a button, one over the other, as the Mac's StatesGlyph (18 by 14, centred).
    static func states(size s: Double = 16) -> [Part] {
        let w = s * 18 / 18, h = s * 14 / 18, top = (s - h) / 2
        var back = PathData(), front = PathData()
        back.rect(w * 0.3, top + 0.5, w * 0.66, h * 0.55, radius: h * 0.27)
        front.rect(w * 0.04, top + h * 0.4, w * 0.66, h * 0.55, radius: h * 0.27)
        return [Part(data: back.d, mode: .stroke, width: 1.3), Part(data: front.d, mode: .cover, width: 1.3)]
    }

    /// The start flag: a ribbon notched at its end, with the triangle of play.
    static func flag(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.05, s * 0.2); p.line(s * 0.95, s * 0.2); p.line(s * 0.95, s * 0.8); p.line(s * 0.05, s * 0.8); p.line(s * 0.25, s * 0.5); p.close()
        return [Part(data: p.d, mode: .fill)]
    }
}

/// How a flow is made, shown by doing it, as the Mac's PullDemo: a thread is pulled out of a
/// button on one screen and tied to the next, which answers; then it starts over. It moves only
/// while it is on screen.
@MainActor
final class PullDemo {
    let view = Canvas()
    private let button = Rectangle()
    private let thread = WinUI.Path()
    private let end = Ellipse()
    private let ring = Rectangle()
    private let tied = Rectangle()
    private let arrow = WinUI.Path()
    private var ticking: EventCleanup?
    private let started = Date()

    private let w = 46.0, h = 84.0
    private var a = CGRect.zero, b = CGRect.zero

    init() {
        let width = Theme.cardWidth, height = 112.0
        view.width = width
        view.height = height
        view.margin = Theme.inset(0, 10, 0, 0)
        view.isHitTestVisible = false
        a = CGRect(x: width / 2 - 92, y: (height - h) / 2, width: w, height: h)
        b = CGRect(x: width / 2 + 46, y: (height - h) / 2, width: w, height: h)
        for r in [a, b] { add(rounded(r, 7, fill: Theme.brush(Theme.card), stroke: Theme.ink(4), width: 1)) }
        // A few lines of a screen, and the button.
        for i in 0..<3 {
            let d = Double(i)
            add(rounded(CGRect(x: Double(a.minX) + 7, y: Double(a.minY) + 12 + d * 8, width: w - 14 - d * 6, height: 3), 1.5, fill: Theme.ink(4)))
            add(rounded(CGRect(x: Double(b.minX) + 7, y: Double(b.minY) + 12 + d * 8, width: w - 18 + d * 3, height: 3), 1.5, fill: Theme.ink(4)))
        }
        place(button, CGRect(x: Double(a.minX) + 7, y: Double(a.maxY) - 22, width: w - 14, height: 11))
        button.radiusX = 5.5
        button.radiusY = 5.5
        add(button)
        thread.stroke = Theme.brush(Theme.pencil)
        thread.strokeThickness = 1.8
        thread.strokeStartLineCap = .round
        thread.strokeEndLineCap = .round
        add(thread)
        end.width = 7
        end.height = 7
        end.fill = Theme.brush(Theme.pencil)
        add(end)
        for r in [ring, tied] {
            r.stroke = Theme.brush(Theme.pencil)
            r.strokeThickness = 1.5
            add(r)
        }
        arrow.fill = Theme.ink(1)
        arrow.stroke = Theme.brush(Theme.card)
        arrow.strokeThickness = 0.8
        add(arrow)
        step()
        view.loaded.addHandler { [weak self] _, _ in self?.start() }
        view.unloaded.addHandler { [weak self] _, _ in
            self?.ticking?.dispose()
            self?.ticking = nil
        }
    }

    private func start() {
        guard ticking == nil else { return }
        // The demo holds itself while it moves; letting go of the view lets go of it.
        ticking = CompositionTarget.rendering.addHandler { _, _ in MainActor.assumeIsolated { self.step() } }
    }

    private func add(_ e: UIElement) { view.children.append(e) }

    private func place(_ e: FrameworkElement, _ r: CGRect) {
        try? Canvas.setLeft(e, Double(r.minX))
        try? Canvas.setTop(e, Double(r.minY))
        e.width = max(0, Double(r.width))
        e.height = max(0, Double(r.height))
    }

    private func rounded(_ r: CGRect, _ radius: Double, fill: Brush, stroke: Brush? = nil, width: Double = 0) -> Rectangle {
        let shape = Rectangle()
        shape.radiusX = radius
        shape.radiusY = radius
        shape.fill = fill
        if let stroke {
            shape.stroke = stroke
            shape.strokeThickness = width
        }
        place(shape, r)
        return shape
    }

    private func step() {
        let t = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: 3.4)
        let knob = CGRect(x: Double(a.minX) + 7, y: Double(a.maxY) - 22, width: w - 14, height: 11)
        let pull = min(max((t - 0.5) / 1.1, 0), 1)
        let held = t > 0.25 && t < 2.9
        button.fill = held ? Theme.brush(Theme.pencil) : Theme.ink(3)
        let p0 = (x: Double(knob.maxX), y: Double(knob.midY))
        let p3 = (x: Double(b.minX), y: Double(b.midY) + 10)
        let e = 1 - pow(1 - pull, 3)
        let tip = (x: p0.x + (p3.x - p0.x) * e, y: p0.y + (p3.y - p0.y) * e - sin(e * .pi) * 10)
        let pulling = held && pull > 0
        thread.visibility = pulling ? .visible : .collapsed
        end.visibility = pulling ? .visible : .collapsed
        if pulling {
            let sag = (1 - e) * 16
            let figure = PathFigure()
            figure.startPoint = Point(x: Float(p0.x), y: Float(p0.y))
            // The curve as short straight steps: the bindings have no Bézier segment.
            let c1 = (x: p0.x + 30, y: p0.y + sag), c2 = (x: tip.x - 30, y: tip.y + sag)
            for k in 1...20 {
                let u = Double(k) / 20, v = 1 - u
                let x = v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * tip.x
                let y = v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * tip.y
                let line = LineSegment()
                line.point = Point(x: Float(x), y: Float(y))
                figure.segments.append(line)
            }
            let g = PathGeometry()
            g.figures.append(figure)
            thread.data = g
            try? Canvas.setLeft(end, tip.x - 3.5)
            try? Canvas.setTop(end, tip.y - 3.5)
        }
        // The screen answers once it is tied.
        let answering = t > 1.6 && t < 2.9
        ring.visibility = answering ? .visible : .collapsed
        tied.visibility = answering ? .visible : .collapsed
        if answering {
            let u = min((t - 1.6) / 0.7, 1)
            let grow = 2 + 10 * u
            place(ring, b.insetBy(dx: -grow, dy: -grow))
            ring.radiusX = 9 + 5 * u
            ring.radiusY = ring.radiusX
            ring.opacity = 1 - u
            place(tied, b.insetBy(dx: -2, dy: -2))
            tied.radiusX = 8
            tied.radiusY = 8
        }
        // The pointer that pulls it.
        arrow.visibility = held ? .visible : .collapsed
        if held {
            let at = pull > 0 ? tip : (x: Double(knob.midX), y: Double(knob.midY))
            let figure = PathFigure()
            figure.startPoint = Point(x: Float(at.x + 2), y: Float(at.y + 2))
            figure.isClosed = true
            for (dx, dy) in [(2.0, 14.0), (5.5, 10.5), (10.5, 10.0)] {
                let line = LineSegment()
                line.point = Point(x: Float(at.x + dx), y: Float(at.y + dy))
                figure.segments.append(line)
            }
            let g = PathGeometry()
            g.figures.append(figure)
            arrow.data = g
        }
    }
}
