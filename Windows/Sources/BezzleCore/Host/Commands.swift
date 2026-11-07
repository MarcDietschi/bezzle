import Foundation

// What the Windows canvas and menus ask of the design, each the Mac's own code shared in
// Bezzle/Model (Picking, LayerArranging, LayerClipboard, LayerEditing); here only the adapters.

extension WindowsCore {
    // MARK: Picking

    /// What a click at `p` on the canvas picks, as the Mac picks it: with `selection` as it is,
    /// the group it lies in is looked in first.
    public static func pick(_ p: CGPoint, selection: [UUID], zoom: Double) -> UUID? {
        guard let doc = design else { return nil }
        return Picking(doc: doc, selection: selection, fronts: fronts, zoom: CGFloat(zoom)).pick(p)
    }

    /// What a double click on a group picks inside it, one level down.
    public static func pick(_ p: CGPoint, inGroup id: UUID, zoom: Double) -> UUID? {
        guard let doc = design, let group = doc.node(id), group.isGroup else { return nil }
        return Picking(doc: doc, fronts: fronts, zoom: CGFloat(zoom)).hit(p, in: group)
    }

    /// What a box dragged on the canvas picks: on the artboard at `index`, what it touches there;
    /// on the canvas (nil), the layers it touches and the artboards it holds whole.
    public static func marquee(_ rect: CGRect, onBoard index: Int?, zoom: Double) -> [UUID] {
        guard let doc = design else { return [] }
        let inside = index.flatMap { $0 < doc.nodes.count ? doc.nodes[$0].id : nil }
        return Picking(doc: doc, fronts: fronts, zoom: CGFloat(zoom)).marquee(rect, inside: inside)
    }

    /// What Select All picks, as on the Mac: what lies with the selection, or on the artboard at
    /// `board` when nothing is selected, or everything on the canvas.
    public static func selectAll(_ selection: [UUID], board: Int?) -> [UUID] {
        guard let doc = design else { return [] }
        let focused = board.flatMap { $0 < doc.nodes.count ? doc.nodes[$0] : nil }
        return Picking(doc: doc, selection: selection, fronts: fronts).all(focused: focused)
    }

    /// The artboard under a canvas point, by its place in the design.
    public static func board(at p: CGPoint) -> Int? {
        guard let doc = design, let board = doc.artboard(at: p) else { return nil }
        return doc.nodes.firstIndex { $0.id == board.id }
    }

    /// The artboard a layer lies on, or is, by its place in the design; for a layer on the canvas
    /// outside artboards, the place of the layer on the canvas it is or lies in.
    public static func board(of id: UUID) -> Int? {
        guard let doc = design else { return nil }
        let board = doc.node(id)?.isArtboard == true ? doc.node(id) : doc.artboard(of: id)
        if let board { return doc.nodes.firstIndex { $0.id == board.id } }
        let top = doc.ancestors(of: id).first?.id ?? id
        return doc.nodes.firstIndex { $0.id == top }
    }

    public static func isGroup(_ id: UUID) -> Bool { design?.node(id)?.isGroup == true }
    public static func isText(_ id: UUID) -> Bool { design?.node(id)?.kind == .text }
    public static func isPath(_ id: UUID) -> Bool { design?.node(id)?.kind == .path }

    /// What the Path card shows of the selected paths: whether any is filled (only a fill shows
    /// where the outline crosses itself), and whether all cut their overlaps out.
    public static func pathFills(_ ids: [UUID]) -> (filled: Bool, cutOut: Bool) {
        let nodes = ids.compactMap { design?.node($0) }
        return (nodes.contains { $0.fill.on }, !nodes.isEmpty && nodes.allSatisfy { $0.evenOdd == true })
    }

    /// Fills in where the paths' outlines overlap, or cuts it out.
    public static func setCutOut(_ ids: [UUID], _ cut: Bool) {
        edit { d in for id in ids { d.update(id) { $0.evenOdd = cut ? true : nil } } }
    }
    public static func isArtboard(_ id: UUID) -> Bool { design?.node(id)?.isArtboard == true }

    /// The box round layers on the canvas, each as far as it reaches turned.
    public static func bounds(of ids: [UUID]) -> CGRect? { design?.bounds(of: ids) }

    // MARK: Moving

