import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore
import WinSDK

/// The film's timeline, as the Mac's FilmTimeline: a card floating at the foot of the canvas while
/// the design is animated. A ruler of seconds over a ruled sheet: the camera's line first, then one
/// for each layer that moves, each key a bead on it, filled where the layer is away from the design
/// and hollow where it is as designed. Everything is taken by the core's hand (`FilmHand`): a press
/// on the ruler or the bare sheet moves the playhead, a bead dragged moves its key, a line's band
/// its whole motion, the flag at the end how long the film runs.
///
/// The wheel with Ctrl held, as on the canvas, or two fingers pinched on a touchpad look at the
/// film closer about the moment under the pointer; sideways or with Shift the wheel then moves it
/// along, and a stroke under the lines shows which part of the film is in sight: twice clicked,
/// or the film looked at from further off until all of it shows, the whole film is back. How
/// close it is looked at is the viewer's own (`FilmDesk.window`). The lines are made again only
/// when another part shows; the card itself grows and shrinks with its lines on the Mac's spring.
@MainActor
final class FilmTimelineView {
    let root = Grid()
    private let session: DesignSession
    private var hand: WindowsCore.FilmHand { session.filmHand }
    private var desk: WindowsCore.FilmDesk { session.film }
    private let card = Theme.card(radius: 18)
    private let shadow = Image()
    /// Bezzle's own menus, for a right click on the sheet.
    var menus: MenuHost?

    // The row above.
    private let playBox = Border()
    private let playGlyph = Grid()
    private let clock = TextBlock()
    private let holdBead = Grid()
    private let paces = StackPanel()
    private let roundBox = Border()

    // The sheet.
    private let names = StackPanel()
    private let ruler = Canvas()
    private let tracks = Canvas()
    private let rows = Grid()
    private let scroller = ScrollViewer()
    private let playhead = Canvas()
    private let sheet = Grid()
    private let namesColumn = ColumnDefinition()
    private let rowsNamesColumn = ColumnDefinition()
    private var namesWidth = 120.0
    /// Under the lines: the stroke that shows which part of a film looked at closer is in sight
    /// (the Mac's FilmThumb). Not there while the whole film shows.
    private let foot = Canvas()
    private let thumb = Border()
    /// The sheet's sides: a film looked at closer goes on past them, and its lines, its ruler and
    /// its playhead are cut there.
    private let tracksClip = RectangleGeometry()
    private let rulerClip = RectangleGeometry()
    private let playheadClip = RectangleGeometry()
    /// How tall the lines' room is: as many lines as the card shows, four to seven. It grows and
    /// shrinks on the Mac's spring (Theme.spring) as lines come and go.
    private var tall = DeckSpring(4 * FilmFraming.rowHeight)
    private lazy var growing = Motion.Ticker { [weak self] dt in self?.grow(dt) ?? false }
    /// Whether the card has been laid out since it last came up: only then does it spring.
    private var laid = false
    /// What the card's shadow was last drawn for: the card's size, how tall the lines' room was
    /// then, and how far the shadow reaches past the card.
    private var shadowFor: (w: Double, h: Double, tall: Double, pad: Double)?
    /// The part of the film shown changed (`FilmDesk.looked`), and the lines are yet to be made
    /// again for it.
    private var linesOwed = false
    /// Moves a sheet looked at closer along under what is dragged past either end of the part
    /// shown, with every frame for as long as the hand has reason to (`FilmHand.creeps`).
    private lazy var creeper = Motion.Ticker { [weak self] dt in
        guard let self, self.hand.creeps else { return false }
        self.hand.creep(dt)
        return self.hand.creeps
    }
    private var lastPress: (at: Point, time: DWORD, clicks: Int)?
    private var pressAt: Double?
    /// The row above as it was last painted, so that what did not change is left as it is.
    private struct Header: Equatable {
        var playing: Bool
        var hold: WindowsCore.KeyBead
        var inHand: Bool
        var chosen: String?
        var once: Bool
    }
    private var painted: Header?
    /// How far past their keys the springs in hand go, named beside the paces: its number as
    /// last painted (nil: no springs in hand), and what makes the number's field, the panel's own
    /// (`Inspector.field`), given by the window.
    private let bounceBox = StackPanel()
    private var paintedBounce: (springs: Bool, bounce: Double?, wide: Bool)?
    var bounceField: ((_ percent: Double?, _ set: @escaping (Double) -> Void) -> FrameworkElement)?
    /// The playhead's line and tab, made once and moved after that.
    private var playLine: Rectangle?
    private var playTab: FrameworkElement?

    static let rowHeight = 24.0
    static let rulerHeight = 24.0
    /// The room under the lines (the six points `FilmFraming.foot` counts).
    static let footHeight = 6.0

