import Testing
import AppKit
import SwiftUI
@testable import Bezzle

/// Not a check: pictures of the inspector for each kind of selection, to look at its layout.
/// Runs only when BEZZLE_INSPECTOR_SHOTS names a folder to put them in.
@MainActor
struct InspectorShots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["BEZZLE_INSPECTOR_SHOTS"]

    private func design() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 20, y: 20, width: 120, height: 80))
        card.cornerRadius = 12
        card.border = Border(on: true, color: .black, width: 2, position: .inside)
        card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.14), x: 0, y: 4, blur: 12)
        card.blur = Blur(radius: 8, background: true)
        let plain = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 200, y: 20, width: 60, height: 60))
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 150, width: 0, height: 0))
        title.text = "Hello there"
        title.refit()
        var shape = Node(kind: .path, name: "Shape", frame: .zero)
        shape.path = "M 0 0 L 60 0 L 70 40 C 50 60 20 60 0 40 Z"
        shape.pathBox = PathData.bounds(shape.path!)
        shape.frame = shape.pathBox!.offsetBy(dx: 200, dy: 150)
        var field = Node(kind: .rectangle, name: "Field", frame: CGRect(x: 20, y: 220, width: 200, height: 40))
        field.cornerRadius = 8
        field.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.16), x: 0, y: 2, blur: 6, inset: true)
        var tilted = Node(kind: .rectangle, name: "Tilted", frame: CGRect(x: 240, y: 220, width: 120, height: 60))
        tilted.transform3D = Presets.heldUp
        var frosted = Node(kind: .rectangle, name: "Frosted", frame: CGRect(x: 280, y: 100, width: 100, height: 60))
        frosted.blur = Blur(radius: 12, ramp: .down)
        board.children = [card, plain, title, shape, field, tilted, frosted]
        var carousel = Node(kind: .artboard, name: "Launch", frame: CGRect(x: 500, y: 0, width: 3240, height: 1350))
        carousel.slideSize = CGSize(width: 1080, height: 1350)
        var doc = BezzleDocument()
        doc.nodes = [board, carousel]
        return doc
    }

    @Test(.enabled(if: InspectorShots.folder != nil)) func shots() async throws {
        let folder = URL(fileURLWithPath: try #require(Self.folder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = design()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleShots-\(UUID().uuidString).bezzle")
        let store = DocumentStore(url: url, document: doc)
        func id(_ name: String) -> UUID { store.doc.allNodes.first { $0.name == name }!.id }
        // Each look with every card folded, and with the card named open.
        let looks: [(String, [String], Tool, Aspect?)] = [
            ("rectangle", ["Card"], .select, nil), ("rectangle-frame", ["Card"], .select, .frame), ("rectangle-shadow", ["Card"], .select, .shadow),
            ("rectangle-blur", ["Card"], .select, .blur), ("ellipse", ["Dot"], .select, .fill), ("text", ["Title"], .select, .text),
            ("path", ["Shape"], .select, .path), ("inset", ["Field"], .select, .shadow), ("3d", ["Tilted"], .select, .depth),
            ("growing", ["Frosted"], .select, .blur), ("several", ["Card", "Dot"], .select, .arrange), ("artboard", ["Board"], .select, .artboard),
            ("carousel", ["Launch"], .select, .artboard), ("nothing", [], .select, nil), ("presets", [], .artboard, nil),
        ]
        for appearance in ["light", "dark"] {
            for (name, picked, tool, open) in looks {
                store.tool = tool
                store.openAspect = open
                store.selection = picked.map(id)
                try await shot(store, to: folder.appendingPathComponent("\(name)-\(appearance).png"), dark: appearance == "dark")
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func shot(_ store: DocumentStore, to url: URL, dark: Bool) async throws {
        let menus = MenuHost(), gradients = GradientSession()
        gradients.store = store
        gradients.menus = menus
        let size = CGSize(width: 280, height: 1250)
        let root = Inspector(store: store)
            .frame(width: size.width, height: size.height)
            .background(Theme.paper)
            .environment(menus)
            .environment(gradients)
            .environment(store)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
        window.close()
    }
}
