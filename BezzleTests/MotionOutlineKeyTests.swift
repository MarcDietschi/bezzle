import Testing
import AppKit
@testable import Bezzle

/// Animate's Shape keys that hold an outline of their own: one with other points than the
/// design's, more or fewer. What such a key is in a design's file and in a shared design, what a
/// Bezzle from before them makes of it, how a shape goes from one outline into another, what
/// the design's own changes do to it, and a shape given another shape's outline.
@MainActor
struct MotionOutlineKeyTests {
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

    /// A path on the canvas through these points, its frame round them.
    private func path(_ data: String, name: String = "Path") -> Node {
        var n = Node.path(BezierPath(data), name: name)
        n.fill.on = true
        n.fill.color = .black
        return n
    }

    /// A triangle that is a square with four points at one second and a house with five at two.
    private func house() -> Node {
        var n = path("M 0 0 L 100 0 L 50 80 Z", name: "House")
        n.poseShape(BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z"), at: 1)
        n.poseShape(BezierPath("M 0 0 L 50 -40 L 100 0 L 100 80 L 0 80 Z"), at: 2)
        return n
    }

    /// Whether two outlines are the same runs of points, each where the other has it, give or take.
    private func alike(_ a: BezierPath?, _ b: BezierPath?, _ e: Double = 0.001) -> Bool {
        guard let a, let b, a.hasRuns(of: b) else { return false }
        return zip(a.numbers, b.numbers).allSatisfy { abs($0 - $1) < e }
    }

    private func close(_ a: CGRect, _ b: CGRect, _ e: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) < e && abs(a.minY - b.minY) < e && abs(a.width - b.width) < e && abs(a.height - b.height) < e
    }

    /// How far a gentle pace has come at half its time: further than halfway, as it sets off
    /// faster than it arrives.
    private let gently = MotionEase.progress(.smooth, 0.5)

