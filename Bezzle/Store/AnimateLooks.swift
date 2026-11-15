import AppKit

/// Animate: how layers look, keyed at the playhead (`LookTrack`). The cards that change a fill, a
/// border, the corners and a shadow in the design are the ones that change them here: they show
/// the picked layers as they look at the playhead, and what they change is keyed there, the
/// design staying as it is.
extension DocumentStore {
    /// The selected layers as the cards for how they look show them: in Animate, those a pose
    /// goes to, as they look at the moment the panels show (`panelTime`); the design's otherwise.
    var lookedSelection: [Node] {
        guard animating, let board = filmBoard else { return selectedNodes }
        let t = panelTime
        return posedLayers.compactMap { board.descendant($0)?.looked(at: t) }
    }

    /// Animate: makes a change to the selection as the design's cards make it, to each layer as it
    /// looks at the playhead, and keys there what it changed of the layer's looks; nothing else of
    /// such a change reaches the design, nor does it reach a layer picked along that has no such
    /// look to key. A change to no look of any layer is the design's, as it always was, and where
    /// that changed how a layer looks (a dashed border made plain), the cards of those looks say
    /// so for a moment (`designLooked`). False, with nothing done, where there is no film to key.
    func poseLooks(_ action: LocalizedStringResource, _ change: (inout Node) -> Void) -> Bool {
        guard animating, filmBoard != nil else { return false }
        let posed = Set(posedLayers), t = filmTime
        guard selection.contains(where: posed.contains) else { return false }
        var keyed = false
        var looks = Set<Aspect>()
        edit(action) { doc in
            var rest: [UUID] = []
            for id in selection {
                var taken = false
                if posed.contains(id) {
                    doc.update(id) { node in taken = node.poseLooks(at: t, change) }
                }
                if taken { keyed = true } else { rest.append(id) }
            }
            guard !keyed else { return }
            for id in rest {
                doc.update(id) { node in
                    let was = node
                    change(&node)
                    node.refit()
                    looks.formUnion(Self.looks(changedFrom: was, to: node))
                }
            }
        }
        if keyed {
            designLooked = nil
        } else if !looks.isEmpty {
            tellDesignLooked(looks)
        }
        return true
    }

    /// Has the cards of looks a change made in Animate changed in the design itself say so, for
    /// a moment: while the same layers are picked, and the design is as that change left it.
    private func tellDesignLooked(_ looks: Set<Aspect>) {
        let told = DesignLooked(aspects: looks, layers: selection, version: version)
        designLooked = told
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(DesignLooked.shown))
            if self?.designLooked == told { self?.designLooked = nil }
        }
    }

    /// The cards whose looks differ between a layer and the same layer changed: each fill,
    /// border and shadow by its slot, the corners, and the first fill for how the layer blends
    /// (shown with it) and for a text's letters with colours of their own.
    static func looks(changedFrom was: Node, to now: Node) -> Set<Aspect> {
        var looks = Set<Aspect>()
        for slot in 0..<max(was.slots(.fill), now.slots(.fill)) where was[fill: slot] != now[fill: slot] { looks.insert(.fill(slot)) }
        for slot in 0..<max(was.slots(.border), now.slots(.border)) where was[border: slot] != now[border: slot] { looks.insert(.border(slot)) }
        for slot in 0..<max(was.slots(.shadow), now.slots(.shadow)) where was[shadow: slot] != now[shadow: slot] { looks.insert(.shadow(slot)) }
        if was.radii != now.radii || was.cornerSmoothing != now.cornerSmoothing { looks.insert(.corners) }
        if was.blend != now.blend || was.spans?.map(\.look.color) != now.spans?.map(\.look.color) { looks.insert(.fill(0)) }
        return looks
    }

    /// Changes looks of the picked layers at the playhead, each layer as it looks there: for
    /// what is not one of the design's cards, a handle on the canvas or the AI server.
    func poseLooks(of ids: [UUID], _ action: LocalizedStringResource, _ change: (inout Node) -> Void) {
        let t = filmTime
        edit(action) { doc in
            for id in ids {
                doc.update(id) { node in
                    guard !node.locked else { return }
                    _ = node.poseLooks(at: t, change)
                }
            }
        }
    }

    /// How looks stand at the playhead, over the picked layers that have them: for the bead on
    /// their card.
    func lookKeyState(_ looks: [LookTrack], at moment: Double? = nil) -> FilmKeyState {
        guard let board = filmBoard else { return .none }
        let t = moment ?? filmTime
        var state = FilmKeyState.none
        for id in posedLayers {
            guard let node = board.descendant(id) else { continue }
            for look in looks where node.fits(look) {
                if node[track: look.name]?.index(at: t) != nil { return .here }
                state = .between
            }
        }
        return state
    }

    /// Sets a key of looks at the playhead, holding how each is there; or, where every picked
    /// layer has one there already, takes it away.
    func toggleLookKeys(_ looks: [LookTrack]) {
        guard let board = filmBoard else { return }
        let t = filmTime
        // Each layer's own of them: one has a colour where another has a gradient.
        let ids = posedLayers.filter { id in board.descendant(id).map { n in looks.contains { n.lookCount($0) != nil } } == true }
        guard !ids.isEmpty else { return }
        func keyed(_ n: Node, _ look: LookTrack) -> Bool { n.fits(look) && n[track: look.name]?.index(at: t) != nil }
        let all = ids.allSatisfy { id in
            guard let n = board.descendant(id) else { return false }
            return looks.filter { n.lookCount($0) != nil }.allSatisfy { keyed(n, $0) }
        }
        edit(all ? "Remove Key" : "Add Key") { doc in
            for id in ids {
                doc.update(id) { n in
                    guard !n.locked else { return }
                    for look in looks where n.lookCount(look) != nil {
                        if all {
                            n.removeKeys(at: t, tracks: [look.name])
                        } else if !keyed(n, look), let change = n.lookValue(look, at: t) {
                            n.setLookKey(look, change: change, at: t)
                        }
                    }
                }
            }
        }
    }
}

/// Animate: what a change made on the cards for how the picked layers look changed in the design
/// itself, as no key could hold it (a dashed border made plain), and so for the whole film and not
/// at the playhead. The cards of those looks say so for a moment, in place of what they come to
/// (`SelectionInspector.toldDesign`).
struct DesignLooked: Equatable {
    /// The cards of the looks it changed.
    let aspects: Set<Aspect>
    /// The layers picked when it was made: said only while they are the ones picked.
    let layers: [UUID]
    /// The design's count of changes once it was made (`DocumentStore.version`): said only while
    /// the design is as it left it, so neither after an undo nor after a change that was keyed.
    let version: Int

    /// For how many seconds it is said.
    static let shown: Double = 5
}
