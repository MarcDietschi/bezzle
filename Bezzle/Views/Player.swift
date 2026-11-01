import SwiftUI
import AppKit
import QuartzCore

// MARK: - The prototype, played

/// The prototype being played: the screens it has been through, how the one in front came on, and
/// what its copies of components show as they are pointed at and tapped. The screen flies off the
/// canvas into the device it is for, and back to where it lies when the playing ends.
@Observable
final class Player {
    @ObservationIgnored unowned var store: DocumentStore

    /// A screen shown, and how it came to be.
    struct Visit: Equatable {
        let board: UUID
        /// A sheet: the screen it opened over, dimmed under it.
        let under: UUID?
        /// How it came on, to go back the same way.
        let way: Prototype.Way
    }

    private(set) var history: [Visit]
    var visit: Visit { history[history.count - 1] }

    enum Phase { case arriving, playing, leaving }
    var phase: Phase = .arriving
    /// The screen as a picture, flying in from the canvas and back.
    var snapshot: CGImage?
    /// Where on the window the screen flies from, and back to; nil fades instead.
    var canvasRect: CGRect?
    /// The thing it is played on, and the size of its screen in the design's points.
    let form: SizeForm
    let screen: CGSize
    /// What was said of the flow just taken, written under the device.
    var caption: Caption?
    struct Caption: Equatable {
        let text: String
        let token = UUID()
    }
    /// Counts the times there was no way back, for the device to shake its head.
    var refusals = 0

    // What the copies of components show. Variants by copy, as taps chose them.
    @ObservationIgnored var chosen: [UUID: Int?] = [:]
    @ObservationIgnored var hovering: UUID?
    @ObservationIgnored var pressing: UUID?
    /// A copy showing that it is loading, before its flow is taken.
    @ObservationIgnored var waiting: (copy: UUID, flow: FlowLink, until: CFTimeInterval)?
    @ObservationIgnored var transit: Transit?
    /// How far a screen taller than the device is scrolled down.
    @ObservationIgnored var scroll: CGFloat = 0
    @ObservationIgnored weak var view: PlayerScreenView?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keys: Any?
    /// Copies made again as another variant, by copy, with the variant and the design's version.
    @ObservationIgnored private var built: [UUID: (variant: Int?, version: Int, node: Node)] = [:]

