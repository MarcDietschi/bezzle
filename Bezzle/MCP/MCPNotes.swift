import Foundation

/// Notes in a design's margins, for the assistant to read, write, answer, move, tick off and show.
extension MCPTools {
    func notes(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let (name, replica) = ("Claude", "assistant")
        let now = Date().timeIntervalSince1970
        var made: [UUID] = []

        func area(_ key: String) throws -> CGRect? {
            guard let o = try Read.object(args[key], key) else { return nil }
            guard let x = try Read.number(o["x"], "\(key).x"), let y = try Read.number(o["y"], "\(key).y"),
                  let w = try Read.number(o["width"], "\(key).width"), let h = try Read.number(o["height"], "\(key).height"), w > 0, h > 0 else {
                throw MCPError("\(key) should be {x, y, width, height} on the canvas, with some width and height.")
            }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func thread(_ ref: String?, for key: String) throws -> UUID {
            guard let ref, let id = UUID(uuidString: ref), store.doc.notesByID[id]?.startsThread == true else {
                throw MCPError("\(key) needs thread: the id of the note that starts it. notes with only design lists them.")
            }
            return id
        }

        if let text = try args.string("write") {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError("write needs some words.") }
            var note = MarginNote(text: text, by: name, replica: replica, time: now)
            if let r = try area("area") {
                note.put(around: r, in: store.doc)
            } else if let ref = try args.string("layer") {
                let id = try Self.layer(ref, in: store.doc)
                guard let f = store.doc.absoluteFrame(of: id) else { throw MCPError("\(ref) has no place on the canvas.") }
                let x = min(max(try args.number("x") ?? 0.5, 0), 1), y = min(max(try args.number("y") ?? 0.5, 0), 1)
                note.put(at: CGPoint(x: f.minX + f.width * x, y: f.minY + f.height * y), on: id, in: store.doc)
            } else {
                guard let x = try args.number("x"), let y = try args.number("y") else {
                    throw MCPError("A note is about a layer (layer, with x and y from 0 to 1 across and down it), round a part (area), or at x and y on the canvas.")
                }
                note.put(at: CGPoint(x: x, y: y), on: nil, in: store.doc)
            }
            try change(store, "Write Note") { doc in doc.notes = (doc.notes ?? []) + [note] }
            made.append(note.id)
        }
        if let text = try args.string("answer") {
            let id = try thread(try args.string("thread"), for: "answer")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError("answer needs some words.") }
            let note = MarginNote(thread: id, text: text, by: name, replica: replica, time: now)
            try change(store, "Answer Note") { doc in doc.notes = (doc.notes ?? []) + [note] }
            made.append(note.id)
        }
        if args["move"] != nil || (args["area"] != nil && args["write"] == nil) {
            let id = try thread(try args.string("thread"), for: "move")
            let to = try Read.point(args["move"], "move")
            let around = try area("area")
            try change(store, "Move Note") { doc in
                guard let i = doc.notes?.firstIndex(where: { $0.id == id }) else { return }
                var note = doc.notes![i]
                if let around {
                    note.put(around: around, in: doc)
                } else if let to {
                    if let r = doc.area(of: note) {
                        note.put(around: r.offsetBy(dx: to.x - r.midX, dy: to.y - r.midY), in: doc)
                    } else {
                        let under = doc.allNodes.last { n in !n.isArtboard && doc.absoluteFrame(of: n.id)?.contains(to) == true }?.id
                        note.put(at: to, on: under ?? doc.artboard(at: to)?.id, in: doc)
                    }
                }
                doc.notes?[i] = note
            }
        }
        for (key, done) in [("close", true), ("reopen", false)] {
            guard let refs = try args.strings(key) else { continue }
            let ids = try refs.map { ref -> UUID in
                guard let id = UUID(uuidString: ref), store.doc.notesByID[id]?.startsThread == true else { throw MCPError("\(ref) starts no thread.") }
                return id
            }
            try change(store, done ? "Close Note" : "Open Note Again") { doc in
                for id in ids { if let i = doc.notes?.firstIndex(where: { $0.id == id }) { doc.notes?[i].done = done ? true : nil } }
            }
        }
        if let refs = try args.strings("remove") {
            let ids = Set(refs.compactMap(UUID.init(uuidString:)))
            try change(store, "Delete Note") { doc in
                doc.notes?.removeAll { ids.contains($0.id) || $0.thread.map(ids.contains) == true }
                if doc.notes?.isEmpty == true { doc.notes = nil }
            }
        }
        if let ref = try args.string("show") {
            let id = try thread(ref, for: "show")
            if store.doc.notesByID[id]?.isDone == true { throw MCPError("\(ref) is ticked off; reopen it first.") }
            store.showThread(id)
        }

        let threads: [JSONValue] = store.doc.threads.map { thread in
            func one(_ n: MarginNote) -> JSONValue {
                .compact([("id", .string(n.id.uuidString)), ("by", .string(n.by)), ("text", .string(n.text)),
                          ("written", .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: n.time))))])
            }
            let on = thread.start.on.flatMap { store.doc.node($0) }
            let spot = store.doc.spot(of: thread.start)
            let circled = store.doc.area(of: thread.start)
            return .compact([
                ("id", .string(thread.start.id.uuidString)),
                ("about", on.map { .string("\($0.name) (\($0.id.uuidString))") } ?? .string("the canvas")),
                ("at", spot.map { .compact([("x", .number(Double($0.x))), ("y", .number(Double($0.y)))]) }),
                ("area", circled.map { .compact([("x", .number(Double($0.minX))), ("y", .number(Double($0.minY))),
                                                 ("width", .number(Double($0.width))), ("height", .number(Double($0.height)))]) }),
                ("closed", thread.start.isDone ? true : nil),
                ("open", store.openThread == thread.start.id ? true : nil),
                ("by", .string(thread.start.by)), ("text", .string(thread.start.text)),
                ("written", .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: thread.start.time)))),
                ("answers", thread.replies.isEmpty ? nil : .array(thread.replies.map(one))),
            ])
        }
        return [.text(JSONValue.compact([
            ("design", .string(store.name)),
            ("made", made.isEmpty ? nil : .array(made.map { .string($0.uuidString) })),
            ("threads", .array(threads)),
            ("note", threads.isEmpty ? nil : .string("at and area are on the canvas, where they are now.")),
        ]).text)]
    }
}
