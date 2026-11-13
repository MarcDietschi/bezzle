import Testing
import AppKit
@testable import Bezzle

/// What the tests of a film in the rest of the app make their designs of.
enum Filmed {
    /// A layer given a way of coming on: it fades in and rises into place on a spring. At the
    /// start of its film it is nowhere to be seen, so a picture that showed the film would differ.
    static func moving(_ layer: Node) -> Node {
        var n = layer
        n.setKey(.fade, [0], at: 0)
        n.setKey(.fade, [1], at: 0.6, ease: MotionEase(kind: .easeOut))
        n.setKey(.move, [0, 40], at: 0)
        n.setKey(.move, [0, 0], at: 0.8, ease: MotionEase(kind: .spring, bounce: 0.3))
        return n
    }

    /// The motion a moving layer has.
    static let moves = moving(Node(kind: .rectangle, name: "", frame: .zero)).motion

    /// A coloured card, moving unless told to stay.
    static func card(_ name: String, _ frame: CGRect, moving: Bool = true) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill = Fill(color: RGBA(r: 0.9, g: 0.3, b: 0.2))
        return moving ? Self.moving(n) : n
    }

    /// Words, moving unless told to stay.
    static func words(_ name: String, _ text: String, at origin: CGPoint, moving: Bool = true) -> Node {
        var n = Node(kind: .text, name: name, frame: CGRect(origin: origin, size: .zero))
        n.text = text
        n.refit()
        return moving ? Self.moving(n) : n
    }

    /// An artboard given a film of its own: three seconds, played once, on a dark backdrop, its
    /// camera closing in on a point off its middle.
    static func filmed(_ board: Node) -> Node {
        var b = board
        b.film = Film(length: 3, once: true, backdrop: RGBA(r: 0.1, g: 0.1, b: 0.12))
        b.setKey(.cameraZoom, [1], at: 0)
        b.setKey(.cameraZoom, [1.6], at: 2, ease: MotionEase(kind: .smooth))
        b.setKey(.cameraMove, [0, 0], at: 0)
        b.setKey(.cameraMove, [30, -20], at: 2)
        return b
    }

    /// A design of one artboard, nothing in it moving: a card, a group holding a badge and a
    /// title, and a dot.
    static func still() -> BezzleDocument {
        var group = Node(kind: .group, name: "Group", frame: .zero)
        group.children = [card("Badge", CGRect(x: 0, y: 0, width: 60, height: 40), moving: false),
                          words("Title", "Hello", at: CGPoint(x: 0, y: 60), moving: false)]
        // Fitted round what it holds, as every group in a design is.
        let box = group.children[0].frame.union(group.children[1].frame)
        group.frame = CGRect(x: 200, y: 40, width: box.maxX, height: box.maxY)
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 40, y: 200, width: 30, height: 30))
        dot.fill = Fill(color: RGBA(r: 0.1, g: 0.4, b: 0.9))
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        board.children = [card("Card", CGRect(x: 40, y: 40, width: 120, height: 80), moving: false), group, dot]
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    /// The same design with a film: the card, the group and the badge in it move, the dot stays.
    static func animated(_ still: BezzleDocument) -> BezzleDocument {
        var doc = still
        for n in still.allNodes {
            switch n.name {
            case "Card", "Badge", "Group": doc.update(n.id) { $0 = moving($0) }
            case "A": doc.update(n.id) { $0 = filmed($0) }
            default: break
            }
        }
        return doc
    }

    static func design() -> BezzleDocument { animated(still()) }

    /// A layer of every property and every pace, with a key Bezzle gave it for company.
    static func everything(_ name: String = "All") -> Node {
        var n = Node(kind: .rectangle, name: name, frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        for (i, p) in MotionProperty.layer.enumerated() {
            for (j, kind) in MotionEase.Kind.allCases.enumerated() {
                let value = p.rest.map { $0 + Double(j + 1) * (p == .fade ? -0.1 : 0.3) }
                n.setKey(p, value, at: Double(j) * 0.5 + Double(i) * 0.01, ease: MotionEase(kind: kind, bounce: kind == .spring ? 0.4 : nil))
            }
        }
        return n
    }

    /// A folder of its own in the temporary one.
    static func place(_ ending: String = "bezzle") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-film-\(UUID().uuidString).\(ending)")
    }

    /// A picture's pixels: red, green, blue and alpha.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

