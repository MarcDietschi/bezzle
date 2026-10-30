import AppKit
import ImageIO

/// The tools that read and change layers.
extension MCPTools {
    /// Makes `body`'s change to a copy of the design, then puts it in as one step of the undo
    /// history, as a change made by hand is. When `body` throws, nothing changes. Returns whether
    /// anything did.
    @discardableResult
    private func change(_ store: DocumentStore, _ action: String, _ body: (inout BezzleDocument) throws -> Void) throws -> Bool {
        store.canvas?.endEditing()
        var working = store.doc
        try body(&working)
        // As `edit` will see it: what changes nothing must not leave an empty step to undo.
        var fitted = working
        fitted.fitGroups(since: store.doc)
        fitted.fitCarousels()
        guard fitted != store.doc else { return false }
        // A change made by hand is one step of the undo history because the click or key press
        // that made it ends; these come from no event, so each is given a step of its own.
        guard let undo = store.undoManager else {
            store.edit(action) { $0 = working }
            return true
        }
        let byEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        store.edit(action) { $0 = working }
        undo.endUndoGrouping()
        undo.groupsByEvent = byEvent
        return true
    }

    /// Does to a copy of the design what the menus do to a selection, then makes the same change
    /// to the design, selecting what it leaves selected. Returns whether anything changed.
    private func onSelection(_ store: DocumentStore, _ ids: [UUID], _ action: String, _ body: (DocumentStore) -> Void) throws -> Bool {
        // It has no window and no undo history, and saves nothing: it is gone before it would.
        let copy = DocumentStore(url: store.url, document: store.doc)
        copy.selection = ids
        body(copy)
        let changed = try change(store, action) { $0 = copy.doc }
        store.selection = copy.selection.filter { store.doc.node($0) != nil }
        return changed
    }

    private func described(_ ids: [UUID], in store: DocumentStore, full: Bool = false, depth: Int = 0, warnings: [String] = []) -> [Content] {
        let layers = ids.compactMap { store.doc.node($0) }.map { Self.describe($0, in: store.doc, full: full, depth: depth) }
        return [.text(JSONValue.compact([("layers", .array(layers)), ("warnings", .array(warnings.map { .string($0) }))]).text)]
    }

    // MARK: Reading

