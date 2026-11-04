import Testing
import AppKit
@testable import Bezzle

/// Masks taken through everything that can happen to one: made from the menus, by resting a layer
/// over a shape and from the offered word; reordered, moved, resized, turned, flipped, cut, put in
/// grids and decks; clicked, dragged into and out of; drawn, exported, saved, shared and driven by
/// the assistant. Each test says what a person would expect to see. See `Mask` and `MaskTool`.
///
/// The tests that rest a drag spin `RunLoop.main` for the moment it takes a shape to open, so they
/// stay synchronous.
@MainActor
struct MaskSuiteTests {
    // MARK: - Fixtures

    /// On artboard A at 100,100: a red rectangle "Photo" at 10,10 sized 200 × 120, and over it a
    /// grey ellipse "Window" at 60,30 sized 80 × 80 with a black border, then `more`. On the canvas
    /// the photo is at 110,110 and the window at 160,130, its middle at 200,170.
    private func photoAndWindow(_ more: [Node] = []) -> Bench {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.border = Border(on: true, color: .black, width: 4, position: .center)
        return Bench(extra: [photo, window] + more)
    }

    /// The same with the window holding the photo, made from the menu, and the mask selected.
    private func masked(_ more: [Node] = []) throws -> (Bench, Node) {
        let bench = photoAndWindow(more)
        bench.store.selection = [id(bench, "Photo"), id(bench, "Window")]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(bench.a.children.first { $0.isMask })
        return (bench, mask)
    }

    /// The window on A as above, and the photo below it, clear of it: on the canvas at 110,260.
    private func photoBelowWindow() -> Bench {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 160, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.border = Border(on: true, color: .black, width: 4, position: .center)
        return Bench(extra: [photo, window])
    }

    /// A blue square on A at 120,60, partly over the window: 220,160 on the canvas.
    private func sticker() -> Node {
        var s = CanvasTests.rect("Sticker", CGRect(x: 120, y: 60, width: 60, height: 60))
        s.fill.color = RGBA(r: 0, g: 0, b: 1)
        return s
    }

    /// The id of the layer so named; a made-up one when there is none, so the test fails rather than traps.
    private func id(_ bench: Bench, _ name: String) -> UUID { bench.node(name)?.id ?? UUID() }

    private func absolute(_ bench: Bench, _ name: String) -> CGRect? {
        bench.store.doc.absoluteFrame(of: id(bench, name))
    }

    private func masks(_ bench: Bench) -> [Node] { bench.store.doc.allNodes.filter(\.isMask) }

    /// What is wrong with any mask in the design: one holding fewer than two layers, or held by
    /// something that is no shape lying flat. Empty when every mask is as a mask should be.
    private func broken(_ doc: BezzleDocument) -> [String] {
        doc.allNodes.filter(\.isMask).compactMap { m in
            if m.children.count < 2 { return "\(m.name) holds \(m.children.map(\.name))" }
            if let h = m.holder, !Mask.canHold(h) { return "\(m.name) is held by \(h.name), a \(h.kind)" }
            return nil
        }
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 220 && p.g < 80 && p.b < 80 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 235 && p.g > 235 && p.b > 235 }

    // MARK: - What can be masked

    @Test func oneLayerOrALockedOneIsNoMask() {
        let bench = photoAndWindow()
        bench.store.selection = [id(bench, "Window")]
        #expect(bench.store.maskPlan == nil)
        bench.step { bench.store.setLocked(true, [id(bench, "Photo")]) }
        bench.store.selection = [id(bench, "Photo"), id(bench, "Window")]
        #expect(bench.store.maskPlan == nil, "a locked layer is not pulled into a mask")
    }

    @Test func layersOnTwoArtboardsAreNoMask() {
        let bench = photoAndWindow()
        let photo = id(bench, "Photo")
        // Onto B in the layers list, where it still lies over the window on the canvas.
        bench.step { bench.store.move(photo, to: bench.b.id, at: 0) }
        bench.store.selection = [photo, id(bench, "Window")]
        #expect(bench.store.maskPlan == nil)
    }

