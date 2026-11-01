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
        var imported = try read(url)
        let target = Library.shared.freeURL(named: url.deletingPathExtension().lastPathComponent, in: folder)
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
    mutating func setImportedRuns(_ runs: [(text: String, letters: Letters)]) {
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
        self.style = style
        setRuns(runs.map { TextSpan(text: $0.text, look: TextLook($0.letters, over: style, color: fill.color)) })
    }
}
