import Foundation
import CBezzleHost

// MARK: - Resources

extension WindowsCore {
    /// Something from the resources panel, as the app names it (the shared `Resource`).
    nonisolated public enum Thing: Hashable, Sendable {
        /// A kit's part, by its id ("ios.tab-bar").
        case part(String)
        /// An icon of a set, in a style: its index among the set's styles, and the weight of its lines.
        case icon(set: String, name: String, style: Int, weight: Double)
        /// One of the design's own components: another copy of it.
        case own(UUID)
        /// A component of another design, by its file and its id: taken in, a copy of it.
        case library(URL, UUID)

        var resource: Resource? {
            switch self {
            case .part(let id): return .component(id)
            case .icon(let set, let name, let style, let weight):
                guard let set = IconSetID(rawValue: set) else { return nil }
                return .icon(set, name, IconStyle(index: style, weight: CGFloat(weight)))
            case .own(let id): return .design(id)
            case .library(let url, let id): return .library(url, id)
            }
        }
    }

    nonisolated public struct KitLook: Sendable {
        public let id: String
        /// What it is called, as a key of the Mac's words.
        public let title: String
        public let count: Int
        public let paper: UInt32
        public let darkPaper: UInt32
    }

    nonisolated public struct PartLook: Sendable {
        public let id: String
        public let title: String
        public let kit: String
        public let kitTitle: String
        public let width: Double
        public let height: Double
        /// Wider than half the panel holds at a readable size, or a bar: a row of its own.
        public var wide: Bool { width > 190 || width / max(height, 1) > 4.5 }
    }

    nonisolated public struct IconSetLook: Sendable {
        public let id: String
        public let name: String
        public let count: Int
        /// Drawn as lines at a weight (Lucide), else filled in styles.
        public let lines: Bool
        public let styles: [String]
        public let defaultStyle: Int
        public let defaultWeight: Double
        public let box: CGRect
    }

    private static func rgb(_ c: RGBA) -> UInt32 {
        func b(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return b(Double(c.r)) << 16 | b(Double(c.g)) << 8 | b(Double(c.b))
    }

    private static func part(_ c: Component, of kit: Kit) -> PartLook {
        PartLook(id: c.id, title: c.title.key, kit: kit.id, kitTitle: kit.title.key, width: Double(c.size.width), height: Double(c.size.height))
    }

    public static func kits() -> [KitLook] {
        Kits.all.map { KitLook(id: $0.id, title: $0.title.key, count: $0.components.count, paper: rgb($0.paper), darkPaper: rgb($0.darkPaper)) }
    }

    /// A kit's parts by section, those fitting `query` alone when it says something.
    public static func kitSections(_ id: String, query: String) -> [(title: String, parts: [PartLook])] {
        guard let kit = Kits.kit(id) else { return [] }
        let found: Set<String>? = query.isEmpty ? nil : Set(Kits.search(query).filter { $0.kit.id == id }.map(\.component.id))
        return kit.sections.compactMap { s in
            let parts = s.components.filter { found?.contains($0.id) ?? true }
            return parts.isEmpty ? nil : (s.title.key, parts.map { part($0, of: kit) })
        }
    }

    /// The parts of every kit fitting `query`.
    public static func foundParts(_ query: String) -> [PartLook] {
        Kits.search(query).map { part($0.component, of: $0.kit) }
    }

    /// The icon sets, read the first time they are asked for.
    public static func iconSets() -> [IconSetLook] {
        Icons.sets.map { s in
            IconSetLook(id: s.id.rawValue, name: s.name, count: s.icons.count, lines: s.drawnAsLines, styles: s.styles,
                        defaultStyle: s.defaultStyle.index, defaultWeight: Double(s.defaultStyle.weight), box: s.box)
        }
    }

    /// The names of a set's icons, those fitting `query` alone when it says something, best first.
    public static func icons(_ set: String, query: String) -> [(name: String, words: String)] {
        guard let id = IconSetID(rawValue: set) else { return [] }
        let list = query.isEmpty ? Icons.set(id).icons : Icons.search(query, in: id)
        return list.map { ($0.name, $0.words) }
    }

    public static func hasIcon(_ set: String, _ name: String) -> Bool {
        IconSetID(rawValue: set).flatMap { Icons.icon(name, in: $0) } != nil
    }

    /// An icon's outline in one of its styles, as XAML path data in the set's own box.
    public static func iconData(_ set: String, _ name: String, style: Int) -> String {
        guard let id = IconSetID(rawValue: set), let icon = Icons.icon(name, in: id) else { return "" }
        let i = icon.paths.indices.contains(style) && !icon.paths[style].isEmpty ? style : 0
        let path = PathData.cgPath(icon.paths.indices.contains(i) ? icon.paths[i] : "")
        return xaml(path)
    }

    /// A path as XAML path data: absolute moves, lines, curves and closes.
    static func xaml(_ path: CGPath) -> String {
        var out = ""
        func n(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
        func p(_ q: CGPoint) -> String { n(q.x) + "," + n(q.y) }
        path.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: out += "M" + p(pts[0]) + " "
            case .addLineToPoint: out += "L" + p(pts[0]) + " "
            case .addQuadCurveToPoint: out += "Q" + p(pts[0]) + " " + p(pts[1]) + " "
            case .addCurveToPoint: out += "C" + p(pts[0]) + " " + p(pts[1]) + " " + p(pts[2]) + " "
            case .closeSubpath: out += "Z "
            @unknown default: break
            }
        }
        return out
    }

