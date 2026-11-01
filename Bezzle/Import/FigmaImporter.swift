import AppKit

/// Reads Figma files, as Figma saves a local copy of a design: a ZIP archive holding `canvas.fig`,
/// the design in Kiwi, and its pictures, each named by its SHA-1. Older copies are the
/// `canvas.fig` alone. Frames right on a page become artboards and frames in frames groups, cut
/// to their frame when they clip; a component instance comes across as what it shows, the
/// layers of its master with the instance's own changes. Everything Bezzle can draw comes
/// across as it is; the rest comes as close as Bezzle allows and is counted in the report.
enum FigmaImporter {
    nonisolated static let fileExtension = "fig"

    enum Failure: Error, LocalizedError {
        case notFigma

        var errorDescription: String? { String(localized: "This is not a Figma file Bezzle can read.") }
    }

    /// The design a Figma file makes, its pictures still in the file.
    static func read(_ url: URL) throws -> Imported {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var archive: ZipArchive?
        var canvas = data
        if data.starts(with: [0x50, 0x4B]) {
            let zip = try ZipArchive(data: data)
            guard zip.contains("canvas.fig") else { throw Failure.notFigma }
            canvas = try zip.read("canvas.fig")
            archive = zip
        }
        var converter = Converter(message: try message(canvas), archive: archive)
        let doc = converter.document()
        return Imported(document: doc, report: converter.report, archive: archive, pictures: converter.pictures, held: converter.held)
    }

    /// What a `canvas.fig` holds: eight bytes saying what it is, a version, and then the schema
    /// and the design, each a length and the part compressed, with deflate in older files and
    /// Zstandard in newer ones.
    static func message(_ canvas: Data) throws -> Kiwi.Object {
        let bytes = [UInt8](canvas)
        guard bytes.count >= 12, bytes.starts(with: Array("fig-".utf8)) else { throw Failure.notFigma }
        var parts: [Data] = []
        var p = 12
        while p + 4 <= bytes.count, parts.count < 2 {
            let n = Int(UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
            guard n <= bytes.count - p - 4 else { throw Kiwi.Failure.damaged("a part reaches past the end") }
            parts.append(Data(bytes[(p + 4)..<(p + 4 + n)]))
            p += 4 + n
        }
        guard parts.count == 2 else { throw Failure.notFigma }
        let schema = try Kiwi.Schema(unpack(parts[0]))
        return try schema.read(unpack(parts[1]), as: "Message")
    }

    private static func unpack(_ part: Data) throws -> Data {
        if part.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return try Zstd.decompress(part) }
        do {
            return try (part as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Kiwi.Failure.damaged("a part could not be unpacked")
        }
    }
}

private typealias Object = Kiwi.Object

private func num(_ v: Kiwi.Value?, _ fallback: CGFloat = 0) -> CGFloat {
    guard let d = v?.number, d.isFinite else { return fallback }
    return CGFloat(d)
}

/// Figma names each layer by the session that made it and a number within that session.
private struct GUID: Hashable {
    let session: Int
    let local: Int

    init?(_ o: Object?) {
        guard let o, let session = o["sessionID"]?.int, let local = o["localID"]?.int else { return nil }
        self.session = session
        self.local = local
    }

    /// What Figma writes where there is nothing to name.
    var isNone: Bool { session == 0xFFFF_FFFF }
}

private extension Kiwi.Object {
    func guid(_ name: String) -> GUID? { GUID(self[name]?.object) }
    func num(_ name: String, _ fallback: CGFloat = 0) -> CGFloat {
        guard let d = self[name]?.number, d.isFinite else { return fallback }
        return CGFloat(d)
    }
}

/// A change an instance makes to a layer of its master: the layer it is for, by the keys of the
/// instances on the way to it and its own, and the fields it sets.
private struct Change {
    var path: [GUID]
    var node: Object
}

/// The changes that apply inside an instance: those made to it, then those Figma worked out
/// itself when it was resized or its words changed.
private struct Scope {
    var overrides: [Change] = []
    var derived: [Change] = []

    var isEmpty: Bool { overrides.isEmpty && derived.isEmpty }
}

private struct Converter {
    var report = ImportReport(source: "Figma")
    /// Pictures the design keeps: its file name there, and where it is in the archive.
    var pictures: [String: String] = [:]
    /// Pictures from files that are not archives, which keep them with the design.
    var held: [String: Data] = [:]
    private let archive: ZipArchive?
    private let blobs: [Data]
    private var nodes: [GUID: Object] = [:]
    /// What each layer holds, bottom first.
    private var children: [GUID: [GUID]] = [:]
    /// The layers of components, by the keys instances name them by, where those differ.
    private var keyed: [GUID: GUID] = [:]
    /// Each picture looked for, by its hash: its file name in the design and its size, or nil when it is missing.
    private var found: [String: (String, CGSize)?] = [:]
    /// The masters being laid out, so a component that holds itself stops.
    private var expanding: Set<GUID> = []
    private var fonts = FontMatch()
    /// How many masks have been made, to name each.
    private var masks = 0

    private static let identity: Set<String> = ["guid", "guidPath", "parentIndex", "overrideKey", "type", "phase", "styleID"]
    /// What an instance keeps of its own when changes are made to its master as a whole.
    private static let placing = identity.union(["transform", "size"])

    init(message: Object, archive: ZipArchive?) {
        self.archive = archive
        blobs = (message["blobs"]?.objects ?? []).map { $0["bytes"]?.data ?? Data() }
        var parents: [GUID: (GUID, String)] = [:]
        for n in message["nodeChanges"]?.objects ?? [] {
            guard let id = n.guid("guid"), n["phase"]?.string != "REMOVED" else { continue }
            nodes[id] = n
            if let key = n.guid("overrideKey"), !key.isNone, key != id { keyed[key] = id }
            if let parent = n["parentIndex"]?.object, let pid = GUID(parent["guid"]?.object) {
                parents[id] = (pid, parent["position"]?.string ?? "")
            }
        }
        var placed: [GUID: [(String, GUID)]] = [:]
        for (id, (parent, position)) in parents { placed[parent, default: []].append((position, id)) }
        // Figma orders what a layer holds by strings that sort the way it is stacked.
        for (parent, list) in placed {
            children[parent] = list.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }.map(\.1)
        }
    }

    mutating func document() -> BezzleDocument {
        let root = nodes.first { $0.value["type"]?.string == "DOCUMENT" }?.key
        var pages: [[Node]] = []
        for (id, page) in held(by: root) where page["type"]?.string == "CANVAS" && page["internalOnly"]?.bool != true {
            let laid = top(held(by: id), into: .identity)
            if !laid.isEmpty { pages.append(laid) }
            if page["guides"]?.objects.isEmpty == false { report.note("Guides on the canvas, left out") }
        }
        for _ in pages.dropFirst() { report.note("Pages, laid out under the first") }
        var doc = BezzleDocument()
        let laid = Importer.stack(pages)
        // Artboards under loose layers, as Figma shows them.
        doc.nodes = laid.filter(\.isArtboard) + laid.filter { !$0.isArtboard }
        // No viewport: the canvas fits the design to itself when it first opens.
        return doc
    }

    private func held(by id: GUID?) -> [(GUID, Object)] {
        guard let id else { return [] }
        return (children[id] ?? []).compactMap { c in nodes[c].map { (c, $0) } }
    }

    /// Figma keeps a group as a frame that fits itself to what it holds.
    private func isGroup(_ n: Object) -> Bool {
        n["type"]?.string == "GROUP" || (n["type"]?.string == "FRAME" && n["resizeToFit"]?.bool == true)
    }

    private func transform(_ n: Object) -> CGAffineTransform {
        guard let t = n["transform"]?.object else { return .identity }
        return CGAffineTransform(a: t.num("m00", 1), b: t.num("m10"), c: t.num("m01"), d: t.num("m11", 1), tx: t.num("m02"), ty: t.num("m12"))
    }

