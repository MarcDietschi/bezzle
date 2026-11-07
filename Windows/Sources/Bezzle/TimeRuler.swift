import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The ruler of time, as the Mac's Views/TimeRuler.swift: a card floating at the foot of the
/// canvas, with a comb of fine strokes, one for each version, each in the colour of the sky when
/// it was made, the named ones with a bead on top. Under the pointer the strokes swell, as the
/// Dock does, and a label glides along, catching on the version nearest. The pencil line where
/// the design is seen from flies from stroke to stroke when one is clicked, plucking each it
/// passes like a string; dragged, it lifts and follows; let go, it settles on the one under it.
/// The wheel over the card leafs through time.
@MainActor
final class TimeRulerView {
    let root = Grid()
    private let session: DesignSession
    private var versions: WindowsCore.Versions { WindowsCore.versions }
    private let card = Theme.card(radius: 18)
    private let shadow = Image()
    private let comb = WindowsCore.Comb()

    private let title = Theme.text("", size: 15, weight: 500, serif: true)
    private let nameSlot = Grid()
    private let actions = StackPanel()
    private let playHolder = Grid()
    private let combArea = Canvas()
    private var naming = false

    // The comb's parts, made once and moved each frame.
    private let fine = WinUI.Path()
    private let lit = WinUI.Path()
    // Drawn in this order, from the days under the comb to the label over it.
    private let dayLayer = Canvas(), hairLayer = Canvas(), strokeLayer = Canvas(), markLayer = Canvas(), headLayer = Canvas(), lensLayer = Canvas()
    private var strokes: [Rectangle] = []
    private var beads: [Ellipse] = []
    private var days: [TextBlock] = []
    private let nowRing = Ellipse()
    private let headGlow = Rectangle()
    private let headLine = Rectangle()
    private let headDot = Ellipse()
    private let lensBox = Border()
    private let lensText = TextBlock()

    private var hoverX: Double?
    private var dragX: Double?
    private var pressX: Double?
    private var overCard = false
    private var scrolled = 0.0
    private var ticking: EventCleanup?
    /// Awake at least until then, as the Mac checks every half second whether all has settled.
    private var awakeUntil = Date.distantPast
    private var combWidth = 0.0

    static let width = 600.0
    private static let combHeight = 40.0
    private static let baseline = 25.0

