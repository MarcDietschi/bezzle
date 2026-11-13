import Testing
import AppKit
@testable import Bezzle

/// Layers held up off the page: where they show, what is under the pointer there, how they are
/// drawn and go out, and turning them on the canvas.
@MainActor
struct DepthTests {
    private func card(_ frame: CGRect, turn: Transform3D?, name: String = "Card") -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = .white
        n.transform3D = turn
        return n
    }

    private func red(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        Int((NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent * 255).rounded())
    }

    @Test func aTurnedLayerShowsInPerspective() throws {
        let frame = CGRect(x: 50, y: 50, width: 100, height: 100)
        let p = try #require(Perspective(card(frame, turn: Transform3D(y: 60))))
        // Its middle stays put; its right side goes away, shorter, and its left comes nearer, taller.
        #expect(p.shown(frame.center) == frame.center)
        let tl = p.shown(CGPoint(x: 50, y: 50)), bl = p.shown(CGPoint(x: 50, y: 150))
        let tr = p.shown(CGPoint(x: 150, y: 50)), br = p.shown(CGPoint(x: 150, y: 150))
        #expect(bl.y - tl.y > 100 && br.y - tr.y < 100)
        #expect(tr.x - tl.x < 60)
        // Tipped back, its top goes away.
        let back = try #require(Perspective(card(frame, turn: Transform3D(x: 40))))
        #expect(back.shown(CGPoint(x: 150, y: 50)).x - back.shown(CGPoint(x: 50, y: 50)).x < 100)
        #expect(back.shown(CGPoint(x: 150, y: 150)).x - back.shown(CGPoint(x: 50, y: 150)).x > 100)
        // Nearer, bigger.
        let near = try #require(Perspective(card(frame, turn: Transform3D(z: 100))))
        #expect(near.shown(CGPoint(x: 150, y: 150)).x > 150)
        // Turned by nothing, it lies flat.
        #expect(Perspective(card(frame, turn: Transform3D())) == nil)
        #expect(Perspective(card(frame, turn: nil)) == nil)
    }

    @Test func whereALayerShowsLeadsBackToWhereItLies() throws {
        let p = try #require(Perspective(card(CGRect(x: 0, y: 0, width: 300, height: 200), turn: Transform3D(x: 35, y: -50, z: 40))))
        for q in [CGPoint(x: 10, y: 20), CGPoint(x: 290, y: 5), CGPoint(x: 150, y: 100), CGPoint(x: 260, y: 190)] {
            let back = try #require(p.flat(p.shown(q)))
            #expect(hypot(back.x - q.x, back.y - q.y) < 1e-6)
        }
    }

    @Test func whatIsUnderThePointerIsWhereTheLayerShows() {
        let n = card(CGRect(x: 50, y: 50, width: 100, height: 100), turn: Transform3D(y: 60))
        #expect(Geometry.contains(n, CGPoint(x: 100, y: 100), tolerance: 0))
        // Inside its frame, but where it has swung away from.
        #expect(!Geometry.contains(n, CGPoint(x: 140, y: 100), tolerance: 0))
        #expect(!Geometry.contains(n, CGPoint(x: 60, y: 100), tolerance: 0))
        // Outside its frame, where it has come nearer.
        #expect(Geometry.contains(n, CGPoint(x: 78, y: 49), tolerance: 0))
        let b = Geometry.bounds(of: n)
        #expect(b.minX > 70 && b.maxX < 130 && b.minY < 50 && b.maxY > 150, "\(b)")
    }

    @Test func aTurnedLayerIsDrawnWhereItShows() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        board.fill.color = .black
        board.children = [card(CGRect(x: 50, y: 50, width: 100, height: 100), turn: Transform3D(y: 60))]
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(red(image, 100, 100) > 250)
        #expect(red(image, 60, 100) < 5 && red(image, 140, 100) < 5)
        #expect(red(image, 78, 49) > 128, "nearer, past its frame: \(red(image, 78, 49))")
        #expect(red(image, 120, 49) < 128, "further, short of it: \(red(image, 120, 49))")
        // Drawn again from the picture kept, the same.
        let again = try #require(Renderer.image(of: board, scale: 1))
        #expect(red(again, 78, 49) == red(image, 78, 49))
    }

    @Test func aTurnedLayersShadowFallsFromTheShapeItMakes() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 220))
        board.fill.color = .white
        // Tipped back, it shows from about 60 to 124 down; its shadow falls 30 below that.
        var c = card(CGRect(x: 50, y: 40, width: 100, height: 100), turn: Transform3D(x: 50))
        c.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 30, blur: 12)
        board.children = [c]
        // Close up, where the shadow is made apart at fewer pixels.
        let image = try #require(Renderer.image(of: board, scale: 4))
        #expect(red(image, 400, 560) < 200, "under it: \(red(image, 400, 560))")
        #expect(red(image, 400, 200) > 250, "above it, inside its frame: \(red(image, 400, 200))")
        #expect(red(image, 400, 400) > 250, "the card itself: \(red(image, 400, 400))")
        #expect(red(image, 400, 760) > 245, "well past it: \(red(image, 400, 760))")
    }

    @Test func aGroupTurnsWithWhatItHolds() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        board.fill.color = .black
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 50, y: 50, width: 100, height: 100))
        group.children = [card(CGRect(x: 0, y: 0, width: 100, height: 100), turn: nil, name: "Inside")]
        group.transform3D = Transform3D(y: 60)
        board.children = [group]
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(red(image, 100, 100) > 250 && red(image, 140, 100) < 5 && red(image, 78, 49) > 128)

        // A point in the group shows where it is turned to, and leads back.
        var doc = BezzleDocument()
        doc.nodes = [board]
        let q = CGPoint(x: 30, y: 70)
        let shown = doc.shown(q, inside: group.id)
        #expect(hypot(shown.x - (q.x + 50), shown.y - (q.y + 50)) > 1)
        let back = try #require(doc.placed(shown, inside: group.id))
        #expect(hypot(back.x - q.x, back.y - q.y) < 1e-6)
    }

    @Test func aChangeInsideATurnedGroupRedrawsAllOfIt() throws {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 50, y: 50, width: 100, height: 100))
        group.children = [card(CGRect(x: 0, y: 0, width: 100, height: 100), turn: nil, name: "Inside")]
        group.transform3D = Transform3D(x: 30, y: 40)
        var old = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        old.children = [group]
        var new = old
        new.children[0].children[0].fill.color = RGBA(r: 1, g: 0, b: 0)
        let damage = try #require(Damage.between(old, new))
        #expect(damage.contains(Renderer.reach(of: group)), "\(damage)")
    }

    @Test func aTurnedLayerGoesOutAsItShows() throws {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let c = card(CGRect(x: 50, y: 50, width: 100, height: 100), turn: Transform3D(y: 60))
        board.children = [c]
        var doc = BezzleDocument()
        doc.nodes = [board]
        let item = try #require(ExportItem(layer: c.id, in: doc))
        let rect = item.bounds(assets: nil)
        // Seen from the artboard's middle, down and to the right of it: about half as wide.
        #expect(rect.width < 64 && rect.height > 100, "\(rect)")
        let whole = ExportItem(artboard: board)
        let svg = SVGWriter.document(for: whole, bounds: whole.bounds(assets: nil), assets: nil)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(svg.contains("<image id=\"Card\""))
    }

    @Test func aFaceTurnsWhereItIsLed() {
        for t in [Transform3D(x: 20, y: -30), Transform3D(x: -50, y: 10), Transform3D(x: 0, y: 70)] {
            let (x, y) = DepthTool.turn(facing: DepthTool.facing(t))
            #expect(abs(x - t.x) < 1e-6 && abs(y - t.y) < 1e-6, "\(t)")
        }
        // Nearly face on, it settles flat; with Shift, in steps of 15°.
        let flat = DepthTool.settled(1.2, -2, steps: false)
        #expect(flat.x == 0 && flat.y == 0)
        let stepped = DepthTool.settled(22, -8, steps: true)
        #expect(stepped.x == 15 && stepped.y == -15)
    }

    @Test func justOutsideASideADragTurnsItInDepth() throws {
        // On artboard A at 100, 100: from 200, 150 to 400, 300 on the canvas, its middle at 300, 225.
        let bench = Bench(extra: [Node(kind: .rectangle, name: "R", frame: CGRect(x: 100, y: 50, width: 200, height: 150))])
        bench.click(CGPoint(x: 300, y: 225))
        // Just outside the middle of its right side, and on to the right: it faces right.
        bench.drag(CGPoint(x: 412, y: 225), CGPoint(x: 452, y: 225))
        let r = try #require(bench.node("R"))
        let t = try #require(r.transform3D)
        // Across swings it round, toward the pointer; nothing tips it, and it stays where it was.
        #expect(t.y > 15 && t.x == 0, "\(t)")
        #expect(r.frame.origin == CGPoint(x: 100, y: 50))
        #expect(bench.store.selection == [r.id])
        bench.undo.undo()
        #expect(bench.node("R")?.transform3D == nil)
        // Only a click there: nothing turns, and what is under it, nothing, is picked.
        bench.click(CGPoint(x: 300, y: 225))
        bench.click(CGPoint(x: 412, y: 225))
        #expect(bench.node("R")?.transform3D == nil && bench.store.selection.isEmpty)
    }

    @Test func theKnobAimsTheFaceAndADoubleClickLaysItFlat() throws {
        var r = Node(kind: .rectangle, name: "R", frame: CGRect(x: 100, y: 50, width: 200, height: 150))
        // In 3D and face on: its knob is in its middle.
        r.transform3D = Transform3D()
        let bench = Bench(extra: [r])
        bench.store.selection = [r.id]
        // Up and to the right: it faces there, tipped back and swung round to the right.
        bench.drag(CGPoint(x: 300, y: 225), CGPoint(x: 318, y: 207))
        let t = try #require(bench.node("R")?.transform3D)
        #expect(t.x > 30 && t.y > 25, "\(t)")
        // The knob turns it; it does not move it.
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 100, y: 50))
        let f = DepthTool.facing(t)
        bench.click(CGPoint(x: 300 + f.x * DepthTool.reach, y: 225 + f.y * DepthTool.reach), clicks: 2)
        #expect(bench.node("R")?.transform3D == Transform3D())
    }
}
