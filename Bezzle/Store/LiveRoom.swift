import AppKit
import Observation
import QuartzCore

/// A shared design open on several Macs at once, each in the same room on the live relay. Here
/// everyone sees everyone else's pointer, where they are looking, what they hold, and their drags
/// as they go; what they change comes in a moment after, merged exactly as the design's records
/// are (see `SharedDesign`), so nothing anyone does is ever lost or put over someone else's. The
/// records on the relay, or the synced folder the design is kept in, carry every change too:
/// they are what keeps the design, for those who come later, for those offline, and should the
/// room be away.
///
/// Everything sent is sealed with a key made from the design's secret (`LiveKey`), the one in
/// its link or in its synced folder, which only those it is shared with know. The relay passes
/// on what it cannot read.
@Observable
final class LiveRoom {
    /// Someone else in the room.
    struct Person: Identifiable, Equatable {
        /// Their place in the room, which the relay gives.
        let id: UInt32
        var replica: String
        var name: String
        var timeZone: String?
        var pencil: Pencil
        var doing: LivePresence.Doing = .looking
        var away = false

        var initial: String { name.first.map { String($0).uppercased() } ?? "•" }
    }

    /// Someone shook their pointer to be looked at.
    struct Wink: Equatable {
        let by: UInt32
        let at: CGPoint
        let time: CFTimeInterval
    }

    /// A change someone else made, lighting up the layer for a moment in their colour.
    struct Glow {
        let id: UUID
        let pencil: Pencil
        let time: CFTimeInterval
    }

    /// The others in the room, in the order they came. It changes only as people come and go or
    /// start and stop doing something, so what shows them is not drawn again at every move.
    private(set) var people: [Person] = []
    /// Whether anyone else is here, apart from who: for what only changes as the room fills or empties.
    private(set) var hasPeople = false
    private(set) var link: LiveLink = .connecting
    /// The person whose view this canvas goes along with.
    private(set) var following: UInt32?
    /// Counts what others did that shows on the canvas: pointers, gazes, drags, winks and glows.
    private(set) var beat = 0

    @ObservationIgnored private(set) var presence: [UInt32: LivePresence] = [:]
    /// The layers each person is dragging, as they last were.
    @ObservationIgnored private(set) var motion: [UInt32: Motion] = [:]
    @ObservationIgnored private(set) var winks: [Wink] = []
    @ObservationIgnored private(set) var glows: [Glow] = []
    /// What this canvas draws of it all.
    @ObservationIgnored let marks = LiveMarks()

    /// A picture shown before it is here: from its glimpse, or as photographic paper with none,
    /// developing until it comes, then drawn into focus.
    struct Developing {
        var since: CFTimeInterval
        var standIn: CGImage?
        var arrived: CFTimeInterval?
    }

    /// Pictures shown that are not here yet, by name.
    @ObservationIgnored private(set) var developing: [String: Developing] = [:]
    /// Pictures this Mac has offered glimpses of, or had before the room was opened.
    @ObservationIgnored private var offered: Set<String> = []
    /// Pictures this Mac has asked the room for.
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var lookedForPictures: CFTimeInterval = 0
    @ObservationIgnored private var grainFrame: CFTimeInterval = 0

    struct Motion {
        var nodes: [UUID: Node]
        /// Set once the drag has ended: the layers stay as it left them until the change itself
        /// is shown, so nothing jumps back in between.
        var settled: CFTimeInterval?
    }

