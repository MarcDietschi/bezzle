import Testing
import AppKit
@testable import Bezzle

/// Styles and the dark taken through everything that can happen to them: every kind of look
/// named from its card, given to other layers and changed on any of them or in the design's list;
/// what is and is not part of a look; names let go of, renamed and taken away; looks found on
/// several layers; repeat grids, stacks and components; artboards made dark, light again and
/// without a dark look, layers moved between them; copied into another design, saved, read, driven
/// by the assistant, shared between Macs changing things at once; and every step undone. After
/// each, `problems` says what is wrong anywhere in the design. See `Style`.
@MainActor
struct StyleSuiteTests {
    // MARK: - Fixtures

    static let paper = RGBA(hex: "F5F1EA")!, ink = RGBA(hex: "1F1D1A")!, blue = RGBA(hex: "3559C7")!
    static let red = RGBA(hex: "E8664A")!, green = RGBA(hex: "2E8B57")!

    /// Artboard A holding, bottom first: "Back", paper filling it; "Card", a white rectangle with
    /// round corners and a shadow; "Title", 32 pt bold ink; "Body", 16 pt ink; "Button", a blue
    /// rectangle with "Label", white words, on it; "Ring", an ellipse with a blue border and no
    /// fill; and "Photo", a picture. Artboard B holds "Card B", white with the same corners and
    /// shadow, and "Title B", 32 pt bold ink.
    private func page() -> Bench {
        func rect(_ name: String, _ r: CGRect, _ c: RGBA, radius: CGFloat = 0, shadow: Bool = false) -> Node {
            var n = CanvasTests.rect(name, r)
            n.fill.color = c
            n.cornerRadius = radius
            if shadow { n.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.14), x: 0, y: 8, blur: 24) }
            return n
        }
        func text(_ name: String, _ words: String, _ p: CGPoint, size: CGFloat, face: String = "Regular", color: RGBA) -> Node {
            var t = Node(kind: .text, name: name, frame: CGRect(origin: p, size: .zero))
            t.text = words
            t.style?.size = size
            t.style?.face = face
            t.fill.color = color
            t.refit()
            return t
        }
        var ring = Node(kind: .ellipse, name: "Ring", frame: CGRect(x: 300, y: 20, width: 60, height: 60))
        ring.fill.on = false
        ring.border = Border(on: true, color: Self.blue, width: 2)
        var photo = rect("Photo", CGRect(x: 220, y: 100, width: 60, height: 60), .white)
        photo.fill.image = ImageFill(asset: "a.png", size: CGSize(width: 4, height: 4))
        let b = Bench(extra: [
            rect("Back", CGRect(x: 0, y: 0, width: 400, height: 300), Self.paper),
            rect("Card", CGRect(x: 20, y: 20, width: 180, height: 120), .white, radius: 16, shadow: true),
            text("Title", "Hello", CGPoint(x: 30, y: 30), size: 32, face: "Bold", color: Self.ink),
            text("Body", "Some words", CGPoint(x: 30, y: 80), size: 16, color: Self.ink),
            rect("Button", CGRect(x: 220, y: 200, width: 160, height: 44), Self.blue, radius: 12),
            text("Label", "Go", CGPoint(x: 240, y: 210), size: 16, color: .white),
            ring, photo,
        ])
        let o = b.b.frame.origin
        b.step { b.store.add(rect("Card B", CGRect(x: o.x + 20, y: o.y + 20, width: 180, height: 120), .white, radius: 16, shadow: true), onto: b.b.id) }
        b.step { b.store.add(text("Title B", "There", CGPoint(x: o.x + 30, y: o.y + 30), size: 32, face: "Bold", color: Self.ink), onto: b.b.id) }
        b.store.selection = []
        return b
    }

    private func id(_ b: Bench, _ name: String) -> UUID { b.node(name)?.id ?? UUID() }
    private func n(_ b: Bench, _ name: String) -> Node { b.node(name) ?? Node(kind: .rectangle, name: "missing \(name)", frame: .zero) }
    private func a(_ b: Bench) -> Node { b.store.doc.nodes.first { $0.name == "A" }! }
    private func bb(_ b: Bench) -> Node { b.store.doc.nodes.first { $0.name == "B" }! }

    /// Names the look these layers have at `place`, as the dashed chip of its card does.
    @discardableResult
    private func nameIt(_ b: Bench, _ names: [String], _ place: StylePlace, _ name: String) -> UUID {
        b.store.selection = names.map { id(b, $0) }
        var made: UUID?
        b.step { made = b.store.nameLook(at: place, name) }
        return made ?? UUID()
    }

    private func use(_ b: Bench, _ style: UUID, on names: [String], at place: StylePlace) {
        guard let s = b.store.style(style) else { Issue.record("no style"); return }
        b.store.selection = names.map { id(b, $0) }
        b.step { b.store.use(s, at: place) }
    }

    private func change(_ b: Bench, _ names: [String], _ change: @escaping (inout Node) -> Void) {
        b.store.selection = names.map { id(b, $0) }
        b.step { b.store.updateSelection("Change") { change(&$0) } }
    }

    /// What is wrong with the design's styles: a layer named after a style that does not look as
    /// that style does where the layer lies (light or dark), or after one the design has not, or
    /// one that cannot go there; corners named while they differ; a post's own look still named;
    /// a style listed twice, or kept as it should not be; words not fitted to their box.
    private func problems(_ doc: BezzleDocument, dangling: Bool = false, fitted: Bool = true) -> [String] {
        var out: [String] = []
        let styles = doc.stylesByID
        if let list = doc.styles {
            if list.isEmpty { out.append("styles is empty rather than none") }
            if Set(list.map(\.id)).count != list.count { out.append("a style is listed twice") }
            for s in list {
                if s.look != s.look.kept { out.append("\(s.name) is not kept as a style is") }
                if let d = s.dark, d.kind != s.kind { out.append("\(s.name) is another kind in the dark") }
            }
        }
        func visit(_ n: Node, dark: Bool) {
            let own = Set(n.own ?? [])
            for place in StylePlace.all(in: n) {
                guard let id = place.named(in: n) else { continue }
                guard let s = styles[id] else {
                    if !dangling { out.append("\(n.name) is named after a style the design has not") }
                    continue
                }
                let shown = s.look(dark: dark)
                if !place.takes(shown, in: n) { out.append("\(n.name) is named after \(s.name), which cannot go there") }
                else if !place.shows(shown, in: n) { out.append("\(n.name) does not look as \(s.name) does\(dark ? " in the dark" : "")") }
                if place == .corners, n.corners != nil { out.append("\(n.name)'s corners differ but are named") }
                if place.fields.contains(where: own.contains) { out.append("\(n.name) keeps its own look but is named") }
            }
            if fitted, n.kind == .text, n.style?.sizing == .autoWidth {
                var m = n
                m.refit()
                if abs(m.frame.width - n.frame.width) > 0.5 || abs(m.frame.height - n.frame.height) > 0.5 { out.append("\(n.name) is not fitted to its words") }
            }
            n.children.forEach { visit($0, dark: dark) }
        }
        for top in doc.nodes { visit(top, dark: top.showsDark) }
        for m in doc.components ?? [] { visit(m, dark: false) }
        return out
    }

    // MARK: - Naming

    @Test func everyKindOfLookCanBeNamedFromItsCard() {
        let b = page()
        let colour = nameIt(b, ["Card"], .fill(0), "Surface")
        let border = nameIt(b, ["Ring"], .border(0), "Accent")
        let shadow = nameIt(b, ["Card"], .shadow(0), "Lifted")
        let type = nameIt(b, ["Title"], .text, "Title")
        let corners = nameIt(b, ["Card"], .corners, "Soft")
        let kinds = [colour, border, shadow, type, corners].compactMap { b.store.style($0)?.kind }
        #expect(kinds == [.colour, .colour, .shadow, .text, .corners])
        #expect(n(b, "Card").fill.named == colour && n(b, "Card").shadow.named == shadow && n(b, "Card").cornersNamed == corners)
        #expect(n(b, "Ring").border.named == border && n(b, "Title").style?.named == type)
        #expect(b.store.style(border)?.look == .colour(ColourLook(color: Self.blue)))
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
        // Each named card says so.
        b.store.selection = [id(b, "Card")]
        #expect(b.store.sharedStyle(at: .fill(0))?.name == "Surface" && b.store.sharedStyle(at: .corners)?.name == "Soft")
    }

    @Test func aPictureHasNoLookToName() {
        let b = page()
        b.store.selection = [id(b, "Photo")]
        #expect(b.store.holding(.fill(0)).isEmpty)
        var made: UUID?
        b.step { made = b.store.nameLook(at: .fill(0), "Photo") }
        #expect(made == nil && b.store.doc.styles == nil)
        // Nor is a colour style offered there, nor taken.
        let s = nameIt(b, ["Card"], .fill(0), "Surface")
        b.store.selection = [id(b, "Photo")]
        #expect(b.store.styles(for: .fill(0)).isEmpty)
        b.step { b.store.use(b.store.style(s)!, at: .fill(0)) }
        #expect(n(b, "Photo").fill.named == nil && n(b, "Photo").fill.image != nil)
    }

    @Test func namesAreTidiedAndWhatIsLeftOutIsSuggested() {
        let b = page()
        let trimmed = nameIt(b, ["Card"], .fill(0), "   Surface \n")
        #expect(b.store.style(trimmed)?.name == "Surface")
        let long = nameIt(b, ["Button"], .fill(0), String(repeating: "x", count: 100))
        #expect(b.store.style(long)?.name.count == 60)
        let suggested = nameIt(b, ["Title"], .fill(0), "")
        #expect(b.store.style(suggested)?.name == String(localized: "Black"))
        // A second black is numbered on, never the same name.
        change(b, ["Body"], { $0.fill.color = RGBA(hex: "202020")! })
        let second = nameIt(b, ["Body"], .fill(0), " ")
        #expect(b.store.style(second)?.name == "\(String(localized: "Black")) 2")
        // Every kind has a name of its own to start with.
        #expect(b.store.suggestedName(for: .text(TypeLook(n(b, "Title").style!))) == String(localized: "Title"))
        #expect(b.store.suggestedName(for: .text(TypeLook(n(b, "Body").style!))) == String(localized: "Body"))
        #expect(b.store.suggestedName(for: .corners(CornerLook(radius: 12))) == String(localized: "Soft"))
        #expect(StyleNames.colour(Self.paper) == String(localized: "Ivory") && StyleNames.colour(.white) == String(localized: "White"))
        #expect(StyleNames.colour(Self.ink) == String(localized: "Black") && StyleNames.colour(Self.blue) == String(localized: "Blue"))
        #expect(StyleNames.colour(RGBA(hex: "FFFF00")!) == String(localized: "Yellow") && StyleNames.colour(RGBA(hex: "8B4513")!) == String(localized: "Brown"))
    }

    @Test func namingSeveralLayersGivesThemAllTheFirstsLook() {
        let b = page()
        change(b, ["Body"], { $0.style?.size = 18 })
        let s = nameIt(b, ["Title", "Body"], .text, "Heading")
        #expect(n(b, "Title").style?.named == s && n(b, "Body").style?.named == s)
        #expect(n(b, "Body").style?.size == 32 && n(b, "Body").style?.face == "Bold")
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func theOfferNamesOnlyTheLayersThatLookTheSame() {
        let b = page()
        let s = nameIt(b, ["Card"], .fill(0), "Surface")
        guard case .nameToo(_, let uses)? = b.store.styleShow.offer?.kind else { Issue.record("no offer"); return }
        // Card B and the label's words are white too; a picture is no colour, and the blue button is another.
        let layers = Set(uses.map(\.layer))
        #expect(layers.contains(id(b, "Card B")) && layers.contains(id(b, "Label")) && !layers.contains(id(b, "Photo")))
        #expect(!layers.contains(id(b, "Card")) && !layers.contains(id(b, "Button")))
        b.step { b.store.take(b.store.styleShow.offer!) }
        #expect(n(b, "Card B").fill.named == s && n(b, "Label").fill.named == s && n(b, "Photo").fill.named == nil)
        #expect(b.store.styleShow.offer == nil)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func nothingIsOfferedWhenNothingElseLooksTheSame() {
        let b = page()
        nameIt(b, ["Button"], .corners, "Button corners")
        #expect(b.store.styleShow.offer == nil)
        // An offer goes with the next change.
        nameIt(b, ["Card"], .fill(0), "Surface")
        #expect(b.store.styleShow.offer != nil)
        change(b, ["Ring"], { $0.opacity = 0.5 })
        #expect(b.store.styleShow.offer == nil)
    }

    // MARK: - Using

    @Test func aColourGoesOnFillsWordsAndBorders() {
        let b = page()
        let s = nameIt(b, ["Button"], .fill(0), "Brand")
        use(b, s, on: ["Title"], at: .fill(0))
        use(b, s, on: ["Card"], at: .border(0))
        #expect(n(b, "Title").fill.color == Self.blue && n(b, "Title").fill.named == s)
        // A border that is off takes the name and colour, and stays off.
        #expect(n(b, "Card").border.named == s && n(b, "Card").border.color == Self.blue && !n(b, "Card").border.on)
        #expect(n(b, "Ring").border.named == nil)
        change(b, ["Button"], { $0.fill.color = Self.red })
        #expect(n(b, "Title").fill.color == Self.red && n(b, "Card").border.color == Self.red)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aGradientStyleKeepsEachLayersDirectionAndPaintsWordsAndBorders() {
        let b = page()
        let g = Gradient.fading(from: Self.blue)
        change(b, ["Button"], { $0.fill.gradient = g })
        let s = nameIt(b, ["Button"], .fill(0), "Sky")
        use(b, s, on: ["Title"], at: .fill(0))
        use(b, s, on: ["Ring"], at: .border(0))
        #expect(n(b, "Title").fill.gradient?.stops == g.stops && n(b, "Ring").border.gradient?.stops == g.stops)
        // Turned on the ring alone, it runs its own way; recoloured anywhere, everywhere.
        change(b, ["Ring"], { $0.border.gradient?.end = CGPoint(x: 1, y: 0) })
        #expect(n(b, "Button").fill.gradient?.end == g.end)
        var stops = g.stops
        stops[1].color = Self.red
        change(b, ["Title"], { $0.fill.gradient?.stops = stops })
        #expect(n(b, "Button").fill.gradient?.stops == stops && n(b, "Ring").border.gradient?.end == CGPoint(x: 1, y: 0))
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func namedTypeLeavesAlignTheBoxAndColouredLettersAlone() {
        let b = page()
        let s = nameIt(b, ["Title"], .text, "Title")
        // Body has a word set bigger and a word coloured, and is centred in a box of its own width.
        change(b, ["Body"], { n in
            n.style?.align = .center
            n.style?.sizing = .autoHeight
            n.frame.size.width = 200
            n.spans = [TextSpan(text: "Some ", look: TextLook(size: 40)), TextSpan(text: "words", look: TextLook(color: Self.red))]
        })
        use(b, s, on: ["Body"], at: .text)
        let body = n(b, "Body")
        #expect(body.style?.size == 32 && body.style?.face == "Bold" && body.style?.align == .center && body.style?.sizing == .autoHeight)
        // The size set apart follows the type; the colour stays the word's.
        #expect(body.spans?.contains { $0.look.size != nil } != true)
        #expect(body.spans?.contains { $0.look.color == Self.red } == true)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func theStylesOfferedFitThePlace() {
        let b = page()
        let colour = nameIt(b, ["Card"], .fill(0), "Surface")
        let type = nameIt(b, ["Title"], .text, "Title")
        let corners = nameIt(b, ["Card"], .corners, "Soft")
        b.store.selection = [id(b, "Button")]
        #expect(b.store.styles(for: .fill(0)).map(\.id) == [colour])
        #expect(b.store.styles(for: .corners).map(\.id) == [corners])
        b.store.selection = [id(b, "Body")]
        #expect(b.store.styles(for: .text).map(\.id) == [type])
        // An ellipse has no corners to name.
        #expect(!StylePlace.all(in: n(b, "Ring")).contains(.corners))
    }

    @Test func aNameOfAnotherKindIsNoNameForAPlace() {
        let b = page()
        let type = nameIt(b, ["Title"], .text, "Title")
        // As a merge, or another app, could leave it.
        b.step { b.store.edit("x") { $0.update(id(b, "Card")) { $0.fill.named = type } } }
        #expect(n(b, "Card").fill.named == nil && n(b, "Card").fill.color == .white)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - Changing through layers

    @Test func everyPartOfAStyleFollowsAChangeOnAnyLayer() {
        let b = page()
        let colour = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        let shadow = nameIt(b, ["Card", "Card B"], .shadow(0), "Lifted")
        let type = nameIt(b, ["Title", "Title B"], .text, "Title")
        let corners = nameIt(b, ["Card", "Card B"], .corners, "Soft")
        change(b, ["Card"], { $0.fill.color = Self.green })
        change(b, ["Card"], { $0.shadow.y = 20; $0.shadow.blur = 40; $0.shadow.spread = 4 })
        change(b, ["Card"], { $0.radii = Array(repeating: 6, count: 4); $0.cornerSmoothing = 0.6 })
        change(b, ["Title"], { $0.style?.size = 40; $0.style?.tracking = 20; $0.style?.lineSpacing = 50; $0.style?.letterCase = .upper })
        let card = n(b, "Card B"), title = n(b, "Title B")
        #expect(card.fill.color == Self.green && card.shadow.y == 20 && card.shadow.blur == 40 && card.shadow.spread == 4)
        #expect(card.cornerRadius == 6 && card.cornerSmoothing == 0.6)
        #expect(title.style?.size == 40 && title.style?.tracking == 20 && title.style?.lineSpacing == 50 && title.style?.letterCase == .upper)
        #expect([colour, shadow, type, corners].allSatisfy { b.store.layers(using: $0).count == 2 })
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func whatIsNoPartOfAStyleStaysEachLayersOwn() {
        let b = page()
        let border = nameIt(b, ["Ring"], .border(0), "Accent")
        use(b, border, on: ["Card"], at: .border(0))
        change(b, ["Card"], { $0.border.on = true })
        nameIt(b, ["Card", "Card B"], .shadow(0), "Lifted")
        let type = nameIt(b, ["Title", "Title B"], .text, "Title")
        change(b, ["Ring"], { $0.border.width = 8; $0.border.position = .outside; $0.border.dash = 4 })
        change(b, ["Card"], { $0.shadow.on = false; $0.opacity = 0.5; $0.frame.origin.x += 10 })
        change(b, ["Title"], { $0.style?.align = .right; $0.style?.sizing = .autoHeight })
        #expect(n(b, "Card").border.width == 1 && n(b, "Card").border.dash == 0)
        #expect(n(b, "Card B").shadow.on && n(b, "Card B").opacity == 1)
        #expect(n(b, "Title B").style?.align == .left && n(b, "Title B").style?.sizing == .autoWidth)
        #expect(n(b, "Title").style?.named == type && n(b, "Ring").border.named == border)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func cornersMadeToDifferLetGoOfTheirName() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B", "Button"], .corners, "Soft")
        change(b, ["Card"], { $0.radii = [16, 16, 0, 0] })
        #expect(n(b, "Card").cornersNamed == nil && n(b, "Card").radii == [16, 16, 0, 0])
        #expect(n(b, "Card B").cornerRadius == 16 && b.store.style(s)?.look == .corners(CornerLook(radius: 16)))
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func wordsGrownWithTheirBoxLetGoOfTheirType() {
        let b = page()
        let s = nameIt(b, ["Title", "Title B"], .text, "Title")
        change(b, ["Title"], { $0.scaleType(by: 1.5) })
        #expect(n(b, "Title").style?.named == nil && n(b, "Title").style?.size == 48)
        #expect(n(b, "Title B").style?.size == 32 && b.store.style(s)?.look.type?.size == 32)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aLayerFlippedOverKeepsItsNamedGradientAndChangesNoOther() {
        let b = page()
        change(b, ["Button", "Card"], { $0.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .white), GradientStop(offset: 1, color: Self.blue)],
                                                                    start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5)) })
        let s = nameIt(b, ["Button", "Card"], .fill(0), "Sky")
        b.store.selection = [id(b, "Button")]
        b.step { b.store.flip(horizontally: true) }
        #expect(n(b, "Button").fill.named == s && n(b, "Button").fill.gradient?.start == CGPoint(x: 1, y: 0.5))
        #expect(n(b, "Card").fill.gradient?.start == CGPoint(x: 0, y: 0.5))
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func onlyHereKeepsAChangeOnTheSelectionAlone() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        change(b, ["Card"], { $0.fill.color = Self.green })
        guard case .onlyHere? = b.store.styleShow.offer?.kind else { Issue.record("no offer"); return }
        #expect(b.store.styleShow.offer?.layers == [id(b, "Card B")])
        b.step { b.store.take(b.store.styleShow.offer!) }
        #expect(n(b, "Card").fill.color == Self.green && n(b, "Card").fill.named == nil)
        #expect(n(b, "Card B").fill.color == .white && b.store.style(s)?.look.paint?.color == .white)
        // Undone, the change is everywhere again; undone again, nowhere.
        b.undo.undo()
        #expect(n(b, "Card B").fill.color == Self.green && n(b, "Card").fill.named == s)
        b.undo.undo()
        #expect(n(b, "Card").fill.color == .white && n(b, "Card B").fill.color == .white)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aChangeToEveryUserAtOnceOffersNothing() {
        let b = page()
        nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        change(b, ["Card", "Card B"], { $0.fill.color = Self.green })
        #expect(b.store.styleShow.offer == nil)
        #expect(Set(b.store.styleShow.wave?.layers ?? []) == [id(b, "Card"), id(b, "Card B")])
    }

    @Test func undoAndRedoTakeAStyleChangeBackEverywhere() {
        let b = page()
        let s = nameIt(b, ["Title", "Title B"], .text, "Title")
        change(b, ["Title"], { $0.style?.size = 50 })
        let wide = n(b, "Title B").frame.width
        b.undo.undo()
        #expect(n(b, "Title B").style?.size == 32 && b.store.style(s)?.look.type?.size == 32)
        #expect(n(b, "Title B").frame.width < wide)
        b.undo.redo()
        #expect(n(b, "Title B").style?.size == 50 && abs(n(b, "Title B").frame.width - wide) < 0.5)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - From the list

    @Test func renamingKeepsLooksAndANameLeftEmptyStays() {
        let b = page()
        let s = nameIt(b, ["Card"], .fill(0), "Surface")
        b.step { b.store.renameStyle(s, to: "Paper") }
        #expect(b.store.style(s)?.name == "Paper")
        b.step { b.store.renameStyle(s, to: "   ") }
        #expect(b.store.style(s)?.name == "Paper" && n(b, "Card").fill.color == .white)
    }

    @Test func aStyleTakenAwayLeavesItsLooksAndComesBackWithUndo() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.green)) } }
        b.step { b.store.removeStyle(s) }
        #expect(b.store.doc.styles == nil && n(b, "Card").fill.named == nil && n(b, "Card B").fill.color == Self.green)
        b.undo.undo()
        #expect(b.store.style(s) != nil && n(b, "Card").fill.named == s && n(b, "Card B").fill.named == s)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aStyleReachesHiddenAndLockedLayersToo() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        change(b, ["Card B"], { $0.hidden = true; $0.locked = true })
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.green)) } }
        #expect(n(b, "Card B").fill.color == Self.green)
    }

    @Test func eachKindChangesFromTheList() {
        let b = page()
        let shadow = nameIt(b, ["Card"], .shadow(0), "Lifted")
        let type = nameIt(b, ["Title"], .text, "Title")
        let corners = nameIt(b, ["Card"], .corners, "Soft")
        b.store.selection = []
        b.step { b.store.changeStyle(shadow, "x") { if case .shadow(var s) = $0 { s.y = 2; s.inset = true; $0 = .shadow(s) } } }
        b.step { b.store.changeStyle(type, "x") { if case .text(var t) = $0 { t.family = TextStyle.system; t.face = "Light"; t.size = 20; $0 = .text(t) } } }
        b.step { b.store.changeStyle(corners, "x") { $0 = .corners(CornerLook(radius: 0, smoothing: nil)) } }
        #expect(n(b, "Card").shadow.y == 2 && n(b, "Card").shadow.inside && n(b, "Card").cornerRadius == 0)
        #expect(n(b, "Title").style?.face == "Light" && n(b, "Title").style?.size == 20)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - Found looks

    @Test func looksSeveralLayersShareAreFoundTheMostUsedFirst() throws {
        let b = page()
        let found = b.store.doc.foundLooks()
        let colours = found[.colour] ?? []
        // White: the card, card B, the label and the artboards; ink: three texts.
        #expect(colours.first?.look == .colour(ColourLook(color: .white)))
        #expect(colours.contains { $0.look == .colour(ColourLook(color: Self.ink)) && $0.count == 3 })
        #expect(found[.text]?.first?.count == 2 && found[.shadow]?.first?.count == 2 && found[.corners]?.first?.count == 2)
        // Seen once only, a look is not offered; named, it is no longer found.
        #expect(!colours.contains { $0.look == .colour(ColourLook(color: Self.paper)) })
        #expect(b.store.doc.foundLooks(least: 1)[.colour]?.contains { $0.look == .colour(ColourLook(color: Self.paper)) } == true)
        let ink = try #require(colours.first { $0.look == .colour(ColourLook(color: Self.ink)) })
        var made: UUID?
        b.step { made = b.store.name(ink) }
        #expect(b.store.layers(using: made!).count == 3)
        #expect(b.store.doc.foundLooks()[.colour]?.contains { $0.look == ink.look } != true)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func gradientsAreFoundAlikeWhicheverWayTheyRun() {
        let b = page()
        let g = Gradient.fading(from: Self.blue)
        change(b, ["Button"], { $0.fill.gradient = g })
        change(b, ["Card"], { var h = g; h.end = CGPoint(x: 1, y: 1); $0.fill.gradient = h })
        let found = b.store.doc.foundLooks()[.colour] ?? []
        #expect(found.contains { $0.look.paint?.gradient?.stops == g.stops && $0.count == 2 })
    }

    // MARK: - Repeat grids, stacks and components

    @Test func everyCellOfAGridFollowsAndAnyCellChangesIt() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        b.store.selection = [id(b, "Card")]
        b.step { b.store.makeRepeatGrid() }
        let grid = b.store.selection[0]
        b.step { b.store.edit("x") { $0.update(grid) { $0.grid?.columns = 2; $0.grid?.rows = 2 } } }
        let cells = { b.store.doc.allNodes.filter { $0.name == "Card" } }
        #expect(cells().count == 4 && cells().allSatisfy { $0.fill.named == s })
        b.store.selection = [cells()[3].id]
        b.step { b.store.updateSelection("x") { $0.fill.color = Self.green } }
        #expect(cells().allSatisfy { $0.fill.color == Self.green } && n(b, "Card B").fill.color == Self.green)
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.red)) } }
        #expect(cells().allSatisfy { $0.fill.color == Self.red })
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func everyPostOfAStackFollowsAndAPostsOwnLookLetsGoOfItsName() {
        let b = page()
        let s = nameIt(b, ["Title", "Title B"], .text, "Title")
        b.step { _ = b.store.spread(["One", "Two", "Three"], from: id(b, "Title")) }
        let deck = a(b)
        #expect(deck.isDeck && deck.posts.count == 3)
        func titles() -> [Node] { a(b).posts.compactMap { p in a(b).layers(of: p).first { $0.name == "Title" } } }
        #expect(titles().count == 3 && titles().allSatisfy { $0.style?.named == s })
        // From the list: every post, and the other artboard.
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { if case .text(var t) = $0 { t.size = 40; $0 = .text(t) } } }
        #expect(titles().allSatisfy { $0.style?.size == 40 } && n(b, "Title B").style?.size == 40)
        // Kept in one post alone, that post's title is its own and named nothing.
        let second = a(b).posts[1]
        b.store.turn(deck.id, to: second)
        let mine = a(b).layers(of: second).first { $0.name == "Title" }!.id
        b.store.selection = [mine]
        b.step { b.store.updateSelection("Change Size") { $0.style?.size = 20 } }
        if let offer = b.store.offer { b.step { b.store.take(offer) } }
        #expect(b.store.node(mine)?.style?.size == 20)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func componentCopiesFollowTheirStylesAndADarkCopyKeepsItsDark() throws {
        let b = page()
        let s = nameIt(b, ["Button"], .fill(0), "Brand")
        b.store.selection = [id(b, "Button"), id(b, "Label")]
        b.step { b.store.makeComponent() }
        let master = try #require(b.store.doc.masters.first)
        var placed: UUID?
        b.step { placed = b.store.placeCopy(of: master.id, onto: bb(b).id) }
        let copyID = try #require(placed)
        b.step { b.store.show(bb(b).id, dark: true) }
        func back(_ copy: UUID) -> Node? { b.store.node(copy)?.children.first { $0.fill.named == s } }
        let lightCopy = try #require(b.store.doc.copies(of: master.id).first { $0.id != copyID })
        #expect(back(lightCopy.id)?.fill.color == Self.blue)
        #expect(back(copyID)?.fill.color == Self.blue.darkened)
        // The component itself stays light.
        #expect(b.store.doc.master(master.id)?.children.contains { $0.fill.named == s && $0.fill.color == Self.blue } == true)
        // Recoloured from the list: each copy as it is seen, the component in the light.
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.green)) } }
        #expect(back(lightCopy.id)?.fill.color == Self.green && back(copyID)?.fill.color == Self.green.darkened)
        // Changed on the dark copy, only the dark changes; the light copy stays.
        b.store.selection = [back(copyID)!.id]
        b.step { b.store.updateSelection("x") { $0.fill.color = Self.red } }
        #expect(b.store.style(s)?.dark?.paint?.color == Self.red && back(lightCopy.id)?.fill.color == Self.green)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - Light and dark

    @Test func theSwitchFlipsBetweenLightAndDarkAndStaysTillTakenAway() {
        let b = page()
        b.store.selection = [a(b).id]
        b.step { b.store.show(a(b).id, dark: true) }
        #expect(a(b).dark == true)
        b.step { b.store.show(a(b).id, dark: false) }
        // Light again, the switch is still there: the card stays, and there is nothing to add.
        #expect(a(b).dark == false && !a(b).showsDark)
        #expect(n(b, "Card").fill.color == .white && n(b, "Title").fill.color == Self.ink)
        b.step { b.store.show(a(b).id, dark: true) }
        #expect(a(b).showsDark && n(b, "Card").fill.color == RGBA.white.darkened)
        b.step { b.store.forgetDark(a(b).id) }
        #expect(a(b).dark == nil && n(b, "Card").fill.color == .white)
        b.undo.undo()
        #expect(a(b).showsDark && n(b, "Card").fill.color == RGBA.white.darkened)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aStyleLessArtboardTurnsDarkInOneGo() {
        let b = page()
        b.step { b.store.show(a(b).id, dark: true) }
        let board = a(b)
        #expect(board.fill.named != nil && n(b, "Back").fill.color == Self.paper.darkened)
        // A card stays lighter than its page; words go pale; white words on blue stay white.
        #expect(n(b, "Card").fill.color.oklab.l > n(b, "Back").fill.color.oklab.l)
        #expect(n(b, "Title").fill.color.oklab.l > 0.8 && n(b, "Label").fill.color == .white)
        #expect(n(b, "Ring").border.color == Self.blue.darkened && n(b, "Photo").fill.image != nil)
        // Artboard B keeps its looks, with the same names where they are the same.
        #expect(n(b, "Card B").fill.color == .white && n(b, "Card B").fill.named == n(b, "Card").fill.named)
        #expect(n(b, "Title B").fill.named == n(b, "Title").fill.named && n(b, "Title B").fill.color == Self.ink)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func darkReachesAllTheWayDownIntoGroups() {
        let b = page()
        b.store.selection = [id(b, "Card"), id(b, "Title")]
        b.step { b.store.group() }
        b.step { b.store.show(a(b).id, dark: true) }
        #expect(n(b, "Card").fill.color == RGBA.white.darkened && n(b, "Title").fill.color.oklab.l > 0.8)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aLayerMovedOntoADarkArtboardTurnsDarkAndBack() {
        let b = page()
        b.step { b.store.show(a(b).id, dark: true) }
        let card = id(b, "Card B")
        #expect(n(b, "Card B").fill.color == .white && n(b, "Card B").fill.named != nil)
        // Onto A: dark.
        b.step { b.store.edit("Move") { doc in
            guard let moved = doc.detach(card) else { return }
            doc.attach(moved, to: doc.nodes.first { $0.name == "A" }!.id)
        } }
        #expect(b.store.node(card)?.fill.color == RGBA.white.darkened)
        // Back onto B: light, and nothing else changed for it.
        b.step { b.store.edit("Move") { doc in
            guard let moved = doc.detach(card) else { return }
            doc.attach(moved, to: doc.nodes.first { $0.name == "B" }!.id)
        } }
        #expect(b.store.node(card)?.fill.color == .white)
        #expect(b.store.style(n(b, "Card B").fill.named!)?.look.paint?.color == .white)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func theDarkFollowsTheLightUntilItIsMadeThere() {
        let b = page()
        let s = nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        b.step { b.store.show(a(b).id, dark: true) }
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.green)) } }
        #expect(n(b, "Card").fill.color == Self.green.darkened && n(b, "Card B").fill.color == Self.green)
        // Made in the dark, by hand on the layer: from then on its own there.
        change(b, ["Card"], { $0.fill.color = Self.blue })
        #expect(b.store.style(s)?.dark?.paint?.color == Self.blue && n(b, "Card B").fill.color == Self.green)
        b.store.selection = []
        b.step { b.store.changeStyle(s, "x") { $0 = .colour(ColourLook(color: Self.red)) } }
        #expect(n(b, "Card").fill.color == Self.blue && n(b, "Card B").fill.color == Self.red)
        b.step { b.store.followInTheDark(s) }
        #expect(n(b, "Card").fill.color == Self.red.darkened)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func wordsOnADarkButtonGoDarkWhenTheButtonGoesPale() {
        let b = page()
        change(b, ["Button"], { $0.fill.color = Self.ink })
        b.step { b.store.show(a(b).id, dark: true) }
        // The button turns pale, so its white words turn dark, as words on a page do.
        #expect(n(b, "Button").fill.color.oklab.l > 0.8 && n(b, "Label").fill.color.oklab.l < 0.4)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func aLookNamedInTheDarkLooksTheSameAfterward() {
        let b = page()
        b.step { b.store.edit("x") { $0.update(b.a.id) { $0.dark = true } } }
        let s = nameIt(b, ["Button"], .fill(0), "Night blue")
        #expect(n(b, "Button").fill.color == Self.blue && b.store.style(s)?.dark?.paint?.color == Self.blue)
        // A found look named there keeps too.
        let found = b.store.doc.foundLooks()[.colour]!.first { $0.look == .colour(ColourLook(color: Self.ink)) }!
        b.step { _ = b.store.name(found) }
        #expect(n(b, "Title").fill.color == Self.ink)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    @Test func pointingAtTheDarkChipShowsItWithoutChangingAnything() {
        let b = page()
        let before = b.store.doc
        b.store.showPreview("add-dark", reshaping: b.store.previewing(a(b).id, dark: true))
        let shown = b.store.shownDoc
        #expect(shown.nodes.first { $0.name == "A" }?.showsDark == true)
        #expect(shown.allNodes.first { $0.name == "Card" }?.fill.color == RGBA.white.darkened)
        #expect(b.store.doc == before)
        b.store.showPreview("add-dark", reshaping: nil)
        #expect(b.store.shownDoc == before)
    }

    @Test func aLockedArtboardIsNotSwitched() {
        let b = page()
        b.step { b.store.edit("x") { $0.update(b.a.id) { $0.locked = true } } }
        b.step { b.store.show(a(b).id, dark: true) }
        #expect(a(b).dark == nil)
    }

    @Test func aLightOneBesideTheDarkLiesClearOfTheOthers() throws {
        let b = page()
        b.step { b.store.show(a(b).id, dark: true) }
        var made: UUID?
        b.step { b.store.edit("x") { made = DocumentStore.lightTwin(of: b.a.id, in: &$0) } }
        let twin = try #require(made.flatMap { b.store.node($0) })
        #expect(twin.dark == nil && twin.frame.minX >= bb(b).frame.maxX + 80)
        #expect(twin.children.first { $0.name == "Card" }?.fill.color == .white)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - Another design, files

    @Test func stylesComeAlongIntoAnotherDesign() {
        let b = page()
        let s = nameIt(b, ["Card"], .fill(0), "Surface")
        let brought = [b.store.style(s)!]
        var other = BezzleDocument()
        let theirs = Style(name: "SURFACE", look: .colour(ColourLook(color: Self.green)))
        other.addStyle(theirs)
        // Same kind and name: theirs. Another kind of the same name is not the same.
        other.addStyle(Style(name: "Surface", look: .corners(CornerLook(radius: 4))))
        let map = other.takeIn(brought)
        #expect(map == [s: theirs.id])
        var board = Node(kind: .artboard, name: "X", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.children = [n(b, "Card").renamingStyles(map)]
        other.nodes = [board]
        other.repairStyles()
        #expect(other.nodes[0].children[0].fill.color == Self.green && problems(other, fitted: false).isEmpty)
    }

    @Test func aDesignWithStylesIsSavedAndReadAsItWasAndHealsOnReading() throws {
        let b = page()
        nameIt(b, ["Card", "Card B"], .fill(0), "Surface")
        b.step { b.store.show(a(b).id, dark: true) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StyleSuite-\(UUID().uuidString).bezzle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(b.store.doc, to: url)
        let read = try DesignFile.read(url)
        #expect(read.styles == b.store.doc.styles && read.nodes == b.store.doc.nodes)
        // A file that says a card is named but shows another colour shows the style's once read.
        var broken = b.store.doc
        broken.update(id(b, "Card B")) { $0.fill.color = Self.red }
        try DesignFile.write(broken, to: url)
        #expect(try DesignFile.read(url).node(id(b, "Card B"))?.fill.color == .white)
        // A design from before styles reads as it did.
        let old = try JSONDecoder().decode(BezzleDocument.self, from: Data("{\"version\":1,\"nodes\":[]}".utf8))
        #expect(old.styles == nil)
    }

    // MARK: - The assistant

    @Test func theAssistantListsNamesUsesChangesAndTakesAwayStyles() async throws {
        let b = page()
        let tools = MCPTools()
        MCPTools.opened(b.store)
        func call(_ args: [String: Any]) async -> (String, Bool) {
            var args = args
            args["design"] = b.store.name
            let result = await tools.call("styles", args)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let text = (object?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            return (text, object?["isError"] as? Bool == true)
        }
        var (text, failed) = await call([:])
        #expect(!failed && text.contains("unnamedLooksSharedByLayers"))
        (text, failed) = await call(["name": "Surface", "layer": id(b, "Card").uuidString, "place": "fill", "all_alike": true])
        #expect(!failed, "\(text)")
        let s = try #require(b.store.doc.styles?.first { $0.name == "Surface" })
        #expect(n(b, "Card B").fill.named == s.id)
        (text, failed) = await call(["style": "surface", "color": "#2E8B57"])
        #expect(!failed && n(b, "Card B").fill.color == Self.green)
        (text, failed) = await call(["style": "Surface", "layers": [id(b, "Ring").uuidString], "place": "border"])
        #expect(!failed && n(b, "Ring").border.named == s.id && n(b, "Ring").border.color == Self.green)
        (text, failed) = await call(["layer": "A", "appearance": "dark"])
        #expect(!failed && a(b).showsDark && n(b, "Card").fill.color == Self.green.darkened)
        (text, failed) = await call(["style": "Surface", "dark_color": "#123456"])
        #expect(!failed && n(b, "Card").fill.color == RGBA(hex: "123456")! && n(b, "Card B").fill.color == Self.green)
        (text, failed) = await call(["style": "Surface", "dark_auto": true])
        #expect(!failed && n(b, "Card").fill.color == Self.green.darkened)
        (text, failed) = await call(["style": "Surface", "rename": "Paper"])
        #expect(!failed && b.store.style(s.id)?.name == "Paper")
        (text, failed) = await call(["unname": true, "layers": [id(b, "Ring").uuidString]])
        #expect(!failed && n(b, "Ring").border.named == nil)
        (text, failed) = await call(["style": "Paper", "remove": true])
        #expect(!failed && b.store.style(s.id) == nil && n(b, "Card B").fill.color == Self.green)
        // What makes no sense says so.
        (text, failed) = await call(["style": "Nothing"])
        #expect(failed)
        (text, failed) = await call(["name": "X", "layer": id(b, "Photo").uuidString, "place": "fill"])
        #expect(failed)
        (text, failed) = await call(["layer": "Card", "appearance": "dark"])
        #expect(failed)
        #expect(problems(b.store.doc).isEmpty, "\(problems(b.store.doc))")
    }

    // MARK: - Many steps, at random

    /// The same numbers every run, from a seed.
    private struct Dice {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func pick<T>(_ list: [T]) -> T? { list.isEmpty ? nil : list[int(list.count)] }
    }

    private static let colours = [RGBA.white, paper, ink, blue, red, green, RGBA(hex: "FFD166")!]

    @Test(arguments: Array(1...12)) func anyStepsAtAllKeepEveryLayerLookingAsItsStyle(seed: Int) {
        let b = page()
        var dice = Dice(state: UInt64(seed) * 7919)
        let names = ["Back", "Card", "Title", "Body", "Button", "Label", "Ring", "Card B", "Title B"]
        // What the steps came to, to be sure they did something.
        var mostNamed = 0, mostStyles = 0, darkSeen = false
        for step in 0..<150 {
            let doc = b.store.doc
            let places: (Node) -> [StylePlace] = { n in StylePlace.all(in: n).filter { $0.look(of: n) != nil } }
            switch dice.int(13) {
            case 0, 1:
                guard let name = dice.pick(names), let node = b.node(name), let place = dice.pick(places(node)) else { break }
                nameIt(b, [name], place, dice.int(3) == 0 ? "" : "S\(step)")
            case 2, 3:
                guard let s = dice.pick(doc.styles ?? []), let name = dice.pick(names), let node = b.node(name),
                      let place = places(node).first(where: { $0.kind == s.kind }) else { break }
                use(b, s.id, on: [name], at: place)
            case 4, 5:
                guard let name = dice.pick(names), let node = b.node(name), let place = dice.pick(places(node)) else { break }
                let c = dice.pick(Self.colours)!, k = CGFloat(dice.int(30) + 4)
                change(b, [name], { n in
                    switch place {
                    case .fill(let i): n[fill: i].color = c
                    case .border(let i): n[border: i].color = c
                    case .shadow(let i): n[shadow: i].y = k
                    case .text: n.style?.size = k
                    case .corners: n.radii = Array(repeating: k, count: 4)
                    }
                })
            case 6:
                guard let s = dice.pick(doc.styles ?? []) else { break }
                let c = dice.pick(Self.colours)!, k = CGFloat(dice.int(30) + 4), dark = dice.int(2) == 0
                b.store.selection = []
                b.step { b.store.changeStyle(s.id, "x", dark: dark) { look in
                    switch look {
                    case .colour: look = .colour(ColourLook(color: c))
                    case .text(var t): t.size = k; look = .text(t)
                    case .shadow(var sh): sh.blur = k; look = .shadow(sh)
                    case .corners: look = .corners(CornerLook(radius: k))
                    }
                } }
            case 7:
                guard let s = dice.pick(doc.styles ?? []) else { break }
                b.step { b.store.removeStyle(s.id) }
            case 8:
                let board = dice.int(2) == 0 ? a(b) : bb(b)
                switch dice.int(3) {
                case 0: b.step { b.store.show(board.id, dark: true) }
                case 1: b.step { b.store.show(board.id, dark: false) }
                default: b.step { b.store.forgetDark(board.id) }
                }
            case 9:
                guard let name = dice.pick(names), let node = b.node(name), let place = dice.pick(places(node)) else { break }
                b.store.selection = [node.id]
                b.step { b.store.unname(at: place) }
            case 10:
                if let offer = b.store.styleShow.offer { b.step { b.store.take(offer) } }
                else if let s = dice.pick(doc.styles ?? []) { b.step { b.store.followInTheDark(s.id) } }
            case 11:
                if dice.int(2) == 0 { if b.undo.canUndo { b.undo.undo() } } else if b.undo.canRedo { b.undo.redo() }
            default:
                // A layer moved to the other artboard.
                guard let name = dice.pick(names), let node = b.node(name), let board = b.store.doc.artboard(of: node.id) else { break }
                let to = board.id == a(b).id ? bb(b).id : a(b).id
                b.step { b.store.edit("Move") { doc in
                    guard let moved = doc.detach(node.id) else { return }
                    doc.attach(moved, to: to)
                } }
            }
            let found = problems(b.store.doc)
            #expect(found.isEmpty, "step \(step): \(found)")
            if !found.isEmpty { return }
            mostStyles = max(mostStyles, b.store.doc.styles?.count ?? 0)
            mostNamed = max(mostNamed, b.store.doc.styleUses.values.reduce(0, +))
            darkSeen = darkSeen || b.store.doc.nodes.contains(where: \.showsDark)
        }
        #expect(mostStyles >= 3 && mostNamed >= 5 && darkSeen, "styles \(mostStyles), named \(mostNamed), dark \(darkSeen)")
    }

    // MARK: - Shared between Macs

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

        /// A change as `edit` makes it.
        mutating func edit(_ change: (inout BezzleDocument) -> Void) {
            let before = doc
            change(&doc)
            doc.syncStyles(since: before)
            doc.fitGroups()
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

    /// Three Macs with the same page.
    private func three() -> (macs: [Mac], doc: BezzleDocument) {
        let doc = page().store.doc
        var macs = [Mac("a", doc: doc), Mac("b", doc: BezzleDocument()), Mac("c", doc: BezzleDocument())]
        macs[1].receive(macs[0].state)
        macs[2].receive(macs[0].state)
        return (macs, doc)
    }

    private func node(_ doc: BezzleDocument, _ name: String) -> Node? { doc.allNodes.first { $0.name == name } }

    @Test func twoPeopleNamingDifferentLooksAtOnceBothKeepTheirStyles() {
        var (macs, doc) = three()
        let card = node(doc, "Card")!.id, title = node(doc, "Title")!.id
        let surface = Style(name: "Surface", look: .colour(ColourLook(color: .white)))
        let heading = Style(name: "Heading", look: TypeLook(node(doc, "Title")!.style!).asLook)
        macs[0].edit { $0.addStyle(surface); $0.update(card) { $0.fill.named = surface.id } }
        macs[1].edit { $0.addStyle(heading); $0.update(title) { $0.style?.named = heading.id } }
        Self.sync(&macs)
        for m in macs {
            #expect(m.doc.style(surface.id) != nil && m.doc.style(heading.id) != nil)
            #expect(m.doc.node(card)?.fill.named == surface.id && m.doc.node(title)?.style?.named == heading.id)
            #expect(problems(m.doc, fitted: false).isEmpty, "\(problems(m.doc, fitted: false))")
        }
        #expect(macs[0].doc == macs[1].doc && macs[1].doc == macs[2].doc)
    }

    @Test func aLayerNamedAfterAStyleTakenAwayElsewhereKeepsItsLook() {
        var (macs, doc) = three()
        let card = node(doc, "Card")!.id, cardB = node(doc, "Card B")!.id
        let s = Style(name: "Surface", look: .colour(ColourLook(color: .white)))
        macs[0].edit { $0.addStyle(s); $0.update(card) { $0.fill.named = s.id } }
        Self.sync(&macs)
        // One takes it away while another names a second layer after it.
        macs[0].edit { $0.removeStyle(s.id) }
        macs[1].edit { $0.update(cardB) { $0.fill.named = s.id } }
        Self.sync(&macs)
        for m in macs {
            #expect(m.doc.node(cardB)?.fill.color == .white && m.doc.node(card)?.fill.color == .white)
            #expect(problems(m.doc, dangling: true, fitted: false).isEmpty, "\(problems(m.doc, dangling: true, fitted: false))")
        }
        #expect(macs[0].doc == macs[1].doc && macs[1].doc == macs[2].doc)
    }

    @Test func oneTurningAnArtboardDarkWhileAnotherRecoloursTheStyleSeesItDark() {
        var (macs, doc) = three()
        let card = node(doc, "Card")!.id, boardA = doc.nodes.first { $0.name == "A" }!.id
        let s = Style(name: "Surface", look: .colour(ColourLook(color: .white)))
        macs[0].edit { $0.addStyle(s); $0.update(card) { $0.fill.named = s.id } }
        Self.sync(&macs)
        macs[0].edit { $0.show(boardA, dark: true) { _ in "x" } }
        macs[1].time += 50
        macs[1].edit { $0.changeStyle(s.id) { $0.look = .colour(ColourLook(color: Self.green)) } }
        Self.sync(&macs)
        for m in macs {
            #expect(m.doc.node(card)?.fill.color == Self.green.darkened)
            #expect(problems(m.doc, dangling: true, fitted: false).isEmpty, "\(problems(m.doc, dangling: true, fitted: false))")
        }
        #expect(macs[0].doc == macs[1].doc && macs[1].doc == macs[2].doc)
    }

    @Test(arguments: Array(11...20)) func threePeopleChangingStylesAtRandomEndAlike(seed: Int) {
        var (macs, doc) = three()
        var dice = Dice(state: UInt64(seed) * 104_729)
        let layers = doc.allNodes.filter { !$0.isArtboard && $0.name != "Photo" }.map(\.id)
        let boards = doc.nodes.map(\.id)
        for round in 0..<70 {
            let i = dice.int(3)
            var m = macs[i]
            let styles = m.doc.styles ?? []
            switch dice.int(8) {
            case 0:
                guard let id = dice.pick(layers), let n = m.doc.node(id),
                      let place = dice.pick(StylePlace.all(in: n).filter { $0.look(of: n) != nil }), let look = place.look(of: n) else { break }
                let s = Style(name: "S\(round)", look: look.kept)
                m.edit { $0.addStyle(s); $0.update(id) { place.name(s.id, in: &$0) } }
            case 1:
                guard let s = dice.pick(styles), let id = dice.pick(layers), let n = m.doc.node(id),
                      let place = StylePlace.all(in: n).first(where: { $0.kind == s.kind && $0.look(of: n) != nil }) else { break }
                m.edit { $0.update(id) { place.name(s.id, in: &$0) } }
            case 2:
                guard let s = dice.pick(styles), case .colour = s.look else { break }
                let c = dice.pick(Self.colours)!, dark = dice.int(2) == 0
                m.edit { $0.changeStyle(s.id) { if dark { $0.dark = .colour(ColourLook(color: c)) } else { $0.look = .colour(ColourLook(color: c)) } } }
            case 3:
                guard let s = dice.pick(styles) else { break }
                m.edit { $0.changeStyle(s.id) { $0.name = "R\(round)" } }
            case 4:
                guard let s = dice.pick(styles) else { break }
                m.edit { $0.removeStyle(s.id) }
            case 5:
                guard let board = dice.pick(boards) else { break }
                let dark = dice.int(2) == 0
                m.edit { $0.show(board, dark: dark) { _ in "Auto" } }
            case 6:
                // A named colour changed on a layer, as the inspector does.
                guard let id = dice.pick(layers), let n = m.doc.node(id), n.fill.named != nil, n.fill.image == nil else { break }
                let c = dice.pick(Self.colours)!
                m.edit { $0.update(id) { $0.fill.color = c } }
            default:
                if dice.int(3) == 0 { Self.sync(&macs) }
            }
            macs[i] = m
            if dice.int(4) == 0 {
                let others = [0, 1, 2].filter { $0 != i }
                macs[others[dice.int(2)]].receive(macs[i].state)
            }
        }
        Self.sync(&macs)
        for m in macs {
            #expect(problems(m.doc, dangling: true, fitted: false).isEmpty, "\(m.name): \(problems(m.doc, dangling: true, fitted: false))")
        }
        #expect(macs[0].doc == macs[1].doc && macs[1].doc == macs[2].doc)
    }
}

private extension TypeLook {
    var asLook: StyleLook { .text(self) }
}
