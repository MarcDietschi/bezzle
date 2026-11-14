import Foundation

/// The others in a shared design's live room, as the page shows them (site/live.mjs): who is
/// there, each in their own pencil, where their hand is, what they hold, and the loop they draw
/// by shaking their pointer. The page listens to the relay and opens what is sealed
/// (site/share.mjs). What a message says, whose pencil is whose, and where on the design a
/// layer someone holds lies is worked out here, by the Mac's own code (Model/LiveMessages.swift,
/// Model/Perspective.swift), as `LiveRoom` and `LiveMarks` put them together on the Mac.
///
/// The viewer only watches. It never says who it is (`LiveHello`), so nobody in the room is
/// shown it: no pencil is handed to it, and it stands in nobody's list of people.
///
/// Only here, in the browser's core: Bezzle for Windows has its own room (Host/LiveTogether.swift).
enum WebLive {
    /// Who said who they are, by their place in the room, which the relay gives.
    private static var hellos: [UInt32: LiveHello] = [:]
    /// The order they came in.
    private static var came: [UInt32] = []
    private static var presence: [UInt32: LivePresence] = [:]
    private static var pencils: [String: Pencil] = [:]
    /// What each holds, outlined, worked out again only as that or the design changes.
    private static var held: [UInt32: (selection: [UUID], design: Int, json: String)] = [:]
    /// Counts the designs shown, for `held`.
    private static var design = 0
    private static var winks: UInt64 = 0

    /// Nobody is there: the room was left, or its connection lost.
    static func clear() {
        hellos = [:]
        came = []
        presence = [:]
        pencils = [:]
        held = [:]
    }

    /// The design shows something else: what people hold lies elsewhere.
    static func designChanged() { design += 1 }

    /// Someone left.
    static func left(_ peer: UInt32) {
        presence[peer] = nil
        held[peer] = nil
        guard hellos.removeValue(forKey: peer) != nil else { return }
        came.removeAll { $0 == peer }
        handOutPencils()
    }

    /// Everyone has the pencil every Mac in the room hands them: a Mac hands them out among
    /// those who said hello and itself, which are the same people.
    private static func handOutPencils() {
        pencils = Pencil.hand(to: Set(hellos.values.map(\.replica)))
    }

    /// Takes a message as it travelled, its seal opened (`LiveMessage.packed`), from someone in
    /// the room. Answers what it was, as the page reads it: `hello` (people come and pencils may
    /// change hands: ask for `people`), `presence` with that person as they are now, `wink` with
    /// its loop, or `other` for what a viewer does not show.
    static func take(_ plain: Data, from peer: UInt32, in doc: BezzleDocument?) -> String {
        guard let message = LiveMessage(packed: plain) else { return "{\"kind\":\"unread\"}" }
        switch message {
        case .hello(let hello):
            // The same copy come back on a new connection: its old place goes.
            for (other, h) in hellos where other != peer && h.replica == hello.replica { left(other) }
            if hellos[peer] == nil { came.append(peer) }
            hellos[peer] = hello
            handOutPencils()
            return "{\"kind\":\"hello\"}"
        case .presence(let p):
            presence[peer] = p
            guard let person = person(peer, in: doc) else { return "{\"kind\":\"other\"}" }
            return "{\"kind\":\"presence\",\"person\":\(person)}"
        case .wink(let at):
            guard let hello = hellos[peer] else { return "{\"kind\":\"other\"}" }
            winks &+= 1
            let seed = UInt64(Date().timeIntervalSince1970 * 1000) &+ winks
            let points = PencilLoop.points(seed: seed, radius: 30)
            let widths = points.indices.map { PencilLoop.width(at: Double($0) / Double(max(points.count - 1, 1)), 2.6) }
            // How far it is drawn and how strong it shows, sixty times a second, for as long as it lasts.
            let steps = Int((PencilLoop.lasts * 60).rounded(.up))
            let shown = (0...steps).map { PencilLoop.shown(at: Double($0) / 60) }
            return "{\"kind\":\"wink\",\"peer\":\(peer),\"color\":\(color(of: hello.replica)),\"at\":[\(at.x),\(at.y)],\"board\":\(board(at: at, in: doc)),"
                + "\"points\":\(numbers(points.flatMap { [Double($0.x), Double($0.y)] })),\"widths\":\(numbers(widths.map { Double($0) })),"
                + "\"drawn\":\(numbers(shown.map(\.drawn))),\"alpha\":\(numbers(shown.map(\.alpha)))}"
        case .changes(let changes):
            // What someone changed, as they change it: the page takes it in as it takes records.
            guard let packed = WebSharing.pack(changes) else { return "{\"kind\":\"other\"}" }
            return "{\"kind\":\"changes\",\"record\":\"\(packed.base64EncodedString())\"}"
        case .motion, .settle, .glimpses, .want, .version:
            return "{\"kind\":\"other\"}"
        }
    }

    /// Everyone who said who they are, in the order they came.
    static func people(in doc: BezzleDocument?) -> String {
        "[" + came.compactMap { person($0, in: doc) }.joined(separator: ",") + "]"
    }

    // MARK: A person

    private static func color(of replica: String) -> String {
        let rgb = (pencils[replica] ?? Pencil.preferred(replica)).rgb
        return "[\(rgb.r),\(rgb.g),\(rgb.b)]"
    }

