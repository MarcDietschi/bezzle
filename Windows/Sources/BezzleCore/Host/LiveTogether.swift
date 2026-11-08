import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Working on a shared design at the same moment as others, on Windows: from Bezzle/Store/
// LiveSocket.swift and the protocol part of LiveRoom.swift. Everything said in the room is sealed
// with the shared Live.swift's LiveKey (Host/Sealing.swift on Windows), so a Mac, Windows and a
// browser in one room hear each other: who is there (hello), where they are and what they do
// (presence), what they are dragging (motion, settle), what they changed a moment ago (changes,
// merged as everything is), winks, and the relay saying its records moved on or the room is gone.
// What the others' pencils, light pools and winks look like on the canvas is the app's to draw,
// from `people`, `presence`, `motion` and `winks` here.

/// How a room's connection to the relay is (the Mac's LiveLink).
public enum LiveLinkState: Equatable, Sendable {
    case connecting
    case live
    /// Lost; trying again in a moment.
    case away
}

/// A room's WebSocket to the relay (the Mac's LiveSocket): it pings, notices when nothing comes
/// back, and tries again a little later each time.
final class LiveWebSocket {
    var onFrame: ((LiveFrame) -> Void)?
    var onLink: ((LiveLinkState) -> Void)?

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    /// Counts connections, so what an old one says late is not taken for the new one's.
    private var generation = 0
    private var attempt = 0
    private var stopped = true
    private var finished = false
    private var lastHeard = Date()
    private var inFlight = 0
    private var pinger: Timer?
    private var retry: Timer?

    init(room: String, read: String, relay: URL) {
        var parts = URLComponents(url: relay.appendingPathComponent("v2").appendingPathComponent(room).appendingPathComponent("live"),
                                  resolvingAgainstBaseURL: false)!
        if parts.scheme == "https" { parts.scheme = "wss" } else if parts.scheme == "http" { parts.scheme = "ws" }
        parts.queryItems = [URLQueryItem(name: "read", value: read)]
        url = parts.url!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func start() {
        guard stopped, !finished else { return }
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        finished = true
        pinger?.invalidate()
        retry?.invalidate()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    private func connect() {
        guard !stopped else { return }
        generation += 1
        let generation = generation
        onLink?(.connecting)
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "X-Bezzle-Live")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.task = task
        inFlight = 0
        lastHeard = Date()
        task.resume()
        listen(task, generation)
        pinger?.invalidate()
        pinger = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping(generation) }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask, _ generation: Int) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    guard let self, self.generation == generation else { return }
                    self.reconnect(now: false)
                    return
                }
                guard let self, self.generation == generation else { return }
                self.lastHeard = Date()
                switch message {
                case .data(let data):
                    guard let frame = LiveFrame.read(data) else { continue }
                    if case .welcome = frame {
                        self.attempt = 0
                        self.onLink?(.live)
                    }
                    self.onFrame?(frame)
                default:
                    break
                }
            }
        }
    }

    private func ping(_ generation: Int) {
        guard generation == self.generation, let task else { return }
        // The relay answers every ping: nothing for a while means the connection is gone.
        if Date().timeIntervalSince(lastHeard) > 25 {
            reconnect(now: true)
            return
        }
        task.send(.string("ping")) { _ in }
    }

    func send(_ frame: Data, droppable: Bool) {
        guard let task, !stopped else { return }
        if droppable && inFlight > 6 { return }
        inFlight += 1
        let generation = generation
        task.send(.data(frame)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.inFlight = max(0, self.inFlight - 1)
            }
        }
    }

    private func reconnect(now: Bool) {
        guard !stopped else { return }
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pinger?.invalidate()
        onLink?(.away)
        retry?.invalidate()
        let delay = now ? 0.1 : min(15, 0.5 * pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        attempt += 1
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
    }
}

