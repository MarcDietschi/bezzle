import AppKit

/// Reads Adobe XD files. An .xd file is a ZIP archive with a manifest of its artboards, a JSON
/// scene for each (XD calls it a graphics tree), shared resources such as component masters,
/// and the pictures. Everything Bezzle can draw comes across as it is; the rest comes as close
/// as Bezzle allows and is counted in the report.
enum XDImporter {
    nonisolated static let fileExtension = "xd"

    enum Failure: Error, LocalizedError {
        case notXD

        var errorDescription: String? { String(localized: "This is not an Adobe XD file Bezzle can read.") }
    }

    /// The design an XD file makes, its pictures still in the file.
    static func read(_ url: URL) throws -> Imported {
        let archive = try ZipArchive(url: url)
        guard archive.contains("manifest") else { throw Failure.notXD }
        var converter = Converter(archive: archive)
        let doc = try converter.document()
        return Imported(document: doc, report: converter.report, archive: archive, pictures: converter.images)
    }
}

private typealias JSON = [String: Any]

private func num(_ v: Any?, _ fallback: CGFloat = 0) -> CGFloat {
    switch v {
    case let d as Double: CGFloat(d)
    case let i as Int: CGFloat(i)
    case let n as NSNumber: CGFloat(n.doubleValue)
    default: fallback
    }
}

private func dict(_ v: Any?) -> JSON { v as? JSON ?? [:] }
private func list(_ v: Any?) -> [JSON] { v as? [JSON] ?? [] }

private struct Converter {
    let archive: ZipArchive
    var report = ImportReport(source: "Adobe XD")
    /// Pictures the design keeps: its file name there, and where it is in the archive.
    var images: [String: String] = [:]
    /// Component masters and everything in them, by id, for the instances that point at them.
    private var masters: [String: JSON] = [:]
    /// Gradients and masks kept apart from where they are used, as older files do.
    private var gradients: [String: JSON] = [:]
    private var clipPaths: [String: JSON] = [:]
    /// The kind of each picture in the archive, by its name there.
    private var imageTypes: [String: String] = [:]
    private var fonts = FontMatch()
    /// How many masks have been made, to name those XD left unnamed.
    private var masks = 0

    init(archive: ZipArchive) {
        self.archive = archive
    }

    mutating func document() throws -> BezzleDocument {
        guard let manifest = try JSONSerialization.jsonObject(with: archive.read("manifest")) as? JSON else { throw XDImporter.Failure.notXD }
        let sections = list(manifest["children"])
        for resources in sections where resources["name"] as? String == "resources" {
            for c in list(resources["components"]) {
                if let path = c["path"] as? String, let type = c["type"] as? String, type.hasPrefix("image/") {
                    imageTypes[path] = type == "image/jpeg" ? "jpg" : String(type.dropFirst(6))
                }
            }
        }
        if let data = try? archive.read("resources/graphics/graphicContent.agc"),
           let shared = try? JSONSerialization.jsonObject(with: data) as? JSON {
            let resources = dict(shared["resources"])
            for (id, g) in dict(resources["gradients"]) { gradients[id] = dict(g) }
            for (id, c) in dict(resources["clipPaths"]) { clipPaths[id] = dict(c) }
            for symbol in list(dict(dict(resources["meta"])["ux"])["symbols"]) { index(symbol) }
        }

        var doc = BezzleDocument()
        for artwork in sections where artwork["name"] as? String == "artwork" {
            for entry in list(artwork["children"]) {
                guard let path = entry["path"] as? String else { continue }
                guard let data = try? archive.read("artwork/\(path)/graphics/graphicContent.agc"),
                      let scene = try? JSONSerialization.jsonObject(with: data) as? JSON else {
                    report.note("Artboards that could not be read")
                    continue
                }
                if path == "pasteboard" {
                    // Loose layers lie on the canvas itself.
                    for e in topLevel(scene) {
                        if let n = convert(e, into: .identity) { doc.nodes.append(n) }
                    }
                } else if path.hasPrefix("artboard-") {
                    let bounds = dict(entry["uxdesign#bounds"])
                    let frame = CGRect(x: num(bounds["x"]), y: num(bounds["y"]), width: num(bounds["width"], 375), height: num(bounds["height"], 812))
                    doc.nodes.append(artboard(scene, name: entry["name"] as? String ?? String(localized: "Artboard"), frame: frame))
                }
            }
        }
        // Artboards under loose layers, as XD shows them.
        doc.nodes.sort { $0.isArtboard && !$1.isArtboard }
        doc.fitGroups()
        // No viewport: the canvas fits the design to itself when it first opens.
        return doc
    }

