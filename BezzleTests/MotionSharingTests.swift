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

    /// The same, shown as the app shows it (`DocumentStore.showChangesFromOthers`): Shape keys
    /// this Mac had for an outline the others changed go with it.
    mutating func show(_ other: SharedDesign) {
        commit()
        let old = doc
        state.merge(other)
        base = state.flatDesign()
        var next = base.document()
        next.followOutlines(merging: old)
        doc = next
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

    /// A layer's move keyed at the start and at two seconds, for two people to key further.
    private func keyed() -> BezzleDocument {
        var doc = design()
        set(&doc, "One") { $0.setKey(.move, [10, 0], at: 0); $0.setKey(.move, [100, 0], at: 2) }
        return doc
    }

    private func key(_ doc: BezzleDocument, _ name: String, _ property: MotionProperty, at time: Double) -> MotionKey? {
        node(doc, name)?[track: property]?.keys.first { $0.t == time }
    }

    @Test func twoPeopleKeyingOnePropertyAtDifferentMomentsBothKeepTheirKeys() {
        // Each key is shared on its own, so it does not matter who saved later.
        for later in ["a", "b"] {
            var (a, b) = pair(keyed())
            if later == "a" { a.time += 10 } else { b.time += 10 }
            a.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
            b.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 3, ease: MotionEase(kind: .linear)) } }
            let both = settled(a, b)
            #expect(times(both, "One", .move) == [0, 1, 2, 3], "\(later) later")
            #expect(key(both, "One", .move, at: 1) == MotionKey(t: 1, v: [50, 80]))
            #expect(key(both, "One", .move, at: 3) == MotionKey(t: 3, v: [200, 0], ease: MotionEase(kind: .linear)))
        }

        // The camera's keys the same.
        var (c, d) = pair()
        c.edit { set(&$0, "Board") { $0.setKey(.cameraZoom, [2], at: 1) } }
        d.edit { set(&$0, "Board") { $0.setKey(.cameraZoom, [1.2], at: 2.5) } }
        #expect(times(settled(c, d), "Board", .cameraZoom) == [1, 2.5])

        // One sets how a key is come to, takes another away and moves a third, while the other
        // sets one more: each of these is kept.
        var doc = keyed()
        set(&doc, "One") { $0.setKey(.move, [10, 10], at: 0.5); $0.setKey(.move, [20, 20], at: 1.5) }
        var (e, f) = pair(doc)
        e.edit { set(&$0, "One") {
            $0.setEase(MotionEase(kind: .hold), at: 2, of: [.move])
            $0.removeKeys(at: 0.5, of: [.move])
            $0.moveKeys(from: 1.5, to: 1.7, of: [.move])
        } }
        f.time = e.time + 10
        f.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 3) } }
        let all = settled(e, f)
        #expect(times(all, "One", .move) == [0, 1.7, 2, 3])
        #expect(key(all, "One", .move, at: 2)?.ease == MotionEase(kind: .hold) && key(all, "One", .move, at: 1.7)?.v == [20, 20])
    }

    @Test func twoPeoplePosingALayerNobodyHadPosedBothKeepTheirPose() {
        // Posing a property for the first time, Bezzle gives it the design for company: for the
        // one who poses at the start, a key half a second on; for the one who poses later, a key
        // at the start. A key given is shared under a name of its own, so it never takes the
        // place of the key the other set at that moment, whoever saved later.
        for later in ["a", "b"] {
            var (a, b) = pair()
            if later == "a" { a.time += 10 } else { b.time += 10 }
            a.edit { set(&$0, "One") { $0.pose(.move, [0, 60], at: 0) } }
            b.edit { set(&$0, "One") { $0.pose(.move, [90, 0], at: 1) } }
            let both = settled(a, b)
            #expect(times(both, "One", .move) == [0, 0.5, 1], "\(later) later")
            #expect(key(both, "One", .move, at: 0) == MotionKey(t: 0, v: [0, 60]))
            #expect(key(both, "One", .move, at: 0.5) == MotionKey(t: 0.5, v: [0, 0], given: true))
            #expect(key(both, "One", .move, at: 1) == MotionKey(t: 1, v: [90, 0]))
        }

        // One poses at the start, the other half a second in, where the first one's company is:
        // again both poses stand, and the two keys given are gone.
        var (c, d) = pair()
        c.edit { set(&$0, "One") { $0.pose(.fade, [0], at: 0) } }
        d.time = c.time + 10
        d.edit { set(&$0, "One") { $0.pose(.fade, [0.5], at: 0.5) } }
        let met = settled(c, d)
        #expect(node(met, "One")?[track: .fade]?.keys == [MotionKey(t: 0, v: [0]), MotionKey(t: 0.5, v: [0.5])])

        // The key given, touched by one, is that one's: the other posing past it, which takes
        // the given key away there, does not take it away here.
        var doc = design()
        set(&doc, "One") { $0.pose(.turn, [30], at: 0) }
        var (e, f) = pair(doc)
        e.edit { set(&$0, "One") { $0.setKey(.turn, [10], at: 0.5) } }
        f.time = e.time + 10
        f.edit { set(&$0, "One") { $0.pose(.turn, [-20], at: 1) } }
        let touched = settled(e, f)
        #expect(node(touched, "One")?[track: .turn]?.keys == [MotionKey(t: 0, v: [30]), MotionKey(t: 0.5, v: [10]), MotionKey(t: 1, v: [-20])])
    }

    @Test func twoPeopleSettingOneKeyAtTheSameMomentLeaveTheOneSavedLater() {
        // One property at one moment is one value still: the later saver's, whole.
        var (a, b) = pair(keyed())
        a.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1, ease: MotionEase(kind: .linear)) } }
        // The second saves later, by this design's clock.
        b.time = a.time + 10
        b.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 1) } }
        let both = settled(a, b)
        #expect(times(both, "One", .move) == [0, 1, 2])
        #expect(key(both, "One", .move, at: 1) == MotionKey(t: 1, v: [200, 0]))

        // The other way round in time, the other's stands.
        var (c, d) = pair(keyed())
        d.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 1) } }
        c.time = d.time + 10
        c.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1, ease: MotionEase(kind: .linear)) } }
        #expect(key(settled(c, d), "One", .move, at: 1) == MotionKey(t: 1, v: [50, 80], ease: MotionEase(kind: .linear)))

        // A key that was there, given a pace by one and a value by the other: the later one's key,
        // never a mixture that neither saw.
        var (e, f) = pair(keyed())
        e.edit { set(&$0, "One") { $0.setEase(MotionEase(kind: .linear), at: 2, of: [.move]) } }
        f.time = e.time + 10
        f.edit { set(&$0, "One") { $0.setKey(.move, [120, 0], at: 2) } }
        #expect(key(settled(e, f), "One", .move, at: 2) == MotionKey(t: 2, v: [120, 0]))

        // A key is known by its moment. Moved by one while the other changes it: saved later,
        // the move stands, and the key is gone from where it was with what the other did to it.
        var (g, h) = pair(keyed())
        g.edit { set(&$0, "One") { $0.setEase(MotionEase(kind: .linear), at: 2, of: [.move]) } }
        h.time = g.time + 10
        h.edit { set(&$0, "One") { $0.moveKeys(from: 2, to: 2.5, of: [.move]) } }
        let moved = settled(g, h)
        #expect(times(moved, "One", .move) == [0, 2.5] && key(moved, "One", .move, at: 2.5)?.ease == nil)
        // Changed after it was moved, by someone who had not seen it go: it is back where it
        // was, as they made it, beside the one that was moved.
        var (i, j) = pair(keyed())
        j.edit { set(&$0, "One") { $0.moveKeys(from: 2, to: 2.5, of: [.move]) } }
        i.time = j.time + 10
        i.edit { set(&$0, "One") { $0.setEase(MotionEase(kind: .linear), at: 2, of: [.move]) } }
        let back = settled(i, j)
        #expect(times(back, "One", .move) == [0, 2, 2.5] && key(back, "One", .move, at: 2)?.ease == MotionEase(kind: .linear))

        // Taken away by one while the other changes it: the same, the later of the two stands.
        var (k, l) = pair(keyed())
        k.edit { set(&$0, "One") { $0.setKey(.move, [120, 0], at: 2) } }
        l.time = k.time + 10
        l.edit { set(&$0, "One") { $0.removeKeys(at: 2, of: [.move]) } }
        #expect(times(settled(k, l), "One", .move) == [0])
        var (m, n) = pair(keyed())
        n.edit { set(&$0, "One") { $0.removeKeys(at: 2, of: [.move]) } }
        m.time = n.time + 10
        m.edit { set(&$0, "One") { $0.setKey(.move, [120, 0], at: 2) } }
        #expect(key(settled(m, n), "One", .move, at: 2) == MotionKey(t: 2, v: [120, 0]))
    }

    @Test func twoKeysCloserThanTheTimelineTellsApartBecomeOneOnEveryMac() {
        // Three thousandths of a second apart, two keys are one moment to the timeline, which
        // would show one and take hold of the first. The later of the two in the film stands,
        // whoever saved later.
        for later in ["a", "b"] {
            var (a, b) = pair(keyed())
            if later == "a" { a.time += 10 } else { b.time += 10 }
            a.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
            b.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 1.003) } }
            var macs = [a, b]
            sync(&macs)
            #expect(macs[0].doc.nodes == macs[1].doc.nodes)
            #expect(times(macs[0].doc, "One", .move) == [0, 1.003, 2], "\(later) later")
            // Nothing of the one that gave way is left to come back: the key that stands taken
            // away, there is none at that moment, on either Mac.
            macs[0].edit { set(&$0, "One") { $0.removeKeys(at: 1.003, of: [.move]) } }
            sync(&macs)
            #expect(times(macs[0].doc, "One", .move) == [0, 2] && times(macs[1].doc, "One", .move) == [0, 2])
        }

        // Five thousandths apart they are two moments, and both stay.
        var (c, d) = pair(keyed())
        c.edit { set(&$0, "One") { $0.setKey(.move, [50, 80], at: 1) } }
        d.edit { set(&$0, "One") { $0.setKey(.move, [200, 0], at: 1.005) } }
        #expect(times(settled(c, d), "One", .move) == [0, 1, 1.005, 2])

        // A key somebody set stands rather than one Bezzle gave for company, earlier or later.
        for near in [0.497, 0.503] {
            var (e, f) = pair()
            e.edit { set(&$0, "One") { $0.pose(.move, [0, 60], at: 0) } }
            f.edit { set(&$0, "One") { $0.setKey(.move, [30, 0], at: near) } }
            let met = settled(e, f)
            #expect(node(met, "One")?[track: .move]?.keys == [MotionKey(t: 0, v: [0, 60]), MotionKey(t: near, v: [30, 0])], "\(near)")
        }

        // Three in a row, each within reach of the next, set on three Macs: all three see the
        // same keys, no two at one moment, and the last of them is among them.
        var macs = [Mac("a", doc: keyed()), Mac("b"), Mac("c")]
        sync(&macs)
        for (i, t) in [1, 1.003, 1.006].enumerated() { macs[i].edit { set(&$0, "One") { $0.setKey(.move, [Double(i), 0], at: t) } } }
        sync(&macs)
        #expect(macs[0].doc.nodes == macs[1].doc.nodes && macs[1].doc.nodes == macs[2].doc.nodes)
        let row = node(macs[0].doc, "One")?[track: .move] ?? MotionTrack()
        #expect(!row.isCrowded && row.keys.contains { $0.t == 1.006 })

        // The rule by itself: from the end, a key that was set before one that was given.
        var crowded = MotionTrack([MotionKey(t: 1, v: [1]), MotionKey(t: 1.002, v: [2]), MotionKey(t: 1.004, v: [3], given: true), MotionKey(t: 2, v: [4])])
        let went = crowded.settle()
        #expect(went && crowded.keys.map(\.t) == [1.002, 2])
        var apart = MotionTrack([MotionKey(t: 1, v: [1]), MotionKey(t: 1.005, v: [2])])
        let none = apart.settle()
        #expect(!none && apart.keys.count == 2)
        // Keys of a property this Bezzle does not know are a later one's to put in order.
        var later = design()
        set(&later, "One") { $0.motion = ["wobble": MotionTrack([MotionKey(t: 1, v: [1]), MotionKey(t: 1.002, v: [2])]), "turn": MotionTrack([MotionKey(t: 1, v: [1]), MotionKey(t: 1.002, v: [2])])] }
        later.repairMotion()
        #expect(node(later, "One")?.motion?["wobble"]?.keys.count == 2 && times(later, "One", .turn) == [1.002])
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

        // A key of the same property moved meanwhile, by either: the keys that were taken away
        // are gone, and the one that was moved is where it was moved to.
        for later in ["c", "d"] {
            var (c, d) = pair(doc)
            if later == "c" { c.time += 10 } else { d.time += 10 }
            c.edit { doc in doc.clearMotion([node(doc, "One")!.id]) }
            d.edit { set(&$0, "One") { $0.moveKeys(from: 0.8, to: 1.6, of: [.move]) } }
            let kept = settled(c, d)
            #expect(node(kept, "One")?.motionProperties == [.move] && times(kept, "One", .move) == [1.6], "\(later) later")
        }
        // A key of it changed meanwhile, by the one who saved later: that key is back as they made it.
        var (g, h) = pair(doc)
        g.edit { doc in doc.clearMotion([node(doc, "One")!.id]) }
        h.time = g.time + 10
        h.edit { set(&$0, "One") { $0.setKey(.fade, [0.4], at: 0) } }
        let changed = settled(g, h)
        #expect(node(changed, "One")?.motionProperties == [.fade] && node(changed, "One")?[track: .fade]?.keys == [MotionKey(t: 0, v: [0.4])])

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

        // A key undone while someone else keyed another property of the layer.
        var keyed = before
        set(&keyed, "One") { $0.pose(.move, [0, 60], at: 0) }
        var other = keyed
        set(&other, "One") { $0.pose(.fade, [0], at: 0) }
        #expect(node(FlatDesign.apply(from: keyed, to: before, onto: other), "One")?.motionProperties == [.fade])
    }

    @Test func undoingAKeyLeavesTheKeysSomeoneElseSetOfTheSameProperty() {
        // Undo takes back the keys set on this Mac, each on its own: a key someone else set
        // since, of the same property at another moment, stays.
        let before = keyed()
        var mine = before
        set(&mine, "One") { $0.setKey(.move, [50, 80], at: 1) }
        var now = mine
        set(&now, "One") { $0.setKey(.move, [200, 0], at: 3) }
        let undone = FlatDesign.apply(from: mine, to: before, onto: now)
        #expect(times(undone, "One", .move) == [0, 2, 3] && key(undone, "One", .move, at: 3)?.v == [200, 0])
        // Done again, mine is back beside theirs.
        let redone = FlatDesign.apply(from: before, to: mine, onto: undone)
        #expect(times(redone, "One", .move) == [0, 1, 2, 3] && key(redone, "One", .move, at: 1)?.v == [50, 80])

        // The key I set, changed by someone since: it is theirs now, and stays as they made it.
        var theirs = mine
        set(&theirs, "One") { $0.setKey(.move, [70, 70], at: 1) }
        #expect(key(FlatDesign.apply(from: mine, to: before, onto: theirs), "One", .move, at: 1)?.v == [70, 70])

        // A key I took away, undone, while someone set another: mine is back, theirs stays.
        var less = before
        set(&less, "One") { $0.removeKeys(at: 2, of: [.move]) }
        var more = less
        set(&more, "One") { $0.setKey(.move, [200, 0], at: 3) }
        #expect(times(FlatDesign.apply(from: before, to: less, onto: now), "One", .move) == [0, 1, 3])
        #expect(times(FlatDesign.apply(from: less, to: before, onto: more), "One", .move) == [0, 2, 3])

        // A key I moved, undone: it is back where it was, and the one they set stays.
        var shifted = before
        set(&shifted, "One") { $0.moveKeys(from: 2, to: 2.5, of: [.move]) }
        var since = shifted
        set(&since, "One") { $0.setKey(.move, [200, 0], at: 3) }
        #expect(times(FlatDesign.apply(from: shifted, to: before, onto: since), "One", .move) == [0, 2, 3])

        // The first pose of a property, undone after someone else set a key of it: my pose and
        // the key Bezzle gave with it go, theirs stays, alone.
        let plain = design()
        var posed = plain
        set(&posed, "One") { $0.pose(.move, [0, 60], at: 0) }
        var joined = posed
        set(&joined, "One") { $0.setKey(.move, [80, 0], at: 2) }
        let alone = FlatDesign.apply(from: posed, to: plain, onto: joined)
        #expect(node(alone, "One")?[track: .move]?.keys == [MotionKey(t: 2, v: [80, 0])])
        // With nothing of it changed since, undoing the pose leaves no track at all.
        #expect(node(FlatDesign.apply(from: posed, to: plain, onto: posed), "One")?.motion == nil)
        var elsewhere = posed
        set(&elsewhere, "Two") { $0.name = "Second" }
        #expect(node(FlatDesign.apply(from: posed, to: plain, onto: elsewhere), "One")?.motion == nil)

        // My key brought back by undo right beside one set since, closer than the timeline tells
        // apart: one moment has one key, by the same rule as when changes are put together.
        var near = less
        set(&near, "One") { $0.setKey(.move, [200, 0], at: 2.003) }
        #expect(times(FlatDesign.apply(from: less, to: before, onto: near), "One", .move) == [0, 2.003])
    }

    // MARK: Shape keys and an outline changed meanwhile

    /// The board with a triangle whose tip goes 30 down at one second.
    private func keyedTriangle() -> BezzleDocument {
        var doc = design()
        var tri = Node.path(BezierPath("M 0 0 L 100 0 L 50 80 Z"), name: "Tri")
        tri.frame.origin = CGPoint(x: 500, y: 200)
        var outline = tri.ownOutline!
        outline.subpaths[0].anchors[2].point.y += 30
        tri.poseShape(outline, at: 1)
        doc.nodes[0].children.append(tri)
        return doc
    }

    /// How far the triangle's tip has gone from the design's at a moment.
    private func tip(_ doc: BezzleDocument, at t: Double) -> CGPoint? {
        guard let n = node(doc, "Tri"), let design = n.ownOutline, let now = n.outline(at: t) else { return nil }
        return CGPoint(x: now.anchorPoints[2].x - design.anchorPoints[2].x, y: now.anchorPoints[2].y - design.anchorPoints[2].y)
    }

    private func near(_ p: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool {
        guard let p else { return false }
        return abs(p.x - x) < 1e-6 && abs(p.y - y) < 1e-6
    }

    /// The triangle made twice as high on a Mac, its keys going with it as an edit in the app has them.
    private func resized(_ mac: inout Mac) {
        mac.edit { doc in
            let was = doc
            set(&doc, "Tri") { $0.frame.size.height = 160 }
            doc.followOutlines(since: was)
        }
    }

    /// The triangle's tip keyed to go `by` from the design's at a moment, on a Mac, for the triangle as it has it.
    private func keyed(_ mac: inout Mac, _ by: CGPoint, at t: Double) {
        mac.edit { doc in
            set(&doc, "Tri") { n in
                var o = n.ownOutline!
                o.subpaths[0].anchors[2].point = o.subpaths[0].anchors[2].point + by
                n.poseShape(o, at: t)
            }
        }
    }

    @Test(arguments: [false, true])
    func aShapeKeyOneSetsForTheOldSizeGrowsWithTheResizeTheOtherMadeMeanwhile(resizerFirst: Bool) {
        var (a, b) = pair(keyedTriangle())
        resized(&a)
        keyed(&b, CGPoint(x: 0, y: 20), at: 2)
        // They meet, each showing what came as the app shows it, in either order.
        var macs = resizerFirst ? [a, b] : [b, a]
        for _ in 0..<3 {
            macs[1].show(macs[0].state)
            macs[0].show(macs[1].state)
        }
        #expect(macs[0].doc.nodes == macs[1].doc.nodes)
        let doc = macs[0].doc
        #expect(node(doc, "Tri")?.frame.height == 160)
        // Both keys are for the triangle as tall as it is now: the tip goes twice as far down.
        #expect(near(tip(doc, at: 1), 0, 60), "\(String(describing: tip(doc, at: 1)))")
        #expect(near(tip(doc, at: 2), 0, 40), "\(String(describing: tip(doc, at: 2)))")
        #expect(times(doc, "Tri", .shape) == [0, 1, 2])
    }

    @Test func aShapeKeyOneChangesForTheOldSizeAfterTheOtherResizedIsKeptAndGrows() {
        var (a, b) = pair(keyedTriangle())
        resized(&a)
        // Later still, the other moves the key at one second's tip 10 right, for the triangle it has.
        b.time = a.time + 10
        keyed(&b, CGPoint(x: 10, y: 30), at: 1)
        var macs = [a, b]
        for _ in 0..<3 {
            macs[0].show(macs[1].state)
            macs[1].show(macs[0].state)
        }
        #expect(macs[0].doc.nodes == macs[1].doc.nodes)
        // That change is the later one, and is kept, grown with the triangle.
        #expect(near(tip(macs[0].doc, at: 1), 10, 60), "\(String(describing: tip(macs[0].doc, at: 1)))")
    }

    @Test func keysNobodyKeyedMeanwhileAreAsTheResizeLeftThem() {
        var (a, b) = pair(keyedTriangle())
        resized(&a)
        // The other changes something else of it meanwhile.
        b.edit { set(&$0, "Tri") { $0.fill.color = .black } }
        var macs = [a, b]
        for _ in 0..<3 {
            macs[0].show(macs[1].state)
            macs[1].show(macs[0].state)
        }
        #expect(macs[0].doc.nodes == macs[1].doc.nodes)
        #expect(near(tip(macs[0].doc, at: 1), 0, 60) && node(macs[0].doc, "Tri")?.fill.color == .black)
        // And a design without Shape keys is shown as it is put together.
        var plain = keyedTriangle()
        plain.update(node(plain, "Tri")!.id) { $0.motion = nil }
        var moved = plain
        moved.update(node(plain, "Tri")!.id) { $0.frame.size.height = 160 }
        var shown = moved
        shown.followOutlines(merging: plain)
        #expect(shown == moved)
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
        // There, meanwhile: another property of the same layer and one more key of its move, the
        // film's backdrop, the camera.
        other.time = Collaboration.now + 10
        other.edit { doc in
            set(&doc, "R") { $0.pose(.turn, [45], at: 1); $0.setKey(.move, [5, 5], at: 3) }
            set(&doc, "A") { $0.film?.backdrop = .black; $0.setKey(.cameraZoom, [2], at: 1) }
        }
        session.receive([other.state], from: .cloud)
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        #expect(bench.node("R")?[track: .move]?.keys.map(\.t) == [0, 0.8, 3])
        #expect(bench.a.film == Film(length: 5, backdrop: .black) && bench.a.hasCamera)

        // Undo here takes back the film's length alone, then the keys set here alone: the key
        // of the same property set there stays.
        bench.undo.undo()
        #expect(bench.a.film == Film(backdrop: .black) && bench.a.hasCamera)
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        bench.undo.undo()
        #expect(bench.node("R")?.motionProperties == [.move, .turn])
        #expect(bench.node("R")?[track: .move]?.keys == [MotionKey(t: 3, v: [5, 5])])
        store.save()
        other.receive(session.state)
        #expect(other.doc.nodes == store.doc.nodes)
        bench.undo.redo()
        bench.undo.redo()
        #expect(bench.node("R")?.motionProperties == [.move, .turn, .fade])
        #expect(bench.node("R")?[track: .move]?.keys.map(\.t) == [0, 0.8, 3])
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

    @Test func inTheAppAShapeKeySetHereForTheOldSizeGrowsWithAResizeFromElsewhereAndUndoesAlone() throws {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        let r = bench.node("R")!.id
        let corner = try #require(bench.node("R")?.ownOutline?.anchorPoints.firstIndex { abs($0.x - 50) < 0.01 && abs($0.y - 50) < 0.01 })
        // How far R's bottom right corner goes down at a moment.
        func down(_ n: Node?, at t: Double) -> Double? {
            guard let n, let design = n.ownOutline?.anchorPoints, let now = n.outline(at: t)?.anchorPoints else { return nil }
            return Double(now[corner].y - design[corner].y)
        }
        func keyed(_ by: Double, at t: Double) -> (inout Node) -> Void {
            { n in
                var v = n.shapeRest
                for i in [1, 3, 5] { v[corner * 6 + i] = by }
                n.setKey(.shape, v, at: t)
            }
        }
        // Here: its corner goes 10 down at one second.
        bench.step { store.edit("Pose") { $0.update(r, keyed(10, at: 1)) } }
        store.save()
        other.receive(session.state)
        // There: R made twice as high, its keys with it.
        other.time = Collaboration.now + 10
        other.edit { doc in
            let was = doc
            set(&doc, "R") { $0.frame.size.height = 100 }
            doc.followOutlines(since: was)
        }
        // Here, meanwhile: its corner keyed 20 down at two seconds, for R as it is here.
        bench.step { store.edit("Pose") { $0.update(r, keyed(20, at: 2)) } }
        session.receive([other.state], from: .cloud)
        // Both keys are for R as tall as it is now.
        #expect(bench.node("R")?.frame.height == 100)
        #expect(down(bench.node("R"), at: 1) == 20 && down(bench.node("R"), at: 2) == 40)
        // Saved, the other Mac has it so too.
        store.save()
        other.receive(session.state)
        #expect(other.doc.nodes == store.doc.nodes)
        #expect(down(node(other.doc, "R"), at: 2) == 40)
        // Undone here, the key set here goes, as it has grown; the resize made there, and the
        // key it grew, stay.
        bench.undo.undo()
        #expect(bench.node("R")?[track: .shape]?.keys.map(\.t) == [1])
        #expect(bench.node("R")?.frame.height == 100 && down(bench.node("R"), at: 1) == 20)
        bench.undo.redo()
        #expect(bench.node("R")?[track: .shape]?.keys.map(\.t) == [1, 2] && down(bench.node("R"), at: 2) == 40)
    }

    @Test func aShapeKeySavedHereForTheOldSizeGrowsWithAResizeMadeWhileTheDesignWasClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDrive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        defer {
            SyncedFolders.forTests[folder.path] = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("Film.bezzle")
        let doc = keyedTriangle()
        let tri = try #require(node(doc, "Tri")).id
        try DesignFile.write(doc, to: url)
        // Someone else has it open, as it is.
        let ben = try #require(Collaboration.open(url, replica: "ben", claiming: false))
        _ = ben.document()
        // Here: opened, the tip keyed 20 down at two seconds, saved and closed.
        let store = try DocumentStore(opening: url)
        store.edit("Pose") { doc in
            doc.update(tri) { n in
                var o = n.ownOutline!
                o.subpaths[0].anchors[2].point.y += 20
                n.poseShape(o, at: 2)
            }
        }
        store.save()
        store.sharing?.persist()
        DocumentStore.finishSaving()
        store.sharing?.close()
        // There, meanwhile, without having seen it: twice as high, its keys with it.
        var there = ben.state.flatDesign().document()
        #expect(times(there, "Tri", .shape) == [0, 1])
        let was = there
        there.update(tri) { $0.frame.size.height = 160 }
        there.followOutlines(since: was)
        ben.takeIn(there)
        ben.persist()
        DocumentStore.finishSaving()
        ben.close()
        // Opened here again: both keys are for the triangle as tall as it is now.
        let reopened = try DocumentStore(opening: url)
        defer { reopened.sharing?.close() }
        #expect(node(reopened.doc, "Tri")?.frame.height == 160)
        #expect(near(tip(reopened.doc, at: 1), 0, 60) && near(tip(reopened.doc, at: 2), 0, 40), "\(String(describing: tip(reopened.doc, at: 2)))")
    }

    // MARK: What cannot be read

    @Test func aFilmFromALaterBezzleIsKeptForItByAMacThatCannotReadIt() throws {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        b.receive(a.state)
        let one = try #require(node(a.doc, "One")).id
        let stamp = Stamp(time: a.time + 5, by: "later")
        func said(_ json: String) throws -> FieldValue { try JSONDecoder().decode(FieldValue.self, from: Data(json.utf8)) }
        // A property this Bezzle does not know, with something in a key it does not know either;
        // a setting of the film it does not know; as a later Bezzle on a third Mac would share them.
        var later = a.state
        let wobbles = ["motion/wobble/0": try said(#"{"v":[1]}"#), "motion/wobble/1500": try said(#"{"v":[0],"ease":{"kind":"spring","bounce":0.2},"curl":3}"#)]
        for (name, value) in wobbles { later.layers[one]?.fields[name] = Register(value: value, stamp: stamp) }
        let board = try #require(node(a.doc, "Board")).id
        later.layers[board]?.fields["film/sound"] = Register(value: .string("waves.mp3"), stamp: stamp)
        later.layers[board]?.fields["film/length"] = Register(value: .number(7), stamp: stamp)
        b.receive(later)
        // What it can read, it shows; the rest it leaves alone and shares on untouched. The
        // property it does not know is in the design it shows, and so in the file it writes.
        #expect(node(b.doc, "One")?.motionProperties == [.move, .fade])
        #expect(node(b.doc, "One")?.motion?["wobble"]?.keys == [MotionKey(t: 0, v: [1]), MotionKey(t: 1.5, v: [0], ease: .spring(0.2))])
        #expect(node(b.doc, "Board")?.film == Film(length: 7))
        b.edit { set(&$0, "One") { $0.pose(.turn, [30], at: 1) } }
        b.edit { set(&$0, "Board") { $0.film?.once = true } }
        for (name, value) in wobbles { #expect(b.state.layers[one]?.fields[name] == Register(value: value, stamp: stamp), "\(name)") }
        #expect(b.state.layers[board]?.fields["film/sound"]?.value == .string("waves.mp3"))
        #expect(node(b.doc, "Board")?.film == Film(length: 7, once: true))
        #expect(node(b.doc, "One")?.motion?["wobble"]?.keys.count == 2)

        // A key with a pace it cannot read: the keys of that property are not shown here, the
        // layer's other motion is, and what is shared stays as the later Bezzle wrote it.
        var odd = b.state
        let elastic = try said(#"{"v":[0.5],"ease":{"kind":"elastic"}}"#)
        odd.layers[one]?.fields["motion/fade/2000"] = Register(value: elastic, stamp: Stamp(time: b.time + 50, by: "later"))
        b.receive(odd)
        #expect(node(b.doc, "One")?.motionProperties == [.move, .turn])
        #expect(node(b.doc, "One")?[track: .move] == Filmed.moves?["move"])
        #expect(node(b.doc, "One")?.motion?["wobble"]?.keys.count == 2)
        #expect(b.state.layers[one]?.fields["motion/fade/2000"]?.value == elastic)
        #expect(b.state.layers[one]?.fields["motion/fade/600"]?.value == MotionKey(t: 0.6, v: [1], ease: MotionEase(kind: .easeOut)).entry)
        // Changing something else of that layer here, or keying it, writes nothing over the keys it could not show.
        b.edit { set(&$0, "One") { $0.name = "First"; $0.setKey(.turn, [60], at: 2) } }
        #expect(b.state.layers[one]?.fields["motion/fade/2000"]?.value == elastic)
        #expect(b.state.layers[one]?.fields["motion/fade/0"]?.value == MotionKey(t: 0, v: [0]).entry)
        #expect(b.state.layers[one]?.fields["motion/fade/600"]?.value == MotionKey(t: 0.6, v: [1], ease: MotionEase(kind: .easeOut)).entry)
        // Once the later Bezzle gives that key a pace this one knows, the property is back whole.
        var mended = b.state
        mended.layers[one]?.fields["motion/fade/2000"] = Register(value: try said(#"{"v":[0.5],"ease":{"kind":"linear"}}"#), stamp: Stamp(time: b.time + 90, by: "later"))
        b.receive(mended)
        #expect(times(b.doc, "First", .fade) == [0, 0.6, 2])
    }

    @Test func entriesThisBezzleCannotPlaceAreLeftAloneAndSharedOn() throws {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0 = Filmed.moving($0) } }
        b.receive(a.state)
        let one = try #require(node(a.doc, "One")).id
        let stamp = Stamp(time: a.time + 5, by: "other")
        let whole = try FieldValue(encoding: MotionTrack([MotionKey(t: 0, v: [10]), MotionKey(t: 1, v: [90])]))
        let key = MotionKey(t: 0, v: [45]).entry
        // A whole property's keys under its name, as a build of Bezzle shared them before each
        // key was shared on its own; names that say more after the moment than this Bezzle
        // knows, or no moment it can read; and a property nobody here has heard of, with two
        // slashes in its name, as a key's entry looks to a Bezzle from before Animate.
        let strange: [String: FieldValue] = [
            "motion/turn": whole, "motion/turn/1000/soft": key, "motion/turn/half": key, "motion/turn/-5": key, "motion/turn/007": key,
            "motion/turn/1.5": key, "motion//5": key, "motion/turn/5/given/given": key, "motion/turn/250": .number(3),
            "sound/track/1500": key, "sound/track/1500/given": key,
        ]
        var other = a.state
        for (name, value) in strange { other.layers[one]?.fields[name] = Register(value: value, stamp: stamp) }
        b.receive(other)
        // None of it shows, nothing traps, and the layer moves as it did.
        #expect(node(b.doc, "One")?.motion == Filmed.moves)
        // Through changes made here, to the layer and to its keys, all of it stays as it came.
        b.edit { set(&$0, "One") { $0.name = "First"; $0.setKey(.turn, [20], at: 1); $0.removeKeys(at: 0.6, of: [.fade]) } }
        b.edit { doc in doc.clearMotion([one]) }
        for (name, value) in strange { #expect(b.state.layers[one]?.fields[name] == Register(value: value, stamp: stamp), "\(name)") }
        // Kept on disk as a shared design is, and taken in by a third Mac from this one, it is
        // all there still: whoever can read it will find it.
        let kept = try JSONDecoder().decode(SharedDesign.self, from: JSONEncoder().encode(b.state))
        var c = Mac("c")
        c.receive(kept)
        for (name, value) in strange { #expect(c.state.layers[one]?.fields[name] == Register(value: value, stamp: stamp), "\(name)") }
        #expect(c.doc.nodes == b.doc.nodes)
        // And what the Mac that wrote it sends is what it wrote.
        #expect(Set(kept.changes(by: "other", after: 0).layers[one]?.fields.keys.map { $0 } ?? []) == Set(strange.keys))
    }

    @Test func everyPartOfAKeyIsSharedInItsEntryOrItsName() throws {
        // A key is shared as what its entry holds and what the entry's name says. Whatever a key
        // is given to hold later must go into one of the two, or it would not reach the others.
        let key = MotionKey(t: 1.5, v: [1, 2], ease: .spring(0.4), given: true)
        guard case .object(let written) = try FieldValue(encoding: key), case .object(let entry) = key.entry else {
            Issue.record("A key is written as an object")
            return
        }
        #expect(Set(written.keys) == ["t", "v", "ease", "given"])
        #expect(Set(entry.keys) == ["v", "ease"] && entry["v"] == written["v"] && entry["ease"] == written["ease"])
        let place = MotionKeyPlace("move", key)
        #expect(place.name == "move/1500/given" && MotionKeyPlace(place.name) == place && place.time == 1.5)
        #expect(MotionKeyPlace("move", MotionKey(t: 0.0164, v: [0])).name == "move/16")
        // Only names written just so are places.
        for odd in ["move", "move/", "/5", "move/05", "move/-5", "move/+5", "move/1.5", "move/5/later", "move/given", "move/5/given/given", ""] {
            #expect(MotionKeyPlace(odd) == nil, "\(odd)")
        }
        // A time no file could hold makes a name all the same, and no trap.
        var far = MotionKey(t: 0, v: [0])
        for t in [Double.infinity, -.infinity, .nan, 1e300, -3] {
            far.t = t
            #expect(MotionKeyPlace(MotionKeyPlace("move", far).name) != nil, "\(t)")
        }

        // And all of it arrives: every property, every pace, a key that was given.
        var (a, b) = pair()
        a.edit { doc in
            set(&doc, "Three") { $0 = Filmed.everything("Three").with(id: $0.id).with { $0.frame = CGRect(x: 0, y: 0, width: 100, height: 100) } }
            set(&doc, "One") { $0.pose(.move, [0, 60], at: 0) }
        }
        b.receive(a.state)
        #expect(node(b.doc, "Three")?.motion == node(a.doc, "Three")?.motion && node(b.doc, "One")?.motion == node(a.doc, "One")?.motion)
        let names = Set(b.state.layers[node(a.doc, "One")!.id]?.fields.keys.filter { $0.hasPrefix("motion") } ?? [])
        #expect(names == ["motion/move/0", "motion/move/500/given"])
    }

    // MARK: Whatever is done

    @Test(arguments: [11, 12, 13, 14, 15, 16, 17, 18] as [UInt64])
    func whateverThreePeopleDoToAFilmTheyEndUpSeeingTheSame(seed: UInt64) {
        var dice = MotionDice(seed: seed)
        var macs = [Mac("a", doc: design()), Mac("b"), Mac("c")]
        sync(&macs)
        let names = ["One", "Two", "Three", "Group"]
        for round in 0..<40 {
            for i in macs.indices where dice.chance(0.7) {
                // Few layers, few properties and few moments, some of them a few thousandths of
                // a second from another, so that people meet at one key and beside one often.
                let name = dice.pick(names), p = dice.pick([.move, .move, .fade, .turn, .scale] as [MotionProperty])
                let t = dice.pick([0, 0.5, 1, 1.5, 2, 3] as [Double]) + dice.pick([0, 0, 0, 0.002, 0.003, 0.006] as [Double])
                let value = p.rest.map { $0 + dice.number(-0.5...0.5) }
                macs[i].time += Int64.random(in: 0..<5, using: &dice)
                switch Int.random(in: 0..<12, using: &dice) {
                case 0...2: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.pose(p, value, at: t) } } }
                case 3, 10, 11: macs[i].edit { doc in if let id = node(doc, name)?.id { doc.update(id) { $0.setKey(p, value, at: t, ease: dice.chance(0.3) ? .linear : nil) } } }
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
        // What is shared has come to rest as well, the same on all three: nobody has anything
        // left to put in order that the others have not seen.
        #expect(macs[0].state.layers == macs[1].state.layers && macs[1].state.layers == macs[2].state.layers, "seed \(seed)")
        // And what is shared says what they see, with nothing more in it: read by a Mac that
        // opens the design now, it is this design, and that Mac finds nothing to put in order.
        var fresh = Mac("d")
        fresh.receive(macs[0].state)
        #expect(fresh.doc.nodes == macs[0].doc.nodes && fresh.state.layers == macs[0].state.layers, "seed \(seed)")
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
