import Foundation
import WinUI
import UWP
import BezzleCore

/// An artboard's layout grid and guides as cards, as the Mac's (Views/LayoutCards.swift). The
/// grid: folded, what it is made of; its dial sets how many columns (or rows, or the baselines'
/// step), catching at the counts layouts are usually made with. Open, its parts switched on and
/// off as tiles, each with its numbers; guides at its margins. The guides: each with how far it
/// lies from the edge it keeps to, which edge that is, and a cross; whether they are locked.
extension Inspector {
    static let red: UInt32 = 0xE5484D, blue: UInt32 = 0x1E9BD7

    func layoutCard(_ board: UUID, change: @escaping @MainActor (WindowsCore.LayoutChange) -> Void) -> UIElement? {
        guard let g = WindowsCore.layoutLook(board) else { return nil }
        let summary: String = switch (g.columns, g.rows) {
        case let (c?, r?): "\(c.count) × \(r.count)"
        case let (c?, nil): c.count == 1 ? "1 column" : "\(c.count) columns"
        case let (nil, r?): r.count == 1 ? "1 row" : "\(r.count) rows"
        case (nil, nil): g.baseline.map { "Baseline \(number($0.step))" } ?? ""
        }
        var dial: Dial?
        if let c = g.columns ?? g.rows {
            let columns = g.columns != nil, top = 24.0
            let stops: [Double] = columns ? [2, 3, 4, 6, 8, 12, 16, 24] : [2, 3, 4, 6, 8, 12]
            dial = Dial(fraction: (Double(c.count) - 1) / (top - 1), set: { f in
                change(.count(columns: columns, Int((1 + f * (top - 1)).rounded())))
            }, summary: { f in
                let n = Int((1 + f * (top - 1)).rounded())
                return columns ? (n == 1 ? "1 column" : "\(n) columns") : (n == 1 ? "1 row" : "\(n) rows")
            }, stops: stops.map { ($0 - 1) / (top - 1) })
        } else if let b = g.baseline {
            dial = Dial(fraction: (b.step - 2) / 30, set: { change(.step((2 + $0 * 30).rounded())) },
                        summary: { "Baseline \(self.number((2 + $0 * 30).rounded()))" }, stops: [4, 6, 8, 12, 16, 24].map { ($0 - 2) / 30 })
        }
        return card("Layout Grid", summary, mark: Self.layoutGlyph(g), dial: dial, remove: { [self] in
            WindowsCore.removeLayout(board)
            session.edited(board: nil)
        }, removal: "Remove layout grid", body: { [self] in
            var rows: [UIElement] = [partTiles(g, change: change)]
            if let c = g.columns { rows += track(c, columns: true, change: change) }
            if let r = g.rows { rows += track(r, columns: false, change: change) }
            if let b = g.baseline {
                rows.append(Controls.row("Baseline", field("", b.step, range: WindowsCore.baselineSteps, scrub: 0.1) { change(.step($0)) }))
                rows.append(Controls.row("Offset", field("", b.offset, range: 0...10_000, scrub: 0.25) { change(.offset($0)) }))
            }
            rows.append(Controls.caption("What you move catches on the columns, and text sits on the baselines."))
            if WindowsCore.hasTracks(board) {
                let guides = ExportSheet.textButton("Guides at Margins") { [self] in
                    WindowsCore.addGuidesAtMargins(board)
                    session.edited(board: nil)
                } as? FrameworkElement
                guides?.horizontalAlignment = .right
                try? ToolTipService.setToolTip(guides, Words.t("Put guides where the columns and rows begin and end, to keep to once the grid is hidden"))
                if let guides { rows.append(guides) }
            }
            return rows
        })
    }

    /// How many columns or rows, and the gutters between them and the margins either side.
    private func track(_ t: WindowsCore.Track, columns: Bool, change: @escaping @MainActor (WindowsCore.LayoutChange) -> Void) -> [UIElement] {
        let counts = WindowsCore.columnCounts
        let fewer = Controls.iconButton(Glyphs.minus(size: 14), size: Controls.height) { change(.count(columns: columns, t.count - 1)) }
        fewer.opacity = t.count > counts.lowerBound ? 1 : 0.35
        fewer.isHitTestVisible = t.count > counts.lowerBound
        let more = Controls.iconButton(Glyphs.plus(size: 14), size: Controls.height) { change(.count(columns: columns, t.count + 1)) }
        more.opacity = t.count < counts.upperBound ? 1 : 0.35
        more.isHitTestVisible = t.count < counts.upperBound
        let count = field("", Double(t.count), range: Double(counts.lowerBound)...Double(counts.upperBound), scrub: 0.05,
                          width: Theme.cardWidth - 24 - Inspector.column - Inspector.columnGap - 2 * Controls.height - 8) { v in
            change(.count(columns: columns, Int(v.rounded())))
        }
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 4
        for e in [fewer, count, more] { line.children.append(e) }
        try? ToolTipService.setToolTip(fewer, Words.t(columns ? "One column fewer" : "One row fewer"))
        try? ToolTipService.setToolTip(more, Words.t(columns ? "One column more" : "One row more"))
        return [Controls.row(columns ? "Columns" : "Rows", line),
                Controls.row("Gutter", field("", t.gutter, range: 0...10_000, scrub: 0.25) { change(.gutter(columns: columns, $0)) }),
                Controls.row("Margin", field("", t.margin, range: 0...10_000, scrub: 0.25) { change(.margin(columns: columns, $0)) })]
    }