    private mutating func index(_ e: JSON) {
        if let id = e["id"] as? String { masters[id] = e }
        for c in children(of: e) { index(c) }
    }

    private func topLevel(_ scene: JSON) -> [JSON] {
        let roots = list(scene["children"])
        if roots.count == 1, roots[0]["type"] as? String == "artboard" { return children(of: roots[0]) }
        return roots
    }

    private mutating func artboard(_ scene: JSON, name: String, frame: CGRect) -> Node {
        var board = Node(kind: .artboard, name: name, frame: frame)
        report.artboards += 1
        let root = list(scene["children"]).first { $0["type"] as? String == "artboard" } ?? [:]
        if let fill = root["style"].flatMap({ dict($0)["fill"] }) as? JSON, let f = self.fill(fill, flipped: false) {
            board.fill = f
        }
        let ux = dict(dict(root["meta"])["ux"])
        board.layout = layoutGrid(dict(ux["gridStyle"]), width: frame.width)
        let guides = dict(ux["guidesModel"])
        func positions(_ v: Any?) -> [CGFloat] { list(dict(v)["guides"]).map { num($0["position"], -1) } }
        board.guides = ImportLayout.guides(across: positions(guides["verticalGuides"]), down: positions(guides["horizontalGuides"]), in: frame.size)
        let toBoard = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        for e in topLevel(scene) {
            // Layers right on the artboard say where they are on the canvas, and also, when the
            // file is recent enough, where they are on the artboard.
            let resolved = resolve(e)
            let local = dict(dict(resolved["meta"])["ux"])["localTransform"]
            let node = local != nil ? convert(e, into: .identity, transform: transform(local)) : convert(e, into: toBoard)
            if let node { board.children.append(node) }
        }
        return board
    }

    // MARK: Elements

    private func children(of e: JSON) -> [JSON] {
        for key in ["group", "artboard", "syncRef"] {
            if let c = dict(e[key])["children"] as? [JSON] { return c }
        }
        if e["type"] as? String == "shape", dict(e["shape"])["type"] as? String == "compound" { return [] }
        return list(e["children"])
    }

    /// A component instance is its master with the instance's own changes laid over it.
    private mutating func resolve(_ e: JSON) -> JSON {
        guard e["type"] as? String == "syncRef" else { return e }
        guard let source = e["syncSourceGuid"] as? String, let master = masters[source] else {
            report.note("Component instances whose master is missing")
            var group = e
            group["type"] = "group"
            return group
        }
        return Self.merged(master, with: e)
    }

    private static func merged(_ master: JSON, with instance: JSON) -> JSON {
        var out = master
        for (key, value) in instance where !["type", "syncSourceGuid", "guid"].contains(key) {
            if let a = out[key] as? JSON, let b = value as? JSON {
                out[key] = merged(a, with: b)
            } else {
                out[key] = value
            }
        }
        return out
    }

    private func transform(_ v: Any?) -> CGAffineTransform {
        let t = dict(v)
        guard !t.isEmpty else { return .identity }
        return CGAffineTransform(a: num(t["a"], 1), b: num(t["b"]), c: num(t["c"]), d: num(t["d"], 1), tx: num(t["tx"]), ty: num(t["ty"]))
    }

