import Foundation
import CBezzleHost

// Exporting on Windows, as the Mac exports (Export/Exporter.swift): what goes out, how the files
// are named and where they go is the shared ExportPlan.swift; here each is drawn with Skia and
// written as PNG, JPEG or WebP, as AVIF by libavif as the Mac's Image I/O writes it (CBezzleHost/
// avif.cpp; offered when the build has it, Host/PictureFormats.swift), or as one PDF that keeps
// text and shapes sharp; SVG is the shared SVGWriter, its text and pictures as Web/WebSVGText.swift
// has them.

extension ExportItem {
    /// The part of the canvas it covers: an artboard's frame, or for a layer just what it paints,
    /// its shadow and blur included, found by drawing it.
    func bounds(assets: Assets?) -> CGRect {
        if node.isArtboard { return slideFrame ?? node.frame }
        return pixels(scale: 1, opaque: false, assets: assets)?.rect ?? node.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The recording that draws it at `scale` pixels a point, over `rect` on the canvas: an
    /// artboard whole, or a layer over all it may paint.
    func recording(scale: CGFloat, opaque: Bool, assets: Assets?) -> (image: CGImage, rect: CGRect)? {
        if node.isArtboard {
            let rect = slideFrame ?? node.frame
            return Renderer.image(of: node, part: slideFrame, scale: scale, opaque: opaque, assets: assets).map { ($0, rect) }
        }
        // The layer's own top left falls on a whole pixel, so its edges come out sharp.
        let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let reach = Renderer.reach(of: node).offsetBy(dx: origin.x, dy: origin.y)
        let minX = frame.minX + ((reach.minX - frame.minX) * scale).rounded(.down) / scale
        let minY = frame.minY + ((reach.minY - frame.minY) * scale).rounded(.down) / scale
        let w = Int(((reach.maxX - minX) * scale).rounded(.up)), h = Int(((reach.maxY - minY) * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 400_000_000, let ctx = Renderer.bitmap(CGSize(width: w, height: h)) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -minX, y: -minY)
        Renderer.withFlippedContext(ctx) { drawLayer(in: ctx, scale: scale, assets: assets) }
        guard let image = ctx.makeImage() else { return nil }
        return (image, CGRect(x: minX, y: minY, width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }

    /// Drawn at `scale` pixels to the point as premultiplied RGBA pixels: an artboard whole, or a
    /// layer trimmed to what it paints, on nothing; `opaque` puts it on white, as a JPEG has to be.
    func pixels(scale: CGFloat, opaque: Bool, assets: Assets?) -> (width: Int, height: Int, pixels: [UInt8], rect: CGRect)? {
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let (image, rect) = recording(scale: scale, opaque: opaque, assets: assets) else { return nil }
        for picture in Images.shared.list where picture.id >= first { WindowsCore.send(picture) }
        defer { WindowsCore.forget(before: first) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let read = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 0, $0.baseAddress) }
        guard read == 0 else { return nil }
        guard !node.isArtboard else { return (image.width, image.height, pixels, rect) }
        // A layer goes out only as big as what it paints.
        guard let used = Self.painted(pixels, width: image.width, height: image.height) else { return nil }
        var trimmed = [UInt8](repeating: 0, count: used.width * used.height * 4)
        for y in 0..<used.height {
            let from = ((used.minY + y) * image.width + used.minX) * 4, to = y * used.width * 4
            trimmed.replaceSubrange(to..<to + used.width * 4, with: pixels[from..<from + used.width * 4])
        }
        if opaque {
            // On white: what shows through is white.
            for k in stride(from: 0, to: trimmed.count, by: 4) {
                let clear = 255 - Int(trimmed[k + 3])
                for c in 0..<3 { trimmed[k + c] = UInt8(min(255, Int(trimmed[k + c]) + clear)) }
                trimmed[k + 3] = 255
            }
        }
        let shown = CGRect(x: rect.minX + CGFloat(used.minX) / scale, y: rect.minY + CGFloat(used.minY) / scale,
                           width: CGFloat(used.width) / scale, height: CGFloat(used.height) / scale)
        return (used.width, used.height, trimmed, shown)
    }

    /// The pixels that are not wholly clear, counted from the top left; nil when none are.
    private static func painted(_ pixels: [UInt8], width w: Int, height h: Int) -> (minX: Int, minY: Int, width: Int, height: Int)? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where pixels[row + x * 4 + 3] != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = y
            }
        }
        return maxX >= 0 ? (minX, minY, maxX - minX + 1, maxY - minY + 1) : nil
    }
}