    private func size(_ n: Object) -> CGSize {
        let s = n["size"]?.object
        return CGSize(width: max(s?.num("x") ?? 0, 0), height: max(s?.num("y") ?? 0, 0))
    }

    /// The key instances name a layer of a master by.
    private func key(_ n: Object, _ id: GUID) -> GUID {
        if let k = n.guid("overrideKey"), !k.isNone { return k }
        return id
    }

    // MARK: Layers

    /// The layers right on a page, bottom first. Frames there are artboards; a section gives what
    /// it holds to the page; anything else lies on the canvas, a mask among them cutting off those
    /// above it up to the next artboard.
    private mutating func top(_ kids: [(GUID, Object)], into m: CGAffineTransform) -> [Node] {
        var out: [Node] = [], loose: [(GUID, Object)] = []
        func lay(_ out: inout [Node], _ loose: inout [(GUID, Object)]) {
            out += layers(loose, into: m, scope: Scope())
            loose = []
        }
        for (id, n) in kids {
            let type = n["type"]?.string
            if type == "SECTION" {
                report.note("Sections, left out around what they hold")
                lay(&out, &loose)
                out += top(held(by: id), into: transform(n).concatenating(m))
            } else if ["FRAME", "SYMBOL", "INSTANCE"].contains(type), !isGroup(n), let board = artboard(n, id, m) {
                lay(&out, &loose)
                out.append(board)
            } else {
                loose.append((id, n))
            }
        }
        lay(&out, &loose)
        return out
    }

    /// The layers a frame or group holds, bottom first. A layer that is a mask cuts off those
    /// above it without being drawn itself, so they become a mask, Bezzle's own, its shape clear.
    private mutating func layers(_ kids: [(GUID, Object)], into m: CGAffineTransform, scope: Scope) -> [Node] {
        var out: [Node] = []
        var cut: (shape: Node, held: [Node])?
        func close(_ out: inout [Node], _ cut: inout (shape: Node, held: [Node])?) {
            defer { cut = nil }
            guard let (shape, held) = cut, !held.isEmpty else { return }
            if let holder = ImportMask.holder(shape, drawn: false), let mask = ImportMask.mask(holder, holding: held, name: maskName()) {
                out.append(mask)
            } else {
                // Only a shape can hold others; anything else cuts by its box, as it always did.
                report.note("Masks of text or lines, cutting by their box")
                var g = Node(kind: .group, frame: .zero)
                g.mask = [shape]
                g.children = held
                out.append(g)
            }
        }
        for (id, k) in kids {
            if k["mask"]?.bool == true, k["visible"]?.bool != false, var shape = convert(k, id, into: m, scope: scope) {
                close(&out, &cut)
                if k["maskType"]?.string == "LUMINANCE" {
                    report.note("Masks by brightness, cutting by their shape")
                } else if k["maskType"]?.string != "OUTLINE", k["maskIsOutline"]?.bool != true, fades(k) {
                    report.note("Alpha masks, cutting by their outline")
                }
                shape.hidden = false
                cut = (shape, [])
                continue
            }
            guard let n = convert(k, id, into: m, scope: scope) else { continue }
            if cut != nil { cut?.held.append(n) } else { out.append(n) }
        }
        close(&out, &cut)
        return out
    }

    /// The name of the next mask: "Mask 1", "Mask 2", as Bezzle names its own.
    private mutating func maskName() -> String {
        masks += 1
        return String(localized: "Mask \(masks)")
    }

    /// Whether a mask cutting by how clear its paints are would fade what it holds, rather than
    /// cut it off at its outline: some paint of it lets what lies under it through.
    private func fades(_ e: Object) -> Bool {
        shown(e["fillPaints"]?.objects ?? []).contains { p in
            if num(p["opacity"], 1) < 0.999 { return true }
            switch p["type"]?.string {
            case "SOLID": return color(p["color"]).a < 0.999
            case "IMAGE": return false
            default: return (p["stops"]?.objects ?? []).contains { color($0["color"]).a < 0.999 }
            }
        }
    }

    /// A layer of a master with the changes meant for it, and those to pass on to what it holds:
    /// through a layer that is not an instance all of them, as paths name only the instances on
    /// the way; through an instance those that go on past it.
    private func apply(_ scope: Scope, to raw: Object, _ id: GUID) -> (Object, Scope) {
        guard !scope.isEmpty else { return (raw, scope) }
        let key = self.key(raw, id)
        var n = raw
        var down = Scope()
        for c in scope.overrides where c.path.first == key {
            if c.path.count == 1 { n = n.merged(with: c.node, except: Self.identity) } else { down.overrides.append(Change(path: Array(c.path.dropFirst()), node: c.node)) }
        }
        for c in scope.derived where c.path.first == key {
            if c.path.count == 1 { n = n.merged(with: c.node, except: Self.identity) } else { down.derived.append(Change(path: Array(c.path.dropFirst()), node: c.node)) }
        }
        return (n, n["type"]?.string == "INSTANCE" ? down : scope)
    }

    /// What a frame holds and the changes that apply there. An instance holds its master's
    /// layers, with its own changes and then those passed down to it, which win; changes to the
    /// master as a whole are laid over the instance. Also says which master it is.
    private mutating func contents(of n: inout Object, _ id: GUID, scope: Scope) -> ([(GUID, Object)], Scope, GUID?) {
        guard n["type"]?.string == "INSTANCE" else { return (held(by: id), scope, nil) }
        let data = n["symbolData"]?.object
        let symbol = n.guid("overriddenSymbolID") ?? data?.guid("symbolID")
        guard let symbol, let masterID = nodes[symbol] != nil ? symbol : keyed[symbol], let master = nodes[masterID] else {
            report.note("Component instances whose master is missing")
            return ([], Scope(), nil)
        }
        guard !expanding.contains(masterID) else {
            report.note("Components that hold themselves, left empty inside")
            return ([], Scope(), nil)
        }
        var inner = Scope()
        inner.overrides = (data?["symbolOverrides"]?.objects ?? []).compactMap(change) + properties(of: n, master: masterID) + scope.overrides
        inner.derived = (n["derivedSymbolData"]?.objects ?? []).compactMap(change) + scope.derived
        let whole = key(master, masterID)
        for c in inner.overrides where c.path == [whole] { n = n.merged(with: c.node, except: Self.placing) }
        if let s = data?["uniformScaleFactor"]?.number, abs(s - 1) > 0.001 { report.note("Instances scaled as a whole, their insides at full size") }
        return (held(by: masterID), inner, masterID)
    }

    private func change(_ o: Object) -> Change? {
        let path = (o["guidPath"]?.object?["guids"]?.objects ?? []).compactMap { GUID($0) }
        return path.isEmpty ? nil : Change(path: path, node: o)
    }

    /// The component properties set on an instance, as the changes they make to the layers of
    /// its master that use them.
    private func properties(of instance: Object, master: GUID) -> [Change] {
        let assigned = instance["componentPropAssignments"]?.objects ?? []
        guard !assigned.isEmpty else { return [] }
        var out: [Change] = []
        var stack = held(by: master)
        while let next = stack.popLast() {
            let (id, n) = next
            stack += held(by: id)
            for ref in n["componentPropRefs"]?.objects ?? [] where ref["isDeleted"]?.bool != true {
                guard let def = ref.guid("defID"), let a = assigned.first(where: { $0.guid("defID") == def }) else { continue }
                let value = a["value"]?.object, variable = a["varValue"]?.object?["value"]?.object
                let blank = Object(type: n.type, fields: [])
                let set: Object
                switch ref["componentPropNodeField"]?.string {
                case "TEXT_DATA": set = blank.setting("textData", value?["textValue"] ?? variable?["textDataValue"])
                case "VISIBLE": set = blank.setting("visible", value?["boolValue"] ?? variable?["boolValue"])
                case "OVERRIDDEN_SYMBOL_ID": set = blank.setting("overriddenSymbolID", value?["guidValue"] ?? variable?["symbolIdValue"]?.object?["guid"])
                default: continue
                }
                if !set.fields.isEmpty { out.append(Change(path: [key(n, id)], node: set)) }
            }
        }
        return out
    }

