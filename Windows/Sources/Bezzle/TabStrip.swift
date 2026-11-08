import Foundation
import WinUI
import UWP
import WinSDK
import WindowsFoundation
import BezzleCore

/// The tabs along the bar, as the Mac's TabStrip (Views/TabBar.swift): Bezzle's name first, which
/// is home, then a tab for each open design, then a round plus to start another. Each tab is as
/// wide as its name; the one in front opens out to the full 196 points and rests on a card of its
/// own, which slides along to whichever tab is picked. When they are too many for the room, the
/// longest names give way first, down to 44 points each. A tab dragged sideways takes another
/// place, the others making way; pressed, it comes to the front at once; a double click renames
/// its design; a right click offers Rename, Show in Explorer and closing. Everything moves on the
/// Mac's spring (Theme.spring: response 0.34, damping 0.86).
///
/// One strip for the window: it sits in the bar of whatever is in front (`place(in:)`).
@MainActor
final class TabStrip {
    let root = Canvas()

    static let height = 30.0
    static let spacing = 4.0
    static let widest = 196.0
    static let narrowest = 44.0
    /// Between home and the first design, as the Mac's HStack(spacing: spacing + 2).
    static let homeGap = 6.0
    static let plusSize = 26.0

    /// The card the tab in front rests on.
    private let card = Theme.card(radius: 9)
    private let home = Border()
    private let plus: Pressable
    private var views: [TabView] = []
    /// Closed tabs on their way out.
    private var leaving: [TabView] = []
    private var cardX = DeckSpring(0), cardW = DeckSpring(0), plusX = DeckSpring(0)
    private var homeWidth = 0.0
    private var homeHovering = false
    /// The room the bar leaves the tabs, home and plus included.
    private var room = Double.infinity
    private var ticking: EventCleanup?
    private var last = 0.0
    private var placedOnce = false

    /// A tab being pressed or dragged sideways.
    private struct Drag {
        let id: UUID
        let from: Int
        let pointer: WinUI.Pointer?
        var startX: Double
        var offset = 0.0
        var moved = false
    }
    private var drag: Drag?

    /// The menus of what is in front, which the strip's menus open in.
    var menus: () -> MenuHost? = { nil }

