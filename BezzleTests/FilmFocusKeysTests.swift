import Testing
import AppKit
@testable import Bezzle

/// One Mac's copy of a shared design, kept as `Collaboration` keeps it but without a relay, as
/// in `MotionSharingTests`.
private struct Mac {
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

    mutating func edit(_ change: (inout Node) -> Void) {
        let id = doc.nodes[0].id
        doc.update(id, change)
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

/// The camera's focus and its blur as two more of its numbers: keyed, paced, shown along the
/// timeline, stepped to, held and taken away as the others are, and kept in the design's file
/// and shared as two more of the artboard's tracks, which a Bezzle that does not know them
/// reads past and keeps.
@MainActor
struct FilmFocusKeysTests {
    private func board() -> Node {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80))]
        return board
    }

    // MARK: Two more of the camera's numbers

    @Test func theCamerasFocusAndBlurAreTwoMoreOfItsNumbers() {
        #expect(MotionProperty.camera.suffix(2) == [.cameraFocus, .cameraBlur])
        #expect(MotionProperty.view + [.cameraFocus, .cameraBlur] == MotionProperty.camera)
        #expect(MotionProperty.cameraFocus.isCamera && MotionProperty.cameraBlur.isCamera)
        #expect(MotionProperty.cameraFocus.rest == [0] && MotionProperty.cameraBlur.rest == [0])
        #expect(MotionProperty.cameraFocus.rawValue == "cameraFocus" && MotionProperty.cameraBlur.rawValue == "cameraBlur")
        #expect(MotionProperty.cameraFocus.title == "Focus" && MotionProperty.cameraBlur.title == "Blur")
        // Within what shows: no blur below nothing, none past a point of blur for every point
        // off the focus, and a focus no further off than a design reaches.
        #expect(MotionProperty.cameraBlur.clamped([-3]) == [0] && MotionProperty.cameraBlur.clamped([250]) == [100])
        #expect(MotionProperty.cameraBlur.clamped([.nan]) == [0] && MotionProperty.cameraBlur.clamped([6.5]) == [6.5])
        #expect(MotionProperty.cameraFocus.clamped([1e9]) == [100_000] && MotionProperty.cameraFocus.clamped([-1e9]) == [-100_000])
        #expect(MotionProperty.cameraFocus.clamped([.infinity]) == [0] && MotionProperty.cameraFocus.clamped([-80.5]) == [-80.5])
        var camera = FilmCamera()
        camera[.cameraFocus] = [120]
        camera[.cameraBlur] = [400]
        #expect(camera.focus == 120 && camera.blur == 100 && camera[.cameraFocus] == [120] && camera[.cameraBlur] == [100])
        // It still sees the whole artboard, and is no longer as it is with no keys at all.
        #expect(camera.seesWhole && !camera.isRest && !camera.inDepth)
    }

    @Test func theyAreKeyedAndComeToLikeItsOthers() {
        var b = board()
        #expect(b.camera(at: 1) == .rest && !b.hasCamera)
        b.setKey(.cameraBlur, [0], at: 0, ease: .linear)
        b.setKey(.cameraBlur, [8], at: 2, ease: .linear)
        b.setKey(.cameraFocus, [-40], at: 1, ease: .linear)
        b.setKey(.cameraFocus, [120], at: 2, ease: .hold)
        #expect(b.hasCamera && b.hasFilm && b.motionProperties == [.cameraFocus, .cameraBlur])
        #expect(b.camera(at: 0).blur == 0 && b.camera(at: 1).blur == 4 && b.camera(at: 2).blur == 8 && b.camera(at: 5).blur == 8)
        // Held until its key, and before its first as that is.
        #expect(b.camera(at: 0).focus == -40 && b.camera(at: 1.9).focus == -40 && b.camera(at: 2).focus == 120)
        #expect(b.keyTimes(MotionProperty.camera) == [0, 1, 2] && b.filmLength == 2)
        // Posed, a first key comes with the design for company, as any property's does.
        var posed = board()
        posed.pose(.cameraBlur, [6], at: 1.5)
        #expect(posed[track: .cameraBlur]?.keys == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1.5, v: [6])])
        posed.pose(.cameraFocus, [0], at: 1.5)
        #expect(posed[track: .cameraFocus] == nil)
        // What a key may hold is what the camera may be.
        posed.setKey(.cameraBlur, [1000], at: 3)
        #expect(posed.camera(at: 3).blur == 100)
    }

    @Test func theTimelineHasALineForEachAndAMarqueePicksTheirKeys() {
        var b = board()
        b.setKey(.cameraZoom, [2], at: 0)
        b.setKey(.cameraFocus, [120], at: 1)
        b.setKey(.cameraBlur, [0], at: 0)
        b.setKey(.cameraBlur, [8], at: 2)
        var rows = FilmRow.rows(of: b, open: [])
        #expect(rows.map(\.name) == ["Camera"] && rows[0].marks.map(\.t) == [0, 1, 2])
        rows = FilmRow.rows(of: b, open: [b.id])
        #expect(rows.map(\.name) == ["Camera", "Zoom", "Focus", "Blur"])
        #expect(rows[2].property == .cameraFocus && rows[2].camera && rows[2].marks.map(\.t) == [1])
        #expect(rows[3].property == .cameraBlur && rows[3].marks.map(\.t) == [0, 2] && rows[3].marks.map(\.home) == [true, false])
        // Over the Focus line and the Blur line, the second half of the film.
        let scale = FilmScale(width: 400, span: 4)
        let caught = FilmMarquee(from: 0.8, to: 2.2, top: 2 * 20 + 2, foot: 4 * 20 - 2).keys(of: rows, line: 20, scale: scale)
        #expect(caught == [FilmKeyRef(b.id, .cameraFocus, at: 1), FilmKeyRef(b.id, .cameraBlur, at: 2)])
    }

    // MARK: On the desk

    @Test func thePlayheadStepsToThemHoldSetsThemAndRemoveMotionTakesThem() {
        let bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80))])
        let store = bench.store
        store.show(.animate)
        store.glide.stop()
        func keys(_ property: MotionProperty) -> [MotionKey] { store.filmBoard?[track: property]?.keys ?? [] }
        store.pickCamera()
        store.seek(1)
        bench.step { store.poseCamera(.cameraBlur, number: 0, to: 6) }
        #expect(bench.undo.undoActionName == "Blur")
        store.seek(2)
        bench.step { store.poseCamera(.cameraFocus, number: 0, to: 80) }
        #expect(bench.undo.undoActionName == "Focus")
        #expect(keys(.cameraBlur).map(\.t) == [0, 1] && keys(.cameraFocus).map(\.t) == [0, 2])
        #expect(store.filmBoard?.camera(at: 2) == { var c = FilmCamera(); c.focus = 80; c.blur = 6; return c }())
        // The arrows step from key to key of the camera, these among them.
        #expect(store.filmStops == [0, 1, 2])
        // Between keys, the bead says so, and Hold sets one for each there, holding what it is.
        store.seek(1.5)
        #expect(store.keyState(.cameraFocus) == .between && store.keyState(.cameraBlur) == .between && store.holdState == .between)
        let focus = store.filmBoard?.camera(at: 1.5).focus ?? -1
        #expect(focus > 0 && focus < 80)
        bench.step { store.holdHere() }
        #expect(store.keyState(.cameraFocus) == .here && store.keyState(.cameraBlur) == .here && store.holdState == .here)
        #expect(keys(.cameraFocus).map(\.t) == [0, 1.5, 2] && keys(.cameraFocus)[1].v == [focus] && keys(.cameraBlur).last == MotionKey(t: 1.5, v: [6]))
        // A bead clicked takes its key away; a key picked in the timeline is taken away alone.
        bench.step { store.toggleKey(.cameraBlur) }
        #expect(keys(.cameraBlur).map(\.t) == [0, 1] && store.keyState(.cameraBlur) == .between)
        store.film.keys = [FilmKeyRef(bench.a.id, .cameraFocus, at: 1.5)]
        bench.step { store.removeFilmKeys() }
        #expect(keys(.cameraFocus).map(\.t) == [0, 2] && keys(.cameraBlur).map(\.t) == [0, 1])
        // Moved along the timeline like any key.
        bench.step {
            store.beginGesture()
            #expect(store.retime([FilmKeyRef(bench.a.id, .cameraFocus, at: 2)], by: 0.5) == [FilmKeyRef(bench.a.id, .cameraFocus, at: 2.5)])
            store.endGesture("Move Key")
        }
        #expect(keys(.cameraFocus).map(\.t) == [0, 2.5])
        // Remove Motion, with the camera in hand, takes all of the camera's.
        bench.step { store.poseCamera(.cameraZoom, number: 0, to: 2) }
        bench.step { store.clearFilmMotion() }
        #expect(store.filmBoard?.motion == nil && store.filmBoard?.camera(at: 1) == .rest)
        bench.undo.undo()
        #expect(keys(.cameraFocus).map(\.t) == [0, 2.5] && keys(.cameraBlur).map(\.t) == [0, 1])
    }

    // MARK: The file, and sharing

    private func filmed() -> BezzleDocument {
        var b = board()
        b.setKey(.cameraZoom, [1.5], at: 0)
        b.setKey(.cameraFocus, [-40], at: 0, ease: .linear)
        b.setKey(.cameraFocus, [120], at: 1, ease: .spring(0.4))
        b.setKey(.cameraBlur, [6.5], at: 2.345)
        b.children[0].setKey(.lift, [120], at: 0)
        var doc = BezzleDocument()
        doc.nodes = [b]
        return doc
    }

    @Test func aDesignKeepsThemThroughItsFileAndThroughSharing() throws {
        let doc = filmed()
        // Its file: two more of the artboard's tracks, by their names, each a list of keys as any is.
        let data = try JSONEncoder().encode(doc.nodes)
        #expect(try JSONDecoder().decode([Node].self, from: data) == doc.nodes)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let motion = try #require(json[0]["motion"] as? [String: [String: Any]])
        #expect(Set(motion.keys) == ["cameraZoom", "cameraFocus", "cameraBlur"])
        let zoom = try #require((motion["cameraZoom"]?["keys"] as? [[String: Any]])?.first)
        let blur = try #require((motion["cameraBlur"]?["keys"] as? [[String: Any]])?.first)
        #expect(Set(blur.keys) == Set(zoom.keys) && blur["v"] as? [Double] == [6.5] && blur["t"] as? Double == 2.345)
        #expect(Set(motion["cameraBlur"]?.keys.map { $0 } ?? []) == Set(motion["cameraZoom"]?.keys.map { $0 } ?? []))
        // Shared: each key on its own, by its track's name and its moment.
        let flat = FlatDesign(doc)
        #expect(flat.document().nodes == doc.nodes)
        var shared = SharedDesign()
        shared.absorb(flat, since: FlatDesign(), by: "a", at: 1)
        #expect(shared.flatDesign().document().nodes == doc.nodes)
        let fields = shared.layers[doc.nodes[0].id]?.fields.keys.filter { $0.hasPrefix("motion/") }.sorted() ?? []
        #expect(fields.contains("motion/cameraFocus/0") && fields.contains("motion/cameraFocus/1000") && fields.contains("motion/cameraBlur/2345"), "\(fields)")
        // Two keys closer than the timeline tells apart, as two people can leave: one stands.
        var crowded = doc
        crowded.update(doc.nodes[0].id) { n in
            n.motion?["cameraFocus"]?.keys.append(MotionKey(t: 1.001, v: [5]))
            n.motion?["cameraFocus"]?.keys.sort { $0.t < $1.t }
        }
        #expect(crowded.nodes[0][track: .cameraFocus]?.isCrowded == true)
        crowded.repairMotion()
        #expect(crowded.nodes[0][track: .cameraFocus]?.isCrowded == false)
    }

    @Test func twoPeopleKeyingThemBothKeepWhatTheySet() {
        var a = Mac("a", doc: filmed())
        var b = Mac("b")
        b.receive(a.state)
        #expect(b.doc.nodes == a.doc.nodes)
        // Before either has seen the other's: one pulls the focus later, the other sets a blur
        // at the start and takes the late one away.
        a.edit { $0.setKey(.cameraFocus, [300], at: 3, ease: .linear) }
        b.edit { n in
            n.setKey(.cameraBlur, [2], at: 0)
            n.removeKeys(at: 2.345, of: [.cameraBlur])
        }
        for _ in 0..<3 {
            a.receive(b.state)
            b.receive(a.state)
        }
        #expect(a.doc.nodes == b.doc.nodes)
        let board = a.doc.nodes[0]
        #expect(board[track: .cameraFocus]?.keys.map(\.t) == [0, 1, 3] && board[track: .cameraFocus]?.keys.last?.v == [300])
        #expect(board[track: .cameraBlur]?.keys == [MotionKey(t: 0, v: [2])])
        // The same key set two ways: both come to show the same one of the two.
        a.edit { $0.setKey(.cameraFocus, [10], at: 1) }
        b.edit { $0.setKey(.cameraFocus, [20], at: 1) }
        for _ in 0..<3 {
            a.receive(b.state)
            b.receive(a.state)
        }
        #expect(a.doc.nodes == b.doc.nodes)
        #expect([[10.0], [20.0]].contains(a.doc.nodes[0][track: .cameraFocus]?.keys[1].v ?? []))
    }

    @Test func aFilmWithoutThemIsWrittenAsItAlwaysWas() throws {
        // Every other number of the camera keyed, and a layer blurred by its own keys.
        var b = board()
        for p in MotionProperty.view { b.setKey(p, p == .cameraMove ? [10, 20] : [1.5], at: 1) }
        b.children[0].setKey(.blur, [4], at: 0)
        b.film = Film(length: 3, once: true)
        var doc = BezzleDocument()
        doc.nodes = [b]
        let written = try #require(String(data: JSONEncoder().encode(doc), encoding: .utf8))
        #expect(!written.contains("cameraFocus") && !written.contains("cameraBlur"))
        #expect(written.contains("cameraSwing") && written.contains("\"blur\""))
        // Nor is anything written for a camera whose focus and blur were keyed and taken away again.
        var had = doc
        had.update(b.id) { n in
            n.setKey(.cameraBlur, [6], at: 1)
            n.setKey(.cameraFocus, [60], at: 1)
            n.removeKeys(at: 1, of: [.cameraBlur, .cameraFocus])
        }
        #expect(had == doc)
        // And shared, such a film has no entry of theirs.
        var shared = SharedDesign()
        shared.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1)
        #expect(shared.layers[b.id]?.fields.keys.contains { $0.contains("cameraFocus") || $0.contains("cameraBlur") } == false)
    }

    /// The design's file as a Bezzle reads it that does not know the two tracks. What it does
    /// with a track is told by the track's name alone, so here they go by two names this Bezzle
    /// does not know either: it reads them as Bezzle 1.7 reads `cameraFocus` and `cameraBlur`,
    /// with the code 1.7 has for it (`Node.motion` is a dictionary of tracks by name there too,
    /// and its sharing goes by each track's name: checked against v1.7's `Node.swift`,
    /// `Motion.swift` and `FlatDesign.swift`).
    @Test func aBezzleThatDoesNotKnowThemReadsPastThemAndKeepsThem() throws {
        let doc = filmed()
        func renamed(_ data: Data, _ names: [String: String]) throws -> Data {
            func walk(_ value: Any) -> Any {
                if let d = value as? [String: Any] { return Dictionary(uniqueKeysWithValues: d.map { (names[$0.key] ?? $0.key, walk($0.value)) }) }
                if let a = value as? [Any] { return a.map(walk) }
                return value
            }
            return try JSONSerialization.data(withJSONObject: walk(JSONSerialization.jsonObject(with: data)))
        }
        let unknown = ["cameraFocus": "cameraFar", "cameraBlur": "cameraSoft"]
        #expect(MotionProperty(rawValue: "cameraFar") == nil && MotionProperty(rawValue: "cameraSoft") == nil)
        let file = try renamed(JSONEncoder().encode(doc), unknown)
        // It opens, and its film is the film without them: the camera closer, the card lifted, nothing blurred.
        let older = try JSONDecoder().decode(BezzleDocument.self, from: file)
        let board = older.nodes[0]
        #expect(board.motionProperties == [.cameraZoom] && board.children == doc.nodes[0].children)
        var plain = FilmCamera()
        plain.zoom = 1.5
        #expect(board.camera(at: 1) == plain)
        let pieces = board.filmPieces(), layers = board.filmLayers(of: pieces)
        #expect(pieces.indices.allSatisfy { board.placement(of: pieces[$0], layer: layers[$0], at: 1, camera: board.camera(at: 1)).soft == nil })
        #expect(FilmRow.rows(of: board, open: [board.id, board.children[0].id]).map(\.name) == ["Camera", "Zoom", "Card", "Lift"])
        // Their keys count toward how long the film runs when it follows its keys.
        #expect(board.filmLength == 2.5)
        // Kept: saved again, the file has them as they were, and this Bezzle reads its own design back.
        let saved = try JSONEncoder().encode(older)
        #expect(try JSONDecoder().decode(BezzleDocument.self, from: renamed(saved, Dictionary(uniqueKeysWithValues: unknown.map { ($0.value, $0.key) }))) == doc)
        // Kept through an edit of the camera and of a layer, as that Bezzle makes them.
        var edited = older
        edited.update(board.id) { $0.pose(.cameraZoom, [3], at: 1) }
        edited.update(board.children[0].id) { $0.pose(.move, [10, 0], at: 1) }
        edited.repairMotion()
        #expect(edited.nodes[0].motion?["cameraFar"] == board.motion?["cameraFar"] && edited.nodes[0].motion?["cameraSoft"] == board.motion?["cameraSoft"])
        // Kept through sharing, each key an entry of its own under its track's name.
        #expect(FlatDesign(older).document().nodes == older.nodes)
        var shared = SharedDesign()
        shared.absorb(FlatDesign(older), since: FlatDesign(), by: "old", at: 1)
        #expect(shared.flatDesign().document().nodes == older.nodes)
        let fields = shared.layers[board.id]?.fields.keys.filter { $0.hasPrefix("motion/camera") }.sorted() ?? []
        #expect(fields.contains("motion/cameraFar/1000") && fields.contains("motion/cameraSoft/2345"), "\(fields)")
        // Taking all motion from the artboard takes them along; taking the camera's leaves
        // them, as 1.7 names the camera's tracks one by one.
        var cleared = older
        cleared.clearMotion([board.id])
        #expect(cleared.nodes[0].motion == nil)
    }
}
