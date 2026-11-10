import Foundation

// What the Mac's CutoutTool has Core Graphics draw into a small grey bitmap (its `cells`): which
// cells of the grid over a layer lie inside an outline, or on the subject found in its picture,
// for `CutoutLoop` to lay the line to cut along by. Bezzle's drawing on Windows is written down
// for Skia and not read back, so the cells are worked out here, from the outlines' own points.
// Nothing here asks Windows anything: Windows/Tests checks it on a Mac too.

/// The cells of the grid `CutoutLoop` lays over a layer: a value a cell, row by row from the
/// top, 255 where the cell's middle is inside and 0 where it is not.
nonisolated enum CutoutCells {
    /// The cells of a layer `width` × `height` big that lie inside `polygons`: closed lines in
    /// the layer's own coordinates, y down, filled as a path is, by its winding or `evenOdd`.
    static func cells(_ w: Int, _ h: Int, width: Double, height: Double, inside polygons: [[CGPoint]], evenOdd: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(w, 0) * max(h, 0))
        guard w > 0, h > 0, width > 0, height > 0 else { return out }
        let across = width / Double(w), down = height / Double(h)
        // The first cell whose middle is at `x` or past it; none before the first, none past the last.
        func cell(from x: Double) -> Int { Int(min(max((x / across - 0.5).rounded(.up), 0), Double(w))) }
        var crossings: [(x: Double, turn: Int)] = []
        for row in 0..<h {
            // Where the outline crosses the line through this row's middles, and which way.
            let y = (Double(row) + 0.5) * down
            crossings.removeAll(keepingCapacity: true)
            for points in polygons where points.count >= 3 {
                var a = points[points.count - 1]
                for b in points {
                    let ay = Double(a.y), by = Double(b.y)
                    if (ay <= y) != (by <= y) {
                        let x = Double(a.x) + (y - ay) / (by - ay) * (Double(b.x) - Double(a.x))
                        if x.isFinite { crossings.append((x, by > ay ? 1 : -1)) }
                    }
                    a = b
                }
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            for i in 0..<(crossings.count - 1) {
                winding += crossings[i].turn
                guard evenOdd ? (i + 1) % 2 == 1 : winding != 0 else { continue }
                // The cells whose middles lie from this crossing to the next.
                let first = cell(from: crossings[i].x), past = cell(from: crossings[i + 1].x)
                if first < past { for cell in first..<past { out[row * w + cell] = 255 } }
            }
        }
        return out
    }

    /// Where a picture lies in a layer: the unit square, across and down the picture, laid into
    /// the layer's own coordinates as x' = a·x + c·y + tx and y' = b·x + d·y + ty (the numbers
    /// of `ImageFill.placing`).
    struct Placing: Sendable, Equatable {
        var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

        /// Where a point of the layer is in the picture, across and down; nil where the picture
        /// has no size in the layer.
        func picture(x: Double, y: Double) -> (x: Double, y: Double)? {
            let det = a * d - b * c
            guard abs(det) > 1e-12 else { return nil }
            let px = x - tx, py = y - ty
            return ((d * px - c * py) / det, (a * py - b * px) / det)
        }
    }

    /// The cells of a layer `width` × `height` big that lie on what `mask` marks in the layer's
    /// picture: `mw` × `mh` values across the whole picture, rows top first, 128 and more on it.
    /// A cell past the picture's edge is off.
    static func cells(_ w: Int, _ h: Int, width: Double, height: Double, on mask: [UInt8], _ mw: Int, _ mh: Int, placed: Placing) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(w, 0) * max(h, 0))
        guard w > 0, h > 0, mw > 0, mh > 0, mask.count >= mw * mh else { return out }
        for row in 0..<h {
            let y = (Double(row) + 0.5) * height / Double(h)
            for cell in 0..<w {
                guard let p = placed.picture(x: (Double(cell) + 0.5) * width / Double(w), y: y), p.x >= 0, p.x < 1, p.y >= 0, p.y < 1 else { continue }
                if mask[min(mh - 1, Int(p.y * Double(mh))) * mw + min(mw - 1, Int(p.x * Double(mw)))] >= 128 { out[row * w + cell] = 255 }
            }
        }
        return out
    }

    /// Whether every cell is inside: a plain rectangle, whose outline `CutoutLoop` knows itself.
    static func isWhole(_ cells: [UInt8]) -> Bool { !cells.contains { $0 < 128 } }
}
