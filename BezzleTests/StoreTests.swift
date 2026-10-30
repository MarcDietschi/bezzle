import Testing
import AppKit
@testable import Bezzle

@MainActor
struct StoreTests {
    @Test func aDesignSurvivesSavingAndOpening() throws {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 20, width: 30, height: 40))])
        bench.step { bench.store.updateSelection("x") { _ in } }
        bench.store.save()
        DocumentStore.finishSaving()
        let reopened = try DocumentStore(opening: bench.store.url)
        #expect(reopened.doc.nodes == bench.store.doc.nodes)
        try? FileManager.default.removeItem(at: bench.store.url)
    }

    @Test func theOldVellumFolderMovesAcrossOnce() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BezzleTests-move-\(UUID().uuidString)")
        let old = root.appendingPathComponent("Vellum"), new = root.appendingPathComponent("Bezzle")
        try fm.createDirectory(at: old.appendingPathComponent("Poster.vellum"), withIntermediateDirectories: true)
        try Data().write(to: old.appendingPathComponent("Notes.txt"))
        Library.moveDesigns(from: old, to: new)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("Poster.bezzle").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("Notes.txt").path))
        // With a library already there, the old folder is left as it is.
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        Library.moveDesigns(from: old, to: new)
        #expect(fm.fileExists(atPath: old.path))
        try? fm.removeItem(at: root)
    }

    @Test func alignAndDistribute() {
        let bench = Bench(extra: [CanvasTests.rect("R1", CGRect(x: 10, y: 10, width: 20, height: 20)),
                                  CanvasTests.rect("R2", CGRect(x: 50, y: 40, width: 20, height: 20)),
                                  CanvasTests.rect("R3", CGRect(x: 200, y: 90, width: 20, height: 20))])
        bench.store.selection = bench.a.children.map(\.id)
        bench.step { bench.store.align(.top) }
        #expect(bench.a.children.allSatisfy { $0.frame.minY == 10 })
        bench.step { bench.store.distribute(horizontally: true) }
        #expect(bench.node("R2")?.frame.minX == 105)
        // One layer alone lines up with its artboard.
        bench.store.selection = [bench.node("R1")!.id]
        bench.step { bench.store.align(.right) }
        #expect(bench.node("R1")?.frame.maxX == 400)
    }

    @Test func arrangeMovesWithinItsOwnList() {
        let bench = Bench(extra: [CanvasTests.rect("R1", .zero), CanvasTests.rect("R2", .zero), CanvasTests.rect("R3", .zero)])
        bench.store.selection = [bench.node("R1")!.id]
        bench.step { bench.store.arrange(.front) }
        #expect(bench.a.children.map(\.name) == ["R2", "R3", "R1"])
        bench.step { bench.store.arrange(.backward) }
        #expect(bench.a.children.map(\.name) == ["R2", "R1", "R3"])
        bench.step { bench.store.arrange(.back) }
        #expect(bench.a.children.map(\.name) == ["R1", "R2", "R3"])
    }

    @Test func layersListMovesALayerOntoAnotherArtboardKeepingItsPlaceOnScreen() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 20, height: 20))])
        let id = bench.node("R")!.id
        bench.step { bench.store.move(id, to: bench.b.id, at: 0) }
        #expect(bench.b.children.first?.name == "R")
        #expect(bench.store.doc.absoluteFrame(of: id)?.origin == CGPoint(x: 110, y: 110))
        bench.step { bench.store.move(id, to: nil, at: 0) }
        #expect(bench.store.doc.nodes.first?.name == "R")
    }

    @Test func copyAndPasteMakesFreshLayersOffsetFromTheOriginals() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 20, height: 20))])
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        bench.store.selection = [bench.node("R")!.id]
        bench.store.copySelection()
        bench.step { bench.store.paste() }
        let copies = bench.a.children.filter { $0.name == "R" }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).count == 2)
        #expect(copies.last?.frame.origin == CGPoint(x: 20, y: 20))
    }

    @Test func resizingAnArtboardLeavesItsContentWhereItWas() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 20, height: 20))])
        let id = bench.node("R")!.id
        bench.click(CGPoint(x: 104, y: 92))
        // Pull the top left handle 50 up and left.
        bench.drag(CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 50), flags: [.command])
        #expect(bench.a.frame == CGRect(x: 50, y: 50, width: 450, height: 350))
        #expect(bench.store.doc.absoluteFrame(of: id)?.origin == CGPoint(x: 110, y: 110))
    }

    @Test func textGrowsWithItsWords() {
        var t = Node(kind: .text, name: "T", frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        t.text = "Hi"
        t.refit()
        let short = t.frame.width
        t.text = "Hi there, a longer line"
        t.refit()
        #expect(t.frame.width > short * 3)
        t.style?.sizing = .autoHeight
        t.frame.size.width = 60
        t.refit()
        #expect(t.frame.width == 60)
        #expect(t.frame.height > 50)
    }
}

@MainActor
struct MenuTests {
    @Test func aClickOutsideClosesTheMenuAndOneOnItsControlIsLeftToIt() {
        let host = MenuHost()
        host.toggle("zoom", entries: [.item("A") {}])
        host.track(menu: CGRect(x: 100, y: 100, width: 200, height: 300), anchor: CGRect(x: 100, y: 60, width: 80, height: 30))
        host.passing(.leftMouseDown, at: CGPoint(x: 150, y: 200))
        #expect(host.open != nil)
        // The control toggles the menu itself.
        host.passing(.leftMouseDown, at: CGPoint(x: 120, y: 70))
        #expect(host.open != nil)
        host.passing(.scrollWheel, at: CGPoint(x: 600, y: 600))
        #expect(host.open != nil)
        host.passing(.leftMouseDown, at: CGPoint(x: 600, y: 600))
        #expect(host.open == nil)
    }

    @Test func scrollingAwayClosesARightClickMenu() {
        let host = MenuHost()
        host.show(at: CGPoint(x: 100, y: 100), entries: [.item("A") {}])
        host.track(menu: CGRect(x: 100, y: 100, width: 200, height: 300), anchor: nil)
        host.passing(.scrollWheel, at: CGPoint(x: 150, y: 150))
        #expect(host.open != nil)
        host.passing(.scrollWheel, at: CGPoint(x: 600, y: 600))
        #expect(host.open == nil)
    }
}

struct ColorTests {
    @Test func hexAndHSBRoundTrip() {
        let c = RGBA(hex: "#3559C7")!
        #expect(c.hex == "3559C7")
        let (h, s, b) = c.hsb
        #expect(RGBA(h: h, s: s, b: b).hex == "3559C7")
        #expect(RGBA(hex: "fff")?.hex == "FFFFFF")
        #expect(RGBA(hex: "nope") == nil)
    }
}
