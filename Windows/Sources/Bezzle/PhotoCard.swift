import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// Whether Alt is held, for a row dragged a quarter as fast.
private var altHeld: Bool { GetKeyState(Int32(VK_MENU)) < 0 }

/// The Photo card, as the Mac's PhotoCard: for layers filled with a picture, how it is developed.
///
/// Folded, the drag sets how much of the development there is, from none to twice as much. Open:
/// Light, Colour and Detail, each a list of rows dragged sideways, the colours each with their own
/// hue, strength and lightness, and a double click puts a row back to nothing.
extension Glyphs {
    /// The Mac's ToneGlyph: the picture's tones as a little landscape in a ring.
    static func tones(_ tones: [Double]?, size s: Double = 16) -> [Part] {
        var ring = PathData()
        ring.rect(0.65, 1.65, s - 1.3, s - 3.3, radius: 4)
        // A few steps of the tones, smoothed, as a picture this small can show.
        var steps = [0.15, 0.45, 0.8, 0.6, 0.85, 0.4, 0.15]
        if let tones, !tones.isEmpty {
            let n = 8, per = max(tones.count / n, 1)
            let sums = (0..<n).map { i in tones[(i * per)..<min((i + 1) * per, tones.count)].reduce(0, +) / Double(per) }
            let most = sums.max() ?? 1
            steps = sums.map { most > 0 ? $0 / most : 0 }
        }
        var land = PathData()
        let x0 = 2.5, x1 = s - 2.5, y0 = 1 + 3.5, y1 = s - 1 - 2.5
        func point(_ i: Int) -> (Double, Double) {
            (x0 + Double(i) / Double(steps.count - 1) * (x1 - x0), y1 - pow(min(max(steps[i], 0), 1.15), 0.7) * (y1 - y0) * 0.86)
        }
        land.move(x0, y1)
        let a = point(0)
        land.line(a.0, a.1)
        for i in 1..<steps.count {
            let p = point(i - 1), q = point(i)
            land.quad(p.0, p.1, (p.0 + q.0) / 2, (p.1 + q.1) / 2)
        }
        let last = point(steps.count - 1)
        land.line(last.0, last.1)
        land.line(x1, y1)
        land.close()
        return [Part(data: ring.d, mode: .stroke, width: 1.3), Part(data: land.d, mode: .fill)]
    }

    /// A wand with a spark at its tip, as wand.and.sparkles: Auto.
    static func wand(size s: Double = 14) -> [Part] {
        var stick = PathData()
        stick.move(s * 0.18, s * 0.84)
        stick.line(s * 0.62, s * 0.40)
        var spark = PathData()
        let c = (s * 0.74, s * 0.27), r = s * 0.2, k = s * 0.05
        spark.move(c.0, c.1 - r); spark.line(c.0 + k, c.1 - k); spark.line(c.0 + r, c.1); spark.line(c.0 + k, c.1 + k)
        spark.line(c.0, c.1 + r); spark.line(c.0 - k, c.1 + k); spark.line(c.0 - r, c.1); spark.line(c.0 - k, c.1 - k); spark.close()
        var dots = PathData()
        dots.ellipse(s * 0.3, s * 0.12, s * 0.12, s * 0.12)
        dots.ellipse(s * 0.82, s * 0.62, s * 0.1, s * 0.1)
        return [Part(data: stick.d, mode: .stroke, width: 1.4), Part(data: spark.d, mode: .fill), Part(data: dots.d, mode: .fill)]
    }
}

