import Testing
import AppKit
@testable import Bezzle

/// One Mac's copy of a shared design, kept as `Collaboration` keeps it but without iCloud: what
/// it shows, and the shared design it sends and takes in.
private struct Mac {
    let name: String
    var state = SharedDesign()
    var base = FlatDesign()
    var doc = BezzleDocument()
    var time: Int64 = 1_000
    /// Takes in only the artboards that changed, as `Collaboration` does while it knows the
    /// design `base` was made from, rather than the whole design.
    var incremental = false
    var baseDoc: BezzleDocument?

    init(_ name: String, doc: BezzleDocument = BezzleDocument(), incremental: Bool = false) {
        self.name = name
        self.doc = doc
        self.incremental = incremental
        commit()
    }

    /// Takes in what was changed here, as saving does.
    mutating func commit() {
        time += 1
        if incremental, let before = baseDoc {
            let (old, new) = FlatDesign.changes(from: before, to: doc)
            state.absorb(new, since: old, by: name, at: time)
            base.replace(old, with: new)
        } else {
            state.absorb(FlatDesign(doc), since: base, by: name, at: time)
            base = FlatDesign(doc)
        }
        baseDoc = doc
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
        baseDoc = nil
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

private func names(_ nodes: [Node]) -> [String] { nodes.map(\.name) }

/// The same numbers every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct SharingTests {
    /// An artboard holding One, Two and Three, bottom first.
    private func design() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        board.children = [
            CanvasTests.rect("One", CGRect(x: 10, y: 10, width: 100, height: 100)),
            CanvasTests.rect("Two", CGRect(x: 200, y: 10, width: 100, height: 100)),
            CanvasTests.rect("Three", CGRect(x: 400, y: 10, width: 100, height: 100)),
        ]
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    /// Two Macs with the same design, the second having fetched it from the first.
    private func pair(_ doc: BezzleDocument? = nil) -> (Mac, Mac) {
        let a = Mac("a", doc: doc ?? design())
        var b = Mac("b")
        b.receive(a.state)
        return (a, b)
    }

    // MARK: The pieces

    @Test func everyPropertyOfALayerIsSharedOnItsOwn() {
        let labels = Set(Mirror(reflecting: Node(kind: .rectangle, frame: .zero)).children.compactMap(\.label))
        #expect(labels.subtracting(["id", "children"]) == Set(LayerField.all.map(\.name)))
    }

    @Test func orderKeysAlwaysFitBetween() {
        var top = [OrderKey.between(nil, nil)]
        for _ in 0..<1000 { top.append(OrderKey.between(top.last, nil)) }
        #expect(zip(top, top.dropFirst()).allSatisfy { OrderKey.less($0, $1) })
        #expect(top.map(\.count).max()! <= 4)

        var bottom = [OrderKey.between(nil, nil)]
        for _ in 0..<1000 { bottom.insert(OrderKey.between(nil, bottom.first), at: 0) }
        #expect(zip(bottom, bottom.dropFirst()).allSatisfy { OrderKey.less($0, $1) })

        var random = Seeded(state: 7)
        var list = [OrderKey.between(nil, nil)]
        var inOrder = true
        for _ in 0..<2000 {
            let i = Int.random(in: 0...list.count, using: &random)
            let below = i > 0 ? list[i - 1] : nil, above = i < list.count ? list[i] : nil
            let k = OrderKey.between(below, above)
            if let below, !OrderKey.less(below, k) { inOrder = false }
            if let above, !OrderKey.less(k, above) { inOrder = false }
            list.insert(k, at: i)
        }
        #expect(inOrder)

        // A bad key never stops anything.
        for (a, b) in [("", "a0"), ("a0", "a0"), ("b1", "a0"), ("a0!", nil), (nil, "~")] as [(String?, String?)] {
            #expect(!OrderKey.between(a, b).isEmpty)
        }
    }

    @Test func aDesignComesOutOfItsSharedCopyAsItWent() {
        var doc = design()
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 200, width: 10, height: 10))
        group.children = [CanvasTests.rect("In", CGRect(x: 0, y: 0, width: 50, height: 50)),
                          CanvasTests.rect("Also", CGRect(x: 60, y: 20, width: 40, height: 40))]
        var masked = Node(kind: .group, name: "Masked", frame: CGRect(x: 300, y: 300, width: 10, height: 10))
        masked.children = [CanvasTests.rect("Under", CGRect(x: 0, y: 0, width: 100, height: 100))]
        masked.mask = [Node(kind: .ellipse, name: "Mask", frame: CGRect(x: 10, y: 10, width: 60, height: 60))]
        var text = Node(kind: .text, name: "Words", frame: CGRect(x: 5, y: 500, width: 100, height: 30))
        text.text = "Hello"
        var path = Node(kind: .path, name: "Squiggle", frame: CGRect(x: 600, y: 400, width: 50, height: 50))
        path.path = "M0 0 L10 10 L20 0 Z"
        path.pathBox = CGRect(x: 0, y: 0, width: 20, height: 10)
        path.blend = .multiply
        path.blur = Blur(radius: 4)
        doc.nodes[0].children += [group, masked, text, path]
        doc.nodes.append(CanvasTests.rect("Loose", CGRect(x: 900, y: 0, width: 20, height: 20)))
        doc.fitGroups()

