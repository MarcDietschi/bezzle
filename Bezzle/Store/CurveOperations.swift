import Foundation

/// Words along a curve (see `TextCurve`): a text bent into an arc, laid on a shape's outline to
/// ride it, and taken off again.
extension DocumentStore {
    static let bending = LocalizedStringResource("undo.bend-text", defaultValue: "Bend Text", comment: "Undo name: a text's letters bent into an arc.")
    static let straightening = LocalizedStringResource("undo.straighten-text", defaultValue: "Straighten Text", comment: "Undo name: a text's letters straight again after running along a curve.")
    static let riding = LocalizedStringResource("undo.text-on-path", defaultValue: "Put Text on Path", comment: "Undo name: a text laid along a shape's outline, following it.")
    static let takingOffPath = LocalizedStringResource("undo.take-text-off-path", defaultValue: "Take Text off Path", comment: "Undo name: a text taken off the outline it ran along.")
    static let slidingText = LocalizedStringResource("undo.slide-text", defaultValue: "Move Text along Path", comment: "Undo name: a text moved along the outline it runs on, or to its other side.")

    // MARK: Riding a shape

    /// Whether a text could ride `shape`'s outline (`BezzleDocument.canRide`, in Model/TextRiding.swift).
    static func canRide(_ text: UUID, on shape: UUID, in doc: BezzleDocument) -> Bool {
        doc.canRide(text, on: shape)
    }

    /// Lays a text along a shape's outline and returns the group they share (`BezzleDocument.ride`).
    @discardableResult
    static func ride(_ text: UUID, on shape: UUID, curve: TextCurve, in doc: inout BezzleDocument) -> UUID? {
        doc.ride(text, on: shape, curve: curve)
    }

    /// Takes texts off the outlines they ride (`BezzleDocument.takeOffPath`).
    static func takeOffPath(_ ids: [UUID], in doc: inout BezzleDocument) {
        doc.takeOffPath(ids)
    }

    /// The selection as a text to lay along a shape: one text and one shape it could ride.
    var ridePair: (text: UUID, shape: UUID)? {
        guard selection.count == 2, let a = node(selection[0]), let b = node(selection[1]) else { return nil }
        let (text, shape) = a.kind == .text ? (a, b) : (b, a)
        guard text.kind == .text, !text.rides || doc.parent(of: text.id)?.carrier?.id != shape.id,
              Self.canRide(text.id, on: shape.id, in: doc) else { return nil }
        return (text.id, shape.id)
    }

    /// Where a text laid along a shape goes: its words' middle at the point of the outline nearest
    /// its own middle, on the side of the outline it lies on, reading upright.
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

    /// Lays the selected text along the selected shape, where it lies nearest it, and selects the text.
    func rideSelection() {
        guard let (text, shape) = ridePair, let curve = Self.placement(of: text, on: shape, in: doc) else { return }
        canvas?.curveTool.fly(text)
        edit(Self.riding) { doc in Self.ride(text, on: shape, curve: curve, in: &doc) }
        if doc.node(text) != nil { selection = [text] }
    }

    /// Whether anything selected runs along a curve, which can be straightened.
    var canStraighten: Bool { selectedNodes.contains { $0.kind == .text && $0.curve != nil && !$0.locked } }

    // MARK: Changing them

    /// Bends the selected texts into arcs going `bend` of the way round a circle, or straightens them at zero.
    func bendSelection(_ bend: Double, _ action: LocalizedStringResource = DocumentStore.bending) {
        updateSelection(action) { node in
            guard node.kind == .text, !node.rides else { return }
            node.bend(to: bend)
        }
    }

    /// Straightens the selected texts, taking those riding an outline off it.
    func straightenSelection() {
        let ids = selection.filter { node($0)?.kind == .text && node($0)?.curve != nil }
        guard !ids.isEmpty else { return }
        let riders = ids.filter { node($0)?.rides == true }
        edit(riders.isEmpty ? Self.straightening : Self.takingOffPath) { doc in
            Self.takeOffPath(riders, in: &doc)
            for id in ids where !riders.contains(id) { doc.update(id) { $0.straighten() } }
        }
        selection = ids.filter { doc.node($0) != nil }
    }

    /// The selected texts riding outlines turned to the other side of them, reading upright there.
    func flipSelectedCurves() {
        updateSelection(Self.slidingText) { node in
            guard node.rides, var curve = node.curve else { return }
            curve.hangs = !(curve.hangs ?? false)
            node.curve = curve
        }
    }
}
