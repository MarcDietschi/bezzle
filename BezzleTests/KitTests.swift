import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The kits' parts and the icon sets: every part makes sound layers at every width it can be
/// made at, and every icon a part asks for is there.
struct KitTests {
    @Test func iconSetsAreThere() {
        let sets = Icons.sets
        #expect(sets.map(\.id) == [.lucide, .phosphor, .material])
        for set in sets { #expect(set.icons.count > 1000, "\(set.name) has \(set.icons.count) icons") }
        #expect(Icons.icon("heart", in: .lucide) != nil)
        #expect(Icons.icon("heart", in: .phosphor)?.paths.count == 5)
        #expect(Icons.icon("home", in: .material) != nil)
    }

    @Test func lineIconsGrowIntoOutlines() throws {
        let heart = try #require(Icons.icon("heart", in: .lucide))
        let thin = Icons.outline(heart, style: IconStyle(index: 0, weight: 1))
        let thick = Icons.outline(heart, style: IconStyle(index: 0, weight: 3))
        let a = PathData.bounds(thin.data), b = PathData.bounds(thick.data)
        #expect(a.width > 18 && a.width < 22.5, "\(a)")
        #expect(b.width > a.width + 1.5, "\(a) \(b)")
        #expect(thin.box == CGRect(x: 0, y: 0, width: 24, height: 24))
        // Every line icon makes an outline that can be filled.
        for icon in Icons.set(.lucide).icons {
            let made = Icons.outline(icon, style: Icons.set(.lucide).defaultStyle)
            let box = PathData.bounds(made.data)
            #expect(!box.isNull && box.width > 1 && box.height > 1 && box.maxX < 26 && box.minX > -2, "\(icon.name): \(box)")
        }
    }

    @Test func filledIconsReadWhole() {
        for id in [IconSetID.phosphor, .material] {
            let set = Icons.set(id)
            for icon in set.icons where !icon.paths[0].isEmpty {
                let box = PathData.bounds(icon.paths[0])
                #expect(!box.isNull && set.box.insetBy(dx: -set.box.width * 0.05, dy: -set.box.height * 0.05).contains(box), "\(id) \(icon.name): \(box)")
            }
        }
    }

    @Test func findingIcons() {
        let found = Icons.search("arrow right", in: .lucide)
        #expect(found.first?.name == "arrow-right")
        #expect(Icons.search("magnifying", in: .phosphor).contains { $0.name == "magnifying-glass" })
        #expect(Icons.search("zzzzqqq").isEmpty)
    }

    @Test func iconsTakeEachOthersPlace() throws {
        let heart = try #require(Icons.icon("heart", in: .lucide)), star = try #require(Icons.icon("star", in: .phosphor))
        var node = Icons.node(heart, frame: CGRect(x: 10, y: 20, width: 48, height: 48), color: .hex("#FF0000"))
        #expect(Icons.isIcon(node))
        node = Icons.swapped(node, for: star)
        #expect(node.name == "star")
        #expect(node.fill.color == .hex("#FF0000"))
        #expect(abs(node.frame.minX - 10) < 0.01 && abs(node.frame.width - 48) < 0.01)
    }

    @Test func everyPartIsMadeSoundly() {
        Parts.missing.with { $0.removeAll() }
        var ids = Set<String>()
        for kit in Kits.all {
            #expect(!kit.components.isEmpty, "\(kit.id) has no parts")
            for c in kit.components {
                #expect(ids.insert(c.id).inserted, "\(c.id) twice")
                #expect(c.id.hasPrefix(kit.id + "."), "\(c.id) is not under \(kit.id)")
                var widths = [c.size.width]
                if c.stretches { widths += [c.minWidth ?? c.size.width, c.size.width * 1.6] }
                for width in widths {
                    for dark in [false, true] {
                        let n = c.node(width: width, dark: dark)
                        let label = "\(c.id) at \(Int(width))\(dark ? " dark" : "")"
                        #expect(n.isGroup, "\(label) is not a group")
                        #expect(n.frame.minX == 0 && n.frame.minY == 0, "\(label) starts at \(n.frame.origin)")
                        if c.stretches {
                            #expect(abs(n.frame.width - width) < 1.01, "\(label) is \(n.frame.width) wide")
                        } else {
                            #expect(abs(n.frame.width - c.size.width) < 1.01 && abs(n.frame.height - c.size.height) < 1.01,
                                    "\(label) is \(n.frame.size), not \(c.size)")
                        }
                        check(n, label)
                    }
                }
            }
        }
        let missing = Parts.missing.with { $0 }
        #expect(missing.isEmpty, "icons no set has: \(missing.sorted())")
    }

