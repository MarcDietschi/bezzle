import AppKit

/// Reads Sketch files. A .sketch file is a ZIP archive with the document's shared parts, among
/// them the symbols it takes from libraries, a JSON file of layers for each page, and the
/// pictures. Everything Bezzle can draw comes across as it is; the rest comes as close as Bezzle
/// allows and is counted in the report.
enum SketchImporter {
    nonisolated static let fileExtension = "sketch"

    enum Failure: Error, LocalizedError {
        case notSketch
        case tooOld

        var errorDescription: String? {
            switch self {
            case .notSketch: String(localized: "This is not a Sketch file Bezzle can read.")
            case .tooOld: String(localized: "This file was saved by a Sketch older than version 43, which Bezzle cannot read. Open it in a newer Sketch, save it again, and bring that in.")
            }
        }
    }

    /// The design a Sketch file makes, its pictures still in the file.
    static func read(_ url: URL) throws -> Imported {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch ZipArchive.Failure.notAnArchive {
            // Before Sketch 43 a file was a database rather than an archive.
            let handle = try? FileHandle(forReadingFrom: url)
            let head = try? handle?.read(upToCount: 15)
            try? handle?.close()
            throw head == Data("SQLite format 3".utf8) ? Failure.tooOld : Failure.notSketch
        }
        guard archive.contains("document.json") else { throw Failure.notSketch }
        var converter = Converter(archive: archive)
        let doc = try converter.document()
        return Imported(document: doc, report: converter.report, archive: archive, pictures: converter.images, held: converter.held)
    }
}

private typealias JSON = [String: Any]

/// A number from the file, or `fallback` when there is none; never one too large to draw.
private func num(_ v: Any?, _ fallback: CGFloat = 0) -> CGFloat {
    let n: CGFloat = switch v {
    case let d as Double: CGFloat(d)
    case let i as Int: CGFloat(i)
    case let n as NSNumber: CGFloat(n.doubleValue)
    default: fallback
    }
    return n.isFinite ? min(max(n, -1e7), 1e7) : fallback
}

private func int(_ v: Any?, _ fallback: Int = 0) -> Int { Int(num(v, CGFloat(fallback))) }
private func dict(_ v: Any?) -> JSON { v as? JSON ?? [:] }
private func list(_ v: Any?) -> [JSON] { v as? [JSON] ?? [] }
private func enabled(_ part: JSON) -> Bool { part["isEnabled"] as? Bool ?? true }

/// A point as Sketch writes it: "{0.5, 1}".
private func point(_ v: Any?) -> CGPoint? {
    guard let s = v as? String else { return nil }
    let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).split(separator: ",")
        .map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite else { return nil }
    return CGPoint(x: min(max(x, -1e5), 1e5), y: min(max(y, -1e5), 1e5))
}

/// "BoldItalic" as a person writes it: "Bold Italic".
private func spaced(_ s: String) -> String {
    var out = ""
    for (i, c) in s.enumerated() {
        if i > 0, c.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
        out.append(c)
    }
    return out
}

/// What a symbol instance changes in the layers of its master, by the ids of the instances on the
/// way down to each, and the ids on the way down to the layers being read.
private struct Scope {
    var overrides: [String: Any] = [:]
    var path: [String] = []

    func value(_ path: [String], _ property: String) -> Any? {
        overrides.isEmpty ? nil : overrides[path.joined(separator: "/") + "_" + property]
    }
}

private struct Converter {
    let archive: ZipArchive
    var report = ImportReport(source: "Sketch")
    /// Pictures the design keeps: its file name there, and where it is in the archive.
    var images: [String: String] = [:]
    /// Pictures kept in the layers themselves, as older files do.
    var held: [String: Data] = [:]
    /// Symbol masters, on the pages and from libraries, by their symbol id.
    private var masters: [String: JSON] = [:]
    /// Shared layer and text styles, for the instances that swap them.
    private var styles: [String: JSON] = [:]
    /// Each picture once read: its file name in the design and its size in pixels.
    private var pictures: [String: (String, CGSize)?] = [:]
    /// The symbols being laid out, outermost first, so that one holding itself is caught.
    private var expanding: [String] = []
    /// How far down the layers being read are.
    private var depth = 0
    /// Colours are in Display P3 rather than sRGB.
    private var p3 = false
    private var fonts = FontMatch()
    /// How many masks have been made, to name each.
    private var masks = 0

    private static let shapes: Set<String> = ["rectangle", "oval", "shapePath", "polygon", "star", "triangle"]
    private static let blends: [Int: BlendMode] = [1: .darken, 2: .multiply, 3: .colorBurn, 4: .lighten, 5: .screen, 6: .colorDodge,
                                                   7: .overlay, 8: .softLight, 9: .hardLight, 10: .difference, 11: .exclusion,
                                                   12: .hue, 13: .saturation, 14: .color, 15: .luminosity]
    /// What instances change that Bezzle brings across.
    private static let overridden: Set<String> = ["stringValue", "symbolID", "image", "layerStyle", "textStyle", "flowDestination"]

    init(archive: ZipArchive) {
        self.archive = archive
    }

    mutating func document() throws -> BezzleDocument {
        guard let document = json("document.json") else { throw SketchImporter.Failure.notSketch }
        p3 = int(document["colorSpace"]) == 2
        var pages: [JSON] = []
        for ref in list(document["pages"]).compactMap({ $0["_ref"] as? String }) {
            guard let page = json(ref.hasSuffix(".json") ? ref : "\(ref).json") else {
                report.note("Pages that could not be read")
                continue
            }
            pages.append(page)
        }
        for e in pages.flatMap({ list($0["layers"]) }) + list(document["foreignSymbols"]).map({ dict($0["symbolMaster"]) })
        where e["_class"] as? String == "symbolMaster" {
            if let id = e["symbolID"] as? String, masters[id] == nil { masters[id] = e }
        }
        let shared = ["layerStyles", "layerTextStyles"].flatMap { list(dict(document[$0])["objects"]) }
            + ["foreignLayerStyles", "foreignTextStyles"].flatMap { list(document[$0]).map { dict($0["localSharedStyle"]) } }
        for s in shared {
            if let id = s["do_objectID"] as? String { styles[id] = dict(s["value"]) }
        }
        // The masters Sketch keeps on a page of their own are seen through their instances.
        if let i = pages.firstIndex(where: { $0["name"] as? String == "Symbols" }),
           Self.onlyShown(pages[i], elsewhere: pages.indices.filter { $0 != i }.map { pages[$0] }, masters: masters) {
            pages.remove(at: i)
        }

        var stacked: [[Node]] = []
        for page in pages {
            if !Self.guides(page["horizontalRulerData"]).isEmpty || !Self.guides(page["verticalRulerData"]).isEmpty {
                report.note("Guides on the canvas, left out")
            }
            var boards: [Node] = [], loose: [Node] = [], run: [JSON] = []
            for e in list(page["layers"]) {
                if ["artboard", "symbolMaster"].contains(e["_class"] as? String) {
                    loose += layers(run, into: .identity, scope: Scope())
                    run = []
                    boards.append(artboard(e))
                } else {
                    run.append(e)
                }
            }
            loose += layers(run, into: .identity, scope: Scope())
            // Artboards under the loose layers, as designs from XD have them.
            stacked.append(boards + loose)
        }
        var doc = BezzleDocument()
        doc.nodes = Importer.stack(stacked)
        doc.fitGroups()
        // No viewport: the canvas fits the design to itself when it first opens.
        return doc
    }

    private func json(_ name: String) -> JSON? {
        guard let data = try? archive.read(name) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSON
    }