extension WindowsCore {
    /// Someone else in the design's live room, as their hello says (the Mac's LiveRoom.Person).
    public struct LivePerson: Equatable, Sendable {
        /// Their place in the room, for as long as they are connected.
        public let id: UInt32
        public var replica: String
        public var name: String
        public var timeZone: String?
        /// Their pencil, as sRGB, the same on every computer in the room.
        public var pencil: UInt32
        public var doing: String = "looking"
        public var away = false
        public var initial: String { name.first.map { String($0).uppercased() } ?? "•" }
    }

    /// Where someone else is and what they do, in canvas points (the shared LivePresence).
    public struct LiveSeen: Equatable, Sendable {
        public var pointer: CGPoint?
        public var view: CGRect
        public var selection: [UUID]
        public var tool: String
        public var doing: String
        public var away: Bool
    }

    /// The open design's live room, while it has one.
    public static var live: LiveTogether? { sharing?.live }
}

/// A shared design's live room on Windows: the protocol part of the Mac's LiveRoom.
public final class LiveTogether {
    public private(set) var people: [WindowsCore.LivePerson] = []
    public private(set) var link: LiveLinkState = .connecting
    /// Where each is and what they do; what they drag, as it is this moment; their winks.
    public private(set) var presence: [UInt32: WindowsCore.LiveSeen] = [:]
    /// What each is dragging, as it is this moment; once they let go, kept until the design
    /// shows what they left it as (`settled`, the Mac's Motion).
    private(set) var motion: [UInt32: (nodes: [UUID: Node], settled: Double?)] = [:]
    /// Pointers shaken, on the canvas, by whom (`selfID` for this computer's own), and when.
    public private(set) var winks: [(by: UInt32, at: CGPoint, time: Double)] = []
    /// What others just changed, lighting up for a moment in their pencil (the Mac's glows).
    public private(set) var glows: [(id: UUID, pencil: UInt32, time: Double)] = []
    private let opened = WindowsCore.now
    /// Something the canvas or the bar shows changed: someone came, moved, winked, left.
    public var changed: () -> Void = {}

    private weak var session: SharedSession?
    private let key: LiveKey
    private let socket: LiveWebSocket
    private var me: UInt32?
    private var roomPeers: Set<UInt32> = []
    private var asked: [UInt32: Date] = [:]
    private var hellos: [UInt32: LiveHello] = [:]
    private var heard: [UInt32: Date] = [:]
    private var pencils: [String: Pencil] = [:]
    private var timer: Timer?
    private var sentPresence: LivePresence?
    private var sentPresenceAt = Date.distantPast
    private var relayedUpTo: Int64 = 0
    /// Where this computer is and what it does, as the app last said.
    private var mine = LivePresence(pointer: nil, view: .zero)
    /// This computer's own winks, among the others' (the Mac's LiveRoom.selfID).
    public static let selfID: UInt32 = 0
    private var detector = WinkDetector()
    /// Who this computer goes along with, its canvas flying to where they look and staying there.
    public internal(set) var following: UInt32?
    /// What the canvas draws of the others, eased from frame to frame (Host/LiveScene.swift).
    let marks = LiveMarks()
    let camera = LiveCamera()
    /// What was dragged here last, sent as it moved; the design as last taken in.
    private var sentMotion: [Node] = []
    private var wasInGesture = false
    private var takenVersion = -1
    /// Pictures this computer has offered glimpses of, or had before the room was opened.
    private var offered: Set<String> = []
    /// Pictures this computer has asked the room for, and those it found it has.
    private var wanted: Set<String> = []
    private var present: Set<String> = []
    private var lookedForPictures = 0.0