    init(store: DocumentStore, start: UUID) {
        self.store = store
        let board = store.seenDoc.node(start)
        let (form, screen) = Self.device(for: board?.frame.size ?? CGSize(width: 390, height: 844))
        self.form = form
        self.screen = screen
        history = [Visit(board: start, under: nil, way: .instant)]
        canvasRect = windowRect(of: start)
        snapshot = picture()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.phase == .playing else { return event }
            return self.key(event) ? nil : event
        }
        arrived()
    }

    // MARK: The device

    /// What a screen of this size is played on, and the size of the device's screen: an iPhone
    /// for a phone's screen, a browser for a page, and a long page scrolls in a screen of the
    /// device's height.
    static func device(for size: CGSize) -> (SizeForm, CGSize) {
        let screens: Set<Preset.Group> = [.iPhone, .android, .iPad, .mac, .web, .watch]
        if let p = Preset.all.first(where: { abs($0.size.width - size.width) < 0.5 && abs($0.size.height - size.height) < 0.5 }) {
            return (SizeForm.of(p), size)
        }
        if let p = Preset.all.first(where: { screens.contains($0.group) && abs($0.size.width - size.width) < 0.5 && $0.size.height < size.height }) {
            return (SizeForm.of(p), p.size)
        }
        let w = size.width, h = size.height
        if w <= 460, h >= w * 1.3 { return (.phone(island: true), CGSize(width: w, height: min(h, (w * 2.17).rounded()))) }
        if w <= 1100, h >= w * 0.6 { return (.tablet, CGSize(width: w, height: min(h, (w * 1.4).rounded()))) }
        if w > 1100 { return (.browser, CGSize(width: w, height: min(h, (w * 0.62).rounded()))) }
        return (.post(roundness: 0.012), size)
    }

    // MARK: Moving between screens

    var animating: Bool { transit != nil || waiting != nil }

    /// Takes a flow from a layer on the screen in front.
    func take(_ flow: FlowLink, from source: UUID) {
        if flow.goesBack { back(); return }
        let seen = store.seenDoc
        guard let to = flow.to, let target = seen.node(to), target.isArtboard, let here = seen.node(visit.board) else { return }
        finishTransit()
        let way = Prototype.way(from: visit.under.flatMap { seen.node($0) } ?? here, to: target, motion: flow.motion)
        let next = Visit(board: to, under: way == .sheet ? (visit.under ?? visit.board) : nil, way: way)
        let from = visit
        // As it shows at the tap, pointed at as it is.
        let fromScene = scene(of: from)
        history.append(next)
        caption = flow.note.flatMap { $0.isEmpty ? nil : Caption(text: $0) }
        let aScroll = scroll
        scroll = 0
        hovering = nil
        pressing = nil
        if way.moves {
            let t = Transit(a: from, b: next, way: way, reverse: false, start: .infinity, aScroll: aScroll)
            transit = t
            view?.begin(t, a: fromScene, b: scene(of: next))
        } else {
            view?.refresh()
        }
        arrived()
    }

    /// Back to the screen before, the way this one came on, undone.
    func back() {
        guard history.count > 1 else {
            refusals += 1
            return
        }
        finishTransit()
        let leavingScene = scene(of: visit)
        let leaving = history.removeLast()
        caption = nil
        let bScroll = scroll
        scroll = 0
        hovering = nil
        pressing = nil
        if leaving.way.moves {
            let t = Transit(a: visit, b: leaving, way: leaving.way, reverse: true, start: .infinity, aScroll: 0, bScroll: bScroll)
            transit = t
            view?.begin(t, a: scene(of: visit), b: leavingScene)
        } else {
            view?.refresh()
        }
        arrived()
    }

    func restart() {
        guard history.count > 1 || scroll != 0 else { return }
        finishTransit()
        let first = history[0]
        let leaving = visit
        let leavingScene = scene(of: leaving)
        history = [first]
        chosen = [:]
        caption = nil
        let bScroll = scroll
        scroll = 0
        hovering = nil
        pressing = nil
        let t = Transit(a: first, b: leaving, way: .dissolve, reverse: true, start: .infinity, aScroll: 0, bScroll: bScroll)
        transit = t
        view?.begin(t, a: scene(of: first), b: leavingScene)
        arrived()
    }

    private func finishTransit() {
        transit = nil
        waiting = nil
    }

    /// A screen has come on: one that goes on by itself is timed.
    private func arrived() {
        timer?.invalidate()
        timer = nil
        guard let board = store.seenDoc.node(visit.board), let flow = board.flow, flow.leads, let after = flow.after else { return }
        let at = visit
        let t = Timer(timeInterval: max(after, 0.1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visit == at, self.phase != .leaving else { return }
                self.take(flow, from: board.id)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Done with at once, as when the design stops being seen as a prototype.
    func stop() {
        finishTransit()
        timer?.invalidate()
        timer = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    /// The end of playing: the screen flies back to where it lies on the canvas.
    func close() {
        guard phase != .leaving else { return }
        finishTransit()
        timer?.invalidate()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        // Brought into view first, behind the stage, so it has somewhere to land.
        store.show(visit.board)
        snapshot = picture()
        canvasRect = windowRect(of: visit.board)
        store.selection = [visit.board]
        phase = .leaving
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak store] in
            store?.player = nil
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close()
        case 123, 51: back()
        case 15 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: restart()
        default: return false
        }
        return true
    }

    /// Where a screen lies on the window, as the canvas shows it, measured from the window's top.
    private func windowRect(of board: UUID) -> CGRect? {
        guard let canvas = store.canvas, let window = canvas.window, let r = store.viewRect(of: board),
              let height = window.contentView?.bounds.height else { return nil }
        // Only the part the device shows: the top of a long page.
        var part = r
        if let b = store.seenDoc.node(board), b.frame.height > screen.height {
            part.size.height = r.height * screen.height / b.frame.height
        }
        guard part.intersects(canvas.bounds) else { return nil }
        let w = canvas.convert(part, to: nil)
        return CGRect(x: w.minX, y: height - w.maxY, width: w.width, height: w.height)
    }

    // MARK: Pointing and tapping

    /// What lies at a point of the device's screen (in the design's points): the screen it is on,
    /// where on it, or nil off a sheet.
    private func place(_ p: CGPoint) -> (board: Node, local: CGPoint)? {
        let seen = store.seenDoc
        guard let board = shown(visit.board, in: seen) else { return nil }
        if visit.under != nil {
            let r = sheetRect(of: board)
            guard r.contains(p) else { return nil }
            return (board, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
        }
        return (board, CGPoint(x: p.x, y: p.y + scroll))
    }

    /// The layer at a point that goes somewhere, and the copy it lies in that has states.
    func target(at p: CGPoint) -> (flow: (UUID, FlowLink)?, copy: Node?, offSheet: Bool) {
        guard let (board, local) = place(p) else { return (nil, nil, visit.under != nil) }
        let chain = Prototype.chain(at: local, in: board)
        let flow = chain.first { $0.flow?.leads == true }.map { ($0.id, $0.flow!) }
        let copy = chain.first { $0.isCopy && !states(of: $0).isEmpty }
        return (flow, copy, false)
    }

    private func states(of copy: Node) -> [VariantState: Int?] {
        guard let m = copy.instance.flatMap({ store.doc.master($0.of) }) else { return [:] }
        return Components.states(of: m)
    }

    private func base(of copy: Node) -> Int? {
        if let c = chosen[copy.id] { return c }
        return copy.instance?.variant
    }

    private func disabled(_ copy: Node) -> Bool {
        guard let m = copy.instance.flatMap({ store.doc.master($0.of) }) else { return false }
        return Components.state(of: base(of: copy), in: m) == .disabled
    }

    func hover(at p: CGPoint?) -> Bool {
        guard transit == nil, phase == .playing else { return false }
        let t = p.map(target(at:))
        let copy = t?.copy.flatMap { c in states(of: c)[.hover] != nil && !disabled(c) ? c.id : nil }
        if copy != hovering {
            hovering = copy
            view?.refresh()
        }
        guard let t else { return false }
        return t.flow != nil || t.copy.map { !disabled($0) } == true || t.offSheet
    }

    func down(at p: CGPoint) {
        guard phase == .playing else { return }
        let t = target(at: p)
        if let c = t.copy, !disabled(c), states(of: c)[.pressed] != nil {
            pressing = c.id
            view?.refresh()
        }
    }

    func up(at p: CGPoint) {
        guard phase == .playing else { return }
        let wasPressing = pressing
        pressing = nil
        let t = target(at: p)
        defer { view?.refresh() }
        if t.offSheet { back(); return }
        if let c = t.copy, disabled(c) { return }
        if let (source, flow) = t.flow {
            if let c = t.copy, let loading = states(of: c)[.loading] {
                _ = loading
                waiting = (c.id, flow, CACurrentMediaTime() + 0.9)
                view?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, let w = self.waiting, w.copy == c.id else { return }
                    self.waiting = nil
                    self.take(flow, from: source)
                }
                return
            }
            take(flow, from: source)
            return
        }
        if let c = t.copy {
            let s = states(of: c)
            if let on = s[.selected] {
                let now = base(of: c)
                let m = c.instance.flatMap { store.doc.master($0.of) }
                let isOn = m.map { Components.state(of: now, in: $0) == .selected } ?? false
                chosen[c.id] = isOn ? .some(c.instance?.variant == on ? nil : c.instance?.variant) : .some(on)
                return
            }
            if let focus = s[.focused] {
                // One field at a time.
                for (id, v) in chosen where v == focus { chosen[id] = nil }
                chosen[c.id] = .some(focus)
                return
            }
            if wasPressing == c.id { return }
        }
        view?.flash(tappable())
    }

    func scrolled(by dy: CGFloat) {
        guard transit == nil, visit.under == nil, let b = store.seenDoc.node(visit.board) else { return }
        let most = max(0, b.frame.height - screen.height)
        guard most > 0 else { return }
        scroll = min(max(scroll - dy, 0), most)
        view?.scrolled()
    }

    // MARK: What shows

    /// A screen as it shows in the player: at the top left, its copies showing what they are
    /// pointed at or tapped to.
    func shown(_ id: UUID, in seen: BezzleDocument) -> Node? {
        guard var b = seen.node(id), b.isArtboard else { return nil }
        b = b.shownAlone
        b.frame.origin = .zero
        b.children = b.children.map { stated($0, seen: seen) }
        return b
    }

    private func stated(_ n: Node, seen: BezzleDocument) -> Node {
        var n = n
        if let inst = n.instance, let master = seen.master(inst.of) {
            let s = Components.states(of: master)
            var want = base(of: n)
            if !disabled(n) {
                if waiting?.copy == n.id, let l = s[.loading] { want = l }
                else if pressing == n.id, let p = s[.pressed] { want = p }
                else if hovering == n.id, let h = s[.hover] { want = h }
            }
            if Components.variant(want, of: master) != Components.variant(inst.variant, of: master) {
                if let b = built[n.id], b.variant == want, b.version == store.version {
                    n = b.node
                } else {
                    let made = Components.build(Components.switched(n, to: want, in: master), master: master, masterWas: nil, masters: seen.mastersByID)
                    built[n.id] = (want, store.version, made)
                    n = made
                }
            }
        }
        if !n.children.isEmpty {
            n.children = n.children.map { stated($0, seen: seen) }
        }
        return n
    }

    /// What the copies show now, in a few words, to tell one look of a screen from another.
    private var statesKey: String {
        var parts: [String] = []
        if let h = hovering { parts.append("h\(h)") }
        if let p = pressing { parts.append("p\(p)") }
        if let w = waiting { parts.append("w\(w.copy)") }
        for (id, v) in chosen.sorted(by: { $0.key.uuidString < $1.key.uuidString }) { parts.append("c\(id):\(v.map(String.init) ?? "-")") }
        return parts.joined(separator: ",")
    }

    /// A visit as the screen shows it now, to be made into pictures.
    func scene(of v: Visit) -> PlayerScene? {
        let seen = store.seenDoc
        guard let board = shown(v.board, in: seen) else { return nil }
        let fronts = store.fronts.sorted { $0.key.uuidString < $1.key.uuidString }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return PlayerScene(key: "\(v.board)|\(v.under?.uuidString ?? "")|\(store.version)|\(fronts)|\(statesKey)",
                           board: board, under: v.under.flatMap { shown($0, in: seen) }, screen: screen)
    }

    /// The screens the one in front leads to, as they will show when they come on, to be made
    /// into pictures ahead of a tap.
    func nextScenes() -> [PlayerScene] {
        let seen = store.seenDoc
        guard let board = seen.node(visit.board) else { return [] }
        var targets: [UUID] = []
        func look(_ n: Node) {
            if let to = n.flow?.to, !targets.contains(to) { targets.append(to) }
            n.children.forEach(look)
        }
        look(board)
        return targets.prefix(8).compactMap { scene(of: Visit(board: $0, under: nil, way: .instant)) }
    }

    /// Where on the screen in front what can be tapped lies, in the device's points.
    func tappable() -> [CGRect] {
        guard let board = shown(visit.board, in: store.seenDoc) else { return [] }
        let origin: CGPoint = visit.under != nil ? sheetRect(of: board).origin : CGPoint(x: 0, y: -scroll)
        var rects: [CGRect] = []
        func collect(_ nodes: [Node], _ o: CGPoint) {
            for n in nodes where !n.hidden {
                let r = n.frame.offsetBy(dx: o.x, dy: o.y)
                if n.flow?.leads == true || (n.isCopy && !states(of: n).isEmpty) { rects.append(r); continue }
                if !n.children.isEmpty { collect(n.children, CGPoint(x: r.minX, y: r.minY)) }
            }
        }
        collect(board.children, origin)
        return rects
    }

    /// Where a sheet lies on the device's screen: along its foot, in the middle.
    func sheetRect(of board: Node) -> CGRect {
        CGRect(x: (screen.width - board.frame.width) / 2, y: screen.height - board.frame.height, width: board.frame.width, height: board.frame.height)
    }

    /// The screen in front, as a picture, for flying.
    func picture() -> CGImage? {
        guard let s = scene(of: visit) else { return nil }
        return PlayerPictures.composite(s, scroll: scroll, scale: 2, assets: store.assets)
    }
}

// MARK: - From one screen to the next

/// One screen giving way to the next, by the way it comes on; `reverse` plays it backwards, from
/// the second screen to the first, to go back. Its clock starts once its pictures are made.
struct Transit {
    let a: Player.Visit
    let b: Player.Visit
    let way: Prototype.Way
    let reverse: Bool
    var start: CFTimeInterval
    var aScroll: CGFloat = 0
    var bScroll: CGFloat = 0

    var duration: CFTimeInterval {
        switch way {
        case .push(_, let morph): morph ? 0.62 : 0.5
        case .sheet: 0.62
        case .dissolve: 0.34
        case .instant: 0
        }
    }

    /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
    static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

    /// How far it has come, 0 the first screen and 1 the second, as a spring would carry it.
    func progress(_ now: CFTimeInterval) -> (CGFloat, Bool) {
        let t = (now - start) / Self.slow
        if t >= duration { return (reverse ? 0 : 1, true) }
        if t <= 0 { return (reverse ? 1 : 0, false) }
        let x: Double
        switch way {
        case .push(_, let morph):
            let w = morph ? 12.5 : 15.0
            x = 1 - (1 + w * t) * exp(-w * t)
        case .sheet:
            // A little give at the top as it lands.
            let w = 15.0, z = 0.8, wd = w * sqrt(1 - z * z)
            x = 1 - exp(-z * w * t) * (cos(wd * t) + z / sqrt(1 - z * z) * sin(wd * t))
        case .dissolve:
            let u = t / duration
            x = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
        case .instant:
            x = 1
        }
        return (CGFloat(reverse ? 1 - x : x), false)
    }
}

private struct PlayerScreen: NSViewRepresentable {
    let player: Player

    func makeNSView(context: Context) -> PlayerScreenView { PlayerScreenView(player: player) }
    func updateNSView(_ view: PlayerScreenView, context: Context) { view.refresh() }
}

// MARK: - The stage it is played on

/// The prototype played over the design: the stage goes dark, the screen lifts off the canvas and
/// settles into the device it is for, lit from above. Under it, what was said of the way just
/// taken, in the designer's hand; and the few controls there are.
struct PlayerOverlay: View {
    let store: DocumentStore
    let player: Player
    @State private var settled = false
    @State private var shake: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let room = geo.size
            let origin = geo.frame(in: .global).origin
            let fit = min((room.width - 120) / max(player.form.metrics(player.screen).size.width, 1),
                          (room.height - 200) / max(player.form.metrics(player.screen).size.height, 1), 1.25)
            let screen = CGSize(width: player.screen.width * fit, height: player.screen.height * fit)
            let m = player.form.metrics(screen)
            let deviceOrigin = CGPoint(x: (room.width - m.size.width) / 2, y: max(28, (room.height - m.size.height) / 2 - 34))
            let screenRect = m.screen.offsetBy(dx: deviceOrigin.x, dy: deviceOrigin.y)
            let leaving = player.phase == .leaving
            let live = settled && player.phase == .playing
            ZStack(alignment: .topLeading) {
                Stage(lit: settled && !leaving)
                    .onTapGesture { player.close() }
                // The device, coming up round the screen as it lands.
                ZStack(alignment: .topLeading) {
                    FormDrawing(form: player.form, m: m)
                    // The screen dark until the picture lands in it.
                    Color.black
                        .frame(width: screen.width, height: screen.height)
                        .clipShape(player.form.outline(m))
                        .offset(x: m.screen.minX, y: m.screen.minY)
                    PlayerScreen(player: player)
                        .frame(width: screen.width, height: screen.height)
                        .clipShape(player.form.outline(m))
                        .offset(x: m.screen.minX, y: m.screen.minY)
                        .opacity(live ? 1 : 0)
                    if case .phone(true) = player.form {
                        let w = screen.width
                        Capsule().fill(Color.black)
                            .frame(width: w * 0.3, height: max(1.5, w * 0.085))
                            .offset(x: m.screen.midX - w * 0.15, y: m.screen.minY + max(1.2, w * 0.035))
                    }
                }
                .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
                .compositingGroup()
                // Standing on the sheet, lit from above: a soft shadow round it, a darker one where
                // it meets the paper.
                .shadow(color: Color(nsColor: CanvasInk.shadow).opacity(0.22), radius: 34, y: 24)
                .shadow(color: Color(nsColor: CanvasInk.shadow).opacity(0.18), radius: 4, y: 2)
                .scaleEffect(settled && !leaving ? 1 : 0.94)
                .opacity(settled && !leaving ? 1 : 0)
                .offset(x: deviceOrigin.x + shake, y: deviceOrigin.y)
                // The screen as a picture, flying off the canvas and back.
                if let snapshot = player.snapshot, !live {
                    let from = player.canvasRect.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) } ?? screenRect.insetBy(dx: screenRect.width * 0.1, dy: screenRect.height * 0.1)
                    let at = settled && !leaving ? screenRect : from
                    Image(decorative: snapshot, scale: 2)
                        .resizable()
                        .clipShape(RoundedRectangle(cornerRadius: settled && !leaving ? m.radius : 2, style: .continuous))
                        .frame(width: at.width, height: at.height)
                        .offset(x: at.minX, y: at.minY)
                        .opacity(player.canvasRect == nil && (leaving || !settled) ? 0 : 1)
                        .allowsHitTesting(false)
                }
                Under(player: player)
                    .frame(width: max(m.size.width, 420))
                    .offset(x: (room.width - max(m.size.width, 420)) / 2, y: deviceOrigin.y + m.size.height + 22)
                    .opacity(settled && !leaving ? 1 : 0)
                Controls(store: store, player: player)
                    .padding(.top, 18)
                    .padding(.trailing, 22)
                    .frame(width: room.width, alignment: .trailing)
                    .opacity(settled && !leaving ? 1 : 0)
            }
            .frame(width: room.width, height: room.height, alignment: .topLeading)
        }
        .clipped()
        .onAppear {
            withAnimation(.spring(response: 0.52, dampingFraction: 0.82)) { settled = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if player.phase == .arriving { player.phase = .playing }
            }
        }
        .onChange(of: player.phase) { _, now in
            if now == .leaving { withAnimation(.spring(response: 0.44, dampingFraction: 0.9)) { settled = false } }
        }
        .onChange(of: player.refusals) {
            // No way back: the device shakes its head.
            withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) { shake = 0 }
            }
        }
    }
}