    /// One layer and everything in it. `outer` takes the layer's parent's coordinates to those
    /// of the Bezzle layer it goes into; groups are never turned in Bezzle, so a group's own
    /// transform is handed down to what it holds.
    private mutating func convert(_ raw: Object, _ id: GUID, into outer: CGAffineTransform, scope: Scope) -> Node? {
        let applied = apply(scope, to: raw, id)
        var e = applied.0
        let inner = applied.1
        let m = transform(e).concatenating(outer)
        var node: Node?
        // Frames put their effects where they belong themselves.
        var placed = false
        switch e["type"]?.string {
        case "FRAME", "SYMBOL", "INSTANCE", "GROUP", "SECTION":
            let (kids, within, master) = contents(of: &e, id, scope: inner)
            node = frame(e, kids, within, master: master, m)
            placed = true
        case "RECTANGLE", "ROUNDED_RECTANGLE": node = rectangle(e, m)
        case "ELLIPSE": node = ellipse(e, m)
        case "LINE": node = line(e, m)
        case "VECTOR", "STAR", "REGULAR_POLYGON", "BOOLEAN_OPERATION": node = vector(e, m)
        case "TEXT": node = text(e, m)
        case "SLICE": return nil
        default:
            if children[id] != nil {
                node = frame(e, held(by: id), inner, master: nil, m)
                placed = true
            } else if e["fillGeometry"]?.array.isEmpty == false {
                node = vector(e, m)
            } else {
                report.note("Kinds of layer Bezzle does not know")
            }
        }
        guard var n = node else { return nil }
        if let name = e["name"]?.string, !name.isEmpty { n.name = name }
        if !placed { effects(&n, e) }
        if e["visible"]?.bool == false { n.hidden = true }
        if e["locked"]?.bool == true { n.locked = true }
        report.layers += 1
        return n
    }

    // MARK: Frames

    /// A frame right on a page, as an artboard; nil when it is turned or flipped, which an
    /// artboard cannot be.
    private mutating func artboard(_ raw: Object, _ id: GUID, _ outer: CGAffineTransform) -> Node? {
        let t = transform(raw).concatenating(outer)
        guard abs(t.b) < 0.001, abs(t.c) < 0.001, t.a > 0, t.d > 0 else { return nil }
        var e = raw
        let (kids, scope, master) = contents(of: &e, id, scope: Scope())
        let size = self.size(e)
        var board = Node(kind: .artboard, name: e["name"]?.string ?? String(localized: "Frame"), frame: CGRect(x: t.tx, y: t.ty, width: size.width * t.a, height: size.height * t.d))
        report.artboards += 1
        let inside = CGAffineTransform(scaleX: t.a, y: t.d)
        if let master { expanding.insert(master) }
        let held = layers(kids, into: inside, scope: scope)
        if let master { expanding.remove(master) }
        board.clips = e["frameMaskDisabled"]?.bool != true
        let box = CGRect(origin: .zero, size: size)
        // An artboard has one fill of its own; more, unless they come to one colour, and round
        // corners are drawn by a layer under what it holds.
        let one = boardFill(e["fillPaints"]?.objects ?? [])
        let (under, over) = backing(e, box, inside, alone: one == nil || corners(e).contains { $0 > 0 })
        if let under {
            board.fill.on = false
            board.children = [under] + held
        } else {
            board.fill = one ?? Fill(on: false, color: .white)
            board.children = held
        }
        if let over { board.children.append(over) }
        board.layout = layoutGrid(e, scale: CGSize(width: t.a, height: t.d), in: board.frame.size)
        let guides = (e["guides"]?.objects ?? []).map { (vertical: $0["axis"]?.string != "Y", at: $0.num("offset")) }
        board.guides = ImportLayout.guides(across: guides.filter(\.vertical).map { $0.at * t.a },
                                           down: guides.filter { !$0.vertical }.map { $0.at * t.d }, in: board.frame.size)
        if e["effects"]?.objects.contains(where: { $0["visible"]?.bool != false }) == true { report.note("Shadows and blurs on artboards, left out") }
        if num(e["opacity"], 1) < 1 { report.note("See-through artboards, drawn solid") }
        if e["visible"]?.bool == false { board.hidden = true }
        if e["locked"]?.bool == true { board.locked = true }
        return board
    }

    /// The columns, rows and baselines a frame right on a page is laid out on, as far as Bezzle's
    /// grid holds them: one of each, columns and rows stretching between equal margins. Rows that
    /// touch are lines a step apart, a baseline grid. `scale` is how much the frame is stretched.
    private mutating func layoutGrid(_ e: Object, scale: CGSize, in size: CGSize) -> LayoutGrid? {
        var grid = LayoutGrid(), more = false
        for g in e["layoutGrids"]?.objects ?? [] where g["visible"]?.bool != false {
            if g["pattern"]?.string == "GRID" {
                report.note("Square grids, left out")
                continue
            }
            let across = g["axis"]?.string != "Y", k = across ? scale.width : scale.height
            let length = across ? size.width : size.height
            let gutter = max(g.num("gutterSize"), 0) * k, offset = g.num("offset") * k, section = max(g.num("sectionSize"), 0) * k
            // Figma counts as many as fit, when told to, by the largest number it can.
            let told = g["numSections"]?.int ?? 1, fitting = told <= 0 || told >= Int(Int32.max)
            var track: LayoutGrid.Track?
            if g["type"]?.string == "STRETCH" || g["type"] == nil {
                track = ImportLayout.stretched(count: fitting ? 1 : told, gutter: gutter, start: offset, end: offset, report: &report)
            } else {
                let room = g["type"]?.string == "CENTER" ? length : length - max(offset, 0)
                let count = fitting ? max(Int(((room + gutter) / max(section + gutter, 1)).rounded(.down)), 1) : told
                let total = CGFloat(count) * section + CGFloat(count - 1) * gutter
                let start = switch g["type"]?.string {
                case "CENTER": (length - total) / 2
                case "MAX": length - offset - total
                default: offset
                }
                if !across, gutter == 0, LayoutGrid.Baseline.steps.contains(section) {
                    if grid.baseline == nil {
                        let first = start.truncatingRemainder(dividingBy: section)
                        grid.baseline = LayoutGrid.Baseline(step: section, offset: first < 0 ? first + section : first)
                    } else {
                        more = true
                    }
                    continue
                }
                track = ImportLayout.track(count: count, size: section, gutter: gutter, start: start, along: length, report: &report)
            }
            guard let track else { continue }
            if across {
                if grid.columns == nil { grid.columns = track } else { more = true }
            } else {
                if grid.rows == nil { grid.rows = track } else { more = true }
            }
        }
        if more { report.note("Further layout grids of the same kind, left out") }
        return grid.orNil
    }