    @ObservationIgnored private weak var collaboration: Collaboration?
    @ObservationIgnored private weak var store: DocumentStore?
    @ObservationIgnored private let key: LiveKey
    @ObservationIgnored private let transport: LiveTransport
    @ObservationIgnored private var me: UInt32?
    /// Who else the relay says is in the room, whether or not they have said who they are yet.
    @ObservationIgnored private var roomPeers: Set<UInt32> = []
    /// When each person not known yet was last asked who they are.
    @ObservationIgnored private var asked: [UInt32: CFTimeInterval] = [:]
    /// Held while others are in the room, so that macOS does not slow Bezzle down in the background
    /// and leave them thinking it has gone.
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var hellos: [UInt32: LiveHello] = [:]
    @ObservationIgnored private var heard: [UInt32: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var detector = WinkDetector()
    /// This Mac's pointer on the canvas, in canvas points.
    @ObservationIgnored private(set) var pointer: CGPoint?
    @ObservationIgnored private var sentPresence: LivePresence?
    @ObservationIgnored private var sentPresenceAt: CFTimeInterval = 0
    @ObservationIgnored private var sentMotion: [Node] = []
    @ObservationIgnored private var wasInGesture = false
    @ObservationIgnored private var takenVersion = -1
    /// The latest of this Mac's changes the room has been sent.
    @ObservationIgnored private var relayedUpTo: Int64 = 0
    @ObservationIgnored private let opened = CACurrentMediaTime()
    @ObservationIgnored private lazy var camera = LiveCamera(room: self)

    /// This Mac's own wink, drawn for whoever made it.
    @ObservationIgnored static let selfID: UInt32 = 0

    init(collaboration: Collaboration, store: DocumentStore, transport: LiveTransport) {
        self.collaboration = collaboration
        self.store = store
        key = LiveKey(collaboration.liveKeys)
        self.transport = transport
        relayedUpTo = collaboration.changedUpTo
        offered = Collaboration.pictures(in: store.sharedDoc)
        transport.onFrame = { [weak self] in self?.handle($0) }
        transport.onLink = { [weak self] link in
            guard let self, self.link != link else { return }
            self.link = link
            if link != .live { self.everyoneLeft() }
        }
        transport.start()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.pointerMoved(event)
            return event
        }
    }

    /// The room for a shared design that has just been opened, when there is a relay to use.
    static func open(for collaboration: Collaboration, store: DocumentStore) -> LiveRoom? {
        guard !BezzleApp.isTesting, let relay = LiveRelay.address, !collaboration.isReadOnly else { return nil }
        let keys = collaboration.liveKeys
        let socket = LiveSocket(room: keys.room, read: keys.readToken, relay: relay)
        return LiveRoom(collaboration: collaboration, store: store, transport: socket)
    }

    func leave() {
        keepAwake(false)
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        camera.stop()
        transport.stop()
        everyoneLeft()
    }

    /// Whether anyone else is here, so that their changes come this way rather than through iCloud.
    var hasOthers: Bool { link == .live && !people.isEmpty }

