import Testing
import AppKit
@testable import Bezzle

/// Lists as Text Kit sets them on the Mac, for comparing with the Windows core and the browser
/// (Web/Sources/BezzleCore/Web/WebText.swift): a design of texts with bulleted and numbered
/// items (`Lists.bezzle`), each text's lines with where they begin, and its markers, and each
/// artboard drawn at 2×. Like WebTruthTests, run from an archived copy of the tree with this file
/// put into BezzleTests, never added to the real test target, with LIST_TRUTH_OUT a folder; then
/// bezzle-render draws and measures the same design (BEZZLE_TEXTS, BEZZLE_TEXTS_PROBES=0) and
/// list-compare.py compares the two.
struct ListTruthTests {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIST_TRUTH_OUT"] ?? "/tmp/list-truth")

    /// A paragraph of a text, as an item of a list or not.
    typealias Paragraph = (words: String, list: TextList?)

    static func text(_ paragraphs: [Paragraph], family: String = TextStyle.system, face: String = "Regular", size: CGFloat = 16,
                     sizing: TextSizing = .autoWidth, width: CGFloat = 10, align: TextAlign = .left,
                     lineSpacing: CGFloat? = nil, paragraphSpacing: CGFloat? = nil, at: CGPoint,
                     look: (Int, inout TextLook) -> Void = { _, _ in }) -> Node {
        var n = Node(kind: .text, name: "list", frame: CGRect(origin: at, size: CGSize(width: width, height: 10)))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.sizing = sizing
        s.align = align
        s.lineSpacing = lineSpacing
        s.paragraphSpacing = paragraphSpacing
        n.style = s
        let runs = paragraphs.enumerated().map { k, p in
            var l = TextLook(list: p.list)
            look(k, &l)
            return TextSpan(text: p.words + (k < paragraphs.count - 1 ? "\n" : ""), look: l)
        }
        n.setRuns(runs)
        n.refit()
        return n
    }

    static func board(_ name: String, x: CGFloat, _ texts: [Node]) -> Node {
        var b = Node(kind: .artboard, name: name, frame: CGRect(x: x, y: 0, width: 640, height: 900))
        b.children = texts
        return b
    }

    /// The probes, on three artboards: the same on the Mac and on Windows, read from the design.
    static func design() -> BezzleDocument {
        let bullets: [Paragraph] = [("Hxg one", .bullet), ("Hxg two", .bullet), ("Hxg three", .bullet)]
        let numbers: [Paragraph] = (1...11).map { ("Item \($0)", .number) }
        let mixed: [Paragraph] = [("Intro line before the list", nil), ("First point", .bullet), ("Second point", .bullet),
                                  ("Words between", nil), ("One", .number), ("Two", .number), ("Dot", .bullet), ("Again", .number)]
        let long: [Paragraph] = [("A bullet item that runs long enough to wrap over several lines", .bullet), ("Short", .bullet),
                                 ("Then a numbered one that wraps over its lines too", .number)]
        let red = RGBA(r: 0.8, g: 0.1, b: 0.1)
        let one = board("Lists 1", x: 0, [
            text(bullets, at: CGPoint(x: 20, y: 20)),
            text(numbers, sizing: .autoHeight, width: 260, at: CGPoint(x: 300, y: 20)),
            text(mixed, sizing: .autoHeight, width: 260, at: CGPoint(x: 20, y: 140)),
            text(long, sizing: .fixed, width: 200, at: CGPoint(x: 20, y: 360)),
            text(bullets, size: 16, lineSpacing: 30, at: CGPoint(x: 300, y: 360)),
            text(bullets, size: 16, sizing: .autoHeight, width: 260, paragraphSpacing: 10, at: CGPoint(x: 300, y: 500)),
            text(mixed, size: 12, sizing: .autoHeight, width: 200, at: CGPoint(x: 20, y: 600)),
        ])
        let two = board("Lists 2", x: 700, [
            text(long, sizing: .autoHeight, width: 260, align: .center, at: CGPoint(x: 20, y: 20)),
            text(long, sizing: .autoHeight, width: 260, align: .right, at: CGPoint(x: 330, y: 20)),
            text(long, sizing: .autoHeight, width: 260, align: .justify, at: CGPoint(x: 20, y: 240)),
            // The first letters bigger, and of a colour of their own.
            text(bullets, at: CGPoint(x: 330, y: 240)) { k, l in if k == 1 { l.size = 28; l.color = RGBA(r: 0.1, g: 0.3, b: 0.9) } },
            text(numbers.prefix(4).map { $0 }, size: 22, at: CGPoint(x: 20, y: 460)) { k, l in if k == 2 { l.size = 12 } },
            text(bullets, size: 40, at: CGPoint(x: 330, y: 460)),
        ])
        var colored = text(mixed, size: 15, sizing: .autoHeight, width: 280, at: CGPoint(x: 20, y: 660))
        colored.fill.color = red
        var three = board("Lists 3", x: 1400, [
            text(mixed, family: "Helvetica", face: "Regular", size: 18, sizing: .autoHeight, width: 280, at: CGPoint(x: 20, y: 20)),
            text(mixed, family: "Georgia", face: "Regular", size: 18, sizing: .autoHeight, width: 280, at: CGPoint(x: 330, y: 20)),
            text(mixed, family: "Avenir Next", face: "Regular", size: 14, sizing: .autoHeight, width: 280, at: CGPoint(x: 20, y: 330)),
            text(mixed, face: "Bold", size: 15, sizing: .autoHeight, width: 280, at: CGPoint(x: 330, y: 330)),
        ])
        three.children.append(colored)
        var doc = BezzleDocument()
        doc.nodes = [one, two, three]
        return doc
    }

    @Test func dumpLists() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let doc = Self.design()
        let url = Self.out.appendingPathComponent("Lists.bezzle")
        try? FileManager.default.removeItem(at: url)
        try DesignFile.write(doc, to: url)
        var texts: [[String: Any]] = []
        for board in doc.nodes {
            for n in board.children where n.kind == .text {
                var d = describe(n)
                d["key"] = "Lists/\(n.id.uuidString)"
                d["board"] = board.name
                texts.append(d)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": texts], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.out.appendingPathComponent("lists-mac.json"))
        let png = Self.out.appendingPathComponent("png")
        try FileManager.default.createDirectory(at: png, withIntermediateDirectories: true)
        for (i, board) in doc.nodes.enumerated() {
            guard let image = Renderer.image(of: board, scale: 2, assets: Assets(folder: nil)) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: png.appendingPathComponent(String(format: "Lists-%02d.png", i)))
        }
    }

    private func describe(_ n: Node) -> [String: Any] {
        let laid = TextLayout.layout(n)
        let manager = laid.manager
        var lines: [[Double]] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let place = manager.location(forGlyphAt: glyphs.location)
            lines.append([Double(chars.location), Double(NSMaxRange(chars)), Double(rect.minY), Double(rect.height), Double(used.width),
                          Double(rect.minY + place.y), Double(used.minX), Double(rect.minX + place.x)])
        }
        let markers = TextLayout.markers(manager).map { [$0.text, Double($0.at.x), Double($0.at.y), Double($0.font.pointSize)] as [Any] }
        let fitted = TextLayout.fittedFrame(n)
        return [
            "text": laid.storage.string, "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height],
            "used": [laid.usedSize.width, laid.usedSize.height], "natural": TextLayout.naturalWidth(n),
            "firstBaseline": TextLayout.firstBaseline(n), "fitted": [fitted.width, fitted.height],
            "lines": lines, "markers": markers,
        ]
    }
}