    /// A frame in a frame, or a group: a Bezzle group of what it holds, over a rectangle with the
    /// frame's fill and under one with its border, as Figma draws a frame's border over what it
    /// holds; cut to the frame when it clips.
    private mutating func frame(_ e: Object, _ kids: [(GUID, Object)], _ scope: Scope, master: GUID?, _ m: CGAffineTransform) -> Node? {
        if let master { expanding.insert(master) }
        let held = layers(kids, into: m, scope: scope)
        if let master { expanding.remove(master) }
        var g = Node(kind: .group, frame: .zero)
        if isGroup(e) {
            guard !held.isEmpty else { return nil }
            g.children = held
            effects(&g, e)
            return g
        }
        // Only an artboard is laid out on a grid or has guides of its own.
        if e["layoutGrids"]?.objects.contains(where: { $0["visible"]?.bool != false }) == true { report.note("Layout grids on frames inside frames, left out") }
        if e["guides"]?.objects.isEmpty == false { report.note("Guides on frames inside frames, left out") }
        let box = CGRect(origin: .zero, size: size(e))
        let (under, over) = backing(e, box, m, alone: true)
        if held.isEmpty, var only = under ?? over {
            // A frame with nothing in it is its rectangle.
            if under != nil, let over { only.borders = over.borders }
            effects(&only, e)
            return only
        }
        if e["frameMaskDisabled"]?.bool != true, !held.isEmpty, let edge = boxShape(e, box, m)?.0, ImportMask.reaches(held, outside: edge) {
            // A frame cutting off what reaches past it holds it as a mask does: its fill under it
            // and its border over it, as Figma draws a frame.
            var holder = under ?? edge
            if under == nil {
                ImportMask.clear(&holder)
                holder.name = String(localized: "Edge")
            }
            holder.borders = over?.borders ?? []
            g.children = [holder] + held
            g.clipsToFirst = true
        } else {
            g.children = [under].compactMap { $0 } + held + [over].compactMap { $0 }
        }
        guard !g.children.isEmpty else { return nil }
        effects(&g, e)
        // What lies behind a frame is blurred through its fill.
        if let blur = g.blur, blur.background {
            g.blur = nil
            if under != nil { g.children[0].blur = blur }
        }
        return g
    }

    /// The rectangles a frame's fill and border are drawn with, when it has them; its fill only
    /// when it needs one of its own, which it does `alone`.
    private mutating func backing(_ e: Object, _ box: CGRect, _ m: CGAffineTransform, alone: Bool) -> (Node?, Node?) {
        let fills = self.fills(e["fillPaints"]?.objects ?? [])
        let borders = self.borders(e, open: false)
        var under: Node?, over: Node?
        if !fills.isEmpty, alone, let shaped = boxShape(e, box, m) {
            var r = shaped.0
            r.name = String(localized: "Background")
            r.fills = shaped.1 ? fills.map { $0.flipped(horizontally: false) } : fills
            r.borders = []
            under = r
        }
        if !borders.isEmpty, let shaped = boxShape(e, box, m) {
            var r = shaped.0
            r.name = String(localized: "Border")
            r.fills = []
            r.borders = shaped.1 ? borders.map { $0.flipped(horizontally: false) } : borders
            over = r
        }
        return (under, over)
    }

    // MARK: Shapes

    private func corners(_ e: Object) -> [CGFloat] {
        if e["rectangleCornerRadiiIndependent"]?.bool == true {
            return ["rectangleTopLeftCornerRadius", "rectangleTopRightCornerRadius", "rectangleBottomRightCornerRadius", "rectangleBottomLeftCornerRadius"].map { e.num($0) }
        }
        return Array(repeating: e.num("cornerRadius"), count: 4)
    }

    /// A rectangle the shape of a rectangle or frame, placed by `m`, and whether it is flipped;
    /// slanted, an outline instead.
    private func boxShape(_ e: Object, _ box: CGRect, _ m: CGAffineTransform) -> (Node, Bool)? {
        guard let placed = ImportGeometry.place(box, m) else {
            let path = Renderer.roundedRect(box, corners: corners(e))
            return ImportGeometry.outline(PathData.string(path), m).map { ($0, false) }
        }
        var n = Node(kind: .rectangle, frame: placed.frame)
        n.rotation = placed.rotation
        let s = min(placed.scale.width, placed.scale.height)
        var radii = corners(e).map { $0 * s }
        if placed.flipped { radii = [radii[3], radii[2], radii[1], radii[0]] }
        if Set(radii).count == 1 { n.cornerRadius = radii[0] } else { n.corners = radii }
        let smoothing = e.num("cornerSmoothing")
        if smoothing > 0, radii.contains(where: { $0 > 0 }) { n.cornerSmoothing = min(smoothing, 1) }
        return (n, placed.flipped)
    }

    private mutating func rectangle(_ e: Object, _ m: CGAffineTransform) -> Node? {
        guard let shaped = boxShape(e, CGRect(origin: .zero, size: size(e)), m) else { return nil }
        var n = shaped.0
        paint(&n, e, flipped: shaped.1)
        return n
    }

    private mutating func ellipse(_ e: Object, _ m: CGAffineTransform) -> Node? {
        // A slice of a ring is an outline, which Figma has worked out.
        if let arc = e["arcData"]?.object {
            let sweep = abs(arc.num("endingAngle") - arc.num("startingAngle"))
            if arc.num("innerRadius") > 0.001 || (sweep > 0.001 && abs(sweep - 2 * .pi) > 0.001) { return vector(e, m) }
        }
        guard let placed = ImportGeometry.place(CGRect(origin: .zero, size: size(e)), m) else { return vector(e, m) }
        var n = Node(kind: .ellipse, frame: placed.frame)
        n.rotation = placed.rotation
        paint(&n, e, flipped: placed.flipped)
        return n
    }

    private mutating func line(_ e: Object, _ m: CGAffineTransform) -> Node? {
        var n = Node(kind: .line, frame: .zero)
        n.setLineEnds(CGPoint.zero.applying(m), CGPoint(x: size(e).width, y: 0).applying(m))
        n.borders = borders(e, open: true)
        return n
    }

    /// An outline: a vector, a star, a polygon or what a boolean operation makes, as Figma worked
    /// it out. A vector may fill each of the regions its lines close in a paint of its own, and
    /// draw lines that close nothing; then it is a group of a layer for each fill and one for
    /// the border along its lines.
    private mutating func vector(_ e: Object, _ m: CGAffineTransform) -> Node? {
        let fills = regions(e)
        let borders = self.borders(e, open: false)
        let net = e["type"]?.string == "VECTOR" ? network(e) : nil
        guard fills.count > 1 || net?.loose == true else {
            if let only = fills.first, var n = ImportGeometry.outline(PathData.string(only.path), m) {
                paint(&n, e, flipped: false)
                n.fills = self.fills(only.paints)
                if only.evenOdd { n.evenOdd = true }
                return n
            }
            if !borders.isEmpty, let n = lines(e, net, borders, m) { return n }
            report.note("Shapes without an outline, left out")
            return nil
        }
        var g = Node(kind: .group, frame: .zero)
        for region in fills {
            let paints = self.fills(region.paints)
            guard !paints.isEmpty, var n = ImportGeometry.outline(PathData.string(region.path), m) else { continue }
            n.name = String(localized: "Fill")
            n.fills = paints
            if region.evenOdd { n.evenOdd = true }
            g.children.append(n)
        }
        if !borders.isEmpty, var n = lines(e, net, borders, m) {
            n.name = String(localized: "Border")
            g.children.append(n)
        }
        return g.children.count > 1 ? g : g.children.first
    }

    /// A vector's border: along its lines, or where Figma rounds the corners its lines meet at,
    /// which Bezzle cannot, its border's outline as a shape.
    private mutating func lines(_ e: Object, _ net: (path: CGPath, loose: Bool)?, _ borders: [Border], _ m: CGAffineTransform) -> Node? {
        let table = e["vectorData"]?.object?["styleOverrideTable"]?.objects ?? []
        let rounded = e.num("cornerRadius") > 0 || table.contains { $0.num("cornerRadius") > 0 }
        if let net, !rounded, var n = ImportGeometry.outline(PathData.string(net.path), m) {
            n.fills = []
            n.borders = net.loose ? borders.map { b in var b = b; b.position = .center; return b } : borders
            return n
        }
        guard let outline = geometry(e["strokeGeometry"]), var n = ImportGeometry.outline(PathData.string(outline.0), m) else { return nil }
        n.fills = borders.map { b in
            var f = b.paint
            f.on = true
            return f
        }
        report.note("Borders on rounded corners, drawn as shapes")
        return n
    }