    /// The grid's three parts as tiles side by side in a well, each drawn as it looks and lifted when on.
    private func partTiles(_ g: WindowsCore.LayoutLook, change: @escaping @MainActor (WindowsCore.LayoutChange) -> Void) -> UIElement {
        let well = Theme.well(radius: 10)
        let grid = Grid()
        grid.margin = Theme.inset(2)
        grid.columnSpacing = 2
        let parts: [(String, Bool, WindowsCore.LayoutChange)] = [("Columns", g.columns != nil, .columns(g.columns == nil)),
                                                                ("Rows", g.rows != nil, .rows(g.rows == nil)),
                                                                ("Baselines", g.baseline != nil, .baseline(g.baseline == nil))]
        for (k, (title, on, toggle)) in parts.enumerated() {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            grid.columnDefinitions.append(column)
            let press = Pressable(radius: 8) { change(toggle) }
            press.hoverWash = on ? 0 : 0.04
            press.box.height = 52
            press.box.background = on ? Theme.brush(Theme.card) : Theme.clear
            if on {
                press.box.borderBrush = Theme.brush(Theme.shadow, 0.1)
                press.box.borderThickness = Theme.inset(0, 0, 0, 0.75)
            }
            let stack = StackPanel()
            stack.spacing = 5
            stack.verticalAlignment = .center
            let glyph = Self.partGlyph(k, on: on)
            glyph.horizontalAlignment = .center
            stack.children.append(glyph)
            let words = Theme.text(title, size: 11, weight: on ? 500 : 400, ink: on ? 1 : 2)
            words.horizontalAlignment = .center
            stack.children.append(words)
            press.box.child = stack
            try? Grid.setColumn(press.box, Int32(k))
            grid.children.append(press.box)
        }
        well.child = grid
        return well
    }

