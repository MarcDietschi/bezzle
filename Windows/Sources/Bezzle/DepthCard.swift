import Foundation
import WinUI
import UWP
import WinSDK
import BezzleCore

/// The 3D card, as the Mac's (LookCards.depthCard): layers held up off the page. The drag tips
/// them further, the way they are already turned; open, the pad aims them (the card faces the
/// pointer), and under it the exact tip, swing and nearness. Several layers lying together are one
/// body: the card says how its lead is turned, and what turns that turns them all about the
/// middle they share (the core's `turning`). A group has a switch besides: whether what it holds
/// keeps its depth, each layer standing in the scene, or the group is one card.
extension Inspector {
    func depthCard(_ l: WindowsCore.Looks, change: @escaping @MainActor (WindowsCore.LookChange) -> Void) -> UIElement? {
        guard let d = l.depth else { return nil }
        let ids = session.selection
        let now = hypot(d.x, d.y)
        let dial = Dial(fraction: now / 60, set: { WindowsCore.change(ids, .tip((($0 * 60) / 2).rounded() * 2)) },
                        summary: { f in
                            let by = ((f * 60) / 2).rounded() * 2
                            let t = WindowsCore.tipped(x: d.x, y: d.y, by: by)
                            return "\(Int(t.x.rounded()))°, \(Int(t.y.rounded()))°"
                        }, stops: [])
        return card("3D", d.summary, mark: Self.cardInDepth(x: d.x, y: d.y, width: 19, height: 15), dial: dial,
                    remove: { change(.removeDepth) }, removal: "Remove 3D", body: { [self] in
            let w = (Theme.cardWidth - 24 - 16) / 3
            let fields = StackPanel()
            fields.orientation = .horizontal
            fields.spacing = 8
            fields.children.append(field("X", d.xs, unit: "°", range: -180...180, scrub: 0.5, width: w) { change(.depthX($0)) })
            fields.children.append(field("Y", d.ys, unit: "°", range: -180...180, scrub: 0.5, width: w) { change(.depthY($0)) })
            fields.children.append(field("Z", d.zs, range: -10_000...10_000, scrub: 1, width: w) { change(.depthZ($0)) })
            var rows: [UIElement] = [aimPad(x: d.x, y: d.y, change: change), fields]
            // A group is one card, unless told that what it holds stands in the scene on its own.
            if d.groups { rows.append(Self.switchRow("Layers keep their depth", d.keepDepth) { change(.keepDepth($0)) }) }
            rows.append(Controls.caption("On the canvas, drag the knob in its middle to aim it. Hold Alt once a layer is moving to bring it nearer or push it away. Just outside a side, a drag turns anything in depth."))
            return rows
        })
    }