    func findLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc
        var scope = doc.allNodes
        if let ref = try args.string("within") {
            let id = try Self.layer(ref, in: doc)
            func flatten(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + flatten($0.children) } }
            scope = flatten(doc.node(id)?.children ?? [])
        }
        let name = try args.string("name")?.lowercased(), text = try args.string("text")?.lowercased()
        var kind: Node.Kind?
        if let k = try args.string("kind") {
            guard let found = Node.Kind(rawValue: k.lowercased()) else { throw MCPError("kind is one of artboard, rectangle, ellipse, line, text, path, group.") }
            kind = found
        }
        let found = scope.filter { n in
            (name == nil || n.name.lowercased().contains(name!)) && (kind == nil || n.kind == kind)
                && (text == nil || n.text?.lowercased().contains(text!) == true)
        }
        let listed: [JSONValue] = found.prefix(200).map { n in
            guard case .object(var pairs) = Self.describe(n, in: doc, full: false, depth: 0) else { return .null }
            pairs.insert(("on", .string(doc.parent(of: n.id)?.name ?? "the canvas")), at: 3)
            return .object(pairs)
        }
        return [.text(JSONValue.compact([
            ("found", .number(found.count)), ("layers", .array(listed)),
            ("note", found.count > listed.count ? .string("Only the first \(listed.count) are listed.") : nil),
        ]).text)]
    }

    func getLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        return described(ids, in: store, full: true, depth: try args.bool("children") == true ? .max : 0)
    }

    // MARK: Adding

    func addLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let specs = try args.objects("layers"), !specs.isEmpty else { throw MCPError("Give the layers to add, each with a kind.") }
        let doc = store.doc
        var parent: UUID?
        if let ref = try args.string("parent") {
            if ref.lowercased() != "canvas" {
                let id = try Self.layer(ref, in: doc)
                guard doc.node(id)?.isContainer == true else { throw MCPError("Layers go on an artboard, into a group, or on the canvas: \(doc.node(id)?.name ?? ref) is none of these.") }
                parent = id
            }
        } else {
            parent = store.focusedArtboard?.id ?? (doc.artboards.count == 1 ? doc.artboards[0].id : nil)
        }
        let index = try args.int("index")
        var warnings: [String] = []
        var names = Set(doc.allNodes.map(\.name))
        var nextBoard = Self.nextArtboardOrigin(in: doc)
        let parentSize = parent.flatMap { doc.node($0)?.frame.size }
        let defaultBoard = store.lastPreset ?? Preset.all[0].size
        var made: [Node] = []
        for spec in specs {
            made.append(try Self.make(spec, parentSize: parentSize, boardSize: defaultBoard, names: &names, warnings: &warnings, nextBoard: &nextBoard))
        }

        try change(store, made.count == 1 ? "Add \(made[0].kind.title)" : "Add Layers") { doc in
            let path = parent.flatMap { doc.path(of: $0) }
            var placed = 0
            for node in made {
                if node.isArtboard {
                    doc.nodes.append(node)
                } else if let path {
                    let count = doc[path].children.count
                    doc.insert(node, at: NodePath(indices: path.indices + [min(index.map { $0 + placed } ?? count, count)]))
                    placed += 1
                } else {
                    doc.insert(node, at: NodePath(indices: [min(index.map { $0 + placed } ?? doc.nodes.count, doc.nodes.count)]))
                    placed += 1
                }
            }
        }
        store.selection = made.map(\.id)
        if made.contains(where: \.isArtboard), !made.filter(\.isArtboard).allSatisfy({ store.visibleCanvasRect.contains($0.frame) }) { store.zoomToFit() }

        let into: JSONValue = made.allSatisfy(\.isArtboard) ? nil : parent.flatMap { id in store.doc.node(id).map { .object([("id", .string(id.uuidString)), ("name", .string($0.name))]) } } ?? "canvas"
        let layers = made.compactMap { store.doc.node($0.id) }.map { Self.describe($0, in: store.doc, full: false) }
        return [.text(JSONValue.compact([("addedTo", into), ("layers", .array(layers)), ("warnings", .array(warnings.map { .string($0) }))]).text)]
    }

    private static let kindWords: [String: Node.Kind] = [
        "rect": .rectangle, "square": .rectangle, "circle": .ellipse, "oval": .ellipse, "frame": .artboard, "board": .artboard, "vector": .path,
    ]

    /// A new layer as `spec` describes it, and what it holds. Placed in the middle of its parent
    /// unless it says where.
    private static func make(_ spec: [String: Any], parentSize: CGSize?, boardSize: CGSize, names: inout Set<String>,
                             warnings: inout [String], nextBoard: inout CGPoint) throws -> Node {
        guard let word = try Read.string(spec["kind"], "kind")?.lowercased() else {
            throw MCPError("Each layer needs a kind: artboard, carousel, rectangle, ellipse, line, text, path or group.")
        }
        let carousel = word == "carousel"
        guard let kind = carousel ? .artboard : Node.Kind(rawValue: word) ?? kindWords[word] else {
            throw MCPError("There is no kind of layer \"\(word)\". There are: artboard, carousel, rectangle, ellipse, line, text, path and group.")
        }
        var node = Node(kind: kind, frame: .zero)
        switch kind {
        case .artboard: node.frame = CGRect(origin: nextBoard, size: boardSize)
        case .rectangle, .ellipse: node.frame.size = CGSize(width: 100, height: 100)
        case .line: node.frame.size = CGSize(width: 100, height: 0)
        default: break
        }
        var props = spec
        props["kind"] = nil
        let children = props.removeValue(forKey: "children")
        if carousel && props["carousel"] == nil { props["carousel"] = Carousel.formats[0].name }
        try apply(props, to: &node, warnings: &warnings)

        if kind == .path && node.path == nil { throw MCPError("A path needs its outline in path, as SVG path data.") }
        if kind == .text && (node.text ?? "").isEmpty { throw MCPError("A text layer needs text.") }
        let placed = ["x", "x1", "x2", "path"].contains { spec[$0] != nil }, placedDown = ["y", "y1", "y2", "path"].contains { spec[$0] != nil }
        if let parentSize, ![.artboard, .group, .path].contains(kind) {
            if !placed { node.frame.origin.x = ((parentSize.width - node.frame.width) / 2).rounded() }
            if !placedDown { node.frame.origin.y = ((parentSize.height - node.frame.height) / 2).rounded() }
        }
        if kind == .artboard { nextBoard.x = node.frame.maxX + 80 }
        if spec["name"] == nil {
            node.name = kind == .text ? String((node.text ?? "").prefix(40)) : carousel ? nextName("Carousel", artboard: true, taken: names) : nextName(kind.title, artboard: kind == .artboard, taken: names)
        }
        names.insert(node.name)

        if let children {
            guard node.isContainer else { throw MCPError("Only artboards and groups hold layers: \(node.name) is a \(kind.rawValue).") }
            guard let list = children as? [[String: Any]] else { throw MCPError("children should be a list of layers.") }
            // A new group's layers are placed as its siblings are, and it fits itself round them.
            let inner = kind == .artboard ? node.frame.size : parentSize
            node.children = try list.map { try make($0, parentSize: inner, boardSize: boardSize, names: &names, warnings: &warnings, nextBoard: &nextBoard) }
        }
        if kind == .group {
            guard !node.children.isEmpty else { throw MCPError("A group needs children: the layers in it.") }
            node.frame = .zero
        }
        return node
    }

    /// Unique names, as the app gives them: "Rectangle 3".
    private static func nextName(_ base: String, artboard: Bool, taken: Set<String>) -> String {
        if artboard && !taken.contains(base) { return base }
        var i = artboard ? 2 : 1
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Where a new artboard goes: to the right of the others, along their top.
    private static func nextArtboardOrigin(in doc: BezzleDocument) -> CGPoint {
        let right = doc.artboards.map(\.frame.maxX).max()
        let top = doc.artboards.map(\.frame.minY).min() ?? 0
        return right.map { CGPoint(x: $0 + 80, y: top) } ?? .zero
    }

    func placeImage(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let path = try args.string("file") else { throw MCPError("Give the picture's file.") }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MCPError("There is no file at \(file.path).") }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw MCPError("\(file.lastPathComponent) is not a picture Bezzle can read.") }
        guard DesignFile.isPackage(store.url) else {
            throw MCPError("\(store.name) was saved before designs could hold pictures. Make a new design (or duplicate this one's layers into one) to place pictures.")
        }
        var mode = ImageFill.Mode.cover
        if let m = try args.string("mode") {
            guard let found = ImageFill.Mode(rawValue: m.lowercased()) else { throw MCPError("mode is cover, fit or stretch.") }
            mode = found
        }
        let doc = store.doc
        var target: UUID?
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: doc)
            guard let n = doc.node(id), [.rectangle, .ellipse, .path].contains(n.kind) else { throw MCPError("Pictures fill rectangles, ellipses and paths.") }
            target = id
        }

        // Into the design's own images, so it goes wherever the design does.
        let images = store.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let asset = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: images.appendingPathComponent(asset))
        } catch {
            throw MCPError("The picture could not be copied into the design: \(error.localizedDescription)")
        }
        let image = ImageFill(asset: asset, mode: mode, size: CGSize(width: w, height: h))

        if let target {
            try change(store, "Add Picture") { doc in
                doc.update(target) { n in
                    n.fill.on = true
                    n.fill.image = image
                }
            }
            store.selection = [target]
            return described([target], in: store, full: true)
        }

        var parent: UUID?
        if let ref = try args.string("parent") {
            if ref.lowercased() != "canvas" {
                let id = try Self.layer(ref, in: doc)
                guard doc.node(id)?.isContainer == true else { throw MCPError("Pictures go on an artboard, into a group, or on the canvas.") }
                parent = id
            }
        } else {
            parent = store.focusedArtboard?.id ?? (doc.artboards.count == 1 ? doc.artboards[0].id : nil)
        }
        let room = parent.flatMap { doc.node($0)?.frame.size }
        // Its own size, in points, unless it is bigger than where it goes; given one side, the
        // other keeps its proportions.
        let aspect = CGFloat(h) / CGFloat(w)
        var size = CGSize(width: w, height: h)
        if let room, size.width > room.width * 0.8 {
            let fitted = (room.width * 0.8).rounded()
            size = CGSize(width: fitted, height: (fitted * aspect).rounded())
        }
        let width = try args.number("width").map { CGFloat($0) }, height = try args.number("height").map { CGFloat($0) }
        switch (width, height) {
        case let (width?, height?): size = CGSize(width: width, height: height)
        case let (width?, nil): size = CGSize(width: width, height: (width * aspect).rounded())
        case let (nil, height?): size = CGSize(width: (height / aspect).rounded(), height: height)
        default: break
        }
        let x = try args.number("x").map { CGFloat($0) } ?? room.map { (($0.width - size.width) / 2).rounded() } ?? 0
        let y = try args.number("y").map { CGFloat($0) } ?? room.map { (($0.height - size.height) / 2).rounded() } ?? 0
        var node = Node(kind: .rectangle, name: try args.string("name") ?? file.deletingPathExtension().lastPathComponent, frame: CGRect(x: x, y: y, width: size.width, height: size.height))
        node.fill = Fill(color: .shape, image: image)
        try change(store, "Add Picture") { doc in
            if let parent, let path = doc.path(of: parent) {
                doc.insert(node, at: NodePath(indices: path.indices + [doc[path].children.count]))
            } else {
                doc.nodes.append(node)
            }
        }
        store.selection = [node.id]
        return described([node.id], in: store, full: true)
    }

    // MARK: Changing

    func updateLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let updates = try args.objects("updates"), !updates.isEmpty else { throw MCPError("Give updates: a list of {layer, and what to change}.") }
        var warnings: [String] = []
        var ids: [UUID] = []
        let selection = store.selection.map(\.uuidString)
        let changed = try change(store, "Change") { doc in
            for (i, update) in updates.enumerated() {
                let item = Arguments(update)
                let refs = try item.strings("layers") ?? item.string("layer").map { [$0] } ?? selection
                guard !refs.isEmpty else { throw MCPError("updates[\(i)] names no layer, and nothing is selected.") }
                for ref in refs {
                    let id = try Self.layer(ref, in: doc)
                    guard var node = doc.node(id) else { continue }
                    try Self.apply(update, to: &node, warnings: &warnings, ignoring: ["layer", "layers"])
                    doc.update(id) { $0 = node }
                    if !ids.contains(id) { ids.append(id) }
                }
            }
        }
        if !changed { warnings.append("Nothing changed: the layers were like that already.") }
        return described(ids, in: store, full: true, warnings: warnings)
    }

    func deleteLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let names = ids.compactMap { store.doc.node($0)?.name }
        try change(store, ids.count == 1 ? "Delete \(store.doc.node(ids[0])?.kind.title ?? "Layer")" : "Delete Layers") { doc in
            for id in ids { _ = doc.detach(id) }
        }
        store.selection = store.selection.filter { store.doc.node($0) != nil }
        store.hovered = nil
        return [.text(JSONValue.object([("deleted", .array(names.map { .string($0) }))]).text)]
    }

    func duplicateLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let offset = CGPoint(x: try args.number("dx") ?? 10, y: try args.number("dy") ?? 10)
        var copies: [UUID] = []
        try change(store, ids.count == 1 ? "Duplicate" : "Duplicate Layers") { doc in
            copies = DocumentStore.duplicate(ids, in: &doc, offset: offset)
        }
        store.selection = copies
        return described(copies, in: store)
    }

    func moveLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let index = try args.int("index")
        let parentRef = try args.string("parent")
        guard parentRef != nil || index != nil else { throw MCPError("Say where to: a parent, an index among its layers, or both.") }
        var target: UUID?
        if let parentRef, parentRef.lowercased() != "canvas" {
            target = try Self.layer(parentRef, in: store.doc)
            guard store.doc.node(target!)?.isContainer == true else { throw MCPError("Layers go on an artboard, into a group, or on the canvas.") }
        }
        try change(store, "Move Layer") { doc in
            for (k, id) in ids.enumerated() {
                guard let node = doc.node(id) else { continue }
                let destination = parentRef != nil ? target : doc.parent(of: id)?.id
                if node.isArtboard && destination != nil { throw MCPError("Artboards stay on the canvas.") }
                if let destination, destination == id || doc.ancestors(of: destination).contains(where: { $0.id == id }) {
                    throw MCPError("\(node.name) cannot go inside itself.")
                }
                var at = index.map { $0 + k }
                // Taking it out first moves what lay above it in the same list down one.
                if let a = at, let old = doc.path(of: id), old.parent.map({ doc[$0].id }) == destination, old.indices.last! < a { at = a - 1 }
                guard let taken = doc.detach(id) else { continue }
                doc.attach(taken, to: destination, at: at)
            }
        }
        return described(ids, in: store)
    }

    func groupLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        guard !ids.contains(where: { doc.node($0)?.isArtboard == true }) else { throw MCPError("Artboards cannot be grouped.") }
        let parents = Set(ids.map { doc.parent(of: $0)?.id })
        guard parents.count == 1, let parent = parents.first else { throw MCPError("Group layers that lie in the same artboard or group. move_layers brings them together.") }
        let name = try args.string("name")
        var group = Node(kind: .group, name: name ?? doc.nextName(for: .group), frame: .zero)
        try change(store, "Group") { doc in
            let path = parent.flatMap { doc.path(of: $0) }
            var siblings = path.map { doc[$0].children } ?? doc.nodes
            let chosen = Set(ids)
            guard let top = siblings.lastIndex(where: { chosen.contains($0.id) }) else { return }
            // In the group, its layers keep where they are: it starts at its parent's top left and
            // is fitted round them.
            group.children = siblings.filter { chosen.contains($0.id) }
            siblings.removeAll { chosen.contains($0.id) }
            siblings.insert(group, at: top + 1 - group.children.count)
            if let path {
                var holder = doc[path]
                holder.children = siblings
                doc[path] = holder
            } else {
                doc.nodes = siblings
            }
        }
        store.selection = [group.id]
        return described([group.id], in: store, depth: 1)
    }

    func ungroupLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        guard ids.allSatisfy({ store.doc.node($0)?.isGroup == true }) else { throw MCPError("Only groups can be ungrouped.") }
        var freed: [UUID] = []
        var warnings: [String] = []
        try change(store, "Ungroup") { doc in
            for id in ids {
                guard let path = doc.path(of: id), let group = doc.node(id) else { continue }
                if group.mask?.isEmpty == false { warnings.append("\(group.name)'s mask went with it.") }
                if group.opacity != 1 || group.blend != nil || group.blur != nil || group.shadow.on {
                    warnings.append("\(group.name)'s opacity, blend, blur and shadow went with it.")
                }
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
        }
        store.selection = freed
        return described(freed, in: store, warnings: warnings)
    }

    // MARK: As the Object menu does

    func arrangeLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let order = try args.string("order")?.lowercased()
        let how: DocumentStore.Arrange = switch order {
        case "front": .front
        case "forward": .forward
        case "backward": .backward
        case "back": .back
        default: throw MCPError("order is front, forward, backward or back.")
        }
        let name = switch how {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
        let changed = try onSelection(store, ids, name) { $0.arrange(how) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing moved: they were there already."])
    }

    func alignLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let edge = try args.string("edge")?.lowercased()
        let how: DocumentStore.Align = switch edge {
        case "left": .left
        case "center", "centre", "centerx": .centerX
        case "right": .right
        case "top": .top
        case "middle", "centery": .centerY
        case "bottom": .bottom
        default: throw MCPError("edge is left, center, right, top, middle or bottom.")
        }
        if ids.count == 1, store.doc.artboard(of: ids[0]) == nil { throw MCPError("A layer on its own lines up with its artboard, and this one is on none.") }
        let changed = try onSelection(store, ids, "Align") { $0.align(how) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing moved: they were lined up already, or locked."])
    }

    func distributeLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        guard ids.count >= 3 else { throw MCPError("Spacing out takes three layers or more.") }
        let direction = try args.string("direction")?.lowercased()
        let across = switch direction {
        case "horizontal", "across", "horizontally": true
        case "vertical", "down", "vertically": false
        default: throw MCPError("direction is horizontal or vertical.")
        }
        let changed = try onSelection(store, ids, "Distribute") { $0.distribute(horizontally: across) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing moved: they were evenly spaced already."])
    }

    func flipLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let direction = try args.string("direction")?.lowercased()
        let across = switch direction {
        case "horizontal", "horizontally": true
        case "vertical", "vertically": false
        default: throw MCPError("direction is horizontal (left to right) or vertical (top to bottom).")
        }
        let changed = try onSelection(store, ids, across ? "Flip Horizontally" : "Flip Vertically") { $0.flip(horizontally: across) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing changed: artboards, locked layers, and text on its own do not flip."])
    }

    func combineShapes(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let operation = try args.string("operation")?.lowercased()
        let how: DocumentStore.Combine = switch operation {
        case "union": .union
        case "subtract": .subtract
        case "intersect": .intersect
        case "exclude": .exclude
        default: throw MCPError("operation is union, subtract, intersect or exclude.")
        }
        var combinable = false
        let changed = try onSelection(store, ids, how.title) { copy in
            combinable = copy.canCombine
            if combinable { copy.combine(how) }
        }
        guard combinable else { throw MCPError("Combining takes two or more rectangles, ellipses and paths, none locked.") }
        guard changed else { throw MCPError("Nothing would be left of them, so nothing changed.") }
        return described(store.selection, in: store, full: true)
    }

    func convertToPath(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        guard try onSelection(store, ids, "Convert to Path", { $0.convertToPath() }) else {
            throw MCPError("Only rectangles, ellipses and lines become paths, and none of these is one (or they are locked).")
        }
        return described(ids, in: store, full: true)
    }

    func selectLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        store.canvas?.endEditing()
        if let list = args["layers"] as? [Any], list.isEmpty {
            store.selection = []
        } else {
            store.selection = try Self.layers(args, in: store)
        }
        return described(store.selection, in: store)
    }
}
