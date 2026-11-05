import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The Mac's own layout and drawing of the sample designs, for the web prototype to be compared
/// with: each text's lines as Text Kit breaks them, and each artboard drawn.
struct WebTruthTests {
    @Test func dumpTruth() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth")
        let designs = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_DESIGNS"] ?? "")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: designs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bezzle" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [String: Any] = [:]
        for url in files {
            let doc = try DesignFile.read(url)
            let name = url.deletingPathExtension().lastPathComponent
            var texts: [[String: Any]] = []
            func walk(_ nodes: [Node]) {
                for n in nodes {
                    if n.kind == .text, !n.isCurved { texts.append(describe(n)) }
                    walk(n.children)
                }
            }
            walk(doc.nodes)
            var boards: [[String: Any]] = []
            let assets = Assets(design: url)
            for (i, board) in doc.nodes.enumerated() where board.isArtboard {
                let file = "\(name)-\(i).png"
                if let image = Renderer.image(of: board, scale: 2, assets: assets) { try write(image, to: out.appendingPathComponent(file)) }
                boards.append(["index": i, "name": board.name, "file": file, "frame": [board.frame.minX, board.frame.minY, board.frame.width, board.frame.height]])
            }
            all[name] = ["texts": texts, "boards": boards]
        }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("truth.json"))
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

    private func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