    init(session: DesignSession) {
        self.session = session
        // As wide as there is room for, up to 600: stretched with a most width, WinUI centres it.
        root.horizontalAlignment = .stretch
        root.verticalAlignment = .bottom
        root.maxWidth = Self.width
        root.margin = Theme.inset(28, 0, 28, 16)
        root.visibility = .collapsed
        shadow.isHitTestVisible = false
        shadow.stretch = .fill
        root.children.append(shadow)
        root.children.append(card)

        let stack = StackPanel()
        stack.spacing = 16
        stack.padding = Theme.inset(16, 12, 16, 6)
        stack.children.append(header())
        let row = Grid()
        let c0 = ColumnDefinition(), c1 = ColumnDefinition()
        c0.width = GridLength(value: 1, gridUnitType: .auto)
        c1.width = GridLength(value: 1, gridUnitType: .star)
        row.columnDefinitions.append(c0)
        row.columnDefinitions.append(c1)
        row.columnSpacing = 12
        playHolder.verticalAlignment = .top
        row.children.append(playHolder)
        combArea.height = Self.combHeight
        combArea.background = Theme.clear
        try? Grid.setColumn(combArea, 1)
        row.children.append(combArea)
        stack.children.append(row)
        card.child = stack
        makeComb()

        card.pointerEntered.addHandler { [weak self] _, _ in self?.overCard = true }
        card.pointerExited.addHandler { [weak self] _, _ in self?.overCard = false }
        card.pointerWheelChanged.addHandler { [weak self] _, args in
            guard let self, let args else { return }
            args.handled = true
            self.leaf(args)
        }
        // A press on the card itself goes no further: the canvas under it is not clicked.
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        root.sizeChanged.addHandler { [weak self] _, _ in self?.drawShadow() }
        combArea.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.combWidth = self.combArea.actualWidth
            self.wake()
        }
        combArea.pointerMoved.addHandler { [weak self] _, args in self?.moved(args) }
        combArea.pointerExited.addHandler { [weak self] _, _ in
            guard let self, self.pressX == nil else { return }
            self.hoverX = nil
            self.wake()
        }
        combArea.pointerPressed.addHandler { [weak self] _, args in self?.pressed(args) }
        combArea.pointerReleased.addHandler { [weak self] _, args in self?.released(args) }
        combArea.pointerCaptureLost.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.pressX = nil
            self.dragX = nil
            self.wake()
        }
    }

    /// Shows the card as the versions are: out or away, the version shown, what can be done.
    func refresh() {
        let out = versions.browsing
        root.visibility = out ? .visible : .collapsed
        guard out else { stopTicking(); return }
        let shown = versions.shown
        title.text = shown.map { Self.when($0.date) } ?? Words.t("Now")
        title.text = Self.shown(title.text)
        title.foreground = shown == nil ? Theme.brush(Theme.pencil) : Theme.ink(1)
        if !naming { nameArea(shown) }
        paintActions()
        paintPlay()
        wake()
    }

    // MARK: The row above

    private func header() -> FrameworkElement {
        let row = Grid()
        row.height = 24
        // The title's fixed slot, the name taking what room is left (cut short if it must), the
        // buttons, and the cross.
        for w in [GridLength(value: 150, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star),
                  GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto)] {
            let c = ColumnDefinition()
            c.width = w
            row.columnDefinitions.append(c)
        }
        row.columnSpacing = 8
        title.verticalAlignment = .center
        row.children.append(title)
        nameSlot.verticalAlignment = .center
        nameSlot.horizontalAlignment = .left
        try? Grid.setColumn(nameSlot, 1)
        row.children.append(nameSlot)
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.verticalAlignment = .center
        try? Grid.setColumn(actions, 2)
        row.children.append(actions)
        let close = Pressable(radius: 6) { [weak self] in self?.versions.leave() }
        close.box.width = 22
        close.box.height = 22
        close.box.child = Glyphs.view(Glyphs.cross(size: 22), size: 22, brush: Theme.ink(3))
        try? ToolTipService.setToolTip(close.box, Words.t("Put the ruler away  ⎋"))
        try? Grid.setColumn(close.box, 3)
        row.children.append(close.box)
        return row
    }

    /// The name of what is shown, or a flag to give it one; written in place when asked.
    private func nameArea(_ version: WindowsCore.Version?) {
        nameSlot.children.clear()
        if let words = version?.name {
            let text = Theme.text(Self.shown(words), size: 12.5, weight: 500, ink: 2)
            text.isHitTestVisible = true
            let hit = Border()
            hit.background = Theme.clear
            hit.child = text
            hit.tapped.addHandler { [weak self] _, _ in self?.startNaming(words) }
            try? ToolTipService.setToolTip(hit, Words.t("Give it a name"))
            nameSlot.children.append(hit)
        } else {
            let flag = Pressable(radius: 6) { [weak self] in self?.startNaming("") }
            flag.box.width = 22
            flag.box.height = 22
            let g = Glyphs.view(Glyphs.nameFlag(size: 12), size: 12, brush: Theme.ink(3))
            g.horizontalAlignment = .center
            g.verticalAlignment = .center
            flag.box.child = g
            try? ToolTipService.setToolTip(flag.box, Words.t(version == nil ? "Name this moment" : "Give it a name"))
            nameSlot.children.append(flag.box)
        }
    }

    private func startNaming(_ words: String) {
        naming = true
        nameSlot.children.clear()
        let shown = versions.shown
        let field = TextBox()
        field.text = words
        field.placeholderText = Words.t(shown == nil ? "Name this moment" : "Give it a name")
        field.width = 170
        field.fontFamily = Theme.ui
        field.fontSize = 12.5
        field.fontWeight = FontWeight(weight: 500)
        field.foreground = Theme.ink(1)
        field.background = Theme.clear
        field.borderThickness = Theme.inset(0, 0, 0, 1.5)
        field.borderBrush = Theme.brush(Theme.pencil)
        field.padding = Theme.inset(0, 3, 0, 3)
        field.minHeight = 0
        field.minWidth = 0
        var done = false
        let finish: @MainActor (Bool) -> Void = { [weak self] keep in
            guard let self, !done else { return }
            done = true
            if keep {
                if let id = shown?.id { self.versions.rename(id, field.text) } else { self.versions.nameNow(field.text) }
            }
            self.naming = false
            self.refresh()
        }
        field.keyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; finish(true) }
            if args.key == .escape { args.handled = true; finish(false) }
        }
        // Let go of when the pointer goes elsewhere in the window; another window coming to the
        // front leaves it as it is (the focused element comes back as a wrapper of its own, so it
        // is known by name).
        field.name = "versionName"
        field.lostFocus.addHandler { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard field.xamlRoot != nil else { return }
                    let now = try? FocusManager.getFocusedElement(field.xamlRoot)
                    if now == nil || (now as? FrameworkElement)?.name == field.name { return }
                    finish(false)
                }
            }
        }
        field.loaded.addHandler { _, _ in
            _ = try? field.focus(.programmatic)
            try? field.selectAll()
        }
        nameSlot.children.append(field)
    }

    private func paintActions() {
        actions.children.clear()
        guard versions.lookingBack else { return }
        if versions.pickedCount > 0 {
            let bring = Controls.cardButton(Words.t("Bring Back"), glyph: Glyphs.uturn(size: 12), height: 26) { [weak self] in
                guard let self else { return }
                let ids = self.versions.bringBack()
                if !ids.isEmpty { self.session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? self.session.board) }
            }
            try? ToolTipService.setToolTip(bring, Words.t("Brings the layers picked back as they were, into the design as it is now"))
            actions.children.append(bring)
        }
        let back = Controls.cardButton(Words.t("Go Back to This Version"), height: 26) { [weak self] in self?.versions.restore() }
        try? ToolTipService.setToolTip(back, Words.t("The design becomes what it was then. What it is now is kept as a version first."))
        actions.children.append(back)
    }

    private func paintPlay() {
        playHolder.children.clear()
        let playing = versions.playing, empty = versions.list.isEmpty
        let button = Pressable(radius: 13) { [weak self] in
            guard let self else { return }
            if self.versions.playing { self.versions.stop() } else { self.versions.play() }
            self.wake()
        }
        button.box.width = 26
        button.box.height = 26
        button.box.margin = Theme.inset(0, 0, 0, 10)
        let disc = Ellipse()
        disc.width = 26
        disc.height = 26
        disc.fill = playing ? Theme.brush(Theme.pencil) : Theme.brush(Theme.ink, 0.06)
        let holder = Grid()
        holder.children.append(disc)
        let g = Glyphs.view(playing ? Glyphs.pause(size: 11) : Glyphs.play(size: 11), size: 11,
                            brush: playing ? Theme.brush(0xFFFFFF) : Theme.ink(2))
        g.horizontalAlignment = .center
        g.verticalAlignment = .center
        if !playing { g.margin = Theme.inset(1, 0, 0, 0) }
        holder.children.append(g)
        button.box.child = holder
        if empty { button.box.opacity = 0.4; button.box.isHitTestVisible = false }
        try? ToolTipService.setToolTip(button.box, Words.t(playing ? "Stop" : "Play its story"))
        playHolder.children.append(button.box)
    }

    // MARK: The comb

    private func makeComb() {
        for layer in [dayLayer, hairLayer, strokeLayer, markLayer, headLayer, lensLayer] {
            layer.isHitTestVisible = false
            combArea.children.append(layer)
        }
        fine.fill = Theme.brush(Theme.ink, 0.14)
        lit.fill = Theme.brush(Theme.ink, 0.26)
        hairLayer.children.append(fine)
        hairLayer.children.append(lit)
        nowRing.width = 7
        nowRing.height = 7
        nowRing.stroke = Theme.brush(Theme.pencil)
        nowRing.strokeThickness = 1.5
        markLayer.children.append(nowRing)
        headGlow.fill = Theme.brush(Theme.pencil, 0.18)
        headLine.fill = Theme.brush(Theme.pencil)
        headDot.fill = Theme.brush(Theme.pencil)
        lensText.fontFamily = Theme.ui
        lensText.fontSize = 10
        lensText.fontWeight = FontWeight(weight: 600)
        lensText.foreground = Theme.brush(Theme.card)
        lensText.verticalAlignment = .center
        lensBox.child = lensText
        lensBox.height = 17
        lensBox.padding = Theme.inset(7, 0, 7, 0)
        lensBox.cornerRadius = Theme.corners(8.5)
        lensBox.background = Theme.brush(Theme.ink, 0.88)
        lensBox.isHitTestVisible = false
        lensBox.renderTransform = CompositeTransform()
        headLayer.children.append(headGlow)
        headLayer.children.append(headLine)
        headLayer.children.append(headDot)
        lensLayer.children.append(lensBox)
    }

    /// Where the versions stand on the comb, and now after them.
    private var xs: [Double] {
        WindowsCore.slots(versions.list.map(\.date), width: max(combWidth, 40))
    }

    private var index: Int { versions.shownIndex }

    /// Keeps the comb moving until all of it has settled again.
    private func wake() {
        awakeUntil = max(awakeUntil, Date().addingTimeInterval(0.5))
        guard ticking == nil, versions.browsing else { draw(); return }
        draw()
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draw()
                if Date() > self.awakeUntil, self.comb.settled, self.dragX == nil, self.hoverX == nil, !self.versions.playing { self.stopTicking() }
            }
        }
    }

    private func stopTicking() {
        ticking?.dispose()
        ticking = nil
    }

    private func draw() {
        guard versions.browsing, combWidth > 0 else { return }
        let list = versions.list
        let xs = self.xs
        let bases = list.map { $0.isNamed ? 15.0 : 11.0 } + [0]
        let at = min(index, xs.count - 1)
        let pointer = dragX ?? hoverX
        let near = pointer.map { WindowsCore.nearestSlot($0, in: xs) }
        comb.step(at: Date(), xs: xs, bases: bases, pointer: pointer, head: dragX ?? xs[at], held: dragX != nil, width: combWidth)
        let base = Self.baseline
        let heights = comb.heights, glow = comb.glow
        guard heights.count == xs.count else { return }

        // The days, quietly, under the first stroke of each.
        let calendar = Calendar.current
        let dates = list.map(\.date) + [Date()]
        var shownDays = 0
        var taken = -Double.infinity
        for i in dates.indices where i == 0 || !calendar.isDate(dates[i - 1], inSameDayAs: dates[i]) {
            let words = Self.day(dates[i])
            let label = dayLabel(shownDays)
            label.text = words
            try? label.measure(Size(width: 400, height: 40))
            let tw = Double(label.desiredSize.width)
            let x = min(xs[i] - 1, combWidth - tw)
            guard x > taken + 8 else { label.visibility = .collapsed; shownDays += 1; continue }
            taken = x + tw
            label.visibility = .visible
            try? Canvas.setLeft(label, x)
            try? Canvas.setTop(label, base + 9 - Double(label.desiredSize.height) / 2)
            shownDays += 1
        }
        for k in shownDays..<days.count { days[k].visibility = .collapsed }

        // The scale: hairlines all along, carrying the ripples that run along the comb.
        let wave = comb.wave, spacing = WindowsCore.Comb.spacing
        let nearX = near.map { xs[$0] }
        let fineGeometry = PathGeometry(), litGeometry = PathGeometry()
        for k in wave.indices {
            let x = Double(k) * spacing + spacing / 2
            guard x < xs[xs.count - 1] - 4 else { break }
            let swell = comb.swell(at: x)
            let h = max(2.5 * (1 + 1.8 * swell) + wave[k], 0.5)
            let close = nearX.map { abs($0 - x) < 30 } ?? false
            let figure = PathFigure()
            figure.startPoint = Point(x: Float(x - 0.5), y: Float(base - h))
            figure.isClosed = true
            figure.isFilled = true
            for p in [(x + 0.5, base - h), (x + 0.5, base), (x - 0.5, base)] {
                let s = LineSegment()
                s.point = Point(x: Float(p.0), y: Float(p.1))
                figure.segments.append(s)
            }
            (close ? litGeometry : fineGeometry).figures.append(figure)
        }
        fine.data = fineGeometry
        lit.data = litGeometry

        // The versions, in the colours of their skies, swelling under the pointer and ringing
        // when plucked.
        while strokes.count < list.count {
            let line = Rectangle()
            line.isHitTestVisible = false
            strokeLayer.children.append(line)
            strokes.append(line)
        }
        var beadsUsed = 0
        for (i, v) in list.enumerated() {
            let x = xs[i], line = strokes[i]
            let h = max(heights[i] + comb.ripple(at: x), 0)
            guard h > 0.2 else { line.visibility = .collapsed; continue }
            line.visibility = .visible
            let shine = max(glow[i], nearX == x ? 1 : 0)
            // A stroke with round ends: a bar as wide as the line, rounded, reaching half its width
            // past either end.
            Self.bar(line, x: x, from: base, to: base - h, width: 2.4 + shine * 0.6)
            line.fill = Theme.brush(Self.stroke(v.date), 0.78 + 0.22 * shine)
            if v.isNamed {
                let r = 2.7
                let bead = beadAt(beadsUsed)
                beadsUsed += 1
                bead.visibility = .visible
                bead.width = r * 2
                bead.height = r * 2
                try? Canvas.setLeft(bead, x - r)
                try? Canvas.setTop(bead, base - h - r * 2 - 1.5)
            }
        }
        for k in list.count..<strokes.count { strokes[k].visibility = .collapsed }
        for k in beadsUsed..<beads.count { beads[k].visibility = .collapsed }

        // Now, at the right end.
        let nx = xs[xs.count - 1]
        try? Canvas.setLeft(nowRing, nx - 3.5)
        try? Canvas.setTop(nowRing, base - 7)

        // The pencil line, lifted while held.
        let hx = comb.head, lift = comb.lift
        Self.bar(headLine, x: hx, from: base + 3, to: 4, width: 2.25)
        Self.bar(headGlow, x: hx, from: base + 3, to: 4, width: 2.25 + 2 * (3 + 4 * lift))
        headGlow.fill = Theme.brush(Theme.pencil, (0.35 + 0.25 * lift) * 0.4)
        let r = 3.5 * (1 + 0.4 * lift)
        headDot.width = r * 2
        headDot.height = r * 2
        try? Canvas.setLeft(headDot, hx - r)
        try? Canvas.setTop(headDot, 4 - r)

        // The label gliding with the pointer, catching on the version nearest it.
        let shown = comb.lensShown
        if let near, shown > 0.01 {
            lensText.text = Self.shown(near < list.count ? Self.when(list[near].date) + (list[near].name.map { "  " + $0 } ?? "") : Words.t("Now"))
            lensBox.visibility = .visible
            try? lensBox.measure(Size(width: 600, height: 40))
            let w = Double(lensBox.desiredSize.width)
            try? Canvas.setLeft(lensBox, comb.lens - w / 2)
            try? Canvas.setTop(lensBox, -9 - 8.5)
            lensBox.opacity = shown
            if let scale = lensBox.renderTransform as? CompositeTransform {
                scale.centerX = w / 2
                scale.centerY = 17
                scale.scaleX = 0.86 + 0.14 * shown
                scale.scaleY = 0.86 + 0.14 * shown
            }
        } else {
            lensBox.visibility = .collapsed
        }
    }

    /// A vertical line with round ends from `a` to `b`, as a rounded bar.
    private static func bar(_ r: Rectangle, x: Double, from a: Double, to b: Double, width w: Double) {
        let top = min(a, b) - w / 2, h = abs(a - b) + w
        r.width = w
        r.height = h
        r.radiusX = w / 2
        r.radiusY = w / 2
        try? Canvas.setLeft(r, x - w / 2)
        try? Canvas.setTop(r, top)
    }

    private func dayLabel(_ k: Int) -> TextBlock {
        while days.count <= k {
            let t = TextBlock()
            t.fontFamily = Theme.ui
            t.fontSize = 8.5
            t.fontWeight = FontWeight(weight: 600)
            t.foreground = Theme.brush(Theme.ink, 0.38)
            t.isHitTestVisible = false
            dayLayer.children.append(t)
            days.append(t)
        }
        return days[k]
    }

    private func beadAt(_ k: Int) -> Ellipse {
        while beads.count <= k {
            let e = Ellipse()
            e.fill = Theme.brush(Theme.pencil)
            e.isHitTestVisible = false
            markLayer.children.append(e)
            beads.append(e)
        }
        return beads[k]
    }

    /// The colour of a stroke: the sky then, kept legible on the card.
    private static func stroke(_ date: Date) -> UInt32 {
        let c = WindowsCore.sky(at: date)
        let k = Theme.dark ? 0.45 : 0.3
        let to: Double = Theme.dark ? 1 : 0.12
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v + (to - v) * k, 0), 1) * 255).rounded()) }
        return byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
    }

    // MARK: The pointer

    private func x(_ args: PointerRoutedEventArgs?) -> Double? {
        guard let point = try? args?.getCurrentPoint(combArea) else { return nil }
        return Double(point.position.x)
    }

    private func moved(_ args: PointerRoutedEventArgs?) {
        guard let x = x(args) else { return }
        hoverX = x
        if let start = pressX {
            // A press is a click until it moves: the line flies there; then it follows.
            let xs = self.xs
            if abs(x - start) > 3 || dragX != nil { dragX = min(max(x, xs[0]), xs[xs.count - 1]) }
            go(to: WindowsCore.nearestSlot(x, in: xs))
        }
        wake()
    }

    private func pressed(_ args: PointerRoutedEventArgs?) {
        guard let args, let x = x(args) else { return }
        args.handled = true
        _ = try? combArea.capturePointer(args.pointer)
        pressX = x
        hoverX = x
        go(to: WindowsCore.nearestSlot(x, in: xs))
    }

    private func released(_ args: PointerRoutedEventArgs?) {
        args?.handled = true
        pressX = nil
        dragX = nil
        try? combArea.releasePointerCaptures()
        wake()
    }

    private func go(to i: Int) {
        wake()
        guard i != index || versions.playing else { return }
        versions.show(index: i)
    }

    /// The wheel over the card steps through the versions, one each notch; a touchpad's smaller
    /// turns add up to one.
    private func leaf(_ args: PointerRoutedEventArgs) {
        guard !versions.list.isEmpty, !naming, let point = try? args.getCurrentPoint(card), let props = point.properties else { return }
        let d = Double(props.mouseWheelDelta) * (props.isHorizontalMouseWheel ? 1 : -1)
        scrolled += d
        while scrolled >= 120 { go(to: min(index + 1, versions.list.count)); scrolled -= 120 }
        while scrolled <= -120 { go(to: max(index - 1, 0)); scrolled += 120 }
        if abs(d) >= 120 { scrolled = 0 }
    }

    // MARK: The card's shadow

    private func drawShadow() {
        let scale = Double(root.xamlRoot?.rasterizationScale ?? 1)
        let w = root.actualWidth, h = root.actualHeight
        guard w > 0, h > 0 else { return }
        let pad = Int((40 * scale).rounded())
        let sw = Int((w * scale).rounded()), sh = Int((h * scale).rounded())
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: sw, height: sh, pad: pad, blur: 18 * scale, dy: 0, colour: Theme.shadow, alpha: 0.16) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        shadow.source = bitmap
        shadow.width = w + 2 * Double(pad) / scale
        shadow.height = h + 2 * Double(pad) / scale
        shadow.margin = Theme.inset(-Double(pad) / scale, -Double(pad) / scale + 9, -Double(pad) / scale, -Double(pad) / scale - 9)
    }

    // MARK: Words

    /// A moment as one says it: the day, and the time.
    static func when(_ date: Date) -> String { day(date) + ", " + time(date) }

    private static var locale: Locale { Locale(identifier: Words.language) }

    /// The day of a moment, as one says it: today, yesterday, a weekday this week, else a date.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return Words.t("Today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return Words.t("Yesterday") }
        if now.timeIntervalSince(date) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide).locale(locale)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated).locale(locale)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().locale(locale)) }

    /// Words as the card shows them: the narrow space Foundation puts before "PM" (also in the
    /// names it gives versions) is one the UI font has not, so a plain one that does not break
    /// stands in.
    static func shown(_ words: String) -> String {
        words.replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }
}
