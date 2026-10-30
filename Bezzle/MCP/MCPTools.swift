import AppKit

/// What an AI assistant can do in Bezzle, as tools of the Model Context Protocol: find and open
/// designs, read their layers and look at them as pictures, add, change and arrange layers, undo,
/// and export. Each change goes through the design's store as one made by hand does, so it shows
/// at once, is one step of the undo history, and is saved a moment later.
final class MCPTools {
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

    /// Each tool's name and the first sentence of what it does, for a short list.
    var summaries: [(name: String, summary: String)] {
        definitions.map { d in (d.name, d.description.split(separator: ". ", maxSplits: 1).first.map { $0.hasSuffix(".") ? String($0) : $0 + "." } ?? d.description) }
    }

    func has(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    func call(_ name: String, _ arguments: [String: Any]) async -> JSONValue {
        guard let tool = definitions.first(where: { $0.name == name }) else { return Self.failed("There is no tool called \(name).") }
        do {
            let content = try await tool.run(Arguments(arguments))
            return ["content": .array(content.map(\.json))]
        } catch let error as MCPError {
            return Self.failed(error.message)
        } catch {
            return Self.failed(error.localizedDescription)
        }
    }

    private static func failed(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    /// Told to the assistant when it connects.
    static let instructions = """
        Bezzle is a Mac app for designing screens, posts and pages. A design is an infinite canvas \
        of artboards (like screens or pages, possibly carousels of slides, or decks of posts that \
        share one design and differ in their words and pictures) with layers on them: \
        rectangles, ellipses, lines, text, paths (vector outlines), groups. Coordinates are points, \
        y pointing down. An artboard's x and y are on the canvas; any other layer's are measured \
        from the top left of the artboard or group it lies in. Layers are listed bottom first. \
        Refer to designs by name and layers by id (or exact name). Start with get_design to see \
        what is open. add_layers builds a whole screen in one call, nested; update_layers changes \
        many layers at once. Look at what you made with render and fix what looks wrong. Every \
        change is one step the person can undo with Command-Z, and designs save themselves: there \
        is no save.
        """

    // MARK: Designs open in windows

    private struct OpenDesign {
        weak var store: DocumentStore?
    }

    private static var open: [OpenDesign] = []

    /// A design window has opened its design.
    static func opened(_ store: DocumentStore) {
        open.removeAll { $0.store == nil || $0.store === store }
        open.append(OpenDesign(store: store))
    }

    static func closed(_ store: DocumentStore) {
        open.removeAll { $0.store == nil || $0.store === store }
    }

    /// The open designs, the window in front first.
    static var stores: [DocumentStore] {
        let all = open.compactMap(\.store)
        var ordered = NSApp.orderedWindows.compactMap { window in all.first { $0.canvas?.window === window } }
        ordered += all.reversed().filter { s in !ordered.contains { $0 === s } }
        return ordered
    }

    /// The design `design` names, opened if it is not, or the one in front.
    func store(_ args: Arguments) async throws -> DocumentStore {
        if let ref = try args.string("design") {
            if let store = Self.openStore(ref) { return store }
            return try await open(try locate(ref))
        }
        guard let front = Self.stores.first else {
            throw MCPError("No design is open. list_designs shows the designs; open one with open_design, or make one with create_design.")
        }
        return front
    }

    private static func openStore(_ ref: String) -> DocumentStore? {
        let url = fileURL(ref)
        return stores.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame || url.map($0.isAt) == true }
    }

    /// A design's file: one on the home screen by name, or a path.
    private func locate(_ ref: String) throws -> URL {
        Library.shared.refresh()
        if let entry = Library.shared.entries.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return entry.url }
        if let url = Self.fileURL(ref), FileManager.default.fileExists(atPath: url.path) { return url }
        throw MCPError("There is no design called \"\(ref)\". list_designs shows them all; a path to a .bezzle, .vellum, .xd, .fig or .sketch file works too.")
    }

