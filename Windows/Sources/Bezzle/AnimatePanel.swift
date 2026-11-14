import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore
import WinSDK

/// The panel on the right while the design is animated, as the Mac's AnimateInspector. With
/// nothing picked: moves for the whole artboard, and the film itself. With layers picked: moves
/// for them, their pose at the playhead to the number, their shader's inputs, and the camera sent
/// to look at them. With the camera picked: where it looks and how. A bead beside every number is
/// its key at the playhead: filled where there is one.
extension Inspector {
    private var film: WindowsCore.FilmDesk { session.film }

    // What the cards show of the film at a moment (the pose of what is picked, its shader's inputs,
    // the camera, the beads beside them) they show at the panels' moment, `FilmDesk.panelTime`,
    // and each number, bead and summary follows it in place (`Inspector.filmFollowers`): the cards
    // are made once for what is picked, not again at every step of a hand scrubbing through the film.

    func showAnimate() {
        guard film.hasFilm else { return }
        let layers = film.posedLayers
        if film.camera {
            cards.children.append(cameraCard())
        } else {
            cards.children.append(movesCard(layers))
            if !layers.isEmpty {
                cards.children.append(poseCard())
                let inputs = film.posedInputs
                if !inputs.isEmpty { cards.children.append(shaderCard(inputs)) }
                cards.children.append(flyCard())
            }
        }
        cards.children.append(filmCard())
    }

    /// Seconds as they are written here.
    private static func seconds(_ t: Double) -> String { Inspector.number(t, places: 2) + " s" }

    /// A card of this panel: what it is and what it comes to on one line, and its controls under
    /// it. With `follow`, what it comes to is read again as the playhead moves on.
    private func panelCard(_ title: String, _ summary: String, glyph: [Glyphs.Part], rows: [UIElement], follow: (() -> String)? = nil) -> UIElement {
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        let stack = StackPanel()
        let line = Grid()
        line.height = 40
        line.padding = Theme.inset(9, 0, 11, 0)
        let lead = StackPanel()
        lead.orientation = .horizontal
        lead.spacing = 8
        lead.verticalAlignment = .center
        let box = Border()
        box.width = 22
        box.height = 22
        let g = Glyphs.view(glyph, size: 18, brush: Theme.ink(2))
        g.horizontalAlignment = .center
        g.verticalAlignment = .center
        box.child = g
        lead.children.append(box)
        lead.children.append(Theme.text(title, size: 12.5, weight: 600))
        line.children.append(lead)
        let value = Theme.text(summary, size: 12, ink: 2)
        value.horizontalAlignment = .right
        value.maxWidth = 130
        line.children.append(value)
        if let follow {
            var said = summary
            // The view is held for as long as these cards are (`Inspector.filmFollowers`): held
            // weakly, it was let go of at once, still on the screen but no longer reached from here.
            filmFollowers.append {
                let now = follow()
                if now != said {
                    said = now
                    value.text = now
                }
                return true
            }
        }
        stack.children.append(line)
        let content = StackPanel()
        content.spacing = 8
        content.padding = Theme.inset(12, 0, 12, 12)
        for row in rows { content.children.append(row) }
        stack.children.append(content)
        card.child = stack
        return card
    }

    private func hairline() -> UIElement {
        let b = Border()
        b.height = 0.5
        b.background = Theme.hairline
        b.margin = Theme.inset(0, 2, 0, 2)
        return b
    }

    // MARK: A property's key

    /// A property's key at the playhead: a click sets a key here, holding what it is; on a key, it
    /// takes that away.
    private func keyBead(_ state: @escaping () -> WindowsCore.KeyBead, toggle: @escaping @MainActor () -> Void) -> FrameworkElement {
        let press = Pressable(radius: 10, action: toggle)
        press.hoverWash = 0.07
        press.box.width = 20
        press.box.height = 20
        var shown: WindowsCore.KeyBead?
        let box = press.box
        // As the property stands at the panels' moment, and again as the playhead moves on.
        let paint = {
            let now = state()
            guard now != shown else { return }
            shown = now
            box.child = FilmTimelineView.bead(state: now, size: 9)
            try? ToolTipService.setToolTip(box, Words.t(now == .here ? "A key here. Click to take it away." : "Set a key here"))
        }
        paint()
        filmFollowers.append {
            paint()
            return true
        }
        return press.box
    }

