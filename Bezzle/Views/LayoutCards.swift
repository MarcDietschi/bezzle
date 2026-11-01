import SwiftUI
import AppKit

/// An artboard's layout grid as a card. Folded, what it is made of; a sideways drag sets how many
/// columns it has, clicking at the counts layouts are usually made with, and one past the bottom
/// takes the grid away. Open, its parts are switched on and off as tiles, each with its numbers
/// under it, while on the canvas its gutters, margins and baselines can be dragged.
struct LayoutCard: View {
    let store: DocumentStore
    let board: Node
    var live = false

    var body: some View {
        let grid = board.layout ?? LayoutGrid()
        AspectCard(aspect: .layout, title: "Layout Grid", summary: Self.summary(grid), dial: dial(grid),
                   remove: { store.removeLayout(from: board.id) }, removal: "Remove layout grid", live: live) {
            LayoutGlyph(grid: grid)
        } picks: {
            PartTiles(grid: grid) { part in toggle(part, in: grid) }
            if let c = grid.columns {
                track(c, columns: true)
                    .transition(.unfold)
            }
            if let r = grid.rows {
                track(r, columns: false)
                    .transition(.unfold)
            }
            if let b = grid.baseline {
                Row(title: "Baseline") {
                    NumberField(label: "", value: Double(b.step), range: Double(LayoutGrid.Baseline.steps.lowerBound)...Double(LayoutGrid.Baseline.steps.upperBound),
                                scrub: 0.1, decimals: 1, action: "Change Baseline") { v in change("Change Baseline") { $0.baseline?.step = CGFloat(v) } }
                }
                .transition(.unfold)
                Row(title: "Offset") {
                    NumberField(label: "", value: Double(b.offset), range: 0...10_000, scrub: 0.25, decimals: 0, action: "Change Baseline") { v in
                        change("Change Baseline") { $0.baseline?.offset = CGFloat(v) }
                    }
                }
                .transition(.unfold)
            }
            Caption("While this card is open, drag the gutters, margins and baselines on the artboard. What you move catches on the columns, and text sits on the baselines.")
            if grid.columns != nil || grid.rows != nil {
                HStack {
                    Spacer(minLength: 0)
                    TextButton(title: "Guides at Margins") { store.addGuidesAtMargins(of: board.id) }
                        .help("Put guides where the columns and rows begin and end, to keep to once the grid is hidden")
                }
            }
        }
        .animation(Theme.unfold, value: grid.columns != nil)
        .animation(Theme.unfold, value: grid.rows != nil)
        .animation(Theme.unfold, value: grid.baseline != nil)
    }

    /// The size the grid is laid out on: a carousel's slide, or the artboard.
    private var area: CGSize { LayoutGrid.areas(of: board).first?.size ?? board.frame.size }

    private func change(_ action: LocalizedStringResource, _ edit: @escaping (inout LayoutGrid) -> Void) {
        store.changeLayout(of: board.id, action, edit)
    }

    private func toggle(_ part: LayoutPart, in grid: LayoutGrid) {
        withAnimation(Theme.unfold) {
            switch part {
            case .columns:
                change(grid.columns == nil ? "Add Columns" : "Remove Columns") { g in
                    g.columns = g.columns == nil ? LayoutGrid.suggestedColumns(for: area) : nil
                }
            case .rows:
                change(grid.rows == nil ? "Add Rows" : "Remove Rows") { g in
                    g.rows = g.rows == nil ? LayoutGrid.suggestedRows(for: area, columns: g.columns) : nil
                }
            case .baseline:
                change(grid.baseline == nil ? "Add Baselines" : "Remove Baselines") { g in
                    g.baseline = g.baseline == nil ? LayoutGrid.suggestedBaseline(for: area) : nil
                }
            }
        }
    }

