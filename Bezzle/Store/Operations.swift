import AppKit

/// What can be done to the layers: adding and removing them, arranging, aligning, copying.
extension DocumentStore {
    // MARK: Adding and removing

    /// Adds a layer whose frame is in canvas points, onto `artboard` or the canvas, and selects it.
    func add(_ node: Node, onto artboard: UUID?, action: String? = nil) {
        edit(action ?? "Add \(node.kind.title)") { doc in
            doc.attach(node, to: node.isArtboard ? nil : artboard)
        }
        selection = [node.id]
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        edit(ids.count == 1 ? "Delete \(node(ids[0])?.kind.title ?? "Layer")" : "Delete Layers") { doc in
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
    func updateSelection(_ action: String, _ change: (inout Node) -> Void) {
        update(selection, action, change)
    }

    func update(_ ids: [UUID], _ action: String, _ change: (inout Node) -> Void) {
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
        if hidden { selection.removeAll { ids.contains($0) } }
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
            selection = parent.children.filter { !$0.hidden && !$0.locked }.map(\.id)
        } else if let board = focusedArtboard, !board.children.isEmpty, selection.isEmpty {
            selection = board.children.filter { !$0.hidden && !$0.locked }.map(\.id)
        } else {
            selection = doc.nodes.filter { !$0.hidden && !$0.locked }.map(\.id)
        }
    }

    // MARK: Arranging

    enum Arrange { case front, forward, backward, back }

    func arrange(_ how: Arrange) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let name = switch how {
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
    }

    func copySelection() {
        let nodes = selection.compactMap { id -> Node? in
            guard var n = doc.node(id) else { return nil }
            n.frame = doc.absoluteFrame(of: id) ?? n.frame
            return n
        }
        guard !nodes.isEmpty, let data = try? JSONEncoder().encode(Clip(nodes: nodes)) else { return }
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
            edit("Paste") { doc in
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
        n.id = UUID()
        n.children = children.map { $0.freshCopy() }
        return n
    }
}
