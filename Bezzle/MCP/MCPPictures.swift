import AppKit
import UniformTypeIdentifiers

/// Pictures of a design: for the assistant to look at what it made, and exported as files.
extension MCPTools {
    func render(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        if args["time"] != nil || args["frames"] != nil { return try renderFilm(args, store) }
        let doc = store.doc
        // As large as a model looks at a picture whole.
        let longest = CGFloat(min(max(try args.number("maxSize") ?? 1568, 64), 4096))
        let wanted = CGFloat(min(max(try args.number("scale") ?? 2, 0.05), 4))
        let image: CGImage?
        let what: String
        var scale: CGFloat
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: doc)
            guard let node = doc.node(id) else { throw MCPError("That layer is gone.") }
            if node.isArtboard {
                scale = min(wanted, longest / max(node.frame.width, node.frame.height, 1))
                image = Renderer.image(of: node, scale: scale, assets: store.assets)
            } else {
                guard let item = ExportItem(layer: id, in: doc) else { throw MCPError("\(node.name) is hidden, so there is nothing to draw.") }
                let reach = Renderer.reach(of: node, eye: doc.eye(forParentOf: id))
                scale = min(wanted, longest / max(reach.width, reach.height, 1))
                image = item.picture(scale: scale, opaque: false, assets: store.assets)?.image
            }
            what = node.name
        } else {
            guard let bounds = doc.contentBounds, bounds.width > 0 || bounds.height > 0 else { throw MCPError("\(store.name) is empty: there is nothing to draw.") }
            // The thumbnail is drawn at twice its size in points.
            scale = min(wanted, longest / max(bounds.width, bounds.height, 1))
            image = Renderer.thumbnail(of: doc, size: CGSize(width: bounds.width * scale / 2, height: bounds.height * scale / 2), assets: store.assets)
            what = "the whole of \(store.name)"
            scale *= 0.86
        }
        guard let image, let png = Self.png(image) else { throw MCPError("The picture could not be drawn.") }
        let note: JSONValue = [
            "drawn": .string(what),
            "pixels": .string("\(image.width)×\(image.height)"),
            "pixelsPerPoint": .number((scale * 1000).rounded() / 1000),
        ]
        return [.png(png), .text(note.text)]
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    func export(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc
        if let word = try args.string("format")?.lowercased(), word == "mp4" || word == "movie" { return try await exportMovies(args, store) }
        let format = try Self.format(try args.string("format") ?? "png")
        // Whole numbers, as the Export panel offers them, so the files are named "@2x" and so on.
        let scale = CGFloat(min(max((try args.number("scale") ?? 1).rounded(), 1), 4))
        let quality = min(max(try args.number("quality") ?? Exporter.defaultQuality, 0), 1)
        let marked = try args.bool("marked") == true
        let replacing = try args.bool("replace") == true
        var ids: [UUID] = []
        if args["layers"] != nil { ids = try Self.layers(args, in: store) } else if !marked { ids = store.selection }
        var warnings: [String] = []
        var items: [ExportItem] = []
        for id in ids {
            guard let n = doc.node(id) else { continue }
            if marked && n.exports?.isEmpty != false {
                warnings.append("\(n.name) is not marked for export, so it was left out. Give it exports first.")
            } else if n.isArtboard {
                items += ExportItem.items(for: n)
            } else if let item = ExportItem(layer: id, in: doc) {
                items.append(item)
            } else {
                warnings.append("\(n.name) is hidden, so it was left out.")
            }
        }
        // With nothing named or selected, every artboard: a carousel a picture a slide; or, as
        // marked, everything marked.
        if ids.isEmpty { items = marked ? ExportItem.marked(in: doc, seen: store.seenDoc) : doc.artboards.flatMap(ExportItem.items(for:)) }
        guard !items.isEmpty else {
            throw MCPError(marked ? "There is nothing to export: nothing in \(store.name) is marked for export. Give layers exports with update_layers."
                                  : "There is nothing to export: \(store.name) has no artboards.")
        }

        let (folder, hint) = try Self.exportFolder(args)
        let files = marked ? Exporter.files(presetsOf: items) : Exporter.files(items, format: format, scale: scale, name: store.name)
        let assets = store.assets, target = folder
        // Beside the canvas, which goes on drawing meanwhile.
        let written = await Task.detached(priority: .userInitiated) { Exporter.write(files, quality: quality, to: target, replacing: replacing, assets: assets) }.value
        if written.count < files.count {
            warnings.append("\(files.count - written.count) of the \(files.count) files could not be made\(files.contains { $0.format == .webp } ? " (a webp is at most 16383 pixels a side)" : "").")
        }
        guard !written.isEmpty else { throw MCPError("Nothing could be written to \(folder.path).\(hint)") }
        return [.text(JSONValue.compact([
            ("files", .array(written.map { .string($0.path) })),
            ("warnings", .array(warnings.map { .string($0) })),
        ]).text)]
    }

    /// Where exported files go, made when it is not there, and what to say when it cannot be.
    private static func exportFolder(_ args: Arguments) throws -> (URL, String) {
        var folder: URL
        if let path = try args.string("folder") {
            folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else if let last = UserDefaults.standard.string(forKey: "exportFolder"), FileManager.default.isWritableFile(atPath: last) {
            folder = URL(fileURLWithPath: last, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        // In the sandbox, ~ is Bezzle's own folder and Downloads a link from it; the files are
        // named by where they really are.
        folder = folder.resolvingSymlinksInPath()
        // Sandboxed, as released, Bezzle may only write where the user has let it.
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let hint = sandboxed ? " Bezzle can write to Downloads, and to folders once chosen in its Export panel." : ""
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw MCPError("\(folder.path) could not be made: \(error.localizedDescription)\(hint)")
        }
        return (folder, hint)
    }

    // MARK: Films

    /// The artboards a film is wanted of: those named, or the artboards of layers named; the
    /// selection's, or the one in sight; or, for `all`, every artboard with a film.
    private func filmBoards(_ args: Arguments, _ store: DocumentStore, all: Bool) throws -> [Node] {
        let doc = store.doc
        var boards: [Node] = []
        var refs = try args.strings("layers") ?? []
        if let one = try args.string("layer") { refs.append(one) }
        for ref in refs {
            let id = try Self.layer(ref, in: doc)
            guard let board = doc.node(id)?.isArtboard == true ? doc.node(id) : doc.artboard(of: id) else {
                throw MCPError("\(doc.node(id)?.name ?? ref) is not on an artboard, so it is in no film.")
            }
            if !boards.contains(where: { $0.id == board.id }) { boards.append(board) }
        }
        if boards.isEmpty, let board = store.focusedArtboard, !all || Self.moves(board) { boards = [board] }
        if boards.isEmpty, all { boards = doc.artboards.filter(Self.moves) }
        guard !boards.isEmpty else { throw MCPError("Say which artboard's film, as layer.") }
        // As they are seen: a deck shows its post in front.
        return boards.map { store.seenDoc.node($0.id) ?? $0 }
    }

    /// Whether anything on an artboard moves as its film plays: keys, its camera, or a shader.
    private static func moves(_ board: Node) -> Bool { board.hasFilm || board.holdsMovingShader }

    /// An artboard's film at moments, as the movie shows it: camera, depth, blur, backdrop and
    /// shaders as they are then. One moment is one picture; several are a sheet of them, left to
    /// right and top to bottom, each marked with its moment.
    private func renderFilm(_ args: Arguments, _ store: DocumentStore) throws -> [Content] {
        guard let board = try filmBoards(args, store, all: false).first else { throw MCPError("Say which artboard's film, as layer.") }
        let length = board.filmLength
        var times: [Double]
        if let count = try args.int("frames") {
            guard (2...24).contains(count) else { throw MCPError("frames is how many moments to show, 2 to 24.") }
            let once = board.film?.once == true
            times = (0..<count).map { length * Double($0) / Double(once ? count - 1 : count) }
        } else {
            guard let t = try args.number("time"), t >= 0 else { throw MCPError("time is seconds from the film's start, 0 or more.") }
            times = [min(t, length)]
        }
        let longest = CGFloat(min(max(try args.number("maxSize") ?? 1568, 64), 4096))
        let wanted = CGFloat(min(max(try args.number("scale") ?? 2, 0.05), 4))
        let w = max(board.frame.width, 1), h = max(board.frame.height, 1)
        // Laid out as near a square as the frames make, the longest side of the sheet within reach.
        var columns = 1
        if times.count > 1 {
            columns = (1...times.count).min { a, b in
                let ra = (times.count + a - 1) / a, rb = (times.count + b - 1) / b
                return max(CGFloat(a) * w, CGFloat(ra) * h) < max(CGFloat(b) * w, CGFloat(rb) * h)
            } ?? 1
        }
        let rows = (times.count + columns - 1) / columns
        let gap: CGFloat = times.count > 1 ? 12 : 0
        let scale = min(wanted, (longest - gap * CGFloat(max(columns, rows) - 1)) / max(CGFloat(columns) * w, CGFloat(rows) * h))
        let cell = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard cell.width >= 1, cell.height >= 1 else { throw MCPError("The film could not be drawn.") }
        let sheet = CGSize(width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap, height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap)
        guard let ctx = Renderer.bitmap(sheet) else { throw MCPError("The film could not be drawn.") }
        if times.count > 1 {
            ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.9, blue: 0.88, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: sheet))
        }
        for (i, t) in times.enumerated() {
            guard let frame = FilmExport.frame(of: board, at: t, size: cell, assets: store.assets) else { continue }
            let col = i % columns, row = i / columns
            // Drawn from the bottom: the first row is the top one.
            let rect = CGRect(x: CGFloat(col) * (cell.width + gap), y: sheet.height - CGFloat(row + 1) * cell.height - CGFloat(row) * gap,
                              width: cell.width, height: cell.height)
            ctx.draw(frame, in: rect)
            if times.count > 1 { Self.mark(String(format: "%.2f s", t), at: rect, in: ctx) }
        }
        guard let image = ctx.makeImage(), let png = Self.png(image) else { throw MCPError("The film could not be drawn.") }
        let note: JSONValue = .compact([
            ("drawn", .string("\(board.name)'s film")),
            ("moments", .array(times.map { .number(($0 * 1000).rounded() / 1000) })),
            ("order", times.count > 1 ? .string("\(columns) across, \(rows) down, left to right and top to bottom") : nil),
            ("length", .number(length)),
            ("pixelsPerPoint", .number((scale * 1000).rounded() / 1000)),
        ])
        return [.png(png), .text(note.text)]
    }

    /// A moment written small in the top left of a frame of a sheet, on a dark chip.
    private static func mark(_ words: String, at rect: CGRect, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(10, min(rect.width, rect.height) * 0.06), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]))
        // Measured by the line itself: its image bounds would count from wherever the last was drawn.
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = CTFontGetSize(font) * 0.45
        let chip = CGRect(x: rect.minX + pad, y: rect.maxY - pad - (ascent + descent) - pad * 2, width: width + pad * 2, height: ascent + descent + pad * 2)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.62))
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: pad, cornerHeight: pad, transform: nil))
        ctx.fillPath()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: chip.minX + pad, y: chip.minY + pad + descent)
        CTLineDraw(line, ctx)
    }

    /// Films saved as movies, as Animate's Save as Movie does: an .mp4 each, H.264.
    private func exportMovies(_ args: Arguments, _ store: DocumentStore) async throws -> [Content] {
        let boards = try filmBoards(args, store, all: true)
        let still = boards.filter { !Self.moves($0) }
        guard still.isEmpty else {
            throw MCPError("\(still.map(\.name).joined(separator: ", ")) \(still.count == 1 ? "has" : "have") nothing that moves: animate sets keys first.")
        }
        let scale = CGFloat(min(max(try args.number("scale") ?? 2, 0.25), 4))
        let fps = min(max(try args.int("fps") ?? 60, 1), FilmExport.fastest)
        let replacing = try args.bool("replace") == true
        let (folder, hint) = try Self.exportFolder(args)
        var written: [JSONValue] = []
        for board in boards {
            let base = board.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            var url = folder.appendingPathComponent(base + ".mp4")
            var n = 2
            while !replacing, FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) \(n).mp4")
                n += 1
            }
            let settings = FilmExport.Settings(scale: scale, fps: fps)
            do {
                try await FilmExport.write(board, assets: store.assets, to: url, settings: settings) { _ in }
            } catch {
                throw MCPError("\(board.name)'s film could not be saved: \(error.localizedDescription)\(hint)")
            }
            let size = FilmExport.size(of: board, settings: settings)
            written.append(.compact([("file", .string(url.path)), ("seconds", .number(board.filmLength)), ("fps", .number(fps)),
                                     ("pixels", .string("\(Int(size.width))×\(Int(size.height))"))]))
        }
        return [.text(JSONValue.compact([("movies", .array(written))]).text)]
    }

    func removeBackground(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        if try args.bool("restore") == true {
            let cut = ids.filter { store.node($0)?.fill.image?.cutout != nil }
            guard try change(store, "Restore Background", { doc in for id in cut { doc.update(id) { $0.fill.image?.cutout = nil } } }) else {
                throw MCPError("None of these shows a picture with its background taken away.")
            }
            return described(ids, in: store, full: true)
        }
        var picks: [CGPoint]?
        if let given = args["picks"] {
            guard let list = given as? [Any] else { throw MCPError("picks should be a list of points, {\"x\": 0.5, \"y\": 0.4}.") }
            picks = try list.compactMap { try Read.point($0, "picks") }
            guard picks?.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) == true else {
                throw MCPError("picks are 0 to 1 across and down the picture.")
            }
        }
        let pictured = ids.filter { store.node($0)?.fill.image != nil }
        guard !pictured.isEmpty else { throw MCPError("None of these is filled with a picture; place_image puts one in.") }
        store.canvas?.endEditing()
        do {
            guard try await !store.cutOut(pictured, picks: picks).isEmpty else {
                throw MCPError("The layers changed while their pictures were being cut out, so nothing was changed.")
            }
        } catch let trouble as DocumentStore.CutoutTrouble {
            throw MCPError("\(trouble)")
        }
        return described(ids, in: store, full: true)
    }

    func vectorize(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ids = try Self.layers(args, in: store)
        guard !store.isReadOnly else { throw MCPError("\(DocumentStore.VectorTrouble.readOnly)") }
        store.canvas?.endEditing()
        if try args.bool("restore") == true {
            let vectors = ids.filter { store.vector(of: $0) != nil }
            guard !vectors.isEmpty else { throw MCPError("None of these was vectorized from a picture while the design has been open; undo brings a picture back too.") }
            for id in vectors { store.backToPicture(id) }
            return described(ids, in: store, full: true)
        }
        var settings = VectorSettings()
        var given = false
        func amount(_ name: String) throws -> Double? {
            guard let v = try args.number(name) else { return nil }
            guard (0...100).contains(v) else { throw MCPError("\(name) is from 0 to 100.") }
            given = true
            return v / 100
        }
        if let detail = try amount("detail") { settings.detail = detail }
        if let smoothing = try amount("smoothing") { settings.smoothing = smoothing }
        if let colors = try args.int("colors") {
            guard (2...64).contains(colors) else { throw MCPError("colors is from 2 to 64.") }
            settings.colors = colors
            given = true
        }
        // A group made from a picture is traced again, the way now asked for.
        let vectors = ids.filter { store.vector(of: $0) != nil }
        for id in vectors where given {
            store.setVector(id) { now in
                if args["detail"] != nil { now.detail = settings.detail }
                if args["smoothing"] != nil { now.smoothing = settings.smoothing }
                if args["colors"] != nil { now.colors = settings.colors }
            }
            while store.retracing.contains(id) { try await Task.sleep(for: .milliseconds(20)) }
        }
        let pictures = ids.filter { store.vectorizable($0) }
        guard !pictures.isEmpty || !vectors.isEmpty else {
            throw MCPError("None of these is a rectangle, ellipse or path filled with a picture that can be vectorized; place_image puts a picture in. A picture in a component's copy, a repeat grid, a deck or holding a mask stays one.")
        }
        if !pictures.isEmpty {
            do {
                guard try await !store.vectorize(pictures, settings: settings).isEmpty else {
                    throw MCPError("The layers changed while their pictures were being traced, so nothing was changed.")
                }
            } catch let trouble as DocumentStore.VectorTrouble {
                throw MCPError("\(trouble)")
            }
        }
        return described(ids, in: store, full: true, depth: 1)
    }
}