    init(session: DesignSession) {
        self.session = session
        root.horizontalAlignment = .stretch
        root.verticalAlignment = .bottom
        root.maxWidth = 1040
        root.margin = Theme.inset(18, 0, 18, 14)
        root.visibility = .collapsed
        shadow.isHitTestVisible = false
        shadow.stretch = .fill
        root.children.append(shadow)
        root.children.append(card)

        let stack = StackPanel()
        stack.children.append(header())
        let hair = Border()
        hair.height = 0.5
        hair.background = Theme.hairline
        stack.children.append(hair)
        stack.children.append(makeSheet())
        card.child = stack
        // A press on the card itself goes no further: the canvas under it is not clicked.
        card.pointerPressed.addHandler { _, args in args?.handled = true }
        root.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            // Growing or shrinking on its spring, the card changes only in height, frame after
            // frame: its shadow is stretched along meanwhile (`layTall`) and drawn anew once it
            // rests, and its lines are as they were.
            if self.growing.running, let had = self.shadowFor, abs(self.root.actualWidth - had.w) < 0.5 { return }
            self.drawShadow()
            self.refresh()
        }
        hand.changed = { [weak self] in Probe.time("timeline.refresh(hand)") { self?.refresh() } }
        // Another part of the film shows, by the wheel, by a playhead put out of sight or by a
        // film playing out of what showed: the lines are made again, once.
        desk.looked = { [weak self] in self?.owesLines() }
        hand.creeping = { [weak self] in self?.creeper.start() }
        session.listenToFilm { [weak self] in Probe.time("timeline.refresh(film)") { self?.refresh() } }
        // A hand scrubbing through the film moves the playhead alone at every step, and the row
        // above, which shows the panels' moment, no more than thirty times a second: not every
        // line of the timeline again.
        session.listenToPlayhead { [weak self] in Probe.time("timeline.playhead(moved)") { self?.movePlayhead() } }
        session.listenToPanelTime { [weak self] in
            guard let self, self.root.visibility == .visible, self.session.isFront else { return }
            Probe.time("timeline.header(panel)") { self.paintHeader() }
        }
        session.listen { [weak self] in self?.refresh() }
        session.listenToEdits { [weak self] _ in self?.refresh() }
    }

    /// Words for a menu of the core's.
    static func entries(_ items: [WindowsCore.MotionHand.MenuItem]) -> [MenuHost.Entry] {
        items.map { item in
            if item.isSeparator { return .separator }
            let action = item.action ?? {}
            return .item(item.title, shortcut: item.shortcut, enabled: item.enabled, checked: item.checked) { action() }
        }
    }

    // MARK: The row above

    private func header() -> UIElement {
        let row = Grid()
        row.height = 44
        row.padding = Theme.inset(12, 0, 10, 0)
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                  GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto),
                  GridLength(value: 1, gridUnitType: .auto)] {
            let c = ColumnDefinition()
            c.width = w
            row.columnDefinitions.append(c)
        }
        row.columnSpacing = 10
        // Play, or stop.
        playBox.width = 26
        playBox.height = 26
        playBox.cornerRadius = Theme.corners(13)
        playBox.verticalAlignment = .center
        playBox.child = playGlyph
        playBox.pointerPressed.addHandler { _, args in args?.handled = true }
        playBox.tapped.addHandler { [weak self] _, _ in self?.later { self?.desk.toggle() } }
        row.children.append(playBox)
        // The moment the film shows.
        let time = StackPanel()
        time.orientation = .horizontal
        time.spacing = 3
        time.width = 58
        time.verticalAlignment = .center
        clock.fontFamily = Theme.serif
        clock.fontSize = 15
        clock.fontWeight = FontWeight(weight: 500)
        clock.verticalAlignment = .bottom
        time.children.append(clock)
        let unit = Theme.text("s", size: 12, ink: 3, serif: true)
        unit.verticalAlignment = .bottom
        unit.margin = Theme.inset(0, 0, 0, 1.5)
        time.children.append(unit)
        try? Grid.setColumn(time, 1)
        row.children.append(time)
        // How far past its key a spring goes, while springs are in hand: in the room between the
        // clock and the paces, so nothing moves as keys come into hand.
        bounceBox.orientation = .horizontal
        bounceBox.spacing = 6
        bounceBox.horizontalAlignment = .right
        bounceBox.verticalAlignment = .center
        bounceBox.visibility = .collapsed
        try? Grid.setColumn(bounceBox, 2)
        row.children.append(bounceBox)
        // Holding what is picked as it is at the playhead.
        holdBead.width = 26
        holdBead.height = 26
        holdBead.verticalAlignment = .center
        holdBead.background = Theme.clear
        holdBead.pointerPressed.addHandler { _, args in args?.handled = true }
        holdBead.tapped.addHandler { [weak self] _, _ in
            self?.later {
                guard let self else { return }
                if self.desk.holdState == .here { self.desk.removeKeys() } else { self.desk.holdHere() }
            }
        }
        try? Grid.setColumn(holdBead, 3)
        row.children.append(holdBead)
        // The ways a key can be come to, readier while keys are in hand.
        paces.orientation = .horizontal
        paces.spacing = 1
        paces.verticalAlignment = .center
        try? Grid.setColumn(paces, 4)
        row.children.append(paces)
        let line = Border()
        line.width = 0.5
        line.height = 16
        line.background = Theme.hairline
        line.verticalAlignment = .center
        try? Grid.setColumn(line, 5)
        row.children.append(line)
        // Round and round, or once.
        roundBox.width = 26
        roundBox.height = 26
        roundBox.cornerRadius = Theme.corners(13)
        roundBox.verticalAlignment = .center
        roundBox.pointerPressed.addHandler { _, args in args?.handled = true }
        roundBox.tapped.addHandler { [weak self] _, _ in
            self?.later {
                guard let self else { return }
                self.desk.setOnce(!self.desk.once)
            }
        }
        try? Grid.setColumn(roundBox, 6)
        row.children.append(roundBox)
        return row
    }

    private func later(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }

    /// The row above, as the film is now, at the panels' moment (`panelTime`); only what changed
    /// since it was last painted is painted again.
    private func paintHeader() {
        let t = desk.panelTime
        let inHand = desk.hasKeysToRemove(at: t)
        let now = Header(playing: desk.playing, hold: desk.holdState(at: t), inHand: inHand, chosen: inHand ? desk.sharedEase(at: t) : nil, once: desk.once)
        let was = painted
        painted = now
        if was?.playing != now.playing { paintPlay(now.playing) } else { showClock() }
        if was?.hold != now.hold { paintHold(now.hold) }
        let springs = now.chosen == "spring"
        let bounce = springs ? desk.sharedBounce(at: t) : nil
        if was?.inHand != now.inHand || was?.chosen != now.chosen || (springs && bounce != paintedBounce?.bounce) {
            paintPaces(inHand: now.inHand, chosen: now.chosen, bounce: bounce)
        }
        if was?.once != now.once { paintRound(now.once) }
        paintBounce(springs: springs, bounce: bounce)
    }

    /// Bounce and its number, 0 to 100 %, beside the paces while the keys in hand are springs.
    /// Left as it is under a hand dragging its number, and made again once the hand lets go.
    private func paintBounce(springs: Bool, bounce: Double?) {
        let wide = sheet.actualWidth >= 600
        if let was = paintedBounce, was.springs == springs, was.bounce == bounce, was.wide == wide { return }
        guard !WindowsCore.inGesture else { return bounceSettles() }
        paintedBounce = (springs, bounce, wide)
        bounceBox.children.clear()
        bounceBox.visibility = springs ? .visible : .collapsed
        guard springs, let make = bounceField else { return }
        // On a narrow card the number stands alone.
        if wide {
            let name = Theme.text(Words.t("Bounce"), size: 11, weight: 500, ink: 3)
            name.verticalAlignment = .center
            bounceBox.children.append(name)
        }
        bounceBox.children.append(make(bounce.map { ($0 * 100).rounded() }) { [weak self] percent in self?.desk.setBounce(percent / 100) })
        try? ToolTipService.setToolTip(bounceBox, Words.t("How far a spring goes past its key before it comes to rest"))
    }

    /// Looks again once the hand on the number has let go.
    private var bounceWaits = false
    private func bounceSettles() {
        guard !bounceWaits else { return }
        bounceWaits = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bounceWaits = false
                guard self.session.mode == 3 else { return }
                if WindowsCore.inGesture { self.bounceSettles() } else { self.paintHeader() }
            }
        }
    }

    private func paintPlay(_ playing: Bool) {
        playBox.background = playing ? Theme.brush(Theme.pencil) : Theme.brush(Theme.ink, 0.06)
        playGlyph.children.clear()
        let g = Glyphs.view(playing ? Glyphs.pause(size: 12) : Glyphs.play(size: 12), size: 12, brush: playing ? Theme.brush(0xFFFFFF) : Theme.ink(2))
        g.horizontalAlignment = .center
        g.verticalAlignment = .center
        g.margin = Theme.inset(playing ? 0 : 1, 0, 0, 0)
        playGlyph.children.append(g)
        try? ToolTipService.setToolTip(playBox, Words.t(playing ? "Stop the film  Space" : "Play the film  Space"))
        clock.foreground = playing ? Theme.brush(Theme.pencil) : Theme.ink(1)
        showClock()
    }

    private func paintHold(_ hold: WindowsCore.KeyBead) {
        holdBead.children.clear()
        holdBead.children.append(Self.bead(state: hold, size: 10))
        holdBead.opacity = hold == .none ? 0.3 : 1
        holdBead.isHitTestVisible = hold != .none
        try? ToolTipService.setToolTip(holdBead, Words.t(hold == .here ? "A key here. Click to take it away." : "Hold it here: a key at the playhead  K"))
    }

    private func paintPaces(inHand: Bool, chosen: String?, bounce: Double?) {
        paces.children.clear()
        for pace in WindowsCore.FilmDesk.paces {
            // The chosen Spring chip draws the springs' own bounce.
            paces.children.append(paceChip(pace.name, title: pace.title, chosen: chosen == pace.name,
                                           bounce: pace.name == "spring" && chosen == "spring" ? bounce : nil))
        }
        paces.opacity = inHand ? 1 : 0.3
        paces.isHitTestVisible = inHand
    }

    private func paintRound(_ once: Bool) {
        roundBox.background = once ? Theme.clear : Theme.brush(Theme.pencil, Theme.pencilWash)
        let loop = Glyphs.view(Glyphs.loop(size: 14), size: 14, brush: once ? Theme.ink(3) : Theme.brush(Theme.pencil))
        loop.horizontalAlignment = .center
        loop.verticalAlignment = .center
        roundBox.child = loop
        try? ToolTipService.setToolTip(roundBox, Words.t(once ? "Plays once and stops. Click to play it round and round." : "Plays round and round. Click to play it once."))
    }

    private func showClock() {
        clock.text = String(format: "%.2f", desk.live)
    }

    /// A bead as the panel and the timeline show a key at the playhead: faint while there are no
    /// keys, a ring where there are some but none here, filled where there is one.
    static func bead(state: WindowsCore.KeyBead, size d: Double) -> FrameworkElement {
        let e = Ellipse()
        e.width = d
        e.height = d
        e.fill = state == .here ? Theme.brush(Theme.pencil) : Theme.brush(Theme.card)
        e.stroke = state == .here ? Theme.brush(Theme.pencil) : state == .between ? Theme.ink(2) : Theme.ink(4)
        e.strokeThickness = 1.4
        e.horizontalAlignment = .center
        e.verticalAlignment = .center
        e.isHitTestVisible = false
        return e
    }

    /// A way of coming to a key, as the curve it is: dashed for Auto, which is read from the keys.
    private func paceChip(_ name: String, title: String, chosen: Bool, bounce: Double? = nil) -> UIElement {
        let press = Pressable(radius: 7) { [weak self] in self?.desk.setEase(name) }
        press.box.width = 28
        press.box.height = 26
        if chosen { press.box.background = Theme.brush(Theme.pencil, Theme.pencilWash) }
        var d = PathData()
        let steps = 28, box = (x: 6.0, y: 6.5, w: 16.0, h: 13.0)
        // A spring's own bounce as the Mac's chip draws it: the same picture as ever at the usual
        // bounce (drawn with more than a spring usually has, to be seen at this size), a plain
        // arrival with none, and all of it with all.
        let drawn = bounce.map { b -> Double in
            let b = min(max(b, 0), 1), usually = 0.3, usual = 0.55
            return b <= usually ? b / usually * usual : usual + (b - usually) / (1 - usually) * (1 - usual)
        } ?? 0.55
        for k in 0...steps {
            let u = Double(k) / Double(steps)
            let v = WindowsCore.paceProgress(name, u, bounce: drawn) * (name == "spring" ? 0.8 : 1)
            let x = box.x + box.w * u, y = box.y + box.h - box.h * v
            if k == 0 { d.move(x, y) } else { d.line(x, y) }
        }
        // Auto is read from the keys round it: its curve is only pencilled in.
        let dash = name == "auto" ? " StrokeDashArray='1.6 1.9'" : ""
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1.4' StrokeLineJoin='Round' StrokeStartLineCap='Round' StrokeEndLineCap='Round'\(dash)/>"
        let view = Canvas()
        view.width = 28
        view.height = 26
        view.isHitTestVisible = false
        if let path = (try? XamlReader.load(xaml)) as? WinUI.Path {
            path.stroke = chosen ? Theme.brush(Theme.pencil) : Theme.ink(2)
            view.children.append(path)
        }
        press.box.child = view
        try? ToolTipService.setToolTip(press.box, title)
        return press.box
    }

    // MARK: The sheet

    private func makeSheet() -> UIElement {
        let c1 = ColumnDefinition()
        namesColumn.width = GridLength(value: namesWidth, gridUnitType: .pixel)
        c1.width = GridLength(value: 1, gridUnitType: .star)
        sheet.columnDefinitions.append(namesColumn)
        sheet.columnDefinitions.append(c1)
        // The ruler, the lines, and six points under them, where the stroke lies that shows which
        // part of the film is in sight.
        let r0 = RowDefinition(), r1 = RowDefinition(), r2 = RowDefinition()
        r0.height = GridLength(value: Self.rulerHeight, gridUnitType: .pixel)
        r1.height = GridLength(value: 1, gridUnitType: .auto)
        r2.height = GridLength(value: Self.footHeight, gridUnitType: .pixel)
        sheet.rowDefinitions.append(r0)
        sheet.rowDefinitions.append(r1)
        sheet.rowDefinitions.append(r2)

        ruler.height = Self.rulerHeight
        ruler.background = Theme.clear
        ruler.clip = rulerClip
        try? Grid.setColumn(ruler, 1)
        sheet.children.append(ruler)

        // The names and the tracks side by side, scrolling together past seven lines.
        let cr1 = ColumnDefinition()
        rowsNamesColumn.width = GridLength(value: namesWidth, gridUnitType: .pixel)
        cr1.width = GridLength(value: 1, gridUnitType: .star)
        rows.columnDefinitions.append(rowsNamesColumn)
        rows.columnDefinitions.append(cr1)
        rows.children.append(names)
        // From the top, while the card closes over fewer lines than it still has room for.
        rows.verticalAlignment = .top
        tracks.background = Theme.clear
        tracks.clip = tracksClip
        try? Grid.setColumn(tracks, 1)
        rows.children.append(tracks)
        scroller.content = rows
        scroller.verticalScrollBarVisibility = .hidden
        scroller.horizontalScrollBarVisibility = .disabled
        try? Grid.setRow(scroller, 1)
        try? Grid.setColumnSpan(scroller, 2)
        sheet.children.append(scroller)

        // Within the sheet: moved along, a film looked at closer takes the playhead out of sight.
        playhead.isHitTestVisible = false
        playhead.clip = playheadClip
        try? Grid.setColumn(playhead, 1)
        try? Grid.setRowSpan(playhead, 2)
        sheet.children.append(playhead)

        // Which part of the film shows, while not all of it does: as long against the sheet as
        // that part is against the film. Twice clicked, the whole film shows again.
        foot.height = Self.footHeight
        try? Grid.setColumn(foot, 1)
        try? Grid.setRow(foot, 2)
        sheet.children.append(foot)
        let stroke = Rectangle()
        stroke.height = 3
        stroke.radiusX = 1.5
        stroke.radiusY = 1.5
        stroke.fill = Theme.brush(Theme.ink, 0.2)
        stroke.verticalAlignment = .center
        stroke.isHitTestVisible = false
        thumb.height = Self.footHeight
        thumb.background = Theme.clear
        thumb.child = stroke
        thumb.visibility = .collapsed
        thumb.doubleTapped.addHandler { [weak self] _, args in
            args?.handled = true
            self?.later { self?.hand.showWhole() }
        }
        foot.children.append(thumb)

        tracks.pointerWheelChanged.addHandler { [weak self] _, args in self?.wheel(args, ruler: false) }
        ruler.pointerWheelChanged.addHandler { [weak self] _, args in self?.wheel(args, ruler: true) }
        tracks.pointerPressed.addHandler { [weak self] _, args in self?.pressed(args, ruler: false) }
        tracks.pointerMoved.addHandler { [weak self] _, args in self?.moved(args, ruler: false) }
        tracks.pointerReleased.addHandler { [weak self] _, args in self?.released(args) }
        tracks.pointerExited.addHandler { [weak self] _, _ in
            guard let self, !self.hand.dragging else { return }
            self.hand.hot = WindowsCore.FilmHand.Hot()
        }
        tracks.rightTapped.addHandler { [weak self] _, args in
            guard let self, let menus = self.menus, let at = try? args?.getPosition(menus.layer) else { return }
            if let p = try? args?.getPosition(self.tracks) { self.hand.hot = self.hand.point(CGPoint(x: Double(p.x), y: Double(p.y))) }
            let entries = Self.entries(self.hand.menu())
            if !entries.isEmpty { menus.show(at: CGPoint(x: Double(at.x), y: Double(at.y)), width: 200, entries: entries) }
        }
        ruler.pointerPressed.addHandler { [weak self] _, args in self?.pressed(args, ruler: true) }
        ruler.pointerMoved.addHandler { [weak self] _, args in self?.moved(args, ruler: true) }
        ruler.pointerReleased.addHandler { [weak self] _, args in self?.released(args) }
        ruler.pointerExited.addHandler { [weak self] _, _ in
            guard let self, !self.hand.dragging else { return }
            self.hand.hot = WindowsCore.FilmHand.Hot()
        }
        return sheet
    }

    private func position(_ args: PointerRoutedEventArgs?, in element: UIElement) -> CGPoint? {
        guard let p = try? args?.getCurrentPoint(element)?.position else { return nil }
        return CGPoint(x: Double(p.x), y: Double(p.y))
    }

    private func pressed(_ args: PointerRoutedEventArgs?, ruler onRuler: Bool) {
        guard let args, let p = position(args, in: onRuler ? ruler : tracks) else { return }
        args.handled = true
        let keys = UInt32(truncatingIfNeeded: args.keyModifiers.rawValue)
        // A second press soon after the first, where it was, is a double click.
        let now = GetTickCount(), at = Point(x: Float(p.x), y: Float(p.y))
        if let last = lastPress, now - last.time <= GetDoubleClickTime(), abs(last.at.x - at.x) <= 4, abs(last.at.y - at.y) <= 4 {
            lastPress = (at, now, last.clicks + 1)
        } else {
            lastPress = (at, now, 1)
        }
        let clicks = lastPress?.clicks ?? 1
        pressAt = Double(p.x)
        _ = try? (onRuler ? ruler : tracks).capturePointer(args.pointer)
        if onRuler { hand.pressRuler(at: p, clicks: clicks) } else { hand.press(at: p, shift: keys & 4 != 0, clicks: clicks) }
        hand.dragged(to: p, by: 0, free: keys & 1 != 0, fine: keys & 2 != 0)
    }

    private func moved(_ args: PointerRoutedEventArgs?, ruler onRuler: Bool) {
        guard let args, let p = position(args, in: onRuler ? ruler : tracks) else { return }
        let keys = UInt32(truncatingIfNeeded: args.keyModifiers.rawValue)
        if hand.dragging, let from = pressAt {
            hand.dragged(to: p, by: CGFloat(Double(p.x) - from), free: keys & 1 != 0, fine: keys & 2 != 0)
        } else {
            hand.hot = onRuler ? hand.pointRuler(p) : hand.point(p)
        }
    }

    private func released(_ args: PointerRoutedEventArgs?) {
        guard let args else { return }
        args.handled = true
        try? ruler.releasePointerCapture(args.pointer)
        try? tracks.releasePointerCapture(args.pointer)
        let keys = UInt32(truncatingIfNeeded: args.keyModifiers.rawValue)
        pressAt = nil
        hand.ended(shift: keys & 4 != 0)
    }

    /// The wheel over the lines or the ruler. With Ctrl held it looks at the film closer or from
    /// further off about the moment under the pointer, as it zooms the canvas; two fingers
    /// pinched on a touchpad do the same, which Windows tells an app as the wheel with Ctrl said
    /// to be held while no key is down. Turned sideways (two fingers moved sideways on a
    /// touchpad) or with Shift held it moves a film looked at closer along. Up and down it is
    /// left to the lines, which scroll as before: only a turn that was used goes no further.
    private func wheel(_ args: PointerRoutedEventArgs?, ruler onRuler: Bool) {
        guard let args, let current = try? args.getCurrentPoint(onRuler ? ruler : tracks), let properties = current.properties else { return }
        let delta = Double(properties.mouseWheelDelta)
        let said = UInt32(truncatingIfNeeded: args.keyModifiers.rawValue)
        if said & 1 != 0 || GetKeyState(Int32(VK_CONTROL)) < 0 {
            hand.zoom(by: FilmSheet.closer(byWheel: delta), at: Double(current.position.x))
            args.handled = true
        } else if properties.isHorizontalMouseWheel || said & 4 != 0 || GetKeyState(Int32(VK_SHIFT)) < 0 {
            // The whole film has nowhere to go.
            guard hand.zoomed else { return }
            hand.scroll(by: FilmSheet.along(byWheel: delta))
            args.handled = true
        }
    }

    // MARK: Showing it

    /// The card shown as the film is now.
    func refresh() {
        let on = session.mode == 3
        root.visibility = on ? .visible : .collapsed
        guard on else {
            // Put away: it comes up again as tall as its film's lines, at once.
            laid = false
            growing.stop()
            tall = DeckSpring(tall.target)
            return
        }
        guard session.isFront else { return }
        linesOwed = false
        painted = nil
        playLine = nil
        paintHeader()
        let lines = hand.lines()
        let width = max(sheet.actualWidth, 300)
        namesWidth = min(150, max(104, width * 0.22))
        names.width = namesWidth
        namesColumn.width = GridLength(value: namesWidth, gridUnitType: .pixel)
        rowsNamesColumn.width = GridLength(value: namesWidth, gridUnitType: .pixel)
        let tracksWidth = max(width - namesWidth, 60)
        hand.width = CGFloat(tracksWidth)
        ruler.margin = Theme.inset(0, 0, 0, 0)
        // As many lines as `FilmFraming.foot(lines:)` keeps the film's artboard clear of. With
        // other lines to show the card grows or shrinks on the Mac's spring; at once when it
        // first comes up, under a hand on the sheet and while the film plays.
        let want = Double(FilmFraming.shown(of: lines.count)) * Self.rowHeight
        if want != tall.target {
            if laid, !hand.dragging, !desk.playing {
                tall.target = want
                growing.start()
            } else {
                tall = DeckSpring(want)
                growing.stop()
            }
        }
        laid = true
        rows.height = max(Double(lines.count) * Self.rowHeight, want)
        tracks.width = tracksWidth
        tracks.height = rows.height
        // While the card closes over lines that have gone, the paper there stays ruled.
        let ruled = max(rows.height, tall.value)
        tracksClip.rect = Rect(x: 0, y: 0, width: Float(tracksWidth), height: Float(ruled))
        rulerClip.rect = Rect(x: 0, y: 0, width: Float(tracksWidth), height: Float(Self.rulerHeight))
        playheadClip.rect = Rect(x: 0, y: 0, width: Float(tracksWidth), height: Float(Self.rulerHeight + 8 * Self.rowHeight))
        layTall()
        drawNames(lines)
        drawTracks(lines, width: tracksWidth, height: ruled)
        drawRuler(width: tracksWidth)
        placeThumb()
        movePlayhead()
    }

    /// The part of the film shown changed (`FilmDesk.looked`): the lines are made again once what
    /// is being done is done, unless that makes them again itself, as a key dragged along while
    /// the sheet creeps under it does. So a step draws them once, not twice.
    private func owesLines() {
        guard !linesOwed else { return }
        linesOwed = true
        later { [weak self] in
            guard let self, self.linesOwed else { return }
            self.linesOwed = false
            Probe.time("timeline.refresh(looked)") { self.refresh() }
        }
    }

    /// The stroke under the lines: which part of the film is in sight, while not all of it is.
    private func placeThumb() {
        guard let part = hand.thumb else {
            thumb.visibility = .collapsed
            return
        }
        thumb.width = part.long
        try? Canvas.setLeft(thumb, part.x)
        thumb.visibility = .visible
    }

    // MARK: The card's height

    /// A frame of the card growing or shrinking with its lines. False once it rests.
    private func grow(_ dt: Double) -> Bool {
        tall.step(dt, stiffness: Motion.spring.stiffness, damping: Motion.spring.damping)
        let rests = tall.settled
        if rests { tall = DeckSpring(tall.target) }
        layTall()
        if rests { rested() }
        return !rests
    }

    /// The lines' room as tall as it is now, on its way or at rest: the room itself, the
    /// playhead's line down it, and the card's shadow, stretched along with the picture it has
    /// rather than drawn anew at every frame.
    private func layTall() {
        scroller.height = tall.value
        playLine?.height = Self.rulerHeight + tall.value
        if let had = shadowFor { shadow.height = max(had.h + tall.value - had.tall, 1) + 2 * had.pad }
    }

    /// The card rests at its new height: its shadow is drawn for it, once it is laid out so.
    private func rested() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.growing.running, let had = self.shadowFor else { return }
                if abs(self.root.actualHeight - had.h) > 0.25 || abs(self.root.actualWidth - had.w) > 0.25 { self.drawShadow() }
            }
        }
    }

    /// The playhead alone, as the film plays or a hand scrubs through it: its line and tab, made
    /// once and moved after that, and the clock.
    func movePlayhead() {
        guard root.visibility == .visible else { return }
        showClock()
        let x = Double(hand.x(desk.live))
        let height = Self.rulerHeight + tall.value
        if playLine == nil || playTab == nil {
            playhead.children.clear()
            let line = Rectangle()
            line.width = 1.25
            line.fill = Theme.brush(Theme.pencil)
            playhead.children.append(line)
            // The tab drawn about its own middle, laid where the playhead is.
            var tab = PathData()
            let r = (x: -5.5, y: 0.0, w: 11.0, h: 12.0)
            let shoulder = r.y + r.h * 0.5, round = 2.5
            tab.move(r.x + round, r.y); tab.line(r.x + r.w - round, r.y); tab.quad(r.x + r.w, r.y, r.x + r.w, r.y + round)
            tab.line(r.x + r.w, shoulder); tab.line(r.x + r.w / 2, r.y + r.h); tab.line(r.x, shoulder); tab.line(r.x, r.y + round)
            tab.quad(r.x, r.y, r.x + round, r.y); tab.close()
            let view = Glyphs.view([Glyphs.Part(data: tab.d, mode: .fill)], size: 0, brush: Theme.brush(Theme.pencil))
            playhead.children.append(view)
            playLine = line
            playTab = view
        }
        guard let line = playLine, let view = playTab else { return }
        if line.height != height { line.height = height }
        try? Canvas.setLeft(line, x - 0.625)
        try? Canvas.setLeft(view, x)
    }

    private func drawNames(_ lines: [WindowsCore.FilmLine]) {
        names.children.clear()
        for line in lines {
            let row = Grid()
            row.height = Self.rowHeight
            row.padding = Theme.inset(8, 0, 6, 0)
            row.background = line.picked ? Theme.brush(Theme.pencil, Theme.pencilWash * (line.single ? 0.35 : 0.7)) : Theme.clear
            let lead = StackPanel()
            lead.orientation = .horizontal
            lead.spacing = 5
            lead.verticalAlignment = .center
            if !line.single {
                let chevron = Border()
                chevron.width = 14
                chevron.height = Self.rowHeight
                chevron.background = Theme.clear
                let g = Glyphs.view(Glyphs.chevron(open: line.open, size: 9), size: 9, brush: line.open ? Theme.ink(2) : Theme.ink(4))
                g.horizontalAlignment = .center
                g.verticalAlignment = .center
                chevron.child = g
                chevron.opacity = line.marks.isEmpty ? 0 : 1
                let layer = line.layer
                chevron.pointerPressed.addHandler { _, args in args?.handled = true }
                chevron.tapped.addHandler { [weak self] _, args in
                    args?.handled = true
                    self?.later { self?.hand.toggleOpen(layer) }
                }
                lead.children.append(chevron)
                let glyph = line.kind.map { Glyphs.view(Glyphs.kind($0, size: 15), size: 15, brush: line.picked ? Theme.brush(Theme.pencil) : Theme.ink(2)) }
                    ?? Glyphs.view(Glyphs.camera(size: 15), size: 15, brush: line.picked ? Theme.brush(Theme.pencil) : Theme.ink(2))
                lead.children.append(glyph)
            } else {
                let room = Border()
                room.width = 34
                lead.children.append(room)
            }
            let name = Theme.text(line.name, size: line.single ? 11 : 12, weight: line.picked && !line.single ? 500 : 400, ink: line.single ? 3 : 1)
            if line.picked, !line.single { name.foreground = Theme.brush(Theme.pencil) }
            name.maxWidth = namesWidth - 14 - (line.single ? 34 : 34)
            lead.children.append(name)
            row.children.append(lead)
            row.pointerPressed.addHandler { _, args in args?.handled = true }
            row.tapped.addHandler { [weak self] _, _ in
                let shift = GetKeyState(Int32(VK_SHIFT)) < 0
                self?.later { self?.hand.pickLine(line, shift: shift) }
            }
            names.children.append(row)
        }
    }

    private func drawTracks(_ lines: [WindowsCore.FilmLine], width: Double, height: Double) {
        tracks.children.clear()
        // Under every line a hairline, whether one is written on it yet or not.
        var ruled = PathData()
        var y = Self.rowHeight
        while y < height + 0.5 {
            ruled.move(0, y - 0.25); ruled.line(width, y - 0.25)
            y += Self.rowHeight
        }
        add(ruled, stroke: Theme.ink(1), alpha: 0.07, width: 0.5, to: tracks)
        // Where moments lie along the sheet, read once for all its lines: the film's start, and
        // how wide a second is (`FilmHand.x`).
        let origin = Double(hand.x(0)), perSecond = Double(hand.perSecond)
        func along(_ t: Double) -> Double { origin + t * perSecond }
        // Past the film's end, the sheet is in shade: what is keyed there does not play.
        let end = max(along(desk.length), 0)
        if end < width {
            let past = Rectangle()
            past.width = width - end
            past.height = height
            past.fill = Theme.brush(Theme.ink, 0.05)
            past.isHitTestVisible = false
            try? Canvas.setLeft(past, end)
            tracks.children.append(past)
        }
        let hot = hand.hot
        for (i, line) in lines.enumerated() {
            let top = Double(i) * Self.rowHeight, mid = top + Self.rowHeight / 2
            if line.picked {
                let wash = Rectangle()
                wash.width = width
                wash.height = Self.rowHeight
                wash.fill = Theme.brush(Theme.pencil, Theme.pencilWash * (line.single ? 0.35 : 0.7))
                wash.isHitTestVisible = false
                try? Canvas.setTop(wash, top)
                tracks.children.append(wash)
            }
            let own = line.single
            if let first = line.marks.first, let last = line.marks.last, last.t > first.t {
                let band = hot.band == line.id || (hand.holdsBand && hot.row == line.id)
                let h = own ? 11.0 : 15.0
                // As much of it as shows: on a film looked at closer a band goes on far past
                // the sheet's sides.
                let from = max(along(first.t) - h / 2, -h), to = min(along(last.t) + h / 2, width + h)
                if to > from {
                    let capsule = Rectangle()
                    capsule.width = to - from
                    capsule.height = h
                    capsule.radiusX = h / 2
                    capsule.radiusY = h / 2
                    capsule.fill = Theme.brush(Theme.ink, band ? 0.13 : own ? 0.05 : 0.075)
                    capsule.isHitTestVisible = false
                    try? Canvas.setLeft(capsule, from)
                    try? Canvas.setTop(capsule, mid - h / 2)
                    tracks.children.append(capsule)
                }
            }
            if own, line.marks.count > 1 {
                // How each key is come to, drawn between it and the one before.
                var pace = PathData()
                let rise = 7.0
                for k in 1..<line.marks.count {
                    guard let curve = line.marks[k].pace else { continue }
                    let a = along(line.marks[k - 1].t) + 5, b = along(line.marks[k].t) - 5
                    // Only what is in sight: a film looked at closer has long stretches out of it.
                    guard b - a > 10, b > 0, a < width else { continue }
                    // The part of the stretch in sight, a point for every three across it.
                    let from = max(a, -3), to = min(b, width + 3)
                    let steps = max(8, Int((to - from) / 3))
                    for s in 0...steps {
                        let x = from + (to - from) * Double(s) / Double(steps)
                        let py = mid + rise / 2 - rise * curve((x - a) / (b - a))
                        if s == 0 { pace.move(x, py) } else { pace.line(x, py) }
                    }
                }
                add(pace, stroke: Theme.ink(1), alpha: 0.34, width: 1, to: tracks)
            }
            for mark in line.marks {
                let d = own ? 7.0 : 9.0
                let ink: UInt32 = mark.picked ? Theme.pencil : Theme.ink
                let alpha = mark.picked ? 1 : mark.given ? 0.44 : 1
                let grown = mark.hot ? 1.3 : 1.0
                let x = along(mark.t)
                // Only the beads in sight are made.
                guard x > -12, x < width + 12 else { continue }
                if mark.picked {
                    let halo = Ellipse()
                    halo.width = d + 9
                    halo.height = d + 9
                    halo.fill = Theme.brush(Theme.pencil, 0.2)
                    halo.isHitTestVisible = false
                    try? Canvas.setLeft(halo, x - (d + 9) / 2)
                    try? Canvas.setTop(halo, mid - (d + 9) / 2)
                    tracks.children.append(halo)
                }
                let e = Ellipse()
                e.width = d * grown
                e.height = d * grown
                e.fill = mark.home ? Theme.brush(Theme.card) : Theme.brush(ink, alpha)
                e.stroke = Theme.brush(ink, alpha)
                e.strokeThickness = own ? 1.2 : 1.5
                e.isHitTestVisible = false
                try? Canvas.setLeft(e, x - d * grown / 2)
                try? Canvas.setTop(e, mid - d * grown / 2)
                tracks.children.append(e)
            }
        }
    }

    private func add(_ d: PathData, stroke: SolidColorBrush, alpha: Double, width: Double, to canvas: Canvas, fill: Brush? = nil) {
        guard !d.d.isEmpty else { return }
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='\(width)' StrokeLineJoin='Round' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>"
        guard let p = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
        p.stroke = stroke
        p.opacity = alpha
        if let fill { p.fill = fill }
        p.isHitTestVisible = false
        canvas.children.append(p)
    }

    /// The seconds along the top, and the flag where the film ends: hollow while the film is as
    /// long as its keys, filled once its length was set. Its numbers thin out and fill in with
    /// how close the film is looked at, from one a minute down to one every twentieth of a second
    /// with a stroke every hundredth, and only the strokes in sight are made (`FilmSheet.step`,
    /// `strokes`, the Mac's FilmRuler).
    private func drawRuler(width: Double) {
        ruler.children.clear()
        let perSecond = Double(hand.perSecond), origin = Double(hand.x(0))
        let rule = FilmSheet.strokes(perSecond: perSecond, origin: origin, width: width)
        let minor = rule.major / Double(rule.parts)
        let length = desk.length
        let h = Self.rulerHeight
        var strokes = PathData(), fine = PathData()
        for i in rule.first..<rule.end {
            let t = Double(i) * minor
            let x = origin + t * perSecond
            if x > width - 2 { break }
            let whole = i % rule.parts == 0
            let past = t > length + 0.0001
            if past { fine.move(x, h - (whole ? 7 : 3.5)); fine.line(x, h) } else { strokes.move(x, h - (whole ? 7 : 3.5)); strokes.line(x, h) }
            if whole {
                let label = Theme.text(FilmSheet.label(t, step: rule.major), size: 9.5, weight: 500)
                label.foreground = Theme.brush(Theme.ink, past ? 0.22 : 0.46)
                label.isHitTestVisible = false
                try? Canvas.setLeft(label, x + 3.5)
                try? Canvas.setTop(label, h - 12 - 7)
                ruler.children.append(label)
            }
        }
        add(strokes, stroke: Theme.ink(1), alpha: 0.3, width: 1, to: ruler)
        add(fine, stroke: Theme.ink(1), alpha: 0.14, width: 1, to: ruler)
        // The film's end.
        let hot = hand.hot.end || hand.holdsLength
        let x = origin + length * perSecond
        var pole = PathData()
        pole.move(x, 5); pole.line(x, h)
        add(pole, stroke: Theme.ink(1), alpha: hot ? 0.9 : 0.55, width: 1.25, to: ruler)
        let grow = hot ? 1.5 : 0
        var flag = PathData()
        flag.move(x, 4.5 - grow); flag.line(x - 8 - grow, 8); flag.line(x, 11.5 + grow); flag.close()
        add(flag, stroke: Theme.ink(1), alpha: hot ? 0.9 : 0.6, width: 1.1, to: ruler,
            fill: desk.lengthSet ? Theme.brush(Theme.ink, hot ? 0.95 : 0.8) : Theme.brush(Theme.card))
        try? ToolTipService.setToolTip(ruler, Words.t("Where the film ends. Drag to set its length; double click to let it follow the keys."))
    }

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
        shadowFor = (w, h, tall.value, Double(pad) / scale)
    }
}
