import Testing
import AppKit
@testable import Bezzle

/// Words along curves: a text bent into an arc of its own, or riding a shape's outline.
@MainActor
struct TextCurveTests {
    /// A text "Words" on artboard A, at 40,40, its letters 32 pt.
    private func words(_ text: String = "ROUND AND ROUND", size: CGFloat = 32) -> Node {
        var n = Node(kind: .text, name: "Words", frame: CGRect(x: 40, y: 40, width: 10, height: 10))
        n.text = text
        n.style?.size = size
        n.refit()
        return n
    }

    private func ring(_ frame: CGRect = CGRect(x: 100, y: 80, width: 160, height: 160)) -> Node {
        Node(kind: .ellipse, name: "Ring", frame: frame)
    }

    /// Where a layer's point of its own coordinates is on the canvas.
    private func onCanvas(_ p: CGPoint, of id: UUID, in doc: BezzleDocument) -> CGPoint {
        p.applying(CurveTool.toCanvas(doc.node(id)!, origin: doc.parentOrigin(of: id)))
    }

    /// The middle of each letter's baseline, on the canvas, and which way it reads there.
    private func feet(of id: UUID, in doc: BezzleDocument) -> [(p: CGPoint, angle: CGFloat)] {
        let node = doc.node(id)!
        guard let laid = CurvedText.laid(node) else { return [] }
        let t = CurveTool.toCanvas(node, origin: doc.parentOrigin(of: id))
        return laid.letters.filter { $0.advance > 1 }.map { l in
            let m = l.place.concatenating(t)
            return (CGPoint(x: l.advance / 2, y: 0).applying(m), atan2(m.b, m.a))
        }
    }

    // MARK: Bending

    @Test func bendingKeepsTheMiddleOfTheWordsWhereItWas() throws {
        var n = words()
        let middle = CGPoint(x: n.frame.minX + n.frame.width / 2, y: n.frame.minY + TextLayout.firstBaseline(n))
        n.bend(to: 0.25)
        let laid = try #require(CurvedText.laid(n))
        #expect(n.curve?.bend == 0.25)
        let apex = CGPoint(x: n.frame.minX + laid.anchor.x, y: n.frame.minY + laid.anchor.y)
        #expect(abs(apex.x - middle.x) < 0.05 && abs(apex.y - middle.y) < 0.05, "\(apex) \(middle)")
        // Arched: the ends lie lower than the middle, and the box is taller than a line.
        let ends = (laid.walk.points.first!, laid.walk.points.last!)
        #expect(ends.0.y > laid.anchor.y + 5 && ends.1.y > laid.anchor.y + 5)
        #expect(n.frame.height > 50)
        // Straight again, the words' middle is where it was.
        n.bend(to: 0)
        #expect(n.curve == nil && n.curvePath == nil)
        let back = CGPoint(x: n.frame.minX + n.frame.width / 2, y: n.frame.minY + TextLayout.firstBaseline(n))
        #expect(abs(back.x - middle.x) < 0.6 && abs(back.y - middle.y) < 0.6, "\(back) \(middle)")
    }

    @Test func aFullBendClosesTheWordsIntoARing() throws {
        var n = words("ONE TWO THREE FOUR FIVE SIX ")
        n.bend(to: 1)
        let laid = try #require(CurvedText.laid(n))
        // As wide as it is tall, give or take the letters' own shapes.
        #expect(abs(n.frame.width - n.frame.height) < n.frame.width * 0.08, "\(n.frame)")
        // Its line goes all the way round: its two ends meet below its middle.
        let a = laid.walk.points.first!, b = laid.walk.points.last!
        #expect(hypot(a.x - b.x, a.y - b.y) < 0.5)
        let r = CurvedText.width(of: n) / (2 * .pi)
        #expect(abs(a.y - laid.anchor.y - 2 * r) < 0.5)
        // The middle letter reads upright, at the top.
        let feet = laid.letters.map { l in (CGPoint(x: l.advance / 2, y: 0).applying(l.place), atan2(l.place.b, l.place.a)) }
        let top = try #require(feet.min { $0.0.y < $1.0.y })
        #expect(abs(top.1) < 0.15)
    }