    /// Whether the relay says anyone else is in the room: then this Mac keeps saying where it is,
    /// and sends what it changes, even to someone who has not said who they are yet.
    private var inCompany: Bool { link == .live && !roomPeers.isEmpty }

    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Working on a shared design live with others")
        } else if !on, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
    }

    // MARK: Who this Mac is

    static let myName: String = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["BEZZLE_LIVE_NAME"] { return name }
        #endif
        let full = NSFullUserName()
        if let parts = PersonNameComponentsFormatter().personNameComponents(from: full) {
            let short = PersonNameComponentsFormatter.localizedString(from: parts, style: .short)
            if !short.isEmpty { return short }
        }
        return full.isEmpty ? NSUserName() : full
    }()

    /// This Mac's name among those sharing the design.
    private var myReplica: String { collaboration?.replica ?? Sharing.replica }
    /// How the others see this Mac's person named.
    @ObservationIgnored var name = LiveRoom.myName

    private var hello: LiveHello {
        LiveHello(replica: myReplica, name: name, timeZone: TimeZone.current.identifier)
    }

    // MARK: Sending

    private func send(_ message: LiveMessage, to peer: UInt32? = nil, droppable: Bool = false) {
        guard link == .live, let sealed = key.seal(message) else { return }
        // Too much for the relay at once: iCloud carries it, as it carries everything.
        guard sealed.count < 900_000 else { return }
        transport.send(peer.map { LiveFrame.to($0, sealed) } ?? LiveFrame.toAll(sealed), droppable: droppable)
    }

    /// What was changed here and not yet sent to the room goes now. The shared design calls this
    /// whenever it takes in a change made here.
    func relay() {
        guard let collaboration else { return }
        let upTo = collaboration.changedUpTo
        guard upTo > relayedUpTo else { return }
        if inCompany {
            let changes = collaboration.state.changes(by: collaboration.replica, after: relayedUpTo)
            if !changes.isEmpty { send(.changes(changes)) }
        }
        relayedUpTo = upTo
    }

    /// What this Mac changed that the room's records or the folder do not have yet, for someone who
    /// has just come in: they would otherwise wait for it to arrive from there.
    private func catchUp(_ peer: UInt32?) {
        guard let collaboration else { return }
        let changes = collaboration.state.changes(by: collaboration.replica, after: collaboration.sentUpTo)
        if !changes.isEmpty { send(.changes(changes), to: peer) }
    }

    private func tick() {
        guard let store, let collaboration else { return }
        let now = CACurrentMediaTime()
        dropSilent()
        if now - lookedForPictures > 0.5 {
            lookedForPictures = now
            lookForPictures(store, now)
        }
        // A picture on its way in sight keeps developing, its grain moving at a film's pace, until it comes.
        if let area = marks.developingArea, now - grainFrame >= 1.0 / 12, let canvas = store.canvas {
            grainFrame = now
            canvas.setNeedsDisplay(area.insetBy(dx: -2, dy: -2).intersection(canvas.bounds))
        }
        guard inCompany else {
            takenVersion = store.version
            wasInGesture = store.inGesture
            return
        }
        // Changes made here go as soon as they are made, rather than when the design is next
        // saved; a drag's, once it ends.
        if !store.inGesture, store.version != takenVersion {
            takenVersion = store.version
            collaboration.takeIn(store.sharedDoc)
        }
        if store.inGesture {
            let nodes = movingNodes(store)
            if nodes != sentMotion {
                sentMotion = nodes
                send(.motion(nodes), droppable: true)
            }
        } else if wasInGesture {
            send(.settle(sentMotion.compactMap { n in store.doc.node(n.id).map(Self.alone) }))
            sentMotion = []
        }
        wasInGesture = store.inGesture

        #if DEBUG
        demo?.step(self, store, now)
        #endif
        let p = currentPresence(store)
        if p != sentPresence || now - sentPresenceAt > 4 {
            send(.presence(p), droppable: p == sentPresence)
            sentPresence = p
            sentPresenceAt = now
        }
    }

    private func currentPresence(_ store: DocumentStore) -> LivePresence {
        let canvas = store.canvas
        let window = canvas?.window
        var p = LivePresence(view: store.visibleCanvasRect)
        p.pointer = pointer
        p.selection = Array(store.selection.prefix(64))
        p.tool = store.tool.rawValue
        if store.editingText != nil { p.doing = .typing }
        else if store.inGesture { p.doing = store.tool == .select ? .moving : .drawing }
        p.away = !(NSApp.isActive && window?.isKeyWindow == true)
        #if DEBUG
        if demo != nil { p.away = false }
        #endif
        return p
    }

    /// The selected layers as they are this moment of a drag, without what they hold, and what
    /// is in them while that is not much.
    private func movingNodes(_ store: DocumentStore) -> [Node] {
        var out: [Node] = []
        for id in store.selection.prefix(32) {
            guard let node = store.doc.node(id) else { continue }
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

    private static func alone(_ node: Node) -> Node {
        var n = node
        n.children = []
        return n
    }

    private func pointerMoved(_ event: NSEvent) {
        guard let store, let canvas = store.canvas, let window = canvas.window, event.window === window else { return }
        let v = canvas.convert(event.locationInWindow, from: nil)
        guard canvas.bounds.contains(v) else {
            pointer = nil
            return
        }
        let p = store.viewport.toCanvas(v)
        pointer = p
        if detector.add(event.locationInWindow, at: event.timestamp) {
            winks.append(Wink(by: Self.selfID, at: p, time: CACurrentMediaTime()))
            beat += 1
            send(.wink(p))
        }
    }

    // MARK: Receiving

    private func handle(_ frame: LiveFrame) {
        defer { keepAwake(inCompany) }
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
            if let store { send(.presence(currentPresence(store)), to: peer) }
            catchUp(peer)
        case .left(let peer):
            remove(peer)
        case .records(let upTo):
            collaboration?.cloud?.recordsChanged(upTo: upTo)
        case .gone:
            collaboration?.cloud?.gone()
        case .message(let from, let sealed):
            guard let message = key.open(sealed) else {
                Sharing.log.error("A live message could not be opened")
                return
            }
            heard[from] = Date()
            roomPeers.insert(from)
            // Heard from, but not known, as after either of us was away a while: asked who they are.
            if hellos[from] == nil {
                if case .hello = message {} else { askWho(from) }
            }
            take(message, from: from)
        }
    }

    private func take(_ message: LiveMessage, from peer: UInt32) {
        let now = CACurrentMediaTime()
        switch message {
        case .hello(var hello):
            // The same Mac come back on a new connection: its old place goes.
            for (other, h) in hellos where other != peer && h.replica == hello.replica { remove(other) }
            let first = hellos[peer] == nil
            if hello.ask == true { send(.hello(self.hello), to: peer) }
            hello.ask = nil
            hellos[peer] = hello
            asked[peer] = nil
            // Someone new may have what nobody here had: asked again.
            if first { wanted = [] }
            handOutPencils()
            if first, store?.inGesture == false, let store {
                // Whoever comes in hears straight away what is moving here.
                send(.presence(currentPresence(store)), to: peer)
            }
            marks.arrived(peer)
        case .presence(let p):
            let was = presence[peer]
            presence[peer] = p
            if was?.doing != p.doing || was?.away != p.away { updatePerson(peer) { $0.doing = p.doing; $0.away = p.away } }
            beat += 1
        case .motion(let nodes):
            motion[peer] = Motion(nodes: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), settled: nil)
            beat += 1
        case .settle(let nodes):
            if nodes.isEmpty { motion[peer] = nil } else {
                motion[peer] = Motion(nodes: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), settled: now)
            }
            beat += 1
        case .changes(let changes):
            guard let collaboration else { return }
            collaboration.receive([changes], from: .relay)
            collaboration.persist()
        case .wink(let at):
            winks.append(Wink(by: peer, at: at, time: now))
            beat += 1
        case .glimpses(let glimpses):
            take(glimpses, from: peer)
        case .want(let names):
            if let folder = store?.assets.folder { sendGlimpses(of: names, from: folder, to: peer) }
        case .version(let version, let data):
            if let data { store?.versions.arrived(version, data: data) }
        }
    }

    private func askWho(_ peer: UInt32) {
        let now = CACurrentMediaTime()
        guard now - (asked[peer] ?? -.infinity) > 3 else { return }
        asked[peer] = now
        var mine = hello
        mine.ask = true
        send(.hello(mine), to: peer)
    }

    /// A motion settles once the design shows what it ended with, or after a while in any case.
    func settle(_ doc: BezzleDocument, at now: CFTimeInterval) {
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

    /// Others' changes have just been shown: each layer lights up for a moment in its maker's colour.
    func glow(_ authors: [UUID: String]) {
        // Not for a whole design arriving, as it does on opening.
        guard !authors.isEmpty, authors.count <= 400, CACurrentMediaTime() - opened > 2 else { return }
        let now = CACurrentMediaTime()
        for (id, replica) in authors where replica != myReplica {
            glows.append(Glow(id: id, pencil: pencil(of: replica), time: now))
        }
        beat += 1
    }

    /// Takes away what has finished showing.
    func forget(before now: CFTimeInterval) {
        winks.removeAll { now - $0.time > PencilLoop.lasts }
        glows.removeAll { now - $0.time > 1.5 }
    }

    // MARK: Pictures

    /// The pictures the design shows now, as the shared design takes in what changed here: any
    /// placed here since go to the others as glimpses at once, to show until iCloud brings them.
    func offer(_ names: Set<String>) {
        let new = names.subtracting(offered)
        guard !new.isEmpty else { return }
        offered.formUnion(new)
        guard inCompany, let folder = store?.assets.folder else { return }
        sendGlimpses(of: Array(new), from: folder, to: nil)
    }

    private func sendGlimpses(of names: [String], from folder: URL, to peer: UInt32?) {
        let names = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !names.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let glimpses = names.prefix(200).compactMap { LiveGlimpse.of(folder.appendingPathComponent($0), name: $0) }
            await MainActor.run { [weak self] in
                // A hundred at a time, well inside what the relay passes in one.
                for start in stride(from: 0, to: glimpses.count, by: 100) {
                    self?.send(.glimpses(Array(glimpses[start..<min(start + 100, glimpses.count)])), to: peer)
                }
            }
        }
    }

    /// Pictures drawing looked for and did not find develop where they are, and the others are
    /// asked for glimpses of them.
    private func lookForPictures(_ store: DocumentStore, _ now: CFTimeInterval) {
        let missing = store.assets.missing
        for name in missing where developing[name] == nil {
            developing[name] = Developing(since: now, standIn: store.assets.standIn(of: name))
            beat += 1
        }
        let ask = missing.subtracting(wanted)
        guard inCompany, !ask.isEmpty else { return }
        wanted.formUnion(ask)
        send(.want(Array(ask.prefix(400))))
    }

    private func take(_ glimpses: [LiveGlimpse], from peer: UInt32) {
        guard let store else { return }
        let folder = store.assets.folder
        let needed = glimpses.filter { g in
            folder.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(g.name).path) } ?? false
                && store.assets.standIn(of: g.name) == nil
        }
        guard !needed.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let made = needed.compactMap { g in g.standIn().map { (g.name, $0) } }
            await MainActor.run { [weak self] in
                guard let self, let store = self.store else { return }
                let now = CACurrentMediaTime()
                for (name, image) in made {
                    store.assets.standIn(name, image)
                    // It starts developing again from its glimpse, now that there is something to see.
                    self.developing[name] = Developing(since: now, standIn: image)
                    store.canvas?.tiles.forget(showing: name)
                    BlurCache.shared.forget(showing: name)
                }
                self.beat += 1
                store.canvas?.needsDisplay = true
            }
        }
    }

    /// A picture that was not here has come: it is drawn into focus.
    func arrived(_ name: String) {
        guard developing[name] != nil, developing[name]?.arrived == nil else { return }
        developing[name]?.arrived = CACurrentMediaTime()
        beat += 1
    }

    /// Pictures that have finished coming into focus.
    func developed(before now: CFTimeInterval) {
        for (name, d) in developing where d.arrived.map({ now - $0 > LiveMarks.focusing }) ?? false { developing[name] = nil }
    }

    // MARK: Versions

    /// A version named here goes to everyone in the room at once.
    func announce(_ version: DesignVersion, data: Data) {
        guard inCompany else { return }
        send(.version(version, data.count < 700_000 ? data : nil))
    }

    // MARK: People

    @ObservationIgnored private var pencils: [String: Pencil] = [:]

    func pencil(of replica: String) -> Pencil { pencils[replica] ?? Pencil.preferred(replica) }

    func person(_ peer: UInt32) -> Person? { people.first { $0.id == peer } }

    private func handOutPencils() {
        pencils = Pencil.hand(to: Set(hellos.values.map(\.replica)).union([myReplica]))
        var next: [Person] = []
        for p in people where hellos[p.id] != nil { next.append(p) }
        for (peer, h) in hellos.sorted(by: { $0.key < $1.key }) where !next.contains(where: { $0.id == peer }) {
            next.append(Person(id: peer, replica: h.replica, name: h.name, timeZone: h.timeZone, pencil: pencil(of: h.replica)))
        }
        for i in next.indices {
            guard let h = hellos[next[i].id] else { continue }
            next[i].replica = h.replica
            next[i].name = h.name
            next[i].timeZone = h.timeZone
            next[i].pencil = pencil(of: h.replica)
            if let p = presence[next[i].id] { next[i].doing = p.doing; next[i].away = p.away }
        }
        if next != people { people = next }
        if hasPeople != !next.isEmpty { hasPeople = !next.isEmpty }
    }

    private func updatePerson(_ peer: UInt32, _ change: (inout Person) -> Void) {
        guard let i = people.firstIndex(where: { $0.id == peer }) else { return }
        var p = people[i]
        change(&p)
        if p != people[i] { people[i] = p }
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
        beat += 1
    }

    /// Someone not heard from for a while shows as away, and comes back as soon as they are heard
    /// again; only after long enough is taken to have gone, should the relay not have said so.
    private func dropSilent() {
        let now = Date()
        for (peer, at) in heard {
            let quiet = now.timeIntervalSince(at)
            if quiet > 300 {
                remove(peer)
            } else if quiet > 25, presence[peer]?.away == false {
                presence[peer]?.away = true
                updatePerson(peer) { $0.away = true }
                beat += 1
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
        beat += 1
    }

    // MARK: Going along

    /// Flies this canvas to where someone is looking, and keeps it there, going along with them
    /// until this Mac moves the view itself. Going to someone already followed lets them go.
    func go(to peer: UInt32) {
        guard let store else { return }
        if following == peer {
            stopFollowing()
            return
        }
        guard let view = presence[peer]?.view else { return }
        following = peer
        camera.fly(store, to: Viewport(showing: view, in: store.canvasSize), follow: true)
    }

    /// Flies to where someone winked, keeping how wide they see.
    func go(toWink wink: Wink) {
        guard let store else { return }
        var target = store.viewport
        if let view = presence[wink.by]?.view { target = Viewport(showing: view, in: store.canvasSize) }
        let size = store.canvasSize
        target.origin = CGPoint(x: wink.at.x - size.width / 2 / target.zoom, y: wink.at.y - size.height / 2 / target.zoom)
        stopFollowing()
        camera.fly(store, to: target, follow: false)
    }

    func stopFollowing() {
        guard following != nil else { return }
        following = nil
        camera.letGo()
    }

    /// Where the person followed is looking, as this canvas would show it.
    func followedView() -> Viewport? {
        guard let peer = following, let view = presence[peer]?.view, let store else { return nil }
        return Viewport(showing: view, in: store.canvasSize)
    }

    /// The latest wink of someone, while it lasts.
    func wink(of peer: UInt32, at now: CFTimeInterval) -> Wink? {
        winks.last { $0.by == peer && now - $0.time < PencilLoop.lasts }
    }

    /// Where someone is in the world, if it is not where this Mac is by the clock.
    func zone(of person: Person, at date: Date = Date()) -> TimeZone? {
        guard let id = person.timeZone, let zone = TimeZone(identifier: id),
              zone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date) else { return nil }
        return zone
    }

    // MARK: Tests

    #if DEBUG
    /// BEZZLE_LIVE_DEMO=1: this copy's person moves their pointer about, winks, and drags a
    /// layer now and then, by themselves, for seeing the room from another copy.
    @ObservationIgnored private lazy var demo: LiveDemo? = ProcessInfo.processInfo.environment["BEZZLE_LIVE_DEMO"] == nil ? nil : LiveDemo()

    fileprivate func demoPointer(_ p: CGPoint) { pointer = p }
    fileprivate func demoWink(_ p: CGPoint) {
        winks.append(Wink(by: Self.selfID, at: p, time: CACurrentMediaTime()))
        beat += 1
        send(.wink(p))
    }

    /// Takes a frame as though it came from the relay.
    func receiveForTesting(_ frame: LiveFrame) { handle(frame) }
    func tickForTesting() { tick() }
    /// Forgets who someone is while the relay still has them, as when this Mac stalled a while.
    func forgetForTesting(_ name: String) {
        if let peer = people.first(where: { $0.name == name })?.id {
            hellos[peer] = nil
            handOutPencils()
        }
    }
    /// Makes it as though someone was last heard from `seconds` ago.
    func quietForTesting(_ name: String, _ seconds: TimeInterval) {
        if let peer = people.first(where: { $0.name == name })?.id { heard[peer] = Date().addingTimeInterval(-seconds) }
    }
    #endif
}