    /// How many columns or rows, and the gutters between them and the margins either side.
    @ViewBuilder private func track(_ t: LayoutGrid.Track, columns: Bool) -> some View {
        let set: (inout LayoutGrid, (inout LayoutGrid.Track) -> Void) -> Void = { g, f in
            if columns { if var c = g.columns { f(&c); g.columns = c } } else { if var r = g.rows { f(&r); g.rows = r } }
        }
        let counting: LocalizedStringResource = columns ? "Change Columns" : "Change Rows"
        let range = LayoutGrid.Track.counts
        Row(title: columns ? "Columns" : "Rows") {
            IconButton(symbol: "minus", help: columns ? "One column fewer" : "One row fewer", size: Theme.controlHeight) {
                change(columns ? "Remove Column" : "Remove Row") { set(&$0) { $0.count -= 1 } }
            }
            .opacity(t.count > range.lowerBound ? 1 : 0.35)
            .allowsHitTesting(t.count > range.lowerBound)
            NumberField(label: "", value: Double(t.count), range: Double(range.lowerBound)...Double(range.upperBound), scrub: 0.05, decimals: 0,
                        action: counting) { v in change(counting) { set(&$0) { $0.count = Int(v.rounded()) } } }
            IconButton(symbol: "plus", help: columns ? "One column more" : "One row more", size: Theme.controlHeight) {
                change(columns ? "Add Column" : "Add Row") { set(&$0) { $0.count += 1 } }
            }
            .opacity(t.count < range.upperBound ? 1 : 0.35)
            .allowsHitTesting(t.count < range.upperBound)
        }
        Row(title: "Gutter") {
            NumberField(label: "", value: Double(t.gutter), range: 0...10_000, scrub: 0.25, decimals: 0, action: "Change Gutter") { v in
                change("Change Gutter") { set(&$0) { $0.gutter = CGFloat(v) } }
            }
        }
        Row(title: "Margin") {
            NumberField(label: "", value: Double(t.margin), range: 0...10_000, scrub: 0.25, decimals: 0, action: "Change Margin") { v in
                change("Change Margin") { set(&$0) { $0.margin = CGFloat(v) } }
            }
        }
    }

    /// What the drag across the card sets: the columns, or with none the rows, or the baselines' step.
    private func dial(_ grid: LayoutGrid) -> Dial? {
        if let c = grid.columns {
            return Dial(value: Double(c.count), range: 1...24, stops: [2, 3, 4, 6, 8, 12, 16, 24], step: 1, action: "Change Columns") { v in
                let n = Int(v.rounded())
                if store.node(board.id)?.layout?.columns?.count != n { change("Change Columns") { $0.columns?.count = n } }
            }
        }
        if let r = grid.rows {
            return Dial(value: Double(r.count), range: 1...24, stops: [2, 3, 4, 6, 8, 12], step: 1, action: "Change Rows") { v in
                let n = Int(v.rounded())
                if store.node(board.id)?.layout?.rows?.count != n { change("Change Rows") { $0.rows?.count = n } }
            }
        }
        if let b = grid.baseline {
            return Dial(value: Double(b.step), range: 2...32, stops: [4, 6, 8, 12, 16, 24], step: 1, action: "Change Baseline") { v in
                let s = CGFloat(v.rounded())
                if store.node(board.id)?.layout?.baseline?.step != s { change("Change Baseline") { $0.baseline?.step = s } }
            }
        }
        return nil
    }

    static func summary(_ grid: LayoutGrid) -> String {
        // Short enough to stand beside the card's name: the columns and rows, or else the baselines.
        switch (grid.columns, grid.rows) {
        case let (c?, r?): return "\(c.count) × \(r.count)"
        case let (c?, nil): return c.count == 1 ? String(localized: "1 column") : String(localized: "\(c.count) columns")
        case let (nil, r?): return r.count == 1 ? String(localized: "1 row") : String(localized: "\(r.count) rows")
        case (nil, nil): return grid.baseline.map { String(localized: "Baseline \(SelectionInspector.said($0.step))") } ?? ""
        }
    }
}

enum LayoutPart: CaseIterable { case columns, rows, baseline }

