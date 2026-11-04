import Foundation

/// Components for the assistant: making one, placing copies of it, showing a copy as one of its
/// variants, keeping something in one copy alone, and unlinking. See `Instance`.
extension MCPTools {
    func componentDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        func list(_ d: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
        let layers = ("layers", list("Layers by id, or by name (\"Artboard/Name\" when the name is on several). Leave it out for the selection."))
        let component = ("component", text("The component, by id or name (see list_components); a copy of it, by id or name, names it too."))
        return [
            Definition(name: "list_components", title: "List components",
                       description: "Lists the design's components: each one's id and name, its variants, and its copies on the canvas (id, artboard, which variant). A component is designed once and used in many places: every copy is a group on the canvas, and a change to the look or the layers of any copy, made with update_layers or any other tool, is made in every copy of it at once. Each copy's words and pictures are its own, and so are where it lies, its size (what spans it stretches, what sits at an edge stays there), its rotation and flips. Kit parts added with add_resource are components: the same part added again is another copy.",
                       properties: .object([design]), readOnly: true, run: { [unowned self] in try await self.listComponents($0) }),
            Definition(name: "make_component", title: "Make a component",
                       description: "Makes layers a component: one group as it is, or several layers grouped first. They are its first copy; duplicate_layers or add_copy makes more. With link_look_alikes, other groups in the design that look the same (the same layers and looks, whatever their words, pictures, place and size) become copies of it too.",
                       properties: .object([
                           design, layers,
                           ("name", text("What it is called; the group's name otherwise.")),
                           ("link_look_alikes", boolean("Also make groups that look the same copies of it.")),
                       ]), run: { [unowned self] in try await self.makeComponent($0) }),
            Definition(name: "add_copy", title: "Add a copy of a component",
                       description: "Puts a new copy of a component onto an artboard, with the component's words, and selects it.",
                       properties: .object([
                           design, component,
                           ("artboard", text("The artboard, by id or name; the one in view otherwise.")),
                           ("x", number("Where its left edge goes, from the artboard's left; its middle otherwise.")),
                           ("y", number("Where its top edge goes, from the artboard's top.")),
                           ("width", number("How wide; as wide as the component otherwise. What spans it stretches.")),
                           ("height", number("How tall.")),
                           ("variant", text("Which variant, by name; the first otherwise.")),
                       ]), required: ["component"], run: { [unowned self] in try await self.addCopy($0) }),
            Definition(name: "set_variant", title: "Show a variant",
                       description: "Shows copies as one of their component's variants, keeping their words and pictures.",
                       properties: .object([design, ("layers", list("The copies, or layers in them. Leave it out for the selection.")),
                                            ("variant", text("The variant's name, as list_components gives it."))]),
                       required: ["variant"], run: { [unowned self] in try await self.setVariant($0) }),
            Definition(name: "add_variant", title: "Add a variant",
                       description: "Adds a variant to a copy's component, as the copy looks now, and shows it in that copy. What is changed first in a copy of a new variant is the variant's own; after that, what a variant keeps of its own (what it differs in) changes in its copies alone, and anything else changes in every variant.",
                       properties: .object([design, ("layer", text("The copy, or a layer in it. The selection otherwise.")),
                                            ("name", text("What the variant is called."))]),
                       run: { [unowned self] in try await self.addVariant($0) }),
            Definition(name: "update_component", title: "Rename a component or its variants",
                       description: "Renames a component, renames one of its variants, or takes a variant away (its copies show the first).",
                       properties: .object([
                           design, component,
                           ("name", text("The component's new name.")),
                           ("variant", text("A variant, by name, to rename or remove.")),
                           ("variant_name", text("The variant's new name.")),
                           ("remove_variant", boolean("Take the variant away.")),
                       ]), required: ["component"], run: { [unowned self] in try await self.updateComponent($0) }),
            Definition(name: "keep_in_copy", title: "Keep in this copy",
                       description: "Makes properties of layers in a copy that copy's own, so that changing them later changes this copy alone, and the component's changes to them no longer reach it; or, with follow, lets them follow the component again. Properties as update_layers names them: fill, border, shadow, opacity, cornerRadius, frame, rotation, hidden, style, blur, name.",
                       properties: .object([
                           design, layers,
                           ("properties", list("The properties to keep.")),
                           ("follow", boolean("Let the layers follow the component again in everything they keep, or in properties.")),
                       ]), run: { [unowned self] in try await self.keepInCopy($0) }),
            Definition(name: "unlink_copies", title: "Unlink copies",
                       description: "Makes copies of a component groups like any other, looking as they do, no longer changed with the component.",
                       properties: .object([design, ("layers", list("The copies, or layers in them. Leave it out for the selection."))]),
                       run: { [unowned self] in try await self.unlinkCopies($0) }),
            Definition(name: "delete_component", title: "Delete a component",
                       description: "Takes a component out of the design; its copies stay, as groups like any other.",
                       properties: .object([design, component]), required: ["component"], destructive: true,
                       run: { [unowned self] in try await self.deleteComponent($0) }),
        ]
    }

