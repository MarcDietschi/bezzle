import AppKit

/// Something from the resources panel: a kit's part, or an icon in a style.
nonisolated enum Resource: Hashable, Sendable {
    case component(String)
    case icon(IconSetID, String, IconStyle)
    /// One of the design's own components, by its id: another copy of it.
    case design(UUID)

    /// As it travels on the pasteboard and to the AI: "ios.tab-bar", "icon/lucide/heart".
    var key: String {
        switch self {
        case .component(let id): id
        case .icon(let set, let name, _): "icon/\(set.rawValue)/\(name)"
        case .design(let id): "component/\(id.uuidString)"
        }
    }

    var component: Component? {
        if case .component(let id) = self { return Kits.component(id) }
        return nil
    }

    var icon: Icon? {
        if case .icon(let set, let name, _) = self { return Icons.icon(name, in: set) }
        return nil
    }
}

/// What dropping a resource would do, worked out once: the layers it makes and where they land,
/// so the canvas can show it before it is let go.
struct ResourcePlacing {
    /// What is made, its frame on the canvas.
    var node: Node
    /// The artboard it goes onto; nil for the canvas itself.
    var board: UUID?
    /// The icon it takes the place of, keeping that layer's colour and size.
    var swap: UUID?
    /// How it fits the artboard: along an edge, or across it; `.free` where it is let go.
    var fit: Component.Fit = .free
    /// A kit's part, as it was made, light or dark: dropped again, it is another copy of the
    /// component the first one became. See `Master.part`.
    var part: String?
}

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

        switch resource {
        case .component(let id):
            guard let c = Kits.component(id) else { return nil }
            var fit = Component.Fit.free
            var node: Node
            if let width, c.stretches {
                node = c.node(width: width, dark: dark)
            } else if let b = usable, c.stretches, b.frame.width >= (c.minWidth ?? 1), b.frame.width <= c.size.width * 2.2 {
                fit = c.fit
                let r = b.frame
                switch c.fit {
                case .top, .bottom:
                    node = c.node(width: r.width, dark: dark)
                    let y = c.fit == .top ? r.minY + edgeStack(of: b, top: true) : r.maxY - edgeStack(of: b, top: false) - node.frame.height
                    node.frame.origin = CGPoint(x: r.minX, y: y)
                case .across(let margin) where r.width - margin * 2 >= (c.minWidth ?? 1):
                    node = c.node(width: r.width - margin * 2, dark: dark)
                    node.frame.origin = CGPoint(x: r.minX + margin, y: (center.y - node.frame.height / 2).rounded())
                default:
                    fit = .free
                    node = c.node(dark: dark)
                }
            } else {
                node = c.node(dark: dark)
            }
            if fit == .free {
                node.frame.origin = CGPoint(x: (center.x - node.frame.width / 2).rounded(), y: (center.y - node.frame.height / 2).rounded())
            }
            let part = dark ? "\(id)/dark" : id
            // Dropped before, it is another copy of the component it became, as the design has it now.
            if let master = doc.masters.first(where: { $0.master?.part == part }) {
                node = Components.newCopy(of: master, at: node.frame.origin, size: node.frame.size)
            }
            return ResourcePlacing(node: node, board: usable?.id, fit: fit, part: part)

        case .design(let id):
            guard let master = doc.master(id) else { return nil }
            let size = Components.box(of: master, variant: nil).size
            let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
            return ResourcePlacing(node: Components.newCopy(of: master, at: origin), board: usable?.id)

        case .icon(_, _, let style):
            guard let icon = resource.icon else { return nil }
            if let target, let old = doc.node(target), Icons.isIcon(old), !old.locked,
               let frame = doc.absoluteFrame(of: target) {
                var swapped = Icons.swapped(old, for: icon, style: style)
                swapped.frame = swapped.frame.offsetBy(dx: frame.minX - old.frame.minX, dy: frame.minY - old.frame.minY)
                return ResourcePlacing(node: swapped, board: doc.artboard(of: target)?.id, swap: target)
            }
            let size: CGFloat = 24
            let frame = CGRect(x: (center.x - size / 2).rounded(), y: (center.y - size / 2).rounded(), width: size, height: size)
            let node = Icons.node(icon, style: style, frame: frame, color: dark ? RGBA(r: 0.93, g: 0.92, b: 0.89) : RGBA(r: 0.11, g: 0.106, b: 0.098))
            return ResourcePlacing(node: node, board: usable?.id)
        }
    }

    /// How far in from an artboard's top (or bottom) edge the layers lying along it, one under
    /// another and each as wide as the artboard, reach: where the next bar goes.
    func edgeStack(of board: Node, top: Bool) -> CGFloat {
        let w = board.frame.width, h = board.frame.height
        let spanning = board.children.filter { !$0.hidden && abs($0.frame.minX) < 0.5 && abs($0.frame.width - w) < 0.5 && $0.frame.height < h / 2 }
        var reach: CGFloat = 0
        while let next = spanning.first(where: { top ? abs($0.frame.minY - reach) < 0.5 : abs(h - $0.frame.maxY - reach) < 0.5 }) {
            reach += next.frame.height
            if reach > h / 2 { break }
        }
        return reach
    }

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
            let made = plan.node
            edit("Replace Icon") { doc in
                // The plan's frame is on the canvas; the layer's is in what holds it.
                let o = doc.parentOrigin(of: swap)
                doc.update(swap) { n in
                    let id = n.id
                    n = made
                    n.id = id
                    n.frame = made.frame.offsetBy(dx: -o.x, dy: -o.y)
                }
            }
            selection = [swap]
            return swap
        }
        let node = plan.node
        var made = node.id
        edit(resource.icon == nil ? "Add Component" : "Add Icon") { doc in
            made = Self.add(node, part: plan.part, to: plan.board, in: &doc)
        }
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
        guard let part, !node.isCopy else {
            doc.attach(node, to: board)
            return node.id
        }
        if let master = doc.masters.first(where: { $0.master?.part == part }) {
            let copy = Components.newCopy(of: master, at: node.frame.origin, size: node.frame.size)
            doc.attach(copy, to: board)
            return copy.id
        }
        doc.attach(node, to: board)
        doc.fitGroups()
        return makeComponent(from: [node.id], in: &doc, name: node.name, part: part) ?? node.id
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
