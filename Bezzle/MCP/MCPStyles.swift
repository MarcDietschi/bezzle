import Foundation

/// The design's styles for the assistant: listing them with the looks several layers share without
/// a name, naming a layer's look, giving layers a style, changing one everywhere at once, renaming
/// it and taking it away. See `Style`.
extension MCPTools {
    func styles(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let placeName = try args.string("place")

        // Naming the look one layer has, and those that look the same with all.
        if let name = try args.string("name") {
            guard let ref = try args.string("layer") else { throw MCPError("Give the layer whose look is named as layer, and its place.") }
            let id = try Self.layer(ref, in: store.doc)
            guard let node = store.doc.node(id) else { throw MCPError("There is no layer \(ref).") }
            let place = try Self.place(placeName, of: node)
            guard let look = place.look(of: node)?.kept else { throw MCPError("\(node.name) has no look there that can be named.") }
            let style = Style(name: name.isEmpty ? store.suggestedName(for: look) : name, look: look)
            let alike = try args.bool("all_alike") == true ? store.doc.looksAlike(look, besides: [id]) : []
            try change(store, "Name Style") { doc in
                doc.addStyle(style)
                doc.update(id) { place.name(style.id, in: &$0) }
                for use in alike { doc.update(use.layer) { use.place.name(style.id, in: &$0) } }
            }
            return listing(store, made: style.id)
        }

        // An artboard shown dark, or light again.
        if let appearance = try args.string("appearance") {
            guard ["dark", "light", "none"].contains(appearance) else { throw MCPError("appearance is dark, light, or none (light, with no dark look at hand).") }
            guard let ref = try args.string("layer") else { throw MCPError("Give the artboard as layer.") }
            let id = try Self.layer(ref, in: store.doc)
            guard store.doc.node(id)?.isArtboard == true, store.doc.path(of: id)?.indices.count == 1 else { throw MCPError("\(ref) is not an artboard.") }
            let before = store.doc
            try change(store, appearance == "dark" ? "Make Dark" : appearance == "light" ? "Make Light" : "Remove Dark") { doc in
                if appearance == "none" {
                    doc.update(id) { $0.dark = nil }
                } else {
                    doc.show(id, dark: appearance == "dark", name: StyleNames.base)
                }
            }
            store.washIn(id, before: before)
            return listing(store)
        }

        // Letting layers go of their names somewhere.
        if try args.bool("unname") == true {
            let ids = try Self.layers(args, in: store)
            try change(store, "Remove Style Name") { doc in
                for id in ids {
                    guard let n = doc.node(id) else { continue }
                    let places = try placeName.map { [try Self.place($0, of: n)] } ?? StylePlace.all(in: n)
                    doc.update(id) { node in for p in places { p.name(nil, in: &node) } }
                }
            }
            return described(ids, in: store, full: true)
        }

        guard let ref = try args.string("style") else { return listing(store) }
        let style = try Self.style(ref, in: store.doc)

        if try args.bool("remove") == true {
            try change(store, "Remove Style") { $0.removeStyle(style.id) }
            return listing(store)
        }
        if let rename = try args.string("rename") {
            let new = rename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty else { throw MCPError("rename is the style's new name.") }
            try change(store, "Rename Style") { $0.changeStyle(style.id) { $0.name = new } }
        }
        if let look = try Self.look(args, changing: style.look) {
            try change(store, "Change Style") { $0.changeStyle(style.id) { $0.look = look } }
        }
        // Its look in the dark: a colour of its own there, or made dark by itself again.
        if let c = args["dark_color"] {
            guard case .colour(var p) = style.look(dark: true) else { throw MCPError("dark_color is for colour styles.") }
            p.color = try Self.color(c, "dark_color")
            p.gradient = nil
            let look = StyleLook.colour(p)
            try change(store, "Change Style") { $0.changeStyle(style.id) { $0.dark = look } }
        }
        if try args.bool("dark_auto") == true {
            try change(store, "Automatic in the Dark") { $0.changeStyle(style.id) { $0.dark = nil } }
        }
        // Giving layers the style.
        let using = try args.bool("use") == true
        if args["layers"] != nil || using {
            let ids = try Self.layers(args, in: store)
            guard let now = store.doc.style(style.id) else { throw MCPError("There is no style \(ref).") }
            var skipped: [String] = []
            try change(store, "Use Style") { doc in
                for id in ids {
                    guard let n = doc.node(id) else { continue }
                    let place = try placeName.map { try Self.place($0, of: n) }
                        ?? StylePlace.all(in: n).first { $0.kind == now.kind && $0.look(of: n) != nil }
                    guard let place, place.look(of: n) != nil, place.takes(now.look, in: n) else { skipped.append(n.name); continue }
                    doc.update(id) { node in
                        place.name(now.id, in: &node)
                        place.apply(now.look, to: &node)
                        node.refit()
                    }
                }
            }
            if !skipped.isEmpty {
                return described(ids, in: store, full: true, warnings: ["\(skipped.joined(separator: ", ")) cannot take a \(now.kind.rawValue) style there."])
            }
            return described(ids, in: store, full: true)
        }
        return listing(store, made: style.id)
    }

