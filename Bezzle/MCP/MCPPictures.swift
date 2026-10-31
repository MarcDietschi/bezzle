import AppKit
import UniformTypeIdentifiers

/// Pictures of a design: for the assistant to look at what it made, and exported as files.
extension MCPTools {
    func render(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
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
                let reach = Renderer.reach(of: node)
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
        let word = try args.string("format")?.lowercased() ?? "png"
        guard let format = ExportFormat(rawValue: word == "jpg" ? "jpeg" : word) else { throw MCPError("format is png, jpeg, svg or pdf.") }
        // Whole numbers, as the Export panel offers them, so the files are named "@2x" and so on.
        let scale = CGFloat(min(max((try args.number("scale") ?? 1).rounded(), 1), 4))
        var ids: [UUID] = []
        if args["layers"] != nil { ids = try Self.layers(args, in: store) } else { ids = store.selection }
        var warnings: [String] = []
        var items: [ExportItem] = []
        for id in ids {
            guard let n = doc.node(id) else { continue }
            if n.isArtboard {
                items += ExportItem.items(for: n)
            } else if let item = ExportItem(layer: id, in: doc) {
                items.append(item)
            } else {
                warnings.append("\(n.name) is hidden, so it was left out.")
            }
        }
        // With nothing named or selected, every artboard: a carousel a picture a slide.
        if ids.isEmpty { items = doc.artboards.flatMap(ExportItem.items(for:)) }
        guard !items.isEmpty else { throw MCPError("There is nothing to export: \(store.name) has no artboards.") }

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
        // The App Store's Bezzle may only write where the user has let it.
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let hint = sandboxed ? " Bezzle can write to Downloads, and to folders once chosen in its Export panel." : ""
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw MCPError("\(folder.path) could not be made: \(error.localizedDescription)\(hint)")
        }
        let written = Exporter.export(items, format: format, scale: scale, name: store.name, to: folder, assets: store.assets)
        guard !written.isEmpty else { throw MCPError("Nothing could be written to \(folder.path).\(hint)") }
        return [.text(JSONValue.compact([
            ("files", .array(written.map { .string($0.path) })),
            ("warnings", .array(warnings.map { .string($0) })),
        ]).text)]
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
}