/// The grid's three parts as tiles side by side in a well, each drawn as it looks and lifted when on.
private struct PartTiles: View {
    let grid: LayoutGrid
    let toggle: (LayoutPart) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LayoutPart.allCases, id: \.self) { part in
                Tile(part: part, on: on(part)) { toggle(part) }
            }
        }
        .padding(2)
        .well(radius: 10)
    }

    private func on(_ part: LayoutPart) -> Bool {
        switch part {
        case .columns: grid.columns != nil
        case .rows: grid.rows != nil
        case .baseline: grid.baseline != nil
        }
    }

    private struct Tile: View {
        let part: LayoutPart
        let on: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(spacing: 5) {
                PartGlyph(part: part, on: on)
                    .frame(width: 30, height: 20)
                Text(title)
                    .font(.system(size: 11, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Theme.card : Theme.ink.opacity(hovering ? 0.04 : 0))
                    .shadow(color: Theme.shadow.opacity(on ? 0.12 : 0), radius: 2, y: 1)
            }
            .scaleEffect(on ? 1 : 0.97)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.pop, value: on)
            .animation(Theme.quick, value: hovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }

        private var title: LocalizedStringResource {
            switch part {
            case .columns: "Columns"
            case .rows: "Rows"
            case .baseline: "Baselines"
            }
        }
    }
}

/// A part of a grid in small: red columns or rows, or blue lines, dashed in ink while it is off.
private struct PartGlyph: View {
    let part: LayoutPart
    let on: Bool

    var body: some View {
        Canvas { ctx, size in
            let red = Color(nsColor: CanvasInk.column), blue = Color(nsColor: CanvasInk.baseline)
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 2.5), with: .color(Theme.ink3.opacity(on ? 0.6 : 0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: on ? [] : [2, 2]))
            switch part {
            case .columns, .rows:
                let n = 4, gap: CGFloat = 2.5
                let inner = frame.insetBy(dx: 3, dy: 3)
                let along = part == .columns ? inner.width : inner.height
                let w = (along - gap * CGFloat(n - 1)) / CGFloat(n)
                for i in 0..<n {
                    let o = CGFloat(i) * (w + gap)
                    let r = part == .columns ? CGRect(x: inner.minX + o, y: inner.minY, width: w, height: inner.height)
                                             : CGRect(x: inner.minX, y: inner.minY + o, width: inner.width, height: w)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(on ? red.opacity(0.45) : Theme.ink4))
                }
            case .baseline:
                var y = frame.minY + 4
                while y < frame.maxY - 2 {
                    ctx.fill(Path(CGRect(x: frame.minX + 3, y: y, width: frame.width - 6, height: 1)), with: .color(on ? blue.opacity(0.8) : Theme.ink4))
                    y += 3.5
                }
            }
        }
        .animation(Theme.quick, value: on)
    }
}

/// The card's own small picture: the grid as it is, in a tiny sheet.
struct LayoutGlyph: View {
    let grid: LayoutGrid

    var body: some View {
        Canvas { ctx, size in
            let red = Color(nsColor: CanvasInk.column), blue = Color(nsColor: CanvasInk.baseline)
            let frame = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 2), with: .foreground, lineWidth: 1.2)
            let inner = frame.insetBy(dx: 2.5, dy: 2.5)
            if let b = grid.baseline, b.step > 0 {
                var y = inner.minY + 1
                while y < inner.maxY { ctx.fill(Path(CGRect(x: inner.minX, y: y, width: inner.width, height: 0.8)), with: .color(blue.opacity(0.8))); y += 2.5 }
            }
            if let c = grid.columns {
                let n = min(c.count, 5), gap: CGFloat = 1.2
                let w = (inner.width - gap * CGFloat(n - 1)) / CGFloat(n)
                for i in 0..<n {
                    ctx.fill(Path(CGRect(x: inner.minX + CGFloat(i) * (w + gap), y: inner.minY, width: w, height: inner.height)), with: .color(red.opacity(0.55)))
                }
            } else if let r = grid.rows {
                let n = min(r.count, 5), gap: CGFloat = 1.2
                let h = (inner.height - gap * CGFloat(n - 1)) / CGFloat(n)
                for i in 0..<n {
                    ctx.fill(Path(CGRect(x: inner.minX, y: inner.minY + CGFloat(i) * (h + gap), width: inner.width, height: h)), with: .color(red.opacity(0.55)))
                }
            }
        }
        .frame(width: 17, height: 17)
    }
}