    @Test func withoutAShapeLyingFlatNothingCanHold() {
        var word = Node(kind: .text, name: "Word", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        word.text = "Hello"
        word.refit()
        var tilted = Node(kind: .ellipse, name: "Tilted", frame: CGRect(x: 10, y: 10, width: 80, height: 80))
        tilted.transform3D = Transform3D(x: 30, y: 0, z: 0)
        let bench = Bench(extra: [word, tilted])
        bench.store.selection = [word.id, tilted.id]
        #expect(bench.store.maskPlan == nil)
    }

    @Test func ofTwoPlainShapesTheFrontOneHolds() throws {
        let back = CanvasTests.rect("Back", CGRect(x: 10, y: 10, width: 100, height: 100))
        let front = Node(kind: .ellipse, name: "Front", frame: CGRect(x: 60, y: 60, width: 100, height: 100))
        let bench = Bench(extra: [back, front])
        let plan = try #require(DocumentStore.maskPlan([back.id, front.id], in: bench.store.doc))
        #expect(plan.shape == front.id)
        #expect(plan.held == [back.id])
    }

    @Test func aMaskPickedWithMoreTakesThemOnTopOfWhatItHolds() throws {
        let (bench, mask) = try masked([sticker()])
        let sticker = id(bench, "Sticker")
        let before = absolute(bench, "Sticker")
        bench.store.selection = [mask.id, sticker]
        #expect(bench.store.maskPlan?.shape == mask.id)
        bench.step { bench.store.maskSelection() }
        #expect(bench.store.node(mask.id)?.children.map(\.name) == ["Window", "Photo", "Sticker"])
        #expect(absolute(bench, "Sticker") == before)
        #expect(bench.store.selection == [mask.id])
        #expect(masks(bench).count == 1)
    }

    @Test func newMasksAreNumberedAndTheirShapesKeepTheirNames() throws {
        let card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 250, y: 150, width: 100, height: 100))
        let pic = CanvasTests.rect("Pic", CGRect(x: 230, y: 170, width: 60, height: 40))
        let (bench, mask) = try masked([card, pic])
        bench.step { bench.store.mask(MaskPlan(shape: card.id, held: [pic.id])) }
        #expect(mask.name == "Mask 1")
        #expect(Set(masks(bench).map(\.name)) == ["Mask 1", "Mask 2"])
        #expect(Set(masks(bench).compactMap(\.holder?.name)) == ["Window", "Card"])
    }

    @Test func aMaskMadeInAGroupStaysInTheGroup() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        let window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 50, y: 20, width: 80, height: 80))
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        group.children = [photo, window]
        let bench = Bench(extra: [group])
        bench.store.selection = [photo.id, window.id]
        bench.step { bench.store.maskSelection() }
        let g = try #require(bench.node("G"))
        #expect(bench.store.doc.parent(of: g.id)?.id == bench.a.id)
        #expect(g.children.count == 1 && g.children.first?.isMask == true)
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func aMaskMadeOffTheArtboardsStaysWhereItIs() throws {
        let bench = Bench()
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 700, y: 500, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        let window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 750, y: 520, width: 80, height: 80))
        bench.step { bench.store.edit("Add") { $0.nodes += [photo, window] } }
        bench.store.selection = [photo.id, window.id]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(bench.store.doc.nodes.first { $0.isMask })
        #expect(mask.frame == CGRect(x: 750, y: 520, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == photo.frame)
        #expect(absolute(bench, "Window") == window.frame)
    }

    @Test func aMaskUndoneAndRedoneIsAsItWasMade() throws {
        let (bench, mask) = try masked()
        let made = bench.store.doc
        bench.undo.undo()
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        bench.undo.redo()
        #expect(bench.store.doc == made)
        #expect(bench.store.node(mask.id)?.isMask == true)
    }

    // MARK: - Keeping a mask a mask

    @Test func theShapeStaysFirstWhereverItOrWhatItHoldsIsArranged() throws {
        let (bench, mask) = try masked([sticker()])
        bench.step { bench.store.mask(MaskPlan(shape: mask.id, held: [id(bench, "Sticker")])) }
        bench.store.selection = [id(bench, "Window")]
        for how in [DocumentStore.Arrange.forward, .front] {
            bench.step { bench.store.arrange(how) }
            #expect(bench.store.node(mask.id)?.children.first?.name == "Window", "the shape sent \(how)")
        }
        bench.store.selection = [id(bench, "Sticker")]
        for how in [DocumentStore.Arrange.backward, .back] {
            bench.step { bench.store.arrange(how) }
            #expect(bench.store.node(mask.id)?.children.first?.name == "Window", "what it holds sent \(how)")
        }
        #expect(broken(bench.store.doc).isEmpty)
    }

    @Test func aLayerDroppedUnderTheShapeInTheLayersListIsHeldOverIt() throws {
        let (bench, mask) = try masked([sticker()])
        let before = absolute(bench, "Sticker")
        bench.step { bench.store.move(id(bench, "Sticker"), to: mask.id, at: 0) }
        #expect(bench.store.node(mask.id)?.children.map(\.name) == ["Window", "Sticker", "Photo"])
        #expect(absolute(bench, "Sticker") == before)
    }

    @Test func aLayerDroppedOntoAMaskInTheLayersListGoesOnTopInside() throws {
        let (bench, mask) = try masked([sticker()])
        let before = absolute(bench, "Sticker")
        bench.step { bench.store.move(id(bench, "Sticker"), to: mask.id, at: 2) }
        #expect(bench.store.node(mask.id)?.children.map(\.name) == ["Window", "Photo", "Sticker"])
        #expect(absolute(bench, "Sticker") == before)
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func theShapeDraggedOutInTheLayersListLetsGoOfWhatItHeld() throws {
        let (bench, _) = try masked()
        bench.step { bench.store.move(id(bench, "Window"), to: bench.a.id, at: 1) }
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func theLastLayerDraggedOutInTheLayersListLeavesTheShapeOnItsOwn() throws {
        let (bench, _) = try masked()
        bench.step { bench.store.move(id(bench, "Photo"), to: bench.a.id, at: 0) }
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func aMaskWhoseShapeIsDeletedShowsAllItHeldWhole() throws {
        let (bench, mask) = try masked([sticker()])
        bench.step { bench.store.mask(MaskPlan(shape: mask.id, held: [id(bench, "Sticker")])) }
        let photo = absolute(bench, "Photo"), sticker = absolute(bench, "Sticker")
        bench.store.selection = [id(bench, "Window")]
        bench.step { bench.store.deleteSelection() }
        #expect(masks(bench).isEmpty)
        #expect(absolute(bench, "Photo") == photo)
        #expect(absolute(bench, "Sticker") == sticker)
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        let past = pixel(image, 20, 20)
        #expect(isRed(past), "the photo shows past where the window was: \(past)")
    }

    @Test func everythingInAMaskDeletedLeavesNothingBehind() throws {
        let (bench, _) = try masked()
        bench.store.selection = [id(bench, "Window"), id(bench, "Photo")]
        bench.step { bench.store.deleteSelection() }
        #expect(bench.a.children.isEmpty, "\(bench.a.children.map(\.name))")
    }

    @Test func nestedMasksBothLosingTheirShapesComeApartInsideOut() throws {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 20, width: 60, height: 100))
        card.fill.on = false
        let (bench, mask) = try masked([card])
        bench.step { bench.store.mask(MaskPlan(shape: card.id, held: [mask.id])) }
        #expect(bench.store.doc.parent(of: mask.id)?.isMask == true)
        bench.store.selection = [id(bench, "Window"), id(bench, "Card")]
        bench.step { bench.store.deleteSelection() }
        #expect(bench.a.children.map(\.name) == ["Photo"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    @Test func ungroupingAMaskReleasesIt() throws {
        let (bench, _) = try masked()
        #expect(bench.store.canUngroup)
        bench.step { bench.store.ungroup() }
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Window", "Photo"])
        #expect(Set(bench.store.selection) == [id(bench, "Window"), id(bench, "Photo")])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    @Test func severalTakenOutLieJustAboveTheMaskInTheirOrder() throws {
        let (bench, mask) = try masked([sticker()])
        bench.step { bench.store.mask(MaskPlan(shape: mask.id, held: [id(bench, "Sticker")])) }
        let photo = absolute(bench, "Photo"), sticker = absolute(bench, "Sticker")
        bench.step { bench.store.takeOutOfMask([id(bench, "Sticker"), id(bench, "Photo")]) }
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Window", "Photo", "Sticker"])
        #expect(absolute(bench, "Photo") == photo)
        #expect(absolute(bench, "Sticker") == sticker)
    }

    @Test func groupingLayersInsideAMaskKeepsThemHeld() throws {
        let (bench, mask) = try masked([sticker()])
        bench.step { bench.store.mask(MaskPlan(shape: mask.id, held: [id(bench, "Sticker")])) }
        let photo = absolute(bench, "Photo")
        bench.store.selection = [id(bench, "Photo"), id(bench, "Sticker")]
        bench.step { bench.store.group() }
        let now = try #require(bench.store.node(mask.id))
        #expect(now.isMask)
        #expect(now.children.first?.name == "Window")
        #expect(now.children.count == 2 && now.children.last?.children.map(\.name) == ["Photo", "Sticker"])
        #expect(absolute(bench, "Photo") == photo)
    }

    @Test func aShapeCutInTwoWithTheKnifeStillHoldsWhatItHeld() throws {
        let (bench, _) = try masked()
        let photo = id(bench, "Photo")
        bench.store.selection = [id(bench, "Window")]
        // Straight down through the window's middle.
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 200, y: 100))
        line.addLine(to: CGPoint(x: 200, y: 240))
        let before = try #require(Renderer.image(of: bench.a, scale: 1))
        var cut = false
        bench.step { cut = bench.store.cut(along: line) }
        #expect(cut)
        #expect(bench.store.doc.parent(of: photo)?.isMask == true, "cutting the window must not quietly let the photo show whole")
        // As a framed picture cut through, frame and all: two masks, each a half of the window
        // holding the photo, so what shows is as it was, in two pieces that come apart.
        let all = masks(bench)
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.children.count == 2 && $0.children.last?.name == "Photo" }, "\(all.map { $0.children.map(\.name) })")
        #expect(Set(all.compactMap { $0.holder?.id }) == Set(bench.store.selection), "the pieces are selected")
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        for (x, y) in [(20, 20), (80, 70), (120, 70), (100, 30), (64, 34)] {
            let was = pixel(before, x, y), now = pixel(image, x, y)
            #expect(abs(was.r - now.r) < 30 && abs(was.g - now.g) < 30 && abs(was.b - now.b) < 30, "at \(x),\(y): \(was) before the cut, \(now) after")
        }
        #expect(broken(bench.store.doc).isEmpty, "\(broken(bench.store.doc))")
        bench.undoLast()
        #expect(masks(bench).count == 1)
        #expect(bench.node("Window")?.kind == .ellipse)
    }

    // MARK: - Moving and shaping

    @Test func aMaskMovesWithAllItHolds() throws {
        let (bench, mask) = try masked()
        bench.step { bench.store.nudge(dx: 7, dy: 3) }
        #expect(absolute(bench, "Window") == CGRect(x: 167, y: 133, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == CGRect(x: 117, y: 113, width: 200, height: 120))
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 167, y: 133, width: 80, height: 80))
    }

    @Test func theShapeMovedAloneLeavesWhatItHoldsAndTakesTheMaskAlong() throws {
        let (bench, mask) = try masked()
        bench.store.selection = [id(bench, "Window")]
        bench.step { bench.store.nudge(dx: 20, dy: 0) }
        #expect(absolute(bench, "Window") == CGRect(x: 180, y: 130, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 180, y: 130, width: 80, height: 80))
    }

    @Test func whatItHoldsMovedLeavesTheMaskWhereItsShapeIs() throws {
        let (bench, mask) = try masked()
        bench.store.selection = [id(bench, "Photo")]
        bench.step { bench.store.nudge(dx: -10, dy: 0) }
        #expect(absolute(bench, "Photo") == CGRect(x: 100, y: 110, width: 200, height: 120))
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func resizingAMaskStretchesItsShapeAndWhatItHolds() throws {
        let (bench, mask) = try masked()
        // Its bottom right handle sits at 240,210 on the canvas; pulled half as big again.
        bench.drag(CGPoint(x: 240, y: 210), CGPoint(x: 280, y: 250), flags: [.command])
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 120, height: 120))
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 120, height: 120))
        #expect(absolute(bench, "Photo") == CGRect(x: 85, y: 100, width: 300, height: 180))
        #expect(bench.store.node(mask.id)?.isMask == true)
    }

    @Test func turningAMaskTurnsItsShapeAndWhatItHoldsAboutItsMiddle() throws {
        let (bench, mask) = try masked()
        // Out past the bottom right corner, then round to the bottom left: a quarter turn.
        bench.drag(CGPoint(x: 250, y: 220), CGPoint(x: 150, y: 220), flags: [.shift])
        let window = try #require(bench.node("Window")), photo = try #require(bench.node("Photo"))
        #expect(window.rotation == 90 && photo.rotation == 90, "\(window.rotation), \(photo.rotation)")
        let c = try #require(bench.store.doc.absoluteFrame(of: photo.id)).center
        #expect(abs(c.x - 200) < 0.5 && abs(c.y - 180) < 0.5, "the photo's middle went round the window's: \(c)")
        #expect(bench.store.node(mask.id)?.children.first?.name == "Window")
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func flippingAMaskMirrorsWhatItHoldsAboutItsShape() throws {
        let (bench, mask) = try masked()
        bench.step { bench.store.flip(horizontally: true) }
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == CGRect(x: 90, y: 110, width: 200, height: 120))
        #expect(bench.store.node(mask.id)?.isMask == true)
    }

    // MARK: - Picking

    @Test func aHiddenShapeIsNeverPicked() throws {
        let (bench, mask) = try masked()
        let photo = id(bench, "Photo"), window = id(bench, "Window")
        bench.step { bench.store.update([window], "Hide") { $0.hidden = true } }
        // Just inside the top of the window, where its edge would be taken hold of; the photo shows there.
        bench.store.selection = [photo]
        bench.click(CGPoint(x: 200, y: 134))
        #expect(bench.store.selection == [photo], "the hidden window was picked instead of the photo that shows")
        // On the window's edge up to the right, clear of the mask's own handles.
        bench.store.selection = [mask.id]
        bench.click(CGPoint(x: 226, y: 144), clicks: 2)
        #expect(bench.store.selection == [photo], "a double click into the mask picked the hidden window")
        // Shown again, its edge takes hold of it as before.
        bench.step { bench.store.update([window], "Show") { $0.hidden = false } }
        bench.store.selection = [mask.id]
        bench.click(CGPoint(x: 226, y: 144), clicks: 2)
        #expect(bench.store.selection == [window])
    }

    @Test func returnOnAMaskPicksWhatItHoldsAndEscapeGoesBackOut() throws {
        let (bench, mask) = try masked()
        bench.key(36, "\r")
        #expect(bench.store.selection == [id(bench, "Photo")])
        bench.key(53)
        #expect(bench.store.selection == [mask.id])
    }

    @Test func selectAllInsideAMaskPicksAllItHolds() throws {
        let (bench, _) = try masked()
        bench.store.selection = [id(bench, "Photo")]
        bench.store.selectAll()
        #expect(Set(bench.store.selection) == [id(bench, "Window"), id(bench, "Photo")])
    }

    @Test func aMarqueeOverWhatIsCutOffPicksNothing() throws {
        let (bench, mask) = try masked()
        bench.store.selection = []
        // Over the photo past the window, where nothing of it shows.
        bench.drag(CGPoint(x: 115, y: 215), CGPoint(x: 135, y: 228), flags: [.command])
        #expect(bench.store.selection.isEmpty)
        bench.drag(CGPoint(x: 150, y: 120), CGPoint(x: 175, y: 145), flags: [.command])
        #expect(bench.store.selection == [mask.id])
    }

    // MARK: - Dragging into and out of masks

    @Test func aShapeOpenedByRestingFollowsThePointerUntilLetGo() throws {
        let bench = photoBelowWindow()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 180), flags: [.command], release: false)
        bench.rest()
        #expect(bench.store.doc.parent(of: photo)?.isMask == true, "the window opened")
        // On a little, still over the window.
        bench.pull(CGPoint(x: 200, y: 180), CGPoint(x: 210, y: 190), flags: [.command])
        bench.release(CGPoint(x: 210, y: 190), flags: [.command])
        let mask = try #require(bench.a.children.first { $0.isMask })
        #expect(mask.children.map(\.name) == ["Window", "Photo"])
        #expect(absolute(bench, "Photo") == CGRect(x: 170, y: 150, width: 200, height: 120))
        #expect(absolute(bench, "Window") == CGRect(x: 160, y: 130, width: 80, height: 80))
        #expect(bench.store.selection == [mask.id])
    }

    @Test func draggedOffTheShapeItOpenedNothingIsMasked() throws {
        let bench = photoBelowWindow()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 180), flags: [.command], release: false)
        bench.rest()
        bench.pull(CGPoint(x: 200, y: 180), CGPoint(x: 150, y: 330), flags: [.command])
        bench.release(CGPoint(x: 150, y: 330), flags: [.command])
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 290, width: 200, height: 120))
        bench.undoLast()
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 260, width: 200, height: 120))
    }

    @Test func escapeWhileAShapeIsOpenPutsItAllBack() {
        let bench = photoBelowWindow()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 180), flags: [.command], release: false)
        bench.rest()
        bench.key(53)
        bench.release(CGPoint(x: 200, y: 180), flags: [.command])
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 260, width: 200, height: 120))
        // Nothing happened, so an undo now changes nothing. (The bench leaves an empty undo group
        // for every step, so whether there is one to take says nothing here.)
        let after = bench.store.doc
        if bench.undo.canUndo { bench.undoLast() }
        #expect(bench.store.doc == after, "undoing after Escape changed the design: \(bench.a.children.map(\.name)), photo at \(absolute(bench, "Photo").map { "\($0)" } ?? "nowhere")")
    }

    @Test func oneUndoTakesBackAMaskMadeByResting() {
        let bench = photoBelowWindow()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 180), flags: [.command], release: false)
        bench.rest()
        bench.release(CGPoint(x: 200, y: 180), flags: [.command])
        #expect(masks(bench).count == 1)
        bench.undoLast()
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 260, width: 200, height: 120))
    }

    @Test func oneUndoPutsWhatWasDraggedOutOfAMaskBackIn() throws {
        let (bench, mask) = try masked()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 200, y: 300), flags: [.command])
        #expect(masks(bench).isEmpty)
        #expect(bench.undo.undoActionName == String(localized: DocumentStore.takingOut))
        bench.undoLast()
        #expect(bench.store.doc.parent(of: photo)?.id == mask.id)
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    @Test func aMaskRestedOverAnotherShapeGoesInsideItWhole() throws {
        let card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 250, y: 150, width: 140, height: 120))
        let (bench, mask) = try masked([card])
        // Over the card, partly past its left edge.
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 380, y: 290), flags: [.command], release: false)
        bench.rest()
        bench.release(CGPoint(x: 380, y: 290), flags: [.command])
        let outer = try #require(bench.a.children.first { $0.isMask && $0.holder?.name == "Card" })
        #expect(outer.children.map(\.name) == ["Card", "Mask 1"])
        #expect(bench.store.node(mask.id)?.children.map(\.name) == ["Window", "Photo"])
        #expect(absolute(bench, "Window") == CGRect(x: 340, y: 250, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == CGRect(x: 290, y: 230, width: 200, height: 120))
    }

    @Test func nothingOpensWhereOnlyTheArtboardCutsOffWhatSticksOut() {
        // A card at A's right edge, and a photo dragged over it reaching past it only beyond that edge.
        let card = CanvasTests.rect("Card", CGRect(x: 300, y: 50, width: 100, height: 100))
        let photo = CanvasTests.rect("Photo", CGRect(x: 250, y: 220, width: 80, height: 40))
        let bench = Bench(extra: [card, photo])
        bench.store.selection = [photo.id]
        bench.drag(CGPoint(x: 360, y: 340), CGPoint(x: 460, y: 195), flags: [.command], release: false)
        bench.rest()
        bench.release(CGPoint(x: 460, y: 195), flags: [.command])
        #expect(masks(bench).isEmpty)
    }

    @Test func whatAMaskHoldsDraggedOffAndBackStaysIn() throws {
        let (bench, mask) = try masked()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        // Wholly off the window, then back over it before letting go.
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 200, y: 300), flags: [.command], release: false)
        bench.pull(CGPoint(x: 200, y: 300), CGPoint(x: 200, y: 175), flags: [.command])
        bench.release(CGPoint(x: 200, y: 175), flags: [.command])
        #expect(bench.store.doc.parent(of: photo)?.id == mask.id)
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 115, width: 200, height: 120))
    }

    @Test func whatAMaskHoldsDraggedOntoAnotherArtboardComesOutOntoIt() throws {
        let (bench, _) = try masked()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 700, y: 170), flags: [.command])
        #expect(masks(bench).isEmpty)
        #expect(bench.store.doc.parent(of: photo)?.id == bench.b.id)
        #expect(absolute(bench, "Photo") == CGRect(x: 610, y: 110, width: 200, height: 120))
        #expect(bench.store.doc.parent(of: id(bench, "Window"))?.id == bench.a.id)
    }

    @Test func theShapeTakenByItsEdgeMovesAloneAndTheMaskGoesWithIt() throws {
        let (bench, mask) = try masked()
        bench.store.selection = [id(bench, "Photo")]
        // Just inside the window's top, on the band along its outline.
        bench.drag(CGPoint(x: 200, y: 134), CGPoint(x: 220, y: 144), flags: [.command])
        #expect(absolute(bench, "Window") == CGRect(x: 180, y: 140, width: 80, height: 80))
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 180, y: 140, width: 80, height: 80))
        #expect(bench.store.node(mask.id)?.isMask == true)
    }

    @Test func optionDraggingAMaskLeavesItAndMovesAMaskedCopy() throws {
        let (bench, mask) = try masked()
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 360, y: 170), flags: [.option, .command])
        let all = bench.a.children.filter(\.isMask)
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.children.map(\.name) == ["Window", "Photo"] })
        let copy = try #require(all.first { $0.id != mask.id })
        #expect(bench.store.doc.absoluteFrame(of: copy.id) == CGRect(x: 320, y: 130, width: 80, height: 80))
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
        #expect(broken(bench.store.doc).isEmpty)
    }

    @Test func optionDraggingWhatAMaskHoldsCopiesItInsideIt() throws {
        let (bench, mask) = try masked()
        let photo = id(bench, "Photo")
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 200, y: 170), CGPoint(x: 210, y: 175), flags: [.option, .command])
        let now = try #require(bench.store.node(mask.id))
        #expect(now.children.map(\.name) == ["Window", "Photo", "Photo"])
        #expect(bench.store.doc.absoluteFrame(of: photo) == CGRect(x: 110, y: 110, width: 200, height: 120))
        let copy = try #require(now.children.last)
        #expect(bench.store.doc.absoluteFrame(of: copy.id) == CGRect(x: 120, y: 115, width: 200, height: 120))
    }

    // MARK: - The word offered

    @Test func aShapeDrawnOverAPictureOffersToMaskItAndAPressMakesIt() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.image = ImageFill(asset: "p.jpg", mode: .cover, size: CGSize(width: 400, height: 240))
        let bench = Bench(extra: [photo])
        bench.store.tool = .rectangle
        bench.drag(CGPoint(x: 150, y: 140), CGPoint(x: 250, y: 200), flags: [.command])
        let drawn = try #require(bench.store.selection.first)
        drawOverlays(bench)
        // The word sits over all it is about, the photo from 110 down and 110...310 across: its
        // middle 26 points above that.
        bench.click(CGPoint(x: 210, y: 84))
        let mask = try #require(bench.a.children.first { $0.isMask })
        #expect(mask.holder?.id == drawn)
        #expect(mask.children.map(\.id) == [drawn, photo.id])
        #expect(bench.store.selection == [mask.id])
    }

    /// Draws what the mask tool lays over the canvas once, which places the word it offers, as
    /// the canvas does every frame in the app.
    private func drawOverlays(_ bench: Bench) {
        guard let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let was = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        bench.canvas.maskTool.draw(ctx, scale: 1, in: bench.canvas.bounds)
        NSGraphicsContext.current = was
    }

    // MARK: - Drawing

    @Test func aTurnedShapeCutsAlongItsTurnedOutline() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var diamond = Node(kind: .rectangle, name: "Diamond", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        diamond.rotation = 45
        diamond.fill.on = false
        let bench = Bench(extra: [photo, diamond])
        bench.store.selection = [photo.id, diamond.id]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(bench.a.children.first { $0.isMask })
        // As big as the diamond lies: its square turned on its corner.
        let side = 80 * 2.0.squareRoot()
        #expect(abs(mask.frame.width - side) < 0.5 && abs(mask.frame.midX - 100) < 0.5 && abs(mask.frame.midY - 70) < 0.5, "\(mask.frame)")
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isRed(pixel(image, 100, 70)))
        #expect(isRed(pixel(image, 100, 20)), "near the diamond's top point")
        #expect(isWhite(pixel(image, 64, 34)), "inside the square before it was turned, outside the diamond: \(pixel(image, 64, 34))")
    }

    @Test func aShapeWithNothingFilledStillCutsOff() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.fill.on = false
        let bench = Bench(extra: [photo, window])
        bench.store.selection = [photo.id, window.id]
        bench.step { bench.store.maskSelection() }
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isRed(pixel(image, 100, 70)))
        #expect(isWhite(pixel(image, 20, 20)), "\(pixel(image, 20, 20))")
        #expect(isWhite(pixel(image, 65, 35)), "inside the window's box, past its round edge: \(pixel(image, 65, 35))")
    }

    @Test func theShapesShadowFallsUnderWhatItHoldsAndOutPastIt() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.fill.color = RGBA(r: 1, g: 1, b: 1)
        window.shadow = Shadow(on: true, color: .black, x: 0, y: 30, blur: 0)
        let bench = Bench(extra: [photo, window])
        bench.store.selection = [photo.id, window.id]
        bench.step { bench.store.maskSelection() }
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isRed(pixel(image, 100, 70)), "the photo lies over the shadow inside the window")
        let below = pixel(image, 100, 125)
        #expect(below.r < 60 && below.g < 60 && below.b < 60, "the shadow falls past the window, where the photo is cut off: \(below)")
    }

    @Test func aMaskInsideAMaskIsCutOffAtBothOutlines() throws {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 20, width: 60, height: 100))
        card.fill.on = false
        let (bench, mask) = try masked([card])
        bench.step { bench.store.mask(MaskPlan(shape: card.id, held: [mask.id])) }
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isRed(pixel(image, 80, 70)), "inside both")
        #expect(isWhite(pixel(image, 120, 70)), "inside the window but past the card: \(pixel(image, 120, 70))")
    }

    @Test func aShapeTurnedInDepthCutsWhereItShows() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.fill.color = RGBA(r: 0, g: 0, b: 1)
        let bench = Bench(extra: [photo, window])
        bench.store.selection = [photo.id, window.id]
        bench.step { bench.store.maskSelection() }
        // The window turned 60° about its upright middle, as the depth knob does: seen edge on,
        // it shows about half as wide, some 20 points either side of its middle at 100,70.
        bench.step { bench.store.update([window.id], "Turn in Depth") { $0.transform3D = Transform3D(x: 0, y: 60, z: 0) } }
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isRed(pixel(image, 100, 70)), "the photo shows through the middle of the window")
        if bench.node("Window")?.transform3D != nil {
            for x in [135, 70] {
                #expect(!isRed(pixel(image, x, 70)), "at \(x),70 the turned window no longer shows, yet the photo does: \(pixel(image, x, 70))")
            }
        }
    }

    @Test func aPieceOfTheArtboardShowsAMaskAsTheWholeDoes() throws {
        let (bench, _) = try masked()
        let whole = try #require(Renderer.image(of: bench.a, scale: 1))
        // Only the right half of the window lies in the piece, as in a tile of the canvas.
        let part = CGRect(x: 200, y: 100, width: 120, height: 150)
        let piece = try #require(Renderer.image(of: bench.a, part: part, scale: 1))
        for p in [CGPoint(x: 220, y: 170), CGPoint(x: 260, y: 150), CGPoint(x: 290, y: 120), CGPoint(x: 239, y: 170), CGPoint(x: 205, y: 225)] {
            let a = pixel(whole, Int(p.x - 100), Int(p.y - 100)), b = pixel(piece, Int(p.x - part.minX), Int(p.y - part.minY))
            #expect(abs(a.r - b.r) < 8 && abs(a.g - b.g) < 8 && abs(a.b - b.b) < 8, "at \(p): \(a) drawn whole, \(b) in the piece")
        }
    }

    // MARK: - Export and files

    @Test func aMaskExportedOnItsOwnIsAsBigAsItsShape() throws {
        let (bench, mask) = try masked()
        let item = try #require(ExportItem(layer: mask.id, in: bench.store.doc))
        let r = item.bounds(assets: nil)
        // The window and its border, two points out all round; nothing of the photo cut off past it.
        #expect(r.width >= 80 && r.width <= 86 && r.height >= 80 && r.height <= 86, "\(r)")
    }

    @Test func twoMasksGoOutToSVGEachWithItsOwnClip() throws {
        let (bench, _) = try masked()
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 150, y: 0)) }
        #expect(masks(bench).count == 2)
        let board = ExportItem(artboard: bench.a)
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: nil), assets: nil)
        let defined = captures(#"<clipPath id="([^"]+)""#, in: svg)
        let used = captures(#"clip-path="url\(#([^)]+)\)""#, in: svg)
        #expect(Set(defined).count == defined.count, "clip ids given twice: \(defined)")
        #expect(Set(used).count >= 2, "each mask cuts by its own outline: \(used)")
        #expect(Set(used).isSubset(of: Set(defined)))
        #expect(XMLParser(data: Data(svg.utf8)).parse())
    }

    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    @Test func aMaskSavedAndOpenedAgainIsStillAMask() throws {
        let (bench, mask) = try masked()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MaskSuite-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(bench.store.doc, to: url)
        let back = try DesignFile.read(url)
        #expect(back.node(mask.id)?.isMask == true)
        #expect(back.node(mask.id)?.children.map(\.name) == ["Window", "Photo"])
        #expect(back.absoluteFrame(of: id(bench, "Photo")) == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    // MARK: - Repeat grids and decks

    @Test func aRepeatGridOfAMaskRepeatsItAndKeepsEveryShapeFirst() throws {
        let (bench, mask) = try masked()
        bench.store.selection = [mask.id]
        bench.step { bench.store.makeRepeatGrid() }
        let grid = try #require(bench.store.selection.first)
        bench.step { bench.store.changeGrid(grid, "Repeat") { $0.columns = 3 } }
        let cells = try #require(bench.store.node(grid)).children
        #expect(cells.count == 3)
        #expect(cells.allSatisfy { $0.isMask && $0.children.map(\.name) == ["Window", "Photo"] }, "\(cells.map { $0.children.map(\.name) })")
        // Sent to the back in one cell, the photo stays over its window in every cell.
        let second = try #require(cells.dropFirst().first?.children.last)
        bench.store.selection = [second.id]
        bench.step { bench.store.arrange(.back) }
        let after = try #require(bench.store.node(grid)).children
        #expect(after.allSatisfy { $0.isMask && $0.children.first?.name == "Window" }, "\(after.map { $0.children.map(\.name) })")
        #expect(broken(bench.store.doc).isEmpty, "\(broken(bench.store.doc))")
    }

    @Test func maskingInThePostInFrontMasksTheSameInEveryPost() throws {
        let bench = photoAndWindow()
        bench.step { bench.store.addPost(to: bench.a.id) }
        let deck = bench.a
        let front = try #require(bench.store.front(of: deck))
        bench.store.selection = deck.layers(of: front).map(\.id)
        #expect(bench.store.canMask)
        bench.step { bench.store.maskSelection() }
        let now = bench.a
        #expect(now.posts.count == 2)
        for post in now.posts {
            let layers = now.layers(of: post)
            #expect(layers.count == 1 && layers.first?.isMask == true, "post \(post): \(layers.map(\.name))")
            #expect(layers.first?.children.map(\.name) == ["Window", "Photo"], "post \(post)")
        }
        #expect(broken(bench.store.doc).isEmpty, "\(broken(bench.store.doc))")
    }

    // MARK: - Sharing

    /// A board with the window holding `held` of the photo and the sticker; the rest lie on the board.
    private func sharedMask(holding held: [String]) -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        let window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        board.children = [photo, window, sticker()]
        var doc = BezzleDocument()
        doc.nodes = [board]
        let before = doc
        let ids = board.children.filter { held.contains($0.name) }.map(\.id)
        DocumentStore.mask(MaskPlan(shape: window.id, held: ids), in: &doc)
        doc.keepMasks(since: before)
        doc.fitGroups()
        return doc
    }

    private func named(_ doc: BezzleDocument, _ name: String) -> Node? { doc.allNodes.first { $0.name == name } }

    @Test func twoPeopleEachTakingALayerOutLeaveNoMaskHoldingNothing() throws {
        let start = sharedMask(holding: ["Photo", "Sticker"])
        var a = Peer("a", doc: start)
        var b = Peer("b")
        b.receive(a.state)
        let photo = try #require(named(start, "Photo")).id, sticker = try #require(named(start, "Sticker")).id
        // Each on their own Mac sees a mask still holding one layer, so neither takes it apart.
        a.edit { DocumentStore.takeOut([photo], in: &$0) }
        b.edit { DocumentStore.takeOut([sticker], in: &$0) }
        #expect(a.doc.allNodes.contains(where: \.isMask) && b.doc.allNodes.contains(where: \.isMask))
        var peers = [a, b]
        Peer.sync(&peers)
        let doc = peers[0].doc
        #expect(doc == peers[1].doc)
        #expect(broken(doc).isEmpty, "after both took one out: \(broken(doc))")
        #expect(doc.absoluteFrame(of: photo) == CGRect(x: 10, y: 10, width: 200, height: 120))
        #expect(doc.absoluteFrame(of: sticker) == CGRect(x: 120, y: 60, width: 60, height: 60))
    }

    @Test func aLayerPutInAMaskWhoseShapeSomeoneDeletedIsNotHeldByWhatIsLeft() throws {
        let start = sharedMask(holding: ["Photo"])
        var a = Peer("a", doc: start)
        var b = Peer("b")
        b.receive(a.state)
        let window = try #require(named(start, "Window")).id, sticker = try #require(named(start, "Sticker")).id
        let made = start.allNodes.first { $0.isMask }
        let mask = try #require(made).id
        // One deletes the window, which lets the photo go; the other meanwhile drops the sticker in.
        a.edit { _ = $0.detach(window) }
        b.edit { doc in
            if let s = doc.detach(sticker) { doc.attach(s, to: mask) }
        }
        var peers = [a, b]
        Peer.sync(&peers)
        let doc = peers[0].doc
        #expect(doc == peers[1].doc)
        #expect(broken(doc).isEmpty, "\(broken(doc))")
        let holders = doc.allNodes.filter(\.isMask).compactMap(\.holder?.name)
        #expect(holders.allSatisfy { $0 == "Window" }, "a mask is held by what it was given to hold: \(holders)")
        #expect(named(doc, "Photo") != nil && named(doc, "Sticker") != nil)
    }

    @Test func layersDroppedInWhileSomeoneTookTheShapeAwayAreNotHeldByTheFirstOfThem() throws {
        // Here, two stickers were dropped into the mask; meanwhile someone else deleted its window
        // and took the photo out, which took the mask apart on their Mac.
        let (bench, mask) = try masked([sticker()])
        // On the canvas, as `add` takes it.
        var other = CanvasTests.rect("Other", CGRect(x: 230, y: 180, width: 40, height: 40))
        other.fill.color = RGBA(r: 0, g: 1, b: 0)
        bench.step { bench.store.add(other, onto: bench.a.id) }
        bench.step { bench.store.mask(MaskPlan(shape: mask.id, held: [id(bench, "Sticker"), id(bench, "Other")])) }
        let mine = bench.store.doc
        // What comes in: the group back with only the stickers in it, still a mask.
        var theirs = mine
        let window = id(bench, "Window"), photo = id(bench, "Photo")
        if let w = theirs.detach(window) { _ = w }
        if let p = theirs.detach(photo) { theirs.attach(p, to: bench.a.id, at: 0) }
        #expect(theirs.node(mask.id)?.holder?.name == "Sticker", "as the merge leaves it")
        bench.store.showChangesFromOthers(theirs)
        let doc = bench.store.doc
        #expect(doc.allNodes.filter(\.isMask).isEmpty, "the sticker became the shape: \(doc.allNodes.filter(\.isMask).map { $0.children.map(\.name) })")
        #expect(doc.absoluteFrame(of: id(bench, "Sticker")) == CGRect(x: 220, y: 160, width: 60, height: 60))
        #expect(doc.absoluteFrame(of: id(bench, "Other")) == CGRect(x: 230, y: 180, width: 40, height: 40))
    }

    // MARK: - The assistant

    private func call(_ tools: MCPTools, _ bench: Bench, _ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    @Test func theAssistantMasksAndReleasesAsTheMenusDo() async throws {
        let bench = photoAndWindow()
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let made = await call(tools, bench, "mask_layers", ["layers": ["Photo", "Window"]])
        #expect(!made.failed, "\(made.text)")
        let mask = try #require(bench.a.children.first { $0.isMask })
        #expect(mask.children.map(\.name) == ["Window", "Photo"])
        // As the tool says it answers: the group it made marked as a mask, so it is told from a plain group.
        let answer = (try? JSONSerialization.jsonObject(with: Data(made.text.utf8))) as? [String: Any]
        let described = (answer?["layers"] as? [[String: Any]])?.first
        #expect(described?["mask"] as? Bool == true, "\(made.text)")
        let freed = await call(tools, bench, "release_mask", ["layers": [mask.name]])
        #expect(!freed.failed, "\(freed.text)")
        #expect(bench.a.children.map(\.name) == ["Window", "Photo"])
        #expect(absolute(bench, "Photo") == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    @Test func theAssistantTakingOutTheLastLayerLeavesTheShape() async throws {
        let (bench, _) = try masked()
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let answer = await call(tools, bench, "release_mask", ["layers": ["Photo"]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(masks(bench).isEmpty)
        #expect(bench.a.children.map(\.name) == ["Window", "Photo"])
    }

    @Test func theAssistantAddsToAMaskOnTopOfWhatItHolds() async throws {
        let (bench, mask) = try masked([sticker()])
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let answer = await call(tools, bench, "mask_layers", ["layers": ["Sticker"], "shape": "Mask 1"])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.store.node(mask.id)?.children.map(\.name) == ["Window", "Photo", "Sticker"])
    }

    @Test func theAssistantCannotPullALockedLayerIntoAMask() async {
        let bench = photoAndWindow()
        let photo = id(bench, "Photo")
        bench.step { bench.store.setLocked(true, [photo]) }
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let answer = await call(tools, bench, "mask_layers", ["layers": ["Photo"], "shape": "Window"])
        #expect(bench.store.doc.parent(of: photo)?.isMask != true, "a locked layer went into a mask: \(answer.text)")
        #expect(answer.failed && answer.text.contains("locked"), "\(answer.text)")
        // Nor does a locked shape hold anything.
        bench.step { bench.store.setLocked(false, [photo]) }
        bench.step { bench.store.setLocked(true, [id(bench, "Window")]) }
        let again = await call(tools, bench, "mask_layers", ["layers": ["Photo"], "shape": "Window"])
        #expect(again.failed && masks(bench).isEmpty, "\(again.text)")
    }
}

// MARK: - Helpers

/// Drags that change course: pressed, moved one way, held, then on another way before letting go.
@MainActor
private extension Bench {
    func mouseEvent(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let inWindow = canvas.convert(store.viewport.toView(p), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The pointer, still held down, moved on from `from` to `to` in a few steps.
    func pull(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = []) {
        step {
            for i in 1...4 {
                let t = CGFloat(i) / 4
                canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), flags: flags))
            }
        }
    }

    /// Held still as long as it takes a shape to open under what is dragged.
    func rest() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    }
}

/// One Mac's copy of a shared design, as `Collaboration` keeps it without iCloud; changes made on
/// it go through what `DocumentStore.edit` does to every change, and what comes in from others
/// is shown as it comes, as `showChangesFromOthers` shows it.
private struct Peer {
    let name: String
    var state = SharedDesign()
    var base = FlatDesign()
    var doc = BezzleDocument()
    var time: Int64 = 1_000

    init(_ name: String, doc: BezzleDocument = BezzleDocument()) {
        self.name = name
        self.doc = doc
        commit()
    }

    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    mutating func edit(_ change: (inout BezzleDocument) -> Void) {
        let before = doc
        change(&doc)
        doc.keepMasks(since: before)
        doc.fitGroups(since: before)
        commit()
    }

    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }

    /// Everyone takes in everyone's copy until nothing changes any more.
    static func sync(_ peers: inout [Peer]) {
        for _ in 0..<4 {
            for i in peers.indices {
                for j in peers.indices where j != i { peers[i].receive(peers[j].state) }
            }
        }
    }
}