    /// A line drawn while something catches on it, on the canvas; `field` for a gap as wide as
    /// another, which is filled.
    public struct GuideLine {
        public let from: CGPoint
        public let to: CGPoint
        public let field: CGRect?
    }

    nonisolated(unsafe) static var moving: (originals: [UUID: CGRect], bounds: CGRect, targets: SnapTargets, moved: CGPoint)?
    nonisolated(unsafe) static var pulling: SnapTargets?

    /// Begins moving layers, as the Mac's canvas does once a drag has gone 3 points: inside the
    /// gesture, with what they catch on worked out from the rest of the design. With `duplicate`
    /// (Alt), copies are moved, which catch on their originals; the ids moved.
    public static func beginMove(_ ids: [UUID], duplicate: Bool) -> [UUID] {
        guard let doc = design else { return ids }
        beginGesture()
        var ids = ids.filter { doc.node($0).map { !$0.locked } == true }
        if duplicate {
            var copies: [UUID] = []
            edit { copies = $0.duplicate(ids, offset: .zero) }
            ids = copies
        }
        guard let now = design else { return ids }
        var originals: [UUID: CGRect] = [:]
        for id in ids { originals[id] = now.absoluteFrame(of: id) }
        let bounds = now.bounds(of: ids) ?? .zero
        moving = (originals, bounds, SnapTargets(doc: now, moving: Set(ids)), .zero)
        return ids
    }

    /// Moves them by `delta` from where the drag began (canvas points), caught on what is around
    /// them unless `snapping` is off, Shift (`constrain`) keeping to an axis; the guides to draw.
    public static func move(by delta: CGPoint, constrain: Bool, snapping: Bool, zoom: Double) -> [GuideLine] {
        guard let m = moving else { return [] }
        let (moved, guides) = m.targets.move(m.bounds, by: delta, constrain: constrain, snapping: snapping, threshold: 5 / CGFloat(zoom))
        moving?.moved = moved
        edit { $0.place(m.originals, movedBy: moved) }
        return guides.map { GuideLine(from: $0.from, to: $0.to, field: $0.field) }
    }

    /// Ends the move: each layer goes onto the artboard its middle is over, or off onto the canvas.
    /// With `takingOut`, dragged wholly off the mask they lay in, they come out of it first.
    public static func endMove(takingOut: Bool = false) {
        // Inside the gesture each change is made again from where it began: the move with it.
        if let m = moving {
            let ids = Array(m.originals.keys)
            edit { d in
                d.place(m.originals, movedBy: m.moved)
                if takingOut { d.takeOutOfMasks(ids) }
                d.settle(ids)
            }
        }
        moving = nil
        endGesture()
    }

    /// The move made again as it stands, from what it is made from now (after a shape opened or
    /// closed under it).
    static func replayMove() {
        guard let m = moving else { return }
        edit { $0.place(m.originals, movedBy: m.moved) }
    }

    /// A move or a handle's pull taken back with Escape: the design as it was when it began, and
    /// no step made, as the Mac's canvas cancels its interaction.
    public static func cancelMove() {
        moving = nil
        pulling = nil
        adapting = [:]
        measure = nil
        cancelGesture()
    }

    /// Begins pulling a handle: what the selection's edges catch on, from the rest of the design.
    public static func beginPull(_ ids: [UUID]) {
        beginGesture()
        guard let doc = design else { return }
        pulling = SnapTargets(doc: doc, moving: Set(ids))
        // An artboard's design is read once, to be laid out again at each size the drag reaches.
        adapting = [:]
        for id in ids { if let n = doc.node(id), let session = Adapting.Session(n) { adapting[id] = session } }
    }

    /// The artboards being resized by a handle, each its design read once (the Mac's canvas
    /// adaptSessions).
    nonisolated(unsafe) static var adapting: [UUID: Adapting.Session] = [:]

    /// What the edges caught on while a handle was pulled; nil when nothing is pulled.
    static var pullTargets: SnapTargets? { pulling }

    public static func endPull() {
        pulling = nil
        endGesture()
        // Its design is laid out from the same design next time, while it is left as it is now.
        for session in adapting.values { if let n = design?.node(session.id) { Adapting.remember(source: session.source, laid: n) } }
        adapting = [:]
    }

    // MARK: Commands

