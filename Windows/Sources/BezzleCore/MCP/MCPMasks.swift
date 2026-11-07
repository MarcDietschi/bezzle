import Foundation
import AppKit

// From Bezzle/MCP/MCPMasks.swift, for Windows (see MCPStore.swift).

/// Masks for the assistant: putting layers inside a shape, and taking them out again. See `Mask`.
extension MCPTools {
    func maskLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        var ids = try Self.layers(args, in: store)
        let doc = store.doc
        let shapeID = try args.string("shape").map { try Self.layer($0, in: doc) }
        // As with the menus, nothing locked goes into a mask, or holds one.
        let locked = (ids + (shapeID.map { [$0] } ?? [])).compactMap { doc.node($0) }.filter(\.locked).map(\.name)
        guard locked.isEmpty else {
            throw MCPError("\(locked.joined(separator: ", ")) \(locked.count == 1 ? "is" : "are") locked, and a locked layer is never masked or made to hold others. Unlock it with update_layers first.")
        }
        let plan: MaskPlan
        if let shape = shapeID {
            guard let node = doc.node(shape), node.isMask || Mask.canHold(node) else {
                throw MCPError("Only a rectangle, an ellipse or a path lying flat can hold others, or a mask, to add to it.")
            }
            ids.removeAll { $0 == shape }
            guard !ids.isEmpty else { throw MCPError("Give the layers the shape should hold as well as the shape.") }
            guard DocumentStore.groupable(ids + [shape], in: doc) != nil else {
                throw MCPError("Mask layers that lie on the same artboard, or all on the canvas, and not in a repeat grid. move_layers brings them together.")
            }
            let back = ids.compactMap { id in doc.path(of: id).map { (id: id, at: $0.indices) } }
                .sorted { $0.at.lexicographicallyPrecedes($1.at) }.map(\.id)
            plan = MaskPlan(shape: shape, held: back)
        } else {
            guard let found = DocumentStore.maskPlan(ids, in: doc) else {
                throw MCPError("Give at least two layers on the same artboard, one a rectangle, ellipse or path lying flat that the others overlap; or name it with shape.")
            }
            plan = found
        }
        var made: UUID?
        try change(store, DocumentStore.masking) { doc in made = DocumentStore.mask(plan, in: &doc) }
        guard let made, store.doc.node(made) != nil else { throw MCPError("Nothing could be masked there.") }
        store.selection = [made]
        return described([made], in: store, depth: 1)
    }

    func releaseMask(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        let masks = ids.filter { doc.node($0)?.isMask == true }
        let held = ids.filter { id in !masks.contains(id) && doc.parent(of: id).map { $0.isMask && $0.children.first?.id != id } == true }
        guard !masks.isEmpty || !held.isEmpty else { throw MCPError("Give masks, or layers inside one other than its shape.") }
        var freed: [UUID] = []
        if !masks.isEmpty {
            try change(store, DocumentStore.unmasking) { doc in freed = DocumentStore.ungroup(masks, in: &doc) }
        }
        if !held.isEmpty {
            try change(store, DocumentStore.takingOut) { doc in DocumentStore.takeOut(held, in: &doc) }
            freed += held
        }
        freed = freed.filter { store.doc.node($0) != nil }
        store.selection = freed
        return described(freed, in: store)
    }
}