    /// Whether a page holds nothing but symbol masters that instances on the other pages show,
    /// directly or inside other symbols, so that leaving it out loses nothing.
    private static func onlyShown(_ page: JSON, elsewhere: [JSON], masters: [String: JSON]) -> Bool {
        let layers = list(page["layers"])
        guard layers.allSatisfy({ $0["_class"] as? String == "symbolMaster" }) else { return false }
        var reached: Set<String> = []
        var queue = elsewhere.flatMap { list($0["layers"]) }
        while let e = queue.popLast() {
            if e["_class"] as? String == "symbolInstance" {
                let swaps = list(e["overrideValues"]).filter { ($0["overrideName"] as? String)?.hasSuffix("_symbolID") == true }
                for id in ([e["symbolID"]] + swaps.map { $0["value"] }).compactMap({ $0 as? String }) where reached.insert(id).inserted {
                    if let master = masters[id] { queue.append(master) }
                }
            }
            queue += list(e["layers"])
        }
        return layers.allSatisfy { reached.contains($0["symbolID"] as? String ?? "") }
    }

    // MARK: Layers

    private func frame(of e: JSON) -> CGRect {
        let f = dict(e["frame"])
        return CGRect(x: num(f["x"]), y: num(f["y"]), width: max(num(f["width"]), 0), height: max(num(f["height"]), 0))
    }

