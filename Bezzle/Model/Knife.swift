import Foundation
import CoreGraphics

// The knife, shared by every Bezzle: the Mac's KnifeTool and the Windows canvas hand it the
// pointer and the keys while it is in hand and draw its blade; what it cuts goes through the host.

/// What the knife needs from the design's store.
@MainActor protocol KnifeHost: AnyObject {
    var knifeInHand: Bool { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    /// Cuts what the line runs right across, as one step; false when it parts nothing.
    func cut(along line: CGPath) -> Bool
    /// Says nothing was cut: the Mac beeps.
    func refuse()
}

/// The knife: cuts shapes into pieces along a line drawn across them. A drag cuts the way the
/// pointer went, or straight from where it began with Shift held. Clicks put down a cut line a
/// point at a time instead, as the pen does: a drag pulls a curve out of the point just put
/// down, Shift keeps each part to 45° steps, and Return, a double click or a click back on the
/// first point makes the cut. Delete takes the newest point back, Escape lets the line go.
///
/// The cut parts the selected shapes it runs right across, or, crossing none of them, every
/// shape it does. Its ends reach a little further than drawn, so a line that starts or stops
/// just inside a shape still parts it.
final class Knife {
    private let store: KnifeHost
    var redraw: () -> Void = {}

    /// A cut line being put down a point at a time, on the canvas.
    private var line: BezierPath.Subpath?

    private enum Drag {
        /// The pointer's way from a press with no line started; it is a cut once it moves.
        case trail([CGPoint], moved: Bool)
        /// Pulling the handles out of the point just put down.
        case pull(index: Int)
    }

    private var drag: Drag?
    private var downView: CGPoint = .zero
    private var flags: PenFlags = []
    /// Where the pointer is, for the part of the line still to come.
    private var pointer: CGPoint?

    init(host: KnifeHost) {
        self.store = host
    }

    var dragging: Bool { drag != nil }

    private var zoom: CGFloat { store.zoom }
    private func view(_ p: CGPoint) -> CGPoint { store.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { store.toCanvas(v) }

    /// Lets go of a line the rest of the app has moved on from.
    private func check() {
        if !store.knifeInHand, line != nil || drag != nil {
            line = nil
            drag = nil
        }
    }

    // MARK: - The pointer

    func down(at v: CGPoint, flags: PenFlags, clicks: Int) {
        check()
        downView = v
        self.flags = flags
        let p = canvas(v)
        guard var run = line else {
            drag = .trail([p], moved: false)
            redraw()
            return
        }
        // The second click of a double click: the line is done where the first put its point.
        if clicks >= 2 {
            finish()
            return
        }
        if run.anchors.count > 1, hypot(view(run.anchors[0].point).x - v.x, view(run.anchors[0].point).y - v.y) <= 6 {
            run.closed = true
            line = run
            finish()
            return
        }
        run.anchors.append(BezierPath.Anchor(place(p, after: run.anchors.last?.point)))
        line = run
        drag = .pull(index: run.anchors.count - 1)
        redraw()
    }

    func drag(to v: CGPoint, flags: PenFlags) {
        self.flags = flags
        let p = canvas(v)
        switch drag {
        case .trail(var points, let moved):
            let started = moved || hypot(v.x - downView.x, v.y - downView.y) > 3
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) * zoom >= 1 { points.append(p) }
            drag = .trail(points, moved: started)
            pointer = p
        case .pull(let index):
            guard var run = line, run.anchors.indices.contains(index), hypot(v.x - downView.x, v.y - downView.y) > 3 else { return }
            let at = run.anchors[index].point
            run.anchors[index].handleOut = p
            run.anchors[index].handleIn = CGPoint(x: 2 * at.x - p.x, y: 2 * at.y - p.y)
            line = run
        case nil:
            return
        }
        redraw()
    }

    func up(at v: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .trail(let points, let moved):
            if moved {
                let straight = flags.contains(.shift)
                let way = straight ? [points[0], canvas(v)] : Self.simplified(points + [canvas(v)], tolerance: 1.5 / zoom)
                cut(along: Self.smooth(way))
            } else {
                // Only a click: the first point of a line put down a point at a time.
                line = BezierPath.Subpath(anchors: [BezierPath.Anchor(canvas(v))])
            }
        case .pull:
            break
        }
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil).
    func hover(_ v: CGPoint?, flags: PenFlags) {
        check()
        self.flags = flags
        let was = pointer
        pointer = v.map { canvas($0) }.map { place($0, after: line?.anchors.last?.point) }
        if line != nil, was != pointer { redraw() }
    }

