import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The margin on Windows, as the Mac's NotesLayer: every thread of notes beside the sheet it is
/// about, on free table, a card when there is room and a flag on the sheet's edge when there is
/// not, its pin on what it is about and a pencil thread from the pin to the card. Where each goes
/// and how it moves is the core's (`WindowsCore.NotesHand`); here each card is an element kept
/// for its thread and made again only when what it shows changes, so what is typed in it stays.
@MainActor
final class MarginView {
    let layer = Canvas()
    let notes: WindowsCore.NotesHand
    private let ink = Canvas()
    /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage.
    var view: () -> (zoom: Double, pan: CGPoint) = { (1, .zero) }
    /// The layer at a canvas point, for a pin let go of there.
    var layerAt: (CGPoint) -> UUID? = { _ in nil }
    /// A step made: the design is drawn again and kept.
    var edited: () -> Void = {}
    /// The view brought to a canvas point, to show a thread.
    var reveal: (CGPoint) -> Void = { _ in }
    /// The keys back to the canvas, once a note is posted.
    var returnFocus: () -> Void = {}
    var menus: MenuHost?
    var readOnly = false

    private var cards: [UUID: Card] = [:]
    private var flags: [UUID: Border] = [:]
    private var pins: [UUID: Grid] = [:]
    private var heights: [UUID: BezzleCore.CGFloat] = [:]
    private var drag: WindowsCore.NotesHand.Drag?
    private var pointed: UUID?
    private var ticking: EventCleanup?
    private var lineCache: [String: Int] = [:]

    /// A card and what it showed when it was made, to know when to make it again.
    private final class Card {
        let box = Border()
        let holder = Grid()
        let move = CompositeTransform()
        var signature = ""
        var answer: TextBox?
        var draft: TextBox?
        var change: TextBox?
        /// Starts changing the words of one of its notes, from the note's menu.
        var changers: [UUID: @MainActor () -> Void] = [:]
    }

    init(notes: WindowsCore.NotesHand) {
        self.notes = notes
        layer.children.append(ink)
        ink.isHitTestVisible = false
        notes.redraw = { [weak self] in self?.draw() }
        // How many lines words take on a card, as the card sets them, and how tall a line is.
        let probe = TextBlock()
        probe.fontFamily = Theme.ui
        probe.fontSize = Double(WindowsCore.NotesHand.textSize)
        probe.text = "Ag"
        try? probe.measure(Size(width: 1000, height: 1000))
        let line = max(Double(probe.desiredSize.height), 14)
        notes.lineHeight = line
        notes.lines = { [weak self] text, limit in
            let key = "\(limit ?? 0)|" + text
            if let n = self?.lineCache[key] { return n }
            let t = TextBlock()
            t.fontFamily = Theme.ui
            t.fontSize = Double(WindowsCore.NotesHand.textSize)
            t.textWrapping = .wrap
            t.lineHeight = line + Double(WindowsCore.NotesHand.leading)
            t.text = text
            try? t.measure(Size(width: Float(WindowsCore.NotesHand.measure), height: 10_000))
            var n = max(1, Int((Double(t.desiredSize.height) / (line + Double(WindowsCore.NotesHand.leading))).rounded()))
            if let limit { n = min(n, limit) }
            self?.lineCache[key] = n
            return n
        }
    }

    // MARK: Drawing

    /// The margin as it is now; while something in it moves, again each frame.
    func draw() {
        let (zoom, pan) = view()
        let scene = notes.scene(zoom: BezzleCore.CGFloat(zoom), pan: pan, heights: heights, drag: drag, pointed: pointed)
        ink.children.clear()
        var kept = Set<UUID>(), keptFlags = Set<UUID>(), keptPins = Set<UUID>()
        for s in scene.ghosts {
            drawGhost(s)
            // A card going folds away where it is, faded: ticked off, or taken away.
            if (s.kind == "card" || s.kind == "lifted") && !s.turned, !scene.shown.contains(where: { $0.id == s.id }) {
                place(card: s)
                kept.insert(s.id)
            }
        }
        for s in scene.shown {
            drawInk(s)
            switch s.kind {
            case "card", "lifted":
                place(card: s)
                kept.insert(s.id)
            case "flag":
                place(flag: s)
                keptFlags.insert(s.id)
            default:
                break
            }
            place(pin: s)
            keptPins.insert(s.id)
        }
        if let circle = scene.circle, circle.width > 0 || circle.height > 0 { loop(circle, seed: 7, colour: Theme.pencil, alpha: 0.95, drawn: 1) }
        for (id, card) in cards where !kept.contains(id) {
            remove(card.box)
            cards[id] = nil
        }
        for (id, flag) in flags where !keptFlags.contains(id) {
            remove(flag)
            flags[id] = nil
        }
        for (id, pin) in pins where !keptPins.contains(id) {
            remove(pin)
            pins[id] = nil
        }
        // The pins over everything, an open card too: always there to be pulled elsewhere.
        for pin in pins.values { bringToFront(pin) }
        if notes.moving { keepMoving() }
    }

