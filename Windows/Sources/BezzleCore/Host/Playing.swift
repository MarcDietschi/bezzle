import Foundation
import CBezzleHost

// The prototype played on Windows, as the Mac's Player (Views/Player.swift) and its pictures
// (Views/PlayerStage.swift) have it: the screens it has been through, how the one in front came
// on, and what its copies of components show as they are pointed at and tapped. The device's
// screen shows pictures made once and then only moved about, as the Mac's Core Animation layers
// are: here a `Shot` says which pictures there are and where each lies as a move goes on, and the
// app moves its images there, frame by frame, as a spring carries them. Nothing is drawn while
// they move.

extension WindowsCore {
    /// A clock for the moves, in seconds, finer than a frame: Windows' uptime only moves on with
    /// the system's tick, every 15.6 milliseconds, which would make a move step unevenly. Read on
    /// any thread: work away from the main thread says when its steps began (`CutoutMaker.Progress`).
    nonisolated public static var now: Double {
        let d = ContinuousClock.now - clockStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
    nonisolated private static let clockStart = ContinuousClock.now

    @MainActor public final class Player {
        /// A screen shown, and how it came to be.
        public struct Visit: Equatable {
            public let board: UUID
            /// A sheet: the screen it opened over, dimmed under it.
            public let under: UUID?
            /// How it came on, to go back the same way.
            let way: Prototype.Way
        }

        public private(set) var history: [Visit]
        public var visit: Visit { history[history.count - 1] }

        public enum Phase { case arriving, playing, leaving }
        public var phase: Phase = .arriving
        /// The thing it is played on, as `sizes()` names one (its family and name), and the size
        /// of its screen in the design's points.
        public let device: (group: String, name: String)
        public let screen: CGSize
        /// What was said of the flow just taken, written under the device; counted, so each is
        /// written out anew.
        public private(set) var caption: String?
        public private(set) var captions = 0
        /// Counts the times there was no way back, for the device to shake its head.
        public private(set) var refusals = 0

        /// What shows changed: the screen at rest (`rest()`), the caption, the controls.
        public var changed: () -> Void = {}
        /// A move between screens to play (`motion()`), from its start.
        public var moving: () -> Void = {}
        /// Everything that can be tapped, to light for a moment, in the device's points.
        public var flash: ([CGRect]) -> Void = { _ in }
        /// The screen in front scrolled.
        public var scrolled: () -> Void = {}
        /// The end of playing: the screen to fly back to on the canvas.
        public var closing: (UUID) -> Void = { _ in }

        // What the copies of components show. Variants by copy, as taps chose them.
        private var chosen: [UUID: Int?] = [:]
        private var hovering: UUID?
        private var pressing: UUID?
        /// A copy showing that it is loading, before its flow is taken.
        private var waiting: (copy: UUID, flow: FlowLink)?
        /// The move under way, and the two screens as they showed when it began.
        public private(set) var transit: Transit?
        private var scenes: (a: Scene?, b: Scene?)
        /// How far a screen taller than the device is scrolled down.
        public private(set) var scroll: CGFloat = 0
        /// Copies made again as another variant, by copy. The design does not change while it is
        /// played: the player covers it.
        private var built: [UUID: (variant: Int?, node: Node)] = [:]
        /// Counts the screens come on, so a timer set for one does nothing on another.
        private var arrivals = 0

        public init?(start: UUID) {
            guard let board = WindowsCore.design?.node(start), board.isArtboard else { return nil }
            let (device, screen) = Self.device(for: board.frame.size)
            self.device = device
            self.screen = screen
            history = [Visit(board: start, under: nil, way: .instant)]
            arrived()
        }

        private var seen: BezzleDocument? { WindowsCore.design }

        // MARK: The device

        /// What a screen of this size is played on, and the size of the device's screen: a phone
        /// for a phone's screen, a browser for a page, and a long page scrolls in a screen of the
        /// device's height.
        static func device(for size: CGSize) -> ((group: String, name: String), CGSize) {
            let screens: Set<Preset.Group> = [.iPhone, .android, .iPad, .mac, .web, .watch]
            if let p = Preset.all.first(where: { abs($0.size.width - size.width) < 0.5 && abs($0.size.height - size.height) < 0.5 }) {
                return ((p.group.rawValue, p.name), size)
            }
            if let p = Preset.all.first(where: { screens.contains($0.group) && abs($0.size.width - size.width) < 0.5 && $0.size.height < size.height }) {
                return ((p.group.rawValue, p.name), p.size)
            }
            let w = size.width, h = size.height
            if w <= 460, h >= w * 1.3 { return (("iPhone", ""), CGSize(width: w, height: min(h, (w * 2.17).rounded()))) }
            if w <= 1100, h >= w * 0.6 { return (("iPad", ""), CGSize(width: w, height: min(h, (w * 1.4).rounded()))) }
            if w > 1100 { return (("web", ""), CGSize(width: w, height: min(h, (w * 0.62).rounded()))) }
            return (("post", ""), size)
        }

        // MARK: Moving between screens

        public var animating: Bool { transit != nil || waiting != nil }
        public var canGoBack: Bool { history.count > 1 }
        /// The name of the screen in front.
        public var name: String { seen?.node(visit.board)?.name ?? "" }

        /// Takes a flow from a layer on the screen in front.
        func take(_ flow: FlowLink, from source: UUID) {
            if flow.goesBack { back(); return }
            guard let seen, let to = flow.to, let target = seen.node(to), target.isArtboard, let here = seen.node(visit.board) else { return }
            finishTransit()
            let way = Prototype.way(from: visit.under.flatMap { seen.node($0) } ?? here, to: target, motion: flow.motion)
            let next = Visit(board: to, under: way == .sheet ? (visit.under ?? visit.board) : nil, way: way)
            let from = visit
            // As it shows at the tap, pointed at as it is.
            let fromScene = scene(of: from)
            history.append(next)
            caption = flow.note.flatMap { $0.isEmpty ? nil : $0 }
            captions += 1
            let aScroll = scroll
            scroll = 0
            hovering = nil
            pressing = nil
            if way.moves {
                transit = Transit(a: from, b: next, way: way, reverse: false, aScroll: aScroll)
                scenes = (fromScene, scene(of: next))
                moving()
            }
            changed()
            arrived()
        }

        /// Back to the screen before, the way this one came on, undone.
        public func back() {
            guard history.count > 1 else {
                refusals += 1
                changed()
                return
            }
            finishTransit()
            let leavingScene = scene(of: visit)
            let leaving = history.removeLast()
            if caption != nil { caption = nil; captions += 1 }
            let bScroll = scroll
            scroll = 0
            hovering = nil
            pressing = nil
            if leaving.way.moves {
                transit = Transit(a: visit, b: leaving, way: leaving.way, reverse: true, bScroll: bScroll)
                scenes = (scene(of: visit), leavingScene)
                moving()
            }
            changed()
            arrived()
        }

        /// From the start again.
        public func restart() {
            guard history.count > 1 || scroll != 0 else { return }
            finishTransit()
            let first = history[0]
            let leaving = visit
            let leavingScene = scene(of: leaving)
            history = [first]
            chosen = [:]
            if caption != nil { caption = nil; captions += 1 }
            let bScroll = scroll
            scroll = 0
            hovering = nil
            pressing = nil
            transit = Transit(a: first, b: leaving, way: .dissolve, reverse: true, bScroll: bScroll)
            scenes = (scene(of: first), leavingScene)
            moving()
            changed()
            arrived()
        }

        private func finishTransit() {
            transit = nil
            scenes = (nil, nil)
            waiting = nil
        }

        /// The move's pictures are there: its clock starts.
        public func startMoving() { transit?.start = WindowsCore.now }

        /// The move has come to its end, or could not be shown.
        public func doneMoving() {
            transit = nil
            scenes = (nil, nil)
        }

        /// A screen has come on: one that goes on by itself is timed.
        private func arrived() {
            arrivals += 1
            guard let board = seen?.node(visit.board), let flow = board.flow, flow.leads, let after = flow.after else { return }
            let at = visit, count = arrivals
            DispatchQueue.main.asyncAfter(deadline: .now() + max(after, 0.1)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.arrivals == count, self.visit == at, self.phase != .leaving else { return }
                    self.take(flow, from: board.id)
                }
            }
        }

        /// Done with at once, as when the design stops being seen as a prototype.
        public func stop() {
            finishTransit()
            arrivals += 1
        }

        /// The end of playing: the screen flies back to where it lies on the canvas.
        public func close() {
            guard phase != .leaving else { return }
            finishTransit()
            arrivals += 1
            phase = .leaving
            closing(visit.board)
        }

        /// A key while playing: Escape stops, Left or Backspace goes back, R starts again.
        public func key(_ key: String) -> Bool {
            guard phase == .playing else { return false }
            switch key {
            case "escape": close()
            case "left", "back": back()
            case "r": restart()
            default: return false
            }
            return true
        }

        /// Where on the canvas the screen in front lies, as much of it as the device shows: the
        /// top of a long page.
        public func canvasFrame(of board: UUID) -> CGRect? {
            guard let b = seen?.node(board) else { return nil }
            var r = b.frame
            if r.height > screen.height { r.size.height = screen.height }
            return r
        }

        // MARK: Pointing and tapping

        /// What lies at a point of the device's screen (in the design's points): the screen it is
        /// on, where on it, or nil off a sheet.
        private func place(_ p: CGPoint) -> (board: Node, local: CGPoint)? {
            guard let seen, let board = shown(visit.board, in: seen) else { return nil }
            if visit.under != nil {
                let r = sheetRect(of: board)
                guard r.contains(p) else { return nil }
                return (board, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
            }
            return (board, CGPoint(x: p.x, y: p.y + scroll))
        }

        /// The layer at a point that goes somewhere, and the copy it lies in that has states.
        private func target(at p: CGPoint) -> (flow: (UUID, FlowLink)?, copy: Node?, offSheet: Bool) {
            guard let (board, local) = place(p) else { return (nil, nil, visit.under != nil) }
            let chain = Prototype.chain(at: local, in: board)
            let flow = chain.first { $0.flow?.leads == true }.map { ($0.id, $0.flow!) }
            let copy = chain.first { $0.isCopy && !states(of: $0).isEmpty }
            return (flow, copy, false)
        }

        private func states(of copy: Node) -> [VariantState: Int?] {
            guard let m = copy.instance.flatMap({ seen?.master($0.of) }) else { return [:] }
            return Components.states(of: m)
        }

        private func base(of copy: Node) -> Int? {
            if let c = chosen[copy.id] { return c }
            return copy.instance?.variant
        }

        private func disabled(_ copy: Node) -> Bool {
            guard let m = copy.instance.flatMap({ seen?.master($0.of) }) else { return false }
            return Components.state(of: base(of: copy), in: m) == .disabled
        }

        /// The pointer at a point of the device's screen, or gone: whether what is there can be tapped.
        public func hover(at p: CGPoint?) -> Bool {
            guard transit == nil, phase == .playing else { return false }
            let t = p.map(target(at:))
            let copy = t?.copy.flatMap { c in states(of: c)[.hover] != nil && !disabled(c) ? c.id : nil }
            if copy != hovering {
                hovering = copy
                changed()
            }
            guard let t else { return false }
            return t.flow != nil || t.copy.map { !disabled($0) } == true || t.offSheet
        }

        public func down(at p: CGPoint) {
            guard phase == .playing else { return }
            let t = target(at: p)
            if let c = t.copy, !disabled(c), states(of: c)[.pressed] != nil {
                pressing = c.id
                changed()
            }
        }

        public func up(at p: CGPoint) {
            guard phase == .playing else { return }
            let wasPressing = pressing
            pressing = nil
            let t = target(at: p)
            defer { changed() }
            if t.offSheet { back(); return }
            if let c = t.copy, disabled(c) { return }
            if let (source, flow) = t.flow {
                if let c = t.copy, states(of: c)[.loading] != nil {
                    waiting = (c.id, flow)
                    changed()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, let w = self.waiting, w.copy == c.id else { return }
                            self.waiting = nil
                            self.take(flow, from: source)
                        }
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
                    let m = c.instance.flatMap { seen?.master($0.of) }
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
            flash(tappable())
        }

        /// The wheel turned over the device: a screen taller than it scrolls.
        public func scroll(by dy: CGFloat) {
            guard transit == nil, visit.under == nil, let b = seen?.node(visit.board) else { return }
            let most = max(0, b.frame.height - screen.height)
            guard most > 0 else { return }
            scroll = min(max(scroll - dy, 0), most)
            scrolled()
        }

        // MARK: What shows

        /// A visit to a screen as it shows at one moment: the screen with its copies' states, and
        /// for a sheet the screen under it. Its key tells one look of it from another.
        struct Scene {
            let key: String
            let board: Node
            let under: Node?
            let screen: CGSize

            var sheetRect: CGRect {
                CGRect(x: (screen.width - board.frame.width) / 2, y: screen.height - board.frame.height, width: board.frame.width, height: board.frame.height)
            }
        }

        /// A screen as it shows in the player: at the top left, its copies showing what they are
        /// pointed at or tapped to.
        private func shown(_ id: UUID, in seen: BezzleDocument) -> Node? {
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
                    if let b = built[n.id], b.variant == want {
                        n = b.node
                    } else {
                        let made = Components.build(Components.switched(n, to: want, in: master), master: master, masterWas: nil, masters: seen.mastersByID)
                        built[n.id] = (want, made)
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

        private func scene(of v: Visit) -> Scene? {
            guard let seen, let board = shown(v.board, in: seen) else { return nil }
            return Scene(key: "\(v.board)|\(v.under?.uuidString ?? "")|\(statesKey)", board: board,
                         under: v.under.flatMap { shown($0, in: seen) }, screen: screen)
        }

        /// Where on the screen in front what can be tapped lies, in the device's points.
        private func tappable() -> [CGRect] {
            guard let seen, let board = shown(visit.board, in: seen) else { return [] }
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
        private func sheetRect(of board: Node) -> CGRect {
            CGRect(x: (screen.width - board.frame.width) / 2, y: screen.height - board.frame.height, width: board.frame.width, height: board.frame.height)
        }

        /// The screen in front as one picture, `scale` pixels to the design's point, for flying
        /// off the canvas and back.
        public func snapshot(scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
            guard let s = scene(of: visit) else { return false }
            let scroll = scroll
            return WindowsCore.picture({ PlayerPictures.composite(s, scroll: scroll, scale: CGFloat(scale)) }, into: fill)
        }

        // MARK: The pictures, and where they lie

        /// The screen at rest: its picture, where it lies scrolled.
        public func rest() -> Shot? {
            guard let s = scene(of: visit) else { return nil }
            let frame = restFrame(s), scrolls = s.under == nil
            return Shot(key: s.key, sprites: [restSprite(s)]) { [weak self] _ in
                [Spot(rect: scrolls ? frame.offsetBy(dx: 0, dy: -(self?.scroll ?? 0)) : frame)]
            }
        }

        /// The screens the one in front leads to, as they will show when they come on, to be made
        /// into pictures ahead of a tap.
        public func ahead() -> [Sprite] {
            guard let seen, let board = seen.node(visit.board) else { return [] }
            var targets: [UUID] = []
            func look(_ n: Node) {
                if let to = n.flow?.to, !targets.contains(to) { targets.append(to) }
                n.children.forEach(look)
            }
            look(board)
            return targets.prefix(8).compactMap { scene(of: Visit(board: $0, under: nil, way: .instant)).map { boardSprite($0) } }
        }

        /// The move under way: the pictures of both screens, or of their layers for a morph, and
        /// where they lie part of the way (0 the first screen, 1 the second).
        public func motion() -> Shot? {
            guard let t = transit, let a = scenes.a, let b = scenes.b else { return nil }
            switch t.way {
            case .push(let from, true) where a.under == nil && b.under == nil:
                return morph(t, a, b, from: from)
            case .push(let from, _):
                return slide(t, a, b, from: from)
            case .sheet:
                return sheet(t, a, b)
            default:
                return dissolve(t, a, b)
            }
        }

        /// One picture moved about: a screen, a layer, the dark that dims a screen, or a shadow.
        public struct Sprite {
            public enum Look { case picture, dark }
            public let look: Look
            /// What it is called: the same name, the same picture, to keep and use again.
            public let key: String
            /// Its top corners' radius, in the device's points: a sheet's.
            public var corners: Double = 0
            let draw: ((Double, (Int, Int) -> UnsafeMutableRawPointer?) -> Bool)?

            /// Draws its picture `scale` pixels to the device's point, into premultiplied BGRA
            /// pixels, rows top first, which `fill` gives once it knows the size.
            public func make(scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
                draw?(scale, fill) ?? false
            }
        }

        /// Where a sprite lies, in the device's points, and how much of it shows.
        public struct Spot {
            public var rect: CGRect
            public var opacity: Double = 1
        }

        /// The pictures the screen shows, and where each lies part of the way, in the same order.
        public struct Shot {
            public let key: String
            public let sprites: [Sprite]
            public let place: (CGFloat) -> [Spot]
        }

        private func boardSprite(_ s: Scene, skipping: Set<UUID> = [], only: Set<UUID>? = nil, background: Bool = true, tag: String = "board") -> Sprite {
            Sprite(look: .picture, key: "\(s.key)#\(tag)") { scale, fill in
                WindowsCore.picture({ PlayerPictures.board(s.board, screen: s.screen, scale: CGFloat(scale), skipping: skipping, only: only, background: background) }, into: fill)
            }
        }

        private func sheetSprite(_ s: Scene) -> Sprite {
            Sprite(look: .picture, key: "\(s.key)#sheet") { scale, fill in
                WindowsCore.picture({ PlayerPictures.composite(s, scroll: 0, scale: CGFloat(scale)) }, into: fill)
            }
        }

        /// A visit's picture as it rests: a screen whole, to scroll; a sheet over its screen, at
        /// the device's size.
        private func restSprite(_ s: Scene) -> Sprite { s.under == nil ? boardSprite(s) : sheetSprite(s) }

        private func restFrame(_ s: Scene) -> CGRect {
            guard s.under == nil else { return CGRect(origin: .zero, size: s.screen) }
            let f = PlayerPictures.fit(s.board, in: s.screen)
            return CGRect(x: 0, y: 0, width: s.board.frame.width * f, height: s.board.frame.height * f)
        }

        /// Where a visit's picture lies at rest, scrolled.
        private func placed(_ s: Scene, scroll: CGFloat) -> CGRect {
            restFrame(s).offsetBy(dx: 0, dy: s.under == nil ? -scroll : 0)
        }

        private static let dark = Sprite(look: .dark, key: "dark", draw: nil)

        /// A soft shadow round `size`, `blur` points, `alpha` deep, fallen `dy`: its picture
        /// reaches `pad` past the size each way.
        private static func shadow(_ size: CGSize, blur: Double, dy: Double, alpha: Double) -> (Sprite, CGFloat) {
            let pad = CGFloat((blur * 2 + abs(dy)).rounded(.up))
            let sprite = Sprite(look: .picture, key: "shadow\(Int(size.width))x\(Int(size.height))b\(blur)y\(dy)a\(alpha)") { scale, fill in
                let w = Int((Double(size.width) * scale).rounded()), h = Int((Double(size.height) * scale).rounded())
                let p = Int((Double(pad) * scale).rounded())
                guard w > 0, h > 0, let pixels = fill(w + 2 * p, h + 2 * p) else { return false }
                return bz_shadow(Int32(w), Int32(h), Int32(p), blur * scale, dy * scale, 0x000000, alpha, pixels) == 0
            }
            return (sprite, pad)
        }

        /// The next screen slides in from its side over the one before, which gives way a little
        /// and dims under its shadow; what both have alike stays put over them.
        private func slide(_ t: Transit, _ a: Scene, _ b: Scene, from: CGVector) -> Shot {
            var shared: (a: Set<UUID>, b: Set<UUID>) = ([], [])
            if a.under == nil, b.under == nil, t.aScroll == 0, t.bScroll == 0 {
                let byID = Dictionary(b.board.children.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                for (id, m) in Prototype.matches(a.board.children, b.board.children) where byID[id].map({ Prototype.same(m, $0) }) == true {
                    shared.a.insert(m.id)
                    shared.b.insert(id)
                }
            }
            let sharing = !shared.a.isEmpty
            var sprites: [Sprite]
            if sharing {
                let tag = "less\(shared.b.count)"
                sprites = [boardSprite(a, skipping: shared.a, tag: tag), boardSprite(b, skipping: shared.b, tag: tag)]
            } else {
                sprites = [restSprite(a), restSprite(b)]
            }
            let screenRect = CGRect(origin: .zero, size: screen)
            let (shade, pad) = Self.shadow(screen, blur: 14, dy: 0, alpha: 0.32)
            // The first screen, its dark, the second's shadow, the second, what they share.
            sprites.insert(Self.dark, at: 1)
            sprites.insert(shade, at: 2)
            if sharing { sprites.append(boardSprite(b, only: shared.b, background: false, tag: "shared")) }
            let aFrame = sharing ? restFrame(a) : placed(a, scroll: t.aScroll)
            let bFrame = sharing ? restFrame(b) : placed(b, scroll: t.bScroll)
            let sharedFrame = restFrame(b)
            let span = CGPoint(x: from.dx * screen.width, y: from.dy * screen.height)
            return Shot(key: "slide", sprites: sprites) { p in
                let aOff = CGPoint(x: -span.x * 0.28 * p, y: -span.y * 0.28 * p)
                let bOff = CGPoint(x: span.x * (1 - p), y: span.y * (1 - p))
                var spots = [
                    Spot(rect: aFrame.offsetBy(dx: aOff.x, dy: aOff.y)),
                    Spot(rect: screenRect.offsetBy(dx: aOff.x, dy: aOff.y), opacity: Double(0.2 * p)),
                    Spot(rect: screenRect.insetBy(dx: -pad, dy: -pad).offsetBy(dx: bOff.x, dy: bOff.y), opacity: Double(min(1, (1 - p) * 4))),
                    Spot(rect: bFrame.offsetBy(dx: bOff.x, dy: bOff.y)),
                ]
                if sharing { spots.append(Spot(rect: sharedFrame)) }
                return spots
            }
        }

        /// The sheet rises over the screen it opens on, which dims under it.
        private func sheet(_ t: Transit, _ a: Scene, _ b: Scene) -> Shot {
            let r = b.sheetRect
            let (shade, pad) = Self.shadow(r.size, blur: 14, dy: -2, alpha: 0.3)
            var top = boardSprite(b)
            top.corners = Double(PlayerPictures.sheetRadius(r))
            let under = placed(a, scroll: t.aScroll), screenRect = CGRect(origin: .zero, size: screen)
            let drop = r.height + 24
            return Shot(key: "sheet", sprites: [restSprite(a), Self.dark, shade, top]) { p in
                let y = drop * (1 - p)
                return [Spot(rect: under), Spot(rect: screenRect, opacity: Double(0.34 * p)),
                        Spot(rect: r.insetBy(dx: -pad, dy: -pad).offsetBy(dx: 0, dy: y)), Spot(rect: r.offsetBy(dx: 0, dy: y))]
            }
        }

        /// The next screen fades in over the one before.
        private func dissolve(_ t: Transit, _ a: Scene, _ b: Scene) -> Shot {
            let ra = placed(a, scroll: t.aScroll), rb = placed(b, scroll: t.bScroll)
            return Shot(key: "dissolve", sprites: [restSprite(a), restSprite(b)]) { p in
                [Spot(rect: ra), Spot(rect: rb, opacity: Double(p))]
            }
        }

        /// A layer of the first screen and the same layer on the second, or one that is only on
        /// one of them, each lying in what holds it at an origin on its screen.
        private struct Piece {
            var from: Node?
            var fromOrigin: CGPoint = .zero
            var to: Node?
            var toOrigin: CGPoint = .zero
        }

        /// The two screens' layers paired by name, groups that are alike taken apart into theirs.
        private func morphPieces(_ a: Node, _ b: Node) -> [Piece] {
            var out: [Piece] = []
            func pair(_ x: [Node], _ xo: CGPoint, _ y: [Node], _ yo: CGPoint) {
                let pairs = Prototype.matches(x, y)
                let used = Set(pairs.values.map(\.id))
                for m in x where !m.hidden && !used.contains(m.id) { out.append(Piece(from: m, fromOrigin: xo)) }
                for n in y where !n.hidden {
                    guard let m = pairs[n.id] else { out.append(Piece(to: n, toOrigin: yo)); continue }
                    if PlayerPictures.apart(m), PlayerPictures.apart(n) {
                        pair(m.children, CGPoint(x: xo.x + m.frame.minX, y: xo.y + m.frame.minY), n.children, CGPoint(x: yo.x + n.frame.minX, y: yo.y + n.frame.minY))
                    } else {
                        out.append(Piece(from: m, fromOrigin: xo, to: n, toOrigin: yo))
                    }
                }
            }
            pair(a.children, .zero, b.children, .zero)
            return out
        }

        /// What the two screens share moves to its new place and takes its new look; what is only
        /// on the first fades as it drifts away, and what is only on the second fades in, drifting
        /// into place from the side it comes from; the ground between them changes colour.
        private func morph(_ t: Transit, _ a: Scene, _ b: Scene, from: CGVector) -> Shot {
            let pieces = morphPieces(a.board, b.board)
            var sprites = [boardSprite(a, only: [], tag: "ground"), boardSprite(b, only: [], tag: "ground")]
            let groundA = restFrame(a), groundB = restFrame(b)
            /// Each piece's sprites: the first screen's layer, the second's, where each lies.
            var moving: [(a: Int?, b: Int?, ra: CGRect?, rb: CGRect?)] = []
            let key = "\(a.key)>\(b.key)"
            for (i, p) in pieces.enumerated() {
                var entry: (a: Int?, b: Int?, ra: CGRect?, rb: CGRect?) = (nil, nil, nil, nil)
                if let n = p.from, let r = PlayerPictures.layerRect(n, origin: p.fromOrigin) {
                    let board = a.board, origin = p.fromOrigin
                    entry.a = sprites.count
                    entry.ra = r
                    sprites.append(Sprite(look: .picture, key: "\(key)#m\(i)a") { scale, fill in
                        WindowsCore.picture({ PlayerPictures.layer(n, origin: origin, board: board, scale: CGFloat(scale)) }, into: fill)
                    })
                }
                if let n = p.to, let r = PlayerPictures.layerRect(n, origin: p.toOrigin) {
                    let board = b.board, origin = p.toOrigin
                    entry.b = sprites.count
                    entry.rb = r
                    sprites.append(Sprite(look: .picture, key: "\(key)#m\(i)b") { scale, fill in
                        WindowsCore.picture({ PlayerPictures.layer(n, origin: origin, board: board, scale: CGFloat(scale)) }, into: fill)
                    })
                }
                if entry.a != nil || entry.b != nil { moving.append(entry) }
            }
            let drift: CGFloat = 22, count = sprites.count
            func smooth(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
                let u = min(max((x - e0) / (e1 - e0), 0), 1)
                return u * u * (3 - 2 * u)
            }
            func mix(_ r: CGRect, _ s: CGRect, _ p: CGFloat) -> CGRect {
                CGRect(x: r.minX + (s.minX - r.minX) * p, y: r.minY + (s.minY - r.minY) * p,
                       width: r.width + (s.width - r.width) * p, height: r.height + (s.height - r.height) * p)
            }
            return Shot(key: "morph", sprites: sprites) { p in
                let dy = -(t.aScroll * (1 - p) + t.bScroll * p)
                var spots = [Spot](repeating: Spot(rect: .zero, opacity: 0), count: count)
                spots[0] = Spot(rect: groundA.offsetBy(dx: 0, dy: dy))
                spots[1] = Spot(rect: groundB.offsetBy(dx: 0, dy: dy), opacity: Double(p))
                for m in moving {
                    if let ra = m.ra, let rb = m.rb, let ia = m.a, let ib = m.b {
                        let r = mix(ra, rb, p).offsetBy(dx: 0, dy: dy)
                        spots[ia] = Spot(rect: r, opacity: Double(1 - smooth(0.35, 1, p)))
                        spots[ib] = Spot(rect: r, opacity: Double(smooth(0, 0.65, p)))
                    } else if let ra = m.ra, let ia = m.a {
                        spots[ia] = Spot(rect: ra.offsetBy(dx: -from.dx * drift * p, dy: -from.dy * drift * p + dy), opacity: Double(1 - p))
                    } else if let rb = m.rb, let ib = m.b {
                        spots[ib] = Spot(rect: rb.offsetBy(dx: from.dx * drift * (1 - p), dy: from.dy * drift * (1 - p) + dy), opacity: Double(p))
                    }
                }
                return spots
            }
        }
    }

    /// One screen giving way to the next, by the way it comes on; `reverse` plays it backwards,
    /// from the second screen to the first, to go back. Its clock starts once its pictures are made.
    public struct Transit {
        let a: Player.Visit
        let b: Player.Visit
        let way: Prototype.Way
        let reverse: Bool
        var start: Double = .infinity
        var aScroll: CGFloat = 0
        var bScroll: CGFloat = 0

        init(a: Player.Visit, b: Player.Visit, way: Prototype.Way, reverse: Bool, aScroll: CGFloat = 0, bScroll: CGFloat = 0) {
            self.a = a
            self.b = b
            self.way = way
            self.reverse = reverse
            self.aScroll = aScroll
            self.bScroll = bScroll
        }

        var duration: Double {
            switch way {
            case .push(_, let morph): morph ? 0.62 : 0.5
            case .sheet: 0.62
            case .dissolve: 0.34
            case .instant: 0
            }
        }

        /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
        static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

        /// How far it has come at `now`, 0 the first screen and 1 the second, as a spring would
        /// carry it, and whether it is over.
        public func progress(_ now: Double) -> (CGFloat, Bool) {
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
                let w = 15.0, z = 0.8, wd = w * (1 - z * z).squareRoot()
                x = 1 - exp(-z * w * t) * (cos(wd * t) + z / (1 - z * z).squareRoot() * sin(wd * t))
            case .dissolve:
                let u = t / duration
                x = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            case .instant:
                x = 1
            }
            return (CGFloat(reverse ? 1 - x : x), false)
        }
    }

    /// Draws a picture the core makes, inside `make`, so the pictures it draws with are sent to
    /// Skia, and reads it into premultiplied BGRA pixels, rows top first.
    static func picture(_ make: () -> CGImage?, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = make() else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }
}

/// Pictures of the prototype's screens, as the Mac's PlayerPictures makes them.
@MainActor enum PlayerPictures {
    /// How much smaller a screen wider than the device is drawn, to fit across it.
    nonisolated static func fit(_ board: Node, in screen: CGSize) -> CGFloat {
        board.frame.width > screen.width + 0.5 ? screen.width / board.frame.width : 1
    }

    /// A screen whole, all its height, `scale` pixels to its point, fitted across the device:
    /// with only some of its layers, or all but some, or without its own ground.
    static func board(_ b: Node, screen: CGSize, scale: CGFloat, skipping: Set<UUID> = [], only: Set<UUID>? = nil,
                      background: Bool = true) -> CGImage? {
        var b = b
        b.frame.origin = .zero
        if let only { b.children = b.children.filter { only.contains($0.id) } }
        if !skipping.isEmpty { b.children.removeAll { skipping.contains($0.id) } }
        let f = fit(b, in: screen)
        let size = CGSize(width: max(1, (b.frame.width * f * scale).rounded()), height: max(1, (b.frame.height * f * scale).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale * f, y: -scale * f)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale * f
            o.assets = WindowsCore.assets
            Renderer.drawArtboard(b, in: ctx, options: o, background: background)
        }
        return ctx.makeImage()
    }

    /// Where one layer's picture lies on its screen: all it paints, its shadow too.
    static func layerRect(_ n: Node, origin: CGPoint) -> CGRect? {
        let r = Renderer.reach(of: n).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1).integral
        guard r.width > 0, r.height > 0, r.width < 3000, r.height < 3000 else { return nil }
        return r
    }

    /// One layer alone, lying in what holds it at `origin` on its screen, with all it paints
    /// round it.
    static func layer(_ n: Node, origin: CGPoint, board: Node, scale: CGFloat) -> CGImage? {
        guard let r = layerRect(n, origin: origin) else { return nil }
        let size = CGSize(width: max(1, (r.width * scale).rounded()), height: max(1, (r.height * scale).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = WindowsCore.assets
            o.board = board
            o.offset = origin
            ctx.translateBy(x: origin.x, y: origin.y)
            Renderer.drawNode(n, in: ctx, options: o)
        }
        return ctx.makeImage()
    }

    /// The device's screen as one picture: a screen scrolled, or a sheet over the screen under it.
    static func composite(_ s: WindowsCore.Player.Scene, scroll: CGFloat, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: (s.screen.width * scale).rounded(), height: (s.screen.height * scale).rounded())
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = WindowsCore.assets
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: s.screen))
            func draw(_ b: Node, at p: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                let f = fit(b, in: s.screen)
                ctx.scaleBy(x: f, y: f)
                var b = b
                b.frame.origin = .zero
                Renderer.drawArtboard(b, in: ctx, options: o)
                ctx.restoreGState()
            }
            if let under = s.under {
                draw(under, at: .zero)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.34))
                ctx.fill(CGRect(origin: .zero, size: s.screen))
                let r = s.sheetRect
                let path = sheetPath(r)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
                ctx.addPath(path)
                ctx.setFillColor(s.board.fill.on ? s.board.fill.color.cgColor : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                draw(s.board, at: r.origin)
                ctx.restoreGState()
            } else {
                draw(s.board, at: CGPoint(x: 0, y: -scroll))
            }
        }
        return ctx.makeImage()
    }

