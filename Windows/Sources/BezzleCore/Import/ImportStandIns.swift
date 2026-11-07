import Foundation
import AppKit
import CBezzleHost

// What the Mac's importers (the files beside this one, linked from Bezzle/Import) take from the
// Mac app and from AppKit, Image I/O, Core Text and Core Image, on Windows: the same questions,
// answered with what the core has here (the open fonts, Skia's codecs). Only this folder's files
// ask them.

// MARK: - The app's

/// The canvas's angles (the app's CanvasView.normalized, which is Geometry's).
enum CanvasView {
    nonisolated static func normalized(_ degrees: Double) -> Double { Geometry.normalized(degrees) }
}

/// Where designs are kept, as far as bringing one in needs it (the app's, in Store/Library.swift).
final class Library {
    static let shared = Library()
    /// Documents › Bezzle, as the Windows app keeps them, unless the app says otherwise.
    var folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Bezzle", isDirectory: true)

    /// A file name in `folder` that is not taken yet: "Untitled", then "Untitled 2"…
    func freeURL(named name: String, in folder: URL? = nil) -> URL {
        let dir = folder ?? self.folder
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(i)").appendingPathExtension(BezzleDocument.fileExtension)
            i += 1
        }
        return candidate
    }
}

nonisolated extension DesignFile {
    /// Saves a design as the Mac's DesignFile.write does: over what is there, in the form it
    /// has; a new design becomes a package.
    static func write(_ doc: BezzleDocument, to url: URL, creating: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if exists, isFolder.boolValue {
            try data.write(to: url.appendingPathComponent(documentName), options: .atomic)
        } else if exists {
            try data.write(to: url, options: .atomic)
        } else {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(imagesFolder, isDirectory: true), withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent(documentName), options: .atomic)
        }
    }
}

// MARK: - Uniform Type Identifiers

/// The kinds of picture file the importers name, by the identifiers the Mac gives them.
nonisolated struct UTType: Hashable, Sendable {
    let identifier: String
    let preferredFilenameExtension: String?

    private static let known: [(String, String)] = [
        ("public.png", "png"), ("public.jpeg", "jpeg"), ("com.compuserve.gif", "gif"), ("org.webmproject.webp", "webp"),
        ("public.tiff", "tiff"), ("com.microsoft.bmp", "bmp"), ("public.avif", "avif"), ("public.heic", "heic"), ("public.heif", "heif"),
        ("com.adobe.pdf", "pdf"), ("public.svg-image", "svg"), ("com.microsoft.ico", "ico"),
    ]

    private init(identifier: String, ext: String?) {
        self.identifier = identifier
        preferredFilenameExtension = ext
    }

    init?(_ identifier: String) {
        guard let found = Self.known.first(where: { $0.0 == identifier }) else { return nil }
        self.init(identifier: found.0, ext: found.1)
    }

    init?(filenameExtension ext: String) {
        let ext = ext.lowercased() == "jpg" ? "jpeg" : ext.lowercased()
        guard let found = Self.known.first(where: { $0.1 == ext }) else { return nil }
        self.init(identifier: found.0, ext: found.1)
    }

    static let png = UTType(identifier: "public.png", ext: "png")
}

// MARK: - Image I/O

nonisolated let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
nonisolated let kCGImagePropertyPixelHeight: CFString = "PixelHeight"

