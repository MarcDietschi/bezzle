import Foundation
import CoreGraphics

/// How a text's letters run along a curve rather than straight.
///
/// A text is bent into an arc of its own (`bend`), or rides the outline of a shape: it lies in a
/// group with the shape, and follows the first shape there wherever it is moved, turned or
/// reshaped (`rides`). Either way the curve itself is kept in `Node.curvePath`, in the text's own
/// coordinates, worked out again whenever what it comes from changes, so drawing, picking and
/// exporting the text need nothing but the text. A text whose shape has gone keeps the curve it
/// had.
///
/// The letters always read the way the text was set: they stand on the curve, or hang from it
/// (`hangs`), running along it or against it (`reversed`), so that on a ring the words along the
/// top and those along the bottom both read upright.
nonisolated struct TextCurve: Codable, Hashable {
    /// Bent into an arc of its own: how much of a full circle the letters go round, −1…1. Above
    /// zero they arch up, below zero they sag down, and at either end they close into a ring.
    var bend: Double?
    /// Riding the outline of the first shape in its group.
    var rides: Bool?
    /// Where along the curve the text is placed from, as a share of the curve's length in the
    /// curve's own direction: where its words begin, their middle or their end, as the text is
    /// aligned, and on a closed outline always their middle. Nil for where a text first sits: the
    /// start, middle or end of an open curve, or the top of a closed one (its bottom, reversed).
    var at: Double?
    /// Whether the words run against the curve's direction, as they do along the bottom of a ring.
    var reversed: Bool?
    /// Whether the letters hang from the curve, their tops on it, rather than stand on it.
    var hangs: Bool?

    /// A bend so slight it is no bend at all.
    static let least = 0.004

    /// The shapes a text can ride: those with an outline, lying flat in the page.
    static func canCarry(_ node: Node) -> Bool {
        [.rectangle, .ellipse, .path, .line].contains(node.kind) && node.transform3D == nil && node.kind != .text
    }

    /// The name a new group of a shape and the words riding it is given: "Text on Path 1", the first not taken.
    static func name(in doc: BezzleDocument) -> String {
        let taken = Set(doc.allNodes.lazy.filter(\.isGroup).map(\.name))
        var i = 1
        while taken.contains(String(localized: "Text on Path \(i)")) { i += 1 }
        return String(localized: "Text on Path \(i)")
    }
}

