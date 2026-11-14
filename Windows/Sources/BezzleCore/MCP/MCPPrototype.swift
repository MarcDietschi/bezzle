import Foundation
import AppKit

// From Bezzle/MCP/MCPPrototype.swift, for Windows (see MCPStore.swift).

/// The prototype for the assistant: where layers go, the states of components, the design's
/// tokens, and the whole of it in one go to build as working code, with the way back for what
/// changes in the code. See `FlowLink`.
extension MCPTools {
    func prototypeDefinitions(design: (String, JSONValue)) -> [Definition] {
        func text(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
        func boolean(_ d: String) -> JSONValue { ["type": "boolean", "description": .string(d)] }
        func list(_ d: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
        let motions = FlowMotion.allCases.map(\.rawValue)
        return [
            Definition(name: "prototype", title: "Prototype flows",
                       description: """
                       Reads or changes the prototype: where tapping a layer goes (another screen, which is an artboard, or back to the screen \
                       before), a note on why or when ("after a successful login"), how the next screen comes on, where the prototype starts, and \
                       screens that go on by themselves after a while (a splash screen). With no changes asked for, lists every flow, the start, \
                       and each component's variants that are states. A layer inside a copy of a component links the copy (the whole button). \
                       How screens move is read from the canvas unless a motion is given: a screen lying to the right slides in from the right, \
                       one below rises from below, a narrower or shorter one opens over the screen before as a sheet, and when two screens are \
                       mostly the same, what they share moves to its new place as the rest changes. So lay screens out the way they should move. \
                       Naming a component's variants Hover, Pressed, Focused, Selected, Disabled, Loading, Error or Success makes them states.
                       """,
                       properties: .object([
                           design,
                           ("layers", list("Layers to link from, by id or name; artboards for screens going on by themselves. The selection otherwise.")),
                           ("to", text("The screen they go to, by the artboard's id or name; \"back\" to go back; \"none\" to go nowhere.")),
                           ("note", text("Why, or when, in a few words. An empty string takes the note away.")),
                           ("motion", .object([("type", "string"), ("enum", .array(motions.map { .string($0) })),
                                               ("description", "How the next screen comes on: auto reads it from the canvas (the default).")])),
                           ("after", number("For screens (artboards): go on by themselves this many seconds after showing, to `to`. 0 stops it.")),
                           ("start", text("The screen the prototype starts on, by id or name.")),
                       ]), run: { [unowned self] in try await self.prototype($0) }),
            Definition(name: "get_prototype", title: "Get the prototype",
                       description: """
                       Everything needed to build the design as a working prototype in code, in one go: every screen with its layers \
                       as a tree (ids, kinds, names, frames, fills, text), the flows between them with their notes and motion, the start, \
                       each component with its variants and which are states, the design tokens as CSS, SwiftUI and JSON, how each screen \
                       adapts to other sizes, the picture files it uses, and a picture of each screen. Tag every element in the code with \
                       its layer's id, so that changes made in the code can be written back with update_layers, replace_text, styles and prototype.
                       """,
                       properties: .object([
                           design,
                           ("screens", list("Only these screens, by id or name. Every screen otherwise.")),
                           ("pictures", boolean("A picture of each screen, up to 12; true unless set to false.")),
                       ]), readOnly: true, run: { [unowned self] in try await self.getPrototype($0) }),
            Definition(name: "design_tokens", title: "Design tokens",
                       description: "The design's named styles (colours, gradients, type, shadows, corners) as tokens for code: CSS custom properties with a dark-mode block where the design has dark looks, SwiftUI constants, or the W3C design tokens format as JSON.",
                       properties: .object([
                           design,
                           ("format", .object([("type", "string"), ("enum", ["css", "swiftui", "json", "all"]),
                                               ("description", "Which: css, swiftui, json, or all (the default).")])),
                       ]), readOnly: true, run: { [unowned self] in try await self.designTokens($0) }),
        ] + inspectDefinitions(design: design)
    }

    // MARK: Changing flows

    func prototype(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        var changes: [String] = []
        let doc = store.doc
        let to = try args.string("to"), note = try args.string("note"), motion = try args.string("motion")
        let after = try args.number("after"), start = try args.string("start")
        let changing = to != nil || note != nil || motion != nil || after != nil
        if changing {
            let ids = try Self.layers(args, in: store).compactMap { doc.linkable($0) }
            var target: UUID?, back = false, none = false
            if let to {
                switch to.lowercased() {
                case "back": back = true
                case "none", "nowhere", "": none = true
                default:
                    let id = try Self.layer(to, in: doc)
                    guard doc.node(id)?.isArtboard == true else { throw MCPError("\(doc.node(id)?.name ?? to) is not a screen: to names an artboard.") }
                    target = id
                }
            }
            var m: FlowMotion?
            if let motion {
                guard let found = FlowMotion(rawValue: motion.lowercased()) else { throw MCPError("motion is one of \(FlowMotion.allCases.map(\.rawValue).joined(separator: ", ")).") }
                m = found
            }
            try change(store, "Link") { doc in
                for id in ids {
                    guard let n = doc.node(id) else { continue }
                    var f = n.flow ?? FlowLink()
                    if to != nil {
                        if n.isArtboard, target == id { throw MCPError("\(n.name) can't go to itself.") }
                        f.to = back || none ? nil : target
                        f.back = back ? true : nil
                    }
                    if let note { f.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note }
                    if let m { f.motion = m == .auto ? nil : m }
                    if let after {
                        guard n.isArtboard else { throw MCPError("after is for screens: \(n.name) is a layer. Give an artboard.") }
                        f.after = after > 0 ? after : nil
                    }
                    if !f.leads { f.note = nil; f.motion = nil }
                    doc.update(id) { $0.flow = f.leads || f.after != nil ? f : nil }
                }
            }
            changes.append("\(ids.count == 1 ? "1 layer" : "\(ids.count) layers") changed.")
        }
        if let start {
            let id = try Self.layer(start, in: doc)
            guard store.doc.node(id)?.isArtboard == true else { throw MCPError("start names a screen, an artboard.") }
            try change(store, "Move Start") { $0.markStart(id) }
            changes.append("Starts on \(store.doc.node(id)?.name ?? start).")
        }
        let listing = Self.flowsListing(store)
        return [.text(JSONValue.compact([("done", changes.isEmpty ? nil : .string(changes.joined(separator: " "))), ("prototype", listing)]).text)]
    }

    /// The flows, the start and the states, as `prototype` lists them.
    static func flowsListing(_ store: DocumentStore) -> JSONValue {
        let seen = store.seenDoc
        let start = Prototype.start(of: seen)
        return .compact([
            ("start", start.map { ["id": .string($0.id.uuidString), "name": .string($0.name)] }),
            ("flows", .array(Prototype.links(in: seen).map { flowJSON($0, in: seen) })),
            ("states", .array(seen.masters.compactMap { m -> JSONValue? in
                let states = Components.variants(of: m).compactMap { v in Components.state(of: v, in: m).map { (v, $0) } }
                guard !states.isEmpty else { return nil }
                return ["component": .string(m.name),
                        "states": .array(states.map { v, s in ["variant": .string(Components.name(of: v, in: m)), "state": .string(s.rawValue)] })]
            })),
        ])
    }

    static func flowJSON(_ l: Prototype.Link, in doc: BezzleDocument) -> JSONValue {
        let source = doc.node(l.source)
        let board = doc.node(l.board)
        var way: String?
        if let to = l.flow.to, let b = doc.node(to), let a = board {
            way = Self.wayText(Prototype.way(from: a, to: b, motion: l.flow.motion))
        }
        return .compact([
            ("from", .compact([("layer", .string(l.source.uuidString)), ("name", source.map { .string($0.name) }),
                               ("screen", board.map { .string($0.name) }), ("screenId", .string(l.board.uuidString)),
                               ("isScreen", l.source == l.board ? true : nil)])),
            ("to", l.flow.goesBack ? "back" : l.flow.to.map { id in .compact([("screen", doc.node(id).map { .string($0.name) }), ("id", .string(id.uuidString))]) }),
            ("note", l.flow.note.map { .string($0) }),
            ("motion", .string(l.flow.motion?.rawValue ?? "auto")),
            ("moves", way.map { .string($0) }),
            ("after", l.flow.after.map { .number($0) }),
        ])
    }

    /// How a screen comes on, in words for the code to do the same.
    static func wayText(_ w: Prototype.Way) -> String {
        switch w {
        case .push(let from, let morph):
            if morph { return "smart animate: layers with the same name move and change to their new place and look, the others fade" }
            let side = from.dx > 0 ? "right" : from.dx < 0 ? "left" : from.dy > 0 ? "bottom" : "top"
            return "push from the \(side): the new screen slides in over the old one, which moves a little the other way and dims; layers alike on both stay put"
        case .sheet: return "sheet: rises from the bottom over the screen before, which dims; tapping outside it or going back lowers it"
        case .dissolve: return "dissolve: cross-fade"
        case .instant: return "instant: no motion"
        }
    }

    // MARK: The whole of it

    func getPrototype(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        var screens = Prototype.screens(in: store.seenDoc)
        if let refs = try args.strings("screens") {
            let ids = try refs.map { try Self.layer($0, in: store.doc) }
            screens = screens.filter { ids.contains($0.id) }
        }
        let pictures = try args.bool("pictures") ?? true
        return Self.brief(store, screens: screens, pictures: pictures, stack: nil)
    }

    /// Everything about the prototype, then a picture of each screen.
    static func brief(_ store: DocumentStore, screens: [Node], pictures: Bool, stack: String?) -> [Content] {
        let seen = store.seenDoc
        let start = Prototype.start(of: seen)
        let links = Prototype.links(in: seen)
        var assets: [String: [String]] = [:]
        func noteAssets(_ n: Node) {
            for f in n.fills { if let a = f.image?.asset { assets[a, default: []].append(n.id.uuidString) } }
            n.children.forEach(noteAssets)
        }
        screens.forEach(noteAssets)
        let folder = store.assets.folder
        let json: JSONValue = .compact([
            ("design", .string(store.name)),
            ("start", start.map { ["id": .string($0.id.uuidString), "name": .string($0.name)] }),
            ("screens", .array(screens.map { b in
                let (form, size) = MCPDevice.device(for: b.frame.size)
                return .compact([
                    ("id", .string(b.id.uuidString)),
                    ("name", .string(b.name)),
                    ("width", .number(b.frame.width)),
                    ("height", .number(b.frame.height)),
                    ("device", .string(deviceName(form, size: size, board: b.frame.size))),
                    ("startsHere", b.id == start?.id ? true : nil),
                    ("dark", b.dark == true ? true : nil),
                    ("background", b.fill.on ? .string("#" + b.fill.color.hex) : nil),
                    ("adapts", adaptation(of: b)),
                    ("layers", .array(b.children.map { describe($0, in: seen, full: true) })),
                ])
            })),
            ("flows", .array(links.filter { l in screens.contains { $0.id == l.board } }.map { flowJSON($0, in: seen) })),
            ("components", .array(seen.masters.map { m in
                .compact([
                    ("id", .string(m.id.uuidString)),
                    ("name", .string(m.name)),
                    ("variants", .array(Components.variants(of: m).map { v in
                        .compact([("name", .string(Components.name(of: v, in: m))), ("state", Components.state(of: v, in: m).map { .string($0.rawValue) })])
                    })),
                    ("layers", .array(Components.layers(of: m, variant: nil).map { describe($0, in: seen, full: true) })),
                ])
            })),
            ("tokens", .compact([
                ("css", .string(DesignTokens.css(store.doc, named: store.name))),
                ("swiftui", .string(DesignTokens.swiftUI(store.doc, named: store.name))),
                ("json", .string(DesignTokens.json(store.doc))),
            ])),
            ("assets", .array(assets.keys.sorted().map { a in
                .compact([("file", .string(folder?.appendingPathComponent(a).path ?? a)), ("usedBy", .array(assets[a]!.map { .string($0) }))])
            })),
            ("howToBuild", .string(Self.buildNotes(stack: stack))),
        ])
        var out: [Content] = [.text(json.text)]
        if pictures {
            for b in screens.prefix(12) {
                let scale = min(2, 1400 / max(b.frame.width, b.frame.height, 1))
                if let image = Renderer.image(of: b, scale: scale, assets: store.assets), let png = png(image) {
                    out.append(.text("Screen \"\(b.name)\" (\(b.id.uuidString)):"))
                    out.append(.png(png))
                }
            }
        }
        return out
    }

    private static func deviceName(_ form: SizeForm, size: CGSize, board: CGSize) -> String {
        let scrolls = board.height > size.height + 0.5 ? ", scrolling: the screen shows \(Int(size.width))×\(Int(size.height)) of it" : ""
        let thing: String = switch form {
        case .phone: "phone"
        case .foldable: "foldable phone"
        case .tablet: "tablet"
        case .laptop, .desktop: "desktop"
        case .browser: "browser window"
        case .watch: "watch"
        default: "fixed format"
        }
        return thing + scrolls
    }

    /// How a screen is laid out again at another size, as Bezzle's adaptive layout reads it: its
    /// mode, what covers it, what keeps to an edge, and its blocks in rows and columns, each placed
    /// across the way they stack.
    static func adaptation(of board: Node) -> JSONValue {
        let plan = Adapt.plan(board)
        func ids(_ nodes: [Node], _ indices: [Int]) -> JSONValue { .array(indices.compactMap { nodes.indices.contains($0) ? .string(nodes[$0].id.uuidString) : nil }) }
        func anchor(_ a: Adapt.Anchor) -> String {
            switch a {
            case .start: "start"
            case .end: "end"
            case .center: "center"
            case .span: "stretch"
            case .share(let k): "at \(Int((k * 100).rounded()))% of the room left"
            }
        }
        func frame(_ f: Adapt.Frame, _ nodes: [Node]) -> JSONValue {
            .compact([
                ("covering", f.backdrops.isEmpty ? nil : ids(nodes, f.backdrops)),
                ("keptToEdges", f.loose.isEmpty ? nil : .array(f.loose.compactMap { i, x, y in
                    nodes.indices.contains(i) ? ["layer": .string(nodes[i].id.uuidString), "x": .string(anchor(x.anchor)), "y": .string(anchor(y.anchor))] : nil
                })),
                ("bands", f.bands.isEmpty ? nil : .array(f.bands.compactMap { i, axis, far in
                    nodes.indices.contains(i) ? ["layer": .string(nodes[i].id.uuidString), "edge": .string(axis == .x ? (far ? "bottom" : "top") : (far ? "right" : "left"))] : nil
                })),
                ("flow", f.flow.map { piece(.stack($0), nodes) }),
            ])
        }
        func piece(_ p: Adapt.Piece, _ nodes: [Node]) -> JSONValue {
            switch p {
            case .unit(let u):
                let kind: String
                var inner: JSONValue?
                switch u.shape {
                case .rigid: kind = "scales as a whole"
                case .stretchy: kind = "stretches"
                case .text: kind = "text, rewraps"
                case .holder(_, let f): kind = "holds the others, laid out inside it"; inner = frame(f, nodes)
                case .group(let l, let f): kind = "group, laid out inside"; inner = frame(f, l.nodes)
                }
                return .compact([("layers", ids(nodes, u.members)), ("kind", .string(kind)), ("inside", inner)])
            case .stack(let s):
                return .compact([
                    ("stack", .string(s.axis == .y ? "column" : "row")),
                    ("gaps", .array(zip(s.gaps, s.loose).map { g, loose in .string("\(Int(g.rounded()))\(loose ? " flexible" : " fixed")") })),
                    ("places", .array(s.places.map { .string(anchor($0.anchor)) })),
                    ("wraps", s.alike ? true : nil),
                    ("children", .array(s.children.map { piece($0, nodes) })),
                ])
            }
        }
        return .compact([
            ("mode", .string(plan.mode == .interface ? "interface: text keeps its size, the layout reflows" : "composition: the whole design scales, as a poster does")),
            ("structure", frame(plan.root, plan.layers.nodes)),
        ])
    }

    /// What the assistant is told about building the prototype and keeping it and the design one.
    static func buildNotes(stack: String?) -> String {
        """
        \(stack == nil ? serverless : "")Build the screens as \(stack.map { "\($0) " } ?? "")code, one view or page per screen, and wire up every flow: \
        tapping the layer named in "from" goes to the screen in "to", or back. Make each move as "moves" says, with \
        spring motion. Components are reusable views; a variant whose "state" is set is that state of the view: hover \
        while the pointer is on it, pressed while pressed, selected toggled by a tap, focused for fields, disabled takes \
        no taps, loading shows briefly before the flow is taken, error and success for the code's own results. Use the \
        tokens rather than raw values where a layer's look is named (its "styles"). "adapts" says how each screen \
        should respond to other sizes. Use the picture files in "assets". Tag every element with the id of the layer \
        it comes from (data-bezzle-id="…" on the web, .accessibilityIdentifier("bezzle:…") in SwiftUI). That is the \
        way back: when the code's look, words or flows change later, write the change into the design by those ids \
        with update_layers, replace_text, styles and prototype, so the design never goes stale.
        """
    }

    /// What is built when no stack is asked for: something that opens with a double click, with
    /// no server, no build step and nothing to install.
    static let serverless = """
        Unless asked for another stack, make it one self-contained HTML file: its CSS and JavaScript inline, no \
        modules, no fetch of local files, no packages, no build step and no server. Copy the picture files next to it and \
        refer to them by relative path, so the prototype opens straight from File Explorer in any browser (file://) and works \
        offline. Show it in the size of the device its screens are for, centred in the window. \

        """

    // MARK: Tokens

    func designTokens(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let which = try args.string("format")?.lowercased() ?? "all"
        if which == "all" {
            return DesignTokens.Format.allCases.map { .text(DesignTokens.write(store.doc, named: store.name, as: $0)) }
        }
        guard let format = DesignTokens.Format(rawValue: which) else { throw MCPError("format is css, swiftui, json or all.") }
        return [.text(DesignTokens.write(store.doc, named: store.name, as: format))]
    }
}

// MARK: - Prompts

/// What the server offers as prompts: ready-made asks that bring everything with them.
extension MCPTools {
    struct Prompt {
        let name: String
        let title: String
        let description: String
        let arguments: [(name: String, description: String, required: Bool)]
    }

    static let prompts: [Prompt] = [
        Prompt(name: "build_prototype", title: "Build a prototype",
               description: "Builds the design as a working prototype in code: every screen, flow, component state, design token and picture in one go, tagged so changes in the code can be written back.",
               arguments: [("design", "The design, by name; the one in front otherwise.", false),
                           ("stack", "What to build it in: SwiftUI, React, HTML and CSS, Flutter…", false)]),
        Prompt(name: "write_back", title: "Write the code back into the design",
               description: "Compares a prototype built from the design with the design, and writes what changed in the code (words, colours, layout, flows) back into the design, so the design stays the source.",
               arguments: [("design", "The design, by name; the one in front otherwise.", false),
                           ("code", "Where the prototype's code is, or what changed in it.", false)]),
        Prompt(name: "animate", title: "Animate an artboard",
               description: "Makes an artboard come alive in Animate: entrances, a camera that flies, depth, focus and living shader backgrounds, timed as motion designers time them, checked frame by frame and shown playing.",
               arguments: [("design", "The design, by name; the one in front otherwise.", false),
                           ("artboard", "The artboard, by name; the one in sight otherwise.", false),
                           ("brief", "What the film is for or should feel like: a launch teaser, a calm product tour, a playful loop…", false)]),
    ]

    var promptList: [JSONValue] {
        Self.prompts.map { p in
            [
                "name": .string(p.name),
                "title": .string(p.title),
                "description": .string(p.description),
                "arguments": .array(p.arguments.map { a in ["name": .string(a.name), "description": .string(a.description), "required": .bool(a.required)] }),
            ]
        }
    }

    func prompt(_ name: String, _ arguments: [String: Any]) async throws -> JSONValue {
        let args = Arguments(arguments)
        switch name {
        case "build_prototype":
            let store = try await store(args)
            let stack = try args.string("stack")
            let brief = Self.brief(store, screens: Prototype.screens(in: store.seenDoc), pictures: true, stack: stack)
            var messages: [JSONValue] = [[
                "role": "user",
                "content": ["type": "text", "text": .string("""
                    Build a working prototype of my Bezzle design "\(store.name)"\(stack.map { " in \($0)" } ?? ""). Everything about it \
                    follows: the screens with their layers, the flows between them, the components and their states, the design tokens, \
                    how each screen adapts, and the picture files; then a picture of each screen. Match the pictures closely. \
                    \(Self.buildNotes(stack: stack))
                    """)],
            ]]
            for c in brief {
                switch c {
                case .text(let t): messages.append(["role": "user", "content": ["type": "text", "text": .string(t)]])
                case .png(let d): messages.append(["role": "user", "content": ["type": "image", "data": .string(d.base64EncodedString()), "mimeType": "image/png"]])
                }
            }
            return ["description": .string("A prototype of \(store.name)"), "messages": .array(messages)]
        case "write_back":
            let store = try await store(args)
            let code = try args.string("code")
            let text = """
                The prototype of my Bezzle design "\(store.name)" has changed in code\(code.map { " (\($0))" } ?? ""). Bring the design up to date \
                with it, so the design stays the source: read the code's elements by their Bezzle ids (data-bezzle-id or \
                accessibilityIdentifier "bezzle:…"), compare each with the design using get_prototype or get_layers, and write every \
                difference back: words with replace_text or update_layers, looks with update_layers (or styles where a look is named, so \
                every use follows), sizes and places with update_layers, new elements with add_layers, flows with prototype. Render the \
                changed screens afterwards to check, and say what you changed. Leave alone what only exists in code (logic, data).
                """
            let listing = Self.flowsListing(store)
            return ["description": .string("Write the code back into \(store.name)"),
                    "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]],
                                 ["role": "user", "content": ["type": "text", "text": .string(listing.text)]]]]
        case "animate":
            let store = try await store(args)
            var board: [String: Any] = ["design": store.name]
            if let artboard = try args.string("artboard") { board["artboard"] = artboard }
            let brief = try args.string("brief")
            let film = try await getAnimation(Arguments(board))
            var named = board
            named["layer"] = board["artboard"] ?? store.focusedArtboard?.id.uuidString
            named.removeValue(forKey: "artboard")
            let picture = try await render(Arguments(named))
            var layers: [Content] = []
            if let ref = named["layer"] as? String { layers = try await getLayers(Arguments(["design": store.name, "layers": [ref], "children": true])) }
            var messages: [JSONValue] = [["role": "user", "content": ["type": "text", "text": .string(Self.animateBrief(store.name, brief))]]]
            for c in layers + film + picture {
                switch c {
                case .text(let t): messages.append(["role": "user", "content": ["type": "text", "text": .string(t)]])
                case .png(let d): messages.append(["role": "user", "content": ["type": "image", "data": .string(d.base64EncodedString()), "mimeType": "image/png"]])
                }
            }
            return ["description": .string("Animate \(store.name)"), "messages": .array(messages)]
        default:
            throw MCPError("There is no prompt called \(name).")
        }
    }
}

// From Bezzle/Views/HomeStage.swift: what a size is for, which says what device a screen is.
/// What a size is drawn as on the table.
enum SizeForm: Equatable {
    case phone(island: Bool)
    /// The iPhone Duo: open, a book held sideways, its fold down the middle; closed, a passport
    /// with a straight spine down its left and the rounded edge it opens by on its right.
    case foldable(open: Bool)
    case tablet
    case laptop
    case desktop(iMac: Bool)
    case browser
    case watch
    /// A story, reel, short or TikTok, the full height of a phone.
    case story(sideButtons: Bool)
    /// A cover, header or banner, with the profile's picture over its lower edge.
    case banner
    case video
    case post(roundness: CGFloat)
    case paper
    case businessCard
    case postcard
    case slide
    /// A carousel's slides side by side, what is on them running across the cuts.
    case carousel(slides: Int)

