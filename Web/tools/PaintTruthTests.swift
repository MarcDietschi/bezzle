import Testing
import AppKit
@testable import Bezzle

/// Letters painted with gradients and pictures, and justified text, as the Mac draws and sets
/// them, for comparing with the Windows core and the browser (Web/Sources/BezzleCore/Web/WebText.swift):
/// a design (`Paints.bezzle`, with a photo and a picture of stripes in its images) of painted
/// texts (linear and radial gradients, pictures covering and fitting, letters of a colour of
/// their own among painted ones, lines under and through them, list markers, centred lines,
/// faded layers) and justified paragraphs (several fonts and sizes, lines too wide for their
/// spaces, a word longer than its line, letters spaced apart, line separators, double and
/// non-breaking spaces, a list, painted and justified at once); each text's lines and where
/// each of its letters is set along them; each artboard drawn at 2×; and each exported as the
/// Export sheet exports it (PNG at 2×, JPEG, PDF, SVG). Like WebTruthTests, run from an archived
/// copy of the tree with this file put into BezzleTests, never added to the real test target,
/// with PAINT_TRUTH_OUT a folder; then bezzle-render draws, measures and exports the same design
/// (BEZZLE_TEXTS with BEZZLE_TEXTS_PROBES=0 and BEZZLE_TEXTS_LETTERS=1; BEZZLE_EXPORT), and
/// paint-compare.mjs compares the three.
struct PaintTruthTests {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAINT_TRUTH_OUT"] ?? "/tmp/paint-truth")

    static func text(_ runs: [TextSpan], family: String = "Helvetica", face: String = "Regular", size: CGFloat = 16,
                     sizing: TextSizing = .autoWidth, width: CGFloat = 10, align: TextAlign = .left, tracking: CGFloat = 0,
                     lineSpacing: CGFloat? = nil, paragraphSpacing: CGFloat? = nil, color: RGBA = RGBA(r: 0.1, g: 0.12, b: 0.2),
                     name: String, at: CGPoint) -> Node {
        var n = Node(kind: .text, name: name, frame: CGRect(origin: at, size: CGSize(width: width, height: 10)))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.sizing = sizing
        s.align = align
        s.tracking = tracking
        s.lineSpacing = lineSpacing
        s.paragraphSpacing = paragraphSpacing
        n.style = s
        n.fill.color = color
        n.setRuns(runs)
        n.refit()
        return n
    }

    static func words(_ s: String) -> [TextSpan] { [TextSpan(text: s)] }