    // MARK: Reading what was sent

    /// A style by its id or its name.
    static func style(_ ref: String, in doc: BezzleDocument) throws -> Style {
        let all = doc.styles ?? []
        if let id = UUID(uuidString: ref), let s = all.first(where: { $0.id == id }) { return s }
        let named = all.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw MCPError("There is no style \"\(ref)\". styles with nothing else lists them.") }
        throw MCPError("\(named.count) styles are called \"\(ref)\": \(named.map { "\($0.id.uuidString) (\($0.kind.rawValue))" }.joined(separator: ", ")). Use an id.")
    }

    /// A place on a layer, as "fill", "fill 2" (the second, over the first), "border", "shadow",
    /// "text" or "corners"; left out, the first that can be named.
    static func place(_ name: String?, of node: Node) throws -> StylePlace {
        guard let name else {
            if node.kind == .text { return .text }
            guard let first = StylePlace.all(in: node).first(where: { $0.look(of: node) != nil }) else {
                throw MCPError("\(node.name) has nothing that can be named.")
            }
            return first
        }
        let parts = name.lowercased().split(separator: " ")
        let n = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let place: StylePlace
        switch parts.first ?? "" {
        case "fill", "colour", "color": place = .fill(n - 1)
        case "border", "stroke": place = .border(n - 1)
        case "shadow": place = .shadow(n - 1)
        case "text", "type": place = .text
        case "corners", "radius": place = .corners
        default: throw MCPError("place is fill, border, shadow, text or corners, with a number after it for the second and on (\"fill 2\").")
        }
        guard StylePlace.all(in: node).contains(place) else { throw MCPError("\(node.name) has no \(name).") }
        return place
    }

    /// A new look for a style of its kind, from color, type, shadow or corners; nil when none is given.
    static func look(_ args: Arguments, changing old: StyleLook) throws -> StyleLook? {
        switch old {
        case .colour(var p):
            guard let c = args["color"] else { return nil }
            p.color = try color(c, "color")
            p.gradient = nil
            return .colour(p)
        case .text(var t):
            guard let o = try Read.object(args["type"], "type") else { return nil }
            if let f = try Read.string(o["family"], "type.family") {
                guard let family = Fonts.families.first(where: { $0.caseInsensitiveCompare(f) == .orderedSame || Fonts.displayName($0).caseInsensitiveCompare(f) == .orderedSame })
                else { throw MCPError("There is no font family \(f) on this Mac.") }
                t.face = Fonts.face(like: t.face, of: t.family, in: family)
                t.family = family
            }
            if let f = try Read.string(o["face"], "type.face") {
                guard let face = Fonts.faces(of: t.family).first(where: { $0.caseInsensitiveCompare(f) == .orderedSame })
                else { throw MCPError("\(Fonts.displayName(t.family)) has no \(f); it has \(Fonts.faces(of: t.family).joined(separator: ", ")).") }
                t.face = face
            }
            if let s = try Read.number(o["size"], "type.size") { t.size = CGFloat(min(max(s, 1), 2000)) }
            if o.keys.contains("line_spacing") { t.lineSpacing = try Read.number(o["line_spacing"], "type.line_spacing").map { CGFloat(max($0, 0)) } }
            if let s = try Read.number(o["letter_spacing"], "type.letter_spacing") { t.tracking = CGFloat(s) }
            if o.keys.contains("paragraph_spacing") {
                t.paragraphSpacing = try Read.number(o["paragraph_spacing"], "type.paragraph_spacing").flatMap { $0 > 0 ? CGFloat($0) : nil }
            }
            if o.keys.contains("case") {
                let c = try Read.string(o["case"], "type.case")
                if let c, c != "none" {
                    guard let lc = LetterCase(rawValue: c) else { throw MCPError("type.case is upper, lower, title, smallCaps or none.") }
                    t.letterCase = lc
                } else {
                    t.letterCase = nil
                }
            }
            if let u = try Read.bool(o["underline"], "type.underline") { t.underline = u }
            if let s = try Read.bool(o["strikethrough"], "type.strikethrough") { t.strikethrough = s ? true : nil }
            return .text(t)
        case .shadow(var s):
            guard let o = try Read.object(args["shadow"], "shadow") else { return nil }
            if let v = try Read.number(o["x"], "shadow.x") { s.x = CGFloat(v) }
            if let v = try Read.number(o["y"], "shadow.y") { s.y = CGFloat(v) }
            if let v = try Read.number(o["blur"], "shadow.blur") { s.blur = CGFloat(max(v, 0)) }
            if let v = try Read.number(o["spread"], "shadow.spread") { s.spread = v == 0 ? nil : CGFloat(v) }
            if let c = o["color"], !(c is NSNull) { s.color = try color(c, "shadow.color") }
            if let v = try Read.bool(o["inset"], "shadow.inset") { s.inset = v ? true : nil }
            return .shadow(s)
        case .corners(var c):
            guard let r = try args.number("corners") else { return nil }
            c.radius = CGFloat(max(r, 0))
            if let k = try args.number("smoothing") { c.smoothing = k > 0 ? CGFloat(min(k, 1)) : nil }
            return .corners(c)
        }
    }

    // MARK: Describing

    /// The design's styles, how many layers use each, and the looks several layers share unnamed.
    private func listing(_ store: DocumentStore, made: UUID? = nil) -> [Content] {
        let uses = store.doc.styleUses
        let styles = StyleKind.allCases.flatMap { store.styles(of: $0) }.map { s -> JSONValue in
            let darkens = s.kind == .colour || s.kind == .shadow
            let dark: JSONValue? = darkens ? Self.describe(s.look(dark: true)) : nil
            let byHand: JSONValue? = s.dark != nil ? .bool(true) : nil
            let isMade: JSONValue? = s.id == made ? .bool(true) : nil
            let pairs: [(String, JSONValue?)] = [
                ("id", .string(s.id.uuidString)), ("name", .string(s.name)), ("kind", .string(s.kind.rawValue)),
                ("look", Self.describe(s.look)), ("dark", dark), ("darkByHand", byHand),
                ("layers", .number(Double(uses[s.id] ?? 0))), ("made", isMade),
            ]
            return .compact(pairs)
        }
        let found = store.doc.foundLooks()
        let unnamed = StyleKind.allCases.flatMap { kind in (found[kind] ?? []).prefix(6).map { (kind, $0) } }.map { kind, f -> JSONValue in
            .compact([("kind", .string(kind.rawValue)), ("look", Self.describe(f.look)), ("layers", .number(f.count)),
                      ("example", f.uses.first.map { .string($0.layer.uuidString) })])
        }
        let dark = store.doc.nodes.filter(\.showsDark).map { JSONValue.string($0.name) }
        return [.text(JSONValue.compact([
            ("styles", .array(styles)),
            ("darkArtboards", dark.isEmpty ? nil : .array(dark)),
            ("unnamedLooksSharedByLayers", unnamed.isEmpty ? nil : .array(unnamed)),
            ("note", .string("A style is a look with a name, the same on every layer that uses it: changing it here, or changing that look on any layer that uses it (update_layers), changes it on all of them. name (with layer, place, and all_alike to name every layer that looks the same too) makes one. On a dark artboard (appearance) every style shows its dark look: made dark by itself until set with dark_color or changed on a layer there.")),
        ]).text)]
    }

    static func describe(_ look: StyleLook) -> JSONValue {
        switch look {
        case .colour(let p):
            return .compact([("color", .string(hex(p.color))), ("gradient", p.gradient != nil ? true : nil)])
        case .text(let t):
            return .compact([("family", .string(Fonts.displayName(t.family))), ("face", .string(t.face)), ("size", .number(t.size)),
                             ("lineSpacing", t.lineSpacing.map { .number($0) }), ("letterSpacing", t.tracking != 0 ? .number(t.tracking) : nil),
                             ("case", t.letterCase.map { .string($0.rawValue) })])
        case .shadow(let s):
            return .compact([("x", .number(s.x)), ("y", .number(s.y)), ("blur", .number(s.blur)), ("spread", s.spread.map { .number($0) }),
                             ("color", .string(hex(s.color))), ("inset", s.inset == true ? true : nil)])
        case .corners(let c):
            return .compact([("radius", .number(c.radius)), ("smoothing", c.smoothing.map { .number($0) })])
        }
    }

    /// The styles a layer uses, by where, for describing it.
    static func styleDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        let dark: [(String, JSONValue?)] = node.showsDark ? [("dark", true)] : []
        let named = StylePlace.all(in: node).compactMap { place -> (String, JSONValue)? in
            guard let id = place.named(in: node), let s = doc.style(id) else { return nil }
            let key: String
            switch place {
            case .fill(let i): key = i == 0 ? "fill" : "fill \(i + 1)"
            case .border(let i): key = i == 0 ? "border" : "border \(i + 1)"
            case .shadow(let i): key = i == 0 ? "shadow" : "shadow \(i + 1)"
            case .text: key = "text"
            case .corners: key = "corners"
            }
            return (key, .string(s.name))
        }
        return dark + (named.isEmpty ? [] : [("styles", .object(named))])
    }
}
