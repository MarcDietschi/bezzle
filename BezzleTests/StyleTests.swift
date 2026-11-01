import Testing
import AppKit
@testable import Bezzle

/// Styles: a look given a name is the same wherever it is used. Changed on any layer that has it,
/// or in the design's list, it changes on all of them; taken away, its layers keep their looks;
/// shared, two people's changes to styles and to the layers that use them are both kept.
@MainActor
struct StyleTests {
    private static let blue = RGBA(r: 0.2, g: 0.35, b: 0.8)
    private static let red = RGBA(r: 0.9, g: 0.2, b: 0.1)

    /// Rectangles "One", "Two" and "Three" in blue on artboard A, and a text "Words".
    private func bench() -> Bench {
        func rect(_ name: String, _ x: CGFloat) -> Node {
            var n = CanvasTests.rect(name, CGRect(x: x, y: 20, width: 60, height: 40))
            n.fill.color = Self.blue
            return n
        }
        var words = Node(kind: .text, name: "Words", frame: CGRect(x: 20, y: 120, width: 0, height: 0))
        words.text = "Hello"
        words.refit()
        let b = Bench(extra: [rect("One", 20), rect("Two", 120), rect("Three", 220), words])
        return b
    }

    private func id(_ b: Bench, _ name: String) -> UUID { b.node(name)!.id }