    init() {
        plus = Pressable(radius: 13) { Tabs.shared.showHome() }
        root.height = Self.height
        root.verticalAlignment = .center
        root.horizontalAlignment = .left
        card.height = Self.height
        card.isHitTestVisible = false
        root.children.append(card)

        home.height = Self.height
        home.cornerRadius = Theme.corners(9)
        home.background = Theme.clear
        let word = Theme.text("Bezzle", size: 15, weight: 600, serif: true)
        word.verticalAlignment = .center
        word.horizontalAlignment = .center
        home.child = word
        try? ToolTipService.setToolTip(home, Words.t("Home"))
        home.pointerEntered.addHandler { [weak self] _, _ in self?.homeHovering = true; self?.paintHome() }
        home.pointerExited.addHandler { [weak self] _, _ in self?.homeHovering = false; self?.paintHome() }
        home.pointerPressed.addHandler { _, args in args?.handled = true }
        // Home comes to the front; in front, a click on Bezzle's name opens the Bezzle menu, which
        // on Windows, without a menu bar, hangs from it. A right click opens it from anywhere.
        home.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Tabs.shared.selectedID == nil { self.openBezzleMenu() } else { Tabs.shared.showHome() }
                }
            }
        }
        home.rightTapped.addHandler { [weak self] _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.openBezzleMenu() } }
        }
        root.children.append(home)

        plus.hoverWash = 0.07
        plus.box.width = Self.plusSize
        plus.box.height = Self.plusSize
        plus.box.child = Glyphs.view(Glyphs.plus(), size: Self.plusSize, brush: Theme.ink(2))
        try? ToolTipService.setToolTip(plus.box, Words.t("New Design  Ctrl+N"))
        try? Canvas.setTop(plus.box, (Self.height - Self.plusSize) / 2)
        root.children.append(plus.box)
    }

    // MARK: Where it is

    /// The bar's holder the strip is in (WinUI's own wrappers do not tell one element from another).
    private weak var holder: Border?

    /// Puts the strip in the bar of what is in front.
    func place(in holder: Border) {
        guard holder !== self.holder else { return }
        self.holder?.child = nil
        holder.child = root
        self.holder = holder
    }

    /// The bar's room for the tabs changed: they are laid out again, at once.
    func setRoom(_ room: Double) {
        guard abs(room - self.room) > 0.5 else { return }
        self.room = room
        layout(animated: placedOnce)
    }

    // MARK: The tabs as they are

    /// The open designs, which is in front, their names and marks: shown as they are now.
    func update() {
        let designs = Tabs.shared.designs
        // Gone: on their way out, where they were.
        for view in views where !designs.contains(where: { $0.id == view.id }) {
            view.going = true
            view.shown.target = 0
            leaving.append(view)
        }
        views = designs.map { tab in
            if let view = views.first(where: { $0.id == tab.id }) { return view }
            let view = TabView(id: tab.id, strip: self)
            root.children.append(view.box)
            return view
        }
        let front = Tabs.shared.selectedID
        for (view, tab) in zip(views, designs) {
            view.show(name: tab.name, mark: tab.mark, selected: tab.id == front, renaming: tab.renaming)
        }
        paintHome()
        layout(animated: placedOnce)
        placedOnce = true
    }

    private func paintHome() {
        let front = Tabs.shared.selectedID == nil
        home.background = !front && homeHovering ? Theme.brush(Theme.ink, 0.05) : Theme.clear
    }

    /// How wide `s` is, set as given.
    static func measure(_ s: String, size: Double, weight: UInt16, serif: Bool = false) -> Double {
        let t = Theme.text(s, size: size, weight: weight, serif: serif)
        try? t.measure(Size(width: 10000, height: 100))
        return Double(t.desiredSize.width)
    }

    /// Where everything goes: home, then each tab as wide as `widths` says, then plus.
    private func layout(animated: Bool) {
        homeWidth = (Self.measure("Bezzle", size: 15, weight: 600, serif: true) + 20).rounded(.up)
        home.width = homeWidth
        let selected = views.firstIndex { $0.selected }
        let natural = views.map(\.natural)
        let row = Self.widths(natural, selected: selected, button: Self.plusSize, spacing: Self.spacing,
                              room: room.isFinite ? room - homeWidth - Self.homeGap : nil)
        var x = homeWidth + Self.homeGap
        for (k, view) in views.enumerated() {
            view.base = x
            view.w.target = row[k]
            view.x.target = x + othersOffset(at: k)
            if !view.placed || !animated {
                view.placed = true
                view.x = DeckSpring(view.x.target)
                view.w = DeckSpring(view.w.target)
                if !animated { view.shown = DeckSpring(1) }
            }
            x += row[k] + Self.spacing
        }
        plusX.target = views.isEmpty ? homeWidth + Self.homeGap : x
        if let selected {
            cardX.target = views[selected].x.target
            cardW.target = row[selected]
        } else {
            cardX.target = 0
            cardW.target = homeWidth
        }
        if !animated {
            plusX = DeckSpring(plusX.target)
            cardX = DeckSpring(cardX.target)
            cardW = DeckSpring(cardW.target)
        }
        frame(0)
        tick()
    }

    /// The tabs' widths, then the button's, as the Mac's TabRow lays them: each as wide as its
    /// name and the one in front at full width; when they are too many for the room, the longest
    /// names give way first, down to a few letters each, and only then the tab in front.
    static func widths(_ natural: [Double], selected: Int?, button: Double, spacing: Double, room: Double?) -> [Double] {
        var tabs = natural.map { min(widest, $0.rounded(.up)) }
        if let selected, tabs.indices.contains(selected) { tabs[selected] = widest }
        guard let room, room.isFinite else { return tabs + [button] }
        let available = room - button - spacing * Double(tabs.count)
        guard tabs.reduce(0, +) > available else { return tabs + [button] }
        let others = tabs.indices.filter { $0 != selected }
        let front = selected != nil ? widest : 0
        let cap = max(narrowest, level(others.map { tabs[$0] }, filling: available - front))
        for i in others { tabs[i] = min(tabs[i], cap) }
        if let selected, tabs.indices.contains(selected) {
            tabs[selected] = max(narrowest, min(widest, available - others.reduce(0) { $0 + tabs[$1] }))
        }
        return tabs + [button]
    }

    /// How wide the widest may be for all of them to fill `room`, the narrower keeping their width.
    private static func level(_ widths: [Double], filling room: Double) -> Double {
        var remaining = room, left = Double(widths.count)
        for width in widths.sorted() {
            if width * left <= remaining {
                remaining -= width
                left -= 1
            } else {
                return (remaining / left).rounded(.down)
            }
        }
        return .infinity
    }

    // MARK: Moving a tab

    /// The tabs whose middle the dragged one's leading edge has passed, which step aside for it:
    /// its right edge going right, its left edge going left.
    private func passed(by drag: Drag) -> (right: Int, left: Int) {
        guard views.indices.contains(drag.from) else { return (0, 0) }
        let left = views[drag.from].base + drag.offset
        let right = left + views[drag.from].w.target
        let count = views.count
        let passedRight = drag.offset > 0 ? (drag.from + 1..<max(drag.from + 1, count)).filter { right > views[$0].base + views[$0].w.target / 2 }.count : 0
        let passedLeft = drag.offset < 0 ? (0..<drag.from).filter { left < views[$0].base + views[$0].w.target / 2 }.count : 0
        return (passedRight, passedLeft)
    }

    /// How far a tab steps aside for the one being dragged.
    private func othersOffset(at index: Int) -> Double {
        guard let drag, drag.moved, views.indices.contains(drag.from), index != drag.from else { return 0 }
        let (right, left) = passed(by: drag)
        let step = views[drag.from].w.target + Self.spacing
        if index > drag.from, index <= drag.from + right { return -step }
        if index < drag.from, index >= drag.from - left { return step }
        return 0
    }

    fileprivate func pressed(_ view: TabView, _ args: PointerRoutedEventArgs?) {
        let point = try? args?.getCurrentPoint(root)
        guard let args, let point, point.properties?.isLeftButtonPressed == true,
              let index = views.firstIndex(where: { $0 === view }) else { return }
        args.handled = true
        // The pointer is taken once the tab is dragged, not now: what is in front changes under
        // it first, the strip going into another page's bar.
        drag = Drag(id: view.id, from: index, pointer: args.pointer, startX: Double(point.position.x))
        // Down, the tab comes to the front at once, after the press.
        guard !view.selected, let tab = Tabs.shared.designs.first(where: { $0.id == view.id }) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { Tabs.shared.select(tab) } }
    }

    fileprivate func moved(_ view: TabView, _ args: PointerRoutedEventArgs?) {
        guard var d = drag, d.id == view.id, let x = (try? args?.getCurrentPoint(root))?.position.x else { return }
        let dx = Double(x) - d.startX
        if !d.moved, abs(dx) < 4 { return }
        // The button may have come up away from the tab, unseen.
        guard GetAsyncKeyState(Int32(VK_LBUTTON)) < 0 else { drag = nil; return }
        if !d.moved { _ = try? view.box.capturePointer(args?.pointer) }
        d.moved = true
        // As far as the first tab's left edge and the last one's right, no further.
        guard let lastView = views.last, views.indices.contains(d.from) else { return }
        let first = views[0].base, start = views[d.from].base
        d.offset = min(max(dx, first - start), lastView.base + lastView.w.target - start - views[d.from].w.target)
        drag = d
        for (k, other) in views.enumerated() where k != d.from { other.x.target = other.base + othersOffset(at: k) }
        view.x = DeckSpring(start + d.offset)
        frame(0)
        tick()
    }

    /// The tab lost the pointer: as the strip went into the bar of the tab just brought to the
    /// front, with the button still down, it takes it again and the drag goes on; else it is let go.
    fileprivate func lostCapture(_ view: TabView) {
        guard let d = drag, d.id == view.id, d.moved else { return }
        // After the event, which WinUI may send while it changes what is on screen.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.drag?.id == view.id else { return }
                if GetAsyncKeyState(Int32(VK_LBUTTON)) < 0, (try? view.box.capturePointer(d.pointer)) == true { return }
                self.released(view)
            }
        }
    }

    fileprivate func released(_ view: TabView) {
        guard let d = drag, d.id == view.id else { return }
        drag = nil
        guard d.moved else { return }
        if let pointer = d.pointer { try? view.box.releasePointerCapture(pointer) }
        // The dragged tab settles into the place it was let go at.
        let (right, left) = passed(by: d)
        Tabs.shared.move(id: d.id, to: d.from + right - left)
    }

    // MARK: Menus

    fileprivate func openMenu(for view: TabView, at point: CGPoint) {
        guard let tab = Tabs.shared.designs.first(where: { $0.id == view.id }), let menus = menus() else { return }
        let tabs = Tabs.shared
        var entries: [MenuHost.Entry] = []
        if tab.slot != nil {
            entries.append(.item(Words.t("Rename"), enabled: tab.mayRename) {
                tabs.select(tab)
                tabs.beginRenaming(tab)
            })
            entries.append(.item(Words.t("Show in Explorer")) { if let url = tab.slot?.url { Explorer.show(url) } })
            entries.append(.separator)
        }
        entries.append(.item(Words.t("Close Tab"), shortcut: tabs.selectedID == tab.id ? "Ctrl+W" : nil) { tabs.close(tab) })
        entries.append(.item(Words.t("Close Other Tabs"), enabled: tabs.designs.count > 1) { tabs.closeOthers(than: tab) })
        menus.show(at: point, width: 220, entries: entries)
    }

    private func openBezzleMenu() {
        guard let menus = menus() else { return }
        let spelling = Tabs.shared.selected?.view?.canvas.spellingEntries() ?? []
        menus.show(below: home, width: 260, entries: Bar.appEntries(front: Tabs.shared.selected?.slot?.url, spelling: spelling))
    }

    /// Where a point of the strip is in what is in front, for a menu to open there.
    fileprivate func pointInPage(_ args: RightTappedRoutedEventArgs?, of view: TabView) -> CGPoint {
        let p = (try? args?.getPosition(menus()?.layer))
        return CGPoint(x: Double(p?.x ?? 0), y: Double(p?.y ?? 0))
    }

    // MARK: Motion

    /// Frame by frame while anything is on its way.
    private func tick() {
        guard ticking == nil, moving else { return }
        last = WindowsCore.now
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = WindowsCore.now, dt = min(now - self.last, 1.0 / 30)
                self.last = now
                self.frame(dt)
                if !self.moving {
                    self.ticking?.dispose()
                    self.ticking = nil
                }
            }
        }
    }

    private var moving: Bool {
        !cardX.settled || !cardW.settled || !plusX.settled || !leaving.isEmpty
            || views.contains { !$0.x.settled || !$0.w.settled || !$0.shown.settled }
    }

    /// Each spring a step on, and everything placed where it is now.
    private func frame(_ dt: Double) {
        let (k, c) = Self.spring
        cardX.step(dt, stiffness: k, damping: c)
        cardW.step(dt, stiffness: k, damping: c)
        plusX.step(dt, stiffness: k, damping: c)
        var extent = homeWidth
        for view in views + leaving {
            if drag?.moved != true || drag?.id != view.id { view.x.step(dt, stiffness: k, damping: c) }
            view.w.step(dt, stiffness: k, damping: c)
            view.shown.step(dt, stiffness: k, damping: c)
            view.place()
            extent = max(extent, view.x.value + view.w.value)
        }
        for view in leaving where view.shown.value < 0.02 && view.shown.target == 0 {
            var at: UInt32 = 0
            if (try? root.children.indexOf(view.box, &at)) == true { root.children.removeAt(at) }
        }
        leaving.removeAll { $0.shown.value < 0.02 && $0.shown.target == 0 }
        // The card follows the tab in front, also while it is dragged.
        if let front = views.first(where: { $0.selected }) {
            try? Canvas.setLeft(card, front.x.value)
            card.width = max(0, front.w.value)
        } else {
            try? Canvas.setLeft(card, cardX.value)
            card.width = max(0, cardW.value)
        }
        if drag?.moved != true, let front = views.first(where: { $0.selected }) {
            // Keeps its spring going where the tab is, for when home comes to the front.
            cardX.value = front.x.value
            cardW.value = front.w.value
        }
        try? Canvas.setLeft(plus.box, plusX.value)
        extent = max(extent, plusX.value + Self.plusSize, plusX.target + Self.plusSize)
        root.width = extent.rounded(.up)
    }

    /// The Mac's Theme.spring (response 0.34 s, damping fraction 0.86) as stiffness and damping.
    static let spring: (stiffness: Double, damping: Double) = {
        let w = 2 * Double.pi / 0.34
        return (w * w, 2 * 0.86 * w)
    }()
}