    @Test func aSagCurvesTheOtherWay() throws {
        var n = words()
        n.bend(to: -0.3)
        let laid = try #require(CurvedText.laid(n))
        #expect(laid.walk.points.first!.y < laid.anchor.y - 5)
        #expect(laid.walk.points.last!.y < laid.anchor.y - 5)
    }

    @Test func typingMoreWordsKeepsTheBend() throws {
        var n = words("ABC")
        n.bend(to: 0.5)
        let middle = CurvedText.laid(n)!.anchor.applying(CGAffineTransform(translationX: n.frame.minX, y: n.frame.minY))
        n.text = "ABCDEFGHIJ"
        n.refit()
        let laid = try #require(CurvedText.laid(n))
        // Still a half circle, now a bigger one, its middle where it was.
        let a = laid.walk.points.first!, b = laid.walk.points.last!
        #expect(abs(a.y - b.y) < 0.5)
        #expect(abs((a.y - laid.anchor.y) - abs(b.x - a.x) / 2) < 1, "a half circle is as deep as half its width")
        let now = laid.anchor.applying(CGAffineTransform(translationX: n.frame.minX, y: n.frame.minY))
        #expect(abs(now.x - middle.x) < 0.05 && abs(now.y - middle.y) < 0.05)
    }

    @Test func refittingAgainChangesNothing() {
        var n = words()
        n.bend(to: 0.37)
        let once = n
        n.refit()
        n.refit()
        #expect(n.frame == once.frame, "\(n.frame) \(once.frame)")
        #expect(n.curvePath == once.curvePath, "\(n.curvePath ?? "") || \(once.curvePath ?? "")")
        #expect(n == once)
    }

    @Test func aTurnedTextBendsWhereItIs() throws {
        var n = words()
        n.rotation = 30
        let before = n
        let middle = CGPoint(x: n.frame.width / 2, y: TextLayout.firstBaseline(n)).applying(CurveTool.toCanvas(n, origin: .zero))
        n.bend(to: 0.4)
        let laid = try #require(CurvedText.laid(n))
        let apex = laid.anchor.applying(CurveTool.toCanvas(n, origin: .zero))
        #expect(abs(apex.x - middle.x) < 0.05 && abs(apex.y - middle.y) < 0.05)
        #expect(n.rotation == before.rotation)
    }

    // MARK: Riding a shape

    private func ridden(at: Double? = nil, reversed: Bool = false, hangs: Bool = false) -> (Bench, UUID) {
        let bench = Bench(extra: [ring(), words()])
        let text = bench.node("Words")!.id, shape = bench.node("Ring")!.id
        var curve = TextCurve(rides: true)
        curve.at = at
        curve.reversed = reversed ? true : nil
        curve.hangs = hangs ? true : nil
        bench.step { bench.store.edit(DocumentStore.riding) { doc in DocumentStore.ride(text, on: shape, curve: curve, in: &doc) } }
        return (bench, text)
    }

    @Test func aTextPutOnAShapeRidesItsOutline() throws {
        let (bench, text) = ridden()
        let doc = bench.store.doc
        let group = try #require(doc.parent(of: text))
        #expect(group.isGroup && group.carriesText)
        #expect(group.children.map(\.name) == ["Ring", "Words"])
        let node = try #require(doc.node(text))
        #expect(node.rides && node.curvePath != nil)
        // Every letter stands on the ring: its foot on the outline, round its middle at 280,260 on the canvas.
        let centre = CGPoint(x: 100 + 100 + 80, y: 100 + 80 + 80)
        for f in feet(of: text, in: doc) {
            #expect(abs(hypot(f.p.x - centre.x, f.p.y - centre.y) - 80) < 0.6, "\(f.p)")
        }
        // Centred on the top, reading upright there.
        let top = try #require(feet(of: text, in: doc).min { $0.p.y < $1.p.y })
        #expect(abs(top.p.x - centre.x) < 20)
        #expect(abs(top.angle) < 0.25)
        // The group is the box round the ring and the words.
        let box = Geometry.bounds(of: doc.node(group.children[0].id)!).union(Geometry.bounds(of: node))
        #expect(abs(group.frame.width - box.width) < 0.01 && abs(group.frame.height - box.height) < 0.01)
        // One step back is as it was.
        bench.undoLast()
        #expect(bench.store.doc.parent(of: text)?.isArtboard == true)
        #expect(bench.store.doc.node(text)?.curve == nil)
    }