    /// The parts of a layer's outline, each with the paints it is filled with: a vector's regions
    /// may have their own, the rest are filled with the layer's.
    private func regions(_ e: Object) -> [(path: CGPath, evenOdd: Bool, paints: [Object])] {
        var styles: [Int: [Object]] = [:]
        for s in e["vectorData"]?.object?["styleOverrideTable"]?.objects ?? [] {
            if let id = s["styleID"]?.int, let paints = s["fillPaints"]?.objects { styles[id] = paints }
        }
        let own = e["fillPaints"]?.objects ?? []
        var out: [(path: CGPath, evenOdd: Bool, paints: [Object])] = []
        var places: [Int: Int] = [:]
        for g in e["fillGeometry"]?.objects ?? [] {
            guard let i = g["commandsBlob"]?.int, blobs.indices.contains(i) else { continue }
            let style = styles[g["styleID"]?.int ?? 0] != nil ? g["styleID"]?.int ?? 0 : 0
            let path = CGMutablePath()
            if let at = places[style] { path.addPath(out[at].path) }
            Self.commands(blobs[i], into: path)
            let evenOdd = g["windingRule"]?.string == "ODD" || (places[style].map { out[$0].evenOdd } ?? false)
            if let at = places[style] {
                out[at] = (path, evenOdd, out[at].paints)
            } else {
                places[style] = out.count
                out.append((path, evenOdd, styles[style] ?? own))
            }
        }
        return out.filter { !$0.path.isEmpty }
    }

    /// Outlines Figma keeps as commands, each in a blob of the message.
    private func geometry(_ v: Kiwi.Value?) -> (CGPath, Bool)? {
        let path = CGMutablePath()
        var evenOdd = false
        for g in v?.objects ?? [] {
            guard let i = g["commandsBlob"]?.int, blobs.indices.contains(i) else { continue }
            Self.commands(blobs[i], into: path)
            if g["windingRule"]?.string == "ODD" { evenOdd = true }
        }
        return path.isEmpty ? nil : (path, evenOdd)
    }

    /// A byte for each command, 0 to close, 1 to move, 2 for a line, 3 for a quadratic curve and
    /// 4 for a cubic one, each followed by its points as 32-bit floats.
    private static func commands(_ blob: Data, into path: CGMutablePath) {
        let b = [UInt8](blob)
        var p = 0
        func point() -> CGPoint? {
            guard p + 8 <= b.count else { return nil }
            func float(_ i: Int) -> Float { Float(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24) }
            let x = float(p), y = float(p + 4)
            p += 8
            return x.isFinite && y.isFinite ? CGPoint(x: CGFloat(x), y: CGFloat(y)) : nil
        }
        while p < b.count {
            let command = b[p]
            p += 1
            switch command {
            case 0:
                if !path.isEmpty { path.closeSubpath() }
            case 1:
                guard let a = point() else { return }
                path.move(to: a)
            case 2:
                guard let a = point() else { return }
                if path.isEmpty { path.move(to: a) } else { path.addLine(to: a) }
            case 3:
                guard let c = point(), let a = point() else { return }
                if path.isEmpty { path.move(to: c) }
                path.addQuadCurve(to: a, control: c)
            case 4:
                guard let c1 = point(), let c2 = point(), let a = point() else { return }
                if path.isEmpty { path.move(to: c1) }
                path.addCurve(to: a, control1: c1, control2: c2)
            default:
                return
            }
        }
    }

    /// A vector's own lines: its points and the curves between them, and whether any of them
    /// close nothing, as lines drawn through points do, which an outline of the regions misses.
    private func network(_ e: Object) -> (path: CGPath, loose: Bool)? {
        let data = e["vectorData"]?.object
        guard let i = data?["vectorNetworkBlob"]?.int, blobs.indices.contains(i) else { return nil }
        let b = [UInt8](blobs[i])
        func u32(_ p: Int) -> Int? { p + 4 <= b.count ? Int(UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24) : nil }
        func f32(_ p: Int) -> CGFloat? { u32(p).map { CGFloat(Float(bitPattern: UInt32($0))) }.flatMap { $0.isFinite ? $0 : nil } }
        guard let vertices = u32(0), let segments = u32(4), vertices < b.count / 12, segments < b.count / 28 else { return nil }
        // Points are kept in a box of their own size, which the layer may since have been stretched from.
        let normal = data?["normalizedSize"]?.object, size = self.size(e)
        let sx = (normal?.num("x") ?? 0) > 0 ? size.width / (normal?.num("x") ?? 1) : 1
        let sy = (normal?.num("y") ?? 0) > 0 ? size.height / (normal?.num("y") ?? 1) : 1
        var points: [CGPoint] = []
        for v in 0..<vertices {
            guard let x = f32(12 + v * 12 + 4), let y = f32(12 + v * 12 + 8) else { return nil }
            points.append(CGPoint(x: x * sx, y: y * sy))
        }
        var ends = Array(repeating: 0, count: vertices)
        var curves: [(Int, CGPoint, Int, CGPoint)] = []
        let start = 12 + vertices * 12
        for s in 0..<segments {
            let p = start + s * 28
            guard let a = u32(p + 4), let ax = f32(p + 8), let ay = f32(p + 12), let z = u32(p + 16), let zx = f32(p + 20), let zy = f32(p + 24),
                  a < vertices, z < vertices else { return nil }
            ends[a] += 1
            ends[z] += 1
            curves.append((a, CGPoint(x: ax * sx, y: ay * sy), z, CGPoint(x: zx * sx, y: zy * sy)))
        }
        // Then the regions: how they are filled, and the loops of lines around each.
        var p = start + segments * 28, enclosing = Set<Int>()
        for _ in 0..<(u32(8) ?? 0) {
            guard let loops = u32(p + 4), loops < b.count else { break }
            p += 8
            for _ in 0..<loops {
                guard let count = u32(p), count < b.count else { break }
                for k in 0..<count { if let s = u32(p + 4 + k * 4) { enclosing.insert(s) } }
                p += 4 + count * 4
            }
        }
        let loose = ends.contains(1) || curves.indices.contains { !enclosing.contains($0) }
        let path = CGMutablePath()
        var at: Int?
        for (a, ta, z, tz) in curves {
            if at != a { path.move(to: points[a]) }
            if ta == .zero && tz == .zero {
                path.addLine(to: points[z])
            } else {
                path.addCurve(to: points[z], control1: CGPoint(x: points[a].x + ta.x, y: points[a].y + ta.y),
                              control2: CGPoint(x: points[z].x + tz.x, y: points[z].y + tz.y))
            }
            at = z
        }
        return path.isEmpty ? nil : (path, loose)
    }

    // MARK: Style

    private func color(_ v: Kiwi.Value?) -> RGBA {
        let c = v?.object
        return RGBA(r: Double(c?.num("r") ?? 0), g: Double(c?.num("g") ?? 0), b: Double(c?.num("b") ?? 0), a: Double(c?.num("a", 1) ?? 1))
    }

    private func shown(_ paints: [Object]) -> [Object] {
        paints.filter { $0["visible"]?.bool != false && num($0["opacity"], 1) > 0 }
    }

    private mutating func paint(_ n: inout Node, _ e: Object, flipped: Bool) {
        let fills = self.fills(e["fillPaints"]?.objects ?? [])
        n.fills = flipped ? fills.map { $0.flipped(horizontally: false) } : fills
        let borders = self.borders(e, open: false)
        n.borders = flipped ? borders.map { $0.flipped(horizontally: false) } : borders
    }

    /// The fills a layer's paints come to, one over another as Figma lays them, the first lowest.
    /// Bezzle holds a picture only in the first, so what lies under the top picture is left out.
    private mutating func fills(_ paints: [Object]) -> [Fill] {
        var fills = shown(paints).compactMap { fill(paint: $0) }
        if let top = fills.lastIndex(where: { $0.image != nil }), top > 0 {
            fills.removeFirst(top)
            report.note("Fills under a picture, left out")
        }
        return fills
    }