    private func keepMoving() {
        guard ticking == nil else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.notes.moving { self.draw() } else {
                    self.ticking?.dispose()
                    self.ticking = nil
                    self.draw()
                }
            }
        }
    }

    private func remove(_ e: UIElement) {
        var k: UInt32 = 0
        if (try? layer.children.indexOf(e, &k)) == true { layer.children.removeAt(k) }
    }

    private func bringToFront(_ e: UIElement) {
        var k: UInt32 = 0
        guard (try? layer.children.indexOf(e, &k)) == true, k + 1 < layer.children.size else { return }
        layer.children.removeAt(k)
        layer.children.append(e)
    }

    // MARK: Ink

    private func path(_ d: String, width: Double) -> WinUI.Path? {
        (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d)' StrokeThickness='\(width)' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>")) as? WinUI.Path
    }

    /// A thread in its writer's pencil over the paper's own white edge.
    private func stroke(_ curve: WindowsCore.FlowCurve, colour: UInt32, lit: Bool, alpha: Double) {
        let d = curve.data
        if let casing = path(d, width: lit ? 4.2 : 3.4) {
            casing.stroke = Theme.brush(Theme.dark ? 0x1B1A18 : 0xFFFFFF, (Theme.dark ? 0.35 : 0.85) * alpha)
            ink.children.append(casing)
        }
        if let line = path(d, width: lit ? 1.5 : 1.1) {
            line.stroke = Theme.brush(colour, (lit ? 0.95 : 0.62) * alpha)
            ink.children.append(line)
        }
    }

    /// The hand loop round a part, drawn as far as `drawn`.
    private func loop(_ r: CGRect, seed: UInt64, colour: UInt32, alpha: Double, drawn: Double) {
        guard drawn > 0, alpha > 0 else { return }
        let points = WindowsCore.NotesHand.loop(around: r, seed: seed)
        let n = max(1, Int(Double(points.count - 1) * min(drawn, 1)))
        // In three lengths, finer where the pencil lands and lifts.
        var d = PathData()
        for i in 0..<n where i + 1 < points.count {
            d.move(Double(points[i].0.x), Double(points[i].0.y))
            d.line(Double(points[i + 1].0.x), Double(points[i + 1].0.y))
        }
        if let line = path(d.d, width: 1.8) {
            line.stroke = Theme.brush(colour, alpha)
            ink.children.append(line)
        }
    }

    private func drawInk(_ s: WindowsCore.NotesHand.Shown) {
        let ease = WindowsCore.NotesHand.ease, out = WindowsCore.NotesHand.out
        if let area = s.area {
            loop(area, seed: WindowsCore.NotesHand.seed(s.id), colour: s.item.colour, alpha: s.lit ? 0.95 : 0.5, drawn: s.turned ? 1 : ease(s.born / 0.45))
        }
        // A flag's thread shows only while it is pointed at: across the work, it would be in the way.
        let shows = s.kind == "card" || s.kind == "lifted" || (s.kind == "flag" && s.lit)
        guard shows else { return }
        var curve = WindowsCore.NotesHand.thread(from: s.pin, to: s.anchor, sag: s.sag)
        let drawn = s.turned ? out(s.born / 0.6) : ease((s.born - 0.1) / 0.42)
        guard drawn > 0.001 else { return }
        if drawn < 1 { curve = curve.upTo(BezzleCore.CGFloat(drawn)) }
        stroke(curve, colour: s.item.colour, lit: s.lit, alpha: s.item.done ? 0.5 : 1)
    }

    private func drawGhost(_ s: WindowsCore.NotesHand.Shown) {
        let ease = WindowsCore.NotesHand.ease, out = WindowsCore.NotesHand.out
        let p = s.leaving ?? 1
        let reel = s.tickedOff ? ease((p - 0.3) / 0.45) : ease(p / 0.8)
        let fade = s.tickedOff ? 1 - ease((p - 0.55) / 0.4) : 1 - ease(p)
        if s.turned {
            if s.kind == "card" || s.kind == "lifted" {
                stroke(WindowsCore.NotesHand.thread(from: s.pin, to: s.anchor, sag: s.sag).upTo(BezzleCore.CGFloat(1 - out(p))),
                       colour: s.item.colour, lit: false, alpha: 1 - p)
            }
            return
        }
        if let area = s.area { loop(area, seed: WindowsCore.NotesHand.seed(s.id), colour: s.item.colour, alpha: 0.5 * fade, drawn: 1) }
        if s.kind == "card" || s.kind == "lifted", reel < 0.999 {
            stroke(WindowsCore.NotesHand.thread(from: s.pin, to: s.anchor, sag: s.sag).upTo(BezzleCore.CGFloat(1 - reel)),
                   colour: s.item.colour, lit: false, alpha: 1)
        }
        // The pin goes, and where a thread was ticked off, a small tick stays a moment.
        let gone = s.tickedOff ? ease((p - 0.55) / 0.3) : ease(p / 0.6)
        if gone < 1 {
            let r = 5.5 * (1 - gone)
            let dot = Ellipse()
            dot.width = 2 * r
            dot.height = 2 * r
            dot.fill = Theme.brush(0xFFFFFF)
            dot.stroke = Theme.brush(s.item.colour)
            dot.strokeThickness = 1.6
            try? Canvas.setLeft(dot, Double(s.pin.x) - r)
            try? Canvas.setTop(dot, Double(s.pin.y) - r)
            ink.children.append(dot)
        }
        if s.tickedOff {
            let t = (p - 0.6) / 0.4
            if t > 0 {
                let o = (x: Double(s.pin.x) - 6, y: Double(s.pin.y) - 3)
                var d = PathData()
                d.move(o.x, o.y + 3); d.line(o.x + 4, o.y + 7); d.line(o.x + 12, o.y - 3)
                if let tick = path(d.d, width: 2) {
                    tick.stroke = Theme.brush(Theme.pencil)
                    tick.opacity = 1 - ease((t - 0.5) / 0.5)
                    ink.children.append(tick)
                }
            }
        }
    }

    // MARK: Pins

    private func place(pin s: WindowsCore.NotesHand.Shown) {
        let id = s.id
        let pin: Grid
        if let p = pins[id] { pin = p } else {
            pin = Grid()
            pin.background = Theme.clear
            pin.width = 26
            pin.height = 26
            let transform = CompositeTransform()
            transform.centerX = 13
            transform.centerY = 13
            pin.renderTransform = transform
            hookUpPin(pin, id: id)
            layer.children.append(pin)
            pins[id] = pin
        }
        pin.children.clear()
        if s.kind == "pin" {
            // On the table with no room for its card: their token.
            pin.children.append(token(s.item.notes.first, size: 20, ring: true))
        } else {
            let d = s.area == nil ? 11.0 : 9.0
            let dot = Ellipse()
            dot.width = d
            dot.height = d
            dot.fill = Theme.brush(0xFFFFFF)
            dot.stroke = Theme.brush(s.item.colour, s.item.done ? 0.5 : 1)
            dot.strokeThickness = 1.6
            pin.children.append(dot)
            let core = Ellipse()
            core.width = 3.5
            core.height = 3.5
            core.fill = Theme.brush(s.item.colour, s.item.done ? 0.5 : 1)
            pin.children.append(core)
        }
        try? Canvas.setLeft(pin, Double(s.pin.x) - 13)
        try? Canvas.setTop(pin, Double(s.pin.y) - 13)
        // Dropping in, with a little give; bigger while pulled or pointed at.
        let pop = s.born >= 1 || s.turned ? 1 : Self.pop(s.born / 0.38)
        if let t = pin.renderTransform as? CompositeTransform {
            t.scaleX = pop * (s.dragged ? 1.4 : s.lit ? 1.22 : 1)
            t.scaleY = t.scaleX
        }
        pin.opacity = s.leaving == nil ? 1 : 0
        if let first = s.item.notes.first { try? ToolTipService.setToolTip(pin, "\(first.by): \(first.text)") }
    }

    /// Dropping in, with a little give.
    private static func pop(_ t: Double) -> Double {
        let t = min(max(t, 0), 1), c = 1.9
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }

    /// Pointed at, its thread lights; clicked, it opens; pulled, it takes its thread to another spot.
    private func hookUpPin(_ pin: Grid, id: UUID) {
        final class Hold { var at: Point?; var moved = false }
        let hold = Hold()
        pin.pointerEntered.addHandler { [weak self] _, _ in
            self?.pointed = id
            self?.draw()
        }
        pin.pointerExited.addHandler { [weak self] _, _ in
            if self?.pointed == id { self?.pointed = nil }
            self?.draw()
        }
        pin.pointerPressed.addHandler { [weak self] _, args in
            guard let self, let p = try? args?.getCurrentPoint(self.layer)?.position else { return }
            args?.handled = true
            hold.at = p
            hold.moved = false
            _ = try? pin.capturePointer(args?.pointer)
        }
        pin.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let start = hold.at, !self.readOnly, id != self.notes.draftID,
                  let p = try? args?.getCurrentPoint(self.layer)?.position else { return }
            let by = CGSize(width: Double(p.x - start.x), height: Double(p.y - start.y))
            guard hold.moved || hypot(Double(by.width), Double(by.height)) > 3 else { return }
            hold.moved = true
            var d = self.drag?.id == id ? self.drag! : WindowsCore.NotesHand.Drag(id: id, by: .zero)
            d.by = by
            self.drag = d
            self.draw()
        }
        pin.pointerReleased.addHandler { [weak self] _, args in
            guard let self, hold.at != nil else { return }
            hold.at = nil
            try? pin.releasePointerCaptures()
            if hold.moved, let d = self.drag, d.id == id, let spot = self.notes.spot(of: id) {
                self.drag = nil
                let zoom = self.view().zoom
                let p = CGPoint(x: Double(spot.spot.x) + Double(d.by.width) / zoom, y: Double(spot.spot.y) + Double(d.by.height) / zoom)
                self.notes.move(id, to: p, on: spot.loop ? nil : (self.layerAt(p) ?? WindowsCore.boardID(at: p)))
                self.edited()
            } else if !hold.moved, id != self.notes.draftID {
                self.notes.toggle(id)
            }
            self.draw()
        }
        pin.rightTapped.addHandler { [weak self] _, args in
            guard let self, let menus = self.menus, let p = try? args?.getPosition(menus.layer) else { return }
            args?.handled = true
            self.showMenu(id, at: CGPoint(x: Double(p.x), y: Double(p.y)))
        }
    }

    // MARK: Flags

    /// A thread where there is no room for its card: a flag stuck to the sheet's edge, level with
    /// its spot, in its writer's pencil; paler once read, and ticked once ticked off.
    private func place(flag s: WindowsCore.NotesHand.Shown) {
        let id = s.id
        let flag: Border
        if let f = flags[id] { flag = f } else {
            flag = Border()
            flag.pointerEntered.addHandler { [weak self] _, _ in
                self?.pointed = id
                self?.draw()
            }
            flag.pointerExited.addHandler { [weak self] _, _ in
                if self?.pointed == id { self?.pointed = nil }
                self?.draw()
            }
            flag.pointerPressed.addHandler { _, args in args?.handled = true }
            flag.tapped.addHandler { [weak self] _, _ in
                self?.notes.toggle(id)
            }
            flag.rightTapped.addHandler { [weak self] _, args in
                guard let self, let menus = self.menus, let p = try? args?.getPosition(menus.layer) else { return }
                args?.handled = true
                self.showMenu(id, at: CGPoint(x: Double(p.x), y: Double(p.y)))
            }
            layer.children.append(flag)
            flags[id] = flag
        }
        let f = s.frame, right = s.right
        let appear = s.leaving.map { 1 - WindowsCore.NotesHand.out($0) } ?? WindowsCore.NotesHand.out(s.born / (s.turned ? 1 : 0.5))
        let reach = Double(f.width) + (pointed == id ? 4 : 0)
        let radius = min(Double(f.height) / 2, 6, Double(f.width))
        flag.cornerRadius = right ? CornerRadius(topLeft: 0, topRight: radius, bottomRight: radius, bottomLeft: 0)
                                  : CornerRadius(topLeft: radius, topRight: 0, bottomRight: 0, bottomLeft: radius)
        flag.background = Theme.brush(s.item.colour, s.item.done ? 0.38 : s.item.unread ? 1 : 0.78)
        flag.width = max(0, reach * appear)
        flag.height = Double(f.height)
        if f.width >= 13 {
            let mark = Theme.text(s.item.done ? "✓" : (s.item.notes.first?.initial ?? "•"), size: 10, weight: 700)
            mark.foreground = Theme.brush(0xFFFFFF)
            mark.horizontalAlignment = .center
            flag.child = mark
        } else {
            flag.child = nil
        }
        try? Canvas.setLeft(flag, right ? Double(f.minX) : Double(f.maxX) - reach * appear)
        try? Canvas.setTop(flag, Double(f.minY))
        if let first = s.item.notes.first { try? ToolTipService.setToolTip(flag, "\(first.by): \(first.text)") }
    }

    // MARK: Cards

    /// A writer's initial in their pencil.
    private func token(_ note: WindowsCore.NotesHand.NoteLook?, size: Double, ring: Bool = false, colour: UInt32? = nil) -> FrameworkElement {
        let disc = Border()
        disc.width = size
        disc.height = size
        disc.cornerRadius = Theme.corners(size / 2)
        disc.background = Theme.brush(colour ?? note?.colour ?? Theme.pencil)
        if ring {
            disc.borderBrush = Theme.brush(0xFFFFFF)
            disc.borderThickness = Theme.inset(1.5)
        }
        let letter = Theme.text(note?.initial ?? "•", size: size * 0.55, weight: 700)
        letter.foreground = Theme.brush(0xFFFFFF)
        letter.horizontalAlignment = .center
        disc.child = letter
        return disc
    }

    private func place(card s: WindowsCore.NotesHand.Shown) {
        let id = s.id
        let card = cards[id] ?? {
            let c = Card()
            c.holder.width = WindowsCore.noteCardWidth
            c.box.child = c.holder
            c.box.renderTransform = c.move
            layer.children.append(c.box)
            cards[id] = c
            return c
        }()
        let open = s.item.open || s.item.draft
        let signature = "\(open)|\(s.item.draft)|\(s.item.done)|\(s.item.unread)|\(s.item.notes.map { "\($0.id)\($0.text)" }.joined())|\(notes.reviewCount)|\(s.right)|\(readOnly)"
        if signature != card.signature {
            card.signature = signature
            build(card, s)
        }
        // Shut, as tall as the margin was told it is.
        card.holder.minHeight = open ? 0 : Double(s.frame.height)
        try? Canvas.setLeft(card.box, Double(s.frame.minX))
        try? Canvas.setTop(card.box, Double(s.frame.minY))
        // Coming in: unfolding from where its thread meets it; going: folded away, and faded.
        let toward: Double = s.right ? -1 : 1
        let appear = s.turned ? WindowsCore.NotesHand.out(s.born) : WindowsCore.NotesHand.out((s.born - 0.3) / 0.7)
        var fold = 0.0, fade = 0.0
        if let p = s.leaving {
            fold = s.tickedOff ? WindowsCore.NotesHand.ease((p - 0.3) / 0.5) : WindowsCore.NotesHand.out(p)
            fade = s.tickedOff ? WindowsCore.NotesHand.ease((p - 0.45) / 0.4) : WindowsCore.NotesHand.out(p)
        }
        let grown = (s.turned ? 0.72 + 0.28 * appear : 0.94 + 0.06 * appear) * (1 - (s.turned ? 0.5 : 0.62) * fold)
        card.move.centerX = s.right ? 0 : WindowsCore.noteCardWidth
        card.move.centerY = WindowsCore.noteLineIn
        card.move.scaleX = grown
        card.move.scaleY = grown
        card.move.translateX = toward * (1 - appear) * (s.turned ? 4 : 8)
        card.box.opacity = appear * (1 - fade)
        card.box.isHitTestVisible = s.leaving == nil
        // Open, the margin is told how tall it came out, for the next frame to place it.
        if open {
            try? card.box.measure(Size(width: Float(WindowsCore.noteCardWidth), height: 4000))
            let h = BezzleCore.CGFloat(Double(card.box.desiredSize.height))
            if abs((heights[id] ?? 0) - h) > 0.5 {
                heights[id] = h
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.draw() } }
            }
        } else {
            heights[id] = nil
        }
        // Asked from a menu: the typing into the answer, or into words to change them.
        if let focus = notes.focus {
            switch focus {
            case .answer(let thread) where thread == id:
                notes.focus = nil
                if let field = card.answer { DispatchQueue.main.async { MainActor.assumeIsolated { _ = try? field.focus(.programmatic) } } }
            case .change(let note):
                guard let begin = card.changers[note] else { break }
                notes.focus = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { begin() } }
            default:
                break
            }
        }
    }

    private func build(_ card: Card, _ s: WindowsCore.NotesHand.Shown) {
        let item = s.item, open = item.open || item.draft
        card.box.cornerRadius = Theme.corners(11)
        card.box.background = Theme.brush(Theme.card)
        card.box.borderBrush = Theme.hairline
        card.box.borderThickness = Theme.inset(0.5)
        card.holder.children.clear()
        card.answer = nil
        card.draft = nil
        card.changers = [:]
        card.change = nil
        let stack = StackPanel()
        stack.spacing = 9
        stack.padding = Theme.inset(11, 10, 11, 10)
        let id = s.id
        if item.draft {
            stack.children.append(header(item.notes.first, first: true, item: item, open: true, draft: true))
            let field = writingField(placeholder: Words.t("Write a note"))
            // Found by name: the focused element comes back as a wrapper of its own.
            field.name = "draft"
            field.keyDown.addHandler { [weak self] _, args in
                guard let self, let args else { return }
                if args.key == .enter {
                    args.handled = true
                    if self.notes.post(field.text) { self.edited() }
                    self.returnFocus()
                }
                if args.key == .escape {
                    args.handled = true
                    self.notes.dropDraft()
                    self.returnFocus()
                }
            }
            // Let go of when the pointer goes elsewhere in the window; but a draft just made, which
            // the canvas takes the keys from as the click that made it is let go of, takes them
            // back. Another window coming to the front leaves it as it is, to come back to.
            let made = WindowsCore.now
            field.lostFocus.addHandler { [weak self] _, _ in
                guard let self, self.notes.draftID == id else { return }
                if field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, WindowsCore.now - made < 0.8 {
                    DispatchQueue.main.async { MainActor.assumeIsolated { _ = try? field.focus(.programmatic) } }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.notes.draftID == id, field.xamlRoot != nil else { return }
                        let now = try? FocusManager.getFocusedElement(field.xamlRoot)
                        if now == nil || (now as? FrameworkElement)?.name == field.name { return }
                        if self.notes.post(field.text) { self.edited() }
                    }
                }
            }
            field.loaded.addHandler { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { _ = try? field.focus(.programmatic) } }
            }
            card.draft = field
            stack.children.append(field)
        } else {
            for (k, note) in item.notes.enumerated() {
                if k > 0 {
                    guard open else { break }
                    let rule = Border()
                    rule.height = 0.5
                    rule.background = Theme.hairline
                    stack.children.append(rule)
                }
                stack.children.append(noteView(note, first: k == 0, item: item, open: open, card: card))
            }
            if !open, item.notes.count > 1 { stack.children.append(answered(item)) }
            if open, !readOnly, !item.done {
                let composer = Border()
                composer.cornerRadius = Theme.corners(8)
                composer.background = Theme.brush(Theme.well, 0.6)
                composer.padding = Theme.inset(4, 2, 4, 2)
                let field = writingField(placeholder: Words.t("Answer"))
                field.keyDown.addHandler { [weak self] _, args in
                    guard let self, let args else { return }
                    if args.key == .enter {
                        args.handled = true
                        if self.notes.answer(id, field.text) {
                            field.text = ""
                            self.edited()
                        }
                    }
                    if args.key == .escape {
                        args.handled = true
                        self.notes.openThread = nil
                        self.returnFocus()
                    }
                }
                composer.child = field
                card.answer = field
                stack.children.append(composer)
            }
        }
        card.holder.children.append(stack)
        // The writer's pencil along the card's edge, where the thread comes in.
        let edge = Border()
        edge.width = 2.5
        edge.height = 16
        edge.cornerRadius = Theme.corners(1.25)
        edge.background = Theme.brush(item.colour, item.done ? 0.45 : 1)
        edge.horizontalAlignment = s.right ? .left : .right
        edge.verticalAlignment = .top
        edge.margin = Theme.inset(s.right ? -1.25 : 0, WindowsCore.noteLineIn - 8, s.right ? 0 : -1.25, 0)
        card.holder.children.append(edge)
        card.box.pointerPressed.addHandler { _, args in args?.handled = true }
        card.box.tapped.addHandler { [weak self] _, _ in
            guard let self, !open else { return }
            self.notes.toggle(id)
        }
        card.box.rightTapped.addHandler { [weak self] _, args in
            guard let self, !item.draft, let menus = self.menus, let p = try? args?.getPosition(menus.layer) else { return }
            args?.handled = true
            self.showMenu(id, at: CGPoint(x: Double(p.x), y: Double(p.y)))
        }
        card.box.pointerEntered.addHandler { [weak self] _, _ in
            self?.pointed = id
            self?.draw()
        }
        card.box.pointerExited.addHandler { [weak self] _, _ in
            if self?.pointed == id { self?.pointed = nil }
            self?.draw()
        }
    }

    private func writingField(placeholder: String) -> TextBox {
        let field = TextBox()
        field.placeholderText = placeholder
        field.fontFamily = Theme.ui
        field.fontSize = Double(WindowsCore.NotesHand.textSize)
        field.textWrapping = .wrap
        field.acceptsReturn = false
        field.background = Theme.clear
        field.borderThickness = Theme.inset(0)
        field.padding = Theme.inset(2, 3, 2, 3)
        field.minHeight = 24
        field.allowFocusOnInteraction = true
        return field
    }

    /// A note with its writer above it: their token and name, how long ago; at the head of an open
    /// card, the steps through a review and the tick that closes it.
    private func header(_ note: WindowsCore.NotesHand.NoteLook?, first: Bool, item: WindowsCore.NotesHand.Item, open: Bool, draft: Bool = false) -> FrameworkElement {
        let row = Grid()
        row.height = 16
        let lead = StackPanel()
        lead.orientation = .horizontal
        lead.spacing = 6
        lead.children.append(token(note, size: 16, colour: draft ? item.colour : nil))
        let name = Theme.text(note?.by ?? notes.author.name, size: 11.5, weight: 600, ink: 2)
        name.maxWidth = 120
        lead.children.append(name)
        if first, item.unread {
            let dot = Ellipse()
            dot.width = 6
            dot.height = 6
            dot.fill = Theme.brush(item.colour)
            dot.verticalAlignment = .center
            lead.children.append(dot)
        }
        row.children.append(lead)
        let tail = StackPanel()
        tail.orientation = .horizontal
        tail.spacing = 4
        tail.horizontalAlignment = .right
        if !draft, let note { tail.children.append(Theme.text(Self.ago(note.time), size: 10.5, ink: 3)) }
        if first, open, !draft, let note {
            if notes.reviewCount > 1 {
                tail.children.append(glyphButton(Glyphs.back(size: 14), help: Words.t("Previous Note")) { [weak self] in self?.step(-1) })
                tail.children.append(glyphButton(Glyphs.chevron(open: false, size: 14), help: Words.t("Next Note")) { [weak self] in self?.step(1) })
            }
            if !readOnly {
                let tick = Border()
                tick.width = 16
                tick.height = 16
                tick.cornerRadius = Theme.corners(8)
                tick.borderThickness = Theme.inset(1.2)
                tick.borderBrush = item.done ? Theme.brush(Theme.pencil) : Theme.ink(3)
                tick.background = item.done ? Theme.brush(Theme.pencil) : Theme.clear
                let mark = Theme.text("✓", size: 9, weight: 700)
                mark.foreground = item.done ? Theme.brush(0xFFFFFF) : Theme.brush(Theme.pencil)
                mark.horizontalAlignment = .center
                mark.opacity = item.done ? 1 : 0
                tick.child = mark
                tick.pointerEntered.addHandler { _, _ in if !item.done { mark.opacity = 1; tick.borderBrush = Theme.brush(Theme.pencil) } }
                tick.pointerExited.addHandler { _, _ in if !item.done { mark.opacity = 0; tick.borderBrush = Theme.ink(3) } }
                tick.pointerPressed.addHandler { _, args in args?.handled = true }
                let thread = note.id
                tick.tapped.addHandler { [weak self] _, args in
                    args?.handled = true
                    guard let self else { return }
                    // The tick lands before the card goes.
                    mark.opacity = 1
                    tick.background = Theme.brush(Theme.pencil)
                    mark.foreground = Theme.brush(0xFFFFFF)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated {
                            self.notes.setDone(thread, !item.done)
                            self.edited()
                        }
                    }
                }
                try? ToolTipService.setToolTip(tick, Words.t(item.done ? "Open Again" : "Mark as Done"))
                tail.children.append(tick)
            }
        }
        row.children.append(tail)
        return row
    }

    private func glyphButton(_ glyph: [Glyphs.Part], help: String, _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let box = Border()
        box.width = 18
        box.height = 16
        box.background = Theme.clear
        let g = Glyphs.view(glyph, size: 14, brush: Theme.ink(3))
        g.horizontalAlignment = .center
        g.verticalAlignment = .center
        box.child = g
        box.pointerEntered.addHandler { _, _ in Glyphs.paint(g, Theme.ink(1)) }
        box.pointerExited.addHandler { _, _ in Glyphs.paint(g, Theme.ink(3)) }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
        try? ToolTipService.setToolTip(box, help)
        return box
    }

    private func noteView(_ note: WindowsCore.NotesHand.NoteLook, first: Bool, item: WindowsCore.NotesHand.Item, open: Bool, card: Card) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 4
        stack.children.append(header(note, first: first, item: item, open: open))
        let words = TextBlock()
        words.text = note.text
        words.fontFamily = Theme.ui
        words.fontSize = Double(WindowsCore.NotesHand.textSize)
        words.lineHeight = notes.lineHeight + Double(WindowsCore.NotesHand.leading)
        words.textWrapping = .wrap
        words.foreground = item.done ? Theme.ink(2) : Theme.ink(1)
        if !open { words.maxLines = 3; words.textTrimming = .characterEllipsis }
        words.isTextSelectionEnabled = open
        // A double click on one's own words, open, changes them, as Edit in its menu does.
        if open, note.mine, !readOnly {
            let begin: @MainActor () -> Void = { [weak self] in
                guard let self, card.change == nil else { return }
                let field = self.writingField(placeholder: "")
                field.text = note.text
                field.keyDown.addHandler { [weak self] _, args in
                    guard let self, let args else { return }
                    if args.key == .enter {
                        args.handled = true
                        self.notes.change(note.id, field.text)
                        self.edited()
                        // Made again even when the words stayed as they were.
                        card.signature = ""
                        self.draw()
                        self.returnFocus()
                    }
                    if args.key == .escape {
                        args.handled = true
                        card.signature = ""
                        self.draw()
                        self.returnFocus()
                    }
                }
                var k: UInt32 = 0
                if (try? stack.children.indexOf(words, &k)) == true {
                    stack.children.removeAt(k)
                    stack.children.insertAt(k, field)
                }
                field.loaded.addHandler { _, _ in
                    _ = try? field.focus(.programmatic)
                    try? field.selectAll()
                }
                card.change = field
            }
            card.changers[note.id] = begin
            words.doubleTapped.addHandler { _, _ in begin() }
        }
        stack.children.append(words)
        return stack
    }

    /// Who answered, as their tokens, with how many.
    private func answered(_ item: WindowsCore.NotesHand.Item) -> FrameworkElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = -4
        row.height = 14
        let replies = Array(item.notes.dropFirst())
        var seen = Set<String>()
        for reply in replies where seen.insert(reply.by).inserted && seen.count <= 4 {
            row.children.append(token(reply, size: 14, ring: true))
        }
        let count = Theme.text("\(replies.count)", size: 10.5, weight: 600, ink: 3)
        count.margin = Theme.inset(9, 0, 0, 0)
        row.children.append(count)
        return row
    }

    /// How long ago, in a word or two.
    static func ago(_ time: Double) -> String {
        let s = Date().timeIntervalSince1970 - time
        if s < 60 { return Words.t("now") }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: time))
    }

    private func step(_ by: Int) {
        if let spot = notes.step(by: by) { reveal(spot) }
        draw()
    }

    // MARK: The menu

    /// What a right click on a note offers, as the Mac's NoteMenu: answering and ticking it off,
    /// changing or taking away what was written here, and copying its words.
    private func showMenu(_ id: UUID, at p: CGPoint) {
        guard let menus, let item = notes.scene(zoom: BezzleCore.CGFloat(view().zoom), pan: view().pan, heights: heights, drag: nil, pointed: nil)
                .shown.first(where: { $0.id == id })?.item else { return }
        var entries: [MenuHost.Entry] = []
        let mine = item.notes.first?.mine == true
        if !readOnly {
            if !item.done { entries.append(.item(Words.t("Answer")) { [weak self] in self?.notes.focus(.answer(id)) }) }
            entries.append(.item(Words.t(item.done ? "Open Again" : "Mark as Done")) { [weak self] in
                self?.notes.setDone(id, !item.done)
                self?.edited()
            })
            entries.append(.separator)
            if mine { entries.append(.item(Words.t("Edit")) { [weak self] in self?.notes.focus(.change(id)) }) }
        }
        entries.append(.item(Words.t("Copy")) { [weak self] in
            guard let self else { return }
            Clipboard.copyText(self.notes.words(of: id))
        })
        if !readOnly, mine {
            entries.append(.separator)
            entries.append(.item(Words.t("Delete")) { [weak self] in
                self?.notes.delete(id)
                self?.edited()
            })
        }
        menus.show(at: p, width: 210, entries: entries)
    }
}