/// A picture file's bytes, as Image I/O reads them: what kind it is by its first bytes, and its
/// pixels, which Skia reads (PNG, JPEG and WebP here), and libavif AVIF (CBezzleHost/avif.cpp).
nonisolated final class CGImageSource: @unchecked Sendable {
    let data: Data
    let type: String?
    /// Its size in pixels as kept, when Skia can read it.
    let size: (width: Int, height: Int)?

    init(_ data: Data) {
        self.data = data
        type = Self.kind(of: data)
        var w: Int32 = 0, h: Int32 = 0
        let read = data.withUnsafeBytes { bz_image_pixel_size($0.baseAddress, Int64($0.count), &w, &h) }
        size = read != 0 ? (Int(w), Int(h)) : nil
    }

    private static func kind(of data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        func starts(_ s: [UInt8], at: Int = 0) -> Bool { b.count >= at + s.count && Array(b[at..<at + s.count]) == s }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "public.png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "public.jpeg" }
        if starts(Array("GIF8".utf8)) { return "com.compuserve.gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "org.webmproject.webp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "public.tiff" }
        if starts(Array("BM".utf8)) { return "com.microsoft.bmp" }
        if starts(Array("ftyp".utf8), at: 4) {
            // An AVIF names "avif" or "avis" as its brand, first or among those it is compatible with.
            let box = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            let brands = [UInt8](data.prefix(min(max(box, 16), 256)))
            let avif = stride(from: 8, to: brands.count - 3, by: 4).contains { k in
                k != 12 && (Array(brands[k..<k + 4]) == Array("avif".utf8) || Array(brands[k..<k + 4]) == Array("avis".utf8))
            }
            return avif ? "public.avif" : "public.heic"
        }
        if starts(Array("%PDF".utf8)) { return "com.adobe.pdf" }
        return nil
    }
}

nonisolated func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? {
    data.isEmpty ? nil : CGImageSource(data)
}

nonisolated func CGImageSourceGetType(_ source: CGImageSource) -> CFString? { source.type }

nonisolated func CGImageSourceGetCount(_ source: CGImageSource) -> Int { source.size == nil ? 0 : 1 }

nonisolated func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard index == 0, let size = source.size else { return nil }
    return [kCGImagePropertyPixelWidth: size.width, kCGImagePropertyPixelHeight: size.height]
}

/// The picture's pixels, premultiplied, as kept (not turned by its orientation, as Image I/O gives them).
nonisolated func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, let size = source.size, size.width > 0, size.height > 0, size.width * size.height < 400_000_000 else { return nil }
    var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
    let done = source.data.withUnsafeBytes { data in
        pixels.withUnsafeMutableBytes { bz_image_decode(data.baseAddress, Int64(data.count), Int32(size.width), Int32(size.height), $0.baseAddress) }
    }
    guard done == 0 else { return nil }
    return CGImage(width: size.width, height: size.height, source: .pixels(pixels, bytesPerRow: size.width * 4, gray: false))
}

/// A PNG being made, as Image I/O writes one (the Photoshop importer's pictures). Safe on any
/// thread: the pictures it is given were made beforehand (`ImportPictures`).
nonisolated final class CGImageDestination: @unchecked Sendable {
    let data: NSMutableData
    let type: String
    var images: [CGImage] = []
    init(data: NSMutableData, type: String) {
        self.data = data
        self.type = type
    }
}

nonisolated func CGImageDestinationCreateWithData(_ data: NSMutableData, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    type == UTType.png.identifier ? CGImageDestination(data: data, type: type) : nil
}