    /// A switch with its words before it, which take what room the switch leaves and wrap: what
    /// a group's switch says is longer than a row's column of titles, in every language.
    private static func switchRow(_ title: String, _ on: Bool, _ set: @escaping @MainActor (Bool) -> Void) -> FrameworkElement {
        let grid = Grid()
        grid.minHeight = Controls.height
        grid.columnSpacing = 8
        for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            grid.columnDefinitions.append(column)
        }
        let words = Theme.text(Words.t(title), size: 12, ink: 2)
        words.verticalAlignment = .center
        words.textWrapping = .wrap
        grid.children.append(words)
        let toggle = Controls.toggle(on, set)
        toggle.verticalAlignment = .center
        try? Grid.setColumn(toggle, 1)
        grid.children.append(toggle)
        return grid
    }

    /// The Mac's CardInDepth: a card turned as the layer is, its perspective strong enough to
    /// read small; lit from above the page, darker as it turns away, grey from behind; its top
    /// edge stronger, so which way up it is reads.
    static func cardInDepth(x: Double, y: Double, width: Double, height: Double) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = width
        canvas.height = height
        canvas.isHitTestVisible = false
        let card = WindowsCore.cardInDepth(x: x, y: y, size: CGSize(width: width, height: height))
        let pts = card.corners
        var outline = PathData()
        outline.move(Double(pts[0].x), Double(pts[0].y))
        for p in pts.dropFirst() { outline.line(Double(p.x), Double(p.y)) }
        outline.close()
        var top = PathData()
        top.move(Double(pts[0].x), Double(pts[0].y))
        top.line(Double(pts[1].x), Double(pts[1].y))
        func path(_ d: String, width: Double = 1) -> WinUI.Path? {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d)' StrokeThickness='\(width)' StrokeLineJoin='Round'/>"
            return (try? XamlReader.load(xaml)) as? WinUI.Path
        }
        if let face = path(outline.d) {
            face.fill = card.back ? Theme.brush(Theme.ink, 0.18) : Theme.brush(Theme.card)
            canvas.children.append(face)
        }
        if !card.back, let shade = path(outline.d) {
            shade.fill = Theme.brush(0x000000, card.shade)
            canvas.children.append(shade)
        }
        if let rim = path(outline.d) {
            rim.stroke = Theme.brush(Theme.ink, 0.5)
            canvas.children.append(rim)
        }
        if let edge = path(top.d, width: 1.6) {
            edge.stroke = Theme.ink(1)
            canvas.children.append(edge)
        }
        return canvas
    }

    /// The Mac's AimPad: a well with a cross and a dashed ring (where the face is seen edge on),
    /// the card in the middle and a knob where it faces. Drag to aim it, from the knob without a
    /// jump; Shift in steps of 15°; a double click lays it flat.
    private func aimPad(x: Double, y: Double, change: @escaping @MainActor (WindowsCore.LookChange) -> Void) -> UIElement {
        let width = Theme.cardWidth - 24, height = 100.0, radius = 38.0
        let well = Theme.well(radius: 9)
        well.width = width
        well.height = height
        let pad = Canvas()
        pad.width = width
        pad.height = height
        pad.background = Theme.clear
        well.child = pad
        let c = CGPoint(x: width / 2, y: height / 2)
        var cross = PathData()
        cross.move(Double(c.x) - radius, Double(c.y)); cross.line(Double(c.x) + radius, Double(c.y))
        cross.move(Double(c.x), Double(c.y) - radius); cross.line(Double(c.x), Double(c.y) + radius)
        var ringData = PathData()
        ringData.move(Double(c.x) - radius, Double(c.y))
        ringData.d += String(format: "A%.2f,%.2f 0 1 1 %.2f,%.2f A%.2f,%.2f 0 1 1 %.2f,%.2f Z", radius, radius, Double(c.x) + radius, Double(c.y), radius, radius, Double(c.x) - radius, Double(c.y))
        for (d, alpha, dashed) in [(cross.d, 0.07, false), (ringData.d, 0.16, true)] {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d)' StrokeThickness='1'" + (dashed ? " StrokeDashArray='2 3'" : "") + "/>"
            if let path = (try? XamlReader.load(xaml)) as? WinUI.Path {
                path.stroke = Theme.brush(Theme.ink, alpha)
                path.isHitTestVisible = false
                pad.children.append(path)
            }
        }
        let moving = Canvas()
        moving.isHitTestVisible = false
        pad.children.append(moving)
        var turn = (x: x, y: y)
        func knobAt() -> CGPoint {
            let f = WindowsCore.facing(x: turn.x, y: turn.y)
            return CGPoint(x: c.x + f.x * radius, y: c.y + f.y * radius)
        }
        func show() {
            moving.children.clear()
            let card = Self.cardInDepth(x: turn.x, y: turn.y, width: 44, height: 32)
            try? Canvas.setLeft(card, Double(c.x) - 22)
            try? Canvas.setTop(card, Double(c.y) - 16)
            moving.children.append(card)
            let k = knobAt()
            var line = PathData()
            line.move(Double(c.x), Double(c.y))
            line.line(Double(k.x), Double(k.y))
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(line.d)' StrokeThickness='1.25'/>"
            if let path = (try? XamlReader.load(xaml)) as? WinUI.Path {
                path.stroke = Theme.ink(1)
                moving.children.append(path)
            }
            let knob = Border()
            knob.width = 12
            knob.height = 12
            knob.cornerRadius = Theme.corners(6)
            knob.background = Theme.brush(Theme.card)
            knob.borderBrush = Theme.ink(1)
            knob.borderThickness = Theme.inset(1)
            let pip = Border()
            pip.width = 3.5
            pip.height = 3.5
            pip.cornerRadius = Theme.corners(1.75)
            pip.background = Theme.ink(1)
            pip.horizontalAlignment = .center
            pip.verticalAlignment = .center
            knob.child = pip
            try? Canvas.setLeft(knob, Double(k.x) - 6)
            try? Canvas.setTop(knob, Double(k.y) - 6)
            moving.children.append(knob)
        }
        show()

        var grip: CGPoint?
        var lastTap: UInt32 = 0
        pad.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let at = try? args?.getCurrentPoint(pad)?.position else { return }
            args?.handled = true
            let s = CGPoint(x: Double(at.x), y: Double(at.y))
            let now = GetTickCount()
            if now - lastTap <= GetDoubleClickTime() {
                lastTap = 0
                change(.layFlat)
                return
            }
            lastTap = now
            // Taken by the knob, it does not jump; anywhere else, it faces there at once.
            let k = knobAt()
            grip = hypot(s.x - k.x, s.y - k.y) <= 12 ? CGPoint(x: k.x - s.x, y: k.y - s.y) : .zero
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            WindowsCore.beginGesture()
            self.dialing = true
            aim(s)
        }
        func aim(_ p: CGPoint) {
            guard let grip else { return }
            let at = CGPoint(x: p.x + grip.x - c.x, y: p.y + grip.y - c.y)
            turn = WindowsCore.turn(facing: CGPoint(x: at.x / radius, y: at.y / radius), steps: GetKeyState(Int32(VK_SHIFT)) < 0)
            change(.aim(turn.x, turn.y))
            show()
        }
        pad.pointerMoved.addHandler { _, args in
            guard grip != nil, let at = try? args?.getCurrentPoint(pad)?.position else { return }
            aim(CGPoint(x: Double(at.x), y: Double(at.y)))
        }
        pad.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, grip != nil else { return }
            grip = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            self.session.edited(board: self.session.board)
        }
        try? ToolTipService.setToolTip(well, Words.t("Drag to aim it: the card faces where you point. Double click to lay it flat."))
        return well
    }
}