    /// One element and everything in it. `outer` takes the element's parent's coordinates to
    /// those of the Bezzle layer it goes into; groups are never turned in Bezzle, so a group's
    /// own transform is handed down to what it holds.
    private mutating func convert(_ raw: JSON, into outer: CGAffineTransform, transform own: CGAffineTransform? = nil) -> Node? {
        let e = resolve(raw)
        let m = (own ?? transform(e["transform"])).concatenating(outer)
        var node: Node?
        switch e["type"] as? String {
        case "shape": node = shape(e, m)
        case "text": node = text(e, m)
        case "group", "syncRef": node = group(e, m)
        default: report.note("Kinds of layer Bezzle does not know")
        }
        guard var n = node else { return nil }
        if let name = e["name"] as? String, !name.isEmpty { n.name = name }
        effects(&n, dict(e["style"]))
        if e["visible"] as? Bool == false { n.hidden = true }
        if dict(dict(e["meta"])["ux"])["locked"] as? Bool == true { n.locked = true }
        report.layers += 1
        return n
    }

    private mutating func group(_ e: JSON, _ m: CGAffineTransform) -> Node? {
        var g = Node(kind: .group, frame: .zero)
        g.children = children(of: e).compactMap { convert($0, into: m) }
        let ux = dict(dict(e["meta"])["ux"])
        // The mask is kept with the group, or in older files among the shared resources. XD cuts
        // by it without drawing it, so it becomes a mask of Bezzle's, its shape clear.
        let ref = dict(dict(e["style"])["clipPath"])["ref"] as? String
        let clip = list(dict(ux["clipPathResources"])["children"]).first ?? ref.flatMap { list(clipPaths[$0]?["children"]).first }
        if let clip, var shape = convert(clip, into: m), !g.children.isEmpty {
            shape.hidden = false
            if let holder = ImportMask.holder(shape, drawn: false) {
                masks += 1
                return ImportMask.mask(holder, holding: g.children, name: String(localized: "Mask \(masks)"))
            }
            report.note("Masks of text or lines, cutting by their box")
            g.mask = [shape]
        } else if ref != nil, clip == nil {
            report.note("Masks that could not be found")
        }
        if ux["repeatGrid"] != nil {
            if let grid = Self.repeatGrid(g, dict(ux["repeatGrid"])) { return grid }
            report.note("Repeat grids, brought in as groups")
        }
        return g.children.isEmpty ? nil : g
    }

    /// The columns an artboard is laid out on, from XD's grid for it: columns stretching between
    /// margins at the left and right. XD's square grid has nothing in Bezzle to go to.
    private mutating func layoutGrid(_ style: JSON, width: CGFloat) -> LayoutGrid? {
        guard style["visible"] as? Bool ?? false else { return nil }
        guard style["type"] as? String ?? "layout" == "layout" else {
            report.note("Square grids, left out")
            return nil
        }
        let count = Int(num(style["columns"]))
        guard count > 0, let columns = ImportLayout.stretched(count: count, gutter: num(style["gutter"]), start: num(style["marginLeft"]),
                                                             end: num(style["marginRight"]), report: &report) else { return nil }
        if num(style["marginTop"]) > 0 || num(style["marginBottom"]) > 0 { report.note("Top and bottom margins of layout grids, left out") }
        return LayoutGrid(columns: columns, rows: nil, baseline: nil)
    }