nonisolated extension Node {
    /// Whether this is a text whose letters run along a curve.
    var isCurved: Bool { kind == .text && curve != nil && curvePath != nil }

    /// Whether this is a text riding a shape's outline.
    var rides: Bool { kind == .text && curve?.rides == true }

    /// Whether this is a text bent into an arc of its own.
    var bent: Bool { kind == .text && curve?.bend != nil }

    /// The shape the texts riding in this group follow: the first one in it.
    var carrier: Node? {
        guard isGroup, !isRepeatGrid, clipsToFirst != true else { return nil }
        return children.first(where: TextCurve.canCarry)
    }

    /// Whether this group holds a shape and words riding it.
    var carriesText: Bool { carrier != nil && children.contains(where: \.rides) }

    /// For a group: every text riding a shape in it laid along the outline of the first shape it
    /// holds, and fitted round its letters. A text with no shape left to ride keeps the curve it
    /// has, as its own.
    mutating func followCurves() {
        guard isGroup, children.contains(where: \.rides) else { return }
        let shape = carrier
        let outline = shape.map { Renderer.placedOutline(of: $0) }
        for i in children.indices where children[i].rides {
            guard let outline else {
                children[i].curve?.rides = nil
                continue
            }
            var text = children[i]
            // Never turned itself: the shape's turn is in its outline.
            text.rotation = 0
            var move = CGAffineTransform(translationX: -text.frame.minX, y: -text.frame.minY)
            let data = PathData.string(outline.copy(using: &move) ?? outline)
            if text.curvePath != data { text.curvePath = data }
            text.refitCurve()
            if text != children[i] { children[i] = text }
        }
    }

    /// For texts on a curve: the arc made again for the words it bends, and the frame fitted
    /// round the letters, the curve staying where it is on the page.
    mutating func refitCurve() {
        guard kind == .text, let curve else { return }
        if let bend = curve.bend {
            guard abs(bend) >= TextCurve.least else {
                straighten()
                return
            }
            let apex = arcApex(bend: bend) ?? straightApex()
            let arc = CurvedText.arc(for: self, apex: apex, bend: bend)
            // The same arc made again keeps its words exactly, so refitting changes nothing.
            if let arc, curvePath.map({ PathData.bounds($0) }).map({ Self.alike($0, arc.boundingBoxOfPath) }) != true {
                curvePath = PathData.string(arc)
            }
        }
        // A text that has only just begun to ride waits for its shape.
        guard let data = curvePath else { return }
        let laid = CurvedText.lay(self, along: PathData.cgPath(data), curve: curve)
        reframe(to: laid.box)
    }

    /// The middle of the arc a bent text lies on, in its own coordinates: the highest of the
    /// points it passes through, or for a sag, the lowest, as the arc is made through it.
    private func arcApex(bend: Double) -> CGPoint? {
        guard let data = curvePath else { return nil }
        var best: CGPoint?
        PathData.cgPath(data).applyWithBlock { element in
            let e = element.pointee
            let count: Int = switch e.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            guard count > 0 else { return }
            let q = e.points[count - 1]
            if best == nil || (bend > 0 ? q.y < best!.y : q.y > best!.y) { best = q }
        }
        return best
    }

    private static func alike(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.002 && abs(a.minY - b.minY) < 0.002 && abs(a.width - b.width) < 0.002 && abs(a.height - b.height) < 0.002
    }

    /// The middle of a straight text's first baseline, in its own coordinates.
    private func straightApex() -> CGPoint {
        var straight = self
        straight.curve = nil
        straight.curvePath = nil
        let fitted = TextLayout.fittedFrame(straight)
        return CGPoint(x: fitted.width / 2, y: TextLayout.firstBaseline(Node.with(straight, frame: fitted)))
    }

    /// The frame moved and sized to `box`, a box in the text's own coordinates, and the curve
    /// moved the other way, so that nothing moves on the page, however the text is turned.
    mutating func reframe(to box: CGRect) {
        let size = frame.size
        guard abs(box.minX) > 0.005 || abs(box.minY) > 0.005 || abs(box.width - size.width) > 0.005 || abs(box.height - size.height) > 0.005 else { return }
        let v = Geometry.rotate(CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), by: rotation)
        frame = CGRect(x: frame.midX + v.x - box.width / 2, y: frame.midY + v.y - box.height / 2, width: box.width, height: box.height)
        if let data = curvePath, box.origin != .zero {
            var move = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            let path = PathData.cgPath(data)
            curvePath = PathData.string(path.copy(using: &move) ?? path)
        }
    }

    /// For texts: bent into an arc that goes `bend` of the way round a circle, its middle staying
    /// where it is; a bend of nothing straightens it.
    mutating func bend(to bend: Double) {
        guard kind == .text else { return }
        let b = min(max(bend, -1), 1)
        guard abs(b) >= TextCurve.least else {
            straighten()
            return
        }
        if let was = curve?.bend {
            // Bent the other way, its middle stays where it is.
            if (was > 0) != (b > 0), let apex = arcApex(bend: was) {
                curve?.bend = b
                curvePath = CurvedText.arc(for: self, apex: apex, bend: b).map(PathData.string)
            } else {
                curve?.bend = b
            }
        } else {
            // From straight, or off a shape: the arc's middle where the words' middle was.
            var apex = straightApex()
            if curvePath != nil, let laid = CurvedText.laid(self) { apex = laid.anchor }
            curve = TextCurve(bend: b)
            curvePath = CurvedText.arc(for: self, apex: apex, bend: b).map(PathData.string)
            guard curvePath != nil else {
                curve = nil
                return
            }
        }
        refitCurve()
    }

    /// For texts on a curve: the letters straight again, the point the words are placed from
    /// staying where it is on the page. Bent, it keeps its turn; off a shape, it reads upright,
    /// or turned as the curve ran there when `turned`.
    mutating func straighten(turned: Bool = false) {
        guard kind == .text, curve != nil || curvePath != nil else { return }
        let laid = curvePath != nil ? CurvedText.laid(self) : nil
        let wasBent = curve?.bend != nil
        curve = nil
        curvePath = nil
        let fitted = TextLayout.fittedFrame(self)
        guard let laid else {
            frame = fitted
            return
        }
        // Where the words were placed from, on the page.
        let size = frame.size
        let v = Geometry.rotate(CGPoint(x: laid.anchor.x - size.width / 2, y: laid.anchor.y - size.height / 2), by: rotation)
        let page = CGPoint(x: frame.midX + v.x, y: frame.midY + v.y)
        if !wasBent { rotation = turned ? rotation + Double(laid.anchorAngle * 180 / .pi) : 0 }
        let rest = CGPoint(x: laid.alignK * fitted.width, y: TextLayout.firstBaseline(Node.with(self, frame: fitted)))
        let w = Geometry.rotate(CGPoint(x: rest.x - fitted.width / 2, y: rest.y - fitted.height / 2), by: rotation)
        frame = CGRect(x: page.x - w.x - fitted.width / 2, y: page.y - w.y - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
