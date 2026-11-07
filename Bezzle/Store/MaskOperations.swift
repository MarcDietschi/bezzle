import Foundation

/// Masks: a shape holding other layers (see `Mask`), made, filled, emptied and taken apart.
extension DocumentStore {
    static let masking = LocalizedStringResource("undo.mask", defaultValue: "Mask", comment: "Undo name and button: layers put inside a shape, cut off at its outline.")
    static let unmasking = LocalizedStringResource("undo.release-mask", defaultValue: "Release Mask", comment: "Undo name and menu: a mask taken apart, what it held showing whole again.")
    static let takingOut = LocalizedStringResource("undo.take-out-of-mask", defaultValue: "Take Out of Mask", comment: "Undo name: layers taken out of the shape that held them.")

    // MARK: What could be masked

    /// The selection as a mask: the shape among it that would hold the rest. Nil when there is
    /// none, or when the shape would hold nothing that it overlaps.
    var maskPlan: MaskPlan? { Self.maskPlan(selection, in: doc) }

    var canMask: Bool { maskPlan != nil }

    /// Of several layers, the one that holds the rest (shared: `BezzleDocument.maskPlan`).
    static func maskPlan(_ ids: [UUID], in doc: BezzleDocument) -> MaskPlan? { doc.maskPlan(ids) }

    /// Layers being moved, held over a layer, as a mask (shared: `BezzleDocument.dipPlan`).
    static func dipPlan(_ moving: [UUID], over target: UUID, in doc: BezzleDocument) -> MaskPlan? { doc.dipPlan(moving, over: target) }

    // MARK: Making one

    /// Puts layers inside a shape, or into a mask (shared: `BezzleDocument.mask`).
    @discardableResult
    static func mask(_ plan: MaskPlan, in doc: inout BezzleDocument) -> UUID? { doc.mask(plan) }

    /// Masks the selection as `maskPlan` says, and selects the mask.
    func maskSelection() {
        guard let plan = maskPlan else { return }
        mask(plan)
    }

    func mask(_ plan: MaskPlan) {
        var made: UUID?
        edit(Self.masking) { doc in made = Self.mask(plan, in: &doc) }
        if let made, doc.node(made) != nil { selection = [made] }
    }

    // MARK: Taking it apart

    /// The one mask selected, or the mask the one layer selected lies in.
    var selectedMask: Node? {
        guard selection.count == 1, let node = node(selection[0]) else { return nil }
        if node.isMask { return node }
        return doc.parent(of: node.id).flatMap { $0.isMask ? $0 : nil }
    }

    var canReleaseMask: Bool { selectedMask.map { !$0.locked } == true }

    /// Takes a mask apart: its shape and what it held lie where they are, the shape under them,
    /// and are selected.
    func releaseMask(_ id: UUID) {
        guard node(id)?.isMask == true else { return }
        canvas?.maskTool.released(id)
        var freed: [UUID] = []
        edit(Self.unmasking) { doc in freed = Self.ungroup([id], in: &doc) }
        selection = freed.filter { doc.node($0) != nil }
    }

    /// Takes layers out of the masks they lie in (shared: `BezzleDocument.takeOutOfMasks`).
    static func takeOut(_ ids: [UUID], in doc: inout BezzleDocument) { doc.takeOutOfMasks(ids) }

    func takeOutOfMask(_ ids: [UUID]) {
        edit(Self.takingOut) { doc in Self.takeOut(ids, in: &doc) }
        selection = ids.filter { doc.node($0) != nil }
    }
}
