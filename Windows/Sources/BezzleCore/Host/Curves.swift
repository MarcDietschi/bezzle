import Foundation

// Words along a curve on Windows, as on the Mac (Store/CurveOperations.swift, Views/CurveCard.swift):
// texts bent into an arc of their own, laid along a shape's outline to ride it (the shared
// `BezzleDocument.ride` and `takeOffPath`, Model/TextRiding.swift), and straight again.

extension WindowsCore {
    /// The Curve card of the selected texts: bent (how far round a circle, the same for all or
    /// not), or riding a shape (where along it, and the shape's name for one text). Nil when the
    /// card does not show: not all texts, not all curved, or some bent and some riding.
    public struct CurveLook: Sendable {
        public let riding: Bool
        /// How much of a circle the words go round, −1…1, the first text's.
        public let bend: Double
        /// Whether every text is bent the same.
        public let same: Bool
        /// Where along its outline a riding text is placed from, 0…1, the first text's.
        public let at: Double
        /// The outline's shape, for one text riding it.
        public let shape: String?
    }

    public static func curveLook(_ ids: [UUID]) -> CurveLook? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard let first = nodes.first, nodes.count == ids.count, nodes.allSatisfy({ $0.kind == .text && $0.curve != nil }) else { return nil }
        let riding = nodes.allSatisfy(\.rides)
        guard riding || !nodes.contains(where: \.rides) else { return nil }
        let bend = first.curve?.bend ?? 0
        return CurveLook(riding: riding, bend: bend, same: nodes.allSatisfy { abs(($0.curve?.bend ?? 0) - bend) < 0.0005 },
                         at: CurvedText.at(of: first), shape: nodes.count == 1 ? doc.parent(of: first.id)?.carrier?.name : nil)
    }

    /// The bends the card offers, by how much of a circle the words go round, and their names.
    public static let curveBends: [(bend: Double, name: String)] = [(-0.25, "Dip"), (0.25, "Arch"), (0.5, "Half circle"), (1, "Ring")]

    /// How far round a circle words bent `bend` go, in degrees, or a ring.
    public static func curveSummary(_ bend: Double) -> String {
        if abs(abs(bend) - 1) < 0.0005 { return say("Ring") }
        let degrees = Int((abs(bend) * 360).rounded())
        return bend < 0 ? "−\(degrees)°" : "\(degrees)°"
    }

    /// Whether the texts can be bent: all of them straight texts, none locked (the Curve chip).
    public static func canCurve(_ ids: [UUID]) -> Bool {
        guard let doc = design, !ids.isEmpty else { return false }
        return ids.allSatisfy { id in doc.node(id).map { $0.kind == .text && $0.curve == nil && !$0.locked } ?? false }
    }

    /// The texts bent into arcs going `bend` of the way round a circle, or straight at nought;
    /// those riding a shape stay on it.
    public static func bend(_ ids: [UUID], to bend: Double) {
        edit { d in
            for id in ids {
                guard let n = d.node(id), n.kind == .text, !n.rides else { continue }
                d.update(id) { $0.bend(to: bend) }
            }
        }
    }

    /// The bend shown while a pick of the card is pointed at.
    public static func previewBend(_ ids: [UUID], _ bend: Double?) {
        endPreview()
        guard let bend else { return }
        preview { d in
            for id in ids {
                guard let n = d.node(id), n.kind == .text, !n.rides else { continue }
                d.update(id) { $0.bend(to: bend) }
            }
        }
    }

    /// Whether any of the texts runs along a curve, which can be straightened.
    public static func canStraighten(_ ids: [UUID]) -> Bool {
        guard let doc = design else { return false }
        return ids.contains { doc.node($0).map { $0.kind == .text && $0.curve != nil && !$0.locked } ?? false }
    }

    /// The texts straight again, those riding a shape taken off it; the texts.
    @discardableResult public static func straighten(_ ids: [UUID]) -> [UUID] {
        guard let doc = design else { return ids }
        let curved = ids.filter { doc.node($0)?.kind == .text && doc.node($0)?.curve != nil }
        guard !curved.isEmpty else { return ids }
        let riders = curved.filter { doc.node($0)?.rides == true }
        edit { d in
            d.takeOffPath(riders)
            for id in curved where !riders.contains(id) { d.update(id) { $0.straighten() } }
        }
        return ids.filter { design?.node($0) != nil }
    }

    /// Riding texts placed `at` along their outlines, 0…1.
    public static func slide(_ ids: [UUID], at: Double) {
        edit { d in
            for id in ids {
                guard d.node(id)?.rides == true else { continue }
                d.update(id) { $0.curve?.at = (at * 10_000).rounded() / 10_000 }
            }
        }
    }

    /// Riding texts sent to the other side of their outlines, reading upright there.
    public static func flipCurves(_ ids: [UUID]) {
        edit { d in
            for id in ids {
                guard d.node(id)?.rides == true else { continue }
                d.update(id) { n in
                    guard var curve = n.curve else { return }
                    curve.hangs = !(curve.hangs ?? false)
                    n.curve = curve
                }
            }
        }
    }

    // MARK: Riding a shape

    /// The selection as a text to lay along a shape: one text and one shape it could ride.
    public static func ridePair(_ ids: [UUID]) -> (text: UUID, shape: UUID)? {
        guard ids.count == 2, let doc = design, let a = doc.node(ids[0]), let b = doc.node(ids[1]) else { return nil }
        let (text, shape) = a.kind == .text ? (a, b) : (b, a)
        guard text.kind == .text, !text.rides || doc.parent(of: text.id)?.carrier?.id != shape.id, doc.canRide(text.id, on: shape.id) else { return nil }
        return (text.id, shape.id)
    }

    /// Where a text laid along a shape goes, as the Mac's DocumentStore.placement: its words'
    /// middle at the point of the outline nearest its own middle, on the side of the outline it
    /// lies on, reading upright.
    static func placement(of text: UUID, on shape: UUID, in doc: BezzleDocument) -> TextCurve? {
        guard let t = doc.node(text), let s = doc.node(shape), let frame = doc.absoluteFrame(of: text) else { return nil }
        let o = doc.parentOrigin(of: shape)
        var move = CGAffineTransform(translationX: o.x, y: o.y)
        let placed = Renderer.placedOutline(of: s)
        let walk = CurvedText.walk(placed.copy(using: &move) ?? placed, oriented: true)
        guard walk.total > 0 else { return nil }
        let near = walk.nearest(to: CGPoint(x: frame.midX, y: frame.midY))
        let reversed = cos(walk.at(near.s).angle) < -0.26
        let left = near.distance > 0.5 ? near.side > 0 : true
        var curve = TextCurve(rides: true)
        curve.reversed = reversed ? true : nil
        curve.hangs = reversed == left ? true : nil
        let k = CurvedText.alignK(t, closed: walk.closed), width = CurvedText.width(of: t), total = walk.total
        let read = reversed ? total - near.s : near.s
        let anchor = read - (0.5 - k) * width
        curve.at = ((Double((reversed ? total - anchor : anchor) / total)) * 10_000).rounded() / 10_000
        return curve
    }

    /// The selected text laid along the selected shape, where it lies nearest it, as one step;
    /// the text, to select.
    public static func ride(_ ids: [UUID]) -> UUID? {
        guard let doc = design, let (text, shape) = ridePair(ids), let curve = placement(of: text, on: shape, in: doc) else { return nil }
        edit { $0.ride(text, on: shape, curve: curve) }
        return design?.node(text) != nil ? text : nil
    }

    /// Shows the text laid along the shape, while its menu entry is pointed at.
    public static func previewRide(_ ids: [UUID], _ on: Bool) {
        endPreview()
        guard on, let doc = design, let (text, shape) = ridePair(ids), let curve = placement(of: text, on: shape, in: doc) else { return }
        preview { $0.ride(text, on: shape, curve: curve) }
    }
}