/// One design's tab: its name, a mark when it is shared, and a cross to close it, which shows on
/// the tab in front and on the one pointed at (the Mac's TabButton).
@MainActor
private final class TabView {
    let id: UUID
    let box = Border()
    private let content = Grid()
    private let words = StackPanel()
    private let name = TextBlock()
    private var markView: FrameworkElement?
    private let cross = Border()
    private let crossGlyph: FrameworkElement
    private let pose = CompositeTransform()
    private weak var strip: TabStrip?
    private var field: TextBox?

    var x = DeckSpring(0), w = DeckSpring(0)
    /// Coming in (0 to 1) or going (1 to 0).
    var shown = DeckSpring(0)
    /// Where it lies along the row, not counting a drag.
    var base = 0.0
    var placed = false
    var going = false
    private(set) var selected = false
    private(set) var natural = 0.0
    private var hovering = false
    private var crossHovering = false
    private var shownName = ""
    private var shownMark: WindowsCore.ShareMark?
    private var renaming = false

    init(id: UUID, strip: TabStrip) {
        self.id = id
        self.strip = strip
        shown.target = 1
        box.height = TabStrip.height
        box.cornerRadius = Theme.corners(9)
        box.background = Theme.clear
        box.renderTransform = pose
        box.renderTransformOrigin = Point(x: 0, y: 0.5)
        words.orientation = .horizontal
        words.spacing = 5
        words.verticalAlignment = .center
        words.horizontalAlignment = .left
        words.margin = Theme.inset(12, 0, 0, 0)
        name.fontFamily = Theme.ui
        name.fontSize = 12.5
        name.textTrimming = .characterEllipsis
        name.textWrapping = .noWrap
        name.verticalAlignment = .center
        words.children.append(name)
        content.children.append(words)

        cross.width = 18
        cross.height = 18
        cross.cornerRadius = Theme.corners(9)
        cross.horizontalAlignment = .right
        cross.verticalAlignment = .center
        cross.margin = Theme.inset(0, 0, 6, 0)
        crossGlyph = Glyphs.view(Glyphs.cross(), size: 18, brush: Theme.ink(3))
        cross.child = crossGlyph
        cross.opacity = 0
        try? ToolTipService.setToolTip(cross, Words.t("Close Tab  Ctrl+W"))
        cross.pointerEntered.addHandler { [weak self] _, _ in self?.crossHovering = true; self?.paint() }
        cross.pointerExited.addHandler { [weak self] _, _ in self?.crossHovering = false; self?.paint() }
        // Its own press, so the tab is neither dragged nor brought forward by it.
        cross.pointerPressed.addHandler { _, args in args?.handled = true }
        let id = id
        cross.tapped.addHandler { [weak self] _, args in
            args?.handled = true
            guard self?.cross.opacity ?? 0 > 0.5 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let tab = Tabs.shared.designs.first(where: { $0.id == id }) { Tabs.shared.close(tab) }
                }
            }
        }
        content.children.append(cross)
        box.child = content

        box.pointerEntered.addHandler { [weak self] _, _ in self?.hovering = true; self?.paint() }
        box.pointerExited.addHandler { [weak self] _, _ in self?.hovering = false; self?.paint() }
        box.pointerPressed.addHandler { [weak self] _, args in
            guard let self, !self.renaming else { return }
            self.strip?.pressed(self, args)
        }
        box.pointerMoved.addHandler { [weak self] _, args in
            guard let self else { return }
            self.strip?.moved(self, args)
        }
        box.pointerReleased.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.strip?.released(self)
        }
        box.pointerCaptureLost.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.strip?.lostCapture(self)
        }
        // A second click renames the design, as on the Mac.
        box.doubleTapped.addHandler { [weak self] _, args in
            args?.handled = true
            guard let self, !self.renaming else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let tab = Tabs.shared.designs.first(where: { $0.id == id }), tab.mayRename { Tabs.shared.beginRenaming(tab) }
                }
            }
        }
        box.rightTapped.addHandler { [weak self] _, args in
            args?.handled = true
            guard let self, let strip = self.strip else { return }
            let at = strip.pointInPage(args, of: self)
            DispatchQueue.main.async { MainActor.assumeIsolated { strip.openMenu(for: self, at: at) } }
        }
    }

    /// Shows the tab as its design is now.
    func show(name newName: String, mark: WindowsCore.ShareMark?, selected now: Bool, renaming nowRenaming: Bool) {
        if newName != shownName || mark != shownMark || now != selected {
            shownName = newName
            shownMark = mark
            selected = now
            name.text = newName
            name.fontWeight = FontWeight(weight: now ? 500 : 400)
            try? ToolTipService.setToolTip(box, newName)
            if let markView, let at = index(of: markView) { words.children.removeAt(at) }
            markView = nil
            var markWidth = 0.0
            if let mark {
                let ended = mark == .ended
                let glyph = ended ? Glyphs.lock(locked: true, size: 9) : Glyphs.share(size: 9)
                let view = Glyphs.view(glyph, size: 9, brush: ended ? Theme.ink(3) : Theme.brush(Theme.pencil))
                view.verticalAlignment = .center
                words.children.insertAt(0, view)
                markView = view
                markWidth = 9 + 5
            }
            natural = TabStrip.measure(newName, size: 12.5, weight: now ? 500 : 400) + 12 + (now ? 26 : 12) + markWidth
        }
        if nowRenaming != renaming {
            renaming = nowRenaming
            if renaming { beginRenaming() } else { endRenaming() }
        }
        paint()
    }

    private func index(of element: UIElement) -> UInt32? {
        var at: UInt32 = 0
        return (try? words.children.indexOf(element, &at)) == true ? at : nil
    }

    /// Where it is now, and how wide; its words as they fit.
    func place() {
        try? Canvas.setLeft(box, x.value)
        box.width = max(0, w.value)
        // Coming in it grows from its leading edge, as on the Mac; going, it shrinks a little.
        let s = going ? 0.85 + 0.15 * shown.value : 0.6 + 0.4 * min(shown.value, 1.2)
        pose.scaleX = s
        pose.scaleY = s
        box.opacity = min(max(shown.value, 0), 1)
        box.isHitTestVisible = !going
        let markWidth = markView == nil ? 0.0 : 14
        let room = max(0, w.value - 12 - (selected && !renaming ? 26 : 12) - markWidth)
        name.maxWidth = room
        field?.width = max(0, w.value - 12 - 12)
        let showsCross = (selected || hovering) && w.value >= 56 && !renaming
        cross.opacity = showsCross ? 1 : 0
        cross.isHitTestVisible = showsCross
        // Over a tab not in front, the cross lies over the end of the name, which fades under it.
        if showsCross && !selected {
            name.width = room
            name.foreground = fade(over: room)
        } else {
            name.width = .nan
            name.foreground = selected || hovering ? Theme.ink(1) : Theme.ink(2)
        }
    }

    /// The name's ink, fading out over the last 22 points of its room, where the cross lies.
    private func fade(over room: Double) -> Brush {
        guard room > 24 else { return Theme.ink(1) }
        let brush = LinearGradientBrush()
        brush.startPoint = Point(x: 0, y: 0.5)
        brush.endPoint = Point(x: 1, y: 0.5)
        for (offset, alpha) in [(0.0, 1.0), ((room - 22) / room, 1.0), ((room - 12) / room, 0.0), (1.0, 0.0)] {
            let stop = GradientStop()
            stop.offset = offset
            stop.color = Theme.color(Theme.ink, alpha)
            brush.gradientStops.append(stop)
        }
        return brush
    }

    private func paint() {
        box.background = !selected && hovering ? Theme.brush(Theme.ink, 0.05) : Theme.clear
        cross.background = crossHovering ? Theme.brush(Theme.ink, 0.08) : Theme.clear
        Glyphs.paint(crossGlyph, crossHovering ? Theme.ink(1) : Theme.ink(3))
        place()
    }

    // MARK: Renaming

    private func beginRenaming() {
        let box = TextBox()
        box.allowFocusOnInteraction = true
        box.text = shownName
        box.fontFamily = Theme.ui
        box.fontSize = 12.5
        box.fontWeight = FontWeight(weight: 500)
        // Wrapping, so a focused one-line field shows no clear button.
        box.textWrapping = .wrap
        box.acceptsReturn = false
        box.minWidth = 0
        box.minHeight = 0
        box.height = 24
        box.padding = Theme.inset(0, 3, 0, 0)
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        box.background = Theme.clear
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        box.margin = Theme.inset(12, 0, 12, 0)
        box.horizontalAlignment = .left
        let id = id
        var done = false
        func finish(_ keep: Bool) {
            guard !done else { return }
            done = true
            let typed = box.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let tab = Tabs.shared.designs.first(where: { $0.id == id }) else { return }
                    Tabs.shared.endRenaming(tab, to: keep ? typed : nil)
                }
            }
        }
        box.keyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; finish(true) }
            if args.key == .escape { args.handled = true; finish(false) }
        }
        // Typed into until the focus goes elsewhere in the window; another window coming up
        // leaves it to go on with, as on the Mac.
        box.name = "tab-rename-\(id.uuidString)"
        box.lostFocus.addHandler { sender, _ in
            if let field = sender as? TextBox, let root = field.xamlRoot,
               let focused = (try? FocusManager.getFocusedElement(root)) as? TextBox, focused.name == field.name { return }
            finish(true)
        }
        box.loaded.addHandler { sender, _ in
            guard let field = sender as? TextBox else { return }
            _ = try? field.focus(.programmatic)
            try? field.selectAll()
        }
        words.visibility = .collapsed
        content.children.append(box)
        field = box
        place()
    }

    private func endRenaming() {
        guard let field else { return }
        var at: UInt32 = 0
        if (try? content.children.indexOf(field, &at)) == true { content.children.removeAt(at) }
        self.field = nil
        words.visibility = .visible
        place()
    }
}
