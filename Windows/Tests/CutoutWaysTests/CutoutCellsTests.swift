import Foundation
import Testing
@testable import CutoutWays

/// The cells the line round a picture is laid on (Host/CutoutCells.swift): which lie inside an
/// outline, and which on the subject found in the layer's picture.
struct CutoutCellsTests {
    private func circle(_ cx: Double, _ cy: Double, _ radius: Double, clockwise: Bool = true, points: Int = 180) -> [CGPoint] {
        (0..<points).map { i in
            let angle = Double(clockwise ? i : -i) / Double(points) * 2 * .pi
            return CGPoint(x: cx + radius * cos(angle), y: cy + radius * sin(angle))
        }
    }

    private func on(_ cells: [UInt8]) -> Int { cells.filter { $0 >= 128 }.count }

    /// The cells as rows of letters, for reading a failure.
    private func drawn(_ cells: [UInt8], _ w: Int) -> String {
        stride(from: 0, to: cells.count, by: w).map { row in cells[row..<(row + w)].map { $0 >= 128 ? "#" : "." }.joined() }.joined(separator: "\n")
    }

    @Test func aPlainRectangleFillsEveryCell() {
        let frame = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 200), CGPoint(x: 0, y: 200)]
        for evenOdd in [false, true] {
            let cells = CutoutCells.cells(160, 107, width: 300, height: 200, inside: [frame], evenOdd: evenOdd)
            #expect(cells.count == 160 * 107 && CutoutCells.isWhole(cells))
        }
        // Drawn the other way round, it is the same rectangle.
        #expect(CutoutCells.isWhole(CutoutCells.cells(40, 30, width: 300, height: 200, inside: [Array(frame.reversed())], evenOdd: false)))
        // Nothing to fill, or no room: no cell is on.
        #expect(on(CutoutCells.cells(40, 30, width: 300, height: 200, inside: [], evenOdd: false)) == 0)
        #expect(on(CutoutCells.cells(40, 30, width: 0, height: 200, inside: [frame], evenOdd: false)) == 0)
        #expect(CutoutCells.cells(0, 30, width: 300, height: 200, inside: [frame], evenOdd: false).isEmpty)
    }

    @Test func cellsAreOnWhereTheirMiddlesAreInside() {
        // A square over the left half of a layer 8 × 4 cells big, each cell 10 points.
        let half = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40)]
        let cells = CutoutCells.cells(8, 4, width: 80, height: 40, inside: [half], evenOdd: false)
        #expect(drawn(cells, 8) == Array(repeating: "####....", count: 4).joined(separator: "\n"))
        // An edge through the cells' middles takes the cells from it on, and not those before it.
        let from = [CGPoint(x: 25, y: 0), CGPoint(x: 55, y: 0), CGPoint(x: 55, y: 40), CGPoint(x: 25, y: 40)]
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, inside: [from], evenOdd: false), 8)
            == Array(repeating: "..###...", count: 4).joined(separator: "\n"))
        // A triangle, its point a little over the top.
        let triangle = [CGPoint(x: 40, y: -5), CGPoint(x: 80, y: 40), CGPoint(x: 0, y: 40)]
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, inside: [triangle], evenOdd: false), 8)
            == ["...##...", "..####..", ".######.", "########"].joined(separator: "\n"))
        // What reaches past the layer is cut at its edge.
        let past = [CGPoint(x: -500, y: -500), CGPoint(x: 500, y: -500), CGPoint(x: 500, y: 20), CGPoint(x: -500, y: 20)]
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, inside: [past], evenOdd: false), 8)
            == ["########", "########", "........", "........"].joined(separator: "\n"))
    }

    @Test func aRoundOutlineFillsAsMuchAsItHolds() {
        // An ellipse filling the frame holds π/4 of it.
        let w = 160, h = 120
        let ellipse = (0..<360).map { i -> CGPoint in
            let angle = Double(i) / 360 * 2 * .pi
            return CGPoint(x: 200 + 200 * cos(angle), y: 150 + 150 * sin(angle))
        }
        let cells = CutoutCells.cells(w, h, width: 400, height: 300, inside: [ellipse], evenOdd: false)
        #expect(abs(Double(on(cells)) / Double(w * h) - .pi / 4) < 0.01)
        #expect(!CutoutCells.isWhole(cells))
        // Its corners are off, its middle on.
        #expect(cells[0] == 0 && cells[w - 1] == 0 && cells[(h - 1) * w] == 0 && cells[h * w - 1] == 0 && cells[(h / 2) * w + w / 2] == 255)
    }

    @Test func aHoleIsLeftOpenByTheRuleThePathIsFilledBy() {
        let w = 100, h = 100
        let outer = circle(50, 50, 40), same = circle(50, 50, 20), other = circle(50, 50, 20, clockwise: false)
        let disc = Double.pi * 40 * 40, hole = Double.pi * 20 * 20
        func share(_ polygons: [[CGPoint]], evenOdd: Bool) -> Double {
            Double(on(CutoutCells.cells(w, h, width: 100, height: 100, inside: polygons, evenOdd: evenOdd)))
        }
        // Even-odd, a line inside another is a hole whichever way it runs.
        #expect(abs(share([outer, same], evenOdd: true) - (disc - hole)) < 60)
        #expect(abs(share([outer, other], evenOdd: true) - (disc - hole)) < 60)
        // By winding, only one running the other way is.
        #expect(abs(share([outer, same], evenOdd: false) - disc) < 60)
        #expect(abs(share([outer, other], evenOdd: false) - (disc - hole)) < 60)
        // Two apart are both filled.
        #expect(abs(share([circle(25, 50, 15), circle(75, 50, 15)], evenOdd: true) - 2 * .pi * 15 * 15) < 60)
    }

    @Test func theSubjectFoundIsLaidWhereItsPictureLiesInTheLayer() {
        // A mask 4 × 2, its left half on the subject.
        let mask: [UInt8] = [255, 255, 0, 0, 255, 200, 100, 0]
        // The picture filling the layer exactly.
        let whole = CutoutCells.Placing(a: 80, b: 0, c: 0, d: 40, tx: 0, ty: 0)
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, on: mask, 4, 2, placed: whole), 8)
            == Array(repeating: "####....", count: 4).joined(separator: "\n"))
        // The picture twice as wide as the layer, its middle in the layer (as one that covers it): the
        // layer shows the picture from a quarter to three quarters across, so the subject ends halfway.
        let covering = CutoutCells.Placing(a: 160, b: 0, c: 0, d: 40, tx: -40, ty: 0)
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, on: mask, 4, 2, placed: covering), 8)
            == Array(repeating: "####....", count: 4).joined(separator: "\n"))
        // The picture smaller than the layer and set in from its corner (as one that fits): past its edge nothing is on.
        let fitted = CutoutCells.Placing(a: 40, b: 0, c: 0, d: 20, tx: 20, ty: 10)
        #expect(drawn(CutoutCells.cells(8, 4, width: 80, height: 40, on: mask, 4, 2, placed: fitted), 8)
            == ["........", "..##....", "..##....", "........"].joined(separator: "\n"))
        // A picture with no size in the layer, or a mask that is not all there: nothing.
        let flat = CutoutCells.Placing(a: 0, b: 0, c: 0, d: 40, tx: 0, ty: 0)
        #expect(on(CutoutCells.cells(8, 4, width: 80, height: 40, on: mask, 4, 2, placed: flat)) == 0)
        #expect(on(CutoutCells.cells(8, 4, width: 80, height: 40, on: [255], 4, 2, placed: whole)) == 0)
    }

    @Test func aPlaceInTheLayerIsFoundInThePicture() {
        // Turned a quarter and moved: back through it, a point is where it came from.
        let placed = CutoutCells.Placing(a: 0, b: 50, c: -30, d: 0, tx: 70, ty: 10)
        // The picture's point (0.2, 0.6) lies in the layer at a·x + c·y + tx, b·x + d·y + ty.
        let x = 0 * 0.2 + -30 * 0.6 + 70, y = 50 * 0.2 + 0 * 0.6 + 10
        let back = placed.picture(x: x, y: y)
        #expect(abs((back?.x ?? 0) - 0.2) < 1e-12 && abs((back?.y ?? 0) - 0.6) < 1e-12)
    }

    @Test func theLineLaidOnTheseCellsBeginsAsTheOutlineAndEndsRoundTheSubject() {
        // A round layer, as the canvas lays the line round it (CutoutHand): the shared CutoutLoop
        // on cells worked out here.
        let size = CGSize(width: 300, height: 300)
        let cells = CutoutLoop.cells(for: size)
        let inside = CutoutCells.cells(cells.w, cells.h, width: 300, height: 300, inside: [circle(150, 150, 150)], evenOdd: false)
        #expect(!CutoutCells.isWhole(inside))
        var loop = CutoutLoop(w: cells.w, h: cells.h, inside: inside)
        // Not drawn in at all, the line is the layer's outline.
        let frame = loop.lines(tight: 0)
        #expect(frame.count == 1)
        for p in frame.first ?? [] { #expect(abs(hypot(p.x - 0.5, p.y - 0.5) - 0.5) < 0.02, "\(p)") }
        // Until the subject is found it only comes loose of the frame, wherever the subject is.
        let loose = loop.lines(tight: 0.9)
        #expect(loose.count == 1 && !loop.found)
        for p in loose.first ?? [] { #expect(hypot(p.x - 0.5, p.y - 0.5) < 0.49 && hypot(p.x - 0.5, p.y - 0.5) > 0.3, "\(p)") }
        // The subject, found in a picture that fills the layer: a square low on its right.
        var mask = [UInt8](repeating: 0, count: 100 * 100)
        for y in 50..<80 { for x in 50..<80 { mask[y * 100 + x] = 255 } }
        let whole = CutoutCells.Placing(a: 300, b: 0, c: 0, d: 300, tx: 0, ty: 0)
        loop.find(CutoutCells.cells(cells.w, cells.h, width: 300, height: 300, on: mask, 100, 100, placed: whole))
        #expect(loop.found)
        // Drawn tight, the line is round the subject, and nowhere else.
        let tight = loop.lines(tight: 1, found: 1)
        #expect(tight.count == 1)
        for p in tight.first ?? [] { #expect(p.x > 0.47 && p.x < 0.83 && p.y > 0.47 && p.y < 0.83, "\(p)") }
        // A plain rectangle's cells are all inside, which the line is told by none at all.
        let plain = CutoutCells.cells(cells.w, cells.h, width: 300, height: 300,
                                      inside: [[CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 300), CGPoint(x: 0, y: 300)]], evenOdd: false)
        #expect(CutoutCells.isWhole(plain))
        let corners = CutoutLoop(w: cells.w, h: cells.h).lines(tight: 0)
        #expect(corners.count == 1)
        for p in corners.first ?? [] { #expect(min(p.x, p.y, 1 - p.x, 1 - p.y) > -0.01 && min(p.x, p.y, 1 - p.x, 1 - p.y) < 0.01, "\(p)") }
    }
}
