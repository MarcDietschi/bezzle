import Foundation

// From Bezzle/MCP/MCPEditing.swift, for Windows: the tools that read and change layers. A change
// is made to a copy of the design and put in as one step, as on the Mac; what the Object menu
// does goes through the core's own commands (Host/Commands.swift).

extension MCPTools {
    /// Makes `body`'s change to a copy of the design, then puts it in as one step of the undo
    /// history, as a change made by hand is. When `body` throws, nothing changes. Returns whether
    /// anything did.
    @discardableResult
    func change(_ store: DocumentStore, _ action: LocalizedStringResource, _ body: (inout BezzleDocument) throws -> Void) throws -> Bool {
        MCPHost.shared.endEditing()
        var working = store.doc
        try body(&working)
        let before = store.doc
        WindowsCore.edit { $0 = working }
        guard store.doc != before else { return false }
        MCPHost.shared.edited()
        return true
    }

    /// Does to a copy of the design what the menus do to a selection, then makes the same change
    /// to the design, selecting what it leaves selected. Returns whether anything changed.
    func onSelection(_ store: DocumentStore, _ ids: [UUID], _ action: LocalizedStringResource, _ body: (DesignCopy) -> Void) throws -> Bool {
        let copy = DesignCopy(store.doc, selection: ids, fronts: store.fronts)
        body(copy)
        let changed = try change(store, action) { $0 = copy.doc }
        store.fronts = copy.fronts
        store.selection = copy.selection.filter { store.doc.node($0) != nil }
        return changed
    }

    /// One of the core's commands on the open design, as one step; whether it changed anything.
    func command(_ store: DocumentStore, _ run: () -> Void) throws -> Bool {
        MCPHost.shared.endEditing()
        let before = store.doc
        run()
        guard store.doc != before else { return false }
        MCPHost.shared.edited()
        return true
    }

