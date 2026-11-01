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

    /// Puts a copy of each layer right above it and returns the copies' ids.
    static func duplicate(_ ids: [UUID], in doc: inout BezzleDocument, offset: CGPoint) -> [UUID] {
        var copies: [UUID] = []
        for id in ids {
            // In a deck's post, the same layer of every post is copied too, each with its own words.
            if let copy = Deck.duplicate(id, in: &doc, offset: offset) {
                copies.append(copy)
                continue
            }
            guard let path = doc.path(of: id) else { continue }
            var copy = doc[path].freshCopy()
            if copy.isArtboard {
                // An artboard's copy goes beside it rather than over it.
                copy.frame.origin.x += copy.frame.width + 80
            } else {
                copy.frame.origin.x += offset.x
                copy.frame.origin.y += offset.y
            }
            var above = path
            above.indices[above.indices.count - 1] += 1
            doc.insert(copy, at: above)
            copies.append(copy.id)
        }
        return copies
    }

    // MARK: Changing layers

    /// Changes every selected layer the same way. Text layers are refitted to their words afterwards.
    func updateSelection(_ action: LocalizedStringResource, _ change: (inout Node) -> Void) {
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
    /// is dragged across. Keeps where it is on screen.
    func settle(_ ids: [UUID], in doc: inout BezzleDocument) {
        for id in ids {
            guard let node = doc.node(id), !node.isArtboard, let frame = doc.absoluteFrame(of: id) else { continue }
            // What is in a group stays in it, wherever it is dragged.
            if doc.parent(of: id)?.isGroup == true { continue }
            let target = doc.artboard(at: frame.center)?.id
            guard target != doc.parent(of: id)?.id else { continue }
            if let n = doc.detach(id) { doc.attach(n, to: target) }
        }
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

    func selectAll() {
        if let first = selection.first, let parent = doc.parent(of: first) {
            selection = (parent.isArtboard ? seenLayers(of: parent) : parent.children).filter { !$0.hidden && !$0.locked }.map(\.id)
        } else if let board = focusedArtboard, !board.children.isEmpty, selection.isEmpty {
            selection = seenLayers(of: board).filter { !$0.hidden && !$0.locked }.map(\.id)
        } else {
            selection = doc.nodes.filter { !$0.hidden && !$0.locked }.map(\.id)
        }
    }

    // MARK: Arranging

    enum Arrange { case front, forward, backward, back }

    func arrange(_ how: Arrange) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let name: LocalizedStringResource = switch how {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
        edit(name) { doc in
            // Each list of siblings is arranged on its own.
            func reorder(_ list: inout [Node]) {
                let chosen = Set(ids)
                guard list.contains(where: { chosen.contains($0.id) }) else { return }
                switch how {
                case .front:
                    let moving = list.filter { chosen.contains($0.id) }
                    list.removeAll { chosen.contains($0.id) }
                    list += moving
                case .back:
                    let moving = list.filter { chosen.contains($0.id) }
                    list.removeAll { chosen.contains($0.id) }
                    list = moving + list
                case .forward:
                    for i in list.indices.reversed() where chosen.contains(list[i].id) && i + 1 < list.count && !chosen.contains(list[i + 1].id) {
                        list.swapAt(i, i + 1)
                    }
                case .backward:
                    for i in list.indices where chosen.contains(list[i].id) && i > 0 && !chosen.contains(list[i - 1].id) {
                        list.swapAt(i, i - 1)
                    }
                }
            }
            // Each list on its own, however deep.
            func everywhere(_ list: inout [Node]) {
                reorder(&list)
                for i in list.indices where !list[i].children.isEmpty { everywhere(&list[i].children) }
            }
            everywhere(&doc.nodes)
        }
    }

    /// Moves a layer in the layers list: onto an artboard (or the canvas, when nil) at `index`,
    /// counted bottom first.
    func move(_ id: UUID, to artboard: UUID?, at index: Int) {
        guard let node = doc.node(id), artboard != id else { return }
        if node.isArtboard && artboard != nil { return }
        edit("Move Layer") { doc in
            let oldPath = doc.path(of: id)
            var target = index
            // Removing it first shifts what comes after it in the same list.
            if let oldPath {
                let sameList = oldPath.parent.map { doc[$0].id } == artboard
                if sameList && oldPath.indices.last! < target { target -= 1 }
            }
            guard let detached = doc.detach(id) else { return }
            doc.attach(detached, to: artboard, at: target)
        }
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

    /// The layers among `ids` that would go into a group: all but those inside another of them.
    /// Nil when there are none, or one is an artboard or lies in a repeat grid, or they lie on
    /// more than one artboard, or some on one and some on the canvas.
    static func groupable(_ ids: [UUID], in doc: BezzleDocument) -> [UUID]? {
        let chosen = Set(ids)
        let ids = ids.filter { id in doc.node(id) != nil && !doc.ancestors(of: id).contains { chosen.contains($0.id) } }
        guard !ids.isEmpty, Set(ids.map { doc.artboard(of: $0)?.id }).count == 1,
              ids.allSatisfy({ id in doc.node(id)?.isArtboard == false && !doc.ancestors(of: id).contains(where: \.isRepeatGrid) }) else { return nil }
        return ids
    }

    /// Puts layers into a new group, in the artboard or group that holds them all, where the
    /// frontmost of them was, and returns its id. Each stays where it is on the canvas, and in
    /// the same order back to front.
    @discardableResult
    static func group(_ ids: [UUID], in doc: inout BezzleDocument, name: String? = nil) -> UUID? {
        guard let ids = groupable(ids, in: doc) else { return nil }
        // Back to front, as they are drawn.
        let paths = ids.compactMap { id in doc.path(of: id).map { (id: id, at: $0.indices) } }
            .sorted { $0.at.lexicographicallyPrecedes($1.at) }
        guard let front = paths.last else { return nil }
        // Where the deepest artboard or group that holds them all is.
        var shared = Array(front.at.dropLast())
        for p in paths {
            let parent = p.at.dropLast()
            shared = Array(zip(shared, parent).prefix { $0 == $1 }.map(\.0))
        }
        let holder = shared.isEmpty ? nil : doc.ancestors(of: front.id)[shared.count - 1].id
        // Just above what holds the frontmost there, once those lying there themselves are out.
        let place = front.at[shared.count]
        let leaving = paths.filter { $0.at.count == shared.count + 1 && $0.at[shared.count] <= place }.count
        var group = Node(kind: .group, name: name ?? doc.nextName(for: .group), frame: .zero)
        // Taken out onto the canvas, and so into a group lying at the canvas's top left, they keep
        // where they are; it is fitted round them afterwards.
        group.children = paths.compactMap { doc.detach($0.id) }
        doc.attach(group, to: holder, at: place + 1 - leaving)
        return group.id
    }

    /// Takes the layers out of groups, each into its group's place, where they are, and returns them.
    @discardableResult
    static func ungroup(_ ids: [UUID], in doc: inout BezzleDocument) -> [UUID] {
        var freed: [UUID] = []
        for id in ids {
            guard let path = doc.path(of: id), let group = doc.node(id), group.isGroup else { continue }
            // A group is never turned, so its layers only move by where it is.
            let layers = group.children.map { child -> Node in
                var c = child
                c.frame = c.frame.offsetBy(dx: group.frame.minX, dy: group.frame.minY)
                return c
            }
            let i = path.indices.last!
            if let parent = path.parent {
                var holder = doc[parent]
                holder.children.replaceSubrange(i...i, with: layers)
                doc[parent] = holder
            } else {
                doc.nodes.replaceSubrange(i...i, with: layers)
            }
            freed += layers.map(\.id)
        }
        // A group taken apart after the one it was in.
        return freed.filter { doc.node($0) != nil }
    }

    // MARK: Aligning

    enum Align { case left, centerX, right, top, centerY, bottom }

    /// Lines the selection up. A single layer lines up with its artboard.
    func align(_ how: Align) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        let frames = ids.compactMap { id in doc.node(id).map { (id, Geometry.bounds(of: $0).offsetBy(dx: doc.parentOrigin(of: id).x, dy: doc.parentOrigin(of: id).y)) } }
        let reference: CGRect
        if ids.count == 1 {
            guard let board = doc.artboard(of: ids[0]) else { return }
            reference = board.frame
        } else {
            reference = frames.map(\.1).reduce(frames[0].1) { $0.union($1) }
        }
        edit("Align") { doc in
            for (id, r) in frames {
                var dx: CGFloat = 0, dy: CGFloat = 0
                switch how {
                case .left: dx = reference.minX - r.minX
                case .centerX: dx = reference.midX - r.midX
                case .right: dx = reference.maxX - r.maxX
                case .top: dy = reference.minY - r.minY
                case .centerY: dy = reference.midY - r.midY
                case .bottom: dy = reference.maxY - r.maxY
                }
                doc.update(id) { $0.frame = $0.frame.offsetBy(dx: dx.rounded(), dy: dy.rounded()) }
            }
        }
    }

    /// Spaces three or more layers evenly between the outermost two.
    func distribute(horizontally: Bool) {
        let ids = selection.filter { doc.node($0)?.locked == false }
        guard ids.count >= 3 else { return }
        var items = ids.compactMap { id in doc.node(id).map { (id, Geometry.bounds(of: $0).offsetBy(dx: doc.parentOrigin(of: id).x, dy: doc.parentOrigin(of: id).y)) } }
        items.sort { horizontally ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let total = items.reduce(CGFloat(0)) { $0 + (horizontally ? $1.1.width : $1.1.height) }
        let start = horizontally ? items.first!.1.minX : items.first!.1.minY
        let end = horizontally ? items.map(\.1.maxX).max()! : items.map(\.1.maxY).max()!
        let gap = (end - start - total) / CGFloat(items.count - 1)
        edit("Distribute") { doc in
            var cursor = start
            for (id, r) in items {
                let delta = cursor - (horizontally ? r.minX : r.minY)
                doc.update(id) { $0.frame = $0.frame.offsetBy(dx: horizontally ? delta : 0, dy: horizontally ? 0 : delta) }
                cursor += (horizontally ? r.width : r.height) + gap
            }
        }
    }

    // MARK: Flipping

    /// Mirrors the selection left to right, or top to bottom, where it is: a single layer about
    /// its own middle, several about the middle of the box around them all. Artboards stay as they are.
    func flip(horizontally: Bool) {
        let ids = selection.filter { doc.node($0).map { !$0.locked && !$0.isArtboard } == true }
        guard !ids.isEmpty else { return }
        let box = ids.compactMap { id in doc.node(id).map { Geometry.bounds(of: $0).offsetBy(dx: doc.parentOrigin(of: id).x, dy: doc.parentOrigin(of: id).y) } }
            .reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        guard let box else { return }
        edit(horizontally ? "Flip Horizontally" : "Flip Vertically") { doc in
            for id in ids {
                // The line in the layer's parent's own coordinates.
                let o = doc.parentOrigin(of: id)
                let axis = horizontally ? box.midX - o.x : box.midY - o.y
                doc.update(id) { $0 = BezzleDocument.flipped($0, horizontally: horizontally, about: axis) }
            }
        }
    }

    /// Whether flipping the selection would change it. Words read forwards whichever way they
    /// are flipped, so a text layer on its own stays as it is.
    var canFlip: Bool {
        let nodes = selectedNodes.filter { !$0.locked && !$0.isArtboard }
        return nodes.count > 1 || nodes.contains { $0.kind != .text }
    }

    // MARK: Copy and paste

    static let pasteboardType = NSPasteboard.PasteboardType("com.erik.bezzle.layers")

    private struct Clip: Codable {
        /// Layers with their frames on the canvas.
        var nodes: [Node]
        /// The components any of them are copies of, to come along into another design.
        var components: [Node]?
        /// The styles any of them are named after, likewise. See `Style`.
        var styles: [Style]?
        /// The design they were copied from, which the components and styles new to another design
        /// remember (`LibraryLink`).
        var from: String?
    }

    func copySelection() {
        let nodes = selection.compactMap { id -> Node? in
            guard var n = doc.node(id) else { return nil }
            n.frame = doc.absoluteFrame(of: id) ?? n.frame
            return n
        }
        var used = Set(nodes.flatMap(\.componentsUsed))
        for id in used { used.formUnion(doc.uses(id)) }
        let masters = doc.masters.filter { used.contains($0.id) }
        let named = (nodes + masters).reduce(into: Set<UUID>()) { $0.formUnion($1.stylesUsed) }
        let styles = (doc.styles ?? []).filter { named.contains($0.id) }
        guard !nodes.isEmpty, let data = try? JSONEncoder().encode(Clip(nodes: nodes, components: masters.isEmpty ? nil : masters,
                                                                         styles: styles.isEmpty ? nil : styles, from: name)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        // Text layers also go out as plain text, for pasting elsewhere.
        let words = nodes.compactMap(\.text).filter { !$0.isEmpty }
        if !words.isEmpty { pb.setString(words.joined(separator: "\n"), forType: .string) }
    }

    func cutSelection() {
        copySelection()
        let ids = selection
        edit("Cut") { doc in for id in ids { _ = doc.detach(id) } }
        selection = []
    }

    /// Pastes layers from Bezzle where they were copied from when that is in view, else in the
    /// middle of the view; plain text becomes a text layer.
    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(Clip.self, from: data) {
            var nodes = clip.nodes.map { $0.freshCopy() }
            let visible = visibleCanvasRect
            let bounds = nodes.map(\.frame).reduce(nodes[0].frame) { $0.union($1) }
            var shift = CGPoint.zero
            if !visible.intersects(bounds) {
                shift = CGPoint(x: (visible.midX - bounds.midX).rounded(), y: (visible.midY - bounds.midY).rounded())
            }
            // Pasting over the originals offsets the copies, so they can be seen.
            if nodes.contains(where: { n in doc.allNodes.contains { $0.name == n.name && doc.absoluteFrame(of: $0.id) == n.frame } }) {
                shift = shift + CGPoint(x: 10, y: 10)
            }
            for i in nodes.indices { nodes[i].frame = nodes[i].frame.offsetBy(dx: shift.x, dy: shift.y) }
            let target = focusedArtboard?.id
            // From another design, what is new here remembers where it came from.
            let take = LibraryTake(name: clip.from == name ? nil : clip.from, masters: clip.components ?? [], styles: clip.styles ?? [])
            edit("Paste") { doc in
                // Styles and components new to this design come with the layers that use them.
                let renamed = doc.bring(take)
                if !renamed.isEmpty { nodes = nodes.map { $0.renamingStyles(renamed) } }
                for n in nodes {
                    let onto = n.isArtboard ? nil : (doc.artboard(at: n.frame.center)?.id ?? target.flatMap { id in doc.node(id)?.frame.intersects(n.frame) == true ? id : nil })
                    doc.attach(n, to: onto)
                }
            }
            selection = nodes.map(\.id)
        } else if let string = pb.string(forType: .string), !string.isEmpty {
            let board = focusedArtboard
            let center = board?.frame.center ?? visibleCanvasRect.center
            var node = Node(kind: .text, name: String(string.prefix(40)), frame: CGRect(origin: center, size: .zero))
            node.text = string
            node.style?.sizing = string.count > 60 ? .autoHeight : .autoWidth
            if node.style?.sizing == .autoHeight { node.frame.size.width = min(board?.frame.width ?? 400, 400) * 0.8 }
            node.refit()
            node.frame.origin = CGPoint(x: (center.x - node.frame.width / 2).rounded(), y: (center.y - node.frame.height / 2).rounded())
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

extension Node {
    /// The same layer, and what lies on it, with new identities.
    func freshCopy() -> Node {
        var n = self
        // A copy of a component stays one, its layers keyed from the component as every copy's are.
        if instance != nil { return Components.freshCopy(of: self) }
        n.id = UUID()
        // A grid's cells stay copies of its first, each with what it holds; so do a deck's posts.
        n.children = isRepeatGrid ? RepeatGrid.freshCells(of: self) : isDeck ? Deck.freshPosts(of: self) : children.map { $0.freshCopy() }
        return n
    }
}