extension WindowsCore {
    /// The kinds of file Bezzle for Windows writes, in the order the Mac offers them.
    public static var exportFormats: [String] {
        ExportFormat.offered.map(\.rawValue)
    }

    public static func formatTitle(_ raw: String) -> String { ExportFormat(rawValue: raw)?.title ?? raw }
    public static func formatIsPicture(_ raw: String) -> Bool { ExportFormat(rawValue: raw)?.isPicture ?? false }

    private static func choices(_ selection: [UUID]) -> ExportChoices? {
        guard let doc = design else { return nil }
        let name = designURL?.deletingPathExtension().lastPathComponent ?? "Design"
        // A deck by the post in front of it here, as the Mac's seenDoc and fronts.
        return ExportChoices(doc: doc, seen: seen ?? doc, selection: selection, front: { $0.front(in: fronts) }, name: name)
    }

    private static func scope(_ key: String) -> ExportChoices.Scope {
        switch key {
        case "layers": .layers
        case "post": .post
        case "artboards": .artboards
        case "marked": .marked
        default: .all
        }
    }

    private static func key(_ scope: ExportChoices.Scope) -> String {
        switch scope {
        case .layers: "layers"
        case .post: "post"
        case .artboards: "artboards"
        case .marked: "marked"
        case .all: "all"
        }
    }

    /// What the Export sheet offers for the selection, each by its key and what it is called, the
    /// first chosen to begin with; empty when there is nothing to export.
    public static func exportScopes(_ selection: [UUID]) -> [(key: String, title: String)] {
        guard let c = choices(selection), !c.isEmpty else { return [] }
        return c.scopes.map { (key($0), c.title($0).key) }
    }

    /// Whether only carousels' slides go out, which keep a scale of their own.
    public static func exportOnlySlides(_ scopeKey: String, selection: [UUID]) -> Bool {
        choices(selection)?.onlySlides(scope(scopeKey)) ?? false
    }

    /// Whether how much of the picture is kept matters.
    public static func exportLossy(_ scopeKey: String, format: String, selection: [UUID]) -> Bool {
        choices(selection)?.lossy(scope(scopeKey), format: ExportFormat(rawValue: format) ?? .png) ?? false
    }

    /// The qualities offered, each its value and what it is called.
    public static func exportQualities(_ scopeKey: String, format: String) -> [(Double, String)] {
        ExportChoices.qualities(for: scopeKey == "marked" ? nil : ExportFormat(rawValue: format)).map { ($0.0, $0.1.key) }
    }

    /// What will go out, in a sentence.
    public static func exportSummary(_ scopeKey: String, format: String, scale: Double, selection: [UUID]) -> String {
        guard let c = choices(selection) else { return "" }
        let items = c.items(scope(scopeKey))
        return c.summary(scope(scopeKey), format: ExportFormat(rawValue: format) ?? .png, scale: scale) { item in
            items.count == 1 ? item.bounds(assets: assets).size : item.bounds(assets: nil).size
        }
    }

    private static func files(_ scopeKey: String, format: String, scale: Double, selection: [UUID]) -> [ExportFile] {
        choices(selection)?.files(scope(scopeKey), format: ExportFormat(rawValue: format) ?? .png, scale: CGFloat(scale)) ?? []
    }

    /// The files already in `folder` that exporting would replace.
    public static func exportClashes(_ scopeKey: String, format: String, scale: Double, selection: [UUID], in folder: URL) -> [URL] {
        Exporter.clashes(files(scopeKey, format: format, scale: scale, selection: selection), in: folder)
    }

