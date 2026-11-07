import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// The Blur card, as the Mac's (LookCards.blurCard): a blur of the layer itself, or of what lies
/// behind it as frosted glass (only shapes have an outline to show it through). The drag sets how
/// much, catching at each preset; past nothing the blur comes away. Open: the layer or what's
/// behind, the presets, all over or growing toward an edge (with the pad to place where), the
/// exact amount, and behind, how light and how much of the layer's fill lies over it.
extension Inspector {
    func blurCard(_ l: WindowsCore.Looks, canBlurBehind: Bool,
                  change: @escaping @MainActor (WindowsCore.LookChange) -> Void,
                  preview: @escaping @MainActor (WindowsCore.LookChange?) -> Void) -> UIElement? {
        guard let b = l.blur else { return nil }
        let behind = canBlurBehind && b.behind
        let presets = WindowsCore.blurPresets
        func said(_ radius: Double?) -> String {
            var words: [String] = []
            if behind { words.append("Behind") }
            if let radius {
                if let named = presets.first(where: { $0.radius == radius }) { words += [named.name, number(radius)] } else { words.append(number(radius)) }
            } else {
                words.append("Several")
            }
            if b.growing { words.append("Growing") }
            return words.joined(separator: " · ")
        }
        let r = b.firstRadius, top = max(40, r)
        let ids = session.selection
        let dial = Dial(fraction: r / top, set: { WindowsCore.change(ids, .blurAmount(($0 * top).rounded())) },
                        summary: { said(($0 * top).rounded()) }, stops: presets.map { $0.radius / top })
        let mark = Self.blurGlyph(amount: min(r / 32, 1), behind: behind)
        return card("Blur", said(b.radius), mark: mark, dial: dial, remove: { change(.removeBlur) }, removal: "Remove blur", body: { [self] in
            var rows: [UIElement] = []
            if canBlurBehind {
                rows.append(Controls.segmented(behind, [(false, "The layer"), (true, "What's behind")], width: Theme.cardWidth - 24) { change(.blurBehind($0)) })
            }
            rows.append(Controls.presetStrip(presets.indices.map { k in
                (Self.blurGlyph(amount: Double(k) / Double(max(presets.count - 1, 1)), behind: behind), b.preset == k)
            }, width: Theme.cardWidth - 24, point: { k in preview(k.map { .blurPreset($0) }) }, choose: { change(.blurPreset($0)) }))
            rows.append(Controls.segmented(b.growing, [(false, "All over"), (true, "Growing")], width: Theme.cardWidth - 24) { change(.blurGrowing($0)) })
            if b.growing, let ramp = b.ramp {
                rows.append(rampPad(start: ramp.start, end: ramp.end, aspect: b.aspect, change: change))
                let ramps = WindowsCore.rampPresets
                rows.append(Controls.presetStrip(ramps.indices.map { k in (Self.rampGlyph(edge: ramps[k].edge), b.rampPreset == k) },
                                                 width: Theme.cardWidth - 24, point: { k in preview(k.map { .blurRampPreset($0) }) },
                                                 choose: { change(.blurRampPreset($0)) }))
            }
            rows.append(Controls.row("Amount", field("", b.radius, range: 0...500, scrub: 0.25) { change(.blurAmount($0)) }))
            if behind {
                rows.append(Controls.row("Light", field("", b.light, unit: "%", range: -100...100, scrub: 0.5) { change(.blurLight($0)) }))
                rows.append(Controls.row("Fill", field("", b.fill, unit: "%", range: 0...100, scrub: 0.5) { change(.blurFill($0)) }))
                rows.append(Controls.caption("Light brightens what shows through, or darkens it below zero. Fill is how much of the layer's own colour lies over it."))
            }
            if b.growing {
                rows.append(Controls.caption("A growing blur is sharp at the ring and blurs by the whole amount at the dot."))
            }
            return rows
        })
    }