    func described(_ ids: [UUID], in store: DocumentStore, full: Bool = false, depth: Int = 0, warnings: [String] = []) -> [Content] {
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
        let defaultBoard = store.lastPreset ?? Preset.standard.size
        var made: [Node] = []
        for spec in specs {
            made.append(try Self.make(spec, parentSize: parentSize, boardSize: defaultBoard, names: &names, warnings: &warnings, nextBoard: &nextBoard))
        }

        try change(store, made.count == 1 ? made[0].kind.adding : "Add Layers") { doc in
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
            node.name = kind == .text ? String((node.text ?? "").prefix(40)) : carousel ? nextName(String(localized: "Carousel"), artboard: true, taken: names) : nextName(kind.title, artboard: kind == .artboard, taken: names)
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
        let file = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MCPError("There is no file at \(file.path).") }
        var mode = ImageFill.Mode.cover
        if let m = try args.string("mode") {
            guard let found = ImageFill.Mode(rawValue: m.lowercased()) else { throw MCPError("mode is cover, fit or stretch.") }
            mode = found
        }
        let doc = store.doc
        var target: UUID?
        let into = try args.string("into")?.lowercased() ?? "fill"
        guard ["fill", "border"].contains(into) else { throw MCPError("into is fill or border.") }
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: doc)
            guard let n = doc.node(id) else { throw MCPError("There is no layer \(ref).") }
            if into == "border" {
                guard [.rectangle, .ellipse, .path, .line].contains(n.kind) else { throw MCPError("Pictures paint the borders of rectangles, ellipses, paths and lines.") }
            } else {
                guard [.rectangle, .ellipse, .path, .text].contains(n.kind) else { throw MCPError("Pictures fill rectangles, ellipses, paths and the letters of text.") }
            }
            target = id
        } else if into == "border" {
            throw MCPError("Give the layer whose border the picture paints.")
        }

        // Into the design's own images, so it goes wherever the design does.
        guard var image = WindowsCore.importPicture(file) else { throw MCPError("\(file.lastPathComponent) is not a picture Bezzle can read.") }
        image.mode = mode
        let w = Int(image.size.width), h = Int(image.size.height)

        if let target {
            try change(store, "Add Picture") { doc in
                doc.update(target) { n in
                    if into == "border" {
                        n.border.on = true
                        if n.border.width == 0 { n.border.width = 1 }
                        n.border.image = image
                    } else {
                        n.fill.on = true
                        n.fill.image = image
                        // Every letter of a text shows it.
                        n.clearLetterColors()
                    }
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
        try change(store, ids.count == 1 ? store.doc.node(ids[0])?.kind.deleting ?? "Delete Layer" : "Delete Layers") { doc in
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
        guard !ids.contains(where: { doc.ancestors(of: $0).contains(where: \.isRepeatGrid) }) else {
            throw MCPError("Layers in a repeat grid cannot be grouped: the grid's cells follow its first.")
        }
        guard DocumentStore.groupable(ids, in: doc) != nil else {
            throw MCPError("Group layers that lie on the same artboard, or all on the canvas. move_layers brings them together.")
        }
        let name = try args.string("name")
        var group: UUID?
        try change(store, DocumentStore.grouping) { doc in group = DocumentStore.group(ids, in: &doc, name: name) }
        guard let group else { return described(ids, in: store) }
        store.selection = [group]
        return described([group], in: store, depth: 1)
    }

    func ungroupLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        guard ids.allSatisfy({ store.doc.node($0)?.isGroup == true }) else { throw MCPError("Only groups can be ungrouped.") }
        var freed: [UUID] = []
        var warnings: [String] = []
        for group in ids.compactMap({ store.doc.node($0) }) {
            if group.mask?.isEmpty == false { warnings.append("\(group.name)'s mask went with it.") }
            if group.opacity != 1 || group.blend != nil || group.blur != nil || !group.shadows.isEmpty {
                warnings.append("\(group.name)'s opacity, blend, blur and shadow went with it.")
            }
        }
        try change(store, "Ungroup") { doc in freed = DocumentStore.ungroup(ids, in: &doc) }
        store.selection = freed
        return described(freed, in: store, warnings: warnings)
    }

    // MARK: As the Object menu does

    func arrangeLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let order = try args.string("order")?.lowercased()
        let how: WindowsCore.Arrange = switch order {
        case "front": .front
        case "forward": .forward
        case "backward": .backward
        case "back": .back
        default: throw MCPError("order is front, forward, backward or back.")
        }
        let name: LocalizedStringResource = switch how {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
        let changed = try command(store) { WindowsCore.arrange(ids, how) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing moved: they were there already."])
    }

    func alignLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let edge = try args.string("edge")?.lowercased()
        let how: WindowsCore.Align = switch edge {
        case "left": .left
        case "center", "centre", "centerx": .centerX
        case "right": .right
        case "top": .top
        case "middle", "centery": .centerY
        case "bottom": .bottom
        default: throw MCPError("edge is left, center, right, top, middle or bottom.")
        }
        if ids.count == 1, store.doc.artboard(of: ids[0]) == nil { throw MCPError("A layer on its own lines up with its artboard, and this one is on none.") }
        let changed = try command(store) { WindowsCore.align(ids, how) }
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
        let changed = try command(store) { WindowsCore.distribute(ids, horizontally: across) }
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
        let changed = try command(store) { WindowsCore.flip(ids, horizontally: across) }
        return described(ids, in: store, warnings: changed ? [] : ["Nothing changed: artboards, locked layers, and text on its own do not flip."])
    }

    /// Turns layers in depth as one body (`DepthBody`), in the design or, with `time`, in its film.
    func turnLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let x = try args.number("x"), y = try args.number("y"), z = try args.number("z")
        guard x != nil || y != nil || z != nil else { throw MCPError("Say how it shall be turned: x, y, or both; or z, how high it shall stand.") }
        let turnable = ids.filter { store.doc.node($0).map { !$0.isArtboard && !$0.locked } == true }
        guard !turnable.isEmpty else { throw MCPError("An artboard is the page itself, and a locked layer stays as it is: nothing here can be turned.") }
        var warnings: [String] = []
        if turnable.count < ids.count { warnings.append("Artboards and locked layers were left as they are.") }
        if store.doc.depthBodies(of: turnable).count > 1 { warnings.append("These do not all lie together: each artboard's or group's layers were turned as a body of their own, and layers off any artboard each about its own middle.") }
        if let time = try args.number("time") {
            guard z == nil else { throw MCPError("z is the design's. In a film, pose lift with animate.") }
            guard time >= 0 else { throw MCPError("time is seconds from the film's start, 0 or more.") }
            let changed = try change(store, "Turn in Depth") { doc in
                if let x { doc.poseInDepth(.tilt, of: turnable, at: time) { _ in x } }
                if let y { doc.poseInDepth(.swing, of: turnable, at: time) { _ in y } }
            }
            if !changed { warnings.append("Nothing changed: they were posed so already.") }
            return described(turnable, in: store, warnings: warnings + ["Posed in the film at \(JSONValue.number(time).text) s: get_animation lists the keys."])
        }
        let changed = try change(store, "Turn in Depth") { doc in
            doc.turnInDepth(turnable) { _, now in
                var t = now
                if let x { t.x = x }
                if let y { t.y = y }
                if let z { t.z = CGFloat(z) }
                return t
            }
        }
        if !changed { warnings.append("Nothing changed: they were turned so already.") }
        return described(turnable, in: store, warnings: warnings)
    }

    func combineShapes(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let operation = try args.string("operation")?.lowercased() ?? ""
        guard ["union", "subtract", "intersect", "exclude"].contains(operation) else { throw MCPError("operation is union, subtract, intersect or exclude.") }
        guard WindowsCore.canCombine(ids) else { throw MCPError("Combining takes two or more rectangles, ellipses and paths, none locked.") }
        MCPHost.shared.endEditing()
        guard let made = WindowsCore.combine(ids, operation) else { throw MCPError("Nothing would be left of them, so nothing changed.") }
        MCPHost.shared.edited()
        store.selection = [made]
        return described([made], in: store, full: true)
    }

    func convertToPath(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        // Words being typed are the text's before it is outlined.
        MCPHost.shared.endEditing()
        // Texts become the outlines of their letters, as on the Mac (Host/Outlining.swift).
        guard let made = WindowsCore.pathConversion(ids, in: store.doc).change else {
            throw MCPError("Only rectangles, ellipses, lines and texts become paths, and none of these can (they are locked, or texts with emoji or in a repeat grid, a component copy or a deck).")
        }
        try change(store, "Convert to Path") { doc in made(&doc) }
        return described(ids, in: store, full: true)
    }

    func selectLayers(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        MCPHost.shared.endEditing()
        if let list = args["layers"] as? [Any], list.isEmpty {
            store.selection = []
        } else {
            store.selection = try Self.layers(args, in: store)
        }
        return described(store.selection, in: store)
    }
}