    init(session: SharedSession, keys: ShareKeys, relay: URL) {
        self.session = session
        key = LiveKey(keys)
        socket = LiveWebSocket(room: keys.room, read: keys.readToken, relay: relay)
        relayedUpTo = session.changedUpTo
        offered = session.shownPictures
        socket.onFrame = { [weak self] frame in MainActor.assumeIsolated { self?.handle(frame) } }
        socket.onLink = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.link = state
                if state != .live { self.everyoneLeft() }
                self.changed()
            }
        }
        socket.start()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func leave() {
        timer?.invalidate()
        timer = nil
        socket.stop()
        everyoneLeft()
    }

    /// Whether the relay says anyone else is in the room: then this computer keeps saying where it
    /// is, and sends what it changes.
    private var inCompany: Bool { link == .live && !roomPeers.isEmpty }

    private var hello: LiveHello {
        LiveHello(replica: session?.replica ?? WindowsCore.replica, name: WindowsCore.myName, timeZone: TimeZone.current.identifier)
    }

    // MARK: What the app says

    /// Where this computer's pointer is on the canvas (nil off it), what its canvas shows, what is
    /// picked, which tool is out, and what it is doing ("looking", "moving", "typing", "drawing").
    public func say(pointer: CGPoint?, view: CGRect, selection: [UUID], tool: String, doing: String, away: Bool = false) {
        mine = LivePresence(pointer: pointer, view: view, selection: Array(selection.prefix(64)), tool: tool,
                            doing: LivePresence.Doing(rawValue: doing) ?? .looking, away: away)
    }

    /// Where this computer's pointer is on the canvas, nil off it, as it moves, with where it is
    /// in the window (`screen`) at `time`: a shake of it is a wink, circled here and sent.
    public func pointerMoved(to p: CGPoint?, screen: CGPoint, at time: Double) {
        mine.pointer = p
        guard let p else { return }
        if detector.add(screen, at: time) {
            winks.append((Self.selfID, p, WindowsCore.now))
            send(.wink(p))
            changed()
        }
    }

    /// Where this computer's pointer is on the canvas, as last said.
    var myPointer: CGPoint? { mine.pointer }

    /// The layers being dragged here, as they are this moment, and when the drag ends, as it left them.
    public func moving(_ ids: [UUID]) {
        guard inCompany, let doc = WindowsCore.design else { return }
        send(.motion(ids.compactMap { doc.node($0).map(Self.alone) }), droppable: true)
    }

    public func settled(_ ids: [UUID]) {
        guard inCompany, let doc = WindowsCore.design else { return }
        send(.settle(ids.compactMap { doc.node($0).map(Self.alone) }))
    }

    /// Others' changes have just been shown: each layer lights up for a moment in its maker's
    /// colour; not for a whole design arriving, as it does on opening.
    func glow(_ authors: [UUID: String]) {
        guard !authors.isEmpty, authors.count <= 400, WindowsCore.now - opened > 2 else { return }
        let now = WindowsCore.now
        let mine = session?.replica ?? WindowsCore.replica
        for (id, replica) in authors where replica != mine { glows.append((id, pencil(of: replica), now)) }
        changed()
    }

    /// A shake of the pointer at a canvas point, to be looked at.
    public func wink(at p: CGPoint) {
        winks.append((Self.selfID, p, WindowsCore.now))
        send(.wink(p))
    }

    static func alone(_ node: Node) -> Node {
        var n = node
        n.children = []
        return n
    }

    /// The selected layers as they are this moment of a drag, without what they hold, and what
    /// is in them while that is not much (the Mac's movingNodes).
    private func movingNodes() -> [Node] {
        guard let doc = WindowsCore.design else { return [] }
        var out: [Node] = []
        for id in mine.selection.prefix(32) {
            guard let node = doc.node(id) else { continue }
            out.append(Self.alone(node))
            func inside(_ n: Node) {
                for c in n.children where out.count < 48 {
                    out.append(Self.alone(c))
                    inside(c)
                }
            }
            if !node.isArtboard { inside(node) }
        }
        return out
    }

    /// The pencil of someone in the room by their replica, as sRGB.
    public func pencil(of replica: String) -> UInt32 {
        let p = pencils[replica] ?? Pencil.preferred(replica)
        let (r, g, b) = p.rgb
        return UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
    }

    // MARK: Sending

    private func send(_ message: LiveMessage, to peer: UInt32? = nil, droppable: Bool = false) {
        guard link == .live, let sealed = key.seal(message) else { return }
        // Too much for the relay at once: the room's records carry it, as they carry everything.
        guard sealed.count < 900_000 else { return }
        socket.send(peer.map { LiveFrame.to($0, sealed) } ?? LiveFrame.toAll(sealed), droppable: droppable)
    }

    /// What was changed here and not yet sent to the room goes now.
    func relay() {
        guard let session else { return }
        let upTo = session.changedUpTo
        guard upTo > relayedUpTo else { return }
        if inCompany {
            let changes = session.state.changes(by: session.replica, after: relayedUpTo)
            if !changes.isEmpty { send(.changes(changes)) }
        }
        relayedUpTo = upTo
    }

    /// What this computer changed that the room's records or the folder do not have yet, for
    /// someone who has just come in.
    private func catchUp(_ peer: UInt32?) {
        guard let session else { return }
        let changes = session.state.changes(by: session.replica, after: session.sentUpTo)
        if !changes.isEmpty { send(.changes(changes), to: peer) }
    }

    /// How many times the relay said its records moved on.
    public private(set) var recordsHeard = 0

    /// Says where this computer is now, if that changed, and lets go of the silent: thirty times a
    /// second from its own timer, or by hand where no run loop turns (the headless checks).
    func tick() {
        dropSilent()
        let inGesture = Editing.gestureStart != nil
        defer { wasInGesture = inGesture }
        if WindowsCore.now - lookedForPictures > 0.5 {
            lookedForPictures = WindowsCore.now
            lookForPictures()
        }
        guard inCompany else {
            takenVersion = WindowsCore.designVersion
            return
        }
        // Changes made here go as soon as they are made, rather than when the design is next
        // saved; a drag's, once it ends (the Mac's LiveRoom.tick).
        // Only the design in front is the one the core's design is: another tab's room waits.
        guard let session, WindowsCore.sharing === session else { return }
        if !inGesture, WindowsCore.designVersion != takenVersion, let doc = WindowsCore.previewBase ?? WindowsCore.design {
            takenVersion = WindowsCore.designVersion
            var shared = doc
            shared.viewport = nil
            session.takeIn(shared)
        }
        if inGesture {
            let nodes = movingNodes()
            if nodes != sentMotion {
                sentMotion = nodes
                send(.motion(nodes), droppable: true)
            }
        } else if wasInGesture {
            send(.settle(sentMotion.compactMap { n in WindowsCore.design?.node(n.id).map(Self.alone) }))
            sentMotion = []
        }
        let now = Date()
        if mine != sentPresence || now.timeIntervalSince(sentPresenceAt) > 4 {
            send(.presence(mine), droppable: mine == sentPresence)
            sentPresence = mine
            sentPresenceAt = now
        }
    }

    // MARK: Hearing

    func handle(_ frame: LiveFrame) {
        switch frame {
        case .welcome(let you, let others):
            me = you
            link = .live
            roomPeers = Set(others)
            for peer in others { heard[peer] = Date() }
            guard !others.isEmpty else { return }
            send(.hello(hello))
            sentPresence = nil
            catchUp(nil)
        case .joined(let peer):
            roomPeers.insert(peer)
            heard[peer] = Date()
            send(.hello(hello), to: peer)
            send(.presence(mine), to: peer)
            catchUp(peer)
        case .left(let peer):
            remove(peer)
        case .records(let upTo):
            recordsHeard += 1
            session?.cloud?.recordsChanged(upTo: upTo)
        case .gone:
            session?.cloud?.gone()
        case .message(let from, let sealed):
            guard let message = key.open(sealed) else {
                NSLog("Bezzle: a live message could not be opened")
                return
            }
            heard[from] = Date()
            roomPeers.insert(from)
            // Heard from, but not known, as after either was away a while: asked who they are.
            if hellos[from] == nil {
                if case .hello = message {} else { askWho(from) }
            }
            take(message, from: from)
        }
        changed()
    }

    private func take(_ message: LiveMessage, from peer: UInt32) {
        switch message {
        case .hello(var hello):
            // The same computer come back on a new connection: its old place goes.
            for (other, h) in hellos where other != peer && h.replica == hello.replica { remove(other) }
            let first = hellos[peer] == nil
            if hello.ask == true { send(.hello(self.hello), to: peer) }
            hello.ask = nil
            hellos[peer] = hello
            asked[peer] = nil
            handOutPencils()
            // Whoever comes in hears straight away where this one is.
            if first { send(.presence(mine), to: peer) }
            marks.arrived(peer)
        case .presence(let p):
            presence[peer] = WindowsCore.LiveSeen(pointer: p.pointer, view: p.view, selection: p.selection, tool: p.tool, doing: p.doing.rawValue, away: p.away)
            updatePerson(peer) { $0.doing = p.doing.rawValue; $0.away = p.away }
        case .motion(let nodes):
            motion[peer] = (Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), nil)
        case .settle(let nodes):
            if nodes.isEmpty { motion[peer] = nil } else {
                motion[peer] = (Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), WindowsCore.now)
            }
        case .changes(let changes):
            guard let session else { return }
            // What was done here is taken in first, from the design in front only when it is this one.
            session.receive([changes], from: .relay, current: WindowsCore.sharing === session ? WindowsCore.previewBase ?? WindowsCore.design : nil)
            session.persist()
        case .wink(let at):
            winks.append((peer, at, WindowsCore.now))
        case .glimpses(let glimpses):
            take(glimpses)
        case .want(let names):
            sendGlimpses(of: names, to: peer)
        case .version(let version, let data):
            if let data, WindowsCore.sharing === session { WindowsCore.versions.arrived(version, data: data) }
        }
    }

    private func askWho(_ peer: UInt32) {
        guard Date().timeIntervalSince(asked[peer] ?? .distantPast) > 3 else { return }
        asked[peer] = Date()
        var mine = hello
        mine.ask = true
        send(.hello(mine), to: peer)
    }

    private func handOutPencils() {
        pencils = Pencil.hand(to: Set(hellos.values.map(\.replica)).union([hello.replica]))
        var next: [WindowsCore.LivePerson] = []
        for (peer, h) in hellos.sorted(by: { $0.key < $1.key }) {
            var person = people.first { $0.id == peer }
                ?? WindowsCore.LivePerson(id: peer, replica: h.replica, name: h.name, timeZone: h.timeZone, pencil: pencil(of: h.replica))
            person.replica = h.replica
            person.name = h.name
            person.timeZone = h.timeZone
            person.pencil = pencil(of: h.replica)
            if let p = presence[peer] { person.doing = p.doing; person.away = p.away }
            next.append(person)
        }
        // In the order they came, as on the Mac.
        next.sort { a, b in
            let ia = people.firstIndex { $0.id == a.id } ?? Int.max, ib = people.firstIndex { $0.id == b.id } ?? Int.max
            return ia != ib ? ia < ib : a.id < b.id
        }
        people = next
    }

    private func updatePerson(_ peer: UInt32, _ change: (inout WindowsCore.LivePerson) -> Void) {
        guard let i = people.firstIndex(where: { $0.id == peer }) else { return }
        change(&people[i])
    }

    private func remove(_ peer: UInt32) {
        roomPeers.remove(peer)
        asked[peer] = nil
        heard[peer] = nil
        presence[peer] = nil
        motion[peer] = nil
        guard hellos.removeValue(forKey: peer) != nil else { return }
        if following == peer { stopFollowing() }
        handOutPencils()
    }

    /// Someone not heard from for a while shows as away; only after long enough is taken to have gone.
    private func dropSilent() {
        let now = Date()
        for (peer, at) in heard {
            let quiet = now.timeIntervalSince(at)
            if quiet > 300 {
                remove(peer)
                changed()
            } else if quiet > 25, presence[peer]?.away == false {
                presence[peer]?.away = true
                updatePerson(peer) { $0.away = true }
                changed()
            }
        }
    }

    private func everyoneLeft() {
        roomPeers = []
        asked = [:]
        guard !hellos.isEmpty || !presence.isEmpty || !motion.isEmpty else { return }
        hellos = [:]
        heard = [:]
        presence = [:]
        motion = [:]
        stopFollowing()
        handOutPencils()
    }

    // MARK: Pictures

    /// The pictures the design shows now, as the shared design takes in what changed here: any
    /// placed here since go to the others as glimpses at once, to show until the room brings them
    /// (the Mac's LiveRoom.offer).
    func offer(_ names: Set<String>) {
        let new = names.subtracting(offered)
        guard !new.isEmpty else { return }
        offered.formUnion(new)
        guard inCompany else { return }
        sendGlimpses(of: Array(new), to: nil)
    }

    /// Glimpses of the pictures this computer has among `names`, made away from the main thread
    /// (Host/Glimpses.swift), to everyone or to the one who asked.
    private func sendGlimpses(of names: [String], to peer: UInt32?) {
        guard let session else { return }
        let folder = session.url.appendingPathComponent("images", isDirectory: true)
        let names = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !names.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let glimpses = names.prefix(200).compactMap { WindowsCore.glimpse(of: folder.appendingPathComponent($0), name: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A hundred at a time, well inside what the relay passes in one.
                    for start in stride(from: 0, to: glimpses.count, by: 100) {
                        self?.send(.glimpses(Array(glimpses[start..<min(start + 100, glimpses.count)])), to: peer)
                    }
                }
            }
        }
    }

    /// Pictures the design shows and this computer does not have: the others are asked for
    /// glimpses of them (the Mac's lookForPictures).
    private func lookForPictures() {
        guard inCompany, let session else { return }
        let folder = session.url.appendingPathComponent("images", isDirectory: true)
        var ask: [String] = []
        for name in session.shownPictures.subtracting(wanted).subtracting(present) {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { present.insert(name) } else { ask.append(name) }
        }
        guard !ask.isEmpty else { return }
        wanted.formUnion(ask)
        send(.want(Array(ask.prefix(400))))
    }

    /// Glimpses someone sent of pictures this computer does not have yet: each shown by its
    /// glimpse until the picture comes (the Mac's LiveRoom.take).
    private func take(_ glimpses: [LiveGlimpse]) {
        guard let session else { return }
        let folder = session.url.appendingPathComponent("images", isDirectory: true)
        for g in glimpses where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(g.name).path) {
            WindowsCore.standIn(g)
        }
    }

    // MARK: Settling and forgetting

    /// A motion settles once the design shows what it ended with, or after a while in any case.
    func settle(_ doc: BezzleDocument, at now: Double) {
        for (peer, m) in motion {
            guard let settled = m.settled else { continue }
            let left = m.nodes.filter { id, n in doc.node(id).map { !Self.same($0, n) } ?? false }
            if left.isEmpty || now - settled > 8 { motion[peer] = nil } else if left.count != m.nodes.count { motion[peer]?.nodes = left }
        }
    }

    private static func same(_ a: Node, _ b: Node) -> Bool {
        var x = a, y = b
        x.children = []
        y.children = []
        if abs(x.frame.minX - y.frame.minX) < 0.01, abs(x.frame.minY - y.frame.minY) < 0.01,
           abs(x.frame.width - y.frame.width) < 0.01, abs(x.frame.height - y.frame.height) < 0.01 { x.frame = y.frame }
        return x == y
    }

    /// Takes away what has finished showing.
    func forget(before now: Double) {
        winks.removeAll { now - $0.time > PencilLoop.lasts }
        glows.removeAll { now - $0.time > 1.5 }
    }
}
