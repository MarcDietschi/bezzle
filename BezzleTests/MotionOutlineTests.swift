import Testing
import AppKit
@testable import Bezzle

/// Animate's Shape keys when the design gives a layer another outline without a point being
/// edited: resized, its corners rounded, flipped, in a repeat grid's cells and a component's
/// copies. The keys go with the outline, in one step with the change.
@MainActor
struct MotionOutlineTests {
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

    private func path(_ data: String, name: String = "Path") -> Node {
        var n = Node.path(BezierPath(data), name: name)
        n.fill.on = true
        return n
    }

    /// Whether every Shape key of a layer has a change for each of its points as they are now.
    private func fits(_ n: Node) -> Bool {
        (n[track: .shape]?.keys ?? []).allSatisfy { $0.v.count == n.shapeRest.count }
    }

    /// A bench with these layers on artboard A, each found again by its name.
    private func bench(_ layers: [Node]) -> Bench { Bench(extra: layers) }

    // MARK: Resized

    @Test func aPathResizedHasItsShapeKeysGrownWithIt() throws {
        var tri = path("M 100 60 L 200 60 L 150 140 Z", name: "Tri")
        var outline = try #require(tri.ownOutline)
        // Its tip goes 30 right and 60 down at one second.
        outline.subpaths[0].anchors[2].point = outline.subpaths[0].anchors[2].point + CGPoint(x: 30, y: 60)
        tri.poseShape(outline, at: 1)
        let bench = bench([tri])
        let before = bench.store.doc
        // Twice as wide and three times as high, as the Frame card's fields size it.
        bench.step { bench.store.update([tri.id], "Resize") { $0.resize(to: CGSize(width: 200, height: 240), byHeight: false) } }
        let now = try #require(bench.node("Tri"))
        #expect(now.frame.size == CGSize(width: 200, height: 240))
        let design = try #require(now.ownOutline).anchorPoints
        let moved = try #require(now.outline(at: 1)).anchorPoints
        #expect(near(moved[2], CGPoint(x: design[2].x + 60, y: design[2].y + 180)), "\(moved[2]) \(design[2])")
        #expect(near(moved[0], design[0]) && near(moved[1], design[1]))
        #expect(now[track: .shape]?.keys.map(\.t) == [0, 1])
        // Move's keys are points on the artboard, and stay as they are.
        #expect(now[track: .move] == nil)
        // One step with the resize.
        bench.undo.undo()
        #expect(bench.store.doc == before)
        bench.undo.redo()
        #expect(bench.node("Tri")?[track: .shape] == now[track: .shape])
    }

    @Test func moveKeysDoNotGrowWithTheLayer() throws {
        var tri = path("M 100 60 L 200 60 L 150 140 Z", name: "Tri")
        tri.setKey(.move, [40, 10], at: 1)
        let bench = bench([tri])
        bench.step { bench.store.update([tri.id], "Resize") { $0.resize(to: CGSize(width: 200, height: 160), byHeight: false) } }
        #expect(bench.node("Tri")?[track: .move]?.keys.map(\.v) == [[40, 10]])
    }

