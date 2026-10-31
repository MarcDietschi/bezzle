import SwiftUI

/// A repeat grid's card: a field of cells to point at for the size wanted, how many columns and
/// rows exactly and how far apart, and what its cells hold.
struct RepeatGridCard: View {
    let store: DocumentStore
    let grid: Node
    var live = false

    var body: some View {
        let spec = grid.grid ?? RepeatGrid()
        let slots = store.slots(of: grid)
        AspectCard(aspect: .grid, title: "Repeat Grid", summary: "\(spec.columns) × \(spec.rows)", live: live) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11.5, weight: .medium))
        } picks: {
            CellPicker(store: store, grid: grid)
            Row(title: "Columns") { counter(spec.columns, columns: true) { $0.columns = $1 } }
            Row(title: "Rows") { counter(spec.rows, columns: false) { $0.rows = $1 } }
            Row(title: "Gaps") {
                gapField(.verbatim("↔"), spec.columnGap, help: "Between columns") { $0.columnGap = $1 }
                gapField(.verbatim("↕"), spec.rowGap, help: "Between rows") { $0.rowGap = $1 }
            }
            Caption("Or pull the handles on its right and bottom edges, and drag between two cells to space them; Shift spaces them both ways.")
            if !slots.isEmpty {
                Text("Content")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 6)
                ForEach(slots) { slot in
                    HStack(spacing: 8) {
                        KindGlyph(kind: slot.kind)
                            .foregroundStyle(Theme.ink3)
                        Text(slot.name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        MenuButton(id: "grid-fill-\(slot.id.uuidString)", title: slot.kind == .text ? "Words" : "Pictures", width: 250, fills: true) {
                            GridContentMenu.entries(store: store, grid: grid.id, slot: slot.id)
                        }
                        .frame(width: Inspector.column)
                    }
                    .frame(height: Theme.controlHeight)
                }
                Caption("Each cell's words and pictures are its own. Drop a text or CSV file on the grid, or a folder of pictures on a shape in it, to fill every cell at once; a CSV's columns go to the text layers named like them.")
            }
            HStack(spacing: 8) {
                if !slots.isEmpty { ChipButton(title: "Import Data…") { store.chooseData(for: grid.id) } }
                Spacer(minLength: 0)
                TextButton(title: "Ungroup Grid") { store.ungroupGrid(grid.id) }
                    .help("Make it a group of its cells, each a layer of its own  ⇧⌘R")
            }
        }
    }

    /// One fewer, how many, one more: of the grid's columns, or of its rows.
    @ViewBuilder private func counter(_ value: Int, columns: Bool, _ set: @escaping (inout RepeatGrid, Int) -> Void) -> some View {
        let range = RepeatGrid.counts
        let changing: LocalizedStringResource = columns ? "Change Columns" : "Change Rows"
        IconButton(symbol: "minus", help: columns ? "One column fewer" : "One row fewer", size: Theme.controlHeight) {
            store.changeGrid(grid.id, columns ? "Remove Column" : "Remove Row") { set(&$0, value - 1) }
        }
        .opacity(value > range.lowerBound ? 1 : 0.35)
        .allowsHitTesting(value > range.lowerBound)
        NumberField(label: "", value: Double(value), range: Double(range.lowerBound)...Double(range.upperBound),
                    scrub: 0.05, decimals: 0, action: changing) { v in
            store.changeGrid(grid.id, changing) { set(&$0, Int(v.rounded())) }
        }
        IconButton(symbol: "plus", help: columns ? "One column more" : "One row more", size: Theme.controlHeight) {
            store.changeGrid(grid.id, columns ? "Add Column" : "Add Row") { set(&$0, value + 1) }
        }
        .opacity(value < range.upperBound ? 1 : 0.35)
        .allowsHitTesting(value < range.upperBound)
    }

    private func gapField(_ label: LocalizedStringResource, _ value: CGFloat, help: LocalizedStringResource, _ set: @escaping (inout RepeatGrid, CGFloat) -> Void) -> some View {
        NumberField(label: label, value: Double(value), range: -1000...10_000, scrub: 0.5, decimals: 0, action: "Change Gap") { v in
            store.changeGrid(grid.id, "Change Gap") { set(&$0, CGFloat(v)) }
        }
        .help(Text(help))
    }
}

/// A layer in a cell of a repeat grid: which cell it is in, and what fills the same layer in the
/// others.
struct GridCellCard: View {
    let store: DocumentStore
    let node: Node
    let grid: Node

