import Foundation
import CoreGraphics

/// What an artboard is laid out on: columns side by side across it, rows one under another down
/// it, and the baselines text sits on. It is drawn over the artboard on the canvas only and never
/// exported. What is moved, resized or drawn on the artboard catches on the edges of its columns
/// and rows, and text catches on its baselines by its first line. On a carousel it repeats on
/// every slide. The columns and rows stretch between the margins, so they follow the artboard as
/// it grows and shrinks.
nonisolated struct LayoutGrid: Codable, Hashable {
    /// Bands of the same size, `gutter` apart, filling what `margin` leaves at either end.
    nonisolated struct Track: Codable, Hashable {
        var count: Int
        var gutter: CGFloat
        var margin: CGFloat

        static let counts = 1...48

        /// Each band's start and end along a side `length` long. Bands are never narrower than nothing,
        /// even when the gutters and margins take more than there is.
        func bands(along length: CGFloat) -> [(start: CGFloat, end: CGFloat)] {
            let n = max(count, 1)
            let size = max((length - margin * 2 - gutter * CGFloat(n - 1)) / CGFloat(n), 0)
            return (0..<n).map { i in
                let start = margin + CGFloat(i) * (size + gutter)
                return (start, start + size)
            }
        }

        /// Each band's size along a side `length` long.
        func size(along length: CGFloat) -> CGFloat {
            bands(along: length).first.map { $0.end - $0.start } ?? 0
        }

        /// Within what can be had: at least one band, and no gutter or margin below nothing.
        var tidied: Track {
            Track(count: min(max(count, Self.counts.lowerBound), Self.counts.upperBound), gutter: max(gutter.rounded(), 0), margin: max(margin.rounded(), 0))
        }
    }

    /// Lines `step` apart, the first `offset` below the top.
    nonisolated struct Baseline: Codable, Hashable {
        var step: CGFloat
        var offset: CGFloat = 0

        static let steps: ClosedRange<CGFloat> = 2...200

        /// Where each line lies down a side `length` long; no more than `limit` of them.
        func lines(along length: CGFloat, limit: Int = 4000) -> [CGFloat] {
            guard step >= 1 else { return [] }
            var out: [CGFloat] = []
            var y = offset.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y <= length + 0.001, out.count < limit {
                out.append(y)
                y += step
            }
            return out
        }

        var tidied: Baseline {
            Baseline(step: min(max((step * 2).rounded() / 2, Self.steps.lowerBound), Self.steps.upperBound), offset: max(offset.rounded(), 0))
        }
    }

    var columns: Track?
    var rows: Track?
    var baseline: Baseline?

    var isEmpty: Bool { columns == nil && rows == nil && baseline == nil }

    /// What a grid comes to on an artboard: nil when it has nothing in it.
    var orNil: LayoutGrid? { isEmpty ? nil : self }

    // MARK: On an artboard

    /// Where the grid is laid out on an artboard, in its own coordinates: once on each slide of a
    /// carousel, and once on the whole of any other.
    static func areas(of board: Node) -> [CGRect] {
        board.isCarousel && board.slideCount > 1 ? board.slideRects : [CGRect(origin: .zero, size: board.frame.size)]
    }

    /// The columns in an area, each as tall as the area.
    func columnRects(in area: CGRect) -> [CGRect] {
        guard let columns else { return [] }
        return columns.bands(along: area.width).map { CGRect(x: area.minX + $0.start, y: area.minY, width: $0.end - $0.start, height: area.height) }
    }

    /// The rows in an area, each as wide as the area.
    func rowRects(in area: CGRect) -> [CGRect] {
        guard let rows else { return [] }
        return rows.bands(along: area.height).map { CGRect(x: area.minX, y: area.minY + $0.start, width: area.width, height: $0.end - $0.start) }
    }

    /// The baselines down an area.
    func baselines(in area: CGRect) -> [CGFloat] {
        baseline?.lines(along: area.height).map { area.minY + $0 } ?? []
    }

    /// What layers catch on, in the artboard's coordinates: the edges of every column and row,
    /// across and down. Baselines are kept apart, since only text sits on them.
    func edges(of board: Node) -> (xs: [CGFloat], ys: [CGFloat], baselines: [CGFloat]) {
        var xs: [CGFloat] = [], ys: [CGFloat] = [], lines: [CGFloat] = []
        for area in Self.areas(of: board) {
            for c in columnRects(in: area) { xs += [c.minX, c.maxX] }
            for r in rowRects(in: area) { ys += [r.minY, r.maxY] }
            lines += baselines(in: area)
        }
        return (xs, ys, lines)
    }

    // MARK: Suggested

    /// A grid that suits an artboard of this size: four columns on a phone, eight on a tablet or a
    /// post, twelve on a desktop, with gutters and margins of the sizes those usually have; and
    /// baselines four or eight apart.
    static func suggested(for size: CGSize) -> LayoutGrid {
        let w = size.width
        let track: Track
        if w < 600 {
            track = Track(count: 4, gutter: 16, margin: 16)
        } else if w < 1200 {
            track = Track(count: 8, gutter: 24, margin: max(((w * 0.04) / 8).rounded() * 8, 24))
        } else {
            track = Track(count: 12, gutter: 24, margin: max(((w * 0.055) / 8).rounded() * 8, 32))
        }
        return LayoutGrid(columns: track, rows: nil, baseline: nil)
    }

    /// Columns for an artboard of this size, as the suggested grid has them.
    static func suggestedColumns(for size: CGSize) -> Track { suggested(for: size).columns! }

    /// Rows that make square fields with the columns: as many as fit down the artboard with the
    /// columns' gutter and margin.
    static func suggestedRows(for size: CGSize, columns: Track?) -> Track {
        let c = columns ?? suggestedColumns(for: size)
        let module = c.size(along: size.width) + c.gutter
        let count = module > 0 ? Int(((size.height - c.margin * 2 + c.gutter) / module).rounded()) : 6
        return Track(count: min(max(count, 1), 24), gutter: c.gutter, margin: c.margin)
    }

    /// Baselines for an artboard of this size: four apart on a phone, eight on anything bigger.
    static func suggestedBaseline(for size: CGSize) -> Baseline {
        Baseline(step: size.width < 600 ? 4 : 8, offset: 0)
    }
}

