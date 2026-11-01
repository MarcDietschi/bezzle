import Foundation

/// The resources panel for the assistant: what the kits and icon sets hold, and putting a part
/// or an icon onto an artboard as the panel does. See `Kit`, `Icons`.
extension MCPTools {
    func resourceDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        let libraries = Kits.all.map(\.id) + IconSetID.allCases.map(\.rawValue)
        return [
            Definition(name: "list_resources", title: "List UI kits and icons",
                       description: "Lists what the resources panel holds: UI kits (\(Kits.all.map(\.id).joined(separator: ", "))) of ready-made parts such as bars, buttons, controls, lists and dialogs, and icon sets (Lucide, Phosphor, Material Symbols). With no arguments: the libraries and how much each holds. With library: a kit's parts by section (id, size, how it fits an artboard), or an icon set's styles and icon names. With query: the parts and icons whose names or tags fit it. add_resource puts one onto an artboard.",
                       properties: .object([
                           ("library", ["type": "string", "enum": .array(libraries.map { .string($0) }), "description": "One kit or icon set."]),
                           ("query", text("Words to look for, such as \"tab bar\", \"toggle\" or \"arrow right\".")),
                           ("limit", number("At most this many icons a set; 60 otherwise.")),
                       ]), readOnly: true, run: { [unowned self] in try self.listResources($0) }),
            Definition(name: "add_resource", title: "Add a UI part or an icon",
                       description: "Puts a kit's part or an icon onto an artboard as editable layers (a part is one group, named after it; an icon is one path layer), as dropping it from the resources panel does, and selects it. A part comes dark on a dark artboard. With no x and y: bars made for an edge (fit top or bottom) settle along the artboard's top or bottom edge, as wide as it, under or over bars already there (a status bar, then a navigation bar under it); parts that fit across a phone screen are as wide as it less their margin; the rest go in the artboard's middle. An icon given replace takes the place of that icon layer, keeping its size and colour.",
                       properties: .object([
                           design,
                           ("resource", text("A part by id, such as \"ios.tab-bar\" (see list_resources), or an icon as \"lucide/heart\", \"phosphor/house\" or \"material/home\".")),
                           ("artboard", text("The artboard to put it on, by id or name; the one in view otherwise.")),
                           ("x", number("Where its left edge goes, from the artboard's left (or on the canvas, with no artboard).")),
                           ("y", number("Where its top edge goes, from the artboard's top.")),
                           ("width", number("Parts that stretch: how wide to make it.")),
                           ("dark", boolean("Parts: dark (true) or light (false), whatever the artboard is.")),
                           ("style", text("Icons: the set's style, such as \"fill\" or \"bold\" (Phosphor: thin, light, regular, bold, fill; Material: outline, fill).")),
                           ("weight", number("Lucide icons: the width of their lines on a 24 point icon, 0.5 to 4; 2 otherwise.")),
                           ("size", number("Icons: how big, in points; 24 otherwise.")),
                           ("color", text("Icons: their colour, such as \"#1C1B19\"; ink, or white on a dark artboard, otherwise.")),
                           ("replace", text("Icons: an icon layer to take the place of, by id or name.")),
                       ]), required: ["resource"], run: { [unowned self] in try await self.addResource($0) }),
        ]
    }

    func listResources(_ args: Arguments) throws -> [Content] {
        let limit = max(1, try args.int("limit") ?? 60)
        let query = try args.string("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let library = try args.string("library")

        func part(_ c: Component, section: String? = nil) -> JSONValue {
            var fields: [(String, JSONValue)] = [("id", .string(c.id)), ("name", .string(String(localized: c.title))),
                                                 ("width", .number(c.size.width)), ("height", .number(c.size.height))]
            if let section { fields.append(("section", .string(section))) }
            switch c.fit {
            case .free: break
            case .top: fields.append(("fit", "top"))
            case .bottom: fields.append(("fit", "bottom"))
            case .across(let margin): fields.append(("fit", .string("across, \(Int(margin)) from each side")))
            }
            if let min = c.minWidth, c.stretches { fields.append(("minWidth", .number(min))) }
            return .object(fields)
        }
        func icons(_ set: IconSet, _ found: [Icon]) -> JSONValue {
            .object([("set", .string(set.id.rawValue)), ("styles", .array(set.styles.map { .string($0) })),
                     ("found", .number(found.count)),
                     ("icons", .array(found.prefix(limit).map { .string("\(set.id.rawValue)/\($0.name)") }))])
        }

        if let library, let kit = Kits.kit(library) {
            let wanted = query.isEmpty ? nil : Set(Kits.search(query).map(\.component.id))
            let parts = kit.sections.flatMap { s in
                s.components.filter { wanted?.contains($0.id) ?? true }.map { part($0, section: String(localized: s.title)) }
            }
            return [.text(JSONValue.object([("kit", .string(kit.id)), ("parts", .array(parts))]).text)]
        }
        if let library, let id = IconSetID(rawValue: library) {
            let set = Icons.set(id)
            return [.text(icons(set, query.isEmpty ? set.icons : Icons.search(query, in: id)).text)]
        }
        if let library { throw MCPError("library is one of \(Kits.all.map(\.id).joined(separator: ", ")), \(IconSetID.allCases.map(\.rawValue).joined(separator: ", ")); not \(library).") }

        if !query.isEmpty {
            let parts = Kits.search(query).map { part($0.component) }
            let sets = Icons.sets.compactMap { set -> JSONValue? in
                let found = Icons.search(query, in: set.id)
                return found.isEmpty ? nil : icons(set, found)
            }
            return [.text(JSONValue.object([("parts", .array(parts)), ("icons", .array(sets))]).text)]
        }
        let kits = Kits.all.map { kit -> JSONValue in
            .object([("id", .string(kit.id)), ("name", .string(String(localized: kit.title))), ("parts", .number(kit.components.count)),
                     ("sections", .array(kit.sections.map { .string(String(localized: $0.title)) }))])
        }
        let sets = Icons.sets.map { set -> JSONValue in
            .object([("id", .string(set.id.rawValue)), ("name", .string(set.name)), ("icons", .number(set.icons.count)),
                     ("styles", .array(set.styles.map { .string($0) })), ("licence", .string(set.licence))])
        }
        return [.text(JSONValue.object([("kits", .array(kits)), ("iconSets", .array(sets))]).text)]
    }

    func addResource(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let ref = try args.string("resource")?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw MCPError("Give resource: a part's id such as \"ios.tab-bar\", or an icon such as \"lucide/heart\".")
        }
        let resource = try Self.resource(ref, style: try args.string("style"), weight: try args.number("weight"))

        var boardID: UUID?
        if let name = try args.string("artboard") {
            let id = try Self.layer(name, in: store.doc)
            guard store.doc.node(id)?.isArtboard == true else { throw MCPError("\(name) is not an artboard.") }
            boardID = id
        }
        var target: UUID?
        if let name = try args.string("replace") {
            guard resource.icon != nil else { throw MCPError("replace is for icons: a part is added beside what is there.") }
            let id = try Self.layer(name, in: store.doc)
            guard let old = store.doc.node(id), Icons.isIcon(old) else { throw MCPError("\(name) is not an icon from one of the sets, so nothing takes its place.") }
            target = id
        }
        let width = try args.number("width").map { CGFloat($0) }
        if let width, let c = resource.component {
            guard c.stretches else { throw MCPError("\(c.id) is made at one size, \(Int(c.size.width))×\(Int(c.size.height)); it does not stretch.") }
            guard width >= (c.minWidth ?? 1) else { throw MCPError("\(c.id) is at least \(Int(c.minWidth ?? 1)) wide.") }
        }
        guard var plan = store.placing(resource, at: nil, on: target, into: boardID, dark: try args.bool("dark"), width: width) else {
            throw MCPError(store.isReadOnly ? "This design can only be looked at." : "\(ref) could not be made.")
        }
        if plan.swap == nil, resource.icon != nil {
            if let size = try args.number("size") {
                guard size > 0 else { throw MCPError("size should be more than 0.") }
                let k = CGFloat(size) / 24
                let c = plan.node.frame.center
                plan.node.frame = CGRect(x: c.x - plan.node.frame.width * k / 2, y: c.y - plan.node.frame.height * k / 2,
                                         width: plan.node.frame.width * k, height: plan.node.frame.height * k)
            }
            if let color = args["color"] { plan.node.fill.color = try Self.color(color, "color") }
        }
        if plan.swap == nil {
            let x = try args.number("x").map { CGFloat($0) }, y = try args.number("y").map { CGFloat($0) }
            if x != nil || y != nil {
                let origin = plan.board.flatMap { store.doc.node($0)?.frame.origin } ?? .zero
                if let x { plan.node.frame.origin.x = origin.x + x }
                if let y { plan.node.frame.origin.y = origin.y + y }
                plan.fit = .free
            }
        }
        let made = plan.node, board = plan.board
        if let swap = plan.swap {
            try change(store, "Replace Icon") { doc in
                let o = doc.parentOrigin(of: swap)
                doc.update(swap) { n in
                    let id = n.id
                    n = made
                    n.id = id
                    n.frame = made.frame.offsetBy(dx: -o.x, dy: -o.y)
                }
            }
            store.selection = [swap]
            return described([swap], in: store, depth: 1)
        }
        var added = made.id
        let part = plan.part
        try change(store, resource.component != nil ? "Add Component" : "Add Icon") { doc in added = DocumentStore.add(made, part: part, to: board, in: &doc) }
        store.selection = [added]
        return described([added], in: store, depth: 1)
    }

    /// A part's id, or an icon as "set/name" (or "icon/set/name"), with the style asked for.
    static func resource(_ ref: String, style: String?, weight: Double?) throws -> Resource {
        if Kits.component(ref) != nil { return .component(ref) }
        var parts = ref.split(separator: "/").map(String.init)
        if parts.first == "icon" { parts.removeFirst() }
        guard parts.count == 2 else {
            let near = Kits.search(ref.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")).prefix(5).map(\.component.id)
            throw MCPError("\(ref) is neither a part nor an icon.\(near.isEmpty ? "" : " Perhaps \(near.joined(separator: ", ")).") list_resources lists them.")
        }
        guard let id = IconSetID(rawValue: parts[0].lowercased()) else {
            throw MCPError("\(parts[0]) is not an icon set: \(IconSetID.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let set = Icons.set(id)
        guard set.icon(parts[1]) != nil else {
            let near = Icons.search(parts[1], in: id, limit: 6).map(\.name)
            throw MCPError("\(set.name) has no icon \(parts[1]).\(near.isEmpty ? "" : " Perhaps \(near.joined(separator: ", ")).")")
        }
        var s = set.defaultStyle
        if let style {
            let wanted = style.lowercased() == "filled" ? "fill" : style.lowercased() == "outlined" ? "outline" : style.lowercased()
            guard let i = set.styles.firstIndex(of: wanted) else {
                throw MCPError("\(set.name)'s styles are \(set.styles.joined(separator: ", ")).")
            }
            s.index = i
        }
        if let weight {
            guard set.drawnAsLines else { throw MCPError("weight is for Lucide's lines; \(set.name) has styles: \(set.styles.joined(separator: ", ")).") }
            s.weight = CGFloat(min(max(weight, 0.5), 4))
        }
        return .icon(id, parts[1], s)
    }
}