    /// One property on a line: its key, its name, and its numbers.
    private func propertyRow(_ title: String, bead: FrameworkElement, fields: [FrameworkElement], mono: Bool = false) -> UIElement {
        let row = Grid()
        row.margin = Theme.inset(-5, 0, 0, 0)
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let c = ColumnDefinition()
            c.width = w
            row.columnDefinitions.append(c)
        }
        row.columnSpacing = 4
        bead.verticalAlignment = .center
        row.children.append(bead)
        let name = Theme.text(title, size: 12, ink: 2)
        if mono { name.fontFamily = FontFamily("Consolas") }
        try? Grid.setColumn(name, 1)
        row.children.append(name)
        let numbers = StackPanel()
        numbers.orientation = .horizontal
        numbers.spacing = 4
        for f in fields { numbers.children.append(f) }
        try? Grid.setColumn(numbers, 2)
        row.children.append(numbers)
        return row
    }

    private func property(_ name: String, _ title: String, fields: [FrameworkElement]) -> UIElement {
        let film = self.film
        return propertyRow(title, bead: keyBead({ film.keyState(name, at: film.panelTime) }) { [weak self] in self?.film.toggleKey(name) }, fields: fields)
    }

    /// One number of the picked layers' pose: what they share, or a dash where they differ.
    private func poseField(_ name: String, _ index: Int, label: String = "", unit: String = "", range: ClosedRange<Double> = -100_000...100_000,
                           times: Double = 1, scrub: Double = 1, decimals: Int = 1, width: Double = 84) -> FrameworkElement {
        let film = self.film
        let value = { film.sharedValue(name, index, at: film.panelTime).map { $0 * times } }
        return field(label, value(), unit: unit, range: range, scrub: scrub, width: width, decimals: decimals, follow: value) { [weak self] shown in
            self?.film.pose(name, number: index, to: shown / times)
        }
    }

    // MARK: Moves

    /// Moves given in one go: each chip plays its move in miniature while pointed at, and a click
    /// gives it to what is picked at the playhead, one layer after another, and shows it.
    private func movesCard(_ layers: [UUID]) -> UIElement {
        let count = film.moveCount
        let summary = layers.isEmpty ? Words.t("Everything") : layers.count == 1 ? film.posedName ?? "" : Words.t("%lld layers", layers.count)
        var rows: [UIElement] = []
        rows.append(Controls.segmented(film.going, [(false, "Comes On"), (true, "Goes")], width: Theme.cardWidth - 24) { [weak self] going in
            self?.film.going = going
            self?.show()
        })
        // Three to a row, so that every move has its company: there are nine.
        let moves = WindowsCore.FilmDesk.moves, across = 3
        let grid = Grid()
        grid.columnSpacing = 6
        grid.rowSpacing = 6
        for _ in 0..<across {
            let c = ColumnDefinition()
            c.width = GridLength(value: 1, gridUnitType: .star)
            grid.columnDefinitions.append(c)
        }
        for _ in 0..<((moves.count + across - 1) / across) { grid.rowDefinitions.append(RowDefinition()) }
        for (k, move) in moves.enumerated() {
            let chip = MoveChip(name: move.name, title: move.title, going: film.going) { [weak self] in self?.film.applyMove(move.name) }
            try? Grid.setColumn(chip.root, Int32(k % across))
            try? Grid.setRow(chip.root, Int32(k / across))
            grid.children.append(chip.root)
        }
        grid.margin = Theme.inset(0, 2, 0, 2)
        rows.append(grid)
        let apart = Grid()
        let words = Theme.text(Words.t("One After Another"), size: 12, ink: 2)
        apart.children.append(words)
        let seconds = field("", film.apart, unit: "s", range: 0...1, scrub: 0.004, width: 84, decimals: 2) { [weak self] v in
            self?.film.apart = v
        }
        seconds.horizontalAlignment = .right
        apart.children.append(seconds)
        apart.opacity = count > 1 ? 1 : 0.35
        apart.isHitTestVisible = count > 1
        rows.append(apart)
        return panelCard(Words.t("Moves"), summary, glyph: Glyphs.cascade(), rows: rows)
    }

    // MARK: A pose

    private func poseCard() -> UIElement {
        var rows: [UIElement] = [
            property("move", WindowsCore.FilmDesk.title("move"), fields: [poseField("move", 0, label: "X", width: 64), poseField("move", 1, label: "Y", width: 64)]),
            property("scale", WindowsCore.FilmDesk.title("scale"), fields: [poseField("scale", 0, unit: "%", range: 0.1...10_000, times: 100, decimals: 0)]),
            property("turn", WindowsCore.FilmDesk.title("turn"), fields: [poseField("turn", 0, unit: "°", range: -3600...3600)]),
            property("fade", WindowsCore.FilmDesk.title("fade"), fields: [poseField("fade", 0, unit: "%", range: 0...100, times: 100, decimals: 0)]),
            property("blur", WindowsCore.FilmDesk.title("blur"), fields: [poseField("blur", 0, range: 0...200, scrub: 0.25)]),
            hairline(),
            property("lift", WindowsCore.FilmDesk.title("lift"), fields: [poseField("lift", 0, range: -4000...4000)]),
            property("tilt", WindowsCore.FilmDesk.title("tilt"), fields: [poseField("tilt", 0, unit: "°", range: -360...360)]),
            property("swing", WindowsCore.FilmDesk.title("swing"), fields: [poseField("swing", 0, unit: "°", range: -360...360)]),
        ]
        // Shapes, whose outline is points: how much of it is drawn, and where its points are.
        if film.posedShapes {
            rows.append(hairline())
            rows.append(property("draw", WindowsCore.FilmDesk.title("draw"), fields: [
                poseField("draw", 0, unit: "%", range: 0...100, times: 100, scrub: 0.5, decimals: 0, width: 70),
                rightArrow(),
                poseField("draw", 1, unit: "%", range: 0...100, times: 100, scrub: 0.5, decimals: 0, width: 70),
            ]))
            rows.append(property("shape", WindowsCore.FilmDesk.title("shape"), fields: [pointsChip()]))
        }
        let film = self.film
        return panelCard(Words.t("Pose"), Inspector.seconds(film.panelTime), glyph: Glyphs.pose(), rows: rows) { Inspector.seconds(film.panelTime) }
    }

    /// The small arrow between where a line's drawing starts and where it ends.
    private func rightArrow() -> FrameworkElement {
        var d = PathData()
        d.move(1, 4.5); d.line(8, 4.5)
        d.move(5, 1.5); d.line(8, 4.5); d.line(5, 7.5)
        let arrow = Glyphs.view([Glyphs.Part(data: d.d, mode: .stroke, width: 1.4)], size: 9, brush: Theme.ink(3))
        arrow.verticalAlignment = .center
        return arrow
    }

    /// Takes the picked shape's points in hand on the canvas, or puts them down, as the Mac's
    /// PointsChip: moved there, they give it another shape at the playhead, a key of its Shape.
    private func pointsChip() -> FrameworkElement {
        let motion = session.motion
        let (done, one) = motion.pointsChip
        let words = Theme.text(Words.t(done ? "Done" : "Edit Points"), size: 11.5, weight: 500)
        let ink: Brush = done ? Theme.brush(Theme.pencil) : Theme.ink(2)
        words.foreground = ink
        words.margin = Theme.inset(10, 0, 10, 0)
        words.verticalAlignment = .center
        let capsule = Border()
        capsule.cornerRadius = Theme.corners(11)
        capsule.background = Theme.brush(Theme.ink, 0.045)
        capsule.child = words
        let press = Pressable(radius: 11) { [weak self] in
            guard let self else { return }
            let motion = self.session.motion
            if motion.pointsChip.done { motion.putPointsDown() } else { motion.takePoints() }
            self.session.changed()
        }
        press.hoverWash = 0.035
        press.box.height = 22
        press.box.child = capsule
        press.box.verticalAlignment = .center
        press.box.opacity = one ? 1 : 0.4
        press.box.isHitTestVisible = one
        if !done {
            press.box.pointerEntered.addHandler { _, _ in words.foreground = Theme.ink(1) }
            press.box.pointerExited.addHandler { _, _ in words.foreground = ink }
        }
        try? ToolTipService.setToolTip(press.box, Words.t("Move its points on the canvas to give it another shape at the playhead"))
        return press.box
    }

    /// The inputs of the picked layers' shader at the playhead, each with its key: a colour, or
    /// its numbers, each a change from what the design sets.
    private func shaderCard(_ inputs: [String]) -> UIElement {
        var rows: [UIElement] = []
        let film = self.film
        for name in inputs {
            let count = film.inputCount(name)
            let bead = keyBead({ film.inputKeyState(name, at: film.panelTime) }) { [weak self] in self?.film.toggleInputKey(name) }
            func number(_ i: Int, _ label: String, _ width: Double) -> FrameworkElement {
                let value = { film.sharedInput(name, i, at: film.panelTime) }
                return field(label, value(), scrub: 0.01, width: width, decimals: 3, follow: value) { [weak self] v in
                    self?.film.poseInput(name, number: i, to: v)
                }
            }
            if film.inputIsColour(name) {
                let colour = film.inputColour(name, at: film.panelTime)
                let well = Colours.field(colour, suggestions: [], open: { [weak self] anchor in
                    self?.openColourPanel(below: anchor, start: colour ?? WindowsCore.Colour(r: 0.5, g: 0.5, b: 0.5, a: 1)) { c in
                        self?.film.poseInput(name, colour: c)
                    }
                }, preview: { _ in }, apply: { [weak self] c in self?.film.poseInput(name, colour: c) })
                well.width = 150
                // A colour's field is made for its colour: once that is another, the cards are made again.
                filmFollowers.append { film.inputColour(name, at: film.panelTime) == colour }
                rows.append(propertyRow(name, bead: bead, fields: [well], mono: true))
            } else if count <= 2 {
                let fields = (0..<count).map { number($0, count == 1 ? "" : ["X", "Y"][$0], count == 1 ? 84 : 64) }
                rows.append(propertyRow(name, bead: bead, fields: fields, mono: true))
            } else {
                rows.append(propertyRow(name, bead: bead, fields: [], mono: true))
                let line = StackPanel()
                line.orientation = .horizontal
                line.spacing = 4
                line.horizontalAlignment = .right
                for i in 0..<min(count, 4) { line.children.append(number(i, ["X", "Y", "Z", "W"][i], 52)) }
                rows.append(line)
            }
        }
        return panelCard(Words.t("Shader"), Inspector.seconds(film.panelTime), glyph: Glyphs.sparkle(), rows: rows) { Inspector.seconds(film.panelTime) }
    }

    /// Sends the camera to the picked layers: a key at the playhead that looks at them.
    private func flyCard() -> UIElement {
        let press = Pressable(radius: 12) { [weak self] in self?.film.flyCamera() }
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.height = 40
        let row = Grid()
        row.padding = Theme.inset(9, 0, 12, 0)
        let lead = StackPanel()
        lead.orientation = .horizontal
        lead.spacing = 8
        lead.verticalAlignment = .center
        let glyph = Glyphs.view(Glyphs.camera(size: 18), size: 18, brush: Theme.ink(2))
        let box = Border()
        box.width = 22
        box.height = 22
        glyph.horizontalAlignment = .center
        glyph.verticalAlignment = .center
        box.child = glyph
        lead.children.append(box)
        lead.children.append(Theme.text(Words.t("Fly the Camera Here"), size: 12.5, weight: 600))
        row.children.append(lead)
        let arrow = Glyphs.view(Glyphs.arrowOut(size: 12), size: 12, brush: Theme.ink(3))
        arrow.horizontalAlignment = .right
        arrow.verticalAlignment = .center
        row.children.append(arrow)
        card.child = row
        press.box.child = card
        press.box.pointerEntered.addHandler { _, _ in
            Glyphs.paint(glyph, Theme.brush(Theme.pencil))
            Glyphs.paint(arrow, Theme.brush(Theme.pencil))
            card.borderBrush = Theme.brush(Theme.shadow, 0.2)
        }
        press.box.pointerExited.addHandler { _, _ in
            Glyphs.paint(glyph, Theme.ink(2))
            Glyphs.paint(arrow, Theme.ink(3))
            card.borderBrush = Theme.hairline
        }
        try? ToolTipService.setToolTip(press.box, Words.t("The camera looks at what is picked from the playhead on, and flies there from where it was before"))
        return press.box
    }

    // MARK: The camera

    private func cameraCard() -> UIElement {
        // What the panels show is at their moment, which a scrub catches up with thirty times a second.
        let film = self.film
        let pose = film.cameraPose(at: film.panelTime)
        func cameraField(_ name: String, _ index: Int, label: String = "", unit: String = "", range: ClosedRange<Double> = -100_000...100_000,
                         scrub: Double = 1, decimals: Int = 1, width: Double = 84) -> FrameworkElement {
            let value: () -> Double? = { film.cameraValue(name, index, at: film.panelTime) }
            return field(label, value(), unit: unit, range: range, scrub: scrub, width: width, decimals: decimals, follow: value) { [weak self] v in
                self?.film.poseCamera(name, number: index, to: v)
            }
        }
        var rows: [UIElement] = [cameraPad()]
        rows.append(property("cameraZoom", WindowsCore.FilmDesk.title("cameraZoom"), fields: [cameraField("cameraZoom", 0, unit: "×", range: 0.1...16, scrub: 0.01, decimals: 2)]))
        rows.append(property("cameraMove", WindowsCore.FilmDesk.title("cameraMove"), fields: [cameraField("cameraMove", 0, label: "X", width: 64), cameraField("cameraMove", 1, label: "Y", width: 64)]))
        rows.append(property("cameraRoll", WindowsCore.FilmDesk.title("cameraRoll"), fields: [cameraField("cameraRoll", 0, unit: "°", range: -3600...3600)]))
        rows.append(property("cameraTilt", WindowsCore.FilmDesk.title("cameraTilt"), fields: [cameraField("cameraTilt", 0, unit: "°", range: -80...80)]))
        rows.append(property("cameraSwing", WindowsCore.FilmDesk.title("cameraSwing"), fields: [cameraField("cameraSwing", 0, unit: "°", range: -80...80)]))
        let whole = Controls.cardButton(Words.t("See the Whole Artboard"), height: 28) { [weak self] in self?.film.restCamera() }
        whole.horizontalAlignment = .right
        whole.margin = Theme.inset(0, 2, 0, 0)
        // Ready only while the camera is somewhere else than at rest.
        var rested: Bool?
        let ready = { (rest: Bool) in
            guard rest != rested else { return }
            rested = rest
            whole.opacity = rest ? 0.4 : 1
            whole.isHitTestVisible = !rest
        }
        ready(pose?.isRest ?? true)
        filmFollowers.append {
            ready(film.cameraPose(at: film.panelTime)?.isRest ?? true)
            return true
        }
        rows.append(whole)
        let zoomed = { "×" + Inspector.number(film.cameraPose(at: film.panelTime)?.zoom ?? 1, places: 2) }
        return panelCard(Words.t("Camera"), zoomed(), glyph: Glyphs.camera(size: 18), rows: rows, follow: zoomed)
    }

    /// The artboard as the camera sees it, small, in the frame the film has: dragged, the scene
    /// tips back and swings round under the camera; a double click looks straight down again.
    private func cameraPad() -> UIElement {
        let well = Theme.well(radius: 9)
        well.height = 118
        well.width = Theme.cardWidth - 24
        let drawing = Canvas()
        drawing.isHitTestVisible = false
        well.child = drawing
        let size = CGSize(width: Theme.cardWidth - 24, height: 118)
        let film = self.film
        // The camera as it was last drawn here: drawn again only once it is another.
        var drawn: WindowsCore.FilmDesk.CameraPose?
        func draw() {
            drawn = film.cameraPose(at: film.panelTime)
            drawing.children.clear()
            guard let pad = film.pad(size: size, at: film.panelTime) else { return }
            if let sheet = pad.sheet {
                var d = PathData()
                d.move(Double(sheet[0].x), Double(sheet[0].y))
                for p in sheet.dropFirst() { d.line(Double(p.x), Double(p.y)) }
                d.close()
                var rules = PathData()
                for (a, b) in pad.rules { rules.move(Double(a.x), Double(a.y)); rules.line(Double(b.x), Double(b.y)) }
                drawing.children.append(Glyphs.view([Glyphs.Part(data: d.d, mode: .fill)], size: 0, brush: Theme.brush(Theme.card)))
                drawing.children.append(Glyphs.view([Glyphs.Part(data: rules.d, mode: .stroke, width: 0.75)], size: 0, brush: Theme.brush(Theme.ink, 0.12)))
                drawing.children.append(Glyphs.view([Glyphs.Part(data: d.d, mode: .stroke, width: 1.2)], size: 0, brush: Theme.brush(Theme.ink, 0.75)))
            }
            var frame = PathData()
            frame.rect(Double(pad.frame.minX), Double(pad.frame.minY), Double(pad.frame.width), Double(pad.frame.height), radius: 2)
            let c = (Double(pad.frame.midX), Double(pad.frame.midY))
            frame.move(c.0 - 3.5, c.1); frame.line(c.0 + 3.5, c.1)
            frame.move(c.0, c.1 - 3.5); frame.line(c.0, c.1 + 3.5)
            drawing.children.append(Glyphs.view([Glyphs.Part(data: frame.d, mode: .stroke, width: 1.25)], size: 0, brush: Theme.brush(Theme.pencil)))
        }
        draw()
        filmFollowers.append {
            if film.cameraPose(at: film.panelTime) != drawn { draw() }
            return true
        }
        well.background = Theme.brush(Theme.well)
        var from: (x: Double, y: Double, pose: WindowsCore.FilmDesk.CameraPose)?
        var turning = false
        well.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let args, let p = try? args.getCurrentPoint(well)?.position, let pose = self.film.cameraPose else { return }
            args.handled = true
            from = (Double(p.x), Double(p.y), pose)
            turning = false
            _ = try? (sender as? UIElement)?.capturePointer(args.pointer)
        }
        well.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let args, let f = from, let p = try? args.getCurrentPoint(well)?.position else { return }
            let dx = Double(p.x) - f.x, dy = Double(p.y) - f.y
            guard turning || hypot(dx, dy) >= 2 else { return }
            if !turning {
                turning = true
                self.dialing = true
                WindowsCore.beginGesture()
            }
            self.film.turnScene(from: f.pose, dx: dx, dy: dy, stepped: GetKeyState(Int32(VK_SHIFT)) < 0)
            draw()
        }
        well.pointerReleased.addHandler { [weak self] sender, args in
            guard let self else { return }
            args?.handled = true
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            from = nil
            if turning {
                turning = false
                WindowsCore.endGesture()
                self.dialing = false
                self.session.edited(board: nil)
            }
        }
        well.doubleTapped.addHandler { [weak self] _, args in
            args?.handled = true
            self?.film.straightenScene()
        }
        try? ToolTipService.setToolTip(well, Words.t("Drag to tip the scene back and swing it round under the camera. Double click to look straight down."))
        return well
    }

    // MARK: The film

    /// How sharp a movie is saved, and how many pictures a second, as the Mac keeps them.
    private var movieScale: Int {
        get { UserDefaults.standard.object(forKey: "film.movie.scale") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "film.movie.scale") }
    }
    private var movieFPS: Int {
        get { UserDefaults.standard.object(forKey: "film.movie.fps") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "film.movie.fps") }
    }

    /// The film itself: how long it runs and whether it goes round, what shows past the
    /// artboard's edges, and the way out, as a movie.
    private func filmCard() -> UIElement {
        let fixed = film.lengthSet
        var rows: [UIElement] = []
        // The words, then, only once the length was set, the way back to as long as the keys, which
        // gives way when the words are long, then the seconds.
        let length = Grid()
        length.columnSpacing = 6
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let c = ColumnDefinition()
            c.width = w
            length.columnDefinitions.append(c)
        }
        length.children.append(Theme.text(Words.t("Length"), size: 12, ink: 2))
        if fixed {
            let follow = Pressable(radius: 6) { [weak self] in self?.film.setLength(nil) }
            let words = Theme.text(Words.t("Follow the Keys"), size: 11.5, weight: 500)
            words.foreground = Theme.brush(Theme.pencil)
            words.margin = Theme.inset(4, 0, 4, 0)
            follow.box.child = words
            follow.box.height = 24
            follow.box.horizontalAlignment = .right
            try? Grid.setColumn(follow.box, 1)
            length.children.append(follow.box)
        }
        let lengthField = field("", film.length, unit: "s", range: 0.25...600, scrub: 0.02, width: 84, decimals: 2) { [weak self] v in
            self?.film.setLength(v)
        }
        try? Grid.setColumn(lengthField, 2)
        length.children.append(lengthField)
        rows.append(length)
        rows.append(Controls.segmented(film.once, [(false, "Round and Round"), (true, "Once")], width: Theme.cardWidth - 24) { [weak self] once in
            self?.film.setOnce(once)
        })
        let backdrop = Grid()
        let words = Theme.text(Words.t("Backdrop"), size: 12, ink: 2)
        try? ToolTipService.setToolTip(words, Words.t("What shows past the artboard's edges when the camera sees them"))
        backdrop.children.append(words)
        let colour = film.backdropColour
        let well = Colours.field(colour, suggestions: [], open: { [weak self] anchor in
            self?.openColourPanel(below: anchor, start: colour ?? WindowsCore.Colour(r: 0.9, g: 0.88, b: 0.85, a: 1)) { c in
                self?.film.setBackdrop(c)
            }
        }, preview: { _ in }, apply: { [weak self] c in self?.film.setBackdrop(c) })
        well.width = 132
        well.horizontalAlignment = .right
        backdrop.children.append(well)
        rows.append(backdrop)
        rows.append(hairline())
        let exporting = film.exporting
        let settings = StackPanel()
        settings.orientation = .horizontal
        settings.spacing = 8
        settings.children.append(Controls.segmented(movieScale, [(1, "1×"), (2, "2×"), (3, "3×")], width: Theme.cardWidth - 24 - 84 - 8) { [weak self] s in
            self?.movieScale = s
            self?.show()
        })
        let fps = Controls.segmented(movieFPS, [(30, "30"), (60, "60")], width: 84) { [weak self] f in
            self?.movieFPS = f
            self?.show()
        }
        try? ToolTipService.setToolTip(fps, Words.t("Pictures a second"))
        settings.children.append(fps)
        settings.opacity = exporting == nil ? 1 : 0.5
        settings.isHitTestVisible = exporting == nil
        rows.append(settings)
        if let size = WindowsCore.FilmMovie.size(of: film, settings: WindowsCore.FilmMovie.Settings(scale: Double(movieScale), fps: movieFPS)) {
            let said = Theme.text(Words.t("%@ × %@ pixels, %lld a second", String(size.width), String(size.height), movieFPS), size: 11, ink: 3)
            said.horizontalAlignment = .center
            rows.append(said)
        }
        rows.append(saveButton(exporting))
        return panelCard(Words.t("Film"), Inspector.seconds(film.length), glyph: Glyphs.reel(), rows: rows)
    }

    /// Save as Movie…, in pencil; while the movie is being saved, Stop Saving, filling with how
    /// far it has come.
    private func saveButton(_ exporting: Double?) -> UIElement {
        let box = Grid()
        box.height = 32
        let back = Border()
        back.cornerRadius = Theme.corners(9)
        back.background = Theme.brush(Theme.pencil, exporting == nil ? 1 : 0.35)
        box.children.append(back)
        let done = Border()
        done.cornerRadius = Theme.corners(9)
        done.background = Theme.brush(Theme.pencil)
        done.horizontalAlignment = .left
        done.width = (Theme.cardWidth - 24) * (exporting ?? 0)
        if exporting != nil { box.children.append(done) }
        let title = Theme.text(Words.t(exporting == nil ? "Save as Movie…" : "Stop Saving"), size: 12.5, weight: 600)
        title.foreground = Theme.brush(Theme.onInk)
        title.horizontalAlignment = .center
        box.children.append(title)
        let press = Pressable(radius: 9) { [weak self] in
            guard let self else { return }
            if self.film.exporting == nil { self.saveMovie() } else { self.film.stopSaving() }
        }
        press.box.child = box
        if exporting != nil {
            // How far it has come, frame by frame, without the panel being made again.
            var ticking: EventCleanup?
            press.box.loaded.addHandler { [weak self] _, _ in
                ticking = CompositionTarget.rendering.addHandler { _, _ in
                    MainActor.assumeIsolated {
                        guard let far = self?.film.exporting else { ticking?.dispose(); ticking = nil; return }
                        done.width = (Theme.cardWidth - 24) * far
                    }
                }
            }
            press.box.unloaded.addHandler { _, _ in ticking?.dispose(); ticking = nil }
        }
        return press.box
    }

    /// Asks where, and saves the film there as a movie; then shows it in Explorer.
    private func saveMovie() {
        if let refused = film.movieRefusal {
            session.tell?(refused.title, refused.detail)
            return
        }
        let name = (film.boardName.isEmpty ? "Film" : film.boardName) + ".mp4"
        let folder = UserDefaults.standard.string(forKey: "film.movie.folder").map { URL(fileURLWithPath: $0) }
        guard let url = FileDialogs.chooseSaveFile(title: Words.t("Save the Film as a Movie"), name: name, filter: ("MPEG-4", "mp4"), startingIn: folder) else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "film.movie.folder")
        let session = session
        film.saveMovie(to: url, scale: Double(movieScale), fps: movieFPS) { error in
            if let error {
                // Stopped by hand, there is nothing to say.
                if !(error is CancellationError) { session.tell?(Words.t("Save the Film as a Movie"), error.localizedDescription) }
            } else {
                Explorer.show(url)
            }
        }
        show()
    }
}