/// A film where the rest of the app meets it: written to a design's file and read again, however
/// the file has it; kept in versions; and left out of everything that shows the design as it is
/// designed, the pictures exported, Inspect's code, the prototype, and what comes in from other apps.
@MainActor
struct MotionDesignTests {
    private func written(_ doc: BezzleDocument) throws -> Data {
        let url = Filmed.place()
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(doc, to: url)
        return try Data(contentsOf: url.appendingPathComponent(DesignFile.documentName))
    }

    /// A layer as it is read from a file that says what its own would with `change` made to it.
    private func opened(_ node: Node, _ change: (inout [String: Any]) -> Void) throws -> Node {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(Node.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The same, with the change made to its motion.
    private func moving(_ node: Node, _ change: (inout [String: Any]) -> Void) throws -> Node {
        try opened(node) { object in
            var motion = object["motion"] as? [String: Any] ?? [:]
            change(&motion)
            object["motion"] = motion
        }
    }

    private func keys(_ list: [(Double, [Double])]) -> [String: Any] {
        ["keys": list.map { ["t": $0.0, "v": $0.1] as [String: Any] }]
    }

    /// What a file says in so many words.
    private func said(_ json: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
    }

    // MARK: A design's file

    @Test func aFilmIsWrittenToADesignsFileAndReadAsItWas() throws {
        var doc = Filmed.design()
        doc.update(doc.nodes[0].id) { $0.children.append(Filmed.everything()) }
        // A key posed by hand, with the one Bezzle gives it for company.
        var posed = Filmed.card("Posed", CGRect(x: 300, y: 200, width: 40, height: 40), moving: false)
        posed.pose(.turn, [45], at: 1.2)
        #expect(posed[track: .turn]?.keys.map(\.given) == [true, nil])
        doc.update(doc.nodes[0].id) { $0.children.append(posed) }

        let url = Filmed.place()
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(doc, to: url)
        let back = try DesignFile.read(url)
        #expect(back.nodes == doc.nodes)
        let all = try #require(back.allNodes.first { $0.name == "All" })
        #expect(all.motionProperties == MotionProperty.layer)
        for p in MotionProperty.layer {
            // Left to Bezzle, a pace is not written at all; every other is, a spring with its bounce.
            #expect(all[track: p]?.keys.map { $0.ease?.kind } == [nil, .smooth, .easeIn, .easeOut, .linear, .spring, .hold])
            #expect(all[track: p]?.keys[5].ease?.bounce == 0.4)
        }
        let board = back.nodes[0]
        #expect(board.film == Film(length: 3, once: true, backdrop: RGBA(r: 0.1, g: 0.1, b: 0.12)))
        #expect(board.hasCamera && board.filmLength == 3)
        // Written a second time, it is the same file to the byte.
        #expect(try written(back) == (try written(doc)))
    }

    @Test func aLayerThatNeverMovedIsWrittenAsItAlwaysWas() throws {
        let still = Filmed.still()
        for n in still.allNodes {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as? [String: Any])
            #expect(object["motion"] == nil && object["film"] == nil, "\(n.name)")
        }
        let file = String(decoding: try written(still), as: UTF8.self)
        #expect(!file.contains("\"motion\"") && !file.contains("\"film\""))
        // And one that does says so in two words of its own, beside what it said before.
        let moving = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Filmed.design().nodes[0])) as? [String: Any])
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(still.nodes[0])) as? [String: Any])
        #expect(Set(moving.keys).subtracting(plain.keys) == ["motion", "film"])
        #expect(Set(plain.keys).subtracting(moving.keys).isEmpty)
        #expect(Set((moving["motion"] as? [String: Any] ?? [:]).keys) == ["cameraMove", "cameraZoom"])
        #expect(Set((moving["film"] as? [String: Any] ?? [:]).keys) == ["length", "once", "backdrop"])
    }

    @Test func aDesignWhoseFilmWasTakenAwayIsWrittenAsOneThatNeverMoved() throws {
        let still = Filmed.still()
        let before = try written(still)

        // All of it at once.
        var cleared = Filmed.animated(still)
        #expect(try written(cleared) != before)
        cleared.clearMotion(cleared.nodes.map(\.id))
        #expect(try written(cleared) == before)

        // Key by key, and the film's settings one by one.
        var emptied = Filmed.animated(still)
        for n in emptied.allNodes {
            emptied.update(n.id) { layer in
                for p in MotionProperty.allCases {
                    for t in layer.keyTimes([p]) { layer.removeKeys(at: t, of: [p]) }
                }
                layer.film?.length = nil
                layer.film?.once = nil
                layer.film?.backdrop = nil
                // With nothing set, a film says nothing: the panel takes it away then, as here.
                if layer.film == Film() { layer.film = nil }
            }
        }
        #expect(try written(emptied) == before)

        // A layer posed and then posed back where it is designed has two keys that say the same:
        // they stay, for they were made by hand. Taken away, nothing is left of them.
        var posed = still
        let card = try #require(posed.allNodes.first { $0.name == "Card" }).id
        posed.update(card) { $0.pose(.turn, [30], at: 1); $0.pose(.turn, [0], at: 1) }
        posed.update(card) { $0.removeKeys(at: 1, of: [.turn]) }
        #expect(posed.node(card)?.motion == nil)
        #expect(try written(posed) == before)
    }

    @Test func aPropertyThisBezzleDoesNotKnowIsKeptAndLeftAlone() throws {
        let card = Filmed.card("Card", CGRect(x: 40, y: 40, width: 120, height: 80))
        let later = try moving(card, { $0["wobble"] = self.keys([(0, [1, 2, 3]), (9, [0])]) })
        // No part of how the layer is posed here.
        #expect(later.motionProperties == [.move, .fade])
        for t in [0, 0.3, 0.8, 5, 9] { #expect(later.pose(at: t) == card.pose(at: t)) }
        #expect(later.keyTimes(MotionProperty.allCases) == card.keyTimes(MotionProperty.allCases))
        // Kept for the Bezzle that wrote it: written again as it came.
        #expect(later.motion?["wobble"]?.keys.map(\.v) == [[1, 2, 3], [0]])
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(later)) == later)
        // The film is as long as that Bezzle made it: its last key counts.
        #expect(later.lastKey == 9)

        // Alone on a layer, it makes nothing here move, and the layer is drawn into the film's ground.
        let only = try moving(Filmed.card("Still", card.frame, moving: false), { $0["wobble"] = self.keys([(0, [1]), (2, [0])]) })
        #expect(!only.isAnimated && only.motionProperties.isEmpty)
        #expect(only.posed(at: 1).atRest == only.atRest)
    }

    @Test func aKeyThatCannotBeReadRefusesTheDesignRatherThanTrapping() throws {
        let card = Filmed.card("Card", CGRect(x: 40, y: 40, width: 120, height: 80))
        func refused(_ what: String, _ change: (inout [String: Any]) -> Void) {
            #expect(throws: DecodingError.self, "\(what)") { _ = try self.moving(card, change) }
        }
        // A pace this Bezzle has no name for.
        refused("an unknown pace") { $0["fade"] = self.said(#"{"keys":[{"t":0,"v":[0]},{"t":1,"v":[1],"ease":{"kind":"elastic"}}]}"#) }
        // A key with no moment, or no value; a property with no keys at all.
        refused("no moment") { $0["fade"] = self.said(#"{"keys":[{"v":[0]}]}"#) }
        refused("no value") { $0["fade"] = self.said(#"{"keys":[{"t":0}]}"#) }
        refused("no keys") { $0["fade"] = self.said("{}") }
        // Words where numbers belong.
        refused("a moment in words") { $0["fade"] = self.said(#"{"keys":[{"t":"soon","v":[0]}]}"#) }
        refused("a value in words") { $0["fade"] = self.said(#"{"keys":[{"t":0,"v":["half"]}]}"#) }
        refused("keys that are no list") { $0["fade"] = self.said(#"{"keys":"none"}"#) }
        #expect(throws: DecodingError.self) { _ = try self.opened(card) { $0["motion"] = self.said("[1,2,3]") } }
        #expect(throws: DecodingError.self) { _ = try self.opened(card) { $0["film"] = self.said(#"{"length":"long"}"#) } }
        #expect(throws: DecodingError.self) { _ = try self.opened(card) { $0["film"] = self.said(#"{"backdrop":"black"}"#) } }

        // The whole design is then refused as any file that cannot be read is: an error to show,
        // and nothing opened by halves.
        var doc = Filmed.design()
        let id = try #require(doc.allNodes.first { $0.name == "Card" }).id
        doc.update(id) { $0.setEase(MotionEase(kind: .linear), at: 0.6, of: [.fade]) }
        let url = Filmed.place()
        defer { try? FileManager.default.removeItem(at: url) }
        try DesignFile.write(doc, to: url)
        let file = url.appendingPathComponent(DesignFile.documentName)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("\"kind\":\"linear\""))
        try Data(text.replacingOccurrences(of: "\"kind\":\"linear\"", with: "\"kind\":\"elastic\"").utf8).write(to: file)
        #expect(throws: DecodingError.self) { _ = try DesignFile.read(url) }
        #expect(throws: (any Error).self) { _ = try DocumentStore(opening: url) }
    }

    @Test func keysWithTheWrongNumbersOrOutOfOrderOpenAndArePosedAllTheSame() throws {
        let plain = Filmed.card("Card", CGRect(x: 40, y: 40, width: 120, height: 80), moving: false)
        // Every moment a film could ask for, and some it could not.
        let moments: [Double] = (-10...500).map { Double($0) / 100 } + [1e9, -1e9, .nan, .infinity, -.infinity]
        func sound(_ n: Node, _ what: String) {
            for p in MotionProperty.allCases {
                for t in moments {
                    let v = n.value(of: p, at: t)
                    #expect(v.count == p.rest.count && v.allSatisfy(\.isFinite) && v == p.clamped(v), "\(what): \(p) at \(t) is \(v)")
                }
            }
            for t in moments where t.isFinite {
                let posed = n.posed(at: t)
                #expect(posed.frame.width.isFinite && posed.frame.minX.isFinite && posed.opacity.isFinite, "\(what) at \(t)")
            }
            #expect(n.lastKey.isFinite, "\(what)")
            #expect((try? JSONEncoder().encode(n)) != nil, "\(what) cannot be written again")
        }

        // Too few numbers and too many: what is missing is as designed, what is over is left out.
        let few = try moving(plain, { $0["move"] = self.keys([(0, [50]), (1, []), (2, [10, 20, 30, 40])]) })
        #expect(few.value(of: .move, at: 0) == [50, 0])
        #expect(few.value(of: .move, at: 1) == [0, 0])
        #expect(few.value(of: .move, at: 2) == [10, 20])
        sound(few, "too few and too many")
        // Three keys going the same way, the middle one with fewer numbers: a flight through it.
        let ragged = try moving(plain, {
            $0["move"] = self.keys([(0, [0, 0]), (1, [10]), (2, [20, 20]), (3, [30])])
            $0["scale"] = self.keys([(0, [1]), (1, [1.5, 1.5]), (2, [2]), (3, [2.5, 2.5, 9])])
        })
        sound(ragged, "ragged")

        // Out of order, they are put in order as they are read.
        let jumbled = try moving(plain, { $0["fade"] = self.keys([(2, [1]), (0, [0]), (1, [0.5])]) })
        #expect(jumbled[track: .fade]?.keys.map(\.t) == [0, 1, 2])
        #expect(jumbled.value(of: .fade, at: 0) == [0] && jumbled.value(of: .fade, at: 1) == [0.5] && jumbled.value(of: .fade, at: 3) == [1])
        sound(jumbled, "out of order")

        // Two at one moment, one before the start, one a lifetime away, values past every limit.
        let twice = try moving(plain, { $0["turn"] = self.keys([(1, [10]), (1, [90]), (1, [45]), (2, [0])]) })
        sound(twice, "three keys at one moment")
        let early = try moving(plain, { $0["fade"] = self.keys([(-5, [0]), (-1, [1]), (1e12, [0.5])]) })
        #expect(early.value(of: .fade, at: 0).allSatisfy { $0 >= 0 && $0 <= 1 })
        sound(early, "before the start and far away")
        let wild = try moving(plain, {
            $0["fade"] = self.keys([(0, [-40]), (1, [1e300])])
            $0["scale"] = self.keys([(0, [-1e300, 0]), (1, [1e300, 1e300])])
            $0["blur"] = self.keys([(0, [-3]), (1, [1e9])])
        })
        #expect(wild.value(of: .fade, at: 0) == [0] && wild.value(of: .fade, at: 1) == [1])
        sound(wild, "past every limit")

        // A property with an empty list of keys moves nothing and is no motion.
        let none = try moving(plain, { $0["fade"] = self.said(#"{"keys":[]}"#) })
        #expect(!none.isAnimated && none.motionProperties.isEmpty && none.keyTimes().isEmpty)
        sound(none, "no keys")

        // A pace with a bounce no spring has, and one that is not a spring at all.
        let bounced = try moving(plain, {
            $0["move"] = self.said(#"{"keys":[{"t":0,"v":[0,0]},{"t":1,"v":[100,0],"ease":{"kind":"spring","bounce":40}},{"t":2,"v":[0,0],"ease":{"kind":"hold","bounce":-3}}]}"#)
        })
        sound(bounced, "a bounce out of range")

        // A number too large to be one: refused, or read as a number, never a trap.
        let json = String(decoding: try JSONEncoder().encode(Filmed.moving(plain)), as: UTF8.self).replacingOccurrences(of: "\"t\":0.8", with: "\"t\":1e999")
        #expect(json.contains("1e999"))
        if let huge = try? JSONDecoder().decode(Node.self, from: Data(json.utf8)) { sound(huge, "a moment too large to be a number") }
    }

    @Test func aFilmSetOddlyInAFileIsStillAFilm() throws {
        let board = Filmed.design().nodes[0]
        // No length, none that can be, or one from before the start: it runs as long as its keys.
        for length in [0.0, -3, -1e300] {
            let odd = try opened(board) { $0["film"] = ["length": length] }
            #expect(odd.filmLength == 2, "\(length)")
        }
        // An absurd one is taken at its word by the model, which still measures the film without trapping.
        let long = try opened(board) { $0["film"] = ["length": 1e300] }
        #expect(long.filmLength == 1e300)
        for piece in long.filmPieces() { #expect(long.filmStretch(of: piece, around: CGRect(origin: .zero, size: long.frame.size)).isFinite) }
        // What this Bezzle does not know of a film is left out; what it does is read.
        let more = try opened(board) { $0["film"] = self.said(#"{"length":4.5,"once":false,"sound":"waves.mp3"}"#) }
        #expect(more.film == Film(length: 4.5, once: false))
        // A film with nothing set says nothing, and is one all the same.
        let empty = try opened(board) { $0["film"] = self.said("{}") }
        #expect(empty.film == Film() && empty.filmLength == 2 && empty.hasFilm)
        #expect(empty.filmBackdrop == board.with { $0.film = nil }.filmBackdrop)
        // A layer that is no artboard and has a film, or a camera: nothing comes of either.
        let layer = try opened(Filmed.card("Card", CGRect(x: 0, y: 0, width: 50, height: 50))) {
            $0["film"] = self.said(#"{"length":9}"#)
            var motion = $0["motion"] as? [String: Any] ?? [:]
            motion["cameraZoom"] = self.keys([(0, [1]), (1, [3])])
            $0["motion"] = motion
        }
        var held = board
        held.children = [layer]
        #expect(held.filmLength == 3)
        #expect(held.camera(at: 1) == board.camera(at: 1))
        #expect(layer.pose(at: 0.3) == Filmed.card("Card", layer.frame).pose(at: 0.3))
    }

    @Test func theStoreSavesAFilmAndADesignOpenedFreshHasIt() throws {
        let bench = Bench(extra: Filmed.still().nodes[0].children)
        defer {
            DocumentStore.finishSaving()
            try? FileManager.default.removeItem(at: bench.store.url)
        }
        let before = bench.store.doc
        bench.step { bench.store.edit("Add Key") { $0 = Filmed.animated($0) } }
        #expect(bench.store.doc != before)
        bench.store.save()
        DocumentStore.finishSaving()

        let fresh = try DocumentStore(opening: bench.store.url)
        #expect(fresh.doc.nodes == bench.store.doc.nodes)
        #expect(fresh.doc.nodes[0].filmLength == 3 && fresh.doc.nodes[0].hasCamera)
        #expect(fresh.doc.allNodes.first { $0.name == "Badge" }?.isAnimated == true)
        // The film is the artboard's and the layers' own: nothing of it is kept beside them.
        #expect(fresh.doc.with { $0.nodes = [] } == before.with { $0.nodes = [] })

        // Undone and saved, the file is the design that never moved.
        bench.undoLast()
        #expect(bench.store.doc.nodes == before.nodes)
        bench.store.save()
        DocumentStore.finishSaving()
        let file = String(decoding: try Data(contentsOf: bench.store.url.appendingPathComponent(DesignFile.documentName)), as: UTF8.self)
        #expect(!file.contains("\"motion\"") && !file.contains("\"film\""))
    }

    // MARK: Versions

    /// A bench whose design is a package on disk, as versions need.
    private func kept() throws -> Bench {
        let bench = Bench(extra: Filmed.still().nodes[0].children)
        try DesignFile.write(bench.store.doc, to: bench.store.url)
        bench.store.becamePackage()
        return bench
    }

    private func done(_ bench: Bench) {
        bench.store.versions.stop()
        DocumentStore.finishSaving()
        try? FileManager.default.removeItem(at: bench.store.url)
    }

    @Test func aVersionKeepsTheFilmAndGoingBackBringsItBack() throws {
        let bench = try kept()
        defer { done(bench) }
        let store = bench.store
        bench.step { store.edit("Add Key") { $0 = Filmed.animated($0) } }
        let animated = store.doc

        // Packed for a version and unpacked, nothing of the film is lost.
        let packed = try #require(VersionFiles.pack(animated))
        var back = try #require(VersionFiles.unpack(packed))
        back.viewport = animated.viewport
        #expect(back == animated)

        let then = try #require(store.versions.take(store.sharedDoc, name: "Animated"))
        // Only the film changes: a key moved, the film made longer. That alone is another design.
        let card = try #require(bench.node("Card")).id
        bench.step {
            store.edit("Move Key") { doc in
                doc.update(card) { $0.moveKeys(from: 0.8, to: 1.4, of: [.move]) }
                doc.update(doc.nodes[0].id) { $0.film?.length = 5 }
            }
        }
        #expect(!store.sharedDoc.sameDesign(as: animated))
        #expect(VersionKeeping.differences(animated, store.doc).changed == [card, store.doc.nodes[0].id])
        bench.step { store.versions.restore(then.id) }
        #expect(store.doc.nodes == animated.nodes)
        // Going back kept how it was just before, film and all.
        let saved = try #require(store.versions.list.first { $0.id != then.id })
        let before = try #require(store.versions.document(saved.id))
        #expect(before.node(card)?[track: .move]?.keys.map(\.t) == [0, 1.4])
        #expect(before.nodes[0].film?.length == 5)

        // And all of the film taken away, then gone back to.
        bench.step { store.edit("Remove Motion") { $0.clearMotion($0.nodes.map(\.id)) } }
        #expect(store.doc.allNodes.allSatisfy { $0.motion == nil && $0.film == nil })
        bench.step { store.versions.restore(then.id) }
        #expect(store.doc.nodes == animated.nodes)
    }

    @Test func aLayerBroughtBackFromAVersionMovesAsItDidThen() throws {
        let bench = try kept()
        defer { done(bench) }
        let store = bench.store
        bench.step { store.edit("Add Key") { $0 = Filmed.animated($0) } }
        let then = try #require(store.versions.take(store.sharedDoc, name: "Animated"))
        let card = try #require(bench.node("Card")), dot = try #require(bench.node("Dot"))
        // Since then the card lost its motion and the dot got some.
        bench.step {
            store.edit("Change Motion") { doc in
                doc.clearMotion([card.id])
                doc.update(dot.id) { $0.pose(.scale, [2, 2], at: 1) }
            }
        }
        store.versions.show(then.id)
        // The card is at 40, 40 on its artboard, which is at 100, 100.
        store.versions.pick(at: CGPoint(x: 200, y: 180))
        bench.step { store.versions.bringBack() }
        #expect(bench.node("Card")?.motion == card.motion)
        #expect(bench.node("Dot")?[track: .scale]?.keys.count == 2)
        #expect(bench.a.film == Filmed.filmed(bench.a).film)
    }

    // MARK: What shows the design as it is designed

    /// The artboard of a design as a picture.
    private func picture(_ doc: BezzleDocument, scale: CGFloat = 2) throws -> [UInt8] {
        Filmed.pixels(try #require(ExportItem(artboard: doc.nodes[0]).picture(scale: scale, opaque: true, assets: nil)).image)
    }

    @Test func picturesOfAnArtboardShowTheDesignAndNotItsFilm() throws {
        let still = Filmed.still(), moving = Filmed.animated(still)
        // The film would show: at its start the card is not to be seen at all.
        var first = moving
        first.update(first.nodes[0].id) { $0 = $0.posed(at: 0).atRest }
        #expect(try picture(first) != (try picture(still)))

        // As pixels.
        #expect(try picture(moving) == (try picture(still)))
        #expect(try #require(Renderer.image(of: moving.nodes[0], scale: 1)).width == 400)
        #expect(Filmed.pixels(try #require(Renderer.image(of: moving.nodes[0], scale: 1))) == Filmed.pixels(try #require(Renderer.image(of: still.nodes[0], scale: 1))))
        // As a drawing.
        let a = ExportItem(artboard: moving.nodes[0]), b = ExportItem(artboard: still.nodes[0])
        #expect(a.bounds(assets: nil) == b.bounds(assets: nil))
        let svg = SVGWriter.document(for: a, bounds: a.bounds(assets: nil), assets: nil)
        #expect(svg == SVGWriter.document(for: b, bounds: b.bounds(assets: nil), assets: nil))
        #expect(!svg.contains("animate") && !svg.contains("opacity=\"0\""))

        // As files of every kind, the same to the byte but for a PDF, which carries when it was made.
        let folder = Filmed.place("exports")
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in ExportFormat.allCases {
            let one = try #require(Exporter.export([a], format: format, scale: 2, name: "Moving", to: folder.appendingPathComponent("a")).first, "\(format)")
            let other = try #require(Exporter.export([b], format: format, scale: 2, name: "Moving", to: folder.appendingPathComponent("b")).first, "\(format)")
            if format == .pdf {
                #expect(try page(one) == (try page(other)))
            } else {
                #expect(try Data(contentsOf: one) == (try Data(contentsOf: other)), "\(format)")
            }
        }
    }

    /// The first page of a PDF as pixels.
    private func page(_ url: URL) throws -> [UInt8] {
        let page = try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let ctx = try #require(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: box.size))
        ctx.drawPDFPage(page)
        return Filmed.pixels(try #require(ctx.makeImage()))
    }

    @Test func aLayerExportedAloneIsAsDesigned() throws {
        let still = Filmed.still(), moving = Filmed.animated(still)
        for name in ["Card", "Group", "Badge"] {
            let id = try #require(still.allNodes.first { $0.name == name }).id
            let a = try #require(ExportItem.items(for: [id], in: moving).first), b = try #require(ExportItem.items(for: [id], in: still).first)
            #expect(a.bounds(assets: nil) == b.bounds(assets: nil), "\(name)")
            let one = try #require(a.picture(scale: 2, opaque: false, assets: nil)), other = try #require(b.picture(scale: 2, opaque: false, assets: nil))
            #expect(one.rect == other.rect && Filmed.pixels(one.image) == Filmed.pixels(other.image), "\(name)")
            #expect(SVGWriter.document(for: a, bounds: a.bounds(assets: nil), assets: nil) == SVGWriter.document(for: b, bounds: b.bounds(assets: nil), assets: nil), "\(name)")
        }
    }

    @Test func inspectsCodeIsOfTheDesignAndSaysNothingOfTheFilm() throws {
        let still = Filmed.still(), moving = Filmed.animated(still)
        for n in still.allNodes where !n.isArtboard {
            let now = try #require(moving.node(n.id))
            #expect(Inspect.css(now, in: moving, tokens: .none) == Inspect.css(n, in: still, tokens: .none), "\(n.name)")
            #expect(Inspect.swiftUI(now, in: moving, tokens: .none) == Inspect.swiftUI(n, in: still, tokens: .none), "\(n.name)")
            #expect(Inspect.box(of: n.id, in: moving) == Inspect.box(of: n.id, in: still), "\(n.name)")
        }
    }

    @Test func aPrototypeGoesFromScreenToScreenAsIfNothingMoved() throws {
        // Two screens of one app: the same bar on both, a list on one and a page on the other.
        func screen(_ name: String, x: CGFloat, _ more: Node) -> Node {
            var board = Node(kind: .artboard, name: name, frame: CGRect(x: x, y: 0, width: 400, height: 300))
            board.children = [Filmed.card("Bar", CGRect(x: 0, y: 0, width: 400, height: 44), moving: false),
                              Filmed.words("Heading", "Bezzle", at: CGPoint(x: 20, y: 10), moving: false), more]
            return board
        }
        let home = screen("Home", x: 0, Filmed.card("List", CGRect(x: 20, y: 80, width: 360, height: 200), moving: false))
        let page = screen("Page", x: 500, Filmed.card("List", CGRect(x: 20, y: 80, width: 360, height: 200), moving: false))
        let way = Prototype.way(from: home, to: page, motion: nil)
        #expect(way == .push(from: CGVector(dx: 1, dy: 0), morph: false))

        // The first screen's bar is given a way of coming on in its film: the prototype, which
        // shows the design, goes on to the next as it did.
        var filmed = Filmed.filmed(home)
        filmed.children[0] = Filmed.moving(filmed.children[0])
        #expect(Prototype.same(filmed.children[0], page.children[0]))
        #expect(Prototype.way(from: filmed, to: page, motion: nil) == way)
        #expect(Prototype.way(from: page, to: filmed, motion: nil) == Prototype.way(from: page, to: home, motion: nil))
        #expect(Prototype.alike(filmed, page) == Prototype.alike(home, page))
        // A layer that really lies elsewhere on the next screen still makes the two one screen changing.
        var changed = page
        changed.children[2].frame.origin.y = 120
        #expect(Prototype.way(from: filmed, to: changed, motion: nil) == .push(from: CGVector(dx: 1, dy: 0), morph: true))
        // Within a group, and for a group that holds what moves, the same.
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        group.children = [Filmed.card("In", CGRect(x: 0, y: 0, width: 50, height: 50), moving: false)]
        var moved = group
        moved.children[0] = Filmed.moving(moved.children[0])
        #expect(Prototype.same(group, moved))

        // Played, an animated design is shown as it is designed.
        var doc = BezzleDocument()
        doc.nodes = [filmed, page]
        let bench = Bench()
        bench.step { bench.store.edit("Open") { $0.nodes = doc.nodes } }
        bench.store.prototyping = true
        bench.store.play(from: filmed.id)
        let player = try #require(bench.store.player)
        #expect(player.visit.board == filmed.id)
        bench.store.prototyping = false
        #expect(bench.store.player == nil)
    }

    @Test func whatIsBroughtInFromOtherAppsHasNoFilm() throws {
        func plain(_ doc: BezzleDocument, _ what: String) throws {
            #expect(!doc.allNodes.isEmpty, "\(what)")
            #expect(doc.allNodes.allSatisfy { $0.motion == nil && $0.film == nil }, "\(what)")
            #expect(doc.masters.allSatisfy { $0.atRest == $0 }, "\(what)")
            let file = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
            #expect(!file.contains("\"film\"") && !file.contains("\"keys\""), "\(what)")
        }
        let xd = try XDImportTests.file()
        defer { try? FileManager.default.removeItem(at: xd) }
        try plain(try XDImporter.read(xd).document, "Adobe XD")
        let figma = try FigmaImportTests.file()
        defer { try? FileManager.default.removeItem(at: figma) }
        try plain(try FigmaImporter.read(figma).document, "Figma")
        let sketch = try SketchImportTests.file()
        defer { try? FileManager.default.removeItem(at: sketch) }
        try plain(try SketchImporter.read(sketch).document, "Sketch")
        let paper = TestPSD.Layer(name: "Paper", rect: (0, 0, 30, 40), rgba: TestPSD.solid(40, 30, (250, 250, 250, 255)))
        try plain(try PhotoshopImporter.read(TestPSD.file(width: 40, height: 30, layers: [paper]), named: "Mockup").document, "Photoshop")
    }
}

extension BezzleDocument {
    /// The design changed, in one expression.
    func with(_ change: (inout BezzleDocument) -> Void) -> BezzleDocument {
        var doc = self
        change(&doc)
        return doc
    }
}
