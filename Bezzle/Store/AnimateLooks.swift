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
    /// look to key. A change to no look of any layer is the design's, as it always was. False,
    /// with nothing done, where there is no film to key.
    func poseLooks(_ action: LocalizedStringResource, _ change: (inout Node) -> Void) -> Bool {
        guard animating, filmBoard != nil else { return false }
        let posed = Set(posedLayers), t = filmTime
        guard selection.contains(where: posed.contains) else { return false }
        edit(action) { doc in
            var any = false
            var rest: [UUID] = []
            for id in selection {
                var taken = false
                if posed.contains(id) {
                    doc.update(id) { node in taken = node.poseLooks(at: t, change) }
                }
                if taken { any = true } else { rest.append(id) }
            }
            guard !any else { return }
            for id in rest {
                doc.update(id) { node in
                    change(&node)
                    node.refit()
                }
            }
        }
        return true
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
