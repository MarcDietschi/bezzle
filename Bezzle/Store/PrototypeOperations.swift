import AppKit

/// The prototype, as the store changes it: where layers go, what is said about it, where it
/// starts, and playing it. See `FlowLink`.
extension DocumentStore {
    /// Seeing the design as a prototype or as layers again.
    func prototypingChanged() {
        writingNote = nil
        flowPreview = nil
        if prototyping {
            // Looking from the side is a way of designing: the table shows every artboard from the front.
            lookFromTheFront()
            if editingText != nil { canvas?.endEditing() }
            tool = .select
            editingPath = nil
            editingPicture = nil
            building = nil
            openAspect = nil
        } else {
            player?.stop()
            player = nil
            inspecting = false
            animating = false
            // Back at the layers, Frame is open again, as it is to begin with.
            openAspect = .frame
        }
        canvas?.flowTool.modeChanged(prototyping)
    }

    /// The layers the selection links from: each, or the copy of a component it lies in.
    var linkSources: [UUID] {
        var seen = Set<UUID>()
        return selection.compactMap { doc.linkable($0) }.filter { seen.insert($0).inserted }
    }

    /// The flow the layers the selection links from all have, when they have the same.
    var sharedFlow: FlowLink? {
        let flows = linkSources.map { doc.node($0)?.flow }
        guard let first = flows.first, flows.allSatisfy({ $0 == first }) else { return nil }
        return first ?? nil
    }

    /// Sends layers to a screen, or back, or nowhere (nil, not back). What else their flows say,
    /// their notes and motion, stays (`BezzleDocument.linkFlow`, in Model/PrototypeEditing.swift).
    func linkFlow(_ ids: [UUID], to board: UUID?, back: Bool = false) {
        let ids = ids.compactMap { doc.linkable($0) }
        guard !ids.isEmpty else { return }
        edit(board == nil && !back ? "Remove Link" : "Link") { $0.linkFlow(ids, to: board, back: back) }
    }

    func unlinkFlow(_ ids: [UUID]) { linkFlow(ids, to: nil) }

    /// What is said of where layers go, written on their threads.
    func setNote(_ note: String?, for ids: [UUID]) {
        edit("Write Note") { $0.setFlowNote(note, for: ids) }
    }

    func setMotion(_ motion: FlowMotion, for ids: [UUID]) {
        edit("Change Motion") { $0.setFlowMotion(motion, for: ids) }
    }

    /// A screen goes on by itself after `seconds`, to where its own flow leads; nil stops it.
    func setGoesOn(after seconds: Double?, board: UUID) {
        edit("Go On by Itself") { $0.setGoesOn(after: seconds, board: board) }
    }

    /// Where the prototype starts.
    func setStart(_ board: UUID?) {
        edit("Move Start") { $0.markStart(board) }
    }

    /// The screen the prototype starts on.
    var startScreen: Node? { Prototype.start(of: seenDoc) }

    // MARK: Playing

    /// Plays the prototype from a screen, or from where it starts.
    func play(from board: UUID? = nil) {
        guard player == nil else { return }
        if editingText != nil { canvas?.endEditing() }
        let seen = seenDoc
        let first = board.flatMap { id in seen.node(id).flatMap { $0.isArtboard ? $0 : seen.artboard(of: id) } }
            ?? selection.first.flatMap { id in seen.node(id).flatMap { $0.isArtboard ? $0 : seen.artboard(of: id) } }
            ?? Prototype.start(of: seen)
        guard let first else { return }
        player = Player(store: self, start: first.id)
    }

    /// Where an artboard lies in the canvas view, in the view's own points, for the player to
    /// rise from and settle back into.
    func viewRect(of board: UUID) -> CGRect? {
        guard let frame = doc.node(board)?.frame else { return nil }
        return viewport.toView(frame)
    }
}
