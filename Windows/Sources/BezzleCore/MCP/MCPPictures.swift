import Foundation
import CBezzleHost

// From Bezzle/MCP/MCPPictures.swift, for Windows: pictures of a design, for the assistant to look
// at what it made, and exported as files, drawn and written by Skia as the Export sheet's are.

extension MCPTools {
    func render(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc
        // As large as a model looks at a picture whole.
        let longest = CGFloat(min(max(try args.number("maxSize") ?? 1568, 64), 4096))
        let wanted = CGFloat(min(max(try args.number("scale") ?? 2, 0.05), 4))
        let png: Data?
        let what: String
        var scale: CGFloat
        var size = (0, 0)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: doc)
            guard let node = doc.node(id) else { throw MCPError("That layer is gone.") }
            let item: ExportItem
            if node.isArtboard {
                item = ExportItem(artboard: node)
                scale = min(wanted, longest / max(node.frame.width, node.frame.height, 1))
            } else {
                guard let layer = ExportItem(layer: id, in: doc) else { throw MCPError("\(node.name) is hidden, so there is nothing to draw.") }
                item = layer
                let reach = Renderer.reach(of: node)
                scale = min(wanted, longest / max(reach.width, reach.height, 1))
            }
            guard let drawn = item.pixels(scale: scale, opaque: false, assets: store.assets) else { throw MCPError("The picture could not be drawn.") }
            png = Self.png(drawn.pixels, width: drawn.width, height: drawn.height)
            size = (drawn.width, drawn.height)
            what = node.name
        } else {
            guard let bounds = doc.contentBounds, bounds.width > 0 || bounds.height > 0 else { throw MCPError("\(store.name) is empty: there is nothing to draw.") }
            // The thumbnail is drawn at twice its size in points.
            scale = min(wanted, longest / max(bounds.width, bounds.height, 1))
            let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
            WindowsCore.picturesFrom = first
            defer {
                WindowsCore.picturesFrom = nil
                WindowsCore.forget(before: first)
            }
            guard let image = Renderer.thumbnail(of: doc, size: CGSize(width: bounds.width * scale / 2, height: bounds.height * scale / 2), assets: store.assets) else {
                throw MCPError("The picture could not be drawn.")
            }
            png = SVGWriter.png(image)
            size = (image.width, image.height)
            what = "the whole of \(store.name)"
            scale *= 0.86
        }
        guard let png else { throw MCPError("The picture could not be drawn.") }
        let note: JSONValue = [
            "drawn": .string(what),
            "pixels": .string("\(size.0)×\(size.1)"),
            "pixelsPerPoint": .number((scale * 1000).rounded() / 1000),
        ]
        return [.png(png), .text(note.text)]
    }

    /// A picture the core drew, as a PNG file: drawn by Skia with the pictures made for it.
    static func png(_ image: CGImage) -> Data? {
        let first = Images.shared.list.first.map(\.id) ?? 0
        WindowsCore.picturesFrom = first
        defer { WindowsCore.picturesFrom = nil }
        return SVGWriter.png(image)
    }

    /// Premultiplied RGBA pixels as a PNG file.
    static func png(_ pixels: [UInt8], width: Int, height: Int) -> Data? {
        let count = pixels.withUnsafeBytes { bz_image_encode(Int32(width), Int32(height), $0.baseAddress, 0, 1) }
        guard count > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: Int(count))
        out.withUnsafeMutableBytes { bz_host_take($0.baseAddress) }
        return Data(out)
    }

    func export(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let doc = store.doc
        let format = try Self.format(try args.string("format") ?? "png")
        // Whole numbers, as the Export sheet offers them, so the files are named "@2x" and so on.
        let scale = CGFloat(min(max((try args.number("scale") ?? 1).rounded(), 1), 4))
        let quality = min(max(try args.number("quality") ?? 0.9, 0), 1)
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
        let folder: URL
        if let path = try args.string("folder") {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? MCPHost.shared.designsFolder()
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw MCPError("\(folder.path) could not be made: \(error)")
        }
        let files = marked ? Exporter.files(presetsOf: items) : Exporter.files(items, format: format, scale: scale, name: store.name)
        let destinations = Exporter.destinations(of: files, in: folder, replacing: replacing)
        var written: [URL] = []
        for (file, url) in zip(files, destinations) {
            guard let url else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if WindowsCore.write(file, to: url, quality: quality) { written.append(url) }
        }
        if written.count < files.count {
            warnings.append("\(files.count - written.count) of the \(files.count) files could not be made\(files.contains { $0.format == .webp } ? " (a webp is at most 16383 pixels a side)" : "").")
        }
        guard !written.isEmpty else { throw MCPError("Nothing could be written to \(folder.path).") }
        return [.text(JSONValue.compact([
            ("files", .array(written.map { .string($0.path) })),
            ("warnings", .array(warnings.map { .string($0) })),
        ]).text)]
    }
}
