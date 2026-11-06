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

    @Test func flippingALayerTurnsItOverWhereItIs() throws {
        var card = CanvasTests.rect("R", CGRect(x: 10, y: 20, width: 40, height: 30))
        card.corners = [1, 2, 3, 4]
        card.rotation = 30
        card.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .white), GradientStop(offset: 1, color: .black)],
                                      start: CGPoint(x: 0.25, y: 0), end: CGPoint(x: 1, y: 1))
        let bench = Bench(extra: [card])
        bench.store.selection = [bench.node("R")!.id]
        bench.step { bench.store.flip(horizontally: true) }
        var r = try #require(bench.node("R"))
        #expect(abs(r.frame.midX - 30) < 0.001 && abs(r.frame.midY - 35) < 0.001 && r.frame.size == card.frame.size)
        #expect(r.rotation == -30)
        #expect(r.corners == [2, 1, 4, 3])
        #expect(r.fill.gradient?.start == CGPoint(x: 0.75, y: 0) && r.fill.gradient?.end == CGPoint(x: 0, y: 1))
        bench.step { bench.store.flip(horizontally: false) }
        r = try #require(bench.node("R"))
        #expect(r.rotation == 30)
        #expect(r.corners == [3, 4, 1, 2])
        #expect(r.fill.gradient?.start == CGPoint(x: 0.75, y: 1))
        bench.undoLast()
        #expect(bench.node("R")?.corners == [2, 1, 4, 3])
    }

    @Test func flippingSeveralLayersMirrorsThemAcrossTheirMiddle() {
        var shape = Node(kind: .path, name: "P", frame: CGRect(x: 200, y: 100, width: 40, height: 40))
        shape.path = "M 0 0 L 40 0 L 0 40 Z"
        shape.pathBox = CGRect(x: 0, y: 0, width: 40, height: 40)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 100, y: 20, width: 50, height: 50))
        group.children = [Node(kind: .line, name: "L", frame: CGRect(x: 0, y: 0, width: 20, height: 50)),
                          CanvasTests.rect("Dot", CGRect(x: 30, y: 0, width: 20, height: 20))]
        let bench = Bench(extra: [group, shape])
        bench.store.selection = [bench.node("G")!.id, bench.node("P")!.id]
        // Together they reach from x 100 to 240, so they mirror across x 170.
        bench.step { bench.store.flip(horizontally: true) }
        #expect(bench.node("P")?.frame.minX == 100)
        #expect(bench.node("P")?.path == "M 40 0 L 0 0 L 40 40 Z")
        #expect(bench.node("G")?.frame == CGRect(x: 190, y: 20, width: 50, height: 50))
        // What the group holds is mirrored inside it.
        #expect(bench.node("L")?.frame.minX == 30 && bench.node("L")?.rising == true)
        #expect(bench.node("Dot")?.frame.minX == 0)
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

    @Test func groupingPutsTheSelectionInAGroupWhereTheFrontmostWas() {
        let bench = Bench(extra: [CanvasTests.rect("R1", CGRect(x: 10, y: 10, width: 20, height: 20)),
                                  CanvasTests.rect("R2", CGRect(x: 60, y: 40, width: 20, height: 20)),
                                  CanvasTests.rect("R3", CGRect(x: 200, y: 200, width: 10, height: 10))])
        let frames = bench.a.children.map { bench.store.doc.absoluteFrame(of: $0.id) }
        bench.store.selection = [bench.node("R3")!.id, bench.node("R1")!.id]
        #expect(bench.store.canGroup && !bench.store.canUngroup)
        bench.step { bench.store.group() }
        let group = try! #require(bench.node("Group 1"))
        #expect(bench.a.children.map(\.name) == ["R2", "Group 1"])
        #expect(group.children.map(\.name) == ["R1", "R3"])
        #expect(group.frame == CGRect(x: 10, y: 10, width: 200, height: 200))
        #expect(bench.store.selection == [group.id])
        #expect(bench.store.canUngroup)
        bench.step { bench.store.ungroup() }
        #expect(bench.a.children.map(\.name) == ["R2", "R1", "R3"])
        #expect(bench.store.selection.map { bench.store.node($0)?.name } == ["R1", "R3"])
        let after = ["R1", "R2", "R3"].map { bench.store.doc.absoluteFrame(of: bench.node($0)!.id) }
        #expect(after == frames)
        bench.undoLast()
        bench.undoLast()
        #expect(bench.a.children.map(\.name) == ["R1", "R2", "R3"])
    }

    @Test func groupingLayersFromDifferentGroupsGathersThemInWhatHoldsThemAll() {
        var pair = Node(kind: .group, name: "Pair", frame: CGRect(x: 10, y: 10, width: 60, height: 20))
        pair.children = [CanvasTests.rect("Inner", CGRect(x: 0, y: 0, width: 20, height: 20)),
                         CanvasTests.rect("Other", CGRect(x: 40, y: 0, width: 20, height: 20))]
        let bench = Bench(extra: [pair, CanvasTests.rect("Loose", CGRect(x: 100, y: 100, width: 20, height: 20))])
        let inner = bench.node("Inner")!.id, loose = bench.node("Loose")!.id
        let before = [inner, loose].map { bench.store.doc.absoluteFrame(of: $0) }
        bench.store.selection = [loose, inner]
        bench.step { bench.store.group() }
        #expect(bench.a.children.map(\.name) == ["Pair", "Group 1"])
        #expect(bench.node("Pair")?.children.map(\.name) == ["Other"])
        #expect(bench.node("Group 1")?.children.map(\.name) == ["Inner", "Loose"])
        #expect([inner, loose].map { bench.store.doc.absoluteFrame(of: $0) } == before)
        // Not across artboards, and not an artboard itself.
        bench.step { bench.store.add(CanvasTests.rect("OnB", CGRect(x: 0, y: 0, width: 10, height: 10)), onto: bench.b.id) }
        bench.store.selection = [inner, bench.node("OnB")!.id]
        #expect(!bench.store.canGroup)
        bench.store.selection = [bench.a.id]
        #expect(!bench.store.canGroup)
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

    /// One told to keep its layers in place; otherwise its design is laid out again (AdaptTests).
    @Test func resizingAnArtboardLeavesItsContentWhereItWas() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 20, height: 20))])
        bench.step { bench.store.update([bench.a.id], "Keep Layers in Place") { $0.pinsLayers = true } }
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
        host.scrolling(200, at: CGPoint(x: 600, y: 600))
        #expect(host.open != nil)
        host.passing(.leftMouseDown, at: CGPoint(x: 600, y: 600))
        #expect(host.open == nil)
    }

    @Test func scrollingAwayClosesARightClickMenu() {
        let host = MenuHost()
        host.show(at: CGPoint(x: 100, y: 100), entries: [.item("A") {}])
        host.track(menu: CGRect(x: 100, y: 100, width: 200, height: 300), anchor: nil)
        host.scrolling(200, at: CGPoint(x: 150, y: 150))
        #expect(host.open != nil)
        host.scrolling(40, at: CGPoint(x: 600, y: 600))
        #expect(host.open == nil)
    }

    /// Two fingers clicking on a trackpad send scrolls of their own as they land, slide a little
    /// and lift; the menu they opened stays. A real scroll after it, or a wheel's turn, still
    /// closes it.
    @Test func theFingersThatRightClickDoNotCloseTheirMenu() throws {
        func scroll(_ dy: Int32, pixels: Bool = true, phase: Int64 = 0) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
            if phase != 0 { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
            return try #require(NSEvent(cgEvent: cg))
        }
        let away = CGPoint(x: 600, y: 600)
        let host = MenuHost()
        host.show(at: CGPoint(x: 100, y: 100), entries: [.item("A") {}])
        host.track(menu: CGRect(x: 100, y: 100, width: 200, height: 300), anchor: nil)
        // Landing (may begin), sliding a few points as they press, lifting (cancelled).
        for event in [try scroll(0, phase: 128), try scroll(2, phase: 1), try scroll(-3, phase: 2), try scroll(0, phase: 16)] {
            host.scrolling(MenuHost.travel(of: event), at: away)
        }
        #expect(host.open != nil)
        for _ in 0..<4 { host.scrolling(MenuHost.travel(of: try scroll(-6, phase: 2)), at: away) }
        #expect(host.open == nil)

        host.show(at: CGPoint(x: 100, y: 100), entries: [.item("A") {}])
        host.scrolling(MenuHost.travel(of: try scroll(-1, pixels: false)), at: away)
        #expect(host.open == nil)
    }

    private func key(_ characters: String, code: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func typingNarrowsTheFontsMenuBestMatchFirst() {
        let host = MenuHost()
        var previewed: [String] = [], chosen: String?
        let fonts = ["SF Pro", "Arial", "Avenir Next", "Helvetica", "Helvetica Neue", "Times New Roman", "Neue Haas Grotesk", "Didot", "Zapfino"]
        host.toggle("font-family", searchable: true, entries: fonts.map { f in
            .item(.verbatim(f), preview: { if $0 { previewed.append(f) } }) { chosen = f }
        })
        #expect(host.shown.count == fonts.count)
        for c in "neue" { #expect(host.key(key(String(c)))) }
        // Beginning with the words, then a word beginning with them, then holding them anywhere.
        #expect(host.shown.map(\.title) == ["Neue Haas Grotesk", "Helvetica Neue"])
        #expect(host.highlighted == 0)
        #expect(previewed.last == "Neue Haas Grotesk")
        // Delete takes back a letter, arrows move through what is left, Return chooses.
        #expect(host.key(key("\u{7F}", code: 51)))
        #expect(host.query == "neu")
        #expect(host.key(key("\u{F701}", code: 125)))
        #expect(host.key(key("\r", code: 36)))
        #expect(chosen == "Helvetica Neue")
        #expect(host.open == nil)
    }

    @Test func caseAccentsAndLeftOutSpacesDoNotCount() {
        let entries: [MenuEntry] = ["Times New Roman", "Côte", "Avenir"].map { .item(.verbatim($0)) {} }
        #expect(MenuHost.matching(entries, "TIMESNEW").map(\.title) == ["Times New Roman"])
        #expect(MenuHost.matching(entries, "cote").map(\.title) == ["Côte"])
        #expect(MenuHost.matching(entries, "ven").map(\.title) == ["Avenir"])
        #expect(MenuHost.matching(entries, "  ").count == 3)
        #expect(MenuHost.matching(entries, "xyz").isEmpty)
    }

    @Test func escapeClearsTheWordsBeforeItClosesAndDeleteNeverReachesTheCanvas() {
        let host = MenuHost()
        host.toggle("font-family", searchable: true, entries: ["Arial", "Didot"].map { .item(.verbatim($0)) {} })
        // Delete with nothing typed is still the menu's, so the selection on the canvas stays.
        #expect(host.key(key("\u{7F}", code: 51)))
        #expect(host.key(key(" ", code: 49)))
        #expect(host.query.isEmpty)
        #expect(host.key(key("d")))
        #expect(host.shown.map(\.title) == ["Didot"])
        // Shortcuts other than paste go on to the app.
        #expect(!host.key(key("z", code: 6, .command)))
        #expect(host.key(key("\u{1B}", code: 53)))
        #expect(host.open != nil)
        #expect(host.shown.count == 2)
        #expect(host.highlighted == nil)
        #expect(host.key(key("\u{1B}", code: 53)))
        #expect(host.open == nil)
    }

    @Test func aMenuThatDoesNotFilterLeavesTypingToTheApp() {
        let host = MenuHost()
        host.toggle("zoom", entries: [.item("A") {}])
        #expect(!host.key(key("a")))
        #expect(!host.key(key("\u{7F}", code: 51)))
        #expect(host.query.isEmpty)
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