    /// A component by its id or name, or by a copy of it.
    static func component(_ ref: String, in doc: BezzleDocument) throws -> Node {
        if let id = UUID(uuidString: ref), let m = doc.master(id) { return m }
        if let m = doc.masters.first(where: { $0.name == ref }) ?? doc.masters.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return m }
        if let id = try? layer(ref, in: doc), let c = doc.copy(holding: id), let m = c.instance.flatMap({ doc.master($0.of) }) { return m }
        let names = doc.masters.map(\.name)
        throw MCPError(names.isEmpty ? "The design has no components. make_component makes one." : "There is no component \"\(ref)\": \(names.joined(separator: ", ")).")
    }

    /// A variant of a component by its name, or its place among them counted from 1.
    static func variant(_ ref: String, of master: Node) throws -> Int? {
        let all = Components.variants(of: master)
        if let v = all.first(where: { Components.name(of: $0, in: master).caseInsensitiveCompare(ref) == .orderedSame }) { return v }
        if let i = Int(ref), i >= 1, i <= all.count { return all[i - 1] }
        throw MCPError("\(master.name) has no variant \"\(ref)\": \(all.map { Components.name(of: $0, in: master) }.joined(separator: ", ")).")
    }

    /// What a copy is a copy of, for describing it.
    static func copyDetails(_ node: Node, in doc: BezzleDocument) -> [(String, JSONValue?)] {
        guard let inst = node.instance, let master = doc.master(inst.of) else { return [] }
        return [("component", .string(master.name)),
                ("variant", Components.variants(of: master).count > 1 ? .string(Components.name(of: inst.variant, in: master)) : nil)]
    }

    func listComponents(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc
        let list: [JSONValue] = doc.masters.map { m in
            let mine = store.copiesInOrder(of: m.id).compactMap { doc.node($0) }
            return .compact([
                ("id", .string(m.id.uuidString)),
                ("name", .string(m.name)),
                ("width", .number(round(Components.box(of: m, variant: nil).width))),
                ("height", .number(round(Components.box(of: m, variant: nil).height))),
                ("part", m.master?.part.map { .string($0) }),
                ("variants", .array(Components.variants(of: m).map { .string(Components.name(of: $0, in: m)) })),
                ("copies", .array(mine.map { c in
                    .compact([("id", .string(c.id.uuidString)), ("name", .string(c.name)),
                              ("artboard", doc.artboard(of: c.id).map { .string($0.name) }),
                              ("variant", Components.variants(of: m).count > 1 ? .string(Components.name(of: c.instance?.variant, in: m)) : nil)])
                })),
            ])
        }
        return [.text(JSONValue.object([("components", .array(list))]).text)]
    }

    func makeComponent(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        guard ids.allSatisfy({ !doc.insideCopy($0) }), ids.count > 1 || doc.node(ids[0])?.isCopy == false else {
            throw MCPError("That is a copy of a component already, or lies in one. Several layers, copies among them, make a component that holds those copies.")
        }
        guard ids.allSatisfy({ doc.node($0)?.isArtboard == false }) else { throw MCPError("An artboard cannot be a component; make one of the layers on it.") }
        guard DocumentStore.groupable(ids, in: doc) != nil else {
            throw MCPError("Make a component of layers on the same artboard, or all on the canvas, and not in a repeat grid.")
        }
        let name = try args.string("name")
        var made: UUID?
        try change(store, "Make Component") { doc in made = DocumentStore.makeComponent(from: ids, in: &doc, name: name) }
        guard let made else { throw MCPError("Nothing could be made a component there.") }
        var linked: [UUID] = []
        if try args.bool("link_look_alikes") == true, let inst = store.doc.node(made)?.instance {
            let found = DocumentStore.lookAlikes(of: made, in: store.doc)
            if !found.isEmpty {
                try change(store, "Link to Component") { doc in
                    for id in found { if let c = DocumentStore.link(id, to: inst.of, in: &doc) { linked.append(c) } }
                }
            }
        }
        store.selection = [made]
        let found = linked.isEmpty ? DocumentStore.lookAlikes(of: made, in: store.doc).count : 0
        return described([made] + linked, in: store, depth: 1,
                         warnings: found > 0 ? ["\(found) more groups look the same as it; make_component with link_look_alikes, on a new component, or delete and make again, links them."] : [])
    }

    func addCopy(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard !store.isReadOnly else { throw MCPError("This design can only be looked at.") }
        let master = try Self.component(try args.string("component") ?? "", in: store.doc)
        let v = try args.string("variant").map { try Self.variant($0, of: master) } ?? nil
        var boardID: UUID?
        if let ref = try args.string("artboard") {
            let id = try Self.layer(ref, in: store.doc)
            guard store.doc.node(id)?.isArtboard == true else { throw MCPError("\(ref) is not an artboard.") }
            boardID = id
        }
        let board = boardID.flatMap { store.doc.node($0) } ?? store.focusedArtboard
        let natural = Components.box(of: master, variant: v).size
        let size = CGSize(width: try args.number("width").map { CGFloat(max(1, $0)) } ?? natural.width,
                          height: try args.number("height").map { CGFloat(max(1, $0)) } ?? natural.height)
        let origin: CGPoint = try {
            let o = board?.frame.origin ?? .zero
            if let x = try args.number("x"), let y = try args.number("y") { return CGPoint(x: o.x + x, y: o.y + y) }
            let c = board?.frame.center ?? store.visibleCanvasRect.center
            return CGPoint(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded())
        }()
        let copy = Components.newCopy(of: master, variant: v, at: origin, size: size)
        try change(store, "Add Component") { doc in doc.attach(copy, to: board?.id) }
        store.selection = [copy.id]
        return described([copy.id], in: store, depth: 1)
    }

    private func copies(_ args: Arguments, in store: DocumentStore, key: String = "layers") throws -> [Node] {
        let ids: [UUID]
        if let one = try args.string("layer"), key == "layer" { ids = [try Self.layer(one, in: store.doc)] } else { ids = try Self.layers(args, in: store) }
        var seen = Set<UUID>(), out: [Node] = []
        for id in ids {
            guard let c = store.doc.copy(holding: id) else { throw MCPError("\(store.doc.node(id)?.name ?? id.uuidString) is no copy of a component, nor in one.") }
            if seen.insert(c.id).inserted { out.append(c) }
        }
        return out
    }

    func setVariant(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let copies = try copies(args, in: store)
        guard let ref = try args.string("variant") else { throw MCPError("Say which variant.") }
        var done: [UUID] = []
        try change(store, "Change Variant") { doc in
            for c in copies {
                guard let master = c.instance.flatMap({ doc.master($0.of) }) else { continue }
                let v = try Self.variant(ref, of: master)
                doc.update(c.id) { $0 = Components.switched($0, to: v, in: master) }
                done.append(c.id)
            }
        }
        return described(done, in: store, depth: 1)
    }

    func addVariant(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let copy = try copies(args, in: store, key: "layer").first, let inst = copy.instance,
              var master = store.doc.master(inst.of) else { throw MCPError("Say which copy.") }
        let name = try args.string("name")
        var made: Int?
        try change(store, "New Variant") { doc in
            let shown = Components.plan(copy, master: master)?.to
            guard let n = Components.addVariant(from: copy, keeping: [:], named: name, to: &master),
                  let i = doc.masters.firstIndex(where: { $0.id == master.id }) else { return }
            made = n
            doc.masters[i] = master
            doc.update(copy.id) { c in
                if let shown { c = Components.showing(c, variant: n, of: master, at: shown) } else { c.instance?.variant = n }
                c = Node.forgettingOwnLooks(c)
            }
        }
        guard made != nil else { throw MCPError("No variant could be made of it.") }
        return described([copy.id], in: store, depth: 1)
    }

    func updateComponent(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let master = try Self.component(try args.string("component") ?? "", in: store.doc)
        if let name = try args.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            try change(store, "Rename Component") { doc in DocumentStore.renameComponent(master.id, to: name, in: &doc) }
        }
        if let ref = try args.string("variant") {
            let v = try Self.variant(ref, of: master)
            if try args.bool("remove_variant") == true {
                guard let v else { throw MCPError("The first variant is the component itself; it cannot be taken away.") }
                try change(store, "Delete Variant") { doc in DocumentStore.removeVariant(v, of: master.id, in: &doc) }
            } else if let name = try args.string("variant_name") {
                try change(store, "Rename Variant") { doc in DocumentStore.renameVariant(v, of: master.id, to: name, in: &doc) }
            }
        }
        return try await listComponents(args)
    }

    func keepInCopy(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        let doc = store.doc
        guard ids.allSatisfy({ id in doc.copy(holding: id).map { $0.id != id } == true }) else {
            throw MCPError("Give layers inside copies of a component, not the copies themselves.")
        }
        let names = try args.strings("properties") ?? []
        let known = Components.keepable
        let unknown = names.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw MCPError("\(unknown.joined(separator: ", ")) cannot be kept: \(known.sorted().joined(separator: ", ")).") }
        if try args.bool("follow") == true {
            try change(store, "Follow Component") { doc in
                for id in ids {
                    doc.update(id) { n in
                        let left = names.isEmpty ? [] : (n.own ?? []).filter { !names.contains($0) }
                        n.own = left.isEmpty ? nil : left
                    }
                }
            }
        } else {
            guard !names.isEmpty else { throw MCPError("Say which properties to keep.") }
            try change(store, "Keep in This Copy") { doc in
                for id in ids { doc.update(id) { $0.own = Array(Set($0.own ?? []).union(names)).sorted() } }
            }
        }
        return described(ids, in: store, full: true)
    }

    func unlinkCopies(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let copies = try copies(args, in: store)
        try change(store, copies.count == 1 ? "Unlink Copy" : "Unlink Copies") { doc in
            for c in copies { doc.update(c.id) { $0 = $0.unlinked() } }
        }
        return described(copies.map(\.id), in: store)
    }

    func deleteComponent(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let master = try Self.component(try args.string("component") ?? "", in: store.doc)
        try change(store, "Delete Component") { doc in doc.masters.removeAll { $0.id == master.id } }
        return [.text(JSONValue.object([("deleted", .string(master.name))]).text)]
    }
}
