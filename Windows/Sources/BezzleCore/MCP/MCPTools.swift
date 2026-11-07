import Foundation

// From Bezzle/MCP/MCPTools.swift, for Windows: what an AI assistant can do in Bezzle, as tools
// of the Model Context Protocol. Each change goes through the core as one made by hand does, so
// it shows at once, is one step of the undo history, and is saved a moment later. Windows has one
// design open at a time: a tool that names another opens it in the window.

@MainActor final class MCPTools {
    struct Definition {
        let name: String
        let title: String
        let description: String
        let properties: JSONValue
        var required: [String] = []
        var readOnly = false
        var destructive = false
        let run: (Arguments) async throws -> [Content]
    }

    enum Content {
        case text(String)
        case png(Data)

        var json: JSONValue {
            switch self {
            case .text(let s): ["type": "text", "text": .string(s)]
            case .png(let data): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
            }
        }
    }

    private var definitions: [Definition] = []

    init() {
        definitions = makeDefinitions()
    }

    var list: [JSONValue] {
        definitions.map { d in
            [
                "name": .string(d.name),
                "title": .string(d.title),
                "description": .string(d.description),
                "inputSchema": .object([("type", "object"), ("properties", d.properties)] + (d.required.isEmpty ? [] : [("required", .array(d.required.map { .string($0) }))])),
                "annotations": [
                    "title": .string(d.title),
                    "readOnlyHint": .bool(d.readOnly),
                    "destructiveHint": .bool(d.destructive),
                    "idempotentHint": .bool(d.readOnly),
                    "openWorldHint": false,
                ],
            ]
        }
    }

    var names: [String] { definitions.map(\.name) }

    func has(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    func call(_ name: String, _ arguments: [String: Any]) async -> JSONValue {
        guard let tool = definitions.first(where: { $0.name == name }) else { return Self.failed("There is no tool called \(name).") }
        do {
            let content = try await tool.run(Arguments(arguments))
            return ["content": .array(content.map(\.json))]
        } catch let error as MCPError {
            return Self.failed(error.message)
        } catch {
            return Self.failed("\(error)")
        }
    }

    private static func failed(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    /// Told to the assistant when it connects.
    static let instructions = """
        Bezzle is an app for designing screens, posts and pages, here on Windows. A design is an \
        infinite canvas of artboards (like screens or pages, possibly carousels of slides, or \
        decks of posts that share one design and differ in their words and pictures) with layers \
        on them: rectangles, ellipses, lines, text, paths (vector outlines), groups. Coordinates \
        are points, y pointing down. An artboard's x and y are on the canvas; any other layer's \
        are measured from the top left of the artboard or group it lies in. Layers are listed \
        bottom first. Refer to designs by name and layers by id (or exact name). Start with \
        get_design to see what is open; Bezzle on Windows has one design open at a time, and a \
        tool that names another opens it. add_layers builds a whole screen in one call, nested; \
        update_layers changes many layers at once. Look at what you made with render and fix \
        what looks wrong. Every change is one step the person can undo with Ctrl+Z, and designs \
        save themselves: there is no save.
        """

    // MARK: The design open

    /// The design `design` names, opened if it is not, or the one open.
    func store(_ args: Arguments) async throws -> DocumentStore {
        let store = DocumentStore.open
        if let ref = try args.string("design") {
            if store.isOpen, store.name.caseInsensitiveCompare(ref) == .orderedSame || Self.fileURL(ref).map(store.isAt) == true { return store }
            return try open(try locate(ref))
        }
        guard store.isOpen else {
            throw MCPError("No design is open. list_designs shows the designs; open one with open_design, or make one with create_design.")
        }
        return store
    }

    /// The designs on the home screen: those in the designs folder, the latest first.
    private static func designs() -> [(name: String, url: URL, modified: Date)] {
        let folder = MCPHost.shared.designsFolder()
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "bezzle" }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url.deletingPathExtension().lastPathComponent, url, modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// A design's file: one on the home screen by name, or a path.
    private func locate(_ ref: String) throws -> URL {
        if let entry = Self.designs().first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return entry.url }
        if let url = Self.fileURL(ref), FileManager.default.fileExists(atPath: url.path) { return url }
        throw MCPError("There is no design called \"\(ref)\". list_designs shows them all; a path to a .bezzle design works too.")
    }

    private static func fileURL(_ ref: String) -> URL? {
        guard ref.contains("/") || ref.contains("\\") else { return nil }
        return URL(fileURLWithPath: ref).standardizedFileURL
    }

    /// Opens a design in the window, as the home screen does.
    private func open(_ url: URL) throws -> DocumentStore {
        guard url.pathExtension.lowercased() == "bezzle" else {
            throw MCPError("\(url.lastPathComponent) is not a design: Bezzle on Windows opens .bezzle designs.")
        }
        let store = DocumentStore.open
        if store.isAt(url) { return store }
        MCPHost.shared.endEditing()
        guard MCPHost.shared.open(url), store.isAt(url) else { throw MCPError("\(url.lastPathComponent) could not be opened.") }
        return store
    }

    // MARK: Designs

    func listDesigns(_ args: Arguments) throws -> [Content] {
        let open = DocumentStore.open
        let designs: [JSONValue] = Self.designs().map { entry in
            let isOpen = open.isAt(entry.url)
            return .compact([
                ("name", .string(entry.name)),
                ("path", .string(entry.url.path)),
                ("modified", .string(ISO8601DateFormatter().string(from: entry.modified))),
                ("open", isOpen ? true : nil),
                ("front", isOpen ? true : nil),
            ])
        }
        return [.text(JSONValue.compact([("folder", .string(MCPHost.shared.designsFolder().path)), ("designs", .array(designs))]).text)]
    }

    func createDesign(_ args: Arguments) async throws -> [Content] {
        var board = Node(kind: .artboard, frame: .zero)
        var warnings: [String] = []
        var props: [String: Any] = [:]
        for key in ["preset", "carousel", "width", "height"] where args[key] != nil { props[key] = args[key] }
        var doc = BezzleDocument()
        if !props.isEmpty {
            board.frame.size = CGSize(width: 393, height: 852)
            try Self.apply(props, to: &board, warnings: &warnings)
            let preset = try args.string("preset").flatMap { p in Preset.all.first { $0.name.caseInsensitiveCompare(p) == .orderedSame } }
            board.name = preset.map { String(localized: $0.title) } ?? (board.isCarousel ? String(localized: "Carousel") : String(localized: "Artboard"))
            doc.nodes = [board]
        }
        let wanted = try args.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let folder = MCPHost.shared.designsFolder()
        let base = wanted.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        var url = folder.appendingPathComponent("\(base).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(i).bezzle")
            i += 1
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
            try encoder.encode(doc).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        } catch {
            throw MCPError("The design could not be made: \(error)")
        }
        let store = try open(url)
        store.zoomToFit()
        return [.text(summary(of: store, warnings: warnings).text)]
    }

