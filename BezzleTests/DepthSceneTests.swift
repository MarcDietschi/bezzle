import Testing
import AppKit
@testable import Bezzle

/// An artboard as one 3D scene: everything on it seen from one eye in front of its middle, nearer
/// over further, and layers pushed and pulled in depth with Control while they are dragged, on
/// the canvas and in Animate. The film's camera at rest sees what the design shows.
@MainActor
struct DepthSceneTests {
    /// A 400 by 300 artboard is seen from 800 points in front of its middle.
    private let size = CGSize(width: 400, height: 300)
    private var eye: Eye { Eye.stage(size) }

    private func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), color: RGBA = .white) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = color
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    private func board(_ children: [Node]) -> Node {
        var b = Node(kind: .artboard, name: "Stage", frame: CGRect(origin: .zero, size: size))
        b.fill.color = .black
        b.children = children
        return b
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    private func near(_ a: CGPoint, _ b: CGPoint, _ within: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) <= within }

    // MARK: One eye

    @Test func theEyeIsInFrontOfTheArtboardsMiddleAsFarAsItsCameraRests() {
        #expect(eye == Eye(at: CGPoint(x: 200, y: 150), distance: 800))
        #expect(Eye.stage(CGSize(width: 1920, height: 1080)).distance == CGFloat(FilmLens.distance(for: CGSize(width: 1920, height: 1080))))
        // In a group, the same eye where the group's own points begin.
        #expect(eye.inside(CGPoint(x: 50, y: 20)) == Eye(at: CGPoint(x: 150, y: 130), distance: 800))
    }

    @Test func aLayerBroughtNearerComesOutFromTheMiddleAndOnePushedAwayGoesIn() throws {
        // In front of the eye it only grows, about its middle.
        let middle = try #require(Perspective(card("M", CGRect(x: 180, y: 130, width: 40, height: 40), z: 100), eye: eye))
        #expect(near(middle.shown(CGPoint(x: 200, y: 150)), CGPoint(x: 200, y: 150)))
        #expect(abs(middle.shown(CGPoint(x: 220, y: 150)).x - (200 + 20 * 8 / 7)) < 1e-6)
        // To the left of it, nearer, it moves out to the left as it grows, as far as it is nearer.
        let left = card("L", CGRect(x: 20, y: 130, width: 40, height: 40), z: 100)
        let nearer = try #require(Perspective(left, eye: eye)).shown(CGPoint(x: 40, y: 150))
        #expect(abs(nearer.x - (200 - 160.0 * 800 / 700)) < 1e-6 && abs(nearer.y - 150) < 1e-6)
        // Pushed away, it shrinks toward the middle.
        var back = left
        back.transform3D?.z = -100
        let further = try #require(Perspective(back, eye: eye)).shown(CGPoint(x: 40, y: 150))
        #expect(abs(further.x - (200 - 160.0 * 800 / 900)) < 1e-6)
        // Off any artboard there is no stage: it is seen from in front of its own middle, as before.
        #expect(near(try #require(Perspective(left)).shown(CGPoint(x: 40, y: 150)), CGPoint(x: 40, y: 150)))
    }

    @Test func layersTurnedAlikeLeanToOneVanishingPoint() throws {
        // Tipped back, the sides of each card run up toward one point above the eye, wherever the
        // cards lie: one scene, not two pictures.
        func sides(_ n: Node) throws -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            let p = try #require(Perspective(n, eye: eye))
            let f = n.frame
            return (p.shown(CGPoint(x: f.minX, y: f.maxY)), p.shown(CGPoint(x: f.minX, y: f.minY)),
                    p.shown(CGPoint(x: f.maxX, y: f.maxY)), p.shown(CGPoint(x: f.maxX, y: f.minY)))
        }
        func meet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
            let d1 = CGPoint(x: b.x - a.x, y: b.y - a.y), d2 = CGPoint(x: d.x - c.x, y: d.y - c.y)
            let t = ((c.x - a.x) * d2.y - (c.y - a.y) * d2.x) / (d1.x * d2.y - d1.y * d2.x)
            return CGPoint(x: a.x + d1.x * t, y: a.y + d1.y * t)
        }
        let a = try sides(card("A", CGRect(x: 40, y: 160, width: 80, height: 60), turn: (50, 0)))
        let b = try sides(card("B", CGRect(x: 260, y: 60, width: 100, height: 50), turn: (50, 0)))
        let va = meet(a.0, a.1, a.2, a.3), vb = meet(b.0, b.1, b.2, b.3)
        #expect(near(va, vb, 1e-6), "\(va) \(vb)")
        #expect(abs(va.x - 200) < 1e-6 && va.y < 0)
    }

    @Test func whereALayerShowsLeadsBackToWhereItLiesSeenFromAnywhere() throws {
        var pinned = card("P", CGRect(x: 30, y: 40, width: 160, height: 100), z: 60, turn: (20, -35))
        pinned.transform3D?.corners = [CGPoint(x: 0.05, y: 0), CGPoint(x: 1, y: 0.1), CGPoint(x: 0.9, y: 1), CGPoint(x: 0, y: 0.95)]
        for n in [card("T", CGRect(x: 30, y: 40, width: 160, height: 100), z: -80, turn: (35, 50)), pinned] {
            let p = try #require(Perspective(n, eye: eye))
            for q in [CGPoint(x: 35, y: 45), CGPoint(x: 185, y: 44), CGPoint(x: 110, y: 90), CGPoint(x: 40, y: 135)] {
                let back = try #require(p.flat(p.shown(q)))
                #expect(near(back, q, 1e-6), "\(n.name): \(q) came back as \(back)")
            }
        }
    }

    @Test func aDesignKnowsWhereEachLayerIsSeenFrom() throws {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 50, y: 20, width: 200, height: 200))
        let inside = card("In", CGRect(x: 10, y: 10, width: 40, height: 40), z: 50)
        group.children = [inside]
        var b = board([group])
        b.frame.origin = CGPoint(x: 1000, y: 500)
        let loose = card("Loose", CGRect(x: 0, y: 0, width: 40, height: 40), z: 50)
        var doc = BezzleDocument()
        doc.nodes = [b, loose]
        #expect(doc.eye(forParentOf: group.id) == eye)
        #expect(doc.eye(forParentOf: inside.id) == eye.inside(group.frame.origin))
        #expect(doc.eye(inside: b.id) == eye)
        #expect(doc.eye(forParentOf: loose.id) == nil)
        // Where the layer in the group shows on the canvas is where its eye sees it, and leads back.
        let q = CGPoint(x: 12, y: 15)
        let seen = try #require(Perspective(inside, eye: eye.inside(group.frame.origin))).shown(q)
        #expect(near(doc.shownOnCanvas(q + CGPoint(x: 1050, y: 520), of: inside), seen + CGPoint(x: 1050, y: 520)))
        let flat = try #require(doc.flatOnCanvas(seen + CGPoint(x: 1050, y: 520), of: inside))
        #expect(near(flat, q + CGPoint(x: 1050, y: 520), 1e-6))
    }

    // MARK: Nearer over further

    @Test func layersAsNearAsEachOtherKeepTheirOrderAndNearerOnesComeOver() {
        let flat = [card("a", .zero), card("b", .zero), card("c", .zero)]
        #expect(DepthOrder.order(flat) == [0, 1, 2])
        #expect(!DepthOrder.leaves(flat))
        let mixed = [card("a", .zero), card("b", .zero, z: 10), card("c", .zero, z: -5), card("d", .zero, z: 10)]
        #expect(DepthOrder.order(mixed) == [2, 0, 1, 3])
        #expect(DepthOrder.stacked(mixed).map(\.name) == ["c", "a", "b", "d"])
        // A slice keeps its own positions.
        #expect(DepthOrder.order(mixed.dropFirst()) == [2, 1, 3])
    }

    @Test func aLayerBroughtNearerIsDrawnOverOneListedAboveIt() throws {
        let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)
        let image = try #require(Renderer.image(of: board([card("Low", CGRect(x: 150, y: 100, width: 100, height: 100), z: 20, color: red),
                                                         card("High", CGRect(x: 150, y: 100, width: 100, height: 100), color: blue)]), scale: 1))
        let c = pixel(image, 200, 150)
        #expect(c.redComponent > 0.95 && c.blueComponent < 0.05, "\(c)")
        // Pushed back, the other way round.
        let again = try #require(Renderer.image(of: board([card("Low", CGRect(x: 150, y: 100, width: 100, height: 100), color: red),
                                                         card("High", CGRect(x: 150, y: 100, width: 100, height: 100), z: -20, color: blue)]), scale: 1))
        #expect(pixel(again, 200, 150).redComponent > 0.95)
    }

    @Test func aLayerNearerTheEyeIsDrawnAndPickedWhereItShows() throws {
        // Left of the middle and 100 nearer: its middle shows at about 17, its right side at 40, not 60.
        let lifted = card("Lifted", CGRect(x: 20, y: 130, width: 40, height: 40), z: 100)
        let image = try #require(Renderer.image(of: board([lifted]), scale: 1))
        #expect(pixel(image, 5, 150).redComponent > 0.95, "out past where it lies")
        #expect(pixel(image, 50, 150).redComponent < 0.05, "short of its frame's right side")
        #expect(Geometry.contains(lifted, CGPoint(x: 5, y: 150), tolerance: 0, eye: eye))
        #expect(!Geometry.contains(lifted, CGPoint(x: 50, y: 150), tolerance: 0, eye: eye))
        let box = Geometry.bounds(of: lifted, eye: eye)
        #expect(abs(box.minX - (200 - 180 * 8 / 7.0)) < 1e-6 && abs(box.maxX - (200 - 140 * 8 / 7.0)) < 1e-6, "\(box)")
        // Where it may paint, which tiles are drawn again by, is where it shows.
        #expect(Renderer.reach(of: lifted, eye: eye).contains(box))
    }

    @Test func aClickPicksTheNearerOfTwoAndTheBoxIsRoundWhatShows() throws {
        // On artboard A at 100,100 (400 by 300): two squares on its middle, the one under brought nearer.
        let bench = Bench(extra: [card("Low", CGRect(x: 150, y: 100, width: 100, height: 100), z: 40),
                                  card("High", CGRect(x: 150, y: 100, width: 100, height: 100))])
        bench.click(CGPoint(x: 300, y: 250))
        let low = try #require(bench.node("Low"))
        #expect(bench.store.selection == [low.id])
        // Nearer, it shows larger than its frame, and so does the box round it.
        let box = try #require(bench.store.selectionBounds)
        #expect(abs(box.width - 100 * 800 / 760) < 1e-6 && abs(box.midX - 300) < 1e-6, "\(box)")
    }

    @Test func movingAGroupRedrawsWhereWhatItHoldsShowsInDepth() throws {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 20, y: 20, width: 100, height: 100))
        group.children = [card("In", CGRect(x: 0, y: 0, width: 40, height: 40), z: 150)]
        let old = board([group])
        var new = old
        new.children[0].frame.origin.x += 60
        let damage = try #require(Damage.between(old, new))
        let shown = Renderer.reach(of: new.children[0].children[0], eye: eye.inside(new.children[0].frame.origin))
            .offsetBy(dx: new.children[0].frame.minX, dy: new.children[0].frame.minY)
        let was = Renderer.reach(of: old.children[0].children[0], eye: eye.inside(old.children[0].frame.origin))
            .offsetBy(dx: old.children[0].frame.minX, dy: old.children[0].frame.minY)
        #expect(damage.contains(shown) && damage.contains(was), "\(damage) \(shown) \(was)")
    }

    // MARK: Control pushes and pulls

    private func mouse(_ bench: Bench, _ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        let inWindow = bench.canvas.convert(bench.store.viewport.toView(p), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func keys(_ bench: Bench, _ flags: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        bench.canvas.flagsChanged(with: e)
    }

    @Test func withControlADragUpBringsALayerNearerAndDownSendsItAway() throws {
        // A square on A's middle: 250,200 to 350,300 on the canvas.
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100))])
        bench.click(CGPoint(x: 300, y: 250))
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 312, y: 190), flags: .control)
        let r = try #require(bench.node("R"))
        #expect(r.transform3D == Transform3D(z: 60))
        // Across, it stays where it was.
        #expect(r.frame.origin == CGPoint(x: 150, y: 100))
        #expect(bench.undo.undoActionName == "Move in Depth")
        bench.undo.undo()
        #expect(bench.node("R")?.transform3D == nil)
        // Down, it goes away.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 330), flags: .control)
        #expect(bench.node("R")?.transform3D?.z == -80)
        // Back up to the page, it is flat again, with nothing of 3D left on it.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 170), flags: .control)
        #expect(bench.node("R")?.transform3D == nil)
    }

    @Test func controlPressedDuringAMoveHoldsItAcrossAndLetGoItMovesOnFromThere() throws {
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100))])
        bench.click(CGPoint(x: 300, y: 250))
        let free: NSEvent.ModifierFlags = .command
        bench.step {
            bench.canvas.mouseDown(with: mouse(bench, .leftMouseDown, CGPoint(x: 300, y: 250), free))
            bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 320, y: 250), free))
            bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 340, y: 250), free))
        }
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 190, y: 100))
        // Control down: up and to the side, it only comes nearer.
        bench.step {
            keys(bench, free.union(.control))
            bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 350, y: 235), free.union(.control)))
            bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 355, y: 220), free.union(.control)))
        }
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 190, y: 100))
        #expect(bench.node("R")?.transform3D?.z == 30)
        #expect(bench.store.measurement?.0 == "Z 30")
        // Let go of it: nothing jumps, and the drag moves it across again from where the pointer is.
        bench.step { keys(bench, free) }
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 190, y: 100) && bench.node("R")?.transform3D?.z == 30)
        #expect(bench.store.measurement == nil)
        bench.step {
            bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 375, y: 230), free))
            bench.canvas.mouseUp(with: mouse(bench, .leftMouseUp, CGPoint(x: 375, y: 230), free))
        }
        let r = try #require(bench.node("R"))
        #expect(r.frame.origin == CGPoint(x: 210, y: 110))
        #expect(r.transform3D?.z == 30)
        #expect(bench.undo.undoActionName == "Move")
        // One step undoes all of it.
        bench.undo.undo()
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 150, y: 100) && bench.node("R")?.transform3D == nil)
    }

    @Test func aPushedLayerCatchesAtThePageAndAtTheHeightsAroundItAndShiftStepsInTens() throws {
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100)),
                                  card("S", CGRect(x: 10, y: 10, width: 40, height: 40), z: 80)])
        bench.click(CGPoint(x: 300, y: 250))
        // Two short of the other's height: level with it.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 172), flags: .control)
        #expect(bench.node("R")?.transform3D?.z == 80)
        bench.undo.undo()
        // Three off the page: on it.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 253), flags: .control)
        #expect(bench.node("R")?.transform3D == nil)
        // With Shift, in tens (pressed once the drag is under way: at the press it would let go of R).
        bench.step {
            bench.canvas.mouseDown(with: mouse(bench, .leftMouseDown, CGPoint(x: 300, y: 250), .control))
            for y in [240, 230, 216] as [CGFloat] {
                bench.canvas.mouseDragged(with: mouse(bench, .leftMouseDragged, CGPoint(x: 300, y: y), [.control, .shift]))
            }
            bench.canvas.mouseUp(with: mouse(bench, .leftMouseUp, CGPoint(x: 300, y: 216), [.control, .shift]))
        }
        #expect(bench.node("R")?.transform3D?.z == 30)
    }

    @Test func pushedInDepthNothingCatchesItAcross() throws {
        // Another's right side lies two points off R's left: moved, R would catch on it.
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100)),
                                  card("Edge", CGRect(x: 60, y: 220, width: 92, height: 40))])
        bench.click(CGPoint(x: 300, y: 250))
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 303, y: 200), flags: .control, release: false)
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 150, y: 100))
        #expect(bench.store.guides.isEmpty)
        bench.release(CGPoint(x: 303, y: 200), flags: .control)
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 150, y: 100) && bench.node("R")?.transform3D?.z == 50)
        // The 3D card says how near it is held.
        #expect(bench.node("R")?.transform3D == Transform3D(z: 50))
    }

    @Test func severalLayersArePushedAlikeEachFromItsOwnHeight() throws {
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100), z: 10),
                                  card("S", CGRect(x: 10, y: 10, width: 40, height: 40), z: -30)])
        let r = try #require(bench.node("R")), s = try #require(bench.node("S"))
        bench.store.selection = [r.id, s.id]
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 200), flags: .control)
        #expect(bench.node("R")?.transform3D?.z == 60 && bench.node("S")?.transform3D?.z == 20)
        #expect(bench.node("R")?.frame.origin == r.frame.origin && bench.node("S")?.frame.origin == s.frame.origin)
    }

    @Test func aLayerOnlyHeldNearerHasNoKnobSoADragOnItsMiddleMovesIt() throws {
        let bench = Bench(extra: [card("R", CGRect(x: 150, y: 100, width: 100, height: 100), z: 40)])
        let r = try #require(bench.node("R"))
        bench.store.selection = [r.id]
        #expect(bench.canvas.depthTool.turning.knob() == nil)
        // Nearer, it shows round its middle at 300, 250: a drag from there moves it, and turns nothing.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 340, y: 250), flags: .command)
        let moved = try #require(bench.node("R"))
        #expect(moved.frame.origin.x > 150 && moved.transform3D == Transform3D(z: 40), "\(moved.frame) \(String(describing: moved.transform3D))")
        // Turned, it has its knob again.
        bench.step { bench.store.edit("Turn in Depth") { $0.update(r.id) { $0.transform3D?.y = 20 } } }
        #expect(bench.canvas.depthTool.turning.knob() != nil)
    }

    @Test func theKnobBringsItNearerWithControlAsWithOption() throws {
        var r = card("R", CGRect(x: 100, y: 50, width: 200, height: 150))
        r.transform3D = Transform3D()
        let bench = Bench(extra: [r])
        bench.store.selection = [r.id]
        // Its knob is on its middle, face on: 300, 225 on the canvas.
        bench.drag(CGPoint(x: 300, y: 225), CGPoint(x: 300, y: 185), flags: .control)
        let t = try #require(bench.node("R")?.transform3D)
        #expect(t.z == 40 && t.x == 0 && t.y == 0, "\(t)")
    }

    // MARK: Handed over

    @Test func itsCodeSaysTheSceneAsCSSDoes() {
        var lifted = card("Lifted Card", CGRect(x: 20, y: 30, width: 120, height: 80), z: 40, turn: (15, -25))
        lifted.rotation = 10
        var group = Node(kind: .group, name: "Holder", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        group.children = [lifted]
        let b = board([group])
        let css = Inspect.css(lifted, in: BezzleDocument(), tokens: .none)
        #expect(css.contains("transform: translateZ(40px) rotateX(15deg) rotateY(-25deg) rotate(10deg);"), "\(css)")
        // The artboard is the scene's perspective; a group lying flat passes it on.
        let scene = Inspect.css(b, in: BezzleDocument(), tokens: .none)
        #expect(scene.contains("perspective: 800px;") && scene.contains("perspective-origin: center;"), "\(scene)")
        #expect(Inspect.css(group, in: BezzleDocument(), tokens: .none).contains("transform-style: preserve-3d;"))
        // Flat, none of it.
        #expect(!Inspect.css(board([card("Flat", .zero)]), in: BezzleDocument(), tokens: .none).contains("perspective"))
    }

    // MARK: The film sees the same scene

    @Test func theCameraAtRestSeesALayerTheDesignHoldsInDepthWhereTheDesignShowsIt() throws {
        let lifted = card("Lifted", CGRect(x: 20, y: 30, width: 120, height: 80), z: 90, turn: (15, -25))
        let b = board([card("Under", CGRect(x: 0, y: 0, width: 50, height: 50)), lifted])
        let pieces = b.filmPieces()
        let i = try #require(pieces.firstIndex { $0.layers == [lifted.id] })
        #expect(pieces[i].flat && pieces[i].kind == .layer)
        let map = b.placement(of: pieces[i], at: 0, camera: .rest).map
        let p = try #require(Perspective(lifted, eye: eye))
        for q in [CGPoint(x: 20, y: 30), CGPoint(x: 140, y: 30), CGPoint(x: 140, y: 110), CGPoint(x: 80, y: 70)] {
            #expect(near(map(q), p.shown(q), 1e-6), "\(q): \(map(q)) against \(p.shown(q))")
        }
        // Tilted, the camera sees how high it stands: off the ground under where the design has it.
        var camera = FilmCamera()
        camera.tilt = 40
        let tilted = b.placement(of: pieces[i], at: 0, camera: camera).map
        let ground = FilmLens.ground(camera, size: size)
        let middle = CGPoint(x: 80, y: 70)
        #expect(hypot(tilted(middle).x - ground(middle).x, tilted(middle).y - ground(middle).y) > 20)
        // What lies on the artboard stays on the ground.
        let under = try #require(pieces.firstIndex { $0.kind == .run })
        #expect(b.placement(of: pieces[under], at: 0, camera: camera).map == ground)
    }

    @Test func aLayerPushedBehindThePageShowsOnItInTheFilmAsInTheDesign() throws {
        let sunk = card("Sunk", CGRect(x: 150, y: 100, width: 100, height: 100), z: -240)
        let b = board([sunk])
        let pieces = b.filmPieces()
        let placements = pieces.map { b.placement(of: $0, at: 0, camera: .rest) }
        // The sheet first, the layer over it, as the design draws it.
        #expect(pieces.map(\.kind) == [.ground, .layer])
        #expect(b.filmOrder(pieces, placements) == [0, 1])
        #expect(placements[1].height == -240)
    }

    @Test func inAnimateControlLiftsWhatIsDraggedAndKeysNothingElse() throws {
        let film = FilmBench()
        film.fresh()
        let at = film.middle("Card")
        film.press(at, flags: .control)
        film.pull(to: CGPoint(x: at.x + 10, y: at.y - 20), flags: .control)
        film.pull(to: CGPoint(x: at.x + 15, y: at.y - 40), flags: .control)
        film.letGo(at: CGPoint(x: at.x + 15, y: at.y - 40), flags: .control)
        #expect(film.value("Card", .lift) == [40])
        #expect(film.keys("Card", .move).isEmpty)
        #expect(film.undo.undoActionName == MotionProperty.lift.title)
        // The design itself is as it was: Animate keeps changes from it, never the design.
        #expect(film.node("Card").transform3D == nil && film.node("Card").frame.origin == CGPoint(x: 40, y: 40))
    }
}