    /// An XD repeat grid as one of Bezzle's: its cells read from the top left, the first one the
    /// others follow, each keeping its own words and pictures. Nil when its cells are not alike.
    private static func repeatGrid(_ group: Node, _ spec: JSON) -> Node? {
        let columns = Int(num(spec["columns"], 1)), rows = Int(num(spec["rows"], 1))
        guard RepeatGrid.counts.contains(columns), RepeatGrid.counts.contains(rows), group.children.count == columns * rows,
              group.mask == nil else { return nil }
        let boxes = group.children.map { RepeatGrid.box(of: $0) }
        let order = group.children.indices.sorted { a, b in
            abs(boxes[a].minY - boxes[b].minY) > 1 ? boxes[a].minY < boxes[b].minY : boxes[a].minX < boxes[b].minX
        }
        let cells = order.map { group.children[$0] }
        func kinds(_ n: Node) -> [Node.Kind] { [n.kind] + n.children.flatMap(kinds) }
        let first = cells[0], box = boxes[order[0]]
        guard cells.allSatisfy({ kinds($0) == kinds(first) }) else { return nil }
        // As far apart as XD lays them, which may be more or less than the first cell's size.
        let across = columns > 1 ? boxes[order[1]].minX - box.minX : num(spec["cellWidth"]) + num(spec["paddingX"])
        let down = rows > 1 ? boxes[order[columns]].minY - box.minY : num(spec["cellHeight"]) + num(spec["paddingY"])
        func content(_ from: Node, into to: inout Node) {
            if to.kind == .text {
                // Its words, each letter looking as it does in the cell, over the first cell's style.
                let style = from.style ?? TextStyle(), base = to.style ?? TextStyle(), ink = from.fill.color, color = to.fill.color
                to.setRuns(from.runs.map { TextSpan(text: $0.text, look: TextLook($0.look.resolved(over: style, color: ink), over: base, color: color)) })
            }
            to.fill.image = from.fill.image
            for i in to.children.indices where i < from.children.count { content(from.children[i], into: &to.children[i]) }
        }
        var grid = group
        grid.grid = RepeatGrid(columns: columns, rows: rows, columnGap: (across - box.width).rounded(), rowGap: (down - box.height).rounded())
        grid.children = [first] + cells.enumerated().dropFirst().map { i, cell in
            var copy = RepeatGrid.copy(first, RepeatGrid.key(RepeatGrid.Cell(column: i % columns, row: i / columns)))
            content(cell, into: &copy)
            return copy
        }
        RepeatGrid.heal(&grid)
        return grid
    }

    // MARK: Shapes

    private mutating func shape(_ e: JSON, _ m: CGAffineTransform) -> Node? {
        let shape = dict(e["shape"])
        let style = dict(e["style"])
        switch shape["type"] as? String {
        case "rect":
            let box = CGRect(x: num(shape["x"]), y: num(shape["y"]), width: num(shape["width"]), height: num(shape["height"]))
            var radii: [CGFloat]
            if let r = shape["r"] as? [Any] { radii = r.map { num($0) } } else { radii = Array(repeating: num(shape["r"]), count: 4) }
            if radii.count != 4 { radii = Array(repeating: radii.first ?? 0, count: 4) }
            guard let placed = place(box, m) else {
                return path(PathData.string(Renderer.roundedRect(box, corners: radii)), m, style: style)
            }
            var n = Node(kind: .rectangle, frame: placed.frame)
            n.rotation = placed.rotation
            let s = min(placed.scale.width, placed.scale.height)
            radii = radii.map { $0 * s }
            if placed.flipped { radii = [radii[3], radii[2], radii[1], radii[0]] }
            if Set(radii).count == 1 { n.cornerRadius = radii[0] } else { n.corners = radii }
            paint(&n, style, flipped: placed.flipped)
            return n
        case "ellipse", "circle":
            let rx = num(shape["rx"], num(shape["r"])), ry = num(shape["ry"], num(shape["r"]))
            let box = CGRect(x: num(shape["cx"]) - rx, y: num(shape["cy"]) - ry, width: rx * 2, height: ry * 2)
            guard let placed = place(box, m) else {
                return path(PathData.string(CGPath(ellipseIn: box, transform: nil)), m, style: style)
            }
            var n = Node(kind: .ellipse, frame: placed.frame)
            n.rotation = placed.rotation
            paint(&n, style, flipped: placed.flipped)
            return n
        case "line":
            let a = CGPoint(x: num(shape["x1"]), y: num(shape["y1"])).applying(m)
            let b = CGPoint(x: num(shape["x2"]), y: num(shape["y2"])).applying(m)
            var n = Node(kind: .line, frame: .zero)
            n.setLineEnds(a, b)
            n.border = border(dict(style["stroke"]), open: true)
            return n
        case "path", "compound":
            // A compound shape carries the outline its parts make, already worked out.
            guard let data = shape["path"] as? String else { return nil }
            if shape["type"] as? String == "compound" && !(shape["path"] is String) { report.note("Compound shapes without an outline") }
            return path(data, m, style: style)
        case "polygon":
            let points = list(shape["points"]).map { CGPoint(x: num($0["x"]), y: num($0["y"])) }
            guard let first = points.first else { return nil }
            if num(shape["uxdesign#cornerRadius"]) > 0 { report.note("Rounded polygon corners, drawn sharp") }
            let data = "M \(first.x) \(first.y) " + points.dropFirst().map { "L \($0.x) \($0.y)" }.joined(separator: " ") + " Z"
            return path(data, m, style: style)
        default:
            report.note("Kinds of shape Bezzle does not know")
            return nil
        }
    }

