import Testing
import AppKit
@testable import Bezzle

/// Text Kit's measures of the sample designs' texts and of probe texts in every family the open
/// fonts stand in for, to compare with what the Windows core makes of them
/// (Windows/Sources/BezzleCore/Host/TextReport.swift, through bezzle-render's BEZZLE_TEXTS and
/// BEZZLE_INK). Like WebTruthTests, run from an archived copy of the tree with this file put into
/// BezzleTests, never added to the real test target; then text-compare.py compares, and
/// text-table.py makes the tables of Web/Sources/BezzleCore/Web/MacFonts.swift again.
struct TextMeasureTests {
    /// Where the measures go (TEXT_MEASURE_OUT, a folder), and the designs measured
    /// (TEXT_MEASURE_DESIGNS): the App Store's sample designs unless said.
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXT_MEASURE_OUT"] ?? "/tmp/text-measure")
    static let designs = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXT_MEASURE_DESIGNS"]
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppStore/screenshots-src/designs").path)

    static let families = ["System", "Avenir Next", "Avenir", "Futura", "Bodoni 72", "Helvetica Neue", "Helvetica", "Arial",
                           "Times New Roman", "Times", "Georgia", "Courier New", "Courier", "Menlo", "Didot", "Baskerville"]
    static let sizes: [CGFloat] = [9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 40, 48, 64, 72, 96, 132]
    static let probe = "Hamburgefonstiv Qxy"
    static let words = "The quick brown fox jumps over the lazy dog 0123456789"