extension SelectionInspector {
    /// A layout grid for one artboard that has none: the one that suits its size, shown on the
    /// canvas while the chip is pointed at.
    func addLayout(_ nodes: [Node]) -> AddBar.Item? {
        guard nodes.count == 1, let board = nodes.first, board.isArtboard, board.layout == nil else { return nil }
        return .init(id: "add-layout", aspect: .layout, title: "Layout Grid", help: "Add a layout grid", action: "Add Layout Grid", change: { n in
            n.layout = LayoutGrid.suggested(for: LayoutGrid.areas(of: n).first?.size ?? n.frame.size)
        }, add: { [store] in store.addLayout(to: board.id) })
    }
}

// MARK: - Guides

/// An artboard's guides as a card: how many, and pulled past the bottom, all of them taken away.
/// Open, each guide with how far it lies from the edge it keeps to, which edge that is, and a
/// cross to take it away.
struct GuidesCard: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        let guides = board.sortedGuides()
        AspectCard(aspect: .guides, title: "Guides",
                   summary: guides.count == 1 ? String(localized: "1 guide") : String(localized: "\(guides.count) guides"),
                   remove: { store.removeGuides(from: board.id) }, removal: "Remove guides") {
            GuidesGlyph()
        } picks: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(guides, id: \.key) { item in
                    GuideRow(store: store, board: board, key: item.key, guide: item.guide)
                        .transition(.unfold)
                }
            }
            Row(title: "Lock guides") {
                Switch(isOn: Binding(get: { Helpers.shared.guidesLocked }, set: { Helpers.shared.guidesLocked = $0 }))
            }
            Caption("Pull guides out of the rulers, or click a ruler to put one there. Each keeps its distance from the edge it is nearer as the artboard changes size.")
        }
        .animation(Theme.unfold, value: guides.map(\.key))
    }
}

private struct GuideRow: View {
    let store: DocumentStore
    let board: Node
    let key: String
    let guide: Guideline

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: guide.vertical ? "arrow.left.and.right" : "arrow.up.and.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.pencil)
                .frame(width: 16)
                .rotationEffect(.degrees(0))
            NumberField(label: "", value: Double(guide.offset), range: -100_000...100_000, scrub: 0.5, decimals: 1, action: "Move Guide") { v in
                store.edit("Move Guide") { doc in doc.update(board.id) { $0.guides?[key]?.offset = CGFloat(v) } }
            }
            .frame(width: 78)
            MenuButton(id: "guide-edge-\(board.id.uuidString)-\(key)", title: edgeTitle(guide.edge), width: 170, fills: true) {
                [Guideline.Edge.start, .middle, .end].map { edge in
                    MenuEntry.item(edgeTitle(edge), checked: edge == guide.edge) { keep(to: edge) }
                }
            }
            RemoveButton(help: "Remove guide") { store.removeGuide(key, from: board.id) }
        }
    }

    private func edgeTitle(_ edge: Guideline.Edge) -> LocalizedStringResource {
        switch (edge, guide.vertical) {
        case (.start, true): "Left"
        case (.middle, true): "Centre"
        case (.end, true): "Right"
        case (.start, false): "Top"
        case (.middle, false): "Middle"
        case (.end, false): "Bottom"
        }
    }

    /// Keeps the guide to another edge (or the middle), where it is: the number is how far from it.
    private func keep(to edge: Guideline.Edge) {
        let size = board.frame.size, at = guide.position(in: size), length = guide.vertical ? size.width : size.height
        let offset: CGFloat = switch edge {
        case .start: at
        case .middle: at - length / 2
        case .end: length - at
        }
        store.edit("Move Guide") { doc in doc.update(board.id) { $0.guides?[key] = Guideline(vertical: guide.vertical, edge: edge, offset: offset) } }
    }
}

/// Two guides crossing, each with its pins.
private struct GuidesGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width * 0.38, y: size.height * 0.62)
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: 1.5)); p.addLine(to: CGPoint(x: c.x, y: size.height - 1.5))
            p.move(to: CGPoint(x: 1.5, y: c.y)); p.addLine(to: CGPoint(x: size.width - 1.5, y: c.y))
            ctx.stroke(p, with: .foreground, lineWidth: 1.2)
            for q in [CGPoint(x: c.x, y: 1.5), CGPoint(x: c.x, y: size.height - 1.5), CGPoint(x: 1.5, y: c.y), CGPoint(x: size.width - 1.5, y: c.y)] {
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3)), with: .foreground)
            }
        }
        .frame(width: 16, height: 16)
    }
}
