import Testing
import AppKit
@testable import Bezzle

/// How layers look, keyed in Animate as it is used: the design's own cards changing a colour, a
/// border, the corners and a shadow at the playhead, the bead on each card, their lines in the
/// timeline, a rectangle's corner dots on the stage, and the assistant. The arithmetic is in
/// `MotionLooksTests`.
@MainActor
@Suite(.serialized)
struct AnimateLooksTests {
    static let red = MotionLooksTests.red, blue = MotionLooksTests.blue, green = MotionLooksTests.green

    /// On artboard A: a red card with a black border two points wide and a shadow, and a badge.
    static var layers: [Node] {
        var card = MotionLooksTests.card()
        card.border = Border(on: true, color: .black, width: 2)
        card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.4), x: 0, y: 4, blur: 8)
        var badge = CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40))
        badge.fill = Fill(color: green)
        return [card, badge]
    }

    /// The card picked, the playhead a second in.
    private func bench(_ layers: [Node] = AnimateLooksTests.layers, at time: Double = 1) -> FilmBench {
        let f = FilmBench(layers)
        f.step { f.store.selection = [f.id("Card")] }
        f.step { f.store.seek(time) }
        f.fresh()
        return f
    }

    private func near(_ a: RGBA, _ b: RGBA) -> Bool { MotionLooksTests.near(a, b) }

    /// The picked layers as the cards show them, once the panels have caught up with the playhead
    /// (they do so thirty times a second, which a test does not wait for).
    private func looked(_ f: FilmBench) -> [Node] {
        f.store.film.shown = f.store.film.time
        return f.store.lookedSelection
    }

    // MARK: The cards

    @Test func aCardsChangeIsKeyedAtThePlayheadAndTheDesignStays() {
        let f = bench()
        let design = f.design
        #expect(looked(f).map(\.fill.color) == [Self.red])
        #expect(f.store.lookKeyState([.fill(0), .fillStops(0)]) == .none)
        // The fill card's swatch, as it sets a colour.
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue; $0.fill.on = true } }
        #expect(f.design == design)
        #expect(f.undo.undoActionName == "Change Fill")
        let keys = f.node("Card")[track: "fill.0"]?.keys ?? []
        #expect(keys.map(\.t) == [0, 1] && keys.first?.given == true)
        #expect(near(looked(f)[0].fill.color, Self.blue))
        #expect(f.store.lookKeyState([.fill(0), .fillStops(0)]) == .here)
        // The card shows it as it looks at the playhead: on the way there, between the two.
        f.step { f.store.seek(0.5) }
        let between = looked(f)[0].fill.color
        #expect(!near(between, Self.red) && !near(between, Self.blue))
        #expect(f.store.lookKeyState([.fill(0)]) == .between)
        f.step { f.store.seek(0) }
        #expect(near(looked(f)[0].fill.color, Self.red))
        // The same colour again is no change, and no step.
        f.step { f.store.seek(1) }
        let before = f.store.doc
        let same = looked(f)[0].fill.color
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = same } }
        #expect(f.store.doc == before)
        // One step to undo, and the film is as it was.
        f.undo.undo()
        #expect(f.node("Card").motion == nil && f.design == design)
    }

    @Test func aBorderTheCornersAndAShadowAreKeyedFromTheirCards() {
        let f = bench()
        let design = f.design
        // The border card's drag sets its weight; its swatch its colour.
        f.step { f.store.updateSelection("Change Border") { $0.border.width = 6; $0.border.on = true } }
        f.step { f.store.updateSelection("Change Border") { $0.border.color = Self.blue; $0.border.on = true } }
        #expect(f.node("Card")[track: "border.0.width"]?.keys.map(\.v) == [[0], [4]])
        #expect(f.node("Card")[track: "border.0"]?.keys.count == 2)
        // The corners card's drag rounds them all; a field changes each from its own.
        f.step { f.store.updateSelection("Change Corners") { $0.radii = [12, 12, 12, 12] } }
        #expect(f.node("Card")[track: "corners"]?.keys.map(\.v) == [[0, 0, 0, 0], [12, 12, 12, 12]])
        // The shadow card's fields, one at a time: the others keep what they are there.
        f.step { f.store.updateSelection("Change Shadow") { $0.shadow.y = 12 } }
        f.step { f.store.updateSelection("Change Shadow") { $0.shadow.blur = 20 } }
        let shadow = f.node("Card")[track: "shadow.0"]?.keys.last?.v ?? []
        #expect(shadow.count == 9 && Array(shadow[5...]) == [0, 8, 12, 0])
        #expect(f.design == design)
        let shown = looked(f)[0]
        #expect(shown.border.width == 6 && near(shown.border.color, Self.blue) && shown.radii == [12, 12, 12, 12])
        #expect(shown.shadow.y == 12 && shown.shadow.blur == 20 && shown.shadow.color == design[0].children[0].shadow.color)
        // A preset sets more than is keyed: which side a shadow falls on is the design's.
        f.step { f.store.updateSelection("Change Shadow") { Presets.applyShadow(Presets.innerShadows[1], to: &$0.shadow) } }
        #expect(f.design == design)
        #expect(looked(f)[0].shadow.inset == nil)
        #expect(looked(f)[0].shadow.blur == Presets.innerShadows[1].blur)
    }

    @Test func whatIsNoLookIsStillTheDesigns() {
        let f = bench()
        let design = f.design
        // Opacity is no look that is keyed here: the design takes it, as before.
        f.step { f.store.updateSelection("Change Opacity") { $0.opacity = 0.5 } }
        #expect(f.node("Card").opacity == 0.5 && f.node("Card").motion == nil)
        #expect(f.design != design)
        // Out of Animate, a card changes the design.
        f.step { f.store.show(.design) }
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        #expect(f.node("Card").fill.color == Self.blue && f.node("Card").motion == nil)
    }

    @Test func theFillMenuKeysAColourAndAGradientsColours() {
        var card = MotionLooksTests.card()
        card.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.blue)],
                                      start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        var word = Node(kind: .text, name: "Word", frame: CGRect(x: 40, y: 200, width: 120, height: 30))
        word.text = "Hello"
        word.fill = Fill(color: Self.red)
        let f = bench([card, word])
        let design = f.design
        // A colour of the gradient chosen in the menu, and one moved along its bar.
        f.step {
            f.store.updatePaint(.fill(0), "Change Fill") { fill in fill.gradient?.stops[1].color = Self.green }
        }
        f.step {
            f.store.updatePaint(.fill(0), "Move Gradient Colour") { fill in fill.gradient?.stops[0].offset = 0.25 }
        }
        #expect(f.design == design)
        let stops = looked(f)[0].fill.gradient?.stops ?? []
        #expect(stops.map(\.offset) == [0.25, 1] && near(stops[1].color, Self.green) && near(stops[0].color, Self.red))
        #expect(f.node("Card")[track: "fill.0.stops"]?.keys.map(\.t) == [0, 1])
        #expect(f.store.lookKeyState([.fill(0), .fillStops(0)]) == .here)
        // Text's colour, as its card sets it for every letter.
        f.step { f.store.selection = [f.id("Word")] }
        f.step { f.store.restyleLetters("Change Fill") { $0.color = Self.blue } }
        #expect(f.design == design)
        #expect(f.node("Word")[track: "fill.0"]?.keys.map(\.t) == [0, 1])
        #expect(near(looked(f)[0].fill.color, Self.blue))
    }

    // MARK: Keys

    @Test func theBeadSetsAKeyThatHoldsTheLookAndTakesItAway() {
        let f = bench()
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        f.step { f.store.seek(0.5) }
        let held = looked(f)[0].fill.color
        f.step { f.store.toggleLookKeys([.fill(0), .fillStops(0)]) }
        #expect(f.undo.undoActionName == "Add Key")
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 0.5, 1])
        #expect(near(looked(f)[0].fill.color, held))
        #expect(f.store.lookKeyState([.fill(0)]) == .here)
        f.step { f.store.toggleLookKeys([.fill(0), .fillStops(0)]) }
        #expect(f.undo.undoActionName == "Remove Key")
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 1])
        // A look that never changed is keyed where it is, as the design has it.
        f.step { f.store.toggleLookKeys([.corners]) }
        #expect(f.node("Card")[track: "corners"]?.keys.map(\.v) == [[0, 0, 0, 0]])
        #expect(f.store.lookKeyState([.corners]) == .here)
    }

    @Test func holdingStepsAndDeleteKnowLookKeys() {
        let f = bench()
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        f.step { f.store.pose(.move, of: [f.id("Card")]) { _ in [30, 0] } }
        // The playhead's arrows stop at them, with the card picked and with nothing picked.
        f.step { f.store.seek(2) }
        f.step { f.store.updateSelection("Change Border") { $0.border.width = 5 } }
        #expect(f.store.filmStops == [0, 1, 2])
        f.step { f.store.selection = [] }
        #expect(f.store.filmStops == [0, 1, 2])
        f.step { f.store.selection = [f.id("Card")] }
        // Held where there is no key: a key for everything of it that changes, its looks too.
        f.step { f.store.seek(0.5) }
        #expect(f.store.holdState == .between)
        f.step { f.store.holdHere() }
        #expect(f.store.holdState == .here)
        #expect(f.node("Card")[track: "fill.0"]?.index(at: 0.5) != nil && f.node("Card")[track: "border.0.width"]?.index(at: 0.5) != nil)
        #expect(f.keys("Card", .move).map(\.t) == [0, 0.5, 1])
        // Delete takes the keys at the playhead, of every kind.
        #expect(f.store.hasKeysToRemove)
        f.step { f.store.removeFilmKeys() }
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 1] && f.node("Card")[track: "border.0.width"]?.keys.map(\.t) == [0, 2])
        // Remove Motion takes the looks' keys with the rest.
        f.step { f.store.clearFilmMotion() }
        #expect(f.node("Card").motion == nil)
    }

    // MARK: The timeline

    private func sheet(_ f: FilmBench) -> (rows: [FilmRow], scale: FilmScale, length: Double) {
        let board = f.board
        return (FilmRow.rows(of: board, open: f.store.film.open), FilmScale(width: 600, span: FilmScale.span(for: board.filmLength)), board.filmLength)
    }

    private func at(_ t: Double, line: Int, _ scale: FilmScale) -> CGPoint {
        CGPoint(x: scale.x(t), y: (CGFloat(line) + 0.5) * FilmTimeline.rowHeight)
    }

    @Test func aLooksLineIsDraggedPacedAndKeyedLikeAnyOther() throws {
        let f = bench()
        let card = f.id("Card")
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        f.step { f.store.film.open = [card] }
        let hand = FilmHand(store: f.store)
        var (rows, scale, length) = sheet(f)
        // Lines: the camera, the card, its fill.
        let line = try #require(rows.firstIndex { $0.look == .fill(0) })
        #expect(rows[line].name == "Fill" && rows[line].single && rows[line].marks.map(\.t) == [0, 1])
        #expect(rows[line].marks.map(\.home) == [true, false] && !rows[line].marks.contains(where: \.gone))
        // Its bead dragged later moves that key, as one step.
        let from = at(1, line: line, scale)
        f.step {
            hand.press(at: from, rows: rows, scale: scale)
            #expect(f.store.film.keys == [FilmKeyRef(card, look: .fill(0), at: 1)])
            hand.dragged(to: CGPoint(x: scale.x(1.5), y: from.y), by: scale.x(1.5) - from.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(f.undo.undoActionName == "Move Key")
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 1.5])
        #expect(f.store.pickedKeys == [FilmKeyRef(card, look: .fill(0), at: 1.5)])
        // Its pace, set for the picked key.
        f.step { f.store.setEase(MotionEase(kind: .linear)) }
        #expect(f.node("Card")[track: "fill.0"]?.keys.last?.ease?.kind == .linear)
        // Twice on the line sets a key there, holding the colour it has then.
        (rows, scale, length) = sheet(f)
        f.step { hand.press(at: at(0.75, line: line, scale), rows: rows, scale: scale, clicks: 2) }
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 0.75, 1.5])
        #expect(f.store.filmTime == 0.75)
        // Delete takes the picked key alone.
        f.step { f.store.film.keys = [FilmKeyRef(card, look: .fill(0), at: 0.75)] }
        f.step { f.store.removeFilmKeys() }
        #expect(f.node("Card")[track: "fill.0"]?.keys.map(\.t) == [0, 1.5])
    }

    @Test func aMarqueeCatchesALooksKeyOnItsOwnLine() throws {
        let f = bench()
        let card = f.id("Card")
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        f.step { f.store.edit("Add Key") { doc in doc.update(card) { $0.setKey(.move, [10, 0], at: 1) } } }
        f.step { f.store.film.open = [card] }
        let hand = FilmHand(store: f.store)
        var (rows, scale, length) = sheet(f)
        let line = try #require(rows.firstIndex { $0.look == .fill(0) })
        #expect(line == rows.count - 1 && rows.contains { $0.property == .move })
        // From bare sheet under the lines, up over the fill's line alone, round its key a second in.
        func marquee(over line: Int) {
            let a = CGPoint(x: scale.x(1) - 30, y: CGFloat(rows.count) * FilmTimeline.rowHeight + 10)
            let b = at(1, line: line, scale).applying(.init(translationX: 10, y: 0))
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: b, by: b.x - a.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        marquee(over: line)
        #expect(f.store.film.keys == [FilmKeyRef(card, look: .fill(0), at: 1)] && f.store.selection == [card])
        // Folded, the layer's bead is every key it has at that moment, the colour's among them.
        f.step { f.store.film.open = [] }
        (rows, scale, length) = sheet(f)
        #expect(rows.count == 2 && rows[1].marks.map(\.t) == [0, 1])
        marquee(over: 1)
        #expect(f.store.film.keys == [FilmKeyRef(card, at: 1)])
        // Opened again and caught on its own line, Delete takes the colour's key, and with it the
        // one the app placed at the start for it, and leaves the move the layer has at that moment.
        f.step { f.store.film.open = [card] }
        (rows, scale, length) = sheet(f)
        marquee(over: line)
        #expect(f.store.film.keys == [FilmKeyRef(card, look: .fill(0), at: 1)])
        f.step { f.store.removeFilmKeys() }
        #expect(f.node("Card")[track: "fill.0"] == nil)
        #expect(f.node("Card")[track: .move]?.keys.map(\.t) == [1])
        #expect(near(looked(f)[0].fill.color, Self.red))
    }

    @Test func keysForWhatTheDesignNoLongerHasAreShownFaint() {
        let f = bench()
        f.step { f.store.updateSelection("Change Fill") { $0.fill.color = Self.blue } }
        // In the design the fill becomes a gradient: the colour's keys wait, and change nothing.
        f.step { f.store.show(.design) }
        f.step { f.store.choosePaint(.linear, for: .fill(0)) }
        f.step { f.store.show(.animate) }
        f.step { f.store.film.open = [f.id("Card")] }
        let rows = sheet(f).rows
        let line = rows.first { $0.look == .fill(0) }
        #expect(line?.marks.count == 2 && line?.marks.allSatisfy(\.gone) == true)
        #expect(f.store.lookKeyState([.fill(0), .fillStops(0)]) == .none)
        #expect(looked(f)[0] == f.node("Card"))
        #expect(f.board.filmPieces().first { $0.layers == [f.id("Card")] }?.changes == false)
        // One colour again, they are back.
        f.step { f.store.show(.design) }
        f.step { f.store.choosePaint(.solid, for: .fill(0)) }
        #expect(f.node("Card").fits(.fill(0)))
    }

    // MARK: The stage

    @Test(arguments: FilmView.allCases)
    func aCornersDotRoundsTheCornersAtThePlayhead(view: FilmView) {
        // Big enough for its dots to show from far off too.
        var card = MotionLooksTests.card()
        card.frame = CGRect(x: 40, y: 40, width: 200, height: 160)
        let f = FilmBench([card], view: view)
        f.step { f.store.selection = [f.id("Card")] }
        f.step { f.store.seek(1) }
        f.fresh()
        let design = f.design
        let k = f.zoom
        // The card's top left is at 40, 40 on the artboard; the dot lies ten points on screen in.
        let corner = f.corners("Card")[0]
        let dot = CGPoint(x: corner.x + 10, y: corner.y + 10)
        f.hover(f.middle("Card"))
        // Pulled in along the diagonal to twenty of the card's own points from each side.
        f.drag(dot, CGPoint(x: corner.x + 20 * k, y: corner.y + 20 * k))
        #expect(f.undo.undoActionName == "Change Corners")
        #expect(f.design == design)
        #expect(f.node("Card")[track: "corners"]?.keys.map(\.v) == [[0, 0, 0, 0], [20, 20, 20, 20]])
        #expect(looked(f)[0].radii == [20, 20, 20, 20])
        // With Option, that corner alone.
        let now = f.corners("Card")[0]
        f.drag(CGPoint(x: now.x + 20 * k, y: now.y + 20 * k), CGPoint(x: now.x + 8 * k, y: now.y + 8 * k), flags: [.option])
        #expect(looked(f)[0].radii == [8, 20, 20, 20])
        // Each drag is one step.
        f.undo.undo()
        #expect(looked(f)[0].radii == [20, 20, 20, 20])
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        // Put back where the design has them, nothing is left of it.
        f.drag(dot, CGPoint(x: corner.x + 20 * k, y: corner.y + 20 * k))
        let round = f.corners("Card")[0]
        f.drag(CGPoint(x: round.x + 20 * k, y: round.y + 20 * k), CGPoint(x: round.x - 4, y: round.y - 4))
        #expect(f.node("Card").motion == nil)
    }

    @Test func aCornersDotFollowsTheLayerWhereTheFilmShowsIt() {
        let f = bench()
        // Moved, grown and turned at the playhead: the dot is where the film shows the corner.
        f.step { f.store.pose(.move, of: [f.id("Card")]) { _ in [60, 30] } }
        f.step { f.store.pose(.scale, of: [f.id("Card")]) { _ in [1.5, 1.5] } }
        f.step { f.store.pose(.turn, of: [f.id("Card")]) { _ in [90] } }
        f.fresh()
        let q = f.corners("Card")
        let c = f.middle("Card")
        // The top left corner's own diagonal runs to the middle: ten points on screen along each of its sides.
        let across = CGPoint(x: (q[1].x - q[0].x) / hypot(q[1].x - q[0].x, q[1].y - q[0].y), y: (q[1].y - q[0].y) / hypot(q[1].x - q[0].x, q[1].y - q[0].y))
        let down = CGPoint(x: (q[3].x - q[0].x) / hypot(q[3].x - q[0].x, q[3].y - q[0].y), y: (q[3].y - q[0].y) / hypot(q[3].x - q[0].x, q[3].y - q[0].y))
        let dot = CGPoint(x: q[0].x + (across.x + down.x) * 10, y: q[0].y + (across.y + down.y) * 10)
        f.hover(c)
        // Thirty points on screen in from each side is twenty of its own, grown by a half.
        f.drag(dot, CGPoint(x: q[0].x + (across.x + down.x) * 30, y: q[0].y + (across.y + down.y) * 30))
        #expect(f.undo.undoActionName == "Change Corners")
        #expect(looked(f)[0].radii == [20, 20, 20, 20])
        // It moved nothing: the pose is as it was.
        #expect(f.value("Card", .move) == [60, 30] && f.value("Card", .turn) == [90])
    }

    @Test func aRectangleWhosePointsAreKeyedHasNoCornersToKeyThere() {
        var card = MotionLooksTests.card()
        card.frame = CGRect(x: 40, y: 40, width: 200, height: 160)
        let f = FilmBench([card])
        f.step { f.store.selection = [f.id("Card")] }
        f.step { f.store.seek(1) }
        // Rounded at the playhead, then its points moved there: the corners are the design's again.
        f.step { f.store.updateSelection("Change Corners") { $0.radii = [20, 20, 20, 20] } }
        #expect(looked(f)[0].radii == [20, 20, 20, 20])
        f.step { f.store.pose(.shape, of: [f.id("Card")]) { n in n.shapeRest.map { _ in 2 } } }
        f.fresh()
        let shown = looked(f)[0]
        #expect(shown.radii == [0, 0, 0, 0] && shown.lookCount(.corners) == nil && !shown.keyableLooks.contains(.corners))
        // Their line stays in the timeline, its keys faint.
        let rows = f.store.filmBoard.map { FilmRow.rows(of: $0, open: [f.id("Card")]) } ?? []
        #expect(rows.first { $0.look == .corners }?.marks.map(\.gone) == [true, true])
        // No dot is there to take: a drag from where one lay keys no corners.
        let keys = f.node("Card")[track: "corners"]
        let corner = f.corners("Card")[0]
        f.hover(f.middle("Card"))
        f.drag(CGPoint(x: corner.x + 10, y: corner.y + 10), CGPoint(x: corner.x + 30, y: corner.y + 30))
        #expect(f.undo.undoActionName != "Change Corners" && keys != nil && f.node("Card")[track: "corners"] == keys)
    }

    // MARK: The assistant

    @Test func theAssistantKeysLooksAndReadsThem() async throws {
        var layers = Self.layers
        layers[1].fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.blue)],
                                           start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        let bench = Bench(extra: layers)
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let tools = MCPTools()
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let design = bench.store.doc.nodes.map { board -> Node in
            var board = board
            board.children = board.children.map { var n = $0; n.motion = nil; return n }
            return board
        }
        let keyed = await call("animate", ["keys": [
            ["layer": "Card", "look": "fill", "time": 0, "value": "#E61A1A"],
            ["layer": "Card", "look": "fill", "time": 2, "value": "#1A4DCC", "pace": "linear"],
            ["layer": "Card", "look": "borderWidth", "time": 0, "value": 2],
            ["layer": "Card", "look": "borderWidth", "time": 2, "value": 8, "pace": "linear"],
            ["layer": "Card", "look": "corners", "time": 2, "value": [4, 8, 12, 16]],
            ["layer": "Card", "look": "shadow", "time": 2, "value": ["y": 16, "color": "#00000080"]],
            ["layer": "Badge", "look": "fill", "time": 2, "value": ["#00FF00", ["color": "#0000FF", "offset": 0.8]]],
        ]])
        #expect(!keyed.failed, "\(keyed.text)")
        let card = try #require(bench.node("Card")), badge = try #require(bench.node("Badge"))
        #expect(card[track: "fill.0"]?.keys.map(\.t) == [0, 2] && card[track: "fill.0"]?.keys.last?.ease?.kind == .linear)
        #expect(card[track: "fill.0"]?.keys.first?.v == [0, 0, 0, 0, 0])
        #expect(MotionLooksTests.near(card.looked(at: 2).fill.color, Self.blue, within: 0.01))
        #expect(card.looked(at: 1).border.width == 5 && card.looked(at: 2).radii == [4, 8, 12, 16])
        #expect(card.looked(at: 2).shadow.y == 16 && card.looked(at: 2).shadow.blur == 8)
        #expect(abs(card.looked(at: 2).shadow.color.a - 0.5) < 0.01)
        #expect(badge.looked(at: 2).fill.gradient?.stops.map(\.offset) == [0, 0.8])
        // Nothing of it is the design's.
        let after = bench.store.doc.nodes.map { board -> Node in
            var board = board
            board.children = board.children.map { var n = $0; n.motion = nil; return n }
            return board
        }
        #expect(after == design)
        // Read back as the looks themselves.
        let read = await call("get_animation", ["artboard": "A"])
        let object = try JSONSerialization.jsonObject(with: Data(read.text.utf8)) as? [String: Any]
        let listed = (object?["layers"] as? [[String: Any]])?.first { $0["name"] as? String == "Card" }
        let looks = listed?["looks"] as? [[String: Any]] ?? []
        #expect(looks.map { $0["look"] as? String } == ["fill", "borderWidth", "corners", "shadow"])
        let fill = looks.first { $0["look"] as? String == "fill" }
        #expect(fill?["design"] as? String == "#E61A1A")
        #expect((fill?["keys"] as? [[String: Any]])?.map { $0["value"] as? String } == ["#E61A1A", "#1A4DCC"])
        let width = looks.first { $0["look"] as? String == "borderWidth" }
        #expect((width?["keys"] as? [[String: Any]])?.map { $0["value"] as? Double } == [2, 8])
        // What a layer has not, a gradient given the wrong count, a look there is none of: each said.
        let none = await call("animate", ["keys": [["layer": "Badge", "look": "shadow", "time": 1, "value": ["y": 2]]]])
        #expect(none.failed && none.text.contains("no shadow"))
        let count = await call("animate", ["keys": [["layer": "Badge", "look": "fill", "time": 1, "value": "#FF0000"]]])
        #expect(count.failed && count.text.contains("gradient of 2 colours"))
        #expect(await call("animate", ["keys": [["layer": "Card", "look": "glow", "time": 1, "value": 1]]]).failed)
        #expect(await call("animate", ["keys": [["layer": "Card", "look": "fill", "property": "fade", "time": 1, "value": 1]]]).failed)
        #expect(await call("animate", ["keys": [["layer": "Card", "property": "fade", "which": 2, "time": 1, "value": 1]]]).failed)
        // Corners and a shape for one rectangle: a shape's keys move the points its corners make.
        let both = await call("animate", ["keys": [
            ["layer": "Card", "look": "corners", "time": 1, "value": 6],
            ["layer": "Card", "property": "shape", "time": 1, "path": "M0 0 L120 0 L120 80 L0 80 Z"],
        ]])
        #expect(both.failed && both.text.contains("corners and a shape"), "\(both.text)")
        #expect(bench.node("Card") == card)
        // Taken away by look: one key, then all of them.
        let one = await call("animate", ["remove": [["layer": "Card", "look": "borderWidth", "time": 2]]])
        #expect(!one.failed && bench.node("Card")?[track: "border.0.width"] == nil)
        let gone = await call("animate", ["remove": [["layer": "Card", "look": "fill"]]])
        #expect(!gone.failed && bench.node("Card")?[track: "fill.0"] == nil && bench.node("Card")?[track: "corners"] != nil)
    }
}
