import Testing
import AppKit
@testable import Bezzle

/// One Mac's copy of a shared design, kept as `Collaboration` keeps it but without a relay: what
/// it shows, and the shared design it sends and takes in. As in `SharingTests`.
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

    /// Takes in what was changed here, as saving does.
    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    mutating func edit(_ change: (inout BezzleDocument) -> Void) {
        change(&doc)
        doc.fitGroups()
        commit()
    }

    /// Takes in another Mac's copy and shows it, as `Collaboration.receive` does.
    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }
}

/// Everyone takes in everyone's copy until nothing changes any more.
private func sync(_ macs: inout [Mac]) {
    for _ in 0..<4 {
        for i in macs.indices {
            for j in macs.indices where j != i { macs[i].receive(macs[j].state) }
        }
    }
}

private func node(_ doc: BezzleDocument, _ name: String) -> Node? { doc.allNodes.first { $0.name == name } }

private func set(_ doc: inout BezzleDocument, _ name: String, _ change: (inout Node) -> Void) {
    guard let id = node(doc, name)?.id else { Issue.record("No layer \(name)"); return }
    doc.update(id, change)
}

/// A film in a design several people work on at once. The rule is that no edit may ever be lost:
/// each test here is two people doing two things before either has seen the other's, and says
/// what both see afterwards.
@MainActor
struct MotionSharingTests {
    /// An artboard holding One, Two and a group of Three, bottom first.
    private func design() -> BezzleDocument {
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 400, y: 10, width: 100, height: 100))
        group.children = [CanvasTests.rect("Three", CGRect(x: 0, y: 0, width: 100, height: 100))]
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        board.children = [
            CanvasTests.rect("One", CGRect(x: 10, y: 10, width: 100, height: 100)),
            CanvasTests.rect("Two", CGRect(x: 200, y: 10, width: 100, height: 100)),
            group,
        ]
        let other = Node(kind: .artboard, name: "Other", frame: CGRect(x: 1000, y: 0, width: 800, height: 600))
        var doc = BezzleDocument()
        doc.nodes = [board, other]
        return doc
    }

    /// Two Macs with the same design, the second having fetched it from the first.
    private func pair(_ doc: BezzleDocument? = nil) -> (Mac, Mac) {
        let a = Mac("a", doc: doc ?? design())
        var b = Mac("b")
        b.receive(a.state)
        return (a, b)
    }

    /// Both have taken in the other's: they show the same design, which is returned.
    private func settled(_ a: Mac, _ b: Mac) -> BezzleDocument {
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc.nodes == macs[1].doc.nodes)
        #expect(macs[0].doc.masters == macs[1].doc.masters)
        return macs[0].doc
    }

    private func times(_ doc: BezzleDocument, _ name: String, _ property: MotionProperty) -> [Double] {
        node(doc, name)?[track: property]?.keys.map(\.t) ?? []
    }

    // MARK: Each their own

    @Test func aFilmReachesTheOtherMacAsItWasMade() {
        var (a, b) = pair()
        a.edit { doc in
            set(&doc, "One") { $0 = Filmed.moving($0) }
            set(&doc, "Three") { $0 = Filmed.everything("Three") .with(id: $0.id).with { $0.frame = CGRect(x: 0, y: 0, width: 100, height: 100) } }
            set(&doc, "Board") { $0 = Filmed.filmed($0) }
        }
        b.receive(a.state)
        #expect(b.doc.nodes == a.doc.nodes)
        #expect(node(b.doc, "Three")?.motionProperties == MotionProperty.layer)
        #expect(node(b.doc, "Board")?.film == Film(length: 3, once: true, backdrop: RGBA(r: 0.1, g: 0.1, b: 0.12)))
        #expect(node(b.doc, "Board")?.hasCamera == true)
        // And taken away again, it is gone on both: nothing of it stays behind in what is shared.
        a.edit { doc in doc.clearMotion(doc.nodes.map(\.id)) }
        b.receive(a.state)
        #expect(b.doc.allNodes.allSatisfy { $0.motion == nil && $0.film == nil })
        #expect(b.doc.nodes == a.doc.nodes)
        for layer in b.state.layers.values {
            for (name, field) in layer.fields where name.hasPrefix("motion") || name.hasPrefix("film") { #expect(field.value == .null, "\(name)") }
        }
    }

    @Test func twoPeoplePosingDifferentLayersBothKeepTheirKeys() {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0.pose(.move, [0, 60], at: 0) } }
        b.edit { set(&$0, "Two") { $0.pose(.turn, [90], at: 1) } }
        let doc = settled(a, b)
        #expect(times(doc, "One", .move) == [0, 0.5] && times(doc, "Two", .turn) == [0, 1])
        #expect(node(doc, "Two")?.value(of: .turn, at: 1) == [90])
    }

    @Test func twoPeoplePosingDifferentPropertiesOfOneLayerBothKeepTheirs() {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0.pose(.move, [0, 60], at: 0) } }
        b.edit { set(&$0, "One") { $0.pose(.fade, [0], at: 0); $0.pose(.scale, [2, 2], at: 2) } }
        let doc = settled(a, b)
        #expect(node(doc, "One")?.motionProperties == [.move, .scale, .fade])
        #expect(times(doc, "One", .move) == [0, 0.5] && times(doc, "One", .fade) == [0, 0.5] && times(doc, "One", .scale) == [0, 2])

        // The same of the camera: one zooms while the other looks elsewhere.
        var (c, d) = pair()
        c.edit { set(&$0, "Board") { $0.setKey(.cameraZoom, [2], at: 1) } }
        d.edit { set(&$0, "Board") { $0.setKey(.cameraMove, [40, 0], at: 1) } }
        let filmed = settled(c, d)
        #expect(node(filmed, "Board")?.motionProperties == [.cameraMove, .cameraZoom])
        #expect(node(filmed, "Board")?.camera(at: 1) == FilmCamera(x: 40, y: 0, zoom: 2))
    }

    // MARK: The same property

    /// What should be, and is not yet: keys of one property set by two people at different
    /// moments are both kept.
    @Test(.disabled("A property's keys are shared as one value, so of two people keying the same property of the same layer at once, the one who saved later keeps theirs and the other's keys are gone. Keeping both needs each key shared on its own, which changes how a film is shared: a decision to take before Animate is first released."))
    func twoPeopleKeyingOnePropertyAtDifferentMomentsBothKeepTheirKeys() {
        var doc = design()
        set(&doc, "One") { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [100, 0], at: 2) }
        var (a, b) = pair(doc)
        a.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
        b.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 3) } }
        #expect(times(settled(a, b), "One", .move) == [0, 1, 2, 3])
    }

    @Test func twoPeopleKeyingOnePropertyAtOnceLeaveOnePersonsKeysWhole() {
        var doc = design()
        set(&doc, "One") { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [100, 0], at: 2) }
        var (a, b) = pair(doc)
        a.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
        // The second saves later, by this design's clock.
        b.time = a.time + 10
        b.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 3) } }
        let both = settled(a, b)
        // Both see the same keys, and they are the keys one of them made, never a mixture that
        // neither saw: here the later one's, without the key the other set at one second.
        #expect(times(both, "One", .move) == [0, 2, 3])
        #expect(node(both, "One")?[track: .move] == node(b.doc, "One")?[track: .move])

        // The other way round in time, the other's stand.
        var (c, d) = pair(doc)
        d.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 3) } }
        c.time = d.time + 10
        c.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
        #expect(times(settled(c, d), "One", .move) == [0, 1, 2])

        // A pace set on a key by one and a key moved by the other: one property still, one of the two stands.
        var (e, f) = pair(doc)
        e.edit { set(&$0, "One") { $0.setEase(MotionEase(kind: .linear), at: 2, of: [.move]) } }
        f.time = e.time + 10
        f.edit { set(&$0, "One") { $0.moveKeys(from: 2, to: 2.5, of: [.move]) } }
        let paced = settled(e, f)
        #expect(times(paced, "One", .move) == [0, 2.5] && node(paced, "One")?[track: .move]?.keys[1].ease == nil)
    }

    // MARK: A layer moved, or gone

    @Test func oneMovesALayerWhileTheOtherAnimatesIt() {
        var (a, b) = pair()
        a.edit { doc in
            set(&doc, "One") { $0.frame.origin = CGPoint(x: 300, y: 300); $0.name = "First"; $0.fill.color = RGBA(r: 1, g: 0, b: 0) }
        }
        b.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        let doc = settled(a, b)
        let one = node(doc, "First")
        #expect(one?.frame.origin == CGPoint(x: 300, y: 300) && one?.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(one?.motion == Filmed.moves)

        // Put onto another artboard, into a group, or above the others meanwhile.
        var (c, d) = pair()
        c.edit { doc in
            let one = node(doc, "One")!.id, two = node(doc, "Two")!.id, three = node(doc, "Three")!.id
            doc.move(one, to: node(doc, "Other")!.id, at: 0)
            _ = doc.group([two])
            doc.arrange([three], .front)
        }
        d.edit { doc in
            for name in ["One", "Two", "Three"] { set(&doc, name) { $0 = Filmed.moving($0) } }
        }
        let moved = settled(c, d)
        #expect(node(moved, "Other")?.children.map(\.name) == ["One"])
        #expect(moved.parent(of: node(moved, "Two")!.id)?.isGroup == true)
        for name in ["One", "Two", "Three"] { #expect(node(moved, name)?.motion == Filmed.moves, "\(name)") }
        #expect(node(moved, "Other")?.hasFilm == true)
    }

    @Test func oneDeletesALayerTheOtherAnimates() {
        // Animated after it was taken away, by someone who had not seen it go: it comes back, with its keys.
        var (a, b) = pair()
        a.edit { doc in _ = doc.detach(node(doc, "One")!.id) }
        b.time = a.time + 10
        b.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        let back = settled(a, b)
        #expect(node(back, "One")?.motion == Filmed.moves)
        #expect(node(back, "Board")?.children.map(\.name).contains("One") == true)

        // Taken away after it was animated, by someone who had not seen the keys: it stays away.
        // The keys go with the layer they were on, as its colour would.
        var (c, d) = pair()
        d.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        c.time = d.time + 10
        c.edit { doc in _ = doc.detach(node(doc, "One")!.id) }
        let gone = settled(c, d)
        #expect(node(gone, "One") == nil)
        #expect(node(gone, "Board")?.holdsMotion == false)

        // The group it lies in taken apart while it is animated: it lies on the artboard, and moves.
        var (e, f) = pair()
        e.edit { doc in _ = doc.ungroup([node(doc, "Group")!.id]) }
        f.time = e.time + 10
        f.edit { set(&$0, "Three") { $0 = Filmed.moving($0) } }
        let apart = settled(e, f)
        #expect(node(apart, "Three")?.motion == Filmed.moves)
        #expect(node(apart, "Three")?.frame.width == 100)

        // The artboard deleted while its camera is posed by the other, who saved later: it comes back.
        var (g, h) = pair()
        g.edit { doc in _ = doc.detach(node(doc, "Board")!.id) }
        h.time = g.time + 10
        h.edit { set(&$0, "Board") { $0 = Filmed.filmed($0) } }
        let board = settled(g, h)
        #expect(node(board, "Board")?.film?.length == 3 && node(board, "Board")?.hasCamera == true)
    }

    // MARK: Taking motion away

    @Test func oneTakesMotionAwayWhileTheOtherAddsToIt() {
        var doc = design()
        set(&doc, "One") { $0 = Filmed.moving($0) }
        // Of another property: what was taken away is gone, what was added is there.
        var (a, b) = pair(doc)
        a.edit { doc in doc.clearMotion([node(doc, "One")!.id]) }
        b.edit { set(&$0, "One") { $0.pose(.turn, [45], at: 1) } }
        let turned = settled(a, b)
        #expect(node(turned, "One")?.motionProperties == [.turn])

        // Of the same property, by the one who saved later: that property is as they left it, the other still gone.
        var (c, d) = pair(doc)
        c.edit { doc in doc.clearMotion([node(doc, "One")!.id]) }
        d.time = c.time + 10
        d.edit { set(&$0, "One") { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        let kept = settled(c, d)
        #expect(node(kept, "One")?.motionProperties == [.move] && times(kept, "One", .move) == [0, 1.6])

        // One key of a property removed by one while the other moves a key of another property.
        var (e, f) = pair(doc)
        e.edit { set(&$0, "One") { $0.removeKeys(at: 0.6, of: [.fade]) } }
        f.edit { set(&$0, "One") { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
        let both = settled(e, f)
        #expect(times(both, "One", .fade) == [0] && times(both, "One", .move) == [0, 1.6])
    }

    // MARK: The film's settings

    @Test func oneSetsTheFilmsLengthWhileTheOtherSetsItsBackdrop() {
        let dark = RGBA(r: 0.1, g: 0.1, b: 0.12)
        var (a, b) = pair()
        a.edit { set(&$0, "Board") { $0.film = Film(length: 5) } }
        b.edit { set(&$0, "Board") { $0.film = Film(backdrop: dark) } }
        #expect(node(settled(a, b), "Board")?.film == Film(length: 5, backdrop: dark))

        // On a film that had all three set: each changes one, and all three are as last set.
        var doc = design()
        set(&doc, "Board") { $0.film = Film(length: 3, once: true, backdrop: dark) }
        var (c, d) = pair(doc)
        c.edit { set(&$0, "Board") { $0.film?.length = 8 } }
        d.edit { set(&$0, "Board") { $0.film?.once = nil } }
        #expect(node(settled(c, d), "Board")?.film == Film(length: 8, backdrop: dark))

        // Both set the length: one of the two stands, the later, and the rest is untouched.
        var (e, f) = pair(doc)
        e.edit { set(&$0, "Board") { $0.film?.length = 8 } }
        f.time = e.time + 10
        f.edit { set(&$0, "Board") { $0.film?.length = 4 } }
        #expect(node(settled(e, f), "Board")?.film == Film(length: 4, once: true, backdrop: dark))

        // One lets the length follow the keys again while the other changes the backdrop; and
        // the last setting taken away leaves no film at all, on both.
        var (g, h) = pair(doc)
        g.edit { set(&$0, "Board") { $0.film?.length = nil; $0.film?.once = nil } }
        h.edit { set(&$0, "Board") { $0.film?.backdrop = .white } }
        #expect(node(settled(g, h), "Board")?.film == Film(backdrop: .white))
        var (i, j) = pair(doc)
        i.edit { set(&$0, "Board") { $0.film?.length = nil; $0.film?.once = nil } }
        j.edit { set(&$0, "Board") { $0.film?.backdrop = nil } }
        #expect(node(settled(i, j), "Board")?.film == nil)

        // The film's settings by one, its camera by the other, a layer's keys by a third.
        var macs = [Mac("a", doc: design()), Mac("b"), Mac("c")]
        sync(&macs)
        macs[0].edit { set(&$0, "Board") { $0.film = Film(length: 6, once: true) } }
        macs[1].edit { set(&$0, "Board") { $0.setKey(.cameraZoom, [1.5], at: 2) } }
        macs[2].edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        sync(&macs)
        #expect(macs[0].doc.nodes == macs[1].doc.nodes && macs[1].doc.nodes == macs[2].doc.nodes)
        let board = node(macs[2].doc, "Board")
        #expect(board?.film == Film(length: 6, once: true) && board?.hasCamera == true && board?.holdsMotion == true)
    }

    @Test func undoingAFilmSettingLeavesWhatSomeoneElseSetSince() {
        // Undo goes through `FlatDesign.apply`: it takes back only what was done on this Mac.
        let dark = RGBA(r: 0.1, g: 0.1, b: 0.12)
        var before = design()
        set(&before, "Board") { $0.film = Film(length: 3) }
        var mine = before
        set(&mine, "Board") { $0.film?.length = 8 }
        var now = mine
        set(&now, "Board") { $0.film?.backdrop = dark; $0.film?.once = true }
        set(&now, "One") { $0 = Filmed.moving($0) }
        let undone = FlatDesign.apply(from: mine, to: before, onto: now)
        #expect(node(undone, "Board")?.film == Film(length: 3, once: true, backdrop: dark))
        #expect(node(undone, "One")?.motion == Filmed.moves)
        // Someone set the length too since: theirs stands.
        var theirs = mine
        set(&theirs, "Board") { $0.film?.length = 12 }
        #expect(node(FlatDesign.apply(from: mine, to: before, onto: theirs), "Board")?.film == Film(length: 12))
        // Setting a film where there was none, undone: there is none, unless someone set something of it.
        let none = design()
        var made = none
        set(&made, "Board") { $0.film = Film(length: 4, once: true) }
        #expect(node(FlatDesign.apply(from: made, to: none, onto: made), "Board")?.film == nil)
        var more = made
        set(&more, "Board") { $0.film?.backdrop = dark }
        #expect(node(FlatDesign.apply(from: made, to: none, onto: more), "Board")?.film == Film(backdrop: dark))

        // A key undone while someone else keyed another property of the layer, and the same one.
        var keyed = before
        set(&keyed, "One") { $0.pose(.move, [0, 60], at: 0) }
        var other = keyed
        set(&other, "One") { $0.pose(.fade, [0], at: 0) }
        #expect(node(FlatDesign.apply(from: keyed, to: before, onto: other), "One")?.motionProperties == [.fade])
        var same = keyed
        set(&same, "One") { $0.setKey(.move, [80, 0], at: 2) }
        #expect(times(FlatDesign.apply(from: keyed, to: before, onto: same), "One", .move) == [0, 0.5, 2])
    }

    // MARK: In the app

    /// A bench whose design is shared by link, kept on disk as a shared design is, with another
    /// Mac that has fetched it. No relay is reached: tests have none. As in `SharingTests`.
    private func sharedBench() -> (Bench, Collaboration, Mac) {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        bench.store.save()
        DocumentStore.finishSaving()
        try? SharingFiles.write(ShareLink(secret: ShareKeys.newSecret().base64URL, title: "Test"), to: bench.store.url)
        let session = Collaboration.open(bench.store.url)!
        _ = session.document()
        bench.store.sharing = session
        session.attach(to: bench.store)
        var other = Mac("other")
        other.time = Collaboration.now
        other.receive(session.state)
        return (bench, session, other)
    }

    @Test func inTheAppAFilmIsSharedAndUndoingHereLeavesWhatOthersDidToIt() throws {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        let r = bench.node("R")!.id, a = bench.a.id
        // Here a layer is given keys, and then the film a length.
        bench.step { store.edit("Add Key") { doc in doc.update(r) { $0 = Filmed.moving($0) } } }
        bench.step { store.edit("Film Length") { doc in doc.update(a) { $0.film = Film(length: 5) } } }
        store.save()
        other.receive(session.state)
        #expect(other.doc.nodes == store.doc.nodes)
        // There, meanwhile: another property of the same layer, the film's backdrop, the camera.
        other.time = Collaboration.now + 10
        other.edit { doc in
            set(&doc, "R") { $0.pose(.turn, [45], at: 1) }
            set(&doc, "A") { $0.film?.backdrop = .black; $0.setKey(.cameraZoom, [2], at: 1) }
        }
        session.receive([other.state], from: .cloud)
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        #expect(bench.a.film == Film(length: 5, backdrop: .black) && bench.a.hasCamera)

        // Undo here takes back the film's length alone, then the layer's own keys alone.
        bench.undo.undo()
        #expect(bench.a.film == Film(backdrop: .black) && bench.a.hasCamera)
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        bench.undo.undo()
        #expect(bench.node("R")?.motionProperties == [.turn])
        store.save()
        other.receive(session.state)
        #expect(other.doc.nodes == store.doc.nodes)
        bench.undo.redo()
        bench.undo.redo()
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        #expect(bench.a.film == Film(length: 5, backdrop: .black) && bench.a.hasCamera)

        // Closed and opened again, the shared design has all of it.
        store.save()
        session.persist()
        DocumentStore.finishSaving()
        session.close()
        let reopened = try DocumentStore(opening: store.url)
        #expect(reopened.doc.nodes == store.doc.nodes)
        #expect(reopened.sharing?.link == session.link)
        reopened.sharing?.close()
    }

    // MARK: What cannot be read

    @Test func aFilmFromALaterBezzleIsKeptForItByAMacThatCannotReadIt() throws {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        b.receive(a.state)
        let one = try #require(node(a.doc, "One")).id
        let stamp = Stamp(time: a.time + 5, by: "later")
        // A property this Bezzle does not know, a setting of the film it does not know, and a
        // pace it has no name for, as a later Bezzle on a third Mac would share them.
        var later = a.state
        let wobble = try FieldValue(encoding: MotionTrack([MotionKey(t: 0, v: [1]), MotionKey(t: 1, v: [0])]))
        later.layers[one]?.fields["motion/wobble"] = Register(value: wobble, stamp: stamp)
        let board = try #require(node(a.doc, "Board")).id
        later.layers[board]?.fields["film/sound"] = Register(value: .string("waves.mp3"), stamp: stamp)
        later.layers[board]?.fields["film/length"] = Register(value: .number(7), stamp: stamp)
        b.receive(later)
        // What it can read, it shows; the rest it leaves alone and shares on untouched.
        #expect(node(b.doc, "One")?.motionProperties == [.move, .fade])
        #expect(node(b.doc, "One")?.motion?["wobble"]?.keys.count == 2)
        #expect(node(b.doc, "Board")?.film == Film(length: 7))
        b.edit { set(&$0, "One") { $0.pose(.turn, [30], at: 1) } }
        b.edit { set(&$0, "Board") { $0.film?.once = true } }
        #expect(b.state.layers[one]?.fields["motion/wobble"]?.value == wobble)
        #expect(b.state.layers[board]?.fields["film/sound"]?.value == .string("waves.mp3"))
        #expect(node(b.doc, "Board")?.film == Film(length: 7, once: true))

        // A key with a pace it cannot read: the layer opens with no motion here rather than the
        // design failing to open, and what is shared stays as the later Bezzle wrote it.
        var odd = b.state
        let elastic = try JSONDecoder().decode(FieldValue.self, from: Data(#"{"keys":[{"t":0,"v":[0]},{"t":1,"v":[1],"ease":{"kind":"elastic"}}]}"#.utf8))
        odd.layers[one]?.fields["motion/fade"] = Register(value: elastic, stamp: Stamp(time: b.time + 50, by: "later"))
        b.receive(odd)
        #expect(node(b.doc, "One") != nil)
        #expect(node(b.doc, "One")?.motion == nil)
        #expect(b.state.layers[one]?.fields["motion/fade"]?.value == elastic)
        #expect(b.state.layers[one]?.fields["motion/move"]?.value != .null)
        // Changing something else of that layer here writes nothing over the motion it could not read.
        b.edit { set(&$0, "One") { $0.name = "First" } }
        #expect(b.state.layers[one]?.fields["motion/fade"]?.value == elastic)
        #expect(b.state.layers[one]?.fields["motion/move"]?.value != .null)
    }

    // MARK: Whatever is done

    @Test(arguments: [11, 12, 13] as [UInt64])
    func whateverThreePeopleDoToAFilmTheyEndUpSeeingTheSame(seed: UInt64) {
        var dice = MotionDice(seed: seed)
        var macs = [Mac("a", doc: design()), Mac("b"), Mac("c")]
        sync(&macs)
        let names = ["One", "Two", "Three", "Group"]
        for round in 0..<40 {
            for i in macs.indices where dice.chance(0.7) {
                let name = dice.pick(names), p = dice.pick(MotionProperty.layer), t = dice.pick([0, 0.5, 1, 1.5, 2, 3] as [Double])
                let value = p.rest.map { $0 + dice.number(-0.5...0.5) }
                macs[i].time += Int64.random(in: 0..<5, using: &dice)
                switch Int.random(in: 0..<10, using: &dice) {
                case 0...3: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.pose(p, value, at: t) } } }
                case 4: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.removeKeys(at: t, of: [p]) } } }
                case 5: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.moveKeys(from: t, to: t + 0.25, of: MotionProperty.layer) } } }
                case 6: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.frame.origin.x += 7 } } }
                case 7: macs[i].edit { doc in if let id = node(doc, "Board")?.id { doc.update(id) { $0.setKey(dice.pick(MotionProperty.camera), [1.2, 3], at: t) } } }
                case 8:
                    macs[i].edit { doc in
                        guard let id = node(doc, "Board")?.id else { return }
                        doc.update(id) { board in
                            var film = board.film ?? Film()
                            switch Int.random(in: 0..<3, using: &dice) {
                            case 0: film.length = dice.chance(0.3) ? nil : t + 2
                            case 1: film.once = dice.chance(0.5) ? true : nil
                            default: film.backdrop = dice.chance(0.5) ? .black : nil
                            }
                            board.film = film == Film() ? nil : film
                        }
                    }
                default: macs[i].edit { doc in if let id = node(doc, name)?.id, name != "Group" { doc.clearMotion([id]) } }
                }
            }
            // Now and then two of them hear of each other; at the end of a round sometimes all do.
            if dice.chance(0.5) {
                let i = Int.random(in: 0..<3, using: &dice), j = (i + 1 + Int.random(in: 0..<2, using: &dice)) % 3
                macs[i].receive(macs[j].state)
            }
            if round % 10 == 9 {
                sync(&macs)
                #expect(macs[0].doc.nodes == macs[1].doc.nodes && macs[1].doc.nodes == macs[2].doc.nodes, "seed \(seed), round \(round)")
            }
        }
        sync(&macs)
        #expect(macs[0].doc.nodes == macs[1].doc.nodes && macs[1].doc.nodes == macs[2].doc.nodes, "seed \(seed)")
        // What they see is a film in order: every property's keys in time, none twice at a moment.
        for n in macs[0].doc.allNodes {
            for (name, track) in n.motion ?? [:] {
                #expect(!track.keys.isEmpty, "\(n.name) \(name)")
                #expect(zip(track.keys, track.keys.dropFirst()).allSatisfy { $0.t < $1.t && !MotionTiming.same($0.t, $1.t) }, "\(n.name) \(name)")
            }
            #expect(n.film != Film(), "\(n.name)")
        }
        // And it is what a design's file would hold: written and read, it is the same.
        let written = try? JSONEncoder().encode(macs[0].doc)
        #expect(written.flatMap { try? JSONDecoder().decode(BezzleDocument.self, from: $0) }?.nodes == macs[0].doc.nodes)
    }
}
