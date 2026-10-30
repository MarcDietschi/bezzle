import AppKit

/// What an import brought across, and what it could only come close to, so it is clear what to
/// look at.
struct XDReport {
    var artboards = 0
    var layers = 0
    /// What was approximated, and how often.
    var notes: [String: Int] = [:]
    var missingFonts: Set<String> = []

    mutating func note(_ what: String) { notes[what, default: 0] += 1 }

    /// The notes as sentences, the most frequent first.
    var lines: [String] {
        var out = notes.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }
        if !missingFonts.isEmpty { out.append("Fonts not on this Mac: " + missingFonts.sorted().joined(separator: ", ")) }
        return out
    }
}

/// Reads Adobe XD files. An .xd file is a ZIP archive with a manifest of its artboards, a JSON
/// scene for each (XD calls it a graphics tree), shared resources such as component masters,
/// and the pictures. Everything Bezzle can draw comes across as it is; the rest comes as close
/// as Bezzle allows and is counted in the report.
enum XDImporter {
    nonisolated static let fileExtension = "xd"

    enum Failure: Error, LocalizedError {
        case notXD

        var errorDescription: String? { "This is not an Adobe XD file Bezzle can read." }
    }

    /// Makes a new design out of the XD file, in `folder`, and says where it is.
    static func importFile(_ url: URL, into folder: URL) throws -> (URL, XDReport) {
        let archive = try ZipArchive(url: url)
        guard archive.contains("manifest") else { throw Failure.notXD }
        var converter = Converter(archive: archive)
        let doc = try converter.document()

        let target = Library.shared.freeURL(named: url.deletingPathExtension().lastPathComponent, in: folder)
        let images = target.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for (asset, source) in converter.images {
                do {
                    try archive.read(source).write(to: images.appendingPathComponent(asset))
                } catch {
                    converter.report.note("Pictures missing from the XD file")
                }
            }
            try DesignFile.write(doc, to: target)
        } catch {
            // Only what this import made itself is taken away again.
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return (target, converter.report)
    }

    /// The design an XD file makes, without writing anything, for checking.
    static func read(_ url: URL) throws -> (BezzleDocument, XDReport) {
        let archive = try ZipArchive(url: url)
        guard archive.contains("manifest") else { throw Failure.notXD }
        var converter = Converter(archive: archive)
        let doc = try converter.document()
        return (doc, converter.report)
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

/// Where an element lands in Bezzle: its frame in the parent, how far it is turned, and what
/// was left of its transform after that.
private struct Placement {
    var frame: CGRect
    var rotation: Double
    var flipped: Bool
    var scale: CGSize
}

private struct Converter {
    let archive: ZipArchive
    var report = XDReport()
    /// Pictures the design keeps: its file name there, and where it is in the archive.
    var images: [String: String] = [:]
    /// Component masters and everything in them, by id, for the instances that point at them.
    private var masters: [String: JSON] = [:]
    /// Gradients and masks kept apart from where they are used, as older files do.
    private var gradients: [String: JSON] = [:]
    private var clipPaths: [String: JSON] = [:]
    /// The kind of each picture in the archive, by its name there.
    private var imageTypes: [String: String] = [:]
    private var fonts: [String: (String, String)] = [:]

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
                    doc.nodes.append(artboard(scene, name: entry["name"] as? String ?? "Artboard", frame: frame))
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
        // The mask is kept with the group, or in older files among the shared resources.
        let ref = dict(dict(e["style"])["clipPath"])["ref"] as? String
        let mask = list(dict(ux["clipPathResources"])["children"]).first ?? ref.flatMap { list(clipPaths[$0]?["children"]).first }
        if let mask, let shape = convert(mask, into: m) {
            g.mask = [shape]
        } else if ref != nil {
            report.note("Masks that could not be found")
        }
        if ux["repeatGrid"] != nil { report.note("Repeat grids, brought in as groups") }
        return g.children.isEmpty ? nil : g
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

    /// An outline in the element's own coordinates, kept turned as the element is; any stretch,
    /// flip or slant is worked into the outline itself.
    private mutating func path(_ data: String, _ m: CGAffineTransform, style: JSON) -> Node? {
        let theta = atan2(m.b, m.a)
        let turn = CGAffineTransform(rotationAngle: theta)
        let rest = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0).concatenating(turn.inverted())
        let shaped = PathData.transformed(data, rest)
        let box = PathData.bounds(shaped)
        guard box.width.isFinite, box.height.isFinite, !box.isNull else { return nil }
        let center = CGPoint(x: box.midX, y: box.midY).applying(turn)
        var n = Node(kind: .path, frame: CGRect(center: CGPoint(x: center.x + m.tx, y: center.y + m.ty), size: box.size))
        n.rotation = CanvasView.normalized(Double(theta) * 180 / .pi)
        n.path = shaped
        n.pathBox = box
        paint(&n, style, flipped: false)
        if !Self.isClosed(shaped) && n.border.on && n.border.position != .center { n.border.position = .center }
        return n
    }

    private static func isClosed(_ data: String) -> Bool { data.contains("Z") || data.contains("z") }

    /// Takes a box in an element's coordinates to a frame and a turn in the parent. Slanted
    /// shapes cannot be a frame and a turn, so they become outlines instead.
    private func place(_ box: CGRect, _ m: CGAffineTransform) -> Placement? {
        let theta = atan2(m.b, m.a)
        let rest = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0).concatenating(CGAffineTransform(rotationAngle: theta).inverted())
        guard abs(rest.c) < 0.001 * max(abs(rest.a), abs(rest.d), 1) else { return nil }
        let size = CGSize(width: box.width * abs(rest.a), height: box.height * abs(rest.d))
        let center = CGPoint(x: box.midX, y: box.midY).applying(m)
        return Placement(frame: CGRect(center: center, size: size), rotation: CanvasView.normalized(Double(theta) * 180 / .pi),
                         flipped: rest.d < 0, scale: CGSize(width: abs(rest.a), height: abs(rest.d)))
    }

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
            guard archive.contains(source) else { report.note("Pictures missing from the XD file"); return Fill(on: true, color: .shape) }
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
                let shadows = list(params["dropShadows"])
                if let s = shadows.first {
                    n.shadow = Shadow(on: visible, color: color(s["color"]), x: num(s["dx"]), y: num(s["dy"]), blur: num(s["r"]))
                }
                if shadows.count > 1 && visible { report.note("Layers with several shadows, keeping the first") }
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