    /// An outline in the element's own coordinates, kept turned as the element is.
    private mutating func path(_ data: String, _ m: CGAffineTransform, style: JSON) -> Node? {
        guard var n = ImportGeometry.outline(data, m) else { return nil }
        paint(&n, style, flipped: false)
        if !ImportGeometry.isClosed(data) && n.border.on && n.border.position != .center { n.border.position = .center }
        return n
    }

    private func place(_ box: CGRect, _ m: CGAffineTransform) -> Placement? { ImportGeometry.place(box, m) }

    // MARK: Style

    private mutating func paint(_ n: inout Node, _ style: JSON, flipped: Bool) {
        if let fill = style["fill"] as? JSON, let f = self.fill(fill, flipped: flipped) {
            n.fill = f
        } else {
            n.fill.on = false
        }
        n.border = border(dict(style["stroke"]), open: false)
    }

    private func color(_ v: Any?) -> RGBA {
        let c = dict(v)
        let value = dict(c["value"])
        if let argb = (c["value"] as? NSNumber)?.uint32Value, value.isEmpty {
            return RGBA(r: Double((argb >> 16) & 0xFF) / 255, g: Double((argb >> 8) & 0xFF) / 255, b: Double(argb & 0xFF) / 255,
                        a: Double((argb >> 24) & 0xFF) / 255)
        }
        return RGBA(r: Double(num(value["r"])) / 255, g: Double(num(value["g"])) / 255, b: Double(num(value["b"])) / 255,
                    a: Double(num(c["alpha"], 1)))
    }

