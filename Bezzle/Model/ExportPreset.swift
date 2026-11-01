import Foundation
import CoreGraphics
import ImageIO

/// The kinds of file a design can be exported as.
nonisolated enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, webp, avif, svg, pdf

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        case .avif: "avif"
        case .svg: "svg"
        case .pdf: "pdf"
        }
    }

    /// As it is written everywhere, in every language.
    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .svg: "SVG"
        case .pdf: "PDF"
        }
    }

    /// Drawn in pixels, at a scale; the others stay sharp at any size.
    var isPicture: Bool { self == .png || self == .jpeg || self == .webp || self == .avif }

    /// Smaller for giving up a little of the picture, as much as its quality says.
    var isLossy: Bool { self == .jpeg || self == .webp || self == .avif }

    /// Whether what is see-through stays so: a JPEG has to lie on white.
    var keepsTransparency: Bool { self != .jpeg }

    /// What this Mac can write. AVIF needs a Mac whose ImageIO writes it.
    var isAvailable: Bool { self != .avif || Self.writesAVIF }

    /// The formats offered, in the order they are offered.
    static var offered: [ExportFormat] { allCases.filter(\.isAvailable) }

    private static let writesAVIF: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains("public.avif")
    }()
}

/// How big a picture is exported: so many pixels to a point, or so many pixels wide or tall
/// whatever size it is. Written as people type it, "2x", "512w" or "64h", in files too.
nonisolated enum ExportSize: Hashable, Sendable {
    case scale(Double)
    case width(Double)
    case height(Double)

    static let scales = 0.01...20.0
    static let pixels = 1.0...16_384.0

    /// Reads "2", "2x", "2×", "@2x", "1,5x", "512w" or "64h"; nil for anything else, or a size
    /// too small or too large to draw.
    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        if s.hasPrefix("@") { s.removeFirst() }
        s = s.replacingOccurrences(of: " ", with: "")
        var make: (Double) -> ExportSize = { .scale($0) }
        var range = Self.scales
        if let last = s.last, "x×".contains(last) {
            s.removeLast()
        } else if s.hasSuffix("w") {
            s.removeLast()
            make = { .width($0.rounded()) }
            range = Self.pixels
        } else if s.hasSuffix("h") {
            s.removeLast()
            make = { .height($0.rounded()) }
            range = Self.pixels
        }
        guard let v = Double(s), v.isFinite, range.contains(v) else { return nil }
        self = make(v)
    }

    /// As it is stored and typed: "2x", "512w", "64h".
    var text: String {
        switch self {
        case .scale(let s): "\(Self.number(s))x"
        case .width(let w): "\(Self.number(w))w"
        case .height(let h): "\(Self.number(h))h"
        }
    }

    /// As it is shown: "2×", "512w", "64h".
    var shown: String {
        switch self {
        case .scale(let s): "\(Self.number(s))×"
        case .width, .height: text
        }
    }

    /// What goes after the name when nothing else is asked: nothing at 1×, "@2x" at 2×, as
    /// iOS and the web name them, "-512w" for a set width.
    var suffix: String {
        switch self {
        case .scale(let s): s == 1 ? "" : "@\(Self.number(s))x"
        case .width(let w): "-\(Self.number(w))w"
        case .height(let h): "-\(Self.number(h))h"
        }
    }

    /// The pixels to a point that draw something `size` points big at this size.
    func scale(for size: CGSize) -> CGFloat {
        switch self {
        case .scale(let s): CGFloat(s)
        case .width(let w): size.width > 0 ? CGFloat(w) / size.width : 1
        case .height(let h): size.height > 0 ? CGFloat(h) / size.height : 1
        }
    }

    /// The pixels to a point it comes to for something of no particular size: its scale, or 1.
    var plainScale: Double? {
        if case .scale(let s) = self { return s }
        return nil
    }

    /// A number as a file name has it: to two decimals at most, with a point, never grouped.
    private static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

extension ExportSize: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let size = ExportSize(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No export size: \(text)"))
        }
        self = size
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// One file a layer goes out as whenever it is exported as it is marked: drawn at a size, in a
/// format, and named after the layer with a suffix, such as "Icon@2x.png".
nonisolated struct ExportPreset: Codable, Hashable, Sendable {
    var size: ExportSize = .scale(1)
    var format: ExportFormat = .png
    /// Put after the layer's name; nil is the size's own, such as "@2x" at 2×.
    var suffix: String?

    init(size: ExportSize = .scale(1), format: ExportFormat = .png, suffix: String? = nil) {
        self.size = size
        self.format = format
        self.suffix = suffix
    }

    /// What goes after the layer's name. A drawing that is sharp at any size has no size to name.
    var nameSuffix: String { suffix ?? (format.isPicture ? size.suffix : "") }

    /// The preset that comes after these, as the + offers it: the next size up, 1× then 2×, 3×,
    /// in the format of the last.
    static func next(after presets: [ExportPreset]) -> ExportPreset {
        guard let last = presets.last else { return ExportPreset() }
        let scales = presets.compactMap { $0.format == last.format ? $0.size.plainScale : nil }
        let top = scales.max() ?? 0
        let size: ExportSize = top < 1 ? .scale(1) : .scale(top.rounded(.down) + 1)
        return ExportPreset(size: last.format.isPicture ? size : .scale(1), format: last.format)
    }
}
