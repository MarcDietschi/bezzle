import Testing
import AppKit
@testable import Bezzle

/// How wide the Mac sets letters that sit close (Yo, Ly, "1,"), letters that do not (HH, oo) and
/// some words, in the system font and Avenir Next at every weight the samples use and at sizes
/// from 9 to 96 points, with Futura as a face that is neither tracked nor sized by eye: for
/// finding where the browser's widths leave the Mac's (tools/compare.mjs, whose report has each
/// text's `dWidth`; tools/widths.mjs sorts them by face, size and letters).
///
/// Like WebTruthTests, this is copied into `BezzleTests/` to be run, with
/// `TEST_RUNNER_WEB_TRUTH_OUT=<dir>`. Everything goes to `<dir>/widths`: the design
/// (`Widths.bezzle`) and `truth.json` in the shape WebTruthTests writes, without pictures.
@MainActor
struct WidthTruthTests {
    static let faces: [(family: String, face: String)] = [
        (TextStyle.system, "Regular"), (TextStyle.system, "Medium"), (TextStyle.system, "Semibold"), (TextStyle.system, "Bold"),
        ("Avenir Next", "Regular"), ("Avenir Next", "Medium"), ("Avenir Next", "Demi Bold"), ("Futura", "Medium"),
    ]
    static let sizes: [CGFloat] = [9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 22.6, 24, 26, 27.7, 28, 30, 32, 36, 40, 48, 56, 64, 72, 96]
    static let words = ["HH", "oo", "nn", "Yo", "Ly", "1,", "To", "AV", "Wa", "r.", "P.", "LT", "ff", "· 1", "Where to next?", "SAT · 10 AM", "Neuschwanstein",
                        "Saved trips", "Yosemite", "Hamburgefonstiv"]

    @Test func dumpWidths() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth").appendingPathComponent("widths", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var board = Node(kind: .artboard, name: "Widths", frame: CGRect(x: 0, y: 0, width: 4000, height: 4000))
        var y: CGFloat = 10
        for (family, face) in Self.faces {
            for size in Self.sizes {
                var x: CGFloat = 10
                for word in Self.words {
                    var n = Node(kind: .text, name: word, frame: CGRect(x: x, y: y, width: 10, height: 10))
                    var s = TextStyle()
                    s.family = family
                    s.face = face
                    s.size = size
                    s.sizing = .autoWidth
                    n.style = s
                    n.setRuns([TextSpan(text: word)])
                    n.refit()
                    board.children.append(n)
                    x += n.frame.width + 12
                }
                y += size * 1.4
            }
        }
        board.frame.size.height = y + 10
        var doc = BezzleDocument()
        doc.nodes = [board]
        let url = root.appendingPathComponent("Widths.bezzle")
        try DesignFile.write(doc, to: url)

        let read = try DesignFile.read(url)
        let texts = read.nodes[0].children.map(describe)
        let all: [String: Any] = ["Widths": ["texts": texts, "boards": [[String: Any]]()]]
        try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]).write(to: root.appendingPathComponent("truth.json"))
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
        return [
            "id": n.id.uuidString, "name": n.name, "text": laid.storage.string,
            "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height],
            "family": style.family, "face": style.face, "size": style.size, "sizing": "\(style.sizing)",
            "used": [laid.usedSize.width, laid.usedSize.height],
            "natural": TextLayout.naturalWidth(n), "firstBaseline": TextLayout.firstBaseline(n),
            "fitted": { let f = TextLayout.fittedFrame(n); return [f.width, f.height] }(),
            "lines": lines,
        ]
    }
}
