import Foundation
import AppKit

// How the core measures text here, for comparing with Text Kit on the Mac: the open design's
// texts and probe texts in every family the open fonts stand in for, each with its lines (start,
// end, top, height, width, baseline), its used and natural size, first baseline and fitted frame.
// bezzle-render writes it with BEZZLE_TEXTS=<file>; the Mac's side is Web/tools/TextMeasureTests.swift,
// which walks the same texts with the same probes and writes the same keys, and
// Web/tools/text-compare.py compares the two.

extension WindowsCore {
    static let reportFamilies = ["System", "Avenir Next", "Avenir", "Futura", "Bodoni 72", "Helvetica Neue", "Helvetica", "Arial",
                                 "Times New Roman", "Times", "Georgia", "Courier New", "Courier", "Menlo", "Didot", "Baskerville"]
    static let reportSizes: [CGFloat] = [9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 40, 48, 64, 72, 96, 132]

    private static func probe(_ words: String, family: String, face: String, size: CGFloat, lineSpacing: CGFloat? = nil,
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

    /// The report as JSON: the open design's texts under "samples" (keyed by `design` and each
    /// text's id), the probes under "probes" and "extra", and under "decks" which posts seem
    /// broken when each artboard is made a deck.
    public static func textReport(design name: String) -> String {
        // With BEZZLE_TEXTS_PLAIN=1, the stand-ins as wide as they are, for fitting MacFonts' spacings.
        if ProcessInfo.processInfo.environment["BEZZLE_TEXTS_PLAIN"] == "1" {
            MacFonts.standIns = []
            TextLayout.forget()
        }
        var samples: [[String: Any]] = []
        var decks: [String: Any] = [:]
        if let doc = design {
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
            decks[name] = reportDecks(doc)
        }
        var probes: [[String: Any]] = []
        let one = "Hamburgefonstiv Qxy", words = "The quick brown fox jumps over the lazy dog 0123456789"
        if ProcessInfo.processInfo.environment["BEZZLE_TEXTS_PROBES"] != "0" {
            for family in reportFamilies {
                let faces = Fonts.faces(of: family)
                for face in faces {
                    for size in reportSizes {
                        var d = describe(probe(one, family: family, face: face, size: size))
                        d["key"] = "one/\(family)/\(face)/\(size)"
                        d["host"] = hostLines(probe("A", family: family, face: face, size: size))
                        probes.append(d)
                    }
                    var w = describe(probe(words, family: family, face: face, size: 100))
                    w["key"] = "words/\(family)/\(face)/100"
                    probes.append(w)
                }
                let face = faces.first ?? "Regular"
                for size: CGFloat in [12, 16, 24, 40, 72] {
                    var d = describe(probe("Hxg\nHxg\nHxg", family: family, face: face, size: size))
                    d["key"] = "three/\(family)/\(face)/\(size)"
                    probes.append(d)
                    for k: CGFloat in [0.8, 1.0, 1.2, 1.5, 2.0] {
                        let spacing = (size * k).rounded()
                        var d = describe(probe("Hxg\nHxg\nHxg", family: family, face: face, size: size, lineSpacing: spacing))
                        d["key"] = "spaced/\(family)/\(face)/\(size)/\(spacing)"
                        probes.append(d)
                    }
                    let small = (size * 0.5).rounded()
                    let spans = [TextSpan(text: "Big "), TextSpan(text: "small", look: TextLook(size: small))]
                    var m = describe(probe("Big small", family: family, face: face, size: size, spans: spans))
                    m["key"] = "mixed/\(family)/\(face)/\(size)/\(small)"
                    probes.append(m)
                    for tracking: CGFloat in [-20, 50] {
                        var t = describe(probe(one, family: family, face: face, size: size, tracking: tracking))
                        t["key"] = "tracked/\(family)/\(face)/\(size)/\(tracking)"
                        probes.append(t)
                    }
                }
            }
        }
        var extra: [String: Any] = [:]
        if ProcessInfo.processInfo.environment["BEZZLE_TEXTS_PROBES"] != "0" {
            for (key, n) in extraProbes() {
                if key.hasPrefix("corpus/") {
                    extra[key] = [Double(TextLayout.layout(n).lines.map(\.width).max() ?? 0), Double(TextLayout.naturalWidth(n))]
                } else if key.hasPrefix("fine/") {
                    let line = TextLayout.layout(n).lines.first
                    extra[key] = [Double(line?.height ?? 0), Double(line?.baseline ?? 0)]
                } else {
                    extra[key] = describe(n)
                }
            }
        }
        let report: [String: Any] = ["samples": samples, "probes": probes, "extra": extra, "decks": decks]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where letters are drawn against where their baseline is said to be: "HHHH" in each family's
    /// first face at sizes from 9 to 40 points, on a white artboard at 4×, the flat bottom of its
    /// letters found in the pixels. Per probe: the first baseline, and the ink's top and bottom
    /// edges, in points from the text's top.
    public static func inkReport() -> String {
        var out: [String: Any] = [:]
        let kept = design
        defer { design = kept }
        for family in reportFamilies {
            let face = Fonts.faces(of: family).first ?? "Regular"
            for k in 18...80 {
                let size = CGFloat(k) / 2
                var text = probe("HHHH", family: family, face: face, size: size)
                text.frame.origin = CGPoint(x: 10, y: 10)
                var board = Node(kind: .artboard, name: "ink", frame: CGRect(x: 0, y: 0, width: 400, height: size * 2 + 20))
                board.children = [text]
                var doc = BezzleDocument()
                doc.nodes = [board]
                design = doc
                guard let picture = render(board: 0, scale: 4) else { continue }
                let edges = inkEdges(picture.pixels, width: picture.width, height: picture.height)
                out["\(family)/\(face)/\(size)"] = [Double(TextLayout.firstBaseline(text)), edges.top / 4 - 10, edges.bottom / 4 - 10]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The top and bottom edges of the dark letters on white, in pixels: the first and last rows
    /// half covered or more.
    private static func inkEdges(_ pixels: [UInt8], width: Int, height: Int) -> (top: Double, bottom: Double) {
        var top = -1, bottom = -1
        for y in 0..<height {
            var darkest = 0
            for x in 0..<width {
                let k = (y * width + x) * 4
                darkest = max(darkest, 255 - (Int(pixels[k]) + Int(pixels[k + 1]) + Int(pixels[k + 2])) / 3)
            }
            if darkest >= 128 {
                if top < 0 { top = y }
                bottom = y + 1
            }
        }
        return (Double(top), Double(bottom))
    }

    /// Each artboard made a deck with one more post, and which of its posts seem broken (words
    /// cut off or past the page): its texts as kept, and refitted to their words. As the Mac's
    /// TextMeasureTests does.
    private static func reportDecks(_ doc: BezzleDocument) -> [String: [[Int]]] {
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

    static let reportCorpus = [
        "The quick brown fox jumps over the lazy dog.", "Pack my box with five dozen liquor jugs",
        "Discover places worth the trip", "Settings Profile Saved Explore", "Sign in with your email address",
        "0123456789 12.50 4.8 1,234 reviews", "Über Größe Straße Café naïve", "WANDER AUTUMN MENU ADOPTION DAY",
    ]

    /// Words for fitting widths, empty texts, paragraphs set apart, two families on a line, and a
    /// fine sweep of sizes for the line's height: as the Mac's side makes them.
    private static func extraProbes() -> [(String, Node)] {
        var out: [(String, Node)] = []
        for family in reportFamilies {
            let all = Fonts.faces(of: family)
            for face in all {
                for size in reportSizes {
                    for (i, words) in reportCorpus.enumerated() {
                        out.append(("corpus/\(i)/\(family)/\(face)/\(size)", probe(words, family: family, face: face, size: size)))
                    }
                }
                for size: CGFloat in [12, 16, 24] {
                    out.append(("empty/\(family)/\(face)/\(size)", probe("", family: family, face: face, size: size)))
                }
                for k in 40...400 {
                    let size = CGFloat(k) / 10
                    out.append(("fine/\(family)/\(face)/\(size)", probe("Hxg", family: family, face: face, size: size)))
                }
            }
            let face = all.first ?? "Regular"
            for size: CGFloat in [12, 16, 24] {
                for after: CGFloat in [6, 10] {
                    for spacing: CGFloat in [0, (size * 1.5).rounded()] {
                        var n = probe("Hxg\nHxg Hxg Hxg Hxg Hxg Hxg Hxg Hxg\n\nHxg", family: family, face: face, size: size,
                                      lineSpacing: spacing > 0 ? spacing : nil)
                        n.style?.paragraphSpacing = after
                        n.style?.sizing = .autoHeight
                        n.frame.size.width = size * 7
                        n.refit()
                        out.append(("paragraph/\(family)/\(face)/\(size)/\(after)/\(spacing)", n))
                    }
                }
                for (name, words) in [("trailing", "Hxg\n"), ("leading", "\nHxg"), ("both", "Hxg\nHxg\n")] {
                    var n = probe(words, family: family, face: face, size: size)
                    n.style?.paragraphSpacing = 10
                    n.refit()
                    out.append(("edge/\(name)/\(family)/\(face)/\(size)", n))
                }
                let spans = [TextSpan(text: "Hxg "), TextSpan(text: "Hxg", look: TextLook(family: "Times", face: "Regular"))]
                out.append(("families/\(family)/\(face)/\(size)", probe("Hxg Hxg", family: family, face: face, size: size, spans: spans)))
            }
        }
        return out
    }

    /// What the host itself says of a text's lines: start, end, width, ascent, descent, leading.
    private static func hostLines(_ n: Node) -> [[Double]] {
        let style = n.style ?? TextStyle()
        let spec: [String: Any] = ["width": 100_000.0, "align": style.align.rawValue, "lineSpacing": 0.0, "paragraphSpacing": 0.0,
                                   "runs": TextLayout.runs(n)]
        let json = (try? JSONSerialization.data(withJSONObject: spec)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let answer = Host.call(.textLayout, string: json)
        guard let reply = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any] else { return [] }
        return ((reply["lines"] as? [[Any]]) ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
    }

    private static func describe(_ n: Node) -> [String: Any] {
        let laid = TextLayout.layout(n)
        let style = n.style ?? TextStyle()
        var refit = n
        refit.refit()
        let fitted = TextLayout.fittedFrame(n)
        return [
            "name": n.name, "text": laid.string,
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
            // Each line's place, and where its letters begin, twice, as the Mac's side gives where
            // its used rect and its first letter begin (Web/tools/ListTruthTests.swift).
            "lines": laid.lines.map { [Double($0.start), Double($0.end), Double($0.top), Double($0.height), Double($0.width), Double($0.baseline),
                                       Double($0.left), Double($0.left)] },
            "markers": laid.markers.map { [$0.text, Double($0.at.x), Double($0.at.y), Double($0.size)] as [Any] },
        ]
    }
}
