import Foundation

// A shared design in the browser, as the Mac's CloudSync and Collaboration keep one: the state
// all copies merge (`SharedDesign`), made from the zone's snapshot and change records, and the
// design shown made from it. What is changed here goes back as a change record of this browser's
// own, packed as the Mac packs them: JSON, then LZFSE. Only the model's code decides anything:
// `merge`, `absorb`, `changes(by:after:)`, `flatDesign()`.

nonisolated enum WebSharing {
    nonisolated(unsafe) static var state = SharedDesign()
    /// The design as last shown or taken in: what an edit is measured from.
    nonisolated(unsafe) static var base = FlatDesign(BezzleDocument())
    /// This browser's name among the copies, kept by the page.
    nonisolated(unsafe) static var replica = ""
    /// The latest time this browser's changes have been sent up to.
    nonisolated(unsafe) static var sentUpTo: Int64 = 0

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// A record's design: its packed data, unpacked as `CloudSync.design(in:)` does.
    static func unpack(_ packed: Data) -> SharedDesign? {
        do {
            let data = try (packed as NSData).decompressed(using: .lzfse) as Data
            do {
                return try JSONDecoder().decode(SharedDesign.self, from: data)
            } catch {
                Host.log("A shared record could not be read: \(error)")
            }
        } catch {
            Host.log("A shared record could not be unpacked (\(packed.count) bytes): \(error)")
        }
        return nil
    }

    static func pack(_ design: SharedDesign) -> Data? {
        guard let data = try? JSONEncoder().encode(design) else { return nil }
        return try? (data as NSData).compressed(using: .lzfse) as Data
    }

    /// Starts from the zone's records, snapshot and changes in any order: merging is the same either way.
    static func open(_ records: [Data], replica: String) -> (BezzleDocument, unread: Int) {
        self.replica = replica
        state = SharedDesign()
        var unread = 0
        for packed in records {
            if let d = unpack(packed) { state.merge(d) } else { unread += 1 }
        }
        let doc = state.flatDesign().document()
        base = FlatDesign(doc)
        sentUpTo = state.clock.time
        return (doc, unread)
    }

    /// Takes in others' change records; answers the design as it is now.
    static func receive(_ records: [Data], into shown: BezzleDocument) -> BezzleDocument {
        // What was done here first, so it is kept as it is.
        _ = state.absorb(FlatDesign(shown), since: base, by: replica, at: now)
        for packed in records { if let d = unpack(packed) { state.merge(d) } }
        var doc = state.flatDesign().document()
        doc.viewport = shown.viewport
        base = FlatDesign(doc)
        return doc
    }

    /// What was changed here since it was last sent, packed for a change record; nil for nothing.
    static func changes(in shown: BezzleDocument) -> Data? {
        if state.absorb(FlatDesign(shown), since: base, by: replica, at: now) { base = FlatDesign(shown) }
        let mine = state.changes(by: replica, after: sentUpTo)
        guard !mine.isEmpty, let packed = pack(mine) else { return nil }
        sentUpTo = state.clock.time
        return packed
    }

    /// A design as its owner's Mac first puts it in a zone: all of it, as one snapshot.
    static func snapshot(of doc: BezzleDocument, by replica: String) -> Data? {
        var s = SharedDesign()
        _ = s.absorb(FlatDesign(doc), since: FlatDesign(BezzleDocument()), by: replica, at: now)
        return pack(s)
    }
}
