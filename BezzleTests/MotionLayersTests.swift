import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// A film through everything else that handles layers: copied, pasted, duplicated, deleted and
/// brought back, grouped, put elsewhere, made a component, a repeat grid, a deck, a mask, a path
/// or shapes, cut, combined, laid out again on a resized artboard. Each either takes the motion
/// with it or leaves it behind for a reason these tests name.
@MainActor
struct MotionLayersTests {
    /// On artboard A (at 100,100, 400 by 300), which has a film and a camera: a moving card top
    /// left, a moving group of a moving badge and a title that stays, and a dot that stays.
    let bench: Bench
    var store: DocumentStore { bench.store }

    /// The motion a moving layer here has.
    static let moves = Filmed.moves

    init() {
        bench = Bench(extra: Filmed.design().nodes[0].children)
        let board = bench.a.id
        let store = bench.store
        bench.step { store.edit("Add Key") { $0.update(board) { $0 = Filmed.filmed($0) } } }
    }

    private func id(_ name: String) -> UUID { bench.node(name)!.id }

    private func named(_ name: String) -> [Node] { store.doc.allNodes.filter { $0.name == name } }

    /// A change to the design made behind the scenes, as its own step.
    private func edit(_ change: (inout BezzleDocument) -> Void) {
        bench.step { store.edit("Add Key", change) }
    }

    /// The layers as the clipboard carries them: written and read again.
    private func clip(_ ids: [UUID], from store: DocumentStore) throws -> LayerClip {
        let copied = try #require(store.doc.clip(of: ids, designName: store.name))
        return try JSONDecoder().decode(LayerClip.self, from: JSONEncoder().encode(copied.clip))
    }

    private func paste(_ clip: LayerClip, into bench: Bench, onto board: UUID? = nil) -> [UUID] {
        var pasted: [UUID] = []
        let store = bench.store
        bench.step { store.edit("Paste") { pasted = $0.paste(clip, designName: store.name, visible: store.visibleCanvasRect, focused: board) } }
        return pasted
    }

    // MARK: Copies

    @Test func aPastedLayerMovesAsTheOneItWasCopiedFrom() throws {
        let card = id("Card"), group = id("Group")
        let copied = try clip([card, group], from: store)
        let pasted = paste(copied, into: bench)
        #expect(pasted.count == 2 && Set(pasted).isDisjoint(with: [card, group]))
        let newCard = try #require(store.node(pasted[0])), newGroup = try #require(store.node(pasted[1]))
        #expect(newCard.motion == Self.moves && newGroup.motion == Self.moves)
        #expect(newGroup.children.map(\.motion) == [Self.moves, nil])
        #expect(store.node(card)?.motion == Self.moves)
        // Its keys say how far from where it is designed: the copy rises into its own place.
        #expect(newCard.frame != store.node(card)?.frame && newCard.pose(at: 0).move == CGPoint(x: 0, y: 40))
        bench.undoLast()
        #expect(named("Card").count == 1)

        // A whole artboard: its film and its camera come along.
        let board = bench.a
        let again = try #require(paste(try clip([board.id], from: store), into: bench).first)
        let second = try #require(store.node(again))
        #expect(second.isArtboard && second.id != board.id)
        #expect(second.film == board.film && second.motion == board.motion)
        #expect(second.children.map(\.atRest.name) == board.children.map(\.name))
        #expect(second.children.map(\.motion) == board.children.map(\.motion))
        #expect(second.filmLength == 3 && second.camera(at: 2) == board.camera(at: 2))

        // Into another design.
        let other = Bench()
        let there = paste(copied, into: other, onto: other.a.id)
        #expect(other.store.node(there[0])?.motion == Self.moves)
        #expect(other.store.node(there[1])?.children.map(\.motion) == [Self.moves, nil])
        #expect(!other.a.children.isEmpty && other.a.hasFilm)
    }

