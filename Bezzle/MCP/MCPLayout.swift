import Foundation

/// Layout grids and guides for the assistant: an artboard's columns, rows and baselines, and the
/// guides on it. See `LayoutGrid` and `Guideline`.
extension MCPTools {
    /// The artboard `layer` names, or holds the layer it names; else the selection's, or the one in sight.
    private func artboard(_ args: Arguments, in store: DocumentStore) throws -> Node {
        let doc = store.doc
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: doc)
            if let n = doc.node(id), n.isArtboard { return n }
            if let b = doc.artboard(of: id) { return b }
            throw MCPError("\(doc.node(id)?.name ?? ref) is not on an artboard. Layout grids and guides belong to artboards.")
        }
        if let b = store.focusedArtboard { return b }
        throw MCPError("Say which artboard, as layer.")
    }

    func layoutGrid(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let board = try artboard(args, in: store)
        let size = LayoutGrid.areas(of: board).first?.size ?? board.frame.size
        if try args.bool("remove") == true {
            try change(store, "Remove Layout Grid") { doc in doc.update(board.id) { $0.layout = nil } }
            return described([board.id], in: store)
        }
        var grid = board.layout ?? LayoutGrid()
        if try args.bool("suggested") == true { grid = LayoutGrid.suggested(for: size) }

        func track(_ name: String, _ current: LayoutGrid.Track?, fallback: () -> LayoutGrid.Track) throws -> LayoutGrid.Track?? {
            let count = try args.int(name), gutter = try args.number("\(name.dropLast())_gutter"), margin = try args.number("\(name.dropLast())_margin")
            guard count != nil || gutter != nil || margin != nil else { return .none }
            if count == 0 { return .some(nil) }
            var t = current ?? fallback()
            if let count {
                guard LayoutGrid.Track.counts.contains(count) else { throw MCPError("\(name) is 1 to \(LayoutGrid.Track.counts.upperBound), or 0 for none.") }
                t.count = count
            }
            if let gutter { t.gutter = CGFloat(gutter) }
            if let margin { t.margin = CGFloat(margin) }
            return .some(t)
        }
        if let c = try track("columns", grid.columns, fallback: { LayoutGrid.suggestedColumns(for: size) }) { grid.columns = c }
        if let r = try track("rows", grid.rows, fallback: { LayoutGrid.suggestedRows(for: size, columns: grid.columns) }) { grid.rows = r }
        let step = try args.number("baseline"), offset = try args.number("baseline_offset")
        if step == 0 {
            grid.baseline = nil
        } else if step != nil || offset != nil {
            var b = grid.baseline ?? LayoutGrid.suggestedBaseline(for: size)
            if let step { b.step = CGFloat(step) }
            if let offset { b.offset = CGFloat(offset) }
            grid.baseline = b
        }
        try change(store, board.layout == nil ? "Add Layout Grid" : "Change Layout Grid") { doc in
            doc.update(board.id) { n in DocumentStore.changeLayout(of: &n) { $0 = grid } }
        }
        Helpers.shared.grids = true
        return described([board.id], in: store)
    }

    func guides(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let board = try artboard(args, in: store)
        let size = board.frame.size
        var all = board.guides ?? [:]
        if let remove = try args.strings("remove") {
            if remove.contains(where: { $0.lowercased() == "all" }) { all = [:] }
            for key in remove where key.lowercased() != "all" {
                guard all[key] != nil else { throw MCPError("\(board.name) has no guide \(key); get_layers on it lists its guides.") }
                all[key] = nil
            }
        }
        var added: [String] = []
        for g in try args.objects("add") ?? [] {
            let direction = try Read.string(g["direction"], "add.direction")?.lowercased()
            guard let direction, ["vertical", "horizontal"].contains(direction) else {
                throw MCPError("Each guide to add needs direction: vertical (running down, at an x) or horizontal (across, at a y).")
            }
            guard let at = try Read.number(g["at"], "add.at") else { throw MCPError("Each guide to add needs at: how far from the edge in from.") }
            let vertical = direction == "vertical"
            let length = vertical ? size.width : size.height
            let from = try Read.string(g["from"], "add.from")?.lowercased()
            let position: CGFloat
            switch from {
            case nil, "start", "left", "top": position = CGFloat(at)
            case "middle", "center", "centre": position = length / 2 + CGFloat(at)
            case "end", "right", "bottom": position = length - CGFloat(at)
            default: throw MCPError("from is start, middle or end (or left, centre, right; top, bottom).")
            }
            let key = Guideline.key(besides: all.keys)
            var guide = Guideline.at(position, vertical: vertical, in: size)
            // Kept to the edge it was given from, when one was.
            switch from {
            case "start", "left", "top": guide = Guideline(vertical: vertical, edge: .start, offset: CGFloat(at))
            case "end", "right", "bottom": guide = Guideline(vertical: vertical, edge: .end, offset: CGFloat(at))
            case "middle", "center", "centre": guide = Guideline(vertical: vertical, edge: .middle, offset: CGFloat(at))
            default: break
            }
            all[key] = guide
            added.append(key)
        }
        try change(store, added.isEmpty ? "Remove Guides" : added.count == 1 ? "Add Guide" : "Add Guides") { doc in
            doc.update(board.id) { $0.guides = all.isEmpty ? nil : all }
        }
        if !added.isEmpty { Helpers.shared.guides = true }
        return described([board.id], in: store)
    }

    // MARK: Describing

    /// An artboard's layout grid and guides, as the assistant is told of them.
    static func layoutDetails(_ board: Node) -> [(String, JSONValue?)] {
        guard board.isArtboard else { return [] }
        var out: [(String, JSONValue?)] = []
        if let grid = board.layout {
            func track(_ t: LayoutGrid.Track?) -> JSONValue? {
                t.map { .compact([("count", .number($0.count)), ("gutter", .number($0.gutter)), ("margin", .number($0.margin))]) }
            }
            out.append(("layoutGrid", .compact([
                ("columns", track(grid.columns)), ("rows", track(grid.rows)),
                ("baseline", grid.baseline.map { .compact([("step", .number($0.step)), ("offset", .number($0.offset))]) }),
                ("perSlide", board.isCarousel ? true : nil),
            ])))
        }
        let guides = board.sortedGuides()
        if !guides.isEmpty {
            let size = board.frame.size
            out.append(("guides", .array(guides.map { item in
                let g = item.guide
                return .compact([
                    ("id", .string(item.key)),
                    ("direction", .string(g.vertical ? "vertical" : "horizontal")),
                    (g.vertical ? "x" : "y", .number((g.position(in: size) * 10).rounded() / 10)),
                    ("keptTo", .string(g.edge == .start ? (g.vertical ? "left" : "top") : g.edge == .end ? (g.vertical ? "right" : "bottom") : "middle")),
                ])
            })))
        }
        return out
    }
}