    /// Exports into `folder`, a file at a time, telling how far it has come (0…1); files of the
    /// same names already there are replaced when `replacing`, else the new ones are numbered.
    /// Returns the one file written or the folder, and how many were written and missed.
    public static func export(_ scopeKey: String, format: String, scale: Double, quality: Double, selection: [UUID],
                              to folder: URL, replacing: Bool, progress: @MainActor (Double) -> Void) async -> (shown: URL, written: Int, missed: Int) {
        let files = files(scopeKey, format: format, scale: scale, selection: selection)
        let places = Exporter.destinations(of: files, in: folder, replacing: replacing)
        var written: [URL] = [], missed = 0
        for (k, (file, place)) in zip(files, places).enumerated() {
            if let place, write(file, to: place, quality: quality) { written.append(place) } else { missed += 1 }
            progress(Double(k + 1) / Double(max(files.count, 1)))
            // A moment for the window to show how far it has come.
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return (written.count == 1 ? written[0] : folder, written.count, missed)
    }

    /// While an SVG is written, the first of the pictures made for it, which reach Skia before
    /// one of them is encoded (`Host.encodePicture`).
    nonisolated(unsafe) static var picturesFrom: Int?

    /// Writes one file where it goes, replacing what is there.
    static func write(_ file: ExportFile, to url: URL, quality: Double) -> Bool {
        switch file.format {
        case .pdf:
            let pdf = bz_pdf_begin(url.path)
            guard pdf != 0 else { return false }
            var ok = true
            for item in file.items {
                // Drawn at 2× where it has to be pixels (blurs, pictures); shapes and text stay as they are.
                let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
                guard let (image, rect) = item.recording(scale: 2, opaque: item.node.isArtboard, assets: assets) else { ok = false; continue }
                for picture in Images.shared.list where picture.id >= first { send(picture) }
                if bz_pdf_page(pdf, Int32(image.id), Double(rect.width), Double(rect.height), 2) != 0 { ok = false }
                forget(before: first)
            }
            return bz_pdf_end(pdf) == 0 && ok
        case .png, .jpeg, .webp, .avif:
            guard let item = file.items.first, file.format.isAvailable else { return false }
            let scale = file.scale(drawn: item.bounds(assets: assets).size)
            guard let drawn = item.pixels(scale: scale, opaque: !file.format.keepsTransparency, assets: assets) else { return false }
            // A WebP is at most 16383 pixels a side.
            if file.format == .webp, max(drawn.width, drawn.height) > 16_383 { return false }
            let kind: Int32 = switch file.format {
            case .jpeg: 1
            case .webp: 2
            case .avif: 3
            default: 0
            }
            return drawn.pixels.withUnsafeBytes { bz_image_write(url.path, Int32(drawn.width), Int32(drawn.height), $0.baseAddress, kind, quality) } == 0
        case .svg:
            guard let item = file.items.first else { return false }
            let bounds = item.bounds(assets: assets)
            // What has to come as a picture is drawn by Skia as the writer asks for it.
            let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
            picturesFrom = first
            defer {
                picturesFrom = nil
                forget(before: first)
            }
            let svg = SVGWriter.document(for: item, bounds: bounds, assets: assets)
            return (try? svg.write(to: url, atomically: true, encoding: .utf8)) != nil
        }
    }
}

// MARK: - Marked for export

extension WindowsCore {
    /// One file a layer goes out as when what is marked is exported: its size as shown ("2×",
    /// "512w"), what goes after its name, its format, and whether it is drawn in pixels.
    nonisolated public struct ExportMark: Sendable {
        public let size: String
        public let suffix: String
        public let format: String
        public let isPicture: Bool
    }

    /// The first selected layer's marks, which the Export card shows and every change sets on all
    /// of them; whether they all have the same; and the marks in a few words. Nil while none is marked.
    public static func exportMarks(_ ids: [UUID]) -> (marks: [ExportMark], same: Bool, summary: String)? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard let first = nodes.first, nodes.contains(where: { $0.exports?.isEmpty == false }) else { return nil }
        let presets = first.exports ?? []
        let marks = presets.map { ExportMark(size: $0.format.isPicture ? $0.size.shown : "1×", suffix: $0.nameSuffix, format: $0.format.rawValue, isPicture: $0.format.isPicture) }
        return (marks, nodes.allSatisfy { $0.exports == presets }, ExportPreset.summary(of: presets))
    }