    @Test func aDuplicateAndACopyDraggedOffMoveAsTheirOriginal() throws {
        let card = id("Card"), group = id("Group")
        store.selection = [card]
        bench.step { store.duplicateSelection() }
        let copy = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(copy.id != card && copy.motion == Self.moves)
        #expect(copy.frame == CGRect(x: 50, y: 50, width: 120, height: 80))
        #expect(store.node(card)?.motion == Self.moves)
        bench.undoLast()
        #expect(named("Card").count == 1)

        // With Option held, a copy is dragged off the card, whose middle is at 200, 180 on the canvas.
        bench.drag(CGPoint(x: 200, y: 180), CGPoint(x: 230, y: 290), flags: [.option, .command])
        let both = named("Card")
        #expect(both.count == 2 && both.allSatisfy { $0.motion == Self.moves })
        #expect(Set(both.map(\.frame.minY)) == [40, 150])
        bench.undoLast()

        // A group with what it holds.
        store.selection = [group]
        bench.step { store.duplicateSelection() }
        let twin = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(twin.id != group && twin.motion == Self.moves && twin.children.map(\.motion) == [Self.moves, nil])
        #expect(Set(twin.children.map(\.id)).isDisjoint(with: store.node(group)!.children.map(\.id)))
        bench.undoLast()

        // An artboard, with its film and its camera.
        let board = bench.a
        store.selection = [board.id]
        bench.step { store.duplicateSelection() }
        let second = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(second.isArtboard && second.id != board.id && second.frame.minX == 580)
        #expect(second.film == board.film && second.motion == board.motion)
        #expect(second.children.map(\.motion) == board.children.map(\.motion))
        #expect(second.atRest.children.map(\.frame) == board.atRest.children.map(\.frame))
        bench.undoLast()
        #expect(store.doc.nodes.count == 2)
    }

    @Test func aDeletedLayerComesBackWithItsMotionWhenUndone() throws {
        let card = try #require(bench.node("Card")), group = try #require(bench.node("Group"))
        store.selection = [card.id, group.id]
        bench.step { store.deleteSelection() }
        #expect(bench.node("Card") == nil && bench.node("Badge") == nil)
        // Nothing on the artboard moves now but its camera, whose last key is at two seconds.
        #expect(!bench.a.holdsMotion && bench.a.hasFilm && bench.a.lastKey == 2)
        bench.undoLast()
        #expect(bench.node("Card") == card && bench.node("Group") == group)
        bench.undo.redo()
        #expect(bench.node("Card") == nil)
        bench.undo.undo()
        #expect(bench.node("Card") == card)

        // The artboard itself, with its film.
        let board = bench.a
        store.selection = [board.id]
        bench.step { store.deleteSelection() }
        #expect(store.doc.nodes.map(\.name) == ["B"])
        bench.undoLast()
        #expect(bench.a == board)

        // Cut and pasted, a layer is the one that was cut.
        let cut = try clip([card.id], from: store)
        store.selection = [card.id]
        bench.step { store.edit("Cut") { _ = $0.detach(card.id) } }
        #expect(bench.node("Card") == nil)
        let pasted = paste(cut, into: bench)
        #expect(store.node(pasted[0])?.motion == card.motion && store.node(pasted[0])?.frame == card.frame)
    }

    // MARK: Where a layer lies

    @Test func groupedLayersKeepTheirMotionAndAGroupTakenApartTakesItsOwnWithIt() throws {
        let card = id("Card"), dot = id("Dot")
        store.selection = [card, dot]
        bench.step { store.group() }
        let made = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(made.isGroup && made.motion == nil && made.holdsMotion)
        #expect(made.children.first { $0.id == card }?.motion == Self.moves)
        #expect(made.children.first { $0.id == dot }?.motion == nil)
        // In the film the card is still a piece of its own, taken out of the group that holds it.
        #expect(bench.a.filmPieces().contains { $0.kind == .layer && $0.layers == [card] && $0.holders == [made.id] })
        bench.step { store.ungroup() }
        #expect(store.node(card)?.motion == Self.moves && store.node(card)?.frame == CGRect(x: 40, y: 40, width: 120, height: 80))
        #expect(store.node(made.id) == nil)

        // A group that moves as a whole, taken apart: no group is left to move, and what it held
        // keeps what was its own, no more.
        let group = try #require(bench.node("Group"))
        store.selection = [group.id]
        bench.step { store.ungroup() }
        #expect(bench.node("Group") == nil)
        #expect(bench.node("Badge")?.motion == Self.moves && bench.node("Title")?.motion == nil)
        bench.undoLast()
        #expect(bench.node("Group") == group)
    }

