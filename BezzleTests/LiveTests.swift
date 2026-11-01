import Testing
import AppKit
@testable import Bezzle

/// A relay of the tests' own, doing what Relay/src/worker.js does, a frame at a time when asked.
private final class TestRelay {
    final class Socket: LiveTransport {
        var onFrame: ((LiveFrame) -> Void)?
        var onLink: ((LiveLink) -> Void)?
        weak var relay: TestRelay?
        var id: UInt32 = 0
        var sent: [Data] = []

        func start() { relay?.join(self) }
        func send(_ frame: Data, droppable: Bool) {
            sent.append(frame)
            relay?.carry(frame, from: self)
        }
        func stop() { relay?.leave(self) }
    }

    private var sockets: [Socket] = []
    private var next: UInt32 = 1
    private var queue: [(Socket, LiveFrame)] = []

    func socket() -> Socket {
        let s = Socket()
        s.relay = self
        return s
    }

    func join(_ s: Socket) {
        s.id = next
        next += 1
        queue.append((s, .welcome(you: s.id, others: sockets.map(\.id))))
        for other in sockets { queue.append((other, .joined(s.id))) }
        sockets.append(s)
        s.onLink?(.live)
    }

    func leave(_ s: Socket) {
        sockets.removeAll { $0 === s }
        for other in sockets { queue.append((other, .left(s.id))) }
    }

    func carry(_ frame: Data, from s: Socket) {
        let b = [UInt8](frame)
        if b[0] == 0x10 {
            for other in sockets where other !== s { queue.append((other, .message(from: s.id, Data(b[1...])))) }
        } else if b[0] == 0x11 {
            let to = b[1..<5].reduce(0) { $0 << 8 | UInt32($1) }
            for other in sockets where other.id == to { queue.append((other, .message(from: s.id, Data(b[5...])))) }
        }
    }

    /// Passes on everything waiting, and what that makes the rooms send in turn.
    func pump() {
        var rounds = 0
        while !queue.isEmpty, rounds < 1000 {
            let (s, frame) = queue.removeFirst()
            if sockets.contains(where: { $0 === s }) { s.onFrame?(frame) }
            rounds += 1
        }
    }
}

/// One Mac with a shared design open, in a live room.
private struct Seat {
    let bench: Bench
    let session: Collaboration
    let room: LiveRoom
    let socket: TestRelay.Socket

    var store: DocumentStore { bench.store }

    init(_ name: String, zone: String, relay: TestRelay, from state: SharedDesign? = nil) {
        bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        session = Collaboration(url: bench.store.url, link: SharingLink(zone: zone, owner: nil), state: state ?? SharedDesign())
        session.replica = name
        if state != nil {
            // Opened as it is shared, as a design someone else shared is.
            var doc = session.document()
            doc.viewport = bench.store.viewport
            bench.store.showChangesFromOthers(doc)
        }
        bench.store.sharing = session
        session.attach(to: bench.store)
        socket = relay.socket()
        room = LiveRoom(collaboration: session, store: bench.store, transport: socket)
        room.name = name
        session.meet(in: room)
    }

    func close() {
        room.leave()
        try? FileManager.default.removeItem(at: store.url)
    }
}

@MainActor
struct LiveTests {
    // MARK: Sealing

    @Test func aRoomIsNamedAfterItsKeyAndNotItsZone() {
        let a = LiveKey(zone: "design-1"), b = LiveKey(zone: "design-1"), c = LiveKey(zone: "design-2")
        #expect(a.room == b.room)
        #expect(a.room != c.room)
        #expect(a.room.count == 64)
        #expect(a.room.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(!a.room.contains("design"))
    }

    @Test func onlyTheRoomsOwnCanOpenWhatIsSealed() throws {
        let key = LiveKey(zone: "design-\(UUID().uuidString)")
        let message = LiveMessage.presence(LivePresence(pointer: CGPoint(x: 4, y: 2), view: CGRect(x: 0, y: 0, width: 800, height: 600), selection: [UUID()]))
        let sealed = try #require(key.seal(message))
        #expect(key.open(sealed) == message)
        #expect(LiveKey(zone: "design-other").open(sealed) == nil)
        var tampered = sealed
        tampered[tampered.count / 2] ^= 1
        #expect(key.open(tampered) == nil)
    }

    @Test func largeMessagesArePackedSmall() throws {
        let key = LiveKey(zone: "design-big")
        let nodes = (0..<200).map { i in CanvasTests.rect("Layer \(i)", CGRect(x: i, y: i, width: 40, height: 40)) }
        let message = LiveMessage.motion(nodes)
        let sealed = try #require(key.seal(message))
        #expect(sealed.count < (try JSONEncoder().encode(message)).count / 3)
        #expect(key.open(sealed) == message)
    }