    /// A picture the core draws, `size` big, at twice its points for a sharp edge.
    static func rendered(_ size: CGSize, _ draw: (_ scale: Double, _ fill: (Int, Int) -> UnsafeMutableRawPointer?) -> Bool) -> Image {
        let image = Image()
        image.width = Double(size.width)
        image.height = Double(size.height)
        image.isHitTestVisible = false
        var bitmap: WriteableBitmap?
        _ = draw(2) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        image.source = bitmap
        return image
    }

    /// The Mac's BlurGlyph: a dot softened by `amount`, or half under a pane that blurs it.
    static func blurGlyph(amount: Double, behind: Bool) -> FrameworkElement {
        rendered(CGSize(width: 18, height: 18)) { scale, fill in
            WindowsCore.blurGlyph(amount: amount, behind: behind, ink: Theme.ink, scale: scale, into: fill)
        }
    }

    /// The Mac's RampGlyph: a square that darkens toward one edge, as a blur that grows toward
    /// it does (0 the bottom, then the left, top and right).
    static func rampGlyph(edge: Int) -> FrameworkElement {
        let ends: (Point, Point) = switch edge % 4 {
        case 1: (Point(x: 1, y: 0.5), Point(x: 0, y: 0.5))
        case 2: (Point(x: 0.5, y: 1), Point(x: 0.5, y: 0))
        case 3: (Point(x: 0, y: 0.5), Point(x: 1, y: 0.5))
        default: (Point(x: 0.5, y: 0), Point(x: 0.5, y: 1))
        }
        let h = Theme.ink
        let ink = (r: Double((h >> 16) & 0xFF) / 255, g: Double((h >> 8) & 0xFF) / 255, b: Double(h & 0xFF) / 255)
        let square = Border()
        square.width = 15
        square.height = 15
        square.cornerRadius = Theme.corners(2.5)
        square.background = Colours.gradient([(0, WindowsCore.Colour(r: ink.r, g: ink.g, b: ink.b, a: 0)), (1, WindowsCore.Colour(r: ink.r, g: ink.g, b: ink.b, a: 0.8))],
                                             from: ends.0, to: ends.1)
        square.borderBrush = Theme.ink(1)
        square.borderThickness = Theme.inset(1)
        square.isHitTestVisible = false
        return square
    }