    private static func fileURL(_ ref: String) -> URL? {
        guard ref.contains("/") else { return nil }
        return URL(fileURLWithPath: (ref as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Opens a design in a window, as the home screen does, and waits for it. A file from Adobe XD,
    /// Figma or Sketch becomes a new design in the Bezzle folder, which is what opens.
    private func open(_ url: URL) async throws -> DocumentStore {
        let url = url.standardizedFileURL
        let ext = url.pathExtension.lowercased()
        let foreign = Importer.imports(url)
        guard BezzleDocument.fileExtensions.contains(ext) || foreign else {
            throw MCPError("\(url.lastPathComponent) is not a design: Bezzle opens .bezzle and .vellum designs, and brings in .xd, .fig and .sketch files.")
        }
        if !foreign {
            do { _ = try DesignFile.read(url) } catch {
                throw MCPError("\(url.lastPathComponent) could not be opened: \(error.localizedDescription)")
            }
        }
        if let store = Self.stores.first(where: { $0.isAt(url) }) { return store }
        let before = Set(Self.stores.map(ObjectIdentifier.init))
        // Until a window of Bezzle's has shown, it has nothing to open windows with; the home
        // window shows once the app comes forward, and then opens what is waiting.
        if WindowRouter.shared.openWindow == nil { NSApp.activate() }
        WindowRouter.shared.open(url)
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            let stores = Self.stores
            if let store = stores.first(where: { $0.isAt(url) }) ?? (foreign ? stores.first { !before.contains(ObjectIdentifier($0)) } : nil) {
                // A moment for the canvas to find its size, so zooming works.
                try await Task.sleep(for: .milliseconds(200))
                return store
            }
        }
        throw MCPError("\(url.lastPathComponent) did not open. If Bezzle has no window open at all, click its icon in the Dock and try again.")
    }

    // MARK: Designs

    func listDesigns(_ args: Arguments) throws -> [Content] {
        Library.shared.refresh()
        let open = Self.stores
        let designs: [JSONValue] = Library.shared.entries.map { entry in
            let store = open.first { $0.isAt(entry.url) }
            return .compact([
                ("name", .string(entry.name)),
                ("path", .string(entry.url.path)),
                ("modified", .string(ISO8601DateFormatter().string(from: entry.modified))),
                ("open", store != nil ? true : nil),
                ("front", store != nil && store === open.first ? true : nil),
            ])
        }
        return [.text(JSONValue.compact([("folder", .string(Library.shared.folder.path)), ("designs", .array(designs))]).text)]
    }

    func createDesign(_ args: Arguments) async throws -> [Content] {
        var size: CGSize?
        var board = Node(kind: .artboard, frame: .zero)
        var warnings: [String] = []
        var props: [String: Any] = [:]
        for key in ["preset", "carousel", "width", "height"] where args[key] != nil { props[key] = args[key] }
        if !props.isEmpty {
            board.frame.size = CGSize(width: 393, height: 852)
            try Self.apply(props, to: &board, warnings: &warnings)
            size = board.frame.size
        }
        let name = try args.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        var doc = BezzleDocument()
        if size != nil {
            // Named for its preset, as the home screen names it.
            let preset = try args.string("preset").flatMap { p in Preset.all.first { $0.name.caseInsensitiveCompare(p) == .orderedSame } }
            board.name = preset.map { String(localized: $0.title) } ?? (board.isCarousel ? String(localized: "Carousel") : String(localized: "Artboard"))
            doc.nodes = [board]
        }
        let url = Library.shared.freeURL(named: name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled"))
        do {
            try DesignFile.write(doc, to: url)
        } catch {
            throw MCPError("The design could not be made: \(error.localizedDescription)")
        }
        Library.shared.refresh()
        let store = try await open(url)
        store.zoomToFit()
        return [.text(summary(of: store, warnings: warnings).text)]
    }

    func openDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        store.canvas?.window?.makeKeyAndOrderFront(nil)
        return [.text(summary(of: store).text)]
    }

    func closeDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let name = store.name
        store.canvas?.endEditing()
        store.save()
        guard let window = store.canvas?.window else { throw MCPError("\(name) has no window to close.") }
        window.performClose(nil)
        return [.text("Closed \(name). It was saved.")]
    }

    func renameDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let name = try args.string("name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError("Give the new name.") }
        store.rename(to: name)
        return [.text(summary(of: store).text)]
    }

    func duplicateDesign(_ args: Arguments) async throws -> [Content] {
        guard let ref = try args.string("design") else { throw MCPError("Say which design to copy.") }
        let url = try Self.openStore(ref)?.url ?? locate(ref)
        if let store = Self.openStore(ref) {
            store.save()
            DocumentStore.finishSaving()
        }
        // The same name `Library.duplicate` picks.
        let copy = Library.shared.freeURL(named: url.deletingPathExtension().lastPathComponent + " copy", in: url.deletingLastPathComponent())
        Library.shared.duplicate(url)
        guard FileManager.default.fileExists(atPath: copy.path) else { throw MCPError("The copy could not be made.") }
        return [.text(JSONValue.object([("name", .string(copy.deletingPathExtension().lastPathComponent)), ("path", .string(copy.path))]).text)]
    }

    func deleteDesign(_ args: Arguments) async throws -> [Content] {
        guard let ref = try args.string("design") else { throw MCPError("Say which design to delete.") }
        let store = Self.openStore(ref)
        let url = try store?.url ?? locate(ref)
        if let store {
            store.canvas?.endEditing()
            store.save()
            store.canvas?.window?.performClose(nil)
            DocumentStore.finishSaving()
        }
        let inFolder = url.standardizedFileURL.path.hasPrefix(Library.shared.folder.standardizedFileURL.path + "/")
        Library.shared.remove(url)
        return [.text(inFolder ? "Moved \(url.lastPathComponent) to the Trash." : "Took \(url.lastPathComponent) off the home screen; the file itself is where it was.")]
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
        let undo = store.undoManager
        return [
            ("design", .string(store.name)),
            ("path", .string(store.url.path)),
            ("artboards", .array(store.doc.artboards.map { .object([("id", .string($0.id.uuidString)), ("name", .string($0.name))]) })),
            ("layerCount", .number(store.layerCount)),
            ("selection", .array(store.selection.map { .string($0.uuidString) })),
            ("view", .compact([("zoom", .number(store.viewport.zoom)), ("visible", store.canvasSize == .zero ? nil : Self.rect(visible))])),
            ("canUndo", undo?.canUndo == true ? .string(undo?.undoActionName ?? "") : nil),
            ("canRedo", undo?.canRedo == true ? .string(undo?.redoActionName ?? "") : nil),
        ]
    }

    // MARK: Undo

    func undo(_ args: Arguments, redo: Bool) async throws -> [Content] {
        let store = try await store(args)
        guard let undo = store.undoManager else { throw MCPError("\(store.name) has no undo history.") }
        store.canvas?.endEditing()
        var done: [String] = []
        for _ in 0..<max(1, try args.int("steps") ?? 1) {
            guard redo ? undo.canRedo : undo.canUndo else { break }
            done.append(redo ? undo.redoActionName : undo.undoActionName)
            if redo { undo.redo() } else { undo.undo() }
        }
        guard !done.isEmpty else { return [.text("There is nothing to \(redo ? "redo" : "undo").")] }
        let summary = summary(of: store)
        return [.text(JSONValue.object([(redo ? "redid" : "undid", .array(done.map { .string($0) })), ("now", summary)]).text)]
    }

    // MARK: Looking

    func view(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: store.doc)
            guard let frame = store.doc.absoluteFrame(of: id) else { throw MCPError("That layer is gone.") }
            store.viewport.fit(Geometry.bounds(of: frame, rotation: store.doc.node(id)?.rotation ?? 0), in: store.canvasSize, padding: 80, maxZoom: 8)
        } else if let word = args["zoom"] as? String {
            switch word.lowercased() {
            case "fit", "all": store.zoomToFit()
            case "selection": store.zoomToSelection()
            default: throw MCPError("zoom is a number, 1 for actual size, or \"fit\" or \"selection\".")
            }
        } else if let zoom = try args.number("zoom") {
            store.zoom(to: zoom)
        } else {
            throw MCPError("Give a layer to look at, or a zoom.")
        }
        return [.text(summary(of: store).text)]
    }

    func listFonts(_ args: Arguments) throws -> [Content] {
        if let family = try args.string("family") {
            let match = family.caseInsensitiveCompare("SF Pro") == .orderedSame ? TextStyle.system : Fonts.families.first { $0.caseInsensitiveCompare(family) == .orderedSame }
            guard let match else { throw MCPError("There is no font family called \(family) on this Mac.") }
            return [.text(JSONValue.object([("family", .string(match)), ("faces", .array(Fonts.faces(of: match).map { .string($0) }))]).text)]
        }
        let search = try args.string("search")?.lowercased()
        let families = Fonts.families.filter { search == nil || $0.lowercased().contains(search!) }
        return [.text(JSONValue.object([("families", .array(families.map { .string($0) })), ("note", "\"System\" is SF Pro, the Mac's own. list_fonts with a family lists its faces.")]).text)]
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

struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension DocumentStore {
    /// Whether this is the design at `url`. A package's address may or may not end in a slash,
    /// and one in /tmp may or may not start with /private, so they are told apart by path.
    func isAt(_ url: URL) -> Bool {
        self.url.standardizedFileURL.path == url.standardizedFileURL.path
    }
}
