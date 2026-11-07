import Foundation

/// Something from the resources panel: a kit's part, or an icon in a style.
nonisolated enum Resource: Hashable, Sendable {
    case component(String)
    case icon(IconSetID, String, IconStyle)
    /// One of the design's own components, by its id: another copy of it.
    case design(UUID)
    /// A component of another design, the design's file and the component's id: taken in, a copy
    /// of it. See `LibraryLink`.
    case library(URL, UUID)

    /// As it travels on the pasteboard and to the AI: "ios.tab-bar", "icon/lucide/heart".
    var key: String {
        switch self {
        case .component(let id): id
        case .icon(let set, let name, _): "icon/\(set.rawValue)/\(name)"
        case .design(let id): "component/\(id.uuidString)"
        case .library(let url, let id): "library/\(url.deletingPathExtension().lastPathComponent)/\(id.uuidString)"
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
    /// The components and styles a part from another design brings along. See `LibraryLink`.
    var brings: LibraryTake?
}

extension BezzleDocument {
    /// Where a resource lands round `center` on the canvas, on artboard `usable` (nil: the canvas),
    /// over `target`: a part comes light or dark (`dark`); a bar settles along the artboard's edge,
    /// under what lies along it already, and a list across it; an icon let go onto another icon
    /// takes its place. `width` makes a part that stretches as wide. `library` reads another
    /// design's components and styles. The Mac's store and Windows work out the rest.
    func placing(_ resource: Resource, center: CGPoint, on usable: Node?, over target: UUID?, dark: Bool, width: CGFloat?,
                 library: (URL) -> LibraryContent?) -> ResourcePlacing? {
        switch resource {
        case .component(let id):
            guard let c = Kits.component(id) else { return nil }
            var fit = Component.Fit.free
            var made: Node
            if let width, c.stretches {
                made = c.node(width: width, dark: dark)
            } else if let b = usable, c.stretches, b.frame.width >= (c.minWidth ?? 1), b.frame.width <= c.size.width * 2.2 {
                fit = c.fit
                let r = b.frame
                switch c.fit {
                case .top, .bottom:
                    made = c.node(width: r.width, dark: dark)
                    let y = c.fit == .top ? r.minY + edgeStack(of: b, top: true) : r.maxY - edgeStack(of: b, top: false) - made.frame.height
                    made.frame.origin = CGPoint(x: r.minX, y: y)
                case .across(let margin) where r.width - margin * 2 >= (c.minWidth ?? 1):
                    made = c.node(width: r.width - margin * 2, dark: dark)
                    made.frame.origin = CGPoint(x: r.minX + margin, y: (center.y - made.frame.height / 2).rounded())
                default:
                    fit = .free
                    made = c.node(dark: dark)
                }
            } else {
                made = c.node(dark: dark)
            }
            if fit == .free {
                made.frame.origin = CGPoint(x: (center.x - made.frame.width / 2).rounded(), y: (center.y - made.frame.height / 2).rounded())
            }
            let part = dark ? "\(id)/dark" : id
            // Dropped before, it is another copy of the component it became, as the design has it now.
            if let master = masters.first(where: { $0.master?.part == part }) {
                made = Components.newCopy(of: master, at: made.frame.origin, size: made.frame.size)
            }
            return ResourcePlacing(node: made, board: usable?.id, fit: fit, part: part)

        case .design(let id):
            guard let own = master(id) else { return nil }
            let size = Components.box(of: own, variant: nil).size
            let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
            return ResourcePlacing(node: Components.newCopy(of: own, at: origin), board: usable?.id)

        case .library(let url, let id):
            // Taken before, it is another copy of it as this design has it now.
            if master(id) != nil {
                return placing(.design(id), center: center, on: usable, over: target, dark: dark, width: width, library: library)
            }
            guard let content = library(url), let theirs = content.master(id) else { return nil }
            let size = Components.box(of: theirs, variant: nil).size
            let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
            return ResourcePlacing(node: Components.newCopy(of: theirs, at: origin, masters: content.mastersByID), board: usable?.id,
                                   brings: content.taking(id))

        case .icon(_, _, let style):
            guard let icon = resource.icon else { return nil }
            if let target, let old = node(target), Icons.isIcon(old), !old.locked, let frame = absoluteFrame(of: target) {
                var swapped = Icons.swapped(old, for: icon, style: style)
                swapped.frame = swapped.frame.offsetBy(dx: frame.minX - old.frame.minX, dy: frame.minY - old.frame.minY)
                return ResourcePlacing(node: swapped, board: artboard(of: target)?.id, swap: target)
            }
            let size: CGFloat = 24
            let frame = CGRect(x: (center.x - size / 2).rounded(), y: (center.y - size / 2).rounded(), width: size, height: size)
            let made = Icons.node(icon, style: style, frame: frame, color: dark ? RGBA(r: 0.93, g: 0.92, b: 0.89) : RGBA(r: 0.11, g: 0.106, b: 0.098))
            return ResourcePlacing(node: made, board: usable?.id)
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

    /// Puts what a placing made into the design: the icon in place of the one it was let go onto,
    /// or the part, icon or copy onto its artboard, with what it brings from another design.
    /// Returns the layer. (Pictures it brings are the caller's to copy into the design's package.)
    mutating func place(_ plan: ResourcePlacing) -> UUID {
        if let swap = plan.swap {
            let made = plan.node
            // The plan's frame is on the canvas; the layer's is in what holds it.
            let o = parentOrigin(of: swap)
            update(swap) { n in
                let id = n.id
                n = made
                n.id = id
                n.frame = made.frame.offsetBy(dx: -o.x, dy: -o.y)
            }
            return swap
        }
        var made = plan.node
        if let take = plan.brings { made = made.renamingStyles(bring(take)) }
        return add(made, part: plan.part, to: plan.board)
    }

    /// Puts a part or icon onto an artboard, or the canvas, and returns it. A kit's part is a
    /// component: the first time it is dropped into a design it becomes one, and every time after
    /// that it is another copy of it, as the design has it then, as big as the part was made, so
    /// changing one of them changes them all.
    mutating func add(_ node: Node, part: String?, to board: UUID?) -> UUID {
        guard let part, !node.isCopy else {
            attach(node, to: board)
            return node.id
        }
        if let master = masters.first(where: { $0.master?.part == part }) {
            let copy = Components.newCopy(of: master, at: node.frame.origin, size: node.frame.size)
            attach(copy, to: board)
            return copy.id
        }
        attach(node, to: board)
        fitGroups()
        return makeComponent(from: [node.id], name: node.name, part: part) ?? node.id
    }
}