    @Test func aRoundedRectangleResizedKeepsEachPointsChangeGrown() throws {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 100, height: 80))
        card.cornerRadius = 10
        // Four corners' curves, each between two points, and where the outline begins: nine points.
        let rest = card.shapeRest
        #expect(rest.count == 9 * 6)
        // Every point its own way, to tell them apart.
        let change = rest.indices.map { Double($0 % 7) - 3 }
        card.setKey(.shape, change, at: 1)
        let bench = bench([card])
        bench.step { bench.store.update([card.id], "Resize") { $0.resize(to: CGSize(width: 300, height: 40), byHeight: false) } }
        let now = try #require(bench.node("Card"))
        let got = try #require(now[track: .shape]?.keys.first?.v)
        #expect(got.count == change.count)
        for i in change.indices {
            let grown = change[i] * (i % 2 == 0 ? 3 : 0.5)
            #expect(abs(got[i] - grown) < 1e-9, "\(i): \(got[i]) not \(grown)")
        }
    }

    @Test func aLayerDraggedFlatAndOutAgainHasItsKeysFromWhereTheDragBegan() throws {
        var tri = path("M 100 60 L 200 60 L 150 140 Z", name: "Tri")
        var outline = try #require(tri.ownOutline)
        outline.subpaths[0].anchors[2].point = outline.subpaths[0].anchors[2].point + CGPoint(x: 30, y: 60)
        tri.poseShape(outline, at: 1)
        let bench = bench([tri])
        let store = bench.store
        bench.step {
            store.beginGesture()
            for width in [60.0, 0, 0, 25, 200] {
                store.edit("Resize") { $0.update(tri.id) { $0.frame.size.width = width } }
            }
            store.endGesture("Resize")
        }
        let now = try #require(bench.node("Tri"))
        let key = try #require(now[track: .shape]?.keys.last?.v)
        // The tip's change: twice as far across, as far down as it was.
        #expect(abs(key[12] - 60) < 1e-6 && abs(key[13] - 60) < 1e-6, "\(key[12]) \(key[13])")
        bench.undo.undo()
        #expect(bench.node("Tri")?[track: .shape] == tri[track: .shape])
    }

    @Test func insideAGroupThatIsResizedAShapeGrowsWithItsKeys() throws {
        var tri = path("M 10 10 L 110 10 L 60 90 Z", name: "Tri")
        var outline = try #require(tri.ownOutline)
        outline.subpaths[0].anchors[2].point.y += 40
        tri.poseShape(outline, at: 1)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 20, y: 20, width: 120, height: 100))
        group.children = [tri, CanvasTests.rect("Box", CGRect(x: 0, y: 0, width: 120, height: 100))]
        let bench = bench([group])
        bench.step { bench.store.update([group.id], "Resize") { $0.resize(to: CGSize(width: 240, height: 300), byHeight: false) } }
        let now = try #require(bench.node("Tri"))
        let key = try #require(now[track: .shape]?.keys.last?.v)
        #expect(abs(key[13] - 120) < 1e-6, "\(key[13])")
        #expect(abs(key[12]) < 1e-9)
    }

    // MARK: Other corners

    @Test func aRectangleGivenRoundCornersStillShowsWhatWasKeyed() throws {
        var box = CanvasTests.rect("Box", CGRect(x: 40, y: 40, width: 100, height: 100))
        var outline = try #require(box.ownOutline)
        #expect(outline.anchorCount == 4)
        // Its bottom right corner goes 50 down at one second.
        let corner = try #require(outline.subpaths[0].anchors.firstIndex { near($0.point, CGPoint(x: 100, y: 100)) })
        outline.subpaths[0].anchors[corner].point.y += 50
        box.poseShape(outline, at: 1)
        let keyed = try #require(box.outline(at: 1))
        let bench = bench([box])
        let before = bench.store.doc
        bench.step { bench.store.update([box.id], "Corner Radius") { $0.cornerRadius = 10 } }
        var now = try #require(bench.node("Box"))
        #expect(now.ownOutline?.anchorCount == 9)
        #expect(fits(now))
        // Every point of the rounded outline lies on the outline as it was keyed, or at the
        // rounded corners a little inside it; those round the corner that moved went with it.
        var shown = try #require(now.outline(at: 1))
        for a in shown.subpaths[0].anchors {
            let spot = try #require(keyed.nearest(to: a.point))
            #expect(spot.distance < 0.01, "\(a.point) is \(spot.distance) off what was keyed")
        }
        #expect(shown.anchorPoints.contains { near($0, CGPoint(x: 100, y: 135)) }, "\(shown.anchorPoints)")
        #expect(shown.anchorPoints.contains { near($0, CGPoint(x: 90, y: 145)) }, "\(shown.anchorPoints)")
        // The corner's curve leaves along the sides as they now run: its handles lie on them too.
        for a in shown.subpaths[0].anchors {
            for h in [a.handleIn, a.handleOut].compactMap({ $0 }) where near(a.point, CGPoint(x: 100, y: 135)) || near(a.point, CGPoint(x: 90, y: 145)) {
                #expect(try #require(keyed.nearest(to: h)).distance < 0.01, "a handle at \(h)")
            }
        }
        // At the start, as designed: round.
        #expect(now.outline(at: 0) == now.ownOutline)
        // One step with the corners.
        bench.undo.undo()
        #expect(bench.store.doc == before)
        bench.undo.redo()
        // Rounder, the points go on as their places on the square did: the corner still goes down.
        bench.step { bench.store.update([box.id], "Corner Radius") { $0.cornerRadius = 24 } }
        now = try #require(bench.node("Box"))
        #expect(fits(now))
        shown = try #require(now.outline(at: 1))
        #expect(shown.bounds.maxY > 135)
        for p in shown.anchorPoints { #expect(try #require(keyed.nearest(to: p)).distance < 0.01, "\(p)") }
        // Each corner its own way, then smooth ones, then square again: the keys still fit, and
        // the corner still goes down.
        bench.step { bench.store.update([box.id], "Corner Radius") { $0.corners = [0, 30, 12, 0] } }
        #expect(fits(try #require(bench.node("Box"))))
        bench.step { bench.store.update([box.id], "Corner Radius") { $0.corners = nil; $0.cornerRadius = 20; $0.cornerSmoothing = 0.6 } }
        now = try #require(bench.node("Box"))
        #expect(fits(now))
        #expect(try #require(now.outline(at: 1)).bounds.maxY > 135)
        bench.step { bench.store.update([box.id], "Corner Radius") { $0.cornerRadius = 0; $0.cornerSmoothing = nil } }
        now = try #require(bench.node("Box"))
        #expect(now.ownOutline?.anchorCount == 4)
        #expect(fits(now))
        // Square again, exactly as it was keyed.
        let last = try #require(now.outline(at: 1)).anchorPoints
        let low = try #require(last.max { $0.y < $1.y })
        #expect(abs(low.x - 100) < 1e-6 && abs(low.y - 150) < 1e-6, "\(last)")
    }

    @Test func aRectangleRoundedAndSquaredAgainHasExactlyWhatWasKeyed() throws {
        var box = CanvasTests.rect("Box", CGRect(x: 40, y: 40, width: 100, height: 80))
        var outline = try #require(box.ownOutline)
        let corners = outline.subpaths[0].anchors
        // The bottom right corner goes 50 down, and the top left one is pulled into a curve: its
        // point 10 right, its handles out along the sides.
        let low = try #require(corners.firstIndex { near($0.point, CGPoint(x: 100, y: 80)) })
        let top = try #require(corners.firstIndex { near($0.point, .zero) })
        outline.subpaths[0].anchors[low] = corners[low].offset(by: CGPoint(x: 0, y: 50))
        outline.subpaths[0].anchors[top] = BezierPath.Anchor(CGPoint(x: 10, y: 0), in: CGPoint(x: 10, y: 30), out: CGPoint(x: 40, y: -10))
        box.poseShape(outline, at: 1)
        let keyed = try #require(box[track: .shape]?.keys.last?.v)
        let keyedSquare = try #require(box.outline(at: 1))
        let bench = bench([box])
        // Rounded, rounded otherwise, each corner its own way, smooth, and square again.
        let steps: [(inout Node) -> Void] = [
            { $0.cornerRadius = 10 }, { $0.cornerRadius = 24 }, { $0.corners = [0, 30, 12, 0] },
            { $0.corners = nil; $0.cornerRadius = 20; $0.cornerSmoothing = 0.6 }, { $0.cornerRadius = 0; $0.cornerSmoothing = nil },
        ]
        for (i, change) in steps.enumerated() {
            bench.step { bench.store.update([box.id], "Corner Radius") { change(&$0) } }
            let now = try #require(bench.node("Box"))
            #expect(fits(now), "step \(i)")
            // Every point of the outline as keyed lies on the square as keyed, however its corners
            // are rounded, as each goes as its place along the square's sides went. (Smoothed
            // corners have points inside the corner too.)
            guard now.cornerSmoothing == nil else { continue }
            for p in try #require(now.outline(at: 1)).anchorPoints {
                let spot = try #require(keyedSquare.nearest(to: p))
                #expect(spot.distance < 0.01, "step \(i): \(p) is \(spot.distance) off the square as keyed")
            }
        }
        // Square again: the keys are what was keyed, every number of them.
        let back = try #require(bench.node("Box")?[track: .shape]?.keys.last?.v)
        #expect(back.count == keyed.count && zip(back, keyed).allSatisfy { abs($0 - $1) < 1e-6 }, "\(back) \(keyed)")
        // Undone step by step, each outline has its keys as they were.
        for _ in steps { bench.undo.undo() }
        #expect(bench.node("Box")?[track: .shape]?.keys.last?.v == keyed)
    }

    @Test func aPointMovedOnTheRoundedRectangleItselfGoesWithTheCornerItLiesOn() throws {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 100, height: 80))
        card.cornerRadius = 10
        // The point where the bottom right corner's curve begins on the right side goes 10 down
        // and its handles with it: a key the square could not have made.
        let rest = card.shapeRest
        let outline = try #require(card.ownOutline)
        let start = try #require(outline.anchorPoints.firstIndex { near($0, CGPoint(x: 100, y: 70)) })
        var change = rest
        for i in [1, 3, 5] { change[start * 6 + i] = 10 }
        card.setKey(.shape, change, at: 1)
        let bench = bench([card])
        bench.step { bench.store.update([card.id], "Corner Radius") { $0.cornerRadius = 0 } }
        let now = try #require(bench.node("Card"))
        #expect(fits(now))
        let key = try #require(now[track: .shape]?.keys.last?.v)
        let design = try #require(now.ownOutline).anchorPoints
        // The bottom right corner goes down by as much as the place nearest it on the curve did,
        // and the other three, far from what moved, not at all.
        let corner = try #require(design.firstIndex { near($0, CGPoint(x: 100, y: 80)) })
        #expect(key[corner * 6 + 1] > 1 && key[corner * 6 + 1] < 10, "\(key)")
        for i in design.indices where i != corner {
            #expect(key[(i * 6)..<(i * 6 + 6)].allSatisfy { $0 == 0 }, "\(design[i]): \(key[(i * 6)..<(i * 6 + 6)])")
        }
    }

    @Test func aPathGivenOtherPointsAtOnceKeepsItsKeysWhereTheOutlineLies() throws {
        // A square whose right side goes 40 further right.
        var square = path("M 0 0 L 100 0 L 100 100 L 0 100 Z", name: "Square")
        var outline = try #require(square.ownOutline)
        outline.subpaths[0].anchors[1].point.x += 40
        outline.subpaths[0].anchors[2].point.x += 40
        square.poseShape(outline, at: 1)
        let bench = bench([square])
        // The same square given a point in the middle of each side, and drawn from another corner,
        // as combining shapes or an assistant writing its path does: not a point at a time.
        bench.step {
            bench.store.update([square.id], "Path") {
                $0.path = "M 100 100 L 50 100 L 0 100 L 0 50 L 0 0 L 50 0 L 100 0 L 100 50 Z"
                $0.pathBox = CGRect(x: 0, y: 0, width: 100, height: 100)
            }
        }
        let now = try #require(bench.node("Square"))
        #expect(fits(now))
        let design = try #require(now.ownOutline).anchorPoints
        let moved = try #require(now.outline(at: 1)).anchorPoints
        for (was, to) in zip(design, moved) {
            // The right side went 40, the left stayed, the middles of top and bottom went half.
            let across: CGFloat = was.x > 99 ? 40 : was.x > 49 ? 20 : 0
            #expect(near(to, CGPoint(x: was.x + across, y: was.y)), "\(was) went to \(to)")
        }
    }

    // MARK: Flipped

    @Test func aPathFlippedHasItsKeysTurnedOverWithIt() throws {
        var tri = path("M 100 60 L 200 60 L 120 140 Z", name: "Tri")
        var outline = try #require(tri.ownOutline)
        // The tip, left of the middle, goes 30 further left and 20 down.
        outline.subpaths[0].anchors[2].point = outline.subpaths[0].anchors[2].point + CGPoint(x: -30, y: 20)
        tri.poseShape(outline, at: 1)
        let bench = bench([tri])
        let before = bench.store.doc
        bench.store.selection = [tri.id]
        bench.step { bench.store.flip(horizontally: true) }
        var now = try #require(bench.node("Tri"))
        var design = try #require(now.ownOutline).anchorPoints
        var moved = try #require(now.outline(at: 1)).anchorPoints
        // The tip is right of the middle now, and goes right.
        #expect(near(design[2], CGPoint(x: 80, y: 80)))
        #expect(near(moved[2], CGPoint(x: 110, y: 100)), "\(moved[2])")
        #expect(near(moved[0], design[0]) && near(moved[1], design[1]))
        bench.undo.undo()
        #expect(bench.store.doc == before)
        bench.undo.redo()
        bench.step { bench.store.flip(horizontally: false) }
        now = try #require(bench.node("Tri"))
        design = try #require(now.ownOutline).anchorPoints
        moved = try #require(now.outline(at: 1)).anchorPoints
        // Top to bottom: the tip is at the top, and goes up.
        #expect(near(design[2], CGPoint(x: 80, y: 0)))
        #expect(near(moved[2], CGPoint(x: 110, y: -20)), "\(moved[2])")
        // Flipped back both ways, the keys are what they were.
        bench.step { bench.store.flip(horizontally: true) }
        bench.step { bench.store.flip(horizontally: false) }
        let back = try #require(bench.node("Tri")?[track: .shape]?.keys.last?.v)
        let was = try #require(tri[track: .shape]?.keys.last?.v)
        #expect(zip(back, was).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func shapesDrawnByTheirKindAreTurnedOverToo() throws {
        // An ellipse whose rightmost point goes 30 further right: flipped, its leftmost goes left.
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 40, y: 40, width: 100, height: 60))
        var outline = try #require(dot.ownOutline)
        let right = try #require(outline.subpaths[0].anchors.firstIndex { near($0.point, CGPoint(x: 100, y: 30)) })
        outline.subpaths[0].anchors[right] = outline.subpaths[0].anchors[right].offset(by: CGPoint(x: 30, y: 0))
        dot.poseShape(outline, at: 1)
        // A line rising to the right whose right end goes 20 up: flipped, its left end does.
        var line = Node(kind: .line, name: "Line", frame: CGRect(x: 200, y: 40, width: 100, height: 50))
        line.rising = true
        var ends = try #require(line.ownOutline)
        #expect(near(ends.anchorPoints[1], CGPoint(x: 100, y: 0)))
        ends.subpaths[0].anchors[1].point.y -= 20
        line.poseShape(ends, at: 1)
        // A rectangle with one round corner, top left, which goes 15 up and left.
        var box = CanvasTests.rect("Box", CGRect(x: 40, y: 160, width: 100, height: 80))
        box.corners = [20, 0, 0, 0]
        var edge = try #require(box.ownOutline)
        for i in edge.subpaths[0].anchors.indices where edge.subpaths[0].anchors[i].point.x <= 20 && edge.subpaths[0].anchors[i].point.y <= 20 {
            edge.subpaths[0].anchors[i] = edge.subpaths[0].anchors[i].offset(by: CGPoint(x: -15, y: -15))
        }
        box.poseShape(edge, at: 1)
        let bench = bench([dot, line, box])
        bench.store.selection = [dot.id]
        bench.step { bench.store.flip(horizontally: true) }
        bench.store.selection = [line.id]
        bench.step { bench.store.flip(horizontally: true) }
        bench.store.selection = [box.id]
        bench.step { bench.store.flip(horizontally: true) }

        let round = try #require(bench.node("Dot")?.outline(at: 1))
        #expect(abs(round.bounds.minX + 30) < 0.01 && abs(round.bounds.maxX - 100) < 0.01, "\(round.bounds)")
        // Still an ellipse's curve through the point that went: its handles went with it.
        let far = try #require(round.subpaths[0].anchors.first { near($0.point, CGPoint(x: -30, y: 30)) })
        #expect(abs((far.handleIn?.x ?? 0) + 30) < 0.01 && abs((far.handleOut?.x ?? 0) + 30) < 0.01)

        let flipped = try #require(bench.node("Line"))
        #expect(flipped.rising == false)
        let now = try #require(flipped.outline(at: 1)).anchorPoints
        // It falls to the right now: its left end, at the top, goes 20 up.
        #expect(near(now[0], CGPoint(x: 0, y: -20)) && near(now[1], CGPoint(x: 100, y: 50)), "\(now)")

        let turned = try #require(bench.node("Box"))
        #expect(turned.corners == [0, 20, 0, 0])
        #expect(fits(turned))
        let shown = try #require(turned.outline(at: 1))
        // The round corner is top right, and goes up and right.
        #expect(abs(shown.bounds.maxX - 115) < 0.01 && abs(shown.bounds.minY + 15) < 0.01 && abs(shown.bounds.minX) < 0.01, "\(shown.bounds)")
    }

    @Test func aGroupFlippedTurnsOverTheKeysOfWhatItHolds() throws {
        var tri = path("M 10 10 L 110 10 L 30 90 Z", name: "Tri")
        var outline = try #require(tri.ownOutline)
        outline.subpaths[0].anchors[2].point.x -= 25
        tri.poseShape(outline, at: 1)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 20, y: 20, width: 200, height: 100))
        group.children = [tri, CanvasTests.rect("Box", CGRect(x: 150, y: 0, width: 50, height: 100))]
        let bench = bench([group])
        bench.store.selection = [group.id]
        bench.step { bench.store.flip(horizontally: true) }
        let key = try #require(bench.node("Tri")?[track: .shape]?.keys.last?.v)
        #expect(abs(key[12] - 25) < 1e-9, "\(key[12])")
    }

    // MARK: Copies

    @Test func everyCellOfARepeatGridKeepsItsOwnKeysWithItsOutline() throws {
        let bench = bench([CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        let store = bench.store
        store.selection = [bench.node("R")!.id]
        bench.step { store.makeRepeatGrid() }
        let grid = store.selection[0]
        bench.step { store.edit("Repeat Grid") { $0.update(grid) { $0.grid?.columns = 2 } } }
        let cells = try #require(store.node(grid)).children.filter { $0.name == "R" || $0.children.contains { $0.name == "R" } }
        func squares() -> [Node] { store.doc.allNodes.filter { $0.name == "R" && $0.kind == .rectangle } }
        #expect(squares().count == 2, "\(cells.count) cells")
        // Each cell's square keyed its own way: the first one's bottom right corner 30 down, the
        // second's 50 right, its handles with it as a point moved on the canvas takes them.
        let first = squares()[0].id, second = squares()[1].id
        bench.step {
            store.edit("Pose") { doc in
                doc.update(first) { n in var v = n.shapeRest; for i in [13, 15, 17] { v[i] = 30 }; n.setKey(.shape, v, at: 1) }
                doc.update(second) { n in var v = n.shapeRest; for i in [12, 14, 16] { v[i] = 50 }; n.setKey(.shape, v, at: 1) }
            }
        }
        #expect(store.node(first)?[track: .shape] != store.node(second)?[track: .shape])
        // The first cell's square rounded: every cell's is, and each keeps what it was keyed to do.
        bench.step { store.update([first], "Corner Radius") { $0.cornerRadius = 12 } }
        for n in squares() {
            #expect(n.cornerRadius == 12)
            #expect(n.ownOutline?.anchorCount == 9)
            #expect(fits(n), "\(n.id == first ? "first" : "second")")
        }
        #expect(try #require(store.node(first)?.outline(at: 1)).bounds.maxY > 120)
        #expect(try #require(store.node(second)?.outline(at: 1)).bounds.maxX > 140)
        #expect(try #require(store.node(second)?.outline(at: 1)).bounds.maxY < 100.01)
    }

    @Test func aNewCopyMadeAtAnotherSizeHasItsShapeKeysGrownWithIt() throws {
        // A button whose back's bottom right corner goes 20 down at one second, and whose dot
        // keeps its size in the middle; made a component.
        var back = CanvasTests.rect("Back", CGRect(x: 0, y: 0, width: 120, height: 40))
        let corner = try #require(back.ownOutline?.anchorPoints.firstIndex { near($0, CGPoint(x: 120, y: 40)) })
        var change = back.shapeRest
        for i in [1, 3, 5] { change[corner * 6 + i] = 20 }
        back.setKey(.shape, change, at: 1)
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 55, y: 15, width: 10, height: 10))
        var round = try #require(dot.ownOutline)
        round.subpaths[0].anchors = round.subpaths[0].anchors.map { $0.offset(by: CGPoint(x: 0, y: -5)) }
        dot.poseShape(round, at: 1)
        var button = Node(kind: .group, name: "Button", frame: CGRect(x: 40, y: 40, width: 120, height: 40))
        button.children = [back, dot]
        var doc = BezzleDocument()
        doc.nodes = [button]
        let made = doc.makeComponent(from: [button.id])
        #expect(made != nil)
        let master = try #require(doc.masters.first)
        // A new copy twice as wide and three times as high: the back's corner goes 60 down.
        let copy = Components.newCopy(of: master, at: CGPoint(x: 300, y: 40), size: CGSize(width: 240, height: 120))
        let grown = try #require(copy.children.first { $0.name == "Back" })
        #expect(grown.frame.size == CGSize(width: 240, height: 120))
        #expect(fits(grown))
        let design = try #require(grown.ownOutline).anchorPoints, moved = try #require(grown.outline(at: 1)).anchorPoints
        let far = try #require(design.firstIndex { near($0, CGPoint(x: 240, y: 120)) })
        #expect(near(moved[far], CGPoint(x: 240, y: 180)), "\(moved[far])")
        #expect(zip(design, moved).enumerated().allSatisfy { $0.offset == far || near($0.element.0, $0.element.1) })
        // The dot, as large as it was, keeps its keys as they were.
        #expect(copy.children.first { $0.name == "Dot" }?[track: .shape] == dot[track: .shape])
        // A copy as large as the component has the component's keys.
        let same = Components.newCopy(of: master, at: .zero)
        #expect(same.children.first { $0.name == "Back" }?[track: .shape] == back[track: .shape])
        // Placed in a design by the store, it is so too, and stays so as the copy is synced.
        let bench = bench([])
        bench.step { bench.store.edit("Add Copy") { $0.masters = doc.masters; $0.nodes[0].children.append(copy) } }
        let placed = try #require(bench.store.doc.allNodes.first { $0.id == grown.id })
        #expect(placed[track: .shape] == grown[track: .shape])
    }

    @Test func aComponentsCopiesKeepTheirOwnKeysWithTheirOutlines() throws {
        var button = Node(kind: .group, name: "Button", frame: CGRect(x: 40, y: 40, width: 120, height: 40))
        button.children = [CanvasTests.rect("Back", CGRect(x: 0, y: 0, width: 120, height: 40))]
        let bench = bench([button])
        let store = bench.store
        store.selection = [button.id]
        bench.step { store.makeComponent() }
        let first = store.selection[0]
        bench.step { store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        let second = store.selection[0]
        func back(_ copy: UUID) -> Node { store.doc.node(copy)!.children.first { $0.name == "Back" }! }
        // The second copy's back keyed: its bottom right corner goes 20 down.
        let corner = try #require(back(second).ownOutline?.anchorPoints.firstIndex { near($0, CGPoint(x: 120, y: 40)) })
        bench.step { store.edit("Pose") { $0.update(back(second).id) { n in var v = n.shapeRest; for i in [1, 3, 5] { v[corner * 6 + i] = 20 }; n.setKey(.shape, v, at: 1) } } }
        #expect(back(first)[track: .shape] == nil)
        // The first copy's back rounded: the component's is, and so the second copy's, which
        // keeps its keys, now for eight points.
        bench.step { store.update([back(first).id], "Corner Radius") { $0.cornerRadius = 8 } }
        #expect(back(second).cornerRadius == 8)
        #expect(fits(back(second)))
        #expect(try #require(back(second).outline(at: 1)).bounds.maxY > 55, "\(back(second)[track: .shape]?.keys.map(\.v) ?? []) \(back(second).ownOutline?.anchorPoints ?? [])")
        // The second copy made twice as wide: its back with it, and its keys.
        let before = try #require(back(second)[track: .shape]?.keys.last?.v)
        bench.step { store.update([second], "Resize") { $0.resize(to: CGSize(width: 240, height: 80), byHeight: false) } }
        let grown = back(second)
        #expect(grown.frame.width > 200)
        #expect(fits(grown))
        let after = try #require(grown[track: .shape]?.keys.last?.v)
        let sy = Double(grown.frame.height / 40)
        #expect(zip(before, after).enumerated().allSatisfy { i, pair in i % 2 == 0 || abs(pair.0 * sy - pair.1) < 1e-6 }, "\(before) \(after)")
        // Flipped whole, top to bottom: the corner that went down goes up, once, and stays so
        // when the copy is made again from its component.
        store.selection = [second]
        bench.step { store.flip(horizontally: false) }
        #expect(fits(back(second)))
        #expect(try #require(back(second).outline(at: 1)).bounds.minY < -15)
        bench.step { store.update([back(first).id], "Fill") { $0.fill.color = RGBA(r: 0.2, g: 0.4, b: 0.6) } }
        #expect(try #require(back(second).outline(at: 1)).bounds.minY < -15)
        #expect(try #require(back(second).outline(at: 1)).bounds.maxY < back(second).frame.height + 0.01)
    }
}
