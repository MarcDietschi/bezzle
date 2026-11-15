import Testing
import AppKit
@testable import Bezzle

/// Groups that keep their layers' depth (`Node.keepsDepth`, CSS's `preserve-3d`): what such a
/// group holds stands in the artboard's scene layer by layer, where the group's turn and height
/// put it, nearer over further across the group's border; everything that asks where a layer
/// shows is true to that; a group not told so is the one card it always was; and the flag is
/// one more key in the file, which a Bezzle that does not know it reads as a card.
@MainActor
struct DepthKeepTests {
    /// A 400 by 300 artboard, seen from 800 points in front of its middle.
    private let size = CGSize(width: 400, height: 300)
    private let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)

    private func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), color: RGBA = .white) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.color = color
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    private func group(_ name: String, _ frame: CGRect, _ children: [Node], z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), keeps: Bool = true) -> Node {
        var g = Node(kind: .group, name: name, frame: frame)
        g.children = children
        if z != 0 || turn.x != 0 || turn.y != 0 { g.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        if keeps { g.keepsDepth = true }
        return g
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

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    private func picture(_ doc: BezzleDocument) throws -> CGImage {
        try #require(Renderer.tile(of: doc.nodes[0], rect: CGRect(origin: .zero, size: size), scale: 1, options: Renderer.Options()))
    }

    /// Where a place in the artboard's scene shows, seen from its eye.
    private func seen(_ p: ScenePoint) -> CGPoint {
        let k = 800 / (800 - p.z)
        return CGPoint(x: 200 + (p.x - 200) * k, y: 150 + (p.y - 150) * k)
    }

    /// Where a point of a layer's parent stands in the scene of what holds that parent, the
    /// layer turned about its middle and lifted: worked out by hand, one step for each layer.
    private func stood(_ p: ScenePoint, in layer: Node) -> ScenePoint {
        let t = layer.transform3D ?? Transform3D()
        let middle = ScenePoint(x: Double(layer.frame.midX), y: Double(layer.frame.midY))
        return Spin(t)(p - middle) + middle + ScenePoint(z: Double(t.z))
    }

    /// The same for a point given inside a group: in what holds the group.
    private func out(_ p: ScenePoint, of group: Node) -> ScenePoint {
        stood(p + ScenePoint(x: Double(group.frame.minX), y: Double(group.frame.minY)), in: group)
    }

    private func corners(_ n: Node) -> [CGPoint] { Geometry.corners(of: n.frame, rotation: n.rotation) }
    private func flat(_ p: CGPoint) -> ScenePoint { ScenePoint(x: Double(p.x), y: Double(p.y)) }
    private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) < tolerance }

    /// A group swung and lifted, holding a card lying in it, one standing off it tipped, and a
    /// group tipped again that holds a card of its own off its plane.
    private func turned(keeps: Bool = true) -> BezzleDocument {
        let deep = group("Inner", CGRect(x: 10, y: 20, width: 100, height: 60),
                         [card("Deep", CGRect(x: 5, y: 5, width: 30, height: 20), z: 15)], z: 10, turn: (25, 0), keeps: keeps)
        return design([group("Group", CGRect(x: 100, y: 50, width: 200, height: 100), [
            card("Lying", CGRect(x: 100, y: 30, width: 80, height: 50), color: red),
            card("Standing", CGRect(x: 20, y: 10, width: 60, height: 40), z: 50, turn: (20, 0), color: blue),
            deep,
        ], z: 30, turn: (0, 40), keeps: keeps)])
    }

    // MARK: Where a layer shows

    @Test func aLayerInAGroupThatKeepsDepthShowsWhereItStandsInTheScene() throws {
        let doc = turned()
        let g = node(doc, "Group"), inner = node(doc, "Inner")
        let standing = node(doc, "Standing"), lying = node(doc, "Lying"), deep = node(doc, "Deep")
        // Standing off the group: turned and lifted in the group, then with the group.
        let eye = try #require(doc.eye(forParentOf: standing.id))
        let perspective = try #require(Perspective(standing, eye: eye))
        let onCanvas = try #require(Perspective.onCanvas(standing, eye: eye))
        for p in corners(standing) {
            let truth = seen(out(stood(flat(p), in: standing), of: g))
            // As everything asks: a point lying in the group that shows there, carried on by the group.
            #expect(near(doc.shown(perspective.shown(p), inParentOf: standing.id), truth))
            // As what draws asks: where it shows itself, measured from where the group begins.
            #expect(near(onCanvas.shown(p) + g.frame.origin, truth))
            // And the way back, from the canvas to the layer.
            let back = try #require(doc.placed(truth, inParentOf: standing.id).flatMap { perspective.flat($0) })
            #expect(near(back, p, 1e-5))
        }
        // Lying in the group, it is where the group as a card shows it, and needs no perspective of its own.
        #expect(Perspective(lying, eye: doc.eye(forParentOf: lying.id)) == nil)
        for p in corners(lying) {
            #expect(near(doc.shown(p, inParentOf: lying.id), seen(out(flat(p), of: g))))
        }
        // A group keeping depth inside another passes the scene on again.
        let deepEye = try #require(doc.eye(forParentOf: deep.id))
        let deepPerspective = try #require(Perspective(deep, eye: deepEye))
        for p in corners(deep) {
            let truth = seen(out(out(stood(flat(p), in: deep), of: inner), of: g))
            #expect(near(doc.shown(deepPerspective.shown(p), inParentOf: deep.id), truth))
        }
        // As one card, the standing layer is drawn onto the group lying flat, which is then turned: somewhere else.
        let card = turned(keeps: false)
        let was = node(card, "Standing")
        let onCard = try #require(Perspective(was, eye: card.eye(forParentOf: was.id)))
        let p = corners(was)[0]
        #expect(!near(card.shown(onCard.shown(p), inParentOf: was.id), seen(out(stood(flat(p), in: was), of: g)), 1))
    }

    @Test func boundsHitsAndWhatIsPaintedFollowTheLayersStanding() throws {
        let doc = turned()
        let stage = doc.nodes[0], g = node(doc, "Group"), inner = node(doc, "Inner")
        let standing = node(doc, "Standing"), lying = node(doc, "Lying"), deep = node(doc, "Deep")
        let eye = doc.stage(of: stage)
        var all = corners(standing).map { seen(out(stood(flat($0), in: standing), of: g)) }
        all += corners(lying).map { seen(out(flat($0), of: g)) }
        all += corners(deep).map { seen(out(out(stood(flat($0), in: deep), of: inner), of: g)) }
        let xs = all.map(\.x), ys = all.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // The group is as big as its layers show, not as its card would.
        let bounds = Geometry.bounds(of: g, eye: eye)
        #expect(abs(bounds.minX - box.minX) < 1e-6 && abs(bounds.maxX - box.maxX) < 1e-6)
        #expect(abs(bounds.minY - box.minY) < 1e-6 && abs(bounds.maxY - box.maxY) < 1e-6)
        #expect(Renderer.reach(of: g, eye: eye).insetBy(dx: 0.001, dy: 0.001).contains(box))
        // A click on a layer standing off the group takes the group; in the group, the layer.
        let middle = seen(out(stood(flat(standing.frame.center), in: standing), of: g))
        #expect(Picking(doc: doc).hit(middle) == g.id)
        #expect(Picking(doc: doc, selection: [lying.id]).pick(middle) == standing.id)
        let deepMiddle = seen(out(out(stood(flat(deep.frame.center), in: deep), of: inner), of: g))
        #expect(Picking(doc: doc).hit(deepMiddle) == g.id)
        #expect(Picking(doc: doc, selection: [lying.id]).pick(deepMiddle) == inner.id)
        // Where the card would be and no layer shows, there is nothing to take.
        let empty = seen(out(ScenePoint(x: 195, y: 95), of: g))
        #expect(Picking(doc: doc).hit(empty) == nil)
        #expect(Picking(doc: doc).marquee(CGRect(x: middle.x - 1, y: middle.y - 1, width: 2, height: 2), inside: stage.id) == [g.id])
        // It is drawn there: blue at the standing layer's middle, red at the lying one's.
        let image = try picture(doc)
        #expect(pixel(image, Int(middle.x), Int(middle.y)).blueComponent > 0.95)
        let lyingMiddle = seen(out(flat(lying.frame.center), of: g))
        #expect(pixel(image, Int(lyingMiddle.x), Int(lyingMiddle.y)).redComponent > 0.95)
    }

    // MARK: Nearer over further across the group's border

    /// A red card 40 off the page, listed under a group that lies in the page and holds a white
    /// card in it and a blue one 80 off it, all over one another.
    private func crossing(keeps: Bool) -> BezzleDocument {
        design([card("Beside", CGRect(x: 150, y: 100, width: 100, height: 100), z: 40, color: red),
                group("Group", CGRect(x: 100, y: 50, width: 200, height: 200), [
                    card("Low", CGRect(x: 60, y: 60, width: 80, height: 80)),
                    card("High", CGRect(x: 70, y: 70, width: 40, height: 40), z: 80, color: blue),
                ], keeps: keeps)])
    }

    @Test func layersOfAGroupThatKeepsDepthStandAmongWhatLiesBesideIt() throws {
        let doc = crossing(keeps: true), card = crossing(keeps: false)
        let stage = doc.nodes[0], g = node(doc, "Group"), beside = node(doc, "Beside")
        // The low layer under the card beside the group, the high one over it.
        let scene = DepthOrder.scene(stage.children, eye: doc.stage(of: stage))
        #expect(scene.map(\.node.name) == ["Low", "Beside", "High"])
        #expect(scene.map(\.top) == [1, 0, 1] && scene[2].groups == [g.id] && scene[2].origin == g.frame.origin)
        // As one card the group lies in the page, all of it under the card beside it.
        #expect(DepthOrder.scene(card.nodes[0].children, eye: card.stage(of: card.nodes[0])).map(\.node.name) == ["Group", "Beside"])
        // So it is drawn,
        let image = try picture(doc), before = try picture(card)
        #expect(pixel(image, 190, 140).blueComponent > 0.95 && pixel(image, 190, 140).redComponent < 0.05)
        #expect(pixel(before, 190, 140).redComponent > 0.95 && pixel(before, 190, 140).blueComponent < 0.05)
        #expect(pixel(image, 230, 180).redComponent > 0.95 && pixel(image, 230, 180).blueComponent < 0.05)
        // and so a click meets it.
        #expect(Picking(doc: doc).hit(CGPoint(x: 190, y: 140)) == g.id)
        #expect(Picking(doc: card).hit(CGPoint(x: 190, y: 140)) == node(card, "Beside").id)
        #expect(Picking(doc: doc).hit(CGPoint(x: 230, y: 180)) == beside.id)
        #expect(Picking(doc: doc).hit(CGPoint(x: 105, y: 55)) == nil)
        // Inside the group, a click takes the layer on top there, and outside it what covers the group.
        let inside = Picking(doc: doc, selection: [node(doc, "Low").id])
        #expect(inside.pick(CGPoint(x: 190, y: 140)) == node(doc, "High").id)
        #expect(inside.pick(CGPoint(x: 230, y: 180)) == beside.id)
        // A locked group lets the click through to what lies under its layers.
        var locked = doc
        locked.nodes[0].children[1].locked = true
        #expect(Picking(doc: locked).hit(CGPoint(x: 190, y: 140)) == beside.id)
    }

    // MARK: Looked at from the side

    @Test func lookedAtFromTheSideEachLayerOfAGroupThatKeepsDepthStandsOnPostsDownToThePage() throws {
        var doc = turned()
        let stage = doc.nodes[0], g = node(doc, "Group"), inner = node(doc, "Inner")
        let standing = node(doc, "Standing"), lying = node(doc, "Lying"), deep = node(doc, "Deep")
        // From 45° to the right, which the group's plane, swung 40° that way, nearly faces.
        doc.looks = [stage.id: DepthLook(across: 45)]
        // Each corner of each layer where it stands in the scene, worked out by hand.
        let lyingCorners = corners(lying).map { out(flat($0), of: g) }
        let standingCorners = corners(standing).map { out(stood(flat($0), in: standing), of: g) }
        let deepCorners = corners(deep).map { out(out(stood(flat($0), in: deep), of: inner), of: g) }
        // The eye 800 to the right of the artboard's middle, as high.
        func top(_ p: ScenePoint) -> CGPoint {
            let k = 800 / (800 - p.z)
            return CGPoint(x: 1000 + (p.x - 1000) * k, y: 150 + (p.y - 150) * k)
        }
        func matches(_ posts: [DepthPost], _ corners: [ScenePoint]) -> Bool {
            posts.count == corners.count && corners.allSatisfy { c in
                posts.contains { near($0.foot, CGPoint(x: c.x, y: c.y), 1e-5) && near($0.top, top(c), 1e-5) }
            }
        }
        // A post under each corner of each layer the group holds, straight down to the page, which
        // every height is measured from; none under the group, which has no card of its own.
        let posts = doc.posts(of: stage)
        #expect(matches(posts, lyingCorners + standingCorners + deepCorners), "\(posts.map(\.foot))")
        #expect(!posts.contains { near($0.foot, g.frame.origin, 1e-3) })
        // The layers lying in the group's plane stand off the page as the group does, above it
        // or, where the group is swung away, below it.
        #expect(lyingCorners.allSatisfy { abs($0.z) > 1 } && lyingCorners.contains { $0.z < 0 })
        // A layer picked, or the group inside, has its own; the group picked, all of them.
        #expect(matches(doc.posts(of: stage, picked: [standing.id]), standingCorners))
        #expect(matches(doc.posts(of: stage, picked: [inner.id]), deepCorners))
        #expect(doc.posts(of: stage, picked: [g.id]) == posts)
        // As one card, the group stands on the four posts under its own corners.
        var card = turned(keeps: false)
        card.looks = [card.nodes[0].id: DepthLook(across: 45)]
        let cardCorners = corners(g).map { out(flat($0 - g.frame.origin), of: g) }
        #expect(matches(card.posts(of: card.nodes[0]), cardCorners))
        // On the canvas, the layer standing off the group is where its posts end.
        let drawn = try #require(Renderer.tile(of: stage, rect: CGRect(origin: .zero, size: size), scale: 1, options: {
            var o = Renderer.Options()
            o.looks = doc.looks
            return o
        }()))
        let middle = top(out(stood(flat(standing.frame.center), in: standing), of: g))
        #expect(pixel(drawn, Int(middle.x), Int(middle.y)).blueComponent > 0.95, "\(middle)")
    }

    // MARK: The prototype

    @Test func aTapInThePlayerReachesWhatIsDrawnNearestAcrossTheGroupsBorder() throws {
        let doc = crossing(keeps: true), card = crossing(keeps: false)
        func names(_ doc: BezzleDocument, _ p: CGPoint) -> [String] { Prototype.chain(at: p, in: doc.nodes[0]).map(\.name) }
        // Where the high layer in the group shows over the card beside it, the tap is the high
        // layer's, then its group's; where the card beside is nearer, the card's.
        #expect(names(doc, CGPoint(x: 190, y: 140)) == ["High", "Group"])
        #expect(names(doc, CGPoint(x: 230, y: 180)) == ["Beside"])
        #expect(names(doc, CGPoint(x: 105, y: 55)).isEmpty)
        // As one card, the group lies in the page, under the card beside it.
        #expect(names(card, CGPoint(x: 190, y: 140)) == ["Beside"])
        // In a group turned and held up, each layer where it stands, the group inside too.
        let turned = turned()
        let g = node(turned, "Group"), inner = node(turned, "Inner")
        let standing = node(turned, "Standing"), lying = node(turned, "Lying"), deep = node(turned, "Deep")
        #expect(names(turned, seen(out(stood(flat(standing.frame.center), in: standing), of: g))) == ["Standing", "Group"])
        #expect(names(turned, seen(out(flat(lying.frame.center), of: g))) == ["Lying", "Group"])
        #expect(names(turned, seen(out(out(stood(flat(deep.frame.center), in: deep), of: inner), of: g))) == ["Deep", "Inner", "Group"])
        // The player follows the flow of what it reaches.
        var linked = doc
        linked.update(node(doc, "High").id) { $0.flow = FlowLink(to: UUID()) }
        #expect(Prototype.chain(at: CGPoint(x: 190, y: 140), in: linked.nodes[0]).first { $0.flow != nil }?.name == "High")
    }

    // MARK: The film

    @Test func theFilmAtRestShowsEachLayerWhereTheDesignDoes() throws {
        let doc = turned()
        let stage = doc.nodes[0], g = node(doc, "Group"), inner = node(doc, "Inner")
        let standing = node(doc, "Standing"), lying = node(doc, "Lying"), deep = node(doc, "Deep")
        // The group comes apart into the scene: what lies in it one piece, what stands off it pieces of their own.
        let pieces = stage.filmPieces()
        #expect(pieces.map(\.layers) == [[], [lying.id], [standing.id], [deep.id]])
        #expect(pieces.dropFirst().allSatisfy { $0.stand != nil } && pieces[3].holders == [g.id, inner.id])
        let placements = pieces.map { stage.placement(of: $0, at: 0, camera: stage.camera(at: 0)) }
        func shown(_ piece: Int, _ p: CGPoint) -> CGPoint { placements[piece].map(p + pieces[piece].origin) }
        // Each drawn lying flat where its frame says, and stood by the film where the design shows it.
        for p in corners(lying) { #expect(near(shown(1, p), seen(out(flat(p), of: g)), 1e-5)) }
        for p in corners(standing) { #expect(near(shown(2, p), seen(out(stood(flat(p), in: standing), of: g)), 1e-5)) }
        for p in corners(deep) { #expect(near(shown(3, p), seen(out(out(stood(flat(p), in: deep), of: inner), of: g)), 1e-5)) }
        // Across the group's border the film orders as the design does.
        let crossed = crossing(keeps: true).nodes[0]
        let parts = crossed.filmPieces()
        let places = parts.map { crossed.placement(of: $0, at: 0, camera: crossed.camera(at: 0)) }
        let names = crossed.filmOrder(parts, places).map { i in parts[i].layers.first.flatMap { crossed.descendant($0)?.name } ?? "Ground" }
        #expect(names == ["Ground", "Low", "Beside", "High"])
        // A group as one card is one piece, as it was.
        let card = turned(keeps: false).nodes[0]
        #expect(card.filmPieces().map(\.layers) == [[], [card.children[0].id]] && card.filmPieces()[1].stand == nil)
    }

    // MARK: Telling a group

    @Test func theAIServerTellsAGroupToKeepDepthInOneUndoStep() async throws {
        let bench = Bench(extra: crossing(keeps: false).nodes[0].children)
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func update(_ layer: String, _ keeps: Bool) async -> String {
            let r = await tools.call("update_layers", ["design": bench.store.name, "updates": [["layer": layer, "keepsDepth": keeps]]])
            return String(decoding: r.data, as: UTF8.self)
        }
        // Where the blue layer shows over the card beside its group, on the bench's artboard at 100, 100.
        let over = CGPoint(x: 290, y: 240)
        #expect(Picking(doc: bench.store.doc).hit(over) == bench.node("Beside")?.id)
        let told = await update("Group", true)
        #expect(!told.contains("\"isError\":true"), "\(told)")
        #expect(bench.node("Group")?.keepsDepth == true && bench.node("Group")?.opensInDepth == true)
        #expect(Picking(doc: bench.store.doc).hit(over) == bench.node("Group")?.id)
        bench.undo.undo()
        #expect(bench.node("Group")?.keepsDepth == nil)
        #expect(Picking(doc: bench.store.doc).hit(over) == bench.node("Beside")?.id)
        // false makes it one card again, with no key left; and only a group can be told.
        _ = await update("Group", true)
        _ = await update("Group", false)
        #expect(bench.node("Group")?.keepsDepth == nil)
        let leaf = await update("Beside", true)
        #expect(leaf.contains("Only a group") && bench.node("Beside")?.keepsDepth == nil)
    }

    // MARK: A card as before

    @Test func aGroupNotToldSoOrDoneSomethingToAsAWholeIsTheCardItWas() throws {
        // Lying flat with flat layers, keeping depth changes nothing, to the last pixel.
        func lying(keeps: Bool) -> BezzleDocument {
            design([card("Beside", CGRect(x: 150, y: 100, width: 100, height: 100), color: red),
                    group("Group", CGRect(x: 100, y: 50, width: 200, height: 200), [
                        card("Low", CGRect(x: 60, y: 60, width: 80, height: 80)),
                        card("High", CGRect(x: 70, y: 70, width: 40, height: 40), color: blue),
                    ], keeps: keeps)])
        }
        #expect(try picture(lying(keeps: true)).dataProvider?.data as Data? == picture(lying(keeps: false)).dataProvider?.data as Data?)
        // A shadow, a fade, a blur, a blend or a mask is done to the group as a whole: one card, as CSS has it.
        var shadowed = turned()
        shadowed.nodes[0].children[0].shadow.on = true
        var plain = shadowed
        plain.nodes[0].children[0].keepsDepth = nil
        #expect(!shadowed.nodes[0].children[0].opensInDepth)
        #expect(try picture(shadowed).dataProvider?.data as Data? == picture(plain).dataProvider?.data as Data?)
        var faded = turned().nodes[0].children[0]
        #expect(faded.opensInDepth)
        faded.opacity = 0.5
        #expect(!faded.opensInDepth)
        var masked = turned().nodes[0].children[0]
        masked.clipsToFirst = true
        #expect(!masked.opensInDepth)
        var pinned = turned().nodes[0].children[0]
        pinned.transform3D?.corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.1), CGPoint(x: 1, y: 0.9), CGPoint(x: 0, y: 1)]
        #expect(!pinned.opensInDepth)
        // Only groups keep depth, and off any artboard there is no scene: a card.
        var leaf = card("Leaf", CGRect(x: 0, y: 0, width: 10, height: 10))
        leaf.keepsDepth = true
        #expect(!leaf.opensInDepth)
        let g = turned().nodes[0].children[0]
        #expect(DepthOrder.scene([g], eye: nil).map(\.node.id) == [g.id])
        var off = BezzleDocument(), offCard = BezzleDocument()
        off.nodes = [g]
        offCard.nodes = [turned(keeps: false).nodes[0].children[0]]
        #expect(Geometry.bounds(of: off.nodes[0]) == Geometry.bounds(of: offCard.nodes[0]))
        // A group as a card inside one that keeps depth is still a card: what it holds does not open.
        let cardInside = group("Card", CGRect(x: 10, y: 10, width: 50, height: 50), [card("Held", CGRect(x: 0, y: 0, width: 50, height: 50), z: 20)], keeps: false)
        let holder = group("Holder", CGRect(x: 100, y: 50, width: 200, height: 100), [cardInside], turn: (0, 30))
        let scene = DepthOrder.scene([holder], eye: Eye.stage(size))
        #expect(scene.map(\.node.name) == ["Card"])
        #expect(Eye.stage(size).within(holder).space != nil && Eye.stage(size).within(holder).within(cardInside).space == nil)
    }

    // MARK: The file

    @Test func theFlagIsOneMoreKeyThatAnOlderBezzleReadsAsACard() throws {
        let doc = turned()
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(BezzleDocument.self, from: data)
        #expect(back == doc && node(back, "Group").keepsDepth == true && node(back, "Inner").keepsDepth == true)
        // Shared with others, it is one more property of the group, sent and merged on its own.
        let shared = FlatDesign(doc).document()
        #expect(node(shared, "Group").keepsDepth == true && node(shared, "Inner").keepsDepth == true && node(shared, "Lying").keepsDepth == nil)
        #expect(LayerField.all.contains { $0.name == "keepsDepth" })
        // A group not told to keep depth is written as it always was: no key at all.
        func cleared(_ n: Node) -> Node {
            var n = n
            n.keepsDepth = nil
            n.children = n.children.map(cleared)
            return n
        }
        var card = doc
        card.nodes = doc.nodes.map(cleared)
        let written = try #require(String(data: JSONEncoder().encode(card), encoding: .utf8))
        #expect(!written.contains("keepsDepth"))
        // The key is all that is new: without it, as a Bezzle that does not know it reads the
        // file, the design is the same group as one card.
        func stripped(_ value: Any) -> Any {
            if let d = value as? [String: Any] { return d.filter { $0.key != "keepsDepth" }.mapValues(stripped) }
            if let a = value as? [Any] { return a.map(stripped) }
            return value
        }
        let older = try JSONSerialization.data(withJSONObject: stripped(JSONSerialization.jsonObject(with: data)))
        #expect(try JSONDecoder().decode(BezzleDocument.self, from: older) == card)
    }
}
