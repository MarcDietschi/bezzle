import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// Designs laid out again when their artboard takes a new size: what is understood of them, that
/// the same size gives the same design back, and that what they hold keeps its sense at others.
@MainActor
struct AdaptTests {
    // MARK: Designs to try it on

    static func text(_ words: String, _ size: CGFloat, face: String = "Regular", at p: CGPoint, width: CGFloat? = nil,
                     align: TextAlign = .left, color: RGBA = RGBA(r: 0.1, g: 0.1, b: 0.12)) -> Node {
        var n = Node(kind: .text, name: words, frame: CGRect(origin: p, size: CGSize(width: width ?? 10, height: 10)))
        n.text = words
        n.style = TextStyle(face: face, size: size, align: align, sizing: width == nil ? .autoWidth : .autoHeight)
        n.fill.color = color
        n.refit()
        if width == nil, align == .center { n.frame.origin.x = p.x - n.frame.width / 2 }
        return n
    }

    static func rect(_ r: CGRect, _ color: RGBA, radius: CGFloat = 0, name: String = "Rectangle") -> Node {
        var n = Node(kind: .rectangle, name: name, frame: r)
        n.fill.color = color
        n.cornerRadius = radius
        return n
    }

    static func photo(_ r: CGRect, radius: CGFloat = 0) -> Node {
        var n = rect(r, .shape, radius: radius, name: "Photo")
        n.fill.image = ImageFill(asset: "lake.jpg", mode: .cover, size: WelcomePhoto.size)
        return n
    }

    static func board(_ size: CGSize, _ children: [Node], color: RGBA = .white) -> Node {
        var b = Node(kind: .artboard, name: "Board", frame: CGRect(origin: CGPoint(x: 100, y: 100), size: size))
        b.fill.color = color
        b.children = children
        return b
    }

    static let ink = RGBA(r: 0.09, g: 0.09, b: 0.11)
    static let accent = RGBA(r: 0.93, g: 0.36, b: 0.24)

    /// A post: a photo across its top, a heading and a line under it, a button, a small mark.
    static func photoPost() -> Node {
        let w: CGFloat = 1080, h: CGFloat = 1350
        return board(CGSize(width: w, height: h), [
            photo(CGRect(x: 0, y: 0, width: w, height: 760)),
            text("Lakeside weekends", 92, face: "Bold", at: CGPoint(x: 80, y: 830), width: 920, color: ink),
            text("Slow mornings, cold water, long light.", 40, at: CGPoint(x: 80, y: 960), width: 920, color: ink.with(alpha: 0.7)),
            rect(CGRect(x: 80, y: 1120, width: 300, height: 96), accent, radius: 48, name: "Button"),
            text("Book now", 36, face: "Semibold", at: CGPoint(x: 230, y: 1146), align: .center, color: .white),
            text("LAKE & CO", 28, face: "Bold", at: CGPoint(x: 850, y: 1155), color: ink),
        ])
    }