    /// Where a growing blur grows, as the Mac's RampPad: the layer in small (its proportions)
    /// with marks on it, blurred as the ramp has it; the ring where it is sharp, the dot where the
    /// blur is whole. Drag either, or across to draw it afresh (Shift in steps of 45°); a double
    /// click blurs toward the bottom again.
    private func rampPad(start: CGPoint, end: CGPoint, aspect: Double, change: @escaping @MainActor (WindowsCore.LookChange) -> Void) -> UIElement {
        let width = Theme.cardWidth - 24, height = 100.0
        let well = Theme.well(radius: 9)
        well.width = width
        well.height = height
        let pad = Canvas()
        pad.width = width
        pad.height = height
        pad.background = Theme.clear
        well.child = pad
        // The layer in the pad: as large as fits with room round it for the ends.
        let room = (w: max(width - 56, 20), h: max(height - 28, 20))
        let a = min(max(aspect.isFinite && aspect > 0 ? aspect : 1, 0.25), 4)
        let bw = min(room.w, room.h * a), bh = bw / a
        let box = CGRect(x: (width - bw) / 2, y: (height - bh) / 2, width: bw, height: bh)
        func view(_ u: CGPoint) -> CGPoint { CGPoint(x: box.minX + u.x * box.width, y: box.minY + u.y * box.height) }
        func unit(_ v: CGPoint) -> CGPoint {
            func clamp(_ x: BezzleCore.CGFloat) -> BezzleCore.CGFloat { (min(max(x, -0.25), 1.25) * 1000).rounded() / 1000 }
            return CGPoint(x: clamp((v.x - box.minX) / box.width), y: clamp((v.y - box.minY) / box.height))
        }
        var ramp = (start: start, end: end)

        let sample = Canvas()
        try? Canvas.setLeft(sample, Double(box.minX))
        try? Canvas.setTop(sample, Double(box.minY))
        pad.children.append(sample)
        let line = Canvas()
        line.isHitTestVisible = false
        pad.children.append(line)
        func knob(_ filled: Bool) -> Border {
            let k = Border()
            k.width = 12
            k.height = 12
            k.cornerRadius = Theme.corners(6)
            k.background = Theme.brush(filled ? Theme.ink : Theme.card)
            k.borderBrush = Theme.brush(filled ? Theme.card : Theme.ink)
            k.borderThickness = Theme.inset(filled ? 1.5 : 1.25)
            k.isHitTestVisible = false
            return k
        }
        let ring = knob(false), dot = knob(true)
        pad.children.append(ring)
        pad.children.append(dot)
        func show() {
            sample.children.clear()
            sample.children.append(Self.rendered(box.size) { scale, fill in
                WindowsCore.rampSample(size: box.size, start: ramp.start, end: ramp.end, card: Theme.card, ink: Theme.ink, scale: scale, into: fill)
            })
            let p = view(ramp.start), q = view(ramp.end)
            line.children.clear()
            var d = PathData()
            d.move(Double(p.x), Double(p.y))
            d.line(Double(q.x), Double(q.y))
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1.25' StrokeDashArray='2.4 2'/>"
            if let path = (try? XamlReader.load(xaml)) as? WinUI.Path {
                path.stroke = Theme.ink(1)
                line.children.append(path)
            }
            try? Canvas.setLeft(ring, Double(p.x) - 6)
            try? Canvas.setTop(ring, Double(p.y) - 6)
            try? Canvas.setLeft(dot, Double(q.x) - 6)
            try? Canvas.setTop(dot, Double(q.y) - 6)
        }
        show()

        enum Grip { case start, end, fresh(CGPoint) }
        var grip: Grip?
        var lastTap: UInt32 = 0
        pad.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let at = try? args?.getCurrentPoint(pad)?.position else { return }
            args?.handled = true
            let s = CGPoint(x: Double(at.x), y: Double(at.y))
            let now = GetTickCount()
            if now - lastTap <= GetDoubleClickTime() {
                // Twice: toward the bottom again.
                lastTap = 0
                change(.blurRampPreset(0))
                return
            }
            lastTap = now
            let a = view(ramp.start), b = view(ramp.end)
            grip = hypot(s.x - a.x, s.y - a.y) <= 12 ? .start : hypot(s.x - b.x, s.y - b.y) <= 12 ? .end : .fresh(s)
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            WindowsCore.beginGesture()
            self.dialing = true
        }
        pad.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let g = grip, let at = try? args?.getCurrentPoint(pad)?.position else { return }
            var p = CGPoint(x: Double(at.x), y: Double(at.y))
            // With Shift, as far from the other end in the nearest of every 45°.
            func settled(_ p: CGPoint, from o: CGPoint) -> CGPoint {
                guard GetKeyState(Int32(VK_SHIFT)) < 0 else { return p }
                let length = hypot(p.x - o.x, p.y - o.y)
                let angle = (atan2(p.y - o.y, p.x - o.x) / (.pi / 4)).rounded() * (.pi / 4)
                return CGPoint(x: o.x + cos(angle) * length, y: o.y + sin(angle) * length)
            }
            switch g {
            case .start: p = settled(p, from: view(ramp.end)); ramp.start = unit(p)
            case .end: p = settled(p, from: view(ramp.start)); ramp.end = unit(p)
            case .fresh(let from):
                // A press that has not gone anywhere yet leaves the ramp as it is.
                guard hypot(p.x - from.x, p.y - from.y) > 3 else { return }
                ramp = (unit(from), unit(settled(p, from: from)))
            }
            change(.blurRamp(start: ramp.start, end: ramp.end))
            show()
            _ = self
        }
        pad.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, grip != nil else { return }
            grip = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            self.session.edited(board: self.session.board)
        }
        try? ToolTipService.setToolTip(well, Words.t("Drag the ring, where it is sharp, or the dot, where the blur is whole; or drag across to draw it afresh. Double click to blur toward the bottom."))
        return well
    }
}