    /// Takes a layer's own coordinates, its frame's top left at zero, to its parent's: turned
    /// about its middle, Sketch counting degrees anticlockwise, then flipped there.
    private func transform(_ e: JSON) -> CGAffineTransform {
        let f = frame(of: e)
        var t = CGAffineTransform(translationX: -f.width / 2, y: -f.height / 2)
        let degrees = num(e["rotation"])
        if degrees != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180)) }
        let h = e["isFlippedHorizontal"] as? Bool == true, v = e["isFlippedVertical"] as? Bool == true
        if h || v { t = t.concatenating(CGAffineTransform(scaleX: h ? -1 : 1, y: v ? -1 : 1)) }
        return t.concatenating(CGAffineTransform(translationX: f.midX, y: f.midY))
    }

    private mutating func artboard(_ e: JSON) -> Node {
        var board = Node(kind: .artboard, frame: frame(of: e))
        if let name = e["name"] as? String, !name.isEmpty { board.name = name }
        report.artboards += 1
        board.fill = e["hasBackgroundColor"] as? Bool == true ? Fill(color: color(e["backgroundColor"])) : Fill(on: false, color: .white)
        board.children = layers(list(e["layers"]), into: .identity, scope: Scope())
        board.layout = layoutGrid(dict(e["layout"]), grid: dict(e["grid"]), size: board.frame.size)
        // The guides pulled out of the ruler across the top run down the artboard, and those out
        // of the one down its side run across it.
        board.guides = ImportLayout.guides(across: Self.guides(e["horizontalRulerData"]), down: Self.guides(e["verticalRulerData"]), in: board.frame.size)
        if e["isVisible"] as? Bool == false { board.hidden = true }
        if e["isLocked"] as? Bool == true { board.locked = true }
        return board
    }

    /// Layers side by side in one parent, bottom first. A layer that is a mask cuts off those
    /// above it, up to one that breaks the chain; they become a mask of Bezzle's with it as its
    /// shape, drawn under them as Sketch draws an outline mask. An alpha mask is not drawn.
    private mutating func layers(_ list: [JSON], into outer: CGAffineTransform, scope: Scope) -> [Node] {
        var out: [Node] = []
        var cut: (shape: Node, drawn: Bool, held: [Node])?
        func close(_ out: inout [Node], _ cut: inout (shape: Node, drawn: Bool, held: [Node])?) {
            defer { cut = nil }
            guard let (shape, drawn, held) = cut else { return }
            // A mask that cuts nothing is only its shape, as Sketch draws it.
            guard !held.isEmpty else {
                if drawn { out.append(shape) }
                return
            }
            if let holder = ImportMask.holder(shape, drawn: drawn) {
                // A group is drawn as it is, and cut by an outline round it.
                let shown = shape.isGroup && drawn ? [shape] : []
                if let mask = ImportMask.mask(holder, holding: shown + held, name: maskName()) { out.append(mask) }
                if drawn, !holder.borders.isEmpty || !holder.innerShadows.isEmpty {
                    report.note("Borders and inner shadows of masks, drawn over what they hold")
                }
            } else {
                // Only a shape can hold others; anything else cuts by its box, as it always did.
                report.note("Masks of text or lines, cutting by their box")
                var g = Node(kind: .group, frame: .zero)
                g.mask = [shape]
                g.children = (drawn ? [Self.renewed(shape)] : []) + held
                if !g.children.isEmpty { out.append(g) }
            }
        }
        for e in list {
            let visible = e["isVisible"] as? Bool ?? true
            if e["hasClippingMask"] as? Bool == true || e["shouldBreakMaskChain"] as? Bool == true { close(&out, &cut) }
            guard let n = convert(e, into: outer, scope: scope) else { continue }
            if e["hasClippingMask"] as? Bool == true, visible {
                let alpha = int(e["clippingMaskMode"]) == 1
                if alpha { report.note("Alpha masks, cutting by their outline") }
                cut = (n, !alpha, [])
            } else if cut != nil {
                cut?.held.append(n)
            } else {
                out.append(n)
            }
        }
        close(&out, &cut)
        return out
    }

    /// The name of the next mask: "Mask 1", "Mask 2", as Bezzle names its own.
    private mutating func maskName() -> String {
        masks += 1
        return String(localized: "Mask \(masks)")
    }

    /// What reaches past `box` is cut off there, as an artboard cuts it off: the layers become a
    /// mask whose shape is the background, or a clear edge where there is none.
    private func edged(_ g: inout Node, back: Node?, box: CGRect, _ m: CGAffineTransform) {
        let held = Array(g.children.dropFirst(back == nil ? 0 : 1))
        guard !held.isEmpty, var edge = back ?? rectangle(box, m, name: String(localized: "Edge"), color: .shape),
              ImportMask.reaches(held, outside: edge) else { return }
        if back == nil { ImportMask.clear(&edge) }
        g.children = [edge] + held
        g.clipsToFirst = true
    }

    /// Where the guides pulled out of a ruler lie, from its ruler data.
    private static func guides(_ ruler: Any?) -> [CGFloat] {
        (dict(ruler)["guides"] as? [Any] ?? []).map { num($0) }
    }

    /// The columns and rows an artboard is laid out on, from Sketch's layout settings. Sketch
    /// sets columns side by side in an area of a width of their own, starting at an offset from
    /// the left, with half a gutter outside the first and last when it says so; rows run from the
    /// top, each a number of gutters tall. Sketch's square grid has nothing in Bezzle to go to.
    private mutating func layoutGrid(_ layout: JSON, grid: JSON, size: CGSize) -> LayoutGrid? {
        if grid["isEnabled"] as? Bool == true, num(grid["gridSize"]) > 0 { report.note("Square grids, left out") }
        guard !layout.isEmpty, enabled(layout) else { return nil }
        var out = LayoutGrid()
        let count = int(layout["numberOfColumns"]), gutter = max(num(layout["gutterWidth"]), 0), column = max(num(layout["columnWidth"]), 0)
        if layout["drawVertical"] as? Bool ?? true, count > 0 {
            let start = num(layout["horizontalOffset"]) + (layout["guttersOutside"] as? Bool == true ? gutter / 2 : 0)
            out.columns = ImportLayout.track(count: count, size: column, gutter: gutter, start: start, along: size.width, report: &report)
        }
        let rowGutter = max(num(layout["gutterHeight"]), 0), row = rowGutter * max(num(layout["rowHeightMultiplication"]), 0)
        if layout["drawHorizontal"] as? Bool == true, row > 0 {
            // As many rows as fit down the artboard.
            let rows = max(Int(((size.height + rowGutter) / (row + rowGutter)).rounded(.down)), 1)
            out.rows = ImportLayout.track(count: rows, size: row, gutter: rowGutter, start: 0, along: size.height, report: &report)
        }
        return out.orNil
    }

    /// A copy of a layer, it and all it holds with ids of their own.
    private static func renewed(_ node: Node) -> Node {
        var n = node
        n.id = UUID()
        n.children = n.children.map(renewed)
        n.mask = n.mask?.map(renewed)
        return n
    }

    /// One layer and everything in it. `outer` takes the layer's parent's coordinates to those
    /// of the Bezzle layer it goes into; groups are never turned in Bezzle, so a group's own
    /// transform is handed down to what it holds.
    private mutating func convert(_ raw: JSON, into outer: CGAffineTransform, scope: Scope) -> Node? {
        guard depth < 200, report.layers < 500_000 else {
            report.note("Layers nested too deeply or too many, left out")
            return nil
        }
        depth += 1
        defer { depth -= 1 }
        var e = raw
        let path = scope.path + [e["do_objectID"] as? String ?? ""]
        for property in ["layerStyle", "textStyle"] {
            if let id = scope.value(path, property) as? String, let style = styles[id] { e["style"] = style }
        }
        let m = transform(e).concatenating(outer)
        let style = dict(e["style"])
        var node: Node?
        switch e["_class"] as? String {
        case let kind? where Self.shapes.contains(kind): node = shape(e, m, style: style, image: scope.value(path, "image"))
        case "shapeGroup": node = shapeGroup(e, m, image: scope.value(path, "image"))
        case "bitmap": node = bitmap(e, m, image: scope.value(path, "image"))
        case "text": node = text(e, m, string: scope.value(path, "stringValue") as? String, restyled: scope.value(path, "textStyle") != nil)
        case "group": node = group(e, m, scope: scope)
        case "symbolInstance": node = instance(e, m, scope: scope, path: path)
        case "artboard", "symbolMaster": node = inset(e, m, scope: scope)
        case "slice", "MSImmutableHotspotLayer": return nil
        default: report.note("Kinds of layer Bezzle does not know")
        }
        guard var n = node else { return nil }
        if let name = e["name"] as? String, !name.isEmpty { n.name = name }
        effects(&n, style)
        // Sketch casts a shape's shadow from its outline, Bezzle from what it draws.
        if [.rectangle, .ellipse, .path].contains(n.kind), !n.outerShadows.isEmpty, n.fills.isEmpty, n.borders.isEmpty {
            report.note("Shadows of shapes with no fill or border, not cast")
        }
        if e["isVisible"] as? Bool == false { n.hidden = true }
        if e["isLocked"] as? Bool == true { n.locked = true }
        n.exports = Self.exports(dict(e["exportOptions"]))
        report.layers += 1
        return n
    }

    /// What Sketch marks a layer to be exported as: its sizes, formats and suffixes. A format
    /// Bezzle does not write goes out as PNG; a name Sketch puts before the layer's has nowhere
    /// to go, so the file is named as Bezzle names it.
    private static func exports(_ options: JSON) -> [ExportPreset]? {
        let presets = list(options["exportFormats"]).map { f -> ExportPreset in
            let size: ExportSize? = switch int(f["visibleScaleType"]) {
            case 1: ExportSize("\(num(f["absoluteSize"]))w")
            case 2: ExportSize("\(num(f["absoluteSize"]))h")
            default: ExportSize("\(num(f["scale"], 1))x")
            }
            let word = (f["fileFormat"] as? String ?? "png").lowercased()
            let format = ExportFormat(rawValue: word == "jpg" ? "jpeg" : word).flatMap { $0.isAvailable ? $0 : nil } ?? .png
            var preset = ExportPreset(size: size ?? .scale(1), format: format)
            if int(f["namingScheme"]) == 0, let name = f["name"] as? String, name != preset.nameSuffix { preset.suffix = name }
            return preset
        }
        return presets.isEmpty ? nil : presets
    }

    private mutating func group(_ e: JSON, _ m: CGAffineTransform, scope: Scope) -> Node? {
        var g = Node(kind: .group, frame: .zero)
        g.children = layers(list(e["layers"]), into: m, scope: scope)
        if let tint = list(dict(e["style"])["fills"]).first(where: enabled) { self.tint(&g, tint) }
        return g.children.isEmpty ? nil : g
    }

    /// A group's fill tints all it holds: each layer keeps its shape and how clear it is, in the
    /// fill's colour, and so do their shadows.
    private mutating func tint(_ g: inout Node, _ fill: JSON) {
        guard int(fill["fillType"]) == 0 else {
            report.note("Groups tinted with a gradient or a picture, left untinted")
            return
        }
        var ink = color(fill["color"])
        ink.a *= opacity(fill)
        var pictures = false
        func tinted(_ node: Node) -> Node {
            var n = node
            if n.fill.image != nil { pictures = true }
            if n.fill.image == nil {
                n.fill.color = ink.with(alpha: (n.fill.gradient == nil ? n.fill.color.a : 1) * ink.a)
                n.fill.gradient = nil
            }
            n.moreFills = n.moreFills?.map { f in
                var f = f
                f.color = ink.with(alpha: (f.gradient == nil ? f.color.a : 1) * ink.a)
                f.gradient = nil
                return f
            }
            n.border.color = ink.with(alpha: n.border.color.a * ink.a)
            n.moreBorders = n.moreBorders?.map { b in var b = b; b.color = ink.with(alpha: b.color.a * ink.a); return b }
            n.shadow.color = ink.with(alpha: n.shadow.color.a * ink.a)
            n.moreShadows = n.moreShadows?.map { s in var s = s; s.color = ink.with(alpha: s.color.a * ink.a); return s }
            n.children = n.children.map(tinted)
            return n
        }
        g.children = g.children.map(tinted)
        if pictures { report.note("Tinted pictures, shown in their own colours") }
    }

    /// An artboard inside another layer, as Sketch's frames can be: a group on its background,
    /// cut off at its edges.
    private mutating func inset(_ e: JSON, _ m: CGAffineTransform, scope: Scope) -> Node? {
        let box = CGRect(origin: .zero, size: frame(of: e).size)
        var g = Node(kind: .group, frame: .zero)
        let back = e["hasBackgroundColor"] as? Bool == true ? rectangle(box, m, color: color(e["backgroundColor"])) : nil
        g.children = [back].compactMap { $0 } + layers(list(e["layers"]), into: m, scope: scope)
        edged(&g, back: back, box: box, m)
        return g.children.isEmpty ? nil : g
    }

    /// A plain rectangle of `box`, for backgrounds and the edges things are cut off at.
    private func rectangle(_ box: CGRect, _ m: CGAffineTransform, name: String = String(localized: "Background"), color: RGBA) -> Node? {
        var n: Node
        if let placed = ImportGeometry.place(box, m) {
            n = Node(kind: .rectangle, name: name, frame: placed.frame)
            n.rotation = placed.rotation
        } else {
            guard let outline = ImportGeometry.outline(PathData.string(CGPath(rect: box, transform: nil)), m) else { return nil }
            n = outline
            n.name = name
        }
        n.fill = Fill(color: color)
        return n
    }

    // MARK: Symbols

    /// A symbol instance is a group of its master's layers, laid out again at the instance's size
    /// as their resizing constraints say, with the instance's own changes.
    private mutating func instance(_ e: JSON, _ m: CGAffineTransform, scope: Scope, path: [String]) -> Node? {
        let swapped = scope.value(path, "symbolID") as? String
        // A nested symbol swapped for none is not shown.
        if swapped == "" { return nil }
        guard let id = swapped ?? e["symbolID"] as? String, let master = masters[id] else {
            report.note("Symbol instances whose master is missing")
            return nil
        }
        guard !expanding.contains(id), expanding.count < 64 else {
            report.note("Symbols that hold themselves, left out")
            return nil
        }
        // An instance's own changes go by the ids inside it; changes from instances further out
        // were set later, so they win.
        var inner = Scope(overrides: scope.overrides, path: expanding.isEmpty ? [] : path)
        let prefix = inner.path.isEmpty ? "" : inner.path.joined(separator: "/") + "/"
        for v in list(e["overrideValues"]) {
            guard let name = v["overrideName"] as? String, let value = v["value"] else { continue }
            if inner.overrides[prefix + name] == nil { inner.overrides[prefix + name] = value }
            if let property = name.split(separator: "_").last, !Self.overridden.contains(String(property)) {
                report.note("Symbol overrides Bezzle does not know, left as in the master")
            }
        }
        if e["overrideValues"] == nil, !dict(e["overrides"]).isEmpty {
            report.note("Symbol overrides in an older form, left as in the master")
        }
        let k = num(e["scale"], 1) > 0 ? num(e["scale"], 1) : 1
        let size = frame(of: e).size, source = frame(of: master).size
        let target = CGSize(width: size.width / k, height: size.height / k)
        let into = CGAffineTransform(scaleX: k, y: k).concatenating(m)
        var g = Node(kind: .group, frame: .zero)
        let box = CGRect(origin: .zero, size: target)
        let back = master["hasBackgroundColor"] as? Bool == true && master["includeBackgroundColorInInstance"] as? Bool == true
            ? rectangle(box, into, color: color(master["backgroundColor"])) : nil
        let content = Self.resized(list(master["layers"]), from: source, to: target)
        expanding.append(id)
        g.children = [back].compactMap { $0 } + layers(content, into: into, scope: inner)
        expanding.removeLast()
        // The master is an artboard, so what reaches past its edges is cut off there.
        edged(&g, back: back, box: box, into)
        return g.children.isEmpty ? nil : g
    }

    /// Layers laid out again in a parent resized from `old` to `new`, as their resizing
    /// constraints say: each edge, and the size, either kept or moved with the parent. The parts
    /// of a combined shape all stretch with it.
    private static func resized(_ layers: [JSON], from old: CGSize, to new: CGSize, stretching: Bool = false, level: Int = 0) -> [JSON] {
        guard abs(old.width - new.width) > 0.001 || abs(old.height - new.height) > 0.001, level < 200 else { return layers }
        return layers.map { l in
            var l = l, f = dict(l["frame"])
            // Each bit set lets that edge or size move: right, width, left, bottom, height, top.
            let c = stretching ? 63 : int(l["resizingConstraint"], 63)
            let x = num(f["x"]), y = num(f["y"]), w = max(num(f["width"]), 0), h = max(num(f["height"]), 0)
            let across = axis(x, w, old.width, new.width, start: c & 4 == 0, size: c & 2 == 0, end: c & 1 == 0)
            let down = axis(y, h, old.height, new.height, start: c & 32 == 0, size: c & 16 == 0, end: c & 8 == 0)
            f["x"] = across.0
            f["width"] = across.1
            f["y"] = down.0
            f["height"] = down.1
            l["frame"] = f
            let kind = l["_class"] as? String
            if kind == "group" || kind == "shapeGroup" {
                l["layers"] = resized(list(l["layers"]), from: CGSize(width: w, height: h), to: CGSize(width: across.1, height: down.1),
                                      stretching: kind == "shapeGroup", level: level + 1)
            }
            return l
        }
    }

    /// Where a layer starts along one side of its parent, and how long it is, once the parent
    /// has grown from `old` to `new`: what is pinned stays, and what is not shares the change.
    private static func axis(_ start: CGFloat, _ length: CGFloat, _ old: CGFloat, _ new: CGFloat,
                             start pinStart: Bool, size pinSize: Bool, end pinEnd: Bool) -> (CGFloat, CGFloat) {
        guard old > 0 else { return (start, length) }
        let end = old - start - length
        switch (pinStart, pinSize, pinEnd) {
        case (true, true, _): return (start, length)
        case (true, false, true): return (start, max(new - start - end, 0))
        case (false, true, true): return (new - end - length, length)
        case (true, false, false):
            return (start, old - start > 0 ? length * (new - start) / (old - start) : length)
        case (false, false, true):
            let grown = old - end > 0 ? length * (new - end) / (old - end) : length
            return (new - end - grown, grown)
        case (false, true, false): return ((start + length / 2) * new / old - length / 2, length)
        case (false, false, false): return (start * new / old, length * new / old)
        }
    }

    // MARK: Shapes

    private mutating func shape(_ e: JSON, _ m: CGAffineTransform, style: JSON, image: Any?) -> Node? {
        let size = frame(of: e).size, box = CGRect(origin: .zero, size: size)
        let edited = e["edited"] as? Bool == true
        switch e["_class"] as? String {
        case "rectangle" where !edited:
            guard let placed = ImportGeometry.place(box, m) else { break }
            var n = Node(kind: .rectangle, frame: placed.frame)
            n.rotation = placed.rotation
            let s = min(placed.scale.width, placed.scale.height)
            var radii = corners(e).map { $0 * s }
            if placed.flipped { radii = [radii[3], radii[2], radii[1], radii[0]] }
            if Set(radii).count == 1 { n.cornerRadius = radii[0] } else { n.corners = radii }
            if int(e["pointRadiusBehaviour"], 1) == 2, radii.contains(where: { $0 > 0 }) { n.cornerSmoothing = 0.6 }
            paint(&n, style, size: size, flipped: placed.flipped, image: image)
            return n
        case "oval" where !edited:
            guard let placed = ImportGeometry.place(box, m) else { break }
            var n = Node(kind: .ellipse, frame: placed.frame)
            n.rotation = placed.rotation
            paint(&n, style, size: size, flipped: placed.flipped, image: image)
            return n
        default:
            break
        }
        let points = list(e["points"]), closed = e["isClosed"] as? Bool ?? true
        if points.count == 2, !closed, let a = point(points[0]["point"]), let b = point(points[1]["point"]),
           !points.contains(where: { $0["hasCurveFrom"] as? Bool == true || $0["hasCurveTo"] as? Bool == true }) {
            // A straight line is a line layer, its ends where they show.
            var n = Node(kind: .line, frame: .zero)
            n.setLineEnds(CGPoint(x: a.x * size.width, y: a.y * size.height).applying(m), CGPoint(x: b.x * size.width, y: b.y * size.height).applying(m))
            n.borders = borders(style, open: true)
            if int(style["startMarkerType"]) != 0 || int(style["endMarkerType"]) != 0 { report.note("Arrowheads on lines, left off") }
            return n
        }
        guard let outline = outline(of: e) else { return nil }
        return path(outline, m, style: style, size: size, closed: closed, image: image)
    }

    /// A rectangle's corner radii: top left, top right, bottom right, bottom left.
    private mutating func corners(_ e: JSON) -> [CGFloat] {
        let points = list(e["points"])
        guard points.count == 4, e["needsConvertionToNewRoundCorners"] as? Bool != true else {
            return Array(repeating: max(num(e["fixedRadius"]), 0), count: 4)
        }
        if points.contains(where: { int($0["cornerStyle"]) != 0 && num($0["cornerRadius"]) > 0 }) {
            report.note("Inverted, angled and square corners, drawn round")
        }
        let radii = points.map { max(num($0["cornerRadius"]), 0) }
        // By where each point is, in case they are not in the usual order.
        let at = points.map { point($0["point"]) ?? CGPoint(x: -1, y: -1) }
        let order = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].compactMap { c in
            at.firstIndex { abs($0.x - c.x) < 0.01 && abs($0.y - c.y) < 0.01 }
        }
        return order.count == 4 ? order.map { radii[$0] } : radii
    }

    /// A shape's outline in its own coordinates, its frame's top left at zero.
    private mutating func outline(of e: JSON) -> CGPath? {
        let size = frame(of: e).size, box = CGRect(origin: .zero, size: size)
        if e["edited"] as? Bool != true {
            switch e["_class"] as? String {
            case "rectangle":
                let radii = corners(e)
                if int(e["pointRadiusBehaviour"], 1) == 2 { return Squircle.path(in: box, corners: radii, smoothing: 0.6) }
                return Renderer.roundedRect(box, corners: radii)
            case "oval":
                return CGPath(ellipseIn: box, transform: nil)
            default:
                break
            }
        }
        return outline(list(e["points"]), closed: e["isClosed"] as? Bool ?? true, size: size,
                       smooth: int(e["pointRadiusBehaviour"], 1) == 2)
    }

    /// The outline Sketch's points make in a layer of `size`. Each point and the handles either
    /// side of it are measured in the frame, 0 to 1; a point with a radius between two straight
    /// sides is rounded off.
    private mutating func outline(_ list: [JSON], closed: Bool, size: CGSize, smooth: Bool) -> CGPath? {
        struct Point {
            var at: CGPoint, from: CGPoint, to: CGPoint
            var curvesFrom: Bool, curvesTo: Bool
            var radius: CGFloat
        }
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let points: [Point] = list.compactMap { p in
            guard let at = point(p["point"]) else { return nil }
            let from = point(p["curveFrom"]) ?? at, to = point(p["curveTo"]) ?? at
            return Point(at: scaled(at), from: scaled(from), to: scaled(to),
                         curvesFrom: p["hasCurveFrom"] as? Bool ?? (from != at), curvesTo: p["hasCurveTo"] as? Bool ?? (to != at),
                         radius: max(num(p["cornerRadius"]), 0))
        }
        guard points.count >= 2 else { return nil }
        let count = points.count
        func straight(_ i: Int) -> Bool { !points[i].curvesFrom && !points[(i + 1) % count].curvesTo }
        // Where a rounded corner leaves its incoming side and joins its outgoing one, and its radius.
        func rounding(_ i: Int) -> (CGPoint, CGPoint, CGFloat)? {
            let p = points[i]
            guard p.radius > 0, closed || (i > 0 && i < count - 1), straight((i + count - 1) % count), straight(i) else { return nil }
            let a = points[(i + count - 1) % count].at, b = points[(i + 1) % count].at
            let la = hypot(a.x - p.at.x, a.y - p.at.y), lb = hypot(b.x - p.at.x, b.y - p.at.y)
            guard la > 0, lb > 0 else { return nil }
            let u = CGPoint(x: (a.x - p.at.x) / la, y: (a.y - p.at.y) / la), v = CGPoint(x: (b.x - p.at.x) / lb, y: (b.y - p.at.y) / lb)
            let angle = acos(min(max(u.x * v.x + u.y * v.y, -1), 1))
            guard angle > 0.01, angle < .pi - 0.01 else { return nil }
            let reach = min(p.radius / tan(angle / 2), la / 2, lb / 2)
            return (CGPoint(x: p.at.x + u.x * reach, y: p.at.y + u.y * reach), CGPoint(x: p.at.x + v.x * reach, y: p.at.y + v.y * reach),
                    reach * tan(angle / 2))
        }
        let path = CGMutablePath()
        let first = rounding(0)
        path.move(to: first?.1 ?? points[0].at)
        for k in 1...(closed ? count : count - 1) {
            let a = points[k - 1], i = k % count, b = points[i]
            if straight(k - 1) {
                if let corner = rounding(i) {
                    path.addLine(to: corner.0)
                    path.addArc(tangent1End: b.at, tangent2End: points[(i + 1) % count].at, radius: corner.2)
                } else {
                    path.addLine(to: b.at)
                }
            } else {
                path.addCurve(to: b.at, control1: a.curvesFrom ? a.from : a.at, control2: b.curvesTo ? b.to : b.at)
            }
        }
        if closed { path.closeSubpath() }
        if points.indices.contains(where: { rounding($0) != nil }) {
            if smooth { report.note("Smooth corners on paths, drawn round") }
            if list.contains(where: { int($0["cornerStyle"]) != 0 && num($0["cornerRadius"]) > 0 }) {
                report.note("Inverted, angled and square corners, drawn round")
            }
        }
        return path
    }

    /// A combined shape: its parts' outlines put together as each part says, drawn in the
    /// group's own style. One shape on its own, as older files keep every shape, stays that shape.
    private mutating func shapeGroup(_ e: JSON, _ m: CGAffineTransform, image: Any?) -> Node? {
        let style = dict(e["style"])
        let parts = list(e["layers"]).filter { $0["isVisible"] as? Bool ?? true }
        if parts.count == 1, let kind = parts[0]["_class"] as? String, Self.shapes.contains(kind) {
            return shape(parts[0], transform(parts[0]).concatenating(m), style: style, image: image)
        }
        guard let outline = combined(e) else { return nil }
        return path(outline, m, style: style, size: frame(of: e).size, closed: true, image: image)
    }

    private mutating func combined(_ e: JSON, level: Int = 0) -> CGPath? {
        guard level < 50 else { return nil }
        let rule: CGPathFillRule = int(dict(e["style"])["windingRule"], 1) == 1 ? .evenOdd : .winding
        var result: CGPath?
        for part in list(e["layers"]) where part["isVisible"] as? Bool ?? true {
            let own: CGPath?
            switch part["_class"] as? String {
            case "shapeGroup": own = combined(part, level: level + 1)
            case let kind? where Self.shapes.contains(kind): own = outline(of: part)
            default:
                report.note("Layers in combined shapes that are not shapes, left out")
                own = nil
            }
            var t = transform(part)
            guard let shape = own?.copy(using: &t) else { continue }
            guard let sofar = result else {
                result = shape
                continue
            }
            switch int(part["booleanOperation"], -1) {
            case 0: result = sofar.union(shape, using: rule)
            case 1: result = sofar.subtracting(shape, using: rule)
            case 2: result = sofar.intersection(shape, using: rule)
            case 3: result = sofar.symmetricDifference(shape, using: rule)
            default:
                let joined = CGMutablePath()
                joined.addPath(sofar)
                joined.addPath(shape)
                result = joined
            }
        }
        return result
    }

    /// A path layer of an outline in the layer's own coordinates, kept turned as the layer is.
    /// Sketch measures gradients on the layer's frame, so they are carried onto the outline's box.
    private mutating func path(_ outline: CGPath, _ m: CGAffineTransform, style: JSON, size: CGSize, closed: Bool, image: Any?) -> Node? {
        let data = PathData.string(outline)
        guard var n = ImportGeometry.outline(data, m) else { return nil }
        if int(style["windingRule"], 1) == 1, data.filter({ $0 == "M" }).count > 1 { n.evenOdd = true }
        let rest = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0).concatenating(CGAffineTransform(rotationAngle: atan2(m.b, m.a)).inverted())
        let box = n.pathBox ?? .zero
        paint(&n, style, size: size, image: image) { p in
            let q = CGPoint(x: p.x * size.width, y: p.y * size.height).applying(rest)
            return CGPoint(x: box.width > 0 ? (q.x - box.minX) / box.width : 0.5, y: box.height > 0 ? (q.y - box.minY) / box.height : 0.5)
        }
        if !closed { n.borders = n.borders.map { b in var b = b; b.position = .center; return b } }
        return n
    }

    /// A picture layer is a rectangle filled with it.
    private mutating func bitmap(_ e: JSON, _ m: CGAffineTransform, image: Any?) -> Node? {
        let box = CGRect(origin: .zero, size: frame(of: e).size)
        var fill = Fill(on: true, color: .shape)
        if let found = picture(image ?? e["image"]) {
            fill.image = ImageFill(asset: found.asset, mode: .stretch, size: found.size)
        }
        var n: Node
        if let placed = ImportGeometry.place(box, m) {
            n = Node(kind: .rectangle, frame: placed.frame)
            n.rotation = placed.rotation
            n.fill = placed.flipped ? fill.flipped(horizontally: false) : fill
        } else {
            guard let outline = ImportGeometry.outline(PathData.string(CGPath(rect: box, transform: nil)), m) else { return nil }
            n = outline
            n.fill = fill
        }
        n.borders = borders(dict(e["style"]), open: false)
        return n
    }

    // MARK: Style

    /// The layer's fills that Bezzle can draw, one over another as Sketch draws them, the first
    /// lowest, and its borders. Bezzle holds a picture only in the first fill, so what lies under
    /// the top picture is left out. `map` carries a point in the layer's frame, 0 to 1, onto the
    /// Bezzle layer's.
    private mutating func paint(_ n: inout Node, _ style: JSON, size: CGSize, flipped: Bool = false, image: Any? = nil,
                                map: (CGPoint) -> CGPoint = { $0 }) {
        var found = list(style["fills"]).filter(enabled).compactMap { fill($0, size: size, image: image, map: map) }
        if let top = found.lastIndex(where: { $0.image != nil }), top > 0 {
            found.removeFirst(top)
            report.note("Fills under a picture, left out")
        }
        n.fills = found.map { flipped ? $0.flipped(horizontally: false) : $0 }
        n.borders = borders(style, open: false, size: size, map: map).map { flipped ? $0.flipped(horizontally: false) : $0 }
    }

    private func color(_ v: Any?) -> RGBA {
        let c = dict(v)
        func unit(_ key: String, _ fallback: CGFloat = 0) -> Double { Double(min(max(num(c[key], fallback), 0), 1)) }
        let r = unit("red"), g = unit("green"), b = unit("blue"), a = unit("alpha", 1)
        guard p3 else { return RGBA(r: r, g: g, b: b, a: a) }
        return RGBA(NSColor(displayP3Red: r, green: g, blue: b, alpha: a)).with(alpha: a)
    }

    /// How much a fill, border or shadow of its own shows, 0 to 1.
    private func opacity(_ part: JSON) -> Double { Double(min(max(num(dict(part["contextSettings"])["opacity"], 1), 0), 1)) }

    private mutating func fill(_ f: JSON, size: CGSize, image: Any?, map: (CGPoint) -> CGPoint) -> Fill? {
        let seen = opacity(f)
        if int(dict(f["contextSettings"])["blendMode"]) != 0 { report.note("Fills with a blend mode of their own, drawn as normal") }
        switch int(f["fillType"]) {
        case 0:
            var c = color(f["color"])
            c.a *= seen
            return Fill(on: true, color: c)
        case 1:
            guard let g = gradient(dict(f["gradient"]), size: size, opacity: seen, map: map) else { return nil }
            return Fill(on: true, color: g.stops[0].color, gradient: g)
        case 4:
            guard let found = picture(image ?? f["image"]) else { return Fill(on: true, color: .shape) }
            if seen < 1 { report.note("Pictures faded in their fill, drawn solid") }
            let mode: ImageFill.Mode
            switch int(f["patternFillType"], 1) {
            case 0:
                report.note("Tiled pictures, drawn once to fill")
                mode = .cover
            case 2: mode = .stretch
            case 3: mode = .fit
            default: mode = .cover
            }
            return Fill(on: true, color: .shape, image: ImageFill(asset: found.asset, mode: mode, size: found.size))
        case 5:
            report.note("Noise fills, left out")
            return nil
        default:
            report.note("Kinds of fill Bezzle does not know")
            return nil
        }
    }

    /// Sketch's gradients run from `from` to `to` in the layer's frame. A radial one is an ellipse
    /// measured on the layer as it is: `to` ends its first radius, and the second is across it,
    /// `elipseLength` times as long.
    private mutating func gradient(_ g: JSON, size: CGSize, opacity seen: Double, map: (CGPoint) -> CGPoint) -> Gradient? {
        let stops = list(g["stops"]).map { s in
            GradientStop(offset: Double(min(max(num(s["position"]), 0), 1)), color: color(s["color"]).with(alpha: color(s["color"]).a * seen))
        }.sorted { $0.offset < $1.offset }
        guard !stops.isEmpty else {
            report.note("Gradients without colours")
            return nil
        }
        let from = point(g["from"]) ?? CGPoint(x: 0.5, y: 0), to = point(g["to"]) ?? CGPoint(x: 0.5, y: 1)
        switch int(g["gradientType"]) {
        case 1:
            let major = CGPoint(x: (to.x - from.x) * size.width, y: (to.y - from.y) * size.height)
            let k = num(g["elipseLength"]) > 0 ? num(g["elipseLength"]) : 1
            let across = CGPoint(x: from.x - (size.width > 0 ? major.y * k / size.width : 0), y: from.y + (size.height > 0 ? major.x * k / size.height : 0))
            return Gradient(kind: .radial, stops: stops, start: map(from), end: map(to), across: map(across))
        case 2:
            report.note("Angular gradients, drawn as linear ones")
            fallthrough
        default:
            return Gradient(kind: .linear, stops: stops, start: map(from), end: map(to))
        }
    }

    /// A picture the file points at, or keeps in the layer itself: its file name in the design,
    /// and its size in pixels. Nil when it is missing or cannot be read.
    private mutating func picture(_ v: Any?) -> (asset: String, size: CGSize)? {
        let ref = dict(v)
        if let source = ref["_ref"] as? String {
            if let known = pictures[source] { return known }
            let name = [source, source + ".png"].first { archive.contains($0) }
            var found: (asset: String, size: CGSize)?
            if let name, let data = try? archive.read(name) {
                if let info = Importer.picture(data) {
                    var asset = (name as NSString).lastPathComponent
                    if asset.hasPrefix(".") || asset.isEmpty { asset = "picture-\(images.count + 1)" }
                    if (asset as NSString).pathExtension.isEmpty { asset += ".\(info.ext)" }
                    images[asset] = name
                    found = (asset, info.size)
                } else {
                    report.note("Pictures Bezzle cannot read, shown grey")
                }
            } else {
                report.note("Pictures missing from the Sketch file")
            }
            pictures[source] = found
            return found
        }
        if let encoded = dict(ref["data"])["_data"] as? String, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            guard let info = Importer.picture(data) else {
                report.note("Pictures Bezzle cannot read, shown grey")
                return nil
            }
            if let same = held.first(where: { $0.value == data }) { return (same.key, info.size) }
            let asset = "picture-\(held.count + 1).\(info.ext)"
            held[asset] = data
            return (asset, info.size)
        }
        if !ref.isEmpty { report.note("Pictures missing from the Sketch file") }
        return nil
    }

    /// The layer's borders, one over another as Sketch draws them, the first lowest. A gradient
    /// is measured on the layer's frame, `size` big, as a fill's is, and carried onto the Bezzle
    /// layer's by `map`.
    private mutating func borders(_ style: JSON, open: Bool, size: CGSize = .zero, map: (CGPoint) -> CGPoint = { $0 }) -> [Border] {
        list(style["borders"]).filter(enabled).map { border($0, style, open: open, size: size, map: map) }
    }

    private mutating func border(_ b: JSON, _ style: JSON, open: Bool, size: CGSize, map: (CGPoint) -> CGPoint) -> Border {
        var c = color(b["color"])
        c.a *= opacity(b)
        var out = Border(on: true, color: c, width: max(num(b["thickness"], 1), 0))
        if int(b["fillType"]) == 1, let g = gradient(dict(b["gradient"]), size: size, opacity: opacity(b), map: map) {
            out.color = g.stops[0].color
            out.gradient = g
        }
        out.position = switch int(b["position"]) {
        case 1: open ? .center : .inside
        case 2: open ? .center : .outside
        default: .center
        }
        let options = dict(style["borderOptions"])
        if enabled(options), let dash = options["dashPattern"] as? [Any], let first = dash.first, num(first) > 0 {
            out.dash = num(first)
            out.gap = num(dash.count > 1 ? dash[1] : first)
        }
        return out
    }

    private mutating func effects(_ n: inout Node, _ style: JSON) {
        let context = dict(style["contextSettings"])
        let seen = Double(min(max(num(context["opacity"], 1), 0), 1))
        if seen < 1 { n.opacity = seen }
        let blend = int(context["blendMode"])
        if blend != 0 {
            if let mode = Self.blends[blend] { n.blend = mode } else { report.note("Blend modes Bezzle does not know, drawn as normal") }
        }
        // Every shadow under the layer and inside it, as Sketch casts them.
        let outside = list(style["shadows"]).filter(enabled), inside = list(style["innerShadows"]).filter(enabled)
        let shadows: [Shadow] = (outside.map { ($0, false) } + inside.map { ($0, true) }).map { s, inset in
            var c = color(s["color"])
            c.a *= opacity(s)
            var shadow = Shadow(on: true, color: c, x: num(s["offsetX"]), y: num(s["offsetY"]), blur: max(num(s["blurRadius"]), 0),
                                inset: inset ? true : nil)
            if num(s["spread"]) != 0 { shadow.spread = num(s["spread"]) }
            return shadow
        }
        if !shadows.isEmpty { n.shadows = shadows }
        let blur = dict(style["blur"])
        if blur["isEnabled"] as? Bool == true, num(blur["radius"]) > 0 {
            let radius = num(blur["radius"])
            switch int(blur["type"]) {
            case 0: n.blur = Blur(radius: radius)
            case 3: n.blur = Blur(radius: radius, background: true, fillOpacity: 1)
            default:
                n.blur = Blur(radius: radius)
                report.note("Motion and zoom blurs, drawn as plain ones")
            }
        }
    }

    // MARK: Text

    /// A text layer. Sketch keeps each run of its words with its own style, as the Mac's text
    /// does, and each run comes across in it; what Bezzle holds for the whole text only comes
    /// from the longest run.
    private mutating func text(_ e: JSON, _ m: CGAffineTransform, string replaced: String?, restyled: Bool) -> Node? {
        let style = dict(e["style"]), attributed = dict(e["attributedString"])
        let common = dict(dict(style["textStyle"])["encodedAttributes"])
        var runs = list(attributed["attributes"])
        var words = attributed["string"] as? String
        if words == nil, let older = Self.archived(attributed) { (words, runs) = older }
        if words == nil {
            report.note("Texts from an older Sketch, set from their layer names")
            words = e["name"] as? String
        }
        // A shared text style swapped in by an instance sets the whole text in it.
        if restyled { runs = [] }
        let main = runs.max { num($0["length"]) < num($1["length"]) }.map { dict($0["attributes"]) } ?? common
        // Each run has its own font, size, colour and lines; how far apart the lines lie, how the
        // paragraphs are aligned and the font's features are the whole text's.
        let typesets = runs.map { Self.typeset(dict($0["attributes"])) }
        if Set(typesets.map(\.spacing)).count > 1 { report.note("Texts with several line or paragraph spacings, spaced as their main part") }
        if Set(typesets.map(\.alignment)).count > 1 { report.note("Texts with paragraphs aligned differently, aligned as their main part") }
        if Set(typesets.map(\.font)).count > 1 { report.note("Texts with font features or axes in part of them, set as their main part") }

        // Each run's words, as Sketch counts them (in UTF-16, as the Mac does), and any no run
        // covers in the longest run's style; new words from an instance are all in that style.
        let text = replaced ?? words ?? "", whole = text as NSString
        var pieces: [(text: String, attributes: JSON)] = []
        if replaced == nil {
            var at = 0
            for run in runs.sorted(by: { int($0["location"]) < int($1["location"]) }) {
                let from = min(max(int(run["location"]), at), whole.length)
                let to = min(int(run["location"]) + max(int(run["length"]), 0), whole.length)
                guard to > from else { continue }
                if from > at { pieces.append((whole.substring(with: NSRange(location: at, length: from - at)), main)) }
                pieces.append((whole.substring(with: NSRange(location: from, length: to - from)), dict(run["attributes"])))
                at = to
            }
            if at < whole.length { pieces.append((whole.substring(from: at), main)) }
        }
        if pieces.isEmpty { pieces = [(text, main)] }

        var n = Node(kind: .text, frame: .zero)
        // Fills on a text layer paint its letters over their own colours, one over another as
        // they lie, in the colour they come to; what an opaque one covers does not show.
        var paint: RGBA?
        let fills = list(style["fills"]).filter(enabled).compactMap { fill($0, size: frame(of: e).size, image: nil, map: { $0 }) }
        // One gradient or picture showing paints them all with it.
        var painting: Fill?
        if !fills.isEmpty {
            let showing = fills[(fills.lastIndex { $0.gradient == nil && $0.image == nil && $0.color.a >= 0.999 } ?? 0)...]
            paint = ImportText.composite(showing.map(\.color))
            if showing.count == 1, let only = showing.first, only.paints {
                painting = only
            } else {
                if showing.contains(where: { $0.gradient != nil }) { report.note("Texts filled with a gradient, in its first colour") }
                if showing.contains(where: { $0.image != nil }) { report.note("Texts filled with a picture, in a plain colour") }
            }
        }
        if list(style["borders"]).contains(where: enabled) { report.note("Texts with a border, drawn without it") }
        var letterRuns: [(text: String, letters: Letters)] = []
        for piece in pieces { letterRuns.append((piece.text, letters(piece.attributes, paint: paint))) }
        // Each run may be in a letter case of its own.
        let cased = ImportText.cased(letterRuns, pieces.map { Self.letterCase($0.attributes) }, report: &report)

        var ts = TextStyle()
        let paragraph = dict(main["paragraphStyle"])
        let height = num(paragraph["maximumLineHeight"], num(paragraph["minimumLineHeight"]))
        if height > 0 { ts.lineSpacing = height }
        ts.align = switch int(paragraph["alignment"]) {
        case 1: .right
        case 2: .center
        case 3: .justify
        default: .left
        }
        if num(paragraph["paragraphSpacing"]) > 0 { ts.paragraphSpacing = num(paragraph["paragraphSpacing"]) }
        ts.letterCase = cased.letterCase
        let font = dict(dict(main["MSAttributedStringFontAttribute"])["attributes"])
        ts.axes = Self.axes(font["variation"])
        n.style = ts
        n.setImportedRuns(cased.runs)
        if let painting {
            n.fill.gradient = painting.gradient
            n.fill.image = painting.image
        }
        ts = n.style ?? ts
        ts.features = Self.features(list(font["featureSettings"]), of: Fonts.font(ts))

        let box = frame(of: e).size
        ts.sizing = switch int(e["textBehaviour"]) {
        case 1: .autoHeight
        case 2: .fixed
        default: .autoWidth
        }
        // Where the lines lie in a box of fixed size; in any other, the box fits around them.
        if ts.sizing == .fixed {
            ts.vertical = switch int(main["textStyleVerticalAlignmentKey"], int(dict(style["textStyle"])["verticalAlignment"])) {
            case 1: .middle
            case 2: .bottom
            default: nil
            }
        }
        n.style = ts
        n.frame = CGRect(x: 0, y: 0, width: ts.sizing == .autoWidth ? 0 : box.width, height: box.height)
        n.refit()
        let laid = n.frame.size
        var local = CGRect(origin: .zero, size: laid)
        if ts.sizing == .autoWidth {
            local.origin.x = switch ts.align {
            case .left, .justify: 0
            case .center: (box.width - laid.width) / 2
            case .right: box.width - laid.width
            }
        }
        // Both lay out with Text Kit, so the first lines agree, unless the line height is set:
        // Bezzle shares the room it adds above and below the letters, Sketch puts it all above.
        // Both move the lines alike in a box whose lines lie in its middle or at its bottom.
        if let baseline = Self.firstBaseline(n) { local.origin.y = baseline - (TextLayout.firstBaseline(n) - TextLayout.offset(n)) }

        var m = m
        if m.a * m.d - m.b * m.c < 0 {
            // Bezzle's words always read forwards, so a flipped text is turned over again where it lies.
            m = CGAffineTransform(translationX: -local.midX, y: 0).concatenating(CGAffineTransform(scaleX: -1, y: 1))
                .concatenating(CGAffineTransform(translationX: local.midX, y: 0)).concatenating(m)
            report.note("Flipped texts, set reading forwards")
        }
        guard let placed = ImportGeometry.place(local, m) else {
            report.note("Slanted texts, set upright")
            n.frame = local.applying(m)
            return n
        }
        n.frame = placed.frame
        n.rotation = placed.rotation
        if abs(placed.scale.height - 1) > 0.01 || abs(placed.scale.width - 1) > 0.01 {
            n.scaleType(by: placed.scale.height)
            n.refit()
            report.note("Stretched texts, set at the size they show")
        }
        return n
    }

    /// How letters in a run with Sketch's `attributes` look; `paint` is the colour a fill on the
    /// layer paints all of them in.
    private mutating func letters(_ a: JSON, paint: RGBA?) -> Letters {
        let font = dict(dict(a["MSAttributedStringFontAttribute"])["attributes"])
        let size = min(max(num(font["size"], 12), 1), 5000)
        let (family, face) = self.font(font["name"] as? String)
        // Sketch spaces letters by points, Bezzle by thousandths of their size.
        return Letters(family: family, face: face, size: size, color: paint ?? color(a["MSAttributedStringColorAttribute"]),
                       underline: int(a["underlineStyle"]) != 0, strikethrough: int(a["strikethroughStyle"]) != 0,
                       tracking: (num(a["kerning"]) / size * 10_000).rounded() / 10, list: nil)
    }

    /// The letter case a run with Sketch's `attributes` is set in.
    private static func letterCase(_ a: JSON) -> LetterCase? {
        switch int(a["MSAttributedStringTextTransformAttribute"]) {
        case 1: .upper
        case 2: .lower
        default: nil
        }
    }

    /// What of a run Bezzle holds for a whole text only, to tell whether runs differ in it: how
    /// far apart its lines and paragraphs lie, how its paragraph is aligned, and its font's
    /// features and axes, each written out.
    private struct Typeset: Hashable {
        var spacing: String
        var alignment: Int
        var font: String
    }

    private static func typeset(_ a: JSON) -> Typeset {
        let font = dict(dict(a["MSAttributedStringFontAttribute"])["attributes"]), p = dict(a["paragraphStyle"])
        func written(_ parts: [Any]) -> String {
            guard JSONSerialization.isValidJSONObject(parts), let data = try? JSONSerialization.data(withJSONObject: parts, options: .sortedKeys) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        return Typeset(spacing: written([Double(num(p["maximumLineHeight"])), Double(num(p["minimumLineHeight"])), Double(num(p["paragraphSpacing"]))]),
                       alignment: int(p["alignment"]) % 4, font: written([font["variation"] ?? [:], font["featureSettings"] ?? []]))
    }

    /// Where a variable font is set along its axes, by their tags; Sketch keys each by the number
    /// a font keeps its tag as.
    private static func axes(_ v: Any?) -> [String: Double]? {
        var axes: [String: Double] = [:]
        for (key, value) in dict(v) {
            guard let code = UInt32(key) else { continue }
            axes[Fonts.tag(code)] = Double(num(value))
        }
        return axes.isEmpty ? nil : axes
    }

    /// The OpenType features Sketch keeps with a font, by their tags. It keeps them as Core Text
    /// names them, by a feature type and a selector, which the font itself says the tags of.
    private static func features(_ settings: [JSON], of font: NSFont) -> [String: Int]? {
        guard !settings.isEmpty else { return nil }
        var tags: [String: Int] = [:]
        let types = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
        func number(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        for s in settings {
            if let tag = s["CTFeatureOpenTypeTag"] as? String {
                tags[tag] = int(s["CTFeatureOpenTypeValue"], 1)
                continue
            }
            let type = int(s["CTFeatureTypeIdentifier"], -1), selector = int(s["CTFeatureSelectorIdentifier"], -1)
            for t in types where number(t[kCTFontFeatureTypeIdentifierKey as String]) == type {
                for sel in t[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? []
                where number(sel[kCTFontFeatureSelectorIdentifierKey as String]) == selector {
                    if let tag = sel[kCTFontOpenTypeFeatureTag as String] as? String {
                        tags[tag] = number(sel[kCTFontOpenTypeFeatureValue as String]) ?? 1
                    }
                }
            }
        }
        return tags.isEmpty ? nil : tags
    }

    /// How far below the top of its lines Sketch sets a text's first baseline, when its line
    /// height is set: as Text Kit does on its own, the letters at the foot of the line.
    private static func firstBaseline(_ n: Node) -> CGFloat? {
        guard let style = n.style, style.lineSpacing != nil else { return nil }
        let set = NSMutableAttributedString(attributedString: TextLayout.attributed(n))
        guard set.length > 0 else { return nil }
        set.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: set.length))
        let laid = TextLayout.Laid(set, font: Fonts.font(style), width: style.sizing == .autoWidth ? 100_000 : max(n.frame.width, 1))
        return laid.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + laid.manager.location(forGlyphAt: 0).y
    }

    /// A font as Sketch names it, by its PostScript name, found among this Mac's. The Mac's own
    /// font has names of its own, such as ".SFNSText-Semibold" or "SFProDisplay-Bold".
    private mutating func font(_ postscript: String?) -> (String, String) {
        let name = postscript ?? ""
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let face = parts.count > 1 ? spaced(parts[1]) : "Regular"
        let system = [".SF", "SFPro", "SFCompact", ".AppleSystemUIFont", ".HelveticaNeueDeskInterface"].contains { name.hasPrefix($0) }
        return fonts.resolve(postscript: system ? nil : postscript, family: system ? "SF Pro" : parts.first.map(spaced), face: face, report: &report)
    }

    /// The words of a text saved by Sketch 43 to 47, kept as an archived attributed string, and
    /// the style of each of its runs as later files write it.
    private static func archived(_ attributed: JSON) -> (String, [JSON])? {
        guard let encoded = dict(attributed["archivedAttributedString"])["_archive"] as? String,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let text = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, NSFont.self, NSFontDescriptor.self, NSColor.self,
                                                                               NSParagraphStyle.self, NSDictionary.self, NSArray.self,
                                                                               NSString.self, NSNumber.self], from: data) as? NSAttributedString
        else { return nil }
        var runs: [JSON] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { a, range, _ in
            var run: JSON = [:]
            let descriptor = a[NSAttributedString.Key("MSAttributedStringFontAttribute")] as? NSFontDescriptor ?? (a[.font] as? NSFont)?.fontDescriptor
            if let descriptor {
                run["MSAttributedStringFontAttribute"] = ["attributes": ["name": descriptor.postscriptName ?? "", "size": Double(descriptor.pointSize)]]
            }
            if let c = (a[.foregroundColor] as? NSColor ?? a[NSAttributedString.Key("NSColor")] as? NSColor)?.usingColorSpace(.sRGB) {
                run["MSAttributedStringColorAttribute"] = ["red": Double(c.redComponent), "green": Double(c.greenComponent),
                                                           "blue": Double(c.blueComponent), "alpha": Double(c.alphaComponent)]
            }
            if let p = a[.paragraphStyle] as? NSParagraphStyle {
                // As Sketch numbers them, which is not how every Mac does.
                let alignment = switch p.alignment {
                case .right: 1
                case .center: 2
                case .justified: 3
                default: 0
                }
                run["paragraphStyle"] = ["alignment": alignment, "maximumLineHeight": Double(p.maximumLineHeight),
                                         "minimumLineHeight": Double(p.minimumLineHeight), "paragraphSpacing": Double(p.paragraphSpacing)]
            }
            if let kern = a[.kern] as? NSNumber { run["kerning"] = kern.doubleValue }
            if let line = a[.underlineStyle] as? NSNumber { run["underlineStyle"] = line.intValue }
            if let line = a[.strikethroughStyle] as? NSNumber { run["strikethroughStyle"] = line.intValue }
            if let transform = a[NSAttributedString.Key("MSAttributedStringTextTransformAttribute")] as? NSNumber {
                run["MSAttributedStringTextTransformAttribute"] = transform.intValue
            }
            runs.append(["location": range.location, "length": range.length, "attributes": run])
        }
        return (text.string, runs)
    }
}