/// The sheet the device stands on: the same graph paper as the canvas, its ruling fading away
/// from the middle, and a pool of light falling on it from above, as the home screen's stage is lit.
private struct Stage: View {
    let lit: Bool

    var body: some View {
        let well = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            Theme.paper
            // The same well the canvas lies in, pressed into the paper, as deep.
            ZStack {
                Color(nsColor: FlowInk.stage)
                GraphPaper()
                    .mask(RadialGradient(colors: [.black, .black.opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 80, endRadius: 760))
                RadialGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.15), .clear], center: UnitPoint(x: 0.5, y: 0.32),
                               startRadius: 10, endRadius: 520)
                    .blendMode(.softLight)
            }
            .clipShape(well)
            .overlay {
                // Its rim: a soft shadow where it dips under the paper, and a hairline all round.
                well.strokeBorder(Theme.shadow.opacity(0.22), lineWidth: 1.5)
                    .blur(radius: 1.5)
                    .offset(y: 1)
                    .mask(well)
                well.strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 9)
        }
        .opacity(lit ? 1 : 0)
        .animation(.easeOut(duration: lit ? 0.35 : 0.3), value: lit)
        .contentShape(Rectangle())
    }
}

/// Millimetre paper, ruled in the pencil's blue: fine lines `step` apart, every fifth a stronger one.
struct GraphPaper: View {
    var step: CGFloat = 9
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { ctx, size in
            var minor = Path(), major = Path()
            func crisp(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
            var i = 0
            while CGFloat(i) * step <= size.width {
                let x = crisp(CGFloat(i) * step)
                if i % 5 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height)) }
                else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)) }
                i += 1
            }
            var j = 0
            while CGFloat(j) * step <= size.height {
                let y = crisp(CGFloat(j) * step)
                if j % 5 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y)) }
                else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)) }
                j += 1
            }
            ctx.stroke(minor, with: .color(Color(nsColor: FlowInk.ruling)), lineWidth: 1 / scale)
            ctx.stroke(major, with: .color(Color(nsColor: FlowInk.rulingMajor)), lineWidth: 1 / scale)
        }
        .allowsHitTesting(false)
    }
}

