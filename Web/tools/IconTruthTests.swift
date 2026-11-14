import Testing
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The Mac's own reading of the icon library, for the browser's core to be compared with
/// (tools/icons.mjs): what each set says of itself with a digest of all its icons, what is found
/// for some words, the box some icons' outlines take at some weights, and a sheet of icons from
/// every set in every style, drawn by the Mac.
///
/// Like WebTruthTests, this is copied into `BezzleTests/` to be run, with
/// `TEST_RUNNER_WEB_TRUTH_OUT=<dir>`. Everything goes to `<dir>/icons`: `icons.json`, the sheet
/// as a design (`Icons.bezzle`), drawn at 2× (`Icons-0.png`), and a `truth.json` in the shape
/// WebTruthTests writes, so that `tools/compare.mjs` can also draw the Mac's own outlines.
@MainActor
struct IconTruthTests {
    private static let paper = [0.97, 0.96, 0.94], ink = [0.12, 0.13, 0.2]

    /// One icon of the sheet, as the core is asked for it too.
    private struct Placed {
        var icon: Icon, style: IconStyle, frame: CGRect
        var asked: [String: Any] {
            ["set": icon.set.rawValue, "name": icon.name, "style": style.index, "weight": Double(style.weight),
             "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }]
        }
    }

    private static func digest(of set: IconSet) -> String {
        var hasher = SHA256()
        for icon in set.icons {
            hasher.update(data: Data(([icon.name, icon.tags] + icon.paths).joined(separator: "\n").utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Icons from every set, each in every style its set has, a line set's at three weights; then
    /// a row of large ones with lines from hair thin to as heavy as they go.
    private static func sheet() -> (size: CGSize, icons: [Placed]) {
        let cell: CGFloat = 44, side: CGFloat = 32, margin: CGFloat = 20, perRow = 24
        var small: [(Icon, IconStyle)] = []
        for set in Icons.sets {
            let every = set.id == .lucide ? 59 : set.id == .phosphor ? 101 : 197
            for i in stride(from: every / 2, to: set.icons.count, by: every) {
                if set.drawnAsLines {
                    for weight in [1, 2, 3.25] as [CGFloat] { small.append((set.icons[i], IconStyle(index: 0, weight: weight))) }
                } else {
                    let paths = set.icons[i].paths
                    for style in set.styles.indices where paths.indices.contains(style) && !paths[style].isEmpty { small.append((set.icons[i], IconStyle(index: style, weight: 2))) }
                }
            }
        }
        var placed = small.enumerated().map { k, one in
            Placed(icon: one.0, style: one.1, frame: CGRect(x: margin + CGFloat(k % perRow) * cell + (cell - side) / 2,
                                                            y: margin + CGFloat(k / perRow) * cell + (cell - side) / 2, width: side, height: side))
        }
        let rows = CGFloat((small.count + perRow - 1) / perRow)
        let lines = Icons.set(.lucide)
        let big: CGFloat = 96, top = margin + rows * cell + 16
        for (k, weight) in ([0.25, 0.5, 1, 1.5, 2.5, 4, 5, 6] as [CGFloat]).enumerated() {
            let icon = lines.icons[(k * 233 + 17) % lines.icons.count]
            placed.append(Placed(icon: icon, style: IconStyle(index: 0, weight: weight), frame: CGRect(x: margin + 16 + CGFloat(k) * (big + 34), y: top + 12, width: big, height: big)))
        }
        return (CGSize(width: margin * 2 + CGFloat(perRow) * cell, height: top + big + 24 + margin), placed)
    }

    @Test func dumpIcons() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth").appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(Icons.sets.map(\.id) == [.lucide, .phosphor, .material])

        let sets: [[String: Any]] = Icons.sets.map { s in
            ["id": s.id.rawValue, "name": s.name, "licence": s.licence, "box": [s.box.minX, s.box.minY, s.box.width, s.box.height].map { Double($0) },
             "stroke": s.stroke.map { Double($0) as Any } ?? NSNull(), "styles": s.styles, "icons": s.icons.count, "digest": Self.digest(of: s)]
        }

        let searches: [[String: Any]] = [
            ["query": "arrow up", "limit": 12], ["query": "home", "set": "lucide", "limit": 8], ["query": "user circle", "set": "phosphor", "limit": 8],
            ["query": "shopping", "set": "material", "limit": 10], ["query": "", "set": "lucide", "limit": 5], ["query": "zzzz", "limit": 5],
            ["query": "Arrow-Up_right", "limit": 6], ["query": "heart", "limit": 20], ["query": "cal", "set": "phosphor", "limit": 9],
        ].map { one in
            var with = one
            let found = Icons.search(one["query"] as! String, in: (one["set"] as? String).flatMap(IconSetID.init(rawValue:)), limit: one["limit"] as! Int)
            with["found"] = found.map { "\($0.set.rawValue)/\($0.name)" }
            return with
        }

        // Outlines: a set of outlines hands its own on, a set of lines grows them.
        var outlines: [[String: Any]] = []
        for set in Icons.sets {
            for i in stride(from: 7, to: set.icons.count, by: set.icons.count / 12) {
                let icon = set.icons[i]
                let styles: [IconStyle] = set.drawnAsLines ? ([0.25, 1, 2, 3.25, 6] as [CGFloat]).map { IconStyle(index: 0, weight: $0) }
                    : set.styles.indices.map { IconStyle(index: $0, weight: 2) }
                for style in styles {
                    let (data, box) = Icons.outline(icon, style: style)
                    var one: [String: Any] = ["set": set.id.rawValue, "name": icon.name, "style": style.index, "weight": Double(style.weight),
                                              "box": [box.minX, box.minY, box.width, box.height].map { Double($0) }]
                    // Grown outlines are each stroker's own: only their box is the same. The others are the set's words.
                    if !set.drawnAsLines { one["data"] = data }
                    outlines.append(one)
                }
            }
        }

        let (size, placed) = Self.sheet()
        var board = Node(kind: .artboard, name: "Icons", frame: CGRect(origin: .zero, size: size))
        board.fill.color = RGBA(r: Self.paper[0], g: Self.paper[1], b: Self.paper[2])
        board.children = placed.map { Icons.node($0.icon, style: $0.style, frame: $0.frame, color: RGBA(r: Self.ink[0], g: Self.ink[1], b: Self.ink[2])) }
        var doc = BezzleDocument()
        doc.nodes = [board]
        let url = root.appendingPathComponent("Icons.bezzle")
        try DesignFile.write(doc, to: url)
        let read = try DesignFile.read(url)
        try write(try #require(Renderer.image(of: read.nodes[0], scale: 2, assets: Assets(design: url))), to: root.appendingPathComponent("Icons-0.png"))

        let all: [String: Any] = [
            "sets": sets, "searches": searches, "outlines": outlines,
            "sheet": ["name": "Icons", "size": [Double(size.width), Double(size.height)], "paper": Self.paper, "ink": Self.ink, "icons": placed.map(\.asked)],
        ]
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("icons.json"))
        let truth: [String: Any] = ["Icons": ["texts": [[String: Any]](), "boards": [["index": 0, "name": "Icons", "file": "Icons-0.png", "frame": [0, 0, Double(size.width), Double(size.height)]]]]]
        try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("truth.json"))
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