/// A line pulled out of a ruler onto an artboard, to line things up with. It runs down the
/// artboard (`vertical`) or across it, and keeps to the edge it was nearer when it was put there,
/// or to the middle when it was put in the middle: as the artboard grows or shrinks it stays as
/// far from that edge, as a margin does.
nonisolated struct Guideline: Codable, Hashable {
    enum Edge: String, Codable { case start, middle, end }

    var vertical: Bool
    var edge: Edge
    /// How far from the edge: in from it, or, from the middle, toward the end.
    var offset: CGFloat

    /// Where it lies across the artboard (`vertical`) or down it.
    func position(in size: CGSize) -> CGFloat {
        let length = vertical ? size.width : size.height
        switch edge {
        case .start: return offset
        case .middle: return length / 2 + offset
        case .end: return length - offset
        }
    }

    /// A guide at a place on an artboard of this size, kept to the edge it is nearer.
    static func at(_ position: CGFloat, vertical: Bool, in size: CGSize) -> Guideline {
        let length = vertical ? size.width : size.height
        let p = (position * 2).rounded() / 2
        if abs(p - length / 2) < 0.25 { return Guideline(vertical: vertical, edge: .middle, offset: 0) }
        return p < length / 2 ? Guideline(vertical: vertical, edge: .start, offset: p) : Guideline(vertical: vertical, edge: .end, offset: length - p)
    }

    /// A key for a new guide that none of `taken` has.
    static func key(besides taken: some Collection<String>) -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyz23456789")
        while true {
            let key = String((0..<8).map { _ in letters.randomElement()! })
            if !taken.contains(key) { return key }
        }
    }
}

nonisolated extension Node {
    /// Its guides in a steady order: down the artboard first, then across, each way from the start.
    func sortedGuides() -> [(key: String, guide: Guideline)] {
        let size = frame.size
        return (guides ?? [:]).map { (key: $0.key, guide: $0.value) }.sorted { a, b in
            if a.guide.vertical != b.guide.vertical { return a.guide.vertical }
            let pa = a.guide.position(in: size), pb = b.guide.position(in: size)
            return pa != pb ? pa < pb : a.key < b.key
        }
    }
}
