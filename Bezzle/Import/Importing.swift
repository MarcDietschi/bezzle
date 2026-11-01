import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What an import brought across, and what it could only come close to, so it is clear what to
/// look at.
struct ImportReport {
    /// The app the design was made in, as it calls itself: "Figma".
    var source: String
    var artboards = 0
    var layers = 0
    /// What was approximated, and how often.
    var notes: [String: Int] = [:]
    var missingFonts: Set<String> = []

    /// Notes what was approximated, in the user's language, as the report shows it.
    mutating func note(_ what: LocalizedStringResource) { notes[String(localized: what), default: 0] += 1 }

    /// The notes as sentences, the most frequent first.
    var lines: [String] {
        var out = notes.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }
        if !missingFonts.isEmpty { out.append("Fonts not on this Mac: " + missingFonts.sorted().joined(separator: ", ")) }
        return out
    }
}

/// A design read out of another app's file, its pictures still in the file.
struct Imported {
    var document: BezzleDocument
    var report: ImportReport
    /// The file, when it is a ZIP archive, as most are.
    let archive: ZipArchive?
    /// The pictures the design uses: each one's file name in the design, and where it is in the archive.
    var pictures: [String: String] = [:]
    /// Pictures the file keeps other than in an archive: each one's file name in the design, and the picture.
    var held: [String: Data] = [:]
}

/// Designs made in Adobe XD, Figma and Sketch. Each file is brought in as a new design in the
/// library, and the file itself is left as it is.
enum Importer {
    nonisolated static let fileExtensions = [XDImporter.fileExtension, FigmaImporter.fileExtension, SketchImporter.fileExtension]

    nonisolated static func imports(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    /// The app a file to bring in was made in.
    nonisolated static func source(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case XDImporter.fileExtension: "Adobe XD"
        case FigmaImporter.fileExtension: "Figma"
        case SketchImporter.fileExtension: "Sketch"
        default: nil
        }
    }

    /// The design a file makes, without writing anything, for checking.
    static func read(_ url: URL) throws -> Imported {
        switch url.pathExtension.lowercased() {
        case FigmaImporter.fileExtension: try FigmaImporter.read(url)
        case SketchImporter.fileExtension: try SketchImporter.read(url)
        default: try XDImporter.read(url)
        }
    }

    /// Makes a new design out of the file, in `folder`, and says where it is.
    static func importFile(_ url: URL, into folder: URL) throws -> (URL, ImportReport) {
        try write(read(url), named: url.deletingPathExtension().lastPathComponent, into: folder)
    }

    /// Writes a design brought in from elsewhere as a new design called `name` in `folder`, its
    /// pictures with it, and says where it is.
    static func write(_ imported: Imported, named name: String, into folder: URL) throws -> (URL, ImportReport) {
        var imported = imported
        let target = Library.shared.freeURL(named: name, in: folder)
        let images = target.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for (asset, source) in imported.pictures {
                do {
                    guard let archive = imported.archive else { throw ZipArchive.Failure.missing(source) }
                    try archive.read(source).write(to: images.appendingPathComponent(asset))
                } catch {
                    imported.report.note("Pictures missing from the \(imported.report.source) file")
                }
            }
            for (asset, data) in imported.held { try data.write(to: images.appendingPathComponent(asset)) }
            try DesignFile.write(imported.document, to: target)
        } catch {
            // Only what this import made itself is taken away again.
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return (target, imported.report)
    }

    /// What kind of picture `data` is, as a file extension, and its size in pixels.
    static func picture(_ data: Data) -> (ext: String, size: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let ext = UTType(type as String)?.preferredFilenameExtension ?? "png"
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (ext == "jpeg" ? "jpg" : ext, CGSize(width: width, height: height))
    }

    /// Bezzle has one canvas, so the pages of a design are laid out on it one under the other:
    /// the first where it is, each of the others below the one before, lined up on its left.
    static func stack(_ pages: [[Node]]) -> [Node] {
        var out: [Node] = []
        var left: CGFloat?, below: CGFloat = 0
        for nodes in pages where !nodes.isEmpty {
            var page = BezzleDocument()
            page.nodes = nodes
            page.fitGroups()
            guard let first = page.nodes.first else { continue }
            let bounds = page.contentBounds ?? page.nodes.map { Geometry.bounds(of: $0) }.reduce(first.frame) { $0.union($1) }
            var moved = page.nodes
            if let left {
                let dx = left - bounds.minX, dy = below + pageGap - bounds.minY
                for i in moved.indices { moved[i].frame = moved[i].frame.offsetBy(dx: dx, dy: dy) }
                below = bounds.maxY + dy
            } else {
                left = bounds.minX
                below = bounds.maxY
            }
            out += moved
        }
        return out
    }

