import Testing
import AppKit
@testable import Bezzle

/// Decks: one artboard that is many posts lying one behind another, every post changing with any
/// other, but for the words and pictures each holds and anything it keeps as its own.
@MainActor
struct DeckTests {
    /// Artboard A with a 400 × 300 rectangle "Back" behind a text "Title" saying "Tip 1".
    private func bench() -> Bench {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        back.fill.color = RGBA(r: 1, g: 1, b: 1)
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        title.text = "Tip 1"
        title.style?.size = 24
        title.refit()
        return Bench(extra: [back, title])
    }

    /// A deck of three posts made from A, with "Tip 1", "Tip 2" and "Tip 3"; the first in front.
    private func deck() -> Bench {
        let bench = bench()
        let a = bench.a.id
        bench.step { bench.store.addPost(to: a) }
        bench.step { bench.store.addPost(to: a) }
        let posts = bench.a.posts
        for (i, p) in posts.enumerated() {
            let title = layer("Title", in: p, bench)!
            bench.step { bench.store.update([title.id], "Type") { $0.text = "Tip \(i + 1)" } }
        }
        bench.store.turn(a, to: posts[0])
        return bench
    }

    private func layer(_ name: String, in post: Int?, _ bench: Bench) -> Node? {
        bench.a.layers(of: post).first { $0.name == name }
    }

    /// The layer named so in every post, in their order.
    private func all(_ name: String, _ bench: Bench) -> [Node] {
        bench.a.posts.compactMap { layer(name, in: $0, bench) }
    }

    @Test func anArtboardBecomesADeckOfTwoPosts() {
        let bench = bench()
        let a = bench.a.id
        let title = bench.node("Title")!.id
        bench.store.selection = [title]
        bench.step { bench.store.addPost(to: a) }
        let deck = bench.a
        #expect(deck.isDeck && deck.posts.count == 2)
        // The layers it had are its first post still, and the new post is in front.
        #expect(deck.layers(of: deck.posts[0]).map(\.id).contains(title))
        #expect(bench.store.front(of: deck) == deck.posts[1])
        // What was selected is selected in the post in front.
        #expect(bench.store.selection == [title.mixed(Deck.key(from: deck.posts[0], to: deck.posts[1]))])
        // The design lies behind, and nobody sees it.
        #expect(deck.layers(of: nil).map(\.name) == ["Back", "Title"])
        #expect(bench.store.seenLayers(of: deck).map(\.id) == deck.layers(of: deck.posts[1]).map(\.id))
        #expect(bench.store.seenDoc.nodes[0].children.count == 2)
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Tip 1"])
        // Undone, it is the artboard it was.
        bench.undo.undo()
        #expect(!bench.a.isDeck && bench.a.children.map(\.id).contains(title))
    }

