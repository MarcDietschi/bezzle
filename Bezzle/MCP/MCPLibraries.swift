import Foundation

/// Other designs as libraries, for the assistant: what they hold of their own, taking a component
/// or a style from one, and bringing what was taken up to date. See `LibraryLink`.
extension MCPTools {
    func libraryDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        return [
            Definition(name: "libraries", title: "Take components and styles from other designs",
                       description: "Every design is a library for every other, with nothing to set up: its components and styles can be taken into another design, which then has them as its own (changed there as any of its own) and remembers where they came from. Layers pasted from another design bring theirs the same way. With nothing but design: the other designs on the home screen that have components or styles of their own, and what this design took from others, each with whether it changed there since. take, with from, brings in a component (as a new copy on artboard, at x and y or in its middle) or a style (into the design's styles, given to layers if they are named). update brings everything taken that changed there since up to date (only what came from from, if given): every copy and every layer using it follows. Nothing ever changes the other design.",
                       properties: .object([
                           design,
                           ("from", text("The other design, by name.")),
                           ("take", text("A component or a style of from, by id or name.")),
                           ("artboard", text("With a component: the artboard to put the copy on, by id or name; the one in view otherwise.")),
                           ("x", number("With a component: where its left edge goes, from the artboard's left.")),
                           ("y", number("With a component: where its top edge goes, from the artboard's top.")),
                           ("layers", ["type": "array", "items": ["type": "string"], "description": "With a style: layers to give it to, by id or name."]),
                           ("update", boolean("Brings what was taken and changed there since up to date.")),
                       ]), run: { [unowned self] in try await self.libraries($0) }),
        ]
    }

    func libraries(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        // What is open elsewhere is read as it is now.
        for other in Self.stores where other !== store { other.save() }
        DocumentStore.finishSaving()
        let shelf = LibraryShelf.shared
        await shelf.refreshed(except: store.url)
        let others = shelf.designs.filter { !LibraryShelf.same($0.url, store.url) }
        let from = try args.string("from")?.trimmingCharacters(in: .whitespaces)
        var chosen = others.filter(\.isLibrary)
        if let from, !from.isEmpty {
            chosen = chosen.filter { $0.name.caseInsensitiveCompare(from) == .orderedSame }
            guard !chosen.isEmpty else {
                let names = others.filter(\.isLibrary).map(\.name)
                throw MCPError("No design called \(from) has components or styles of its own.\(names.isEmpty ? "" : " These do: \(names.joined(separator: ", ")).")")
            }
        }

        if let ref = try args.string("take")?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            return try await take(ref, from: chosen, into: store, args)
        }
        if try args.bool("update") == true {
            var news = store.doc.libraryNews(in: others)
            if from != nil { news = news.filter { n in chosen.contains { $0.url == n.url } } }
            guard !news.isEmpty else { return [.text("Nothing taken from \(from ?? "other designs") has changed there since.")] }
            for n in news { if let lib = others.first(where: { $0.url == n.url }) { store.bringPictures(lib.taking(n.masters)) } }
            try change(store, "Update from Library") { doc in
                for n in news {
                    guard let lib = others.first(where: { $0.url == n.url }) else { continue }
                    doc.update(from: lib, masters: n.masters, styles: n.styles)
                }
            }
            let names = news.map { n in "\(n.count) from \(n.name)" }.joined(separator: ", ")
            return [.text("Brought up to date: \(names).")] + listing(store, others: others, libraries: chosen)
        }
        return listing(store, others: others, libraries: chosen)
    }

    private func listing(_ store: DocumentStore, others: [LibraryContent], libraries: [LibraryContent]) -> [Content] {
        let doc = store.doc
        let libs = libraries.map { lib -> JSONValue in
            let masters = lib.ownMasters.map { m -> JSONValue in
                .object([("id", .string(m.id.uuidString)), ("name", .string(m.name)),
                         ("variants", .number(1 + (m.master?.variants.count ?? 0))), ("taken", .bool(doc.master(m.id) != nil))])
            }
            let styles = lib.ownStyles.map { s -> JSONValue in
                .object([("id", .string(s.id.uuidString)), ("name", .string(s.name)), ("kind", .string(s.kind.rawValue)),
                         ("taken", .bool(doc.style(s.id) != nil))])
            }
            return .object([("design", .string(lib.name)), ("components", .array(masters)), ("styles", .array(styles))])
        }
        let news = doc.libraryNews(in: others)
        let changed = Set(news.flatMap { $0.masters + $0.styles })
        var taken: [JSONValue] = []
        for m in doc.masters {
            guard let link = m.master?.library else { continue }
            taken.append(.object([("kind", "component"), ("id", .string(m.id.uuidString)), ("name", .string(m.name)),
                                  ("from", .string(link.design)), ("changedThere", .bool(changed.contains(m.id)))]))
        }
        for s in doc.styles ?? [] {
            guard let link = s.library else { continue }
            taken.append(.object([("kind", "style"), ("id", .string(s.id.uuidString)), ("name", .string(s.name)),
                                  ("from", .string(link.design)), ("changedThere", .bool(changed.contains(s.id)))]))
        }
        return [.text(JSONValue.object([("libraries", .array(libs)), ("taken", .array(taken))]).text)]
    }

    private func take(_ ref: String, from libraries: [LibraryContent], into store: DocumentStore, _ args: Arguments) async throws -> [Content] {
        let id = UUID(uuidString: ref)
        func fits(_ name: String, _ thing: UUID) -> Bool { thing == id || name.caseInsensitiveCompare(ref) == .orderedSame }
        let masters = libraries.flatMap { lib in lib.ownMasters.filter { fits($0.name, $0.id) }.map { (lib, $0) } }
        let styles = libraries.flatMap { lib in lib.ownStyles.filter { fits($0.name, $0.id) }.map { (lib, $0) } }
        let found = masters.count + styles.count
        guard found > 0 else { throw MCPError("No other design has a component or style \(ref) of its own. libraries lists them.") }
        guard found == 1 else {
            let places = masters.map { "component \($0.1.name) in \($0.0.name) (\($0.1.id.uuidString))" }
                + styles.map { "style \($0.1.name) in \($0.0.name) (\($0.1.id.uuidString))" }
            throw MCPError("\(ref) is more than one: \(places.joined(separator: ", ")). Say which, by id or with from.")
        }

        if let (lib, master) = masters.first {
            var boardID: UUID?
            if let name = try args.string("artboard") {
                let board = try Self.layer(name, in: store.doc)
                guard store.doc.node(board)?.isArtboard == true else { throw MCPError("\(name) is not an artboard.") }
                boardID = board
            }
            guard var plan = store.placing(.library(lib.url, master.id), at: nil, into: boardID) else {
                throw MCPError(store.isReadOnly ? "This design can only be looked at." : "\(master.name) could not be made.")
            }
            let x = try args.number("x").map { CGFloat($0) }, y = try args.number("y").map { CGFloat($0) }
            if x != nil || y != nil {
                let origin = plan.board.flatMap { store.doc.node($0)?.frame.origin } ?? .zero
                if let x { plan.node.frame.origin.x = origin.x + x }
                if let y { plan.node.frame.origin.y = origin.y + y }
            }
            var node = plan.node
            var added = node.id
            let board = plan.board, brings = plan.brings
            if let brings { store.bringPictures(brings) }
            try change(store, "Add Component") { doc in
                if let brings { node = node.renamingStyles(doc.bring(brings)) }
                added = DocumentStore.add(node, part: nil, to: board, in: &doc)
            }
            store.selection = [added]
            return described([added], in: store, depth: 1)
        }

        let (lib, style) = styles[0]
        let targets = args["layers"] == nil ? [] : try Self.layers(args, in: store)
        let take = lib.taking(style: style.id)
        var given = style.id
        try change(store, targets.isEmpty ? "Add Style" : "Use Style") { doc in
            let map = doc.bring(take)
            given = map[style.id] ?? style.id
            guard let s = doc.style(given) else { return }
            for id in targets { doc.update(id) { DocumentStore.give(s, to: &$0, at: nil, dark: false) } }
        }
        let here = store.doc.style(given)
        let note = given != style.id ? " This design has a \(style.kind.rawValue) style called \(style.name) already, which stands in for it." : ""
        return [.text("Style \(here?.name ?? style.name) (\(given.uuidString)) is in the design\(targets.isEmpty ? "" : ", given to \(targets.count) layer\(targets.count == 1 ? "" : "s")").\(note)")]
    }
}