    static func text(_ words: String, family: String, face: String, size: CGFloat, lineSpacing: CGFloat? = nil,
                     spans: [TextSpan]? = nil, tracking: CGFloat = 0) -> Node {
        var n = Node(kind: .text, name: "probe", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.lineSpacing = lineSpacing
        s.tracking = tracking
        s.sizing = .autoWidth
        n.style = s
        n.text = words
        n.spans = spans
        n.refit()
        return n
    }

    @Test func dumpTextMeasures() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let out = Self.out.appendingPathComponent("text-measure-mac.json"), designs = Self.designs
        var report: [String: Any] = [:]

        // The sample designs' texts.
        var samples: [[String: Any]] = []
        var decks: [String: Any] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: designs, includingPropertiesForKeys: nil)) ?? []
        for url in files.filter({ $0.pathExtension == "bezzle" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let doc = try DesignFile.read(url)
            let name = url.deletingPathExtension().lastPathComponent
            func walk(_ nodes: [Node]) {
                for n in nodes {
                    if n.kind == .text, n.curve == nil {
                        var d = describe(n)
                        d["design"] = name
                        d["key"] = "\(name)/\(n.id.uuidString)"
                        samples.append(d)
                    }
                    walk(n.children)
                    walk(n.mask ?? [])
                }
            }
            walk(doc.nodes)
            walk(doc.components ?? [])
            decks[name] = Self.decks(doc)
        }
        report["samples"] = samples
        report["decks"] = decks

        // Probes: one line, two lines, lines set apart, mixed sizes, a long line of words.
        var probes: [[String: Any]] = []
        for family in Self.families {
            let faces = Fonts.faces(of: family)
            for face in faces {
                for size in Self.sizes {
                    var d = describe(Self.text(Self.probe, family: family, face: face, size: size))
                    d["key"] = "one/\(family)/\(face)/\(size)"
                    let font = Fonts.font(Self.text("A", family: family, face: face, size: size).style!)
                    d["font"] = [font.ascender, font.descender, font.leading, font.capHeight, font.xHeight, font.pointSize]
                    d["fontName"] = font.fontName
                    probes.append(d)
                }
                var w = describe(Self.text(Self.words, family: family, face: face, size: 100))
                w["key"] = "words/\(family)/\(face)/100"
                probes.append(w)
            }
            let face = faces.first ?? "Regular"
            for size: CGFloat in [12, 16, 24, 40, 72] {
                var d = describe(Self.text("Hxg\nHxg\nHxg", family: family, face: face, size: size))
                d["key"] = "three/\(family)/\(face)/\(size)"
                probes.append(d)
                for k: CGFloat in [0.8, 1.0, 1.2, 1.5, 2.0] {
                    let spacing = (size * k).rounded()
                    var d = describe(Self.text("Hxg\nHxg\nHxg", family: family, face: face, size: size, lineSpacing: spacing))
                    d["key"] = "spaced/\(family)/\(face)/\(size)/\(spacing)"
                    probes.append(d)
                }
                let small = (size * 0.5).rounded()
                let spans = [TextSpan(text: "Big "), TextSpan(text: "small", look: TextLook(size: small))]
                var m = describe(Self.text("Big small", family: family, face: face, size: size, spans: spans))
                m["key"] = "mixed/\(family)/\(face)/\(size)/\(small)"
                probes.append(m)
                for tracking: CGFloat in [-20, 50] {
                    var t = describe(Self.text(Self.probe, family: family, face: face, size: size, tracking: tracking))
                    t["key"] = "tracked/\(family)/\(face)/\(size)/\(tracking)"
                    probes.append(t)
                }
            }
        }
        report["probes"] = probes

        // More probes: words for fitting widths, empty texts, paragraphs set apart, two families
        // on a line, and a fine sweep of sizes for the line's height; with each face's units.
        var extra: [String: Any] = [:]
        for (key, n) in Self.extraProbes(faces: { Fonts.faces(of: $0) }) {
            if key.hasPrefix("corpus/") {
                let laid = TextLayout.layout(n)
                var width = 0.0
                laid.manager.enumerateLineFragments(forGlyphRange: laid.manager.glyphRange(for: laid.container)) { _, used, _, _, _ in width = max(width, Double(used.width)) }
                extra[key] = [width, Double(TextLayout.naturalWidth(n))]
            } else if key.hasPrefix("fine/") {
                let d = describe(n)
                let line = (d["lines"] as? [[Double]])?.first ?? [0, 0, 0, 0, 0, 0]
                extra[key] = [line[3], line[5]]
            } else {
                extra[key] = describe(n)
            }
        }
        var units: [String: Any] = [:]
        for family in Self.families {
            for face in Fonts.faces(of: family) {
                let font = Fonts.font(Self.text("A", family: family, face: face, size: 1000).style!)
                let upem = Double(CTFontGetUnitsPerEm(font as CTFont))
                units["\(family)/\(face)"] = [upem, Double(CTFontGetAscent(font as CTFont)) * upem / 1000, Double(CTFontGetDescent(font as CTFont)) * upem / 1000,
                                              Double(CTFontGetLeading(font as CTFont)) * upem / 1000, Double(font.ascender), Double(font.descender), Double(font.leading)]
            }
        }
        extra["units"] = units
        report["extra"] = extra
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
    }

    /// Every artboard of the sample designs as the Mac draws it, at 2×, for comparing with bezzle-render.
    @Test func drawBoards() throws {
        let designs = Self.designs, out = Self.out.appendingPathComponent("png")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: designs, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "bezzle" {
            let doc = try DesignFile.read(url)
            let name = url.deletingPathExtension().lastPathComponent
            let assets = Assets(design: url)
            for (i, board) in doc.nodes.enumerated() where board.isArtboard {
                guard let image = Renderer.image(of: board, scale: 2, assets: assets) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(String(format: "%@-%02d.png", name, i)))
            }
        }
    }

    /// Where letters are drawn against their first baseline, as TextReport.inkReport on Windows.
    @Test func inkProbes() throws {
        var out: [String: Any] = [:]
        for family in Self.families {
            let face = Fonts.faces(of: family).first ?? "Regular"
            for k in 18...80 {
                let size = CGFloat(k) / 2
                var text = Self.text("HHHH", family: family, face: face, size: size)
                text.frame.origin = CGPoint(x: 10, y: 10)
                var board = Node(kind: .artboard, name: "ink", frame: CGRect(x: 0, y: 0, width: 400, height: size * 2 + 20))
                board.children = [text]
                guard let image = Renderer.image(of: board, scale: 4, assets: Assets(folder: nil)) else { continue }
                let w = image.width, h = image.height
                var px = [UInt8](repeating: 0, count: w * h * 4)
                let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                var top = -1, bottom = -1
                for y in 0..<h {
                    var darkest = 0
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        darkest = max(darkest, 255 - (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3)
                    }
                    if darkest >= 128 {
                        if top < 0 { top = y }
                        bottom = y + 1
                    }
                }
                out["\(family)/\(face)/\(size)"] = [Double(TextLayout.firstBaseline(text)), Double(top) / 4 - 10, Double(bottom) / 4 - 10]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try data.write(to: Self.out.appendingPathComponent("ink-mac.json"))
    }

    /// Each artboard made a deck with one more post, and which of its posts seem broken (words
    /// cut off or past the page): its texts as kept, and refitted to their words. The same in
    /// TextReport.swift.
    static func decks(_ doc: BezzleDocument) -> [String: [[Int]]] {
        func refitted(_ n: Node) -> Node {
            var n = n
            if n.kind == .text, n.curve == nil { n.refit() }
            n.children = n.children.map(refitted)
            return n
        }
        var out: [String: [[Int]]] = [:]
        for board in doc.nodes where board.isArtboard {
            var d = doc
            d.addPost(to: board.id, after: nil)
            guard let deck = d.nodes.first(where: { $0.id == board.id }) else { continue }
            out[board.name] = [Deck.broken(deck).sorted(), Deck.broken(refitted(deck)).sorted()]
        }
        return out
    }

    static let corpus = [
        "The quick brown fox jumps over the lazy dog.", "Pack my box with five dozen liquor jugs",
        "Discover places worth the trip", "Settings Profile Saved Explore", "Sign in with your email address",
        "0123456789 12.50 4.8 1,234 reviews", "Über Größe Straße Café naïve", "WANDER AUTUMN MENU ADOPTION DAY",
    ]

    /// The same on the Mac and in the Windows core's TextReport.swift.
    static func extraProbes(faces: (String) -> [String]) -> [(String, Node)] {
        var out: [(String, Node)] = []
        for family in families {
            let all = faces(family)
            for face in all {
                for size in sizes {
                    for (i, words) in corpus.enumerated() {
                        out.append(("corpus/\(i)/\(family)/\(face)/\(size)", text(words, family: family, face: face, size: size)))
                    }
                }
                for size: CGFloat in [12, 16, 24] {
                    out.append(("empty/\(family)/\(face)/\(size)", text("", family: family, face: face, size: size)))
                }
                for k in 40...400 {
                    let size = CGFloat(k) / 10
                    out.append(("fine/\(family)/\(face)/\(size)", text("Hxg", family: family, face: face, size: size)))
                }
            }
            let face = all.first ?? "Regular"
            for size: CGFloat in [12, 16, 24] {
                for after: CGFloat in [6, 10] {
                    for spacing: CGFloat in [0, (size * 1.5).rounded()] {
                        var n = text("Hxg\nHxg Hxg Hxg Hxg Hxg Hxg Hxg Hxg\n\nHxg", family: family, face: face, size: size,
                                     lineSpacing: spacing > 0 ? spacing : nil)
                        n.style?.paragraphSpacing = after
                        n.style?.sizing = .autoHeight
                        n.frame.size.width = size * 7
                        n.refit()
                        out.append(("paragraph/\(family)/\(face)/\(size)/\(after)/\(spacing)", n))
                    }
                }
                for (name, words) in [("trailing", "Hxg\n"), ("leading", "\nHxg"), ("both", "Hxg\nHxg\n")] {
                    var n = text(words, family: family, face: face, size: size)
                    n.style?.paragraphSpacing = 10
                    n.refit()
                    out.append(("edge/\(name)/\(family)/\(face)/\(size)", n))
                }
                let spans = [TextSpan(text: "Hxg "), TextSpan(text: "Hxg", look: TextLook(family: "Times", face: "Regular"))]
                out.append(("families/\(family)/\(face)/\(size)", text("Hxg Hxg", family: family, face: face, size: size, spans: spans)))
            }
        }
        return out
    }

    private func describe(_ n: Node) -> [String: Any] {
        let laid = TextLayout.layout(n)
        let manager = laid.manager
        var lines: [[Double]] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let baseline = rect.minY + manager.location(forGlyphAt: glyphs.location).y
            lines.append([Double(chars.location), Double(NSMaxRange(chars)), Double(rect.minY), Double(rect.height), Double(used.width), Double(baseline)])
        }
        let style = n.style ?? TextStyle()
        var refit = n
        refit.refit()
        let fitted = TextLayout.fittedFrame(n)
        return [
            "name": n.name, "text": laid.storage.string,
            "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height],
            "family": style.family, "face": style.face, "size": style.size, "sizing": "\(style.sizing)",
            "lineSpacing": style.lineSpacing ?? 0, "tracking": style.tracking, "align": style.align.rawValue,
            "spans": n.spans?.count ?? 0,
            "used": [laid.usedSize.width, laid.usedSize.height],
            "natural": TextLayout.naturalWidth(n), "firstBaseline": TextLayout.firstBaseline(n),
            "fitted": [fitted.width, fitted.height],
            "refit": [refit.frame.minX, refit.frame.minY, refit.frame.width, refit.frame.height],
            "heightAtWidth": TextLayout.height(n, width: n.frame.width),
            "naturalLineHeight": Fonts.naturalLineHeight(style),
            "lines": lines,
        ]
    }
}
