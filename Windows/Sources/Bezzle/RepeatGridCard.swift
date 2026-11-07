import Foundation
import WinUI
import UWP
import BezzleCore

/// A repeat grid's cards, as the Mac's (Views/GridInspector.swift). The grid: a field of cells to
/// point at for the size wanted, how many columns and rows exactly and how far apart, and what
/// its cells hold. A layer in a cell: which cell, and what fills the same layer in the others.
extension Inspector {
    func repeatGridCard(_ id: UUID, board: Int) -> UIElement? {
        guard let g = WindowsCore.gridLook(id) else { return nil }
        @MainActor func edited() { session.edited(board: board) }
        return card("Repeat Grid", "\(g.columns) × \(g.rows)", glyph: Self.gridGlyph(), body: { [self] in
            var rows: [UIElement] = [cellPicker(id, g, board: board)]
            rows.append(Controls.row("Columns", counter(g.columns, columns: true) { WindowsCore.changeGrid(id, .columns($0)); edited() }))
            rows.append(Controls.row("Rows", counter(g.rows, columns: false) { WindowsCore.changeGrid(id, .rows($0)); edited() }))
            let gaps = StackPanel()
            gaps.orientation = .horizontal
            gaps.spacing = 6
            let w = (Theme.cardWidth - 24 - Inspector.column - Inspector.columnGap - 6) / 2
            let across = field("↔", g.columnGap, range: -1000...10_000, scrub: 0.5, width: w) { WindowsCore.changeGrid(id, .columnGap($0)); edited() }
            let down = field("↕", g.rowGap, range: -1000...10_000, scrub: 0.5, width: w) { WindowsCore.changeGrid(id, .rowGap($0)); edited() }
            try? ToolTipService.setToolTip(across, "Between columns")
            try? ToolTipService.setToolTip(down, "Between rows")
            gaps.children.append(across)
            gaps.children.append(down)
            rows.append(Controls.row("Gaps", gaps))
            if !g.slots.isEmpty {
                let heading = Theme.text("Content", size: 12.5, weight: 600)
                heading.margin = Theme.inset(0, 6, 0, 0)
                rows.append(heading)
                for slot in g.slots {
                    let line = Grid()
                    line.height = Controls.height
                    let lead = StackPanel()
                    lead.orientation = .horizontal
                    lead.spacing = 8
                    lead.verticalAlignment = .center
                    lead.children.append(Glyphs.view(Glyphs.kind(slot.kind, size: 15), size: 15, brush: Theme.ink(3)))
                    let name = Theme.text(slot.name, size: 12.5)
                    name.textTrimming = .characterEllipsis
                    name.maxWidth = 100
                    lead.children.append(name)
                    line.children.append(lead)
                    let menu = Controls.menuButton(slot.kind == "text" ? "Words" : "Pictures", width: Inspector.column, menus: menus, menuWidth: 250,
                                                   entries: { [self] in contentEntries(grid: id, slot: slot.id, kind: slot.kind, count: g.count, board: board) },
                                                   closed: { [self] in if WindowsCore.endPreview() { session.previewed(board: board) } })
                    menu.horizontalAlignment = .right
                    line.children.append(menu)
                    rows.append(line)
                }
                rows.append(Controls.caption("Each cell's words and pictures are its own. A CSV's columns go to the text layers named like them."))
            }
            let foot = Grid()
            if !g.slots.isEmpty {
                let importing = ExportSheet.chip("Import Data…") { [self] in
                    let files = FileDialogs.chooseFiles(title: "Choose a text file of one line per cell, or a CSV file whose column names are the names of text layers in the grid",
                                                        button: "Fill Cells", filters: [("Text and CSV", "*.txt;*.csv;*.tsv")], several: false)
                    guard let file = files.first else { return }
                    WindowsCore.fillCells(id, fromFile: file)
                    edited()
                }
                foot.children.append(importing)
            }
            let ungroup = ExportSheet.textButton("Ungroup Grid") { [self] in
                WindowsCore.ungroupGrid(id)
                edited()
            } as? FrameworkElement
            ungroup?.horizontalAlignment = .right
            try? ToolTipService.setToolTip(ungroup, "Make it a group of its cells, each a layer of its own  Ctrl+Shift+R")
            if let ungroup { foot.children.append(ungroup) }
            rows.append(foot)
            return rows
        })
    }