    private mutating func fill(_ f: JSON, flipped: Bool) -> Fill? {
        switch f["type"] as? String {
        case "solid":
            return Fill(on: true, color: color(f["color"]))
        case "none":
            return Fill(on: false, color: color(f["color"]))
        case "gradient":
            let g = dict(f["gradient"])
            let resource = dict(dict(dict(g["meta"])["ux"])["gradientResources"])
            let source = resource.isEmpty ? (g["ref"] as? String).flatMap { gradients[$0] } ?? [:] : resource
            let stops = list(source["stops"]).map { GradientStop(offset: Double(num($0["offset"])), color: color($0["color"])) }
            guard !stops.isEmpty else { report.note("Gradients without colours"); return nil }
            if g["units"] as? String == "userSpaceOnUse" { report.note("Gradients measured on the canvas, placed by the layer") }
            func y(_ v: CGFloat) -> CGFloat { flipped ? 1 - v : v }
            var gradient: Gradient
            if source["type"] as? String == "radial" {
                gradient = Gradient(kind: .radial, stops: stops, start: CGPoint(x: num(g["cx"], 0.5), y: y(num(g["cy"], 0.5))),
                                    end: .zero, radius: num(g["r"], 0.5))
                if g["gradientTransform"] != nil { report.note("Turned or stretched radial gradients") }
            } else {
                gradient = Gradient(kind: .linear, stops: stops, start: CGPoint(x: num(g["x1"]), y: y(num(g["y1"]))),
                                    end: CGPoint(x: num(g["x2"], 1), y: y(num(g["y2"]))))
            }
            return Fill(on: true, color: stops[0].color, gradient: gradient)
        case "pattern":
            let p = dict(f["pattern"]), ux = dict(dict(p["meta"])["ux"])
            guard let uid = ux["uid"] as? String else { report.note("Pictures without a file"); return nil }
            let source = "resources/\(uid)"
            guard archive.contains(source) else { report.note("Pictures missing from the Adobe XD file"); return Fill(on: true, color: .shape) }
            let asset = "\(uid).\(imageTypes[uid] ?? "png")"
            images[asset] = source
            let mode: ImageFill.Mode = switch ux["scaleBehavior"] as? String {
            case "fit": .fit
            case "stretch": .stretch
            default: .cover
            }
            let image = ImageFill(asset: asset, mode: mode, size: CGSize(width: num(p["width"], 1), height: num(p["height"], 1)),
                                  offset: CGPoint(x: num(ux["offsetX"]), y: num(ux["offsetY"])), scale: num(ux["scale"], 1))
            return Fill(on: true, color: .shape, image: image)
        default:
            report.note("Kinds of fill Bezzle does not know")
            return nil
        }
    }

    private func border(_ s: JSON, open: Bool) -> Border {
        guard s["type"] as? String == "solid" else { return Border(on: false) }
        var b = Border(on: true, color: color(s["color"]), width: num(s["width"], 1))
        b.position = switch s["align"] as? String {
        case "inside": open ? .center : .inside
        case "outside": open ? .center : .outside
        default: .center
        }
        if let dash = s["dash"] as? [Any], let first = dash.first {
            b.dash = num(first)
            b.gap = num(dash.count > 1 ? dash[1] : first)
        }
        return b
    }

    private mutating func effects(_ n: inout Node, _ style: JSON) {
        if let opacity = style["opacity"] { n.opacity = Double(num(opacity, 1)) }
        if let name = style["blendMode"] as? String, !["pass-through", "normal"].contains(name) {
            // XD writes them as CSS does: "color-dodge".
            let parts = name.split(separator: "-")
            let camel = parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
            if let blend = BlendMode(rawValue: camel) { n.blend = blend } else { report.note("Blend modes Bezzle does not know, drawn as normal") }
        }
        for f in list(style["filters"]) {
            let visible = f["visible"] as? Bool ?? true
            let params = dict(f["params"])
            switch f["type"] as? String {
            case "dropShadow":
                // Each shadow XD casts, all of them under the layer.
                let shadows = list(params["dropShadows"]).map { s in
                    Shadow(on: true, color: color(s["color"]), x: num(s["dx"]), y: num(s["dy"]), blur: num(s["r"]))
                }
                if visible, !shadows.isEmpty {
                    n.shadows = shadows
                } else if let first = shadows.first {
                    // Kept off, as XD keeps it, to bring back.
                    n.shadow = first
                    n.shadow.on = false
                }
            case "uxdesign#blur":
                let background = params["backgroundEffect"] as? Bool ?? false
                n.blur = Blur(on: visible, radius: num(params["blurAmount"]), background: background,
                              brightness: Double(num(params["brightnessAmount"])) / 100, fillOpacity: Double(num(params["fillOpacity"])))

            default:
                if visible { report.note("Effects Bezzle does not know") }
            }
        }
    }

    // MARK: Text