    @Test func aChangeInAnyPostIsAChangeInAll() {
        let bench = deck()
        let second = all("Back", bench)[1]
        bench.step { bench.store.update([second.id], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0); $0.cornerRadius = 12 } }
        #expect(all("Back", bench).allSatisfy { $0.fill.color == RGBA(r: 1, g: 0, b: 0) && $0.cornerRadius == 12 })
        #expect(layer("Back", in: nil, bench)?.cornerRadius == 12)
        // Moved in the third, it moves in every post.
        let third = all("Title", bench)[2]
        bench.step { bench.store.update([third.id], "Move") { $0.frame.origin = CGPoint(x: 50, y: 200) } }
        #expect(all("Title", bench).allSatisfy { $0.frame.origin == CGPoint(x: 50, y: 200) })
        // The words stayed each post's own.
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Tip 2", "Tip 3"])
    }

    @Test func aLayerPutOnADeckIsInEveryPost() {
        let bench = deck()
        let posts = bench.a.posts
        bench.store.turn(bench.a.id, to: posts[1])
        let badge = Node(kind: .ellipse, name: "Badge", frame: CGRect(x: 300, y: 20, width: 40, height: 40))
        bench.step { bench.store.add(badge, onto: bench.a.id) }
        // It is in the post in front with the id it was given, and in every other post too.
        #expect(layer("Badge", in: posts[1], bench)?.id == badge.id)
        #expect(all("Badge", bench).count == 3)
        #expect(layer("Badge", in: nil, bench) != nil)
        // Taken away in one, it goes from all.
        let first = all("Badge", bench)[0]
        bench.step { bench.store.edit("Delete") { _ = $0.detach(first.id) } }
        #expect(all("Badge", bench).isEmpty && layer("Badge", in: nil, bench) == nil)
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Tip 2", "Tip 3"])
    }

    @Test func aPostKeepsWhatItWasToldToKeep() {
        let bench = deck()
        let second = all("Back", bench)[1]
        bench.step { bench.store.update([second.id], "Keep") { $0.fill.color = RGBA(r: 0, g: 0, b: 1); $0.own = ["fill"] } }
        // Kept, it is that post's alone.
        #expect(all("Back", bench).map(\.fill.color) == [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0, g: 0, b: 1), RGBA(r: 1, g: 1, b: 1)])
        // A change to the same thing in another post goes everywhere else.
        let third = all("Back", bench)[2]
        bench.step { bench.store.update([third.id], "Fill") { $0.fill.color = RGBA(r: 0, g: 1, b: 0) } }
        #expect(all("Back", bench).map(\.fill.color) == [RGBA(r: 0, g: 1, b: 0), RGBA(r: 0, g: 0, b: 1), RGBA(r: 0, g: 1, b: 0)])
        // What it does not keep still follows the others.
        bench.step { bench.store.update([third.id], "Round") { $0.cornerRadius = 8 } }
        #expect(all("Back", bench).allSatisfy { $0.cornerRadius == 8 })
    }

    @Test func postsAreTakenAwayAndMovedWithoutTouchingTheOthers() {
        let bench = deck()
        let a = bench.a.id
        let posts = bench.a.posts
        let ids = bench.a.children.filter { $0.post == posts[2] }.map(\.id)
        bench.store.turn(a, to: posts[1])
        bench.step { bench.store.removePost(posts[1], from: a) }
        #expect(bench.a.posts == [posts[0], posts[2]])
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Tip 3"])
        // The one after it came to the front, and the last post's layers are as they were.
        #expect(bench.store.front(of: bench.a) == posts[2])
        #expect(bench.a.children.filter { $0.post == posts[2] }.map(\.id) == ids)
        bench.step { bench.store.movePost(posts[2], in: a, to: 0) }
        #expect(all("Title", bench).map(\.text) == ["Tip 3", "Tip 1"])
        #expect(bench.a.children.filter { $0.post == posts[2] }.map(\.id) == ids)
    }

    @Test func turningKeepsTheSameLayerSelected() {
        let bench = deck()
        let a = bench.a.id
        let posts = bench.a.posts
        let first = all("Title", bench)[0]
        bench.store.selection = [first.id, a]
        bench.store.turn(a, to: posts[2])
        #expect(bench.store.selection == [all("Title", bench)[2].id, a])
        bench.store.turnPage(by: -1)
        #expect(bench.store.front(of: bench.a) == posts[1])
        bench.store.turnPage(by: 5)
        #expect(bench.store.front(of: bench.a) == posts[2])
        #expect(bench.store.place(in: bench.a) == (2, 3))
    }

    @Test func linesSpreadOverPostsAndMakeMore() {
        let bench = bench()
        let title = bench.node("Title")!.id
        bench.step { bench.store.spread(["Hats", "Bags", "Shoes", "Belts"], from: title) }
        #expect(bench.a.isDeck && bench.a.posts.count == 4)
        #expect(all("Title", bench).map(\.text) == ["Hats", "Bags", "Shoes", "Belts"])
        // The text keeps its id in its own post.
        #expect(layer("Title", in: bench.a.posts[0], bench)?.id == title)
        // From the third on, over what is there and one more.
        let third = all("Title", bench)[2].id
        bench.step { bench.store.spread(["Caps", "Socks", "Ties"], from: third) }
        #expect(all("Title", bench).map(\.text) == ["Hats", "Bags", "Caps", "Socks", "Ties"])
    }

    @Test func aDeckIsDrawnAndExportedAPostAtATime() {
        let bench = deck()
        let deck = bench.a
        #expect(deck.shownAlone.children.map(\.id) == deck.layers(of: deck.posts[0]).map(\.id))
        let items = ExportItem.items(for: deck)
        #expect(items.count == 3)
        #expect(items.map(\.name) == ["A 01 Tip 1", "A 02 Tip 2", "A 03 Tip 3"])
        #expect(items.allSatisfy { $0.node.children.count == 2 })
    }

    @Test func aDuplicatedDeckStaysADeck() {
        let bench = deck()
        bench.store.selection = [bench.a.id]
        bench.step { bench.store.duplicateSelection() }
        let copy = bench.store.selection[0]
        let board = bench.store.node(copy)!
        #expect(board.isDeck && board.posts == bench.a.posts)
        #expect(Set(board.allIDs).isDisjoint(with: Set(bench.a.allIDs)))
        // Its posts still follow the design behind them.
        let back = board.layers(of: board.posts[1]).first { $0.name == "Back" }!
        bench.step { bench.store.update([back.id], "Round") { $0.cornerRadius = 30 } }
        let after = bench.store.node(copy)!
        #expect(after.posts.allSatisfy { p in after.layers(of: p).first { $0.name == "Back" }?.cornerRadius == 30 })
        #expect(after.posts.map { p in after.layers(of: p).first { $0.name == "Title" }?.text } == ["Tip 1", "Tip 2", "Tip 3"])
        #expect(all("Back", bench).allSatisfy { $0.cornerRadius == 0 })
    }

    @Test func aDeckPutTogetherFromChangesHasAllItsPosts() {
        let bench = deck()
        let a = bench.a.id
        let posts = bench.a.posts
        // As if the change that made the last post's text had not come yet.
        var flat = FlatDesign(bench.store.doc)
        let missing = all("Title", bench)[2].id
        flat.entries[missing] = nil
        flat.order[a]?.removeAll { $0 == missing }
        let built = flat.document()
        let board = built.node(a)!
        #expect(board.layers(of: posts[2]).map(\.name) == ["Back", "Title"])
        #expect(board.children.count == bench.a.children.count)
        // A design that is whole comes back the same.
        #expect(FlatDesign(bench.store.doc).document().nodes == bench.store.doc.nodes)
    }

    @Test func aLayerTakenOffADeckForgetsIt() {
        let bench = deck()
        let first = all("Title", bench)[1]
        bench.step { bench.store.update([first.id], "Keep") { $0.own = ["style"] } }
        let b = bench.b.id
        bench.step {
            bench.store.edit("Move") { doc in
                if let n = doc.detach(first.id) { doc.attach(n, to: b) }
            }
        }
        let moved = bench.store.node(first.id)!
        #expect(moved.post == nil && moved.own == nil)
        #expect(bench.store.doc.artboard(of: moved.id)?.id == b)
        // Taken out of one post, it went from them all.
        #expect(all("Title", bench).isEmpty)
    }

    @Test func keepingOnlyThePostInFront() {
        let bench = deck()
        let a = bench.a.id
        let posts = bench.a.posts
        bench.store.turn(a, to: posts[1])
        let kept = bench.a.layers(of: posts[1]).map(\.id)
        bench.step { bench.store.unstack(a) }
        #expect(!bench.a.isDeck)
        #expect(bench.a.children.map(\.id) == kept)
        #expect(bench.a.children.allSatisfy { $0.post == nil })
        #expect(bench.node("Title")?.text == "Tip 2")
    }
}