    func openDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        return [.text(summary(of: store).text)]
    }

    func closeDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let name = store.name
        MCPHost.shared.endEditing()
        MCPHost.shared.close()
        return [.text("Closed \(name). It was saved.")]
    }

    /// What a design is, how it is looked at, and its layers.
    func getDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let depth = try args.int("depth") ?? .max
        let budget = Budget(Self.layerBudget)
        var pairs = summaryPairs(of: store)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: store.doc)
            pairs.append(("layer", Self.describe(store.doc.node(id)!, in: store.doc, full: false, depth: depth, budget: budget)))
        } else {
            pairs.append(("layers", .array(store.doc.nodes.map { Self.describe($0, in: store.doc, full: false, depth: depth, budget: budget) })))
        }
        if budget.left <= 0 {
            pairs.append(("note", "Not every layer is listed. Ask for one artboard with layer, or less of it with depth."))
        }
        return [.text(JSONValue.compact(pairs).text)]
    }

    func summary(of store: DocumentStore, warnings: [String] = []) -> JSONValue {
        .compact(summaryPairs(of: store) + [("warnings", .array(warnings.map { .string($0) }))])
    }

    private func summaryPairs(of store: DocumentStore) -> [(String, JSONValue?)] {
        let visible = store.visibleCanvasRect
        return [
            ("design", .string(store.name)),
            ("path", .string(store.url.path)),
            ("artboards", .array(store.doc.artboards.map { .object([("id", .string($0.id.uuidString)), ("name", .string($0.name))]) })),
            ("layerCount", .number(store.layerCount)),
            ("selection", .array(store.selection.map { .string($0.uuidString) })),
            ("view", .compact([("zoom", .number(store.zoom)), ("visible", visible.width > 0 ? Self.rect(visible) : nil)])),
            ("canUndo", store.canUndo ? true : nil),
            ("canRedo", store.canRedo ? true : nil),
        ]
    }

    // MARK: Undo

    func undo(_ args: Arguments, redo: Bool) async throws -> [Content] {
        let store = try await store(args)
        MCPHost.shared.endEditing()
        var done = 0
        for _ in 0..<max(1, try args.int("steps") ?? 1) {
            guard redo ? WindowsCore.redo() : WindowsCore.undo() else { break }
            done += 1
        }
        guard done > 0 else { return [.text("There is nothing to \(redo ? "redo" : "undo").")] }
        MCPHost.shared.edited()
        return [.text(JSONValue.object([(redo ? "redid" : "undid", .number(done)), ("now", summary(of: store))]).text)]
    }

    // MARK: Looking

    func view(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: store.doc)
            guard let frame = store.doc.absoluteFrame(of: id) else { throw MCPError("That layer is gone.") }
            MCPHost.shared.show(Geometry.bounds(of: frame, rotation: store.doc.node(id)?.rotation ?? 0))
        } else if let word = args["zoom"] as? String {
            switch word.lowercased() {
            case "fit", "all": store.zoomToFit()
            case "selection":
                guard let r = store.doc.selectionFrame(store.selection) else { throw MCPError("Nothing is selected.") }
                MCPHost.shared.show(r)
            default: throw MCPError("zoom is a number, 1 for actual size, or \"fit\" or \"selection\".")
            }
        } else if let zoom = try args.number("zoom") {
            MCPHost.shared.setZoom(min(max(zoom, 0.02), 64))
        } else {
            throw MCPError("Give a layer to look at, or a zoom.")
        }
        return [.text(summary(of: store).text)]
    }

    func listFonts(_ args: Arguments) throws -> [Content] {
        let all = Fonts.families
        if let family = try args.string("family") {
            let match = family.caseInsensitiveCompare("SF Pro") == .orderedSame ? TextStyle.system : all.first { $0.caseInsensitiveCompare(family) == .orderedSame }
            guard let match else { throw MCPError("There is no font family called \(family) in Bezzle.") }
            return [.text(JSONValue.object([("family", .string(match)), ("faces", .array(Fonts.faces(of: match).map { .string($0) }))]).text)]
        }
        let search = try args.string("search")?.lowercased()
        let families = all.filter { search == nil || $0.lowercased().contains(search!) }
        return [.text(JSONValue.object([("families", .array(families.map { .string($0) })), ("note", "\"System\" is SF Pro, drawn on Windows with an open look-alike. list_fonts with a family lists its faces.")]).text)]
    }

    // MARK: Reading what was sent

    struct Arguments {
        let values: [String: Any]

        init(_ values: [String: Any]) { self.values = values }

        /// What was sent for `key`, if anything; null counts as nothing.
        subscript(key: String) -> Any? { values[key].flatMap { $0 is NSNull ? nil : $0 } }

        func string(_ key: String) throws -> String? { try Read.string(self[key], key) }
        func number(_ key: String) throws -> Double? { try Read.number(self[key], key) }
        func int(_ key: String) throws -> Int? { try Read.number(self[key], key).map { Int($0.rounded()) } }
        func bool(_ key: String) throws -> Bool? { try Read.bool(self[key], key) }

        /// A list of strings, or one on its own.
        func strings(_ key: String) throws -> [String]? {
            guard let v = self[key] else { return nil }
            if let s = v as? String { return [s] }
            guard let list = v as? [Any], let strings = list as? [String] else { throw MCPError("\(key) should be a list of strings.") }
            return strings
        }

        func objects(_ key: String) throws -> [[String: Any]]? {
            guard let v = self[key] else { return nil }
            if let one = v as? [String: Any] { return [one] }
            guard let list = v as? [Any], let objects = list as? [[String: Any]] else { throw MCPError("\(key) should be a list of objects.") }
            return objects
        }
    }

    /// Values of one kind or another out of what `JSONSerialization` read, with a word for the
    /// assistant when one is not what it should be.
    enum Read {
        static func string(_ v: Any?, _ key: String) throws -> String? {
            guard let v, !(v is NSNull) else { return nil }
            guard let s = v as? String else { throw MCPError("\(key) should be a string.") }
            return s
        }

        static func number(_ v: Any?, _ key: String) throws -> Double? {
            guard let v, !(v is NSNull) else { return nil }
            if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            guard let n = v as? NSNumber, !n.isBoolean, n.doubleValue.isFinite else { throw MCPError("\(key) should be a number.") }
            return n.doubleValue
        }

        static func bool(_ v: Any?, _ key: String) throws -> Bool? {
            guard let v, !(v is NSNull) else { return nil }
            if let b = v as? Bool, !(v is NSNumber) || (v as? NSNumber)?.isBoolean == true { return b }
            guard let n = v as? NSNumber, n.isBoolean else { throw MCPError("\(key) should be true or false.") }
            return n.boolValue
        }

        static func object(_ v: Any?, _ key: String) throws -> [String: Any]? {
            guard let v, !(v is NSNull) else { return nil }
            guard let o = v as? [String: Any] else { throw MCPError("\(key) should be an object.") }
            return o
        }

        /// A point as {x, y} or [x, y].
        static func point(_ v: Any?, _ key: String) throws -> CGPoint? {
            guard let v, !(v is NSNull) else { return nil }
            if let o = v as? [String: Any], let x = try number(o["x"], "\(key).x"), let y = try number(o["y"], "\(key).y") { return CGPoint(x: x, y: y) }
            if let a = v as? [Any], a.count == 2, let x = try number(a[0], key), let y = try number(a[1], key) { return CGPoint(x: x, y: y) }
            throw MCPError("\(key) should be a point, {\"x\": 0, \"y\": 0}.")
        }
    }
}

struct MCPError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