    nonisolated public enum Arrange: Sendable { case front, forward, backward, back }
    nonisolated public enum Align: Sendable { case left, centerX, right, top, centerY, bottom }

    /// Copies of layers just above each, offset by ten (an artboard's beside it); the copies.
    public static func duplicate(_ ids: [UUID]) -> [UUID] {
        guard let doc = design else { return [] }
        let ids = ids.filter { doc.node($0)?.locked == false }
        var copies: [UUID] = []
        edit { copies = $0.duplicate(ids, offset: CGPoint(x: 10, y: 10)) }
        return copies
    }

    public static func canGroup(_ ids: [UUID]) -> Bool { design?.groupable(ids) != nil }

    /// The layers put into a new group; the group.
    public static func group(_ ids: [UUID]) -> UUID? {
        var made: UUID?
        edit { made = $0.group(ids) }
        return made
    }

    /// The groups among them taken apart (a repeat grid has its own way out); what was in them.
    public static func ungroup(_ ids: [UUID]) -> [UUID] {
        guard let doc = design else { return [] }
        let groups = ids.filter { doc.node($0).map { $0.isGroup && !$0.isRepeatGrid } == true }
        guard !groups.isEmpty else { return [] }
        var freed: [UUID] = []
        edit { freed = $0.ungroup(groups) }
        return freed
    }

    public static func arrange(_ ids: [UUID], _ how: Arrange) {
        let to: BezzleDocument.Arrange = switch how {
        case .front: .front
        case .forward: .forward
        case .backward: .backward
        case .back: .back
        }
        edit { $0.arrange(ids, to) }
    }

    public static func align(_ ids: [UUID], _ how: Align) {
        let to: BezzleDocument.Align = switch how {
        case .left: .left
        case .centerX: .centerX
        case .right: .right
        case .top: .top
        case .centerY: .centerY
        case .bottom: .bottom
        }
        edit { $0.align(ids, to) }
    }

    public static func distribute(_ ids: [UUID], horizontally: Bool) {
        edit { $0.distribute(ids, horizontally: horizontally) }
    }

    public static func setHidden(_ ids: [UUID], _ hidden: Bool) {
        edit { d in for id in ids { d.update(id) { $0.hidden = hidden } } }
    }

    public static func setLocked(_ ids: [UUID], _ locked: Bool) {
        edit { d in for id in ids { d.update(id) { $0.locked = locked } } }
    }