    func gridCellCard(_ id: UUID, board: Int) -> UIElement? {
        guard let c = WindowsCore.cellLook(id) else { return nil }
        let summary = c.cell.map { "Cell \($0) of \(c.count)" } ?? ""
        return card("In a Repeat Grid", summary, glyph: Self.gridGlyph(), body: { [self] in
            var rows: [UIElement] = []
            if let slot = c.slot, ["text", "rectangle", "ellipse", "path"].contains(c.kind) {
                rows.append(Controls.row(c.kind == "text" ? "Words" : "Pictures",
                                         Controls.menuButton("Fill Cells", menus: menus, menuWidth: 250,
                                                             entries: { [self] in contentEntries(grid: c.grid, slot: slot, kind: c.kind, count: c.count, board: board, from: id) },
                                                             closed: { [self] in if WindowsCore.endPreview() { session.previewed(board: board) } })))
            }
            let note = c.kind == "text" ? "What you change here changes in all \(c.count) cells, but for the words: each cell has its own."
                : c.picture ? "What you change here changes in all \(c.count) cells, but for the picture: each cell has its own."
                : "What you change here changes in all \(c.count) cells."
            rows.append(Controls.caption(note))
            let select = ExportSheet.textButton("Select Grid") { [self] in session.select([c.grid], on: board) } as? FrameworkElement
            select?.horizontalAlignment = .right
            if let select { rows.append(select) }
            return rows
        })
    }

    /// What can fill the same layer in every cell, as the Mac's GridContentMenu: words of some
    /// kind (pointed at, they show in the cells), a file of them, or pictures; mixed up; or all as
    /// one cell has it.
    private func contentEntries(grid: UUID, slot: UUID, kind: String, count: Int, board: Int, from cell: UUID? = nil) -> [MenuHost.Entry] {
        @MainActor func edited() { session.edited(board: board) }
        var entries: [MenuHost.Entry] = []
        if kind == "text" {
            let seed = Int.random(in: 0..<10_000), like = WindowsCore.wordsNow(of: slot)
            for (k, title) in WindowsCore.wordKinds.enumerated() {
                let values = WindowsCore.words(k, count: count, like: like, seed: seed)
                entries.append(.item(title, detail: values.prefix(2).joined(separator: ", ") + (count > 2 ? "…" : ""), preview: { [self] on in
                    WindowsCore.previewFill(slot, in: grid, with: on ? values : nil)
                    session.previewed(board: board)
                }) {
                    WindowsCore.endPreview()
                    WindowsCore.fillCells(slot, in: grid, with: values)
                    edited()
                })
            }
            entries += [.separator, .item("From a File…", detail: "A line a cell, or a CSV's column") {
                let files = FileDialogs.chooseFiles(title: "Choose a text file of one line per cell, or a CSV file whose column names are the names of text layers in the grid",
                                                    button: "Fill Cells", filters: [("Text and CSV", "*.txt;*.csv;*.tsv")], several: false)
                guard let file = files.first else { return }
                WindowsCore.fillCells(grid, fromFile: file, startingWith: slot)
                edited()
            }]
        } else {
            entries.append(.item("Choose Pictures…", detail: "A picture a cell") {
                let files = FileDialogs.chooseFiles(title: "Choose pictures. Each cell gets the next one.", button: "Fill Cells",
                                                    filters: [("Pictures", "*.png;*.jpg;*.jpeg;*.webp")], several: true)
                guard !files.isEmpty else { return }
                WindowsCore.fillCells(slot, in: grid, withPictures: files)
                edited()
            })
        }
        entries += [
            .separator,
            .item("Shuffle", enabled: count > 1) { WindowsCore.shuffleCells(slot, in: grid); edited() },
            .item(cell == nil || cell == slot ? "Same as the First Cell" : "Same as This Cell", enabled: count > 1) {
                WindowsCore.sameInEveryCell(cell ?? slot)
                edited()
            },
        ]
        return entries
    }

    /// One fewer, how many, one more: of the grid's columns, or of its rows.
    private func counter(_ value: Int, columns: Bool, _ set: @escaping @MainActor (Int) -> Void) -> FrameworkElement {
        let range = WindowsCore.gridCounts
        let fewer = Controls.iconButton(Glyphs.minus(size: 14), size: Controls.height) { set(value - 1) }
        fewer.opacity = value > range.lowerBound ? 1 : 0.35
        fewer.isHitTestVisible = value > range.lowerBound
        let more = Controls.iconButton(Glyphs.plus(size: 14), size: Controls.height) { set(value + 1) }
        more.opacity = value < range.upperBound ? 1 : 0.35
        more.isHitTestVisible = value < range.upperBound
        try? ToolTipService.setToolTip(fewer, columns ? "One column fewer" : "One row fewer")
        try? ToolTipService.setToolTip(more, columns ? "One column more" : "One row more")
        let count = field("", Double(value), range: Double(range.lowerBound)...Double(range.upperBound), scrub: 0.05,
                          width: Theme.cardWidth - 24 - Inspector.column - Inspector.columnGap - 2 * Controls.height - 8) { v in set(Int(v.rounded())) }
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 4
        for e in [fewer, count, more] { line.children.append(e) }
        return line
    }

