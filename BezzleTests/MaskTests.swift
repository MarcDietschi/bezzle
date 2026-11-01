import Testing
import AppKit
@testable import Bezzle

/// Masks: a shape holding other layers, as it holds a picture, cut off at its outline.
@MainActor
struct MaskTests {
    /// On artboard A at 100,100: a red rectangle "Photo" 10,10 sized 200 × 120, and over it a
    /// grey ellipse "Window" at 60,30 sized 80 × 80 with a black border.
    private func photoAndWindow() -> Bench {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.color = RGBA(r: 1, g: 0, b: 0)
        var window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        window.border = Border(on: true, color: .black, width: 4, position: .center)
        return Bench(extra: [photo, window])
    }

    private func masked(_ bench: Bench) -> Node? { bench.a.children.first { $0.isMask } }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    @Test func theShapeDrawnOverAPictureHoldsIt() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        let plan = try #require(bench.store.maskPlan)
        #expect(plan.shape == bench.node("Window")!.id)
        bench.step { bench.store.maskSelection() }
        let mask = try #require(masked(bench))
        #expect(bench.store.selection == [mask.id])
        #expect(mask.children.map(\.name) == ["Window", "Photo"])
        // As big as its shape, and nothing moved on the canvas.
        #expect(bench.store.doc.absoluteFrame(of: mask.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
        #expect(bench.store.doc.absoluteFrame(of: bench.node("Photo")!.id) == CGRect(x: 110, y: 110, width: 200, height: 120))
        // One step back is as it was.
        bench.undoLast()
        #expect(masked(bench) == nil)
        #expect(bench.a.children.map(\.name) == ["Photo", "Window"])
    }

    @Test func aPictureOverAPlainShapeGoesInsideIt() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 200, height: 120))
        photo.fill.image = ImageFill(asset: "p.jpg", mode: .cover, size: CGSize(width: 400, height: 240))
        let window = Node(kind: .ellipse, name: "Window", frame: CGRect(x: 60, y: 30, width: 80, height: 80))
        let bench = Bench(extra: [window, photo])
        let plan = try #require(DocumentStore.maskPlan([photo.id, window.id], in: bench.store.doc))
        #expect(plan.shape == window.id)
        #expect(plan.held == [photo.id])
    }

    @Test func layersThatDoNotOverlapAreNoMask() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 0, y: 0, width: 20, height: 20)),
                                  CanvasTests.rect("S", CGRect(x: 100, y: 100, width: 20, height: 20))])
        bench.store.selection = [bench.node("R")!.id, bench.node("S")!.id]
        #expect(bench.store.maskPlan == nil)
    }

    @Test func whatAMaskHoldsIsCutOffAtItsOutlineAndItsBorderLiesOver() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let image = try #require(Renderer.image(of: bench.a, scale: 1))
        // The middle of the window shows the photo; past it, the photo is gone.
        let inside = pixel(image, 100, 70), outside = pixel(image, 20, 20), corner = pixel(image, 65, 35)
        #expect(inside.r > 240 && inside.g < 80 && inside.b < 80, "\(inside)")
        #expect(outside.r > 240 && outside.g > 240, "\(outside)")
        #expect(corner.g > 240, "past the round edge, inside its box: \(corner)")
        // The border is over the photo, not under it.
        let edge = pixel(image, 100, 30)
        #expect(edge.r < 40 && edge.g < 40, "\(edge)")
    }

    @Test func aMaskIsPickedOnlyWhereItsShapeIs() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(masked(bench))
        #expect(Geometry.contains(mask, CGPoint(x: 100, y: 70), tolerance: 0))
        #expect(!Geometry.contains(mask, CGPoint(x: 20, y: 20), tolerance: 0))
        bench.store.selection = []
        bench.click(CGPoint(x: 120, y: 120))
        #expect(bench.store.selection == [], "the photo past the window no longer shows, so it is not there to click")
        bench.click(CGPoint(x: 200, y: 170))
        #expect(bench.store.selection == [mask.id])
        // A double click inside picks what it holds; one on its edge, the shape.
        bench.click(CGPoint(x: 200, y: 170), clicks: 2)
        #expect(bench.store.selection == [bench.node("Photo")!.id])
        bench.store.selection = [mask.id]
        bench.click(CGPoint(x: 228, y: 142), clicks: 2)
        #expect(bench.store.selection == [bench.node("Window")!.id])
    }

    @Test func theShapeStaysFirstWhateverIsSentBehindIt() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        bench.store.selection = [bench.node("Photo")!.id]
        bench.step { bench.store.arrange(.back) }
        #expect(try #require(masked(bench)).children.first?.name == "Window")
    }

    @Test func aMaskWhoseShapeIsDeletedLetsGoOfWhatItHeld() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        bench.store.selection = [bench.node("Window")!.id]
        bench.step { bench.store.deleteSelection() }
        #expect(masked(bench) == nil)
        #expect(bench.a.children.map(\.name) == ["Photo"])
        #expect(bench.store.doc.absoluteFrame(of: bench.node("Photo")!.id) == CGRect(x: 110, y: 110, width: 200, height: 120))
    }

    @Test func aMaskHoldingNothingMoreIsItsShapeAgain() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        bench.step { bench.store.takeOutOfMask([bench.node("Photo")!.id]) }
        #expect(masked(bench) == nil)
        #expect(bench.a.children.map(\.name) == ["Window", "Photo"])
        #expect(bench.store.selection == [bench.node("Photo")!.id])
    }

    @Test func releasingAMaskLeavesItsShapeUnderWhatItHeld() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(masked(bench))
        bench.step { bench.store.releaseMask(mask.id) }
        #expect(masked(bench) == nil)
        #expect(bench.a.children.map(\.name) == ["Window", "Photo"])
        #expect(bench.store.doc.absoluteFrame(of: bench.node("Window")!.id) == CGRect(x: 160, y: 130, width: 80, height: 80))
    }

    @Test func aNewMaskTakesTheShapesPlaceSoWhatLayOverItStillDoes() throws {
        let card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 20, y: 20, width: 200, height: 150))
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 30, y: 30, width: 0, height: 0))
        title.text = "Hello"
        title.refit()
        let photo = CanvasTests.rect("Photo", CGRect(x: 120, y: 60, width: 200, height: 200))
        let bench = Bench(extra: [card, title, photo])
        bench.step { bench.store.mask(MaskPlan(shape: card.id, held: [photo.id])) }
        #expect(bench.a.children.map(\.name) == ["Mask 1", "Title"])
        #expect(masked(bench)?.children.map(\.name) == ["Card", "Photo"])
    }

    @Test func somethingHeldStillOverAShapeGoesIntoItWhenLetGo() throws {
        let bench = photoAndWindow()
        let photo = bench.node("Photo")!.id
        // Moved off the window first, then dragged back over it so it reaches past it, and held there.
        bench.step { bench.store.edit("Move") { $0.update(photo) { $0.frame.origin = CGPoint(x: 10, y: 160) } } }
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 150, y: 300), CGPoint(x: 200, y: 180), release: false)
        // The moment it rests for.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        bench.release(CGPoint(x: 200, y: 180))
        let mask = try #require(masked(bench))
        #expect(mask.children.map(\.name) == ["Window", "Photo"])
        #expect(bench.store.selection == [mask.id])
        // Moved where it was let go.
        #expect(bench.store.doc.absoluteFrame(of: photo) == CGRect(x: 160, y: 140, width: 200, height: 120))
        #expect(bench.undo.undoActionName == String(localized: DocumentStore.masking))
    }

    @Test func somethingDraggedOnWithoutRestingOnlyMoves() {
        let bench = photoAndWindow()
        let photo = bench.node("Photo")!.id
        bench.store.selection = [photo]
        bench.drag(CGPoint(x: 120, y: 120), CGPoint(x: 130, y: 125))
        #expect(masked(bench) == nil)
    }

    @Test func somethingLyingWhollyInsideAShapeDoesNotOpenIt() throws {
        let big = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 10, y: 10, width: 300, height: 250))
        let icon = CanvasTests.rect("Icon", CGRect(x: 50, y: 50, width: 20, height: 20))
        let bench = Bench(extra: [big, icon])
        bench.store.selection = [icon.id]
        bench.drag(CGPoint(x: 160, y: 160), CGPoint(x: 180, y: 170), release: false)
        // The moment it rests for.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        bench.release(CGPoint(x: 180, y: 170))
        #expect(masked(bench) == nil)
    }

    @Test func whatAMaskHoldsDraggedWhollyOffItComesOut() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let photo = bench.node("Photo")!.id
        bench.store.selection = [photo]
        // Grabbed by its ghost, past the window, and dragged right off it.
        bench.drag(CGPoint(x: 130, y: 125), CGPoint(x: 130, y: 335))
        #expect(masked(bench) == nil)
        #expect(bench.store.doc.parent(of: photo)?.id == bench.a.id)
    }

    @Test func aMaskGoesOutToSVGAsItShows() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let board = ExportItem(artboard: bench.a)
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: nil), assets: nil)
        #expect(svg.contains("<clipPath"))
        #expect(svg.components(separatedBy: "<ellipse").count + svg.components(separatedBy: "<path").count > 3, "the window under, the clip, and its border over")
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse())
    }

    @Test func aMaskComesThroughSharingAsItIs() throws {
        let bench = photoAndWindow()
        bench.store.selection = [bench.node("Photo")!.id, bench.node("Window")!.id]
        bench.step { bench.store.maskSelection() }
        let flat = FlatDesign(bench.store.doc)
        let back = flat.document()
        #expect(back.nodes[0].children.first { $0.isMask }?.children.map(\.name) == ["Window", "Photo"])
    }
}
