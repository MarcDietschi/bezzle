import AppKit

extension DocumentStore {
    /// Where a resource lands when let go at a canvas point over `target`, or, with no point,
    /// when picked in the panel: on the artboard being looked at, in the middle of what shows of it.
    /// A part comes light or dark as the artboard is; a bar settles along the artboard's edge,
    /// under what lies along it already, and a list across it; an icon let go onto another
    /// icon takes its place.
    /// `into`, `dark` and `width` say where, how and how wide in place of working it out, for the AI.
    func placing(_ resource: Resource, at point: CGPoint?, on target: UUID? = nil,
                 into boardID: UUID? = nil, dark: Bool? = nil, width: CGFloat? = nil) -> ResourcePlacing? {
        guard !isReadOnly else { return nil }
        let board: Node? = boardID.flatMap { doc.node($0) } ?? (point.map { p in doc.artboard(at: p) } ?? focusedArtboard)
        let usable = board.flatMap { $0.locked ? nil : $0 }
        let center: CGPoint = point ?? {
            if boardID != nil, let usable { return usable.frame.center }
            let visible = visibleCanvasRect
            guard let usable else { return visible.center }
            let shown = usable.frame.intersection(visible)
            return shown.isNull || shown.isEmpty ? usable.frame.center : shown.center
        }()
        let dark = dark ?? Kits.isDark(usable)
        return doc.placing(resource, center: center, on: usable, over: target, dark: dark, width: width,
                           library: { LibraryShelf.shared.content($0) })
    }

    /// How far in from an artboard's top (or bottom) edge the layers lying along it, one under
    /// another and each as wide as the artboard, reach: where the next bar goes.
    func edgeStack(of board: Node, top: Bool) -> CGFloat { doc.edgeStack(of: board, top: top) }

    /// Does what `placing` worked out: adds the part or icon and selects it, or puts the icon in
    /// place of the one it was let go onto. Returns the layer.
    @discardableResult
    func place(_ resource: Resource, at point: CGPoint? = nil, on target: UUID? = nil) -> UUID? {
        guard let plan = placing(resource, at: point, on: target) else { return nil }
        return place(plan, resource: resource)
    }

    @discardableResult
    func place(_ plan: ResourcePlacing, resource: Resource) -> UUID? {
        canvas?.endEditing()
        if let swap = plan.swap {
            edit("Replace Icon") { _ = $0.place(plan) }
            selection = [swap]
            return swap
        }
        var made = plan.node.id
        if let take = plan.brings { bringPictures(take) }
        edit(resource.icon == nil ? "Add Component" : "Add Icon") { made = $0.place(plan) }
        selection = [made]
        return made
    }
}

extension DocumentStore {
    /// Puts a part or icon onto an artboard, or the canvas, and returns it. A kit's part is a
    /// component: the first time it is dropped into a design it becomes one, and every time after
    /// that it is another copy of it, as the design has it then, as big as the part was made, so
    /// changing one of them changes them all.
    static func add(_ node: Node, part: String?, to board: UUID?, in doc: inout BezzleDocument) -> UUID {
        doc.add(node, part: part, to: board)
    }
}

extension DocumentStore {
    /// Brings the resources panel out in the layers list's place, or puts it away and the layers
    /// list back if it was out before.
    func toggleResources() {
        if showsResources {
            showsResources = false
            showsLayers = layersBeforeResources
        } else {
            layersBeforeResources = showsLayers
            showsResources = true
        }
    }
}
