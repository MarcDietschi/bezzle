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

    // MARK: Groups that keep depth

    /// What is picked, when it is groups and nothing else: what can be told whether the layers it
    /// holds keep their depth. A repeat grid is one card whatever it is told (`Node.opensInDepth`).
    var depthGroups: [Node]? {
        let nodes = selectedNodes
        return Self.canKeepDepth(nodes) ? nodes : nil
    }

    /// Whether these are groups that can be told to keep their layers' depth.
    static func canKeepDepth(_ nodes: [Node]) -> Bool {
        !nodes.isEmpty && nodes.allSatisfy { $0.isGroup && !$0.isRepeatGrid }
    }

    /// Tells the groups picked whether the layers they hold keep their depth, each standing in the
    /// artboard's scene, or each group is one card (`Node.keepsDepth`): the 3D card's switch, and
    /// the same in a group's right-click menu, for a group lying flat, whose 3D card is not open.
    func keepDepth(_ on: Bool) {
        updateSelection(on ? "Keep Layers in Depth" : "Draw as One Card") { $0.keepsDepth = on ? true : nil }
    }

    static let keepingDepth = LocalizedStringResource("Layers Keep Their Depth", comment: "Right-click menu item for a group, checked when it is so: the layers in the group stand in the artboard's 3D scene each on its own, rather than the group being one flat card.")

    // MARK: Looking from the side

    /// Whether an artboard can be looked at from the side now: while designing, in a design that
    /// can be changed, with an artboard to look at, and not while looking back at versions, which
    /// shows another design.
    var canLookFromTheSide: Bool {
        !prototyping && !isReadOnly && !versions.browsing && doc.nodes.contains { $0.isArtboard && !$0.hidden }
    }

    /// Where the menu's look from the side begins: from the left and a little above, so that what
    /// stands off the page goes to the right and down, and how high each layer stands reads at once.
    static let firstLook = DepthLook(across: -30, down: -20)

    /// Looks at the artboard being worked on from the side (`firstLook`), or, with nothing in view,
    /// at the first: the menu's way to begin what Control dragged beside the layers does by hand.
    func lookFromTheSide() {
        guard canLookFromTheSide, let board = focusedArtboard.flatMap({ $0.hidden ? nil : $0 }) ?? doc.artboards.first(where: { !$0.hidden }) else { return }
        look(at: board.id, from: Self.firstLook)
    }

    static let lookingFromTheSide = LocalizedStringResource("Look from the Side", comment: "View menu command: the artboard being worked on is looked at from the side, to see how high each layer stands in 3D.")
}