    /// Where the next point goes: in 45° steps from the last with Shift.
    private func place(_ p: CGPoint, after last: CGPoint?) -> CGPoint {
        guard flags.contains(.shift), let last else { return p }
        return Geometry.lineEnd(from: last, to: p, constrain: true)
    }

    // MARK: - Keys

    func key(_ key: PenKey) -> Bool {
        check()
        guard store.knifeInHand else { return false }
        if drag != nil {
            if key == .escape { drag = nil; redraw(); return true }
            return false
        }
        guard var run = line else { return false }
        switch key {
        case .enter:
            finish()
        case .escape:
            line = nil
        case .delete:
            run.anchors.removeLast()
            line = run.anchors.isEmpty ? nil : run
        default:
            return false
        }
        redraw()
        return true
    }

    // MARK: - Cutting

    /// Cuts along the line put down a point at a time, when it has two points or more.
    private func finish() {
        guard let run = line else { return }
        line = nil
        drag = nil
        if run.anchors.count > 1 { cut(along: run) }
        redraw()
    }

    private func cut(along run: BezierPath.Subpath) {
        var run = run
        if !run.closed, run.anchors.count > 1 {
            // A little further at each end, so a line stopping just short of the edge still parts it.
            let reach = 8 / zoom
            let first = run.anchors[0], last = run.anchors[run.anchors.count - 1]
            let out = BezierPath.unit(first.point - (first.handleOut ?? run.anchors[1].point))
            let on = BezierPath.unit(last.point - (last.handleIn ?? run.anchors[run.anchors.count - 2].point))
            run.anchors.insert(BezierPath.Anchor(first.point + out * reach), at: 0)
            run.anchors.append(BezierPath.Anchor(last.point + on * reach))
        }
        if !store.cut(along: BezierPath(subpaths: [run]).cgPath) { store.refuse() }
    }

    /// The pointer's way with the points it hardly bends at taken out (Douglas–Peucker).
    static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            var far = 0.0 as CGFloat, at = -1
            for i in (a + 1)..<b {
                let d = Geometry.distance(from: points[i], toSegment: points[a], points[b])
                if d > far { far = d; at = i }
            }
            if far > tolerance, at > 0 {
                keep[at] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// A smooth run through the points, each curve leaving and arriving along the way from the
    /// point before to the one after (Catmull–Rom).
    static func smooth(_ points: [CGPoint]) -> BezierPath.Subpath {
        guard points.count > 2 else { return BezierPath.Subpath(anchors: points.map { BezierPath.Anchor($0) }) }
        var anchors = points.map { BezierPath.Anchor($0) }
        for i in anchors.indices {
            let before = points[max(i - 1, 0)], after = points[min(i + 1, points.count - 1)]
            let way = (after - before) * (1.0 / 6.0)
            if i > 0 { anchors[i].handleIn = points[i] - way }
            if i < points.count - 1 { anchors[i].handleOut = points[i] + way }
        }
        return BezierPath.Subpath(anchors: anchors)
    }

    // MARK: - What shows

    /// The blade on the canvas, in canvas points: the line drawn or being put down, and its points,
    /// the newest filled. Each platform draws it, a dashed warm red over a pale rim.
    func blade() -> (path: CGPath, anchors: [(point: CGPoint, newest: Bool)])? {
        check()
        guard store.knifeInHand else { return nil }
        let blade = CGMutablePath()
        var anchors: [CGPoint] = []
        if case .trail(let points, true) = drag, let first = points.first {
            if flags.contains(.shift), let end = pointer {
                blade.move(to: first)
                blade.addLine(to: end)
            } else {
                blade.addLines(between: points)
            }
        } else if let run = line {
            blade.addPath(BezierPath(subpaths: [run]).cgPath)
            anchors = run.anchors.map(\.point)
            // The part still to come, to the pointer.
            if drag == nil, let pointer, let last = run.anchors.last {
                blade.move(to: last.point)
                blade.addCurve(to: pointer, control1: last.handleOut ?? last.point, control2: pointer)
            }
        }
        guard !blade.isEmpty else { return nil }
        return (blade, anchors.enumerated().map { ($1, $0 == anchors.count - 1) })
    }
}