    /// The design's own components, with how many copies each has.
    public static func ownComponents() -> [(id: UUID, name: String, copies: Int)] {
        guard let doc = design else { return [] }
        return doc.masters.map { ($0.id, $0.name, doc.copies(of: $0.id).count) }
    }

    /// Whether the artboard at `index` is dark, so parts come dark onto it.
    public static func isDarkBoard(_ index: Int?) -> Bool {
        guard let index, let doc = design, doc.nodes.indices.contains(index) else { return false }
        return Kits.isDark(doc.nodes[index])
    }

    // MARK: Pictures

    /// How big the sheet a part of this size is drawn on is: the part with a margin round it.
    private static func margin(_ size: CGSize) -> CGFloat { max(6, min(size.width, size.height) * 0.08) }

    /// Layers drawn on a sheet of paper a little bigger than they are, at most about as many
    /// pixels as the panel shows them at, as the Mac's Thumbnails draw them. Answers the sheet's
    /// size in points.
    private static func sheet(_ nodes: [Node], paper: RGBA, scale wanted: Double,
                              into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGSize? {
        guard let box = nodes.map({ Geometry.bounds(of: $0) }).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) else { return nil }
        let pad = margin(box.size)
        let r = box.insetBy(dx: -pad, dy: -pad)
        var board = Node(kind: .artboard, name: "Thumbnail", frame: r)
        board.fill = Fill(color: paper)
        board.children = nodes.map { var n = $0; n.frame = n.frame.offsetBy(dx: -r.minX, dy: -r.minY); return n }
        let scale = min(wanted, 460 / Double(r.width), 320 / Double(r.height))
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = Renderer.image(of: board, scale: CGFloat(scale), assets: assets) else { return nil }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height),
              bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0 else { return nil }
        return r.size
    }

    /// A part drawn on its kit's paper, light or dark; answers the sheet's size in points.
    public static func partPicture(_ id: String, dark: Bool, scale: Double,
                                   into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGSize? {
        guard let c = Kits.component(id), let kit = Kits.all.first(where: { k in k.components.contains { $0.id == id } }) else { return nil }
        return sheet([c.node(dark: dark)], paper: dark ? kit.darkPaper : kit.paper, scale: scale, into: fill)
    }

    /// How big a part's sheet is, before it is drawn.
    public static func partSheet(_ id: String) -> CGSize? {
        guard let c = Kits.component(id) else { return nil }
        let pad = margin(c.size)
        return CGSize(width: c.size.width + pad * 2, height: c.size.height + pad * 2)
    }

    /// A kit's cover: a few of its small parts side by side.
    public static func kitCover(_ id: String, dark: Bool, scale: Double,
                                into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGSize? {
        guard let kit = Kits.kit(id) else { return nil }
        let small = kit.components.filter { !$0.stretches && $0.size.width <= 160 && $0.size.height <= 64 }.prefix(4)
        var nodes: [Node] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, c) in small.enumerated() {
            var n = c.node(dark: dark)
            if i == 2 { x = 0; y += rowHeight + 14; rowHeight = 0 }
            n.frame.origin = CGPoint(x: x, y: y)
            x += n.frame.width + 14
            rowHeight = max(rowHeight, n.frame.height)
            nodes.append(n)
        }
        return sheet(nodes, paper: dark ? kit.darkPaper : kit.paper, scale: scale, into: fill)
    }

    /// One of the design's components, as a new copy of it would look, fitted into `size`.
    public static func ownPicture(_ id: UUID, size: CGSize, scale: Double,
                                  into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let doc = design, let master = doc.master(id) else { return false }
        var copy = Components.newCopy(of: master, at: .zero, masters: doc.mastersByID)
        copy.rotation = 0
        var holder = BezzleDocument()
        holder.nodes = [copy]
        holder.fitGroups()
        guard var shown = holder.nodes.first else { return false }
        let box = Geometry.bounds(of: shown)
        guard box.width > 0, box.height > 0 else { return false }
        let k = min(size.width / box.width, size.height / box.height, 2)
        let w = size.width / k, h = size.height / k
        shown.frame.origin = CGPoint(x: (w - box.width) / 2 + (shown.frame.minX - box.minX), y: (h - box.height) / 2 + (shown.frame.minY - box.minY))
        return drawGlyph([shown], size: CGSize(width: w, height: h), scale: scale * Double(k), into: fill)
    }

    // MARK: Putting them in

    /// Where a thing would land, as the canvas shows it while it is carried there.
    nonisolated public struct PlanLook: Sendable {
        /// What is made, its frame on the canvas.
        public let frame: CGRect
        /// The artboard it goes onto, and its frame; nil for the canvas.
        public let board: UUID?
        public let boardFrame: CGRect?
        /// Along an edge or across the artboard, rather than where it is let go.
        public let fitted: Bool
        /// The icon it takes the place of, and its frame.
        public let swap: UUID?
        public let swapFrame: CGRect?
        /// What letting go does, in words.
        public let label: String
    }

    /// Where a thing lands when let go at a canvas point over `target`, or, with no point, when
    /// picked in the panel: on artboard `focused`, in the middle of what shows of it (`visible`).
    static func placing(_ thing: Thing, at point: CGPoint?, over target: UUID?, focused: Int?, visible: CGRect) -> ResourcePlacing? {
        guard let doc = design, let resource = thing.resource else { return nil }
        let board: Node? = point.map { doc.artboard(at: $0) } ?? focused.flatMap { doc.nodes.indices.contains($0) && doc.nodes[$0].isArtboard ? doc.nodes[$0] : nil }
        let usable = board.flatMap { $0.locked ? nil : $0 }
        let center: CGPoint = point ?? {
            guard let usable else { return CGPoint(x: visible.midX, y: visible.midY) }
            let shown = usable.frame.intersection(visible)
            let r = shown.isNull || shown.isEmpty ? usable.frame : shown
            return CGPoint(x: r.midX, y: r.midY)
        }()
        return doc.placing(resource, center: center, on: usable, over: target, dark: Kits.isDark(usable), width: nil, library: { library($0) })
    }

    public static func plan(_ thing: Thing, at point: CGPoint?, over target: UUID?, focused: Int?, visible: CGRect) -> PlanLook? {
        guard let doc = design, let plan = placing(thing, at: point, over: target, focused: focused, visible: visible) else { return nil }
        let board = plan.board.flatMap { doc.node($0) }
        let label: String
        if let swap = plan.swap, let old = doc.node(swap) {
            label = say("Replace %@", old.name)
        } else {
            switch (plan.fit, board?.name) {
            case (.top, let name?): label = say("Along the top of %@", name)
            case (.bottom, let name?): label = say("Along the bottom of %@", name)
            case (.across, let name?): label = say("Across %@", name)
            case (_, let name?): label = say("Add to %@", name)
            default: label = say("Add to the canvas")
            }
        }
        return PlanLook(frame: plan.node.frame, board: plan.board, boardFrame: board?.frame, fitted: plan.fit != .free,
                        swap: plan.swap, swapFrame: plan.swap.flatMap { doc.absoluteFrame(of: $0) }, label: label)
    }

    /// What a thing would make, drawn at `scale` pixels a point, for carrying it over the canvas.
    public static func planPicture(_ thing: Thing, at point: CGPoint?, over target: UUID?, focused: Int?, visible: CGRect, scale: Double,
                                   into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let plan = placing(thing, at: point, over: target, focused: focused, visible: visible) else { return false }
        var node = plan.node
        let r = node.frame
        guard r.width > 0, r.height > 0 else { return false }
        node.frame.origin = .zero
        return drawGlyph([node], size: r.size, scale: scale, into: fill)
    }

    /// Puts a thing in where `plan` says, as one step, and returns the layer to select.
    @discardableResult
    public static func place(_ thing: Thing, at point: CGPoint?, over target: UUID?, focused: Int?, visible: CGRect) -> UUID? {
        guard let plan = placing(thing, at: point, over: target, focused: focused, visible: visible) else { return nil }
        // Pictures a component of another design shows come into this one's package first.
        if let take = plan.brings { bringPictures(take) }
        var made: UUID?
        edit { made = $0.place(plan) }
        return made
    }

    /// Whether a layer is an icon, which an icon let go onto takes the place of.
    public static func isIcon(_ id: UUID) -> Bool { design?.node(id).map(Icons.isIcon) ?? false }

    /// Takes a component out of the design: its copies become groups like any.
    public static func deleteComponent(_ id: UUID) {
        guard design?.master(id) != nil else { return }
        edit { doc in doc.masters.removeAll { $0.id == id } }
    }
}