    /// Names One's fill "Brand", and gives Two the style.
    private func named(_ b: Bench) -> UUID {
        b.store.selection = [id(b, "One")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .fill(0), "Brand") }
        let style = b.store.style(made!)!
        b.store.selection = [id(b, "Two")]
        b.step { b.store.use(style, at: .fill(0)) }
        return style.id
    }

    // MARK: Naming and using

    @Test func namingALookMakesAStyleTheLayerUses() throws {
        let b = bench()
        b.store.selection = [id(b, "One")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .fill(0), "  Brand  ") }
        let style = try #require(made.flatMap { b.store.style($0) })
        #expect(style.name == "Brand" && style.look == .colour(ColourLook(color: Self.blue)))
        #expect(b.node("One")!.fill.named == style.id)
        #expect(b.store.sharedStyle(at: .fill(0))?.id == style.id)
        // Three look the same, unnamed: it is offered to name them too.
        guard case .nameToo(_, let uses)? = b.store.styleShow.offer?.kind else { Issue.record("no offer"); return }
        #expect(Set(uses.map(\.layer)) == [id(b, "Two"), id(b, "Three")])
        b.step { b.store.take(b.store.styleShow.offer!) }
        #expect(b.node("Two")!.fill.named == style.id && b.node("Three")!.fill.named == style.id)
    }

    @Test func aNameLeftEmptyIsOneThatSaysWhatTheLookIs() {
        let b = bench()
        b.store.selection = [id(b, "One")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .fill(0), "") }
        #expect(b.store.style(made!)?.name == String(localized: "Blue"))
        b.store.selection = [id(b, "Three")]
        b.step { made = b.store.nameLook(at: .fill(0), "") }
        #expect(b.store.style(made!)?.name == "\(String(localized: "Blue")) 2")
    }

    @Test func usingAStyleGivesTheLayerItsLook() {
        let b = bench()
        let s = named(b)
        b.store.selection = [id(b, "Three")]
        b.step { b.store.updateSelection("x") { $0.fill.color = Self.red } }
        b.step { b.store.use(b.store.style(s)!, at: .fill(0)) }
        #expect(b.node("Three")!.fill.color == Self.blue && b.node("Three")!.fill.named == s)
    }

    // MARK: Changing

    @Test func aChangeOnOneLayerIsAChangeOnAllOfThem() {
        let b = bench()
        let s = named(b)
        b.store.selection = [id(b, "One")]
        b.step { b.store.updateSelection("Change Fill") { $0.fill.color = Self.red } }
        #expect(b.node("Two")!.fill.color == Self.red)
        #expect(b.store.style(s)?.look == .colour(ColourLook(color: Self.red)))
        // Three has no name, and is left as it was.
        #expect(b.node("Three")!.fill.color == Self.blue)
        // A wave runs over both, and keeping it on One alone is offered.
        #expect(Set(b.store.styleShow.wave?.layers ?? []) == [id(b, "One"), id(b, "Two")])
        guard case .onlyHere? = b.store.styleShow.offer?.kind else { Issue.record("no offer"); return }
        b.step { b.store.take(b.store.styleShow.offer!) }
        #expect(b.node("One")!.fill.color == Self.red && b.node("One")!.fill.named == nil)
        #expect(b.node("Two")!.fill.color == Self.blue && b.node("Two")!.fill.named == s)
        #expect(b.store.style(s)?.look == .colour(ColourLook(color: Self.blue)))
    }

    @Test func aChangeToTheStyleItselfReachesEveryLayer() {
        let b = bench()
        let s = named(b)
        b.store.selection = []
        b.step { b.store.changeStyle(s, "Change Colour") { $0 = .colour(ColourLook(color: Self.red)) } }
        #expect(b.node("One")!.fill.color == Self.red && b.node("Two")!.fill.color == Self.red)
        #expect(b.node("Three")!.fill.color == Self.blue)
        #expect(b.store.styleShow.wave?.origin == nil)
        b.undo.undo()
        #expect(b.node("One")!.fill.color == Self.blue && b.node("Two")!.fill.color == Self.blue)
        #expect(b.store.style(s)?.look == .colour(ColourLook(color: Self.blue)))
    }

    @Test func aStyleTakenAwayLeavesItsLayersAsTheyLook() {
        let b = bench()
        let s = named(b)
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.red)) } }
        b.step { b.store.removeStyle(s) }
        #expect(b.store.doc.styles == nil)
        #expect(b.node("One")!.fill.named == nil && b.node("One")!.fill.color == Self.red)
        #expect(b.node("Two")!.fill.named == nil && b.node("Two")!.fill.color == Self.red)
    }

    @Test func aGradientStyleKeepsWhereEachLayerRunsIt() {
        let b = bench()
        let s = named(b)
        var g = Gradient.fading(from: Self.red)
        b.store.selection = [id(b, "One")]
        b.step { b.store.updateSelection("x") { $0.fill.gradient = g } }
        #expect(b.node("Two")!.fill.gradient?.stops == g.stops)
        // Turned on Two alone: its colours stay the style's, and One keeps its own direction.
        b.store.selection = [id(b, "Two")]
        b.step { b.store.updateSelection("x") { $0.fill.gradient?.end = CGPoint(x: 1, y: 0) } }
        #expect(b.node("One")!.fill.gradient?.end == g.end && b.node("Two")!.fill.gradient?.end == CGPoint(x: 1, y: 0))
        #expect(b.store.style(s)?.look.paint?.gradient?.stops == g.stops)
        g.stops[0].color = Self.blue
        b.step { b.store.updateSelection("x") { $0.fill.gradient?.stops = g.stops } }
        #expect(b.node("One")!.fill.gradient?.stops == g.stops)
    }

    // MARK: Type

    @Test func namedTypeChangesEverywhereAndRefitsTheWords() {
        var words = Node(kind: .text, name: "Words", frame: CGRect(x: 20, y: 120, width: 0, height: 0))
        words.text = "Hello"
        words.refit()
        var more = Node(kind: .text, name: "More", frame: CGRect(x: 20, y: 200, width: 0, height: 0))
        more.text = "Hello there"
        more.refit()
        let b = Bench(extra: [words, more])
        b.store.selection = [id(b, "Words")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .text, "Body") }
        b.store.selection = [id(b, "More")]
        b.step { b.store.use(b.store.style(made!)!, at: .text) }
        let wide = b.node("More")!.frame.width
        b.store.selection = [id(b, "Words")]
        b.step { b.store.updateSelection("Change Size") { $0.style?.size = 48 } }
        #expect(b.node("More")!.style?.size == 48)
        #expect(b.node("More")!.frame.width > wide * 1.5)
        // Pulled bigger with its box, a layer leaves its named type, which stays as it was.
        var n = b.node("More")!
        n.scaleType(by: 2)
        #expect(n.style?.named == nil && n.style?.size == 96)
    }

    @Test func aTypeLeavesWhereTheWordsLieToEachLayer() {
        let b = bench()
        b.store.selection = [id(b, "Words")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .text, "Body") }
        b.step { b.store.updateSelection("Align") { $0.style?.align = .center } }
        #expect(b.store.style(made!)?.look.type == TypeLook(TextStyle()))
    }

    // MARK: Found looks

    @Test func looksSeveralLayersHaveAlikeAreFoundAndNamedAtOnce() throws {
        let b = bench()
        let found = try #require(b.store.doc.foundLooks()[.colour]?.first { $0.look == .colour(ColourLook(color: Self.blue)) })
        #expect(found.count == 3)
        var made: UUID?
        b.step { made = b.store.name(found) }
        for name in ["One", "Two", "Three"] { #expect(b.node(name)!.fill.named == made) }
        #expect(b.store.doc.foundLooks()[.colour]?.contains { $0.look == found.look } != true)
        #expect(Set(b.store.styleShow.wave?.layers ?? []) == Set(["One", "Two", "Three"].map { id(b, $0) }))
    }

    // MARK: Grids

    @Test func everyCellOfAGridFollowsAndAnyCellChangesIt() throws {
        let b = bench()
        let s = named(b)
        b.store.selection = [id(b, "One")]
        b.step { b.store.makeRepeatGrid() }
        let grid = b.store.selection[0]
        b.step { b.store.edit("x") { $0.update(grid) { $0.grid?.columns = 3 } } }
        let cells = b.store.doc.allNodes.filter { $0.name == "One" }
        #expect(cells.count == 3 && cells.allSatisfy { $0.fill.named == s })
        // A change in the last cell goes to every cell, the style, and Two.
        b.store.selection = [cells[2].id]
        b.step { b.store.updateSelection("x") { $0.fill.color = Self.red } }
        #expect(b.store.doc.allNodes.filter { $0.name == "One" }.allSatisfy { $0.fill.color == Self.red && $0.fill.named == s })
        #expect(b.node("Two")!.fill.color == Self.red)
    }

    // MARK: Light and dark

    @Test func darkColoursKeepTheirOrderAndRead() {
        let white = RGBA.white, paper = RGBA(hex: "F5F1EA")!, ink = RGBA(hex: "1F1D1A")!
        #expect(white.darkened.oklab.l < 0.35 && paper.darkened.oklab.l < 0.35)
        // A card stays lighter than its page in the dark too.
        #expect(white.darkened.oklab.l > paper.darkened.oklab.l)
        #expect(ink.darkened.oklab.l > 0.8 && RGBA.black.darkened.oklab.l > 0.9)
        // The same colour made dark twice is the same colour.
        #expect(Self.blue.darkened == Self.blue.darkened && Self.blue.darkened.a == Self.blue.a)
        let back = RGBA(oklab: Self.blue.oklab)
        #expect(abs(back.r - Self.blue.r) < 0.002 && abs(back.b - Self.blue.b) < 0.002)
    }

    @Test func anArtboardMadeDarkNamesItsColoursAndShowsThemDark() throws {
        let b = bench()
        let s = named(b)
        b.step { b.store.show(b.a.id, dark: true) }
        #expect(b.a.dark == true)
        // Its own background and the unnamed rectangle got names; everything shows dark.
        let ground = try #require(b.a.fill.named.flatMap { b.store.style($0) })
        #expect(ground.look == .colour(ColourLook(color: .white)) && ground.dark == nil)
        #expect(b.a.fill.color == RGBA.white.darkened)
        #expect(b.node("One")!.fill.color == Self.blue.darkened && b.node("One")!.fill.named == s)
        #expect(b.node("Three")!.fill.named != nil && b.node("Three")!.fill.color == Self.blue.darkened)
        // The light artboard beside it keeps its looks, named the same.
        #expect(b.b.fill.named == ground.id && b.b.fill.color == .white)
        // Light again: every look as it was.
        b.step { b.store.show(b.a.id, dark: false) }
        #expect(b.a.dark == false && b.a.fill.color == .white && b.node("One")!.fill.color == Self.blue)
        b.undo.undo()
        #expect(b.a.dark == true && b.node("One")!.fill.color == Self.blue.darkened)
    }

    @Test func wordsKeepTheirColourInTheDarkWhereThatReadsBetter() {
        var button = CanvasTests.rect("Button", CGRect(x: 20, y: 200, width: 160, height: 44))
        button.fill.color = Self.blue
        var label = Node(kind: .text, name: "Label", frame: CGRect(x: 40, y: 210, width: 0, height: 0))
        label.text = "Go"
        label.fill.color = .white
        label.refit()
        var words = Node(kind: .text, name: "Words", frame: CGRect(x: 20, y: 40, width: 0, height: 0))
        words.text = "Hello"
        words.fill.color = .black
        words.refit()
        var card = CanvasTests.rect("Card", CGRect(x: 200, y: 20, width: 100, height: 100))
        card.fill.color = .white
        let b = Bench(extra: [words, card, button, label])
        b.step { b.store.show(b.a.id, dark: true) }
        // White on blue stays white; black on the page turns pale; the white card goes deep.
        #expect(b.node("Label")!.fill.color == .white)
        #expect(b.node("Words")!.fill.color == RGBA.black.darkened)
        #expect(b.node("Card")!.fill.color == RGBA.white.darkened)
        #expect(b.node("Label")!.fill.named != b.node("Card")!.fill.named)
        #expect(b.store.style(b.node("Label")!.fill.named!)?.name == String(localized: "White") + " 2" ||
                b.store.style(b.node("Card")!.fill.named!)?.name == String(localized: "White") + " 2")
    }

    @Test func aLookChangedInTheDarkIsItsOwnThere() {
        let b = bench()
        let s = named(b)
        b.step { b.store.show(b.a.id, dark: true) }
        let night = RGBA(r: 0.4, g: 0.5, b: 1)
        b.store.selection = [id(b, "One")]
        b.step { b.store.updateSelection("Change Fill") { $0.fill.color = night } }
        #expect(b.store.style(s)?.dark == .colour(ColourLook(color: night)))
        #expect(b.store.style(s)?.look == .colour(ColourLook(color: Self.blue)))
        #expect(b.node("Two")!.fill.color == night)
        // Changed in the light, it stays as made in the dark.
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.red)) } }
        #expect(b.node("Two")!.fill.color == night)
        // Made dark by itself again, it follows its light look.
        b.step { b.store.followInTheDark(s) }
        #expect(b.node("Two")!.fill.color == Self.red.darkened)
        // Changed in the dark from the list, the light stays.
        b.step { b.store.changeStyle(s, "x", dark: true) { $0 = .colour(ColourLook(color: night)) } }
        #expect(b.node("One")!.fill.color == night && b.store.style(s)?.look.paint?.color == Self.red)
    }

    @Test func aLookNamedInTheDarkLooksTheSameAfter() {
        let b = bench()
        b.step { b.store.edit("Dark") { $0.update(b.a.id) { $0.dark = true } } }
        b.store.selection = [id(b, "Three")]
        var made: UUID?
        b.step { made = b.store.nameLook(at: .fill(0), "Night") }
        #expect(b.node("Three")!.fill.color == Self.blue)
        #expect(b.store.style(made!)?.dark == .colour(ColourLook(color: Self.blue)))
    }

    @Test func aLightOneBesideADarkOneLiesClearOfTheOthers() throws {
        let b = bench()
        b.step { b.store.show(b.a.id, dark: true) }
        var made: UUID?
        b.step { b.store.edit("x") { made = DocumentStore.lightTwin(of: b.a.id, in: &$0) } }
        let twin = try #require(made.flatMap { b.store.node($0) })
        let other = try #require(b.node("B"))
        #expect(twin.dark == nil && twin.frame.minX >= other.frame.maxX + 80)
        #expect(twin.children.first { $0.name == "One" }?.fill.color == Self.blue)
    }

    @Test func lightAndDarkChangedApartAreBothKept() {
        let (doc, s, one, _) = sharedStart()
        var d = doc
        d.show(d.nodes[0].id, dark: true) { _ in "x" }
        d.syncStyles(since: doc)
        var a = Mac("a", doc: d)
        var b = Mac("b", doc: BezzleDocument())
        b.receive(a.state)
        let night = RGBA(r: 0.1, g: 0.1, b: 0.4)
        a.edit { $0.changeStyle(s) { $0.look = .colour(ColourLook(color: Self.red)) } }
        b.edit { $0.changeStyle(s) { $0.dark = .colour(ColourLook(color: night)) } }
        var macs = [a, b]
        Self.sync(&macs)
        for m in macs {
            #expect(m.doc.style(s)?.look.paint?.color == Self.red && m.doc.style(s)?.dark?.paint?.color == night)
            #expect(m.doc.node(one)?.fill.color == night)
        }
    }

    // MARK: Another design

    @Test func stylesComeAlongIntoAnotherDesignOrMeetTheirNamesakes() {
        let b = bench()
        let s = named(b)
        let brought = [b.store.style(s)!]
        // A design with its own "brand", in another colour: the layers take it on.
        var other = BezzleDocument()
        let theirs = Style(name: "brand", look: .colour(ColourLook(color: Self.red)))
        other.addStyle(theirs)
        let map = other.takeIn(brought)
        #expect(map == [s: theirs.id] && other.styles?.count == 1)
        var pasted = b.node("One")!.renamingStyles(map)
        other.nodes = [pasted]
        other.repairStyles()
        #expect(other.nodes[0].fill.named == theirs.id && other.nodes[0].fill.color == Self.red)
        // A design without one gets it.
        var empty = BezzleDocument()
        #expect(empty.takeIn(brought).isEmpty && empty.style(s)?.name == "Brand")
        pasted = b.node("One")!
        #expect(pasted.stylesUsed == [s])
    }

    // MARK: Files

    @Test func stylesAreSavedWithTheDesign() throws {
        let b = bench()
        _ = named(b)
        let data = try JSONEncoder().encode(b.store.doc)
        let back = try JSONDecoder().decode(BezzleDocument.self, from: data)
        #expect(back == b.store.doc)
        // A design without any is saved as it always was.
        #expect(!String(decoding: try JSONEncoder().encode(BezzleDocument()), as: UTF8.self).contains("styles"))
    }

    // MARK: Shared

    /// One Mac's copy of a shared design, as `Collaboration` keeps it.
    private struct Mac {
        let name: String
        var state = SharedDesign()
        var base = FlatDesign()
        var doc: BezzleDocument
        var time: Int64 = 1_000

        init(_ name: String, doc: BezzleDocument) {
            self.name = name
            self.doc = doc
            commit()
        }

        mutating func commit() {
            time += 1
            state.absorb(FlatDesign(doc), since: base, by: name, at: time)
            base = FlatDesign(doc)
        }

        mutating func edit(_ change: (inout BezzleDocument) -> Void) {
            let before = doc
            change(&doc)
            doc.syncStyles(since: before)
            commit()
        }

        mutating func receive(_ other: SharedDesign) {
            commit()
            state.merge(other)
            base = state.flatDesign()
            doc = base.document()
            commit()
        }
    }

    private static func sync(_ macs: inout [Mac]) {
        for _ in 0..<3 {
            for i in macs.indices { for j in macs.indices where j != i { macs[i].receive(macs[j].state) } }
        }
    }

    private func sharedStart() -> (doc: BezzleDocument, style: UUID, one: UUID, two: UUID) {
        let b = bench()
        let s = named(b)
        return (b.store.doc, s, id(b, "One"), id(b, "Two"))
    }

    @Test func twoPeopleChangingAStyleApartBothKeepTheirChange() {
        let (doc, s, one, two) = sharedStart()
        var a = Mac("a", doc: doc)
        var b = Mac("b", doc: BezzleDocument())
        b.receive(a.state)
        #expect(b.doc.style(s)?.name == "Brand")
        // One renames it while the other recolours it.
        a.edit { $0.changeStyle(s) { $0.name = "Primary" } }
        b.edit { $0.changeStyle(s) { $0.look = .colour(ColourLook(color: Self.red)) } }
        var macs = [a, b]
        Self.sync(&macs)
        for m in macs {
            #expect(m.doc.style(s)?.name == "Primary")
            #expect(m.doc.node(one)?.fill.color == Self.red && m.doc.node(two)?.fill.color == Self.red)
        }
        #expect(macs[0].doc == macs[1].doc)
    }

    @Test func aLayerNamedWhileTheStyleChangedElsewhereTakesTheChange() {
        let (doc, s, _, _) = sharedStart()
        let three = doc.allNodes.first { $0.name == "Three" }!.id
        var a = Mac("a", doc: doc)
        var b = Mac("b", doc: BezzleDocument())
        b.receive(a.state)
        // Three is given the name on one Mac, red to begin with; the style turns green on the other.
        let green = RGBA(r: 0.1, g: 0.7, b: 0.3)
        a.edit { d in d.update(three) { $0.fill.color = Self.red } }
        a.edit { d in d.update(three) { $0.fill.named = s } }
        b.time += 50
        b.edit { $0.changeStyle(s) { $0.look = .colour(ColourLook(color: green)) } }
        var macs = [a, b]
        Self.sync(&macs)
        for m in macs { #expect(m.doc.node(three)?.fill.color == green && m.doc.node(three)?.fill.named == s) }
    }

    @Test func aStyleChangedAfterItWasTakenAwayComesBack() {
        let (doc, s, one, _) = sharedStart()
        var a = Mac("a", doc: doc)
        var b = Mac("b", doc: BezzleDocument())
        b.receive(a.state)
        a.edit { $0.removeStyle(s) }
        b.time += 50
        b.edit { $0.changeStyle(s) { $0.name = "Kept" } }
        var macs = [a, b]
        Self.sync(&macs)
        for m in macs { #expect(m.doc.style(s)?.name == "Kept") }
        // The layers the remover let go of stay let go; nothing is lost.
        #expect(macs[0].doc.node(one)?.fill.color == Self.blue)
    }

    @Test func undoTakesBackOnlyWhatWasDoneHere() {
        let (doc, s, one, _) = sharedStart()
        var renamed = doc
        renamed.changeStyle(s) { $0.name = "Theirs" }
        var mine = doc
        mine.changeStyle(s) { $0.look = .colour(ColourLook(color: Self.red)) }
        mine.syncStyles(since: doc)
        var theirs = mine
        theirs.changeStyle(s) { $0.name = "Theirs" }
        // Undoing the recolour, after someone else renamed it.
        let undone = FlatDesign.apply(from: mine, to: doc, onto: theirs)
        #expect(undone.style(s)?.name == "Theirs")
        #expect(undone.style(s)?.look == .colour(ColourLook(color: Self.blue)))
        #expect(undone.node(one)?.fill.color == Self.blue)
        _ = renamed
    }

    @Test func takingInOnlyWhatChangedKeepsTheStyles() {
        let (doc, s, _, _) = sharedStart()
        var state = SharedDesign()
        state.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1)
        var next = doc
        next.changeStyle(s) { $0.name = "Other" }
        let (old, new) = FlatDesign.changes(from: doc, to: next)
        let wrote = state.absorb(new, since: old, by: "a", at: 2)
        #expect(wrote)
        #expect(state.flatDesign().document().style(s)?.name == "Other")
    }
}
