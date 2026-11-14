import Foundation

// From Bezzle/MCP/MCPAnimate.swift, for Windows: the same tools, over the window's film desk
// (Host/Animating.swift) through the store stand-in (MCPStore.swift).

/// Animate for the assistant: an artboard's film read as its keys, and changed by setting keys,
/// taking them away, giving layers a ready made move, and setting what else the film is. See
/// `MotionProperty`, `MotionMove` and `Film`.
extension MCPTools {
    func animateDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        func list(_ d: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
        func choice(_ values: [String], _ d: String) -> JSONValue {
            ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(d)]
        }
        let properties = MotionProperty.allCases.map(\.rawValue)
        let key: JSONValue = .object([
            ("type", "object"),
            ("properties", .object([
                ("layer", text("The layer the key is for, by id or name. Leave it out for the camera's keys.")),
                ("layers", list("Several layers given the same key, in place of layer.")),
                ("property", choice(properties, "What changes. A layer's: \(Self.names(MotionProperty.layer)). The camera's: \(Self.names(MotionProperty.camera)).")),
                ("time", number("Seconds from the film's start, 0 or more.")),
                ("value", ["description": "The value there: [x, y] for move, scale and cameraMove (one number for scale is both ways); [from, to] for draw (one number is to, from 0); one number for the rest."]),
                ("path", text("For property shape, in place of value: the layer's outline at that time, as SVG path data in the layer's own points (its frame's top left at 0, before it is turned). With the same points in the same order as the outline at the key before, each point moves where it is to be. With other points, more or fewer, in as many runs as it takes, open or closed, the one outline goes into the other, and Bezzle pairs their points so that each goes the shortest way. get_animation lists a moving shape's outline as designed and at each key.")),
                ("outlineOf", text("For property shape, in place of path: another path, rectangle, ellipse or line on the artboard, by id or name. The layer has that one's outline at that time, as it is then, as large as it is and turned as it is, about this layer's own middle: a square that becomes the star beside it.")),
                ("pace", choice(MotionEase.Kind.allCases.map(\.rawValue), "How the value arrives here from the key before. Left out, a new key is auto and a key already there keeps its pace.")),
                ("bounce", number("With pace spring: how far past it goes, 0 (not at all) to 1; 0.3 otherwise.")),
                ("to", list("The camera's key only, in place of property and value: the layers it looks at then, whole with room round them, wherever they are at that moment. Sets cameraMove and cameraZoom together, as Bezzle's own fly-to does; tilt, swing and roll stay as they are.")),
                ("input", text("In place of property: an input of the layer's shader (a uniform of its fill.shader, as get_animation lists them with what the design sets), keyed like a property. value is how far it is from the design there, as many numbers as the input has: [0.4, -0.2, 0] turns a colour input more red and less green; 0 for each is the design.")),
            ])),
            ("required", ["time"]),
        ])
        let move: JSONValue = .object([
            ("type", "object"),
            ("properties", .object([
                ("move", choice(MotionMove.allCases.map(\.rawValue), "Which: fade; rise (from a little below, fading in); drop (from above, with a bounce); slide (from off the nearer side of the artboard); pop (grown from small, with a bounce); zoom (settling from larger); flip (tipped up from lying back); focus (out of a blur); draw (a path, rectangle, ellipse or line drawn on as a pen draws it; anything else fades).")),
                ("layers", list("The layers, by id or name. The selection otherwise.")),
                ("time", number("When the first of them starts, in seconds; 0 otherwise.")),
                ("going", boolean("true for going, from the design to away, rather than coming on.")),
                ("apart", number("Seconds between one layer starting and the next; 0, all together, otherwise.")),
            ])),
            ("required", ["move"]),
        ])
        let artboard = text("The artboard, or a layer on it, by id or name. The selection's artboard, or the one in sight, otherwise.")
        return [
            Definition(name: "get_animation", title: "Get an artboard's animation",
                       description: """
                       Reads an artboard's film, as Bezzle's Animate mode keeps it: how many seconds it runs and whether it goes round \
                       or plays once, its backdrop when one is set, the camera's keys, and every layer that moves with its keys. \
                       Each property has its own keys in order of time, each a time in seconds, a value, and its pace when one was \
                       chosen (auto otherwise), a spring's with its bounce, how far past the key it goes, 0 to 1. Values are changes from the design, never places of their own: move is points right \
                       and down from where the design has the layer, scale is times its size, turn is degrees clockwise added to its \
                       rotation, fade is times its opacity, lift is points nearer the eye, tilt and swing are degrees tipped back and \
                       swung round, blur is points of blur added. A path, rectangle, ellipse or line also has draw, [from, to], how \
                       much of its outline is drawn, each 0 (its start) to 1 (its end), and shape, its outline changed: each shape key \
                       is given as path, its outline then in the layer's own points (its frame's top left at 0, before it is turned), \
                       which has the design's points, each moved, or other points altogether, and such a layer lists outline, its \
                       outline as designed in the same points. \
                       Before its first key a property has that key's value and after its \
                       last that one's; a layer with no keys is as designed. A key marked given is the design itself, put there by \
                       Bezzle to go with the first pose made by hand, and anyone's to change. In a deck each layer says its post, \
                       counted from 1, as every post's layers have keys of their own. animating says whether the person's \
                       window shows the design in Animate; when it shows this artboard's film, playhead is the moment in seconds \
                       it is posed at, and playing is true while it plays. Read this before animate, to go on with an animation \
                       rather than write over it.
                       """,
                       properties: .object([design, ("artboard", artboard)]),
                       readOnly: true, run: { [unowned self] in try await self.getAnimation($0) }),
            Definition(name: "animate", title: "Animate an artboard",
                       description: """
                       Changes an artboard's film: sets keys on its layers and its camera, takes keys away, gives layers a ready made \
                       move, and sets how long the film runs, whether it goes round, and its backdrop. All of one call is one step of \
                       the undo history; in it remove is done first, then moves, then keys. A key gives one property a value at a \
                       time, and between two keys the value travels from one to the other. Values are changes from the design: move \
                       [x, y] in points right and down from where the design has the layer, scale [x, y] in times its size, turn in \
                       degrees clockwise, fade in times its opacity (0 gone, 1 as designed), lift in points nearer the eye, tilt and \
                       swing in degrees (its top, or its right side, going away), blur in points. A path, rectangle, ellipse or line \
                       has two more: draw [from, to], how much of its outline is drawn as a pen draws it, each 0 (its start) to 1 (its \
                       end), so a line draws itself on from draw [0, 0] to [0, 1]; and shape, its outline changed, a key given as path, \
                       its outline then, so one outline becomes another: with the same points as the key before, each moved (a blob \
                       that breathes), or with other points, more or fewer, their points paired by Bezzle so each goes the shortest \
                       way (a star into a circle, an icon into the next); or given as outlineOf, another shape on the artboard whose \
                       outline it has then. The design itself is move [0, 0], \
                       scale 1, fade 1 and 0 for the rest. Only the keys given are set and none are added, and before its first key a \
                       property stays at that key's value, after its last at that one's: so a layer coming on takes two keys, one \
                       away from the design at the start (fade 0, move [0, 28]) and one back at the design a little later (fade 1, \
                       move [0, 0]), and a single key away from the design holds the layer there for the whole film. Leave pace out, \
                       or auto, and Bezzle reads it from the keys round it: what comes home to the design settles gently, and a \
                       motion that keeps going the same way flows through its keys; choose smooth, in, out, linear, spring or hold \
                       only where there is a reason. The camera is the artboard's, its keys given without a layer: cameraMove [x, y] \
                       is where it looks, in points from the artboard's middle; cameraZoom is how many times closer than seeing the \
                       whole artboard; cameraRoll, cameraTilt and cameraSwing are degrees. At rest (cameraMove [0, 0], cameraZoom 1, \
                       the others 0) it shows the whole artboard straight on, and a fly over is a few camera keys with tilt and zoom, \
                       ending at rest. A layer filled with a shader also has its inputs keyed (input in place of property): its \
                       colours, intensities and the like, each value a change from what the design sets, so a gradient can shift its \
                       colours as the film plays; the shader's own time runs by itself. moves give layers a whole entrance or exit as keys, one layer after another apart seconds in \
                       the order they are read on the artboard, from the top down and across; the keys can be changed afterwards like \
                       any. In a deck each post's layers have keys of their own and the film shows the post in front: a name is the \
                       layer in the first post, and a layer of another post is given by its id (deck with post lists them). \
                       playhead and play show the film to the person, after everything else in the call is done: they turn \
                       the window to Animate with this artboard's film, posed at a moment or playing, change nothing in the design \
                       and are no step of the undo history. The answer is the film as it is now, for what changed, with animating, \
                       playhead and playing as get_animation says them; get_animation reads all of it.
                       """,
                       properties: .object([
                           design,
                           ("artboard", text("The artboard whose film it is, or a layer on it, by id or name. Left out, it is the one the layers named lie on; with none named, the selection's artboard, or the one in sight.")),
                           ("keys", ["type": "array", "items": key, "description": "Keys to set, each {layer, property, time, value, pace}. A key already there at that time is changed."]),
                           ("moves", ["type": "array", "items": move, "description": "Ready made moves, each {move, layers, time, going, apart}. Keys of the same properties in the time a move takes give way to it."]),
                           ("remove", ["description": "What to take away: a list of {layer or layers, property, time}. With property and time it is one key; with property alone, all of that property's keys; with time alone, the layer's keys at that moment; with neither, all motion of the layers and of what they hold. Without a layer it is the camera's: a camera property, or \"camera\" for all of them. Or \"all\": every key on the artboard, its camera's, and what its film was set to."]),
                           ("length", ["description": "How many seconds the film runs, more than 0. null (or \"auto\") lets it run as long as its last key, to the next half second, and at least 2 seconds."]),
                           ("loop", boolean("true plays the film round and round, the usual; false plays it once.")),
                           ("backdrop", ["description": "What shows past the artboard's edges when the camera sees them: a colour, \"#RRGGBB\". null (or \"auto\") lets Bezzle choose it to go with the artboard."]),
                           ("playhead", number("Shows the design in Animate with this artboard's film, the playhead at this many seconds from its start, so the person sees the artboard as it is posed there. Past the film's end it rests at the end.")),
                           ("play", boolean("true shows the design in Animate and plays this artboard's film for the person, from its start, or from playhead when that is given too. false stops a film that plays.")),
                       ]), run: { [unowned self] in try await self.animate($0) }),
        ]
    }

    // MARK: Reading

    func getAnimation(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let board = try Self.filmBoard(args, in: store)
        let doc = store.doc
        var pairs = Self.filmListing(board)
        pairs += Self.deskListing(board.id, in: store)
        if !board.hasFilm { pairs.append(("note", .string("Nothing on \(board.name) moves yet. animate sets keys."))) }
        let others = doc.artboards.filter { $0.id != board.id && $0.hasFilm }
        pairs.append(("otherFilms", .array(others.map { ["id": .string($0.id.uuidString), "name": .string($0.name)] })))
        return [.text(JSONValue.compact(pairs).text)]
    }

    /// The artboard whose film is meant: the one `artboard` names, or holds the layer it names;
    /// else the one `first` lies on, a layer named in what is asked; else the selection's, or the
    /// one in sight. `layer` is taken for `artboard`, as the tools for an artboard's grid and
    /// guides call it, rather than passed over for the artboard in sight.
    private static func filmBoard(_ args: Arguments, in store: DocumentStore, first: String? = nil) throws -> Node {
        let doc = store.doc
        if let ref = try args.string("artboard") ?? args.string("layer") ?? first {
            let id = try layer(ref, in: doc)
            if let n = doc.node(id), n.isArtboard { return n }
            if let board = doc.artboard(of: id) { return board }
            throw MCPError(notOnAnArtboard(doc.node(id)?.name ?? ref))
        }
        if let board = store.focusedArtboard { return board }
        throw MCPError("Say which artboard, as artboard.")
    }

    private static func notOnAnArtboard(_ name: String) -> String {
        "\(name) is not on an artboard: only layers on an artboard move in its film. move_layers puts it on one."
    }

    /// An artboard's film as the assistant is told of it: what it is set to, the camera's keys,
    /// and each moving layer's. `only` narrows it to what a change touched: those layers, moving
    /// or as designed again, and the camera when `camera` says so.
    static func filmListing(_ board: Node, only: [UUID]? = nil, camera: Bool = true) -> [(String, JSONValue?)] {
        var moving: [JSONValue] = []
        var still: [JSONValue] = []
        // In a deck every post has its layers, and they their keys: each is said with its post.
        let posts = board.posts
        func visit(_ holder: Node, post held: Int?) {
            for child in holder.children {
                let post = holder.id == board.id ? child.post.flatMap { posts.firstIndex(of: $0) }.map { $0 + 1 } : held
                if only?.contains(child.id) != false {
                    let who: [(String, JSONValue?)] = [
                        ("id", .string(child.id.uuidString)), ("name", .string(child.name)),
                        ("post", post.map { .number(Double($0)) }),
                    ]
                    if child.isAnimated {
                        let outline = child.canReshape && child[track: .shape] != nil ? child.ownOutline.map { JSONValue.string($0.data) } : nil
                        moving.append(.compact(who + [("tracks", tracks(of: child, MotionProperty.layer)), ("outline", outline), ("shader", inputs(of: child))]))
                    } else if only != nil {
                        still.append(.compact(who))
                    }
                }
                visit(child, post: post)
            }
        }
        visit(board, post: nil)
        let set = board.film
        return [
            ("artboard", ["id": .string(board.id.uuidString), "name": .string(board.name)]),
            ("length", .number(board.filmLength)),
            ("automaticLength", (set?.length ?? 0) > 0 ? nil : true),
            ("loops", .bool(set?.once != true)),
            ("backdrop", set?.backdrop.map { .string(hex($0)) }),
            ("camera", camera ? tracks(of: board, MotionProperty.camera) : nil),
            ("layers", .array(moving)),
            ("asDesigned", .array(still)),
        ]
    }

    /// A layer's keys of these properties, by property, in order of time; nil when it has none.
    private static func tracks(of node: Node, _ properties: [MotionProperty]) -> JSONValue? {
        var pairs: [(String, JSONValue)] = []
        for p in properties {
            guard let track = node[track: p], !track.keys.isEmpty else { continue }
            let keys: [JSONValue] = track.keys.map { key in
                let pace: MotionEase? = key.ease.flatMap { $0.kind == .auto ? nil : $0 }
                let bounce: Double? = pace?.kind == .spring ? pace?.bounce : nil
                // A shape's key as the outline it gives: what it is made with, rather than a change of
                // each number, or the numbers of an outline it holds itself.
                let path: String? = p == .shape ? node.shapeOutline(of: key.v).map(\.data) : nil
                return .compact([
                    ("time", JSONValue.number(key.t)),
                    ("value", p == .shape ? nil : written(key.v, of: p)),
                    ("path", path.map { JSONValue.string($0) }),
                    ("pace", pace.map { JSONValue.string($0.kind.rawValue) }),
                    ("bounce", bounce.map { JSONValue.number($0) }),
                    ("given", key.given == true ? true : nil),
                ])
            }
            pairs.append((p.rawValue, .array(keys)))
        }
        return pairs.isEmpty ? nil : .object(pairs)
    }

    /// A layer's shader inputs, when it has a shader: each as the design sets it, and its keys,
    /// each a change from that, as every key is.
    private static func inputs(of node: Node) -> JSONValue? {
        guard let shader = node.keyedShader else { return nil }
        let names = shader.inputs
        guard !names.isEmpty else { return nil }
        let pairs: [(String, JSONValue)] = names.map { name in
            var fields: [(String, JSONValue?)] = [("design", .array((shader.value(of: name) ?? []).map { .number($0) }))]
            if let track = node[track: ShaderFill.inputTrack(name)], !track.keys.isEmpty {
                fields.append(("keys", .array(track.keys.map { key in
                    let pace: MotionEase? = key.ease.flatMap { $0.kind == .auto ? nil : $0 }
                    let bounce: Double? = pace?.kind == .spring ? pace?.bounce : nil
                    return .compact([("time", .number(key.t)), ("change", .array(key.v.map { .number($0) })),
                                     ("pace", pace.map { .string($0.kind.rawValue) }), ("bounce", bounce.map { .number($0) }),
                                     ("given", key.given == true ? true : nil)])
                })))
            }
            return (name, .compact(fields))
        }
        return .object(pairs)
    }

    /// A key's value as it is written and as it plays: one number, or two for what has an x and a y.
    private static func written(_ value: [Double], of property: MotionProperty) -> JSONValue {
        let kept = property.clamped(value)
        return kept.count == 1 ? .number(kept[0]) : .array(kept.map { JSONValue.number($0) })
    }

    // MARK: Showing

    /// How an artboard's film stands on the person's desk: whether the window shows the design in
    /// Animate, and when it shows this artboard's film, where its playhead is and that it plays.
    private static func deskListing(_ board: UUID, in store: DocumentStore) -> [(String, JSONValue?)] {
        let here = store.animating && store.film.board == board
        // While it plays, where the playhead shows; else where it rests.
        let playhead = store.film.playing ? MotionTiming.time(store.film.live) : store.filmTime
        return [
            ("animating", .bool(store.animating)),
            ("playhead", here ? .number(playhead) : nil),
            ("playing", here && store.film.playing ? true : nil),
        ]
    }

    /// Turns the window to Animate with an artboard's film on the desk. The desk follows what is
    /// picked, so what is picked on another artboard is let go of for the artboard itself.
    private static func showFilm(of board: UUID, in store: DocumentStore) {
        guard !store.animating || store.film.board != board else { return }
        let picked = store.selection.first.flatMap { $0 == board ? board : store.doc.artboard(of: $0)?.id }
        if picked != board { store.selection = [board] }
        if store.animating { store.focusFilm() } else { store.showAnimate() }
    }

    // MARK: Changing

    /// The step's name in the undo history, the one a change made with update_layers has.
    private static let animating: LocalizedStringResource = "Change"

    private nonisolated struct FilmKey {
        /// The layers it is for; none for the camera.
        var ids: [UUID]
        var property: MotionProperty
        var time: Double
        var value: [Double]
        var ease: MotionEase?
        /// A shape's key only: the shape whose outline it has then, in place of a value.
        var taking: UUID?
    }

    private nonisolated struct FilmRemoval {
        /// The layers it takes from; nil for the camera.
        var ids: [UUID]?
        /// Only these properties; nil for all of them.
        var properties: [MotionProperty]?
        /// Only this shader input's keys, in place of properties.
        var input: String? = nil
        /// Only the keys at this moment; nil for whole tracks.
        var time: Double?
    }

    private nonisolated struct FilmMove {
        var move: MotionMove
        var ids: [UUID]
        var time: Double
        var going: Bool
        var apart: Double
    }

    func animate(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc

        // What is asked for, all of it read and checked before anything changes.
        var everything = false
        var removeSpecs: [[String: Any]] = []
        if let raw = args["remove"], (raw as? [Any])?.isEmpty != true {
            if let words = (raw as? String).map({ [$0] }) ?? raw as? [String] {
                guard words.allSatisfy({ $0.lowercased() == "all" }) else { throw MCPError(Self.removeHelp) }
                everything = true
            } else {
                removeSpecs = try args.objects("remove") ?? []
            }
        }
        let moveSpecs = try args.objects("moves") ?? []
        let keySpecs = try args.objects("keys") ?? []

        /// A setting that null or "auto" hands back to Bezzle: nil when it was not sent at all,
        /// and nothing inside when it is handed back.
        func setting(_ name: String) -> Any?? {
            guard let raw = args.values[name] else { return nil }
            if raw is NSNull { return .some(nil) }
            if let word = raw as? String, ["auto", "automatic"].contains(word.lowercased()) { return .some(nil) }
            return .some(raw)
        }
        var setsLength = false, length: Double?
        if let raw = setting("length") {
            setsLength = true
            if let raw {
                guard let seconds = try Read.number(raw, "length").map(MotionTiming.time), seconds > 0 else {
                    throw MCPError("length is how many seconds the film runs, more than 0; null lets it run as long as its last key.")
                }
                length = seconds
            }
        }
        let loop = try args.bool("loop")
        var setsBackdrop = false, backdrop: RGBA?
        if let raw = setting("backdrop") {
            setsBackdrop = true
            if let raw { backdrop = try Self.color(raw, "backdrop") }
        }
        let setsFilm = setsLength || loop != nil || setsBackdrop
        let playhead = try Self.motionTime(args["playhead"], "playhead")
        let play = try args.bool("play")
        let edits = everything || !removeSpecs.isEmpty || !moveSpecs.isEmpty || !keySpecs.isEmpty || setsFilm
        guard edits || playhead != nil || play != nil else {
            throw MCPError("Give keys, moves or remove, the film's length, loop or backdrop, or playhead or play to show it. get_animation reads the film.")
        }

        /// The layers a key, a move or a removal names; nil when it names none.
        func refs(_ spec: [String: Any]) throws -> [String]? {
            let item = Arguments(spec)
            if let many = try item.strings("layers") { return many }
            return try item.string("layer").map { [$0] }
        }
        var first: String?
        for spec in removeSpecs + moveSpecs + keySpecs where first == nil { first = try refs(spec)?.first }
        let board = try Self.filmBoard(args, in: store, first: first)
        // Only an artboard that shows has a film to show.
        let shows = playhead != nil || play == true
        if shows, board.hidden {
            throw MCPError("\(board.name) is hidden, and the film of a hidden artboard cannot be shown: leave playhead and play out, or show the artboard first with update_layers.")
        }

        // A name that is on several artboards is the one on this artboard.
        var onBoard = doc
        onBoard.nodes = board.children
        var found: [String: UUID] = [:]
        func layer(_ ref: String) throws -> UUID {
            if let id = found[ref] { return id }
            var here: UUID?
            if UUID(uuidString: ref) == nil { here = try? Self.layer(ref, in: onBoard) }
            let id = try here ?? Self.layer(ref, in: doc)
            found[ref] = id
            return id
        }
        func layers(_ refs: [String], _ place: String) throws -> [UUID] {
            guard !refs.isEmpty else { throw MCPError("\(place): layers is empty.") }
            var ids: [UUID] = []
            for ref in refs {
                let id = try layer(ref)
                if !ids.contains(id) { ids.append(id) }
            }
            return ids
        }
        /// Only layers lying on the film's artboard move in it.
        func onFilm(_ id: UUID) throws {
            guard let n = doc.node(id) else { throw MCPError("That layer is gone.") }
            if n.isArtboard {
                throw MCPError("\(n.name) is an artboard: its layers move, and its camera. Leave layer out for the camera's keys.")
            }
            guard let home = doc.artboard(of: id) else { throw MCPError(Self.notOnAnArtboard(n.name)) }
            guard home.id == board.id else {
                throw MCPError("\(n.name) is on \(home.name), not on \(board.name): one call changes one artboard's film.")
            }
        }

        var warnings: [String] = []
        var removals: [FilmRemoval] = []
        for (i, spec) in removeSpecs.enumerated() {
            let place = "remove[\(i)]"
            try Self.known(spec, ["layer", "layers", "property", "time", "input"], place)
            let word = try Read.string(spec["property"], "\(place).property")
            if let input = try Read.string(spec["input"], "\(place).input") {
                guard word == nil, let named = try refs(spec) else { throw MCPError("\(place): an input is a layer's shader's: give layer, and no property.") }
                let ids = try layers(named, place)
                try ids.forEach(onFilm)
                removals.append(FilmRemoval(ids: ids, properties: [], input: input, time: try Self.motionTime(spec["time"], "\(place).time")))
                continue
            }
            let time = try Self.motionTime(spec["time"], "\(place).time")
            if let named = try refs(spec) {
                let ids = try layers(named, place)
                if ids.contains(board.id) {
                    // The artboard itself, whole: its layers' keys, its camera's and its film's settings.
                    guard ids.count == 1, word == nil, time == nil else {
                        throw MCPError("\(place): \(board.name) is the artboard. On its own it takes everything away, as \"all\" does; for its camera's keys leave layer out.")
                    }
                    everything = true
                    continue
                }
                try ids.forEach(onFilm)
                var properties: [MotionProperty]?
                if let word {
                    guard word.lowercased() != "camera" else { throw MCPError("\(place): the camera is the artboard's: leave layer out.") }
                    let property = try Self.motionProperty(word, "\(place).property")
                    guard !property.isCamera else { throw MCPError("\(place): \(Self.cameraOnALayer(property))") }
                    properties = [property]
                }
                removals.append(FilmRemoval(ids: ids, properties: properties, time: time))
            } else {
                guard let word else { throw MCPError("\(place) names nothing to take away. \(Self.removeHelp)") }
                var properties = MotionProperty.camera
                if word.lowercased() != "camera" {
                    let property = try Self.motionProperty(word, "\(place).property")
                    guard property.isCamera else { throw MCPError("\(place): \(Self.layerOnTheCamera(property))") }
                    properties = [property]
                }
                removals.append(FilmRemoval(ids: nil, properties: properties, time: time))
            }
        }

        var moves: [FilmMove] = []
        for (i, spec) in moveSpecs.enumerated() {
            let place = "moves[\(i)]"
            try Self.known(spec, ["move", "layer", "layers", "time", "going", "apart"], place)
            guard let word = try Read.string(spec["move"], "\(place).move")?.lowercased(), let move = MotionMove(rawValue: word) else {
                throw MCPError("\(place): move is one of \(MotionMove.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let ids: [UUID]
            if let named = try refs(spec) {
                ids = try layers(named, place)
            } else {
                guard !store.selection.isEmpty else { throw MCPError("\(place): nothing is selected: say which layers, by id or name.") }
                ids = store.selection
            }
            try ids.forEach(onFilm)
            let apart = try Read.number(spec["apart"], "\(place).apart") ?? 0
            guard apart >= 0 else { throw MCPError("\(place): apart is the seconds between one layer and the next, 0 or more.") }
            moves.append(FilmMove(move: move, ids: ids, time: try Self.motionTime(spec["time"], "\(place).time") ?? 0,
                                  going: try Read.bool(spec["going"], "\(place).going") ?? false, apart: apart))
        }

        var keys: [FilmKey] = []
        /// Camera keys that look at layers: where, worked out once the call's moves are in place.
        var aims: [(ids: [UUID], time: Double, ease: MotionEase?)] = []
        /// Keys of shader inputs, each a change from the input the design sets.
        var inputKeys: [(id: UUID, input: String, change: [Double], time: Double, ease: MotionEase?)] = []
        for (i, spec) in keySpecs.enumerated() {
            let place = "keys[\(i)]"
            try Self.known(spec, ["layer", "layers", "property", "time", "value", "pace", "bounce", "to", "input", "path", "outlineOf"], place)
            if let to = spec["to"] {
                let named = (to as? String).map { [$0] } ?? (to as? [String])
                guard let named, !named.isEmpty else { throw MCPError("\(place).to is the layers the camera looks at, by id or name.") }
                guard spec["layer"] == nil, spec["layers"] == nil, spec["value"] == nil else {
                    throw MCPError("\(place): a key with to is the camera's, and its value is worked out: leave layer, layers and value out.")
                }
                if let word = try Read.string(spec["property"], "\(place).property"), !["cameramove", "camerazoom"].contains(word.lowercased()) {
                    throw MCPError("\(place): to sets cameraMove and cameraZoom together; leave property out.")
                }
                let ids = try layers(named, place)
                try ids.forEach(onFilm)
                guard let time = try Self.motionTime(spec["time"], "\(place).time") else { throw MCPError("\(place) needs time: seconds from the film's start.") }
                aims.append((ids, time, try Self.motionEase(spec, place)))
                continue
            }
            if let input = try Read.string(spec["input"], "\(place).input") {
                guard spec["property"] == nil else { throw MCPError("\(place): a key is of a property or of a shader input, not both.") }
                guard let named = try refs(spec) else { throw MCPError("\(place): say whose shader, as layer.") }
                let ids = try layers(named, place)
                try ids.forEach(onFilm)
                for id in ids {
                    guard let n = doc.node(id), let design = n.shaderInput(input) else {
                        let there = doc.node(id)?.keyedShader?.inputs.joined(separator: ", ")
                        throw MCPError("\(place): \(doc.node(id)?.name ?? "That layer") has \(there.map { "no shader input \(input); its shader has \($0)" } ?? "no shader"). update_layers gives a layer one (fill.shader).")
                    }
                    let raw = spec["value"]
                    let change: [Double]
                    if let n = raw as? NSNumber { change = [n.doubleValue] }
                    else if let list = raw as? [Any] { change = try list.map { try Read.number($0, "\(place).value") ?? 0 } }
                    else { throw MCPError("\(place) needs value: how far the input is from the design there, a number or a list of numbers.") }
                    guard change.count == design.count else {
                        throw MCPError("\(place): \(input) has \(design.count) number\(design.count == 1 ? "" : "s"), so value needs as many.")
                    }
                    guard let time = try Self.motionTime(spec["time"], "\(place).time") else { throw MCPError("\(place) needs time: seconds from the film's start.") }
                    inputKeys.append((id, input, change, time, try Self.motionEase(spec, place)))
                }
                continue
            }
            guard let word = try Read.string(spec["property"], "\(place).property") else {
                throw MCPError("\(place) needs property. \(Self.propertyHelp)")
            }
            let property = try Self.motionProperty(word, "\(place).property")
            if property == .shape || property == .draw {
                // A shape's own: its outline, which only a path, rectangle, ellipse or line has.
                guard let named = try refs(spec) else { throw MCPError("\(place): \(property.rawValue) is a layer's: give layer.") }
                let ids = try layers(named, place)
                try ids.forEach(onFilm)
                guard let time = try Self.motionTime(spec["time"], "\(place).time") else { throw MCPError("\(place) needs time: seconds from the film's start.") }
                let ease = try Self.motionEase(spec, place)
                for id in ids {
                    guard let n = doc.node(id), let design = n.ownOutline else {
                        throw MCPError("\(place): \(doc.node(id)?.name ?? "That layer") has no outline of points: \(property.rawValue) is for paths, rectangles, ellipses and lines.")
                    }
                    if property == .draw {
                        guard spec["path"] == nil, spec["outlineOf"] == nil else { throw MCPError("\(place): path and outlineOf go with property shape.") }
                        var value = try Self.motionValue(spec["value"], of: .draw, "\(place).value")
                        let kept = MotionProperty.draw.clamped(value)
                        if !MotionTiming.alike(kept, value) {
                            warnings.append("\(place): draw \(Self.plain(value)) is outside 0 to 1, and was kept as \(Self.plain(kept)).")
                        }
                        value = kept
                        keys.append(FilmKey(ids: [id], property: .draw, time: time, value: value, ease: ease))
                        continue
                    }
                    if let like = try Read.string(spec["outlineOf"], "\(place).outlineOf") {
                        // Another shape's outline, read when the key is set: as it is then, after what this call sets before it.
                        guard spec["value"] == nil, spec["path"] == nil else { throw MCPError("\(place): outlineOf stands in place of path.") }
                        let others = try layers([like], place)
                        try others.forEach(onFilm)
                        guard others.count == 1, let other = doc.node(others[0]), other.canReshape, other.id != id else {
                            throw MCPError("\(place).outlineOf: one other path, rectangle, ellipse or line on \(board.name), whose outline \(n.name) has then.")
                        }
                        keys.append(FilmKey(ids: [id], property: .shape, time: time, value: [], ease: ease, taking: other.id))
                        continue
                    }
                    guard spec["value"] == nil, let data = try Read.string(spec["path"], "\(place).path") else {
                        throw MCPError("\(place): a shape key is given as path, \(n.name)'s outline at that time in its own points, or as outlineOf, another shape whose outline it has then. Its outline as designed: \(design.data)")
                    }
                    // The design's points, each moved; or other points, an outline the key holds itself.
                    guard let value = n.shapeValue(of: BezierPath(data)) else {
                        throw MCPError("\(place).path: no outline can be read from it. It is SVG path data with two points or more, in \(n.name)'s own points. Its outline as designed: \(design.data)")
                    }
                    keys.append(FilmKey(ids: [id], property: .shape, time: time, value: value, ease: ease))
                }
                continue
            }
            guard spec["path"] == nil, spec["outlineOf"] == nil else { throw MCPError("\(place): path and outlineOf go with property shape.") }
            var ids: [UUID] = []
            if let named = try refs(spec) {
                guard !property.isCamera else { throw MCPError("\(place): \(Self.cameraOnALayer(property))") }
                ids = try layers(named, place)
                try ids.forEach(onFilm)
            } else {
                guard property.isCamera else { throw MCPError("\(place): \(Self.layerOnTheCamera(property))") }
            }
            guard let time = try Self.motionTime(spec["time"], "\(place).time") else {
                throw MCPError("\(place) needs time: seconds from the film's start.")
            }
            let value = try Self.motionValue(spec["value"], of: property, "\(place).value")
            let kept = property.clamped(value)
            if !MotionTiming.alike(kept, value) {
                warnings.append("\(place): \(property.rawValue) \(Self.plain(value)) is outside what the property takes, and was kept as \(Self.plain(kept)).")
            }
            keys.append(FilmKey(ids: ids, property: property, time: time, value: kept, ease: try Self.motionEase(spec, place)))
        }

        // All of it as one change.
        var taken = 0
        let changed = try change(store, Self.animating) { doc in
            let before = doc.node(board.id).map(Self.keyCount) ?? 0
            if everything { doc.clearMotion([board.id]) }
            for removal in removals {
                for id in removal.ids ?? [board.id] {
                    guard let n = doc.node(id) else { continue }
                    if let input = removal.input {
                        let track = ShaderFill.inputTrack(input)
                        if n[track: track] == nil { warnings.append("\(n.name) has no keys of \(input).") }
                        if let time = removal.time { doc.update(id) { $0.removeKeys(at: time, tracks: [track]) } } else { doc.update(id) { $0[track: track] = nil } }
                        continue
                    }
                    let who = removal.ids == nil ? "The camera" : n.name
                    guard let time = removal.time else {
                        guard let properties = removal.properties else {
                            doc.clearMotion([id])
                            continue
                        }
                        if properties.count == 1, n[track: properties[0]] == nil, !everything {
                            warnings.append("\(who) has no \(properties[0].rawValue) keys.")
                        }
                        doc.update(id) { layer in for p in properties { layer[track: p] = nil } }
                        continue
                    }
                    // At a moment with no property named: every key it has there, its shader's inputs' too.
                    let tracks = removal.properties.map { $0.map(\.rawValue) } ?? (removal.ids == nil ? MotionProperty.layer.map(\.rawValue) : n.layerTracks)
                    if !tracks.contains(where: { n[track: $0]?.index(at: time) != nil }), !everything {
                        let what = tracks.count == 1 ? "\(tracks[0]) key" : "key"
                        let times = n.keyTimes(tracks: tracks).map { Self.plain($0) }.joined(separator: ", ")
                        warnings.append("\(who) has no \(what) at \(Self.plain(time)) s" + (times.isEmpty ? "." : ": its keys are at \(times) s."))
                    }
                    doc.update(id) { $0.removeKeys(at: time, tracks: tracks) }
                }
            }
            taken = before - (doc.node(board.id).map(Self.keyCount) ?? 0)
            for move in moves { doc.apply(move.move, to: move.ids, at: move.time, going: move.going, apart: move.apart) }
            for key in keys {
                for id in key.ids.isEmpty ? [board.id] : key.ids {
                    if let other = key.taking {
                        guard let outline = doc.node(board.id)?.outline(of: other, for: id, at: key.time) else { continue }
                        doc.update(id) { n in
                            guard let value = n.shapeValue(taking: outline, at: key.time) else { return }
                            n.setKey(.shape, value, at: key.time, ease: key.ease)
                        }
                        continue
                    }
                    doc.update(id) { $0.setKey(key.property, key.value, at: key.time, ease: key.ease) }
                }
            }
            for key in inputKeys {
                doc.update(key.id) { $0.setInputKey(key.input, change: key.change, at: key.time, ease: key.ease) }
            }
            for aim in aims {
                guard let now = doc.node(board.id), let seen = DocumentStore.cameraAim(at: aim.ids, on: now, in: doc, time: aim.time) else { continue }
                doc.update(board.id) { n in
                    n.setKey(.cameraMove, MotionProperty.cameraMove.clamped(seen.move), at: aim.time, ease: aim.ease)
                    n.setKey(.cameraZoom, MotionProperty.cameraZoom.clamped([seen.zoom]), at: aim.time, ease: aim.ease)
                }
            }
            if setsFilm {
                doc.update(board.id) { n in
                    var film = n.film ?? Film()
                    if setsLength { film.length = length }
                    if let loop { film.once = loop ? nil : true }
                    if setsBackdrop { film.backdrop = backdrop }
                    n.film = film == Film() ? nil : film
                }
            }
        }

        guard let after = store.doc.node(board.id) else { throw MCPError("\(board.name) is gone.") }
        var done: [String] = []
        if changed {
            if everything { done.append("All motion taken from \(board.name).") } else if taken > 0 { done.append("\(Self.counted(taken, "key")) taken away.") }
            for move in moves { done.append("\(move.move.rawValue) given to \(Self.counted(move.ids.count, "layer")).") }
            let set = keys.reduce(0) { $0 + max($1.ids.count, 1) } + aims.count * 2 + inputKeys.count
            if set > 0 { done.append("\(Self.counted(set, "key")) set.") }
            if setsFilm { done.append("The film's settings changed.") }
        } else if edits {
            warnings.append("Nothing changed: the film was like that already.")
        }
        // A key on its own moves nothing: said, as it is the likeliest slip with values that are changes.
        var alone: Set<String> = []
        for key in keys {
            for id in key.ids.isEmpty ? [board.id] : key.ids {
                guard let n = store.doc.node(id), let track = n[track: key.property], track.keys.count == 1 else { continue }
                guard alone.insert("\(id.uuidString) \(key.property.rawValue)").inserted else { continue }
                let who = key.ids.isEmpty ? "The camera" : n.name
                let stays = key.property == .shape ? "has that outline" : "stays at \(Self.plain(track.keys[0].v))"
                warnings.append("\(who) has one \(key.property.rawValue) key, so it \(stays) for the whole film: a motion takes two keys that differ.")
            }
        }
        if !keys.isEmpty || !moves.isEmpty, let end = after.film?.length, end > 0, after.lastKey > end + 0.0042 {
            warnings.append("The film ends at \(Self.plain(end)) s, and keys after that never show: give a longer length, or null to let it run as long as its last key.")
        }

        // Taken away whole, a layer's motion goes with that of what it holds: those are told of too.
        var named: [UUID] = removals.flatMap { removal -> [UUID] in
            guard let ids = removal.ids else { return [] }
            guard removal.properties == nil, removal.time == nil else { return ids }
            return ids.flatMap { id in [id] + Self.moving(in: doc.node(id)) }
        }
        named += moves.flatMap(\.ids)
        named += keys.flatMap(\.ids)
        var touched: [UUID] = []
        for id in named where !touched.contains(id) { touched.append(id) }
        // A deck's film shows the post in front, and a name is the layer in the first post: keys
        // given to a post behind are said, as nothing of them shows until it comes to the front.
        if after.isDeck, let front = store.front(of: after) {
            let posts = after.posts
            var behind: [Int] = []
            for id in moves.flatMap(\.ids) + keys.flatMap(\.ids) {
                guard let post = store.doc.post(of: id)?.post, post != front, let n = posts.firstIndex(of: post), !behind.contains(n + 1) else { continue }
                behind.append(n + 1)
            }
            if !behind.isEmpty, let shown = posts.firstIndex(of: front) {
                let which = behind.count == 1 ? "post \(behind[0])" : "posts " + behind.sorted().map(String.init).joined(separator: ", ")
                warnings.append("These keys are on layers of \(which), and post \(shown + 1) is in front, the one the film shows: each post's layers have keys of their own. deck with show brings a post to the front, and with post lists its layers' ids.")
            }
        }
        let camera = everything || removals.contains { $0.ids == nil } || keys.contains { $0.ids.isEmpty }
        // Shown to the person last, as the film is now.
        if shows {
            Self.showFilm(of: board.id, in: store)
            guard store.animating, store.filmBoard?.id == board.id else { throw MCPError("\(board.name) could not be shown in Animate.") }
            if let playhead {
                store.seek(playhead)
                if playhead > after.filmLength + 0.0005 {
                    warnings.append("playhead \(Self.plain(playhead)) s is past the film's end: it rests at the end, \(Self.plain(after.filmLength)) s.")
                }
            }
            if play == true {
                // From the playhead when one was given, which at the film's end is its start again.
                store.playFilm(fromStart: playhead == nil)
                done.append(playhead == nil ? "Shown in Animate, playing from the start." : "Shown in Animate, playing from \(Self.plain(store.film.live)) s.")
            } else {
                done.append("Shown in Animate, the playhead at \(Self.plain(store.filmTime)) s.")
            }
        }
        if play == false {
            let played = store.film.playing
            store.pauseFilm()
            if playhead == nil { done.append(played ? "The film is stopped." : "No film was playing.") }
        }
        var pairs: [(String, JSONValue?)] = [("done", done.isEmpty ? nil : .string(done.joined(separator: " ")))]
        pairs += Self.filmListing(after, only: everything ? nil : touched, camera: camera)
        pairs += Self.deskListing(board.id, in: store)
        pairs.append(("warnings", .array(warnings.map { .string($0) })))
        return [.text(JSONValue.compact(pairs).text)]
    }

    // MARK: Reading what was sent

    private static func names(_ properties: [MotionProperty]) -> String { properties.map(\.rawValue).joined(separator: ", ") }

    private static let propertyHelp = "A layer's properties are \(names(MotionProperty.layer)); the camera's are \(names(MotionProperty.camera))."

    private static let removeHelp = "remove is \"all\", or a list of {layer or layers, property, time}; without a layer it is the camera's, with property a camera property, or \"camera\" for all of them."

    private static func cameraOnALayer(_ property: MotionProperty) -> String {
        "\(property.rawValue) is the camera's, and the camera is the artboard's: leave layer out. A layer's properties are \(names(MotionProperty.layer))."
    }

    private static func layerOnTheCamera(_ property: MotionProperty) -> String {
        "\(property.rawValue) is a layer's: say which layer, as layer. The camera's properties are \(names(MotionProperty.camera))."
    }

    /// A number as it is said in a sentence: whole without a point.
    private static func plain(_ v: Double) -> String { JSONValue.number(v).text }

    private static func plain(_ v: [Double]) -> String { v.count == 1 ? plain(v[0]) : "[" + v.map { plain($0) }.joined(separator: ", ") + "]" }

    private static func counted(_ count: Int, _ thing: String) -> String { count == 1 ? "1 \(thing)" : "\(count) \(thing)s" }

    /// The layers a layer holds, however deep, that have keys of their own.
    private static func moving(in holder: Node?) -> [UUID] {
        (holder?.children ?? []).flatMap { ($0.isAnimated ? [$0.id] : []) + moving(in: $0) }
    }

    /// How many keys an artboard holds: its camera's, and those of every layer on it.
    private static func keyCount(_ node: Node) -> Int {
        (node.motion ?? [:]).values.reduce(0) { $0 + $1.keys.count } + node.children.reduce(0) { $0 + keyCount($1) }
    }

    /// Refuses what a key, a move or a removal does not take, so that a word such as ease in place
    /// of pace is not passed over in silence.
    private static func known(_ spec: [String: Any], _ names: [String], _ place: String) throws {
        let unknown = Set(spec.keys).subtracting(names)
        guard unknown.isEmpty else {
            throw MCPError("\(place) has no \(unknown.sorted().joined(separator: ", ")). It takes: \(names.joined(separator: ", ")).")
        }
    }

    private static func motionProperty(_ word: String, _ key: String) throws -> MotionProperty {
        if let property = MotionProperty(rawValue: word) { return property }
        if let property = MotionProperty.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(word) == .orderedSame }) { return property }
        throw MCPError("\(key): there is no property \"\(word)\". \(propertyHelp)")
    }

    /// A time as the film keeps it, to the thousandth of a second; nil when none was sent.
    private static func motionTime(_ raw: Any?, _ key: String) throws -> Double? {
        guard let seconds = try Read.number(raw, key) else { return nil }
        guard seconds >= 0 else { throw MCPError("\(key) is \(plain(seconds)): a time is seconds from the film's start, 0 or more.") }
        return MotionTiming.time(seconds)
    }

    /// A key's value: as many numbers as its property has, one alone standing for both of a scale's.
    private static func motionValue(_ raw: Any?, of property: MotionProperty, _ key: String) throws -> [Double] {
        var numbers: [Double] = []
        if let list = raw as? [Any] {
            for item in list {
                guard let n = try Read.number(item, key) else { throw MCPError("\(key) should be numbers.") }
                numbers.append(n)
            }
        } else if let point = raw as? [String: Any] {
            guard let x = try Read.number(point["x"], "\(key).x"), let y = try Read.number(point["y"], "\(key).y"), point.count == 2 else {
                throw MCPError("\(key) should be numbers: [x, y], or one.")
            }
            numbers = [x, y]
        } else if let n = try Read.number(raw, key) {
            numbers = [n]
        } else {
            throw MCPError("\(key) is missing: \(property.rawValue) takes \(property.rest.count == 2 ? "two numbers, [x, y]" : "one number").")
        }
        if property == .scale, numbers.count == 1 { numbers += numbers }
        if property == .draw, numbers.count == 1 { numbers = [0, numbers[0]] }
        guard numbers.count == property.rest.count else {
            let takes = property == .draw ? "[from, to], or one number for to" : property.rest.count == 2 ? "two numbers, [x, y]\(property == .scale ? ", or one for both" : "")" : "one number"
            throw MCPError("\(key): \(property.rawValue) takes \(takes), and \(numbers.count) were given.")
        }
        return numbers
    }

    /// How a key is come to, when its pace was said; nil leaves a key as it is, or auto when new.
    private static func motionEase(_ spec: [String: Any], _ place: String) throws -> MotionEase? {
        let bounce = try Read.number(spec["bounce"], "\(place).bounce")
        guard let word = try Read.string(spec["pace"], "\(place).pace")?.lowercased() else {
            guard bounce == nil else { throw MCPError("\(place): bounce goes with pace spring.") }
            return nil
        }
        guard let kind = MotionEase.Kind(rawValue: word) else {
            throw MCPError("\(place): pace is one of \(MotionEase.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let bounce else { return kind == .spring ? MotionEase.spring() : MotionEase(kind: kind) }
        guard kind == .spring else { throw MCPError("\(place): bounce goes with pace spring, not \(word).") }
        guard (0...1).contains(bounce) else { throw MCPError("\(place): bounce goes from 0 (not at all) to 1.") }
        return MotionEase.spring(bounce)
    }
}
