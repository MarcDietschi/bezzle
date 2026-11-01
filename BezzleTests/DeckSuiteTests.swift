import Testing
import AppKit
import ImageIO
@testable import Bezzle

/// Stacks (decks, as the code calls them) taken through everything that can happen to one: made
/// from the button under an artboard and from the menu; turned with the row of posts, the page
/// keys and the selection; their layers moved, drawn, deleted, duplicated, grouped, restacked,
/// hidden and restyled in one post and so in all; posts added, removed, moved and spread out over
/// the canvas; unstacked; drawn and exported; saved, pasted and shared; driven by the assistant;
/// and every step undone. Each test says what a person would expect to see. See `Deck`.
///
/// The tests that spread the posts out draw the canvas's cards for a moment, a frame at a time, so
/// the cards fly to where they go, and spin `RunLoop.main` meanwhile; they stay synchronous.
@MainActor
struct DeckSuiteTests {
    // MARK: - Fixtures

    /// Artboard A at 100,100 sized 400 × 300 holding, bottom first: "Back", a white rectangle
    /// filling it; "Title", a 24 pt text "Tip" at 20,20; and "Badge", a grey 40 × 40 ellipse at
    /// 340,20. On the canvas the title is at 120,120 and the badge's middle at 460,140.
    private func plain() -> Bench {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        back.fill.color = .white
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        title.text = "Tip"
        title.style?.size = 24
        title.refit()
        var badge = Node(kind: .ellipse, name: "Badge", frame: CGRect(x: 340, y: 20, width: 40, height: 40))
        badge.fill.color = RGBA(r: 0.5, g: 0.5, b: 0.5)
        return Bench(extra: [back, title, badge])
    }

    /// That artboard as a stack of `count` posts saying "Tip 1", "Tip 2" and so on, the first in
    /// front and nothing selected.
    private func stack(_ count: Int = 3) -> Bench {
        let bench = plain()
        let title = bench.a.children[1].id
        bench.step { bench.store.spread((1...count).map { "Tip \($0)" }, from: title) }
        bench.store.turn(bench.a.id, to: bench.a.posts[0])
        bench.store.selection = []
        return bench
    }

    private func layer(_ name: String, in post: Int?, _ bench: Bench) -> Node? {
        bench.a.layers(of: post).first { $0.name == name }
    }

    /// The layer named so in every post, in their order.
    private func all(_ name: String, _ bench: Bench) -> [Node] {
        bench.a.posts.compactMap { layer(name, in: $0, bench) }
    }

    /// What each post's title says, in their order.
    private func words(_ bench: Bench) -> [String?] { all("Title", bench).map(\.text) }

    private func front(_ bench: Bench) -> Int? { bench.store.front(of: bench.a) }

    /// The id of the layer so named in a post, or a made-up one, so the test fails rather than traps.
    private func id(_ name: String, in post: Int?, _ bench: Bench) -> UUID { layer(name, in: post, bench)?.id ?? UUID() }

    /// What is wrong with any stack in the design: a post missing a layer of the design or holding
    /// one more, a layer not keyed to the design's, a post listed twice, a layer marked as in a post
    /// the stack has not; and anything off a stack still marked as in a post. Empty when every
    /// stack is as a stack should be.
    private func problems(_ doc: BezzleDocument) -> [String] {
        var out: [String] = []
        for deck in doc.nodes {
            guard deck.isDeck else {
                if deck.marksDeck { out.append("\(deck.name) is marked as in a post") }
                if deck.isArtboard, deck.children.contains(where: \.marksDeck) { out.append("a layer of \(deck.name) is marked as in a post") }
                continue
            }
            let posts = deck.posts
            if let listed = deck.deck?.posts, Set(listed).count != listed.count { out.append("\(deck.name) lists a post twice") }
            // Only a post's own layers are marked as in it; what they hold may keep something of
            // its own, but the design behind them keeps nothing.
            func inPost(_ n: Node) -> Bool { n.post != nil || n.children.contains(where: inPost) }
            for c in deck.children {
                if let p = c.post, !posts.contains(p) { out.append("\(c.name) is in a post \(deck.name) has not") }
                if c.children.contains(where: inPost) { out.append("what \(c.name) holds is marked as in a post") }
                if c.post == nil, c.marksDeck { out.append("\(c.name) of the design keeps something of its own") }
            }
            let design = deck.layers(of: nil)
            for (i, p) in posts.enumerated() {
                let k = Deck.key(p)
                func same(_ m: Node, _ n: Node, _ path: String) {
                    if n.id != m.id.mixed(k) { out.append("post \(i + 1): \(path) is not the design's") }
                    if n.kind != m.kind { out.append("post \(i + 1): \(path) is a \(n.kind), in the design a \(m.kind)") }
                    guard n.children.count == m.children.count else {
                        out.append("post \(i + 1): \(path) holds \(n.children.map(\.name)), in the design \(m.children.map(\.name))")
                        return
                    }
                    zip(m.children, n.children).forEach { same($0, $1, path + "/" + $1.name) }
                }
                let layers = deck.layers(of: p)
                guard layers.count == design.count else {
                    out.append("post \(i + 1) holds \(layers.map(\.name)), the design \(design.map(\.name))")
                    continue
                }
                zip(design, layers).forEach { same($0, $1, $1.name) }
            }
        }
        return out
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 200 && p.g < 90 && p.b < 90 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 235 && p.g > 235 && p.b > 235 }

    private static let red = RGBA(r: 1, g: 0, b: 0)

    /// Post `post`'s back made red, and kept so in that post alone.
    private func redBack(in post: Int, _ bench: Bench) {
        bench.step { bench.store.update([id("Back", in: post, bench)], "Fill") { $0.fill.color = Self.red; $0.own = ["fill"] } }
    }

    /// Where on the canvas a point of the screen is, as the bench presses.
    private func canvas(_ bench: Bench, _ v: CGPoint) -> CGPoint { bench.store.viewport.toCanvas(v) }