    /// The one fill an artboard's paints come to, as an artboard has one: none, the only one, or
    /// solid colours over one another as the colour they make. Nil when they need a layer of
    /// their own to be drawn, as several with a gradient or a picture among them do.
    private mutating func boardFill(_ paints: [Object]) -> Fill? {
        let shown = shown(paints)
        guard shown.count > 1 else { return shown.first.flatMap { fill(paint: $0) } ?? Fill(on: false, color: .white) }
        guard shown.allSatisfy({ $0["type"]?.string == "SOLID" && normal($0) }),
              let color = ImportText.composite(shown.map { solid($0) }) else { return nil }
        return Fill(on: true, color: color)
    }

    /// Whether a paint lies over those under it as it is, blended into none of them.
    private func normal(_ p: Object) -> Bool { p["blendMode"]?.string.map { ["NORMAL", "PASS_THROUGH"].contains($0) } ?? true }

    /// A solid paint's colour, as clear as the paint is.
    private func solid(_ p: Object) -> RGBA {
        var c = color(p["color"])
        c.a *= Double(num(p["opacity"], 1))
        return c
    }

    /// One of Figma's paints as a fill.
    private mutating func fill(paint p: Object) -> Fill? {
        if let mode = p["blendMode"]?.string, !["NORMAL", "PASS_THROUGH"].contains(mode) { report.note("Fills blended into those under them, drawn over them") }
        let opacity = Double(num(p["opacity"], 1))
        switch p["type"]?.string {
        case "SOLID":
            var c = color(p["color"])
            c.a *= opacity
            return Fill(on: true, color: c)
        case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
            return gradient(p, opacity: opacity)
        case "IMAGE":
            return picture(p, opacity: opacity)
        default:
            report.note("Kinds of fill Bezzle does not know")
            return nil
        }
    }

