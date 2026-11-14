import Testing
import CryptoKit
import AppKit
@testable import Bezzle

/// A relay of the test's own, doing what Relay/src/worker.js does, a frame at a time when asked.
private final class WatchedRelay {
    final class Socket: LiveTransport {
        var onFrame: ((LiveFrame) -> Void)?
        var onLink: ((LiveLink) -> Void)?
        weak var relay: WatchedRelay?
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

    func pump() {
        var rounds = 0
        while !queue.isEmpty, rounds < 1000 {
            let (s, frame) = queue.removeFirst()
            if sockets.contains(where: { $0 === s }) { s.onFrame?(frame) }
            rounds += 1
        }
    }
}

/// One Mac with the shared design open, in its live room.
@MainActor
private struct Desk {
    let bench: Bench
    let session: Collaboration
    let room: LiveRoom
    let socket: WatchedRelay.Socket
    let replica: String

    var store: DocumentStore { bench.store }

    init(_ replica: String, name: String, keys: ShareKeys, relay: WatchedRelay, from state: SharedDesign? = nil) {
        self.replica = replica
        var turned = CanvasTests.rect("S", CGRect(x: 100, y: 20, width: 80, height: 40))
        turned.rotation = 0.5
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 200, y: 120, width: 120, height: 90))
        group.children = [CanvasTests.rect("T", CGRect(x: 210, y: 130, width: 60, height: 30))]
        bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)), turned,
                              Node(kind: .line, name: "L", frame: CGRect(x: 30, y: 150, width: 120, height: 60)), group])
        session = Collaboration(url: bench.store.url, state: state ?? SharedDesign(), keys: keys)
        session.replica = replica
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

