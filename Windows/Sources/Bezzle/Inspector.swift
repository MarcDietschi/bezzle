import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore
import WinSDK

/// The inspector (the Mac's Inspector and its AspectCards): cards 248 wide, radius 12, 8 apart,
/// each folded to one line 40 tall, its picture, title and a summary at the right; dashed chips
/// below for what the selection has not got. With nothing selected: the tools and their keys.
///
/// As on the Mac, a card is a dial: dragging across its line sets its value, the whole card's
/// width the whole range, filling with pencil from the left (stops caught within 3%); a click
/// opens it, to set its values in fields.
@MainActor
final class Inspector {
    let root = Grid()
    let session: DesignSession
    let cards = StackPanel()
    /// The place a style goes, for each card that has one, by the card's name (`card(style:)`).
    private var styleKeys: [String: String] = [:]
    /// Each card's summary as shown, by its key, for the Frame card's to follow a drag.
    private var summaries: [String: TextBlock] = [:]
    /// Whether a card pointed at outlines the other layers with its look's name.
    private var cardLit = false

    /// The card that is open, one at a time as on the Mac (store.openAspect): Frame to begin with.
    var opened: String? = "Frame" {
        // The shadow whose card is open is the one a drag on the canvas moves, as on the Mac.
        didSet {
            session.openCard = opened
            // The photo stops being the control once its card shuts.
            if opened != "Photo", session.develop.on { session.develop.on = false }
            guard let opened, opened == "Shadow" || opened.hasPrefix("Shadow ") else { WindowsCore.openShadow = nil; return }
            WindowsCore.openShadow = Int(opened.dropFirst("Shadow".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    /// While a dial turns, the cards are not made again: the card under the pointer must stay.
    var dialing = false
    /// The piles of fills, borders and shadows shown, and the card of one just put in another
    /// place, which lands there from where it was let go once the panel is made again.
    var piles: [Pile] = []
    var pileLanding: (look: String, slot: Int, offset: Double, at: Double)?
    /// Bezzle's own menus, for the cards' menu buttons.
    var menus: MenuHost?
    /// Whether a variable font's axes are shown, which they are anyway once one is set.
    var showsAxes = false
    /// What a panel open from a card needs kept, such as the colour panel's state.
    var retained: AnyObject?
    /// The open fill menu's gradient bar made again, as its colours move on the canvas.
    var refreshGradientBar: (() -> Void)?
    /// The Export card's export: how far it has come, the question before replacing files, and
    /// where they went, for the layers it was for.
    var exporting: Double?
    var exportAsking: (ids: [UUID], folder: URL, taken: [URL])?
    var exportDone: (ids: [UUID], outcome: (shown: URL, written: Int, missed: Int))?
    /// Gives the keys back to the canvas, once a field has been typed into.
    var returnFocus: (() -> Void)?
    /// The Photo card's tab (light, color, detail), and the colour whose rows show, as on the Mac.
    var photoGroup = "light" { didSet { session.develop.group = photoGroup } }
    var photoBand: String?
    /// Draws the open Photo card's landscape again, as a row changes the picture.
    var photoTerrainRefresh: (() -> Void)?
    /// The tone or colour the pointer is on in the Photo card, and the one shown alone with Alt.
    var photoPointed: (tone: String?, band: String?)?
    var photoIsolated: String?
    var photoPointing: (ids: [UUID], board: Int)?
    /// What was picked when the prototype's cards were last opened by themselves.
    var prototypePicked: [UUID] = []
    /// The story card's moving drawing, held while it shows.
    var pullDemo: AnyObject?
    /// The style rows that show all their styles, by the card's place; the style being renamed; the place whose look is being named.
    var stylesAll: Set<String> = []
    /// The style opened in the kit, whether its name is to be typed, whether its look in the dark is shown, and its colour panel.
    var kitOpen: UUID?
    var kitNaming = false
    var kitDark = false
    var kitPanel: AnyObject?
    var kitChanges = 0
    var renamingStyle: UUID?
    var namingStyle: String?
    /// What Inspect's Asset card takes a layer as: its format, and for a picture how many pixels to the point.
    var assetFormat = "png"
    var assetScale = 2.0
    /// What the Inspect panel writes code for.
    var inspectPlatform: WindowsCore.InspectPlatform = .css

    init(session: DesignSession) {
        self.session = session
        session.showCard = { [weak self] key in self?.opened = key }
        session.openStylePlace = { [weak self] in
            guard let self, let opened = self.opened else { return nil }
            return self.styleKeys[opened]
        }
        // A colour pressed on in the photo shows its rows.
        session.pickPhotoBand = { [weak self] band in
            guard let self, self.photoBand != band else { return }
            self.photoBand = band
            self.show()
        }
        root.width = Theme.inspectorWidth
        cards.spacing = 8
        cards.margin = Theme.inset(16, 14, 16, 28)
        let scroll = ScrollView()
        scroll.content = cards
        // A click between the cards puts the focus nowhere in the panel (WinUI would hand it to the
        // panel's first field), and ends the typing in a field, as a click away does on the Mac.
        // The scroll view takes the focus itself when clicked (a scroll view that is no tab stop
        // hands it to its first field), and the press gives it back to the canvas.
        scroll.isTabStop = true
        scroll.useSystemFocusVisuals = false
        cards.allowFocusOnInteraction = false
        root.background = Theme.clear
        // A press on the panel itself gives the keys back to the canvas, and again once the press
        // is over: WinUI hands the focus to the panel's first field after it, now that the fields
        // take the focus when clicked.
        root.pointerPressed.addHandler { [weak self] _, args in
            // A press in a field being typed into is the field's: placing the caret, choosing words.
            guard !Self.inField(args?.originalSource as? DependencyObject) else { return }
            self?.returnFocus?()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returnFocus?() } }
        }
        root.children.append(scroll)
        session.listen { [weak self] in self?.changed() }
        // Animated, the cards follow the playhead and what of the film is picked.
        session.listenToFilm { [weak self] in
            guard let self, self.session.mode == 3, !self.dialing else { return }
            self.show()
        }
        show()
    }

    /// The cards made again for a change. While a drag on the design's canvas goes on, only the
    /// Frame card's numbers follow it, and the cards are made again once it ends: making them at
    /// every step held the drag up, and with it what the others in a shared design see of it.
    private func changed() {
        guard !dialing else { return }
        guard session.mode == 0, WindowsCore.inGesture else {
            afterGesture?.invalidate()
            afterGesture = nil
            show()
            return
        }
        let layers = session.selectedLayers
        if let box = WindowsCore.selectionFrame(layers.map(\.id)), let value = summaries["Frame"] {
            let turns = Set(layers.map(\.rotation))
            value.text = frameSummary(box, turn: layers.count == 1 ? turns.first : nil).components(separatedBy: " · ").map(Words.match).joined(separator: " · ")
        }
        guard afterGesture == nil else { return }
        afterGesture = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // Its tab behind another, the core is the other design's: it waits to come back.
                guard let self, self.session.isFront, !WindowsCore.inGesture else { return }
                timer.invalidate()
                self.afterGesture = nil
                if !self.dialing { self.show() }
            }
        }
    }