    var body: some View {
        let spec = grid.grid ?? RepeatGrid()
        let slot = store.slot(of: node.id)
        let cell = RepeatGrid.cell(of: node.id, in: grid, doc: store.doc).map { $0.cell.row * spec.columns + $0.cell.column + 1 }
        AspectCard(aspect: .cell, title: "In a Repeat Grid", summary: cell.map { String(localized: "Cell \($0) of \(spec.count)") } ?? "") {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11.5, weight: .medium))
        } picks: {
            if let slot, node.kind == .text || [.rectangle, .ellipse, .path].contains(node.kind) {
                Row(title: node.kind == .text ? "Words" : "Pictures") {
                    MenuButton(id: "cell-fill-\(slot.uuidString)", title: "Fill Cells", width: 250, fills: true) {
                        GridContentMenu.entries(store: store, grid: grid.id, slot: slot, from: node.id)
                    }
                }
            }
            Caption(Self.note(for: node, cells: spec.count))
            HStack {
                Spacer(minLength: 0)
                TextButton(title: "Select Grid") { store.selection = [grid.id] }
            }
        }
    }

    /// What a change to a layer in a cell does to the others.
    private static func note(for node: Node, cells: Int) -> LocalizedStringResource {
        if node.kind == .text { return "What you change here changes in all \(cells) cells, but for the words: each cell has its own." }
        if node.fill.image != nil { return "What you change here changes in all \(cells) cells, but for the picture: each cell has its own." }
        return "What you change here changes in all \(cells) cells."
    }
}

/// What can fill the same layer in every cell of a grid: words of some kind, a file of them, or
/// pictures; mixed up; or all as one cell has it. Pointing at words shows them on the canvas.
enum GridContentMenu {
    static func entries(store: DocumentStore, grid gridID: UUID, slot: UUID, from cell: UUID? = nil) -> [MenuEntry] {
        guard let grid = store.node(gridID), let first = store.node(slot) else { return [] }
        let count = grid.grid?.count ?? 1
        let source = cell ?? slot
        var entries: [MenuEntry] = []
        if first.kind == .text {
            let seed = Int.random(in: 0..<10_000)
            for kind in SampleContent.allCases {
                let values = kind.values(count, like: first.text ?? "", seed: seed)
                entries.append(.item(kind.title, detail: .verbatim(values.prefix(2).joined(separator: ", ") + (count > 2 ? "…" : "")),
                                     preview: { on in preview(store, on ? values : nil, slot: slot, in: gridID) }) {
                    store.fill(slot, in: gridID, with: values, action: kind.filling)
                })
            }
            entries += [
                .separator,
                .item("From a File…", detail: "A line a cell, or a CSV's column") { store.chooseData(for: gridID, startingWith: slot) },
            ]
        } else {
            entries.append(.item("Choose Pictures…", detail: "Or a folder: a picture a cell") { store.choosePictures(for: slot, in: gridID) })
        }
        entries += [
            .separator,
            .item("Shuffle", enabled: count > 1) { store.shuffle(slot, in: gridID) },
            .item(cell == nil || cell == slot ? "Same as the First Cell" : "Same as This Cell", enabled: count > 1) { store.sameInEveryCell(source) },
        ]
        return entries
    }

    /// Shows the words on the canvas in every cell, as they would be, or takes them away again.
    private static func preview(_ store: DocumentStore, _ values: [String]?, slot: UUID, in grid: UUID) {
        guard let values else {
            store.showPreview("grid-fill", nil)
            return
        }
        guard let spec = store.node(grid)?.grid else { return }
        let ids = spec.cells.map { slot.mixed(RepeatGrid.key($0)) }
        store.showPreview("grid-fill", on: [grid]) { node in
            for (i, id) in ids.enumerated() {
                RepeatGrid.change(id, in: &node) { n in
                    n.text = values[i % values.count]
                    n.refit()
                }
            }
        }
    }
}

/// A field of cells to point at: as many columns and rows as are pointed at show on the canvas,
/// and a click makes the grid that size.
private struct CellPicker: View {
    let store: DocumentStore
    let grid: Node
    @State private var pointed: RepeatGrid.Cell?