    /// A sheet's outline: its top corners round, running on past the foot of the screen.
    static func sheetPath(_ r: CGRect) -> CGPath {
        let radius = sheetRadius(r)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.maxY + 40))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 40))
        path.closeSubpath()
        return path
    }

    static func sheetRadius(_ r: CGRect) -> CGFloat { min(16, r.width * 0.04) }

    /// Whether a group can be taken apart into its layers for a morph and look the same:
    /// nothing done to it as a whole.
    static func apart(_ g: Node) -> Bool {
        g.isGroup && g.mask == nil && g.clipsToFirst != true && g.opacity >= 0.999 && g.blur == nil && g.blend == nil
            && g.transform3D == nil && !g.shadow.on && g.moreShadows?.contains(where: \.on) != true
    }
}

extension WindowsCore {
    /// The sheet the played device stands on, as the Mac's player Stage draws it: the canvas's
    /// table, ruled as millimetre paper in the pencil's blue (fine lines 9 points apart, every
    /// fifth a stronger one), the ruling fading away from the middle, and a pool of light falling
    /// on it from above; into BGRA pixels, `scale` to the point.
    /// The start card's small stage rules its paper `step` 7 and fades it sooner, unlit.
    public static func playerStage(width: Int, height: Int, scale: Double, table: UInt32, dark: Bool, step: Double = 9,
                                   fade: (y: Double, from: Double, to: Double, middle: Double) = (0.45, 80, 760, 0.55), lit: Bool = true,
                                   into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        picture({
            guard width > 0, height > 0, let ctx = Renderer.bitmap(CGSize(width: width, height: height)) else { return nil }
            let w = CGFloat(Double(width) / scale), h = CGFloat(Double(height) / scale)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
            func colour(_ rgb: UInt32, _ a: Double) -> CGColor {
                CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: CGFloat(a))
            }
            let all = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.setFillColor(colour(table, 1))
            ctx.fill(all)
            // The ruling, faded from the middle as through a mask.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let ink: UInt32 = dark ? 0x8FA8F2 : 0x3A63D8
            let hair = CGFloat(1 / scale), step = CGFloat(step)
            func crisp(_ v: CGFloat) -> CGFloat { (v * CGFloat(scale)).rounded() / CGFloat(scale) + hair / 2 }
            for major in [false, true] {
                ctx.beginPath()
                var i = 0
                while CGFloat(i) * step <= w {
                    if (i % 5 == 0) == major { ctx.move(to: CGPoint(x: crisp(CGFloat(i) * step), y: 0)); ctx.addLine(to: CGPoint(x: crisp(CGFloat(i) * step), y: h)) }
                    i += 1
                }
                var j = 0
                while CGFloat(j) * step <= h {
                    if (j % 5 == 0) == major { ctx.move(to: CGPoint(x: 0, y: crisp(CGFloat(j) * step))); ctx.addLine(to: CGPoint(x: w, y: crisp(CGFloat(j) * step))) }
                    j += 1
                }
                ctx.setStrokeColor(colour(ink, major ? (dark ? 0.14 : 0.17) : (dark ? 0.07 : 0.075)))
                ctx.setLineWidth(hair)
                ctx.strokePath()
            }
            let middle = CGPoint(x: w * 0.5, y: h * CGFloat(fade.y))
            let stops = [colour(0, 1), colour(0, fade.middle), colour(0, 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops, locations: [0, 0.5, 1] as [CGFloat]) {
                ctx.setBlendMode(.destinationIn)
                ctx.drawRadialGradient(g, startCenter: middle, startRadius: CGFloat(fade.from), endCenter: middle, endRadius: CGFloat(fade.to),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.setBlendMode(.normal)
            }
            ctx.endTransparencyLayer()
            // The light from above.
            guard lit else { return ctx.makeImage() }
            let light = [colour(0xFFFFFF, dark ? 0.1 : 0.55), colour(0xFFFFFF, dark ? 0.03 : 0.15), colour(0xFFFFFF, 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: light, locations: [0, 0.5, 1] as [CGFloat]) {
                let top = CGPoint(x: w * 0.5, y: h * 0.32)
                ctx.setBlendMode(.softLight)
                ctx.drawRadialGradient(g, startCenter: top, startRadius: 10, endCenter: top, endRadius: 520, options: [.drawsAfterEndLocation])
                ctx.setBlendMode(.normal)
            }
            return ctx.makeImage()
        }, into: fill)
    }

    /// A soft shadow round a box `width` by `height` pixels, `blur` pixels soft, fallen `dy`, as
    /// deep as `alpha`: its pixels reach `pad` past the box each way.
    public static func softShadow(width: Int, height: Int, pad: Int, blur: Double, dy: Double, colour: UInt32, alpha: Double,
                                  into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard width > 0, height > 0, let pixels = fill(width + 2 * pad, height + 2 * pad) else { return false }
        return bz_shadow(Int32(width), Int32(height), Int32(pad), blur, dy, colour, alpha, pixels) == 0
    }
}

extension WindowsCore {
    /// Where playing starts, as the Mac's play(from:) has it: the screen asked for, or the one a
    /// picked layer lies on, or where the prototype starts.
    public static func playStart(from board: UUID?, selection: [UUID]) -> UUID? {
        guard let seen = design else { return nil }
        func screen(_ id: UUID) -> Node? { seen.node(id).flatMap { $0.isArtboard ? $0 : seen.artboard(of: id) } }
        return (board.flatMap(screen) ?? selection.first.flatMap(screen) ?? Prototype.start(of: seen))?.id
    }
}

extension WindowsCore {
    /// What a screen is played on, as `sizes()` names it, and the size of the device's screen.
    public static func playDevice(for board: UUID) -> (group: String, name: String, screen: CGSize)? {
        guard let b = design?.node(board), b.isArtboard else { return nil }
        let (d, screen) = Player.device(for: b.frame.size)
        return (d.group, d.name, screen)
    }
}

extension WindowsCore {
    /// Where layers lie on the canvas, the box round them as far as each reaches turned.
    public static func canvasBounds(of ids: [UUID]) -> CGRect? { design?.bounds(of: ids) }
}