/// Moves a canvas's view: in flight to someone, then along with them. A display link of the
/// canvas's own, running only while the view moves.
final class LiveCamera: NSObject {
    private weak var room: LiveRoom?
    private weak var store: DocumentStore?
    private var link: CADisplayLink?
    private var flight: CameraFlight?
    private var began: CFTimeInterval = 0
    private var follow = false
    /// The view as last set here: one that differs was moved by hand, and lets go.
    private var set: Viewport?
    private var last: CFTimeInterval = 0

    init(room: LiveRoom) {
        self.room = room
    }

    func fly(_ store: DocumentStore, to target: Viewport, follow: Bool) {
        self.store = store
        self.follow = follow
        let size = store.canvasSize
        flight = CameraFlight(from: store.viewport.shot(in: size), to: target.shot(in: size))
        began = CACurrentMediaTime()
        set = store.viewport
        start()
    }

    func letGo() {
        follow = false
        if flight == nil { stop() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        flight = nil
        set = nil
    }

    private func start() {
        guard link == nil, let canvas = store?.canvas else { return }
        let link = canvas.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = CACurrentMediaTime()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let store, let room else { return stop() }
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.05)
        last = now
        if let set, !Self.near(store.viewport, set) {
            // Moved by hand: the view is this Mac's own again.
            flight = nil
            room.stopFollowing()
            return stop()
        }
        let size = store.canvasSize
        if let flight {
            // Someone followed keeps moving while the view flies to them: it lands where they are now.
            var target = flight.to
            if follow, let theirs = room.followedView() { target = theirs.shot(in: size) }
            let f = (now - began) / flight.duration
            var shot = flight.shot(at: f)
            if target != flight.to {
                let k = CGFloat(f * f * (3 - 2 * f))
                shot.center = CGPoint(x: shot.center.x + (target.center.x - flight.to.center.x) * k, y: shot.center.y + (target.center.y - flight.to.center.y) * k)
                shot.width *= pow(target.width / flight.to.width, k)
            }
            put(Viewport(shot, in: size), store)
            if f >= 1 {
                self.flight = nil
                if !follow { return stop() }
            }
            return
        }
        guard follow, let target = room.followedView() else { return stop() }
        // Along with them, a little behind, as a hand following a hand.
        let k = CGFloat(1 - exp(-dt / 0.09))
        let a = store.viewport.shot(in: size), b = target.shot(in: size)
        let shot = CameraFlight.Shot(center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * k, y: a.center.y + (b.center.y - a.center.y) * k),
                                     width: a.width * pow(b.width / a.width, k))
        put(Viewport(shot, in: size), store)
    }

    private func put(_ v: Viewport, _ store: DocumentStore) {
        if !Self.near(store.viewport, v) { store.viewport = v }
        set = store.viewport
    }

    private static func near(_ a: Viewport, _ b: Viewport) -> Bool {
        abs(a.zoom - b.zoom) <= 1e-9 * max(a.zoom, b.zoom) && abs(a.origin.x - b.origin.x) < 1e-6 && abs(a.origin.y - b.origin.y) < 1e-6
    }
}