    static let warm = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.98, g: 0.45, b: 0.15)),
                                                      GradientStop(offset: 0.5, color: RGBA(r: 0.85, g: 0.15, b: 0.55)),
                                                      GradientStop(offset: 1, color: RGBA(r: 0.2, g: 0.35, b: 0.95))],
                               start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
    static let sky = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.1, g: 0.6, b: 0.9)),
                                                     GradientStop(offset: 1, color: RGBA(r: 0.1, g: 0.75, b: 0.35))],
                              start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
    static let glow = Gradient(kind: .radial, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 0.85, b: 0.1)),
                                                      GradientStop(offset: 1, color: RGBA(r: 0.75, g: 0.1, b: 0.1))],
                               start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1, y: 0.5))
    static let photo = "lake.jpg", stripes = "stripes.png"
    static let stripesSize = CGSize(width: 600, height: 300)

    /// A picture of coloured stripes across and a light falling down it, so where a picture is
    /// placed shows in the colours its letters take.
    static func stripesPNG() -> Data? {
        let w = Int(stripesSize.width), h = Int(stripesSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.95, 0.6, 0.1), (0.2, 0.7, 0.3), (0.1, 0.5, 0.9), (0.5, 0.2, 0.8), (0.1, 0.1, 0.1)]
        for (k, c) in colors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(k) * stripesSize.width / CGFloat(colors.count), y: 0, width: stripesSize.width / CGFloat(colors.count), height: stripesSize.height))
        }
        // Lighter at the top (CG's y runs up).
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: stripesSize.height), end: CGPoint(x: 0, y: 0), options: [])
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func board(_ name: String, x: CGFloat, height: CGFloat, _ texts: [Node]) -> Node {
        var b = Node(kind: .artboard, name: name, frame: CGRect(x: x, y: 0, width: 720, height: height))
        b.children = texts
        return b
    }

    static let prose = "Design is not just what it looks like and feels like. Design is how it works, and how each part of a page holds the next one in place.\nA second paragraph follows the first, so that the last line of each is left as it is."
    static let craft = "Typography is the craft of endowing human language with a durable visual form, and thus with an independent existence. Its heartwood is calligraphy."

    static func design() -> BezzleDocument {
        var gradient = text(words("Gradient"), face: "Bold", size: 64, name: "linear", at: CGPoint(x: 30, y: 30))
        gradient.fill.gradient = warm
        var radial = text(words("Radial"), family: "Georgia", face: "Bold", size: 64, name: "radial", at: CGPoint(x: 380, y: 30))
        radial.fill.gradient = glow
        var lake = text(words("Lake"), family: "Georgia", face: "Bold", size: 96, name: "photo", at: CGPoint(x: 30, y: 120))
        lake.fill.image = ImageFill(asset: photo, mode: .cover, size: WelcomePhoto.size)
        var striped = text(words("Stripes"), face: "Bold", size: 72, name: "stripes", at: CGPoint(x: 330, y: 130))
        striped.fill.image = ImageFill(asset: stripes, mode: .cover, size: stripesSize)
        let blue = RGBA(r: 0.1, g: 0.3, b: 0.9)
        var mixed = text([TextSpan(text: "Own "), TextSpan(text: "colour", look: TextLook(color: blue)), TextSpan(text: " among "),
                          TextSpan(text: "painted", look: TextLook(underline: true)), TextSpan(text: " and "),
                          TextSpan(text: "struck", look: TextLook(strikethrough: true)), TextSpan(text: " letters", look: TextLook(color: RGBA(r: 0.1, g: 0.6, b: 0.2), underline: true))],
                         face: "Bold", size: 30, name: "own colours", at: CGPoint(x: 30, y: 260))
        mixed.fill.gradient = warm
        var list = text([TextSpan(text: "Painted item\n", look: TextLook(list: .bullet)), TextSpan(text: "Blue item\n", look: TextLook(color: blue, list: .bullet)),
                         TextSpan(text: "Numbered\n", look: TextLook(list: .number)), TextSpan(text: "And on", look: TextLook(list: .number))],
                        size: 22, name: "list", at: CGPoint(x: 30, y: 320))
        list.fill.gradient = sky
        var centred = text(words("Centred lines of painted words that wrap over three lines or so"), family: "Georgia", size: 24,
                           sizing: .autoHeight, width: 300, align: .center, name: "centred", at: CGPoint(x: 370, y: 320))
        centred.fill.gradient = warm
        var fit = text(words("Fitted picture"), face: "Bold", size: 40, name: "fit", at: CGPoint(x: 30, y: 500))
        fit.fill.image = ImageFill(asset: stripes, mode: .fit, size: stripesSize)
        var faded = text(words("Faded"), face: "Bold", size: 56, name: "faded", at: CGPoint(x: 400, y: 480))
        faded.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.1, g: 0.2, b: 0.8, a: 1)),
                                                              GradientStop(offset: 1, color: RGBA(r: 0.9, g: 0.1, b: 0.3, a: 0.4))],
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        faded.opacity = 0.7
        var system = text(words("System painted text set in two lines here"), face: "Semibold", size: 28, sizing: .autoHeight, width: 330,
                          name: "system", at: CGPoint(x: 30, y: 580))
        system.style?.family = TextStyle.system
        system.refit()
        system.fill.image = ImageFill(asset: photo, mode: .cover, size: WelcomePhoto.size)
        var paragraph = text(words(craft), family: "Georgia", size: 15, sizing: .autoHeight, width: 300, align: .justify,
                             name: "painted justified", at: CGPoint(x: 390, y: 580))
        paragraph.fill.gradient = sky

        let painted = board("Painted", x: 0, height: 760, [gradient, radial, lake, striped, mixed, list, centred, fit, faded, system, paragraph])

        let j = TextAlign.justify
        var spaced = text(words(craft), family: "Georgia", size: 16, sizing: .autoHeight, width: 300, align: j, tracking: 50,
                          name: "spaced", at: CGPoint(x: 380, y: 520))
        spaced.fill.color = RGBA(r: 0.3, g: 0.1, b: 0.1)
        let justified = board("Justified", x: 780, height: 1180, [
            text(words(prose), sizing: .autoHeight, width: 260, align: j, name: "helvetica 16", at: CGPoint(x: 30, y: 30)),
            text(words(prose), family: "Georgia", size: 18, sizing: .autoHeight, width: 300, align: j, name: "georgia 18", at: CGPoint(x: 380, y: 30)),
            text(words(craft), family: "Arial", size: 15, sizing: .autoHeight, width: 220, align: j, name: "arial 15", at: CGPoint(x: 30, y: 290)),
            text(words("Lines  with double  spaces and\u{a0}one that\u{a0}does not break, then a line\u{2028}broken by hand, and more words after it to wrap."),
                 family: TextStyle.system, size: 14, sizing: .autoHeight, width: 240, align: j, name: "spaces", at: CGPoint(x: 290, y: 290)),
            text(words("Few words in a narrow column spread far apart at times"), size: 24, sizing: .autoHeight, width: 150, align: j,
                 name: "narrow", at: CGPoint(x: 560, y: 290)),
            text(words("Supercalifragilisticexpialidocious is a word longer than its line"), size: 20, sizing: .autoHeight, width: 150, align: j,
                 name: "long word", at: CGPoint(x: 30, y: 520)),
            text([TextSpan(text: "Mixed sizes of "), TextSpan(text: "letters", look: TextLook(size: 26)), TextSpan(text: " on lines that are set "),
                  TextSpan(text: "justified", look: TextLook(color: RGBA(r: 0.8, g: 0.2, b: 0.1))), TextSpan(text: " across the width they have.")],
                 family: "Georgia", size: 17, sizing: .autoHeight, width: 170, align: j, name: "mixed", at: CGPoint(x: 200, y: 520)),
            spaced,
            text([TextSpan(text: "A bullet item that runs long enough to wrap over several lines\n", look: TextLook(list: .bullet)),
                  TextSpan(text: "Then a numbered one that wraps over its lines too", look: TextLook(list: .number))],
                 size: 16, sizing: .autoHeight, width: 300, align: j, name: "list", at: CGPoint(x: 30, y: 760)),
            text(words(prose), family: "Georgia", size: 15, sizing: .fixed, width: 300, align: j, lineSpacing: 24, paragraphSpacing: 12,
                 name: "spaced lines", at: CGPoint(x: 380, y: 760)),
            text(words(craft), family: TextStyle.system, size: 13, sizing: .autoHeight, width: 300, align: j, name: "system 13", at: CGPoint(x: 30, y: 960)),
        ])
        // Justified lines in the cases Text Kit spreads by rules of their own: several sizes on a
        // line, spaces together while letters are spread too, tabs, Courier (whose font says how
        // it is spread), and words read from right to left.
        func sized(_ parts: [(String, CGFloat)]) -> [TextSpan] { parts.map { TextSpan(text: $0.0, look: TextLook(size: $0.1)) } }
        let cases = board("Cases", x: 1560, height: 1240, [
            text(sized([("Tiny ", 11), ("HUGE ", 30), ("words ", 11), ("mixed ", 20), ("in ", 11), ("one ", 30), ("narrow ", 11), ("column ", 20),
                        ("of type that ", 11), ("wraps ", 26), ("over many lines.", 11)]),
                 size: 11, sizing: .autoHeight, width: 160, align: j, name: "mixed helvetica", at: CGPoint(x: 30, y: 30)),
            text(sized([("A ", 15), ("Capital ", 32), ("start, then words ", 15), ("of the size ", 22), ("of the rest of the ", 15), ("paragraph ", 28),
                        ("that wraps on and on to the end.", 15)]),
                 family: "Georgia", size: 15, sizing: .autoHeight, width: 190, align: j, name: "mixed georgia", at: CGPoint(x: 220, y: 30)),
            text(words("Hi  extraordinarily marvellous an  unbelievably wonderful of  typographically experimental to  the end of it all."),
                 sizing: .autoHeight, width: 190, align: j, name: "double spaces", at: CGPoint(x: 440, y: 30)),
            text(words("Few  words  in a  narrow  column  spread  far  apart  over  lines"), size: 24, sizing: .autoHeight, width: 150, align: j,
                 name: "double narrow", at: CGPoint(x: 30, y: 300)),
            text(words("Name\tA value that runs on for a while and wraps\tthen more words after a second tab that wrap again over lines."),
                 size: 15, sizing: .autoHeight, width: 300, align: j, name: "tabs", at: CGPoint(x: 220, y: 300)),
            text(words("Price\tUnbelievable\tExtraordinarily\tand then more words to wrap"), sizing: .autoHeight, width: 200, align: j,
                 name: "tab letters", at: CGPoint(x: 220, y: 420)),
            text(words(prose), family: "Courier", size: 15, sizing: .autoHeight, width: 260, align: j, name: "courier", at: CGPoint(x: 30, y: 560)),
            text(words("A  narrow column of Courier words that spread  apart over lines"), family: "Courier", size: 14, sizing: .autoHeight,
                 width: 150, align: j, name: "courier narrow", at: CGPoint(x: 330, y: 560)),
            text(words("Unbelievably extraordinary words"), family: "Courier", size: 14, sizing: .autoHeight, width: 120, align: j,
                 name: "courier word", at: CGPoint(x: 520, y: 560)),
            text(words("שלום עולם, זה טקסט בעברית שמיושר לשני הצדדים כדי לבדוק איך הוא מתפרש על פני השורות השונות של הפסקה."),
                 family: "Arial", sizing: .autoHeight, width: 220, align: j, name: "hebrew", at: CGPoint(x: 30, y: 940)),
            text(words("هذا نص عربي مضبوط من الجانبين لكي نرى كيف يتوزع على السطور المختلفة في الفقرة الواحدة."),
                 family: "Arial", sizing: .autoHeight, width: 220, align: j, name: "arabic", at: CGPoint(x: 290, y: 940)),
            // Set from the left, for where tabs stop and which way lines read without spreading.
            text(words("Name\tA value that runs on for a while and wraps\tthen more words after a second tab that wrap again over lines."),
                 size: 15, sizing: .autoHeight, width: 300, name: "tabs left", at: CGPoint(x: 30, y: 1080)),
            text(words("שלום עולם, זה טקסט בעברית שמיושר לשני הצדדים כדי לבדוק איך הוא מתפרש על פני השורות השונות של הפסקה."),
                 family: "Arial", sizing: .autoHeight, width: 220, name: "hebrew left", at: CGPoint(x: 380, y: 1080)),
        ])
        var doc = BezzleDocument()
        doc.nodes = [painted, justified, cases]
        // The box of fixed size as tall as its lines.
        if let k = doc.nodes[1].children.firstIndex(where: { $0.name == "spaced lines" }) {
            doc.nodes[1].children[k].frame.size.height = ceil(TextLayout.layout(doc.nodes[1].children[k]).usedSize.height)
        }
        return doc
    }

    @Test func dumpPaints() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let doc = Self.design()
        let url = Self.out.appendingPathComponent("Paints.bezzle")
        try? FileManager.default.removeItem(at: url)
        try DesignFile.write(doc, to: url)
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try #require(WelcomePhoto.jpeg()).write(to: images.appendingPathComponent(Self.photo))
        try #require(Self.stripesPNG()).write(to: images.appendingPathComponent(Self.stripes))
        let assets = Assets(design: url)
        var texts: [[String: Any]] = []
        for board in doc.nodes {
            for n in board.children where n.kind == .text {
                var d = describe(n)
                d["key"] = "Paints/\(n.id.uuidString)"
                d["board"] = board.name
                d["name"] = n.name
                d["origin"] = [Double(board.frame.minX), Double(board.frame.minY)]
                texts.append(d)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": texts], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.out.appendingPathComponent("paints-mac.json"))
        let png = Self.out.appendingPathComponent("png")
        try FileManager.default.createDirectory(at: png, withIntermediateDirectories: true)
        for (i, board) in doc.nodes.enumerated() {
            guard let image = Renderer.image(of: board, scale: 2, assets: assets) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: png.appendingPathComponent(String(format: "Paints-%02d.png", i)))
        }
        // As the Export sheet exports each artboard.
        let exports = Self.out.appendingPathComponent("export")
        try? FileManager.default.removeItem(at: exports)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        for board in doc.nodes {
            let item = ExportItem(artboard: board)
            for (format, scale) in [(ExportFormat.png, 2.0), (.jpeg, 2), (.pdf, 1), (.svg, 1)] as [(ExportFormat, CGFloat)] {
                Exporter.export([item], format: format, scale: scale, name: board.name, to: exports, replacing: true, assets: assets)
            }
        }
    }

    /// A text's lines, with where each of its letters is set along them, from the text's left.
    private func describe(_ n: Node) -> [String: Any] {
        let laid = TextLayout.layout(n)
        let manager = laid.manager
        var lines: [[Double]] = []
        var letters: [[[Double]]] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let place = manager.location(forGlyphAt: glyphs.location)
            lines.append([Double(chars.location), Double(NSMaxRange(chars)), Double(rect.minY), Double(rect.height), Double(used.width),
                          Double(rect.minY + place.y), Double(used.minX), Double(rect.minX + place.x)])
            var xs: [[Double]] = []
            for g in glyphs.location..<NSMaxRange(glyphs) {
                guard !manager.propertyForGlyph(at: g).contains(.null) else { continue }
                xs.append([Double(manager.characterIndexForGlyph(at: g)), Double(rect.minX + manager.location(forGlyphAt: g).x)])
            }
            letters.append(xs)
        }
        let markers = TextLayout.markers(manager).map { [$0.text, Double($0.at.x), Double($0.at.y), Double($0.font.pointSize)] as [Any] }
        let fitted = TextLayout.fittedFrame(n)
        return [
            "text": laid.storage.string, "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height],
            "used": [laid.usedSize.width, laid.usedSize.height], "natural": TextLayout.naturalWidth(n),
            "firstBaseline": TextLayout.firstBaseline(n), "fitted": [fitted.width, fitted.height],
            "lines": lines, "letters": letters, "markers": markers, "align": (n.style ?? TextStyle()).align.rawValue,
            "painted": n.fill.paints, "offset": TextLayout.offset(n),
        ]
    }
}