    @Test func aLayerKeepsItsMotionWhereverItIsPutAndWhateverItIsCalled() throws {
        let card = id("Card")
        store.selection = [card]
        bench.step { store.arrange(.front) }
        #expect(bench.a.children.last?.id == card && store.node(card)?.motion == Self.moves)
        bench.step { store.arrange(.back) }
        #expect(bench.a.children.first?.id == card && store.node(card)?.motion == Self.moves)
        bench.step { store.renameLayer(card, to: "Hero") }
        bench.step { store.setLocked(true, [card]) }
        bench.step { store.setHidden(true, [card]) }
        #expect(store.node(card)?.name == "Hero" && store.node(card)?.hidden == true && store.node(card)?.motion == Self.moves)
        bench.step { store.setHidden(false, [card]) }
        bench.step { store.setLocked(false, [card]) }
        // Moved, resized and turned as designed, its keys are what they were: they are measured from the design.
        store.selection = [card]
        bench.step { store.nudge(dx: 5, dy: -5) }
        bench.step { store.update([card], "Resize") { $0.frame.size = CGSize(width: 150, height: 60); $0.rotation = 20 } }
        bench.step { store.flip(horizontally: true) }
        #expect(store.node(card)?.motion == Self.moves)
        bench.step { store.update([card], "Resize") { $0.frame = CGRect(x: 40, y: 40, width: 120, height: 80); $0.rotation = 0 } }

        // Dragged across the canvas onto the other artboard: that one has a film now, of its own length.
        bench.drag(CGPoint(x: 200, y: 180), CGPoint(x: 800, y: 250), flags: [.command])
        #expect(bench.b.children.map(\.id) == [card] && store.node(card)?.motion == Self.moves)
        #expect(bench.b.hasFilm && bench.b.film == nil && bench.b.filmLength == 2 && !bench.b.hasCamera)
        #expect(!bench.a.children.contains { $0.id == card } && bench.a.filmLength == 3)
        // And back.
        bench.drag(CGPoint(x: 800, y: 250), CGPoint(x: 300, y: 320), flags: [.command])
        #expect(bench.a.children.contains { $0.id == card } && store.node(card)?.motion == Self.moves)
        #expect(!bench.b.hasFilm)
        // Put onto the other artboard in the layers list, where it stays where it lies on the canvas.
        bench.step { store.move(card, to: bench.b.id, at: 0) }
        #expect(bench.b.children.map(\.id) == [card] && store.node(card)?.motion == Self.moves)
        bench.undoLast()
        // And off every artboard, where no film shows it, it keeps its keys for when it comes back.
        bench.drag(CGPoint(x: 300, y: 320), CGPoint(x: 300, y: 600), flags: [.command])
        #expect(store.doc.artboard(of: card) == nil && store.node(card)?.motion == Self.moves)
    }

    // MARK: Components

