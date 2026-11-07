import Foundation

// From the Mac's tools (Bezzle/MCP: MCPCurves, MCPComponents, MCPGrids, MCPLayout, MCPDevelop,
// MCPStyles), for Windows: what a layer is beyond its frame and looks, as layers are described.

extension MCPTools {
    /// How a text runs along a curve, for describe_layers.
    static func curveDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        guard node.kind == .text, let curve = node.curve else { return [] }
        if let bend = curve.bend { return [("curve", .object([("bend", .number(Double((bend * 360 * 10).rounded() / 10)))]))] }
        var pairs: [(String, JSONValue?)] = []
        if curve.rides == true, let shape = doc.parent(of: node.id)?.carrier { pairs.append(("shape", .string(shape.id.uuidString))) }
        pairs.append(("at", .number((CurvedText.at(of: node) * 1000).rounded() / 1000)))
        if curve.reversed == true { pairs.append(("reversed", true)) }
        if curve.hangs == true { pairs.append(("hang", true)) }
        return [("curve", .compact(pairs))]
    }

    /// What a copy is a copy of, for describing it.
    static func copyDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        guard let inst = node.instance, let master = doc.master(inst.of) else { return [] }
        return [("component", .string(master.name)),
                ("variant", Components.variants(of: master).count > 1 ? .string(Components.name(of: inst.variant, in: master)) : nil)]
    }

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

    /// A picture's development as get_layers shows it: only what is changed.
    static func describe(_ d: Develop?) -> JSONValue? {
        guard let d, !d.isNeutral else { return nil }
        var pairs: [(String, JSONValue?)] = Develop.Setting.allCases.map { s in (s.rawValue, d[s] != 0 ? .number(d[s]) : nil) }
        let colors: [(String, JSONValue?)] = Develop.Band.allCases.map { band in
            let s = d[band]
            return (band.rawValue, s.isNone ? nil : .compact(Develop.Shift.Part.allCases.map { ($0.rawValue, s[$0] != 0 ? .number(s[$0]) : nil) }))
        }
        if !d.bands.isEmpty { pairs.append(("colors", .compact(colors))) }
        return .compact(pairs)
    }

    /// The styles a layer uses, by where, for describing it.
    static func styleDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        let dark: [(String, JSONValue?)] = node.showsDark ? [("dark", true)] : []
        let named = StylePlace.all(in: node).compactMap { place -> (String, JSONValue)? in
            guard let id = place.named(in: node), let s = doc.style(id) else { return nil }
            let key: String
            switch place {
            case .fill(let i): key = i == 0 ? "fill" : "fill \(i + 1)"
            case .border(let i): key = i == 0 ? "border" : "border \(i + 1)"
            case .shadow(let i): key = i == 0 ? "shadow" : "shadow \(i + 1)"
            case .text: key = "text"
            case .corners: key = "corners"
            }
            return (key, .string(s.name))
        }
        return dark + (named.isEmpty ? [] : [("styles", .object(named))])
    }
}
