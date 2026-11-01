import Testing
import AppKit
@testable import Bezzle

/// Gradients and pictures in borders, line strokes and the letters of text, taken through
/// everything that can happen to them: chosen in the fill menu and dropped from the Finder;
/// stacked, removed, flipped, turned, outlined and duplicated; typed into; repeated in grids and
/// decks; drawn with masks, blends, depth, lists and lines through the words; exported, saved,
/// shared and driven by the assistant. Each test says what a person would expect to see. See
/// `Border.paint`, `PaintTarget` and `TextLayout.Manager.painting`.
@MainActor
struct PaintSuiteTests {
    // MARK: - Fixtures

    private static let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1), green = RGBA(r: 0, g: 0.8, b: 0)

    /// Red at the left of the layer, blue at its right.
    private static let across = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)],
                                         start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))

    /// A picture red on its left half and blue on its right, as kept in a design.
    private static let halves = ImageFill(asset: "halves.png", mode: .stretch, size: CGSize(width: 2, height: 1))

    /// On artboard A at 100,100: a white rectangle "Card" at 40,40 sized 200 × 100 with a black
    /// 6 pt border inside it, then `more`. Selected.
    private func card(_ more: [Node] = []) -> Bench {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 200, height: 100))
        card.fill.color = .white
        card.border = Border(on: true, color: .black, width: 6, position: .inside)
        let bench = Bench(extra: [card] + more)
        bench.store.selection = [id(bench, "Card")]
        return bench
    }

    /// "Hello World" in big type, "World" green of its own, on A at 40,160.
    private func hello() -> Node {
        var t = Node(kind: .text, name: "Hello", frame: CGRect(x: 40, y: 160, width: 0, height: 0))
        var style = TextStyle()
        style.size = 48
        t.style = style
        t.text = "Hello World"
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.color = Self.green }
        t.refit()
        return t
    }

    /// A row of square blocks in Menlo, which leave no gaps in them to miss.
    private func blocks(_ words: String = "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}", name: String = "Blocks", at p: CGPoint = CGPoint(x: 10, y: 10)) -> Node {
        var t = Node(kind: .text, name: name, frame: CGRect(origin: p, size: .zero))
        var style = TextStyle()
        style.family = "Menlo"
        style.size = 40
        t.style = style
        t.text = words
        t.fill.color = .black
        t.refit()
        return t
    }

    /// A white page of `size` holding `layers`.
    private func page(_ layers: [Node], width: CGFloat = 260, height: CGFloat = 160) -> Node {
        var board = Node(kind: .artboard, name: "Page", frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.fill.color = .white
        board.children = layers
        return board
    }

    private func id(_ bench: Bench, _ name: String) -> UUID { bench.node(name)?.id ?? UUID() }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 190 && p.g < 70 && p.b < 90 }
    private func isBlue(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.b > 190 && p.r < 90 && p.g < 70 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 245 && p.g > 245 && p.b > 245 }

    /// A folder holding the halves picture, read as a design's pictures are.
    private func halvesFolder() throws -> (Assets, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try halvesPNG().write(to: folder.appendingPathComponent("halves.png"))
        return (Assets(folder: folder), folder)
    }

    private func halvesPNG() throws -> Data {
        let ctx = try #require(Renderer.bitmap(CGSize(width: 2, height: 1)))
        ctx.setFillColor(Self.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(Self.blue.cgColor)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// A picture file somewhere the design can copy it from.
    private func pictureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).png")
        try halvesPNG().write(to: url)
        return url
    }

    // MARK: - Choosing in the fill menu

    @Test func aBorderTurnedToAGradientStartsFromItsColourAndRunsDown() throws {
        let bench = card()
        bench.step { bench.store.choosePaint(.linear, for: .border(0)) }
        let border = try #require(bench.node("Card")).border
        let g = try #require(border.gradient)
        #expect(g.kind == .linear && g.stops.first?.color == .black && g.stops.count == 2)
        #expect(abs(g.start.x - g.end.x) < 1e-9 && g.start.y < g.end.y, "down the layer: \(g)")
        // Its colour and width are as they were; the fill is untouched.
        #expect(border.width == 6 && border.color == .black && bench.node("Card")!.fill.gradient == nil)
    }

    @Test func aLineTurnedToAGradientRunsFromOneEndToTheOther() throws {
        var falling = Node(kind: .line, name: "Falling", frame: CGRect(x: 10, y: 10, width: 100, height: 50))
        falling.border = Border(on: true, color: .black, width: 2, position: .center)
        var rising = falling
        rising.id = UUID()
        rising.name = "Rising"
        rising.rising = true
        var level = falling
        level.id = UUID()
        level.name = "Level"
        level.frame.size.height = 0
        let bench = Bench(extra: [falling, rising, level])
        for name in ["Falling", "Rising", "Level"] {
            bench.store.selection = [id(bench, name)]
            bench.step { bench.store.choosePaint(.linear, for: .border(0)) }
        }
        let f = try #require(bench.node("Falling")?.border.gradient), r = try #require(bench.node("Rising")?.border.gradient)
        let l = try #require(bench.node("Level")?.border.gradient)
        #expect(f.start == CGPoint(x: 0, y: 0) && f.end == CGPoint(x: 1, y: 1))
        #expect(r.start == CGPoint(x: 0, y: 1) && r.end == CGPoint(x: 1, y: 0))
        #expect(l.start == CGPoint(x: 0, y: 0.5) && l.end == CGPoint(x: 1, y: 0.5))
    }

    @Test func aBorderGradientMadeRadialAndBackToOneColourKeepsItsColours() throws {
        let bench = card()
        bench.step { bench.store.updatePaint(.border(0), "Change Border") { $0.gradient = Self.across } }
        bench.step { bench.store.choosePaint(.radial, for: .border(0)) }
        let radial = try #require(bench.node("Card")?.border.gradient)
        #expect(radial.kind == .radial && radial.stops == Self.across.stops && radial.start == CGPoint(x: 0.5, y: 0.5))
        bench.step { bench.store.choosePaint(.solid, for: .border(0)) }
        let solid = try #require(bench.node("Card")).border
        #expect(solid.gradient == nil && solid.image == nil && solid.color == Self.red, "its first colour: \(solid.color)")
    }

    @Test func eachBorderTakesItsOwnPaint() throws {
        let bench = card()
        bench.step { bench.store.updateSelection("Add Border") { $0.add(Border(on: true, color: .white, width: 2, position: .outside)) } }
        bench.step { bench.store.choosePaint(.linear, for: .border(1)) }
        let n = try #require(bench.node("Card"))
        #expect(n.border.gradient == nil, "the first stays one colour")
        #expect(n[border: 1].gradient?.stops.first?.color == .white && n[border: 1].width == 2)
    }

    @Test func aGradientChosenForSeveralLayersGoesToThoseWithSuchABorder() throws {
        var other = CanvasTests.rect("Other", CGRect(x: 260, y: 40, width: 80, height: 80))
        other.border = Border(on: true, color: .white, width: 1)
        let bench = card([other])
        bench.step { bench.store.updateSelection("Add Border") { if $0.name == "Card" { $0.add(Border(on: true, color: .black, width: 1)) } } }
        bench.store.selection = [id(bench, "Card"), id(bench, "Other")]
        bench.step { bench.store.choosePaint(.linear, for: .border(0)) }
        #expect(bench.node("Card")?.border.gradient?.stops.first?.color == .black)
        #expect(bench.node("Other")?.border.gradient?.stops.first?.color == .white, "each from its own colour")
        // Only the card has a second border; the other gains none.
        bench.step { bench.store.choosePaint(.radial, for: .border(1)) }
        #expect(bench.node("Card")?[border: 1].gradient?.kind == .radial)
        #expect(bench.node("Other")?.moreBorders == nil)
    }

    @Test func textTurnedToAGradientShowsItInEveryLetterAndOneUndoBringsTheColoursBack() throws {
        let bench = Bench(extra: [hello()])
        let t = id(bench, "Hello")
        bench.store.selection = [t]
        bench.step { bench.store.choosePaint(.linear, for: .fill(0)) }
        let painted = try #require(bench.store.node(t))
        #expect(painted.fill.gradient != nil && painted.text == "Hello World")
        #expect(painted.spans?.contains { $0.look.color != nil } != true, "no letter keeps a colour of its own")
        bench.undo.undo()
        let back = try #require(bench.store.node(t))
        #expect(back.fill.gradient == nil && back.letters(in: NSRange(location: 6, length: 5)).first?.color == Self.green)
    }

    @Test func aShapesFillIsNotRestyledAsTextIs() throws {
        let bench = card()
        bench.step { bench.store.choosePaint(.linear, for: .fill(0)) }
        let n = try #require(bench.node("Card"))
        #expect(n.fill.gradient?.stops.first?.color == .white && n.border.gradient == nil)
    }

    @Test func choosingWhatIsAlreadyThereChangesNothingToUndo() throws {
        let bench = card()
        bench.step { bench.store.choosePaint(.solid, for: .border(0)) }
        #expect(!bench.undo.canUndo || bench.node("Card")?.border == Border(on: true, color: .black, width: 6, position: .inside))
    }

    // MARK: - Pictures

    @Test func aPictureForABorderTurnsItOnAndLeavesTheFillAlone() throws {
        let bench = card()
        bench.step { bench.store.updateSelection("Remove Border") { $0.border.on = false } }
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var painted = false
        bench.step { painted = bench.store.paint(.border(0), withPictureAt: file) }
        #expect(painted)
        let n = try #require(bench.node("Card"))
        #expect(n.border.on && n.border.image != nil && n.fill.image == nil)
        // It went into the design's own pictures, which are shared and kept with it.
        #expect(Collaboration.pictures(in: bench.store.doc) == Set(n.border.image!.assets))
        #expect(FileManager.default.fileExists(atPath: bench.store.url.appendingPathComponent("images/\(n.border.image!.asset)").path))
    }

    @Test func aFillOverTheFirstTakesNoPicture() throws {
        let bench = card()
        bench.step { bench.store.updateSelection("Add Fill") { $0.add(Fill(color: .black)) } }
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let before = bench.store.doc
        var painted = true
        bench.step { painted = bench.store.paint(.fill(1), withPictureAt: file) }
        #expect(!painted)
        #expect(bench.store.doc == before)
    }

    @Test func aFileThatIsNoPicturePaintsNothing() throws {
        let bench = card()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).txt")
        try Data("words".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = bench.store.doc
        var painted = true
        bench.step { painted = bench.store.paint(.border(0), withPictureAt: file) }
        #expect(!painted)
        #expect(bench.store.doc == before)
    }

    @Test func aPictureDroppedOnALockedTextComesInAsALayerOfItsOwn() throws {
        var t = hello()
        t.locked = true
        let bench = Bench(extra: [t])
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let at = try #require(bench.store.doc.absoluteFrame(of: id(bench, "Hello"))).center
        guard case .place = bench.store.plan(for: Dropped(pictures: [file]), at: at, on: id(bench, "Hello")) else {
            Issue.record("a locked text keeps its letters as they are")
            return
        }
    }

    @Test func severalPicturesDroppedOnATextInARepeatGridGoOneToEachCell() throws {
        let bench = Bench(extra: [hello()])
        bench.store.selection = [id(bench, "Hello")]
        bench.step { bench.store.makeRepeatGrid() }
        let grid = try #require(bench.store.selection.first)
        bench.step { bench.store.changeGrid(grid, "Repeat") { $0.columns = 2 } }
        let first = try #require(bench.store.node(grid)?.children.first)
        let files = try [pictureFile(), pictureFile()]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let at = try #require(bench.store.doc.absoluteFrame(of: first.id)).center
        bench.step { _ = bench.store.drop(Dropped(pictures: files), at: at, on: first.id) }
        let cells = try #require(bench.store.node(grid)).children.filter { $0.kind == .text }
        #expect(cells.count == 2)
        let pictures = cells.compactMap(\.fill.image?.asset)
        #expect(pictures.count == 2 && Set(pictures).count == 2, "a picture each: \(pictures)")
        // The words stay each cell's own; only their paint is new.
        #expect(cells.allSatisfy { $0.text == "Hello World" })
    }

    @Test func severalPicturesDroppedOnATextGiveItAPostEach() throws {
        let bench = Bench(extra: [hello()])
        let files = try [pictureFile(), pictureFile()]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let t = id(bench, "Hello")
        let at = try #require(bench.store.doc.absoluteFrame(of: t)).center
        bench.step { _ = bench.store.drop(Dropped(pictures: files), at: at, on: t) }
        let deck = bench.a
        #expect(deck.posts.count == 2)
        let painted = deck.posts.compactMap { deck.layers(of: $0).first { $0.kind == .text }?.fill.image?.asset }
        #expect(painted.count == 2 && Set(painted).count == 2, "\(painted)")
    }

    // MARK: - Stacking, flipping, turning and outlining

    @Test func restackedBordersTakeTheirPaintAlong() throws {
        let bench = card()
        bench.step {
            bench.store.updateSelection("Add Border") { n in
                var top = Border(on: true, color: .white, width: 2, position: .outside)
                top.gradient = Self.across
                n.add(top)
            }
        }
        bench.step { bench.store.updateSelection("Reorder Borders") { $0.move(.border, from: 1, to: 0) } }
        var n = try #require(bench.node("Card"))
        #expect(n.border.gradient == Self.across && n[border: 1].gradient == nil && n[border: 1].width == 6)
        // Taking away the first lets the next be the first, with its paint.
        bench.step { bench.store.updateSelection("Remove Border") { $0.remove(.border, at: 0) } }
        n = try #require(bench.node("Card"))
        #expect(n.borders.count == 1 && n.border.width == 6 && n.border.gradient == nil)
    }

    @Test func flippingTurnsABordersGradientAndPictureOver() throws {
        let bench = card()
        bench.step {
            bench.store.updateSelection("Change Border") { n in
                n.border.gradient = Self.across
                n.add(Border(on: true, color: .black, width: 2, image: Self.halves))
            }
        }
        bench.step { bench.store.flip(horizontally: true) }
        var n = try #require(bench.node("Card"))
        #expect(n.border.gradient?.start == CGPoint(x: 1, y: 0.5) && n.border.gradient?.end == CGPoint(x: 0, y: 0.5))
        #expect(n[border: 1].image?.flippedX == true)
        bench.step { bench.store.flip(horizontally: false) }
        n = try #require(bench.node("Card"))
        #expect(n[border: 1].image?.flippedY == true)
        // Flipped back both ways, it is as it was.
        bench.step { bench.store.flip(horizontally: true) }
        bench.step { bench.store.flip(horizontally: false) }
        n = try #require(bench.node("Card"))
        #expect(n.border.gradient == Self.across && n[border: 1].image == Self.halves)
    }

    @Test func aTurnedLayersBorderGradientTurnsWithIt() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 30, y: 30, width: 200, height: 100))
        box.fill.on = false
        box.border = Border(on: true, color: .black, width: 10, position: .inside, gradient: Self.across)
        box.rotation = 180
        let image = try #require(Renderer.image(of: page([box]), scale: 1))
        // Upside down, its red is on the right and its blue on the left.
        #expect(isBlue(pixel(image, 34, 80)), "\(pixel(image, 34, 80))")
        #expect(isRed(pixel(image, 226, 80)), "\(pixel(image, 226, 80))")
    }

    @Test func aDuplicateKeepsItsBorderAndLetterPaint() throws {
        var t = blocks(at: CGPoint(x: 40, y: 200))
        t.fill.gradient = Self.across
        let bench = card([t])
        bench.step { bench.store.updatePaint(.border(0), "Change Border") { $0.image = Self.halves } }
        bench.store.selection = [id(bench, "Card"), id(bench, "Blocks")]
        bench.step { bench.store.duplicateSelection() }
        let copies = bench.store.selection.compactMap { bench.store.node($0) }
        #expect(copies.count == 2)
        #expect(copies.first { $0.kind == .rectangle }?.border.image == Self.halves)
        #expect(copies.first { $0.kind == .text }?.fill.gradient == Self.across)
    }

    @Test func anOutlinedLineKeepsItsGradientAlongIt() throws {
        var line = Node(kind: .line, name: "Line", frame: CGRect(x: 20, y: 60, width: 200, height: 0))
        line.border = Border(on: true, color: .black, width: 10, position: .center, gradient: Self.across)
        let bench = Bench(extra: [line])
        bench.store.selection = [id(bench, "Line")]
        bench.step { bench.store.outlineBorders() }
        let shape = try #require(bench.store.selection.first.flatMap { bench.store.node($0) })
        #expect(shape.kind == .path && shape.fill.gradient != nil && shape.borders.isEmpty)
        // Drawn, it runs from red to blue as the line did.
        var board = Node(kind: .artboard, name: "P", frame: CGRect(x: 0, y: 0, width: 260, height: 120))
        board.fill.color = .white
        board.children = [shape]
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(isRed(pixel(image, 22, 60)) && isBlue(pixel(image, 218, 60)), "\(pixel(image, 22, 60)) \(pixel(image, 218, 60))")
    }

    // MARK: - Typing

    /// The text view the canvas types into, while it does.
    private func typing(_ bench: Bench) -> NSTextView? {
        func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
        return find(bench.canvas)
    }

    @Test func lettersTypedIntoShowTheirGradientAndStopWhenItGoes() throws {
        var t = blocks(at: CGPoint(x: 40, y: 40))
        t.fill.gradient = Self.across
        let bench = Bench(extra: [t])
        let b = id(bench, "Blocks")
        bench.step { bench.canvas.beginEditing(b, action: "Typing") }
        defer { bench.step { bench.canvas.endEditing() } }
        let manager = try #require(typing(bench)?.layoutManager as? TextLayout.Manager)
        #expect(manager.painting != nil, "the editor paints the letters as the canvas does")
        // Painted with one colour again, it paints nothing more.
        bench.step { bench.store.choosePaint(.solid, for: .fill(0)) }
        bench.canvas.syncEditor()
        #expect(manager.painting == nil)
    }

    @Test func lettersPickedWhileTypingTakeAColourAndTheRestKeepTheGradient() throws {
        var t = blocks(at: CGPoint(x: 40, y: 40))
        t.fill.gradient = Self.across
        let bench = Bench(extra: [t])
        let b = id(bench, "Blocks")
        bench.step { bench.canvas.beginEditing(b, action: "Typing") }
        let editor = try #require(typing(bench))
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        bench.step { bench.store.restyleLetters("Change Fill") { $0.color = Self.green } }
        bench.step { bench.canvas.endEditing() }
        let n = try #require(bench.store.node(b))
        #expect(n.fill.gradient == Self.across)
        #expect(n.letters(in: NSRange(location: 0, length: 2)).allSatisfy { $0.color == Self.green })
        let image = try #require(Renderer.image(of: page([Node.with(n, frame: CGRect(origin: CGPoint(x: 10, y: 10), size: n.frame.size))], width: 300, height: 80), scale: 1))
        let w = n.frame.width / 6
        #expect(pixel(image, Int(10 + w * 0.5), Int(10 + n.frame.height / 2)).g > 150, "the picked letters green")
        #expect(isBlue(pixel(image, Int(10 + w * 5.5), Int(10 + n.frame.height / 2))), "the last letter still the gradient's end")
    }

    // MARK: - Repeat grids and decks

    @Test func aBorderGradientIsTheSameInEveryCellAndChangesInAllAtOnce() throws {
        let bench = card()
        bench.step { bench.store.updatePaint(.border(0), "Change Border") { $0.gradient = Self.across } }
        bench.step { bench.store.makeRepeatGrid() }
        let grid = try #require(bench.store.selection.first)
        bench.step { bench.store.changeGrid(grid, "Repeat") { $0.columns = 3 } }
        var cells = try #require(bench.store.node(grid)).children
        #expect(cells.count == 3 && cells.allSatisfy { $0.border.gradient == Self.across })
        // Changed in the second cell, it changes in every cell.
        bench.store.selection = [cells[1].id]
        bench.step { bench.store.choosePaint(.radial, for: .border(0)) }
        cells = try #require(bench.store.node(grid)).children
        #expect(cells.allSatisfy { $0.border.gradient?.kind == .radial }, "\(cells.map { $0.border.gradient?.kind as Any })")
    }

    @Test func aGradientGivenToTextInTheFrontPostGoesToItInEveryPost() throws {
        let bench = Bench(extra: [hello()])
        bench.step { bench.store.addPost(to: bench.a.id) }
        let deck = bench.a
        let front = try #require(bench.store.front(of: deck))
        let text = try #require(deck.layers(of: front).first { $0.kind == .text })
        bench.store.selection = [text.id]
        bench.step { bench.store.updatePaint(.fill(0), "Fill with a Gradient") { $0.gradient = Self.across } }
        let now = bench.a
        for post in now.posts {
            #expect(now.layers(of: post).first { $0.kind == .text }?.fill.gradient == Self.across, "post \(post)")
        }
    }

    // MARK: - Drawing

    @Test func aSecondBorderIsDrawnOverTheFirstInItsOwnPaint() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 30, y: 30, width: 200, height: 100))
        box.fill.on = false
        box.border = Border(on: true, color: .black, width: 12, position: .inside)
        box.add(Border(on: true, color: .black, width: 6, position: .inside, gradient: Self.across))
        let image = try #require(Renderer.image(of: page([box]), scale: 1))
        // The outer half of the thick black border shows the gradient over it; the inner half stays black.
        #expect(isRed(pixel(image, 32, 80)), "\(pixel(image, 32, 80))")
        let inner = pixel(image, 39, 80)
        #expect(inner.r < 40 && inner.b < 40, "\(inner)")
    }

    @Test func aMissingBorderPictureShowsAQuietGreyWhereItWouldBe() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 30, y: 30, width: 200, height: 100))
        box.fill.on = false
        box.border = Border(on: true, color: .black, width: 10, position: .inside, image: Self.halves)
        let image = try #require(Renderer.image(of: page([box]), scale: 1))
        let edge = pixel(image, 34, 80)
        #expect(abs(edge.r - edge.b) < 6 && (200...230).contains(edge.r), "grey: \(edge)")
        #expect(isWhite(pixel(image, 130, 80)))
    }

    @Test func aMaskHoldersGradientBorderLiesOverWhatItHolds() throws {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 10, y: 10, width: 220, height: 140))
        photo.fill.color = .black
        var window = Node(kind: .rectangle, name: "Window", frame: CGRect(x: 30, y: 30, width: 200, height: 100))
        window.fill.on = false
        window.border = Border(on: true, color: .black, width: 10, position: .inside, gradient: Self.across)
        let bench = Bench(extra: [photo, window])
        bench.store.selection = [id(bench, "Photo"), id(bench, "Window")]
        bench.step { bench.store.maskSelection() }
        let mask = try #require(bench.a.children.first { $0.isMask })
        var board = page([mask])
        board.frame.size = CGSize(width: 260, height: 160)
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(isRed(pixel(image, 34, 80)) && isBlue(pixel(image, 226, 80)), "the rim over the photo: \(pixel(image, 34, 80)) \(pixel(image, 226, 80))")
        let held = pixel(image, 130, 80)
        #expect(held.r < 30 && held.g < 30 && held.b < 30, "the photo inside: \(held)")
    }

    @Test func fadedLettersShowTheirGradientFaded() throws {
        var t = blocks()
        t.fill.gradient = Self.across
        t.opacity = 0.5
        let r = t.frame
        let image = try #require(Renderer.image(of: page([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        let left = pixel(image, Int(r.minX) + 3, Int(r.midY))
        #expect(left.r > 230 && (100...160).contains(left.g), "half red over white: \(left)")
    }

    @Test func lettersTurnedInDepthKeepTheirGradient() throws {
        var t = blocks()
        t.fill.gradient = Self.across
        t.transform3D = Transform3D(x: 0, y: 25, z: 0)
        let r = t.frame
        let image = try #require(Renderer.image(of: page([t], width: r.maxX + 20, height: r.maxY + 20), scale: 1))
        let row = (Int(r.minX)...Int(r.maxX)).map { pixel(image, $0, Int(r.midY)) }
        #expect(row.contains(where: isRed) && row.contains(where: isBlue), "red and blue across the turned letters")
        #expect(!row.contains { $0.r < 40 && $0.g < 40 && $0.b < 40 }, "no letter left black")
    }

    @Test func centredLettersInAWideBoxTakeTheMiddleOfTheGradient() throws {
        var t = blocks("\u{2588}\u{2588}")
        t.style?.sizing = .fixed
        t.style?.align = .center
        t.frame = CGRect(x: 10, y: 10, width: 300, height: 60)
        t.fill.gradient = Self.across
        let image = try #require(Renderer.image(of: page([t], width: 320, height: 80), scale: 1))
        // The gradient spans the box, not the letters: in its middle they are half red, half blue.
        let middle = pixel(image, 160, 30)
        #expect(middle.r > 90 && middle.b > 90 && middle.g < 60, "\(middle)")
    }

    @Test func aLineThroughPaintedWordsIsPaintedToo() throws {
        var t = blocks("\u{2588}   \u{2588}")
        t.style?.strikethrough = true
        t.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.red)],
                                   start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        t.refit()
        let r = t.frame
        let image = try #require(Renderer.image(of: page([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        // In the gap between the blocks, only the line through them is drawn: red, not black.
        let column = (Int(r.minY)...Int(r.maxY)).map { pixel(image, Int(r.midX), $0) }
        #expect(column.contains(where: isRed), "the strike, red")
        #expect(!column.contains { $0.r < 60 && $0.g < 60 && $0.b < 60 }, "nothing black")
    }

    @Test func aListsMarkersArePaintedAsTheirWordsAre() throws {
        var t = blocks("\u{2588}\u{2588}")
        t.restyleLetters(in: nil) { $0.list = .bullet }
        t.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.red)],
                                   start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        t.refit()
        let laid = TextLayout.layout(t)
        let marker = try #require(TextLayout.markers(laid.manager).first)
        let r = t.frame
        let image = try #require(Renderer.image(of: page([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        let w = Int(TextLayout.width(of: marker.text, in: marker.font).rounded(.up))
        var seen: [(r: Int, g: Int, b: Int, a: Int)] = []
        for x in 0..<max(w, 1) {
            for dy in -Int(marker.font.pointSize / 2)...0 {
                seen.append(pixel(image, Int(r.minX + marker.at.x) + x, Int(r.minY + marker.at.y) + dy))
            }
        }
        #expect(seen.contains(where: isRed), "the bullet is painted")
        #expect(!seen.contains { $0.r < 60 && $0.g < 60 && $0.b < 60 }, "and not left black")
    }

    @Test func aPictureInTextIsDevelopedAsItsLayersPictureIs() throws {
        let (assets, folder) = try halvesFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var t = blocks()
        t.fill.image = Self.halves
        var dark = Develop()
        dark[.exposure] = -2
        t.fill.image?.develop = dark
        let r = t.frame
        let image = try #require(Renderer.image(of: page([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1, assets: assets))
        let left = pixel(image, Int(r.minX) + 3, Int(r.midY))
        #expect(left.r < 170 && left.r > left.b + 40 && left.r > left.g + 40, "darker red: \(left)")
    }

    // MARK: - Export and files

    @Test func aPNGShowsBordersAndLettersAsTheCanvasDoes() throws {
        let (assets, folder) = try halvesFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 20, y: 20, width: 200, height: 60))
        box.fill.on = false
        box.border = Border(on: true, color: .black, width: 8, position: .inside, image: Self.halves)
        var t = blocks(at: CGPoint(x: 20, y: 100))
        t.fill.gradient = Self.across
        let board = page([box, t], width: 280, height: 160)
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = Exporter.export([ExportItem(artboard: board)], format: .png, scale: 1, name: "Paint", to: out, assets: assets)
        let file = try #require(files.first)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(isRed(pixel(image, 23, 50)) && isBlue(pixel(image, 217, 50)), "the picture border")
        #expect(isRed(pixel(image, Int(t.frame.minX) + 3, Int(t.frame.midY))) && isBlue(pixel(image, Int(t.frame.maxX) - 4, Int(t.frame.midY))), "the letters")
    }

    @Test func aPDFKeepsPicturesInBordersAndLetters() throws {
        let (assets, folder) = try halvesFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 20, y: 20, width: 200, height: 60))
        box.fill.on = false
        box.border = Border(on: true, color: .black, width: 8, position: .inside, image: Self.halves)
        var t = blocks(at: CGPoint(x: 20, y: 100))
        t.fill.image = Self.halves
        let board = page([box, t], width: 280, height: 160)
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: board.frame.size)
        let consumer = try #require(CGDataConsumer(data: data))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        Renderer.drawPDFPage(board, in: ctx, assets: assets)
        ctx.closePDF()
        let provider = try #require(CGDataProvider(data: data))
        let pdf = try #require(CGPDFDocument(provider)?.page(at: 1))
        let bitmap = try #require(Renderer.bitmap(board.frame.size))
        bitmap.setFillColor(CGColor.white)
        bitmap.fill(media)
        bitmap.drawPDFPage(pdf)
        let image = try #require(bitmap.makeImage())
        #expect(isRed(pixel(image, 23, 50)) && isBlue(pixel(image, 217, 50)), "the picture border")
        #expect(isRed(pixel(image, Int(t.frame.minX) + 3, Int(t.frame.midY))) && isBlue(pixel(image, Int(t.frame.maxX) - 4, Int(t.frame.midY))), "the letters")
        #expect(isWhite(pixel(image, Int(t.frame.midX), Int(t.frame.minY) - 4)), "nothing round the letters")
    }

    @Test func svgLettersShowTheirPictureAsTheCanvasDoes() throws {
        let (assets, folder) = try halvesFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var t = blocks(at: CGPoint(x: 20, y: 20))
        t.fill.image = Self.halves
        let board = page([t], width: 300, height: 80)
        let svg = SVGWriter.document(for: ExportItem(artboard: board), bounds: board.frame, assets: assets)
        let drawn = try #require(NSImage(data: Data(svg.utf8)))
        let ctx = try #require(Renderer.bitmap(board.frame.size))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        drawn.draw(in: NSRect(origin: .zero, size: board.frame.size))
        NSGraphicsContext.current = nil
        let image = try #require(ctx.makeImage())
        let r = t.frame
        #expect(isRed(pixel(image, Int(r.minX) + 3, Int(r.midY))), "left: \(pixel(image, Int(r.minX) + 3, Int(r.midY)))")
        #expect(isBlue(pixel(image, Int(r.maxX) - 4, Int(r.midY))), "right: \(pixel(image, Int(r.maxX) - 4, Int(r.midY)))")
    }

    @Test func aDesignSavedAndOpenedAgainKeepsEveryPaint() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 20, y: 20, width: 200, height: 60))
        box.border = Border(on: true, color: .black, width: 8, position: .outside, gradient: Self.across)
        box.add(Border(on: true, color: .black, width: 2, image: Self.halves))
        var t = hello()
        t.fill.gradient = Self.across
        var doc = BezzleDocument()
        doc.nodes = [page([box, t])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(doc, to: url)
        let read = try DesignFile.read(url)
        #expect(read == doc)
        #expect(read.nodes[0].children[0][border: 1].image == Self.halves)
        // Its thumbnail reads the border's picture at a size of its own.
        #expect(Library.pictureSizes(in: read, thumbnail: CGSize(width: 200, height: 150), scale: 2)["halves.png"] != nil)
    }

    // MARK: - Sharing

    @Test func twoPeoplePaintingTheBorderAndTheFillOfOneLayerBothKeepTheirChange() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 20, y: 20, width: 200, height: 60))
        box.border = Border(on: true, color: .black, width: 4)
        var doc = BezzleDocument()
        doc.nodes = [page([box])]
        var ada = PaintPeer("ada", doc: doc), bo = PaintPeer("bo", doc: doc)
        ada.receive(bo.state)
        bo.receive(ada.state)
        ada.edit { $0.update(box.id) { $0.border.gradient = Self.across } }
        bo.edit { $0.update(box.id) { $0.fill.color = Self.green } }
        var peers = [ada, bo]
        PaintPeer.sync(&peers)
        for p in peers {
            let n = try #require(p.doc.node(box.id))
            #expect(n.border.gradient == Self.across && n.fill.color == Self.green, "\(p.name)")
        }
    }

    @Test func aPictureSomeoneGaveABorderIsOneToSendAndFetch() throws {
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 20, y: 20, width: 200, height: 60))
        box.border = Border(on: true, color: .black, width: 4)
        var doc = BezzleDocument()
        doc.nodes = [page([box])]
        var ada = PaintPeer("ada", doc: doc), bo = PaintPeer("bo", doc: doc)
        bo.receive(ada.state)
        ada.edit { $0.update(box.id) { $0.border.image = Self.halves } }
        bo.receive(ada.state)
        #expect(bo.doc.node(box.id)?.border.image == Self.halves)
        #expect(Collaboration.pictures(in: bo.doc) == ["halves.png"])
    }

    // MARK: - The assistant

    private func call(_ tools: MCPTools, _ bench: Bench, _ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    @Test func theAssistantPaintsSeveralBordersAndReadsThemBack() async throws {
        let bench = card()
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let answer = await call(tools, bench, "update_layers", ["updates": [["layer": "Card", "border": [
            ["color": "#000000", "width": 6, "position": "inside"],
            ["width": 2, "position": "outside", "gradient": ["type": "radial", "stops": ["#FF0000", "#0000FF"]]],
        ]]]])
        #expect(!answer.failed, "\(answer.text)")
        let n = try #require(bench.node("Card"))
        #expect(n.borders.count == 2 && n.border.gradient == nil && n[border: 1].gradient?.kind == .radial)
        let read = await call(tools, bench, "get_layers", ["layers": ["Card"]])
        let layer = ((try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any])?["layers"] as? [[String: Any]]
        let borders = layer?.first?["border"] as? [[String: Any]]
        #expect(borders?.count == 2 && borders?[1]["gradient"] != nil && borders?[0]["gradient"] == nil, "\(read.text)")
    }

    @Test func theAssistantPaintsTextAndReadsItsGradientBack() async throws {
        let bench = Bench(extra: [hello()])
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let answer = await call(tools, bench, "update_layers", ["updates": [["layer": "Hello",
            "fill": ["gradient": ["type": "linear", "stops": ["#FF0000", "#0000FF"], "angle": 90]]]]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.node("Hello")?.fill.gradient?.stops.count == 2)
        let read = await call(tools, bench, "get_layers", ["layers": ["Hello"]])
        #expect(read.text.contains("\"gradient\""), "\(read.text)")
    }

    @Test func theAssistantPutsAPictureInALinesStroke() async throws {
        var line = Node(kind: .line, name: "Line", frame: CGRect(x: 20, y: 60, width: 200, height: 0))
        line.border = Border(on: true, color: .black, width: 6, position: .center)
        let bench = Bench(extra: [line])
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // A design that can hold pictures, as one made now is.
        _ = bench.store.importPicture(file)
        let answer = await call(tools, bench, "place_image", ["file": file.path, "layer": "Line", "into": "border"])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.node("Line")?.border.image != nil)
        // A line has no fill for a picture to go in.
        let fill = await call(tools, bench, "place_image", ["file": file.path, "layer": "Line"])
        #expect(fill.failed)
    }
}

/// One Mac's copy of a shared design, as `Collaboration` keeps it without iCloud, as in the mask suite.
private struct PaintPeer {
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

    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    mutating func edit(_ change: (inout BezzleDocument) -> Void) {
        change(&doc)
        commit()
    }

    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }

    static func sync(_ peers: inout [PaintPeer]) {
        for _ in 0..<4 {
            for i in peers.indices {
                for j in peers.indices where j != i { peers[i].receive(peers[j].state) }
            }
        }
    }
}
