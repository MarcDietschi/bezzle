import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// Colours in the inspector, as the Mac draws them (Views/Fields.swift, FillMenu.swift): a swatch
/// on a checkerboard, a colour field (its swatch, its hex to type, the design's own colours one
/// click away), the colour panel (brightness and saturation in a square, hue and transparency on
/// strips, the hex, the design's colours) and the fill menu (one colour, a gradient with its
/// colours on a bar, or the picture there is).
@MainActor
enum Colours {
    typealias Colour = WindowsCore.Colour

    static func colour(_ c: Colour) -> UWP.Color {
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return UWP.Color(a: byte(c.a), r: byte(c.r), g: byte(c.g), b: byte(c.b))
    }

    static func brush(_ c: Colour) -> SolidColorBrush { SolidColorBrush(colour(c)) }

    /// Colours running across, at their offsets (0…1), as XAML draws a gradient.
    static func gradient(_ stops: [(Double, Colour)], from start: Point = Point(x: 0, y: 0.5), to end: Point = Point(x: 1, y: 0.5)) -> LinearGradientBrush {
        let brush = LinearGradientBrush()
        brush.startPoint = start
        brush.endPoint = end
        for (offset, c) in stops {
            let stop = WinUI.GradientStop()
            stop.color = colour(c)
            stop.offset = offset
            brush.gradientStops.append(stop)
        }
        return brush
    }

    /// Squares of white and light grey, `square` across, to show how see-through a colour is.
    static func checkerboard(width: Double, height: Double, square: Double = 4) -> FrameworkElement {
        var p = PathData()
        for row in 0..<Int((height / square).rounded(.up)) {
            for col in 0..<Int((width / square).rounded(.up)) where (row + col) % 2 == 1 {
                p.rect(Double(col) * square, Double(row) * square, square, square)
            }
        }
        let board = Grid()
        board.width = width
        board.height = height
        board.background = Theme.brush(0xFFFFFF)
        if !p.d.isEmpty {
            let squares = Glyphs.view([Glyphs.Part(data: p.d, mode: .fill)], size: max(width, height), brush: Theme.brush(0xDBDBDB))
            board.children.append(squares)
        }
        return board
    }

    /// A colour on a checkerboard (the Mac's Swatch); nil is several, half and half of nothing in
    /// particular.
    static func swatch(_ c: Colour?, size: Double = Controls.height, radius: Double = 7) -> FrameworkElement {
        swatch(size: size, radius: radius) { $0.background = c.map(brush) ?? gradient([(0, Colour(r: 0.6, g: 0.6, b: 0.6, a: 0.45)), (1, Colour(r: 0.6, g: 0.6, b: 0.6, a: 0.12))],
                                                                                    from: Point(x: 0, y: 0), to: Point(x: 1, y: 1)) }
    }

    /// A fill as a swatch: its colour, its gradient running as it does on the layer, or the mark of a picture.
    static func swatch(_ paint: WindowsCore.PaintLook, size: Double = Controls.height, radius: Double = 7) -> FrameworkElement {
        switch paint.kind {
        case "linear", "radial":
            let stops = paint.stops.sorted { $0.offset < $1.offset }.map { ($0.offset, $0.colour) }
            let radial = paint.kind == "radial"
            return swatch(size: size, radius: radius) {
                $0.background = radial
                    ? gradient(stops, from: Point(x: 0.5, y: 0.5), to: Point(x: 1, y: 1))
                    : gradient(stops, from: Point(x: Float(paint.start.x), y: Float(paint.start.y)), to: Point(x: Float(paint.end.x), y: Float(paint.end.y)))
            }
        case "picture":
            let box = Border()
            box.width = size
            box.height = size
            box.cornerRadius = Theme.corners(radius)
            box.background = Theme.brush(Theme.ink, 0.06)
            box.borderBrush = Theme.brush(Theme.ink, 0.14)
            box.borderThickness = Theme.inset(0.5)
            let mark = Glyphs.view(Glyphs.picture(), size: 12, brush: Theme.ink(2))
            mark.horizontalAlignment = .center
            mark.verticalAlignment = .center
            box.child = mark
            return box
        default:
            return swatch(paint.colour, size: size, radius: radius)
        }
    }