    /// A gradient is placed by a transform from the layer's box, 0 to 1 both ways, to where it
    /// runs from 0 to 1 across the middle, or spreads from the centre to the edge.
    private mutating func gradient(_ p: Object, opacity: Double) -> Fill? {
        let stops = (p["stops"]?.objects ?? []).map { s in
            var c = color(s["color"])
            c.a *= opacity
            return GradientStop(offset: Double(num(s["position"])), color: c)
        }
        guard let first = stops.first else { report.note("Gradients without colours"); return nil }
        let t = p["transform"]?.object
        let placing = CGAffineTransform(a: t?.num("m00", 1) ?? 1, b: t?.num("m10") ?? 0, c: t?.num("m01") ?? 0, d: t?.num("m11", 1) ?? 1,
                                        tx: t?.num("m02") ?? 0, ty: t?.num("m12") ?? 0)
        guard abs(placing.a * placing.d - placing.b * placing.c) > 1e-9 else { return Fill(on: true, color: first.color) }
        let back = placing.inverted()
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(back) }
        var gradient: Gradient
        switch p["type"]?.string {
        case "GRADIENT_LINEAR":
            gradient = Gradient(kind: .linear, stops: stops, start: at(0, 0.5), end: at(1, 0.5))
        default:
            if p["type"]?.string == "GRADIENT_ANGULAR" { report.note("Angular gradients, drawn as radial ones") }
            if p["type"]?.string == "GRADIENT_DIAMOND" { report.note("Diamond gradients, drawn as radial ones") }
            gradient = Gradient(kind: .radial, stops: stops, start: at(0.5, 0.5), end: at(1, 0.5), across: at(0.5, 1))
        }
        return Fill(on: true, color: first.color, gradient: gradient)
    }

    private mutating func picture(_ p: Object, opacity: Double) -> Fill? {
        let image = p["image"]?.object
        guard let hash = image?["hash"]?.data, !hash.isEmpty else { report.note("Pictures without a file"); return nil }
        let name = hash.map { String(format: "%02x", $0) }.joined()
        guard let stored = asset(name, blob: image?["dataBlob"]?.int) else {
            report.note("Pictures missing from the Figma file")
            return Fill(on: true, color: .shape)
        }
        let mode: ImageFill.Mode
        switch p["imageScaleMode"]?.string {
        case "FIT": mode = .fit
        case "STRETCH":
            // Figma's crop is a stretch with a transform that picks the part shown.
            mode = .stretch
            if let t = p["transform"]?.object, t.num("m00", 1) != 1 || t.num("m11", 1) != 1 || t.num("m02") != 0 || t.num("m12") != 0 {
                report.note("Cropped pictures, shown whole")
            }
        case "TILE":
            mode = .cover
            report.note("Tiled pictures, filling their layer once")
        default: mode = .cover
        }
        if num(p["rotation"]) != 0 { report.note("Turned pictures, shown upright") }
        if opacity < 1 { report.note("See-through pictures, shown solid") }
        if p["paintFilter"] != nil { report.note("Pictures with their colours adjusted, shown as they are") }
        let width = num(p["originalImageWidth"], stored.1.width), height = num(p["originalImageHeight"], stored.1.height)
        return Fill(on: true, color: .shape, image: ImageFill(asset: stored.0, mode: mode, size: CGSize(width: max(width, 1), height: max(height, 1))))
    }

    /// The file a picture has in the design, and its size: from the archive's `images` folder,
    /// or for older files, from among the message's blobs.
    private mutating func asset(_ hash: String, blob: Int?) -> (String, CGSize)? {
        if let known = found[hash] { return known }
        var result: (String, CGSize)?
        if let archive, let data = try? archive.read("images/\(hash)"), let kind = Importer.picture(data) {
            result = ("\(hash).\(kind.ext)", kind.size)
            pictures["\(hash).\(kind.ext)"] = "images/\(hash)"
        } else if let blob, blobs.indices.contains(blob), let kind = Importer.picture(blobs[blob]) {
            result = ("\(hash).\(kind.ext)", kind.size)
            held["\(hash).\(kind.ext)"] = blobs[blob]
        }
        found[hash] = .some(result)
        return result
    }

    /// A layer's borders, one for each of its strokes' paints, the first lowest, all of the
    /// layer's one weight, as Figma draws them.
    private mutating func borders(_ e: Object, open: Bool) -> [Border] {
        let shown = shown(e["strokePaints"]?.objects ?? [])
        guard e.num("strokeWeight", 1) > 0 else { return [] }
        return shown.map { border(e, paint: $0, open: open) }
    }

    private mutating func border(_ e: Object, paint p: Object, open: Bool) -> Border {
        let width = e.num("strokeWeight", 1), opacity = Double(num(p["opacity"], 1))
        var b = Border(on: true, color: RGBA.line, width: width)
        // A gradient or a picture paints the border as it paints a fill.
        switch p["type"]?.string {
        case "SOLID":
            b.color = color(p["color"])
            b.color.a *= opacity
        case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
            if let painted = gradient(p, opacity: opacity) {
                b.color = painted.color
                b.gradient = painted.gradient
            }
        default:
            if let painted = picture(p, opacity: opacity) {
                b.color = painted.color
                b.image = painted.image
            }
        }
        b.position = switch e["strokeAlign"]?.string {
        case "INSIDE": open ? .center : .inside
        case "OUTSIDE": open ? .center : .outside
        default: .center
        }
        let dash = (e["dashPattern"]?.array ?? []).map { num($0) }
        if let first = dash.first, first > 0 {
            b.dash = first
            b.gap = dash.count > 1 ? dash[1] : first
        }
        if e["borderStrokeWeightsIndependent"]?.bool == true { report.note("Borders of a different width on each side, drawn alike") }
        return b
    }

    private mutating func effects(_ n: inout Node, _ e: Object) {
        if let opacity = e["opacity"]?.number, opacity.isFinite { n.opacity = min(max(opacity, 0), 1) }
        if let mode = e["blendMode"]?.string, !["NORMAL", "PASS_THROUGH"].contains(mode) {
            // Figma writes them as COLOR_DODGE.
            let parts = mode.lowercased().split(separator: "_")
            let camel = parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
            if let blend = BlendMode(rawValue: camel) { n.blend = blend } else { report.note("Blend modes Bezzle does not know, drawn as normal") }
        }
        var shadows: [Shadow] = []
        for f in e["effects"]?.objects ?? [] where f["visible"]?.bool != false {
            switch f["type"]?.string {
            case "DROP_SHADOW", "INNER_SHADOW":
                let offset = f["offset"]?.object
                var s = Shadow(on: true, color: color(f["color"]), x: offset?.num("x") ?? 0, y: offset?.num("y") ?? 0, blur: num(f["radius"]))
                if f["type"]?.string == "INNER_SHADOW" { s.inset = true }
                if num(f["spread"]) != 0 { s.spread = num(f["spread"]) }
                shadows.append(s)
            // Figma's blur radius is twice the deviation Bezzle measures a blur by.
            case "FOREGROUND_BLUR", "BACKGROUND_BLUR":
                let behind = f["type"]?.string == "BACKGROUND_BLUR"
                var blur = Blur(radius: num(f["radius"]) / 2, background: behind, fillOpacity: behind ? 1 : 0)
                // One that grows runs from its start to its end in the layer's box, as Bezzle's does.
                if f["blurOpType"]?.string == "PROGRESSIVE" {
                    let a = f["startOffset"]?.object, b = f["endOffset"]?.object
                    blur.ramp = BlurRamp(start: CGPoint(x: a?.num("x", 0.5) ?? 0.5, y: a?.num("y") ?? 0), end: CGPoint(x: b?.num("x", 0.5) ?? 0.5, y: b?.num("y", 1) ?? 1))
                    if num(f["startRadius"]) > 0 { report.note("Blurs growing from some blur, grown from none") }
                }
                n.blur = blur
            default:
                report.note("Effects Bezzle does not know")
            }
        }
        if !shadows.isEmpty { n.shadows = shadows }
    }

    // MARK: Text

    /// A text layer. Figma gives each letter the number of a style, the text's own or one that
    /// changes some of it (`styleOverrideTable`); each run of letters comes across in its own.
    private mutating func text(_ e: Object, _ m: CGAffineTransform) -> Node? {
        let data = e["textData"]?.object
        var n = Node(kind: .text, frame: .zero)
        let words = data?["characters"]?.string ?? ""
        // Each style by its number: the text's own, with what the style changes laid over it.
        // Figma counts letters as Unicode does; those past the end of the list are in the text's own.
        let ids = (data?["characterStyleIDs"]?.array ?? []).compactMap(\.int)
        var styles: [Int: Object] = [0: e]
        for o in data?["styleOverrideTable"]?.objects ?? [] {
            if let id = o["styleID"]?.int, id != 0 { styles[id] = e.merged(with: o, except: Self.identity) }
        }
        var counts: [Int: Int] = [:]
        for id in ids { counts[id, default: 0] += 1 }
        let rest = words.unicodeScalars.count - ids.count
        if rest > 0 || counts.isEmpty { counts[0, default: 0] += max(rest, 0) }
        // What only the whole layer can have comes from the style most of its letters are in.
        let main = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
        let s = styles[main] ?? e
        let used = counts.keys.sorted()
        // Each run of letters has its own font, size, colour and lines; how far apart the lines
        // lie, and the font's features, are the whole text's. Its letter case may differ by run.
        let typesets = used.map { Self.typeset(styles[$0] ?? e) }
        if Set(typesets.map(\.spacing)).count > 1 { report.note("Texts with several line or paragraph spacings, spaced as their main part") }
        if Set(typesets.map(\.font)).count > 1 { report.note("Texts with font features or axes in part of them, set as their main part") }

        // The colour of each style's letters. A text shows none only when none of its styles has a
        // paint; otherwise letters without one are clear.
        let painted = used.contains { ink(shown(styles[$0]?["fillPaints"]?.objects ?? [])) != nil }
        n.fill.on = painted
        let unpainted = painted ? RGBA(r: 0, g: 0, b: 0, a: 0) : n.fill.color
        var looks: [Int: Letters] = [:], cases: [Int: LetterCase] = [:]
        var gradientInk = false, pictureInk = false, blendedInk = false
        // A gradient or a picture alone paints the letters of the text's own colour, those of its
        // main style; letters of another style are in a colour of their own.
        var own: Fill?
        let mainShown = shown(s["fillPaints"]?.objects ?? [])
        if mainShown.count == 1, let p = mainShown.first, let paint = ink(mainShown), paint.gradient || paint.picture {
            let opacity = Double(num(p["opacity"], 1))
            own = paint.gradient ? gradient(p, opacity: opacity) : picture(p, opacity: opacity)
        }
        for id in used {
            let style = styles[id] ?? e
            let paint = ink(shown(style["fillPaints"]?.objects ?? []))
            // Letters painted as the main style's are painted with it.
            let painted = own != nil && paint?.color == own?.color
            if !painted {
                gradientInk = gradientInk || paint?.gradient == true
                pictureInk = pictureInk || paint?.picture == true
            }
            blendedInk = blendedInk || paint?.blended == true
            looks[id] = letters(style, ink: painted ? own?.color ?? unpainted : paint?.color ?? unpainted)
            cases[id] = Self.letterCase(style)
        }
        if blendedInk { report.note("Fills blended into those under them, drawn over them") }
        if gradientInk { report.note("Texts filled with a gradient, in its first colour") }
        if pictureInk { report.note("Texts filled with a picture, in a plain colour") }

        // Runs of letters in one style and one paragraph, each paragraph in its list, if any.
        let lists: [TextList?] = (data?["lines"]?.objects ?? []).map {
            switch $0["lineType"]?.string {
            case "ORDERED_LIST": .number
            case "UNORDERED_LIST": .bullet
            default: nil
            }
        }
        var runs: [(text: String, letters: Letters)] = [], runCases: [LetterCase?] = []
        var piece = String.UnicodeScalarView(), pieceID = 0, pieceList: TextList?, paragraph = 0
        func close() {
            guard !piece.isEmpty else { return }
            var l = looks[pieceID] ?? looks[main] ?? TextLook.plain.resolved(over: TextStyle(), color: n.fill.color)
            l.list = pieceList
            runs.append((String(piece), l))
            runCases.append(looks[pieceID] != nil ? cases[pieceID] : cases[main])
            piece = String.UnicodeScalarView()
        }
        for (i, c) in words.unicodeScalars.enumerated() {
            let id = i < ids.count ? ids[i] : 0, list = paragraph < lists.count ? lists[paragraph] : nil
            if id != pieceID || list != pieceList { close() }
            pieceID = id
            pieceList = list
            piece.append(c)
            if c == "\n" { paragraph += 1 }
        }
        close()

        var ts = TextStyle()
        let fontSize = num(s["fontSize"], 12) > 0 ? num(s["fontSize"], 12) : 12
        if let height = s["lineHeight"]?.object {
            let v = height.num("value")
            switch height["units"]?.string {
            case "PIXELS": ts.lineSpacing = v
            case "RAW": ts.lineSpacing = (fontSize * v * 10).rounded() / 10
            // A hundred per cent is the font's own spacing.
            default: if abs(v - 100) > 0.01 { ts.lineSpacing = (fontSize * v / 10).rounded() / 10 }
            }
        }
        if s.num("paragraphSpacing") > 0 { ts.paragraphSpacing = s.num("paragraphSpacing") }
        ts.align = switch s["textAlignHorizontal"]?.string {
        case "CENTER": .center
        case "RIGHT": .right
        case "JUSTIFIED": .justify
        default: .left
        }
        let cased = ImportText.cased(runs, runCases, report: &report)
        ts.letterCase = cased.letterCase
        ts.features = Self.features(s)
        ts.axes = Self.axes(s)
        if !shown(s["strokePaints"]?.objects ?? []).isEmpty, s.num("strokeWeight", 1) > 0 { report.note("Texts with a border, shown without it") }

        let size = self.size(e)
        ts.sizing = switch s["textAutoResize"]?.string {
        case "WIDTH_AND_HEIGHT": .autoWidth
        case "HEIGHT": .autoHeight
        default: .fixed
        }
        // Where the lines lie in a box of fixed size; in any other, the box fits around them.
        if ts.sizing == .fixed {
            ts.vertical = switch s["textAlignVertical"]?.string {
            case "CENTER": .middle
            case "BOTTOM": .bottom
            default: nil
            }
        }
        n.style = ts
        n.setImportedRuns(cased.runs)
        if let own {
            if n.fill.color == looks[main]?.color {
                n.fill.gradient = own.gradient
                n.fill.image = own.image
            } else if own.gradient != nil {
                report.note("Texts filled with a gradient, in its first colour")
            } else {
                report.note("Texts filled with a picture, in a plain colour")
            }
        }
        n.frame = CGRect(origin: .zero, size: size)
        n.refit()
        // Where Figma put the first baseline, measured from the top of the text wherever in its box
        // the lines lie, as `TextLayout.firstBaseline` measures it.
        let baseline = (data?["baselines"]?.objects.first?["position"]?.object).map { $0.num("y") } ?? TextLayout.firstBaseline(n)
        var x: CGFloat = 0
        if ts.sizing == .autoWidth {
            switch ts.align {
            case .center: x = (size.width - n.frame.width) / 2
            case .right: x = size.width - n.frame.width
            case .left, .justify: x = 0
            }
        }
        let local = CGRect(x: x, y: baseline - TextLayout.firstBaseline(n), width: n.frame.width, height: n.frame.height)
        guard let placed = ImportGeometry.place(local, m) else {
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

    /// How letters in Figma's style `s` look, `ink` their colour.
    private mutating func letters(_ s: Object, ink: RGBA) -> Letters {
        let font = s["fontName"]?.object
        let (family, face) = fonts.resolve(postscript: font?["postscript"]?.string, family: font?["family"]?.string, face: font?["style"]?.string, report: &report)
        let size = num(s["fontSize"], 12) > 0 ? num(s["fontSize"], 12) : 12
        var tracking: CGFloat = 0
        if let spacing = s["letterSpacing"]?.object {
            // Bezzle counts letter spacing in thousandths of the size.
            let v = spacing.num("value")
            tracking = spacing["units"]?.string == "PIXELS" ? v / size * 1000 : v * 10
        }
        let decoration = s["textDecoration"]?.string
        return Letters(family: family, face: face, size: size, color: ink, underline: decoration == "UNDERLINE",
                       strikethrough: decoration == "STRIKETHROUGH", tracking: tracking, list: nil)
    }

    /// The colour letters with these paints come to: solid ones over one another as they lie,
    /// the first lowest, a gradient in its first colour and a picture in grey; nil when none
    /// shows. Also says whether a gradient, a picture or a blend shows in it, so that the colour
    /// is only close to what Figma draws.
    private func ink(_ shown: [Object]) -> (color: RGBA, gradient: Bool, picture: Bool, blended: Bool)? {
        // What an opaque solid paint covers does not show.
        let from = shown.lastIndex { p in p["type"]?.string == "SOLID" && normal(p) && solid(p).a >= 0.999 } ?? 0
        let showing = shown[from...]
        let colors = showing.map { p -> RGBA in
            switch p["type"]?.string {
            case "SOLID": return solid(p)
            case "IMAGE": return .shape
            default:
                var c = (p["stops"]?.objects.first).map { color($0["color"]) } ?? .black
                c.a *= Double(num(p["opacity"], 1))
                return c
            }
        }
        guard let color = ImportText.composite(colors) else { return nil }
        return (color, showing.contains { $0["type"]?.string?.hasPrefix("GRADIENT") == true },
                showing.contains { $0["type"]?.string == "IMAGE" }, showing.contains { !normal($0) })
    }

    /// The letter case a style sets its letters in.
    private static func letterCase(_ s: Object) -> LetterCase? {
        switch s["textCase"]?.string {
        case "UPPER": .upper
        case "LOWER": .lower
        case "TITLE": .title
        case "SMALL_CAPS", "SMALL_CAPS_FORCED": .smallCaps
        default: nil
        }
    }

    /// What of a style Bezzle holds for a whole text only, to tell whether runs differ in it: how
    /// far apart lines and paragraphs lie, and the font's features and axes.
    private struct Typeset: Hashable {
        var spacing: String
        var font: String
    }

    private static func typeset(_ s: Object) -> Typeset {
        let height = s["lineHeight"]?.object
        let spacing = (height.map { "\($0.num("value"))|\($0["units"]?.string ?? "")" } ?? "") + "|\(s.num("paragraphSpacing"))"
        let features = (features(s) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let axes = (axes(s) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return Typeset(spacing: spacing, font: (features + ["|"] + axes).joined(separator: ","))
    }

    /// The OpenType features a style turns on or off, by their tags: those Figma names itself,
    /// and those it sets as the CSS font-variant properties are.
    private static func features(_ s: Object) -> [String: Int]? {
        var f: [String: Int] = [:]
        if s["fontVariantCommonLigatures"]?.bool == false { f["liga"] = 0; f["clig"] = 0 }
        if s["fontVariantContextualLigatures"]?.bool == false { f["calt"] = 0 }
        if s["fontVariantDiscretionaryLigatures"]?.bool == true { f["dlig"] = 1 }
        if s["fontVariantHistoricalLigatures"]?.bool == true { f["hlig"] = 1 }
        if s["fontVariantOrdinal"]?.bool == true { f["ordn"] = 1 }
        if s["fontVariantSlashedZero"]?.bool == true { f["zero"] = 1 }
        let variants: [String: [String: [String]]] = [
            "fontVariantNumericFigure": ["LINING": ["lnum"], "OLDSTYLE": ["onum"]],
            "fontVariantNumericSpacing": ["PROPORTIONAL": ["pnum"], "TABULAR": ["tnum"]],
            "fontVariantNumericFraction": ["DIAGONAL": ["frac"], "STACKED": ["afrc"]],
            "fontVariantCaps": ["SMALL": ["smcp"], "ALL_SMALL": ["smcp", "c2sc"], "PETITE": ["pcap"], "ALL_PETITE": ["pcap", "c2pc"],
                                "UNICASE": ["unic"], "TITLING": ["titl"]],
            "fontVariantPosition": ["SUB": ["subs"], "SUPER": ["sups"]],
        ]
        for (field, values) in variants {
            for tag in s[field]?.string.flatMap({ values[$0] }) ?? [] { f[tag] = 1 }
        }
        // Forced small capitals are capitals too.
        if s["textCase"]?.string == "SMALL_CAPS_FORCED" { f["c2sc"] = 1 }
        // Figma names features by their tags in capitals.
        for t in s["toggledOnOTFeatures"]?.array ?? [] { if let tag = t.string?.lowercased() { f[tag] = 1 } }
        for t in s["toggledOffOTFeatures"]?.array ?? [] { if let tag = t.string?.lowercased() { f[tag] = 0 } }
        return f.isEmpty ? nil : f
    }

    /// Where a variable font is set along its axes, by their tags. Figma keeps a tag as the number
    /// fonts do.
    private static func axes(_ s: Object) -> [String: Double]? {
        var a: [String: Double] = [:]
        for v in s["fontVariations"]?.objects ?? [] {
            guard let code = v["axisTag"]?.int, let value = v["value"]?.number, value.isFinite else { continue }
            a[Fonts.tag(UInt32(truncatingIfNeeded: code))] = value
        }
        return a.isEmpty ? nil : a
    }
}