    static func of(_ preset: Preset) -> SizeForm {
        let name = preset.name, size = preset.size
        switch preset.group {
        case .iPhone: return name.hasPrefix("iPhone Duo") ? .foldable(open: name == "iPhone Duo, open") : .phone(island: true)
        case .android: return .phone(island: false)
        case .iPad: return .tablet
        case .mac: return name.hasPrefix("MacBook") ? .laptop : .desktop(iMac: name.hasPrefix("iMac"))
        case .web: return .browser
        case .watch: return .watch
        case .instagram, .tiktok, .youtube, .facebook, .linkedin, .x, .pinterest:
            let lower = name.lowercased()
            if lower.contains("banner") || lower.contains("cover") || lower.contains("header") { return .banner }
            if size.height / size.width >= 1.6 { return .story(sideButtons: preset.group == .tiktok || preset.group == .youtube) }
            if preset.group == .youtube { return .video }
            return .post(roundness: preset.group == .pinterest ? 0.07 : 0.012)
        case .print:
            if name == "Business card" { return .businessCard }
            if name == "Postcard" { return .postcard }
            return .paper
        case .slides: return .slide
        }
    }

}

extension MCPTools {
    /// What an assistant is told to animate well with: what Bezzle's films can do, and how
    /// motion is timed so it feels made rather than moved.
    static func animateBrief(_ design: String, _ brief: String?) -> String {
        """
        Animate the artboard of my Bezzle design "\(design)" that follows\(brief.map { ": \($0)" } ?? ""). Its layers, its film as it \
        is now, and a picture of it come after this. Go on from what is there rather than writing over it.

        What a Bezzle film can do, all through animate:
        - Entrances and exits in one go: moves (rise, fade, drop, slide, pop, zoom, flip, focus, draw), with apart for one layer after \
        another. Keys are changes from the design, so a layer coming on takes a key away from the design and a key back at it.
        - Depth: lift brings a layer nearer the eye, tilt and swing turn it in space. With the camera tilted or swung, lifted \
        layers part from the page like real layers of a scene.
        - The camera: cameraMove, cameraZoom, cameraRoll, cameraTilt, cameraSwing; a key with to looks at layers, framed whole. \
        A fly over is a few camera keys with tilt and zoom, ending at rest (move [0, 0], zoom 1, the rest 0).
        - Focus: blur on a layer, or a focus move, pulls attention; blur what lies behind while what matters is sharp.
        - Paths, rectangles, ellipses and lines: draw [from, to] draws the outline on as a pen does (a signature, an underline, \
        a check mark, a chart's line); shape changes its outline, one becoming another whatever points each has (a blob that \
        breathes, a wave, a star turning into a circle, an icon into the next), each key given as path in the layer's own \
        points, or as outlineOf, another shape on the artboard.
        - Looks: a key with look in place of property changes how a layer looks as the film plays: its fill's or border's colour \
        (a gradient's colours too), a border's width, a rectangle's corners, a shadow. Its value is the look itself at that time, \
        so a button turns from grey to its accent, a card's shadow deepens as it lifts, a square's corners grow round.
        - Paces: leave auto unless there is a reason; spring with bounce 0.2 to 0.4 for something playful; hold for a cut.
        - Shaders: a layer filled with a shader (brought in from a website) moves by itself as the film plays, its inputs \
        keyed like any property.
        - The film: length, loop (round and round) or once, and the backdrop seen past the artboard's edges.

        How it is done well:
        - Lead the eye: one thing first, what goes with it after, the rest last or not at all. Not everything moves.
        - Timing: small things 0.2 to 0.4 seconds, cards and panels 0.4 to 0.7, the camera 1 to 2.5. Between items in a row, \
        0.05 to 0.12 seconds apart reads as one gesture.
        - Distances: entrances travel little, 16 to 40 points; scale from 0.9 to 1, not from 0. Depth is felt at lift 20 to 120.
        - Let it breathe: hold a finished moment a second before the film ends or goes round. A loop ends as it began.
        - Camera moves are slow and few; a fly over that tips the scene 25 to 45 degrees and comes back reads as cinematic.

        Check as you go: render with frames (8 to 12) to see the whole film on one sheet, and with time for one moment; fix \
        what jumps, crowds or waits too long. Then show it to me playing (animate with play true), and say what you made. \
        export with format mp4 saves it as a movie when I ask for one.
        """
    }
}
