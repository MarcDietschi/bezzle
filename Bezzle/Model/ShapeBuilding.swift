import Foundation
import CoreGraphics

extension BezzleDocument {
    /// Shapes in the order they are drawn, back first.
    func backFirst(_ ids: [UUID]) -> [UUID] {
        ids.compactMap { id in path(of: id).map { (id, $0.indices) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map(\.0)
    }

    /// The pieces shapes (back first) cut each other into. Each says which of them cover it.
    func buildPieces(of ids: [UUID]) -> [Outlines.Piece] {
        Outlines.pieces(of: ids.compactMap { outline(of: $0) })
    }

    /// What joining pieces into one shape, or wiping them away, does: the shape the joined pieces
    /// make, which looks as the frontmost shape over the first piece and goes over the frontmost
    /// of those it took from; the shapes it takes from, by their place among the shapes; and
    /// what it takes. Nil when nothing would change: no piece, or one whole shape picked on its
    /// own, which would only become itself.
    struct BuildPlan {
        let made: Node?
        let frontmost: UUID?
        let from: Set<Int>
        let touched: CGPath
    }

    func buildPlan(_ picked: [Int], erase: Bool, shapes ids: [UUID], pieces: [Outlines.Piece]) -> BuildPlan? {
        let chosen = picked.filter { pieces.indices.contains($0) }
        guard let first = chosen.first, let touched = Outlines.union(chosen.map { pieces[$0].outline }) else { return nil }
        let from = Set(chosen.flatMap { pieces[$0].covers })
        if !erase, from.count == 1, let only = from.first,
           pieces.indices.filter({ pieces[$0].covers.contains(only) }).allSatisfy(chosen.contains) { return nil }
        var made: Node?
        if !erase, let look = pieces[first].covers.last.flatMap({ node(ids[$0]) }) {
            let o = parentOrigin(of: look.id)
            if var joined = look.reshaped(to: touched, origin: o) {
                joined.id = UUID()
                joined.frame = joined.frame.offsetBy(dx: o.x, dy: o.y)
                made = joined
            }
        }
        return BuildPlan(made: made, frontmost: from.max().map { ids[$0] }, from: from, touched: touched)
    }

    /// Does what a plan says: the joined shape in, and each shape it took from keeping the rest of
    /// itself, or gone when nothing is left. The shapes still being built with, back first.
    mutating func build(_ plan: BuildPlan, shapes ids: [UUID]) -> [UUID] {
        if let made = plan.made, let frontmost = plan.frontmost, let at = path(of: frontmost) {
            attach(made, to: at.parent.map { self[$0].id }, at: at.indices[at.indices.count - 1] + 1)
        }
        var kept: [UUID] = []
        for (i, id) in ids.enumerated() {
            guard plan.from.contains(i) else { kept.append(id); continue }
            guard let outline = outline(of: id), let n = node(id) else { continue }
            let rest = Outlines.cleaned(outline.subtracting(plan.touched))
            if rest.isEmpty {
                _ = detach(id)
            } else if let reshaped = n.reshaped(to: rest, origin: parentOrigin(of: id)) {
                update(id) { $0 = reshaped }
                kept.append(id)
            }
        }
        return backFirst(kept + (plan.made.map { [$0.id] } ?? []))
    }
}

/// What building with pieces needs of a canvas: the shapes being built with and their pieces,
/// joining or wiping them, and where the canvas is.
@MainActor protocol BuildHost: AnyObject {
    /// The shapes being built with, or nil while nothing is.
    var building: [UUID]? { get set }
    /// The pieces they cut each other into.
    var buildPieces: [Outlines.Piece] { get }
    /// Joins the pieces (by their place among `buildPieces`) into one shape, or wipes them away.
    func build(_ picked: [Int], erase: Bool)
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
}

/// Building with the pieces overlapping shapes cut each other into, once the selected shapes are
/// being built with, shared by every Bezzle: the canvas hands it the pointer and draws what
/// `marks` says shows. Every piece is outlined, and the one under the pointer lights up. A click
/// makes that piece a shape of its own; a drag across pieces joins every piece it touches into
/// one. With Option (Alt) held, the pieces are wiped away instead. Return, Escape, or a click away
/// from the pieces is done.
final class PieceBuilding {
    private let host: BuildHost
    var redraw: () -> Void = {}

    /// The piece under the pointer, by its place in `host.buildPieces`.
    private var hovered: Int?
    /// The pieces a drag has touched so far, in the order it touched them, and the way it went.
    private var picked: [Int] = []
    private var trail: [CGPoint] = []
    private(set) var erasing = false
    private(set) var dragging = false

    init(host: BuildHost) {
        self.host = host
    }

    var active: Bool { host.building != nil }

    private func piece(at p: CGPoint) -> Int? {
        let pieces = host.buildPieces
        return pieces.indices.last { pieces[$0].outline.contains(p) }
    }

    // MARK: - The pointer

    /// A press at a point on screen while building: on a piece it starts joining or wiping;
    /// anywhere else building is done, and false leaves the press to the canvas.
    func down(at v: CGPoint, option: Bool) -> Bool {
        guard active else { return false }
        let p = host.toCanvas(v)
        guard let i = piece(at: p) else {
            host.building = nil
            return false
        }
        dragging = true
        picked = [i]
        trail = [p]
        erasing = option
        redraw()
        return true
    }

    func drag(to v: CGPoint, option: Bool) {
        guard dragging else { return }
        let p = host.toCanvas(v)
        erasing = option
        // Every piece the way passes over, however fast the pointer goes.
        if let last = trail.last {
            let steps = max(1, Int((hypot(p.x - last.x, p.y - last.y) * host.zoom / 3).rounded(.up)))
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                let q = CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
                if let i = piece(at: q), !picked.contains(i) { picked.append(i) }
            }
        }
        trail.append(p)
        redraw()
    }

    func up(at v: CGPoint) {
        guard dragging else { return }
        dragging = false
        let chosen = picked
        picked = []
        trail = []
        host.build(chosen, erase: erasing)
        hovered = piece(at: host.toCanvas(v))
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil); whether what shows changed.
    @discardableResult func hover(_ v: CGPoint?, option: Bool) -> Bool {
        guard active else {
            hovered = nil
            return false
        }
        let was = (hovered, erasing)
        hovered = v.flatMap { piece(at: host.toCanvas($0)) }
        erasing = option
        guard was != (hovered, erasing) else { return false }
        redraw()
        return true
    }

    /// What the pointer shows while building: the cross for pieces (marked to wipe them away when
    /// `erase`) over one, or the arrow; nil while nothing is being built with.
    var pointer: (onPiece: Bool, erase: Bool)? {
        guard active else { return nil }
        return (hovered != nil || dragging, erasing)
    }

    /// Return or Escape: a drag let go of, or building done. Whether the key was taken.
    func key(_ key: PenKey) -> Bool {
        guard active, key == .escape || key == .enter else { return false }
        if dragging {
            dragging = false
            picked = []
            trail = []
        } else {
            host.building = nil
        }
        redraw()
        return true
    }

    // MARK: - What shows

    /// What a canvas draws while building, on the canvas: each piece's outline and whether it is
    /// lit (under the pointer, or touched by the drag: tinted, its edge solid; the rest faint and
    /// dashed), and the way the drag has gone, on screen. Wiping away shows in red, joining in
    /// the canvas's blue.
    struct Marks {
        var pieces: [(outline: CGPath, lit: Bool)] = []
        var trail: [CGPoint] = []
        var erasing = false
    }

    func marks() -> Marks {
        guard active else { return Marks() }
        let lit = dragging ? picked : hovered.map { [$0] } ?? []
        var m = Marks()
        m.erasing = erasing
        m.pieces = host.buildPieces.enumerated().map { ($0.element.outline, lit.contains($0.offset)) }
        if dragging, trail.count > 1 { m.trail = trail.map(host.toView) }
        return m
    }
}