    /// A text layer. XD keeps how each range of its letters looks with what it keeps for itself
    /// (`meta.ux.rangedStyles`), and older files on the pieces of its lines; each range comes
    /// across with its own look.
    private mutating func text(_ e: JSON, _ m: CGAffineTransform) -> Node? {
        let t = dict(e["text"]), style = dict(e["style"])
        var n = Node(kind: .text, frame: .zero)
        let words = t["rawText"] as? String ?? ""
        let attributes = dict(style["textAttributes"])
        // A gradient or a picture paints the letters of the text's own colour.
        var paint: Fill?
        if let fill = style["fill"] as? JSON, let f = self.fill(fill, flipped: false) {
            n.fill = f
            if f.paints { paint = f }
        }

        // The ranges, each as long as XD counts (in UTF-16, as JavaScript does), the last to the end.
        let whole = words as NSString
        var ranges: [(range: NSRange, style: JSON)] = []
        let ranged = list(dict(dict(e["meta"])["ux"])["rangedStyles"])
        var at = 0
        for (i, r) in ranged.enumerated() {
            let end = i == ranged.count - 1 ? whole.length : min(at + max(Int(num(r["length"])), 0), whole.length)
            if end > at { ranges.append((NSRange(location: at, length: end - at), r)) }
            at = max(at, end)
        }
        if ranged.isEmpty {
            // Older files style the pieces of the lines, as SVG does.
            for piece in list(t["paragraphs"]).flatMap({ ($0["lines"] as? [[JSON]] ?? []).joined() }) {
                let from = min(max(Int(num(piece["from"])), at), whole.length), to = min(Int(num(piece["to"])), whole.length)
                guard to > from else { continue }
                if from > at { ranges.append((NSRange(location: at, length: from - at), [:])) }
                ranges.append((NSRange(location: from, length: to - from), Self.ranged(dict(piece["style"]))))
                at = to
            }
            if at < whole.length { ranges.append((NSRange(location: at, length: whole.length - at), [:])) }
        }
        if ranges.isEmpty { ranges = [(NSRange(location: 0, length: whole.length), ranged.first ?? [:])] }
        // Letters in a colour of their own are told from those painted.
        if var p = paint {
            p.color = ImportText.apart(p.color, from: ranges.compactMap { ink(of: $0.style) })
            n.fill.color = p.color
            paint = p
        }
        var runs: [(text: String, letters: Letters)] = []
        for r in ranges { runs.append((whole.substring(with: r.range), letters(r.style, style, ink: n.fill.color))) }
        // Each range may be in a letter case of its own.
        let cases = ranges.map { r -> LetterCase? in
            switch (r.style["textTransform"] ?? attributes["textTransform"]) as? String {
            case "uppercase": .upper
            case "lowercase": .lower
            case "titlecase": .title
            default: nil
            }
        }
        let cased = ImportText.cased(runs, cases, report: &report)

        var ts = TextStyle()
        if let height = attributes["lineHeight"] { ts.lineSpacing = num(height) }
        if num(attributes["paragraphAfterSpacing"]) > 0 { ts.paragraphSpacing = num(attributes["paragraphAfterSpacing"]) }
        ts.align = switch attributes["paragraphAlign"] as? String {
        case "center": .center
        case "right": .right
        case "justify": .justify
        default: .left
        }
        ts.letterCase = cased.letterCase
        n.style = ts
        n.setImportedRuns(cased.runs, painting: paint)
        ts = n.style ?? ts

        // Where each line starts and where its baseline is, measured from the text's origin.
        let lines = list(t["paragraphs"]).flatMap { p in (p["lines"] as? [[JSON]] ?? []).compactMap(\.first) }
        let frame = dict(t["frame"])
        let local: CGRect
        if frame["type"] as? String == "area" || frame["type"] as? String == "autoHeight" {
            // An area text keeps the box it was given; one of auto height grows with its words.
            ts.sizing = frame["type"] as? String == "area" ? .fixed : .autoHeight
            n.style = ts
            n.frame = CGRect(x: 0, y: 0, width: num(frame["width"], 100), height: num(frame["height"], 20))
            n.refit()
            let baseline = lines.first.map { num($0["y"]) } ?? TextLayout.firstBaseline(n)
            local = CGRect(x: 0, y: baseline - TextLayout.firstBaseline(n), width: n.frame.width, height: n.frame.height)
        } else {
            ts.sizing = .autoWidth
            n.style = ts
            n.refit()
            let left = lines.map { num($0["x"]) }.min() ?? 0
            let baseline = lines.first.map { num($0["y"]) } ?? 0
            local = CGRect(x: left, y: baseline - TextLayout.firstBaseline(n), width: n.frame.width, height: n.frame.height)
        }
        guard let placed = place(local, m) else {
            report.note("Slanted texts, set upright")
            n.frame = local.applying(m)
            return n
        }
        n.frame = placed.frame
        n.rotation = placed.rotation
        if abs(placed.scale.height - 1) > 0.01 {
            n.scaleType(by: placed.scale.height)
            report.note("Stretched texts, set at the size they show")
        }
        return n
    }