    /// The bounds of an outline's points.
    private func box(_ outline: BezierPath?) -> CGRect {
        let points = outline?.anchorPoints ?? []
        guard let first = points.first else { return .null }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    // MARK: The key's numbers

    @Test func anOutlineAsAKeyAndBackIsTheSame() throws {
        let outline = BezierPath("M 0 0 L 100 0 C 120 40 80 80 50 100 L 0 100 Z M 10 10 L 40 12 C 50 20 60 40 30 50")
        #expect(outline.subpaths.map(\.anchors.count) == [4, 3] && outline.subpaths.map(\.closed) == [true, false])
        let key = outline.asKey(over: 3)
        // A nought for each number a change of three points has, six numbers to each run and to
        // each anchor, and how many sixes there are: never a whole number of sixes.
        #expect(key.count == 18 + 6 * (2 + 7) + 1 && key.count % 6 == 1)
        #expect(key.prefix(18).allSatisfy { $0 == 0 })
        #expect(key.last == 9)
        #expect(Array(key[18..<24]) == [4, 1, 0, 0, 0, 0])
        #expect(BezierPath(key: key) == outline)
        // It is read from its end, whatever stands before its runs.
        #expect(BezierPath(key: outline.asKey(over: 0)) == outline)
        #expect(BezierPath(key: [7, 7, 7, 7, 7, 7] + outline.asKey(over: 0)) == outline)
        // The numbers stay what they are when kept as a key's.
        #expect(MotionProperty.shape.clamped(key) == key)
        // A change of points holds none, nor do numbers that are neither.
        #expect(BezierPath(key: Array(repeating: 0, count: 18)) == nil)
        #expect(BezierPath(key: []) == nil && BezierPath(key: [1]) == nil && BezierPath(key: [0, 0, 0, 0, 0, 0, 1]) == nil)
        for (at, value) in [(key.count - 1, 10.0), (key.count - 1, 8.5), (18, 4.5), (18, 5), (18, 0), (19, 2), (26, .nan), (72, .infinity)] {
            var broken = key
            broken[at] = value
            #expect(BezierPath(key: broken) == nil, "\(at) as \(value)")
        }
    }

    @Test func aLayerSaysAnOutlineAsAChangeWhereItCanAndElseAsTheOutline() throws {
        let n = path("M 0 0 L 100 0 L 50 80 Z")
        let design = try #require(n.ownOutline)
        // The design's own runs, moved: a change of each point, as ever.
        var moved = design
        moved.subpaths[0].anchors[2].point.y += 40
        let change = try #require(n.shapeValue(of: moved))
        #expect(change.count == 18 && n.shapeOutline(of: change) == moved)
        // Other points: the outline itself, behind a nought for each of the design's numbers.
        let square = BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z")
        let key = try #require(n.shapeValue(of: square))
        #expect(key.count == 18 + 6 * 5 + 1 && key.prefix(18).allSatisfy { $0 == 0 })
        #expect(n.shapeOutline(of: key) == square)
        #expect(n.takes(.shape, key) && n.takes(.shape, change) && !n.takes(.shape, [1, 2, 3]))
        // The same points, open where the design is closed: the outline itself too.
        var open = design
        open.subpaths[0].closed = false
        let opened = try #require(n.shapeValue(of: open))
        #expect(opened.count % 6 == 1 && n.shapeOutline(of: opened)?.subpaths[0].closed == false)
        // Runs with nothing to draw are left out, and an outline of nothing but those is none.
        let dotted = BezierPath(subpaths: square.subpaths + [BezierPath.Subpath(anchors: [BezierPath.Anchor(CGPoint(x: 5, y: 5))], closed: false)])
        #expect(n.shapeValue(of: dotted) == key)
        #expect(n.shapeValue(of: BezierPath(subpaths: [BezierPath.Subpath(anchors: [BezierPath.Anchor(.zero)], closed: false)])) == nil)
        #expect(n.shapeValue(of: BezierPath()) == nil)
        // Numbers made for a layer with other points are kept as this one says them.
        var other = n
        other.setKey(.shape, square.asKey(over: 11), at: 1)
        #expect(other[track: .shape]?.keys.first?.v == key)
        // And an outline with the design's runs, said as an outline, is kept as a change.
        other.setKey(.shape, moved.asKey(over: 3), at: 2)
        #expect(other[track: .shape]?.keys.last?.v == change)
    }

    @Test func aLayerWithNoOutlineTakesNone() {
        var text = Node(kind: .text, name: "T", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        text.text = "Hi"
        let posed = text.poseShape(BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z"), at: 1)
        #expect(!posed && text.motion == nil)
        #expect(!text.takes(.shape, BezierPath("M 0 0 L 1 1").asKey(over: 0)))
    }

    // MARK: One outline into another

    @Test func atEachKeyTheOutlineIsExactlyWhatWasKeyedAndBetweenItIsOnItsWay() throws {
        let n = house()
        let design = try #require(n.ownOutline)
        let keys = try #require(n[track: .shape]).keys
        #expect(keys.map(\.t) == [0, 1, 2] && keys[0].given == true)
        #expect(keys.map { $0.v.count } == [18, 18 + 30 + 1, 18 + 36 + 1])
        let square = BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z"), roofed = BezierPath("M 0 0 L 50 -40 L 100 0 L 100 80 L 0 80 Z")
        #expect(n.outline(at: 0) == design && n.outline(at: -1) == design)
        #expect(n.outline(at: 1) == square && n.outline(at: 1.002) == square)
        #expect(n.outline(at: 2) == roofed && n.outline(at: 9) == roofed)
        // On the way nothing leaves the room the two outlines take up, and nothing jumps: each
        // moment is close to the one before, from the first key to the last.
        var last = try #require(n.outline(at: 0))
        var t = 0.0
        while t < 2 {
            t += 1.0 / 120
            let now = try #require(n.outline(at: t))
            #expect(now.numbers.allSatisfy { $0.isFinite })
            #expect(CGRect(x: -0.5, y: -40.5, width: 101, height: 121).contains(box(now)), "at \(t): \(box(now))")
            // The same points as a moment ago, moved a little; or, at a key, other points of the same outline.
            if now.hasRuns(of: last) {
                let far = zip(now.anchorPoints, last.anchorPoints).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
                #expect(far < 3, "at \(t): a point \(far) from where it was")
            } else {
                #expect(abs(box(now).height - box(last).height) < 3 && abs(box(now).width - box(last).width) < 3, "at \(t)")
            }
            last = now
        }
        // At half time from the triangle to the square: the two given the same points, each as
        // far as the pace has it. The tip stays where the bottom edge's middle is, and the sides
        // open out to the corners.
        let (from, to) = BezierPath.matched(design, square)
        let half = try #require(n.outline(at: 0.5))
        #expect(alike(half, from.mixed(with: to, gently)))
        #expect(half.anchorCount == 5 && half.anchorPoints.contains { near($0, CGPoint(x: 50, y: 80)) }, "\(half.anchorPoints)")
        #expect(half.anchorPoints.contains { $0.x > 80 && $0.y > 55 && $0.y < 75 } && half.anchorPoints.contains { $0.x < 20 && $0.y > 55 && $0.y < 75 })
        // At half time from the square to the house: the roof's top that far up from the top edge.
        let roof = try #require(n.outline(at: 1.5)).anchorPoints
        #expect(roof.contains { near($0, CGPoint(x: 50, y: -40 * gently)) }, "\(roof)")
        // What is drawn then: a path through those points, its frame round them.
        let drawn = n.reshaped(at: 2)
        #expect(drawn.kind == .path && abs(drawn.frame.minY - (n.frame.minY - 40)) < 0.01 && abs(drawn.frame.height - 120) < 0.01, "\(drawn.frame)")
        #expect(n.reshaped(at: 0) == n)
    }

    @Test func twoKeysThatSayTheSameOtherPointsGoPointByPointAndFlyThroughAKeyBetween() throws {
        var n = path("M 0 0 L 100 0 L 50 80 Z")
        // Three squares, each further right than the last: other points than the design's, the
        // same in all three.
        func square(_ dx: CGFloat) -> BezierPath { BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z").applying(CGAffineTransform(translationX: dx, y: 0)) }
        n.setKey(.shape, try #require(n.shapeValue(of: square(0))), at: 0)
        n.setKey(.shape, try #require(n.shapeValue(of: square(40))), at: 1)
        n.setKey(.shape, try #require(n.shapeValue(of: square(120))), at: 2)
        let track = try #require(n[track: .shape])
        let design = try #require(n.ownOutline)
        // Through the middle key it keeps going, at speed, as any property's keys would.
        #expect(track.shapePace(of: 0, from: design) == .setOff && track.shapePace(of: 1, from: design) == .setDown)
        for t in [0.25, 0.5, 0.9, 1.3, 1.75] {
            let now = try #require(n.outline(at: t))
            #expect(now.subpaths.map(\.anchors.count) == [4] && now.subpaths[0].closed)
            let p = now.anchorPoints
            // Still a square, wherever it is.
            #expect(near(p[1], CGPoint(x: p[0].x + 100, y: 0)) && near(p[2], CGPoint(x: p[0].x + 100, y: 80)) && near(p[3], CGPoint(x: p[0].x, y: 80)), "\(p)")
            #expect(p[0].x > 0 && p[0].x < 120)
        }
        // Still moving as it passes the key between: no rest there.
        let before = try #require(n.outline(at: 0.98)).anchorPoints[0].x, after = try #require(n.outline(at: 1.02)).anchorPoints[0].x
        #expect(after - before > 1, "\(before) \(after)")
        // A pace that was chosen is kept.
        n.setKey(.shape, try #require(n.shapeValue(of: square(120))), at: 2, ease: MotionEase(kind: .linear))
        let even = try #require(n[track: .shape])
        #expect(even.shapePace(of: 1, from: design) == .curve(.linear, bounce: 0.3))
        #expect(near(try #require(n.outline(at: 1.5)).anchorPoints[0], CGPoint(x: 80, y: 0)))
    }

    @Test func thePaceBetweenOutlinesWithOtherPointsIsTheOneChosenOrGentle() throws {
        var n = house()
        let design = try #require(n.ownOutline)
        var track = try #require(n[track: .shape])
        #expect(track.shapePace(of: 0, from: design) == .curve(.smooth, bounce: 0.3))
        #expect(track.shapePace(of: 1, from: design) == .curve(.smooth, bounce: 0.3))
        // Even all the way: a quarter of the way at a quarter of the time.
        n.setKey(.shape, track.keys[2].v, at: 2, ease: MotionEase(kind: .linear))
        let quarter = try #require(n.outline(at: 1.25)).anchorPoints
        #expect(quarter.contains { near($0, CGPoint(x: 50, y: -10)) }, "\(quarter)")
        // Home to the design at the end, it settles.
        n.setKey(.shape, n.shapeRest, at: 3)
        track = try #require(n[track: .shape])
        #expect(track.shapePace(of: 2, from: design) == .curve(.easeOut, bounce: 0.3))
        #expect(n.outline(at: 3) == design)
        // A spring goes past and comes back, and is still whole.
        n.setKey(.shape, n.shapeRest, at: 3, ease: .spring(0.6))
        var past = false
        for t in stride(from: 2.0, through: 3.0, by: 0.01) {
            let now = try #require(n.outline(at: t))
            #expect(now.numbers.allSatisfy { $0.isFinite })
            // The roof's top, come down past the top edge it ends on.
            if now.anchorPoints.contains(where: { abs($0.x - 50) < 0.5 && $0.y > 0.5 && $0.y < 40 }) { past = true }
        }
        #expect(past)
        // The timeline's beads are paced as the shape is drawn.
        let marks = FilmRow.marks(of: n, tracks: [MotionProperty.shape.rawValue])
        #expect(marks.map(\.t) == [0, 1, 2, 3])
        #expect(marks[1].pace == .curve(.smooth, bounce: 0.3) && marks[2].pace == .curve(.linear, bounce: 0.3) && marks[3].pace == .curve(.spring, bounce: 0.6))
        #expect(marks.map(\.home) == [true, false, false, true])
    }

    @Test func aFilmDrawsAStretchBetweenOutlinesQuickly() throws {
        // A star of forty points into a circle of four, and on into a path of two runs.
        var star: [BezierPath.Anchor] = []
        for k in 0..<40 {
            let a = Double(k) / 40 * 2 * .pi, r = k % 2 == 0 ? 100.0 : 55
            star.append(BezierPath.Anchor(CGPoint(x: 100 + cos(a) * r, y: 100 + sin(a) * r)))
        }
        var n = Node.path(BezierPath(subpaths: [BezierPath.Subpath(anchors: star, closed: true)]), name: "Star")
        let circle = BezierPath(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200), transform: nil))
        n.poseShape(circle, at: 1)
        n.poseShape(BezierPath("M 0 0 L 200 0 L 200 90 L 0 90 Z M 0 110 L 200 110 L 200 200 L 0 200 Z"), at: 2)
        #expect(n[track: .shape]?.keys.count == 3)
        _ = n.reshaped(at: 0.5)
        _ = n.reshaped(at: 1.5)
        let start = CFAbsoluteTimeGetCurrent()
        var frames = 0
        for i in 0..<240 {
            let drawn = n.reshaped(at: Double(i) / 120)
            #expect(drawn.path?.isEmpty == false)
            frames += 1
        }
        let each = (CFAbsoluteTimeGetCurrent() - start) / Double(frames)
        // Inside a frame at 120 a second, however busy the Mac.
        #expect(each < 0.008, "\(each * 1000) ms a frame")
    }

    // MARK: A Bezzle from before such keys

    /// What Bezzle 1.7 shows of a layer's Shape at a moment: the design with the track's numbers
    /// then as a change of its points, and the design itself where they are none. The numbers
    /// are `MotionTrack.value(at:rest:)`'s, which is as 1.7 has it.
    private func asBefore(_ n: Node, at t: Double) throws -> BezierPath {
        let design = try #require(n.ownOutline), track = try #require(n[track: .shape])
        return design.changed(by: MotionProperty.shape.clamped(track.value(at: t, rest: n.shapeRest))) ?? design
    }

    @Test func aBezzleFromBeforeSuchKeysShowsTheDesignAtOneAndGoesToItGently() throws {
        var n = path("M 0 0 L 100 0 L 50 80 Z")
        let design = try #require(n.ownOutline)
        var moved = design
        moved.subpaths[0].anchors[2].point.y += 40
        n.poseShape(moved, at: 1)
        n.poseShape(BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z"), at: 2)
        n.poseShape(BezierPath("M 0 0 L 50 -40 L 100 0 L 100 80 L 0 80 Z"), at: 3)
        n.poseShape(moved, at: 4)
        #expect(n[track: .shape]?.keys.map { $0.v.count } == [18, 18, 49, 55, 18])
        // At a key of changes, what it says; at one that holds an outline, and between two, the design.
        #expect(try asBefore(n, at: 1) == moved && asBefore(n, at: 4) == moved)
        #expect(try asBefore(n, at: 2) == design && asBefore(n, at: 3) == design && asBefore(n, at: 2.4) == design)
        // Between a key of changes and one that holds an outline, the changes go, or come.
        #expect(near(try asBefore(n, at: 1.5).anchorPoints[2], CGPoint(x: 50, y: 80 + 40 * (1 - gently))))
        #expect(near(try asBefore(n, at: 3.5).anchorPoints[2], CGPoint(x: 50, y: 80 + 40 * gently)))
        // Never anything but the design's three points, whole.
        for t in stride(from: 0.0, through: 4.2, by: 0.02) {
            let shown = try asBefore(n, at: t)
            #expect(shown.anchorCount == 3 && shown.numbers.allSatisfy(\.isFinite))
            #expect(CGRect(x: -0.01, y: -0.01, width: 100.02, height: 120.02).contains(box(shown)), "at \(t)")
        }
        // Flying through keys, with one that holds an outline among them, it is whole too.
        var flown = path("M 0 0 L 100 0 L 50 80 Z")
        for (i, dy) in [10.0, 20, 30].enumerated() {
            var o = design
            o.subpaths[0].anchors[2].point.y += dy
            flown.setKey(.shape, try #require(flown.shapeValue(of: o)), at: Double(i))
        }
        flown.poseShape(BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z"), at: 3)
        for t in stride(from: 0.0, through: 3.2, by: 0.02) {
            let shown = try asBefore(flown, at: t)
            #expect(shown.anchorCount == 3 && shown.numbers.allSatisfy(\.isFinite), "at \(t)")
        }
    }

    // MARK: Kept in a file, and shared

    @Test func aDesignWithSuchKeysIsWrittenAndReadAsItIsAndSharedAsItIs() throws {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var n = house()
        n.setKey(.shape, try #require(n[track: .shape]).keys[2].v, at: 2, ease: .spring(0.4))
        board.children = [n]
        var doc = BezzleDocument()
        doc.nodes = [board]
        // The file.
        let url = Filmed.place()
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(doc, to: url)
        let back = try DesignFile.read(url)
        #expect(back.nodes == doc.nodes)
        let read = try #require(back.allNodes.first { $0.name == "House" })
        #expect(read.outline(at: 2) == BezierPath("M 0 0 L 50 -40 L 100 0 L 100 80 L 0 80 Z"))
        // Each key is in it as its numbers and its pace, nothing more: what a file has had since Animate.
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as? [String: Any])
        let motion = try #require(object["motion"] as? [String: Any]), shape = try #require(motion["shape"] as? [String: Any])
        let keys = try #require(shape["keys"] as? [[String: Any]])
        #expect(keys.map { Set($0.keys) } == [["t", "v", "given"], ["t", "v"], ["t", "v", "ease"]] as [Set<String>])
        #expect((keys[1]["v"] as? [Double])?.count == 49)
        // Shared: a Mac that takes the design in shows the same film.
        var mine = SharedDesign()
        mine.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1_001)
        var theirs = SharedDesign()
        theirs.merge(try JSONDecoder().decode(SharedDesign.self, from: JSONEncoder().encode(mine)))
        let shown = theirs.flatDesign().document()
        #expect(shown.allNodes.first { $0.name == "House" }?[track: .shape] == n[track: .shape])
        // One key of it changed on the other Mac comes back as that key alone.
        var changed = shown
        let id = n.id
        changed.update(id) { $0.poseShape(BezierPath("M 0 0 L 100 0 L 100 80 L 50 100 L 0 80 Z"), at: 1) }
        theirs.absorb(FlatDesign(changed), since: FlatDesign(shown), by: "b", at: 1_002)
        let sent = theirs.changes(by: "b", after: 0).layers[id]?.fields.keys.map { $0 } ?? []
        #expect(sent == ["motion/shape/1000"], "\(sent)")
        mine.merge(theirs)
        #expect(mine.flatDesign().document().allNodes.first { $0.name == "House" }?.outline(at: 1)?.anchorCount == 5)
    }

    // MARK: Keyed in Animate

    @Test func aKeyHeldBetweenTwoOutlinesSaysTheOutlineAsItIsThen() throws {
        let film = FilmBench([house()])
        let id = film.id("House")
        film.store.selection = [id]
        film.store.seek(0.5)
        let before = try #require(film.node("House").outline(at: 0.5))
        let early = try #require(film.node("House").outline(at: 0.25)), late = try #require(film.node("House").outline(at: 0.75))
        film.step { film.store.toggleKey(.shape) }
        var keys = film.keys("House", .shape)
        #expect(keys.map(\.t) == [0, 0.5, 1, 2])
        #expect(alike(film.node("House").outline(at: 0.5), before))
        #expect(film.store.keyState(.shape) == .here)
        // Either side it is on the same way still, by the same points or by others: where it is drawn is close.
        let earlyNow = try #require(film.node("House").outline(at: 0.25)), lateNow = try #require(film.node("House").outline(at: 0.75))
        #expect(abs(box(earlyNow).height - box(early).height) < 8 && abs(box(lateNow).height - box(late).height) < 8)
        // Taken away again, the film is as it was.
        film.step { film.store.toggleKey(.shape) }
        keys = film.keys("House", .shape)
        #expect(keys.map(\.t) == [0, 1, 2])
        // Hold does the same for everything that moves.
        film.store.seek(1.5)
        let there = try #require(film.node("House").outline(at: 1.5))
        film.step { film.store.holdHere() }
        #expect(film.keys("House", .shape).map(\.t) == [0, 1, 1.5, 2])
        #expect(alike(film.node("House").outline(at: 1.5), there))
        // The value the panel reads there is one the layer takes.
        let value = film.value("House", .shape)
        #expect(film.node("House").takes(.shape, value))
    }

    // MARK: When the design changes

    @Test func resizedInTheDesignAKeysOwnOutlineGrowsWithTheLayer() throws {
        let bench = Bench(extra: [house()])
        let id = try #require(bench.node("House")).id
        let before = bench.store.doc
        bench.step { bench.store.update([id], "Resize") { $0.resize(to: CGSize(width: 200, height: 240), byHeight: false) } }
        let now = try #require(bench.node("House"))
        #expect(now.frame.size == CGSize(width: 200, height: 240))
        // Twice as wide and three times as high, the square and the house with it.
        #expect(alike(now.outline(at: 1), BezierPath("M 0 0 L 200 0 L 200 240 L 0 240 Z")))
        #expect(alike(now.outline(at: 2), BezierPath("M 0 0 L 100 -120 L 200 0 L 200 240 L 0 240 Z")))
        #expect(now.outline(at: 0) == now.ownOutline)
        bench.undo.undo()
        #expect(bench.store.doc == before)
    }

    @Test func flippedInTheDesignAKeysOwnOutlineTurnsOverWithTheLayer() throws {
        let bench = Bench(extra: [house()])
        let id = try #require(bench.node("House")).id
        bench.step { bench.store.edit("Flip") { $0.flip([id], horizontally: false) } }
        let now = try #require(bench.node("House"))
        // Upside down in its frame: the roof points down, below the frame's own height of 80.
        let roof = try #require(now.outline(at: 2)).anchorPoints
        #expect(roof.count == 5 && roof.contains { near($0, CGPoint(x: 50, y: 120)) }, "\(roof)")
        #expect(close(box(now.outline(at: 1)), CGRect(x: 0, y: 0, width: 100, height: 80)))
    }

    @Test func aRectangleRoundedInTheDesignKeepsItsKeysOwnOutlineWhereItWas() throws {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80))
        let blob = BezierPath("M 0 0 L 60 -20 L 120 0 L 120 80 L 60 100 L 0 80 Z")
        card.poseShape(blob, at: 1)
        let bench = Bench(extra: [card])
        let was = try #require(bench.node("Card")).shapeRest.count
        bench.step { bench.store.update([card.id], "Corner Radius") { $0.cornerRadius = 16 } }
        let now = try #require(bench.node("Card"))
        #expect(now.shapeRest.count != was)
        #expect(now.outline(at: 1) == blob)
        // Its key stands behind a nought for each number the design's points have now, which is
        // all an older Bezzle reads of it.
        let key = try #require(now[track: .shape]?.keys.last).v
        #expect(key.count == now.shapeRest.count + 6 * 7 + 1 && key.prefix(now.shapeRest.count).allSatisfy { $0 == 0 })
        #expect(now[track: .shape]?.keys.first?.v == now.shapeRest)
    }

    @Test func pointsEditedInTheDesignLeaveAKeysOwnOutlineWhereItShows() throws {
        let bench = Bench(extra: [house()])
        let id = try #require(bench.node("House")).id
        let before = try #require(bench.node("House"))
        // Where the house shows on the artboard at two seconds.
        let shown = try #require(before.outline(at: 2)).applying(before.placement)
        // In the design, the triangle's left corner pulled 30 further left: its frame is fitted anew.
        var points = try #require(bench.store.doc.points(of: id))
        points.subpaths[0].anchors[0].point.x -= 30
        bench.step { bench.store.edit("Move Points") { $0.setPoints(points, of: id) } }
        let now = try #require(bench.node("House"))
        #expect(abs(now.frame.minX - (before.frame.minX - 30)) < 0.01)
        let after = try #require(now.outline(at: 2)).applying(now.placement)
        for (a, b) in zip(after.anchorPoints, shown.anchorPoints) { #expect(near(a, b), "\(a) \(b)") }
        #expect(after.anchorCount == 5)
    }

    // MARK: Where another shape's outline lies

    @Test func anothersOutlineIsPlacedAsItIsThenThroughWhatHoldsEach() throws {
        // A bar in a group that is turned a quarter, and a triangle that changes in time.
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 200, y: 40, width: 100, height: 40))
        group.rotation = 90
        group.children = [CanvasTests.rect("Bar", CGRect(x: 0, y: 0, width: 100, height: 40))]
        var tri = path("M 0 0 L 100 0 L 50 80 Z", name: "Tri")
        tri.frame.origin = CGPoint(x: 40, y: 150)
        var tall = try #require(tri.ownOutline)
        tall.subpaths[0].anchors[2].point.y += 80
        tri.poseShape(tall, at: 2)
        let dot = CanvasTests.rect("Dot", CGRect(x: 40, y: 20, width: 20, height: 20))
        let film = FilmBench([group, tri, dot])
        let board = film.board
        // The bar stands upright on the artboard, so the dot takes it upright, about its own middle.
        let bar = try #require(board.outline(of: film.id("Bar"), for: film.id("Dot"), at: 0))
        #expect(abs(box(bar).width - 40) < 0.01 && abs(box(bar).height - 100) < 0.01 && near(CGPoint(x: box(bar).midX, y: box(bar).midY), CGPoint(x: 10, y: 10)), "\(box(bar))")
        // The triangle on its way to tall, as it is then.
        let then = try #require(board.outline(of: film.id("Tri"), for: film.id("Dot"), at: 1))
        #expect(abs(box(then).height - (80 + 80 * gently)) < 0.01 && abs(box(then).midX - 10) < 0.01, "\(box(then))")
        // What the dot can take: the other shapes, the one in front first, those in a group too.
        #expect(board.shapesToTake(for: film.id("Dot")).map(\.name) == ["Tri", "Bar"])
        #expect(board.shapesToTake(for: film.id("Group")).isEmpty && board.shapesToTake(for: UUID()).isEmpty)
        // Not from itself, not from what has no outline, not for what has none.
        #expect(board.outline(of: film.id("Dot"), for: film.id("Dot"), at: 0) == nil)
        #expect(board.outline(of: film.id("Group"), for: film.id("Dot"), at: 0) == nil)
        #expect(board.outline(of: film.id("Dot"), for: film.id("Group"), at: 0) == nil)
    }

    @Test func aShapePosedWithAnothersOutlineHasItNumberedToComeFromTheOutlineBefore() throws {
        // A square given a circle of its size, whose own first point is at its right.
        var n = Node(kind: .rectangle, name: "Square", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let circle = BezierPath(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil))
        let posed = n.poseShape(taking: circle, at: 1)
        #expect(posed && n[track: .shape]?.keys.map(\.t) == [0, 1])
        let design = try #require(n.ownOutline), round = try #require(n.outline(at: 1))
        // The circle it is, each of its points come from the corner or the side nearest it.
        #expect(round.anchorPoints.allSatisfy { abs(hypot($0.x - 50, $0.y - 50) - 50) < 0.3 })
        let (from, to) = BezierPath.matched(design, round)
        let far = zip(from.anchorPoints, to.anchorPoints).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        #expect(far < 60, "\(far)")
        // A triangle next: it is laid along the circle before it, not along the design.
        let triangle = BezierPath("M 50 0 L 100 100 L 0 100 Z")
        let value = try #require(n.shapeValue(taking: triangle, at: 2))
        let laid = try #require(n.shapeOutline(of: value))
        #expect(alike(laid, triangle.laid(along: round)))
        #expect(n.shapeValue(taking: BezierPath(), at: 2) == nil)
    }

    // MARK: Another shape's outline

    @Test func aShapeGivenAnothersOutlineHasItAboutItsOwnMiddleNumberedToComeFromItsOwn() throws {
        // A square, and a circle elsewhere, half as large again and turned.
        let square = CanvasTests.rect("Square", CGRect(x: 40, y: 40, width: 100, height: 100))
        var circle = Node(kind: .ellipse, name: "Circle", frame: CGRect(x: 220, y: 60, width: 150, height: 150))
        circle.rotation = 45
        var star = path("M 50 0 L 62 38 L 100 38 L 69 60 L 81 100 L 50 76 L 19 100 L 31 60 L 0 38 L 38 38 Z", name: "Star")
        star.frame.origin = CGPoint(x: 20, y: 180)
        var text = Node(kind: .text, name: "Words", frame: CGRect(x: 300, y: 10, width: 50, height: 20))
        text.text = "Hi"
        let film = FilmBench([square, circle, star, text])
        let id = film.id("Square")
        // What it can take: the other shapes on the artboard, the one in front first; no words.
        #expect(film.store.shapesToTake(for: id).map(\.name) == ["Star", "Circle"])
        #expect(film.store.shapesToTake(for: film.id("Words")).isEmpty)
        film.store.seek(1)
        film.fresh()
        let design = film.design
        film.step { film.store.takeShape(of: film.id("Circle"), for: id) }
        #expect(film.design == design)
        #expect(film.undo.undoActionName == MotionProperty.shape.title)
        var now = film.node("Square")
        #expect(film.keys("Square", .shape).map(\.t) == [0, 1])
        // The circle, as large as it is, about the square's own middle.
        let round = try #require(now.outline(at: 1))
        #expect(round.subpaths.count == 1 && round.subpaths[0].closed)
        let r = round.anchorPoints.map { hypot($0.x - 50, $0.y - 50) }
        #expect(r.allSatisfy { abs($0 - 75) < 0.5 }, "\(r)")
        // Each of its points comes from the square's nearest corner or side: none goes more than
        // a short way, and none round the shape.
        let half = try #require(now.outline(at: 0.5))
        let (from, to) = BezierPath.matched(try #require(now.ownOutline), round)
        let far = zip(from.anchorPoints, to.anchorPoints).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        #expect(far < 40, "\(far)")
        #expect(CGRect(x: -26, y: -26, width: 152, height: 152).contains(box(half)))
        // The star next, a second later: it comes from the circle, and the circle's key is as it was.
        film.store.seek(2)
        film.step { film.store.takeShape(of: film.id("Star"), for: id) }
        now = film.node("Square")
        #expect(film.keys("Square", .shape).map(\.t) == [0, 1, 2])
        #expect(now.outline(at: 1) == round)
        // The star as it is: its ten points, and at most a point more on its outline where the
        // circle's first point and the star's meet between two of them.
        let pointed = try #require(now.outline(at: 2))
        let own = try #require(film.node("Star").ownOutline)
        #expect(own.anchorPoints.allSatisfy { p in pointed.anchorPoints.contains { near($0, p) } }, "\(pointed.anchorPoints)")
        #expect(pointed.anchorCount >= 10 && pointed.anchorCount <= 12)
        #expect(pointed.anchorPoints.allSatisfy { p in own.nearest(to: p).map { hypot($0.point.x - p.x, $0.point.y - p.y) < 0.01 } == true })
        #expect(close(box(pointed), CGRect(x: 0, y: 0, width: 100, height: 100)))
        // One step each.
        film.undo.undo()
        #expect(film.keys("Square", .shape).map(\.t) == [0, 1])
        film.undo.undo()
        #expect(film.node("Square").motion == nil)
        // A locked shape takes none.
        film.edit { $0.update(id) { $0.locked = true } }
        #expect(film.store.shapesToTake(for: id).isEmpty)
        let was = film.store.doc
        film.step { film.store.takeShape(of: film.id("Star"), for: id) }
        #expect(film.store.doc == was)
    }

    // MARK: The movie

    @Test func theMovieShowsTheOutlineOnItsWay() throws {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 200, height: 160))
        board.fill.color = .white
        // A black triangle, its tip at the bottom, that is a square at one second.
        var tri = path("M 50 30 L 150 30 L 100 110 Z", name: "Tri")
        tri.poseShape(BezierPath("M 0 0 L 100 0 L 100 80 L 0 80 Z"), at: 1)
        board.children = [tri]
        func dark(at t: Double, _ x: Int, _ y: Int) throws -> Bool {
            let size = FilmExport.size(of: board, settings: FilmExport.Settings(scale: 1, fps: 30))
            let image = try #require(FilmExport.frame(of: board, at: t, size: size, assets: nil))
            let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            return bytes[y * ctx.bytesPerRow + x * 4] < 90
        }
        // The square's bottom left corner: bare while it is a triangle, covered once it is a
        // square, and covered from halfway up before it is covered at the corner.
        #expect(try !dark(at: 0, 56, 104) && dark(at: 1, 56, 104))
        #expect(try !dark(at: 0, 60, 70) && dark(at: 0.5, 60, 70) && !dark(at: 0.5, 53, 107))
        // The middle is covered throughout.
        #expect(try dark(at: 0, 100, 50) && dark(at: 0.5, 100, 50) && dark(at: 1, 100, 50))
    }
}