    private mutating func text(_ e: JSON, _ m: CGAffineTransform) -> Node? {
        let t = dict(e["text"]), style = dict(e["style"])
        var n = Node(kind: .text, frame: .zero)
        n.text = t["rawText"] as? String ?? ""
        let ranges = list(dict(dict(e["meta"])["ux"])["rangedStyles"])
        // Several styles in one text come across in the one used for most of it.
        let main = ranges.max { num($0["length"]) < num($1["length"]) } ?? [:]
        if Set(ranges.map { "\($0["postscriptName"] ?? "")|\($0["fontSize"] ?? "")|\(dict($0["fill"])["value"] ?? "")" }).count > 1 {
            report.note("Texts with several styles, shown in their main one")
        }
        let font = dict(style["font"])
        var ts = TextStyle()
        let (family, face) = resolveFont(postscript: (main["postscriptName"] ?? font["postscriptName"]) as? String,
                                         family: (main["fontFamily"] ?? font["family"]) as? String,
                                         face: (main["fontStyle"] ?? font["style"]) as? String)
        ts.family = family
        ts.face = face
        ts.size = num(main["fontSize"] ?? font["size"], 12)
        let attributes = dict(style["textAttributes"])
        ts.tracking = num(main["charSpacing"] ?? attributes["letterSpacing"])
        if let height = attributes["lineHeight"] { ts.lineSpacing = num(height) }
        ts.align = switch attributes["paragraphAlign"] as? String {
        case "center": .center
        case "right": .right
        default: .left
        }
        if attributes["paragraphAlign"] as? String == "justify" { report.note("Justified texts, set flush left") }
        ts.underline = main["underline"] as? Bool ?? false
        ts.letterCase = switch main["textTransform"] as? String {
        case "uppercase": .upper
        case "lowercase": .lower
        case "titlecase": .title
        default: nil
        }
        if let fill = style["fill"] as? JSON, let f = self.fill(fill, flipped: false) {
            n.fill = f.gradient == nil && f.image == nil ? f : Fill(on: true, color: f.color)
            if f.gradient != nil { report.note("Texts filled with a gradient, in its first colour") }
        } else if let value = dict(main["fill"])["value"] {
            n.fill = Fill(on: true, color: color(["value": value]))
        }

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
            n.style?.size = (ts.size * placed.scale.height * 10).rounded() / 10
            report.note("Stretched texts, set at the size they show")
        }
        return n
    }

    /// The family and face as Bezzle names them, from what XD says. The Mac's own San Francisco
    /// is the system font; a font that is not installed keeps its name, and is reported.
    private mutating func resolveFont(postscript: String?, family: String?, face: String?) -> (String, String) {
        let key = "\(postscript ?? "")|\(family ?? "")|\(face ?? "")"
        if let known = fonts[key] { return known }
        var result: (String, String)
        if let family, family.hasPrefix("SF Pro") || family.hasPrefix(".SF") || family == "San Francisco" {
            let wanted = face ?? "Regular"
            result = (TextStyle.system, Fonts.faces(of: TextStyle.system).contains(wanted) ? wanted : "Regular")
        } else if let postscript, let font = NSFont(name: postscript, size: 12), let found = font.familyName {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: found) ?? []
            let named = members.first { $0.first as? String == postscript }.flatMap { $0.count > 1 ? $0[1] as? String : nil }
            result = (found, named ?? face ?? "Regular")
        } else if let family, NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            result = (family, face ?? "Regular")
        } else {
            report.missingFonts.insert([family, face].compactMap { $0 }.joined(separator: " "))
            result = (family ?? TextStyle.system, face ?? "Regular")
        }
        fonts[key] = result
        return result
    }
}
