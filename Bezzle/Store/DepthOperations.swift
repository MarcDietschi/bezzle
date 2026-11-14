import Foundation

/// What the 3D card and the AI server do to layers in depth. Several layers picked that lie
/// together are one body (`DepthBody`, shared): the card shows how its lead, its largest face, is
/// turned, and what turns that turns all of them about the middle they share.
extension DocumentStore {
    /// The layer the 3D card reads when these are one body of several: its lead. Nil for one
    /// layer, or layers lying apart, which the card reads each for itself.
    func depthLead(of nodes: [Node]) -> Node? {
        guard nodes.count > 1 else { return nil }
        let bodies = doc.depthBodies(of: nodes.map(\.id))
        guard bodies.count == 1, bodies[0].count > 1 else { return nil }
        return DepthBody.lead(of: bodies[0])
    }

    /// Turns what is picked in depth: `aim` is given how each body's lead is turned and how high
    /// it stands, and says how it shall be. During a drag the body is turned from where it stood
    /// when the drag began, so nothing of it wanders however long the drag.
    func turnSelection(_ action: LocalizedStringResource, _ aim: (Transform3D) -> Transform3D) {
        let ids = selection, start = gestureBefore
        edit(action) { doc in doc.turnInDepth(ids, from: start) { _, now in aim(now) } }
    }

    /// Lays what is picked flat in the page again, a body turned together as one (`layFlat`).
    func layFlat() {
        let ids = selection, start = gestureBefore
        edit("Lay Flat") { doc in doc.layFlat(ids, from: start) }
    }

    /// Takes what is picked out of 3D: laid flat first, so that a body turned together lies as
    /// it lay before, then with nothing of depth left on it.
    func removeDepth() {
        let ids = selection
        edit("Remove 3D") { doc in
            doc.layFlat(ids)
            for id in ids { doc.update(id) { $0.transform3D = nil } }
        }
    }
}