    /// A part of a grid in small, 30 by 20: red columns or rows, or blue lines, dashed in ink while it is off.
    private static func partGlyph(_ part: Int, on: Bool) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = 30
        canvas.height = 20
        canvas.isHitTestVisible = false
        let frame = Rectangle()
        frame.width = 28
        frame.height = 18
        frame.radiusX = 2.5
        frame.radiusY = 2.5
        frame.stroke = Theme.brush(Theme.ink, on ? 0.35 : 0.45)
        frame.strokeThickness = 1
        if !on {
            let dashes = DoubleCollection()
            dashes.append(2)
            dashes.append(2)
            frame.strokeDashArray = dashes
        }
        try? Canvas.setLeft(frame, 1)
        try? Canvas.setTop(frame, 1)
        canvas.children.append(frame)
        let inner = CGRect(x: 4, y: 4, width: 22, height: 12)
        func bar(_ r: CGRect, _ colour: UInt32, _ alpha: Double) {
            let b = Border()
            b.width = Double(r.width)
            b.height = Double(r.height)
            b.cornerRadius = Theme.corners(1)
            b.background = Theme.brush(colour, alpha)
            try? Canvas.setLeft(b, Double(r.minX))
            try? Canvas.setTop(b, Double(r.minY))
            canvas.children.append(b)
        }
        switch part {
        case 0, 1:
            let n = 4, gap = 2.5
            let along = part == 0 ? Double(inner.width) : Double(inner.height)
            let w = (along - gap * Double(n - 1)) / Double(n)
            for i in 0..<n {
                let o = Double(i) * (w + gap)
                let r = part == 0 ? CGRect(x: Double(inner.minX) + o, y: Double(inner.minY), width: w, height: Double(inner.height))
                                  : CGRect(x: Double(inner.minX), y: Double(inner.minY) + o, width: Double(inner.width), height: w)
                bar(r, on ? red : Theme.ink, on ? 0.45 : 0.18)
            }
        default:
            var y = Double(inner.minY)
            while y <= Double(inner.maxY) {
                bar(CGRect(x: Double(inner.minX), y: y, width: Double(inner.width), height: 1), on ? blue : Theme.ink, on ? 0.8 : 0.25)
                y += 3
            }
        }
        return canvas
    }

    /// The Mac's LayoutGlyph, 17 square: a sheet with red columns (or rows) and blue baselines.
    static func layoutGlyph(_ g: WindowsCore.LayoutLook) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = 17
        canvas.height = 17
        canvas.isHitTestVisible = false
        let inner = CGRect(x: 4.5, y: 4.5, width: 8, height: 8)
        func bar(_ r: CGRect, _ colour: UInt32, _ alpha: Double) {
            let b = Border()
            b.width = Double(r.width)
            b.height = Double(r.height)
            b.background = Theme.brush(colour, alpha)
            try? Canvas.setLeft(b, Double(r.minX))
            try? Canvas.setTop(b, Double(r.minY))
            canvas.children.append(b)
        }
        if g.baseline != nil {
            var y = Double(inner.minY) + 1
            while y < Double(inner.maxY) { bar(CGRect(x: Double(inner.minX), y: y, width: Double(inner.width), height: 0.8), blue, 0.8); y += 2.5 }
        }
        if let t = g.columns ?? g.rows {
            let n = min(t.count, 5), gap = 1.2, columns = g.columns != nil
            let w = ((columns ? Double(inner.width) : Double(inner.height)) - gap * Double(n - 1)) / Double(n)
            for i in 0..<n {
                let o = Double(i) * (w + gap)
                bar(columns ? CGRect(x: Double(inner.minX) + o, y: Double(inner.minY), width: w, height: Double(inner.height))
                            : CGRect(x: Double(inner.minX), y: Double(inner.minY) + o, width: Double(inner.width), height: w), red, 0.55)
            }
        }
        let frame = Rectangle()
        frame.width = 13
        frame.height = 13
        frame.radiusX = 2
        frame.radiusY = 2
        frame.stroke = Theme.ink(2)
        frame.strokeThickness = 1.2
        try? Canvas.setLeft(frame, 2)
        try? Canvas.setTop(frame, 2)
        canvas.children.append(frame)
        return canvas
    }

    // MARK: Guides

    func guidesCard(_ board: UUID) -> UIElement? {
        let guides = WindowsCore.guides(board)
        guard !guides.isEmpty else { return nil }
        @MainActor func edited() { session.edited(board: nil) }
        return card("Guides", guides.count == 1 ? "1 guide" : "\(guides.count) guides", mark: Self.guidesGlyph(), remove: {
            WindowsCore.removeGuides(board)
            edited()
        }, removal: "Remove guides", body: { [self] in
            var rows: [UIElement] = guides.map { g in
                let line = StackPanel()
                line.orientation = .horizontal
                line.spacing = 6
                let arrow = Theme.text(g.vertical ? "↔" : "↕", size: 11, weight: 600)
                arrow.foreground = Theme.brush(Theme.pencil)
                arrow.width = 16
                arrow.verticalAlignment = .center
                line.children.append(arrow)
                line.children.append(field("", g.offset, range: -100_000...100_000, scrub: 0.5, width: 78) { v in
                    WindowsCore.setGuideOffset(board, key: g.key, v)
                    edited()
                })
                let titles: [(String, String)] = g.vertical ? [("start", "Left"), ("middle", "Centre"), ("end", "Right")]
                                                            : [("start", "Top"), ("middle", "Middle"), ("end", "Bottom")]
                let menu = Controls.menuButton(titles.first { $0.0 == g.edge }?.1 ?? "", width: 92, menus: menus, menuWidth: 170, entries: {
                    titles.map { edge in
                        MenuHost.Entry.item(edge.1, checked: edge.0 == g.edge) {
                            WindowsCore.keepGuide(board, key: g.key, to: edge.0)
                            edited()
                        }
                    }
                })
                line.children.append(menu)
                let cross = Controls.iconButton(Glyphs.cross(size: 20), size: 20) {
                    WindowsCore.removeGuide(board, key: g.key)
                    edited()
                }
                cross.verticalAlignment = .center
                try? ToolTipService.setToolTip(cross, Words.t("Remove guide"))
                line.children.append(cross)
                return line
            }
            rows.append(Controls.row("Lock guides", Controls.toggle(WindowsCore.guidesLocked) { on in
                WindowsCore.guidesLocked = on
                edited()
            }))
            rows.append(Controls.caption("Pull guides out of the rulers, or click a ruler to put one there. Each keeps its distance from the edge it is nearer as the artboard changes size."))
            return rows
        })
    }

    /// The Mac's GuidesGlyph: two guides crossing, each with its pins.
    private static func guidesGlyph() -> FrameworkElement {
        var p = PathData()
        let s = 16.0, c = (x: s * 0.38, y: s * 0.62)
        p.move(c.x, 1.5); p.line(c.x, s - 1.5)
        p.move(1.5, c.y); p.line(s - 1.5, c.y)
        var parts = [Glyphs.Part(data: p.d, mode: .stroke, width: 1.2)]
        for q in [(c.x, 1.5), (c.x, s - 1.5), (1.5, c.y), (s - 1.5, c.y)] {
            var dot = PathData()
            dot.rect(q.0 - 1.5, q.1 - 1.5, 3, 3, radius: 1.5)
            parts.append(Glyphs.Part(data: dot.d, mode: .fill))
        }
        return Glyphs.view(parts, size: 16, brush: Theme.ink(2))
    }
}