    private static let pageGap: CGFloat = 800
}

/// Where a layer lands in Bezzle: its frame in the parent, how far it is turned, and what was
/// left of its transform after that.
struct Placement {
    var frame: CGRect
    var rotation: Double
    var flipped: Bool
    var scale: CGSize
}

/// Layers in other apps are boxes taken to their parent by a transform, which Bezzle keeps as a
/// frame and a turn.
enum ImportGeometry {
    /// Takes a box in a layer's own coordinates to a frame and a turn in the parent. Slanted
    /// shapes cannot be a frame and a turn, so they become outlines instead.
    static func place(_ box: CGRect, _ m: CGAffineTransform) -> Placement? {
        let theta = atan2(m.b, m.a)
        let rest = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0).concatenating(CGAffineTransform(rotationAngle: theta).inverted())
        guard abs(rest.c) < 0.001 * max(abs(rest.a), abs(rest.d), 1) else { return nil }
        let size = CGSize(width: box.width * abs(rest.a), height: box.height * abs(rest.d))
        let center = CGPoint(x: box.midX, y: box.midY).applying(m)
        return Placement(frame: CGRect(center: center, size: size), rotation: CanvasView.normalized(Double(theta) * 180 / .pi),
                         flipped: rest.d < 0, scale: CGSize(width: abs(rest.a), height: abs(rest.d)))
    }

    /// A path layer of an outline in a layer's own coordinates, kept turned as the layer is; any
    /// stretch, flip or slant is worked into the outline itself. Nil when the outline is empty.
    static func outline(_ data: String, _ m: CGAffineTransform) -> Node? {
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
        return n
    }

    static func isClosed(_ data: String) -> Bool { data.contains("Z") || data.contains("z") }
}

/// Finds the fonts a design asks for among those on this Mac, looking each up once.
struct FontMatch {
    private var known: [String: (String, String)] = [:]

    /// The family and face as Bezzle names them. The Mac's own San Francisco is the system font;
    /// a font that is not installed keeps its name, and is reported.
    mutating func resolve(postscript: String?, family: String?, face: String?, report: inout ImportReport) -> (String, String) {
        let key = "\(postscript ?? "")|\(family ?? "")|\(face ?? "")"
        if let found = known[key] { return found }
        var result: (String, String)
        if let family, family.hasPrefix("SF Pro") || family.hasPrefix(".SF") || family == "San Francisco" {
            let wanted = face ?? "Regular"
            result = (TextStyle.system, Fonts.faces(of: TextStyle.system).contains(wanted) ? wanted : "Regular")
        } else if let postscript, !postscript.isEmpty, let font = NSFont(name: postscript, size: 12), let found = font.familyName {
            let members = NSFontManager.shared.availableMembers(ofFontFamily: found) ?? []
            let named = members.first { $0.first as? String == postscript }.flatMap { $0.count > 1 ? $0[1] as? String : nil }
            result = (found, named ?? face ?? "Regular")
        } else if let family, NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            result = (family, face ?? "Regular")
        } else {
            let name = [family, face].compactMap { $0 }.joined(separator: " ")
            report.missingFonts.insert(name.isEmpty ? postscript ?? String(localized: "Unnamed") : name)
            result = (family ?? postscript ?? TextStyle.system, face ?? "Regular")
        }
        known[key] = result
        return result
    }
}

// MARK: - Styled letters, for every importer

