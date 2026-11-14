import Testing
import AppKit
@testable import Bezzle

/// How a layer looks, keyed in Animate as where it is: a fill's colour, a border's colour and
/// width, the corners, a shadow and a gradient's colours, each a track of the layer's motion that
/// holds changes from the design. What a layer looks like at a moment is `Node.looked(at:)`.
@MainActor
@Suite(.serialized)
struct MotionLooksTests {
    static let red = RGBA(r: 0.9, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.3, b: 0.8), green = RGBA(r: 0.1, g: 0.6, b: 0.3)

    /// A red card.
    static func card(_ color: RGBA = red) -> Node {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80))
        card.fill = Fill(color: color)
        return card
    }

    static func near(_ a: RGBA, _ b: RGBA, within: Double = 0.002) -> Bool {
        abs(a.r - b.r) < within && abs(a.g - b.g) < within && abs(a.b - b.b) < within && abs(a.a - b.a) < within
    }

    /// Two colours mixed as Animate mixes them: along a straight line in OKLab.
    static func mixed(_ a: RGBA, _ b: RGBA, _ p: Double) -> RGBA {
        let x = a.oklab, y = b.oklab
        let rgb = LookColor.rgb(l: x.l + (y.l - x.l) * p, a: x.a + (y.a - x.a) * p, b: x.b + (y.b - x.b) * p)
        return RGBA(r: rgb.r, g: rgb.g, b: rgb.b, a: a.a + (b.a - a.a) * p)
    }

    // MARK: Names

    @Test func everyLookHasATrackOfItsOwnName() {
        let all: [LookTrack] = [.fill(0), .fillStops(0), .fill(3), .border(0), .borderStops(1), .borderWidth(2), .shadow(0), .shadow(12), .corners]
        #expect(all.map(\.name) == ["fill.0", "fill.0.stops", "fill.3", "border.0", "border.1.stops", "border.2.width", "shadow.0", "shadow.12", "corners"])
        for look in all { #expect(LookTrack(name: look.name) == look) }
        // Nothing else is one: a property's, a shader input's, or a name only like one.
        for name in ["move", "shape", "shader.u_tint", "fill", "fill.", "fill.x", "fill.01", "fill.-1", "fill.0.width", "border.0.stops.1",
                     "shadow.0.stops", "corners.0", "cornersX", "", "fill.1000", "filler.0"] {
            #expect(LookTrack(name: name) == nil, "\(name)")
        }
        #expect(all.sorted { $0.order < $1.order }.map(\.name)
            == ["fill.0", "fill.0.stops", "fill.3", "border.0", "border.1.stops", "border.2.width", "corners", "shadow.0", "shadow.12"])
        #expect(LookTrack.fill(0).title() == "Fill" && LookTrack.fill(1).title() == "Fill 2" && LookTrack.borderWidth(0).title() == "Border Width")
        #expect(LookTrack.border(0).title(line: true) == "Line" && LookTrack.borderWidth(1).title(line: true) == "Line Width 2")
    }

    // MARK: A colour

    @Test func aColourKeyIsAColourLaidOverTheDesigns() {
        var card = Self.card()
        #expect(card.keyableLooks == [.fill(0), .corners])
        #expect(!card.isAnimated && card.looks.isEmpty && !card.hasLooks)
        // Posed later: it leaves the design at the start and is there by then.
        var shown = card
        shown.fill.color = Self.blue
        card.poseLook(.fill(0), showing: shown, at: 1)
        let keys = card[track: "fill.0"]?.keys ?? []
        #expect(keys.map(\.t) == [0, 1] && keys.first?.given == true && keys.first?.v == [0, 0, 0, 0, 0])
        #expect(keys.last?.v.count == 5 && keys.last?.v.last == 1)
        #expect(card.isAnimated && card.hasLooks && card.looksChange && card.looks == [.fill(0)] && card.lookTracks == ["fill.0"])
        #expect(card.layerTracks.contains("fill.0") && card.lastKey == 1)
        // Where the keys change nothing, the layer itself; where the key is, its colour.
        #expect(card.looked(at: 0) == card)
        #expect(Self.near(card.looked(at: 1).fill.color, Self.blue, within: 1e-5))
        #expect(card.looked(at: 1).motion == card.motion && card.looked(at: 1).frame == card.frame)
        // Between, the two mixed in OKLab, at the pace of the keys: neither grey nor dark.
        let p = MotionEase.progress(.smooth, 0.5)
        #expect(Self.near(card.looked(at: 0.5).fill.color, Self.mixed(Self.red, Self.blue, p)))
        let straight = Self.red.mixed(Self.blue, p)
        #expect(!Self.near(card.looked(at: 0.5).fill.color, straight, within: 0.01))
        // The design restyled: the key it gave follows it, and the colour that was chosen stays.
        card.fill.color = Self.green
        #expect(card.looked(at: 0) == card && card.looked(at: 0).fill.color == Self.green)
        #expect(Self.near(card.looked(at: 1).fill.color, Self.blue, within: 1e-5))
        #expect(Self.near(card.looked(at: 0.5).fill.color, Self.mixed(Self.green, Self.blue, p)))
        // Posed back to the design's own colour, its one key says nothing, and with only the
        // design for company there is no motion left: the look's line goes.
        var home = card.looked(at: 1)
        home.fill.color = Self.green
        card.poseLook(.fill(0), showing: home, at: 1)
        #expect(card.motion == nil && !card.isAnimated && card.looked(at: 1) == card)
        // Among other keys such a key stays, and holds the design there.
        card.poseLook(.fill(0), showing: shown, at: 1)
        card.poseLook(.fill(0), showing: shown, at: 2)
        card.poseLook(.fill(0), showing: home, at: 1)
        #expect(card[track: "fill.0"]?.keys.map(\.t) == [0, 1, 2])
        #expect(card[track: "fill.0"]?.keys[1].v == [0, 0, 0, 0, 0])
        #expect(card.looked(at: 1) == card && Self.near(card.looked(at: 2).fill.color, Self.blue, within: 1e-5))
        // Taking its keys away leaves the layer as designed, with no motion at all.
        card.removeKeys(at: 1, tracks: ["fill.0"])
        card.removeKeys(at: 2, tracks: ["fill.0"])
        #expect(card.motion == nil && !card.isAnimated)
    }

    @Test func aColourThatBarelyShowsCountsForAsLittle() {
        // From clear to blue: blue all the way, showing more and more, and never the clear red's hue.
        var card = Self.card(Self.red.with(alpha: 0))
        #expect(card.poseLooks(at: 1) { $0.fill.color = Self.blue })
        let p = MotionEase.progress(.smooth, 0.5)
        let half = card.looked(at: 0.5).fill.color
        #expect(Self.near(half, Self.blue.with(alpha: p)))
        #expect(card.looked(at: 0).fill.color == Self.red.with(alpha: 0))
        // And out again to nothing: the colour it had, unseen.
        var faded = Self.card(Self.blue)
        #expect(faded.poseLooks(at: 1) { $0.fill.color = Self.blue.with(alpha: 0) })
        #expect(Self.near(faded.looked(at: 0.5).fill.color, Self.blue.with(alpha: 1 - p)))
        #expect(faded.looked(at: 1).fill.color.a == 0)
        // A spring goes a little past its colour and stays a colour a screen shows.
        var sprung = Self.card()
        sprung.setLookKey(.fill(0), change: [0, 0, 0, 0, 0], at: 0)
        sprung.setLookKey(.fill(0), change: LookColor.change(to: .white, over: Self.red), at: 1, ease: .spring(1))
        for k in 0...40 {
            let c = sprung.looked(at: Double(k) / 40).fill.color
            #expect([c.r, c.g, c.b, c.a].allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    // MARK: Every look

    @Test func aBordersColourAndWidthAreKeyed() {
        var card = Self.card()
        card.border = Border(on: true, color: .black, width: 2)
        #expect(card.keyableLooks == [.fill(0), .border(0), .borderWidth(0), .corners])
        #expect(card.poseLooks(at: 1) { n in
            n.border.color = Self.blue
            n.border.width = 6
        })
        #expect(card.looks == [.border(0), .borderWidth(0)])
        #expect(card[track: "border.0.width"]?.keys.map(\.v) == [[0], [4]])
        #expect(card.looked(at: 0) == card)
        #expect(card.looked(at: 1).border.width == 6 && Self.near(card.looked(at: 1).border.color, Self.blue, within: 1e-5))
        let mid = card.looked(at: 0.5).border.width
        #expect(mid > 2 && mid < 6)
        // A change from the design: made heavier there, it is as much heavier in the film.
        card.border.width = 3
        #expect(card.looked(at: 1).border.width == 7)
        // Never less than no border at all.
        card.setLookKey(.borderWidth(0), change: [-10], at: 2)
        #expect(card.looked(at: 2).border.width == 0)
        // The fill was not touched, and has no keys.
        #expect(card[track: "fill.0"] == nil && card.looked(at: 1).fill == card.fill)
    }

    @Test func theCornersAreKeyedEachByItself() {
        var card = Self.card()
        #expect(card.poseLooks(at: 1) { $0.radii = [20, 20, 0, 0] })
        #expect(card[track: "corners"]?.keys.map(\.v) == [[0, 0, 0, 0], [20, 20, 0, 0]])
        #expect(card.looked(at: 1).radii == [20, 20, 0, 0] && card.looked(at: 0).radii == [0, 0, 0, 0])
        // All alike, they are kept as one radius, as the design keeps them.
        var round = Self.card()
        #expect(round.poseLooks(at: 1) { $0.radii = Array(repeating: 12, count: 4) })
        #expect(round.looked(at: 1).cornerRadius == 12 && round.looked(at: 1).corners == nil)
        // Rounder in the design, as much rounder in the film; and never less than square.
        card.cornerRadius = 8
        #expect(card.looked(at: 1).radii == [28, 28, 8, 8])
        card.setLookKey(.corners, change: [-20, 0, 0, 0], at: 2)
        #expect(card.looked(at: 2).radii == [0, 8, 8, 8])
        // Only a rectangle has corners to key.
        var oval = Node(kind: .ellipse, name: "Oval", frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(!oval.keyableLooks.contains(.corners))
        oval.setLookKey(.corners, change: [4, 4, 4, 4], at: 1)
        #expect(oval.motion == nil)
    }

    @Test func aShadowIsKeyedWhole() {
        var card = Self.card()
        card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.2), x: 0, y: 4, blur: 12)
        #expect(card.keyableLooks.contains(.shadow(0)))
        #expect(card.poseLooks(at: 1) { n in
            n.shadow.y = 24
            n.shadow.blur = 56
            n.shadow.color = Self.blue.with(alpha: 0.5)
        })
        let key = card[track: "shadow.0"]?.keys.last?.v ?? []
        #expect(key.count == 9 && Array(key[5...]) == [0, 20, 44, 0])
        let shown = card.looked(at: 1).shadow
        #expect(shown.y == 24 && shown.blur == 56 && shown.x == 0 && shown.spread == nil && Self.near(shown.color, Self.blue.with(alpha: 0.5), within: 1e-5))
        #expect(card.looked(at: 0) == card)
        // What was left alone keeps what its keys say there: only the spread is set now.
        #expect(card.poseLooks(at: 1) { $0.shadow.spread = 3 })
        let again = card[track: "shadow.0"]?.keys.last?.v ?? []
        #expect(Array(again[..<8]) == Array(key[..<8]) && again[8] == 3)
        #expect(card.looked(at: 1).shadow.spread == 3 && card.looked(at: 1).shadow.y == 24)
        // A blur is never less than none.
        card.setLookKey(.shadow(0), change: [0, 0, 0, 0, 0, 0, 0, -100, 0], at: 2)
        #expect(card.looked(at: 2).shadow.blur == 0)
        // No spread written out as none is nothing to see, so nothing to key, and not the design's
        // either; which side it falls on is the design's.
        var plain = Self.card()
        plain.shadow = Shadow(on: true, color: .black, x: 0, y: 4, blur: 12)
        let was = plain
        #expect(plain.poseLooks(at: 1) { $0.shadow.spread = 0 })
        #expect(plain == was)
        #expect(!plain.poseLooks(at: 1) { $0.shadow.inset = true })
        #expect(plain == was)
    }

    @Test func eachOfSeveralFillsHasItsOwnKeys() {
        var card = Self.card()
        card.add(Fill(color: Self.green.with(alpha: 0.5)))
        #expect(card.slots(.fill) == 2 && card.keyableLooks == [.fill(0), .fill(1), .corners])
        #expect(card.poseLooks(at: 1) { $0[fill: 1].color = Self.blue })
        #expect(card.looks == [.fill(1)])
        #expect(card.looked(at: 1).fill == card.fill && Self.near(card.looked(at: 1)[fill: 1].color, Self.blue, within: 1e-5))
        #expect(card.poseLooks(at: 2) { $0.fill.color = .black })
        #expect(card.looks == [.fill(0), .fill(1)])
        #expect(Self.near(card.looked(at: 2).fill.color, .black, within: 1e-5))
    }

    @Test func aTextsColourCoversItsLettersOwn() {
        var text = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 20, width: 0, height: 0))
        text.text = "Hello World"
        text.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.color = Self.red }
        text.refit()
        #expect(text.spans?.contains { $0.look.color == Self.red } == true)
        #expect(text.keyableLooks == [.fill(0)])
        // Changed as the text card changes it: for every letter, those with a colour of their own too.
        #expect(text.poseLooks(at: 1) { $0.restyleLetters(in: nil) { $0.color = Self.blue } })
        #expect(text.spans?.contains { $0.look.color == Self.red } == true, "the design keeps its letters' colours")
        #expect(text.looked(at: 0) == text)
        let shown = text.looked(at: 1)
        #expect(Self.near(shown.fill.color, Self.blue, within: 1e-5))
        #expect(shown.letters().allSatisfy { Self.near($0.color, Self.blue, within: 1e-5) })
        // Half way, each letter is on its way from its own colour.
        let half = text.looked(at: 0.5).letters().map(\.color)
        #expect(half.count == 2 && !Self.near(half[0], half[1], within: 0.01))
        // Given the colour it shows already, nothing is keyed and the design is left alone.
        let was = text
        #expect(text.poseLooks(at: 1) { $0.restyleLetters(in: nil) { $0.color = shown.fill.color } })
        #expect(text == was)
        // Anything else of its letters is the design's.
        #expect(!text.poseLooks(at: 1) { $0.restyleLetters(in: nil) { $0.underline = true } })
        #expect(text == was)
    }

    @Test func aGradientsColoursAndPlacesAreKeyed() {
        var card = Self.card()
        card.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.blue)],
                                      start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        #expect(card.keyableLooks == [.fillStops(0), .corners] && card.lookCount(.fillStops(0)) == 12 && card.lookCount(.fill(0)) == nil)
        #expect(card.poseLooks(at: 1) { n in
            n.fill.gradient?.stops[1].color = Self.green
            n.fill.gradient?.stops[0].offset = 0.4
        })
        let key = card[track: "fill.0.stops"]?.keys.last?.v ?? []
        #expect(key.count == 12 && Array(key[..<5]) == [0, 0, 0, 0, 0] && abs(key[5] - 0.4) < 1e-9 && key[10] == 1 && key[11] == 0)
        let stops = card.looked(at: 1).fill.gradient?.stops ?? []
        #expect(stops.count == 2 && stops[0].color == Self.red && abs(stops[0].offset - 0.4) < 1e-9 && Self.near(stops[1].color, Self.green, within: 1e-5))
        #expect(card.looked(at: 0) == card)
        // Its line is the design's, and stays.
        #expect(card.looked(at: 1).fill.gradient?.start == card.fill.gradient?.start)
        // A colour more or fewer is another gradient: not for keys, and the design's to change.
        #expect(!card.poseLooks(at: 1) { $0.fill.gradient?.stops.append(GradientStop(offset: 0.5, color: .white)) })
        #expect(card.fill.gradient?.stops.count == 2)
        // A border's gradient likewise.
        card.border = Border(on: true, color: .black, width: 2)
        card.border.gradient = card.fill.gradient
        #expect(card.keyableLooks == [.fillStops(0), .borderStops(0), .borderWidth(0), .corners])
        #expect(card.poseLooks(at: 1) { $0.border.gradient?.stops[0].color = .white })
        #expect(Self.near(card.looked(at: 1).border.gradient?.stops[0].color ?? .black, .white, within: 1e-5))
    }

    // MARK: What is no longer there

    @Test func keysForWhatIsGoneChangeNothingAndWaitForItToComeBack() {
        var card = Self.card()
        #expect(card.poseLooks(at: 1) { $0.fill.color = Self.blue })
        let keyed = card
        // One colour made a gradient: the colour's keys are for nothing the design has.
        card.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.green)],
                                      start: .zero, end: CGPoint(x: 1, y: 1))
        #expect(!card.fits(.fill(0)) && !card.looksChange && card.hasLooks && card.isAnimated)
        #expect(card.looked(at: 1) == card && card.posed(at: 1) == card)
        #expect(FilmRow.marks(of: card, tracks: ["fill.0"]).map(\.gone) == [true, true])
        #expect(card.lookValue(.fill(0), at: 1) == nil)
        // The gradient is keyed beside them, on a track of its own.
        #expect(card.poseLooks(at: 1) { $0.fill.gradient?.stops[1].color = Self.blue })
        #expect(card.looks == [.fill(0), .fillStops(0)] && card.fits(.fillStops(0)))
        #expect(FilmRow.marks(of: card, tracks: ["fill.0.stops"]).map(\.gone) == [false, false])
        // One colour again: its keys are back, and the gradient's wait in their turn.
        card.fill.gradient = nil
        #expect(card.fits(.fill(0)) && !card.fits(.fillStops(0)))
        #expect(card.looked(at: 1).fill.color == keyed.looked(at: 1).fill.color)
        // The fill taken away: only turned off, as the design keeps its colour, and so its keys.
        card.remove(.fill, at: 0)
        #expect(!card.fill.on && card[track: "fill.0"] != nil && !card.fits(.fill(0)) && card.looked(at: 1) == card)
        card.fill.on = true
        #expect(card.fits(.fill(0)))
        // Keys with another count of numbers, as a file could have: nothing.
        card.motion?["fill.0"]?.keys[1].v = [1, 2, 3]
        #expect(!card.fits(.fill(0)) && card.looked(at: 1) == card)
        // Posed anew, those give way.
        #expect(card.poseLooks(at: 1) { $0.fill.color = Self.green })
        #expect(card.fits(.fill(0)) && card[track: "fill.0"]?.keys.allSatisfy { $0.v.count == 5 } == true)
        // An artboard's looks are the design's alone.
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(board.keyableLooks.isEmpty && !board.poseLooks(at: 1) { $0.fill.color = Self.blue })
        board.setLookKey(.fill(0), change: [0, 0, 0, 0, 0], at: 1)
        #expect(board.motion == nil)
    }

    @Test func aRectangleWhosePointsAreKeyedKeepsTheDesignsCorners() {
        var card = Self.card()
        #expect(card.poseLooks(at: 1) { $0.radii = [20, 20, 20, 20] })
        #expect(card.keyableLooks.contains(.corners) && card.looked(at: 1).radii == [20, 20, 20, 20])
        let round = card
        // Its Shape keyed: each key is for the points the design's corners make, so the corners
        // stay the design's in the film, and their keys wait.
        card.setKey(.shape, card.shapeRest.map { _ in 3 }, at: 1)
        #expect(!card.keyableLooks.contains(.corners) && !card.fits(.corners) && !card.looksChange)
        #expect(card.looked(at: 1).radii == [0, 0, 0, 0] && card.lookValue(.corners, at: 1) == nil)
        #expect(FilmRow.marks(of: card, tracks: ["corners"]).map(\.gone) == [true, true])
        // The film draws it as it draws one that never had them: the design's four points, moved.
        var never = card
        never[track: "corners"] = nil
        for t in [0, 0.5, 1] {
            let drawn = card.posed(at: t), alike = never.posed(at: t)
            #expect(drawn.kind == alike.kind && drawn.path == alike.path && drawn.frame == alike.frame && drawn.radii == alike.radii, "\(t)")
        }
        #expect(card.outline(at: 0.5)?.anchorCount == 4)
        // Nothing of the corners is posed there, while a colour still is; the keys they had stay.
        #expect(card.poseLooks(at: 1) { $0.radii = [8, 8, 8, 8]; $0.fill.color = Self.blue })
        #expect(card[track: "corners"] == round[track: "corners"] && card.fits(.fill(0)))
        card.setLookKey(.corners, change: [4, 4, 4, 4], at: 2)
        #expect(card[track: "corners"] == round[track: "corners"])
        // Without the Shape's keys the corners are keyed again, as they were.
        card[track: .shape] = nil
        #expect(card.fits(.corners) && card.looked(at: 1).radii == [20, 20, 20, 20])
    }

    @Test func keysFollowTheirFillAsItIsRestackedOrTakenAway() {
        var card = Self.card()
        card.add(Fill(color: Self.green))
        card.add(Fill(color: Self.blue))
        #expect(card.poseLooks(at: 1) { $0[fill: 1].color = .white })
        #expect(card.poseLooks(at: 1) { $0[fill: 2].color = .black })
        card.pose(.move, [10, 0], at: 1)
        let second = card[track: "fill.1"], third = card[track: "fill.2"], move = card[track: .move]
        // The top one moved to the bottom: each track goes with its fill.
        card.move(.fill, from: 2, to: 0)
        #expect(card.fill.color == Self.blue && card[fill: 2].color == Self.green)
        #expect(card[track: "fill.0"] == third && card[track: "fill.2"] == second && card[track: "fill.1"] == nil)
        #expect(Self.near(card.looked(at: 1).fill.color, .black, within: 1e-5) && Self.near(card.looked(at: 1)[fill: 2].color, .white, within: 1e-5))
        // The bottom one taken away: its keys go with it, the others come down a place.
        card.remove(.fill, at: 0)
        #expect(card.slots(.fill) == 2 && card[track: "fill.1"] == second && card[track: "fill.0"] == nil && card[track: "fill.2"] == nil)
        #expect(Self.near(card.looked(at: 1)[fill: 1].color, .white, within: 1e-5))
        // Nothing else of its motion was touched.
        #expect(card[track: .move] == move)
        // A move that cannot be made moves no keys.
        let was = card
        card.move(.fill, from: 0, to: 5)
        #expect(card == was)
        // Shadows and borders likewise.
        var lit = Self.card()
        lit.shadow = Shadow(on: true)
        lit.add(Shadow(on: true, y: 10))
        #expect(lit.poseLooks(at: 1) { $0[shadow: 1].y = 30 })
        lit.remove(.shadow, at: 0)
        #expect(lit.looks == [.shadow(0)] && lit.looked(at: 1).shadow.y == 30)
    }

    // MARK: In the film

    @Test func theFilmDrawsALayerWhoseLookChangesAgain() throws {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 200, height: 160))
        var group = Node(kind: .group, name: "Row", frame: CGRect(x: 100, y: 20, width: 80, height: 60))
        group.children = [Self.card().with { $0.name = "Dot"; $0.frame = CGRect(x: 0, y: 0, width: 80, height: 60) }]
        board.children = [Self.card(), group]
        #expect(!board.hasFilm && board.filmPieces().allSatisfy { !$0.changes })
        board.children[0].poseLook(.fill(0), showing: board.children[0].with { $0.fill.color = Self.blue }, at: 1)
        let piece = try #require(board.filmPieces().first { $0.layers == [board.children[0].id] })
        #expect(piece.kind == .layer && piece.changes)
        #expect(board.hasFilm && board.filmLength == 2)
        // Its drawing is the layer as it looks then, without its keys.
        let late = FilmPictures.subject(of: piece, on: board, at: 1), early = FilmPictures.subject(of: piece, on: board, at: 0)
        #expect(Self.near(late.layers[0].fill.color, Self.blue, within: 1e-5) && late.layers[0].motion == nil)
        #expect(early.layers[0].fill.color == Self.red && !late.isDrawn(as: early))
        // While its keys hold it, it is not drawn again.
        #expect(FilmPictures.subject(of: piece, on: board, at: 1.5) == late)
        // The frame shows it: red at the start, blue at its key, the page beside it.
        func pixel(_ t: Double, _ x: Int, _ y: Int) throws -> RGBA {
            let image = try #require(FilmExport.frame(of: board, at: t, size: CGSize(width: 200, height: 160), assets: nil))
            let p = ShaderDrawingTests.pixel(image, x, y)
            return RGBA(r: p.r, g: p.g, b: p.b)
        }
        #expect(Self.near(try pixel(0, 100, 80), Self.red, within: 0.03))
        #expect(Self.near(try pixel(1, 100, 80), Self.blue, within: 0.03))
        #expect(Self.near(try pixel(1, 20, 20), .white, within: 0.03))
        #expect(Self.near(try pixel(0.5, 100, 80), Self.mixed(Self.red, Self.blue, MotionEase.progress(.smooth, 0.5)), within: 0.03))
        // A layer inside a group: what holds it is drawn again as it changes.
        #expect(board.children[1].children[0].poseLooks(at: 1) { $0.radii = [20, 20, 20, 20] })
        #expect(board.children[1].holdsMotion && board.children[1].holdsLooks)
        let inner = try #require(board.filmPieces().first { $0.layers == [board.children[1].children[0].id] })
        #expect(inner.changes && inner.holders == [board.children[1].id])
        #expect(FilmPictures.subject(of: inner, on: board, at: 1).layers[0].cornerRadius == 20)
        // Its corner is round in the frame: the page shows where the card's corner was.
        #expect(Self.near(try pixel(1, 101, 21), .white, within: 0.03))
        #expect(Self.near(try pixel(0, 101, 21), Self.red, within: 0.03))
    }

    @Test func theTimelineShowsLooksOnLinesOfTheirOwn() {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var card = Self.card()
        card.border = Border(on: true, color: .black, width: 2)
        #expect(card.poseLooks(at: 1) { $0.fill.color = Self.blue })
        #expect(card.poseLooks(at: 2) { $0.border.width = 8 })
        card.pose(.move, [0, 40], at: 1.5)
        board.children = [card]
        var rows = FilmRow.rows(of: board, open: [])
        #expect(rows.map(\.name) == ["Camera", "Card"])
        #expect(rows[1].marks.map(\.t) == [0, 1, 1.5, 2] && !rows[1].single)
        rows = FilmRow.rows(of: board, open: [card.id])
        #expect(rows.map(\.name) == ["Camera", "Card", "Move", "Fill", "Border Width"])
        let fill = rows[3], width = rows[4]
        #expect(fill.look == .fill(0) && fill.single && fill.property == nil && fill.input == nil)
        #expect(fill.marks.map(\.t) == [0, 1] && fill.marks.map(\.home) == [true, false] && fill.marks.map(\.given) == [true, false])
        #expect(fill.marks.allSatisfy { !$0.gone } && fill.marks.last?.pace == .curve(.smooth, bounce: 0.3))
        #expect(width.marks.map(\.t) == [0, 2])
        // A key picked on a look's line is that line's, and its layer's, and no other line's.
        let ref = FilmKeyRef(card.id, look: .fill(0), at: 1)
        #expect(fill.holds(ref) && rows[1].holds(ref) && !width.holds(ref) && !rows[2].holds(ref) && !ref.whole)
        #expect(fill.holds(FilmKeyRef(card.id, at: 1)) && !fill.holds(FilmKeyRef(card.id, .move, at: 1)))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    // MARK: Kept and shared

    @Test func aDesignKeepsItsLookKeysThroughItsFileAndThroughSharing() throws {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var card = Self.card()
        card.border = Border(on: true, color: .black, width: 2)
        card.shadow = Shadow(on: true)
        #expect(card.poseLooks(at: 1) { n in
            n.fill.color = Self.blue
            n.border.color = Self.green
            n.border.width = 5
            n.radii = [4, 8, 12, 16]
            n.shadow.blur = 20
        })
        card.setLookKey(.fill(0), change: LookColor.change(to: Self.green, over: Self.red), at: 2.345, ease: .spring(0.4))
        board.children = [card]
        var doc = BezzleDocument()
        doc.nodes = [board]
        // Its file.
        let data = try JSONEncoder().encode(doc.nodes)
        #expect(try JSONDecoder().decode([Node].self, from: data) == doc.nodes)
        let text = String(decoding: data, as: UTF8.self)
        for name in ["fill.0", "border.0", "border.0.width", "corners", "shadow.0"] { #expect(text.contains("\"\(name)\""), "\(name)") }
        // Shared: each key on its own, by its track's name and its moment.
        let flat = FlatDesign(doc)
        #expect(flat.document().nodes == doc.nodes)
        var shared = SharedDesign()
        shared.absorb(flat, since: FlatDesign(), by: "a", at: 1)
        #expect(shared.flatDesign().document().nodes == doc.nodes)
        let fields = shared.layers[card.id]?.fields.keys.filter { $0.hasPrefix("motion/") }.sorted() ?? []
        #expect(fields.contains("motion/fill.0/1000") && fields.contains("motion/fill.0/2345") && fields.contains("motion/border.0.width/1000"))
        #expect(fields.contains("motion/corners/0/given") || fields.contains("motion/corners/0"))
        // Two keys of a look closer than the timeline tells apart, as two people can leave: one stands.
        doc.update(card.id) { n in
            n.motion?["fill.0"]?.keys.append(MotionKey(t: 1.001, v: [0, 0, 0, 0, 0]))
            n.motion?["fill.0"]?.keys.sort { $0.t < $1.t }
        }
        #expect(doc.node(card.id)?[track: "fill.0"]?.isCrowded == true)
        doc.repairMotion()
        #expect(doc.node(card.id)?[track: "fill.0"]?.isCrowded == false)
        // Remove Motion takes them with everything else.
        doc.clearMotion([card.id])
        #expect(doc.node(card.id)?.motion == nil)
    }
}