    @Test func aComponentMadeOfAMovingLayerKeepsItMovingAndACopysMotionIsItsOwn() throws {
        let card = try #require(bench.node("Card")), dot = try #require(bench.node("Dot"))
        store.selection = [card.id, dot.id]
        bench.step { store.makeComponent() }
        let first = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(first.isCopy && first.children.map(\.name) == ["Card", "Dot"])
        #expect(first.children.map(\.motion) == [Self.moves, nil] && first.motion == nil)
        bench.undoLast()
        #expect(bench.node("Card") == card && store.doc.masters.isEmpty)
        bench.undo.redo()

        // A copy placed now starts moving as the component was made.
        let master = try #require(store.doc.masters.first)
        var placed: UUID?
        bench.step { placed = store.placeCopy(of: master.id, at: CGPoint(x: 350, y: 350)) }
        let second = try #require(placed.flatMap { store.node($0) })
        #expect(second.isCopy && second.id != first.id && second.children.map(\.motion) == [Self.moves, nil])

        // Changed in one copy, it is as it was in the other.
        let inFirst = first.children[0].id, inSecond = second.children[0].id
        edit { $0.update(inFirst) { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        #expect(store.node(inFirst)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(store.node(inSecond)?.motion == Self.moves)
        // What is the component's reaches every copy, and each still moves in its own way.
        let green = RGBA(r: 0, g: 1, b: 0)
        bench.step { store.update([inFirst], "Fill") { $0.fill.color = green } }
        #expect(store.node(inSecond)?.fill.color == green)
        #expect(store.node(inSecond)?.motion == Self.moves)
        #expect(store.node(inFirst)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        // A copy posed as a whole: its own as well.
        edit { $0.update(first.id) { $0.pose(.turn, [20], at: 1) } }
        #expect(store.node(first.id)?[track: .turn]?.keys.count == 2 && store.node(second.id)?.motion == nil)
        // Taken away in one copy, the other still has it.
        edit { $0.clearMotion([second.id]) }
        #expect(store.node(inSecond)?.motion == nil && store.node(inFirst)?[track: .move] != nil)
        bench.undoLast()

        // A copy duplicated takes its own motion along, as a whole and in what it holds.
        store.selection = [first.id]
        bench.step { store.duplicateSelection() }
        let third = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(third.isCopy && third.id != first.id)
        #expect(third[track: .turn] == store.node(first.id)?[track: .turn])
        #expect(third.children[0][track: .move]?.keys.map(\.t) == [0, 1.6])

        // Pasted into another design, the component comes with it, and the copy moves as it did here.
        let other = Bench()
        let there = paste(try clip([first.id], from: store), into: other, onto: other.a.id)
        let pasted = try #require(other.store.node(there[0]))
        #expect(other.store.doc.masters.map(\.id) == [master.id] && pasted.isCopy)
        #expect(pasted[track: .turn]?.keys.count == 2 && pasted.children[0][track: .move]?.keys.map(\.t) == [0, 1.6])
        // The component brought up to date from the design it came from: the copy's motion stays its own.
        var newer = try #require(store.doc.masters.first)
        newer.children[0].fill.color = RGBA(r: 0, g: 0, b: 1)
        newer.children[0].motion = nil
        let library = LibraryContent(url: store.url, name: store.name, modified: Date(), masters: [newer], styles: [])
        other.step { other.store.edit("Update") { $0.update(from: library, masters: [master.id], styles: []) } }
        let updated = try #require(other.store.node(there[0]))
        #expect(updated.children[0].fill.color == RGBA(r: 0, g: 0, b: 1))
        #expect(updated[track: .turn]?.keys.count == 2 && updated.children[0][track: .move]?.keys.map(\.t) == [0, 1.6])

        // Reset to its component's looks, and unlinked from it: a group like any other, moving as it did.
        edit { $0.resetCopy(first.id) }
        #expect(store.node(first.id)?[track: .turn]?.keys.count == 2)
        bench.step { store.unlinkComponent([first.id]) }
        let loose = try #require(store.node(first.id))
        #expect(!loose.isCopy && loose[track: .turn]?.keys.count == 2)
        #expect(loose.children[0][track: .move]?.keys.map(\.t) == [0, 1.6])
        // The component taken out of the design: the copies stay, and move.
        bench.step { store.deleteComponent(master.id) }
        #expect(store.node(third.id)?.children.first?[track: .move]?.keys.map(\.t) == [0, 1.6])
    }

    /// Found on the way, and nothing to do with a film: such a change was taken for the copy
    /// flipped and thrown away (`Components.flipped`), until a flip was told by what it turns over.
    @Test
    func aLookChangedInACopyOfOneLayerReachesItsComponent() throws {
        let card = try #require(bench.node("Card"))
        store.selection = [card.id]
        bench.step { store.makeComponent() }
        let copy = try #require(store.selection.first.flatMap { store.node($0) })
        let green = RGBA(r: 0, g: 1, b: 0)
        bench.step { store.update([copy.children[0].id], "Fill") { $0.fill.color = green } }
        #expect(store.node(copy.children[0].id)?.fill.color == green)
        #expect(store.doc.masters.first?.children.first?.fill.color == green)
        #expect(store.node(copy.id)?.instance?.flipX == nil)
        #expect(store.node(copy.children[0].id)?.motion == Self.moves)
    }

    @Test func aCopyShownAsAnotherVariantKeepsWhatMovesInIt() throws {
        // The group, which moves as a whole and holds a badge that moves, is made a component.
        let group = id("Group")
        store.selection = [group]
        bench.step { store.makeComponent() }
        let copy = try #require(store.selection.first)
        func badge() -> Node? { store.node(copy)?.children.first { $0.name == "Badge" } }
        #expect(store.node(copy)?.isCopy == true && store.node(copy)?.motion == Self.moves)
        #expect(badge()?.motion == Self.moves)
        edit { $0.update(badge()!.id) { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }

        // A variant made of the copy as it is, and the copy shown as one and the other.
        store.selection = [copy]
        bench.step { store.addVariant() }
        let master = try #require(store.doc.masters.first)
        let variant = try #require(master.master?.variants.first)
        #expect(store.node(copy)?.instance?.variant == variant)
        #expect(store.node(copy)?.motion == Self.moves)
        #expect(badge()?[track: .move]?.keys.map(\.t) == [0, 1.6])
        bench.step { store.setVariant(nil, for: [copy]) }
        #expect(store.node(copy)?.instance?.variant == nil && store.node(copy)?.motion == Self.moves)
        #expect(badge()?[track: .move]?.keys.map(\.t) == [0, 1.6])
        bench.step { store.setVariant(variant, for: [copy]) }
        #expect(badge()?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(badge()?[track: .fade] == Self.moves?["fade"])
    }

    // MARK: Repeat grids and decks

    @Test func aRepeatGridsCellsStartMovingAsTheFirstAndEachKeepsItsOwn() throws {
        let card = id("Card")
        store.selection = [card]
        bench.step { store.makeRepeatGrid() }
        let grid = try #require(store.selection.first)
        #expect(store.node(grid)?.isRepeatGrid == true)
        bench.step { store.changeGrid(grid, "Repeat") { $0.columns = 2 } }
        func cells() -> [Node] { store.node(grid)?.children ?? [] }
        #expect(cells().count == 2 && cells().allSatisfy { $0.name == "Card" && $0.motion == Self.moves })

        // The first cell's key moved: the second is as it was. A look changed reaches both.
        let first = cells()[0].id, second = cells()[1].id
        edit { $0.update(first) { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        #expect(store.node(second)?.motion == Self.moves)
        let green = RGBA(r: 0, g: 1, b: 0)
        bench.step { store.update([first], "Fill") { $0.fill.color = green } }
        #expect(store.node(second)?.fill.color == green && store.node(second)?.motion == Self.moves)
        #expect(store.node(first)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        // The other way round: a key moved in the second cell is the second cell's.
        edit { $0.update(second) { $0.moveKeys(from: 0.6, to: 1, of: [.fade]) } }
        #expect(store.node(first)?[track: .fade] == Self.moves?["fade"])
        #expect(store.node(second)?[track: .fade]?.keys.map(\.t) == [0, 1])
        // A cell more starts as the first is now; the ones there keep theirs.
        bench.step { store.changeGrid(grid, "Repeat") { $0.columns = 3 } }
        #expect(cells().count == 3)
        #expect(cells()[2][track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(cells()[1][track: .fade]?.keys.map(\.t) == [0, 1] && cells()[1][track: .move] == Self.moves?["move"])
        // The grid posed as a whole, then taken apart: its cells are layers like any, each moving as it did.
        edit { $0.update(grid) { $0.pose(.fade, [0], at: 0) } }
        #expect(store.node(grid)?[track: .fade]?.keys.count == 2)
        let were = cells().map(\.motion)
        bench.step { store.ungroupGrid(grid) }
        #expect(store.node(grid)?.isRepeatGrid != true)
        #expect(named("Card").map(\.motion) == were)
    }

    @Test func aDecksPostsStartMovingAsTheDesignAndEachKeepsItsOwn() throws {
        let a = bench.a.id
        let film = bench.a.film, camera = bench.a.motion
        bench.step { store.addPost(to: a) }
        #expect(bench.a.isDeck && bench.a.posts.count == 2)
        // The film's length and its camera are the artboard's, whichever post is in front.
        #expect(bench.a.film == film && bench.a.motion == camera)
        func card(in post: Int) -> Node? { bench.a.layers(of: post).first { $0.name == "Card" } }
        let posts = bench.a.posts
        #expect(card(in: posts[0])?.motion == Self.moves && card(in: posts[1])?.motion == Self.moves)

        // A key moved in the post in front is that post's.
        let front = try #require(store.front(of: bench.a)), behind = try #require(posts.first { $0 != front })
        let inFront = try #require(card(in: front)).id
        edit { $0.update(inFront) { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        #expect(card(in: front)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(card(in: behind)?.motion == Self.moves)
        // A look changed reaches every post, and each still moves in its own way.
        let green = RGBA(r: 0, g: 1, b: 0)
        bench.step { store.update([inFront], "Fill") { $0.fill.color = green } }
        #expect(card(in: behind)?.fill.color == green && card(in: behind)?.motion == Self.moves)
        #expect(card(in: front)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        // What is seen, and so filmed, is the post in front.
        let seen = try #require(store.seenDoc.node(a))
        #expect(seen.children.first { $0.name == "Card" }?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(seen.film == film && seen.motion == camera)
        store.turn(a, to: behind)
        #expect(store.seenDoc.node(a)?.children.first { $0.name == "Card" }?.motion == Self.moves)
        store.turn(a, to: front)

        // Each post made an artboard of its own has the film and the camera, and its layers their motion.
        bench.step { store.spreadOut(a) }
        let boards = store.selection.compactMap { store.node($0) }
        #expect(boards.count == 2 && boards.allSatisfy { $0.isArtboard && !$0.isDeck })
        #expect(boards.allSatisfy { $0.film == film && $0.motion == camera })
        #expect(boards[0].children.first { $0.name == "Card" }?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(boards[1].children.first { $0.name == "Card" }?.motion == Self.moves)
        #expect(boards.allSatisfy { $0.children.first { $0.name == "Group" }?.children.first?.motion == Self.moves })
        bench.undoLast()
        // Or only the post in front kept.
        bench.step { store.unstack(a) }
        #expect(!bench.a.isDeck && bench.a.film == film && bench.a.motion == camera)
        #expect(bench.node("Card")?[track: .move]?.keys.map(\.t) == [0, 1.6])
    }

    // MARK: Masks, paths and shapes

    @Test func maskedLayersKeepTheirMotionAndSoDoesWhatAMaskLetsGo() throws {
        let card = id("Card"), dot = id("Dot")
        edit { $0.update(dot) { $0.frame.origin = CGPoint(x: 60, y: 60); $0.pose(.scale, [2, 2], at: 1) } }
        let scaled = store.node(dot)?.motion
        bench.step { store.mask(MaskPlan(shape: card, held: [dot])) }
        let mask = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(mask.isMask && mask.motion == nil)
        #expect(store.node(card)?.motion == Self.moves && store.node(dot)?.motion == scaled)
        // The mask is one piece of the film, drawn again as what it holds moves.
        #expect(bench.a.filmPieces().contains { $0.layers.contains(mask.id) && $0.changes })
        // Posed as a whole, then let go: shape and layer lie where they did, each with its own motion.
        edit { $0.update(mask.id) { $0.pose(.turn, [15], at: 1) } }
        let whole = try #require(store.node(mask.id))
        bench.step { store.releaseMask(mask.id) }
        #expect(store.node(mask.id) == nil)
        #expect(store.node(card)?.motion == Self.moves && store.node(dot)?.motion == scaled)
        bench.undoLast()
        #expect(store.node(mask.id) == whole)
        // The one layer it held taken out of it: the mask is no more, and both still move.
        bench.step { store.takeOutOfMask([dot]) }
        #expect(store.node(dot)?.motion == scaled)
        #expect(store.node(card)?[track: .move] == Self.moves?["move"] && store.node(card)?[track: .fade] == Self.moves?["fade"])
    }

    @Test func wordsMadeAPathMoveAsTheWordsDid() throws {
        // Words of one colour become one path, with their keys.
        var plain = Filmed.words("Plain", "Hello", at: CGPoint(x: 140, y: 260))
        plain.style?.size = 40
        plain.refit()
        bench.step { store.add(plain, onto: bench.a.id) }
        store.selection = [plain.id]
        bench.step { store.convertToPath() }
        let path = try #require(store.node(plain.id))
        #expect(path.kind == .path && path.motion == Self.moves)
        bench.undoLast()
        #expect(store.node(plain.id)?.kind == .text && store.node(plain.id)?.motion == Self.moves)

        // Words of two colours become a group of two paths. The group moves as the words did;
        // its paths have no keys of their own, or they would move twice as far and fade twice.
        var two = Filmed.words("Two", "Hello there", at: CGPoint(x: 140, y: 320))
        two.style?.size = 40
        two.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.color = RGBA(r: 1, g: 0, b: 0) }
        two.refit()
        bench.step { store.add(two, onto: bench.a.id) }
        store.selection = [two.id]
        bench.step { store.convertToPath() }
        let group = try #require(store.node(two.id))
        #expect(group.kind == .group && group.children.count == 2)
        #expect(group.motion == Self.moves)
        #expect(group.children.allSatisfy { $0.motion == nil })
        // Half way through its fade, a path in it is drawn as faint as the words would have been.
        let posed = bench.a.posed(at: 0.3).children.first { $0.id == two.id }
        let words = two.pose(at: 0.3).fade
        #expect(words > 0.1 && words < 0.95)
        #expect(posed.map { abs($0.opacity - words) < 1e-9 && $0.children.allSatisfy { $0.opacity == 1 } } == true)
    }

    @Test func shapesMadePathsCombinedCutAndOutlinedMoveAsTheShapeDid() throws {
        let card = id("Card"), dot = id("Dot")
        // A rectangle made a path is the same layer.
        store.selection = [card]
        bench.step { store.convertToPath() }
        #expect(store.node(card)?.kind == .path && store.node(card)?.motion == Self.moves)
        bench.undoLast()

        // Its border made a shape of its own lies on it and moves with it.
        bench.step { store.update([card], "Border") { $0.border = Border(on: true, color: .black, width: 6) } }
        store.selection = [card]
        bench.step { store.outlineBorders() }
        let border = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(border.id != card && border.motion == Self.moves && store.node(card)?.motion == Self.moves)
        bench.undoLast()
        bench.undoLast()

        // Cut in two with the knife, both pieces move as the shape did.
        store.selection = [card]
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 200, y: 120))
        line.addLine(to: CGPoint(x: 200, y: 240))
        var cut = false
        bench.step { cut = store.cut(along: line) }
        #expect(cut && store.selection.count == 2)
        #expect(store.selection.allSatisfy { store.node($0)?.motion == Self.moves })
        bench.undoLast()
        #expect(store.node(card)?.motion == Self.moves)

        // Two shapes made one: it is styled as the one at the back, and moves as that one did.
        edit { $0.update(dot) { $0.frame = CGRect(x: 130, y: 90, width: 60, height: 60); $0.pose(.scale, [2, 2], at: 1) } }
        store.selection = [card, dot]
        #expect(store.canCombine)
        bench.step { store.combine(.union) }
        let made = try #require(store.selection.first.flatMap { store.node($0) })
        #expect(made.kind == .path && made.motion == Self.moves)
        bench.undoLast()
        #expect(store.node(card)?.motion == Self.moves && store.node(dot)?[track: .scale]?.keys.count == 2)
        // An outline pulled out behind a shape is a copy of it, moving with it.
        var outset: UUID?
        bench.step { outset = store.offsetCopy(of: card, by: 8, round: true, replacing: nil) }
        #expect(outset.flatMap { store.node($0) }?.motion == Self.moves)
    }

    // MARK: Pictures

    /// A design kept as a package, with a moving layer "Photo" on artboard "A" filled with `picture`.
    private func pictured(_ picture: CGImage) throws -> (DocumentStore, UndoManager) {
        let url = Filmed.place()
        var photo = Filmed.card("Photo", CGRect(x: 50, y: 50, width: 200, height: 150))
        photo.fill = Fill(color: .shape, image: ImageFill(asset: "photo.png", size: CGSize(width: picture.width, height: picture.height)))
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        board.children = [photo]
        var doc = BezzleDocument()
        doc.nodes = [board]
        try DesignFile.write(doc, to: url)
        let out = try #require(CGImageDestinationCreateWithURL(url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("photo.png") as CFURL,
                                                               UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, picture, nil)
        #expect(CGImageDestinationFinalize(out))
        let store = try DocumentStore(opening: url)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func done(_ store: DocumentStore) {
        DocumentStore.finishSaving()
        try? FileManager.default.removeItem(at: store.url)
    }

    @Test func aPictureMadeShapesMovesAsItDidAndSoDoesThePictureGivenBack() async throws {
        let (store, undo) = try pictured(VectorTests.drawing())
        defer { done(store) }
        let id = try #require(store.doc.allNodes.first { $0.name == "Photo" }).id
        #expect(try await store.vectorize([id]) == [id])
        let group = try #require(store.node(id))
        #expect(group.kind == .group && group.motion == Self.moves)
        #expect(!group.children.isEmpty && group.children.allSatisfy { $0.motion == nil })
        undo.undo()
        #expect(store.node(id)?.fill.image?.asset == "photo.png" && store.node(id)?.motion == Self.moves)
        undo.redo()

        // Posed since it became shapes, then given back as a picture: the keys set since are the picture's too.
        undo.beginUndoGrouping()
        store.edit("Add Key") { $0.update(id) { $0.pose(.turn, [30], at: 1.5); $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        undo.endUndoGrouping()
        #expect(store.vector(of: id) != nil)
        undo.beginUndoGrouping()
        store.backToPicture(id)
        undo.endUndoGrouping()
        let back = try #require(store.node(id))
        #expect(back.kind == .rectangle && back.fill.image?.asset == "photo.png")
        #expect(back[track: .turn]?.keys.count == 2 && back[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(back[track: .fade] == Self.moves?["fade"])
    }

    @Test func aPictureWithItsBackgroundTakenAwayMovesAsItDid() async throws {
        let (store, undo) = try pictured(CutoutTests.ball())
        defer { done(store) }
        let id = try #require(store.doc.allNodes.first { $0.name == "Photo" }).id
        #expect(try await store.cutOut([id]) == [id])
        #expect(store.node(id)?.fill.image?.cutout != nil && store.node(id)?.motion == Self.moves)
        store.selection = [id]
        undo.beginUndoGrouping()
        store.restoreBackground()
        undo.endUndoGrouping()
        #expect(store.node(id)?.fill.image?.cutout == nil && store.node(id)?.motion == Self.moves)
    }

    // MARK: Looks and layout

    @Test func namedLooksAndADarkArtboardChangeNothingOfTheFilm() throws {
        let card = id("Card"), a = bench.a.id
        let film = bench.a.film, camera = bench.a.motion
        store.selection = [card]
        var style: UUID?
        bench.step { style = store.nameLook(at: .fill(0), "Brand") }
        let brand = try #require(style)
        #expect(store.node(card)?.motion == Self.moves)
        // The style changed: the layer named after it looks new and moves as before.
        let blue = RGBA(r: 0, g: 0, b: 1)
        bench.step { store.changeStyle(brand, "Change Colour") { $0 = .colour(ColourLook(color: blue)) } }
        #expect(store.node(card)?.fill.color == blue && store.node(card)?.motion == Self.moves)
        // The artboard shown dark, which gives every layer on it its dark look, and light again.
        let motions = bench.a.children.map(\.motion)
        bench.step { store.show(a, dark: true) }
        #expect(bench.a.showsDark)
        #expect(bench.a.children.map(\.motion) == motions && bench.a.film == film && bench.a.motion == camera)
        #expect(bench.node("Badge")?.motion == Self.moves)
        bench.step { store.show(a, dark: false) }
        #expect(bench.a.children.map(\.motion) == motions && bench.a.film == film && bench.a.motion == camera)
        // The style taken out of the design: the layer keeps its look and its keys.
        bench.step { store.removeStyle(brand) }
        #expect(store.node(card)?.fill.color == blue && store.node(card)?.motion == Self.moves)
    }

    @Test func anArtboardResizedKeepsItsFilmAndWhatMovesOnIt() throws {
        let a = bench.a.id, card = id("Card"), dot = id("Dot")
        let before = bench.a
        bench.step { store.resizeArtboards([a]) { _ in CGSize(width: 800, height: 300) } }
        let wide = bench.a
        #expect(wide.frame.size == CGSize(width: 800, height: 300))
        #expect(wide.film == before.film && wide.motion == before.motion)
        #expect(wide.children.map(\.id) == before.children.map(\.id))
        #expect(wide.children.map(\.motion) == before.children.map(\.motion))
        #expect(bench.node("Badge")?.motion == Self.moves)
        // Back at its size with nothing changed between, the design is exactly as it was, film and all.
        bench.step { store.resizeArtboards([a]) { _ in CGSize(width: 400, height: 300) } }
        #expect(bench.a.children.map(\.frame) == before.children.map(\.frame))
        #expect(bench.node("Badge")?.frame == before.children[1].children[0].frame)
        #expect(bench.a.atRest == before.atRest)
        #expect(bench.a.children.map(\.motion) == before.children.map(\.motion) && bench.a.film == before.film && bench.a.motion == before.motion)

        // Wide again, the camera is posed and a layer given keys; back at its size, both are there.
        bench.step { store.resizeArtboards([a]) { _ in CGSize(width: 800, height: 300) } }
        edit { doc in
            doc.update(a) { $0.setKey(.cameraRoll, [10], at: 1) }
            doc.update(dot) { $0.pose(.scale, [2, 2], at: 1) }
            doc.update(card) { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) }
        }
        bench.step { store.resizeArtboards([a]) { _ in CGSize(width: 400, height: 300) } }
        #expect(bench.a.frame.size == CGSize(width: 400, height: 300))
        #expect(bench.a[track: .cameraRoll]?.keys.count == 1 && bench.a.film == before.film)
        #expect(store.node(dot)?[track: .scale]?.keys.count == 2)
        #expect(store.node(card)?[track: .move]?.keys.map(\.t) == [0, 1.6])
        #expect(bench.node("Badge")?.motion == Self.moves)
        // Undone, the wide artboard is as it was posed.
        bench.undoLast()
        #expect(bench.a.frame.width == 800 && store.node(dot)?[track: .scale]?.keys.count == 2)
    }
}