    @Test func wordsReversedAlongTheBottomReadUprightInside() throws {
        let (bench, text) = ridden(reversed: true)
        let doc = bench.store.doc
        let centre = CGPoint(x: 280, y: 260)
        let bottom = try #require(feet(of: text, in: doc).max { $0.p.y < $1.p.y })
        #expect(abs(bottom.p.x - centre.x) < 20)
        #expect(abs(bottom.angle) < 0.25, "upright at the bottom")
        // Standing on the ring from inside: the letters' tops point at its middle.
        let node = doc.node(text)!
        let laid = try #require(CurvedText.laid(node))
        let t = CurveTool.toCanvas(node, origin: doc.parentOrigin(of: text))
        for l in laid.letters where l.advance > 1 {
            let foot = CGPoint(x: l.advance / 2, y: 0).applying(l.place.concatenating(t))
            let head = CGPoint(x: l.advance / 2, y: l.ascent * 0.7).applying(l.place.concatenating(t))
            #expect(hypot(head.x - centre.x, head.y - centre.y) < hypot(foot.x - centre.x, foot.y - centre.y))
        }
    }

    @Test func hangingLettersHaveTheirTopsOnTheOutline() throws {
        let (bench, text) = ridden(hangs: true)
        let doc = bench.store.doc
        let centre = CGPoint(x: 280, y: 260)
        let node = doc.node(text)!
        let laid = try #require(CurvedText.laid(node))
        let cap = CTFontGetCapHeight(Fonts.font(node.style!) as CTFont)
        let t = CurveTool.toCanvas(node, origin: doc.parentOrigin(of: text))
        for l in laid.letters where l.advance > 1 {
            let top = CGPoint(x: l.advance / 2, y: cap).applying(l.place.concatenating(t))
            #expect(abs(hypot(top.x - centre.x, top.y - centre.y) - 80) < 1.5, "\(top)")
        }
    }

    @Test func theWordsFollowTheShapeWhereverItGoes() throws {
        let (bench, text) = ridden()
        let shape = bench.node("Ring")!.id
        // Twice as big, and moved.
        bench.step {
            bench.store.edit("Resize") { doc in doc.update(shape) { $0.frame = CGRect(x: $0.frame.minX + 30, y: $0.frame.minY, width: 320, height: 320) } }
        }
        let doc = bench.store.doc
        let ring = doc.absoluteFrame(of: shape)!
        let centre = CGPoint(x: ring.midX, y: ring.midY)
        for f in feet(of: text, in: doc) {
            #expect(abs(hypot(f.p.x - centre.x, f.p.y - centre.y) - 160) < 0.8, "\(f.p)")
        }
        // Turned with it, still on it.
        bench.step { bench.store.edit("Rotate") { doc in doc.update(shape) { $0.rotation = 45 } } }
        for f in feet(of: text, in: bench.store.doc) {
            #expect(abs(hypot(f.p.x - centre.x, f.p.y - centre.y) - 160) < 0.8)
        }
        #expect(bench.store.doc.node(text)?.rotation == 0)
    }