    /// Whether every selected layer is marked for export, none is (false), or some are (nil).
    public static func exportMarked(_ ids: [UUID]) -> Bool? {
        guard let doc = design else { return nil }
        let marked = ids.compactMap { doc.node($0) }.map { $0.exports?.isEmpty == false }
        guard let first = marked.first else { return nil }
        return marked.allSatisfy { $0 == first } ? first : nil
    }

    private static func presets(_ ids: [UUID]) -> [ExportPreset] { ids.first.flatMap { design?.node($0)?.exports } ?? [] }

    private static func setPresets(_ ids: [UUID], _ presets: [ExportPreset]) {
        edit { d in for id in ids { d.update(id) { $0.exports = presets.isEmpty ? nil : presets } } }
    }

    /// Marks the layers for export, a 1× PNG to begin with (the Mac's "+ Export").
    public static func markForExport(_ ids: [UUID]) { setPresets(ids, [ExportPreset()]) }
    public static func unmarkForExport(_ ids: [UUID]) { setPresets(ids, []) }

    /// Another file after the others: the next size up, in the format of the last.
    public static func addExportMark(_ ids: [UUID]) {
        let all = presets(ids)
        setPresets(ids, all + [ExportPreset.next(after: all)])
    }

    public static func removeExportMark(_ ids: [UUID], at k: Int) {
        var all = presets(ids)
        guard all.indices.contains(k) else { return }
        all.remove(at: k)
        setPresets(ids, all)
    }

    /// A size typed for mark `k` ("2x", "512w", "64h"); false when it reads as none.
    @discardableResult public static func setExportSize(_ ids: [UUID], at k: Int, _ typed: String) -> Bool {
        guard let size = ExportSize(typed) else { return false }
        var all = presets(ids)
        guard all.indices.contains(k) else { return false }
        all[k].size = size
        setPresets(ids, all)
        return true
    }

    /// What goes after the layer's name in mark `k`; the size's own is kept as none of its own.
    public static func setExportSuffix(_ ids: [UUID], at k: Int, _ typed: String) {
        var all = presets(ids)
        guard all.indices.contains(k) else { return }
        let own = ExportPreset(size: all[k].size, format: all[k].format).nameSuffix
        all[k].suffix = typed == own ? nil : typed
        setPresets(ids, all)
    }

    public static func setExportFormat(_ ids: [UUID], at k: Int, _ raw: String) {
        guard let format = ExportFormat(rawValue: raw) else { return }
        var all = presets(ids)
        guard all.indices.contains(k) else { return }
        all[k].format = format
        setPresets(ids, all)
    }

    private static func markedFiles(_ ids: [UUID]) -> [ExportFile] {
        guard let doc = design else { return [] }
        return Exporter.files(presetsOf: ExportItem.items(for: ids, in: doc))
    }

    /// The files exporting the selection as it is marked would make, by name.
    public static func markedListing(_ ids: [UUID]) -> String { ExportChoices.listing(markedFiles(ids), marked: false) }

    public static func markedClashes(_ ids: [UUID], in folder: URL) -> [URL] { Exporter.clashes(markedFiles(ids), in: folder) }

    /// Exports the selection as it is marked, as `export` exports.
    public static func exportMarked(_ ids: [UUID], quality: Double, to folder: URL, replacing: Bool,
                                    progress: @MainActor (Double) -> Void) async -> (shown: URL, written: Int, missed: Int) {
        let files = markedFiles(ids)
        let places = Exporter.destinations(of: files, in: folder, replacing: replacing)
        var written: [URL] = [], missed = 0
        for (k, (file, place)) in zip(files, places).enumerated() {
            if let place, write(file, to: place, quality: quality) { written.append(place) } else { missed += 1 }
            progress(Double(k + 1) / Double(max(files.count, 1)))
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return (written.count == 1 ? written[0] : folder, written.count, missed)
    }
}
