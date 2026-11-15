import Testing
import AppKit
@testable import Bezzle

/// Several layers turned in depth as one body: about the middle they share, each ending where a
/// real body's face would, from the canvas, the 3D card, a film's Pose card and the AI server.
@MainActor
struct DepthBodyTests {
    /// A 400 by 300 artboard, seen from 800 points in front of its middle.
    private let size = CGSize(width: 400, height: 300)

    private func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), rotation: Double = 0,
                      color: RGBA = .white) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = color
        n.rotation = rotation
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
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

    /// A card with a button raised 20 points off it, to the right of its middle.
    private var cardAndButton: [Node] {
        [card("Card", CGRect(x: 100, y: 100, width: 200, height: 100)),
         card("Button", CGRect(x: 240, y: 140, width: 40, height: 20), z: 20, color: RGBA(r: 1, g: 0, b: 0))]
    }

    private func far(_ a: ScenePoint, _ b: ScenePoint) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// How far the furthest of these points is from where a body turned by `spin` about `pivot`
    /// takes it: nothing, for one body.
    private func off(_ before: [ScenePoint], _ after: [ScenePoint], _ spin: Spin, _ pivot: ScenePoint) -> Double {
        guard before.count == after.count, !before.isEmpty else { return .infinity }
        return zip(before, after).map { far(pivot + spin($0 - pivot), $1) }.max() ?? .infinity
    }

    private func turn(_ doc: inout BezzleDocument, _ names: [String], x: Double? = nil, y: Double? = nil) {
        let ids = names.compactMap { name in doc.allNodes.first { $0.name == name }?.id }
        doc.turnInDepth(ids) { _, now in
            var t = now
            if let x { t.x = x }
            if let y { t.y = y }
            return t
        }
    }

    private func node(_ doc: BezzleDocument, _ name: String) -> Node { doc.allNodes.first { $0.name == name }! }

    // MARK: A turn in space

    @Test func aTurnIsKeptAsTipSwingAndTwistAndReadBackTheSame() {
        for (tip, swing, twist) in [(20.0, -30.0, 0.0), (-50, 10, 35), (0, 70, -120), (145, 20, 5), (10, 120, 0), (-170, -100, 60)] {
            let spin = Spin.tip(tip).after(.swing(swing)).after(.turn(twist))
            let read = spin.angles(near: (tip, swing))
            #expect(abs(read.tip - tip) < 1e-9 && abs(read.swing - swing) < 1e-9 && abs(Spin.wrapped(read.twist - twist)) < 1e-9, "\(tip) \(swing) \(twist): \(read)")
        }
        // A layer's turn is its swing, then its tip, as it is drawn: its right side going away, its top going away.
        let spin = Spin(Transform3D(x: 30, y: 40))
        #expect(spin(ScenePoint(x: 1)).z < 0 && spin(ScenePoint(y: -1)).z < 0)
        let undone = spin.back.after(spin).angles()
        #expect(abs(undone.tip) < 1e-9 && abs(undone.swing) < 1e-9 && abs(undone.twist) < 1e-9)
        // Seen edge on, tip and twist are one: all of it is the tip.
        let edge = Spin.tip(25).after(.swing(90)).angles()
        #expect(abs(edge.tip - 25) < 1e-9 && edge.swing == 90 && edge.twist == 0)
    }

    // MARK: One body

    @Test func twoLayersTurnAboutTheMiddleTheyShareEachWhereABodysFaceWouldBe() throws {
        var doc = design(cardAndButton)
        let before = doc
        // The card is the lead, the larger face; the middle is that of the box round both: the
        // card's middle across and down, and halfway up to the button.
        let body = doc.depthBodies(of: doc.nodes[0].children.map(\.id))
        #expect(body.count == 1 && body[0].count == 2)
        let lead = try #require(DepthBody.lead(of: body[0]))
        #expect(lead.name == "Card")
        let pivot = DepthBody.middle(of: body[0], lead: lead)
        #expect(pivot == ScenePoint(x: 200, y: 150, z: 10))

        turn(&doc, ["Card", "Button"], y: 40)
        let c = node(doc, "Card"), b = node(doc, "Button")
        // Both face the same way now.
        #expect(c.transform3D?.x == 0 && c.transform3D?.y == 40 && b.transform3D?.x == 0 && b.transform3D?.y == 40)
        // The card's middle lay 10 under the pivot: it goes a little left and stays about as high.
        let s = sin(40 * Double.pi / 180), k = cos(40 * Double.pi / 180)
        #expect(abs(c.frame.midX - (200 - 10 * s)) < 1e-9 && c.frame.midY == 150 && abs(Double(c.transform3D?.z ?? 0) - (10 - 10 * k)) < 1e-9)
        // The button lay 60 to the right and 10 over it: its side of the body has swung away.
        #expect(abs(b.frame.midX - (200 + 60 * k + 10 * s)) < 1e-9 && b.frame.midY == 150)
        #expect(abs(Double(b.transform3D?.z ?? 0) - (10 - 60 * s + 10 * k)) < 1e-9)
        #expect(c.frame.size == CGSize(width: 200, height: 100) && b.frame.size == CGSize(width: 40, height: 20))
        // Every corner of both went round the pivot as one thing.
        let was = before.nodes[0].children.flatMap(DepthBody.corners), now = doc.nodes[0].children.flatMap(DepthBody.corners)
        #expect(off(was, now, .swing(40), pivot) < 1e-6)
    }

    @Test func laidFlatAgainABodyLiesToThePointWhereItLay() {
        var doc = design(cardAndButton)
        let before = doc
        turn(&doc, ["Card", "Button"], x: 23.5, y: -41)
        #expect(node(doc, "Button").frame != node(before, "Button").frame)
        doc.layFlat(doc.nodes[0].children.map(\.id))
        for name in ["Card", "Button"] {
            #expect(node(doc, name).frame == node(before, name).frame, "\(name): \(node(doc, name).frame)")
        }
        #expect(node(doc, "Card").transform3D == Transform3D())
        #expect(node(doc, "Button").transform3D == Transform3D(z: 20))
    }

    @Test func aBodyGoesRoundTheSamePointHoweverOftenItIsTurned() throws {
        var doc = design(cardAndButton + [card("Tag", CGRect(x: 110, y: 60, width: 50, height: 24), z: -12, rotation: 0)])
        let before = doc
        let names = ["Card", "Button", "Tag"]
        let ids = doc.nodes[0].children.map(\.id)
        let pivot = DepthBody.middle(of: doc.nodes[0].children, lead: node(doc, "Card"))
        for (x, y) in [(10.0, 25.0), (-35, 60), (20, -10), (80, 5)] {
            turn(&doc, names, x: x, y: y)
            let lead = try #require(DepthBody.lead(of: doc.nodes[0].children))
            let again = DepthBody.middle(of: doc.nodes[0].children, lead: lead)
            #expect(far(again, pivot) < 1e-9, "\(x), \(y): \(again)")
            // Turned from flat, it is all turned one way.
            #expect(DepthBody.facesOneWay(doc.nodes[0].children))
            #expect(doc.nodes[0].children.allSatisfy { $0.transform3D?.x == x && $0.transform3D?.y == y && $0.rotation == 0 })
        }
        doc.layFlat(ids)
        for name in names { #expect(node(doc, name).frame == node(before, name).frame, "\(name): \(node(doc, name).frame)") }
        #expect(node(doc, "Tag").transform3D == Transform3D(z: -12))
    }

    @Test func layersFacingOtherWaysStayOneBodyAndTakeTheRestAsATurnInTheirOwnPlane() throws {
        var pinned = card("Screen", CGRect(x: 60, y: 200, width: 120, height: 70), z: 8, turn: (10, 20))
        pinned.transform3D?.corners = [CGPoint(x: 0.05, y: 0), CGPoint(x: 1, y: 0.1), CGPoint(x: 0.9, y: 1), CGPoint(x: 0, y: 0.95)]
        var doc = design([card("Floor", CGRect(x: 60, y: 60, width: 260, height: 160)),
                          card("Side", CGRect(x: 250, y: 90, width: 90, height: 60), z: 15, turn: (30, -50), rotation: 20),
                          pinned])
        let before = doc
        let pivot = DepthBody.middle(of: doc.nodes[0].children, lead: node(doc, "Floor"))
        turn(&doc, ["Floor", "Side", "Screen"], x: 25, y: 35)
        let spin = Spin(Transform3D(x: 25, y: 35))
        #expect(off(DepthBody.corners(of: node(before, "Floor")), DepthBody.corners(of: node(doc, "Floor")), spin, pivot) < 1e-6)
        // A turn in the page is kept in hundredths of a degree, as everywhere: to a hundredth of a point here.
        #expect(off(DepthBody.corners(of: node(before, "Side")), DepthBody.corners(of: node(doc, "Side")), spin, pivot) < 0.01)
        // The side face is turned in its own plane too, by its rotation.
        let side = node(doc, "Side")
        #expect(side.rotation != 20 && side.transform3D?.x != 30)
        #expect(!DepthBody.facesOneWay(doc.nodes[0].children))
        // One pinned by its corners takes that turn where they are pinned: each stands where the body has it.
        func pins(_ n: Node) -> [ScenePoint] {
            let t = n.transform3D!
            return t.corners!.map { k in
                DepthBody.middle(of: n) + Spin(t)(ScenePoint(x: Double((k.x - 0.5) * n.frame.width), y: Double((k.y - 0.5) * n.frame.height)))
            }
        }
        #expect(node(doc, "Screen").rotation == 0 && node(doc, "Screen").transform3D?.pinned == true)
        #expect(off(pins(node(before, "Screen")), pins(node(doc, "Screen")), spin, pivot) < 1e-6)
        // Turned again and again, it goes round the same point and stays one body: nothing
        // drifts but by those hundredths.
        var often = before
        var whole = Spin.none
        for (x, y) in [(25.0, 35.0), (-40, 10), (15, -70), (60, 20)] {
            let lead = Spin(node(often, "Floor").transform3D ?? Transform3D())
            turn(&often, ["Floor", "Side", "Screen"], x: x, y: y)
            whole = Spin(Transform3D(x: x, y: y)).after(lead.back).after(whole)
            #expect(far(DepthBody.middle(of: often.nodes[0].children, lead: node(often, "Floor")), pivot) < 0.05, "\(x), \(y)")
        }
        #expect(off(DepthBody.corners(of: node(before, "Side")), DepthBody.corners(of: node(often, "Side")), whole, pivot) < 0.1)
        #expect(off(pins(node(before, "Screen")), pins(node(often, "Screen")), whole, pivot) < 0.1)
        // Laid flat, layers that face other ways are each laid flat where they are.
        let turned = doc
        doc.layFlat(doc.nodes[0].children.map(\.id))
        #expect(doc.nodes[0].children.allSatisfy { $0.transform3D?.x == 0 && $0.transform3D?.y == 0 })
        #expect(node(doc, "Side").frame == node(turned, "Side").frame && node(doc, "Side").transform3D?.z == node(turned, "Side").transform3D?.z)
    }

    @Test func aGroupInABodyTurnsWhatItHoldsAndStaysWhereTheBodyHasIt() throws {
        var group = Node(kind: .group, name: "Face", frame: CGRect(x: 50, y: 40, width: 120, height: 80))
        group.children = [card("In", CGRect(x: 0, y: 0, width: 60, height: 30)), card("Out", CGRect(x: 80, y: 50, width: 40, height: 30), rotation: 15)]
        group.transform3D = Transform3D(x: 20, y: 60, z: 30)
        var doc = design([card("Floor", CGRect(x: 40, y: 30, width: 300, height: 220)), group])
        doc.fitGroups()
        let before = doc
        // Where the corners of what a group holds stand in the scene: through the group's own turn.
        func held(_ doc: BezzleDocument) -> [ScenePoint] {
            let g = node(doc, "Face")
            let middle = DepthBody.middle(of: g), spin = Spin(g.transform3D ?? Transform3D())
            return g.children.flatMap { child in
                Geometry.corners(of: child.frame, rotation: child.rotation).map { p in
                    middle + spin(ScenePoint(x: Double(p.x + g.frame.minX - g.frame.midX), y: Double(p.y + g.frame.minY - g.frame.midY)))
                }
            }
        }
        let pivot = DepthBody.middle(of: doc.nodes[0].children, lead: node(doc, "Floor"))
        turn(&doc, ["Floor", "Face"], x: 30, y: -20)
        // Fitted already, as the store will leave it: fitting again moves nothing.
        var fitted = doc
        fitted.fitGroups()
        #expect(fitted == doc)
        // A group has no turn of its own in the page: what it holds took it, about its middle.
        #expect(node(doc, "Face").rotation == 0 && node(doc, "In").rotation != 0)
        #expect(abs(Geometry.normalized(node(doc, "Out").rotation - node(doc, "In").rotation) - 15) < 1e-6)
        // To the hundredths of a degree a turn in the page is kept in.
        #expect(off(held(before), held(doc), Spin(Transform3D(x: 30, y: -20)), pivot) < 0.01)
    }

    @Test func oneLayerAndLayersLyingApartTurnAsTheyAlwaysDid() {
        // One layer: about its own middle, where it is.
        var doc = design(cardAndButton)
        turn(&doc, ["Button"], x: 15, y: 40)
        #expect(node(doc, "Button").frame == CGRect(x: 240, y: 140, width: 40, height: 20))
        #expect(node(doc, "Button").transform3D == Transform3D(x: 15, y: 40, z: 20))
        // One on each of two artboards, and two off any artboard, where there is no scene to
        // stand in: each about its own middle.
        var other = board([card("There", CGRect(x: 10, y: 10, width: 80, height: 50))])
        other.frame.origin.x = 500
        var two = BezzleDocument()
        two.nodes = [board([card("Here", CGRect(x: 30, y: 30, width: 80, height: 50))]), other,
                     card("Loose", CGRect(x: 1000, y: 0, width: 60, height: 60)), card("Looser", CGRect(x: 1100, y: 40, width: 60, height: 60))]
        let was = two
        let names = ["Here", "There", "Loose", "Looser"]
        #expect(two.depthBodies(of: names.map { node(two, $0).id }).map(\.count) == [1, 1, 1, 1])
        turn(&two, names, x: 20, y: 30)
        for name in names {
            #expect(node(two, name).frame == node(was, name).frame && node(two, name).transform3D == Transform3D(x: 20, y: 30), "\(name)")
        }
        // Artboards and locked layers are left out of a body.
        var locked = design(cardAndButton)
        locked.update(node(locked, "Button").id) { $0.locked = true }
        #expect(locked.depthBodies(of: locked.allNodes.map(\.id)).map { $0.map(\.name) } == [["Card"]])
    }

    @Test func aBodyIsDrawnWithItsRaisedFaceWhereTheBodyHasIt() throws {
        var doc = design(cardAndButton)
        turn(&doc, ["Card", "Button"], y: 40)
        let image = try #require(Renderer.image(of: doc.nodes[0], scale: 1))
        let bitmap = NSBitmapImageRep(cgImage: image)
        func pixel(_ p: CGPoint) -> NSColor { bitmap.colorAt(x: Int(p.x.rounded()), y: Int(p.y.rounded()))!.usingColorSpace(.sRGB)! }
        let eye = Eye.stage(size)
        let button = node(doc, "Button"), cardNode = node(doc, "Card")
        // The button shows over the card at its own middle, red, where the body has taken it:
        // well to the left of where it lay, its side of the card having swung away.
        let middle = try #require(Perspective(button, eye: eye)).shown(button.frame.center)
        #expect(pixel(middle).redComponent > 0.9 && pixel(middle).blueComponent < 0.05, "\(middle): \(pixel(middle))")
        #expect(middle.x < 255)
        // The card under it, white, at its own middle and a little left of the button.
        let face = try #require(Perspective(cardNode, eye: eye))
        #expect(pixel(face.shown(cardNode.frame.center)).blueComponent > 0.9)
        #expect(pixel(CGPoint(x: middle.x - 24, y: middle.y)).blueComponent > 0.9)
        // Where the button lay before, flat on the card's right, the card has swung away from.
        #expect(pixel(CGPoint(x: 296, y: 150)).redComponent < 0.05)
    }

    // MARK: What covers what

    private func drawn(_ doc: BezzleDocument, only names: Set<String>? = nil) -> [String] {
        DepthOrder.stacked(doc.nodes[0].children).map(\.name).filter { names?.contains($0) ?? true }
    }

    @Test func aBodysFacesCoverOneAnotherAsTheyDidLyingFlat() throws {
        // On a backdrop: a card, a label lying on its right in its own plane, and the button raised off it.
        var doc = design([card("Back", CGRect(x: 20, y: 20, width: 360, height: 260)), cardAndButton[0],
                          card("Label", CGRect(x: 250, y: 110, width: 40, height: 16)), cardAndButton[1]])
        let body = ["Card", "Label", "Button"]
        #expect(drawn(doc) == ["Back", "Card", "Label", "Button"])
        turn(&doc, body, y: 40)
        // Its right side has swung away: the label's middle stands lower than the card's now,
        // and the button's lower than the backdrop. They still lie on the card, and over the backdrop.
        let z = { (name: String) in self.node(doc, name).transform3D?.z ?? 0 }
        #expect(z("Label") < z("Card") && z("Button") < 0 && z("Card") > 0)
        #expect(drawn(doc) == ["Back", "Card", "Label", "Button"])
        // Swung the other way, the same.
        turn(&doc, body, x: 30, y: -55)
        #expect(drawn(doc) == ["Back", "Card", "Label", "Button"])
        // Turned to show its back, the button is behind its card.
        turn(&doc, body, x: 0, y: 150)
        #expect(drawn(doc, only: Set(body)) == ["Button", "Card", "Label"])
        // Laid flat, as it was.
        doc.layFlat(body.map { node(doc, $0).id })
        #expect(drawn(doc) == ["Back", "Card", "Label", "Button"])
    }

    @Test func layersThatAreNoBodyAreOrderedByTheHeightOfTheirMiddlesAsTheyWere() {
        // Turned alike but lying apart, each raised on its own; and one lying level between them.
        var children = [card("High", CGRect(x: 20, y: 20, width: 80, height: 60), z: 30, turn: (0, 30)),
                        card("Low", CGRect(x: 250, y: 200, width: 80, height: 60), z: 10, turn: (0, 30)),
                        card("Level", CGRect(x: 150, y: 120, width: 80, height: 60), z: 20)]
        #expect(DepthOrder.stacked(children).map(\.name) == ["Low", "Level", "High"])
        #expect(DepthOrder.nearness(children.map { DepthOrder.Face($0) }) == [30, 10, 20])
        // Turned other ways, over one another: by their middles too.
        children = [card("Tipped", CGRect(x: 100, y: 100, width: 120, height: 80), z: 12, turn: (40, 0)),
                    card("Swung", CGRect(x: 120, y: 110, width: 120, height: 80), z: 4, turn: (0, 40)),
                    card("Lying", CGRect(x: 110, y: 90, width: 120, height: 80), z: 8)]
        #expect(DepthOrder.stacked(children).map(\.name) == ["Swung", "Lying", "Tipped"])
        // Turned alike at one height, over one another: as listed.
        children = [card("First", CGRect(x: 100, y: 100, width: 120, height: 80), z: 5, turn: (20, 30)),
                    card("Second", CGRect(x: 60, y: 110, width: 120, height: 80), z: 5, turn: (20, 30)),
                    card("Third", CGRect(x: 140, y: 80, width: 120, height: 80), z: 5, turn: (20, 30))]
        #expect(DepthOrder.stacked(children).map(\.name) == ["First", "Second", "Third"])
        // A stack of cards over one place, each turned about its own middle: the higher over the lower, from the back too.
        for swing in [35.0, 140] {
            children = [card("Top", CGRect(x: 100, y: 100, width: 120, height: 80), z: 80, turn: (0, swing)),
                        card("Bottom", CGRect(x: 100, y: 100, width: 120, height: 80), turn: (0, swing)),
                        card("Between", CGRect(x: 100, y: 100, width: 120, height: 80), z: 40, turn: (0, swing))]
            #expect(DepthOrder.stacked(children).map(\.name) == ["Bottom", "Between", "Top"], "\(swing)")
        }
        // Nothing turned: heights alone, and as listed where none is held higher.
        children = [card("A", CGRect(x: 0, y: 0, width: 50, height: 50), z: 3), card("B", CGRect(x: 10, y: 0, width: 50, height: 50)),
                    card("C", CGRect(x: 20, y: 0, width: 50, height: 50), z: 3)]
        #expect(DepthOrder.stacked(children).map(\.name) == ["B", "A", "C"])
        // Three hundred scenes of layers over one another, each turned its own way, some lying
        // level, at heights that often meet: the order is the one their middles' heights always gave.
        var seed: UInt64 = 20261114
        func any(_ below: Double) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31) * below
        }
        for scene in 0..<300 {
            let layers = (0..<7).map { i in
                let level = i == 3 || any(1) < 0.2
                return card("\(i)", CGRect(x: any(200), y: any(150), width: 60 + any(120), height: 40 + any(90)), z: CGFloat((any(7).rounded() - 3) * 10),
                            turn: level ? (0, 0) : (Double(i) * 20 - 60 + any(9).rounded(), Double(i) * -15 + 40 + any(9).rounded()))
            }
            let heights = layers.map { DepthOrder.height(of: $0) }
            let always = layers.indices.sorted { a, b in heights[a] != heights[b] ? heights[a] < heights[b] : a < b }
            #expect(DepthOrder.order(layers) == always, "scene \(scene)")
        }
    }

    @Test func aFaceInTheMiddleOfAnotherStaysOnItWhenSomethingStandsOverItsHigherEnd() throws {
        // A plate in a group that keeps depth, swung and lifted, a title in the plate's middle,
        // its middle exactly as high as the plate's, and a badge held over the plate's higher end.
        let ink = RGBA(r: 0.17, g: 0.15, b: 0.13), red = RGBA(r: 1, g: 0, b: 0)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 50, width: 200, height: 100))
        group.children = [card("Plate", CGRect(x: 0, y: 0, width: 200, height: 100)),
                          card("Title", CGRect(x: 80, y: 44, width: 40, height: 12), color: ink),
                          card("Badge", CGRect(x: 170, y: 4, width: 26, height: 26), z: 12, color: red)]
        group.transform3D = Transform3D(y: -40, z: 30)
        group.keepsDepth = true
        let doc = design([group])
        let board = doc.nodes[0]
        // The title lies on the plate, the badge over both, as listed and as the film has it.
        #expect(DepthOrder.scene(board.children, eye: Eye.stage(size)).map(\.node.name) == ["Plate", "Title", "Badge"])
        let pieces = board.filmPieces()
        let placements = pieces.map { board.placement(of: $0, at: 0, camera: board.camera(at: 0)) }
        #expect(board.filmOrder(pieces, placements).flatMap { pieces[$0].layers.compactMap { board.descendant($0)?.name } } == ["Plate", "Title", "Badge"])
        // So it is drawn: the title's ink in the group's middle, which stands 30 up.
        let image = try #require(Renderer.image(of: board, scale: 1))
        let middle = NSBitmapImageRep(cgImage: image).colorAt(x: 200, y: Int((150 - 50 * 800 / 770.0).rounded()))!.usingColorSpace(.sRGB)!
        #expect(middle.redComponent < 0.3 && middle.greenComponent < 0.3 && middle.blueComponent < 0.3, "\(middle)")
        // The same three turned as one body on the artboard: the title stays on the plate.
        var loose = design([card("Plate", CGRect(x: 100, y: 50, width: 200, height: 100)),
                            card("Title", CGRect(x: 180, y: 94, width: 40, height: 12), color: ink),
                            card("Badge", CGRect(x: 270, y: 54, width: 26, height: 26), z: 12, color: red)])
        turn(&loose, ["Plate", "Title", "Badge"], y: -40)
        let z = { (name: String) in self.node(loose, name).transform3D?.z ?? 0 }
        #expect(z("Plate") == z("Title") && z("Badge") != z("Plate"))
        #expect(drawn(loose) == ["Plate", "Title", "Badge"])
        // Faces turned alike in one plane at one height, with nothing standing over them, keep
        // the heights of their middles to the last place, and so the order listed among all else.
        let alike = [card("First", CGRect(x: 100, y: 100, width: 120, height: 80), z: 5, turn: (0, 30)),
                     card("Level", CGRect(x: 150, y: 120, width: 40, height: 40), z: 5),
                     card("Second", CGRect(x: 130, y: 120, width: 60, height: 40), z: 5, turn: (0, 30))]
        #expect(DepthOrder.nearness(alike.map { DepthOrder.Face($0) }) == [5, 5, 5])
        #expect(DepthOrder.stacked(alike).map(\.name) == ["First", "Level", "Second"])
    }

    @Test func aFilmDrawsABodysFacesInTheOrderTheDesignDoes() throws {
        var doc = design(cardAndButton)
        let ids = doc.nodes[0].children.map(\.id)
        doc.poseInDepth(.swing, of: ids, at: 1) { _ in 40 }
        let board = doc.nodes[0]
        let pieces = board.filmPieces()
        func names(at t: Double) -> [String] {
            let camera = board.camera(at: t)
            let placements = pieces.map { board.placement(of: $0, at: t, camera: camera) }
            return board.filmOrder(pieces, placements).compactMap { i in
                pieces[i].kind == .layer ? pieces[i].layers.first.flatMap { board.descendant($0)?.name } : nil
            }
        }
        // Swung as one body, the button's middle stands lower than its card's, and it is still drawn over it.
        let card = try #require(board.children.first { $0.name == "Card" }), button = try #require(board.children.first { $0.name == "Button" })
        #expect(button.pose(at: 1).lift + 20 < card.pose(at: 1).lift)
        #expect(names(at: 1) == ["Card", "Button"])
        #expect(names(at: 0) == ["Card", "Button"])
    }

    // MARK: On the canvas

    @Test func justOutsideASideADragTurnsSeveralAsOneBodyInOneStep() throws {
        // On artboard A at 100, 100: the card from 200, 200 to 400, 300 on the canvas.
        let bench = Bench(extra: cardAndButton)
        let ids = bench.a.children.map(\.id)
        let before = bench.store.doc
        bench.store.selection = ids
        bench.drag(CGPoint(x: 412, y: 250), CGPoint(x: 452, y: 250))
        let c = try #require(bench.node("Card")), b = try #require(bench.node("Button"))
        let t = try #require(c.transform3D)
        #expect(t.y > 15 && t.x == 0, "\(t)")
        #expect(b.transform3D?.x == 0 && b.transform3D?.y == t.y)
        // As the model turns a body to there, from where it stood when the drag began.
        var expected = before
        expected.turnInDepth(ids) { _, _ in Transform3D(y: t.y) }
        #expect(bench.store.doc.nodes[0].children == expected.nodes[0].children)
        #expect(b.frame.origin != CGPoint(x: 240, y: 140))
        #expect(bench.store.selection == ids)
        #expect(bench.undo.undoActionName == "Turn in Depth")
        bench.undo.undo()
        #expect(bench.store.doc == before)
        #expect(!bench.undo.canUndo)
    }

    @Test func theCardTurnsLiftsLaysFlatAndTakesABodyOutOfDepth() throws {
        let bench = Bench(extra: cardAndButton)
        let ids = bench.a.children.map(\.id)
        bench.store.selection = ids
        // Read by its lead, the card.
        #expect(bench.store.depthLead(of: bench.store.selectedNodes)?.name == "Card")
        #expect(bench.store.depthLead(of: [bench.node("Card")!]) == nil)
        bench.step {
            bench.store.turnSelection("Turn in Depth") { t in
                var t = t
                t.y = 30
                return t
            }
        }
        #expect(bench.node("Card")?.transform3D?.y == 30 && bench.node("Button")?.transform3D?.y == 30)
        #expect(bench.node("Button")?.frame.origin != CGPoint(x: 240, y: 140))
        #expect(bench.undo.undoActionName == "Turn in Depth")
        // Z lifts the whole body, by as much as its lead goes.
        let low = try #require(bench.node("Card")?.transform3D?.z), high = try #require(bench.node("Button")?.transform3D?.z)
        bench.step {
            bench.store.turnSelection("Turn in Depth") { t in
                var t = t
                t.z = 50
                return t
            }
        }
        #expect(bench.node("Card")?.transform3D?.z == 50)
        #expect(abs((bench.node("Button")?.transform3D?.z ?? 0) - (high + 50 - low)) < 1e-6)
        // A drag of the dial or the pad turns it from where it stood when the drag began.
        bench.step {
            bench.store.beginGesture()
            for y in [10.0, -20, 45, 30] {
                bench.store.turnSelection("Turn in Depth") { t in
                    var t = t
                    t.y = y
                    return t
                }
            }
            bench.store.endGesture("Turn in Depth")
        }
        #expect(bench.node("Card")?.transform3D?.z == 50 && abs((bench.node("Button")?.transform3D?.z ?? 0) - (high + 50 - low)) < 1e-6)
        bench.step { bench.store.layFlat() }
        #expect(bench.undo.undoActionName == "Lay Flat")
        #expect(bench.node("Card")?.frame == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(bench.node("Button")?.frame == CGRect(x: 240, y: 140, width: 40, height: 20))
        // Flat, the card lies under the middle it went round, as far as it did before: the
        // body is as much higher as it was lifted.
        let lifted = 50 - low
        #expect(bench.node("Card")?.transform3D?.x == 0 && bench.node("Card")?.transform3D?.y == 0)
        #expect(abs((bench.node("Card")?.transform3D?.z ?? 0) - lifted) < 1e-6 && abs((bench.node("Button")?.transform3D?.z ?? 0) - (20 + lifted)) < 1e-6)
        // Taken out of 3D while turned, it lies as it lay before it was turned.
        bench.undo.undo()
        #expect(bench.node("Button")?.transform3D?.y == 30)
        bench.step { bench.store.removeDepth() }
        #expect(bench.undo.undoActionName == "Remove 3D")
        #expect(bench.node("Card")?.transform3D == nil && bench.node("Button")?.transform3D == nil)
        #expect(bench.node("Button")?.frame == CGRect(x: 240, y: 140, width: 40, height: 20))
    }

    // MARK: In a film

    @Test func inAFilmSeveralLayersAreSwungAsOneBodyWithTheKeysThatPutThemThere() throws {
        let film = FilmBench()
        film.fresh()
        let design = film.design
        let ids = [film.id("Card"), film.id("Badge")]
        film.store.selection = ids
        film.step { film.store.seek(1) }
        film.step { film.store.pose(.swing, number: 0, to: 40, of: film.store.posedLayers) }
        #expect(film.undo.undoActionName == MotionProperty.swing.title)
        // Animate keeps changes from the design, never the design.
        #expect(film.design == design)
        // At the playhead both stand where the design's body turned so would stand.
        var expected = film.store.doc
        expected.turnInDepth(ids) { _, _ in Transform3D(y: 40) }
        for name in ["Card", "Badge"] {
            let posed = film.node(name).posed(at: 1), want = expected.allNodes.first { $0.name == name }!
            #expect(hypot(posed.frame.midX - want.frame.midX, posed.frame.midY - want.frame.midY) < 1e-6, "\(name): \(posed.frame) against \(want.frame)")
            #expect(abs((posed.transform3D?.z ?? 0) - (want.transform3D?.z ?? 0)) < 1e-6)
            #expect(posed.transform3D?.y == 40 && posed.transform3D?.x == 0)
            // Swung, moved and lifted there, and nothing else keyed.
            #expect(film.value(name, .swing) == [40])
            #expect(!film.keys(name, .move).isEmpty && !film.keys(name, .lift).isEmpty)
            #expect(film.keys(name, .tilt).isEmpty && film.keys(name, .turn).isEmpty && film.keys(name, .scale).isEmpty)
        }
        // One step undoes all of it.
        film.undo.undo()
        #expect(film.keys("Card", .swing).isEmpty && film.keys("Badge", .move).isEmpty)
        // One layer alone is tipped about its own middle, as it always was.
        film.step { film.store.pose(.tilt, number: 0, to: 20, of: [ids[0]]) }
        #expect(film.value("Card", .tilt) == [20] && film.keys("Card", .move).isEmpty && film.keys("Card", .lift).isEmpty)
    }

    // MARK: The AI server

    @Test func theAIServerTurnsLayersAsOneBodyInTheDesignOrItsFilm() async throws {
        let bench = Bench(extra: cardAndButton)
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call("turn_layers", arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let before = bench.store.doc
        let ids = bench.a.children.map(\.id)
        let turned = await call(["layers": ["Card", "Button"], "x": 10, "y": 40])
        #expect(!turned.failed, "\(turned.text)")
        var expected = before
        expected.turnInDepth(ids) { _, _ in Transform3D(x: 10, y: 40) }
        #expect(bench.store.doc.nodes[0].children == expected.nodes[0].children)
        #expect(bench.undo.undoActionName == "Turn in Depth")
        // Flat again where it lay.
        let flat = await call(["layers": ["Card", "Button"], "x": 0, "y": 0])
        #expect(!flat.failed && bench.node("Button")?.frame == CGRect(x: 240, y: 140, width: 40, height: 20))
        // In the film, with keys, the design left as it is.
        let design = bench.store.doc
        let posed = await call(["layers": ["Card", "Button"], "y": 30, "time": 1])
        #expect(!posed.failed, "\(posed.text)")
        let button = try #require(bench.node("Button"))
        #expect(button.frame == design.allNodes.first { $0.name == "Button" }?.frame && button.transform3D == Transform3D(z: 20))
        #expect(button.value(of: .swing, at: 1) == [30] && button[track: .move] != nil && button[track: .lift] != nil)
        // Nothing to turn, or nothing said: it says so.
        #expect(await call(["layers": ["A"], "y": 10]).failed)
        #expect(await call(["layers": ["Card"]]).failed)
    }
}
