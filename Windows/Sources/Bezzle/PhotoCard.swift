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
extension Inspector {
    func photoCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard let p = WindowsCore.photoLook(ids) else { return nil }
        @MainActor func edited() { session.edited(board: board) }
        // Twice as much at the far end, as much as now in the middle, in tens.
        func share(_ f: Double) -> Double { (f * 20).rounded() * 10 }
        let dial = Dial(fraction: p.neutral ? 0 : 0.5, set: { f in WindowsCore.photoStrength(ids, share(f) / 100) },
                        summary: { f in "\(Int(share(f)))%" }, stops: [0.5])
        let mark = Glyphs.view(Glyphs.picture(size: 14), size: 14, brush: Theme.ink(2))
        var remove: (@MainActor () -> Void)?
        if !p.neutral { remove = { WindowsCore.resetPhoto(ids); edited() } }
        return card("Photo", p.summary, mark: mark, dial: dial, remove: remove, removal: "Back to the original", body: { [self] in
            photoRows(p, ids: ids, board: board)
        })
    }

    /// The open card: the tabs, the rows of the one chosen, and for Colour, the colours.
    private func photoRows(_ p: WindowsCore.PhotoLook, ids: [UUID], board: Int) -> [UIElement] {
        var rows: [UIElement] = []
        let width = Theme.cardWidth - 24
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
                                            change: { WindowsCore.setPhoto(ids, name, $0) }))
        }
        rows.append(list)
        if photoGroup == "color" {
            rows.append(bandPicks(p, board: board))
            if let band = photoBand, let shift = p.bands[band], let hue = WindowsCore.photoBands.first(where: { $0.name == band })?.hue {
                let parts = StackPanel()
                parts.spacing = 2
                let shown: [(String, String, Double)] = [("hue", "Hue", shift.hue), ("saturation", "Saturation", shift.saturation), ("luminance", "Luminance", shift.luminance)]
                for (part, title, value) in shown {
                    parts.children.append(developRow(Words.t(title), value: value, range: -100...100, decimals: 0,
                                                     track: Self.bandTrack(part, hue: hue), mixed: p.mixedBands.contains(band), board: board,
                                                     change: { WindowsCore.setPhotoBand(ids, band, part, $0) }))
                }
                rows.append(parts)
            }
        }
        let caption = photoGroup == "detail" ? "Detail is best judged close up: zoom in on the photo."
            : "Drag a row sideways to change it, and double click it to put it back."
        rows.append(Controls.caption(caption))
        return rows
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
