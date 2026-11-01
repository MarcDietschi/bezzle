import Testing
import AppKit
@testable import Bezzle

/// Several styles in one text: a word in bold or another colour, lists, and the rest of the type,
/// as they are kept, laid out, typed, carried through grids and decks, merged, and found.
@MainActor
struct RichTextTests {
    private static let red = RGBA(r: 0.9, g: 0.1, b: 0.1)

    private func text(_ words: String, name: String = "T", at p: CGPoint = CGPoint(x: 20, y: 20)) -> Node {
        var t = Node(kind: .text, name: name, frame: CGRect(origin: p, size: .zero))
        t.text = words
        t.refit()
        return t
    }

    /// "Hello World" with "World" bold.
    private func helloBoldWorld() -> Node {
        var t = text("Hello World")
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.face = "Bold" }
        t.refit()
        return t
    }

    // MARK: Spans

    @Test func restylingSomeLettersKeepsTheRestAsTheyAre() {
        let t = helloBoldWorld()
        #expect(t.text == "Hello World")
        #expect(t.spans == [TextSpan(text: "Hello "), TextSpan(text: "World", look: TextLook(face: "Bold"))])
        #expect(t.letters(in: NSRange(location: 0, length: 5)).map(\.face) == ["Regular"])
        #expect(t.letters(in: NSRange(location: 6, length: 5)).map(\.face) == ["Bold"])
        // Bold is wider: the layer grew to its words.
        #expect(t.frame.width > text("Hello World").frame.width)
    }

    @Test func spansKeepTheirLooksWhenTheWordsChangeWithoutThem() {
        var t = helloBoldWorld()
        // As someone else's typing, or the AI setting words, would leave them.
        t.text = "Hello there World!"
        let runs = t.runs
        #expect(runs.map(\.text).joined() == "Hello there World!")
        #expect(runs.last?.text == "World!" || runs.contains { $0.text.hasSuffix("World!") && $0.look.face == "Bold" })
        #expect(t.letters(in: NSRange(location: 0, length: 5)).allSatisfy { $0.face == "Regular" })
        #expect(t.letters(in: NSRange(location: 12, length: 5)).allSatisfy { $0.face == "Bold" })
    }

    @Test func newWordsInPlaceOfAllTakeTheLookMostLettersHad() {
        let looks = TextSpan.looks(of: [TextSpan(text: "Big", look: TextLook(face: "Bold")), TextSpan(text: " sale today")], onto: "Huge discount")
        #expect(looks.allSatisfy { $0 == .plain })
    }

    @Test func plainLettersKeepNoSpans() {
        var t = helloBoldWorld()
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.face = "Regular" }
        #expect(t.spans == nil)
    }

    @Test func spansAreKeptFlatInTheFile() throws {
        let span = TextSpan(text: "World", look: TextLook(face: "Bold", color: Self.red))
        let json = try #require(String(data: JSONEncoder().encode(span), encoding: .utf8))
        #expect(json.contains("\"text\":\"World\""))
        #expect(json.contains("\"face\":\"Bold\""))
        #expect(!json.contains("look"))
        #expect(try JSONDecoder().decode(TextSpan.self, from: Data(json.utf8)) == span)
    }

    @Test func aChangeToTheWholeLayerReachesEveryLetter() {
        var t = helloBoldWorld()
        t.restyleLetters(in: NSRange(location: 0, length: 5)) { $0.color = Self.red }
        t.restyleLetters(in: nil) { $0.face = "Light" }
        #expect(t.style?.face == "Light")
        // The colour was not changed, so the red word stays red; no letter is bold now.
        #expect(t.letters().allSatisfy { $0.face == "Light" })
        #expect(t.letters(in: NSRange(location: 0, length: 5)).first?.color == Self.red)
    }

    @Test func replacingWordsKeepsTheLookOfWhatTheyReplace() {
        var t = helloBoldWorld()
        t.replaceText(in: NSRange(location: 6, length: 5), with: "Bezzle")
        #expect(t.text == "Hello Bezzle")
        #expect(t.letters(in: NSRange(location: 6, length: 6)).allSatisfy { $0.face == "Bold" })
        t.replaceText(in: NSRange(location: 0, length: 5), with: "Hi")
        #expect(t.text == "Hi Bezzle")
        #expect(t.letters(in: NSRange(location: 0, length: 2)).allSatisfy { $0.face == "Regular" })
    }

    @Test func listsAreOfWholeParagraphs() {
        var t = text("Fruit\nApples\nPears")
        // Two letters of "Apples" make all of it, and only it, an item.
        t.restyleLetters(in: NSRange(location: 7, length: 2)) { $0.list = .bullet }
        let looks = TextSpan.looks(of: t.spans ?? [], onto: t.text!)
        let chars = Array(t.text!)
        for (i, c) in chars.enumerated() {
            let inApples = i >= 6 && i < 13
            #expect((looks[i].list == .bullet) == inApples, "\(c) at \(i)")
        }
    }

    @Test func aLineBreakWithinAParagraphKeepsItInItsList() {
        var t = text("One\u{2028}more\nTwo")
        t.restyleLetters(in: NSRange(location: 0, length: 1)) { $0.list = .bullet }
        let looks = TextSpan.looks(of: t.spans ?? [], onto: t.text!)
        #expect(looks[4].list == .bullet)
        #expect(looks.last?.list == nil)
        #expect(TextLayout.markers(TextLayout.layout(t).manager).count == 1)
    }

    @Test func listItemsHaveMarkersAndAreSetIn() throws {
        var t = text("One\nTwo\nThree")
        t.restyleLetters(in: nil) { $0.list = .number }
        t.refit()
        let laid = TextLayout.layout(t)
        let markers = TextLayout.markers(laid.manager)
        #expect(markers.map(\.text) == ["1.", "2.", "3."])
        // The words begin after the markers, which stand before them.
        let first = laid.manager.location(forGlyphAt: 0).x + laid.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minX
        #expect(first > 10)
        #expect(markers.allSatisfy { $0.at.x >= 0 && $0.at.x < first })
    }

    @Test func boldOfAFaceKeepsItsLean() {
        #expect(Fonts.face("Regular", of: TextStyle.system, bold: true) == "Bold")
        #expect(Fonts.face("Regular Italic", of: TextStyle.system, bold: true) == "Bold Italic")
        #expect(Fonts.face("Bold", of: TextStyle.system, bold: false) == "Regular")
        #expect(Fonts.face("Bold", of: TextStyle.system, italic: true) == "Bold Italic")
    }

    // MARK: Type

    @Test func justifiedLinesRunFromSideToSide() {
        var t = text("The quick brown fox jumps over the lazy dog and keeps on running far away")
        t.style?.sizing = .autoHeight
        t.frame.size.width = 160
        t.style?.align = .justify
        t.refit()
        let laid = TextLayout.layout(t)
        let line = laid.manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        #expect(abs(line.width - 160) < 1)
    }

    @Test func linesSitInTheMiddleOrAtTheBottomOfAFixedBox() {
        var t = text("Hello")
        t.style?.sizing = .fixed
        t.frame.size = CGSize(width: 200, height: 200)
        #expect(TextLayout.offset(t) == 0)
        t.style?.vertical = .bottom
        let tall = TextLayout.layout(t).usedSize.height
        #expect(abs(TextLayout.offset(t) - (200 - tall)) <= 0.5)
        t.style?.vertical = .middle
        #expect(abs(TextLayout.offset(t) - (200 - tall) / 2) <= 0.5)
    }

    @Test func paragraphSpacingSpacesParagraphsButNotTheLast() {
        var t = text("One\nTwo")
        let before = t.frame.height
        t.style?.paragraphSpacing = 20
        t.refit()
        #expect(t.frame.height == before + 20)
        var single = text("One")
        let h = single.frame.height
        single.style?.paragraphSpacing = 20
        single.refit()
        #expect(single.frame.height == h)
    }

    @Test func featuresAndAxesChangeTheFont() {
        var style = TextStyle()
        style.size = 40
        let plain = Fonts.font(style)
        style.axes = ["wght": 800]
        let heavy = Fonts.font(style)
        #expect(heavy != plain)
        let width = { (f: NSFont) in NSAttributedString(string: "Hello", attributes: [.font: f]).size().width }
        #expect(width(heavy) > width(plain))
        style.axes = nil
        style.features = ["ss01": 1]
        #expect(Fonts.font(style).fontName == plain.fontName || Fonts.font(style) != plain)
        #expect(Fonts.tags(of: plain).contains("smcp"))
    }

    @Test func smallCapsAreSetSmallerThanCapitals() {
        var t = text("Hello")
        let natural = t.frame.width
        t.style?.letterCase = .upper
        t.refit()
        let upper = t.frame.width
        t.style?.letterCase = .smallCaps
        t.refit()
        #expect(t.frame.width < upper)
        #expect(t.frame.width != natural)
        // A font without small capitals of its own has them made.
        var h = text("Hello")
        h.style?.family = "Helvetica"
        h.style?.letterCase = .smallCaps
        let laid = TextLayout.attributed(h)
        #expect(laid.string == "HELLO")
    }

    @Test func letterSizesGrowWithTheBoxPulledBigger() {
        var t = text("Hello World")
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.size = 48 }
        t.scaleType(by: 2)
        #expect(t.style?.size == 48)
        #expect(t.letters(in: NSRange(location: 6, length: 5)).first?.size == 96)
    }

    @Test func svgKeepsStyledWordsAsText() {
        var t = helloBoldWorld()
        t.restyleLetters(in: NSRange(location: 0, length: 5)) { $0.color = Self.red; $0.strikethrough = true }
        var list = text("One\nTwo", name: "L", at: CGPoint(x: 20, y: 80))
        list.restyleLetters(in: nil) { $0.list = .bullet }
        list.refit()
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        board.children = [t, list]
        let svg = SVGWriter.document(for: ExportItem(artboard: board), bounds: board.frame, assets: nil)
        #expect(svg.contains("<tspan font-weight=\"700\">World</tspan>"))
        #expect(svg.contains("fill=\"#E61A1A\""))
        #expect(svg.contains("line-through"))
        #expect(svg.contains(">•</text>"))
    }

    // MARK: Typing

    @Test func typingKeepsTheLookOfTheLettersTypedAfter() throws {
        let bench = Bench(extra: [helloBoldWorld()])
        let id = bench.node("T")!.id
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        let editor = try #require(bench.editor)
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        let t = try #require(bench.node("T"))
        #expect(t.text == "Hello World!")
        #expect(t.letters(in: NSRange(location: 11, length: 1)).first?.face == "Bold")
        bench.step { bench.canvas.endEditing() }
    }

    @Test func boldWhileTypingMakesThePickedLettersBold() throws {
        let bench = Bench(extra: [text("Hello World")])
        let id = bench.node("T")!.id
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        let editor = try #require(bench.editor)
        let undo = try #require(editor.undoManager)
        // Each change a step of its own, as each click is in the app.
        undo.groupsByEvent = false
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(bench.store.pickedLetters == NSRange(location: 0, length: 5))
        undo.beginUndoGrouping()
        bench.store.toggleBold()
        undo.endUndoGrouping()
        var t = try #require(bench.node("T"))
        #expect(t.letters(in: NSRange(location: 0, length: 5)).first?.face == "Bold")
        #expect(t.letters(in: NSRange(location: 6, length: 5)).first?.face == "Regular")
        // The colour card colours them too.
        undo.beginUndoGrouping()
        bench.store.restyleLetters("Change Colour") { $0.color = Self.red }
        undo.endUndoGrouping()
        t = try #require(bench.node("T"))
        #expect(t.letters(in: NSRange(location: 0, length: 5)).first?.color == Self.red)
        #expect(t.fill.color != Self.red)
        // The editor's own undo takes the colour back, and the bold after it.
        editor.undoManager?.undo()
        t = try #require(bench.node("T"))
        #expect(t.letters(in: NSRange(location: 0, length: 5)).first?.color != Self.red)
        #expect(t.letters(in: NSRange(location: 0, length: 5)).first?.face == "Bold")
        bench.step { bench.canvas.endEditing() }
        // Typing, and all done in it, is one step of the history.
        bench.undoLast()
        #expect(bench.node("T")?.spans == nil)
    }

    @Test func returnOnAnEmptyListItemEndsTheList() throws {
        var t = text("One")
        t.restyleLetters(in: nil) { $0.list = .bullet }
        let bench = Bench(extra: [t])
        let id = bench.node("T")!.id
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        let editor = try #require(bench.editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        // As the Return key does it, through the editor's delegate.
        let newline = #selector(NSTextView.insertNewline(_:))
        editor.doCommand(by: newline)
        var now = try #require(bench.node("T"))
        #expect(now.text == "One\n")
        editor.insertText("Two", replacementRange: NSRange(location: NSNotFound, length: 0))
        now = try #require(bench.node("T"))
        #expect(now.letters(in: NSRange(location: 4, length: 3)).first?.list == .bullet)
        editor.doCommand(by: newline)
        editor.doCommand(by: newline)
        now = try #require(bench.node("T"))
        // The second Return ended the list rather than making an empty item.
        #expect(now.text == "One\nTwo\n")
        editor.insertText("After", replacementRange: NSRange(location: NSNotFound, length: 0))
        now = try #require(bench.node("T"))
        #expect(now.letters(in: NSRange(location: 8, length: 5)).first?.list == nil)
        bench.step { bench.canvas.endEditing() }
    }

    @Test func pastedWordsComeInAsWordsAlone() throws {
        let bench = Bench(extra: [helloBoldWorld()])
        let id = bench.node("T")!.id
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        let editor = try #require(bench.editor)
        #expect(editor.readablePasteboardTypes == [.string])
        #expect(editor.isContinuousSpellCheckingEnabled == (UserDefaults.standard.object(forKey: "BezzleChecksSpelling") as? Bool ?? true))
        bench.step { bench.canvas.endEditing() }
    }

    // MARK: Grids and decks

    @Test func restyledWordsInAGridCellAreRestyledWhereOtherCellsHaveThem() throws {
        var title = text("Price: 5", name: "Title")
        title.style?.size = 10
        title.refit()
        let bench = Bench(extra: [title])
        bench.store.selection = [bench.node("Title")!.id]
        bench.step { bench.store.makeRepeatGrid() }
        let gid = bench.store.selection[0]
        bench.step { bench.store.edit("Repeat Grid") { $0.update(gid) { $0.grid?.columns = 3 } } }
        func cells() -> [Node] { bench.store.node(gid)!.children }
        // Each cell its own words.
        for (i, c) in cells().enumerated() where i > 0 {
            bench.step { bench.store.update([c.id], "Type") { $0.text = "Price: \(5 + i)" } }
        }
        // "Price:" bold in the second cell.
        let second = cells()[1]
        bench.step { bench.store.update([second.id], "Bold") { $0.restyleLetters(in: NSRange(location: 0, length: 6)) { $0.face = "Bold" } } }
        let all = cells()
        #expect(all.map(\.text) == ["Price: 5", "Price: 6", "Price: 7"])
        for c in all {
            #expect(c.letters(in: NSRange(location: 0, length: 6)).allSatisfy { $0.face == "Bold" }, "\(c.text ?? "")")
            #expect(c.letters(in: NSRange(location: 7, length: 1)).allSatisfy { $0.face == "Regular" })
        }
        // A change to the whole layer reaches every letter in every cell.
        bench.step { bench.store.update([all[2].id], "Font") { $0.restyleLetters(in: nil) { $0.face = "Light" } } }
        for c in cells() { #expect(c.letters().allSatisfy { $0.face == "Light" }, "\(c.text ?? "")") }
    }

    @Test func aPostKeepsTheLooksOfItsOwnWords() throws {
        var title = text("Tip 1", name: "Title")
        title.style?.size = 24
        title.refit()
        let bench = Bench(extra: [title])
        let a = bench.a.id
        bench.step { bench.store.addPost(to: a) }
        let posts = bench.a.posts
        func layer(_ post: Int) -> Node { bench.a.layers(of: post).first { $0.name == "Title" }! }
        bench.step { bench.store.update([layer(posts[0]).id], "Type") { $0.text = "Hello World" } }
        bench.step { bench.store.update([layer(posts[1]).id], "Type") { $0.text = "Hi there" } }
        bench.step { bench.store.update([layer(posts[0]).id], "Bold") { $0.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.face = "Bold" } } }
        #expect(layer(posts[0]).letters(in: NSRange(location: 6, length: 5)).first?.face == "Bold")
        // The other post's words are not those, so nothing of it is bold.
        #expect(layer(posts[1]).letters().allSatisfy { $0.face == "Regular" })
        #expect(layer(posts[1]).text == "Hi there")
    }

    // MARK: Sharing

    @Test func someoneTypingWhileSomeoneElseRestylesKeepsBoth() {
        let base = helloBoldWorld()
        var typed = base
        typed.text = "Hello big World"
        // Typed on another Mac: the words; restyled here: the look.
        var restyled = base
        restyled.restyleLetters(in: NSRange(location: 0, length: 5)) { $0.color = Self.red }
        var merged = restyled
        for field in LayerField.all where field.name == "text" { field.copy(&merged, typed) }
        #expect(merged.text == "Hello big World")
        #expect(merged.letters(in: NSRange(location: 0, length: 5)).first?.color == Self.red)
        #expect(merged.letters(in: NSRange(location: 10, length: 5)).first?.face == "Bold")
    }

    // MARK: Finding

    @Test func findingAndReplacingWordsAcrossTheDesign() throws {
        let bench = Bench(extra: [text("Order now", name: "One"), text("Now or never: order now", name: "Two", at: CGPoint(x: 20, y: 120))])
        bench.store.openFind()
        let finder = try #require(bench.store.finder)
        finder.query = "now"
        #expect(bench.store.foundText.count == 3)
        finder.matchCase = true
        #expect(bench.store.foundText.count == 2)
        finder.matchCase = false
        finder.query = "or"
        finder.wholeWords = true
        #expect(bench.store.foundText.count == 1)
        finder.wholeWords = false
        finder.query = "order"
        bench.store.findNext()
        #expect(bench.store.selection == [bench.node("One")!.id])
        finder.replacement = "Buy"
        bench.step { bench.store.replaceFound() }
        #expect(bench.node("One")?.text == "Buy now")
        #expect(bench.store.foundText.count == 1)
        bench.step { bench.store.replaceAllFound() }
        #expect(bench.node("Two")?.text == "Now or never: Buy now")
        bench.undoLast()
        #expect(bench.node("Two")?.text == "Now or never: order now")
    }

    @Test func replacingKeepsTheLookOfTheWordsReplaced() throws {
        let bench = Bench(extra: [helloBoldWorld()])
        bench.store.openFind()
        let finder = try #require(bench.store.finder)
        finder.query = "World"
        finder.replacement = "Bezzle"
        bench.step { bench.store.replaceAllFound() }
        let t = try #require(bench.node("T"))
        #expect(t.text == "Hello Bezzle")
        #expect(t.letters(in: NSRange(location: 6, length: 6)).allSatisfy { $0.face == "Bold" })
    }

    @Test func checkingSpellingFindsMisspeltWords() throws {
        let bench = Bench(extra: [text("This sentense has a mistake")])
        bench.store.openFind(spelling: true)
        #expect(bench.store.misspeltWord == "sentense")
        #expect(bench.store.spellingGuesses.contains("sentence"))
        bench.step { bench.store.replaceFound(with: "sentence") }
        #expect(bench.node("T")?.text == "This sentence has a mistake")
        #expect(bench.store.foundText.isEmpty)
    }
}
