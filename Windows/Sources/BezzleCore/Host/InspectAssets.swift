import Foundation
import CBezzleHost

// What Inspect hands over besides measures and code, as the Mac's InspectInspector does: a
// layer's picture to drag out as a file or copy, in the format and size chosen; the type the
// design is set in, each in itself; and what the design marks for export.

extension WindowsCore {
    /// The layer inspected, as an export draws it.
    private static func inspectItem(_ id: UUID) -> ExportItem? {
        guard let seen = design, let n = seen.node(id) else { return nil }
        return n.isArtboard ? ExportItem(artboard: n) : ExportItem(layer: id, in: seen)
    }

    /// A layer's picture on nothing, as sharp as it needs to be to show no bigger than its own
    /// size in `box`, into premultiplied BGRA pixels; how many pixels it has to a point.
    public static func assetPicture(_ id: UUID, fitting box: CGSize, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Double? {
        guard let item = inspectItem(id) else { return nil }
        let f = item.node.frame
        let scale = min(2, max(0.05, min(box.width * 2 / max(f.width, 1), box.height * 2 / max(f.height, 1))))
        guard let drawn = item.pixels(scale: scale, opaque: false, assets: assets), let to = fill(drawn.width, drawn.height) else { return nil }
        // RGBA to the BGRA a WinUI bitmap has.
        drawn.pixels.withUnsafeBytes { from in
            let a = from.bindMemory(to: UInt8.self), b = to.assumingMemoryBound(to: UInt8.self)
            for k in stride(from: 0, to: drawn.pixels.count, by: 4) {
                b[k] = a[k + 2]; b[k + 1] = a[k + 1]; b[k + 2] = a[k]; b[k + 3] = a[k + 3]
            }
        }
        return Double(scale)
    }

    /// Whether what a layer is painted or written in is light, to show it on a dark board.
    public static func assetIsLight(_ id: UUID) -> Bool {
        guard let n = design?.node(id), !n.isArtboard else { return false }
        let paint = n.kind == .text ? n.fills.first : (n.fills.last ?? n.children.compactMap { $0.fills.last }.first)
        guard let c = paint?.color, paint?.image == nil else { return false }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.8 && c.a > 0.3
    }

    /// The formats a layer can be taken as from Inspect, as Windows writes them.
    public static var assetFormats: [(key: String, title: String)] {
        [ExportFormat.png, .pdf].map { ($0.rawValue, $0.title) }
    }

    /// A layer written as a file of `format` into a folder of its own, named as an export names
    /// it, for dragging out to Explorer or into code, or copying.
    public static func assetFile(_ id: UUID, format raw: String, scale: Double) -> URL? {
        guard let item = inspectItem(id), let format = ExportFormat(rawValue: raw) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle Inspect", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = ExportSize.scale(format.isPicture ? scale : 1)
        let name = format.isPicture && scale != 1 ? item.name + size.suffix : item.name
        let file = ExportFile(items: [item], format: format, size: size, name: name.replacingOccurrences(of: "/", with: "-"))
        let url = Exporter.place(of: file, in: folder)
        return write(file, to: url, quality: Exporter.defaultQuality) ? url : nil
    }

    /// A layer as pixels, `scale` to the point, trimmed to what it paints: for a picture on the
    /// clipboard, beside its file. Premultiplied RGBA, rows top first.
    public static func assetPixels(_ id: UUID, scale: Double) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let item = inspectItem(id), let drawn = item.pixels(scale: CGFloat(scale), opaque: false, assets: assets) else { return nil }
        return (drawn.width, drawn.height, drawn.pixels)
    }

    /// What the design marks for export, but artboards: each layer's name, and what its first
    /// mark makes of it.
    public static func markedAssets() -> [(id: UUID, name: String, format: String, scale: Double)] {
        guard let seen = design else { return [] }
        return ExportItem.marked(in: previewBase ?? seen, seen: seen).filter { !$0.node.isArtboard }.prefix(24).map { item in
            let preset = item.node.exports?.first ?? ExportPreset()
            let format = preset.format == .png || preset.format == .pdf ? preset.format : .png
            return (item.node.id, item.node.name, format.rawValue, preset.size.plainScale ?? 1)
        }
    }

    // MARK: The type

    /// A type the design is set in, as the Mac's TypeSamplesCard shows it: by its name when it
    /// has one, else by what it is; its family, weight and lean to show it in; what a click copies.
    public struct TypeSample: Sendable {
        public let title: String
        public let detail: String
        public let family: String
        /// As CSS counts weight, 100 to 900.
        public let weight: Int
        public let italic: Bool
        public let size: Double
        public let copy: String
    }

    public static func typeSamples(platform: InspectPlatform) -> [TypeSample] {
        guard let seen = design else { return [] }
        let p: Inspect.Platform = platform == .css ? .css : .swiftui
        let tokens = Inspect.Tokens(seen)
        func number(_ v: CGFloat) -> String {
            let r = (v * 10).rounded() / 10 + 0
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", Double(r))
        }
        func sample(_ s: TextStyle, title: String?, copy: String) -> TypeSample {
            let line = s.lineSpacing.map { " / \(number($0))" } ?? ""
            let family = s.family == TextStyle.system ? say("System") : s.family
            let traits = Fonts.traits(named: s.face)
            let weights = [2: 100, 3: 200, 4: 300, 5: 400, 6: 500, 7: 600, 8: 600, 9: 700, 10: 800, 11: 900, 12: 900]
            return TypeSample(title: title ?? "\(family) \(s.face)",
                              detail: title == nil ? "\(number(s.size))\(line)" : "\(family) \(s.face) · \(number(s.size))\(line)",
                              family: s.family, weight: weights[traits.weight] ?? 400, italic: traits.italic,
                              size: Double(min(max(s.size, 11), 22)), copy: copy)
        }
        var out: [TypeSample] = []
        for s in DesignTokens.styles(seen) where s.kind == .text {
            if let t = s.look.type { out.append(sample(t.style, title: s.name, copy: tokens[s.id]?.code(p) ?? "")) }
        }
        // The type layers are set in that has no name, the most used first.
        struct Key: Hashable { let family: String, face: String, size: CGFloat, line: CGFloat? }
        var count: [Key: (TextStyle, Int)] = [:]
        func visit(_ n: Node) {
            guard !n.hidden else { return }
            if n.kind == .text, let s = n.style, s.named == nil {
                let k = Key(family: s.family, face: s.face, size: s.size, line: s.lineSpacing)
                count[k] = (count[k]?.0 ?? s, (count[k]?.1 ?? 0) + 1)
            }
            n.children.forEach(visit)
        }
        seen.nodes.forEach(visit)
        for style in count.values.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.size > $1.0.size }).prefix(6).map(\.0) {
            var t = Node(kind: .text, name: "Text", frame: .zero)
            t.style = style
            t.text = ""
            t.fill.on = false
            out.append(sample(style, title: nil, copy: Inspect.code(t, in: BezzleDocument(), tokens: Inspect.Tokens(BezzleDocument()), for: p)))
        }
        return out
    }
}
