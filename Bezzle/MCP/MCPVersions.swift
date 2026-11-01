import Foundation

/// A design's versions, for the assistant to list, name and go back to.
extension MCPTools {
    func versions(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let shelf = store.versions
        shelf.load()
        var named: UUID?
        if let name = try args.string("name") {
            shelf.nameNow(name)
            named = shelf.list.last?.id
        }
        if let ref = try args.string("show") {
            if ref.lowercased() == "now" {
                shelf.browse()
                shelf.showNow()
            } else if ref.lowercased() == "none" {
                shelf.leave()
            } else {
                guard let id = UUID(uuidString: ref), shelf.list.contains(where: { $0.id == id }) else {
                    throw MCPError("There is no version \(ref). versions with only design lists them.")
                }
                shelf.browse()
                shelf.show(id)
            }
        }
        if let ref = try args.string("go_back_to") {
            guard let id = UUID(uuidString: ref), shelf.list.contains(where: { $0.id == id }) else {
                throw MCPError("There is no version \(ref). versions with only design lists them.")
            }
            // A step of its own in the undo history, as every change the assistant makes is.
            store.canvas?.endEditing()
            let undo = store.undoManager, byEvent = undo?.groupsByEvent ?? true
            undo?.groupsByEvent = false
            undo?.beginUndoGrouping()
            shelf.restore(id)
            undo?.endUndoGrouping()
            undo?.groupsByEvent = byEvent
        }
        let iso = ISO8601DateFormatter()
        let list: [JSONValue] = shelf.list.reversed().map { v in
            .compact([("id", .string(v.id.uuidString)), ("when", .string(iso.string(from: v.date))),
                      ("name", v.name.map { .string($0) }), ("by", v.by.map { .string($0) }),
                      ("layers", .number(v.layers)), ("shared", v.shared == true ? true : nil)])
        }
        return [.text(JSONValue.compact([
            ("design", .string(store.name)),
            ("named", named.map { .string($0.uuidString) }),
            ("versions", .array(list)),
            ("note", .string("Newest first. Versions are taken by themselves while a design is worked on; named ones are kept for good and, in a shared design, shared with everyone. Going back keeps the design as it was just before as a named version, and leaves its notes as they are.")),
        ]).text)]
    }
}
