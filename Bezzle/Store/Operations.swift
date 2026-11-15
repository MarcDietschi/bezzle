import AppKit

/// What can be done to the layers: adding and removing them, arranging, aligning, copying.
extension DocumentStore {
    // MARK: Adding and removing

    /// Adds a layer whose frame is in canvas points, onto `artboard` or the canvas, and selects it.
    func add(_ node: Node, onto artboard: UUID?, action: LocalizedStringResource? = nil) {
        edit(action ?? node.kind.adding) { doc in
            doc.attach(node, to: node.isArtboard ? nil : artboard)
        }
        selection = [node.id]
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        edit(ids.count == 1 ? node(ids[0])?.kind.deleting ?? "Delete Layer" : "Delete Layers") { doc in
            for id in ids { _ = doc.detach(id) }
        }
        selection = []
        hovered = nil
    }

    /// Copies of the selection placed just above each original, offset a little so they show.
    func duplicateSelection(offset: CGPoint = CGPoint(x: 10, y: 10)) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        var copies: [UUID] = []
        edit(ids.count == 1 ? "Duplicate" : "Duplicate Layers") { doc in
            copies = Self.duplicate(ids, in: &doc, offset: offset)
        }
        selection = copies
    }

    /// Puts a copy of each layer right above it and returns the copies' ids (`BezzleDocument.duplicate`).
    static func duplicate(_ ids: [UUID], in doc: inout BezzleDocument, offset: CGPoint) -> [UUID] {
        doc.duplicate(ids, offset: offset)
    }

    // MARK: Changing layers

    /// Changes every selected layer the same way. Text layers are refitted to their words afterwards.
    func updateSelection(_ action: LocalizedStringResource, _ change: (inout Node) -> Void) {
        // In Animate, a change to how layers look is keyed at the playhead (`poseLooks`).
        if animating, poseLooks(action, change) { return }
        update(selection, action, change)
    }

    func update(_ ids: [UUID], _ action: LocalizedStringResource, _ change: (inout Node) -> Void) {
        edit(action) { doc in
            for id in ids {
                doc.update(id) { node in
                    change(&node)
                    node.refit()
                }
            }
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        edit("Move") { doc in
            for id in ids { doc.update(id) { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) } }
        }
    }

    /// Moves each layer onto the artboard its centre is over, or off onto the canvas, as when it
    /// is dragged across (`BezzleDocument.settle`).
    func settle(_ ids: [UUID], in doc: inout BezzleDocument) {
        doc.settle(ids)
    }

    func setHidden(_ hidden: Bool, _ ids: [UUID]) {
        update(ids, hidden ? "Hide" : "Show") { $0.hidden = hidden }
        if hidden {
            // Hidden in a deck's post, it is still offered to stay hidden there alone, though it
            // is no longer selected.
            let offered = offer
            selection.removeAll { ids.contains($0) }
            offer = offered
        }
    }

    func setLocked(_ locked: Bool, _ ids: [UUID]) {
        update(ids, locked ? "Lock" : "Unlock") { $0.locked = locked }
    }

    func renameLayer(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update([id], "Rename") { $0.name = clean }
    }

    // MARK: Selecting

    /// Selects what lies with the selection, or on the artboard in view, or everything (`Picking.all`).
    func selectAll() {
        selection = Picking(doc: doc, selection: selection, fronts: fronts).all(focused: focusedArtboard)
    }

    // MARK: Arranging

    typealias Arrange = BezzleDocument.Arrange

    func arrange(_ how: Arrange) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let name: LocalizedStringResource = switch how {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
        edit(name) { $0.arrange(ids, how) }
    }

    /// Moves a layer in the layers list: onto an artboard (or the canvas, when nil) at `index`,
    /// counted bottom first (`BezzleDocument.move`).
    func move(_ id: UUID, to artboard: UUID?, at index: Int) {
        guard let node = doc.node(id), artboard != id else { return }
        if node.isArtboard && artboard != nil { return }
        edit("Move Layer") { $0.move(id, to: artboard, at: index) }
    }

    // MARK: Grouping

    static let grouping = LocalizedStringResource("undo.group", defaultValue: "Group", comment: "Undo name: layers put into a group.")

    var canGroup: Bool { Self.groupable(selection, in: doc) != nil }

    /// The selected groups, as Ungroup takes them apart. A repeat grid has its own way out.
    private var ungroupable: [UUID] {
        selection.filter { doc.node($0).map { $0.isGroup && !$0.isRepeatGrid } == true }
    }

    var canUngroup: Bool { !ungroupable.isEmpty }

    /// Puts the selection into a new group, which is then what is selected.
    func group() {
        var made: UUID?
        edit(Self.grouping) { doc in made = Self.group(selection, in: &doc) }
        if let made { selection = [made] }
    }

    /// Takes the selected groups apart; what was in them is then selected, beside anything else that was.
    func ungroup() {
        let ids = ungroupable
        guard !ids.isEmpty else { return }
        var freed: [UUID] = []
        edit("Ungroup") { doc in freed = Self.ungroup(ids, in: &doc) }
        selection = selection.filter { !ids.contains($0) && doc.node($0) != nil } + freed
    }

    /// The layers among `ids` that would go into a group (`BezzleDocument.groupable`).
    static func groupable(_ ids: [UUID], in doc: BezzleDocument) -> [UUID]? {
        doc.groupable(ids)
    }

    /// Puts layers into a new group and returns its id (`BezzleDocument.group`).
    @discardableResult
    static func group(_ ids: [UUID], in doc: inout BezzleDocument, name: String? = nil) -> UUID? {
        doc.group(ids, name: name)
    }

    /// Takes the layers out of groups and returns them (`BezzleDocument.ungroup`).
    @discardableResult
    static func ungroup(_ ids: [UUID], in doc: inout BezzleDocument) -> [UUID] {
        doc.ungroup(ids)
    }

    // MARK: Aligning

    typealias Align = BezzleDocument.Align

    /// Lines the selection up (`BezzleDocument.align`). A single layer lines up with its artboard.
    func align(_ how: Align) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        if ids.count == 1, doc.artboard(of: ids[0]) == nil { return }
        edit("Align") { $0.align(ids, how) }
    }

    /// Spaces three or more layers evenly between the outermost two (`BezzleDocument.distribute`).
    func distribute(horizontally: Bool) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard ids.count >= 3 else { return }
        edit("Distribute") { $0.distribute(ids, horizontally: horizontally) }
    }

    // MARK: Flipping

    /// Mirrors the selection left to right, or top to bottom, where it is: a single layer about
    /// its own middle, several about the middle of the box around them all. Artboards stay as they are.
    func flip(horizontally: Bool) {
        let ids = selection.filter { doc.node($0).map { !$0.locked && !$0.isArtboard } == true }
        guard !ids.isEmpty else { return }
        edit(horizontally ? "Flip Horizontally" : "Flip Vertically") { $0.flip(ids, horizontally: horizontally) }
    }

    /// Whether flipping the selection would change it (`BezzleDocument.canFlip`).
    var canFlip: Bool { doc.canFlip(selection) }

    // MARK: Copy and paste

    static let pasteboardType = NSPasteboard.PasteboardType(LayerClip.type)

    func copySelection() {
        guard let (clip, words) = doc.clip(of: selection, designName: name), let data = try? JSONEncoder().encode(clip) else { return }
        // What was copied last is what Paste puts down: keys copied before are let go of.
        Self.filmClip = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        // Text layers also go out as plain text, for pasting elsewhere.
        if let words { pb.setString(words, forType: .string) }
    }

    func cutSelection() {
        copySelection()
        let ids = selection
        edit("Cut") { doc in for id in ids { _ = doc.detach(id) } }
        selection = []
    }

    /// Pastes layers from Bezzle where they were copied from when that is in view, else in the
    /// middle of the view (`BezzleDocument.paste`); plain text becomes a text layer.
    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(LayerClip.self, from: data), !clip.nodes.isEmpty {
            let visible = visibleCanvasRect, target = focusedArtboard?.id, name = name
            var pasted: [UUID] = []
            edit("Paste") { pasted = $0.paste(clip, designName: name, visible: visible, focused: target) }
            selection = pasted
        } else if let string = pb.string(forType: .string), !string.isEmpty {
            let board = focusedArtboard
            let node = BezzleDocument.pastedText(string, center: board?.frame.center ?? visibleCanvasRect.center, width: board?.frame.width)
            add(node, onto: board?.id, action: "Paste")
        }
    }

    var canPaste: Bool {
        let types = NSPasteboard.general.types ?? []
        return types.contains(Self.pasteboardType) || types.contains(.string)
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) {
        viewport.zoom(to: viewport.zoom * factor, keeping: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func zoom(to zoom: CGFloat) {
        viewport.zoom(to: zoom, keeping: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    /// The next step on the zoom ladder, so repeated zooming lands on round numbers.
    func zoomStep(in: Bool) {
        let steps: [CGFloat] = [0.02, 0.05, 0.1, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]
        let z = viewport.zoom
        let next = `in` ? steps.first { $0 > z * 1.01 } ?? Viewport.maxZoom : steps.last { $0 < z * 0.99 } ?? Viewport.minZoom
        zoom(to: next)
    }

    func zoomToFit() {
        guard let bounds = doc.contentBounds else {
            viewport = Viewport(origin: CGPoint(x: -canvasSize.width / 2, y: -canvasSize.height / 2), zoom: 1)
            return
        }
        viewport.fit(bounds, in: canvasSize)
    }

    /// Where a design with no view of its own saved opens: on everything at once, or, for the
    /// welcome tour, on its first sheet as big as it fits.
    func lookFirst() {
        guard let cover = doc.node(Welcome.coverID), cover.isArtboard else { zoomToFit(); return }
        viewport.fit(cover.frame, in: canvasSize, padding: 48)
    }

    func zoomToSelection() {
        guard let bounds = selectionBounds else { zoomToFit(); return }
        viewport.fit(bounds, in: canvasSize, padding: 80, maxZoom: 8)
    }

    /// Brings a layer whole into view, at the zoom there is unless it is too big for that. A
    /// layer in view already is left where it is.
    func show(_ id: UUID) {
        guard let frame = doc.absoluteFrame(of: id), !visibleCanvasRect.contains(frame) else { return }
        viewport.fit(frame, in: canvasSize, padding: 80, maxZoom: viewport.zoom)
    }
}