    public static func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        edit { $0.update(id) { $0.name = clean } }
    }

    /// Moves a layer in the layers list: onto the artboard at `board` (or the canvas, when nil)
    /// at `index`, counted bottom first.
    public static func moveLayer(_ id: UUID, toBoard board: Int?, at index: Int) {
        guard let doc = design else { return }
        let target = board.flatMap { $0 < doc.nodes.count ? doc.nodes[$0].id : nil }
        edit { $0.move(id, to: target, at: index) }
    }

    // MARK: The layers list

    /// A row of the layers list: the layer, how deep, and in what.
    public struct ListedRow {
        public let id: UUID
        public let depth: Int
        public let parent: UUID?
    }

    /// Where a dragged row would go: into the gap before a row, or onto one (into what it shows).
    nonisolated public enum DropPlace: Equatable, Sendable { case gap(Int), onto(Int) }

    /// The rows of the artboard at `board`, top first, as the Mac lists them (`Node.listed`: a
    /// repeat grid only its first cell); what `isShut` folds lists nothing under it.
    public static func rows(board: Int, isShut: (UUID, _ isGroup: Bool) -> Bool) -> [ListedRow] {
        listed(board: board, isShut: isShut).map { ListedRow(id: $0.id, depth: $0.depth, parent: $0.parent) }
    }

    private static func listed(board: Int, isShut: (UUID, Bool) -> Bool) -> [ListedLayer] {
        guard let doc = design, board >= 0, board < doc.nodes.count else { return [] }
        var out: [ListedLayer] = []
        func add(_ nodes: [Node], depth: Int, parent: UUID?) {
            for node in nodes.reversed() {
                out.append(ListedLayer(node: node, depth: depth, parent: parent))
                if node.isContainer, !isShut(node.id, node.isGroup) { add(node.listed(fronts: fronts), depth: depth + 1, parent: node.id) }
            }
        }
        // A layer on the canvas is listed itself, before what it holds.
        if doc.nodes[board].isArtboard { add(doc.nodes[board].listed(fronts: fronts), depth: 0, parent: doc.nodes[board].id) } else { add([doc.nodes[board]], depth: 0, parent: nil) }
        return out
    }

    private static func dropping(board: Int, isShut: @escaping (UUID, Bool) -> Bool) -> LayerDrop? {
        guard let doc = design, board >= 0, board < doc.nodes.count else { return nil }
        return LayerDrop(doc: doc, rows: listed(board: board, isShut: isShut), board: doc.nodes[board].isArtboard ? doc.nodes[board] : nil,
                         isShut: { isShut($0.id, $0.isGroup) })
    }

    /// Where the row of `id`, dragged to `y` in the list (from the top of its first row), would
    /// go, as the Mac's list drops it, and how deep it would be listed there; nil where it cannot.
    public static func dropPlace(_ id: UUID, at y: Double, board: Int, isShut: @escaping (UUID, Bool) -> Bool) -> (place: DropPlace, depth: Int)? {
        guard let drop = dropping(board: board, isShut: isShut), let row = drop.rows.first(where: { $0.id == id }) else { return nil }
        let spot = drop.spot(at: CGFloat(y), for: row)
        guard let (_, _, depth) = drop.destination(for: row, spot: spot) else { return nil }
        switch spot {
        case .gap(let i): return (.gap(i), depth)
        case .onto(let i): return (.onto(i), depth)
        }
    }

    /// The row of `id` let go there: moved into what holds that place, where it shows.
    public static func drop(_ id: UUID, at place: DropPlace, board: Int, isShut: @escaping (UUID, Bool) -> Bool) {
        guard let drop = dropping(board: board, isShut: isShut), let row = drop.rows.first(where: { $0.id == id }) else { return }
        let spot: LayerDropSpot = switch place {
        case .gap(let i): .gap(i)
        case .onto(let i): .onto(i)
        }
        guard let (parent, index, _) = drop.destination(for: row, spot: spot) else { return }
        edit { $0.move(id, to: parent, at: index) }
    }

    // MARK: Copy and paste

    /// The clipboard format layers go under, as on the Mac.
    public static let clipType = LayerClip.type

    /// What copying layers puts on the clipboard: the clip as JSON, and their words as text.
    public static func copy(_ ids: [UUID]) -> (json: String, words: String?)? {
        guard let doc = design, let (clip, words) = doc.clip(of: ids, designName: designName),
              let data = try? JSONEncoder().encode(clip), let json = String(data: data, encoding: .utf8) else { return nil }
        return (json, words)
    }

    /// Pastes layers copied in Bezzle where they were copied from when that is in `visible`, else
    /// in its middle, onto the artboard under each or the one at `board`; the pasted layers.
    public static func paste(json: String, visible: CGRect, board: Int?) -> [UUID] {
        guard let doc = design, let clip = try? JSONDecoder().decode(LayerClip.self, from: Data(json.utf8)), !clip.nodes.isEmpty else { return [] }
        let focused = board.flatMap { $0 < doc.nodes.count ? doc.nodes[$0].id : nil }
        var pasted: [UUID] = []
        edit { pasted = $0.paste(clip, designName: designName, visible: visible, focused: focused) }
        return pasted
    }

    /// Words pasted from elsewhere, as a text layer in the middle of the artboard at `board`, or of
    /// `visible` on the canvas; the new layer.
    public static func paste(text: String, visible: CGRect, board: Int?) -> UUID? {
        guard let doc = design, !text.isEmpty else { return nil }
        let sheet = board.flatMap { $0 < doc.nodes.count ? doc.nodes[$0] : nil }
        let node = BezzleDocument.pastedText(text, center: sheet?.frame.center ?? visible.center, width: sheet?.frame.width)
        edit { $0.attach(node, to: sheet?.id) }
        return node.id
    }

    /// The design's name, as its file has it.
    private static var designName: String? {
        designURL.map { $0.deletingPathExtension().lastPathComponent }
    }
}

extension WindowsCore {
    /// The artboards and groups a layer is in, outermost first, and which of them are groups.
    public static func holders(of id: UUID) -> [(id: UUID, isGroup: Bool)] {
        (design?.ancestors(of: id) ?? []).map { ($0.id, $0.isGroup) }
    }
}