/// What Macs say in a design's live room to one who only watches, as the browser's page does
/// (Web/site/live.mjs), and what each Mac shows of the other meanwhile: for the browser's core to
/// read the same messages and show the same people (Web/tools/live.mjs --truth).
///
/// Two real rooms (`LiveRoom`) and a watcher, on a relay of the test's own. The watcher never says
/// who it is. It says only that it is still there, in the very bytes the page sends. The test
/// holds that a Mac alone with it tells it where it is, and that no Mac counts it among the people.
/// Written to `<WEB_TRUTH_OUT>/live/live.json`.
@MainActor
struct LiveTruthTests {
    /// What the page says to say it still watches (site/share.mjs, STILL_THERE).
    static let stillThere = Data([0]) + Data(#"{"want":{"_0":[]}}"#.utf8)

    @Test func dumpTruth() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth").appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let keys = testKeys("live-truth-\(UUID().uuidString)")
        let relay = WatchedRelay()
        var steps: [[String: Any]] = []

        // The watcher: everything it is sent, as the relay frames it.
        let watcher = relay.socket()
        var events: [[String: Any]] = []
        watcher.onFrame = { frame in
            switch frame {
            case .welcome(let you, let others): events.append(["kind": "welcome", "you": Int(you), "others": others.map(Int.init)])
            case .joined(let peer): events.append(["kind": "joined", "peer": Int(peer)])
            case .left(let peer): events.append(["kind": "left", "peer": Int(peer)])
            case .message(let from, let sealed):
                guard let plain = keys.open(sealed, about: "live"), let message = LiveMessage(packed: plain) else {
                    Issue.record("The watcher could not open what it was sent")
                    return
                }
                events.append(["kind": "message", "peer": Int(from), "plain": plain.base64EncodedString(), "packed": plain.first == 1, "says": Self.kind(message)])
            case .records, .gone: break
            }
        }

        let anna = Desk("anna", name: "Anna", keys: keys, relay: relay)
        defer { anna.close() }
        relay.pump()
        // The design as it is shared, packed as a record of the room is: what the page opens.
        let design = try (JSONEncoder().encode(anna.session.state) as NSData).compressed(using: .lzfse) as Data
        var desks = [anna]

        /// Everything the watcher was sent since the step before, and what each Mac shows of the others now.
        func step(_ name: String, document: Bool = false, wink: Bool = false) throws {
            relay.pump()
            var people: [[String: Any]] = []
            for desk in desks {
                // As another Mac in the room shows them; alone with the watcher, nobody does.
                guard let other = desks.first(where: { $0.replica != desk.replica }),
                      let person = other.room.people.first(where: { $0.replica == desk.replica }) else {
                    people.append(["replica": desk.replica, "name": desk.room.name, "color": Self.color(Pencil.hand(to: Set(desks.map(\.replica)))[desk.replica]!)])
                    continue
                }
                var p: [String: Any] = ["replica": person.replica, "name": person.name, "initial": person.initial, "color": Self.color(person.pencil)]
                if let zone = person.timeZone { p["timeZone"] = zone }
                if let presence = other.room.presence[person.id] {
                    p["doing"] = presence.doing.rawValue
                    p["away"] = presence.away
                    p["tool"] = presence.doing == .typing ? "text" : presence.tool
                    if let at = presence.pointer { p["pointer"] = [Double(at.x), Double(at.y)] }
                    p["view"] = [presence.view.minX, presence.view.minY, presence.view.width, presence.view.height].map { Double($0) }
                    p["holds"] = presence.selection.compactMap { Self.outline(of: $0, in: other.store.doc) }
                }
                people.append(p)
            }
            var said: [String: Any] = ["name": name, "events": events, "people": people]
            if document, let other = desks.last {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                said["document"] = String(decoding: try encoder.encode(other.session.document()), as: UTF8.self)
            }
            if wink, let other = desks.last, let w = other.room.winks.last, let by = other.room.people.first(where: { $0.id == w.by }) {
                said["wink"] = ["replica": by.replica, "at": [Double(w.at.x), Double(w.at.y)]]
            }
            steps.append(said)
            events = []
        }

        /// What the watcher was told in a step, by kind.
        func said(_ step: Int) -> [String] { (steps[step]["events"] as? [[String: Any]] ?? []).compactMap { $0["says"] as? String } }

        // A Mac alone, and someone comes to watch: it is told who the Mac is and where.
        watcher.start()
        try step("someone comes to watch a Mac that is alone")
        #expect(anna.room.people.isEmpty)
        #expect(Set(said(0)).isSuperset(of: ["hello", "presence"]))

        // What the Mac does next is said to the watcher alone, as to anyone in the room.
        let r = try #require(anna.bench.node("R")).id
        anna.store.selection = [r]
        anna.store.tool = .pen
        anna.room.tickForTesting()
        try step("the Mac takes a layer in hand and another tool")
        #expect(said(1).contains("presence"))

        // A second Mac comes: each shows the other, in a pencil the watcher works out the same.
        let ben = Desk("elodie", name: "Élodie", keys: keys, relay: relay, from: anna.session.state)
        defer { ben.close() }
        desks.append(ben)
        relay.pump()
        anna.room.tickForTesting()
        ben.room.tickForTesting()
        try step("a second Mac comes in")
        #expect(anna.room.people.map(\.name) == ["Élodie"])
        #expect(ben.room.people.map(\.name) == ["Anna"])

        // What each holds: a turned layer and one in a group, a line.
        ben.store.selection = [try #require(ben.bench.node("S")).id, try #require(ben.bench.node("T")).id]
        ben.store.viewport = Viewport(origin: CGPoint(x: 300, y: 40), zoom: 2)
        anna.store.selection = [try #require(anna.bench.node("L")).id]
        anna.room.tickForTesting()
        ben.room.tickForTesting()
        try step("each holds something else")

        // Where a hand is, at work, and a wink: said as a Mac says them, by the first Mac's socket.
        let key = LiveKey(keys)
        var presence = LivePresence(view: CGRect(x: 0, y: 0, width: 1200, height: 800))
        presence.pointer = CGPoint(x: 250.5, y: 180.25)
        presence.selection = [r]
        presence.tool = "rectangle"
        presence.doing = .drawing
        anna.socket.send(LiveFrame.toAll(try #require(key.seal(.presence(presence)))), droppable: false)
        try step("a hand over the first artboard, drawing")
        presence.pointer = CGPoint(x: 700, y: 260)
        presence.selection = []
        presence.tool = "select"
        presence.doing = .typing
        anna.socket.send(LiveFrame.toAll(try #require(key.seal(.presence(presence)))), droppable: false)
        anna.socket.send(LiveFrame.toAll(try #require(key.seal(.wink(CGPoint(x: 720, y: 300))))), droppable: false)
        try step("the hand goes to the second artboard, typing, and winks", wink: true)

        // A change, as it is made: small, and one large enough to travel packed.
        anna.bench.step { anna.store.update([r], "Move") { $0.frame.origin.x = 70; $0.fill.color = .black } }
        anna.room.tickForTesting()
        try step("a layer is moved and coloured", document: true)
        anna.bench.step { anna.store.update([r], "Rename") { $0.name = String(repeating: "A long name. ", count: 400) } }
        anna.room.tickForTesting()
        try step("a change large enough to travel packed", document: true)
        #expect((steps.last?["events"] as? [[String: Any]])?.contains { $0["says"] as? String == "changes" && $0["packed"] as? Bool == true } == true)

        // A drag: shown moving on the Macs, and to the watcher once it ends.
        let s = try #require(ben.bench.node("S")).id
        ben.store.selection = [s]
        ben.bench.step {
            ben.store.beginGesture()
            ben.store.update([s], "Move") { $0.frame.origin.y = 90 }
            ben.room.tickForTesting()
            relay.pump()
            ben.store.endGesture("Move")
        }
        ben.room.tickForTesting()
        try step("a layer is dragged", document: true)

        // The watcher says it is still there: heard, asked who it is, and still nobody's person.
        let before = watcher.sent.count
        watcher.send(LiveFrame.toAll(try #require(keys.seal(Self.stillThere, about: "live"))), droppable: false)
        try step("the watcher says it is still there")
        #expect(watcher.sent.count == before + 1)
        #expect(anna.room.people.map(\.name) == ["Élodie"])
        #expect(ben.room.people.map(\.name) == ["Anna"])
        #expect(said(steps.count - 1) == ["hello", "hello"])

        // One leaves.
        ben.room.leave()
        desks.removeLast()
        try step("the second Mac leaves")

        // What all work out alike: pencils, and the loop a pencil draws.
        let rooms: [[String]] = [["anna"], ["anna", "elodie"], ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
                                 ["mac-7f3a", "web-19c2", "win-88e1"], (0..<8).map { "replica\($0)" }]
        let pencils = rooms.map { room -> [String: Any] in
            let hand = Pencil.hand(to: Set(room))
            return ["replicas": room, "colors": Dictionary(uniqueKeysWithValues: room.map { ($0, Self.color(hand[$0]!)) })]
        }
        let loops = [UInt64(1), 42, 1_763_112_000_123, UInt64.max - 7].map { seed -> [String: Any] in
            let points = PencilLoop.points(seed: seed, radius: 30)
            return ["seed": String(seed), "points": points.flatMap { [Double($0.x), Double($0.y)] },
                    "widths": points.indices.map { Double(PencilLoop.width(at: Double($0) / Double(points.count - 1), 2.6)) }]
        }
        let shown = stride(from: 0.0, through: PencilLoop.lasts, by: 1.0 / 60).map { t in [PencilLoop.shown(at: t).drawn, PencilLoop.shown(at: t).alpha] }

        let truth: [String: Any] = ["design": design.base64EncodedString(), "watcher": Int(watcher.id), "steps": steps,
                                    "stillThere": Self.stillThere.base64EncodedString(), "pencils": pencils, "loops": loops, "shown": shown]
        try JSONSerialization.data(withJSONObject: truth, options: [.sortedKeys]).write(to: out.appendingPathComponent("live.json"))
    }

    private static func kind(_ message: LiveMessage) -> String {
        switch message {
        case .hello: "hello"
        case .presence: "presence"
        case .motion: "motion"
        case .settle: "settle"
        case .changes: "changes"
        case .wink: "wink"
        case .glimpses: "glimpses"
        case .want: "want"
        case .version: "version"
        }
    }

    private static func color(_ pencil: Pencil) -> [Double] { [Double(pencil.rgb.r), Double(pencil.rgb.g), Double(pencil.rgb.b)] }

    /// A layer's outline on the canvas, as `LiveMarks` outlines what someone holds, before its view.
    private static func outline(of id: UUID, in doc: BezzleDocument) -> [Double]? {
        guard let node = doc.node(id) else { return nil }
        let eye = doc.eye(forParentOf: id)
        let points: [CGPoint]
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node, eye: eye) }
        } else {
            points = Perspective.corners(of: node, eye: eye)
        }
        return points.map { doc.shown($0, inParentOf: id) }.flatMap { [Double($0.x), Double($0.y)] }
    }
}