nonisolated func CGImageDestinationAddImage(_ destination: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {
    destination.images.append(image)
}

nonisolated func CGImageDestinationFinalize(_ destination: CGImageDestination) -> Bool {
    ImportPictures.timed("png, all threads") { finalize(destination) }
}

nonisolated private func finalize(_ destination: CGImageDestination) -> Bool {
    guard let image = destination.images.first, let pixels = ImportPictures.pixels(of: image) else { return false }
    let w = image.width, h = image.height
    var capacity = w * h * 4 + h + 65_536
    while true {
        var out = [UInt8](repeating: 0, count: capacity)
        let n = pixels.bytes.withUnsafeBytes { p in
            out.withUnsafeMutableBytes { bz_png_encode(Int32(w), Int32(h), p.baseAddress, pixels.straight ? 1 : 0, $0.baseAddress, Int64(capacity)) }
        }
        if n == -1 { return false }
        if n < 0 {
            capacity = Int(-n)
            continue
        }
        destination.data.append(out, length: Int(n))
        return true
    }
}

nonisolated extension CGImage {
    /// The picture's pixels, as Core Graphics hands them over: as they were given for pixels made
    /// here, otherwise as Skia makes them, premultiplied RGBA.
    var dataProvider: CGDataProvider? {
        ImportPictures.timed("pixels handed over") {
            guard let pixels = ImportPictures.pixels(of: self) else { return nil }
            return CGDataProvider(data: Data(pixels.bytes))
        }
    }
}

// MARK: - Colour spaces, Core Image, PDF and SVG, for Photoshop documents

nonisolated enum CGColorSpaceModel: Int32, Sendable {
    case unknown = -1, monochrome, rgb, cmyk, lab, deviceN, indexed, pattern, XYZ
}

nonisolated extension CGColorSpace {
    /// The kind of space an ICC profile describes: here every RGB one is drawn as sRGB, every
    /// grey one as grey and every ink one as plain CMYK.
    convenience init?(iccData data: CFData) {
        guard data.count >= 20 else { return nil }
        switch String(decoding: data.dropFirst(16).prefix(4), as: UTF8.self) {
        case "RGB ": self.init(named: CGColorSpace.sRGB)
        case "GRAY": self.init(named: CGColorSpace.genericGrayGamma2_2)
        case "CMYK": self.init(named: CGColorSpace.genericCMYK)
        default: return nil
        }
    }

    var model: CGColorSpaceModel {
        switch numberOfComponents {
        case 1: .monochrome
        case 4: .cmyk
        default: .rgb
        }
    }
}

nonisolated extension CIFormat {
    /// One byte a pixel.
    static let L8 = CIFormat()
}

nonisolated extension CIContextOption {
    static let outputColorSpace = CIContextOption(name: "output")
}

nonisolated extension CIImage {
    /// Grey pixels, one byte each, rows top first.
    convenience init(bitmapData data: Data, bytesPerRow: Int, size: CGSize, format: CIFormat, colorSpace: CGColorSpace?) {
        self.init(cgImage: CGImage(width: Int(size.width), height: Int(size.height), source: .pixels([UInt8](data), bytesPerRow: bytesPerRow, gray: true)))
    }
}

nonisolated extension CIContext {
    /// A grey picture's pixels, spread as asked (`Images.Change.spread`), `bounds` of them in Core
    /// Image's terms, into one byte a pixel, rows top first. Only what the Photoshop importer asks.
    func render(_ image: CIImage, toBitmap data: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect, format: CIFormat, colorSpace: CGColorSpace?) {
        guard let source = image.source, case .pixels(let bytes, let row, true) = source.source else { return }
        let w = source.width, h = source.height
        var plane = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { plane[y * w + x] = bytes[y * row + x] } }
        for change in image.changes {
            if case .spread(let radius) = change { plane = ImportPictures.spread(plane, width: w, height: h, radius: radius) }
        }
        let out = data.assumingMemoryBound(to: UInt8.self)
        let bw = Int(bounds.width), bh = Int(bounds.height), bx = Int(bounds.minX)
        // Core Image counts from the bottom: the bounds' top row is the picture's row h − maxY.
        let top = h - Int(bounds.maxY)
        for y in 0..<bh {
            for x in 0..<bw {
                let sx = bx + x, sy = top + y
                out[y * rowBytes + x] = sx >= 0 && sx < w && sy >= 0 && sy < h ? plane[sy * w + sx] : 0
            }
        }
    }
}

/// Pictures Bezzle cannot draw here: an SVG as a smart object's contents comes in as its pixels.
nonisolated final class NSImage: @unchecked Sendable {
    let size: CGSize = .zero
    init?(data: Data) { nil }
    func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: NSGraphicsContext?, hints: [String: Any]?) -> CGImage? { nil }
}

/// PDFs and Illustrator files as smart objects' contents: not drawn here, so they come in as their pixels.
nonisolated final class CGPDFDocument: @unchecked Sendable {
    init?(_ provider: CGDataProvider) { nil }
    func page(at number: Int) -> CGPDFPage? { nil }
}