    /// Someone as the page shows them; nil for one who has not said who they are.
    private static func person(_ peer: UInt32, in doc: BezzleDocument?) -> String? {
        guard let hello = hellos[peer] else { return nil }
        let initial = hello.name.first.map { String($0).uppercased() } ?? "•"
        var s = "{\"peer\":\(peer),\"name\":\(quoted(hello.name)),\"initial\":\(quoted(initial)),\"color\":\(color(of: hello.replica))"
        if let zone = hello.timeZone { s += ",\"timeZone\":\(quoted(zone))" }
        guard let p = presence[peer] else { return s + "}" }
        s += ",\"doing\":\"\(p.doing.rawValue)\",\"away\":\(p.away),\"tool\":\(quoted(p.doing == .typing ? "text" : p.tool))"
        if let at = p.pointer { s += ",\"pointer\":[\(at.x),\(at.y)],\"board\":\(board(at: at, in: doc))" }
        s += ",\"view\":[\(p.view.minX),\(p.view.minY),\(p.view.width),\(p.view.height)],\"looksAt\":\(board(most: p.view, in: doc))"
        return s + ",\"holds\":\(holds(peer, p.selection, in: doc))}"
    }

    /// The artboard a point of the canvas lies on, by its place among the design's layers; −1 for none.
    private static func board(at p: CGPoint, in doc: BezzleDocument?) -> Int {
        guard let doc else { return -1 }
        // The one in front where two overlap, as the canvas has it.
        return doc.nodes.indices.last { doc.nodes[$0].isArtboard && doc.nodes[$0].frame.contains(p) } ?? -1
    }

    /// The artboard most of a view shows; −1 when it shows none.
    private static func board(most view: CGRect, in doc: BezzleDocument?) -> Int {
        guard let doc else { return -1 }
        var best = -1, most: CGFloat = 0
        for (i, node) in doc.nodes.enumerated() where node.isArtboard {
            let seen = node.frame.intersection(view)
            let area = seen.isNull ? 0 : seen.width * seen.height
            if area > most { (best, most) = (i, area) }
        }
        return best
    }

    /// What someone holds, each layer outlined as it shows on the canvas, with the artboard it is
    /// on: as `LiveMarks` outlines it on the Mac.
    private static func holds(_ peer: UInt32, _ selection: [UUID], in doc: BezzleDocument?) -> String {
        guard let doc, !selection.isEmpty else { return "[]" }
        if let known = held[peer], known.selection == selection, known.design == design { return known.json }
        let outlines = selection.compactMap { id -> String? in
            guard let node = doc.node(id) else { return nil }
            let eye = doc.eye(forParentOf: id)
            let points: [CGPoint]
            if node.kind == .line {
                let (a, b) = node.lineEnds
                let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
                points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node, eye: eye) }
            } else {
                points = Perspective.corners(of: node, eye: eye)
            }
            let top = doc.ancestors(of: id).first ?? node
            let board = top.isArtboard ? (doc.nodes.firstIndex { $0.id == top.id } ?? -1) : -1
            let shown = points.map { doc.shown($0, inParentOf: id) }
            return "{\"board\":\(board),\"points\":\(numbers(shown.flatMap { [Double($0.x), Double($0.y)] }))}"
        }
        let json = "[" + outlines.joined(separator: ",") + "]"
        held[peer] = (selection, design, json)
        return json
    }

    // MARK: Tests

    /// For testing without a Mac in the room (tools/live.mjs). `{"changes":true}`: what was changed
    /// here since it was last sent, both as a Mac says it in the room (`plain`, a packed
    /// `LiveMessage`) and as the record it then writes (`data`, up to `upTo`). `{"pencils":[…]}`:
    /// the pencil each of these copies is handed. `{"loop":"<seed>"}`: the loop a pencil draws.
    static func test(_ json: Data, in doc: BezzleDocument?) -> String {
        let asked = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        if asked["changes"] != nil {
            guard let doc, let packed = WebSharing.changes(in: doc), let changes = WebSharing.unpack(packed),
                  let plain = LiveMessage.changes(changes).packed() else { return "{}" }
            return "{\"plain\":\"\(plain.base64EncodedString())\",\"data\":\"\(packed.base64EncodedString())\",\"upTo\":\(WebSharing.sentUpTo)}"
        }
        if let replicas = asked["pencils"] as? [String] {
            let hand = Pencil.hand(to: Set(replicas))
            return "{" + hand.keys.sorted().map { "\(quoted($0)):[\(hand[$0]!.rgb.r),\(hand[$0]!.rgb.g),\(hand[$0]!.rgb.b)]" }.joined(separator: ",") + "}"
        }
        if let seed = (asked["loop"] as? String).flatMap({ UInt64($0) }) {
            let points = PencilLoop.points(seed: seed, radius: 30)
            let widths = points.indices.map { PencilLoop.width(at: Double($0) / Double(max(points.count - 1, 1)), 2.6) }
            return "{\"points\":\(numbers(points.flatMap { [Double($0.x), Double($0.y)] })),\"widths\":\(numbers(widths.map { Double($0) }))}"
        }
        return "{}"
    }

    private static func numbers(_ values: [Double]) -> String {
        "[" + values.map { $0.isFinite ? "\($0)" : "0" }.joined(separator: ",") + "]"
    }

    private static func quoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