extension Inspector {
    func photoCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard let p = WindowsCore.photoLook(ids) else { return nil }
        @MainActor func edited() { session.edited(board: board) }
        // Twice as much at the far end, as much as now in the middle, in tens.
        func share(_ f: Double) -> Double { (f * 20).rounded() * 10 }
        let dial = Dial(fraction: p.neutral ? 0 : 0.5, set: { f in WindowsCore.photoStrength(ids, share(f) / 100) },
                        summary: { f in "\(Int(share(f)))%" }, stops: [0.5])
        let tones = WindowsCore.photoTones(ids)
        let mark = Glyphs.view(Glyphs.tones(tones?.tones), size: 16, brush: Theme.ink(2))
        var remove: (@MainActor () -> Void)?
        if !p.neutral { remove = { WindowsCore.resetPhoto(ids); edited() } }
        let auto = Controls.iconButton(Glyphs.wand(), size: 22) { WindowsCore.autoPhoto(ids); edited() }
        try? ToolTipService.setToolTip(auto, Words.t("Develop the photo as suits it best"))
        // Its press is its own, not the card's line's, which would fold the card.
        auto.pointerPressed.addHandler { _, args in args?.handled = true }
        return card("Photo", p.summary, mark: mark, dial: dial, remove: remove, removal: "Back to the original", accessory: auto, body: { [self] in
            photoRows(p, ids: ids, board: board)
        })
    }

    /// The open card: the tabs, the rows of the one chosen, and for Colour, the colours.
    private func photoRows(_ p: WindowsCore.PhotoLook, ids: [UUID], board: Int) -> [UIElement] {
        var rows: [UIElement] = []
        let width = Theme.cardWidth - 24
        rows.append(toneTerrain(ids, board: board))
        rows.append(Controls.segmented(photoGroup, WindowsCore.photoGroups.map { ($0.name, $0.title) }, width: width) { [weak self] g in
            self?.photoGroup = g
            self?.show()
        })
        let list = StackPanel()
        list.spacing = 2
        for s in WindowsCore.photoSettings where s.group == photoGroup {
            let name = s.name
            list.children.append(developRow(s.title, value: p.amounts[name] ?? 0, range: s.low...s.high, decimals: s.decimals,
                                            track: Self.photoTrack(name), mixed: p.mixed.contains(name), board: board,
                                            change: { [weak self] in WindowsCore.setPhoto(ids, name, $0); self?.photoTerrainRefresh?() }))
        }
        rows.append(list)
        if photoGroup == "color" {
            rows.append(colourWheel(ids, board: board))
            if let band = photoBand, let shift = p.bands[band], let hue = WindowsCore.photoBands.first(where: { $0.name == band })?.hue {
                let parts = StackPanel()
                parts.spacing = 2
                let shown: [(String, String, Double)] = [("hue", "Hue", shift.hue), ("saturation", "Saturation", shift.saturation), ("luminance", "Luminance", shift.luminance)]
                for (part, title, value) in shown {
                    parts.children.append(developRow(Words.t(title), value: value, range: -100...100, decimals: 0,
                                                     track: Self.bandTrack(part, hue: hue), mixed: p.mixedBands.contains(band), board: board,
                                                     change: { [weak self] in WindowsCore.setPhotoBand(ids, band, part, $0); self?.photoTerrainRefresh?() }))
                }
                rows.append(parts)
            }
        }
        let caption = photoGroup == "detail" ? "Detail is best judged close up: zoom in on the photo."
            : "Drag a row sideways to change it, and double click it to put it back."
        rows.append(Controls.caption(caption))
        return rows
    }

    /// The picture's tones as a landscape, dark at the left and light at the right, with red,
    /// green and blue alone traced over it, as the Mac's ToneTerrain. It is cut into blacks,
    /// shadows, the middle, highlights and whites: pointing at one names it, and a sideways drag
    /// there moves it, the landscape following (a quarter as fast with Alt, catching at nothing).
    private func toneTerrain(_ ids: [UUID], board: Int) -> FrameworkElement {
        let w = Theme.cardWidth - 24, h = 72.0
        let well = Theme.well(radius: 10)
        well.width = w
        well.height = h
        let canvas = Canvas()
        canvas.width = w
        canvas.height = h
        canvas.background = Theme.clear
        // A clip to the well's rounding.
        let clip = RectangleGeometry()
        clip.rect = Rect(x: 0, y: 0, width: Float(w), height: Float(h))
        canvas.clip = clip
        well.child = canvas
        let zoneShade = Rectangle()
        zoneShade.fill = Theme.brush(Theme.pencil, Theme.pencilWash)
        zoneShade.height = h
        zoneShade.opacity = 0
        canvas.children.append(zoneShade)
        let layers = Canvas()
        layers.isHitTestVisible = false
        canvas.children.append(layers)
        let label = Border()
        label.cornerRadius = Theme.corners(8.5)
        label.background = Theme.brush(Theme.paper, 0.92)
        label.height = 17
        label.padding = Theme.inset(6, 0, 6, 0)
        label.isHitTestVisible = false
        label.opacity = 0
        let labelText = Theme.text("", size: 10.5, weight: 500)
        labelText.verticalAlignment = .center
        label.child = labelText
        try? Canvas.setTop(label, 5)
        canvas.children.append(label)

        func path(_ v: [Double], closed: Bool) -> String {
            guard v.count > 1 else { return "" }
            var d = PathData()
            let top = h * 0.86
            func point(_ i: Int) -> (Double, Double) {
                (Double(i) / Double(v.count - 1) * w, h - 1 - pow(min(max(v[i], 0), 1.15), 0.7) * top)
            }
            if closed { d.move(0, h); let a = point(0); d.line(a.0, a.1) } else { let a = point(0); d.move(a.0, a.1) }
            for i in 1..<v.count {
                let a = point(i - 1), b = point(i)
                d.quad(a.0, a.1, (a.0 + b.0) / 2, (a.1 + b.1) / 2)
            }
            let last = point(v.count - 1)
            d.line(last.0, last.1)
            if closed { d.line(w, h); d.close() }
            return d.d
        }
        func shape(_ data: String, stroke: SolidColorBrush?, fill: Brush?, width: Double) {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(width)'/>"
            guard !data.isEmpty, let p = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            if let stroke { p.stroke = stroke }
            if let fill { p.fill = fill }
            layers.children.append(p)
        }
        var hovered: String?
        var dragging: (setting: String, from: Double, x: Double, slow: Bool)?
        func zone(at x: Double) -> (setting: String, from: Double, to: Double) {
            let f = min(max(x / w, 0), 1)
            return WindowsCore.toneZones.first { f >= $0.from && f <= $0.to } ?? WindowsCore.toneZones[2]
        }
        func redraw() {
            layers.children.clear()
            let look = WindowsCore.photoTones(ids)
            let amounts = WindowsCore.photoLook(ids)?.amounts ?? [:]
            let flat = [Double](repeating: 0, count: 64)
            shape(path(look?.reds ?? flat, closed: false), stroke: Theme.brush(0xDB3D33, 0.45), fill: nil, width: 1)
            shape(path(look?.greens ?? flat, closed: false), stroke: Theme.brush(0x33A84D, 0.45), fill: nil, width: 1)
            shape(path(look?.blues ?? flat, closed: false), stroke: Theme.brush(0x386BE6, 0.45), fill: nil, width: 1)
            let ink = Theme.ink
            let ground = Colours.gradient([(0, WindowsCore.Colour(r: Double((ink >> 16) & 0xFF) / 255, g: Double((ink >> 8) & 0xFF) / 255, b: Double(ink & 0xFF) / 255, a: 0.2)),
                                           (1, WindowsCore.Colour(r: Double((ink >> 16) & 0xFF) / 255, g: Double((ink >> 8) & 0xFF) / 255, b: Double(ink & 0xFF) / 255, a: 0.08))],
                                          from: Point(x: 0.5, y: 0), to: Point(x: 0.5, y: 1))
            shape(path(look?.tones ?? flat, closed: true), stroke: nil, fill: ground, width: 0)
            shape(path(look?.tones ?? flat, closed: false), stroke: Theme.brush(ink, 0.55), fill: nil, width: 1.2)
            let shown = dragging?.setting ?? hovered
            // The zones' edges while one is pointed at, and a dot under each that is changed.
            for z in WindowsCore.toneZones {
                if shown != nil, z.from > 0 {
                    let edge = Rectangle()
                    edge.width = 0.5
                    edge.height = h
                    edge.fill = Theme.brush(ink, 0.12)
                    try? Canvas.setLeft(edge, z.from * w)
                    layers.children.append(edge)
                }
                if (amounts[z.setting] ?? 0) != 0 {
                    let dot = Ellipse()
                    dot.width = 4
                    dot.height = 4
                    dot.fill = Theme.brush(Theme.pencil)
                    try? Canvas.setLeft(dot, (z.from + z.to) / 2 * w - 2)
                    try? Canvas.setTop(dot, h - 7)
                    layers.children.append(dot)
                }
            }
            // Small marks in the top corners when part of the picture is lost to black or to white.
            for (lost, left) in [((look?.crushed ?? 0) > 0.01, true), ((look?.blown ?? 0) > 0.01, false)] where lost {
                var d = PathData()
                let x = left ? 6.0 : w - 11
                if left { d.move(x, 10.5); d.line(x + 5, 7); d.line(x + 5, 14) } else { d.move(x + 5, 10.5); d.line(x, 7); d.line(x, 14) }
                d.close()
                shape(d.d, stroke: nil, fill: Theme.ink(2), width: 0)
            }
            if let shown, let z = WindowsCore.toneZones.first(where: { $0.setting == shown }) {
                zoneShade.opacity = 1
                zoneShade.width = (z.to - z.from) * w
                try? Canvas.setLeft(zoneShade, z.from * w)
                let setting = WindowsCore.photoSettings.first { $0.name == shown }
                let v = amounts[shown] ?? 0
                let amount = v == 0 ? "" : " " + (v > 0 ? "+" : "−") + String(format: "%.\(setting?.decimals ?? 0)f", abs(v))
                labelText.text = (setting?.title ?? shown) + amount
                label.opacity = 1
                try? label.measure(Size(width: 300, height: 20))
                let lw = Double(label.desiredSize.width)
                let x = z.from < 0.2 ? 5 : z.to > 0.8 ? w - lw - 5 : (w - lw) / 2
                try? Canvas.setLeft(label, x)
            } else {
                zoneShade.opacity = 0
                label.opacity = 0
            }
        }
        redraw()
        photoTerrainRefresh = redraw

        canvas.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let pt = try? args?.getCurrentPoint(canvas)?.position else { return }
            let x = Double(pt.x)
            guard var d = dragging else {
                let z = zone(at: x).setting
                if z != hovered { hovered = z; redraw() }
                return
            }
            let slow = altHeld
            if slow != d.slow { d = (d.setting, WindowsCore.photoLook(ids)?.amounts[d.setting] ?? 0, x, slow); dragging = d }
            guard let setting = WindowsCore.photoSettings.first(where: { $0.name == d.setting }) else { return }
            let span = setting.high - setting.low
            var v = min(max(d.from + (x - d.x) / w * span * (slow ? 0.25 : 1), setting.low), setting.high)
            if abs(v) <= span * 0.018 { v = 0 }
            WindowsCore.setPhoto(ids, d.setting, v)
            redraw()
            self.session.edited(board: board)
        }
        canvas.pointerExited.addHandler { _, _ in
            guard dragging == nil else { return }
            hovered = nil
            redraw()
        }
        canvas.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let pt = try? args?.getCurrentPoint(canvas)?.position else { return }
            let z = zone(at: Double(pt.x)).setting
            dragging = (z, WindowsCore.photoLook(ids)?.amounts[z] ?? 0, Double(pt.x), altHeld)
            hovered = z
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            args?.handled = true
            WindowsCore.beginGesture()
            self.dialing = true
            redraw()
        }
        canvas.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, dragging != nil else { return }
            dragging = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            self.session.edited(board: board)
        }
        return well
    }

    /// The picture's colours as a ring of eight, red at the top and round through yellow, green
    /// and blue, around a cloud of the colours the picture has, strongest furthest out, as the
    /// Mac's ColorWheel. Each colour is a bead to drag: round the ring to turn its hue towards its
    /// neighbours, or out for more of it and in for less, whichever way the drag sets off; up or
    /// down with Alt for lighter or darker. A click picks it, for its rows below.
    private func colourWheel(_ ids: [UUID], board: Int) -> FrameworkElement {
        let w = Theme.cardWidth - 24, h = 200.0, ring = 62.0, reach = 28.0, settles = 4.0
        let center = (x: w / 2, y: h / 2)
        let holder = Grid()
        holder.width = w
        holder.height = h
        if let cloud = WindowsCore.photoColours(ids) {
            let image = Self.rendered(CGSize(width: w, height: h)) { scale, fill in
                WindowsCore.colourCloud(cloud.colors, hues: cloud.hues, strengths: cloud.strengths, size: CGSize(width: w, height: h), ring: ring, scale: scale, into: fill)
            }
            holder.children.append(image)
        }
        // The ring, its colours round it.
        let ringMarks = Canvas()
        ringMarks.isHitTestVisible = false
        ringMarks.opacity = 0.5
        for k in 0..<36 {
            var d = PathData()
            let a0 = Double(k) / 36 * 2 * .pi, a1 = Double(k + 1) / 36 * 2 * .pi + 0.01
            d.move(center.x + sin(a0) * ring, center.y - cos(a0) * ring)
            d.line(center.x + sin(a1) * ring, center.y - cos(a1) * ring)
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1.5'/>"
            guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
            path.stroke = Theme.brush(Self.hueColour(Double(k) / 36 * 360, saturation: 0.6, brightness: 0.9))
            ringMarks.children.append(path)
        }
        holder.children.append(ringMarks)
        let beads = Canvas()
        beads.background = Theme.clear
        holder.children.append(beads)

        let bands = WindowsCore.photoBands
        var drag: (band: String, from: (Double, Double, Double), start: (Double, Double), lighter: Bool, part: String?, moved: Bool)?
        var hovered: String?
        func shift(_ band: String) -> (hue: Double, saturation: Double, luminance: Double) {
            WindowsCore.photoLook(ids)?.bands[band] ?? (0, 0, 0)
        }
        func place(_ hue: Double, _ s: (hue: Double, saturation: Double, luminance: Double)) -> (Double, Double) {
            let angle = (hue + s.hue / 100 * 30) * .pi / 180
            let r = ring + s.saturation / 100 * reach
            return (center.x + sin(angle) * r, center.y - cos(angle) * r)
        }
        func colour(_ hue: Double, _ s: (hue: Double, saturation: Double, luminance: Double)) -> UInt32 {
            let light = s.luminance / 100
            let sat = min(max(0.72 + s.saturation / 100 * 0.28, 0.08), 1) * (light > 0 ? 1 - light * 0.45 : 1)
            let bright = min(max(0.86 + light * (light > 0 ? 0.14 : 0.5), 0.2), 1)
            return Self.hueColour(hue + s.hue / 100 * 30, saturation: sat, brightness: bright)
        }
        func polar(_ x: Double, _ y: Double) -> (Double, Double) {
            let dx = x - center.x, dy = y - center.y
            return (atan2(dx, -dy) * 180 / .pi, hypot(dx, dy))
        }
        func redraw() {
            beads.children.clear()
            for band in bands {
                let s = shift(band.name)
                let p = place(band.hue, s)
                let home = place(band.hue, (0, 0, 0))
                // Where it rests, and the thread back to it, while it is moved from there.
                if s.hue != 0 || s.saturation != 0 || s.luminance != 0 {
                    var d = PathData()
                    d.move(home.0, home.1)
                    d.line(p.0, p.1)
                    let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1' StrokeDashArray='1.5 2.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>"
                    if let thread = (try? XamlReader.load(xaml)) as? WinUI.Path {
                        thread.stroke = Theme.ink(3)
                        thread.isHitTestVisible = false
                        beads.children.append(thread)
                    }
                    let dot = Ellipse()
                    dot.width = 4
                    dot.height = 4
                    dot.fill = Theme.ink(3)
                    dot.isHitTestVisible = false
                    try? Canvas.setLeft(dot, home.0 - 2)
                    try? Canvas.setTop(dot, home.1 - 2)
                    beads.children.append(dot)
                }
                let picked = photoBand == band.name, active = hovered == band.name || drag?.band == band.name
                let size = active ? 19.0 : picked ? 17.0 : 14.0
                if picked {
                    let halo = Ellipse()
                    halo.width = size + 7
                    halo.height = size + 7
                    halo.stroke = Theme.brush(Theme.pencil)
                    halo.strokeThickness = 1.5
                    halo.isHitTestVisible = false
                    try? Canvas.setLeft(halo, p.0 - (size + 7) / 2)
                    try? Canvas.setTop(halo, p.1 - (size + 7) / 2)
                    beads.children.append(halo)
                }
                let bead = Ellipse()
                bead.width = size
                bead.height = size
                bead.fill = Theme.brush(colour(band.hue, s))
                bead.stroke = Theme.brush(0xFFFFFF, 0.9)
                bead.strokeThickness = 1.5
                bead.isHitTestVisible = false
                try? Canvas.setLeft(bead, p.0 - size / 2)
                try? Canvas.setTop(bead, p.1 - size / 2)
                beads.children.append(bead)
            }
        }
        /// The bead under the pointer, within 13 of its middle.
        func bead(at x: Double, _ y: Double) -> String? {
            let near = bands.map { band -> (String, Double) in
                let p = place(band.hue, shift(band.name))
                return (band.name, hypot(p.0 - x, p.1 - y))
            }.min { $0.1 < $1.1 }
            return near.flatMap { $0.1 <= 13 ? $0.0 : nil }
        }
        redraw()
        beads.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let pt = try? args?.getCurrentPoint(beads)?.position else { return }
            let x = Double(pt.x), y = Double(pt.y)
            guard var d = drag else {
                let now = bead(at: x, y)
                if now != hovered { hovered = now; redraw() }
                return
            }
            let lighter = altHeld
            // Alt pressed or let go: on from here, with what it has come to.
            if d.lighter != lighter {
                let s = shift(d.band)
                d = (d.band, (s.hue, s.saturation, s.luminance), (x, y), lighter, nil, d.moved)
            }
            var s = (hue: d.from.0, saturation: d.from.1, luminance: d.from.2)
            if d.lighter {
                s.luminance = d.from.2 + (d.start.1 - y) / 60 * 100
            } else {
                let (a0, r0) = polar(d.start.0, d.start.1), (a, r) = polar(x, y)
                let round = WindowsCore.turn(a - a0) * .pi / 180 * max(r0, 1), out = r - r0
                if d.part == nil, hypot(round, out) >= settles { d.part = abs(round) > abs(out) ? "hue" : "saturation" }
                switch d.part {
                case "hue": s.hue = d.from.0 + WindowsCore.turn(a - a0) / 30 * 100
                case "saturation": s.saturation = d.from.1 + out / reach * 100
                default: break
                }
            }
            if hypot(x - d.start.0, y - d.start.1) > 2 { d.moved = true }
            drag = d
            guard d.moved else { return }
            // Held at nothing as it passes, as the rows are.
            func held(_ v: Double, _ was: Double) -> Double {
                let c = min(max(v, -100), 100)
                return c != was && abs(c) <= 4 ? 0 : c
            }
            WindowsCore.setPhotoShift(ids, d.band, hue: held(s.hue, d.from.0), saturation: held(s.saturation, d.from.1), luminance: held(s.luminance, d.from.2))
            redraw()
            self.photoTerrainRefresh?()
            self.session.edited(board: board)
        }
        beads.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let pt = try? args?.getCurrentPoint(beads)?.position, let band = bead(at: Double(pt.x), Double(pt.y)) else { return }
            let s = shift(band)
            drag = (band, (s.hue, s.saturation, s.luminance), (Double(pt.x), Double(pt.y)), altHeld, nil, false)
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            args?.handled = true
            WindowsCore.beginGesture()
            self.dialing = true
        }
        beads.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, let d = drag else { return }
            drag = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            if d.moved {
                // Its rows show, as the Mac picks a bead that is dragged.
                self.photoBand = d.band
            } else {
                self.photoBand = self.photoBand == d.band ? nil : d.band
            }
            self.session.edited(board: board)
            self.show()
        }
        beads.pointerExited.addHandler { _, _ in
            guard drag == nil, hovered != nil else { return }
            hovered = nil
            redraw()
        }
        return holder
    }

    /// The eight colours, each a dot of itself, raised while it is the one whose rows show; a dot
    /// whose colour has been changed is ringed.
    private func bandPicks(_ p: WindowsCore.PhotoLook, board: Int) -> FrameworkElement {
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 6
        line.horizontalAlignment = .center
        for band in WindowsCore.photoBands {
            let shift = p.bands[band.name] ?? (0, 0, 0)
            let changed = shift.hue != 0 || shift.saturation != 0 || shift.luminance != 0
            let picked = photoBand == band.name
            let dot = Ellipse()
            dot.width = picked ? 20 : 16
            dot.height = dot.width
            dot.fill = Theme.brush(Self.hueColour(band.hue + shift.hue * 0.3, saturation: 0.72, brightness: 0.86))
            dot.stroke = picked ? Theme.brush(Theme.pencil) : changed ? Theme.ink(1) : Theme.brush(0xFFFFFF, 0.9)
            dot.strokeThickness = picked ? 2 : 1.5
            let press = Pressable(radius: 12) { [weak self] in
                guard let self else { return }
                self.photoBand = picked ? nil : band.name
                self.show()
            }
            press.box.width = 24
            press.box.height = 24
            dot.horizontalAlignment = .center
            dot.verticalAlignment = .center
            press.box.child = dot
            try? ToolTipService.setToolTip(press.box, band.title)
            line.children.append(press.box)
        }
        return line
    }

    /// A row of the card, as the Mac's DevelopRow: its title and amount, and along its foot a
    /// hairline marked in pencil from nothing to the amount. Dragged sideways it moves the amount
    /// as far along the line as the pointer goes (a quarter as fast with Alt), catching at
    /// nothing; a double click puts it back to nothing.
    func developRow(_ title: String, value: Double, range: ClosedRange<Double>, decimals: Int, track: [UInt32]?, mixed: Bool,
                    board: Int, change: @escaping @MainActor (Double) -> Void) -> FrameworkElement {
        let width = Theme.cardWidth - 24, length = width - 14
        let span = range.upperBound - range.lowerBound
        let origin = min(max(0, range.lowerBound), range.upperBound)
        func at(_ v: Double) -> Double { (v - range.lowerBound) / max(span, 1e-9) * length }
        func said(_ v: Double, several: Bool) -> String {
            if several { return Words.t("Several") }
            if v == 0 { return "0" }
            return (v > 0 ? "+" : "−") + String(format: "%.\(decimals)f", abs(v))
        }

        let row = Grid()
        row.width = width
        row.height = 27
        let shade = Border()
        shade.cornerRadius = Theme.corners(7)
        shade.background = Theme.brush(Theme.pencil, 0)
        row.children.append(shade)
        let name = Theme.text(title, size: 12, ink: value != 0 ? 1 : 2)
        name.verticalAlignment = .center
        name.margin = Theme.inset(7, 0, 0, 3)
        name.textTrimming = .characterEllipsis
        row.children.append(name)
        let amount = Theme.text(said(value, several: mixed), size: 12, ink: value != 0 ? 1 : 3)
        amount.horizontalAlignment = .right
        amount.verticalAlignment = .center
        amount.margin = Theme.inset(0, 0, 7, 3)
        row.children.append(amount)

        // The hairline at the foot: its colours, the pencil from nothing to the amount, the mark.
        let foot = Canvas()
        foot.height = 8
        foot.verticalAlignment = .bottom
        foot.margin = Theme.inset(7, 0, 7, -1)
        foot.isHitTestVisible = false
        let line = Rectangle()
        line.width = length
        line.height = 2
        line.radiusX = 1
        line.radiusY = 1
        if let track, track.count >= 2 {
            line.fill = Colours.gradient(track.enumerated().map { k, hex in
                (Double(k) / Double(track.count - 1), WindowsCore.Colour(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: 1))
            }, from: Point(x: 0, y: 0.5), to: Point(x: 1, y: 0.5))
            line.opacity = 0.4
        } else {
            line.fill = Theme.ink(1)
            line.opacity = 0.1
        }
        try? Canvas.setTop(line, 3)
        foot.children.append(line)
        let marked = Rectangle()
        marked.height = 2
        marked.fill = Theme.brush(Theme.pencil)
        try? Canvas.setTop(marked, 3)
        foot.children.append(marked)
        let thumb = Ellipse()
        thumb.width = 8
        thumb.height = 8
        thumb.fill = Theme.brush(Theme.paper)
        thumb.stroke = Theme.brush(Theme.pencil)
        thumb.strokeThickness = 1.5
        thumb.opacity = 0
        foot.children.append(thumb)
        row.children.append(foot)

        var shown = value
        func place(_ v: Double) {
            let zero = at(origin), x = at(v)
            marked.width = max(abs(x - zero), v == 0 ? 0 : 2)
            try? Canvas.setLeft(marked, min(zero, x))
            try? Canvas.setLeft(thumb, x - 4)
        }
        place(value)

        var from: (value: Double, x: Double, slow: Bool)?
        var hovering = false
        func lit() {
            let active = hovering || from != nil
            thumb.opacity = active ? 1 : 0
            if track != nil { line.opacity = active ? 0.8 : 0.4 }
            shade.background = from != nil ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, hovering ? 0.045 : 0)
        }
        row.background = Theme.clear
        row.pointerEntered.addHandler { _, _ in hovering = true; lit() }
        row.pointerExited.addHandler { _, _ in hovering = false; lit() }
        row.pointerPressed.addHandler { [weak self] sender, args in
            guard let self, let p = try? args?.getCurrentPoint(row)?.position else { return }
            from = (shown, Double(p.x), altHeld)
            _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
            args?.handled = true
            WindowsCore.beginGesture()
            self.dialing = true
            lit()
        }
        row.pointerMoved.addHandler { [weak self] _, args in
            guard let self, var f = from, let p = try? args?.getCurrentPoint(row)?.position else { return }
            let slow = altHeld
            // Alt pressed or let go: counted again from where it is, so nothing jumps.
            if slow != f.slow { f = (shown, Double(p.x), slow); from = f }
            var v = f.value + (Double(p.x) - f.x) / length * span * (slow ? 0.25 : 1)
            v = min(max(v, range.lowerBound), range.upperBound)
            // Held at nothing.
            if abs(v - origin) <= span * 0.018, range.contains(origin) { v = origin }
            let step = decimals > 0 ? pow(10, -Double(decimals)) : 1
            v = (v / step).rounded() * step
            guard v != shown else { return }
            shown = v
            change(v)
            place(v)
            amount.text = said(v, several: false)
            self.session.edited(board: board)
        }
        row.pointerReleased.addHandler { [weak self] sender, args in
            guard let self, from != nil else { return }
            from = nil
            try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
            WindowsCore.endGesture()
            self.dialing = false
            lit()
            self.session.edited(board: board)
        }
        row.doubleTapped.addHandler { [weak self] _, _ in
            guard let self else { return }
            change(0)
            self.session.edited(board: board)
        }
        return row
    }

    /// The colours a setting runs between, drawn along its row, for those whose direction is a colour.
    static func photoTrack(_ name: String) -> [UInt32]? {
        switch name {
        case "temperature": [0x4A7ADB, 0xBFBFBF, 0xE6A33D]
        case "tint": [0x54AD59, 0xBFBFBF, 0xCC5CB8]
        case "saturation", "vibrance": [0x9E9E9E, 0xB3B3B3, 0xDB5C4D]
        default: nil
        }
    }

    /// A colour's rows' colours: round the wheel either way for its hue, out from grey for its
    /// strength, dark to light for its lightness.
    static func bandTrack(_ part: String, hue: Double) -> [UInt32] {
        switch part {
        case "hue": [hueColour(hue - 30, saturation: 0.7, brightness: 0.85), hueColour(hue, saturation: 0.7, brightness: 0.85), hueColour(hue + 30, saturation: 0.7, brightness: 0.85)]
        case "saturation": [0xB3B3B3, hueColour(hue, saturation: 0.85, brightness: 0.85)]
        default: [hueColour(hue, saturation: 0.8, brightness: 0.35), hueColour(hue, saturation: 0.35, brightness: 1)]
        }
    }

    /// A colour by its hue in degrees, strength and brightness, as 0xRRGGBB.
    static func hueColour(_ degrees: Double, saturation s: Double, brightness v: Double) -> UInt32 {
        let h = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        func byte(_ u: Double) -> UInt32 { UInt32(min(max((u + m) * 255, 0), 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