    @Test func slidingMovesTheWordsAlongTheOutline() throws {
        let (bench, text) = ridden()
        let firstTop = try #require(feet(of: text, in: bench.store.doc).min { $0.p.y < $1.p.y })
        let walk = try #require(CurvedText.laid(bench.store.doc.node(text)!)).walk
        let top = CurvedText.top(of: walk, bottom: false) / walk.total
        // A quarter of the way round, clockwise: to the ring's right side.
        bench.step { bench.store.update([text], DocumentStore.slidingText) { $0.curve?.at = Double(top) + 0.25 } }
        let feet = feet(of: text, in: bench.store.doc)
        let right = try #require(feet.max { $0.p.x < $1.p.x })
        #expect(right.p.x > firstTop.p.x + 60)
        #expect(abs(right.angle - .pi / 2) < 0.3)
    }

    @Test func aSecondTextRidesTheSameShape() throws {
        let (bench, text) = ridden()
        var second = words("BOTTOM")
        second.name = "Bottom"
        bench.step { bench.store.edit("Add") { $0.attach(second, to: bench.a.id) } }
        let shape = bench.node("Ring")!.id
        bench.step {
            bench.store.edit(DocumentStore.riding) { doc in DocumentStore.ride(second.id, on: shape, curve: TextCurve(reversed: true), in: &doc) }
        }
        let group = try #require(bench.store.doc.parent(of: text))
        #expect(group.children.map(\.name) == ["Ring", "Words", "Bottom"])
        #expect(bench.store.doc.parent(of: second.id)?.id == group.id)
    }

    @Test func takenOffTheWordsAreStraightAndTheShapeIsAloneAgain() throws {
        let (bench, text) = ridden()
        bench.step { bench.store.edit(DocumentStore.takingOffPath) { doc in DocumentStore.takeOffPath([text], in: &doc) } }
        let doc = bench.store.doc
        let node = try #require(doc.node(text))
        #expect(node.curve == nil && node.curvePath == nil && node.rotation == 0)
        #expect(doc.parent(of: text)?.isArtboard == true)
        // The group made for them is the ring again, where it was.
        let ring = try #require(bench.node("Ring"))
        #expect(doc.parent(of: ring.id)?.isArtboard == true)
        #expect(doc.absoluteFrame(of: ring.id) == CGRect(x: 200, y: 180, width: 160, height: 160))
    }

    @Test func withTheShapeGoneTheWordsKeepTheirCurve() throws {
        let (bench, text) = ridden()
        let before = feet(of: text, in: bench.store.doc)
        let shape = bench.node("Ring")!.id
        bench.step { bench.store.edit("Delete") { _ = $0.detach(shape) } }
        let node = try #require(bench.store.doc.node(text))
        #expect(node.isCurved && !node.rides)
        let after = feet(of: text, in: bench.store.doc)
        #expect(zip(before, after).allSatisfy { hypot($0.p.x - $1.p.x, $0.p.y - $1.p.y) < 0.05 })
    }

