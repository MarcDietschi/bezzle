import Testing
import AppKit
@testable import Bezzle

/// Looking at an artboard's scene from the side while designing: the eye moves and the page
/// stays, what stands off the page shows where the moved eye sees it, everything on the canvas
/// stays true to that, and nothing of it is ever part of the design, saved or exported.
@MainActor
struct DepthLookTests {
    /// A 400 by 300 artboard, seen from 800 points in front of its middle.
    private let size = CGSize(width: 400, height: 300)
    private let red = RGBA(r: 1, g: 0, b: 0)

    private func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), color: RGBA = .white) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = color
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    /// A card lying in the page at the top left, and a red one 40 points off the page over the middle.
    private var scene: [Node] {
        [card("Lying", CGRect(x: 20, y: 20, width: 100, height: 60)),
         card("Lifted", CGRect(x: 180, y: 130, width: 40, height: 40), z: 40, color: red)]
    }

    private func board(_ children: [Node]) -> Node {
        var b = Node(kind: .artboard, name: "Stage", frame: CGRect(origin: .zero, size: size))
        b.fill.color = .black
        b.children = children
        return b
    }

    private func design(_ children: [Node]) -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = [board(children)]
        return doc
    }

    private func node(_ doc: BezzleDocument, _ name: String) -> Node { doc.allNodes.first { $0.name == name }! }

    /// Where a point 40 off the page shows across, seen from an eye standing at `eye` across, 800 above.
    private func across(_ x: CGFloat, from eye: CGFloat, height: CGFloat = 40) -> CGFloat { eye + (x - eye) * 800 / (800 - height) }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    // MARK: The eye

    @Test func theEyeGoesAsideAsHighAsItWasAndNoFurtherThanSixtyDegrees() {
        let eye = Eye.stage(size)
        #expect(eye == Eye(at: CGPoint(x: 200, y: 150), distance: 800))
        #expect(eye.looking(nil) == eye && eye.looking(.front) == eye)
        // From 45° to the left it stands as far left as it is high.
        let left = eye.looking(DepthLook(across: -45))
        #expect(abs(left.at.x - (200 - 800)) < 1e-9 && left.at.y == 150 && left.distance == 800)
        let below = eye.looking(DepthLook(across: 30, down: 40))
        #expect(below.at.x > 200 && below.at.y > 150)
        #expect(abs(hypot(below.at.x - 200, below.at.y - 150) - 800 * CGFloat(tan(50 * Double.pi / 180))) < 1e-6)
        #expect(DepthLook(across: 90).held == DepthLook(across: 60) && abs(DepthLook(across: -80, down: 80).held.angle - 60) < 1e-9)
        #expect(eye.looking(DepthLook(across: 85)) == eye.looking(DepthLook(across: 60)))
        // Dragged, what is held up goes with the pointer: the eye goes the other way.
        #expect(DepthLook.front.dragged(by: CGPoint(x: 100, y: 0), steps: false) == DepthLook(across: -35))
        #expect(DepthLook(across: -35).dragged(by: CGPoint(x: -100, y: 40), steps: false) == DepthLook(across: 0, down: -14))
        // In fives with Shift, catching at the front without, and never past sixty.
        #expect(DepthLook.front.dragged(by: CGPoint(x: -50, y: 0), steps: true) == DepthLook(across: 20))
        #expect(DepthLook(across: 10).dragged(by: CGPoint(x: 25, y: 0), steps: false) == .front)
        #expect(DepthLook.front.dragged(by: CGPoint(x: -1000, y: 0), steps: false) == DepthLook(across: 60))
    }

    @Test func fromTheSideThePageStaysAndWhatStandsOffItShowsWhereTheMovedEyeSeesIt() throws {
        var doc = design(scene)
        let stage = doc.nodes[0], lying = node(doc, "Lying"), lifted = node(doc, "Lifted")
        #expect(doc.stage(of: stage) == Eye.stage(size) && doc.eye(inside: stage.id) == Eye.stage(size))
        #expect(doc.posts(of: stage).isEmpty)
        doc.looks = [stage.id: DepthLook(across: -45)]
        let eye = try #require(doc.eye(forParentOf: lifted.id))
        #expect(abs(eye.at.x + 600) < 1e-9 && eye.at.y == 150 && eye.distance == 800 && doc.stage(of: stage) == eye)
        // What lies in the page is not in depth: nothing of it is asked where it shows.
        #expect(doc.perspective(of: lying) == nil)
        #expect(Geometry.bounds(of: lying, eye: eye) == lying.frame)
        // What stands 40 off it has gone to the right, away from the eye, by a little more than 40.
        let shown = try #require(doc.perspective(of: lifted)).shown(lifted.frame.center)
        #expect(abs(shown.x - across(200, from: -600)) < 1e-9 && abs(shown.y - 150) < 1e-9)
        #expect(abs(shown.x - 242.105) < 0.001)
        let box = Geometry.bounds(of: lifted, eye: eye)
        #expect(abs(box.minX - across(180, from: -600)) < 1e-6 && abs(box.maxX - across(220, from: -600)) < 1e-6)
        // It is picked where it shows, and not where it lies.
        #expect(Picking(doc: doc).hit(CGPoint(x: 242, y: 150)) == lifted.id)
        #expect(Picking(doc: doc).hit(CGPoint(x: 190, y: 150)) == nil)
        #expect(Picking(doc: doc).marquee(CGRect(x: 230, y: 140, width: 20, height: 20), inside: stage.id) == [lifted.id])
        #expect(Picking(doc: doc).marquee(CGRect(x: 180, y: 140, width: 20, height: 20), inside: stage.id) == [])
        // From the front, as ever.
        #expect(Picking(doc: doc.front).hit(CGPoint(x: 190, y: 150)) == lifted.id)
        #expect(doc.front.looks == nil && doc.front.eye(inside: stage.id) == Eye.stage(size))
        // Inside a group it is the same eye, in the group's own points.
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 50, y: 40, width: 100, height: 100))
        group.children = [card("Inside", CGRect(x: 10, y: 10, width: 30, height: 30), z: 20)]
        var grouped = design([group])
        grouped.looks = [grouped.nodes[0].id: DepthLook(across: -45)]
        let within = try #require(grouped.eye(inside: group.id))
        #expect(abs(within.at.x + 650) < 1e-9 && within.at.y == 110 && within.distance == 800)
        // A point of the canvas goes into a lifted layer's parent and comes back the same.
        let there = grouped.shown(ScenePoint(x: 25, y: 25, z: 20), inside: group.id)
        #expect(abs(there.x - (-600 + (75 + 600) * 800 / 780)) < 1e-6)
    }

    @Test func aPostStandsUnderEachCornerOfWhatIsOffThePageOnlyFromTheSide() {
        var doc = design(scene + [card("Leaning", CGRect(x: 300, y: 200, width: 60, height: 40), turn: (0, 40))])
        let stage = doc.nodes[0]
        doc.looks = [stage.id: DepthLook(across: -45)]
        let posts = doc.posts(of: stage)
        // Four under the lifted card, from where each corner would lie to where it shows; four
        // under the leaning one, whose sides stand off the page though its middle lies in it.
        #expect(posts.count == 8)
        let first = posts[0]
        #expect(first.foot == CGPoint(x: 180, y: 130))
        #expect(abs(first.top.x - across(180, from: -600)) < 1e-6 && abs(first.top.y - (150 + (130 - 150) * 800 / 760.0)) < 1e-6)
        // With one of them picked, only its own; with something lying in the page picked, all.
        let leaning = node(doc, "Leaning").id
        #expect(doc.posts(of: stage, picked: [leaning]).count == 4 && doc.posts(of: stage, picked: [leaning]).first != first)
        #expect(doc.posts(of: stage, picked: [node(doc, "Lying").id]) == posts)
        // From the front there are none, nor on an artboard that is not looked at from the side.
        #expect(doc.front.posts(of: stage).isEmpty)
        doc.looks = [UUID(): DepthLook(across: -45)]
        #expect(doc.posts(of: stage).isEmpty)
    }

    // MARK: Never part of the design

    @Test func aWayOfLookingIsNeitherSavedNorComparedNorDrawnByAnythingButTheCanvas() throws {
        let plain = design(scene)
        var doc = plain
        doc.looks = [doc.nodes[0].id: DepthLook(across: -45)]
        // The same design, whatever it is looked at from.
        #expect(doc == plain)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        #expect(data == (try encoder.encode(plain)))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("looks"))
        #expect(try JSONDecoder().decode(BezzleDocument.self, from: data).looks == nil)

        // Drawn as anything but the canvas draws it, an artboard is seen from the front.
        let stage = doc.nodes[0]
        let front = try #require(Renderer.image(of: stage, scale: 1))
        #expect(pixel(front, 200, 150).redComponent > 0.95 && pixel(front, 242, 150).redComponent < 0.05)
        // The canvas says where from: the lifted card shows to the right, the page where it was.
        let rect = CGRect(origin: .zero, size: size)
        var options = Renderer.Options()
        options.looks = doc.looks
        let side = try #require(Renderer.tile(of: stage, rect: rect, scale: 1, options: options))
        #expect(pixel(side, 242, 150).redComponent > 0.95 && pixel(side, 200, 150).redComponent < 0.05)
        #expect(pixel(side, 70, 50).blueComponent > 0.95 && pixel(front, 70, 50).blueComponent > 0.95)
        // With nothing off the page, the same picture to the last pixel.
        let flat = board([scene[0], card("Other", CGRect(x: 200, y: 180, width: 120, height: 70), color: red)])
        var looking = Renderer.Options()
        looking.looks = [flat.id: DepthLook(across: 50, down: -20)]
        let a = try #require(Renderer.tile(of: flat, rect: rect, scale: 1, options: Renderer.Options()))
        let b = try #require(Renderer.tile(of: flat, rect: rect, scale: 1, options: looking))
        #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?)
        // And only what stands off the page is drawn again when the look changes.
        let look = DepthLook(across: -45)
        let damage = Damage.looked(stage, from: nil, to: look)
        #expect(damage.contains(CGPoint(x: 200, y: 150)) && damage.contains(CGPoint(x: 260, y: 150)))
        #expect(!damage.intersects(CGRect(x: 20, y: 20, width: 100, height: 60)) && damage.width < 110)
        #expect(Damage.looked(flat, from: nil, to: look).isNull)
        #expect(Damage.between(stage, stage, look: look)?.isNull == true)
    }

    // MARK: On the canvas

    /// Where the lifted card's middle shows on the bench's canvas, artboard A lying at 100, 100.
    private func shownMiddle(_ bench: Bench) -> CGPoint {
        let lifted = bench.node("Lifted")!
        let p = bench.store.doc.perspective(of: lifted)!.shown(lifted.frame.center)
        return CGPoint(x: p.x + 100, y: p.y + 100)
    }

    @Test func controlDraggedBesideTheLayersLooksFromTheSideAndEditingStaysTrue() throws {
        let bench = Bench(extra: scene)
        let before = bench.store.doc
        let lifted = try #require(bench.node("Lifted")).id
        bench.store.selection = [lifted]
        // On the empty part of the artboard, a hundred points to the right: 35° from the left.
        bench.drag(CGPoint(x: 150, y: 350), CGPoint(x: 250, y: 350), flags: .control)
        #expect(bench.store.looks == [bench.a.id: DepthLook(across: -35)])
        #expect(bench.store.doc.looks == bench.store.looks)
        // Nothing of the design changed, nothing to undo, and what was picked still is.
        #expect(bench.store.doc == before && bench.undo.undoActionName.isEmpty)
        #expect(bench.store.selection == [lifted])
        #expect(bench.store.measurement == nil)
        // The card is picked where it shows now, to the right of where it lies, and not where it lies.
        let middle = shownMiddle(bench)
        #expect(middle.x > 325 && abs(middle.y - 250) < 1e-6)
        bench.store.selection = []
        bench.click(middle)
        #expect(bench.store.selection == [lifted])
        bench.click(CGPoint(x: 290, y: 250))
        #expect(bench.store.selection == [])
        // Moved with Control held, it comes nearer by a point for a point, and stays where it lies.
        bench.drag(middle, CGPoint(x: middle.x, y: middle.y - 30), flags: .control)
        let pushed = try #require(bench.node("Lifted"))
        #expect(pushed.transform3D?.z == 70 && pushed.frame == CGRect(x: 180, y: 130, width: 40, height: 40), "\(pushed.frame) \(String(describing: pushed.transform3D))")
        // Seen from the side it has gone further to the right, where it is picked.
        let higher = shownMiddle(bench)
        #expect(higher.x > middle.x + 20)
        #expect(bench.canvas.layer(at: higher) == lifted)
        // Moved without Control it goes with the pointer in the page.
        bench.drag(higher, CGPoint(x: higher.x + 10, y: higher.y + 20))
        #expect(bench.node("Lifted")?.transform3D?.z == 70 && bench.node("Lifted")?.frame != pushed.frame)
        // Undo takes the changes back and leaves the look.
        bench.undo.undo()
        bench.undo.undo()
        #expect(bench.node("Lifted")?.transform3D?.z == 40 && bench.node("Lifted")?.frame == pushed.frame)
        #expect(bench.store.looks == [bench.a.id: DepthLook(across: -35)] && bench.store.doc.looks == bench.store.looks)
        // A second drag goes on from there; Shift in fives.
        bench.drag(CGPoint(x: 150, y: 350), CGPoint(x: 150, y: 290), flags: [.control, .shift])
        #expect(bench.store.looks == [bench.a.id: DepthLook(across: -35, down: 20)])
        // The other artboard is still seen from the front.
        #expect(bench.store.doc.stage(of: bench.b) == Eye.stage(size))
    }

    @Test func aClickWithControlEscapeTheWordAndLeavingDesignLookFromTheFrontAgain() throws {
        let bench = Bench(extra: scene)
        let look = DepthLook(across: 30, down: -10)
        func aside() { bench.store.look(at: bench.a.id, from: look) }
        aside()
        #expect(bench.store.looks == [bench.a.id: look])
        // A click with Control on nothing.
        bench.click(CGPoint(x: 150, y: 350), flags: .control)
        #expect(bench.store.looks.isEmpty && bench.store.doc.looks == nil)
        // Escape with nothing picked; with something picked it lets go of that first.
        aside()
        bench.store.selection = [try #require(bench.node("Lifted")).id]
        bench.key(53)
        bench.key(53)
        #expect(bench.store.selection.isEmpty && !bench.store.looks.isEmpty)
        bench.key(53)
        #expect(bench.store.looks.isEmpty)
        // Escape during the drag puts the look back as it was.
        aside()
        bench.drag(CGPoint(x: 150, y: 350), CGPoint(x: 250, y: 350), flags: .control, release: false)
        #expect(bench.store.looks[bench.a.id] != look)
        bench.key(53)
        #expect(bench.store.looks == [bench.a.id: look])
        bench.release(CGPoint(x: 250, y: 350))
        #expect(bench.store.looks == [bench.a.id: look])
        // The word by the artboard, drawn with the posts under what stands off the page.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        bench.canvas.lookTool.draw(ctx, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        NSGraphicsContext.current = nil
        let drawn = try #require(ctx.makeImage())
        #expect(bench.store.doc.posts(of: bench.a).count == 4)
        // Above the artboard's top right corner, the word's own ink.
        #expect(NSBitmapImageRep(cgImage: drawn).colorAt(x: 494, y: 800 - 85)?.alphaComponent ?? 0 > 0.9
                || NSBitmapImageRep(cgImage: drawn).colorAt(x: 494, y: 85)?.alphaComponent ?? 0 > 0.9)
        #expect(!bench.canvas.lookTool.wordDown(at: CGPoint(x: 300, y: 300)))
        #expect(bench.canvas.lookTool.wordDown(at: CGPoint(x: 490, y: 85)))
        #expect(bench.store.looks.isEmpty)
        // Seen as a prototype, inspected or animated, everything is from the front.
        aside()
        bench.store.prototyping = true
        #expect(bench.store.looks.isEmpty && bench.store.doc.looks == nil)
        bench.store.prototyping = false
        // Nothing but an artboard is looked at, and never further than sixty degrees.
        bench.store.look(at: try #require(bench.node("Lifted")).id, from: look)
        #expect(bench.store.looks.isEmpty)
        bench.store.look(at: bench.a.id, from: DepthLook(across: 200))
        #expect(bench.store.looks == [bench.a.id: DepthLook(across: 60)])
        bench.store.lookFromTheFront()
        #expect(bench.store.looks.isEmpty && bench.undo.undoActionName.isEmpty)
    }

    @Test func whatLeavesTheCanvasIsSeenFromTheFront() throws {
        let bench = Bench(extra: scene)
        bench.store.look(at: bench.a.id, from: DepthLook(across: -45))
        let stage = bench.a
        // The artboard exported as a picture.
        let item = try #require(ExportItem.items(for: stage).first)
        let picture = try #require(item.picture(scale: 1, opaque: true, assets: bench.store.assets)?.image)
        #expect(pixel(picture, 200, 150).redComponent > 0.95 && pixel(picture, 200, 150).blueComponent < 0.05)
        #expect(pixel(picture, 242, 150).blueComponent > 0.5 || pixel(picture, 242, 150).redComponent < 0.05)
        // The lifted card alone: as big as it shows from the front.
        let lifted = try #require(bench.node("Lifted"))
        let alone = try #require(ExportItem(layer: lifted.id, in: bench.store.doc)?.picture(scale: 1, opaque: false, assets: bench.store.assets)?.image)
        let again = try #require(ExportItem(layer: lifted.id, in: bench.store.doc.front)?.picture(scale: 1, opaque: false, assets: bench.store.assets)?.image)
        #expect(alone.width == again.width && alone.height == again.height)
        #expect(alone.dataProvider?.data as Data? == again.dataProvider?.data as Data?)
        // What the hand-off measures is the design's.
        #expect(Inspect.box(of: lifted.id, in: bench.store.doc) == Inspect.box(of: lifted.id, in: bench.store.doc.front))
        // The file written has nothing of the look.
        let data = try JSONEncoder().encode(bench.store.doc)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("looks"))
    }
}