    /// No empty group, nothing of no size or past where numbers go, no text without words.
    private func check(_ n: Node, _ label: String) {
        let f = n.frame
        #expect(f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite, "\(label): \(n.name) at \(f)")
        if n.isGroup { #expect(!n.children.isEmpty, "\(label): empty group \(n.name)") }
        if n.kind == .text { #expect(n.text?.isEmpty == false, "\(label): \(n.name) has no words") }
        if n.kind == .path { #expect(n.path?.isEmpty == false, "\(label): \(n.name) has no outline") }
        for child in n.children { check(child, label) }
    }

    // MARK: Pictures

    nonisolated static let shots = ProcessInfo.processInfo.environment["BEZZLE_KIT_SHOTS"]

    /// Not a check: a sheet of every part of every kit, light and dark, to look at. Runs only when
    /// BEZZLE_KIT_SHOTS names a folder; BEZZLE_KIT_ONLY may name one kit.
    @Test(.enabled(if: KitTests.shots != nil)) @MainActor func sheets() throws {
        let folder = URL(fileURLWithPath: try #require(Self.shots))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["BEZZLE_KIT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        for kit in Kits.all where only == nil || only == kit.id {
            for dark in [false, true] {
                let board = Self.sheet(kit, dark: dark)
                let image = try #require(Renderer.image(of: board, scale: 2))
                let url = folder.appendingPathComponent("\(kit.id)-\(dark ? "dark" : "light").png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        // A sample of each icon set in each style.
        let names: [IconSetID: [String]] = [
            .lucide: ["heart", "settings", "search", "house", "bell", "camera", "trash-2", "user", "calendar", "map-pin", "share", "plus"],
            .phosphor: ["heart", "gear", "magnifying-glass", "house", "bell", "camera", "trash", "user", "calendar", "map-pin", "share", "plus"],
            .material: ["favorite", "settings", "search", "home", "notifications", "photo_camera", "delete", "person", "calendar_month", "location_on", "share", "add"],
        ]
        var rows: [Node] = []
        var y: CGFloat = 20
        for set in Icons.sets {
            let styles: [IconStyle] = set.drawnAsLines ? [1, 1.5, 2, 2.5, 3].map { IconStyle(index: 0, weight: $0) }
                : set.styles.indices.map { IconStyle(index: $0) }
            for style in styles {
                rows.append(Parts.text("\(set.name) \(set.drawnAsLines ? "\(style.weight)" : set.styles[style.index])", x: 20, y: y + 8, size: 11, color: .hex("#666666")))
                for (i, name) in (names[set.id] ?? []).enumerated() {
                    guard let icon = set.icon(name) else { continue }
                    rows.append(Icons.node(icon, style: style, frame: CGRect(x: 160 + CGFloat(i) * 44, y: y, width: 28, height: 28), color: .hex("#1C1B19")))
                }
                y += 40
            }
        }
        var board = Node(kind: .artboard, name: "Icons", frame: CGRect(x: 0, y: 0, width: 700, height: y + 20))
        board.children = rows
        let image = try #require(Renderer.image(of: board, scale: 2))
        let dest = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent("icons.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Every part of a kit laid out in rows on its paper, each with its name over it; the parts
    /// that stretch are also shown narrow and wide.
    static func sheet(_ kit: Kit, dark: Bool) -> Node {
        let width: CGFloat = 1500
        let ink = dark ? RGBA.hex("#FFFFFF80") : RGBA.hex("#00000080")
        var children: [Node] = []
        var x: CGFloat = 32, y: CGFloat = 32, rowHeight: CGFloat = 0
        func place(_ n: Node, label: String) {
            if x + n.frame.width > width - 32 && x > 32 {
                x = 32
                y += rowHeight + 36
                rowHeight = 0
            }
            children.append(Parts.text(label, x: x, y: y, size: 11, weight: "Medium", color: ink))
            var placed = n
            placed.frame.origin = CGPoint(x: x, y: y + 20)
            children.append(placed)
            x += n.frame.width + 40
            rowHeight = max(rowHeight, n.frame.height + 20)
        }
        for section in kit.sections {
            if x > 32 { x = 32; y += rowHeight + 36; rowHeight = 0 }
            children.append(Parts.text(String(localized: section.title), x: 32, y: y, size: 18, weight: "Bold", color: dark ? .white : .black))
            y += 36
            for c in section.components {
                place(c.node(dark: dark), label: "\(String(localized: c.title))  \(c.id)")
                if c.stretches, let min = c.minWidth, min < c.size.width - 1 {
                    place(c.node(width: min, dark: dark), label: "\(c.id) at \(Int(min))")
                }
            }
        }
        var board = Node(kind: .artboard, name: kit.id, frame: CGRect(x: 0, y: 0, width: width, height: y + rowHeight + 48))
        board.fill = Fill(color: dark ? kit.darkPaper : kit.paper)
        board.children = children
        return board
    }
}
