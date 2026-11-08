import Testing
import AppKit
@testable import Bezzle

/// Convert to Path on texts as the Mac makes it, for comparing with Windows (bezzle-render's
/// BEZZLE_OUTLINE, Windows/Sources/BezzleCore/Host/Outlining.swift): a design of texts
/// (`Outlines.bezzle`: plain, letters of their own colours, lines under and through, a list, a
/// gradient, centred lines, emoji, text on a curve), what each became, and the artboard drawn at
/// 2× before and after. Like WebTruthTests, run from an archived copy of the tree with this file
/// put into BezzleTests, never added to the real test target, with OUTLINE_TRUTH_OUT a folder.
struct OutlineTruthTests {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUTLINE_TRUTH_OUT"] ?? "/tmp/outline-truth")

    static func text(_ runs: [TextSpan], family: String = "Georgia", face: String = "Regular", size: CGFloat = 28,
                     sizing: TextSizing = .autoWidth, width: CGFloat = 10, align: TextAlign = .left, at: CGPoint) -> Node {
        var n = Node(kind: .text, name: "outline", frame: CGRect(origin: at, size: CGSize(width: width, height: 10)))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.sizing = sizing
        s.align = align
        n.style = s
        n.setRuns(runs)
        n.refit()
        return n
    }

    static func design() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Outlines", frame: CGRect(x: 0, y: 0, width: 720, height: 620))
        board.children.append(text([TextSpan(text: "Hamburgefonstiv")], at: CGPoint(x: 30, y: 30)))
        board.children.append(text([TextSpan(text: "Red "), TextSpan(text: "and blue", look: TextLook(color: RGBA(r: 0.1, g: 0.3, b: 0.9))),
                                    TextSpan(text: " words")], family: "Helvetica", at: CGPoint(x: 30, y: 100)))
        board.children.append(text([TextSpan(text: "Under", look: TextLook(underline: true)), TextSpan(text: " and "),
                                    TextSpan(text: "through", look: TextLook(strikethrough: true))], family: "Arial", at: CGPoint(x: 30, y: 170)))
        board.children.append(text([TextSpan(text: "One\n", look: TextLook(list: .bullet)), TextSpan(text: "Two", look: TextLook(list: .number))],
                                   size: 20, at: CGPoint(x: 30, y: 240)))
        var grad = text([TextSpan(text: "Gradient")], face: "Bold", size: 48, at: CGPoint(x: 30, y: 330))
        grad.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.95, g: 0.4, b: 0.2)),
                                                              GradientStop(offset: 1, color: RGBA(r: 0.2, g: 0.4, b: 0.9))],
                                      start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        board.children.append(grad)
        board.children.append(text([TextSpan(text: "Centred lines of words that wrap over")], family: "Helvetica", size: 22, sizing: .autoHeight,
                                   width: 240, align: .center, at: CGPoint(x: 400, y: 30)))
        board.children.append(text([TextSpan(text: "Smile 😀")], family: "Helvetica", size: 24, at: CGPoint(x: 400, y: 200)))
        var turned = text([TextSpan(text: "Turned")], size: 30, at: CGPoint(x: 420, y: 300))
        turned.rotation = 20
        board.children.append(turned)
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    @Test func dumpOutlines() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var doc = Self.design()
        let url = Self.out.appendingPathComponent("Outlines.bezzle")
        try? FileManager.default.removeItem(at: url)
        try DesignFile.write(doc, to: url)
        if let image = Renderer.image(of: doc.nodes[0], scale: 2, assets: Assets(folder: nil)) {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent("before-mac.png"))
        }
        func describe(_ n: Node) -> [String: Any] {
            var d: [String: Any] = ["kind": n.kind.rawValue, "name": n.name,
                                    "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height].map { Double($0) },
                                    "fill": n.fill.on ? n.fill.color.hex : "none", "gradient": n.fill.gradient != nil]
            if !n.children.isEmpty { d["children"] = n.children.map(describe) }
            return d
        }
        var report: [String: Any] = [:]
        for child in doc.nodes[0].children where child.kind == .text {
            if let made = child.outlinedText(), let at = doc.path(of: child.id) {
                doc[at] = made
                report[child.id.uuidString] = describe(made)
            } else {
                report[child.id.uuidString] = "refused"
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.out.appendingPathComponent("outlines-mac.json"))
        if let image = Renderer.image(of: doc.nodes[0], scale: 2, assets: Assets(folder: nil)) {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: Self.out.appendingPathComponent("after-mac.png"))
        }
    }
}