    @Test func framesReadAsTheRelayWritesThem() {
        #expect(LiveFrame.read(Data([0x01, 0, 0, 0, 7, 0, 2, 0, 0, 0, 1, 0, 0, 1, 0])) == .welcome(you: 7, others: [1, 256]))
        #expect(LiveFrame.read(Data([0x02, 0, 0, 0, 9])) == .joined(9))
        #expect(LiveFrame.read(Data([0x03, 1, 0, 0, 0])) == .left(1 << 24))
        #expect(LiveFrame.read(Data([0x04, 0, 0, 0, 3, 42, 43])) == .message(from: 3, Data([42, 43])))
        #expect(LiveFrame.read(Data([0x01, 0, 0])) == nil)
        #expect(LiveFrame.to(0x01020304, Data([9])) == Data([0x11, 1, 2, 3, 4, 9]))
        #expect(LiveFrame.toAll(Data([9])) == Data([0x10, 9]))
    }

    // MARK: Pencils, winks, flights

    @Test func everyoneInARoomHasAPencilOfTheirOwnTheSameEverywhere() {
        let people: Set<String> = ["a1", "b2", "c3", "d4", "e5", "f6"]
        let hand = Pencil.hand(to: people)
        #expect(Set(hand.values).count == people.count)
        #expect(Pencil.hand(to: people) == hand)
        // More people than pencils share, rather than go without.
        let crowd = Set((0..<12).map { "p\($0)" })
        #expect(Pencil.hand(to: crowd).count == 12)
    }

    @Test func shakingThePointerWinksAndMovingItDoesNot() {
        var shake = WinkDetector()
        var winked = false
        for i in 0..<14 {
            let x: CGFloat = i % 2 == 0 ? 100 : 150
            if shake.add(CGPoint(x: x, y: 200), at: Double(i) * 0.04) { winked = true }
        }
        #expect(winked)

        var glide = WinkDetector()
        var glided = false
        for i in 0..<60 where glide.add(CGPoint(x: CGFloat(i) * 12, y: 200 + CGFloat(i % 3)), at: Double(i) * 0.016) { glided = true }
        #expect(!glided)

        // A slow back and forth is looking for something, not winking.
        var slow = WinkDetector()
        var slowWink = false
        for i in 0..<10 where slow.add(CGPoint(x: i % 2 == 0 ? 100 : 160, y: 0), at: Double(i) * 0.4) { slowWink = true }
        #expect(!slowWink)
    }

    @Test func aWinkIsCircledByHandEachTimeALittleDifferently() {
        let a = PencilLoop.points(seed: 1, radius: 30), again = PencilLoop.points(seed: 1, radius: 30)
        let b = PencilLoop.points(seed: 2, radius: 30)
        #expect(a == again)
        #expect(a != b)
        // Round the spot, never through it, and on past where it began.
        #expect(a.allSatisfy { hypot($0.x, $0.y) > 20 && hypot($0.x, $0.y) < 45 })
        let start = atan2(a[0].y, a[0].x), end = atan2(a[a.count - 1].y, a[a.count - 1].x)
        #expect(abs(start - end) > 0.2)
        // Fine where the pencil lands and lifts, full in between.
        #expect(PencilLoop.width(at: 0, 2.6) < PencilLoop.width(at: 0.5, 2.6) / 2)
        #expect(PencilLoop.shown(at: 0.6).drawn == 1 && PencilLoop.shown(at: 1).alpha == 1)
        #expect(PencilLoop.shown(at: PencilLoop.lasts).alpha == 0)
    }

    @Test func aFlightGoesFromOneViewToTheOtherAndLiftsOffForFarOnes() {
        let from = CameraFlight.Shot(center: CGPoint(x: 0, y: 0), width: 1000)
        let to = CameraFlight.Shot(center: CGPoint(x: 20_000, y: 5_000), width: 800)
        let flight = CameraFlight(from: from, to: to)
        let start = flight.shot(at: 0), end = flight.shot(at: 1), middle = flight.shot(at: 0.5)
        #expect(abs(start.center.x) < 0.01 && abs(start.width - 1000) < 0.01)
        #expect(abs(end.center.x - 20_000) < 0.5 && abs(end.center.y - 5_000) < 0.5 && abs(end.width - 800) < 0.5)
        #expect(middle.width > 3000)
        #expect(flight.duration <= 1.5)

        let zoomOnly = CameraFlight(from: from, to: CameraFlight.Shot(center: .zero, width: 250))
        #expect(abs(zoomOnly.shot(at: 1).width - 250) < 0.01)
        #expect(zoomOnly.shot(at: 0.5).width < 1000 && zoomOnly.shot(at: 0.5).width > 250)
    }