    /// The row under the selected stack, or artboard, on the canvas: each post's card and the
    /// button that adds one.
    private func row(_ bench: Bench) -> (cards: [CGPoint], add: CGPoint)? {
        guard let board = bench.store.selectedDeck ?? bench.store.selection.first.flatMap({ bench.store.node($0) }),
              let row = bench.canvas.deckTool.row(under: board), let add = row.add else { return nil }
        return (row.cards.map { canvas(bench, $0.center) }, canvas(bench, add.center))
    }

    /// Just below A's bottom edge, on the feet of the cards behind the post in front.
    private let feet = CGPoint(x: 300, y: 404)

    /// Draws the canvas's stacks for `seconds`, a frame at a time as the screen would, so what
    /// moves gets where it goes, and pictures drawn away from the main thread come in.
    private func frames(_ bench: Bench, _ seconds: Double = 0.9) {
        let bounds = bench.canvas.bounds
        guard let ctx = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            bench.canvas.deckTool.drawStacks(ctx, in: bounds)
            bench.canvas.deckTool.draw(ctx, scale: 2, in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
    }

    /// Opens every post of A over the canvas by pressing the feet of its cards, and lets them land.
    private func spreadOut(_ bench: Bench) throws -> (cards: [Int: CGPoint], trash: [Int: CGPoint], add: CGPoint?) {
        bench.click(feet)
        #expect(bench.canvas.deckTool.spreading)
        frames(bench)
        let places = try #require(bench.canvas.deckTool.spreadPlaces)
        return (places.cards.mapValues { canvas(bench, $0.center) }, places.trash.mapValues { canvas(bench, $0.center) },
                places.add.map { canvas(bench, $0.center) })
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDeckSuite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    // MARK: - Making a stack

    @Test func theButtonUnderAnArtboardMakesItAStackOfTwo() throws {
        let bench = plain()
        let before = bench.a
        bench.store.selection = [bench.a.id]
        let row = try #require(row(bench))
        // Under an artboard that is no stack yet, only the button that adds.
        #expect(row.cards.isEmpty)
        bench.click(row.add)
        let deck = bench.a
        #expect(deck.isDeck && deck.posts.count == 2)
        // The layers it had are its first post, as they were, and the new one is in front.
        #expect(deck.layers(of: deck.posts[0]).map(\.id) == before.children.map(\.id))
        #expect(front(bench) == deck.posts[1])
        #expect(words(bench) == ["Tip", "Tip"])
        #expect(bench.store.selection == [deck.id])
        // The canvas sees only the post in front.
        #expect(bench.store.seenLayers(of: deck).map(\.id) == deck.layers(of: deck.posts[1]).map(\.id))
        #expect(bench.store.layerCount == bench.store.seenDoc.layerCount)
        #expect(problems(bench.store.doc).isEmpty)
        // Undone, it is the artboard it was.
        bench.undoLast()
        #expect(bench.a == before)
    }

    @Test func theButtonUnderAStackDealsACopyOfThePostInFrontRightAfterIt() throws {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[1])
        bench.store.selection = [bench.a.id]
        let row = try #require(row(bench))
        #expect(row.cards.count == 3)
        bench.click(row.add)
        let now = bench.a.posts
        #expect(now.count == 4)
        #expect([now[0], now[1], now[3]] == posts)
        #expect(front(bench) == now[2])
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
        // Undone, the post that was in front is in front again; redone, the new one.
        bench.undoLast()
        #expect(bench.a.posts == posts)
        #expect(front(bench) == posts[1])
        bench.undo.redo()
        #expect(bench.a.posts == now)
        #expect(front(bench) == now[2])
    }

    @Test func addPostFromTheMenuOnALayerMakesItsArtboardAStack() {
        let bench = plain()
        let title = bench.a.children[1].id
        bench.store.selection = [title]
        let board = bench.store.postableBoard
        #expect(board?.id == bench.a.id)
        bench.step { bench.store.addPost(to: bench.a.id) }
        let deck = bench.a
        #expect(deck.isDeck && deck.posts.count == 2)
        // What was selected is selected in the new post, which is in front.
        #expect(bench.store.selection == [title.mixed(Deck.key(from: deck.posts[0], to: deck.posts[1]))])
        #expect(front(bench) == deck.posts[1])
        // On a stack, the menu adds to the stack the selection is in.
        #expect(bench.store.postableBoard?.id == deck.id)
    }

    @Test func anEmptyArtboardBecomesAStackAndWhatIsDrawnOnItIsInEveryPost() {
        let bench = Bench()
        bench.store.selection = [bench.b.id]
        bench.step { bench.store.addPost(to: bench.b.id) }
        #expect(bench.b.isDeck && bench.b.posts.count == 2)
        bench.store.tool = .rectangle
        // B lies at 600,100.
        bench.drag(CGPoint(x: 650, y: 150), CGPoint(x: 750, y: 220), flags: [.command])
        let b = bench.b
        for p in b.posts {
            #expect(b.layers(of: p).map(\.kind) == [.rectangle])
            #expect(b.layers(of: p).first?.frame == CGRect(x: 50, y: 50, width: 100, height: 70))
        }
        #expect(b.layers(of: nil).count == 1)
        #expect(bench.store.selection == b.layers(of: bench.store.front(of: b)).map(\.id))
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(bench.b.isDeck && bench.b.children.isEmpty)
    }

    @Test func aLockedStackTurnsButTakesNoPostsAndLosesNone() throws {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.step { bench.store.setLocked(true, [a]) }
        bench.store.selection = [a]
        #expect(bench.store.postableBoard == nil)
        bench.step { bench.store.addPost(to: a) }
        bench.step { bench.store.removePost(posts[0], from: a) }
        bench.step { bench.store.movePost(posts[0], in: a, to: 3) }
        bench.step { bench.store.unstack(a) }
        bench.step { bench.store.spreadOut(a) }
        #expect(bench.a.posts == posts)
        #expect(bench.store.doc.nodes.count == 2)
        // The row under it turns it, and has nothing that adds.
        #expect(bench.canvas.deckTool.row(under: bench.a).map { $0.cards.count } == 3)
        #expect(bench.canvas.deckTool.row(under: bench.a)?.add == nil)
        // Turning only looks.
        bench.store.turnPage(by: 1)
        #expect(front(bench) == posts[1])
        // Spread out, its posts can be looked at and picked, but neither thrown away nor added to.
        bench.store.selection = []
        let spread = try spreadOut(bench)
        #expect(spread.cards.count == 3)
        #expect(spread.trash.isEmpty && spread.add == nil)
    }

    // MARK: - Turning

    @Test func clickingAPostInTheRowTurnsToIt() throws {
        let bench = stack()
        let posts = bench.a.posts
        let design = bench.store.doc
        bench.store.selection = [bench.a.id]
        let row = try #require(row(bench))
        bench.click(row.cards[2])
        #expect(front(bench) == posts[2])
        #expect(bench.store.selection == [bench.a.id])
        bench.click(row.cards[0])
        #expect(front(bench) == posts[0])
        // Turning changes nothing in the design.
        #expect(bench.store.doc == design)
    }

    @Test func scrubbingAlongTheRowTurnsThroughThePosts() throws {
        let bench = stack()
        let posts = bench.a.posts
        let design = bench.store.doc
        bench.store.selection = [bench.a.id]
        let row = try #require(row(bench))
        bench.drag(row.cards[0], row.cards[2])
        #expect(front(bench) == posts[2])
        #expect(bench.store.doc == design)
        // Let go, the press is over: moving the pointer turns nothing.
        bench.move(row.cards[0])
        #expect(front(bench) == posts[2])
    }

    @Test func thePageKeysTurnAndTheSameLayerStaysSelected() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[0], bench)]
        bench.key(121)
        #expect(front(bench) == posts[1])
        #expect(bench.store.selection == [id("Title", in: posts[1], bench)])
        bench.key(121)
        bench.key(121)
        // Past the last, nothing.
        #expect(front(bench) == posts[2])
        #expect(bench.a.posts == posts)
        bench.key(116)
        #expect(front(bench) == posts[1])
        #expect(bench.store.selection == [id("Title", in: posts[1], bench)])
    }

    @Test func clickingALayerPicksItInThePostInFront() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[1])
        bench.click(CGPoint(x: 130, y: 132))
        #expect(bench.store.selection == [id("Title", in: posts[1], bench)])
        bench.click(CGPoint(x: 460, y: 140))
        #expect(bench.store.selection == [id("Badge", in: posts[1], bench)])
        // Escape goes out a level, to the stack.
        bench.key(53)
        #expect(bench.store.selection == [bench.a.id])
        #expect(front(bench) == posts[1])
    }

    @Test func selectingALayerOfAPostBehindBringsThatPostToTheFront() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Badge", in: posts[2], bench)]
        #expect(front(bench) == posts[2])
        // One of the design behind every post is the same layer in the post in front.
        bench.store.selection = [id("Badge", in: nil, bench)]
        #expect(bench.store.selection == [id("Badge", in: posts[2], bench)])
    }

    @Test func selectAllSelectsThePostInFront() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[1], bench)]
        bench.store.selectAll()
        #expect(Set(bench.store.selection) == Set(bench.a.layers(of: posts[1]).map(\.id)))
    }

    // MARK: - Changing the posts

    @Test func draggingALayerMovesItInEveryPost() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[1])
        let before = all("Title", bench).map(\.frame)
        bench.drag(CGPoint(x: 130, y: 132), CGPoint(x: 160, y: 182), flags: [.command])
        #expect(all("Title", bench).allSatisfy { $0.frame.origin == CGPoint(x: 50, y: 70) })
        #expect(layer("Title", in: nil, bench)?.frame.origin == CGPoint(x: 50, y: 70))
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
        // One step puts it back everywhere.
        bench.undoLast()
        #expect(all("Title", bench).map(\.frame) == before)
    }

    @Test func aLayerDrawnOnAStackIsInEveryPost() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[2])
        bench.store.tool = .ellipse
        bench.drag(CGPoint(x: 150, y: 250), CGPoint(x: 200, y: 300), flags: [.command])
        for p in posts { #expect(bench.a.layers(of: p).last?.kind == .ellipse) }
        #expect(bench.store.selection == [bench.a.layers(of: posts[2]).last?.id ?? UUID()])
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func deletingALayerInOnePostDeletesItInAllAndUndoBringsBackEachPostsOwn() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[1], bench)]
        bench.key(51)
        #expect(all("Title", bench).isEmpty && layer("Title", in: nil, bench) == nil)
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func duplicatingALayerInAPostDuplicatesEachPostsOwn() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[1], bench)]
        bench.step { bench.store.duplicateSelection() }
        for (i, p) in posts.enumerated() {
            let titles = bench.a.layers(of: p).filter { $0.name == "Title" }
            // Every post's copy says what its own title says, just over it.
            #expect(titles.map(\.text) == ["Tip \(i + 1)", "Tip \(i + 1)"])
            #expect(titles.count == 2 && titles[1].frame.origin == CGPoint(x: 30, y: 30))
            #expect(bench.a.layers(of: p).map(\.name) == ["Back", "Title", "Title", "Badge"])
        }
        #expect(bench.store.selection == [bench.a.layers(of: posts[1])[2].id])
        #expect(front(bench) == posts[1])
        #expect(problems(bench.store.doc).isEmpty)
        // A change to the copy in one post is a change to it in all, and only to it.
        bench.step { bench.store.updateSelection("Size") { $0.style?.size = 12 } }
        for p in posts { #expect(bench.a.layers(of: p).filter { $0.name == "Title" }.map { $0.style?.size } == [24, 12]) }
        bench.undoLast()
        bench.undoLast()
        #expect(bench.a.layers(of: posts[0]).map(\.name) == ["Back", "Title", "Badge"])
    }

    @Test func optionDraggingALayerInAPostCopiesEachPostsOwn() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[2])
        bench.drag(CGPoint(x: 130, y: 132), CGPoint(x: 130, y: 232), flags: [.option, .command])
        for (i, p) in posts.enumerated() {
            let titles = bench.a.layers(of: p).filter { $0.name == "Title" }
            #expect(titles.map(\.text) == ["Tip \(i + 1)", "Tip \(i + 1)"])
            #expect(titles.map(\.frame.minY) == [20, 120])
        }
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(all("Title", bench).count == 3 && bench.a.layers(of: posts[0]).count == 3)
    }

    @Test func groupingAndUngroupingInAPostKeepsEveryPostsWords() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[2], bench), id("Badge", in: posts[2], bench)]
        bench.step { bench.store.group() }
        for (i, p) in posts.enumerated() {
            let layers = bench.a.layers(of: p)
            #expect(layers.count == 2 && layers[1].isGroup)
            #expect(layers.last?.children.map(\.name) == ["Title", "Badge"])
            #expect(layers.last?.children.first?.text == "Tip \(i + 1)")
        }
        #expect(problems(bench.store.doc).isEmpty)
        bench.step { bench.store.ungroup() }
        for p in posts { #expect(bench.a.layers(of: p).map(\.name) == ["Back", "Title", "Badge"]) }
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(all("Badge", bench).allSatisfy { $0.frame == CGRect(x: 340, y: 20, width: 40, height: 40) })
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func groupingInAPostKeepsWhatEachPostKeepsOfItsOwnThereAlone() {
        let bench = stack()
        let posts = bench.a.posts
        redBack(in: posts[1], bench)
        bench.store.selection = [id("Back", in: posts[1], bench), id("Title", in: posts[1], bench)]
        bench.step { bench.store.group() }
        let backs = posts.map { p in bench.a.layers(of: p).first?.children.first { $0.name == "Back" } }
        #expect(backs.map { $0?.fill.color } == [.white, Self.red, .white])
        #expect(backs.map { $0?.own } == [nil, ["fill"], nil])
        #expect(problems(bench.store.doc).isEmpty)
        // Ungrouped again, still so.
        bench.step { bench.store.ungroup() }
        #expect(all("Back", bench).map(\.fill.color) == [.white, Self.red, .white])
        #expect(all("Back", bench).map(\.own) == [nil, ["fill"], nil])
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func bringingALayerToTheFrontInOnePostDoesSoInAll() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Back", in: posts[1], bench)]
        bench.step { bench.store.arrange(.front) }
        for p in posts { #expect(bench.a.layers(of: p).map(\.name) == ["Title", "Badge", "Back"]) }
        #expect(bench.a.layers(of: nil).map(\.name) == ["Title", "Badge", "Back"])
        bench.step { bench.store.arrange(.backward) }
        for p in posts { #expect(bench.a.layers(of: p).map(\.name) == ["Title", "Back", "Badge"]) }
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func hidingALayerInOnePostHidesItInAllAndOffersToKeepItThere() throws {
        let bench = stack()
        let posts = bench.a.posts
        let badge = id("Badge", in: posts[1], bench)
        bench.store.selection = [badge]
        bench.step { bench.store.setHidden(true, [badge]) }
        #expect(all("Badge", bench).allSatisfy { $0.hidden })
        let offer = try #require(bench.store.offer)
        #expect(offer.post == posts[1])
        bench.step { bench.store.take(offer) }
        #expect(all("Badge", bench).map(\.hidden) == [false, true, false])
        #expect(layer("Badge", in: posts[1], bench)?.own == ["hidden"])
        // Shown again in another post, the one that keeps it hidden stays so.
        bench.step { bench.store.setHidden(true, [id("Badge", in: posts[0], bench)]) }
        bench.step { bench.store.setHidden(false, [id("Badge", in: posts[0], bench)]) }
        #expect(all("Badge", bench).map(\.hidden) == [false, true, false])
    }

    @Test func aPictureGivenToAShapeInOnePostIsThatPostsOwn() {
        let bench = stack()
        let posts = bench.a.posts
        let picture = ImageFill(asset: "one.png", size: CGSize(width: 10, height: 10))
        bench.step { bench.store.update([id("Back", in: posts[1], bench)], "Picture") { $0.fill.image = picture } }
        #expect(all("Back", bench).map(\.fill.image) == [nil, picture, nil])
        #expect(bench.store.offer == nil)
        // Rounded in another post, it is rounded in all, and keeps its picture.
        bench.step { bench.store.update([id("Back", in: posts[0], bench)], "Round") { $0.cornerRadius = 20 } }
        #expect(all("Back", bench).allSatisfy { $0.cornerRadius == 20 })
        #expect(all("Back", bench).map(\.fill.image) == [nil, picture, nil])
    }

    @Test func restylingAPostsTextRestylesItInAllEachFittingItsWords() {
        let bench = stack()
        let posts = bench.a.posts
        bench.step { bench.store.update([id("Title", in: posts[1], bench)], "Type") { $0.text = "A much longer tip" } }
        bench.step { bench.store.update([id("Title", in: posts[0], bench)], "Size") { $0.style?.size = 36 } }
        #expect(all("Title", bench).allSatisfy { $0.style?.size == 36 })
        #expect(words(bench) == ["Tip 1", "A much longer tip", "Tip 3"])
        let titles = all("Title", bench)
        #expect(titles[1].frame.width > titles[0].frame.width * 2)
        for t in titles {
            var fitted = t
            fitted.refit()
            #expect(fitted.frame == t.frame)
        }
    }

    @Test func aRepeatGridMadeInAPostKeepsEveryPostsWords() {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.selection = [id("Title", in: posts[1], bench)]
        bench.step { bench.store.makeRepeatGrid() }
        for (i, p) in posts.enumerated() {
            let grid = bench.a.layers(of: p).first(where: \.isRepeatGrid)
            #expect(grid?.children.first?.text == "Tip \(i + 1)")
        }
        #expect(problems(bench.store.doc).isEmpty)
    }

    // MARK: - Adding, removing and moving posts

    @Test func removingThePostInFrontShowsTheNextAndUndoBringsItBack() {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        bench.store.selection = [a]
        bench.step { bench.store.removePost(posts[1], from: a) }
        #expect(bench.a.posts == [posts[0], posts[2]])
        #expect(front(bench) == posts[2])
        #expect(words(bench) == ["Tip 1", "Tip 3"])
        bench.undoLast()
        #expect(bench.a.posts == posts)
        #expect(front(bench) == posts[1])
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        bench.undo.redo()
        #expect(bench.a.posts == [posts[0], posts[2]])
        #expect(front(bench) == posts[2])
    }

    @Test func removingAPostWithALayerSelectedSelectsItInTheNextAndUndoInTheOneBack() {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.selection = [id("Badge", in: posts[1], bench)]
        bench.step { bench.store.removePost(posts[1], from: a) }
        #expect(bench.store.selection == [id("Badge", in: posts[2], bench)])
        #expect(front(bench) == posts[2])
        bench.undoLast()
        #expect(bench.store.selection == [id("Badge", in: posts[1], bench)])
        #expect(front(bench) == posts[1])
    }

    @Test func aStackLeftWithOnePostIsAnArtboardAndUndoTurnsBackToThePostShown() {
        let bench = stack(2)
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        bench.store.selection = [a]
        bench.step { bench.store.removePost(posts[0], from: a) }
        #expect(!bench.a.isDeck)
        #expect(bench.a.children.map(\.name) == ["Back", "Title", "Badge"])
        #expect(bench.node("Title")?.text == "Tip 2")
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(bench.a.posts == posts)
        #expect(front(bench) == posts[1])
    }

    @Test func movingAPostKeepsThePostInFront() {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        bench.step { bench.store.movePost(posts[0], in: a, to: 3) }
        #expect(bench.a.posts == [posts[1], posts[2], posts[0]])
        #expect(front(bench) == posts[1])
        #expect(words(bench) == ["Tip 2", "Tip 3", "Tip 1"])
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(bench.a.posts == posts)
        #expect(front(bench) == posts[1])
    }

    @Test func keepingOnlyThePostInFrontAndUndoingShowsThatPostAgain() {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        bench.store.selection = [a]
        bench.step { bench.store.unstack(a) }
        #expect(!bench.a.isDeck)
        #expect(bench.node("Title")?.text == "Tip 2")
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(bench.a.isDeck && bench.a.posts == posts)
        #expect(front(bench) == posts[1])
    }

    @Test func unstackingIntoArtboardsLaysEveryPostOutClearOfTheRest() {
        let bench = stack()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        bench.step { bench.store.spreadOut(a) }
        let boards = bench.store.doc.nodes.filter(\.isArtboard)
        #expect(boards.count == 4)
        #expect(!boards.contains { $0.isDeck })
        // None lies over another: B is where the new ones would go first.
        for (i, one) in boards.enumerated() {
            for other in boards[(i + 1)...] { #expect(!one.frame.intersects(other.frame), "\(one.name) lies over \(other.name)") }
        }
        let made = bench.store.selection.compactMap { bench.store.node($0) }
        #expect(made.count == 3)
        #expect(Set(made.compactMap { $0.children.first { $0.name == "Title" }?.text }) == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(bench.store.doc.nodes.first { $0.id == a }?.children.first { $0.name == "Title" }?.text == "Tip 2")
        #expect(problems(bench.store.doc).isEmpty)
        bench.undoLast()
        #expect(bench.a.isDeck && bench.store.doc.nodes.filter(\.isArtboard).count == 2)
        #expect(front(bench) == posts[1])
    }

    // MARK: - Every post at once

    @Test func pressingTheFeetSpreadsThePostsAndAPressPicksOne() throws {
        let bench = stack()
        let posts = bench.a.posts
        let design = bench.store.doc
        let spread = try spreadOut(bench)
        #expect(spread.cards.count == 3)
        #expect(bench.store.selection == [bench.a.id])
        let card = try #require(spread.cards[posts[2]])
        bench.click(card)
        #expect(front(bench) == posts[2])
        frames(bench, 1.3)
        #expect(!bench.canvas.deckTool.spreading)
        #expect(bench.store.doc == design)
    }

    @Test func escapeLaysTheSpreadBackWithTheSamePostInFront() throws {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[1])
        _ = try spreadOut(bench)
        bench.key(53)
        frames(bench, 1.3)
        #expect(!bench.canvas.deckTool.spreading)
        #expect(front(bench) == posts[1])
    }

    @Test func aPostDraggedInTheSpreadGoesWhereItIsLetGo() throws {
        let bench = stack()
        let posts = bench.a.posts
        let spread = try spreadOut(bench)
        let places = try #require(bench.canvas.deckTool.spreadPlaces)
        let last = try #require(places.cards[posts[2]])
        let first = try #require(spread.cards[posts[0]])
        bench.drag(first, canvas(bench, CGPoint(x: last.maxX + 8, y: last.midY)))
        #expect(bench.a.posts == [posts[1], posts[2], posts[0]])
        #expect(words(bench) == ["Tip 2", "Tip 3", "Tip 1"])
        #expect(bench.canvas.deckTool.spreading)
        bench.undoLast()
        #expect(bench.a.posts == posts)
        // The cards follow what was undone.
        frames(bench, 0.4)
        #expect(bench.canvas.deckTool.spreading)
        bench.key(53)
        frames(bench, 1.3)
        #expect(!bench.canvas.deckTool.spreading)
    }

    @Test func theTrashOnACardThrowsThatPostAwayAndUndoDealsItBackIn() throws {
        let bench = stack()
        let posts = bench.a.posts
        let spread = try spreadOut(bench)
        let trash = try #require(spread.trash[posts[1]])
        bench.click(trash)
        #expect(bench.a.posts == [posts[0], posts[2]])
        #expect(bench.canvas.deckTool.spreading)
        frames(bench, 0.5)
        #expect(bench.canvas.deckTool.spreadPlaces?.cards.count == 2)
        // Undone with the posts still spread out, its card is among them again.
        bench.undoLast()
        #expect(bench.a.posts == posts)
        frames(bench, 0.6)
        #expect(bench.canvas.deckTool.spreadPlaces?.cards.count == 3)
        #expect(Set(bench.canvas.deckTool.spreadPlaces?.cards.keys.map { $0 } ?? []) == Set(posts))
    }

    @Test func thePlusCardInTheSpreadAddsACopyOfTheLastPost() throws {
        let bench = stack()
        let spread = try spreadOut(bench)
        let add = try #require(spread.add)
        bench.click(add)
        #expect(bench.a.posts.count == 4)
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3", "Tip 3"])
        frames(bench, 0.6)
        #expect(bench.canvas.deckTool.spreadPlaces?.cards.count == 4)
        #expect(problems(bench.store.doc).isEmpty)
    }

    @Test func throwingAwayAllButOneInTheSpreadLeavesAnArtboard() throws {
        let bench = stack(2)
        let posts = bench.a.posts
        let spread = try spreadOut(bench)
        let trash = try #require(spread.trash[posts[0]])
        bench.click(trash)
        #expect(!bench.a.isDeck)
        #expect(bench.node("Title")?.text == "Tip 2")
        frames(bench, 1.3)
        #expect(!bench.canvas.deckTool.spreading)
    }

    @Test func undoingTheStackAwayWhileItIsSpreadPutsTheSpreadAway() throws {
        let bench = plain()
        bench.step { bench.store.addPost(to: bench.a.id) }
        bench.store.selection = []
        _ = try spreadOut(bench)
        // The press that spread them is a step of its own here, with nothing in it.
        for _ in 0..<3 where bench.a.isDeck { bench.undoLast() }
        #expect(!bench.a.isDeck)
        frames(bench, 0.3)
        #expect(!bench.canvas.deckTool.spreading)
    }

    // MARK: - Drawing and exporting

    @Test func theCanvasShowsThePostInFrontAndTheHomeScreenTheFirst() throws {
        let bench = stack()
        let posts = bench.a.posts
        redBack(in: posts[1], bench)
        bench.store.turn(bench.a.id, to: posts[1])
        let seen = try #require(bench.store.seenDoc.node(bench.a.id))
        let shown = try #require(Renderer.image(of: seen, scale: 1))
        #expect(isRed(pixel(shown, 200, 250)))
        let alone = try #require(Renderer.image(of: bench.a, scale: 1))
        #expect(isWhite(pixel(alone, 200, 250)))
    }

    @Test func exportingAStackWritesAFileForEachPostAndThePostInFrontAlone() throws {
        let bench = stack()
        let posts = bench.a.posts
        redBack(in: posts[1], bench)
        let all = try folder()
        let urls = Exporter.export(ExportItem.items(for: bench.a), format: .png, scale: 1, name: "Design", to: all)
        #expect(urls.count == 3)
        #expect(urls.map(\.lastPathComponent).sorted() == urls.map(\.lastPathComponent))
        #expect(urls[1].lastPathComponent.contains("Tip 2"))
        let pictures = urls.compactMap(image(at:))
        #expect(pictures.count == 3)
        #expect(pictures.map { isRed(pixel($0, 200, 250)) } == [false, true, false])
        #expect(pictures.allSatisfy { $0.width == 400 && $0.height == 300 })
        // This post: the one in front, alone.
        bench.store.turn(bench.a.id, to: posts[1])
        let one = try folder()
        let made = Exporter.export(ExportItem.items(for: bench.a, post: front(bench)), format: .png, scale: 1, name: "Design", to: one)
        #expect(made.count == 1)
        #expect(made.first.flatMap(image(at:)).map { isRed(pixel($0, 200, 250)) } == true)
    }

    @Test func aLayerOfALaterPostExportsOverWhatLiesBehindItInThatPost() throws {
        let bench = stack()
        let posts = bench.a.posts
        redBack(in: posts[1], bench)
        bench.store.turn(bench.a.id, to: posts[1])
        var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 250, y: 200, width: 100, height: 100))
        glass.fill.on = false
        glass.blur = Blur(radius: 6, background: true)
        bench.step { bench.store.add(glass, onto: bench.a.id) }
        #expect(all("Glass", bench).count == 3)
        let item = try #require(ExportItem(layer: id("Glass", in: posts[1], bench), in: bench.store.doc))
        let picture = try #require(item.picture(scale: 1, opaque: true, assets: nil))
        #expect(isRed(pixel(picture.image, picture.image.width / 2, picture.image.height / 2)))
        // And the same in the first post shows its own white back.
        let first = try #require(ExportItem(layer: id("Glass", in: posts[0], bench), in: bench.store.doc))
        let white = try #require(first.picture(scale: 1, opaque: true, assets: nil))
        #expect(isWhite(pixel(white.image, white.image.width / 2, white.image.height / 2)))
    }

    @Test func anSVGOfAPostHoldsThatPostsWordsAlone() {
        let bench = stack()
        let items = ExportItem.items(for: bench.a)
        let svg = SVGWriter.document(for: items[1], bounds: items[1].node.frame, assets: nil)
        #expect(svg.contains("Tip 2"))
        #expect(!svg.contains("Tip 1") && !svg.contains("Tip 3"))
    }

    @Test func aStackMarkedForExportGoesOutAPostEach() {
        let bench = stack()
        bench.step { bench.store.update([bench.a.id], "Mark for Export") { $0.exports = [ExportPreset()] } }
        let marked = ExportItem.marked(in: bench.store.doc, seen: bench.store.seenDoc)
        #expect(marked.count == 3)
        #expect(Exporter.files(presetsOf: marked).count == 3)
        // A layer of a post marked goes out as it is in the post in front.
        let posts = bench.a.posts
        bench.step { bench.store.update([bench.a.id], "Mark for Export") { $0.exports = nil } }
        bench.step { bench.store.update([id("Badge", in: posts[0], bench)], "Mark for Export") { $0.exports = [ExportPreset()] } }
        bench.store.turn(bench.a.id, to: posts[2])
        let badges = ExportItem.marked(in: bench.store.doc, seen: bench.store.seenDoc)
        #expect(badges.map(\.node.id) == [id("Badge", in: posts[2], bench)])
    }

    // MARK: - Saving, pasting and sharing

    @Test func aStackIsSavedAndOpensAgainAsItWas() throws {
        let bench = stack()
        let posts = bench.a.posts
        redBack(in: posts[1], bench)
        bench.store.turn(bench.a.id, to: posts[2])
        let url = try folder().appendingPathComponent("Stack.bezzle")
        try DesignFile.write(bench.store.doc, to: url)
        let read = try DesignFile.read(url)
        #expect(read == bench.store.doc)
        #expect(read.nodes[0].posts == posts)
        #expect(read.nodes[0].layers(of: posts[1]).first?.own == ["fill"])
        // Which post was in front is this window's alone: opened again, the first is.
        let opened = DocumentStore(url: url, document: read)
        #expect(opened.front(of: read.nodes[0]) == posts[0])
    }

    @Test func aCopiedStackPastesAsAStackOfItsOwn() throws {
        let bench = stack()
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        bench.store.selection = [bench.a.id]
        bench.store.copySelection()
        bench.step { bench.store.paste() }
        let copy = try #require(bench.store.selection.first.flatMap { bench.store.node($0) })
        #expect(copy.id != bench.a.id)
        #expect(copy.isDeck && copy.posts == bench.a.posts)
        #expect(copy.posts.map { p in copy.layers(of: p).first { $0.name == "Title" }?.text } == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(problems(bench.store.doc).isEmpty)
        // Changed, it changes alone.
        let back = try #require(copy.layers(of: copy.posts[1]).first { $0.name == "Back" })
        bench.step { bench.store.update([back.id], "Round") { $0.cornerRadius = 30 } }
        #expect(all("Back", bench).allSatisfy { $0.cornerRadius == 0 })
        let after = try #require(bench.store.node(copy.id))
        #expect(after.posts.allSatisfy { p in after.layers(of: p).first { $0.name == "Back" }?.cornerRadius == 30 })
    }

    @Test func aLayerCopiedFromAPostPastesIntoEveryPostOrOntoAPlainArtboardAsAnyLayer() throws {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.canvasSize = CGSize(width: 1200, height: 800)
        bench.store.selection = [id("Badge", in: posts[1], bench)]
        bench.store.copySelection()
        bench.step { bench.store.paste() }
        for p in posts { #expect(bench.a.layers(of: p).filter { $0.name == "Badge" }.count == 2) }
        #expect(problems(bench.store.doc).isEmpty)
        // Onto B, it is a layer like any.
        bench.step { bench.store.edit("Move") { doc in
            if let n = doc.detach(bench.store.selection[0]) { doc.attach(n, to: bench.b.id) }
        } }
        #expect(bench.b.children.count == 1)
        #expect(problems(bench.store.doc).isEmpty)
        for p in posts { #expect(bench.a.layers(of: p).filter { $0.name == "Badge" }.count == 1) }
    }

    @Test func twoPeopleAddingAPostAtOnceBothGetTheirs() {
        let bench = stack()
        let deck = bench.a.id
        var one = Peer("one", doc: bench.store.doc)
        var two = Peer("two")
        two.receive(one.state)
        one.change { $0.addPost(to: deck) }
        two.change { $0.addPost(to: deck) }
        Peer.sync(&one, &two)
        #expect(one.doc == two.doc)
        let merged = one.doc.node(deck)
        #expect(merged?.posts.count == 5)
        #expect(problems(one.doc).isEmpty)
    }

    @Test func wordsTypedInAPostSomeoneElseRemovedComeBack() {
        let bench = stack()
        let deck = bench.a.id
        let posts = bench.a.posts
        let title = id("Title", in: posts[1], bench)
        var one = Peer("one", doc: bench.store.doc)
        var two = Peer("two")
        two.receive(one.state)
        one.change { $0.removePost(posts[1], from: deck) }
        two.change { $0.update([title], "Type") { $0.text = "Mine" } }
        Peer.sync(&one, &two)
        #expect(one.doc == two.doc)
        let merged = one.doc.node(deck)
        #expect(merged.map { Set($0.posts) } == Set(posts))
        #expect(merged?.layers(of: posts[1]).map(\.name) == ["Back", "Title", "Badge"])
        #expect(one.doc.node(title)?.text == "Mine")
        #expect(problems(one.doc).isEmpty)
    }

    @Test func aLayerAddedWhileSomeoneElseAddedAPostIsInEveryPost() {
        let bench = stack()
        let deck = bench.a.id
        var one = Peer("one", doc: bench.store.doc)
        var two = Peer("two")
        two.receive(one.state)
        one.change { $0.add(Node(kind: .ellipse, name: "Sticker", frame: CGRect(x: 120, y: 120, width: 30, height: 30)), onto: deck) }
        two.change { $0.addPost(to: deck) }
        Peer.sync(&one, &two)
        #expect(one.doc == two.doc)
        let merged = one.doc.node(deck)
        #expect(merged?.posts.count == 4)
        #expect(merged.map { m in m.posts.allSatisfy { m.layers(of: $0).contains { $0.name == "Sticker" } } } == true)
        #expect(problems(one.doc).isEmpty)
    }

    @Test func twoPeopleChangingDifferentPostsBothKeepTheirChange() {
        let bench = stack()
        let deck = bench.a.id
        let posts = bench.a.posts
        let title = id("Title", in: posts[0], bench), back = id("Back", in: posts[2], bench)
        var one = Peer("one", doc: bench.store.doc)
        var two = Peer("two")
        two.receive(one.state)
        one.change { $0.update([title], "Type") { $0.text = "One" } }
        two.change { $0.update([back], "Fill") { $0.fill.color = Self.red } }
        Peer.sync(&one, &two)
        let merged = one.doc.node(deck)
        #expect(merged.map { m in m.posts.compactMap { p in m.layers(of: p).first { $0.name == "Title" }?.text } } == ["One", "Tip 2", "Tip 3"])
        #expect(merged.map { m in m.posts.allSatisfy { p in m.layers(of: p).first { $0.name == "Back" }?.fill.color == Self.red } } == true)
        #expect(problems(one.doc).isEmpty)
    }

    // MARK: - The assistant

    private func call(_ bench: Bench, _ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        MCPTools.opened(bench.store)
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await MCPTools().call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func theAssistantFillsAStackWithLinesInOneStep() async {
        let bench = plain()
        let answer = await call(bench, "deck", ["layer": "A", "text_layer": "Title", "values": ["Hats", "Bags", "Shoes"]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.a.isDeck && words(bench) == ["Hats", "Bags", "Shoes"])
        #expect(problems(bench.store.doc).isEmpty)
        bench.undo.undo()
        #expect(!bench.a.isDeck && bench.a.children.map(\.name) == ["Back", "Title", "Badge"])
    }

    @Test func theAssistantAddsMovesRemovesAndShowsPosts() async {
        let bench = stack()
        var answer = await call(bench, "deck", ["layer": "A", "add": 1, "after": 1])
        #expect(!answer.failed, "\(answer.text)")
        #expect(words(bench) == ["Tip 1", "Tip 1", "Tip 2", "Tip 3"])
        answer = await call(bench, "deck", ["layer": "A", "move": ["1", "4"]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3", "Tip 1"])
        answer = await call(bench, "deck", ["layer": "A", "remove": 4])
        #expect(!answer.failed, "\(answer.text)")
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
        answer = await call(bench, "deck", ["layer": "A", "show": 2])
        #expect(front(bench) == bench.a.posts[1])
        answer = await call(bench, "deck", ["layer": "A", "post": 3])
        let listed = (json(answer.text)["layers"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(listed == bench.a.layers(of: bench.a.posts[2]).map(\.id.uuidString))
        #expect(problems(bench.store.doc).isEmpty)
        // Asked for something that is not there, it says so and changes nothing.
        let design = bench.store.doc
        answer = await call(bench, "deck", ["layer": "A", "remove": 9])
        #expect(answer.failed)
        #expect(bench.store.doc == design)
    }

    @Test func theAssistantChangingALayerOfAPostChangesItInEvery() async {
        let bench = stack()
        let posts = bench.a.posts
        let answer = await call(bench, "update_layers", ["updates": [["layer": id("Back", in: posts[1], bench).uuidString, "fill": "#FF0000"]]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(all("Back", bench).allSatisfy { $0.fill.color == Self.red })
        #expect(words(bench) == ["Tip 1", "Tip 2", "Tip 3"])
    }

    @Test func theAssistantIsToldWhatEveryPostSays() async {
        let bench = stack()
        let answer = await call(bench, "get_layers", ["layers": ["A"]])
        let deck = (json(answer.text)["layers"] as? [[String: Any]])?.first?["deck"] as? [String: Any]
        #expect(deck?["posts"] as? Int == 3)
        #expect((deck?["postTexts"] as? [String: Any])?["Title"] as? [String] == ["Tip 1", "Tip 2", "Tip 3"])
        // A name in a stack is the layer in its first post.
        let title = await call(bench, "get_layers", ["layers": ["Title"]])
        #expect(!title.failed, "\(title.text)")
        #expect((json(title.text)["layers"] as? [[String: Any]])?.first?["text"] as? String == "Tip 1")
    }

    @Test func theAssistantUnstacksIntoArtboardsClearOfTheRest() async {
        let bench = stack()
        let answer = await call(bench, "deck", ["layer": "A", "unstack": "artboards"])
        #expect(!answer.failed, "\(answer.text)")
        let boards = bench.store.doc.nodes.filter(\.isArtboard)
        #expect(boards.count == 4)
        for (i, one) in boards.enumerated() {
            for other in boards[(i + 1)...] { #expect(!one.frame.intersects(other.frame), "\(one.name) lies over \(other.name)") }
        }
    }

    @Test func undoingAPostTheAssistantAddedShowsThePostThatWasInFront() async {
        let bench = stack()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[2])
        bench.store.selection = []
        _ = await call(bench, "deck", ["layer": "A", "add": 1])
        #expect(bench.a.posts.count == 4)
        #expect(front(bench) == bench.a.posts[3])
        bench.undo.undo()
        #expect(bench.a.posts == posts)
        #expect(front(bench) == posts[2])
    }
}

/// One person's copy of a shared design, kept as `Collaboration` keeps it but without iCloud, as
/// `SharingTests` has it: what it shows, and the shared design it sends and takes in.
@MainActor
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

    /// Takes in what was changed here, as saving does.
    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    /// Changes the design as this person's window would, then takes the change in.
    mutating func change(_ body: (DocumentStore) -> Void) {
        let store = DocumentStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("Peer-\(UUID().uuidString).bezzle"), document: doc)
        body(store)
        doc = store.doc
        commit()
    }

    /// Takes in another person's copy and shows it, as `Collaboration.receive` does.
    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }

    /// Both take in each other's copy until nothing changes any more.
    static func sync(_ one: inout Peer, _ two: inout Peer) {
        for _ in 0..<4 {
            one.receive(two.state)
            two.receive(one.state)
        }
    }
}