nonisolated extension Node {
    /// Sets an imported text's words from runs whose letters are each described in full, as the
    /// apps designs come from keep them: the layer's own style and colour become those most of
    /// its letters have, and each run keeps only how it differs from them. The style's other
    /// parts, such as its alignment and line height, stay as they were set.
    ///
    /// With `painting`, a gradient or a picture, the letters in its colour are painted with it:
    /// the layer is filled with it, whatever colour most letters are in, and every other letter
    /// has a colour of its own (see `ImportText.apart`).
    mutating func setImportedRuns(_ runs: [(text: String, letters: Letters)], painting: Fill? = nil) {
        var style = self.style ?? TextStyle()
        func unlisted(_ l: Letters) -> Letters {
            var l = l
            l.list = nil
            return l
        }
        var counts: [Letters: Int] = [:]
        for run in runs { counts[unlisted(run.letters), default: 0] += run.text.count }
        let most = counts.values.max() ?? 0
        // The first of those most letters have, so ties go the same way every time.
        if let main = runs.lazy.map({ unlisted($0.letters) }).first(where: { counts[$0] == most }) {
            style.family = main.family
            style.face = main.face
            style.size = main.size
            style.tracking = main.tracking
            style.underline = main.underline
            style.strikethrough = main.strikethrough ? true : nil
            fill.color = main.color
        }
        if let painting {
            fill.color = painting.color
            fill.gradient = painting.gradient
            fill.image = painting.image
        }
        self.style = style
        setRuns(runs.map { TextSpan(text: $0.text, look: TextLook($0.letters, over: style, color: fill.color)) })
    }
}

/// What other apps' texts have that every importer brings across alike.
enum ImportText {
    /// Runs of a text's words, each in the letter case it was set in. A text has one case of its
    /// own, so where its runs differ in it, each run's case is written into its letters and the
    /// text has none; small capitals are no letters of their own, so those runs are set as they
    /// are. Returns the runs and the text's case.
    static func cased(_ runs: [(text: String, letters: Letters)], _ cases: [LetterCase?],
                      report: inout ImportReport) -> (runs: [(text: String, letters: Letters)], letterCase: LetterCase?) {
        let used = Set(runs.indices.filter { !runs[$0].text.isEmpty }.map { $0 < cases.count ? cases[$0] : nil })
        guard used.count > 1 else { return (runs, used.first ?? nil) }
        if used.contains(.smallCaps) { report.note("Small capitals in part of a text, set in plain letters") }
        // Cased whole, so words are capitalised across runs as a text in one case is, unless that
        // changes how long the words are.
        let whole = runs.map(\.text).joined()
        var wholes: [LetterCase: NSString?] = [:]
        var out = runs, at = 0
        for i in runs.indices {
            let length = runs[i].text.utf16.count
            defer { at += length }
            guard i < cases.count, let c = cases[i], c != .smallCaps else { continue }
            if wholes[c] == nil {
                let set = c.apply(whole)
                wholes[c] = .some(set.utf16.count == whole.utf16.count ? set as NSString : nil)
            }
            if let set = wholes[c] ?? nil {
                out[i].text = set.substring(with: NSRange(location: at, length: length))
            } else {
                out[i].text = c.apply(runs[i].text)
            }
        }
        return (out, nil)
    }

    /// The colour paints lying one over another come to, the first lowest: what shows of each
    /// through those over it, as the apps lay colours over one another. Nil when there are none.
    static func composite(_ colors: [RGBA]) -> RGBA? {
        guard var out = colors.first else { return nil }
        for top in colors.dropFirst() {
            let a = top.a + out.a * (1 - top.a)
            guard a > 0 else {
                out = RGBA(r: top.r, g: top.g, b: top.b, a: 0)
                continue
            }
            func mix(_ t: Double, _ b: Double) -> Double { (t * top.a + b * out.a * (1 - top.a)) / a }
            out = RGBA(r: mix(top.r, out.r), g: mix(top.g, out.g), b: mix(top.b, out.b), a: a)
        }
        return out
    }

    /// The one fill a text's letters are painted with, from fills lying one over another, the
    /// first lowest, as a text has one: what an opaque colour or gradient covers does not show,
    /// nor what lies under a picture; solid colours come to the colour they make, and over or
    /// under a gradient, to that gradient with each of its colours as they make it there. Nil
    /// when more than one gradient or picture shows, or anything over a picture.
    static func painting(_ fills: [Fill], report: inout ImportReport) -> Fill? {
        func covers(_ f: Fill) -> Bool {
            guard f.image == nil else { return false }
            if let stops = f.gradient?.stops, !stops.isEmpty { return stops.allSatisfy { $0.color.a >= 0.999 } }
            return f.color.a >= 0.999
        }
        guard !fills.isEmpty else { return nil }
        let showing = Array(fills[(fills.lastIndex(where: covers) ?? 0)...])
        if let top = showing.lastIndex(where: { $0.image != nil }) {
            guard top == showing.count - 1 else { return nil }
            if top > 0 { report.note("Fills under a picture, left out") }
            return showing[top]
        }
        let painters = showing.indices.filter { showing[$0].paints }
        guard painters.count <= 1 else { return nil }
        guard let at = painters.first else { return composite(showing.map(\.color)).map { Fill(on: true, color: $0) } }
        var paint = showing[at]
        guard showing.count > 1, var gradient = paint.gradient else { return paint }
        let under = showing[..<at].map(\.color), over = showing[(at + 1)...].map(\.color)
        for i in gradient.stops.indices {
            gradient.stops[i].color = composite(under + [gradient.stops[i].color] + over) ?? gradient.stops[i].color
        }
        paint.gradient = gradient
        paint.color = gradient.stops[0].color
        return paint
    }

