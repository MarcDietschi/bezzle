import Foundation

// Layout grids and guides on Windows, as on the Mac (the shared LayoutGrid, Guideline and
// Model/LayoutAids.swift): what the canvas draws over each artboard, and the cards' changes.

extension WindowsCore {
    /// What shows of the drawing aids, and so what catches (the shared snapping reads `Helpers`);
    /// kept from one launch to the next, as the Mac's Helpers.
    private static let helpersRead: Void = {
        let d = UserDefaults.standard
        Helpers.shared.grids = d.object(forKey: "helpers.grids") as? Bool ?? true
        Helpers.shared.guides = d.object(forKey: "helpers.guides") as? Bool ?? true
        Helpers.shared.rulers = d.object(forKey: "helpers.rulers") as? Bool ?? true
        Helpers.shared.guidesLocked = d.bool(forKey: "helpers.guidesLocked")
    }()
    public static var showsGrids: Bool {
        get { _ = helpersRead; return Helpers.shared.grids }
        set { _ = helpersRead; Helpers.shared.grids = newValue; UserDefaults.standard.set(newValue, forKey: "helpers.grids") }
    }
    public static var showsGuides: Bool {
        get { _ = helpersRead; return Helpers.shared.guides }
        set { _ = helpersRead; Helpers.shared.guides = newValue; UserDefaults.standard.set(newValue, forKey: "helpers.guides") }
    }
    public static var showsRulers: Bool {
        get { _ = helpersRead; return Helpers.shared.rulers }
        set { _ = helpersRead; Helpers.shared.rulers = newValue; UserDefaults.standard.set(newValue, forKey: "helpers.rulers") }
    }
    public static var guidesLocked: Bool {
        get { _ = helpersRead; return Helpers.shared.guidesLocked }
        set { _ = helpersRead; Helpers.shared.guidesLocked = newValue; UserDefaults.standard.set(newValue, forKey: "helpers.guidesLocked") }
    }

    /// An artboard's grid as the canvas draws it, on the canvas: its columns and rows, and its
    /// baselines (each a height and the width it runs across), and how far apart those are.
    nonisolated public struct GridMarks: Sendable {
        public let board: UUID
        public let frame: CGRect
        public let columns: [CGRect]
        public let rows: [CGRect]
        public let baselines: [(y: CGFloat, from: CGFloat, to: CGFloat)]
        public let step: CGFloat
        /// How many columns each area has, for numbering them.
        public let perArea: Int
    }

    /// The grids of the artboards that have one, while grids show.
    public static func gridMarks() -> [GridMarks] {
        guard showsGrids, let doc = design else { return [] }
        return doc.artboards.compactMap { b in
            guard !b.hidden, let g = b.layout, !g.isEmpty else { return nil }
            let o = b.frame.origin, areas = LayoutGrid.areas(of: b)
            let columns = areas.flatMap { g.columnRects(in: $0) }.map { $0.offsetBy(dx: o.x, dy: o.y) }
            let rows = areas.flatMap { g.rowRects(in: $0) }.map { $0.offsetBy(dx: o.x, dy: o.y) }
            var lines: [(y: CGFloat, from: CGFloat, to: CGFloat)] = []
            for area in areas { for y in g.baselines(in: area) { lines.append((o.y + y, o.x + area.minX, o.x + area.maxX)) } }
            return GridMarks(board: b.id, frame: b.frame, columns: columns, rows: rows, baselines: lines,
                             step: g.baseline?.step ?? 0, perArea: g.columns?.count ?? 0)
        }
    }

    /// The guides of every artboard, while guides show: each one's line across its artboard, on the canvas.
    public static func guideLines() -> [(board: UUID, key: String, from: CGPoint, to: CGPoint, vertical: Bool)] {
        guard showsGuides, let doc = design else { return [] }
        var out: [(board: UUID, key: String, from: CGPoint, to: CGPoint, vertical: Bool)] = []
        for b in doc.artboards where !b.hidden {
            let f = b.frame
            for (key, g) in b.guides ?? [:] {
                let at = g.position(in: f.size)
                if g.vertical {
                    out.append((b.id, key, CGPoint(x: f.minX + at, y: f.minY), CGPoint(x: f.minX + at, y: f.maxY), true))
                } else {
                    out.append((b.id, key, CGPoint(x: f.minX, y: f.minY + at), CGPoint(x: f.maxX, y: f.minY + at), false))
                }
            }
        }
        return out
    }

    // MARK: The Layout Grid card

    nonisolated public struct Track: Sendable { public let count: Int, gutter: Double, margin: Double }
    /// An artboard's grid as its card shows it.
    nonisolated public struct LayoutLook: Sendable {
        public let columns: Track?
        public let rows: Track?
        public let baseline: (step: Double, offset: Double)?
    }