/// Under the device: what was said of the way just taken, written out by hand, and where it is.
private struct Under: View {
    let player: Player
    @State private var written: CGFloat = 0

    var body: some View {
        let name = player.store.seenDoc.node(player.visit.board)?.name ?? ""
        VStack(spacing: 8) {
            ZStack {
                if let caption = player.caption {
                    Text(verbatim: caption.text)
                        .font(.custom("Bradley Hand", size: 21))
                        .foregroundStyle(Color(nsColor: FlowInk.note))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .mask(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle().frame(width: g.size.width * written + 30)
                            }
                        }
                        .id(caption.token)
                        .onAppear {
                            written = 0
                            withAnimation(.easeOut(duration: Double(min(0.4 + Double(caption.text.count) * 0.025, 1.2))).delay(0.2)) { written = 1 }
                        }
                        .transition(.opacity)
                }
            }
            .frame(height: 30)
            Text(verbatim: name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: name)
        }
        .animation(.easeOut(duration: 0.25), value: player.caption)
        .allowsHitTesting(false)
    }
}

/// Back, from the start again, and done: round, quiet, light on the dark.
private struct Controls: View {
    let store: DocumentStore
    let player: Player

    var body: some View {
        HStack(spacing: 8) {
            RoundButton(symbol: "chevron.left", help: "Back  ←", enabled: player.history.count > 1) { player.back() }
            RoundButton(symbol: "arrow.counterclockwise", help: "From the Start  R", enabled: player.history.count > 1) { player.restart() }
            RoundButton(symbol: "xmark", help: "Stop Playing  esc", enabled: true) { player.close() }
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let help: LocalizedStringResource
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? (hovering ? Theme.ink : Theme.ink2) : Theme.ink4)
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(Theme.card)
                    .shadow(color: Theme.shadow.opacity(hovering && enabled ? 0.16 : 0.07), radius: hovering && enabled ? 8 : 3, y: hovering && enabled ? 3 : 1)
            }
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture { if enabled { action() } }
            .help(Text(help))
            .scaleEffect(hovering && enabled ? 1.06 : 1)
            .animation(Theme.quick, value: hovering)
            .accessibilityLabel(Text(help))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
}
