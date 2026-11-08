import Testing
import AppKit
@testable import Bezzle

/// Words in scripts the design's fonts lack (Arabic, Hebrew, Chinese, Japanese, Korean, Thai,
/// Devanagari, emoji), which Core Text sets in the Mac's own fonts for them, for comparing with
/// the Windows core, which falls back on Windows' own (CBezzleHost/fallback.cpp): a design of
/// them (`Scripts.bezzle`), each text's size and lines, and the artboard drawn at 2×. Like
/// WebTruthTests, run from an archived copy of the tree with this file put into BezzleTests,
/// never added to the real test target, with SCRIPT_TRUTH_OUT a folder; then bezzle-render
/// draws and measures the same design (BEZZLE_TEXTS, BEZZLE_TEXTS_PROBES=0).
struct ScriptTruthTests {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCRIPT_TRUTH_OUT"] ?? "/tmp/script-truth")

    static let words = [
        "Arabic مرحبا بالعالم", "Hebrew שלום עולם", "Chinese 你好，世界", "Japanese こんにちは世界",
        "Korean 안녕하세요 세계", "Thai สวัสดีชาวโลก", "Devanagari नमस्ते दुनिया", "Emoji 😀🎉👍🏽❤️",
        "Mixed 你好 مرحبا 😀 שלום",
    ]

    static func text(_ words: String, family: String, face: String, size: CGFloat, at: CGPoint) -> Node {
        var n = Node(kind: .text, name: "script", frame: CGRect(origin: at, size: CGSize(width: 10, height: 10)))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.sizing = .autoWidth
        n.style = s
        n.text = words
        n.refit()
        return n
    }

    static func design() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Scripts", frame: CGRect(x: 0, y: 0, width: 760, height: 520))
        for (k, w) in words.enumerated() {
            board.children.append(text(w, family: TextStyle.system, face: "Regular", size: 20, at: CGPoint(x: 20, y: 20 + CGFloat(k) * 52)))
            board.children.append(text(w, family: "Georgia", face: k % 2 == 0 ? "Regular" : "Bold", size: 18, at: CGPoint(x: 400, y: 20 + CGFloat(k) * 52)))
        }
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    @Test func dumpScripts() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let doc = Self.design()
        let url = Self.out.appendingPathComponent("Scripts.bezzle")
        try? FileManager.default.removeItem(at: url)
        try DesignFile.write(doc, to: url)
        var texts: [[String: Any]] = []
        for n in doc.nodes[0].children {
            let laid = TextLayout.layout(n)
            var lines: [[Double]] = []
            laid.manager.enumerateLineFragments(forGlyphRange: laid.manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
                let chars = laid.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let place = laid.manager.location(forGlyphAt: glyphs.location)
                lines.append([Double(chars.location), Double(NSMaxRange(chars)), Double(rect.minY), Double(rect.height), Double(used.width), Double(rect.minY + place.y)])
            }
            texts.append(["key": "Scripts/\(n.id.uuidString)", "text": n.text ?? "", "family": n.style?.family ?? "",
                          "used": [laid.usedSize.width, laid.usedSize.height], "natural": TextLayout.naturalWidth(n),
                          "firstBaseline": TextLayout.firstBaseline(n), "lines": lines])
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": texts], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.out.appendingPathComponent("scripts-mac.json"))
        if let image = Renderer.image(of: doc.nodes[0], scale: 2, assets: Assets(folder: nil)) {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent("Scripts-00.png"))
        }
    }
}