    public static func layoutLook(_ board: UUID) -> LayoutLook? {
        guard let g = design?.node(board)?.layout else { return nil }
        func track(_ t: LayoutGrid.Track?) -> Track? { t.map { Track(count: $0.count, gutter: Double($0.gutter), margin: Double($0.margin)) } }
        return LayoutLook(columns: track(g.columns), rows: track(g.rows), baseline: g.baseline.map { (Double($0.step), Double($0.offset)) })
    }

    public static var columnCounts: ClosedRange<Int> { LayoutGrid.Track.counts }
    public static var baselineSteps: ClosedRange<Double> { Double(LayoutGrid.Baseline.steps.lowerBound)...Double(LayoutGrid.Baseline.steps.upperBound) }

    nonisolated public enum LayoutChange: Sendable {
        /// A part switched on, with what suits the artboard, or off.
        case columns(Bool), rows(Bool), baseline(Bool)
        case count(columns: Bool, Int), gutter(columns: Bool, Double), margin(columns: Bool, Double)
        case step(Double), offset(Double)
    }

    public static func changeLayout(_ board: UUID, _ c: LayoutChange) {
        guard let node = design?.node(board) else { return }
        let area = LayoutGrid.areas(of: node).first?.size ?? node.frame.size
        func track(_ columns: Bool, _ g: inout LayoutGrid, _ f: (inout LayoutGrid.Track) -> Void) {
            if columns { if var t = g.columns { f(&t); g.columns = t } } else { if var t = g.rows { f(&t); g.rows = t } }
        }
        edit { d in
            d.changeLayout(of: board) { g in
                switch c {
                case .columns(let on): g.columns = on ? (g.columns ?? LayoutGrid.suggestedColumns(for: area)) : nil
                case .rows(let on): g.rows = on ? (g.rows ?? LayoutGrid.suggestedRows(for: area, columns: g.columns)) : nil
                case .baseline(let on): g.baseline = on ? (g.baseline ?? LayoutGrid.suggestedBaseline(for: area)) : nil
                case .count(let columns, let n): track(columns, &g) { $0.count = n }
                case .gutter(let columns, let v): track(columns, &g) { $0.gutter = CGFloat(v) }
                case .margin(let columns, let v): track(columns, &g) { $0.margin = CGFloat(v) }
                case .step(let v): g.baseline?.step = CGFloat(v)
                case .offset(let v): g.baseline?.offset = CGFloat(v)
                }
            }
        }
    }

    /// The columns that suit the artboard, and grids shown if they were hidden.
    public static func addLayout(_ board: UUID) {
        edit { $0.addLayout(to: board) }
        showsGrids = true
    }

    public static func removeLayout(_ board: UUID) { edit { $0.removeLayout(from: board) } }

    /// Whether the artboard has a grid with columns or rows, whose margins guides could keep to.
    public static func hasTracks(_ board: UUID) -> Bool {
        guard let g = design?.node(board)?.layout else { return false }
        return g.columns != nil || g.rows != nil
    }

    public static func addGuidesAtMargins(_ board: UUID) {
        guard let doc = design else { return }
        let fresh = doc.guidesAtMargins(of: board)
        guard !fresh.isEmpty else { return }
        edit { $0.addGuides(fresh, to: board) }
        showsGuides = true
    }

    // MARK: The Guides card

    /// An artboard's guides, across first and then down, each nearer its start first: its key,
    /// which way it runs, how far from the edge it keeps to, and that edge (start, middle or end).
    public static func guides(_ board: UUID) -> [(key: String, vertical: Bool, offset: Double, edge: String)] {
        guard let b = design?.node(board) else { return [] }
        return b.sortedGuides().map { item in
            let edge = switch item.guide.edge { case .start: "start"; case .middle: "middle"; case .end: "end" }
            return (item.key, item.guide.vertical, Double(item.guide.offset), edge)
        }
    }

    public static func setGuideOffset(_ board: UUID, key: String, _ v: Double) {
        edit { d in d.update(board) { $0.guides?[key]?.offset = CGFloat(v) } }
    }

    /// Keeps a guide to another edge (or the middle), where it is: its number is how far from it.
    public static func keepGuide(_ board: UUID, key: String, to edge: String) {
        guard let b = design?.node(board), let g = b.guides?[key] else { return }
        let size = b.frame.size, at = g.position(in: size), length = g.vertical ? size.width : size.height
        let (to, offset): (Guideline.Edge, CGFloat) = switch edge {
        case "start": (.start, at)
        case "middle": (.middle, at - length / 2)
        default: (.end, length - at)
        }
        edit { d in d.update(board) { $0.guides?[key] = Guideline(vertical: g.vertical, edge: to, offset: offset) } }
    }

    public static func removeGuide(_ board: UUID, key: String) { edit { $0.removeGuide(key, from: board) } }
    public static func removeGuides(_ board: UUID) { edit { $0.removeGuides(from: board) } }
    public static func hasGuides(_ board: UUID) -> Bool { design?.node(board)?.guides?.isEmpty == false }
}
