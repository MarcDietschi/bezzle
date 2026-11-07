import AppKit

/// Words for the assistant: styling some letters of a text, finding and replacing words across
/// the design, and checking their spelling. See `TextSpan` and `TextFinder`.
extension MCPTools {
    func styleText(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let ref = try args.string("layer") else { throw MCPError("Give the text layer as layer.") }
        let id = try Self.layer(ref, in: store.doc)
        guard let node = store.doc.node(id), node.kind == .text else { throw MCPError("\(store.doc.node(id)?.name ?? ref) is not a text layer.") }
        let words = node.text ?? ""
        let ns = words as NSString
        var ranges: [NSRange] = []
        if let find = try args.string("find"), !find.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: find, options: [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                ranges.append(r)
                from = NSMaxRange(r)
            }
            guard !ranges.isEmpty else { throw MCPError("\"\(find)\" is not in \(node.name)'s words: \(words.prefix(120))") }
            if let n = try args.int("occurrence") {
                guard n >= 1, n <= ranges.count else { throw MCPError("\"\(find)\" comes \(ranges.count) times in \(node.name); occurrence is 1 to \(ranges.count).") }
                ranges = [ranges[n - 1]]
            }
        } else if let start = try args.int("start") {
            let letters = Array(words)
            let length = try args.int("length") ?? (letters.count - start)
            guard start >= 0, length > 0, start + length <= letters.count else {
                throw MCPError("\(node.name) has \(letters.count) letters: start is 0 to \(max(letters.count - 1, 0)), and start + length at most \(letters.count).")
            }
            let a = String(letters[..<start]).utf16.count, b = String(letters[start..<(start + length)]).utf16.count
            ranges = [NSRange(location: a, length: b)]
        }
        let keys: Set = ["family", "face", "weight", "size", "color", "underline", "strikethrough", "tracking", "list"]
        let given = args.values.filter { keys.contains($0.key) }
        guard !given.isEmpty else { throw MCPError("Say how the letters should look: any of \(keys.sorted().joined(separator: ", ")).") }
        // Tried first, so a wrong font is said before anything changes.
        var probe = TextLook.plain.resolved(over: node.style ?? TextStyle(), color: node.fill.color)
        try Self.restyle(&probe, from: given, key: "style_text")
        try change(store, "Style Text") { doc in
            doc.update(id) { n in
                if ranges.isEmpty {
                    n.restyleLetters(in: nil) { letters in try? Self.restyle(&letters, from: given, key: "style_text") }
                } else {
                    for r in ranges { n.restyleLetters(in: r) { letters in try? Self.restyle(&letters, from: given, key: "style_text") } }
                }
                n.refit()
            }
        }
        return described([id], in: store, full: true)
    }

    func replaceText(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let find = try args.string("find"), !find.isEmpty else { throw MCPError("Give the words to look for as find.") }
        let finder = TextFinder()
        finder.query = find
        finder.matchCase = try args.bool("match_case") ?? false
        finder.wholeWords = try args.bool("whole_words") ?? false
        let matches = try within(args, store).map { scope in finder.matches(in: store.doc).filter { scope.contains($0.layer) } } ?? finder.matches(in: store.doc)
        guard let replacement = try args.string("replace") else {
            return [.text(JSONValue.compact([("found", .number(matches.count)), ("where", .array(place(matches, in: store.doc)))]).text)]
        }
        guard !matches.isEmpty else { return [.text(JSONValue.compact([("replaced", .number(0))]).text)] }
        try change(store, "Replace All") { $0.replace(matches, with: replacement) }
        let layers = Set(matches.map(\.layer))
        return [.text(JSONValue.compact([("replaced", .number(matches.count)), ("layers", .array(layers.compactMap { store.doc.node($0) }.map { .string($0.name) }))]).text)]
    }

    func checkSpelling(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let finder = TextFinder()
        finder.spelling = true
        let scope = try within(args, store)
        let matches = finder.matches(in: store.doc).filter { scope?.contains($0.layer) ?? true }
        var listed: [JSONValue] = []
        for m in matches.prefix(200) {
            guard let node = store.doc.node(m.layer), let words = node.text else { continue }
            let ns = words as NSString
            guard NSMaxRange(m.range) <= ns.length else { continue }
            let guesses = NSSpellChecker.shared.guesses(forWordRange: m.range, in: words, language: finder.language(of: words),
                                                        inSpellDocumentWithTag: finder.spellTag) ?? []
            listed.append(.compact([
                ("word", .string(ns.substring(with: m.range))), ("layer", .string(m.layer.uuidString)), ("name", .string(node.name)),
                ("start", .number(ns.substring(to: m.range.location).count)),
                ("suggestions", .array(guesses.prefix(5).map { .string($0) })),
            ]))
        }
        return [.text(JSONValue.compact([("misspelt", .array(listed)), ("count", .number(matches.count))]).text)]
    }

    /// The layers inside the one `within` names, and it, if one is named.
    private func within(_ args: Arguments, _ store: DocumentStore) throws -> Set<UUID>? {
        guard let ref = try args.string("within") else { return nil }
        let id = try Self.layer(ref, in: store.doc)
        var ids: Set<UUID> = [id]
        func visit(_ n: Node) {
            ids.insert(n.id)
            n.children.forEach(visit)
        }
        store.doc.node(id)?.children.forEach(visit)
        return ids
    }

    /// Where each thing found is: its layer, and the letter it starts at.
    private func place(_ matches: [TextFinder.Match], in doc: BezzleDocument) -> [JSONValue] {
        matches.prefix(200).compactMap { m in
            guard let node = doc.node(m.layer), let words = node.text else { return nil }
            let ns = words as NSString
            guard NSMaxRange(m.range) <= ns.length else { return nil }
            return .compact([("layer", .string(m.layer.uuidString)), ("name", .string(node.name)),
                             ("start", .number(ns.substring(to: m.range.location).count)), ("words", .string(words.count <= 80 ? words : String(words.prefix(77)) + "…"))])
        }
    }
}