/// A move given in one go, as a chip: a small card making the move over the place it belongs,
/// played over and over while pointed at and part of the way there otherwise.
@MainActor
private final class MoveChip {
    let root = Border()
    private let drawing = Canvas()
    private let name: String
    private let going: Bool
    private var began = 0.0
    private var ticking: EventCleanup?

    init(name: String, title: String, going: Bool, action: @escaping @MainActor () -> Void) {
        self.name = name
        self.going = going
        root.height = 52
        root.cornerRadius = Theme.corners(9)
        root.background = Theme.brush(Theme.ink, 0.035)
        let stack = StackPanel()
        stack.spacing = 3
        stack.verticalAlignment = .center
        drawing.width = 36
        drawing.height = 24
        drawing.horizontalAlignment = .center
        drawing.isHitTestVisible = false
        stack.children.append(drawing)
        // Made a little smaller where the word is long, as the Mac lets it shrink to fit; three to
        // a row, every move's name in every language fits whole.
        let words = Theme.text(title, size: title.count > 11 ? 9.5 : 10.5, ink: 2)
        words.horizontalAlignment = .center
        stack.children.append(words)
        root.child = stack
        draw(away: 0.46)
        root.pointerEntered.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.root.background = Theme.brush(Theme.ink, 0.07)
            words.foreground = Theme.ink(1)
            self.began = WindowsCore.now
            self.ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.tick() } }
        }
        root.pointerExited.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.root.background = Theme.brush(Theme.ink, 0.035)
            words.foreground = Theme.ink(2)
            self.ticking?.dispose()
            self.ticking = nil
            self.draw(away: 0.46)
        }
        root.unloaded.addHandler { [weak self] _, _ in
            self?.ticking?.dispose()
            self?.ticking = nil
        }
        root.pointerPressed.addHandler { _, args in args?.handled = true }
        root.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
    }

    private func tick() {
        let time = WindowsCore.FilmDesk.moveTime(name)
        let u = min(max((WindowsCore.now - began).truncatingRemainder(dividingBy: 1.5) / time / 1.5, 0), 1)
        draw(away: WindowsCore.FilmDesk.moveAway(name, going: going, at: u))
    }

    /// The card `away` from home: 1 away, 0 home; a spring goes a little past.
    private func draw(away: Double) {
        drawing.children.clear()
        let home = (x: 36.0 / 2 - 9, y: 24.0 / 2 - 6.5, w: 18.0, h: 13.0)
        var place = PathData()
        place.rect(home.x + 0.5, home.y + 0.5, home.w - 1, home.h - 1, radius: 2.5)
        drawing.children.append(Glyphs.view([Glyphs.Part(data: place.d, mode: .stroke, width: 1, round: false)], size: 0, brush: Theme.brush(Theme.ink, 0.2)))
        var r = home
        var opacity = 1.0
        let a = away, faded = 1 - min(max(away, 0), 1)
        switch name {
        case "fade": opacity = faded
        case "rise": r.y += 8 * a; opacity = faded
        case "drop": r.y -= 9 * a; opacity = faded
        case "slide": r.x -= 26 * a
        case "pop": r = (r.x + r.w * 0.2 * a, r.y + r.h * 0.2 * a, r.w * (1 - 0.4 * a), r.h * (1 - 0.4 * a)); opacity = faded
        case "zoom": r = (r.x - r.w * 0.2 * a, r.y - r.h * 0.2 * a, r.w * (1 + 0.4 * a), r.h * (1 + 0.4 * a)); opacity = faded
        case "flip":
            let seen = max(cos(80 * .pi / 180 * min(abs(a), 1)), 0.08)
            r = (r.x + r.w * 0.06 * a, r.y + r.h * (1 - seen) / 2, r.w * (1 - 0.12 * a), r.h * seen)
            opacity = faded
        case "focus": opacity = 1 - 0.75 * (1 - faded)
        case "draw":
            // A line drawn on as a pen draws it, over where it belongs.
            let drawn = min(max(1 - away, 0), 1)
            let line = DrawnLine.trimmed(DrawnLine.moveLine(x: home.x, y: home.y, w: home.w, h: home.h), to: drawn)
            if let first = line.first, line.count >= 2 {
                var d = PathData()
                d.move(Double(first.x), Double(first.y))
                for p in line.dropFirst() { d.line(Double(p.x), Double(p.y)) }
                drawing.children.append(Glyphs.view([Glyphs.Part(data: d.d, mode: .stroke, width: 2.2)], size: 0, brush: Theme.brush(Theme.ink, 0.82)))
            }
            clipDrawing()
            return
        default: break
        }
        var card = PathData()
        card.rect(r.x, r.y, max(r.w, 0.5), max(r.h, 0.5), radius: 2.5)
        let shape = Glyphs.view([Glyphs.Part(data: card.d, mode: .fill)], size: 0, brush: Theme.brush(Theme.ink, 0.82 * max(min(opacity, 1), 0)))
        drawing.children.append(shape)
        clipDrawing()
    }

    private func clipDrawing() {
        drawing.clip = {
            let g = RectangleGeometry()
            g.rect = Rect(x: 0, y: 0, width: 36, height: 24)
            return g
        }()
    }
}