    private static func swatch(size: Double, radius: Double, paint: (Border) -> Void) -> FrameworkElement {
        let box = Grid()
        box.width = size
        box.height = size
        let clip = Border()
        clip.cornerRadius = Theme.corners(radius)
        clip.child = checkerboard(width: size, height: size)
        box.children.append(clip)
        let top = Border()
        top.cornerRadius = Theme.corners(radius)
        paint(top)
        top.borderBrush = Theme.brush(Theme.ink, 0.14)
        top.borderThickness = Theme.inset(0.5)
        box.children.append(top)
        return box
    }

    // MARK: The field

    /// The Mac's ColorField: the swatch (a click opens `open`), the hex to type in a well (its
    /// transparency at the end when it has some), and the design's colours in the last column,
    /// each shown on the canvas while pointed at.
    static func field(_ c: Colour?, suggestions: [Colour], open: @escaping @MainActor (FrameworkElement) -> Void,
                      preview: @escaping @MainActor (Colour?) -> Void, apply: @escaping @MainActor (Colour) -> Void) -> FrameworkElement {
        let row = Grid()
        row.columnSpacing = 8
        for w in [GridLength(value: Controls.height, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star),
                  GridLength(value: suggestions.isEmpty ? 0 : Inspector.endField, gridUnitType: .pixel)] {
            let column = ColumnDefinition()
            column.width = w
            row.columnDefinitions.append(column)
        }
        let swatch = self.swatch(c)
        swatch.pointerPressed.addHandler { _, args in args?.handled = true }
        swatch.tapped.addHandler { _, args in
            args?.handled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { open(swatch) } }
        }
        row.children.append(swatch)
        let well = hexWell(c) { hex in
            if let next = Colour(hex: hex, alpha: c?.a ?? 1), next != c { apply(next) }
        }
        try? Grid.setColumn(well, 1)
        row.children.append(well)
        if !suggestions.isEmpty {
            let dots = StackPanel()
            dots.orientation = .horizontal
            dots.spacing = 4
            for s in suggestions.prefix(4) {
                let shown = s.with(alpha: c?.a ?? 1)
                let dot = Border()
                dot.width = 16
                dot.height = 16
                dot.cornerRadius = Theme.corners(8)
                dot.background = brush(s)
                dot.borderBrush = Theme.brush(Theme.ink, 0.16)
                dot.borderThickness = Theme.inset(0.5)
                let hit = Border()
                hit.width = 16
                hit.height = Controls.height
                hit.background = Theme.clear
                hit.child = dot
                hit.pointerEntered.addHandler { _, _ in
                    dot.width = 19; dot.height = 19; dot.cornerRadius = Theme.corners(9.5)
                    preview(shown)
                }
                hit.pointerExited.addHandler { _, _ in
                    dot.width = 16; dot.height = 16; dot.cornerRadius = Theme.corners(8)
                    preview(nil)
                }
                hit.pointerPressed.addHandler { _, args in args?.handled = true }
                hit.tapped.addHandler { _, args in
                    args?.handled = true
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        preview(nil)
                        apply(shown)
                    } }
                }
                dots.children.append(hit)
            }
            try? Grid.setColumn(dots, 2)
            row.children.append(dots)
        }
        return row
    }

    /// A colour's hex in a well, "#" before it and its transparency after: Enter or leaving sets it.
    static func hexWell(_ c: Colour?, height: Double = Controls.height, set: @escaping @MainActor (String) -> Void) -> FrameworkElement {
        let well = Theme.well(radius: 7)
        well.height = height
        let grid = Grid()
        for w in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = w
            grid.columnDefinitions.append(column)
        }
        let hash = Theme.text("#", size: 11, ink: 3)
        hash.verticalAlignment = .center
        hash.margin = Theme.inset(8, 0, 0, 0)
        grid.children.append(hash)
        let box = TextBox()
        box.allowFocusOnInteraction = true
        let shown = c?.hex ?? "–"
        box.text = shown
        box.fontFamily = FontFamily("Consolas")
        box.fontSize = 12
        // Wrapping, a box shows no button to clear it, which a field of a few letters has no room for.
        box.textWrapping = .wrap
        box.minWidth = 0
        box.minHeight = 0
        box.padding = Theme.inset(2, 5, 4, 0)
        box.verticalAlignment = .center
        box.borderThickness = Theme.inset(0)
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused"] {
            _ = box.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused"] {
            _ = box.resources?.insert(key, Theme.ink(1))
        }
        box.background = Theme.clear
        try? Grid.setColumn(box, 1)
        grid.children.append(box)
        if let c, c.a < 1 {
            let percent = Theme.text("\(Int((c.a * 100).rounded()))%", size: 11, ink: 3)
            percent.verticalAlignment = .center
            percent.margin = Theme.inset(0, 0, 7, 0)
            try? Grid.setColumn(percent, 2)
            grid.children.append(percent)
        }
        well.child = grid
        var done = false
        func commit() {
            guard !done else { return }
            let typed = box.text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard typed.uppercased() != shown.uppercased() else { return }
            done = true
            set(typed)
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.keyDown.addHandler { _, args in if args?.key == .enter { args?.handled = true; commit() } }
        box.lostFocus.addHandler { _, _ in commit() }
        return well
    }

    // MARK: The panel

    /// The Mac's ColorPanel: brightness and saturation in a square, hue and transparency on two
    /// strips, the hex and how see-through it is, and the colours the design already uses. A drag
    /// in it is one step of the history.
    @MainActor final class Panel {
        static let width = 248.0
        static let height = 330.0
        let root = StackPanel()
        private var hue = 0.0, saturation = 0.0, brightness = 1.0, alpha = 1.0
        private let apply: (Colour) -> Void
        private let square = Grid(), hueTint = Border(), spot = Border()
        private let hueStrip = Grid(), alphaStrip = Grid(), alphaRun = Border()
        private let hueKnob = Border(), alphaKnob = Border()
        private let hexHolder = Border()
        private let percent: TextBlock
        private let inner = Theme.cardWidth - 28

        var current: Colour { Colour(h: hue, s: saturation, b: brightness, a: alpha) }

        init(start: Colour, used: [Colour], apply: @escaping (Colour) -> Void) {
            self.apply = apply
            percent = Theme.text("", size: 12, ink: 2)
            root.spacing = 12
            root.margin = Theme.inset(14)

            // Brightness and saturation: the hue, washed with white from the left and black from the top.
            square.height = 150
            square.cornerRadius = Theme.corners(8)
            let white = Border(), black = Border()
            white.background = gradient([(0, Colour(r: 1, g: 1, b: 1, a: 1)), (1, Colour(r: 1, g: 1, b: 1, a: 0))])
            black.background = gradient([(0, Colour(r: 0, g: 0, b: 0, a: 0)), (1, Colour(r: 0, g: 0, b: 0, a: 1))], from: Point(x: 0.5, y: 0), to: Point(x: 0.5, y: 1))
            hueTint.cornerRadius = Theme.corners(8)
            white.cornerRadius = Theme.corners(8)
            black.cornerRadius = Theme.corners(8)
            let knobs = Canvas()
            knobs.isHitTestVisible = false
            Self.knob(spot)
            knobs.children.append(spot)
            for e in [hueTint, white, black, knobs] as [UIElement] { square.children.append(e) }
            root.children.append(square)
            drag(square) { [weak self] p in
                guard let self else { return }
                self.saturation = min(max(Double(p.x) / self.inner, 0), 1)
                self.brightness = 1 - min(max(Double(p.y) / 150, 0), 1)
            }

            // Hue, round the wheel; then how see-through, over the checkerboard.
            let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { ($0, Colour(h: $0 == 1 ? 0.9999 : $0, s: 1, b: 1)) }
            strip(hueStrip, background: { b in b.background = gradient(hues) }, knob: hueKnob) { [weak self] v in self?.hue = min(v, 0.9999) }
            root.children.append(hueStrip)
            strip(alphaStrip, background: { [alphaRun] b in
                let board = Border()
                board.cornerRadius = Theme.corners(7)
                board.child = checkerboard(width: Theme.cardWidth - 28, height: 14)
                b.child = board
                alphaRun.cornerRadius = Theme.corners(7)
            }, knob: alphaKnob) { [weak self] v in self?.alpha = (v * 100).rounded() / 100 }
            alphaStrip.children.insertAt(1, alphaRun)
            root.children.append(alphaStrip)

            let line = Grid()
            line.columnSpacing = 8
            for w in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 40, gridUnitType: .pixel)] {
                let column = ColumnDefinition()
                column.width = w
                line.columnDefinitions.append(column)
            }
            line.children.append(hexHolder)
            percent.verticalAlignment = .center
            percent.horizontalAlignment = .right
            try? Grid.setColumn(percent, 1)
            line.children.append(percent)
            root.children.append(line)

            if !used.isEmpty {
                let title = Theme.text("In this design", size: 11.5, weight: 500, ink: 3)
                root.children.append(title)
                let grid = StackPanel()
                grid.spacing = 6
                var row: StackPanel?
                for (k, c) in used.prefix(18).enumerated() {
                    if k % 9 == 0 {
                        let r = StackPanel()
                        r.orientation = .horizontal
                        r.spacing = 6
                        grid.children.append(r)
                        row = r
                    }
                    let s = Colours.swatch(c, size: 20, radius: 5)
                    s.pointerPressed.addHandler { _, args in args?.handled = true }
                    s.tapped.addHandler { [weak self] _, _ in
                        guard let self else { return }
                        self.set(c)
                        self.show()
                        self.apply(c)
                    }
                    row?.children.append(s)
                }
                root.children.append(grid)
                root.spacing = 12
            }
            set(start)
            show()
        }

        /// Starts from `c`: a grey has no hue of its own, so the strip keeps the one it is on.
        func set(_ c: Colour) {
            let (h, s, b) = c.hsb
            if s > 0.001 && b > 0.001 { hue = h }
            saturation = s
            brightness = b
            alpha = c.a
        }

        private static func knob(_ k: Border) {
            k.width = 14
            k.height = 14
            k.cornerRadius = Theme.corners(7)
            k.borderBrush = Theme.brush(0xFFFFFF)
            k.borderThickness = Theme.inset(2.5)
            k.isHitTestVisible = false
        }

        /// The knobs, tints and hex as the colour now is.
        private func show() {
            let c = current
            hueTint.background = brush(Colour(h: hue, s: 1, b: 1))
            spot.background = brush(c.with(alpha: 1))
            try? Canvas.setLeft(spot, saturation * inner - 7)
            try? Canvas.setTop(spot, (1 - brightness) * 150 - 7)
            hueKnob.background = brush(Colour(h: hue, s: 1, b: 1))
            try? Canvas.setLeft(hueKnob, hue * (inner - 14))
            alphaKnob.background = brush(c.with(alpha: 1))
            try? Canvas.setLeft(alphaKnob, alpha * (inner - 14))
            alphaRun.background = gradient([(0, c.with(alpha: 0)), (1, c.with(alpha: 1))])
            percent.text = "\(Int((alpha * 100).rounded()))%"
            hexHolder.child = hexWell(c, height: 26) { [weak self] hex in
                guard let self, let next = Colour(hex: hex, alpha: self.alpha) else { return }
                self.set(next)
                self.show()
                self.apply(next)
            }
        }

        /// A strip 14 tall with a knob on it, for hue and transparency.
        private func strip(_ strip: Grid, background: (Border) -> Void, knob: Border, changed: @escaping (Double) -> Void) {
            strip.height = 14
            let back = Border()
            back.cornerRadius = Theme.corners(7)
            background(back)
            back.borderBrush = Theme.brush(Theme.ink, 0.1)
            back.borderThickness = Theme.inset(0.5)
            strip.children.append(back)
            let knobs = Canvas()
            knobs.isHitTestVisible = false
            Self.knob(knob)
            knobs.children.append(knob)
            strip.children.append(knobs)
            drag(strip) { [weak self] p in
                guard let self else { return }
                changed(min(max((Double(p.x) - 7) / (self.inner - 14), 0), 1))
            }
        }

        /// Pressing and dragging on `element` sets the colour from where the pointer is, as one step.
        private func drag(_ element: UIElement, _ at: @escaping (Point) -> Void) {
            var down = false
            element.pointerPressed.addHandler { [weak self] sender, args in
                guard let self, let p = try? args?.getCurrentPoint(element)?.position else { return }
                args?.handled = true
                down = true
                _ = try? (sender as? UIElement)?.capturePointer(args?.pointer)
                WindowsCore.beginGesture()
                at(p)
                self.show()
                self.apply(self.current)
            }
            element.pointerMoved.addHandler { [weak self] _, args in
                guard let self, down, let p = try? args?.getCurrentPoint(element)?.position else { return }
                at(p)
                self.show()
                self.apply(self.current)
            }
            element.pointerReleased.addHandler { sender, args in
                guard down else { return }
                args?.handled = true
                down = false
                try? (sender as? UIElement)?.releasePointerCapture(args?.pointer)
                WindowsCore.endGesture()
            }
        }
    }
}