    private var afterGesture: Timer?

    /// The Frame card's numbers: size, place, and the turn when there is one.
    private func frameSummary(_ box: CGRect, turn: Double?) -> String {
        var frame = "\(number(box.width)) × \(number(box.height)) · \(number(box.minX)), \(number(box.minY))"
        if let turn, turn != 0 { frame += " · ↻ \(number(turn))°" }
        return frame
    }

    /// Whether an element pressed lies in a text field.
    static func inField(_ element: DependencyObject?) -> Bool {
        var at = element
        while let e = at {
            if e is TextBox { return true }
            at = try? VisualTreeHelper.getParent(e)
        }
        return false
    }

    /// A dial: where its value lies in its range (0…1), how to set it from there, and its summary.
    struct Dial {
        var fraction: Double
        var set: (Double) -> Void
        var summary: (Double) -> String
        var stops: [Double] = [0, 0.25, 0.5, 0.75, 1]
    }

    func show() {
        cards.children.clear()
        piles = []
        summaries = [:]
        // The card pointed at goes with them, and the layers it outlined with it.
        if cardLit {
            cardLit = false
            session.litLayers = []
        }
        // Animated: the film, and what is picked posed in it.
        if session.mode == 3 { showAnimate(); return }
        // Inspecting: the specs of what is picked, read and copied, never changed.
        if session.mode == 2 { showInspect(); return }
        // As a prototype: where what is picked goes.
        if session.mode == 1 { showPrototype(); return }
        let layers = session.selectedLayers
        guard let layer = layers.first, let board = session.board else {
            // The design's styles first, as the Mac's StyleKit stands above the tools.
            for card in styleKitCards() { cards.children.append(card) }
            cards.children.append(toolsCard())
            return
        }
        let ids = layers.map(\.id)
        let several = layers.count > 1
        @MainActor func edited() { self.session.edited(board: board) }
        // Several layers: Arrange first, to line them up and space them, as on the Mac.
        if several {
            cards.children.append(card("Arrange", "\(layers.count) layers", glyph: Glyphs.align(.left), body: {
                [self.arrangePicks(ids, board: board)]
            }))
        }
        // Folded, the numbers in a line (the box round several); its dial sizes them in
        // proportion, caught at a quarter, a third, half and all of the artboard's width. Open,
        // the exact numbers.
        guard let box = WindowsCore.selectionFrame(ids) else { return }
        let turns = Set(layers.map(\.rotation)), turn = turns.count == 1 ? turns.first : nil
        let frame = frameSummary(box, turn: several ? nil : turn)
        let artboard = WindowsCore.boards().first { $0.index == board }?.frame
        var frameDial: Dial?
        if box.width > 0, box.height > 0, layers.allSatisfy({ !$0.locked && $0.kind != "artboard" }) {
            let whole = artboard.map { Double($0.width) }
            let top = max(Double(box.width) * 2, (whole ?? 0) * 1.5, 100)
            frameDial = Dial(fraction: (Double(box.width) - 1) / (top - 1),
                             set: { WindowsCore.setSize(ids, width: (1 + $0 * (top - 1)).rounded(), keepingProportions: true) },
                             summary: { f in
                                 let w = (1 + f * (top - 1)).rounded(), h = (w * Double(box.height) / Double(box.width)).rounded()
                                 return "\(self.number(w)) × \(self.number(h)) · \(self.number(box.minX)), \(self.number(box.minY))"
                             },
                             stops: whole.map { w in [w / 4, w / 3, w / 2, w].map { ($0.rounded() - 1) / (top - 1) } } ?? [])
        }
        cards.children.append(card("Frame", frame, glyph: Glyphs.tool(.rectangle, size: 16), dial: frameDial, body: {
            var rows: [UIElement] = [
                self.pair(self.field("W", Double(box.width), range: 0...100_000) { WindowsCore.setSize(ids, width: $0); edited() },
                          self.field("H", Double(box.height), range: 0...100_000) { WindowsCore.setSize(ids, height: $0); edited() }),
                self.pair(self.field("X", Double(box.minX)) { WindowsCore.setPlace(ids, x: $0); edited() },
                          self.field("Y", Double(box.minY)) { WindowsCore.setPlace(ids, y: $0); edited() }),
            ]
            if layer.kind != "artboard" {
                rows.append(self.pair(self.field("↻", turn, unit: "°", range: -360...360, scrub: 0.5) { WindowsCore.setRotation(ids, $0); edited() },
                                      self.flipButtons(ids, board: board)))
            }
            // One layer lying on the artboard: the artboard in small, to drag it into place.
            if !several, layer.depth == 0, layer.kind != "artboard", !layer.locked, let sheet = WindowsCore.boards().first(where: { $0.index == board }) {
                rows.append(self.placePad(sheet, frame: box, id: layer.id))
            }
            return rows
        }))
        // The cards every selected layer has, as the Mac's SelectionInspector picks them: what
        // they share, shown when any of them has it ("Several" where they differ); what none
        // has yet waits below as dashed chips. Lines are all border and text all colour, so
        // those are not taken away from them.
        let kinds = Set(layers.map(\.kind))
        if kinds == ["text"], let text = WindowsCore.textCard(ids) {
            cards.children.append(textCard(text, ids: ids, board: board))
        }
        // Words along a curve: bent ones, or ones riding a shape, but not both at once.
        if kinds == ["text"], let curve = curveCard(ids, board: board) { cards.children.append(curve) }
        if kinds == ["artboard"], ids.count == 1, let artboard = artboardCard(ids[0], board: board) { cards.children.append(artboard) }
        if kinds == ["artboard"], let deck = deckCard(ids, board: board) { cards.children.append(deck) }
        if let own = postLayerCard(ids, board: board) { cards.children.append(own) }
        if let component = componentCard(ids, board: board) { cards.children.append(component) }
        if let own = copyLayerCard(ids, board: board) { cards.children.append(own) }
        if ids.count == 1, WindowsCore.isGrid(ids[0]) {
            if let grid = repeatGridCard(ids[0], board: board) { cards.children.append(grid) }
        } else if ids.count == 1, let cell = gridCellCard(ids[0], board: board) {
            cards.children.append(cell)
        }
        if let mask = maskCard(ids, board: board) { cards.children.append(mask) }
        // A picture made shapes, while the design remembers the picture.
        if let vector = vectorCard(ids, board: board) { cards.children.append(vector) }
        if kinds == ["path"] { cards.children.append(pathCard(layers, board: board)) }
        for look in lookCards(ids, board: board, kinds: kinds) { cards.children.append(look) }
    }