nonisolated final class CGPDFPage: @unchecked Sendable {
    func getBoxRect(_ box: CGPDFBox) -> CGRect { .zero }
}

nonisolated enum CGPDFBox: Int32, Sendable {
    case mediaBox, cropBox, bleedBox, trimBox, artBox
}

nonisolated extension CGContext {
    func drawPDFPage(_ page: CGPDFPage) {}
}

// MARK: - Fonts and text, as Sketch's texts are read

nonisolated extension Fonts {
    /// A four-letter tag as the number fonts keep it.
    static func tag(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    /// The font a style sets its words in, as the Mac's Fonts.font gives it.
    static func font(_ style: TextStyle) -> NSFont {
        NSFont(family: style.family, face: style.face, size: style.size)
    }
}

/// A font among the open fonts that stand in for the Mac's, found by its PostScript name as the
/// Mac finds an installed one.
nonisolated final class NSFont: @unchecked Sendable {
    let familyName: String?
    let face: String
    let fontName: String
    let pointSize: CGFloat

    init(family: String, face: String, size: CGFloat) {
        familyName = family
        self.face = face
        fontName = Self.postscript(family, face)
        pointSize = size
    }

    init?(name: String, size: CGFloat) {
        guard let (family, face) = Self.named(name) else { return nil }
        familyName = family
        self.face = face
        fontName = name
        pointSize = size
    }

    /// A font named in a file that is not here, which keeps its name (KeyedArchives.swift).
    init(postscriptName name: String, size: CGFloat) {
        familyName = nil
        face = "Regular"
        fontName = name
        pointSize = size
    }

    var fontDescriptor: NSFontDescriptor { NSFontDescriptor(postscriptName: fontName, pointSize: pointSize) }

    /// The PostScript name the Mac's font of this family and face has, as most are made:
    /// "HelveticaNeue-Medium", "AvenirNext-DemiBold".
    static func postscript(_ family: String, _ face: String) -> String {
        let f = family.replacingOccurrences(of: " ", with: ""), s = face.replacingOccurrences(of: " ", with: "")
        return s == "Regular" ? f : "\(f)-\(s)"
    }

    /// Mac fonts whose PostScript names are not made from their family and face.
    private static let unlike: [String: (String, String)] = [
        "ArialMT": ("Arial", "Regular"), "Arial-BoldMT": ("Arial", "Bold"), "Arial-ItalicMT": ("Arial", "Italic"),
        "Arial-BoldItalicMT": ("Arial", "Bold Italic"),
        "TimesNewRomanPSMT": ("Times New Roman", "Regular"), "TimesNewRomanPS-BoldMT": ("Times New Roman", "Bold"),
        "TimesNewRomanPS-ItalicMT": ("Times New Roman", "Italic"), "TimesNewRomanPS-BoldItalicMT": ("Times New Roman", "Bold Italic"),
        "CourierNewPSMT": ("Courier New", "Regular"), "CourierNewPS-BoldMT": ("Courier New", "Bold"),
        "CourierNewPS-ItalicMT": ("Courier New", "Italic"), "CourierNewPS-BoldItalicMT": ("Courier New", "Bold Italic"),
        "Times-Roman": ("Times", "Regular"), "Times-Bold": ("Times", "Bold"), "Times-Italic": ("Times", "Italic"),
        "Times-BoldItalic": ("Times", "Bold Italic"), "Helvetica": ("Helvetica", "Regular"),
        "Avenir-Roman": ("Avenir", "Roman"), "Didot": ("Didot", "Regular"),
        "BodoniSvtyTwoITCTT-Book": ("Bodoni 72", "Book"), "BodoniSvtyTwoITCTT-BookIta": ("Bodoni 72", "Book Italic"),
        "BodoniSvtyTwoITCTT-Bold": ("Bodoni 72", "Bold"), "Futura-CondensedMedium": ("Futura", "Condensed Medium"),
        "Futura-CondensedExtraBold": ("Futura", "Condensed ExtraBold"), "Georgia": ("Georgia", "Regular"),
    ]

    nonisolated(unsafe) private static var byName: [String: (String, String)]?

    static func named(_ name: String) -> (String, String)? {
        if let found = unlike[name] { return found }
        if byName == nil {
            var all: [String: (String, String)] = [:]
            for (family, faces) in NSFontManager.shared.families {
                for face in faces { all[postscript(family, face)] = (family, face) }
            }
            byName = all
        }
        return byName?[name]
    }
}

nonisolated final class NSFontDescriptor: @unchecked Sendable {
    let postscriptName: String?
    let pointSize: CGFloat
    init(postscriptName: String?, pointSize: CGFloat) {
        self.postscriptName = postscriptName
        self.pointSize = pointSize
    }
}

nonisolated enum NSTextAlignment: Int, Sendable {
    case left = 0, center = 1, right = 2, justified = 3, natural = 4
}

nonisolated final class NSParagraphStyle: @unchecked Sendable {
    var alignment: NSTextAlignment = .natural
    var maximumLineHeight: CGFloat = 0
    var minimumLineHeight: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
}

nonisolated extension NSAttributedString.Key {
    static let font = NSAttributedString.Key("NSFont")
    static let foregroundColor = NSAttributedString.Key("NSColor")
    static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    static let kern = NSAttributedString.Key("NSKern")
    static let underlineStyle = NSAttributedString.Key("NSUnderline")
    static let strikethroughStyle = NSAttributedString.Key("NSStrikethrough")
    static let baselineOffset = NSAttributedString.Key("NSBaselineOffset")
}

nonisolated extension NSColor {
    /// A Display P3 colour, as the sRGB colour it is, held to what sRGB can show.
    convenience init(displayP3Red r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func curved(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let lr = linear(Double(r)), lg = linear(Double(g)), lb = linear(Double(b))
        let sr = 1.2249401 * lr - 0.2249404 * lg
        let sg = -0.0420569 * lr + 1.0420571 * lg
        let sb = -0.0196376 * lr - 0.0786361 * lg + 1.0982735 * lb
        func held(_ v: Double) -> CGFloat { CGFloat(min(max(curved(min(max(v, 0), 1)), 0), 1)) }
        self.init(srgbRed: held(sr), green: held(sg), blue: held(sb), alpha: a)
    }
}

// Core Text's names for a font's features (CTFontCopyFeatures), which Sketch keeps them by.
nonisolated let kCTFontFeatureTypeIdentifierKey: CFString = "CTFeatureTypeIdentifier"
nonisolated let kCTFontFeatureTypeSelectorsKey: CFString = "CTFeatureTypeSelectors"
nonisolated let kCTFontFeatureSelectorIdentifierKey: CFString = "CTFeatureSelectorIdentifier"
nonisolated let kCTFontOpenTypeFeatureTag: CFString = "CTFeatureOpenTypeTag"
nonisolated let kCTFontOpenTypeFeatureValue: CFString = "CTFeatureOpenTypeValue"

/// A font's features as Core Text lists them, by Apple's feature types and selectors, each with
/// the OpenType tag it turns on: those of the font's own features that Apple's types name.
func CTFontCopyFeatures(_ font: NSFont) -> CFArray? {
    var style = TextStyle()
    style.family = font.familyName ?? TextStyle.system
    style.face = font.face
    let own = Set(Fonts.features(of: style).map(\.tag))
    var types: [Int: [[String: Any]]] = [:]
    for (type, selector, tag, value) in AppleFeatures.all where own.contains(tag) {
        types[type, default: []].append([kCTFontFeatureSelectorIdentifierKey: selector, kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: value])
    }
    return types.keys.sorted().map { [kCTFontFeatureTypeIdentifierKey: $0, kCTFontFeatureTypeSelectorsKey: types[$0]!] as [String: Any] }
}

/// Apple's feature types and selectors (SFNTLayoutTypes.h) and the OpenType features they are.
private enum AppleFeatures {
    static let all: [(Int, Int, String, Int)] = {
        var out: [(Int, Int, String, Int)] = [
            (1, 0, "rlig", 1), (1, 1, "rlig", 0), (1, 2, "liga", 1), (1, 3, "liga", 0), (1, 4, "dlig", 1), (1, 5, "dlig", 0),
            (1, 18, "clig", 1), (1, 19, "clig", 0), (1, 20, "hlig", 1), (1, 21, "hlig", 0),
            (6, 0, "tnum", 1), (6, 1, "pnum", 1),
            (10, 1, "sups", 1), (10, 2, "subs", 1), (10, 3, "ordn", 1), (10, 4, "sinf", 1),
            (11, 1, "afrc", 1), (11, 2, "frac", 1),
            (14, 4, "zero", 1), (14, 5, "zero", 0),
            (21, 0, "onum", 1), (21, 1, "lnum", 1),
            (33, 0, "case", 1), (33, 1, "case", 0), (33, 2, "cpsp", 1), (33, 3, "cpsp", 0),
            (36, 0, "calt", 1), (36, 1, "calt", 0), (36, 2, "swsh", 1), (36, 3, "swsh", 0), (36, 4, "cswh", 1), (36, 5, "cswh", 0),
            (37, 1, "smcp", 1), (37, 2, "pcap", 1),
            (38, 1, "c2sc", 1), (38, 2, "c2pc", 1),
        ]
        // Stylistic sets: one on, two off, for each of twenty.
        for n in 1...20 {
            let tag = String(format: "ss%02d", n)
            out.append((35, 2 * n, tag, 1))
            out.append((35, 2 * n + 1, tag, 0))
        }
        return out
    }()
}

extension TextLayout {
    /// The text last asked for as an attributed string, which a `Laid` made of it sets.
    nonisolated(unsafe) static var attributedNode: Node?

    /// A text's words, standing in for the Mac's attributed string: only the Sketch importer asks,
    /// to lay it out again (`Laid.init(_:font:width:)`).
    static func attributed(_ node: Node) -> NSAttributedString {
        attributedNode = node
        return NSAttributedString(string: node.runs.map(\.text).joined())
    }
}

extension TextLayout.Laid {
    /// The text last asked for as an attributed string, laid out as Text Kit lays it without
    /// Bezzle's own lift of the letters in lines set further apart than the font's.
    convenience init(_ text: NSAttributedString, font: NSFont, width: CGFloat) {
        guard var node = TextLayout.attributedNode else {
            self.init(id: 0, lines: [], usedSize: .zero, string: text.string)
            return
        }
        node.frame.size.width = width
        let laid = TextLayout.layout(node)
        let style = node.style ?? TextStyle()
        var lift: CGFloat = 0
        if let spacing = style.lineSpacing, spacing > 0 { lift = max((spacing - Fonts.naturalLineHeight(style)) / 2, 0) }
        let lines = laid.lines.map { line in
            var l = line
            l.baseline += lift
            return l
        }
        self.init(id: laid.id, lines: lines, usedSize: laid.usedSize, string: laid.string)
    }

    /// Where its lines lie, as Text Kit's layout manager says.
    var manager: LaidLines { LaidLines(lines: lines) }
}

/// The lines of a laid text, asked as Text Kit's layout manager is.
struct LaidLines {
    let lines: [TextLayout.Line]

    func lineFragmentRect(forGlyphAt glyph: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> CGRect {
        guard let line = lines.first(where: { glyph < $0.end }) ?? lines.last else { return .zero }
        return CGRect(x: 0, y: line.top, width: line.width, height: line.height)
    }

    func location(forGlyphAt glyph: Int) -> CGPoint {
        guard let line = lines.first(where: { glyph < $0.end }) ?? lines.last else { return .zero }
        return CGPoint(x: 0, y: line.baseline - line.top)
    }
}