    @Test func someonesViewShowsWholeHere() {
        let theirs = CGRect(x: 100, y: 200, width: 1600, height: 1000)
        let v = Viewport(showing: theirs, in: CGSize(width: 800, height: 800))
        let shown = CGRect(origin: v.origin, size: CGSize(width: 800 / v.zoom, height: 800 / v.zoom))
        #expect(shown.insetBy(dx: -0.01, dy: -0.01).contains(theirs))
        #expect(abs(shown.midX - theirs.midX) < 0.01 && abs(shown.midY - theirs.midY) < 0.01)
    }

    // MARK: In the room

    @Test func changesMadeOnOneMacShowOnTheOtherAtOnceWithoutICloud() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        relay.pump()
        #expect(anna.room.people.map(\.name) == ["ben"])
        #expect(ben.room.people.map(\.name) == ["anna"])
        #expect(anna.room.people[0].pencil != ben.room.people[0].pencil)

        let r = anna.bench.node("R")!.id
        anna.bench.step { anna.store.update([r], "Colour") { $0.fill.color = .black } }
        anna.room.tickForTesting()
        relay.pump()
        #expect(ben.bench.node("R")?.fill.color == .black)
        // Nothing was saved, and nothing went through iCloud.
        #expect(anna.session.link.sentUpTo == 0)

