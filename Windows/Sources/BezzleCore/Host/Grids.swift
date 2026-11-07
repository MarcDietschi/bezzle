import Foundation

// Repeat grids on Windows, as on the Mac (the shared Model/GridEditing.swift and RepeatGrid):
// made of the selection, their columns, rows and gaps, and what each cell holds of its own.

extension WindowsCore {
    public static func canRepeat(_ ids: [UUID]) -> Bool { design?.repeatable(ids) != nil }

    /// The layers made a repeat grid of one cell, to be pulled out into rows and columns; the grid.
    public static func makeRepeatGrid(_ ids: [UUID]) -> UUID? {
        guard let ids = design?.repeatable(ids) else { return nil }
        var made: UUID?
        edit { made = $0.makeRepeatGrid(of: ids) }
        return made
    }

    public static func isGrid(_ id: UUID) -> Bool { design?.node(id)?.isRepeatGrid == true }

    /// A grid as its card shows it: its columns, rows and gaps, how many cells, and what each cell
    /// holds of its own (its slots: each a layer of the first cell, its name and kind).
    nonisolated public struct GridLook: Sendable {
        public let columns: Int, rows: Int
        public let columnGap: Double, rowGap: Double
        public let count: Int
        public let slots: [(id: UUID, name: String, kind: String)]
    }

    public static func gridLook(_ id: UUID) -> GridLook? {
        guard let doc = design, let g = doc.node(id), let spec = g.grid else { return nil }
        return GridLook(columns: spec.columns, rows: spec.rows, columnGap: Double(spec.columnGap), rowGap: Double(spec.rowGap),
                        count: spec.count, slots: doc.slots(of: g).map { ($0.id, $0.name, $0.kind.rawValue) })
    }

    public static var gridCounts: ClosedRange<Int> { RepeatGrid.counts }

    /// A layer in a grid's cell as its card shows it: the grid, the layer's slot, which cell it is
    /// in (counting from one), how many cells there are, and what kind of layer it is.
    public static func cellLook(_ id: UUID) -> (grid: UUID, slot: UUID?, cell: Int?, count: Int, kind: String, picture: Bool)? {
        guard let doc = design, let n = doc.node(id), !n.isRepeatGrid, let grid = doc.grid(holding: id), let spec = grid.grid else { return nil }
        let cell = RepeatGrid.cell(of: id, in: grid, doc: doc).map { $0.cell.row * spec.columns + $0.cell.column + 1 }
        return (grid.id, doc.slot(of: id), cell, spec.count, n.kind.rawValue, n.fill.image != nil)
    }

    nonisolated public enum GridChange: Sendable {
        case size(columns: Int, rows: Int), columns(Int), rows(Int), columnGap(Double), rowGap(Double)
    }

    private static func apply(_ c: GridChange, to spec: inout RepeatGrid) {
        switch c {
        case .size(let columns, let rows): spec.columns = columns; spec.rows = rows
        case .columns(let n): spec.columns = n
        case .rows(let n): spec.rows = n
        case .columnGap(let v): spec.columnGap = CGFloat(v)
        case .rowGap(let v): spec.rowGap = CGFloat(v)
        }
    }

    public static func changeGrid(_ id: UUID, _ c: GridChange) {
        edit { $0.changeGrid(id) { apply(c, to: &$0) } }
    }

    /// Shows a grid changed so, while its cell field is pointed at; nil takes that away.
    public static func previewGrid(_ id: UUID, _ c: GridChange?) {
        endPreview()
        guard let c else { return }
        preview { $0.changeGrid(id) { apply(c, to: &$0) } }
    }

    public static func ungroupGrid(_ id: UUID) { edit { $0.ungroupGrid(id) } }

    // MARK: What the cells hold

    /// The kinds of words that can fill a grid's cells, by name: numbers, names, cities…
    public static var wordKinds: [String] { SampleContent.allCases.map { $0.title.key } }

    /// `count` words of a kind, like `words` (a text's own) where that matters, picked by `seed`.
    public static func words(_ kind: Int, count: Int, like words: String, seed: Int) -> [String] {
        let all = SampleContent.allCases
        guard all.indices.contains(kind) else { return [] }
        return all[kind].values(count, like: words, seed: seed)
    }

    /// The words a text layer has now.
    public static func wordsNow(of id: UUID) -> String { design?.node(id)?.text ?? "" }

    public static func fillCells(_ slot: UUID, in grid: UUID, with values: [String]) {
        guard !values.isEmpty else { return }
        edit { $0.fillCells(slot, in: grid, with: values) }
    }

    /// Shows the words in every cell, as they would be, while they are pointed at; nil takes them away.
    public static func previewFill(_ slot: UUID, in grid: UUID, with values: [String]?) {
        endPreview()
        guard let values, !values.isEmpty, let spec = design?.node(grid)?.grid else { return }
        let ids = spec.cells.map { slot.mixed(RepeatGrid.key($0)) }
        preview { d in
            d.update(grid) { node in
                for (i, id) in ids.enumerated() {
                    RepeatGrid.change(id, in: &node) { n in
                        n.text = values[i % values.count]
                        n.refit()
                    }
                }
            }
        }
    }

    /// Each cell's copy of a shape given the next of these picture files, copied into the design.
    public static func fillCells(_ slot: UUID, in grid: UUID, withPictures files: [URL]) {
        let pictures = pictureFiles(in: files).compactMap(importPicture)
        guard !pictures.isEmpty else { return }
        edit { $0.fillCells(slot, in: grid, withPictures: pictures) }
    }

    /// A grid's text layers filled from a text or CSV file: a line a cell, or a column by the
    /// layer named like it; how many layers were filled.
    @discardableResult
    public static func fillCells(_ grid: UUID, fromFile file: URL, startingWith slot: UUID? = nil) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        var filled = 0
        edit { filled = $0.fillCells(grid, from: text, startingWith: slot) }
        return filled
    }

    public static func shuffleCells(_ slot: UUID, in grid: UUID) { edit { $0.shuffleCells(slot, in: grid) } }
    public static func sameInEveryCell(_ id: UUID) { edit { $0.sameInEveryCell(id) } }
}