    // MARK: Cards

    /// A card: `id` says which is open, one at a time (its title unless several share one, as a
    /// pile's cards do).
    ///
    /// A card that can be taken away (`remove`) shows an × while open, saying `removal`; one with
    /// a dial also comes away when its dial is dragged on past nothing by 70 points and let go,
    /// as the Mac's tears off, saying "Release to remove" until then.
    func card(_ title: String, _ summary: String, id: String? = nil, glyph: [Glyphs.Part]? = nil, mark: FrameworkElement? = nil,
              swatch: WindowsCore.Paint? = nil, dial: Dial? = nil, remove: (@MainActor () -> Void)? = nil, removal: String = "Remove",
              accessory: FrameworkElement? = nil, more: (help: String, preview: @MainActor (Bool) -> Void, add: @MainActor () -> Void)? = nil,
              restack: ((Double?) -> Void)? = nil, style: String? = nil, body: (@MainActor () -> [UIElement])? = nil) -> UIElement {
        let key = id ?? title
        if let style { styleKeys[key] = style }
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        // Pointed at, a card whose look has a name outlines every other layer with that name on
        // the canvas, as the Mac's StyleMarks does for the pointed aspect.
        if let style {
            card.pointerEntered.addHandler { [weak self] _, _ in
                guard let self else { return }
                let users = WindowsCore.namedLookUsers(at: style, self.session.selection)
                guard !users.isEmpty else { return }
                self.cardLit = true
                self.session.litLayers = users
            }
            card.pointerExited.addHandler { [weak self] _, _ in
                guard let self, self.cardLit else { return }
                self.cardLit = false
                self.session.litLayers = []
            }
        }
        let stack = StackPanel()
        let line = Grid()
        line.height = 40
        line.background = Theme.clear

        // The dial's fill, from the left as far as its value, with an edge of pencil.
        let fill = Border()
        fill.horizontalAlignment = .left
        fill.background = Theme.brush(Theme.pencil, Theme.pencilWash)
        fill.borderBrush = Theme.brush(Theme.pencil, 0.35)
        fill.borderThickness = Theme.inset(0, 0, 1.5, 0)
        fill.cornerRadius = CornerRadius(topLeft: 12, topRight: 0, bottomRight: 0, bottomLeft: opened == key ? 0 : 12)
        fill.opacity = 0
        if let dial { fill.width = max(0, min(1, dial.fraction)) * Theme.cardWidth }
        line.children.append(fill)

        let lead = StackPanel()
        lead.orientation = .horizontal
        lead.spacing = 8
        lead.verticalAlignment = .center
        lead.margin = Theme.inset(9, 0, 0, 0)
        let box = Border()
        box.width = 22
        box.height = 22
        if let swatch {
            let chip = Border()
            chip.width = 14
            chip.height = 14
            chip.cornerRadius = Theme.corners(3.5)
            chip.borderBrush = Theme.hairline
            chip.borderThickness = Theme.inset(0.5)
            chip.background = swatch.picture || swatch.gradient ? Theme.ink(4) : Theme.brush(UInt32(swatch.hex, radix: 16) ?? 0, swatch.alpha)
            box.child = chip
        } else if let mark {
            mark.horizontalAlignment = .center
            mark.verticalAlignment = .center
            box.child = mark
        } else if let glyph {
            let view = Glyphs.view(glyph, size: 16, brush: Theme.ink(2))
            view.horizontalAlignment = .center
            view.verticalAlignment = .center
            box.child = view
        }
        lead.children.append(box)
        let heading = Theme.text(Words.t(title), size: 12.5, weight: 600)
        heading.textTrimming = .characterEllipsis
        lead.children.append(heading)
        line.children.append(lead)
        // The room the open card's + and × take at the right, which what comes before keeps clear of.
        var reserved = 8.0
        if opened == key, remove != nil { reserved += 20 + 4 }
        if opened == key, more != nil { reserved += 20 + 4 }
        // Its parts as Bezzle says them: "3.3 pt · Inside" is "3.3 pt · Innen".
        let value = Theme.text(summary.components(separatedBy: " · ").map(Words.match).joined(separator: " · "), size: 12, ink: 2)
        summaries[key] = value
        value.horizontalAlignment = .right
        value.margin = Theme.inset(0, 0, reserved, 0)
        value.maxWidth = 140
        value.textTrimming = .characterEllipsis
        line.children.append(value)
        // A look with a name says its name, in pencil after the mark, and its picture is ringed.
        var named: FrameworkElement?
        if let style, let name = WindowsCore.styleName(at: style, session.selection) {
            let summary = Self.namedSummary(name)
            summary.horizontalAlignment = .right
            summary.verticalAlignment = .center
            summary.margin = value.margin
            value.visibility = .collapsed
            line.children.append(summary)
            named = summary
            box.borderBrush = Theme.brush(Theme.pencil, 0.75)
            box.borderThickness = Theme.inset(1.2)
            box.cornerRadius = Theme.corners(7.5)
        }
        // Something to do at once, beside the summary, as the Mac's accessory: Release, Take Out,
        // the copy before and after. The summary gives way to it.
        if let accessory {
            accessory.horizontalAlignment = .right
            accessory.verticalAlignment = .center
            accessory.margin = Theme.inset(0, 0, reserved - 2, 0)
            line.children.append(accessory)
            try? accessory.measure(Size(width: 200, height: 40))
            let width = Double(accessory.desiredSize.width)
            value.margin = Theme.inset(0, 0, reserved - 2 + width + 6, 0)
            // The title gives way too, when the accessory needs its room.
            let right = reserved - 2 + width + 6
            try? box.measure(Size(width: 40, height: 40))
            heading.maxWidth = max(40, Theme.cardWidth - right - 9 - Double(box.desiredSize.width) - 8 - 10)
            try? lead.measure(Size(width: 400, height: 40))
            value.maxWidth = max(0, Theme.cardWidth - Double(lead.desiredSize.width) - 10 - right)
            // Too little room to say anything: nothing, rather than a letter.
            if value.maxWidth < 36 { value.visibility = .collapsed }
        }
        // Another of its kind on top, as the Mac's MoreButton: pointed at, it shows; clicked, it is added.
        var trailing = 8.0
        if opened == key, remove != nil { trailing += 20 + 4 }
        if opened == key, let more {
            let plus = Pressable(radius: 10) {
                more.preview(false)
                more.add()
            }
            plus.hoverWash = 0.07
            plus.box.width = 20
            plus.box.height = 20
            plus.box.horizontalAlignment = .right
            plus.box.verticalAlignment = .center
            plus.box.margin = Theme.inset(0, 0, trailing, 0)
            let glyph = Glyphs.view(Glyphs.plus(size: 20), size: 20, brush: Theme.ink(3))
            plus.box.child = glyph
            plus.box.pointerEntered.addHandler { _, _ in
                Glyphs.paint(glyph, Theme.ink(1))
                more.preview(true)
            }
            plus.box.pointerExited.addHandler { _, _ in
                Glyphs.paint(glyph, Theme.ink(3))
                more.preview(false)
            }
            plus.box.pointerPressed.addHandler { _, args in args?.handled = true }
            try? ToolTipService.setToolTip(plus.box, Words.t(more.help))
            line.children.append(plus.box)
            trailing += 20 + 4
        }
        if opened == key, let remove {
            let cross = Pressable(radius: 10) { remove() }
            cross.hoverWash = 0.07
            cross.box.width = 20
            cross.box.height = 20
            cross.box.horizontalAlignment = .right
            cross.box.verticalAlignment = .center
            cross.box.margin = Theme.inset(0, 0, 8, 0)
            let glyph = Glyphs.view(Glyphs.cross(size: 20), size: 20, brush: Theme.ink(3))
            cross.box.child = glyph
            cross.box.pointerEntered.addHandler { _, _ in Glyphs.paint(glyph, Theme.ink(1)) }
            cross.box.pointerExited.addHandler { _, _ in Glyphs.paint(glyph, Theme.ink(3)) }
            // Kept from the line under it, which would fold the card.
            cross.box.pointerPressed.addHandler { _, args in args?.handled = true }
            try? ToolTipService.setToolTip(cross.box, Words.t(removal))
            line.children.append(cross.box)
        }
        stack.children.append(line)

        if opened == key, let body {
            let inside = StackPanel()
            inside.spacing = 8
            inside.margin = Theme.inset(12, 0, 12, 12)
            // The design's styles of the kind first, and the look named.
            if let style, let row = styleRow(style) { inside.children.append(row) }
            for e in body() { inside.children.append(e) }
            stack.children.append(inside)
        }
        card.child = stack

        // Pressing the line: a drag across turns the dial, one up or down picks a card of a pile up
        // (`restack`), a click opens or folds the card. Measured in the window, not on the card,
        // which moves under the pointer as it is carried: else each move would be counted less
        // the last, and the card would shake (as on the Mac).
        var start: (x: Double, y: Double, fraction: Double)?
        var turned = false
        var carrying = false
        var tearing = false
        line.pointerEntered.addHandler { _, _ in if dial != nil, start == nil { fill.opacity = 0.55 } }
        line.pointerExited.addHandler { _, _ in if start == nil { fill.opacity = 0 } }
        line.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let p = try? args?.getCurrentPoint(nil)?.position else { return }
            start = (Double(p.x), Double(p.y), dial?.fraction ?? 0)
            turned = false
            carrying = false
            tearing = false
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            if dial != nil || restack != nil { self.dialing = true }
        }
        line.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let s = start, let p = try? args?.getCurrentPoint(nil)?.position else { return }
            let dx = Double(p.x) - s.x, dy = Double(p.y) - s.y
            if carrying {
                restack?(dy)
                return
            }
            if !turned {
                // Up or down, a card in a pile is picked up; sideways, its dial turns.
                if let restack, abs(dy) >= 4, abs(dy) > abs(dx) {
                    carrying = true
                    line.protectedCursor = Pointer.grab.cursor
                    restack(dy)
                    return
                }
                guard dial != nil, abs(dx) > 3 else { return }
                WindowsCore.beginGesture()
            }
            guard let dial else { return }
            turned = true
            fill.opacity = 1
            named?.visibility = .collapsed
            value.visibility = .visible
            let raw = s.fraction + dx / Theme.cardWidth
            var f = min(1, max(0, raw))
            if let stop = dial.stops.first(where: { abs($0 - f) < 0.03 }) { f = stop }
            fill.width = f * Theme.cardWidth
            // Past nothing, one that can be taken away comes away when let go far enough on.
            tearing = remove != nil && -raw * Theme.cardWidth > 70
            value.text = tearing ? Words.t("Release to remove") : dial.summary(f)
            value.foreground = tearing ? Theme.brush(Theme.warning) : Theme.ink(2)
            dial.set(f)
            self.session.edited(board: self.session.board)
        }
        line.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, start != nil else { return }
            start = nil
            // Before letting the pointer go, which tells of the capture lost at once.
            let carried = carrying
            carrying = false
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            if carried {
                // Put down in the place it was carried to, as one step, or back where it was.
                line.protectedCursor = nil
                restack?(nil)
                return
            }
            if tearing, let remove {
                // Taken away in one step, not turned down to nothing first.
                WindowsCore.cancelGesture()
                self.dialing = false
                // Once the release is over: the panel is made again without this card.
                DispatchQueue.main.async { MainActor.assumeIsolated { remove() } }
                return
            }
            if turned { WindowsCore.endGesture() }
            self.dialing = false
            if turned {
                fill.opacity = 0.55
                self.session.edited(board: self.session.board)
            } else if body != nil {
                self.opened = self.opened == key ? nil : key
                self.show()
            }
        }
        // A card carried when the pointer is taken away from it (another window coming up) is put
        // down as if let go.
        line.pointerCaptureLost.addHandler { _, _ in
            guard carrying else { return }
            carrying = false
            start = nil
            line.protectedCursor = nil
            restack?(nil)
        }
        return card
    }

    /// Two fields side by side, as the Mac's Pair: each a column wide, with the gap between
    /// them (where the lock that ties width to height goes).
    static let column = (Theme.cardWidth - 24 - 20) / 2 - 2
    static let columnGap = 20.0

    /// The artboard in small, with the layer on it to drag into place, as the Mac's PlacePad: it
    /// catches on the artboard's edges and middle, a pencil line showing where.
    private func placePad(_ board: WindowsCore.Board, frame: CGRect, id: UUID) -> UIElement {
        let content = Theme.cardWidth - 24
        let size = board.frame.size
        let s = min((content - 32) / max(Double(size.width), 1), 132 / max(Double(size.height), 1))
        let mw = Double(size.width) * s, mh = Double(size.height) * s
        let well = Theme.well(radius: 10)
        well.width = content
        well.height = mh + 28
        let pad = Canvas()
        pad.width = mw
        pad.height = mh
        pad.horizontalAlignment = .center
        pad.verticalAlignment = .center
        let shade = Border()
        shade.width = mw
        shade.height = mh
        shade.cornerRadius = Theme.corners(2)
        shade.background = Theme.brush(Theme.shadow, 0.14)
        try? Canvas.setTop(shade, 1)
        let sheet = Border()
        sheet.width = mw
        sheet.height = mh
        sheet.cornerRadius = Theme.corners(2)
        sheet.background = Theme.brush(UInt32(board.fill.hex, radix: 16) ?? 0xFFFFFF, board.fill.alpha)
        let box = Border()
        box.width = max(Double(frame.width) * s, 4)
        box.height = max(Double(frame.height) * s, 4)
        box.cornerRadius = Theme.corners(1.5)
        box.background = Theme.brush(Theme.pencil, Theme.pencilWash)
        box.borderBrush = Theme.brush(Theme.pencil)
        box.borderThickness = Theme.inset(1)
        func place(_ p: CGPoint) {
            try? Canvas.setLeft(box, Double(p.x) * s)
            try? Canvas.setTop(box, Double(p.y) * s)
        }
        place(frame.origin)
        let across = Rectangle(), down = Rectangle()
        across.width = 1
        across.height = mh + 12
        try? Canvas.setTop(across, -6)
        down.width = mw + 12
        down.height = 1
        try? Canvas.setLeft(down, -6)
        for line in [across, down] {
            line.fill = Theme.brush(Theme.pencil)
            line.visibility = .collapsed
            line.isHitTestVisible = false
        }
        for e in [shade, sheet, box, across, down] as [UIElement] { pad.children.append(e) }
        well.child = pad

        var start: (x: Double, y: Double)?
        box.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let p = try? args?.getCurrentPoint(pad)?.position else { return }
            args?.handled = true
            start = (Double(p.x), Double(p.y))
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            WindowsCore.beginGesture()
            self.dialing = true
        }
        box.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let from = start, let q = try? args?.getCurrentPoint(pad)?.position else { return }
            let w = Double(size.width), h = Double(size.height), fw = Double(frame.width), fh = Double(frame.height)
            var x = Double(frame.minX) + (Double(q.x) - from.x) / s, y = Double(frame.minY) + (Double(q.y) - from.y) / s
            // Each stop: where the layer's top left goes, and where its line is drawn.
            let xs = [(0.0, 0.0), ((w - fw) / 2, w / 2), (w - fw, w)], ys = [(0.0, 0.0), ((h - fh) / 2, h / 2), (h - fh, h)]
            let reach = 5 / s
            let cx = xs.first { abs($0.0 - x) <= reach }, cy = ys.first { abs($0.0 - y) <= reach }
            if let cx { x = cx.0 }
            if let cy { y = cy.0 }
            across.visibility = cx == nil ? .collapsed : .visible
            down.visibility = cy == nil ? .collapsed : .visible
            if let cx { try? Canvas.setLeft(across, cx.1 * s - 0.5) }
            if let cy { try? Canvas.setTop(down, cy.1 * s - 0.5) }
            place(CGPoint(x: x.rounded(), y: y.rounded()))
            WindowsCore.setPlace([id], x: x.rounded(), y: y.rounded())
            self.session.edited(board: board.index)
        }
        box.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, start != nil else { return }
            args?.handled = true
            start = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            self.show()
        }
        return well
    }

    /// Lining several up, as the Mac's ArrangePicks: six buttons, 28 square, for their left
    /// edges, centres, right edges, tops, middles and bottoms (one layer lines up with its
    /// artboard), then at the right spacing them evenly across and down, for three or more.
    private func arrangePicks(_ ids: [UUID], board: Int) -> UIElement {
        let row = Grid()
        let lead = StackPanel(), trail = StackPanel()
        lead.orientation = .horizontal
        trail.orientation = .horizontal
        trail.horizontalAlignment = .right
        row.margin = Theme.inset(-4, 0, -4, 0)
        func button(_ glyph: [Glyphs.Part], dim: Bool = false, _ action: @escaping @MainActor () -> Void) -> UIElement {
            let press = Pressable(radius: 7) { [weak self] in
                action()
                self?.session.edited(board: board)
            }
            press.box.width = 28
            press.box.height = 28
            let view = Glyphs.view(glyph, size: 16, brush: Theme.ink(2))
            view.horizontalAlignment = .center
            view.verticalAlignment = .center
            press.box.child = view
            press.box.opacity = dim ? 0.35 : 1
            press.box.isHitTestVisible = !dim
            return press.box
        }
        let aligns: [(Glyphs.Alignment, WindowsCore.Align)] = [(.left, .left), (.centerX, .centerX), (.right, .right),
                                                              (.top, .top), (.centerY, .centerY), (.bottom, .bottom)]
        for (glyph, how) in aligns { lead.children.append(button(Glyphs.align(glyph)) { WindowsCore.align(ids, how) }) }
        let few = ids.count < 3
        trail.children.append(button(Glyphs.distribute(horizontally: true), dim: few) { WindowsCore.distribute(ids, horizontally: true) })
        trail.children.append(button(Glyphs.distribute(horizontally: false), dim: few) { WindowsCore.distribute(ids, horizontally: false) })
        row.children.append(lead)
        row.children.append(trail)
        // Shapes, and nothing else: the ways to make them one, as the Mac's ArrangePicks.
        let kinds = Set(session.selectedLayers.map(\.kind))
        guard kinds.isSubset(of: ["rectangle", "ellipse", "path"]) else { return row }
        let both = StackPanel()
        both.spacing = 4
        both.children.append(row)
        let ways = StackPanel()
        ways.orientation = .horizontal
        ways.margin = Theme.inset(-4, 0, 0, 0)
        let can = WindowsCore.canCombine(ids)
        for way in WindowsCore.combines {
            ways.children.append(combineButton(way) { [weak self] in
                guard let self, let made = WindowsCore.combine(ids, way) else { MessageBeep(0); return }
                self.session.select([made], on: board)
                self.session.edited(board: board)
            })
        }
        // Then, a little apart, building with the pieces they cut each other into.
        let gap = Border()
        gap.width = 8
        ways.children.append(gap)
        let builder = session.builder
        ways.children.append(buildButton(on: builder.active) { [weak self] in
            guard let self else { return }
            if builder.active { builder.building = nil } else if !builder.start(ids) { MessageBeep(0) }
            self.session.changed()
        })
        ways.opacity = can ? 1 : 0.35
        ways.isHitTestVisible = can
        both.children.append(ways)
        if builder.active {
            let words = Controls.caption("Drag across pieces to join them into one shape, or click one to make it its own. Hold Alt to wipe pieces away.")
            words.margin = Theme.inset(0, 4, 0, 0)
            both.children.append(words)
        }
        return both
    }

    /// The Build button, as the Mac's CombineButton draws it with no way: the overlap shaded, both
    /// outlines, and a stroke across all three, as the drag that joins them goes; lit while on.
    private func buildButton(on: Bool, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 14, action: action)
        press.hoverWash = 0.08
        press.box.width = 28
        press.box.height = 28
        press.onLook = { Theme.brush(Theme.ink, 0.12) }
        press.isOn = on
        let glyph = WindowsCore.buildGlyph()
        let canvas = Canvas()
        canvas.width = 28
        canvas.height = 28
        canvas.isHitTestVisible = false
        var lines: [WinUI.Path] = []
        func shape(_ data: String, width: Double) -> WinUI.Path? {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(width)' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>"
            return (try? XamlReader.load(xaml)) as? WinUI.Path
        }
        let ink = on ? Theme.ink(1) : Theme.ink(2)
        if let shade = shape(glyph.shade, width: 0) {
            shade.fill = ink
            shade.opacity = 0.3
            canvas.children.append(shade)
        }
        for data in glyph.outlines + [glyph.swipe] {
            guard let line = shape(data, width: data == glyph.swipe ? 1.6 : 1) else { continue }
            line.stroke = ink
            canvas.children.append(line)
            lines.append(line)
        }
        press.box.child = canvas
        if !on {
            press.box.pointerEntered.addHandler { _, _ in for l in lines { l.stroke = Theme.ink(1) } }
            press.box.pointerExited.addHandler { _, _ in for l in lines { l.stroke = Theme.ink(2) } }
        }
        try? ToolTipService.setToolTip(press.box, Words.t(on ? "Done building  Enter"
            : "Build: drag across the pieces the shapes make to join them, or wipe them away with Alt  Ctrl+Alt+B"))
        return press.box
    }

    /// One way of making shapes one, drawn as what it does to two overlapping squares (the
    /// Mac's CombineButton): what is left shaded, the outlines over it, ink under the pointer.
    private func combineButton(_ way: String, _ action: @escaping @MainActor () -> Void) -> UIElement {
        let press = Pressable(radius: 14, action: action)
        press.hoverWash = 0.08
        press.box.width = 28
        press.box.height = 28
        let glyph = WindowsCore.combineGlyph(way)
        let canvas = Canvas()
        canvas.width = 28
        canvas.height = 28
        canvas.isHitTestVisible = false
        var lines: [WinUI.Path] = []
        func shape(_ data: String, fill: Bool) -> WinUI.Path? {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='1'/>"
            return (try? XamlReader.load(xaml)) as? WinUI.Path
        }
        if let shade = shape(glyph.shade, fill: true) {
            shade.fill = Theme.ink(2)
            shade.opacity = 0.3
            canvas.children.append(shade)
        }
        for data in glyph.outlines {
            guard let line = shape(data, fill: false) else { continue }
            line.stroke = Theme.ink(2)
            canvas.children.append(line)
            lines.append(line)
        }
        press.box.child = canvas
        press.box.pointerEntered.addHandler { _, _ in for l in lines { l.stroke = Theme.ink(1) } }
        press.box.pointerExited.addHandler { _, _ in for l in lines { l.stroke = Theme.ink(2) } }
        try? ToolTipService.setToolTip(press.box, Words.t(WindowsCore.combineTitle(way)))
        return press.box
    }

    /// Flip left to right and top to bottom: two buttons, 28 square, dimmed when they would change nothing.
    private func flipButtons(_ ids: [UUID], board: Int) -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 2
        let can = WindowsCore.canFlip(ids)
        for horizontally in [true, false] {
            let button = Pressable(radius: 7) { [weak self] in
                WindowsCore.flip(ids, horizontally: horizontally)
                self?.session.edited(board: board)
            }
            button.box.width = 28
            button.box.height = 28
            let glyph = Glyphs.view(Glyphs.flip(horizontally: horizontally), size: 16, brush: Theme.ink(2))
            glyph.horizontalAlignment = .center
            glyph.verticalAlignment = .center
            button.box.child = glyph
            button.box.opacity = can ? 1 : 0.35
            button.box.isHitTestVisible = can
            row.children.append(button.box)
        }
        return row
    }

    func pair(_ first: UIElement, _ second: UIElement?) -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = Self.columnGap
        row.children.append(first)
        if let second { row.children.append(second) }
        return row
    }

    /// A number in a well, as the Mac's NumberField: 28 tall, radius 7, its label inside at the
    /// left (11 pt medium, ink 3) and the number 12 pt. A sideways drag anywhere on it scrubs the
    /// value, `scrub` a point of travel, in pencil, Shift in whole tens; a click types, and Enter
    /// or leaving sets what was typed, Esc puts it back; the arrow keys step it, Shift by ten.
    func field(_ label: String, _ value: Double?, unit: String = "", range: ClosedRange<Double> = -100_000...100_000,
               scrub: Double = 1, width: Double = Inspector.column, decimals: Int? = nil, each: ((Double) -> Void)? = nil,
               set: @escaping (Double) -> Void) -> FrameworkElement {
        // With `decimals`, its number is shown and scrubbed to that many places, as the Mac's
        // NumberField; without, to one place shown and whole numbers scrubbed.
        let number: (Double) -> String = { v in decimals.map { Inspector.number(v, places: $0) } ?? self.number(v) }
        let well = Theme.well(radius: 7)
        well.width = width
        well.height = 28
        let grid = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            grid.columnDefinitions.append(column)
        }
        let name = Theme.text(label, size: 11, weight: 500, ink: 3)
        name.minWidth = 12
        name.margin = Theme.inset(8, 0, 0, 0)
        name.verticalAlignment = .center
        grid.children.append(name)

        let shown = value.map(number) ?? "–"
        let box = TextBox()
        // The panel takes no focus from clicks (so a click between cards leaves the fields alone);
        // a field itself does.
        box.allowFocusOnInteraction = true
        box.text = shown
        box.fontFamily = Theme.ui
        box.fontSize = 12
        // Wrapping, a box shows no button to clear it, which a field of a few letters has no room
        // for; it shows only while typing, so the box wraps only then, and a number too long for
        // a narrow field is cut at its end rather than broken onto a second line.
        box.textWrapping = .noWrap
        box.minWidth = 0
        box.minHeight = 0
        box.padding = Theme.inset(4, 5, 4, 0)
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        box.background = Theme.clear
        box.foreground = Theme.ink(1)
        // The well is the field in every state: WinUI's own hover and focus looks are put away.
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        try? Grid.setColumn(box, 1)
        grid.children.append(box)
        var tail: TextBlock?
        if !unit.isEmpty {
            let u = Theme.text(unit, size: 11, ink: 3)
            u.verticalAlignment = .center
            u.margin = Theme.inset(0, 0, 7, 0)
            try? Grid.setColumn(u, 2)
            grid.children.append(u)
            tail = u
        }
        // Over it all, what scrubs; put aside while typing, so the caret goes where it is clicked.
        let cover = Border()
        cover.background = Theme.clear
        try? Grid.setColumnSpan(cover, 3)
        grid.children.append(cover)
        well.child = grid
        let edge = Border()
        edge.cornerRadius = Theme.corners(7)
        edge.borderThickness = Theme.inset(1)
        edge.borderBrush = Theme.clear
        edge.isHitTestVisible = false
        try? Grid.setColumnSpan(edge, 3)
        grid.children.append(edge)

        let restWell = well.background
        var done = false
        func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
        func commit() {
            guard !done else { return }
            let typed = box.text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            guard typed != shown, let v = Double(typed) else { return }
            done = true
            set(clamp(v))
        }
        func step(_ by: Double) {
            // Several values (each set apart by `each`): each moved by as much.
            if value == nil, let each, Double(box.text.replacingOccurrences(of: ",", with: ".")) == nil {
                done = true
                each(by)
                return
            }
            let now = Double(box.text.replacingOccurrences(of: ",", with: ".")) ?? value ?? 0
            let v = clamp(now + by * (decimals.map { $0 >= 2 ? 0.1 : 1 } ?? 1))
            box.text = number(v)
            done = true
            set(v)
        }
        box.previewKeyDown.addHandler { _, args in
            guard let args else { return }
            let shift = GetKeyState(Int32(VK_SHIFT)) < 0
            switch args.key {
            // Enter sets it and Esc puts it back; either way the keys go back to the canvas, whose
            // taking them ends the typing (and leaving sets what was typed).
            case .enter: args.handled = true; if let back = self.returnFocus { back() } else { commit() }
            case .escape: args.handled = true; box.text = shown; done = true; self.returnFocus?()
            case .up: args.handled = true; step(shift ? 10 : 1)
            case .down: args.handled = true; step(shift ? -10 : -1)
            default: break
            }
        }
        box.lostFocus.addHandler { _, _ in
            cover.isHitTestVisible = true
            edge.borderBrush = Theme.clear
            box.textWrapping = .noWrap
            commit()
        }
        box.gotFocus.addHandler { _, _ in
            box.textWrapping = .wrap
            edge.borderBrush = Theme.brush(Theme.ink, 0.35)
        }

        var start: (x: Double, value: Double)?
        var scrubbing = false
        var scrubbed = 0.0
        func look(_ on: Bool) {
            well.background = on ? Theme.brush(Theme.mix(Theme.well, Theme.pencil, Theme.pencilWash)) : restWell
            edge.borderBrush = on ? Theme.brush(Theme.pencil, 0.6) : Theme.clear
            name.foreground = on ? Theme.brush(Theme.pencil) : Theme.ink(3)
            box.foreground = on ? Theme.brush(Theme.pencil) : Theme.ink(1)
            tail?.foreground = on ? Theme.brush(Theme.pencil, 0.7) : Theme.ink(3)
        }
        cover.pointerEntered.addHandler { _, _ in if start == nil { name.foreground = Theme.ink(2) } }
        cover.pointerExited.addHandler { _, _ in if start == nil { name.foreground = Theme.ink(3) } }
        cover.pointerPressed.addHandler { sender, args in
            // Kept here: bubbled up, the scroll view would put the focus on its first field.
            args?.handled = true
            guard let p = try? args?.getCurrentPoint(well)?.position else { return }
            start = (Double(p.x), value ?? 0)
            scrubbing = false
            scrubbed = 0
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
        }
        cover.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let s = start, let p = try? args?.getCurrentPoint(well)?.position else { return }
            let dx = Double(p.x) - s.x
            guard scrubbing || abs(dx) >= 3 else { return }
            if !scrubbing {
                scrubbing = true
                self.dialing = true
                WindowsCore.beginGesture()
                look(true)
            }
            var v = s.value + dx * scrub
            if let decimals {
                let step = pow(10, -Double(decimals))
                v = GetKeyState(Int32(VK_SHIFT)) < 0 ? (v / (step * 10)).rounded() * step * 10 : (v / step).rounded() * step
            } else {
                v = GetKeyState(Int32(VK_SHIFT)) < 0 ? (v / 10).rounded() * 10 : v.rounded()
            }
            v = clamp(v)
            box.text = number(v)
            // Several values: each moved by as far as the drag has gone since the last step.
            if value == nil, let each {
                each(v - scrubbed)
                scrubbed = v
            } else {
                set(v)
            }
        }
        cover.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, start != nil else { return }
            args?.handled = true
            start = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            if scrubbing {
                scrubbing = false
                WindowsCore.endGesture()
                look(false)
                self.dialing = false
                self.show()
            } else {
                cover.isHitTestVisible = false
                if (try? box.focus(.pointer)) != true { _ = try? box.focus(.programmatic) }
                try? box.selectAll()
            }
        }
        return well
    }

    /// A colour as six hex digits, and its opacity in per cent.
    private func hexField(_ hex: String, alpha: Double, set: @escaping (String, Double) -> Void) -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        let colour = numberBox("#" + hex)
        colour.width = 110
        let percent = numberBox("\(Int((alpha * 100).rounded()))")
        percent.width = 56
        func commit() {
            let a = (Double(percent.text.replacingOccurrences(of: "%", with: "")) ?? alpha * 100) / 100
            set(colour.text, a)
        }
        for box in [colour, percent] {
            box.keyDown.addHandler { _, args in if args?.key == .enter { args?.handled = true; commit() } }
            box.lostFocus.addHandler { _, _ in commit() }
            row.children.append(box)
        }
        return row
    }

    private func numberBox(_ text: String) -> TextBox {
        let box = TextBox()
        box.allowFocusOnInteraction = true
        box.text = text
        box.fontFamily = Theme.ui
        box.fontSize = 12
        box.minHeight = 24
        box.padding = Theme.inset(7, 3, 6, 0)
        box.background = Theme.brush(Theme.well)
        box.borderThickness = Theme.inset(0)
        box.cornerRadius = Theme.corners(6)
        return box
    }

    /// Dashed chips, 28 tall, radius 8, for adding what the selection has not got.
    /// Each chip's title, the card it opens once added, and what it adds.
    func chips(_ items: [(String, String, () -> Void)], board: Int, previews: [String: @MainActor (Bool) -> Void] = [:]) -> UIElement {
        let wrap = StackPanel()
        wrap.spacing = 6
        var row: StackPanel?
        var used = 0.0
        for item in items {
            let label = Theme.text("+ " + Words.t(item.0), size: 12, ink: 2)
            label.margin = Theme.inset(10, 0, 10, 0)
            try? label.measure(Size(width: 400, height: 28))
            let width = Double(label.desiredSize.width)
            // A new row when this chip would reach past the panel, as the Mac's flow of chips does:
            // the words are longer in German.
            if row == nil || used + 6 + width > Theme.cardWidth {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 6
                wrap.children.append(r)
                row = r
                used = width
            } else {
                used += 6 + width
            }
            let chip = Grid()
            chip.height = 28
            let edge = Rectangle()
            edge.radiusX = 8
            edge.radiusY = 8
            edge.stroke = Theme.ink(4)
            edge.strokeThickness = 1
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(2.5)
            edge.strokeDashArray = dashes
            chip.children.append(edge)
            chip.children.append(label)
            let preview = previews[item.0]
            let press = Pressable(radius: 8) { [weak self] in
                preview?(false)
                item.2()
                self?.opened = item.1
                self?.session.edited(board: board)
            }
            press.box.child = chip
            // Pointed at, what it would add shows on the canvas, as the Mac's AddBar reshapes it.
            if let preview {
                press.box.pointerEntered.addHandler { _, _ in preview(true) }
                press.box.pointerExited.addHandler { _, _ in preview(false) }
            }
            row?.children.append(press.box)
        }
        return wrap
    }

    /// The tools and their keys, for when nothing is selected.
    private func toolsCard() -> UIElement {
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        let list = StackPanel()
        list.margin = Theme.inset(12, 8, 12, 8)
        func line(_ glyph: [Glyphs.Part]?, _ title: String, _ key: String) {
            let row = Grid()
            row.height = 30
            let lead = StackPanel()
            lead.orientation = .horizontal
            lead.spacing = 10
            lead.verticalAlignment = .center
            if let glyph { lead.children.append(Glyphs.view(glyph, size: 16, brush: Theme.ink(2))) }
            lead.children.append(Theme.text(Words.t(title), size: 12.5, ink: 1))
            row.children.append(lead)
            let cap = Theme.well(radius: 5)
            cap.height = 20
            cap.minWidth = 22
            cap.horizontalAlignment = .right
            let letter = Theme.text(Words.t(key), size: 11, weight: 500, ink: 2)
            letter.horizontalAlignment = .center
            letter.margin = Theme.inset(6, 0, 6, 0)
            cap.child = letter
            row.children.append(cap)
            list.children.append(row)
        }
        for tool in Glyphs.Tool.allCases { line(Glyphs.tool(tool, size: 16), tool.title, tool.key) }
        line(nil, "Move around", "Space")
        card.child = list
        return card
    }

    // MARK: Words

    private func summary(_ paint: WindowsCore.Paint) -> String {
        if paint.picture { return "Picture" }
        if paint.gradient { return "Gradient" }
        return "#\(paint.hex) · \(Int((paint.alpha * 100).rounded()))%"
    }

    func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// A number to as many places as it has, at most `places`.
    static func number(_ v: Double, places: Int) -> String {
        var s = String(format: "%.\(max(places, 0))f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}