    /// How the letters of a range look: as its ranged style says, and where it says nothing, as
    /// the layer's style does. `ink` is the layer's colour.
    private mutating func letters(_ r: JSON, _ style: JSON, ink: RGBA) -> Letters {
        let font = dict(style["font"]), attributes = dict(style["textAttributes"])
        let decoration = attributes["decoration"] as? [String] ?? []
        let (family, face) = resolveFont(postscript: (r["postscriptName"] ?? font["postscriptName"]) as? String,
                                         family: (r["fontFamily"] ?? font["family"]) as? String,
                                         face: (r["fontStyle"] ?? font["style"]) as? String)
        let size = num(r["fontSize"] ?? font["size"], 12)
        // XD spaces letters in thousandths of their size, as Bezzle does.
        return Letters(family: family, face: face, size: size > 0 ? size : 12,
                       color: self.ink(of: r) ?? ink,
                       underline: r["underline"] as? Bool ?? decoration.contains("underline"),
                       strikethrough: r["strikethrough"] as? Bool ?? decoration.contains("line-through"),
                       tracking: num(r["charSpacing"] ?? attributes["letterSpacing"]), list: nil)
    }

    /// The colour of its own a range's letters are in, if they have one.
    private func ink(of r: JSON) -> RGBA? {
        dict(r["fill"])["value"].map { color(["value": $0]) }
    }

    /// The style of a piece of a line, as a ranged style would say it.
    private static func ranged(_ style: JSON) -> JSON {
        let font = dict(style["font"]), attributes = dict(style["textAttributes"])
        var r: JSON = [:]
        r["postscriptName"] = font["postscriptName"]
        r["fontFamily"] = font["family"]
        r["fontStyle"] = font["style"]
        r["fontSize"] = font["size"]
        r["charSpacing"] = attributes["letterSpacing"]
        if let decoration = attributes["decoration"] as? [String] {
            r["underline"] = decoration.contains("underline")
            r["strikethrough"] = decoration.contains("line-through")
        }
        if let fill = dict(style["fill"])["color"] as? JSON {
            // As a ranged style keeps its colour: one number, its alpha, red, green and blue a byte each.
            let value = dict(fill["value"])
            func byte(_ v: CGFloat) -> UInt32 { UInt32(min(max(v.rounded(), 0), 255)) }
            r["fill"] = ["value": NSNumber(value: byte(num(fill["alpha"], 1) * 255) << 24 | byte(num(value["r"])) << 16
                                                | byte(num(value["g"])) << 8 | byte(num(value["b"])))]
        }
        return r
    }

    private mutating func resolveFont(postscript: String?, family: String?, face: String?) -> (String, String) {
        fonts.resolve(postscript: postscript, family: family, face: face, report: &report)
    }
}