@MainActor
struct DeckOfferTests {
    /// A deck of three posts, "Tip 1" to "Tip 3", as `DeckTests` makes it, the first in front.
    private func deck() -> Bench {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        back.fill.color = RGBA(r: 1, g: 1, b: 1)
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        title.text = "Tip"
        title.style?.size = 24
        title.refit()
        let bench = Bench(extra: [back, title])
        bench.step { bench.store.spread(["Tip 1", "Tip 2", "Tip 3"], from: title.id) }
        bench.store.turn(bench.a.id, to: bench.a.posts[0])
        return bench
    }

    private func all(_ name: String, _ bench: Bench) -> [Node] {
        bench.a.posts.compactMap { p in bench.a.layers(of: p).first { $0.name == name } }
    }

    @Test func aChangeToAllCanBeKeptInOnePost() {
        let bench = deck()
        bench.store.turn(bench.a.id, to: bench.a.posts[1])
        let back = all("Back", bench)[1]
        bench.store.selection = [back.id]
        bench.step { bench.store.updateSelection("Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        #expect(all("Back", bench).allSatisfy { $0.fill.color == RGBA(r: 1, g: 0, b: 0) })
        let offer = try! #require(bench.store.offer)
        guard case .justHere = offer.kind else { Issue.record("offered \(offer.words)"); return }
        #expect(offer.words == "All 3 posts" && offer.button == "Only This One")
        bench.step { bench.store.take(offer) }
        #expect(all("Back", bench).map(\.fill.color) == [RGBA(r: 1, g: 1, b: 1), RGBA(r: 1, g: 0, b: 0), RGBA(r: 1, g: 1, b: 1)])
        #expect(all("Back", bench)[1].own == ["fill"])
        // Following the design again, it is as the others are.
        bench.step { bench.store.followDesign([back.id]) }
        #expect(all("Back", bench).allSatisfy { $0.fill.color == RGBA(r: 1, g: 1, b: 1) && $0.own == nil })
    }

    @Test func wordsInOnePostCanGoToAll() {
        let bench = deck()
        let title = all("Title", bench)[0]
        bench.store.selection = [title.id]
        bench.step { bench.store.updateSelection("Type") { $0.text = "Same everywhere" } }
        // Words are each post's own: nothing is offered for them.
        #expect(bench.store.offer == nil)
        bench.step { bench.store.giveEveryPost([title.id]) }
        #expect(all("Title", bench).allSatisfy { $0.text == "Same everywhere" })
    }

    @Test func postsAChangeBrokeAreKnown() {
        let bench = deck()
        let title = all("Title", bench)[2]
        bench.step { bench.store.update([title.id], "Type") { $0.text = "A headline far too long to fit on this post at all" } }
        #expect(bench.store.brokenPosts(of: bench.a) == [bench.a.posts[2]])
    }

    @Test func tabTypesOnInTheNextPost() {
        let bench = deck()
        let first = all("Title", bench)[0]
        bench.store.selection = [first.id]
        bench.canvas.beginEditing(first.id, action: "Typing")
        let editor = try! #require(bench.editor)
        bench.step { _ = bench.canvas.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))) }
        #expect(bench.store.front(of: bench.a) == bench.a.posts[1])
        #expect(bench.store.editingText == all("Title", bench)[1].id)
        let second = try! #require(bench.editor)
        second.insertText("Two", replacementRange: NSRange(location: 0, length: second.string.utf16.count))
        bench.step { _ = bench.canvas.textView(second, doCommandBy: #selector(NSResponder.insertTab(_:))) }
        let third = try! #require(bench.editor)
        bench.step { _ = bench.canvas.textView(third, doCommandBy: #selector(NSResponder.insertTab(_:))) }
        // Past the last post, a new one, a copy of the one before.
        #expect(bench.a.posts.count == 4)
        #expect(bench.store.front(of: bench.a) == bench.a.posts[3])
        let fourth = try! #require(bench.editor)
        fourth.insertText("Four", replacementRange: NSRange(location: 0, length: fourth.string.utf16.count))
        bench.step { bench.canvas.endEditing() }
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Two", "Tip 3", "Four"])
    }

    @Test func onePostGoesOutAlone() {
        let bench = deck()
        let items = ExportItem.items(for: bench.a, post: bench.a.posts[1])
        #expect(items.map(\.name) == ["A 02 Tip 2"])
        #expect(items[0].node.children.map(\.id) == bench.a.layers(of: bench.a.posts[1]).map(\.id))
    }

    @Test func linesDroppedOnATextArePosts() {
        let bench = deck()
        let second = all("Title", bench)[1].id
        let dropped = Dropped(text: "Bags\nShoes\nBelts")
        guard case .postWords(_, let count)? = bench.store.plan(for: dropped, at: .zero, on: second) else {
            Issue.record("no plan")
            return
        }
        #expect(count == 3)
        bench.step { bench.store.drop(dropped, at: .zero, on: second) }
        #expect(all("Title", bench).map(\.text) == ["Tip 1", "Bags", "Shoes", "Belts"])
        // A table's columns go to the text layers of their names.
        bench.step { bench.store.drop(Dropped(text: "title,other\nA,x\nB,y\n"), at: .zero, on: all("Title", bench)[0].id) }
        #expect(all("Title", bench).map(\.text) == ["A", "B", "Shoes", "Belts"])
    }
}

private extension Node {
    var allIDs: [UUID] { [id] + children.flatMap(\.allIDs) }
}