    private static let columns = 12, rows = 5
    private static let spacing: CGFloat = 3, inset: CGFloat = 8
    private static var side: CGFloat { ((Inspector.content - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down) }

    var body: some View {
        let spec = grid.grid ?? RepeatGrid()
        let side = Self.side
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: Self.spacing) {
                ForEach(0..<Self.rows, id: \.self) { r in
                    HStack(spacing: Self.spacing) {
                        ForEach(0..<Self.columns, id: \.self) { c in
                            square(c, r, spec)
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
            .padding(Self.inset)
            .well(radius: 10)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let step = side + Self.spacing
                    let c = Int(((p.x - Self.inset) / step).rounded(.down)), r = Int(((p.y - Self.inset) / step).rounded(.down))
                    let cell = RepeatGrid.Cell(column: min(max(c, 0), Self.columns - 1), row: min(max(r, 0), Self.rows - 1))
                    if cell != pointed { point(at: cell) }
                case .ended:
                    point(at: nil)
                }
            }
            .onTapGesture {
                guard let pointed else { return }
                point(at: nil)
                store.changeGrid(grid.id, "Repeat Grid") { $0.columns = pointed.column + 1; $0.rows = pointed.row + 1 }
            }
            .animation(Theme.quick, value: pointed)
            HStack(spacing: 0) {
                let shown = pointed.map { ($0.column + 1, $0.row + 1) } ?? (spec.columns, spec.rows)
                Text(verbatim: "\(shown.0) × \(shown.1)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(pointed == nil ? Theme.ink : Theme.pencil)
                let cells = shown.0 * shown.1
                Group {
                    Text(verbatim: "  ·  ")
                    cells == 1 ? Text("one cell") : Text("\(cells) cells")
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
                if pointed != nil {
                    Text("Click to make it so")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .transition(.opacity)
                }
            }
        }
    }

    /// A cell of the field: dark where the grid has one, pencil blue as far as is pointed at.
    private func square(_ c: Int, _ r: Int, _ spec: RepeatGrid) -> some View {
        let has = c < spec.columns && r < spec.rows
        let lit = pointed.map { c <= $0.column && r <= $0.row } ?? false
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(lit ? Theme.pencil.opacity(has ? 0.85 : 0.55) : has ? Theme.ink.opacity(0.62) : Theme.card)
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lit ? Theme.pencil : Theme.hairline, lineWidth: 0.5)
            }
            .scaleEffect(lit && pointed == RepeatGrid.Cell(column: c, row: r) ? 1.12 : 1)
    }

    private func point(at cell: RepeatGrid.Cell?) {
        pointed = cell
        if let cell {
            store.showPreview("grid-size", on: [grid.id]) { $0.grid?.columns = cell.column + 1; $0.grid?.rows = cell.row + 1 }
        } else {
            store.showPreview("grid-size", nil)
        }
    }
}

extension SampleContent {
    /// The undo step that fills a grid's cells with it, said whole for each.
    var filling: LocalizedStringResource {
        switch self {
        case .numbers: "Fill with Numbers"
        case .names: "Fill with Names"
        case .firstNames: "Fill with First names"
        case .cities: "Fill with Cities"
        case .countries: "Fill with Countries"
        case .jobs: "Fill with Job titles"
        case .companies: "Fill with Companies"
        case .emails: "Fill with Email addresses"
        case .prices: "Fill with Prices"
        case .dates: "Fill with Dates"
        case .times: "Fill with Times"
        case .headlines: "Fill with Headlines"
        case .sentences: "Fill with Sentences"
        }
    }
}

extension RepeatGrid {
    /// Changes the layer with this id somewhere in a grid, however deep.
    static func change(_ id: UUID, in node: inout Node, _ body: (inout Node) -> Void) {
        if node.id == id {
            body(&node)
            return
        }
        for i in node.children.indices { change(id, in: &node.children[i], body) }
    }
}

/// Four cells, two by two, the first drawn solid: for a repeat grid in the layers list.
struct RepeatGridGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let side = w * 0.32, gap = w * 0.1, x0 = (w - side * 2 - gap) / 2, y0 = (h - side * 2 - gap) / 2
            let style = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            for r in 0..<2 {
                for c in 0..<2 {
                    let cell = Path(roundedRect: CGRect(x: x0 + CGFloat(c) * (side + gap), y: y0 + CGFloat(r) * (side + gap), width: side, height: side),
                                    cornerRadius: 1.2)
                    if r == 0 && c == 0 { ctx.fill(cell, with: .foreground) } else { ctx.stroke(cell, with: .foreground, style: style) }
                }
            }
        }
        .frame(width: 15, height: 15)
    }
}