    /// The colour letters a gradient or a picture paints are in: `color`, or one a shade of blue
    /// off it that no one sees, so that they are told from letters of a colour of their own,
    /// `others`. A text's letters in its own colour are painted, and that colour does not show.
    static func apart(_ color: RGBA, from others: [RGBA]) -> RGBA {
        var c = color, k = 0
        while others.contains(c) {
            k += 1
            let b = color.b + Double((k + 1) / 2) / 255 * (k.isMultiple(of: 2) ? -1 : 1)
            c = RGBA(r: color.r, g: color.g, b: min(max(b, 0), 1), a: color.a)
        }
        return c
    }
}

// MARK: - Masks, for every importer

/// Masks brought in from other apps as Bezzle's own (see `Mask`): a group whose first layer, a
/// shape, holds the rest, cut off at its outline. Figma and XD cut by a mask without drawing it,
/// so its shape is clear there; Sketch draws it under what it holds.
enum ImportMask {
    /// The shape a mask cuts with, as a layer that can hold others: the layer itself when it is a
    /// shape, and for a group one outline round everything in it, clear. `drawn` keeps how the
    /// shape looks. Nil for a layer with no outline of its own to cut by, such as a text.
    static func holder(_ layer: Node, drawn: Bool) -> Node? {
        var h: Node
        switch layer.kind {
        case .rectangle, .ellipse, .path:
            h = layer
            if !drawn { clear(&h) }
        case .group:
            guard let outline = outline(of: layer), var n = ImportGeometry.outline(PathData.string(outline), .identity) else { return nil }
            n.name = layer.name
            n.locked = layer.locked
            clear(&n)
            h = n
        default:
            return nil
        }
        h.hidden = false
        h.transform3D = nil
        return h
    }

    /// A shape that shows nothing of itself, only where it cuts.
    static func clear(_ n: inout Node) {
        n.fill = Fill(on: false, color: .shape)
        n.moreFills = nil
        n.borders = []
        n.shadows = []
        n.blur = nil
        n.blend = nil
        n.opacity = 1
    }

    /// A mask of `holder` holding `held`; nil when it holds nothing, as such a mask cuts nothing.
    static func mask(_ holder: Node, holding held: [Node], name: String) -> Node? {
        guard !held.isEmpty else { return nil }
        var g = Node(kind: .group, name: name, frame: .zero)
        g.clipsToFirst = true
        g.children = [holder] + held
        return g
    }

    /// Whether any of `held` shows past the outline of `edge`, a shape in the same coordinates,
    /// with its borders and shadows, so that cutting them off there changes what is seen: past
    /// its box, or into a rounded corner. Groups not yet fitted round what they hold are looked
    /// into. Anything but an upright rectangle is taken to cut something off.
    static func reaches(_ held: [Node], outside edge: Node) -> Bool {
        guard edge.kind == .rectangle, edge.rotation == 0 else { return true }
        let box = edge.frame, inside = box.insetBy(dx: -0.5, dy: -0.5), r = edge.radii
        let corners = [CGRect(x: box.minX, y: box.minY, width: r[0], height: r[0]),
                       CGRect(x: box.maxX - r[1], y: box.minY, width: r[1], height: r[1]),
                       CGRect(x: box.maxX - r[2], y: box.maxY - r[2], width: r[2], height: r[2]),
                       CGRect(x: box.minX, y: box.maxY - r[3], width: r[3], height: r[3])].filter { $0.width > 0.5 }
        return held.contains { n in
            guard let reach = reach(of: n) else { return false }
            return !inside.contains(reach) || corners.contains { $0.intersects(reach) }
        }
    }