        var state = SharedDesign()
        state.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1)
        #expect(state.flatDesign().document().nodes == doc.nodes)

        // And through the JSON it is kept and sent as.
        let again = try! JSONDecoder().decode(SharedDesign.self, from: JSONEncoder().encode(state))
        #expect(again == state)
        #expect(again.flatDesign().document().nodes == doc.nodes)
    }

    // MARK: Two at once

    @Test func twoPeopleChangingDifferentLayersBothKeepTheirChange() {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0.fill.color = .black } }
        b.edit { set(&$0, "Two") { $0.frame.origin.x = 300 } }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(node(macs[0].doc, "One")?.fill.color == .black)
        #expect(node(macs[0].doc, "Two")?.frame.minX == 300)
    }

    @Test func twoPeopleChangingDifferentPropertiesOfOneLayerBothKeepTheirChange() {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0.fill.color = .black } }
        b.edit { set(&$0, "One") { $0.frame.origin.y = 250; $0.opacity = 0.5 } }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        let one = node(macs[0].doc, "One")
        #expect(one?.fill.color == .black)
        #expect(one?.frame.minY == 250)
        #expect(one?.opacity == 0.5)
    }

    @Test func ofTwoChangesToTheSamePropertyTheLaterOneIsKeptEverywhere() {
        var (a, b) = pair()
        a.edit { set(&$0, "One") { $0.fill.color = .black } }
        b.time = a.time + 100
        b.edit { set(&$0, "One") { $0.fill.color = .white } }
        // Whichever comes in first.
        var macs = [b, a]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(node(macs[0].doc, "One")?.fill.color == .white)
    }

    @Test func layersAddedAtOnceAreAllThereInTheSameOrder() {
        var (a, b) = pair()
        a.edit { $0.nodes[0].children.append(CanvasTests.rect("From A", CGRect(x: 0, y: 300, width: 10, height: 10))) }
        b.edit { $0.nodes[0].children.append(CanvasTests.rect("From B", CGRect(x: 50, y: 300, width: 10, height: 10))) }
        b.edit { $0.nodes[0].children.insert(CanvasTests.rect("Bottom B", CGRect(x: 90, y: 300, width: 10, height: 10)), at: 0) }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        let list = names(macs[0].doc.nodes[0].children)
        #expect(Set(list) == ["Bottom B", "One", "Two", "Three", "From A", "From B"])
        #expect(list.first == "Bottom B")
        #expect(Array(list[1...3]) == ["One", "Two", "Three"])
    }

    @Test func layersReorderedAtOnceEachKeepTheirMove() {
        var (a, b) = pair()
        // A brings One to the front while B sends Three to the back.
        a.edit { doc in
            let one = doc.nodes[0].children.removeFirst()
            doc.nodes[0].children.append(one)
        }
        b.edit { doc in
            let three = doc.nodes[0].children.removeLast()
            doc.nodes[0].children.insert(three, at: 0)
        }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(names(macs[0].doc.nodes[0].children) == ["Three", "Two", "One"])
    }

    @Test func aLayerChangedAfterSomeoneElseTookItAwayComesBack() {
        var (a, b) = pair()
        a.edit { doc in _ = doc.detach(node(doc, "One")!.id) }
        b.time = a.time + 100
        b.edit { set(&$0, "One") { $0.fill.color = .black } }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(node(macs[0].doc, "One")?.fill.color == .black)
    }

    @Test func aLayerTakenAwayAfterSomeoneElseChangedItStaysAway() {
        var (a, b) = pair()
        b.edit { set(&$0, "One") { $0.fill.color = .black } }
        a.time = b.time + 100
        a.edit { doc in _ = doc.detach(node(doc, "One")!.id) }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(node(macs[0].doc, "One") == nil)
    }

    @Test func anArtboardTakenAwayWhileALayerOnItChangedComesBackWithThatLayer() {
        var (a, b) = pair()
        a.edit { $0.nodes.removeAll() }
        b.time = a.time + 100
        b.edit { set(&$0, "Two") { $0.name = "Two, changed" } }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(names(macs[0].doc.nodes) == ["Board"])
        #expect(names(macs[0].doc.nodes[0].children) == ["Two, changed"])
    }

    @Test func aGroupFittedAgainByOneNeverMovesWhatAnotherPutInIt() {
        var doc = design()
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 200, width: 10, height: 10))
        group.children = [CanvasTests.rect("Left", CGRect(x: 0, y: 0, width: 50, height: 50)),
                          CanvasTests.rect("Right", CGRect(x: 100, y: 0, width: 50, height: 50))]
        doc.nodes[0].children.append(group)
        doc.fitGroups()
        var (a, b) = pair(doc)
        // A pulls Left further left, so the group grows that way and what it holds shifts inside it.
        a.edit { set(&$0, "Left") { $0.frame.origin.x -= 40 } }
        // B meanwhile moves Right along.
        b.edit { set(&$0, "Right") { $0.frame.origin.x += 30 } }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        let result = macs[0].doc
        #expect(result.absoluteFrame(of: node(result, "Left")!.id)?.minX == 60)
        #expect(result.absoluteFrame(of: node(result, "Right")!.id)?.minX == 230)
        #expect(result.absoluteFrame(of: node(result, "Group")!.id)?.minX == 60)
    }

    @Test func layersMovedIntoEachOtherAtOnceEndUpSomewhere() {
        var doc = BezzleDocument()
        var g1 = Node(kind: .group, name: "G1", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        g1.children = [CanvasTests.rect("In 1", CGRect(x: 0, y: 0, width: 10, height: 10))]
        var g2 = Node(kind: .group, name: "G2", frame: CGRect(x: 100, y: 0, width: 10, height: 10))
        g2.children = [CanvasTests.rect("In 2", CGRect(x: 0, y: 0, width: 10, height: 10))]
        doc.nodes = [g1, g2]
        var (a, b) = pair(doc)
        a.edit { doc in
            let moved = doc.detach(node(doc, "G1")!.id)!
            doc.attach(moved, to: node(doc, "G2")!.id)
        }
        b.edit { doc in
            let moved = doc.detach(node(doc, "G2")!.id)!
            doc.attach(moved, to: node(doc, "G1")!.id)
        }
        var macs = [a, b]
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(Set(macs[0].doc.allNodes.map(\.name)) == ["G1", "G2", "In 1", "In 2"])
    }

    @Test(arguments: [1, 2, 3, 42, 99, 2026] as [UInt64])
    func manyPeopleChangingEverythingAtOnceAllEndTheSame(seed: UInt64) {
        var random = Seeded(state: seed)
        var macs = [Mac("a", doc: design())]
        macs.append(Mac("b"))
        macs.append(Mac("c"))
        sync(&macs)
        var made = 0
        for _ in 0..<400 {
            let i = Int.random(in: 0..<macs.count, using: &random)
            macs[i].time += Int64.random(in: 0...40, using: &random)
            macs[i].edit { doc in Self.change(&doc, &random, &made) }
            if Int.random(in: 0..<6, using: &random) == 0 {
                let j = (i + Int.random(in: 1..<macs.count, using: &random)) % macs.count
                macs[j].receive(macs[i].state)
            }
        }
        sync(&macs)
        #expect(macs[0].doc == macs[1].doc)
        #expect(macs[1].doc == macs[2].doc)
        #expect(macs[0].state == macs[1].state && macs[1].state == macs[2].state)
        #expect(macs[0].doc.allNodes.allSatisfy { !$0.isGroup || !$0.children.isEmpty })
    }

    /// Taking in only the artboards and loose layers that changed does just what taking in the
    /// whole design does, step by step, through all the kinds of change people make, artboards
    /// added and taken away among them, and others' changes coming in between.
    @Test(arguments: [1, 2, 3, 42, 99, 2026, 7, 8] as [UInt64])
    func takingInOnlyWhatChangedIsTakingInEverything(seed: UInt64) {
        var doc = design()
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 200, width: 10, height: 10))
        var inner = Node(kind: .group, name: "Inner", frame: CGRect(x: 10, y: 10, width: 10, height: 10))
        inner.children = [CanvasTests.rect("Deep", CGRect(x: 0, y: 0, width: 30, height: 30))]
        group.children = [CanvasTests.rect("In", CGRect(x: 0, y: 0, width: 50, height: 50)), inner]
        var masked = Node(kind: .group, name: "Masked", frame: CGRect(x: 300, y: 300, width: 10, height: 10))
        masked.children = [CanvasTests.rect("Under", CGRect(x: 0, y: 0, width: 100, height: 100))]
        masked.mask = [Node(kind: .ellipse, name: "Mask", frame: CGRect(x: 10, y: 10, width: 60, height: 60))]
        doc.nodes[0].children += [group, masked]
        for k in 1...3 {
            var board = Node(kind: .artboard, name: "Board \(k)", frame: CGRect(x: CGFloat(k) * 1000, y: 0, width: 800, height: 600))
            board.children = [CanvasTests.rect("On \(k)", CGRect(x: 10, y: 10, width: 100, height: 100))]
            doc.nodes.append(board)
        }
        doc.nodes.append(CanvasTests.rect("Loose", CGRect(x: -200, y: 0, width: 20, height: 20)))
        doc.fitGroups()

        var runs: [[Mac]] = [false, true].map { incremental in
            var macs = [Mac("a", doc: doc, incremental: incremental), Mac("b", incremental: incremental), Mac("c", incremental: incremental)]
            sync(&macs)
            return macs
        }
        var random = Seeded(state: seed)
        var made = 0
        for step in 0..<300 {
            let i = Int.random(in: 0..<3, using: &random)
            let wait = Int64.random(in: 0...40, using: &random)
            runs[0][i].time += wait
            runs[0][i].edit { doc in
                switch Int.random(in: 0..<12, using: &random) {
                case 0:
                    made += 1
                    doc.nodes.insert(Node(kind: .artboard, name: "Board made \(made)", frame: CGRect(x: 0, y: 2000, width: 400, height: 300)),
                                     at: Int.random(in: 0...doc.nodes.count, using: &random))
                case 1:
                    let boards = doc.nodes.indices.filter { doc.nodes[$0].isArtboard }
                    if boards.count > 1 { doc.nodes.remove(at: boards[Int.random(in: 0..<boards.count, using: &random)]) }
                default:
                    Self.change(&doc, &random, &made)
                }
            }
            // The very same change, taken in only where it changed things.
            runs[1][i].time += wait
            runs[1][i].doc = runs[0][i].doc
            runs[1][i].commit()
            if Int.random(in: 0..<6, using: &random) == 0 {
                let j = (i + Int.random(in: 1..<3, using: &random)) % 3
                for r in 0..<2 { runs[r][j].receive(runs[r][i].state) }
            }
            for k in 0..<3 {
                #expect(runs[1][k].state == runs[0][k].state, "Mac \(k) after step \(step)")
                #expect(runs[1][k].doc == runs[0][k].doc, "Mac \(k)'s design after step \(step)")
                #expect(runs[1][k].base == FlatDesign(runs[1][k].doc), "Mac \(k)'s layers after step \(step)")
            }
            if (0..<3).contains(where: { runs[1][$0].state != runs[0][$0].state }) { return }
        }
        for r in 0..<2 { sync(&runs[r]) }
        #expect(runs[0].map(\.state) == runs[1].map(\.state))
        #expect(runs[1][0].doc == runs[1][1].doc && runs[1][1].doc == runs[1][2].doc)
    }

    @Test func takingInNothingChangedFindsNothing() {
        let doc = design()
        let (old, new) = FlatDesign.changes(from: doc, to: doc)
        #expect(old == new)
        #expect(new.entries.isEmpty)
        var state = SharedDesign()
        state.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1)
        let changed = state.absorb(new, since: old, by: "a", at: 2)
        #expect(!changed)
    }

    /// One change of the kinds people make: adding, taking away, moving, restyling, reordering,
    /// moving to another artboard, grouping and ungrouping.
    private static func change(_ doc: inout BezzleDocument, _ random: inout Seeded, _ made: inout Int) {
        let all = doc.allNodes
        let layers = all.filter { !$0.isArtboard }
        let containers = [nil] + all.filter(\.isContainer).map(\.id)
        func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[Int.random(in: 0..<items.count, using: &random)] }
        func coordinate() -> CGFloat { CGFloat(Int.random(in: 0...500, using: &random)) }
        switch Int.random(in: 0..<9, using: &random) {
        case 0, 1:
            made += 1
            let rect = CanvasTests.rect("Made \(made)", CGRect(x: coordinate(), y: coordinate(), width: 40, height: 40))
            doc.attach(rect, to: pick(containers) ?? nil)
        case 2:
            if let n = pick(layers) { _ = doc.detach(n.id) }
        case 3:
            if let n = pick(layers) { doc.update(n.id) { $0.frame.origin = CGPoint(x: coordinate(), y: coordinate()) } }
        case 4:
            if let n = pick(layers) { doc.update(n.id) { $0.fill.color = RGBA(r: Double(Int.random(in: 0...9, using: &random)) / 9, g: 0.5, b: 0.5) } }
        case 5:
            guard let n = pick(all), let path = doc.path(of: n.id) else { return }
            let parent = path.parent.map { doc[$0].id }
            let count = parent.flatMap { doc.node($0)?.children.count } ?? doc.nodes.count
            if let moved = doc.detach(n.id) { doc.attach(moved, to: parent, at: Int.random(in: 0...max(0, count - 1), using: &random)) }
        case 6:
            if let n = pick(layers), let to = pick(all.filter(\.isArtboard)), to.id != n.id, let moved = doc.detach(n.id) {
                doc.attach(moved, to: to.id)
            }
        case 7:
            guard let parent = pick(all.filter(\.isContainer)), parent.children.count >= 2 else { return }
            let ids = Array(parent.children.prefix(2)).map(\.id)
            let kids = ids.compactMap { doc.detach($0) }
            let box = kids.map(\.frame).reduce(kids[0].frame) { $0.union($1) }
            var group = Node(kind: .group, name: "Group \(made)", frame: box)
            made += 1
            group.children = kids.map { var k = $0; k.frame.origin.x -= box.minX; k.frame.origin.y -= box.minY; return k }
            doc.attach(group, to: parent.id)
        default:
            guard let group = pick(all.filter(\.isGroup)) else { return }
            let parent = doc.parent(of: group.id)?.id
            guard let taken = doc.detach(group.id) else { return }
            for var child in taken.children {
                child.frame.origin.x += taken.frame.minX
                child.frame.origin.y += taken.frame.minY
                doc.attach(child, to: parent)
            }
        }
    }

    // MARK: Undo

    @Test func undoTakesBackOnlyWhatWasDoneHere() {
        let before = design()
        var after = before
        set(&after, "One") { $0.fill.color = .black }
        // Meanwhile someone else moved One, and renamed Two.
        var now = after
        set(&now, "One") { $0.frame.origin.x = 222 }
        set(&now, "Two") { $0.name = "Second" }
        let undone = FlatDesign.apply(from: after, to: before, onto: now)
        #expect(node(undone, "One")?.fill.color == node(before, "One")?.fill.color)
        #expect(node(undone, "One")?.frame.minX == 222)
        #expect(node(undone, "Second") != nil)
        // With nothing changed since, it is what it was.
        #expect(FlatDesign.apply(from: after, to: before, onto: after) == before)
    }

    @Test func undoLeavesAPropertySomeoneElseChangedSince() {
        let before = design()
        var after = before
        set(&after, "One") { $0.fill.color = .black }
        var now = after
        set(&now, "One") { $0.fill.color = .white }
        #expect(node(FlatDesign.apply(from: after, to: before, onto: now), "One")?.fill.color == .white)
    }

    @Test func undoBringsBackWhatWasTakenAwayAndTakesAwayWhatWasAdded() {
        let before = design()
        var after = before
        _ = after.detach(node(after, "Two")!.id)
        after.nodes[0].children.append(CanvasTests.rect("New", CGRect(x: 0, y: 0, width: 5, height: 5)))
        var now = after
        set(&now, "Three") { $0.name = "Third" }
        let undone = FlatDesign.apply(from: after, to: before, onto: now)
        #expect(names(undone.nodes[0].children) == ["One", "Two", "Third"])
    }

    @Test func undoPutsBackALayerMovedOutOfAGroup() {
        var before = design()
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 0, y: 300, width: 10, height: 10))
        group.children = [CanvasTests.rect("A", CGRect(x: 0, y: 0, width: 50, height: 50)),
                          CanvasTests.rect("B", CGRect(x: 60, y: 0, width: 50, height: 50))]
        before.nodes[0].children.append(group)
        before.fitGroups()
        // Ungrouped here.
        var after = before
        let taken = after.detach(node(after, "Group")!.id)!
        for child in taken.children {
            var c = child
            c.frame.origin.x += taken.frame.minX
            c.frame.origin.y += taken.frame.minY
            after.attach(c, to: after.nodes[0].id)
        }
        var now = after
        set(&now, "One") { $0.name = "First" }
        let undone = FlatDesign.apply(from: after, to: before, onto: now)
        #expect(names(undone.nodes[0].children) == ["First", "Two", "Three", "Group"])
        #expect(names(node(undone, "Group")?.children ?? []) == ["A", "B"])
        #expect(undone.absoluteFrame(of: node(undone, "B")!.id) == before.absoluteFrame(of: node(before, "B")!.id))
    }

    // MARK: In the app

    /// A bench whose design is shared, with another Mac that has fetched it.
    private func sharedBench() -> (Bench, Collaboration, Mac) {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        let session = Collaboration(url: bench.store.url, link: SharingLink(zone: "design-test-\(UUID().uuidString)", owner: nil), state: SharedDesign())
        bench.store.sharing = session
        _ = CloudSync.shared.claim(session.zone, at: bench.store.url)
        session.attach(to: bench.store)
        var other = Mac("other")
        other.time = Collaboration.now
        other.receive(session.state)
        return (bench, session, other)
    }

    @Test func changesFromOthersShowAndUndoingHereLeavesThem() {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        #expect(other.doc.nodes == store.doc.nodes)

        bench.step { store.update([bench.node("R")!.id], "Colour") { $0.fill.color = .black } }
        store.save()
        other.receive(session.state)
        other.time = Collaboration.now + 10
        other.edit { set(&$0, "S") { $0.frame.origin.x = 333 } }
        session.receive([other.state])
        #expect(bench.node("S")?.frame.minX == 333)
        #expect(bench.node("R")?.fill.color == .black)

        bench.undo.undo()
        #expect(bench.node("R")?.fill.color == CanvasTests.rect("R", .zero).fill.color)
        #expect(bench.node("S")?.frame.minX == 333)
        // The undo is a change like any other, and goes to the others.
        store.save()
        other.receive(session.state)
        #expect(node(other.doc, "R")?.fill.color == CanvasTests.rect("R", .zero).fill.color)
        #expect(other.doc.nodes == store.doc.nodes)

        bench.undo.redo()
        #expect(bench.node("R")?.fill.color == .black)
        #expect(bench.node("S")?.frame.minX == 333)
    }

    @Test func changesFromOthersWaitForADragToEnd() {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        other.time = Collaboration.now + 10
        other.edit { set(&$0, "S") { $0.name = "S, renamed" } }

        bench.step {
            store.beginGesture()
            store.update([bench.node("R")!.id], "Move") { $0.frame.origin.x = 40 }
            session.receive([other.state])
            #expect(bench.node("S, renamed") == nil)
            store.endGesture("Move")
        }
        #expect(bench.node("S, renamed") != nil)
        #expect(bench.node("R")?.frame.minX == 40)
    }

    @Test func aSharedDesignOpensAsItIsSharedEvenIfItsFileLagsBehind() throws {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let url = bench.store.url
        defer { try? FileManager.default.removeItem(at: url) }
        bench.store.save()
        DocumentStore.finishSaving()
        other.time = Collaboration.now + 10
        other.edit { $0.nodes[0].children.append(CanvasTests.rect("Late", CGRect(x: 0, y: 200, width: 10, height: 10))) }
        session.receive([other.state])
        session.persist()
        DocumentStore.finishSaving()
        // Bezzle stops before the design's own file is written.
        session.close()
        let reopened = try DocumentStore(opening: url)
        #expect(reopened.doc.allNodes.contains { $0.name == "Late" })
        #expect(reopened.sharing?.zone == session.zone)
        reopened.sharing?.close()
    }

    @Test func aDesignNoLongerSharedCanOnlyBeLookedAtAndSavedAsACopy() throws {
        let (bench, session, _) = sharedBench()
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        session.link.owner = "_someoneElse"
        #expect(store.sharing?.mark == .sharedBy(nil))
        session.link.ended = true
        #expect(store.isReadOnly)
        #expect(store.sharing?.mark == .ended)
        let before = store.doc
        bench.step { store.update([bench.node("R")!.id], "Colour") { $0.fill.color = .black } }
        #expect(store.doc == before)

        store.saveCopy()
        DocumentStore.finishSaving()
        let copy = Library.shared.folder.appendingPathComponent("\(store.name) copy.bezzle")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(SharingFiles.link(of: copy) == nil)
        let opened = try DocumentStore(opening: copy)
        #expect(opened.sharing == nil && !opened.isReadOnly)
        #expect(opened.doc.allNodes.map(\.name) == store.doc.allNodes.map(\.name))
        session.close()
    }

    @Test func aDuplicateOfASharedDesignIsNotShared() throws {
        let (bench, session, _) = sharedBench()
        let url = bench.store.url
        defer { try? FileManager.default.removeItem(at: url) }
        bench.store.save()
        DocumentStore.finishSaving()
        Library.shared.duplicate(url)
        let copy = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " copy.bezzle")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(SharingFiles.link(of: copy) == nil)
        session.close()
    }

    @Test func aCopyOfASharedDesignIsADesignOfItsOwn() throws {
        let (bench, session, _) = sharedBench()
        let url = bench.store.url
        let copy = url.deletingLastPathComponent().appendingPathComponent("Copy-\(UUID().uuidString).bezzle")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        bench.store.save()
        DocumentStore.finishSaving()
        try FileManager.default.copyItem(at: url, to: copy)
        let opened = try DocumentStore(opening: copy)
        #expect(opened.sharing == nil)
        #expect(SharingFiles.link(of: copy) == nil)
        #expect(SharingFiles.link(of: url)?.zone == session.zone)
        session.close()
    }
}