    @Test func aMasksShapeOrARepeatGridCarriesNoWords() {
        var photo = Node(kind: .rectangle, name: "Photo", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        photo.fill.color = .black
        var mask = Node(kind: .group, name: "Mask", frame: .zero)
        mask.clipsToFirst = true
        mask.children = [ring(CGRect(x: 0, y: 0, width: 80, height: 80)), photo]
        let bench = Bench(extra: [mask, words()])
        #expect(!DocumentStore.canRide(bench.node("Words")!.id, on: bench.node("Ring")!.id, in: bench.store.doc))
    }

    // MARK: Drawing, picking, sharing, exporting

    @Test func lettersArePickedWhereTheyAreNotInTheMiddleOfARing() throws {
        var n = words("AROUND THE WORLD AROUND THE ")
        n.bend(to: 1)
        let laid = try #require(CurvedText.laid(n))
        let parent = CGPoint(x: n.frame.minX, y: n.frame.minY)
        let letter = laid.letters[laid.letters.count / 2]
        let on = CGPoint(x: letter.advance / 2, y: letter.ascent / 2).applying(letter.place)
        #expect(Geometry.contains(n, CGPoint(x: parent.x + on.x, y: parent.y + on.y), tolerance: 0))
        #expect(!Geometry.contains(n, CGPoint(x: n.frame.midX, y: n.frame.midY), tolerance: 2))
    }

    @Test func curvedWordsAreDrawn() throws {
        var n = words("OOOOOOOOOOOO", size: 40)
        n.fill.color = RGBA(r: 1, g: 0, b: 0)
        n.bend(to: 1)
        n.frame.origin = CGPoint(x: 20, y: 20)
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: n.frame.maxX + 20, height: n.frame.maxY + 20))
        board.children = [n]
        let image = try #require(Renderer.image(of: board, scale: 1))
        let rep = NSBitmapImageRep(cgImage: image)
        var red = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.8, c.greenComponent < 0.3 { red += 1 }
            }
        }
        #expect(red > 200)
        // Nothing in the middle of the ring.
        let mid = rep.colorAt(x: Int(n.frame.midX), y: Int(n.frame.midY))!
        #expect(mid.greenComponent > 0.9)
    }

    @Test func curvesAreSharedAndSavedField() throws {
        #expect(LayerField.all.contains { $0.name == "curve" })
        #expect(LayerField.all.contains { $0.name == "curvePath" })
        var n = words()
        n.bend(to: -0.6)
        let data = try JSONEncoder().encode(n)
        let back = try JSONDecoder().decode(Node.self, from: data)
        #expect(back == n)
    }

    @Test func svgKeepsEveryLetterAsTextTurnedWhereItLies() throws {
        var n = words("CURVE")
        n.bend(to: 0.5)
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        board.children = [n]
        let svg = SVGWriter.document(for: ExportItem(artboard: board), bounds: board.frame, assets: nil)
        #expect(svg.components(separatedBy: "<text transform=\"matrix(").count - 1 == 5, "\(svg)")
        #expect(svg.contains(">C</text>") && svg.contains(">V</text>"))
    }

    @Test func typingIsStraightWhereTheCurveRunsThroughTheWordsMiddle() throws {
        var n = words()
        n.bend(to: 1)
        let laid = try #require(CurvedText.laid(n))
        let (flat, frame) = CurvedText.straight(n, frame: n.frame)
        #expect(flat.curve == nil && flat.curvePath == nil)
        // Its baseline's middle is where the ring's top is, and it reads level there.
        let middle = CGPoint(x: frame.width / 2, y: TextLayout.firstBaseline(Node.with(flat, frame: frame))).applying(CurveTool.toCanvas(Node.with(flat, frame: frame), origin: .zero))
        let top = laid.anchor.applying(CurveTool.toCanvas(n, origin: .zero))
        #expect(abs(middle.x - top.x) < 0.6 && abs(middle.y - top.y) < 0.6, "\(middle) \(top)")
        #expect(abs(flat.rotation) < 1)
    }

    // MARK: For the assistant

    @Test func theAssistantBendsLaysAlongAndStraightens() async throws {
        let bench = Bench(extra: [ring(), words()])
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let bent = await call("curve_text", ["layers": ["Words"], "bend": 180])
        #expect(!bent.failed, "\(bent.text)")
        #expect(bench.node("Words")?.curve?.bend == 0.5)
        #expect(bent.text.contains("\"curve\":{\"bend\":180}"), "\(bent.text)")
        let laid = await call("curve_text", ["layers": ["Words"], "shape": "Ring", "reversed": true])
        #expect(!laid.failed, "\(laid.text)")
        let node = try #require(bench.node("Words"))
        #expect(node.rides && node.curve?.reversed == true && node.curve?.bend == nil)
        let slid = await call("curve_text", ["layers": ["Words"], "at": 0.25])
        #expect(!slid.failed, "\(slid.text)")
        #expect(bench.node("Words")?.curve?.at == 0.25)
        let refused = await call("curve_text", ["layers": ["Words"], "bend": 90])
        #expect(refused.failed)
        let straight = await call("straighten_text", ["layers": ["Words"]])
        #expect(!straight.failed, "\(straight.text)")
        #expect(bench.node("Words")?.curve == nil)
        #expect(bench.store.doc.parent(of: node.id)?.isArtboard == true)
    }
}