        // The same change arriving from iCloud later changes nothing.
        let before = ben.store.doc
        ben.session.receive([anna.session.state])
        #expect(ben.store.doc == before)
    }

    @Test func bothMacsChangingAtOnceKeepEverything() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        relay.pump()
        let r = anna.bench.node("R")!.id, s = anna.bench.node("S")!.id
        anna.bench.step { anna.store.update([r], "Colour") { $0.fill.color = .black } }
        ben.bench.step { ben.store.update([s], "Move") { $0.frame.origin.x = 222 } }
        ben.bench.step { ben.store.update([r], "Opacity") { $0.opacity = 0.5 } }
        anna.room.tickForTesting()
        ben.room.tickForTesting()
        relay.pump()
        for seat in [anna, ben] {
            #expect(seat.bench.node("R")?.fill.color == .black)
            #expect(seat.bench.node("R")?.opacity == 0.5)
            #expect(seat.bench.node("S")?.frame.minX == 222)
        }
        #expect(anna.store.doc.nodes == ben.store.doc.nodes)
    }

    @Test func whereSomeoneIsAndWhatTheyHoldComeAcross() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        relay.pump()
        let r = anna.bench.node("R")!.id
        anna.store.selection = [r]
        anna.store.viewport = Viewport(origin: CGPoint(x: 300, y: 40), zoom: 2)
        anna.room.tickForTesting()
        relay.pump()
        let peer = ben.room.people[0].id
        let seen = ben.room.presence[peer]
        #expect(seen?.selection == [r])
        #expect(seen?.view == anna.store.visibleCanvasRect)
    }

    @Test func aDragShowsAsItGoesAndSettlesOnItsChange() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        relay.pump()
        let r = anna.bench.node("R")!.id
        anna.store.selection = [r]
        let peer = ben.room.people[0].id

        anna.bench.step {
            anna.store.beginGesture()
            anna.store.update([r], "Move") { $0.frame.origin.x = 70 }
            anna.room.tickForTesting()
            relay.pump()
            // Moving on Ben's canvas, not yet changed in his design.
            #expect(ben.room.motion[peer]?.nodes[r]?.frame.minX == 70)
            #expect(ben.bench.node("R")?.frame.minX == 10)
            anna.store.update([r], "Move") { $0.frame.origin.x = 90 }
            anna.room.tickForTesting()
            relay.pump()
            #expect(ben.room.motion[peer]?.nodes[r]?.frame.minX == 90)
            anna.store.endGesture("Move")
        }
        anna.room.tickForTesting()
        relay.pump()
        #expect(ben.bench.node("R")?.frame.minX == 90)
        ben.room.settle(ben.store.doc, at: CACurrentMediaTime())
        #expect(ben.room.motion[peer] == nil)
    }

    @Test func someoneComingLaterGetsWhatICloudDoesNotHaveYet() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        defer { anna.close() }
        relay.pump()
        let shared = anna.session.state
        let r = anna.bench.node("R")!.id
        // Made while alone in the room, and not sent to iCloud.
        anna.bench.step { anna.store.update([r], "Rename") { $0.name = "Hero" } }
        anna.store.save()

        let ben = Seat("ben", zone: zone, relay: relay, from: shared)
        defer { ben.close() }
        #expect(ben.bench.node("Hero") == nil)
        relay.pump()
        #expect(ben.bench.node("Hero") != nil)
    }

    @Test func someoneLeavingGoesFromTheRoom() {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close() }
        relay.pump()
        #expect(anna.room.people.count == 1)
        ben.close()
        relay.pump()
        #expect(anna.room.people.isEmpty)
        #expect(!anna.room.hasOthers)
    }

    // MARK: Pictures on their way

    /// A photo of `size`, a gradient so that its glimpse is something, as a PNG.
    private static func photo(_ size: CGSize) -> Data {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors, locations: nil)!, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// Makes the seat's design a package, with these pictures in it.
    private static func package(_ seat: Seat, pictures: [String: Data]) throws {
        let images = seat.store.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for (name, data) in pictures { try data.write(to: images.appendingPathComponent(name)) }
        seat.store.becamePackage()
    }

    /// Passes frames on until `done`, giving the glimpses made away from the main thread time to be.
    private static func pump(_ relay: TestRelay, until done: () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            relay.pump()
            try await Task.sleep(for: .milliseconds(10))
        }
        relay.pump()
    }

    @Test func aGlimpseIsAKilobyteAndStandsInSoftAndWhole() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glimpse-\(UUID().uuidString).png")
        try Self.photo(CGSize(width: 1600, height: 900)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let glimpse = try #require(LiveGlimpse.of(url, name: "p.png"))
        #expect(glimpse.jpeg.count < 2_000)
        let standIn = try #require(glimpse.standIn())
        #expect(max(standIn.width, standIn.height) >= 300)
        #expect(abs(Double(standIn.width) / Double(standIn.height) - 16.0 / 9) < 0.15)
    }

    @Test func aPicturePlacedShowsAtOnceElsewhereAndComesIntoFocusWhenItArrives() async throws {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        let name = "photo-\(UUID().uuidString).png", data = Self.photo(CGSize(width: 800, height: 600))
        try Self.package(anna, pictures: [name: data])
        try Self.package(ben, pictures: [:])
        relay.pump()

        let r = anna.bench.node("R")!.id
        anna.bench.step {
            anna.store.update([r], "Picture") { $0.fill.on = true; $0.fill.image = ImageFill(asset: name, size: CGSize(width: 800, height: 600)) }
        }
        anna.room.tickForTesting()
        try await Self.pump(relay) { ben.store.assets.standIn(of: name) != nil }
        #expect(ben.bench.node("R")?.fill.image?.asset == name)
        let standIn = try #require(ben.store.assets.standIn(of: name))
        // Drawn in its place while the picture is not here.
        #expect(ben.store.assets.image(name, pixels: 400) === standIn)

        // iCloud brings it.
        try data.write(to: ben.store.url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent(name))
        ben.room.tickForTesting()
        ben.store.pictureArrived(name)
        ben.room.arrived(name)
        #expect(ben.room.developing[name]?.arrived != nil)
        #expect(ben.store.assets.image(name, pixels: 400) !== standIn)
        ben.room.developed(before: CACurrentMediaTime() + 5)
        #expect(ben.room.developing[name] == nil)
    }

    @Test func someoneMissingAPictureAsksTheRoomForAGlimpse() async throws {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let name = "old-\(UUID().uuidString).png", data = Self.photo(CGSize(width: 640, height: 640))
        let anna = Seat("anna", zone: zone, relay: relay)
        try Self.package(anna, pictures: [name: data])
        let r = anna.bench.node("R")!.id
        // Placed before anyone else was here, so nobody was sent a glimpse.
        anna.bench.step {
            anna.store.update([r], "Picture") { $0.fill.on = true; $0.fill.image = ImageFill(asset: name, size: CGSize(width: 640, height: 640)) }
        }
        anna.store.save()
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        try Self.package(ben, pictures: [:])
        relay.pump()
        // Drawing looks for it and does not find it.
        #expect(ben.store.assets.image(name, pixels: 200) == nil)
        ben.room.tickForTesting()
        #expect(ben.room.developing[name] != nil)
        try await Self.pump(relay) { ben.store.assets.standIn(of: name) != nil }
        #expect(ben.store.assets.standIn(of: name) != nil)
    }

    @Test func aMessageFromOutsideTheRoomIsIgnored() throws {
        let relay = TestRelay(), zone = "design-test-\(UUID().uuidString)"
        let anna = Seat("anna", zone: zone, relay: relay)
        let ben = Seat("ben", zone: zone, relay: relay, from: anna.session.state)
        defer { anna.close(); ben.close() }
        relay.pump()
        let before = ben.store.doc
        var stranger = SharedDesign()
        stranger.clock = Stamp(time: .max / 2, by: "mallory")
        let sealed = try #require(LiveKey(zone: "design-elsewhere").seal(.changes(stranger)))
        ben.room.receiveForTesting(.message(from: 99, sealed))
        #expect(ben.store.doc == before)
    }
}