    /// A post centred on a coloured ground, a circle bleeding off its corner.
    static func centredPost() -> Node {
        let w: CGFloat = 1080, h: CGFloat = 1080
        var circle = Node(kind: .ellipse, name: "Circle", frame: CGRect(x: 760, y: -180, width: 520, height: 520))
        circle.fill.color = RGBA(r: 1, g: 0.85, b: 0.4)
        var ground = rect(CGRect(x: 0, y: 0, width: w, height: h), RGBA(r: 0.16, g: 0.2, b: 0.45), name: "Ground")
        ground.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.2, g: 0.25, b: 0.55)),
                                                               GradientStop(offset: 1, color: RGBA(r: 0.1, g: 0.12, b: 0.3))],
                                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        return board(CGSize(width: w, height: h), [
            ground,
            circle,
            text("SUMMER", 40, face: "Bold", at: CGPoint(x: 540, y: 330), align: .center, color: RGBA(r: 1, g: 0.85, b: 0.4)),
            text("Sale", 220, face: "Black", at: CGPoint(x: 540, y: 390), align: .center, color: .white),
            text("Up to 50% off everything", 44, at: CGPoint(x: 540, y: 660), align: .center, color: .white.with(alpha: 0.8)),
            rect(CGRect(x: 390, y: 770, width: 300, height: 90), .white, radius: 45, name: "Button"),
            text("Shop now", 34, face: "Semibold", at: CGPoint(x: 540, y: 794), align: .center, color: ink),
        ])
    }

    /// A phone screen: a bar at the top, cards down it, a tab bar at its foot.
    static func phoneScreen() -> Node {
        let w: CGFloat = 402, h: CGFloat = 874
        var kids: [Node] = [
            rect(CGRect(x: 0, y: 0, width: w, height: 110), RGBA(r: 0.97, g: 0.97, b: 0.98), name: "Bar"),
            text("9:41", 16, face: "Semibold", at: CGPoint(x: 32, y: 18), color: ink),
            text("Trips", 32, face: "Bold", at: CGPoint(x: 20, y: 60), color: ink),
        ]
        for i in 0..<3 {
            let y = CGFloat(130 + i * 196)
            kids.append(rect(CGRect(x: 20, y: y, width: 362, height: 180), RGBA(r: 0.95, g: 0.95, b: 0.96), radius: 18, name: "Card"))
            kids.append(photo(CGRect(x: 32, y: y + 12, width: 120, height: 156), radius: 12))
            kids.append(text(["Lake Como", "Dolomites", "Lucerne"][i], 20, face: "Semibold", at: CGPoint(x: 168, y: y + 24), color: ink))
            kids.append(text("Three nights by the water, with boats and long dinners.", 15, at: CGPoint(x: 168, y: y + 56), width: 196, color: ink.with(alpha: 0.6)))
        }
        kids.append(rect(CGRect(x: 0, y: h - 84, width: w, height: 84), .white, name: "Tab bar"))
        for i in 0..<4 {
            var dot = Node(kind: .ellipse, name: "Tab", frame: CGRect(x: 48 + CGFloat(i) * 92, y: h - 66, width: 26, height: 26))
            dot.fill.color = i == 0 ? accent : RGBA(r: 0.75, g: 0.75, b: 0.78)
            kids.append(dot)
        }
        return board(CGSize(width: w, height: h), kids)
    }

    /// A web page's top: a bar of links, a heading beside a picture, three features in a row.
    static func webHero() -> Node {
        let w: CGFloat = 1440, h: CGFloat = 1024
        var kids: [Node] = [
            text("Northwind", 26, face: "Bold", at: CGPoint(x: 80, y: 36), color: ink),
            text("Product", 18, at: CGPoint(x: 1010, y: 40), color: ink),
            text("Pricing", 18, at: CGPoint(x: 1120, y: 40), color: ink),
            text("Sign in", 18, face: "Semibold", at: CGPoint(x: 1240, y: 40), color: accent),
            text("Plan trips that feel like holidays already", 64, face: "Bold", at: CGPoint(x: 80, y: 180), width: 600, color: ink),
            text("Everything for the journey in one place, shared with everyone who comes along.", 22, at: CGPoint(x: 80, y: 420), width: 520, color: ink.with(alpha: 0.65)),
            rect(CGRect(x: 80, y: 520, width: 220, height: 60), ink, radius: 12, name: "Button"),
            text("Start free", 20, face: "Semibold", at: CGPoint(x: 190, y: 537), align: .center, color: .white),
            photo(CGRect(x: 760, y: 150, width: 600, height: 460), radius: 24),
        ]
        for i in 0..<3 {
            let x = 80 + CGFloat(i) * 440
            kids.append(rect(CGRect(x: x, y: 700, width: 400, height: 240), RGBA(r: 0.96, g: 0.95, b: 0.93), radius: 20, name: "Feature"))
            kids.append(text(["Together", "Offline", "Calm"][i], 26, face: "Bold", at: CGPoint(x: x + 32, y: 732), color: ink))
            kids.append(text("Plans, tickets and notes that everyone sees as soon as they change.", 18, at: CGPoint(x: x + 32, y: 780), width: 336, color: ink.with(alpha: 0.6)))
        }
        return board(CGSize(width: w, height: h), kids)
    }

    /// A poster spread over its height: heading at the top, a picture, a line of small print at the foot.
    static func spreadPoster() -> Node {
        let w: CGFloat = 1080, h: CGFloat = 1350
        return board(CGSize(width: w, height: h), [
            text("Mountains at dusk", 96, face: "Bold", at: CGPoint(x: 80, y: 80), width: 700, color: ink),
            photo(CGRect(x: 80, y: 420, width: 920, height: 640), radius: 8),
            text("EXHIBITION · OCTOBER", 26, face: "Semibold", at: CGPoint(x: 80, y: 1240), color: ink),
            text("ARTHOUSE", 26, face: "Bold", at: CGPoint(x: 860, y: 1240), color: ink),
        ], color: RGBA(r: 0.96, g: 0.94, b: 0.9))
    }

    static let designs: [(String, Node)] = [("photo-post", photoPost()), ("centred-post", centredPost()),
                                             ("phone", phoneScreen()), ("web", webHero()), ("poster", spreadPoster())]

    // MARK: What it keeps

    static let sizes: [CGSize] = [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 1200, height: 627),
                                  CGSize(width: 1500, height: 500), CGSize(width: 402, height: 874), CGSize(width: 1920, height: 1080),
                                  CGSize(width: 768, height: 1024), CGSize(width: 208, height: 248)]

    private func layer(_ board: Node, _ name: String) throws -> Node {
        try #require(board.children.first { $0.name == name })
    }

    @Test func theSameSizeGivesTheSameDesign() {
        for (_, design) in Self.designs {
            let r = Adapt.compose(Adapt.plan(design), to: design.frame.size)
            #expect(r.board == design)
        }
    }

    /// A pixel or two wider moves nothing far: no jump as a drag sets off.
    @Test func aLittleWiderMovesALittle() {
        for (name, design) in Self.designs {
            let plan = Adapt.plan(design)
            let r = Adapt.compose(plan, to: CGSize(width: design.frame.width + 2, height: design.frame.height))
            #expect(r.arrangement == .original, "\(name)")
            for (a, b) in zip(design.children, r.board.children) {
                #expect(abs(a.frame.minX - b.frame.minX) <= 4 && abs(a.frame.minY - b.frame.minY) <= 4, "\(name): \(a.name) moved from \(a.frame) to \(b.frame)")
            }
        }
    }

    @Test func comingBackGivesTheDesignBackExactly() {
        for (name, design) in Self.designs {
            var b = design
            b.id = UUID()
            let original = b
            for s in [CGSize(width: 1200, height: 627), CGSize(width: 600, height: 1400), original.frame.size] {
                b = Adapting.resized(b, to: s)
            }
            #expect(b.children == original.children, "\(name)")
        }
    }

    @Test func everythingStaysOnTheArtboard() {
        for (name, design) in Self.designs {
            let plan = Adapt.plan(design)
            for size in Self.sizes {
                let r = Adapt.compose(plan, to: size)
                let page = CGRect(origin: .zero, size: size).insetBy(dx: -1.5, dy: -1.5)
                for (was, n) in zip(design.children, r.board.children) {
                    let wasInside = CGRect(origin: .zero, size: design.frame.size).insetBy(dx: -1, dy: -1).contains(Geometry.bounds(of: was))
                    guard wasInside else { continue }
                    #expect(page.contains(Geometry.bounds(of: n)), "\(name) at \(size): \(n.name) \(n.frame) left the artboard")
                }
            }
        }
    }

    /// Blocks that lay apart still do: nothing is laid over something it was not on.
    @Test func nothingOverlapsThatDidNot() {
        for (name, design) in Self.designs {
            let plan = Adapt.plan(design)
            for size in Self.sizes {
                let r = Adapt.compose(plan, to: size)
                let kids = r.board.children
                for i in kids.indices {
                    for j in kids.indices where j > i {
                        let a0 = Geometry.bounds(of: design.children[i]), b0 = Geometry.bounds(of: design.children[j])
                        guard !a0.insetBy(dx: -1, dy: -1).intersects(b0) else { continue }
                        let a = Geometry.bounds(of: kids[i]).insetBy(dx: 1, dy: 1), b = Geometry.bounds(of: kids[j]).insetBy(dx: 1, dy: 1)
                        #expect(!a.intersects(b), "\(name) at \(size): \(kids[i].name) \(kids[i].frame) over \(kids[j].name) \(kids[j].frame)")
                    }
                }
            }
        }
    }

    @Test func aBackdropGoesOnCovering() throws {
        let r = Adapt.compose(Adapt.plan(Self.centredPost()), to: CGSize(width: 1600, height: 900))
        #expect(try layer(r.board, "Ground").frame == CGRect(x: 0, y: 0, width: 1600, height: 900))
        // The circle still bleeds off the top right corner.
        let circle = try layer(r.board, "Circle").frame
        #expect(circle.maxX > 1600 && circle.minY < 0)
    }

    @Test func barsRunEdgeToEdgeAndATabBarKeepsToTheFoot() throws {
        let r = Adapt.compose(Adapt.plan(Self.phoneScreen()), to: CGSize(width: 1032, height: 1376))
        let bar = try layer(r.board, "Bar").frame, tabs = try layer(r.board, "Tab bar").frame
        #expect(bar.minX == 0 && bar.maxX == 1032 && bar.minY == 0)
        // A screen's bars keep the height they read at.
        #expect(abs(bar.height - 110) <= 1 && abs(tabs.height - 84) <= 1)
        #expect(tabs.minX == 0 && tabs.maxX == 1032 && tabs.maxY == 1376)
        // Type on a screen stays the size it reads at.
        #expect(try layer(r.board, "Trips").style?.size == 32)
        // Cards widen, their words taking the room.
        let card = try #require(r.board.children.first { $0.name == "Card" })
        #expect(card.frame.width > 900)
    }

    @Test func aWideFormatPutsThePictureBesideItsWords() throws {
        let r = Adapt.compose(Adapt.plan(Self.photoPost()), to: CGSize(width: 1200, height: 627))
        let photo = try layer(r.board, "Photo").frame, heading = try layer(r.board, "Lakeside weekends").frame
        #expect(r.arrangement.turned == [])
        #expect(photo.minX == 0 && photo.minY == 0 && photo.maxY == 627)
        #expect(heading.minX >= photo.maxX)
        // And a tall one back above them.
        let back = Adapt.compose(Adapt.plan(r.board), to: CGSize(width: 1080, height: 1350))
        let p2 = try layer(back.board, "Photo").frame, h2 = try layer(back.board, "Lakeside weekends").frame
        #expect(h2.minY >= p2.maxY)
    }

    @Test func cardsInARowWrapOnANarrowScreen() throws {
        let r = Adapt.compose(Adapt.plan(Self.webHero()), to: CGSize(width: 768, height: 1024))
        let features = r.board.children.filter { $0.name == "Feature" }
        #expect(features.count == 3)
        #expect(Set(features.map { $0.frame.minX }).count == 1)
        #expect(features[0].frame.maxY <= features[1].frame.minY)
    }

    @Test func aPictureKeepsWhatItShowsWhereItWas() {
        let image = ImageFill(asset: "x", mode: .cover, size: CGSize(width: 1600, height: 1000))
        let focus = CGPoint(x: 0.7, y: 0.3)
        let r = Adapt.recropped(image, from: CGSize(width: 1600, height: 1000), to: CGSize(width: 500, height: 1000), focus: focus)
        let rect = Renderer.imageRect(r, in: CGSize(width: 500, height: 1000))
        // The point of the picture that draws the eye stays in sight, near where it was across.
        let x = rect.minX + focus.x * rect.width
        #expect(x > 0 && x < 500)
        #expect(rect.minX <= 0.001 && rect.maxX >= 499.999 && rect.minY <= 0.001 && rect.maxY >= 999.999)
    }

    @Test func aPinnedArtboardOrACarouselKeepsItsLayers() {
        var pinned = Self.photoPost()
        pinned.pinsLayers = true
        #expect(Adapting.resized(pinned, to: CGSize(width: 1200, height: 627)).children == pinned.children)
        var carousel = Self.photoPost()
        carousel.slideSize = CGSize(width: 1080, height: 1350)
        #expect(!Adapting.adapts(carousel))
    }

    @Test func resizingIsOneStepThatUndoes() {
        let bench = Bench(extra: Self.photoPost().children.map { var n = $0; n = Adapt.scaled(n, by: 300.0 / 1080); n.frame.origin = CGPoint(x: $0.frame.minX * 300 / 1080, y: $0.frame.minY * 300 / 1080); return n })
        let before = bench.store.doc
        bench.step { bench.store.resizeArtboards([bench.a.id]) { _ in CGSize(width: 600, height: 300) } }
        #expect(bench.a.frame.size == CGSize(width: 600, height: 300))
        #expect(bench.a.children != before.nodes[0].children)
        bench.undo.undo()
        #expect(bench.store.doc == before)
    }

    @Test func draggingAnArtboardsEdgeLaysItsDesignOut() throws {
        let bench = Bench(extra: [
            Self.rect(CGRect(x: 0, y: 0, width: 400, height: 60), Self.accent, name: "Top"),
            Self.text("Hello there", 24, at: CGPoint(x: 140, y: 140), align: .left),
        ])
        bench.store.selection = [bench.a.id]
        bench.drag(CGPoint(x: 500, y: 250), CGPoint(x: 800, y: 250))
        #expect(bench.a.frame.width == 700)
        let top = try #require(bench.node("Top"))
        // The bar runs across the wider artboard.
        #expect(top.frame.width == 700)
        bench.undo.undo()
        #expect(bench.a.frame.width == 400)
        #expect(bench.node("Top")?.frame.width == 400)
    }

    @Test func aDraggedArtboardKeepsItsLayersWhenToldTo() throws {
        let bench = Bench(extra: [Self.rect(CGRect(x: 0, y: 0, width: 400, height: 60), Self.accent, name: "Top")])
        bench.step { bench.store.update([bench.a.id], "Keep Layers in Place") { $0.pinsLayers = true } }
        bench.store.selection = [bench.a.id]
        bench.drag(CGPoint(x: 500, y: 250), CGPoint(x: 800, y: 250))
        #expect(bench.a.frame.width == 700)
        #expect(bench.node("Top")?.frame == CGRect(x: 0, y: 0, width: 400, height: 60))
    }

    @Test func aDecksPostsFollowItsDesign() throws {
        var deck = Self.photoPost()
        deck.frame.origin = CGPoint(x: 100, y: 100)
        let bench = Bench()
        bench.step { bench.store.edit("Add") { doc in doc.nodes.append(deck) } }
        bench.step { bench.store.addPost(to: deck.id) }
        bench.step { bench.store.addPost(to: deck.id) }
        #expect(bench.store.doc.node(deck.id)?.isDeck == true)
        bench.step { bench.store.resizeArtboards([deck.id]) { _ in CGSize(width: 1200, height: 627) } }
        let board = try #require(bench.store.doc.node(deck.id))
        let design = board.layers(of: nil)
        for post in board.posts {
            for layer in board.layers(of: post) {
                let twin = try #require(design.first { $0.id.mixed(Deck.key(post)) == layer.id })
                #expect(layer.frame == twin.frame, "\(layer.name)")
            }
        }
        #expect(board.frame.size == CGSize(width: 1200, height: 627))
    }

    @Test func theAIResizingAnArtboardLaysItOutToo() async throws {
        let bench = Bench(extra: [Self.rect(CGRect(x: 0, y: 0, width: 400, height: 60), Self.accent, name: "Top")])
        MCPTools.opened(bench.store)
        let tools = MCPTools()
        _ = await tools.call("update_layers", ["design": bench.store.name, "updates": [["layer": "A", "width": 700]]])
        #expect(bench.a.frame.width == 700)
        #expect(bench.node("Top")?.frame.width == 700)
        _ = await tools.call("update_layers", ["design": bench.store.name, "updates": [["layer": "A", "adapts": false, "width": 900]]])
        #expect(bench.a.frame.width == 900)
        #expect(bench.node("Top")?.frame.width == 700)
        #expect(bench.a.pinsLayers == true)
    }

    @Test func layersTravelToTheirNewPlaces() throws {
        let post = Self.photoPost()
        var a = BezzleDocument(), b = BezzleDocument()
        a.nodes = [post]
        b.nodes = [Adapting.resized(post, to: CGSize(width: 1200, height: 627), remembering: false)]
        let tool = AdaptTool()
        _ = tool.frame(of: a, at: 10)
        tool.move([post.id], withBoard: true)
        let early = tool.frame(of: b, at: 10.016)
        #expect(tool.isMoving)
        let photo = try #require(early.nodes[0].children.first { $0.name == "Photo" })
        let end = try #require(b.nodes[0].children.first { $0.name == "Photo" })
        #expect(photo.frame != end.frame)
        // On its way: the artboard too.
        #expect(early.nodes[0].frame.width < 1200)
        var t = 10.016, last = early
        for _ in 0..<200 {
            t += 1.0 / 120
            last = tool.frame(of: b, at: t)
        }
        #expect(!tool.isMoving)
        #expect(last == b)
    }

    @Test func aDragThatTurnsTheDesignMovesItsLayers() throws {
        let bench = Bench()
        var post = Self.photoPost()
        post.frame.origin = CGPoint(x: 100, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [post] } }
        bench.store.selection = [post.id]
        let tool = bench.canvas.adaptTool
        _ = tool.frame(of: bench.store.doc, at: 10)
        bench.drag(CGPoint(x: 640, y: 1450), CGPoint(x: 640, y: 620), release: false)
        #expect(bench.store.doc.nodes[0].frame.height == 520)
        let shown = tool.frame(of: bench.store.doc, at: 10.016)
        #expect(tool.isMoving)
        #expect(shown != bench.store.doc)
        bench.release(CGPoint(x: 640, y: 620))
    }

    @Test func pointingAtASizeShowsItWithoutMakingIt() throws {
        let bench = Bench()
        var post = Self.photoPost()
        post.frame.origin = CGPoint(x: 100, y: 100)
        bench.step { bench.store.edit("Add") { doc in doc.nodes = [post] } }
        let before = bench.store.doc
        let change = try #require(bench.store.adaptedPreview(of: post.id, to: CGSize(width: 1200, height: 627)))
        bench.store.showPreview("artboard-size", reshaping: change)
        #expect(bench.store.shownDoc.nodes[0].frame.size == CGSize(width: 1200, height: 627))
        #expect(bench.store.doc == before)
        bench.store.showPreview("artboard-size", reshaping: nil)
        // Choosing it afterwards still comes back exactly.
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1200, height: 627) } }
        bench.step { bench.store.resizeArtboards([post.id]) { _ in CGSize(width: 1080, height: 1350) } }
        #expect(bench.store.doc.nodes[0].children == post.children)
    }

    /// Laid out again at every step of a drag, it must leave the frame its time.
    @Test func layingOutIsQuick() throws {
        guard let out = Self.sheets else { return }
        var lines: [String] = []
        for (name, design) in Self.designs {
            let plan = Adapt.plan(design)
            let start = CACurrentMediaTime()
            for i in 0..<40 { _ = Adapt.compose(plan, to: CGSize(width: design.frame.width * (0.5 + Double(i) / 40), height: design.frame.height)) }
            lines.append("\(name): \(((CACurrentMediaTime() - start) / 40 * 1000).rounded()) ms a layout (Debug)")
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("speed.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Contact sheets

    /// Where pictures of the designs at many sizes go, to look at; set to see them.
    static var sheets: URL? {
        ProcessInfo.processInfo.environment["BEZZLE_ADAPT_SHEETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func assets() throws -> Assets {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adapt-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("lake.jpg")
        if !FileManager.default.fileExists(atPath: file.path), let data = WelcomePhoto.jpeg() { try data.write(to: file) }
        return Assets(folder: folder)
    }

    @Test func drawsContactSheets() throws {
        guard let out = Self.sheets else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let assets = try Self.assets()
        let sizes: [String: [CGSize]] = [
            "photo-post": [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 1200, height: 627), CGSize(width: 1500, height: 500)],
            "centred-post": [CGSize(width: 1080, height: 1350), CGSize(width: 1080, height: 1920), CGSize(width: 1600, height: 900), CGSize(width: 1500, height: 500)],
            "phone": [CGSize(width: 1032, height: 1376), CGSize(width: 360, height: 780), CGSize(width: 208, height: 248), CGSize(width: 402, height: 1200)],
            "web": [CGSize(width: 1920, height: 1080), CGSize(width: 1024, height: 1366), CGSize(width: 768, height: 1024), CGSize(width: 402, height: 1600)],
            "poster": [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 1600, height: 900), CGSize(width: 595, height: 842)],
        ]
        for (name, design) in Self.designs {
            let plan = Adapt.plan(design)
            var boards = [design]
            for s in sizes[name] ?? [] { boards.append(Adapt.compose(plan, to: s).board) }
            try Self.sheet(boards, assets: assets, to: out.appendingPathComponent("\(name).png"))
        }
    }

    @Test func printsOptions() throws {
        guard let out = Self.sheets else { return }
        var lines: [String] = []
        for (name, design, size) in [("web", Self.webHero(), CGSize(width: 1024, height: 1366)), ("web-phone", Self.webHero(), CGSize(width: 402, height: 1600))] {
            let plan = Adapt.plan(design)
            lines.append("\(name) turnPaths \(plan.turnPaths) wrap \(String(describing: plan.wrapPath)) mode \(plan.mode)")
            for (a, _, k, s) in Adapt.options(plan, to: size) {
                lines.append("  turned \(String(describing: a.turned)) columns \(String(describing: a.columns)) k \(k) score \(s)")
            }
        }
        for (name, design, size) in [("post-banner", Self.photoPost(), CGSize(width: 1500, height: 500)), ("web-768", Self.webHero(), CGSize(width: 768, height: 1024))] {
            let r = Adapt.compose(Adapt.plan(design), to: size)
            lines.append("\(name) k \(r.scale) arrangement \(String(describing: r.arrangement.turned)) \(String(describing: r.arrangement.columns))")
            for n in r.board.children { lines.append("  \(n.name.prefix(24)) \(n.frame.integral)") }
        }
        for (name, design, size) in [("sticker", AdaptSuiteTests.sticker(), CGSize(width: 360, height: 780)), ("random233", AdaptSuiteTests.randomDesign(233), CGSize(width: 402, height: 874))] {
            let plan = Adapt.plan(design)
            let r = Adapt.compose(plan, to: size)
            lines.append("\(name) k \(r.scale) from \(design.frame.size) arrangement \(String(describing: r.arrangement.turned)) \(String(describing: r.arrangement.columns))")
            for (a, n) in zip(design.children, r.board.children) { lines.append("  \(n.name.prefix(20)) \(Geometry.bounds(of: a).integral) -> \(Geometry.bounds(of: n)) size \(String(describing: n.style?.size))") }
            for b in r.skeleton.blocks { lines.append("  block \(b)") }
            lines.append("  tree \(String(describing: plan.root.flow.map { Adapt.describe(.stack($0)) }))")
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8)
    }

    /// A design to try it on in the app, with the photo in it: BEZZLE_ADAPT_SHEETS/Adapt.bezzle.
    @Test func writesADesignToTryItOn() throws {
        guard let out = Self.sheets else { return }
        let url = out.appendingPathComponent("Adapt.bezzle")
        try? FileManager.default.removeItem(at: url)
        var doc = BezzleDocument()
        var post = Self.photoPost(), poster = Self.centredPost(), phone = Self.phoneScreen()
        post.frame.origin = CGPoint(x: 0, y: 0)
        poster.frame.origin = CGPoint(x: 1300, y: 0)
        phone.frame.origin = CGPoint(x: 2600, y: 0)
        post.name = "Post"
        poster.name = "Sale"
        phone.name = "Phone"
        doc.nodes = [post, poster, phone]
        doc.viewport = Viewport(origin: CGPoint(x: -200, y: -150), zoom: 0.4)
        try DesignFile.write(doc, to: url)
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try #require(WelcomePhoto.jpeg()).write(to: images.appendingPathComponent("lake.jpg"))
    }

    /// A real design, BEZZLE_ADAPT_DOC, each of its artboards resized through the store as the app
    /// does, drawn into BEZZLE_ADAPT_SHEETS with what is wrong with each, in words.
    @Test func triesARealDesign() throws {
        guard let out = Self.sheets, let path = ProcessInfo.processInfo.environment["BEZZLE_ADAPT_DOC"] else { return }
        let url = URL(fileURLWithPath: path)
        let doc = try DesignFile.read(url)
        let assets = Assets(design: url)
        let sizes = [CGSize(width: 842, height: 595), CGSize(width: 420, height: 595), CGSize(width: 595, height: 595),
                     CGSize(width: 595, height: 1000), CGSize(width: 400, height: 842), CGSize(width: 1080, height: 1920)]
        var report: [String] = []
        for (b, board) in doc.nodes.enumerated() where board.isArtboard {
            var shown = [board.shownAlone]
            for size in sizes {
                let bench = Bench()
                var d = doc
                d.viewport = nil
                bench.step { bench.store.edit("Open") { $0 = d } }
                bench.step { bench.store.resizeArtboards([board.id]) { _ in size } }
                let laid = try #require(bench.store.doc.node(board.id))
                shown.append(laid.shownAlone)
                var was = board.shownAlone
                was.frame.origin = laid.frame.origin
                report += AdaptSuiteTests.problems(was, laid.shownAlone, size: size)
                // The design behind its posts too.
                if board.isDeck {
                    var design = board
                    design.children = board.layers(of: nil)
                    var after = laid
                    after.children = laid.layers(of: nil)
                    design.deck = nil; after.deck = nil
                    report += AdaptSuiteTests.problems(design, after, size: size).map { "design: " + $0 }
                }
            }
            try Self.sheet(shown, assets: assets, to: out.appendingPathComponent("real-\(b).png"))
            if b == 1 {
                let r = Adapt.compose(Adapt.plan(board), to: CGSize(width: 842, height: 595))
                report.append("page 1 at 842×595: k \(r.scale) arrangement \(String(describing: r.arrangement.turned))")
                for n in r.board.children { report.append("  \(n.post.map { "post \($0)" } ?? "design") \(n.name) \(n.frame.integral) own \(n.own ?? [])") }
            }
            let plan = Adapt.plan(board)
            report.append("\(board.name): mode \(plan.mode)\n" + (plan.root.flow.map { Adapt.describe(.stack($0)) } ?? "no flow"))
            if b >= 5 { break }
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
    }

    /// The artboards side by side, each as tall as the others.
    static func sheet(_ boards: [Node], assets: Assets, to url: URL) throws {
        // One scale for all, so that what grew looks bigger.
        let gap: CGFloat = 40
        let unit = 560 / (boards.map(\.frame.height).max() ?? 1)
        let widths = boards.map { $0.frame.width * unit }
        let tall = 560.0
        let width = widths.reduce(0, +) + gap * CGFloat(boards.count + 1)
        let ctx = try #require(CGContext(data: nil, width: Int(width), height: Int(tall + gap * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: tall + gap * 2))
        var x = gap
        for (b, w) in zip(boards, widths) {
            let h = b.frame.height * unit
            if let image = Renderer.image(of: b, scale: max(unit, 0.05) * 2, assets: assets) {
                ctx.draw(image, in: CGRect(x: x, y: gap + tall - h, width: w, height: h))
            }
            x += w + gap
        }
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