    private static func reach(of n: Node) -> CGRect? {
        guard !n.hidden else { return nil }
        var box: CGRect?
        if n.isGroup {
            if let cut = n.cutBy {
                box = Geometry.bounds(of: cut)
            } else {
                box = n.children.compactMap(reach).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
            }
            box = box?.offsetBy(dx: n.frame.minX, dy: n.frame.minY)
        } else {
            box = Geometry.bounds(of: n)
            let border = n.borders.filter { $0.position != .inside || n.kind == .line }.map(\.width).max() ?? 0
            box = box?.insetBy(dx: -border, dy: -border)
        }
        let cast = n.outerShadows.map { s in s.blur * 1.5 + max(abs(s.x), abs(s.y)) + max(s.spread ?? 0, 0) }.max() ?? 0
        let blurred = n.blur.map { $0.on && !$0.background ? $0.radius * 3 : 0 } ?? 0
        let out = cast + blurred
        return out > 0 ? box?.insetBy(dx: -out, dy: -out) : box
    }

    /// The outline round everything a layer shows, in its parent's coordinates; a mask's, its
    /// shape's, as that is all of it that shows.
    static func outline(of layer: Node) -> CGPath? {
        guard !layer.hidden else { return nil }
        guard layer.isGroup else { return layer.kind == .line ? nil : Renderer.placedOutline(of: layer) }
        let parts: [CGPath]
        if let cut = layer.cutBy {
            parts = [Renderer.placedOutline(of: cut)]
        } else {
            parts = layer.children.compactMap(outline(of:))
        }
        guard var whole = parts.first else { return nil }
        for p in parts.dropFirst() { whole = whole.union(p) }
        var t = CGAffineTransform(translationX: layer.frame.minX, y: layer.frame.minY)
        return whole.copy(using: &t)
    }
}

// MARK: - Layout grids and guides, for every importer

/// The columns, rows and guides artboards in other apps are laid out on, as Bezzle's.
enum ImportLayout {
    /// Bands `size` long and `gutter` apart, the first `start` in, along a side `length` long, as
    /// Bezzle's columns or rows, which lie between equal margins and stretch with the artboard.
    /// They lie where they did when they were in the middle; otherwise they keep their size and
    /// go to the middle.
    static func track(count: Int, size: CGFloat, gutter: CGFloat, start: CGFloat, along length: CGFloat,
                      report: inout ImportReport) -> LayoutGrid.Track? {
        guard count > 0, size.isFinite, gutter.isFinite, start.isFinite, length > 0 else { return nil }
        let gutter = max(gutter, 0)
        if count > LayoutGrid.Track.counts.upperBound {
            report.note("Layout grids of more than 48 columns or rows, kept to 48")
            return LayoutGrid.Track(count: LayoutGrid.Track.counts.upperBound, gutter: gutter, margin: max(start, 0))
        }
        let margin = (length - CGFloat(count) * size - CGFloat(count - 1) * gutter) / 2
        if abs(margin - start) > 0.5 { report.note("Layout grids with uneven margins, centred") }
        return LayoutGrid.Track(count: count, gutter: gutter, margin: max(margin, 0))
    }

    /// Bands stretching between a margin of `start` at one end and `end` at the other, as Bezzle's,
    /// which have one margin for both: halfway between the two when they differ.
    static func stretched(count: Int, gutter: CGFloat, start: CGFloat, end: CGFloat, report: inout ImportReport) -> LayoutGrid.Track? {
        guard count > 0, gutter.isFinite, start.isFinite, end.isFinite else { return nil }
        if abs(start - end) > 0.5 { report.note("Layout grids with uneven margins, centred") }
        if count > LayoutGrid.Track.counts.upperBound { report.note("Layout grids of more than 48 columns or rows, kept to 48") }
        return LayoutGrid.Track(count: min(count, LayoutGrid.Track.counts.upperBound), gutter: max(gutter, 0), margin: max((start + end) / 2, 0))
    }

    /// Guides at these places across an artboard of `size` (running down it) and down it (running
    /// across it), each once; those off the artboard have nothing to line up and are left out.
    static func guides(across xs: [CGFloat], down ys: [CGFloat], in size: CGSize) -> [String: Guideline]? {
        var out: [String: Guideline] = [:]
        var seen = Set<Guideline>()
        for (positions, vertical) in [(xs, true), (ys, false)] {
            let length = vertical ? size.width : size.height
            for p in positions where p.isFinite && p >= 0 && p <= length {
                let guide = Guideline.at(p, vertical: vertical, in: size)
                guard seen.insert(guide).inserted else { continue }
                out[Guideline.key(besides: out.keys)] = guide
            }
        }
        return out.isEmpty ? nil : out
    }
}
