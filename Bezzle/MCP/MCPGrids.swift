import Foundation

/// Repeat grids for the assistant: making one and changing it, and giving its cells words and
/// pictures of their own. See `RepeatGrid`.
extension MCPTools {
    func repeatGrid(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        let columns = try args.int("columns"), rows = try args.int("rows")
        let columnGap = try args.number("column_gap").map { CGFloat($0) }, rowGap = try args.number("row_gap").map { CGFloat($0) }
        // A grid already: changed, or made a plain group.
        if ids.count == 1, let grid = doc.node(ids[0]), grid.isRepeatGrid {
            if try args.bool("ungroup") == true {
                try change(store, "Ungroup Grid") { doc in doc.update(grid.id) { $0.grid = nil } }
                return described([grid.id], in: store, depth: 1)
            }
            try change(store, "Change Repeat Grid") { doc in
                doc.update(grid.id) { n in
                    if let columns { n.grid?.columns = RepeatGrid.clamped(columns) }
                    if let rows { n.grid?.rows = RepeatGrid.clamped(rows) }
                    if let columnGap { n.grid?.columnGap = columnGap.rounded() }
                    if let rowGap { n.grid?.rowGap = rowGap.rounded() }
                }
            }
            store.selection = [grid.id]
            return described([grid.id], in: store, depth: 1)
        }
        guard try args.bool("ungroup") != true else { throw MCPError("That is not a repeat grid.") }
        guard !ids.contains(where: { doc.node($0)?.isArtboard == true }) else { throw MCPError("Artboards cannot be repeated; their layers can.") }
        guard !ids.contains(where: { doc.node($0)?.isRepeatGrid == true }) else { throw MCPError("Change one grid at a time; give it on its own.") }
        let parents = Set(ids.map { doc.parent(of: $0)?.id })
        guard parents.count == 1, let parent = parents.first else { throw MCPError("Repeat layers that lie in the same artboard or group. move_layers brings them together.") }
        if let parent, doc.node(parent)?.isRepeatGrid == true {
            throw MCPError("That is a cell of a repeat grid already: change its columns and rows with the grid's id.")
        }
        let name = try args.string("name")
        var made: UUID?
        try change(store, "Make Repeat Grid") { doc in
            made = DocumentStore.makeRepeatGrid(of: ids, in: &doc, columns: columns ?? 1, rows: rows ?? 1,
                                                columnGap: columnGap, rowGap: rowGap, name: name)
        }
        guard let made else { throw MCPError("The layers could not be repeated.") }
        store.selection = [made]
        return described([made], in: store, depth: 1)
    }

    func fillRepeatGrid(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let ref = try args.string("layer") else { throw MCPError("Give the grid, or a text or shape in one of its cells, as layer.") }
        let id = try Self.layer(ref, in: store.doc)
        guard let grid = store.grid(holding: id) else { throw MCPError("\(store.node(id)?.name ?? ref) is not in a repeat grid.") }

        if let data = try args.string("data") {
            var filled = 0
            _ = try onSelection(store, [grid.id], "Fill Cells") { copy in filled = copy.fill(grid.id, from: data) }
            guard filled > 0 else { throw MCPError("The grid has no text layers for the data to go to.") }
            return described([grid.id], in: store, depth: 1)
        }

        guard let slot = grid.id == id ? store.slots(of: grid).first?.id : store.slot(of: id), let first = store.node(slot) else {
            throw MCPError("Give a text or shape in one of the grid's cells as layer.")
        }
        let count = grid.grid?.count ?? 1
        if let files = try args.strings("pictures") {
            guard [.rectangle, .ellipse, .path].contains(first.kind) else { throw MCPError("Pictures fill rectangles, ellipses and paths; \(first.name) is a \(first.kind.rawValue).") }
            let urls = DocumentStore.pictureFiles(in: files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            guard !urls.isEmpty else { throw MCPError("None of those is a picture Bezzle can read.") }
            let pictures = urls.compactMap { store.importPicture($0) }
            guard !pictures.isEmpty else { throw MCPError("The pictures could not be copied into the design.") }
            _ = try onSelection(store, [grid.id], "Fill Cells with Pictures") { copy in copy.fill(slot, in: grid.id, withPictures: pictures) }
            return described([grid.id], in: store, depth: 1)
        }

        guard first.kind == .text else { throw MCPError("\(first.name) is a \(first.kind.rawValue): give it pictures, or give a text layer for words.") }
        var values = try args.strings("values")
        if values == nil, let sample = try args.string("sample") {
            let wanted = sample.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            guard let kind = SampleContent.allCases.first(where: { $0.rawValue.lowercased() == wanted || $0.title.key.lowercased().replacingOccurrences(of: " ", with: "") == wanted })
            else { throw MCPError("sample is one of \(Self.sampleNames.joined(separator: ", ")).") }
            values = kind.values(count, like: first.text ?? "", seed: Int.random(in: 0..<10_000))
        }
        guard let values, !values.isEmpty else { throw MCPError("Give values, a sample, pictures or data.") }
        _ = try onSelection(store, [grid.id], "Fill Cells") { copy in copy.fill(slot, in: grid.id, with: values) }
        return described([grid.id], in: store, depth: 1)
    }

    static let sampleNames = SampleContent.allCases.map { $0.title.key.lowercased().replacingOccurrences(of: " ", with: "_") }

    // MARK: Describing grids

    /// What a grid is beyond a group: its columns, rows and gaps, and what each cell's text layers
    /// say, in reading order.
    static func gridDetails(_ grid: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        guard let spec = grid.grid, let layout = RepeatGrid.layout(of: grid) else { return [] }
        var texts: [(String, JSONValue)] = []
        func visit(_ n: Node) {
            if n.kind == .text {
                let words = spec.cells.map { cell -> JSONValue in
                    doc.node(n.id.mixed(RepeatGrid.key(cell)))?.text.map { .string($0) } ?? .null
                }
                texts.append((n.name, .array(words)))
            }
            n.children.forEach(visit)
        }
        visit(grid.children[layout.first])
        return [("repeatGrid", .compact([
            ("columns", .number(spec.columns)), ("rows", .number(spec.rows)),
            ("columnGap", .number(spec.columnGap)), ("rowGap", .number(spec.rowGap)),
            ("rotation", spec.turn != 0 ? .number((spec.turn * 10).rounded() / 10) : nil),
            ("cellTexts", texts.isEmpty ? nil : .object(texts)),
            ("note", .string("layers lists the first cell only; the others are copies of it, by text layer above.")),
        ]))]
    }

    /// What a layer holds as the assistant is told of it: of a grid, only its first cell; of a
    /// deck, only its first post.
    static func listed(in node: Node) -> [Node] {
        if node.isDeck { return node.layers(of: node.posts.first) }
        guard node.isRepeatGrid, let layout = RepeatGrid.layout(of: node) else { return node.children }
        return [node.children[layout.first]]
    }

    /// Of several layers of one name, those that are not copies in a grid's other cells, nor in a
    /// deck's other posts or the design behind them.
    static func firstCells(_ nodes: [Node], in doc: BezzleDocument) -> [Node] {
        nodes.filter { n in
            if let (deck, post) = doc.post(of: n.id), post != deck.posts.first { return false }
            guard let grid = doc.ancestors(of: n.id).last(where: \.isRepeatGrid) else { return true }
            return RepeatGrid.cell(of: n.id, in: grid, doc: doc)?.cell == .first
        }
    }
}