#if DEBUG
/// What BEZZLE_LIVE_DEMO's person does.
private final class LiveDemo {
    private let began = CACurrentMediaTime()
    /// BEZZLE_LIVE_GO=seconds: goes to the first person in the room that long after opening.
    private var goAt = ProcessInfo.processInfo.environment["BEZZLE_LIVE_GO"].flatMap(Double.init)
    let moves = ProcessInfo.processInfo.environment["BEZZLE_LIVE_DEMO"] != "still"
    private var lastWink: CFTimeInterval = 0
    private var dragging: (id: UUID, from: CGRect, start: CFTimeInterval)?
    private var lastDrag: CFTimeInterval = 0

    func step(_ room: LiveRoom, _ store: DocumentStore, _ now: CFTimeInterval) {
        let t = now - began
        // Pictures copied into the package by hand arrive, as from iCloud.
        if let folder = store.assets.folder {
            for (name, d) in room.developing where d.arrived == nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                store.pictureArrived(name)
                room.arrived(name)
            }
        }
        if let at = goAt, t > at, let first = room.people.first {
            goAt = nil
            room.go(to: first.id)
        }
        if ProcessInfo.processInfo.environment["BEZZLE_LIVE_DEMO"] == "wink" {
            // Winks in the middle of the view every few seconds, for looking at the circle.
            let view = store.visibleCanvasRect
            let c = CGPoint(x: view.midX, y: view.midY)
            room.demoPointer(CGPoint(x: c.x + 30 / store.viewport.zoom, y: c.y + 26 / store.viewport.zoom))
            if now - lastWink > 3 {
                lastWink = now
                room.demoWink(c)
            }
            return
        }
        guard moves else { return }
        let view = store.visibleCanvasRect
        let c = CGPoint(x: view.midX, y: view.midY)
        if let drag = dragging {
            let f = min((now - drag.start) / 1.8, 1)
            let dx = sin(f * .pi) * drag.from.width * 1.4, dy = sin(f * .pi * 2) * drag.from.height * 0.3
            store.update([drag.id], "Move") { $0.frame.origin = CGPoint(x: drag.from.minX + dx, y: drag.from.minY + dy) }
            if let frame = store.doc.absoluteFrame(of: drag.id) { room.demoPointer(CGPoint(x: frame.midX, y: frame.midY)) }
            if f >= 1 {
                store.endGesture("Move")
                dragging = nil
                lastDrag = now
            }
            return
        }
        room.demoPointer(CGPoint(x: c.x + cos(t * 0.9) * view.width * 0.3, y: c.y + sin(t * 1.8) * view.height * 0.22))
        if now - lastWink > 9, t > 4 {
            lastWink = now
            room.demoWink(CGPoint(x: c.x + cos(t * 0.9) * view.width * 0.3, y: c.y + sin(t * 1.8) * view.height * 0.22))
        }
        if now - lastDrag > 6, t > 2, let board = store.focusedArtboard,
           let layer = board.children.first(where: { !$0.locked && !$0.hidden }) {
            store.selection = [layer.id]
            store.beginGesture()
            dragging = (layer.id, layer.frame, now)
        }
    }
}
#endif
