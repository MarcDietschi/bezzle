import Foundation
import CBezzleHost

// Pictures and words brought in from elsewhere, as the Mac's Store/Dropping.swift brings them:
// what letting go of them on the canvas does is the shared `BezzleDocument.dropPlan`, and each
// picture is copied into the design's own images first (the Mac's importPicture), so it goes
// wherever the design does.

extension WindowsCore {
    /// The kinds of picture the drawing here reads.
    static let pictureKinds: Set<String> = ["png", "jpg", "jpeg", "webp"]

    /// The pictures among some files, and those in any folders among them, by name.
    public static func pictureFiles(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found += inside.filter { pictureKinds.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if pictureKinds.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found
    }

    /// A picture file's size in pixels, upright, or nil when it is no picture Skia reads.
    static func pictureSize(_ url: URL) -> CGSize? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var w: Int32 = 0, h: Int32 = 0
        let ok = data.withUnsafeBytes { bz_image_size($0.baseAddress, Int32($0.count), &w, &h) }
        return ok != 0 ? CGSize(width: Int(w), height: Int(h)) : nil
    }

    /// Makes a design kept as a single file a package, its document inside, so it can hold pictures.
    static func makePackage() throws {
        guard let url = designURL else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return }
        let data = try Data(contentsOf: url)
        let aside = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: aside)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent("document.json"), options: .atomic)
        try? FileManager.default.removeItem(at: aside)
        assets = Assets(folder: url.appendingPathComponent("images"))
    }

    /// Copies a picture into the design's own images and returns it as a fill.
    static func importPicture(_ file: URL) -> ImageFill? {
        guard let size = pictureSize(file), let url = designURL else { return nil }
        do {
            try makePackage()
            let images = url.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
            let asset = "\(UUID().uuidString).\(ext)"
            try FileManager.default.copyItem(at: file, to: images.appendingPathComponent(asset))
            // Skia is given it by its name, as it was given the others when the design was opened.
            let data = try Data(contentsOf: images.appendingPathComponent(asset))
            _ = data.withUnsafeBytes { bz_asset_add(asset, $0.baseAddress, Int32($0.count)) }
            return ImageFill(asset: asset, mode: .cover, size: size)
        } catch {
            return nil
        }
    }

    /// What letting go of files (pictures, or a text or CSV file) or words at a canvas point, on
    /// `target`, would do: nil when they can go nowhere.
    static func plan(files: [URL], text: String?, at p: CGPoint, on target: UUID?) -> DropPlan? {
        guard let doc = design else { return nil }
        let sizes = pictureFiles(in: files).compactMap(pictureSize)
        return doc.dropPlan(pictures: sizes, text: sizes.isEmpty ? words(files: files, text: text) : nil, at: p, on: target)
    }

    /// The words a drop brings: a text or CSV file's, or those dragged themselves.
    private static func words(files: [URL], text: String?) -> String? {
        let lists = files.filter { ["txt", "text", "csv", "tsv"].contains($0.pathExtension.lowercased()) }
        return lists.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? (files.isEmpty ? text : nil)
    }

    /// The layer a drop at a canvas point lands on: the one under it, however deep in groups.
    public static func dropTarget(at p: CGPoint, zoom: Double) -> UUID? {
        guard let doc = design else { return nil }
        return Picking(doc: doc, fronts: fronts, zoom: CGFloat(zoom)).dropTarget(p)
    }

    public static func canDrop(files: [URL], text: String?, at p: CGPoint, on target: UUID?) -> Bool {
        plan(files: files, text: text, at: p, on: target) != nil
    }

    /// Does what letting go there does, as one step, and returns what to select then; nil when
    /// nothing came of it.
    public static func drop(files: [URL], text: String?, at p: CGPoint, on target: UUID?) -> [UUID]? {
        guard let plan = plan(files: files, text: text, at: p, on: target) else { return nil }
        let pictures = pictureFiles(in: files).filter { pictureSize($0) != nil }
        switch plan {
        case .fill(let shapes):
            let fills = pictures.compactMap(importPicture)
            guard !fills.isEmpty else { return nil }
            edit { $0.fill(shapes, withPictures: fills) }
            return target.map { [$0] } ?? shapes
        case .place(let frames, let board):
            let placed = zip(pictures, frames).compactMap { file, frame in
                importPicture(file).map { (name: file.deletingPathExtension().lastPathComponent, frame: frame, image: $0) }
            }
            guard !placed.isEmpty else { return nil }
            var made: [UUID] = []
            edit { made = $0.place(pictures: placed, onto: board) }
            return made
        case .posts(let shape, _):
            let fills = pictures.compactMap(importPicture)
            guard !fills.isEmpty else { return nil }
            edit { $0.spread(fills, from: shape) }
            return [shape]
        case .postWords(let textID, _):
            guard let words = words(files: files, text: text) else { return nil }
            let lines = words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            edit { d in
                d.spread([(textID, { n, i in
                    guard n.kind == .text else { return }
                    n.text = lines[i]
                    n.refit()
                })], count: lines.count)
            }
            return [textID]
        case .words(let gridID, _, _, _):
            guard let words = words(files: files, text: text), let target, let doc = design, let grid = doc.node(gridID) else { return nil }
            // A line or a column each, from the text layer it was let go on, as the Mac fills a grid.
            let slot = doc.slot(of: target).flatMap { doc.node($0)?.kind == .text ? $0 : nil }
            let each = doc.assignments(from: words, in: grid, startingWith: slot).map { (doc.copies(of: $0.slot, in: grid), $0.values) }
            guard !each.isEmpty else { return nil }
            edit { d in
                for (ids, values) in each {
                    for (i, id) in ids.enumerated() {
                        d.update(id) { n in
                            guard n.kind == .text else { return }
                            n.text = values[i % values.count]
                            n.refit()
                        }
                    }
                }
            }
            return [gridID]
        }
    }
}

extension WindowsCore {
    /// Whether a layer is a shape a picture can fill: a rectangle, an ellipse or a path.
    public static func isShape(_ id: UUID) -> Bool {
        guard let n = design?.node(id) else { return false }
        return [.rectangle, .ellipse, .path].contains(n.kind) && !n.locked
    }
}