    /// A field of cells to point at, as the Mac's CellPicker: as many columns and rows as are
    /// pointed at show on the canvas, and a click makes the grid that size.
    private func cellPicker(_ id: UUID, _ g: WindowsCore.GridLook, board: Int) -> UIElement {
        let columns = 12, rows = 5, spacing = 3.0, inset = 8.0
        let side = ((Theme.cardWidth - 24 - inset * 2 - spacing * Double(columns - 1)) / Double(columns)).rounded(.down)
        let stack = StackPanel()
        stack.spacing = 6
        let well = Theme.well(radius: 10)
        let field = Canvas()
        field.width = Double(columns) * side + Double(columns - 1) * spacing
        field.height = Double(rows) * side + Double(rows - 1) * spacing
        field.margin = Theme.inset(inset)
        field.background = Theme.clear
        well.child = field
        stack.children.append(well)
        let label = Grid()
        let size = Theme.text("\(g.columns) × \(g.rows)", size: 12, weight: 500)
        let cells = Theme.text("  ·  " + (g.count == 1 ? "one cell" : "\(g.count) cells"), size: 12, ink: 3)
        let sizes = StackPanel()
        sizes.orientation = .horizontal
        sizes.children.append(size)
        sizes.children.append(cells)
        label.children.append(sizes)
        let hint = Theme.text("Click to make it so", size: 11, ink: 3)
        hint.horizontalAlignment = .right
        hint.visibility = .collapsed
        label.children.append(hint)
        stack.children.append(label)
        var squares: [Border] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let b = Border()
                b.width = side
                b.height = side
                b.cornerRadius = Theme.corners(3.5)
                b.borderThickness = Theme.inset(0.5)
                b.isHitTestVisible = false
                try? Canvas.setLeft(b, Double(c) * (side + spacing))
                try? Canvas.setTop(b, Double(r) * (side + spacing))
                field.children.append(b)
                squares.append(b)
            }
        }
        var pointed: (c: Int, r: Int)?
        func paint() {
            for r in 0..<rows {
                for c in 0..<columns {
                    let b = squares[r * columns + c]
                    let has = c < g.columns && r < g.rows
                    let lit = pointed.map { c <= $0.c && r <= $0.r } ?? false
                    b.background = lit ? Theme.brush(Theme.pencil, has ? 0.85 : 0.55) : has ? Theme.brush(Theme.ink, 0.62) : Theme.brush(Theme.card)
                    b.borderBrush = lit ? Theme.brush(Theme.pencil) : Theme.hairline
                }
            }
            let shown = pointed.map { ($0.c + 1, $0.r + 1) } ?? (g.columns, g.rows)
            size.text = "\(shown.0) × \(shown.1)"
            size.foreground = pointed == nil ? Theme.ink(1) : Theme.brush(Theme.pencil)
            let n = shown.0 * shown.1
            cells.text = "  ·  " + (n == 1 ? "one cell" : "\(n) cells")
            hint.visibility = pointed == nil ? .collapsed : .visible
        }
        paint()
        field.pointerMoved.addHandler { [weak self] _, args in
            guard let self, let p = try? args?.getCurrentPoint(field)?.position else { return }
            let step = side + spacing
            let c = min(max(Int(Double(p.x) / step), 0), columns - 1), r = min(max(Int(Double(p.y) / step), 0), rows - 1)
            guard pointed?.c != c || pointed?.r != r else { return }
            pointed = (c, r)
            paint()
            WindowsCore.previewGrid(id, .size(columns: c + 1, rows: r + 1))
            self.session.previewed(board: board)
        }
        field.pointerExited.addHandler { [weak self] _, _ in
            pointed = nil
            paint()
            if WindowsCore.endPreview() { self?.session.previewed(board: board) }
        }
        field.pointerPressed.addHandler { _, args in args?.handled = true }
        field.tapped.addHandler { [weak self] _, args in
            args?.handled = true
            guard let self, let at = pointed else { return }
            pointed = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WindowsCore.endPreview()
                    WindowsCore.changeGrid(id, .size(columns: at.c + 1, rows: at.r + 1))
                    self.session.edited(board: board)
                }
            }
        }
        return stack
    }

    /// Four cells, two by two, the first solid: a repeat grid.
    static func gridGlyph() -> [Glyphs.Part] {
        let w = 16.0, side = w * 0.32, gap = w * 0.1, x0 = (w - side * 2 - gap) / 2
        var solid = PathData(), open = PathData()
        for r in 0..<2 {
            for c in 0..<2 {
                let x = x0 + Double(c) * (side + gap), y = x0 + Double(r) * (side + gap)
                if r == 0 && c == 0 { solid.rect(x, y, side, side, radius: 1.2) } else { open.rect(x, y, side, side, radius: 1.2) }
            }
        }
        return [Glyphs.Part(data: solid.d, mode: .fill), Glyphs.Part(data: open.d, mode: .stroke, width: 1.2)]
    }
}
