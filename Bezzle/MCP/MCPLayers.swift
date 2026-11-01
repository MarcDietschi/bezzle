import AppKit

/// Layers as the assistant reads and writes them: plain names for what the inspector shows,
/// colours as hex, positions in the parent, as the inspector measures them.
extension MCPTools {
    // MARK: Finding layers

    /// A layer by its id, its name, or "Artboard/Layer" when the name alone is not enough.
    static func layer(_ ref: String, in doc: BezzleDocument) throws -> UUID {
        if let id = UUID(uuidString: ref), doc.node(id) != nil { return id }
        let all = doc.allNodes
        var named = all.filter { $0.name == ref }
        if named.isEmpty { named = all.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame } }
        if named.isEmpty, let slash = ref.firstIndex(of: "/") {
            let within = String(ref[..<slash]), rest = String(ref[ref.index(after: slash)...])
            if let parent = try? layer(within, in: doc), let container = doc.node(parent) {
                var inside = doc
                inside.nodes = container.children
                if let id = try? layer(rest, in: inside) { return id }
            }
        }
        if named.count == 1 { return named[0].id }
        // A layer repeated in a grid is the one in its first cell; in a deck's posts, the one in its first post.
        if named.count > 1, case let firsts = firstCells(named, in: doc), firsts.count == 1 { return firsts[0].id }
        if named.isEmpty { throw MCPError("There is no layer \"\(ref)\". get_design lists them, with their ids.") }
        let places = named.prefix(6).map { "\($0.id.uuidString) (on \(doc.artboard(of: $0.id)?.name ?? "the canvas"))" }
        throw MCPError("\(named.count) layers are called \"\(ref)\": \(places.joined(separator: ", ")). Use an id, or \"Artboard/\(ref)\".")
    }

    /// The layers `layers` names, or the selection when it names none.
    static func layers(_ args: Arguments, in store: DocumentStore) throws -> [UUID] {
        if let refs = try args.strings("layers") {
            guard !refs.isEmpty else { throw MCPError("layers is empty.") }
            var ids: [UUID] = []
            for ref in refs {
                let id = try layer(ref, in: store.doc)
                if !ids.contains(id) { ids.append(id) }
            }
            return ids
        }
        guard !store.selection.isEmpty else { throw MCPError("Nothing is selected: say which layers, by id or name.") }
        return store.selection
    }

    // MARK: Describing

    /// How many layers one answer lists, so a large design does not swamp it.
    static let layerBudget = 500

    final class Budget {
        var left: Int
        init(_ left: Int) { self.left = left }
    }

    /// A layer and, `depth` deep, what it holds: where it is, and with `full`, how it looks.
    static func describe(_ node: Node, in doc: BezzleDocument, full: Bool, depth: Int = .max, budget: Budget? = nil) -> JSONValue {
        budget?.left -= 1
        var pairs: [(String, JSONValue?)] = [
            ("id", .string(node.id.uuidString)),
            ("kind", .string(node.kind.rawValue)),
            ("name", .string(node.name)),
            ("x", .number(round(node.frame.minX))),
            ("y", .number(round(node.frame.minY))),
            ("width", .number(round(node.frame.width))),
            ("height", .number(round(node.frame.height))),
            ("rotation", node.rotation != 0 ? .number(round(node.rotation)) : nil),
            ("hidden", node.hidden ? true : nil),
            ("locked", node.locked ? true : nil),
            // What it is, as kind is, so a mask is told from a group in every answer.
            ("mask", node.isMask ? true : nil),
        ]
        if node.kind == .text, let text = node.text {
            pairs.append(("text", .string(full || text.count <= 80 ? text : String(text.prefix(77)) + "…")))
        }
        if node.isRepeatGrid { pairs += gridDetails(node, in: doc) }
        if node.isDeck { pairs += deckDetails(node, front: nil, broken: DocumentStore.broken(node)) }
        if node.isArtboard { pairs += layoutDetails(node) }
        if node.isCarousel, let slide = node.slideSize {
            pairs.append(("carousel", .string(Carousel.format(of: slide)?.name ?? "\(Int(slide.width))×\(Int(slide.height))")))
            pairs.append(("slides", .number(node.slideCount)))
        }
        if full {
            pairs += style(of: node)
        } else if node.kind != .group {
            let fills = node.fills
            pairs.append(("fill", fills.count > 1 ? .array(fills.map(fill)) : fill(node.fill)))
        }
        if node.isContainer {
            let count = BezzleDocument.layerCount(listed(in: node))
            if depth > 0, (budget?.left ?? 1) > 0 {
                var children: [JSONValue] = []
                let listed = listed(in: node)
                for child in listed {
                    guard (budget?.left ?? 1) > 0 else { break }
                    children.append(describe(child, in: doc, full: full, depth: depth - 1, budget: budget))
                }
                pairs.append(("layers", .array(children)))
                if children.count < listed.count { pairs.append(("layersNotListed", .number(listed.count - children.count))) }
            } else if count > 0 {
                pairs.append(("layersInside", .number(count)))
            }
        }
        return .compact(pairs)
    }

    private static func style(of node: Node) -> [(String, JSONValue?)] {
        var pairs: [(String, JSONValue?)] = []
        // Several of a kind are a list, bottom first.
        if node.kind != .group {
            let fills = node.fills
            pairs.append(("fill", fills.count > 1 ? .array(fills.map(fill)) : fill(node.fill)))
        }
        func border(_ b: Border) -> JSONValue {
            .compact([
                ("color", .string(hex(b.color))), ("width", .number(b.width)), ("position", .string(b.position.rawValue)),
                ("dash", b.dash > 0 ? .number(b.dash) : nil), ("gap", b.dash > 0 ? .number(b.gap) : nil),
            ])
        }
        let borders = node.borders
        if !borders.isEmpty { pairs.append(("border", borders.count > 1 ? .array(borders.map(border)) : border(borders[0]))) }
        func shadow(_ s: Shadow) -> JSONValue {
            .compact([
                ("color", .string(hex(s.color))), ("x", .number(s.x)), ("y", .number(s.y)), ("blur", .number(s.blur)),
                ("spread", s.grown != 0 ? .number(s.grown) : nil), ("inset", s.inside ? .bool(true) : nil),
            ])
        }
        let shadows = node.shadows
        if !shadows.isEmpty { pairs.append(("shadow", shadows.count > 1 ? .array(shadows.map(shadow)) : shadow(shadows[0]))) }
        if node.opacity != 1 { pairs.append(("opacity", .number(node.opacity))) }
        if node.kind == .rectangle {
            if let corners = node.corners, corners.count == 4 {
                pairs.append(("cornerRadius", .array(corners.map { .number($0) })))
            } else if node.cornerRadius > 0 {
                pairs.append(("cornerRadius", .number(node.cornerRadius)))
            }
            if let smoothing = node.cornerSmoothing, smoothing > 0 { pairs.append(("cornerSmoothing", .number(smoothing))) }
        }
        if node.kind == .text, let t = node.style {
            pairs.append(("font", .compact([
                ("family", .string(t.family)), ("face", .string(t.face)), ("size", .number(t.size)), ("align", .string(t.align.rawValue)),
                ("lineSpacing", t.lineSpacing.map { .number($0) }), ("tracking", t.tracking != 0 ? .number(t.tracking) : nil),
                ("underline", t.underline ? true : nil), ("sizing", .string(sizingName(t.sizing))), ("case", t.letterCase.map { .string($0.rawValue) }),
                ("strikethrough", t.strikethrough == true ? true : nil), ("paragraphSpacing", t.paragraphSpacing.map { .number($0) }),
                ("vertical", t.vertical.map { .string($0.rawValue) }),
                ("features", t.features.map { f in .object(f.keys.sorted().map { ($0, .number(f[$0] ?? 0)) }) }),
                ("axes", t.axes.map { a in .object(a.keys.sorted().map { ($0, .number(round(a[$0] ?? 0))) }) }),
            ])))
            if node.hasStyledLetters { pairs.append(("spans", .array(node.runs.map(span)))) }
        }
        if let blur = node.blur, blur.on {
            pairs.append(("blur", .compact([
                ("radius", .number(blur.radius)), ("background", blur.background ? true : nil),
                ("brightness", blur.background && blur.brightness != 0 ? .number(blur.brightness) : nil),
                ("fillOpacity", blur.background && blur.fillOpacity != 0 ? .number(blur.fillOpacity) : nil),
                ("ramp", blur.ramp.map { .object([("start", point($0.start)), ("end", point($0.end))]) }),
            ])))
        }
        if let t = node.transform3D {
            pairs.append(("transform3D", ["x": .number(t.x), "y": .number(t.y), "z": .number(t.z)]))
        }
        if let blend = node.blend { pairs.append(("blend", .string(blend.rawValue))) }
        if node.isArtboard && !node.clips { pairs.append(("clips", false)) }
        if node.kind == .line {
            let (a, b) = node.lineEnds
            pairs += [("x1", .number(round(a.x))), ("y1", .number(round(a.y))), ("x2", .number(round(b.x))), ("y2", .number(round(b.y)))]
        }
        if node.kind == .path, let data = node.path {
            pairs.append(("path", .string(placedPath(data, of: node))))
            if node.evenOdd == true { pairs.append(("evenOdd", true)) }
        }
        if node.mask?.isEmpty == false { pairs.append(("masked", true)) }
        if let exports = node.exports, !exports.isEmpty { pairs.append(("exports", Self.exports(exports))) }
        return pairs
    }

    /// Export presets as the exports property takes them back.
    static func exports(_ presets: [ExportPreset]) -> JSONValue {
        .array(presets.map { p in
            .compact([("size", p.format.isPicture ? .string(p.size.text) : nil), ("format", .string(p.format.rawValue)),
                      ("suffix", p.suffix.map { .string($0) }), ("file", .string("<name>\(p.nameSuffix).\(p.format.fileExtension)"))])
        })
    }

    /// Reads the exports property: presets, or nothing to unmark the layer.
    private static func exports(_ v: Any?) throws -> [ExportPreset]? {
        guard let v else { return nil }
        if let s = v as? String, ["none", ""].contains(s.lowercased()) { return nil }
        guard let list = v as? [Any] else { throw MCPError("exports should be a list of {size, format, suffix}, or \"none\".") }
        let presets = try list.map { item -> ExportPreset in
            // A size alone is a PNG; a format alone is 1×.
            if let s = item as? String {
                if let f = try? format(s) { return ExportPreset(format: f) }
                guard let size = ExportSize(s) else { throw MCPError("\"\(s)\" is neither a size (\"2x\", \"512w\", \"64h\") nor a format.") }
                return ExportPreset(size: size)
            }
            if let n = item as? NSNumber, let size = ExportSize("\(n)x") { return ExportPreset(size: size) }
            guard let o = item as? [String: Any] else { throw MCPError("Each export should be {size, format, suffix}.") }
            let unknown = Set(o.keys).subtracting(["size", "format", "suffix", "file"])
            guard unknown.isEmpty else { throw MCPError("An export has no \(unknown.sorted().joined(separator: ", ")). It takes size, format and suffix.") }
            var preset = ExportPreset()
            if let s = o["size"], !(s is NSNull) {
                let text = (s as? NSNumber).map { "\($0)x" } ?? (s as? String) ?? ""
                guard let size = ExportSize(text) else { throw MCPError("size \"\(text)\" should be pixels to a point, \"2x\", or pixels wide or tall, \"512w\" or \"64h\".") }
                preset.size = size
            }
            if let f = try Read.string(o["format"], "format") { preset.format = try format(f) }
            preset.suffix = try Read.string(o["suffix"], "suffix")
            return preset
        }
        return presets.isEmpty ? nil : presets
    }

    /// A format by its name, as export and exports take it.
    static func format(_ word: String) throws -> ExportFormat {
        let w = word.lowercased()
        guard let f = ExportFormat(rawValue: w == "jpg" ? "jpeg" : w) else {
            throw MCPError("There is no format \(word). There are: \(ExportFormat.offered.map(\.rawValue).joined(separator: ", ")).")
        }
        guard f.isAvailable else { throw MCPError("This Mac cannot write \(f.title) files. It can write \(ExportFormat.offered.map(\.rawValue).joined(separator: ", ")).") }
        return f
    }

    static func fill(_ f: Fill) -> JSONValue {
        guard f.on else { return "none" }
        if f.gradient == nil && f.image == nil { return .string(hex(f.color)) }
        var pairs: [(String, JSONValue?)] = [("color", .string(hex(f.color)))]
        if let g = f.gradient {
            var gradient: [(String, JSONValue?)] = [
                ("type", .string(g.kind.rawValue)),
                ("stops", .array(g.stops.map { ["offset": .number($0.offset), "color": .string(hex($0.color))] })),
                ("start", point(g.start)),
            ]
            if g.kind == .linear || g.across != nil { gradient.append(("end", point(g.end))) }
            if g.kind == .radial { gradient.append(g.across.map { ("across", point($0)) } ?? ("radius", .number(g.radius))) }
            pairs.append(("gradient", .compact(gradient)))
        }
        if let i = f.image {
            pairs.append(("image", .compact([
                ("file", .string(i.asset)), ("mode", .string(i.mode.rawValue)),
                ("pixelWidth", .number(i.size.width)), ("pixelHeight", .number(i.size.height)),
                ("offset", i.offset != .zero ? point(i.offset) : nil), ("scale", i.scale != 1 ? .number(i.scale) : nil),
                ("backgroundRemoved", i.cutout != nil ? .bool(true) : nil),
                ("develop", Self.describe(i.develop)),
            ])))
        }
        return .compact(pairs)
    }

    /// A path's outline in its parent, as it lies before it is turned: what `path` takes back.
    private static func placedPath(_ data: String, of node: Node) -> String {
        let box = node.pathBox ?? PathData.bounds(data)
        let t = CGAffineTransform(translationX: node.frame.minX, y: node.frame.minY)
            .scaledBy(x: box.width > 0 ? node.frame.width / box.width : 1, y: box.height > 0 ? node.frame.height / box.height : 1)
            .translatedBy(x: -box.minX, y: -box.minY)
        return PathData.transformed(data, t)
    }

    static func hex(_ c: RGBA) -> String {
        c.a < 0.999 ? "#\(c.hex)\(String(format: "%02X", Int((min(max(c.a, 0), 1) * 255).rounded())))" : "#\(c.hex)"
    }

    static func rect(_ r: CGRect) -> JSONValue {
        ["x": .number(round(r.minX)), "y": .number(round(r.minY)), "width": .number(round(r.width)), "height": .number(round(r.height))]
    }

    private static func point(_ p: CGPoint) -> JSONValue { ["x": .number(round(p.x, 4)), "y": .number(round(p.y, 4))] }

    private static func round(_ v: CGFloat, _ places: Int = 2) -> CGFloat {
        let k = pow(10, CGFloat(places))
        return (v * k).rounded() / k
    }

    private static func round(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Some letters and how they differ from the rest of their text, as `spans` takes them.
    private static func span(_ s: TextSpan) -> JSONValue {
        let l = s.look
        return .compact([
            ("text", .string(s.text)), ("family", l.family.map { .string($0) }), ("face", l.face.map { .string($0) }),
            ("size", l.size.map { .number($0) }), ("color", l.color.map { .string(hex($0)) }),
            ("underline", l.underline.map { .bool($0) }), ("strikethrough", l.strikethrough.map { .bool($0) }),
            ("tracking", l.tracking.map { .number($0) }), ("list", l.list.map { .string($0.rawValue) }),
        ])
    }

    private static func sizingName(_ s: TextSizing) -> String {
        switch s {
        case .autoWidth: "auto"
        case .autoHeight: "fixedWidth"
        case .fixed: "fixed"
        }
    }

    // MARK: Changing

    static let propertyKeys: Set<String> = [
        "name", "x", "y", "width", "height", "rotation", "opacity", "hidden", "locked", "fill", "border", "shadow",
        "cornerRadius", "cornerSmoothing", "text", "spans", "font", "blur", "transform3D", "blend", "x1", "y1", "x2", "y2", "path", "evenOdd",
        "clips", "preset", "carousel", "slides", "exports",
    ]

    /// Changes a layer as `props` say, as the inspector would. What does not apply to this kind
    /// of layer is left out, with a warning; what makes no sense at all is an error.
    static func apply(_ props: [String: Any], to node: inout Node, warnings: inout [String], ignoring: Set<String> = []) throws {
        let unknown = Set(props.keys).subtracting(propertyKeys).subtracting(ignoring)
        guard unknown.isEmpty else {
            throw MCPError("Layers have no \(unknown.sorted().joined(separator: ", ")). They take: \(propertyKeys.sorted().joined(separator: ", ")).")
        }
        func has(_ key: String) -> Bool { props.keys.contains(key) }
        func value(_ key: String) -> Any? { props[key].flatMap { $0 is NSNull ? nil : $0 } }
        func num(_ key: String) throws -> CGFloat? { try Read.number(value(key), key).map { CGFloat($0) } }
        let name = node.name, kind = node.kind
        func only(_ kinds: [Node.Kind], _ key: String) -> Bool {
            guard has(key) else { return false }
            if kinds.contains(kind) { return true }
            warnings.append("\(key) is for \(kinds.map(\.rawValue).joined(separator: " and ")) layers: left out on \(name), which is a \(kind.rawValue).")
            return false
        }

        if has("name") {
            guard let s = try Read.string(value("name"), "name")?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { throw MCPError("name cannot be empty.") }
            node.name = s
        }

        // What decides the size, before the size itself.
        if only([.artboard], "preset"), let p = try Read.string(value("preset"), "preset") {
            guard let preset = Preset.all.first(where: { $0.name.caseInsensitiveCompare(p) == .orderedSame }) else {
                throw MCPError("There is no artboard preset \"\(p)\". The presets: \(Preset.all.map { "\($0.name) (\(Int($0.size.width))×\(Int($0.size.height)))" }.joined(separator: ", ")).")
            }
            node.frame.size = preset.size
        }
        if only([.artboard], "carousel") {
            if let v = value("carousel") {
                let count = node.isCarousel ? node.slideCount : Carousel.startingCount
                node.slideSize = try carouselSlide(v)
                node.frame.size = node.carouselSize(count: count)
            } else {
                node.slideSize = nil
            }
        }
        if has("slides"), let n = try Read.number(value("slides"), "slides") {
            if node.isCarousel { node.frame.size = node.carouselSize(count: Int(n.rounded())) } else { warnings.append("slides is for carousels: \(name) is not one. Make it one with carousel.") }
        }
        if only([.text], "text") { node.text = try Read.string(value("text"), "text") ?? "" }
        if only([.text], "font"), let o = try Read.object(value("font"), "font") {
            var style = node.style ?? TextStyle()
            try applyFont(o, to: &style)
            node.style = style
        }
        if only([.text], "spans") {
            if let list = value("spans") {
                guard let items = list as? [Any] else { throw MCPError("spans should be a list of {text, …} runs, end to end.") }
                let style = node.style ?? TextStyle()
                node.setRuns(try items.enumerated().map { i, item in
                    guard let o = item as? [String: Any] else { throw MCPError("spans[\(i)] should be an object, {text, face, color…}.") }
                    return try textSpan(o, key: "spans[\(i)]", style: style, color: node.fill.color)
                })
            } else {
                node.spans = nil
            }
        }
        if only([.path], "path") {
            guard let data = try Read.string(value("path"), "path") else { throw MCPError("path cannot be empty.") }
            let box = PathData.bounds(data)
            guard !box.isNull, box.minX.isFinite, box.width.isFinite, box.height.isFinite else { throw MCPError("path should be SVG path data, such as \"M 0 0 L 100 0 L 50 80 Z\".") }
            node.path = data
            node.pathBox = box
            node.frame = box
        }
        if only([.path], "evenOdd") { node.evenOdd = try Read.bool(value("evenOdd"), "evenOdd") == true ? true : nil }
        let ends = ["x1", "y1", "x2", "y2"].filter(has)
        if let first = ends.first, only([.line], first) {
            var (a, b) = node.lineEnds
            if let v = try num("x1") { a.x = v }
            if let v = try num("y1") { a.y = v }
            if let v = try num("x2") { b.x = v }
            if let v = try num("y2") { b.y = v }
            node.setLineEnds(a, b)
        }

        // Where it is and how big.
        let x = try num("x"), y = try num("y"), w = try num("width"), h = try num("height")
        if (w ?? 0) < 0 || (h ?? 0) < 0 { throw MCPError("width and height cannot be less than 0.") }
        if w != nil || h != nil {
            let old = node.frame.size
            let size = CGSize(width: w ?? old.width, height: h ?? old.height)
            switch kind {
            case .text:
                if let w {
                    // As a width typed in does: the words wrap to it.
                    if node.style?.sizing == .autoWidth { node.style?.sizing = .autoHeight }
                    node.frame.size.width = w
                }
                if let h {
                    if node.style?.sizing == .fixed { node.frame.size.height = h } else {
                        warnings.append("Text is as tall as its words, unless font.sizing is \"fixed\": height left out on \(name). font.size makes the letters bigger.")
                    }
                }
            case .group:
                // A group's layers stretch with it.
                node.children = BezzleDocument.scaled(node.children, from: old, to: size)
                node.mask = node.mask.map { BezzleDocument.scaled($0, from: old, to: size) }
                node.frame.size = size
            default:
                node.frame.size = size
            }
        }
        if let x { node.frame.origin.x = x }
        if let y { node.frame.origin.y = y }
        if let r = try Read.number(value("rotation"), "rotation") {
            // A repeat grid turns as one, its rows with it.
            if let turn = node.grid?.turn {
                node = RepeatGrid.turned(node, by: CanvasView.normalized(r) - turn, about: node.frame.center)
            } else if node.isContainer { warnings.append("\(kind == .group ? "A group" : "An artboard") is never turned itself: rotation left out on \(name). Turn its layers.") } else { node.rotation = CanvasView.normalized(r) }
        }

        // How it looks.
        // One changes the first, and "none" takes all of them away; a list is all of them,
        // bottom first, each merged into the one in its place.
        if has("fill") {
            if let list = value("fill") as? [Any] {
                if kind == .text && list.count > 1 { warnings.append("Text takes one colour: only the first fill kept on \(name).") }
                let fills = try list.enumerated().map { i, item in try fill(item, on: i < node.slots(.fill) ? node[fill: i] : Fill(color: .shape)) }
                node.fills = Array(fills.filter(\.on).prefix(kind == .text ? 1 : .max))
                if !node.fill.on { node.blend = nil }
            } else {
                node.fill = try fill(value("fill"), on: node.fill)
                if !node.fill.on { node.moreFills = nil }
            }
        }
        if has("border") {
            if let list = value("border") as? [Any] {
                let borders = try list.enumerated().map { i, item in
                    try border(item, on: i < node.slots(.border) ? node[border: i] : Border(on: true, color: .line, width: 1))
                }
                node.borders = borders.filter(\.on)
            } else {
                node.border = try border(value("border"), on: node.border)
                if !node.border.on { node.moreBorders = nil }
            }
        }
        if has("shadow") {
            if let list = value("shadow") as? [Any] {
                var shadows: [Shadow] = []
                for (i, item) in list.enumerated() {
                    var s = i < node.slots(.shadow) ? node[shadow: i] : Shadow()
                    try shadow(item, on: &s)
                    if s.on { shadows.append(s) }
                }
                node.shadows = shadows
            } else {
                try shadow(value("shadow"), on: &node.shadow)
                if !node.shadow.on { node.moreShadows = nil }
            }
            if kind == .line && node.shadows.contains(where: \.inside) {
                node.shadows = node.shadows.map { s in var s = s; s.inset = nil; return s }
                warnings.append("A line has no inside for a shadow to fall in: inset left out on \(name).")
            }
            if !Renderer.spreads(node, Shadow(spread: 1)) && node.shadows.contains(where: { $0.grown != 0 }) {
                warnings.append("Only a shape's shadow spreads: spread kept on \(name), but it casts from what it draws.")
            }
        }
        if let o = try Read.number(value("opacity"), "opacity") { node.opacity = min(max(o, 0), 1) }
        if only([.rectangle], "cornerRadius") { try corners(value("cornerRadius"), on: &node) }
        if only([.rectangle], "cornerSmoothing") {
            let s = try Read.number(value("cornerSmoothing"), "cornerSmoothing") ?? 0
            node.cornerSmoothing = s > 0 ? CGFloat(min(s, 1)) : nil
        }
        if has("blur") { try blur(value("blur"), on: &node) }
        if has("transform3D") {
            if node.isArtboard { warnings.append("An artboard is the page itself: transform3D left out on \(name). Turn its layers.") } else { try transform3D(value("transform3D"), on: &node) }
        }
        if has("blend") {
            if let b = try Read.string(value("blend"), "blend"), b.lowercased() != "normal" {
                guard let mode = BlendMode.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(b) == .orderedSame }) else {
                    throw MCPError("There is no blend mode \(b). There are: normal, \(BlendMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                node.blend = mode
            } else {
                node.blend = nil
            }
        }
        if let v = try Read.bool(value("hidden"), "hidden") { node.hidden = v }
        if let v = try Read.bool(value("locked"), "locked") { node.locked = v }
        if only([.artboard], "clips") { node.clips = try Read.bool(value("clips"), "clips") ?? true }
        if has("exports") { node.exports = try exports(value("exports")) }

        // Text takes the size its words need, its top left where it was asked to be.
        if kind == .text {
            node.refit()
            if let x { node.frame.origin.x = x }
            if let y { node.frame.origin.y = y }
        }
    }

    private static func carouselSlide(_ v: Any) throws -> CGSize {
        if let name = v as? String {
            let n = name.lowercased()
            guard let format = Carousel.formats.first(where: { $0.name.lowercased() == n || $0.name.lowercased().hasPrefix(n + " ") || $0.name.lowercased().hasSuffix(" " + n) }) else {
                throw MCPError("There is no carousel format \"\(name)\". There are: \(Carousel.formats.map { "\($0.name) (\(Int($0.size.width))×\(Int($0.size.height)), \($0.platforms))" }.joined(separator: "; ")); or give {width, height}.")
            }
            return format.size
        }
        if let o = v as? [String: Any], let w = try Read.number(o["width"], "carousel.width"), let h = try Read.number(o["height"], "carousel.height"), w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        throw MCPError("carousel should be a format's name, such as \"Portrait 4:5\", or {width, height} of a slide.")
    }

    /// One run of a text's letters, from what the assistant gave: its words, and what about them
    /// differs from the rest of the text.
    static func textSpan(_ o: [String: Any], key: String, style: TextStyle, color: RGBA) throws -> TextSpan {
        let known: Set = ["text", "family", "face", "weight", "size", "color", "underline", "strikethrough", "tracking", "list"]
        let unknown = Set(o.keys).subtracting(known)
        guard unknown.isEmpty else { throw MCPError("\(key) has no \(unknown.sorted().joined(separator: ", ")). It takes: \(known.sorted().joined(separator: ", ")).") }
        guard let words = try Read.string(o["text"], "\(key).text") else { throw MCPError("\(key) needs its text.") }
        var letters = TextLook.plain.resolved(over: style, color: color)
        try restyle(&letters, from: o, key: key)
        return TextSpan(text: words, look: TextLook(letters, over: style, color: color))
    }

    /// Changes letters as an object of font, colour and the rest says, as `spans` and `style_text` take it.
    static func restyle(_ letters: inout Letters, from o: [String: Any], key: String) throws {
        func value(_ k: String) -> Any? { o[k].flatMap { $0 is NSNull ? nil : $0 } }
        if let family = try Read.string(value("family"), "\(key).family") {
            let match = ["system", "sf pro"].contains(family.lowercased()) ? TextStyle.system : Fonts.families.first { $0.caseInsensitiveCompare(family) == .orderedSame }
            guard let match else { throw MCPError("There is no font family \"\(family)\" on this Mac. list_fonts lists them.") }
            letters.face = Fonts.face(like: letters.face, of: letters.family, in: match)
            letters.family = match
        }
        if let face = try Read.string(value("face") ?? value("weight"), "\(key).face") {
            let faces = Fonts.faces(of: letters.family)
            guard let match = faces.first(where: { $0.caseInsensitiveCompare(face) == .orderedSame }) else {
                throw MCPError("\(Fonts.displayName(letters.family)) has no face \"\(face)\". It has: \(faces.joined(separator: ", ")).")
            }
            letters.face = match
        }
        if let size = try Read.number(value("size"), "\(key).size") {
            guard size > 0 else { throw MCPError("\(key).size should be more than 0.") }
            letters.size = CGFloat(size)
        }
        if let c = value("color") { letters.color = try color(c, "\(key).color") }
        if let u = try Read.bool(value("underline"), "\(key).underline") { letters.underline = u }
        if let u = try Read.bool(value("strikethrough"), "\(key).strikethrough") { letters.strikethrough = u }
        if let t = try Read.number(value("tracking"), "\(key).tracking") { letters.tracking = CGFloat(t) }
        if o.keys.contains("list") {
            let l = try Read.string(value("list"), "\(key).list")
            if let l, l.lowercased() != "none" {
                guard let list = TextList(rawValue: l.lowercased() == "numbered" ? "number" : l.lowercased() == "bulleted" ? "bullet" : l.lowercased()) else {
                    throw MCPError("\(key).list is bullet, number or none.")
                }
                letters.list = list
            } else {
                letters.list = nil
            }
        }
    }

    private static func applyFont(_ o: [String: Any], to style: inout TextStyle) throws {
        let known: Set = ["family", "face", "weight", "size", "align", "lineSpacing", "tracking", "underline", "sizing", "case",
                          "strikethrough", "paragraphSpacing", "vertical", "features", "axes"]
        let unknown = Set(o.keys).subtracting(known)
        guard unknown.isEmpty else { throw MCPError("font has no \(unknown.sorted().joined(separator: ", ")). It takes: \(known.sorted().joined(separator: ", ")).") }
        func value(_ key: String) -> Any? { o[key].flatMap { $0 is NSNull ? nil : $0 } }
        if let family = try Read.string(value("family"), "font.family") {
            let match = ["system", "sf pro"].contains(family.lowercased()) ? TextStyle.system : Fonts.families.first { $0.caseInsensitiveCompare(family) == .orderedSame }
            guard let match else { throw MCPError("There is no font family \"\(family)\" on this Mac. list_fonts lists them.") }
            style.family = match
            let faces = Fonts.faces(of: match)
            if !faces.contains(style.face) { style.face = faces.contains("Regular") ? "Regular" : faces.first ?? "Regular" }
        }
        if let face = try Read.string(value("face") ?? value("weight"), "font.face") {
            let faces = Fonts.faces(of: style.family)
            guard let match = faces.first(where: { $0.caseInsensitiveCompare(face) == .orderedSame }) else {
                throw MCPError("\(Fonts.displayName(style.family)) has no face \"\(face)\". It has: \(faces.joined(separator: ", ")).")
            }
            style.face = match
        }
        if let size = try Read.number(value("size"), "font.size") {
            guard size > 0 else { throw MCPError("font.size should be more than 0.") }
            style.size = CGFloat(size)
        }
        if let a = try Read.string(value("align"), "font.align") {
            let named = a.lowercased() == "centre" ? "center" : a.lowercased() == "justified" ? "justify" : a.lowercased()
            guard let align = TextAlign(rawValue: named) else { throw MCPError("font.align is left, center, right or justify.") }
            style.align = align
        }
        if o.keys.contains("lineSpacing") { style.lineSpacing = try Read.number(value("lineSpacing"), "font.lineSpacing").map { CGFloat(max($0, 0)) } }
        if let t = try Read.number(value("tracking"), "font.tracking") { style.tracking = CGFloat(t) }
        if let u = try Read.bool(value("underline"), "font.underline") { style.underline = u }
        if let s = try Read.string(value("sizing"), "font.sizing") {
            switch s.lowercased() {
            case "auto", "autowidth": style.sizing = .autoWidth
            case "fixedwidth", "autoheight": style.sizing = .autoHeight
            case "fixed", "fixedsize": style.sizing = .fixed
            default: throw MCPError("font.sizing is \"auto\" (as wide as the words), \"fixedWidth\" (wrapped at its width, as tall as the words) or \"fixed\" (a box of set size).")
            }
        }
        if o.keys.contains("case") {
            let c = try Read.string(value("case"), "font.case")
            if let c, c.lowercased() != "none" {
                guard let letterCase = LetterCase.allCases.first(where: { $0.rawValue.lowercased() == c.lowercased().replacingOccurrences(of: "_", with: "") }) else {
                    throw MCPError("font.case is upper, lower, title, smallCaps or none.")
                }
                style.letterCase = letterCase
            } else {
                style.letterCase = nil
            }
        }
        if let u = try Read.bool(value("strikethrough"), "font.strikethrough") { style.strikethrough = u ? true : nil }
        if o.keys.contains("paragraphSpacing") {
            style.paragraphSpacing = try Read.number(value("paragraphSpacing"), "font.paragraphSpacing").flatMap { $0 > 0 ? CGFloat($0) : nil }
        }
        if o.keys.contains("vertical") {
            let v = try Read.string(value("vertical"), "font.vertical")?.lowercased()
            if let v, v != "top" {
                guard let vertical = TextVertical(rawValue: v == "center" || v == "centre" ? "middle" : v) else { throw MCPError("font.vertical is top, middle or bottom.") }
                style.vertical = vertical
            } else {
                style.vertical = nil
            }
        }
        if o.keys.contains("features") {
            if let f = try Read.object(value("features"), "font.features") {
                var features = style.features ?? [:]
                for (tag, v) in f {
                    guard tag.count == 4 else { throw MCPError("font.features are OpenType tags of four letters, such as \"onum\", \"tnum\" or \"ss01\".") }
                    if v is NSNull { features[tag] = nil; continue }
                    if let b = try? Read.bool(v, "font.features.\(tag)") { features[tag] = b == true ? 1 : 0; continue }
                    guard let n = try Read.number(v, "font.features.\(tag)") else { continue }
                    features[tag] = Int(n)
                }
                style.features = features.isEmpty ? nil : features
            } else {
                style.features = nil
            }
        }
        if o.keys.contains("axes") {
            if let a = try Read.object(value("axes"), "font.axes") {
                var axes = style.axes ?? [:]
                for (tag, v) in a {
                    guard tag.count == 4 else { throw MCPError("font.axes are a variable font's axes by their tags of four letters, such as \"wght\" or \"wdth\".") }
                    axes[tag] = try Read.number(v, "font.axes.\(tag)")
                }
                style.axes = axes.isEmpty ? nil : axes
            } else {
                style.axes = nil
            }
        }
    }

    static func color(_ v: Any?, _ key: String) throws -> RGBA {
        guard let s = v as? String else { throw MCPError("\(key) should be a colour, such as \"#1E88E5\" or \"#1E88E580\".") }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "white": return .white
        case "black": return .black
        case "transparent", "clear": return RGBA(r: 0, g: 0, b: 0, a: 0)
        default: break
        }
        if t.hasPrefix("rgb") {
            let numbers = t.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
            guard numbers.count == 3 || numbers.count == 4 else { throw MCPError("\(key): \(s) is not a colour.") }
            return RGBA(r: numbers[0] / 255, g: numbers[1] / 255, b: numbers[2] / 255, a: numbers.count == 4 ? numbers[3] : 1)
        }
        var digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if digits.count == 4 || digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        var alpha = 1.0
        if digits.count == 8, let a = UInt8(digits.suffix(2), radix: 16) {
            alpha = Double(a) / 255
            digits = String(digits.prefix(6))
        }
        guard let c = RGBA(hex: digits, alpha: alpha) else { throw MCPError("\(key): \(s) is not a colour. Use \"#RRGGBB\", or \"#RRGGBBAA\" with transparency.") }
        return c
    }

    private static func fill(_ v: Any?, on current: Fill) throws -> Fill {
        var f = current
        guard let v else { f.on = false; return f }
        if let s = v as? String {
            if s.lowercased() == "none" { f.on = false; return f }
            // A colour on its own is a solid fill, in place of a gradient or picture.
            f.color = try color(s, "fill")
            f.gradient = nil
            f.image = nil
            f.on = true
            return f
        }
        guard let o = v as? [String: Any] else { throw MCPError("fill should be a colour, \"none\", or {color, gradient, image}.") }
        let unknown = Set(o.keys).subtracting(["on", "color", "gradient", "image"])
        guard unknown.isEmpty else { throw MCPError("fill has no \(unknown.sorted().joined(separator: ", ")). It takes on, color, gradient and image.") }
        if let c = o["color"], !(c is NSNull) { f.color = try color(c, "fill.color") }
        if o.keys.contains("gradient") { f.gradient = o["gradient"] is NSNull ? nil : try gradient(o["gradient"]) }
        if o.keys.contains("image") {
            if o["image"] is NSNull {
                f.image = nil
            } else {
                guard var image = f.image else { throw MCPError("There is no picture in this fill to change: place_image puts one in.") }
                guard let p = try Read.object(o["image"], "fill.image") else { throw MCPError("fill.image should be {mode, offset, scale}.") }
                if let m = try Read.string(p["mode"], "fill.image.mode") {
                    guard let mode = ImageFill.Mode(rawValue: m.lowercased()) else { throw MCPError("fill.image.mode is cover, fit or stretch.") }
                    image.mode = mode
                }
                if let offset = try Read.point(p["offset"], "fill.image.offset") { image.offset = CGPoint(x: min(max(offset.x, -1), 1), y: min(max(offset.y, -1), 1)) }
                if let s = try Read.number(p["scale"], "fill.image.scale") { image.scale = CGFloat(max(s, 1)) }
                f.image = image
            }
        }
        f.on = try Read.bool(o["on"], "fill.on") ?? true
        return f
    }

    private static func gradient(_ v: Any?) throws -> Gradient {
        guard let o = v as? [String: Any] else { throw MCPError("fill.gradient should be {type, stops, angle} or null.") }
        let unknown = Set(o.keys).subtracting(["type", "stops", "angle", "start", "end", "radius"])
        guard unknown.isEmpty else { throw MCPError("fill.gradient has no \(unknown.sorted().joined(separator: ", ")). It takes type, stops, angle, start, end and radius.") }
        let type = try Read.string(o["type"], "fill.gradient.type")?.lowercased() ?? "linear"
        guard let kind = Gradient.Kind(rawValue: type) else { throw MCPError("fill.gradient.type is linear or radial.") }
        guard let list = o["stops"] as? [Any], list.count >= 2 else { throw MCPError("fill.gradient.stops should be two colours or more.") }
        var stops: [GradientStop] = []
        for (i, item) in list.enumerated() {
            if let o = item as? [String: Any] {
                let offset = try Read.number(o["offset"], "fill.gradient.stops.offset") ?? Double(i) / Double(list.count - 1)
                stops.append(GradientStop(offset: min(max(offset, 0), 1), color: try color(o["color"], "fill.gradient.stops.color")))
            } else {
                stops.append(GradientStop(offset: Double(i) / Double(list.count - 1), color: try color(item, "fill.gradient.stops")))
            }
        }
        stops.sort { $0.offset < $1.offset }
        var g = Gradient(kind: kind, stops: stops, start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        if kind == .radial {
            g.start = CGPoint(x: 0.5, y: 0.5)
            g.end = CGPoint(x: 1, y: 0.5)
        }
        if kind == .linear, let angle = try Read.number(o["angle"], "fill.gradient.angle") {
            // As CSS counts it: 0 runs upward, 90 to the right, 180 downward.
            let r = angle * .pi / 180, d = CGPoint(x: sin(r) / 2, y: -cos(r) / 2)
            // To four places, so that 180 runs from 0.5 and not 0.49999…
            func tidy(_ v: CGFloat) -> CGFloat { (v * 10000).rounded() / 10000 }
            g.start = CGPoint(x: tidy(0.5 - d.x), y: tidy(0.5 - d.y))
            g.end = CGPoint(x: tidy(0.5 + d.x), y: tidy(0.5 + d.y))
        }
        if let p = try Read.point(o["start"], "fill.gradient.start") { g.start = p }
        if let p = try Read.point(o["end"], "fill.gradient.end") { g.end = p }
        if let r = try Read.number(o["radius"], "fill.gradient.radius") { g.radius = CGFloat(max(r, 0.001)) }
        return g
    }

    private static func border(_ v: Any?, on current: Border) throws -> Border {
        var b = current
        guard let v else { b.on = false; return b }
        if let s = v as? String {
            if s.lowercased() == "none" { b.on = false; return b }
            b.color = try color(s, "border")
            b.on = true
            return b
        }
        if let n = v as? NSNumber, !n.isBoolean {
            b.width = CGFloat(max(n.doubleValue, 0))
            b.on = true
            return b
        }
        guard let o = v as? [String: Any] else { throw MCPError("border should be \"none\", a colour, a width, or {color, width, position, dash, gap}.") }
        let unknown = Set(o.keys).subtracting(["on", "color", "width", "position", "dash", "gap"])
        guard unknown.isEmpty else { throw MCPError("border has no \(unknown.sorted().joined(separator: ", ")). It takes on, color, width, position, dash and gap.") }
        if let c = o["color"], !(c is NSNull) { b.color = try color(c, "border.color") }
        if let w = try Read.number(o["width"], "border.width") { b.width = CGFloat(max(w, 0)) }
        if let p = try Read.string(o["position"], "border.position") {
            guard let position = Border.Position(rawValue: p.lowercased() == "centre" ? "center" : p.lowercased()) else { throw MCPError("border.position is inside, center or outside.") }
            b.position = position
        }
        if let d = try Read.number(o["dash"], "border.dash") { b.dash = CGFloat(max(d, 0)) }
        if let g = try Read.number(o["gap"], "border.gap") { b.gap = CGFloat(max(g, 0)) }
        if b.dash > 0 && b.gap == 0 { b.gap = b.dash }
        b.on = try Read.bool(o["on"], "border.on") ?? true
        return b
    }

    private static func shadow(_ v: Any?, on shadow: inout Shadow) throws {
        guard let v else { shadow.on = false; return }
        if let s = v as? String {
            let word = s.lowercased()
            if word == "none" { shadow.on = false; return }
            let presets = Presets.shadows + Presets.innerShadows
            if let preset = presets.first(where: { $0.name.key.lowercased() == word || $0.id == "shadow-" + word }) {
                Presets.applyShadow(preset, to: &shadow)
                return
            }
            guard (try? color(s, "shadow")) != nil else {
                throw MCPError("shadow should be \"none\", a preset (\(presets.map { $0.name.key.lowercased() }.joined(separator: ", "))), a colour, or {color, x, y, blur, spread, inset}.")
            }
            shadow.color = try color(s, "shadow")
            shadow.on = true
            return
        }
        guard let o = v as? [String: Any] else { throw MCPError("shadow should be \"none\", a preset name, a colour, {color, x, y, blur, spread, inset}, or a list of these.") }
        let unknown = Set(o.keys).subtracting(["on", "color", "x", "y", "blur", "spread", "inset"])
        guard unknown.isEmpty else { throw MCPError("shadow has no \(unknown.sorted().joined(separator: ", ")). It takes on, color, x, y, blur, spread and inset.") }
        if let c = o["color"], !(c is NSNull) { shadow.color = try color(c, "shadow.color") }
        if let x = try Read.number(o["x"], "shadow.x") { shadow.x = CGFloat(x) }
        if let y = try Read.number(o["y"], "shadow.y") { shadow.y = CGFloat(y) }
        if let b = try Read.number(o["blur"], "shadow.blur") { shadow.blur = CGFloat(max(b, 0)) }
        if let d = try Read.number(o["spread"], "shadow.spread") { shadow.spread = d == 0 ? nil : CGFloat(d) }
        if let inset = try Read.bool(o["inset"], "shadow.inset") { shadow.inset = inset ? true : nil }
        shadow.on = try Read.bool(o["on"], "shadow.on") ?? true
    }

    private static func corners(_ v: Any?, on node: inout Node) throws {
        if let s = v as? String, s.lowercased() == "pill" {
            node.cornerRadius = Presets.cornerRadius(nil, for: node)
            node.corners = nil
        } else if let list = v as? [Any] {
            guard list.count == 4 else { throw MCPError("cornerRadius as a list is four radii: top left, top right, bottom right, bottom left.") }
            node.radii = try list.map { CGFloat(max(try Read.number($0, "cornerRadius") ?? 0, 0)) }
        } else {
            node.cornerRadius = CGFloat(max(try Read.number(v, "cornerRadius") ?? 0, 0))
            node.corners = nil
        }
    }

    private static func blur(_ v: Any?, on node: inout Node) throws {
        guard let v else { node.blur = nil; return }
        if let s = v as? String, s.lowercased() == "none" { node.blur = nil; return }
        if let n = v as? NSNumber, !n.isBoolean {
            if n.doubleValue <= 0 { node.blur = nil } else { Presets.applyBlur(CGFloat(n.doubleValue), to: &node) }
            return
        }
        guard let o = v as? [String: Any] else { throw MCPError("blur should be \"none\", a radius, or {radius, background, brightness, fillOpacity, ramp}.") }
        let unknown = Set(o.keys).subtracting(["on", "radius", "background", "brightness", "fillOpacity", "ramp"])
        guard unknown.isEmpty else { throw MCPError("blur has no \(unknown.sorted().joined(separator: ", ")). It takes on, radius, background, brightness, fillOpacity and ramp.") }
        var b = node.blur ?? Blur(radius: Presets.blurs[1].radius)
        if let r = try Read.number(o["radius"], "blur.radius") { b.radius = CGFloat(max(r, 0)) }
        if let bg = try Read.bool(o["background"], "blur.background") { b.background = bg }
        if let x = try Read.number(o["brightness"], "blur.brightness") { b.brightness = min(max(x, -1), 1) }
        if let x = try Read.number(o["fillOpacity"], "blur.fillOpacity") { b.fillOpacity = min(max(x, 0), 1) }
        if o.keys.contains("ramp") { b.ramp = try ramp(o["ramp"], from: b.ramp) }
        b.on = try Read.bool(o["on"], "blur.on") ?? true
        node.blur = b
    }

    /// A blur's ramp: "none" for an even blur; the edge it blurs toward, "bottom", "left", "top"
    /// or "right"; or {start, end} in the layer's box, 0 to 1, sharp at start and blurred at end.
    private static func ramp(_ v: Any?, from old: BlurRamp?) throws -> BlurRamp? {
        guard let v, !(v is NSNull) else { return nil }
        if let s = v as? String {
            if s.lowercased() == "none" { return nil }
            guard let edge = ["bottom", "left", "top", "right"].firstIndex(of: s.lowercased()) else {
                throw MCPError("blur.ramp should be \"none\", \"bottom\", \"left\", \"top\", \"right\", or {start, end}.")
            }
            return BlurRamp.toward(edge)
        }
        guard let o = v as? [String: Any] else { throw MCPError("blur.ramp should be \"none\", an edge such as \"bottom\", or {start, end}.") }
        var ramp = old ?? .down
        if let p = try Read.point(o["start"], "blur.ramp.start") { ramp.start = p }
        if let p = try Read.point(o["end"], "blur.ramp.end") { ramp.end = p }
        return ramp
    }

    private static func transform3D(_ v: Any?, on node: inout Node) throws {
        guard let v else { node.transform3D = nil; return }
        if let s = v as? String, s.lowercased() == "none" { node.transform3D = nil; return }
        guard let o = v as? [String: Any] else { throw MCPError("transform3D should be \"none\" or {x, y, z}.") }
        let unknown = Set(o.keys).subtracting(["x", "y", "z"])
        guard unknown.isEmpty else { throw MCPError("transform3D has no \(unknown.sorted().joined(separator: ", ")). It takes x, y and z.") }
        var t = node.transform3D ?? Transform3D()
        if let x = try Read.number(o["x"], "transform3D.x") { t.x = x }
        if let y = try Read.number(o["y"], "transform3D.y") { t.y = y }
        if let z = try Read.number(o["z"], "transform3D.z") { t.z = CGFloat(z) }
        node.transform3D = t
    }
}
