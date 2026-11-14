import Foundation

// From Bezzle/MCP/MCPAnimateLooks.swift, for Windows: the same keys of how a layer looks, set and
// read through the shared model (`Bezzle/Model/LookMotion.swift`).

/// Animate for the assistant, how layers look: a fill's colour or its gradient's colours, a
/// border's colour and width, a rectangle's corners and a shadow, keyed as a layer's properties
/// are (`LookTrack`). The assistant gives a key as how the look is at that moment, a colour or a
/// width, and reads it back so; the film keeps it as a change from the design, as every key is.
extension MCPTools {
    /// The looks a key can be of, as the assistant names them.
    static let lookWords = ["fill", "border", "borderWidth", "corners", "shadow"]

    static let lookHelp = "look is one of \(lookWords.joined(separator: ", ")): a fill's or a border's colour (a gradient's colours, where it is one), a border's width, a rectangle's corners, a shadow."

    /// A key of a look as it was sent: the layer made to look so at a moment.
    struct LookKey {
        var id: UUID
        var look: LookTrack
        var time: Double
        var ease: MotionEase?
        /// Changes the layer, as it looks at that moment, into what the key says.
        var set: (inout Node) -> Void
    }

    /// Which look is meant, in the assistant's word for it.
    private static func lookWord(_ raw: String, _ place: String) throws -> String {
        guard let word = lookWords.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw MCPError("\(place): there is no look \"\(raw)\". \(lookHelp)")
        }
        return word
    }

    /// Which of several fills, borders or shadows, counted from 1 at the bottom; the first otherwise.
    private static func lookSlot(_ spec: [String: Any], _ word: String, _ place: String) throws -> Int {
        guard let n = try Read.number(spec["which"], "\(place).which") else { return 0 }
        guard n >= 1, n == n.rounded(), n < 1000 else { throw MCPError("\(place).which counts fills, borders or shadows from 1, the bottom one.") }
        guard word != "corners" || n == 1 else { throw MCPError("\(place): a rectangle has one set of corners; leave which out.") }
        return Int(n) - 1
    }

    /// The tracks a removal of a look takes: a fill's and a border's both as one colour and as a gradient.
    static func lookTracks(_ spec: [String: Any], _ place: String) throws -> [LookTrack]? {
        guard let raw = try Read.string(spec["look"], "\(place).look") else { return nil }
        let word = try lookWord(raw, place)
        let slot = try lookSlot(spec, word, place)
        switch word {
        case "fill": return [.fill(slot), .fillStops(slot)]
        case "border": return [.border(slot), .borderStops(slot)]
        case "borderWidth": return [.borderWidth(slot)]
        case "corners": return [.corners]
        default: return [.shadow(slot)]
        }
    }

    /// Reads a key of a look for a layer as designed, `n`: nil when the key names no look. What
    /// is wrong with it is said with what the layer has.
    static func lookKey(_ spec: [String: Any], on n: Node, time: Double, ease: MotionEase?, _ place: String) throws -> LookKey? {
        guard let raw = try Read.string(spec["look"], "\(place).look") else { return nil }
        let word = try lookWord(raw, place)
        let slot = try lookSlot(spec, word, place)
        let value = spec["value"], at = "\(place).value"
        let nth = slot == 0 ? "" : " \(slot + 1)"
        func number(_ raw: Any?, _ key: String) throws -> CGFloat {
            guard let v = try Read.number(raw, key), v.isFinite else { throw MCPError("\(key) should be a number.") }
            return CGFloat(v)
        }
        /// A gradient's colours at that moment: one for each the design has, a colour, or {color, offset}.
        func stops(_ design: [GradientStop], _ what: String) throws -> [(color: RGBA?, offset: Double?)] {
            guard let list = value as? [Any], list.count == design.count else {
                let has = design.map { hex($0.color) }.joined(separator: ", ")
                throw MCPError("\(at): \(n.name)'s \(what)\(nth) is a gradient of \(design.count) colours (\(has)), and a key changes them and where they lie: give as many, each a colour or {color, offset}.")
            }
            return try list.enumerated().map { i, item in
                if let o = item as? [String: Any] {
                    guard Set(o.keys).isSubset(of: ["color", "offset"]) else { throw MCPError("\(at)[\(i)] takes color and offset.") }
                    let offset = try Read.number(o["offset"], "\(at)[\(i)].offset")
                    if let offset, !(0...1).contains(offset) { throw MCPError("\(at)[\(i)].offset goes from 0 to 1 along the gradient.") }
                    return (try o["color"].map { try color($0, "\(at)[\(i)].color") }, offset)
                }
                return (try color(item, "\(at)[\(i)]"), nil)
            }
        }
        func moved(_ design: [GradientStop], by given: [(color: RGBA?, offset: Double?)], _ now: [GradientStop]?) -> [GradientStop] {
            let now = now?.count == design.count ? now ?? design : design
            return zip(now, given).map { stop, to in GradientStop(offset: to.offset ?? stop.offset, color: to.color ?? stop.color) }
        }
        switch word {
        case "fill":
            if n.lookCount(.fill(slot)) != nil {
                let c = try color(value, at)
                return LookKey(id: n.id, look: .fill(slot), time: time, ease: ease) { $0[fill: slot].color = c }
            }
            if n.lookCount(.fillStops(slot)) != nil, let design = n[fill: slot].gradient?.stops {
                let given = try stops(design, "fill")
                return LookKey(id: n.id, look: .fillStops(slot), time: time, ease: ease) { node in
                    let now = node[fill: slot].gradient?.stops
                    node[fill: slot].gradient?.stops = moved(design, by: given, now)
                }
            }
            throw MCPError("\(place): \(n.name) has no fill\(nth) of one colour or a gradient to key: a picture, a shader, a fill that is off and an artboard's background are the design's. update_layers gives a layer a fill.")
        case "border":
            if n.lookCount(.border(slot)) != nil {
                let c = try color(value, at)
                return LookKey(id: n.id, look: .border(slot), time: time, ease: ease) { $0[border: slot].color = c }
            }
            if n.lookCount(.borderStops(slot)) != nil, let design = n[border: slot].gradient?.stops {
                let given = try stops(design, "border")
                return LookKey(id: n.id, look: .borderStops(slot), time: time, ease: ease) { node in
                    let now = node[border: slot].gradient?.stops
                    node[border: slot].gradient?.stops = moved(design, by: given, now)
                }
            }
            throw MCPError("\(place): \(n.name) has no border\(nth) of one colour or a gradient to key. update_layers gives a layer a border.")
        case "borderWidth":
            guard n.lookCount(.borderWidth(slot)) != nil else {
                throw MCPError("\(place): \(n.name) has no border\(nth) to key the width of. update_layers gives a layer a border.")
            }
            let width = try number(value, at)
            guard width >= 0 else { throw MCPError("\(at) is a border's width in points, 0 or more.") }
            return LookKey(id: n.id, look: .borderWidth(slot), time: time, ease: ease) { $0[border: slot].width = width }
        case "corners":
            guard n.lookCount(.corners) != nil else {
                guard n.kind == .rectangle else { throw MCPError("\(place): \(n.name) is no rectangle, and only a rectangle's corners are keyed.") }
                throw MCPError("\(place): \(n.name) has shape keys, which move the points its corners make, so its corners stay the design's while it has them. Take its shape keys away to key its corners, or give a shape key a path with rounder corners.")
            }
            var radii: [CGFloat]
            if let list = value as? [Any] {
                radii = try list.map { try number($0, at) }
                guard radii.count == 4 else { throw MCPError("\(at): corners take one radius for all four, or four: [top left, top right, bottom right, bottom left].") }
            } else {
                radii = Array(repeating: try number(value, at), count: 4)
            }
            guard radii.allSatisfy({ $0 >= 0 }) else { throw MCPError("\(at): a corner's radius is 0 or more.") }
            return LookKey(id: n.id, look: .corners, time: time, ease: ease) { $0.radii = radii }
        default:
            guard n.lookCount(.shadow(slot)) != nil else {
                throw MCPError("\(place): \(n.name) has no shadow\(nth) to key. update_layers gives a layer a shadow.")
            }
            guard let o = value as? [String: Any], !o.isEmpty, Set(o.keys).isSubset(of: ["color", "x", "y", "blur", "spread"]) else {
                throw MCPError("\(at): a shadow's key is {color, x, y, blur, spread}, any of them: what is left out stays as it is then.")
            }
            let c = try o["color"].map { try color($0, "\(at).color") }
            let x = try o["x"].map { try number($0, "\(at).x") }, y = try o["y"].map { try number($0, "\(at).y") }
            let blur = try o["blur"].map { try number($0, "\(at).blur") }, spread = try o["spread"].map { try number($0, "\(at).spread") }
            if let blur, blur < 0 { throw MCPError("\(at).blur is 0 or more.") }
            return LookKey(id: n.id, look: .shadow(slot), time: time, ease: ease) { node in
                if let c { node[shadow: slot].color = c }
                if let x { node[shadow: slot].x = x }
                if let y { node[shadow: slot].y = y }
                if let blur { node[shadow: slot].blur = blur }
                if let spread { node[shadow: slot].spread = spread == 0 ? nil : spread }
            }
        }
    }

    /// Sets a key of a look: the layer as it looks at that moment, changed as the key says, and
    /// what that takes kept as the key. False where the design no longer has the look.
    static func set(_ key: LookKey, in doc: inout BezzleDocument) -> Bool {
        var done = false
        doc.update(key.id) { n in
            var shown = n.looked(at: key.time)
            key.set(&shown)
            guard let change = n.lookChange(key.look, showing: shown, at: key.time) else { return }
            n.setLookKey(key.look, change: change, at: key.time, ease: key.ease)
            done = true
        }
        return done
    }

    /// A layer's looks that have keys, as the assistant reads them: each as the design has it, and
    /// its keys as it looks at each. Keys for what the design no longer has are said to be gone.
    static func looks(of node: Node) -> JSONValue? {
        let looks = node.looks
        guard !looks.isEmpty else { return nil }
        func stops(_ list: [GradientStop]?) -> JSONValue {
            .array((list ?? []).map { ["color": .string(hex($0.color)), "offset": .number($0.offset)] })
        }
        func said(_ look: LookTrack, of n: Node) -> JSONValue {
            switch look {
            case .fill(let i): return .string(hex(n[fill: i].color))
            case .fillStops(let i): return stops(n[fill: i].gradient?.stops)
            case .border(let i): return .string(hex(n[border: i].color))
            case .borderStops(let i): return stops(n[border: i].gradient?.stops)
            case .borderWidth(let i): return .number(n[border: i].width)
            case .corners: return .array(n.radii.map { .number($0) })
            case .shadow(let i):
                let s = n[shadow: i]
                return ["color": .string(hex(s.color)), "x": .number(s.x), "y": .number(s.y), "blur": .number(s.blur), "spread": .number(s.grown)]
            }
        }
        func word(_ look: LookTrack) -> String {
            switch look {
            case .fill, .fillStops: "fill"
            case .border, .borderStops: "border"
            case .borderWidth: "borderWidth"
            case .corners: "corners"
            case .shadow: "shadow"
            }
        }
        return .array(looks.map { look in
            let fits = node.fits(look)
            let keys: [JSONValue] = (node[track: look.name]?.keys ?? []).map { key in
                let pace: MotionEase? = key.ease.flatMap { $0.kind == .auto ? nil : $0 }
                let bounce: Double? = pace?.kind == .spring ? pace?.bounce : nil
                return .compact([
                    ("time", .number(key.t)),
                    ("value", fits ? said(look, of: node.looked(at: key.t)) : nil),
                    ("pace", pace.map { .string($0.kind.rawValue) }),
                    ("bounce", bounce.map { .number($0) }),
                    ("given", key.given == true ? true : nil),
                ])
            }
            return .compact([
                ("look", .string(word(look))),
                ("which", look.place.flatMap { $0.slot > 0 ? .number($0.slot + 1) : nil }),
                ("design", fits ? said(look, of: node) : nil),
                ("gone", fits ? nil : true),
                ("keys", .array(keys)),
            ])
        })
    }
}
