import Testing
import AppKit
@testable import Bezzle

/// Animate used at random for a long while: everything the panel, the timeline, the canvas and
/// the menus can ask, in any order, with undo and redo in between. After every step the film has
/// to be sound, the desk has to make sense, and the design itself has to be what it was; and
/// undoing everything has to give the design back as it began.
///
/// Each run is told by its seed, so one that fails can be run again and followed step by step.
@MainActor
struct AnimateStressTests {
    /// SplitMix64: the same steps for the same seed, on any Mac.
    struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A design as it is without its film, and whatever is locked or hidden: what Animate may
    /// never change. Frames count to a billionth of a point: a group resized in the design is
    /// fitted round its layers again at the next change of anything in it, which can move its
    /// frame by the last digit a number has (`BezzleDocument.fitGroups(since:)` fits exactly).
    static func plain(_ doc: BezzleDocument) -> BezzleDocument {
        func near(_ x: CGFloat) -> CGFloat { (x * 1e9).rounded() / 1e9 }
        func strip(_ n: inout Node) {
            n.motion = nil
            n.film = nil
            n.locked = false
            n.hidden = false
            n.frame = CGRect(x: near(n.frame.origin.x), y: near(n.frame.origin.y), width: near(n.frame.size.width), height: near(n.frame.size.height))
            for i in n.children.indices { strip(&n.children[i]) }
        }
        var out = doc
        var nodes = out.nodes
        for i in nodes.indices { strip(&nodes[i]) }
        out.nodes = nodes
        out.viewport = nil
        return out
    }

    /// Everything wrong with a film as it is kept in a design.
    static func faults(in doc: BezzleDocument) -> [String] {
        var out: [String] = []
        for n in doc.allNodes {
            if let film = n.film {
                if !n.isArtboard { out.append("\(n.name) is no artboard and has a film") }
                if film == Film() { out.append("\(n.name) keeps a film that says nothing") }
                if let length = film.length, !(length > 0 && length.isFinite) { out.append("\(n.name): a film \(length) long") }
            }
            guard let motion = n.motion else { continue }
            if motion.isEmpty { out.append("\(n.name) keeps motion with nothing in it") }
            for (raw, track) in motion {
                guard let p = MotionProperty(rawValue: raw) else {
                    out.append("\(n.name): no such property as \(raw)")
                    continue
                }
                if p.isCamera != n.isArtboard { out.append("\(n.name) has keys of \(raw)") }
                if track.keys.isEmpty { out.append("\(n.name).\(raw) has no keys") }
                for (i, key) in track.keys.enumerated() {
                    if !(key.t >= 0 && key.t.isFinite) || key.t != MotionTiming.time(key.t) { out.append("\(n.name).\(raw): a key at \(key.t)") }
                    if i > 0, key.t - track.keys[i - 1].t < 0.0042 { out.append("\(n.name).\(raw): keys at \(track.keys[i - 1].t) and \(key.t)") }
                    let count = p == .shape ? n.shapeRest.count : p.rest.count
                    // A Shape's key may hold an outline of its own: behind a nought for every number the design's points have.
                    var fits = key.v.count == count
                    if !fits, p == .shape, let own = BezierPath(key: key.v) {
                        fits = key.v.count == count + 1 + 6 * (own.subpaths.count + own.anchorCount) && key.v.prefix(count).allSatisfy { $0 == 0 }
                            && own.subpaths.allSatisfy { $0.anchors.count >= 2 }
                    }
                    if !fits || key.v != p.clamped(key.v) { out.append("\(n.name).\(raw): a key of \(key.v)") }
                    if key.ease?.kind == .auto { out.append("\(n.name).\(raw): no pace kept as a pace") }
                    if let bounce = key.ease?.bounce, !bounce.isFinite { out.append("\(n.name).\(raw): a spring of \(bounce)") }
                }
            }
        }
        return out
    }

    /// Everything wrong with the desk: what is on it, where its playhead is, what is picked.
    static func faults(on store: DocumentStore, hand: FilmHand) -> [String] {
        var out: [String] = []
        let doc = store.doc
        if let id = store.film.board {
            if let board = doc.node(id), board.isArtboard, !board.hidden {} else { out.append("the desk has an artboard that is gone or hidden") }
        } else if store.animating, doc.artboards.contains(where: { !$0.hidden }) {
            out.append("the desk is empty though there is an artboard")
        }
        let length = store.filmBoard?.filmLength ?? 0
        if !(store.filmTime >= 0 && store.filmTime <= length) { out.append("posing at \(store.filmTime) in a film of \(length)") }
        for (name, t) in [("time", store.film.time), ("live", store.film.live), ("head", store.film.head)] where !(t >= 0 && t.isFinite) {
            out.append("the playhead's \(name) is \(t)")
        }
        if !store.film.playing {
            if max(store.film.time, store.film.live) > length + 1e-9 { out.append("the playhead rests at \(store.film.time), shown at \(store.film.live), past \(length)") }
            if store.film.pass != nil { out.append("a film that has stopped still has a pass to play") }
        }
        if !store.animating, store.film.playing || store.film.camera || !store.film.keys.isEmpty { out.append("out of Animate, something of it is still in hand") }
        if store.film.camera, !store.selection.allSatisfy({ $0 == store.film.board }) { out.append("the camera and layers are picked at once") }
        if !Set(store.pickedKeys).isSubset(of: store.film.keys) { out.append("keys count as picked that are not") }
        if store.gestureBefore != nil { out.append("a gesture was left open") }
        if hand.drag != nil || hand.held != nil || hand.marquee != nil { out.append("the timeline's hand still holds something") }
        if !store.film.keys.allSatisfy({ $0.layer == store.film.board || store.selection.contains($0.layer) }) {
            out.append("keys are picked of a layer that is not")
        }
        if hand.creep(0.1) { out.append("the timeline creeps along with nothing dragged") }
        if store.animating, let part = store.film.window {
            if part.fitted(to: store.filmWhole) != part { out.append("the timeline shows \(part) of a film \(store.filmWhole) long") }
            let sheet = hand.scale(width: 600)
            if !(sheet.perSecond > 0 && sheet.perSecond <= FilmWindow.closest + 1e-6 && sheet.start >= 0) { out.append("the timeline's sheet is \(sheet)") }
        }
        if !(store.film.apart >= 0 && store.film.apart.isFinite) { out.append("layers \(store.film.apart) apart") }
        if let board = store.filmBoard {
            let rows = FilmRow.rows(of: board, open: store.film.open)
            if Set(rows.map(\.id)).count != rows.count { out.append("two lines of the timeline are one") }
            if rows.first?.camera != true { out.append("the camera's line is not the first") }
            for row in rows {
                for (a, b) in zip(row.marks, row.marks.dropFirst()) where b.t - a.t < 0.0042 { out.append("\(row.name): beads at \(a.t) and \(b.t)") }
            }
            // What the stage would draw is whole at the playhead, whatever the keys say.
            let seen = board.camera(at: store.film.live)
            if ![seen.x, seen.y, seen.zoom, seen.roll, seen.tilt, seen.swing].allSatisfy(\.isFinite) || seen.zoom <= 0 { out.append("a camera of \(seen)") }
            for n in board.children {
                let pose = n.pose(at: store.film.live)
                if ![Double(pose.move.x), Double(pose.move.y), Double(pose.scale.x), Double(pose.scale.y), pose.turn, pose.fade, pose.lift, pose.tilt, pose.swing, pose.blur].allSatisfy(\.isFinite) {
                    out.append("\(n.name) posed as \(pose)")
                }
                if pose.fade < 0 || pose.fade > 1 || pose.blur < 0 || pose.scale.x <= 0 || pose.scale.y <= 0 { out.append("\(n.name) shows as \(pose)") }
            }
            // Every shape whose outline changes has a whole one then, and a frame to draw it in.
            func shapes(_ n: Node) -> [Node] { (n.reshapes ? [n] : []) + n.children.flatMap(shapes) }
            for n in board.children.flatMap(shapes) {
                let drawn = n.reshaped(at: store.film.live)
                let numbers = (n.outline(at: store.film.live)?.numbers ?? [.nan]) + [drawn.frame.minX, drawn.frame.minY, drawn.frame.width, drawn.frame.height].map { Double($0) }
                if !numbers.allSatisfy(\.isFinite) { out.append("\(n.name) has no whole outline at \(store.film.live)") }
            }
        }
        return out
    }

    /// A dozen runs every time; `TEST_RUNNER_ANIMATE_RUNS=500 xcodebuild test …` makes it that
    /// many more, to go looking for what is rare.
    nonisolated static var seeds: [Int] {
        // One run alone, to follow it: `TEST_RUNNER_ANIMATE_RUN=<seed>`.
        if let only = ProcessInfo.processInfo.environment["ANIMATE_RUN"].flatMap(Int.init) { return [only] }
        let more = ProcessInfo.processInfo.environment["ANIMATE_RUNS"].flatMap(Int.init) ?? 0
        return [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233] + (0..<max(more, 0)).map { 1000 + $0 }
    }

    @Test(arguments: seeds)
    func aLongRunAtRandomKeepsTheFilmSoundAndUndoesToTheDesign(seed: Int) {
        var row = Node(kind: .group, name: "Row", frame: CGRect(x: 40, y: 240, width: 200, height: 40))
        row.children = [
            CanvasTests.rect("Icon", CGRect(x: 0, y: 0, width: 40, height: 40)),
            CanvasTests.rect("Label", CGRect(x: 60, y: 10, width: 140, height: 20)),
        ]
        let bench = Bench(extra: [
            CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
            CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40)),
            row,
        ])
        let store = bench.store
        bench.step { store.edit("Add") { $0.nodes[1].children = [CanvasTests.rect("Far", CGRect(x: 20, y: 20, width: 50, height: 50))] } }
        bench.undo.removeAllActions()
        let hand = FilmHand(store: store)
        var dice = Dice(state: UInt64(seed))

        func animate() {
            store.show(.animate)
            store.glide.stop()
            store.viewport = Viewport(origin: .zero, zoom: 1)
        }
        animate()
        let began = store.doc
        // The design as it should be: what Animate does never changes it, and what changes it
        // (a layer resized, rounded or flipped under the film, and undoing that) is noted here.
        var design = Self.plain(began)
        let layers = ["Card", "Badge", "Row", "Icon", "Label", "Far"].map { bench.node($0)!.id }
        let boards = [bench.a.id, bench.b.id]

        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &dice) < p }
        func number(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &dice) }
        func whole(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &dice) }
        func one<T>(_ of: [T]) -> T { of[Int.random(in: 0..<of.count, using: &dice)] }
        func moment() -> Double { chance(0.6) ? one([0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3]) : number(-0.5...4) }
        func value(of p: MotionProperty) -> [Double] {
            p.rest.map { rest in chance(0.2) ? rest : one([0, 1, -1, 0.5, 2, 90, number(-300...300), number(-1e7...1e7)]) }
        }
        func flags() -> NSEvent.ModifierFlags { one([[], [], [], .shift, .option, .command]) }
        func sheet() -> (rows: [FilmRow], scale: FilmScale, length: Double)? {
            guard let board = store.filmBoard else { return nil }
            // As the card shows it: the whole film, or the part of it looked at closer.
            return (FilmRow.rows(of: board, open: store.film.open), hand.scale(width: 600), board.filmLength)
        }
        /// A point of the sheet: on a bead as often as not, else anywhere on it or just off it.
        func spot(_ rows: [FilmRow], _ scale: FilmScale) -> CGPoint {
            let withBeads = rows.indices.filter { !rows[$0].marks.isEmpty }
            if !withBeads.isEmpty, chance(0.6) {
                let i = one(withBeads)
                return CGPoint(x: scale.x(one(rows[i].marks).t) + CGFloat(number(-5...5)), y: (CGFloat(i) + 0.5) * FilmTimeline.rowHeight)
            }
            return CGPoint(x: number(-20...620), y: number(-10...Double(rows.count) * 24 + 20))
        }

        var trail: [String] = []
        func did(_ what: String) { trail.append(what) }

        func step(_ n: Int) {
            // With every artboard hidden there is no film to do anything to: one is soon shown again.
            if store.filmBoard == nil, chance(0.25), let hidden = store.doc.artboards.first(where: \.hidden) {
                did("show \(hidden.name)")
                bench.step { store.edit("Show") { $0.update(hidden.id) { $0.hidden = false } } }
                return
            }
            switch whole(0...32) {
            case 0, 1:
                let t = moment()
                did("seek \(t)")
                store.seek(t)
            case 30, 31:
                // A shape given an outline with other points at the playhead: a point more on
                // it, one fewer, or one drawn anew, open or closed, in one run or two.
                let what = whole(0...3), turn = number(0...6.28), points = whole(2...9), far = one([4.0, 30, 120])
                did("pose another outline \(what) of \(points)")
                let t = store.filmTime
                bench.step {
                    store.pose(.shape, of: store.posedLayers) { n in
                        guard var outline = n.outline(at: t), !outline.subpaths.isEmpty else { return n.shapeRest }
                        switch what {
                        case 0:
                            let run = points % outline.subpaths.count
                            if outline.subpaths[run].segmentCount > 0 { outline.insert(run, segment: points % outline.subpaths[run].segmentCount, t: 0.4) }
                        case 1:
                            let run = points % outline.subpaths.count
                            outline.remove([PathPoint(subpath: run, index: points % outline.subpaths[run].anchors.count)])
                        default:
                            var anchors: [BezierPath.Anchor] = []
                            for k in 0..<points {
                                let a = turn + Double(k) / Double(points) * 6.283, r = k % 2 == 0 ? far : far * 0.6
                                let p = CGPoint(x: 20 + cos(a) * r, y: 20 + sin(a) * r)
                                anchors.append(k % 3 == 0 ? BezierPath.Anchor(p, in: CGPoint(x: p.x - 3, y: p.y + 2), out: CGPoint(x: p.x + 3, y: p.y - 2)) : BezierPath.Anchor(p))
                            }
                            outline = BezierPath(subpaths: [BezierPath.Subpath(anchors: anchors, closed: what == 2)])
                            if points > 5 { outline.subpaths.append(BezierPath.Subpath(anchors: [BezierPath.Anchor(.zero), BezierPath.Anchor(CGPoint(x: far, y: 5))], closed: false)) }
                        }
                        return n.shapeValue(of: outline) ?? n.shapeRest
                    }
                }
            case 32:
                // A shape given the outline another has at the playhead.
                guard let id = store.posedLayers.first, let other = store.shapesToTake(for: id).randomElement(using: &dice) else { return }
                did("take the outline of \(other.name)")
                bench.step { store.takeShape(of: other.id, for: id) }
            case 2:
                var picked: [UUID] = []
                for _ in 0..<whole(0...3) { picked.append(one(layers + boards)) }
                did("select \(picked.map { store.doc.node($0)?.name ?? "?" })")
                store.selection = picked
            case 3:
                did("pick camera")
                store.pickCamera()
            case 4, 5:
                let p = one(MotionProperty.layer)
                if p == .shape {
                    // A shape's points, each moved its own way: as many changes as each layer has points.
                    let far = one([1.0, 40, 300])
                    did("pose shape by up to \(far)")
                    bench.step { store.pose(.shape, of: store.posedLayers) { n in n.shapeRest.map { _ in chance(0.3) ? 0 : number(-far...far) } } }
                    break
                }
                let v = value(of: p)
                did("pose \(p.rawValue) \(v)")
                bench.step { store.pose(p, of: store.posedLayers) { _ in v } }
            case 6:
                let p = one(MotionProperty.layer.filter { $0 != .shape }), i = whole(0...1), v = value(of: p)[0]
                did("pose \(p.rawValue)[\(i)] \(v)")
                bench.step { store.pose(p, number: i, to: v, of: store.posedLayers) }
            case 7, 8:
                let p = one(MotionProperty.camera), v = value(of: p)
                did("pose camera \(p.rawValue) \(v)")
                bench.step { if chance(0.5) { store.poseCamera(p, v) } else { store.poseCamera(p, number: whole(0...1), to: v[0]) } }
            case 9:
                let p = one(MotionProperty.allCases)
                did("toggle key \(p.rawValue)")
                bench.step { store.toggleKey(p) }
            case 10:
                did("hold")
                bench.step { store.holdHere() }
            case 11:
                did("remove keys")
                bench.step { store.removeFilmKeys() }
            case 12:
                let kind = one(MotionEase.Kind.allCases)
                did("pace \(kind.rawValue)")
                bench.step { store.setEase(kind == .spring ? .spring(number(0...1)) : MotionEase(kind: kind)) }
            case 13, 14:
                let move = one(MotionMove.allCases)
                store.film.going = chance(0.4)
                store.film.apart = one([0, 0.06, 0.2, number(0...0.5)])
                did("move \(move.rawValue) going \(store.film.going) apart \(store.film.apart)")
                bench.step { store.applyMove(move) }
            case 15:
                guard chance(0.4) else { return }
                did("remove motion")
                bench.step { store.clearFilmMotion() }
            case 16:
                let what = whole(0...3)
                let length: Double? = chance(0.3) ? nil : one([0.25, 0.5, 1, 2, 3.5, number(0.25...6)])
                did("film setting \(what) \(String(describing: length))")
                bench.step {
                    switch what {
                    case 0, 1: store.setFilm("Film Length") { $0.length = length }
                    case 2: store.setFilm("Play Once") { $0.once = $0.once == true ? nil : true }
                    default: store.setFilm("Backdrop") { $0.backdrop = $0.backdrop == nil ? RGBA(r: 0.1, g: 0.1, b: 0.1) : nil }
                    }
                }
            case 17:
                did(chance(0.7) ? "fly" : "rest camera")
                bench.step { if trail.last == "fly" { store.flyCamera(to: store.posedLayers) } else { store.restCamera() } }
            case 18, 19, 20:
                guard let (rows, scale, length) = sheet() else { return }
                let p = spot(rows, scale), held = flags(), clicks = chance(0.15) ? 2 : 1
                var to: [CGFloat] = []
                for _ in 0..<whole(0...4) { to.append(chance(0.3) ? p.x + CGFloat(number(-4...4)) : CGFloat(number(-40...660))) }
                // As often as not up and down the lines too, which from bare sheet is a marquee
                // over the keys; and now and then Escape before it is let go.
                let across = chance(0.5), escaped = chance(0.15)
                did("sheet press \(p) \(held.rawValue) x\(clicks) to \(to)\(across ? " across the lines" : "")\(escaped ? ", escaped" : "")")
                bench.step {
                    hand.press(at: p, rows: rows, scale: scale, flags: held, clicks: clicks)
                    for x in to {
                        // The sheet as it is by then: looked at closer, it creeps along under what is dragged past its end.
                        let (scale, length) = (hand.scale(width: 600), store.filmBoard?.filmLength ?? length)
                        let y = across ? CGFloat(number(-10...Double(rows.count) * 24 + 20)) : p.y
                        hand.dragged(to: CGPoint(x: x, y: y), by: x - p.x, rows: rows, scale: scale, length: length, flags: held)
                        if chance(0.4) { hand.creep(number(0...0.3)) }
                    }
                    if escaped { hand.cancel() }
                    hand.ended(scale: hand.scale(width: 600), flags: held)
                }
            case 21:
                guard let (rows, scale, length) = sheet() else { return }
                let x = chance(0.6) ? scale.x(length) + CGFloat(number(-6...6)) : CGFloat(number(-20...620))
                let held = flags(), clicks = chance(0.2) ? 2 : 1
                var to: [CGFloat] = []
                for _ in 0..<whole(0...3) { to.append(CGFloat(number(-40...660))) }
                did("ruler press \(x) x\(clicks) to \(to)")
                bench.step {
                    hand.pressRuler(at: CGPoint(x: x, y: 10), scale: scale, length: length, clicks: clicks)
                    for x2 in to {
                        let (scale, length) = (hand.scale(width: 600), store.filmBoard?.filmLength ?? length)
                        hand.dragged(to: CGPoint(x: x2, y: 10), by: x2 - x, rows: rows, scale: scale, length: length, flags: held)
                        if chance(0.4) { hand.creep(number(0...0.3)) }
                    }
                    hand.ended(scale: hand.scale(width: 600), flags: held)
                }
            case 22:
                guard let (rows, scale, _) = sheet() else { return }
                hand.hot = hand.point(spot(rows, scale), rows: rows, scale: scale)
                let items = hand.menu(rows: rows, scale: scale).filter { $0.kind == .item && $0.enabled }
                guard !items.isEmpty else { return }
                let item = one(items)
                did("menu \(item.title)")
                bench.step { item.action() }
            case 23:
                if chance(0.6), bench.undo.canUndo {
                    did("undo")
                    bench.undo.undo()
                } else if bench.undo.canRedo {
                    did("redo")
                    bench.undo.redo()
                }
                design = Self.plain(store.doc)
            case 24:
                let from = CGPoint(x: number(60...1040), y: number(60...440)), held = flags()
                if chance(0.3) {
                    did("canvas click \(from) \(held.rawValue)")
                    bench.click(from, flags: held, clicks: chance(0.2) ? 2 : 1)
                } else {
                    let to = CGPoint(x: from.x + CGFloat(number(-160...160)), y: from.y + CGFloat(number(-120...120)))
                    did("canvas drag \(from) to \(to) \(held.rawValue)")
                    bench.drag(from, to, flags: held)
                }
                store.glide.stop()
            case 25:
                let code = one([51, 51, 49, 53, 123, 124, 125, 126] as [UInt16])
                did("key \(code)")
                bench.key(code, flags: chance(0.2) ? .shift : [])
            case 26:
                switch whole(0...8) {
                case 5:
                    // The timeline looked at closer, or less close, about some point of it.
                    let factor = chance(0.5) ? one([0.5, 0.8, 1.25, 2, 6, 40]) : number(-0.5...12), x = CGFloat(number(-20...620))
                    did("timeline \(factor) times closer at \(x)")
                    hand.zoom(by: factor, at: x, scale: hand.scale(width: 600))
                case 6:
                    if chance(0.75) {
                        let dx = CGFloat(chance(0.2) ? number(-50_000...50_000) : number(-300...300))
                        did("timeline along by \(dx)")
                        hand.scroll(by: dx, scale: hand.scale(width: 600))
                    } else {
                        did("timeline double tap")
                        hand.smartZoom(at: CGFloat(number(-20...620)), scale: hand.scale(width: 600))
                    }
                case 7:
                    // A spring's bounce, to the number or from its chip; or another pace for the keys in hand.
                    switch whole(0...2) {
                    case 0:
                        let bounce = chance(0.1) ? one([.nan, .infinity, -3, 7]) : number(-0.2...1.2)
                        did("bounce \(bounce)")
                        bench.step { store.setBounce(bounce) }
                    case 1:
                        var turns: [CGFloat] = []
                        for _ in 0..<whole(0...4) { turns.append(CGFloat(number(-200...200))) }
                        did("spring chip turned \(turns)")
                        bench.step {
                            for dx in turns { hand.turnBounce(by: dx) }
                            hand.bounceTurned()
                        }
                    default:
                        let kind = one(MotionEase.Kind.allCases)
                        did("pace \(kind)")
                        bench.step { store.setPace(kind) }
                    }
                case 0:
                    let mode = one([CanvasMode.design, .prototype, .inspect])
                    did("to \(mode) and back")
                    store.show(mode)
                    let wrong = Self.faults(on: store, hand: hand)
                    #expect(wrong.isEmpty, "seed \(seed), step \(n), out of Animate: \(wrong)")
                    animate()
                case 1:
                    did("play")
                    store.playFilm(fromStart: chance(0.3))
                case 2:
                    did("pause")
                    store.pauseFilm()
                case 3:
                    did("film on by a while")
                    _ = store.filmStep(CACurrentMediaTime() + number(0...4))
                case 4:
                    did("step to key")
                    store.stepToKey(forward: chance(0.5))
                default:
                    var open: Set<UUID> = []
                    for _ in 0..<whole(0...3) { open.insert(one(layers + boards)) }
                    did("open \(open.count) lines")
                    store.film.open = open
                }
            case 27, 28:
                // The design's outlines changed under the film: a layer resized, a rectangle's
                // corners rounded, a layer flipped. Shape keys have to go with them, each still a
                // change for every point its layer has.
                let id = one(layers), what = whole(0...4)
                let size = CGSize(width: one([8, 30, 90, 200]), height: one([8, 20, 60, 140]))
                let radius = one([0, 0, 6, 18, 400]), across = chance(0.5)
                did("design \(what) of \(store.doc.node(id)?.name ?? "?") \(size) \(radius)")
                bench.step {
                    switch what {
                    case 0: store.edit("Resize") { $0.update(id) { $0.resize(to: size, byHeight: false) } }
                    case 1: store.edit("Corner Radius") { $0.update(id) { $0.corners = nil; $0.cornerRadius = CGFloat(radius) } }
                    case 2: store.edit("Corner Radius") { $0.update(id) { $0.corners = [CGFloat(radius), 0, 12, 0] } }
                    case 3: store.edit("Corner Radius") { $0.update(id) { $0.cornerSmoothing = $0.cornerSmoothing == nil ? 0.6 : nil } }
                    default: store.edit("Flip") { $0.flip([id], horizontally: across) }
                    }
                }
                design = Self.plain(store.doc)
            default:
                // The design itself changed under the film: something locked or hidden, by hand or by someone working along.
                let id = chance(0.15) ? one(boards) : one(layers)
                let hide = chance(0.5)
                did("\(hide ? "hide" : "lock") \(store.doc.node(id)?.name ?? "?")")
                bench.step { store.edit(hide ? "Hide" : "Lock") { $0.update(id) { n in if hide { n.hidden.toggle() } else { n.locked.toggle() } } } }
            }
        }

        func sound(_ n: Int) -> Bool {
            var wrong = Self.faults(in: store.doc) + Self.faults(on: store, hand: hand)
            let now = Self.plain(store.doc)
            if now != design {
                // Which layers: each compared without what is inside it.
                func alone(_ n: Node) -> Node { var n = n; n.children = []; return n }
                let which = zip(now.allNodes, design.allNodes).filter { alone($0) != alone($1) }.map { "\($0.name): \($0.frame) \($0.kind) was \($1.frame) \($1.kind)" }
                wrong.append("the design itself is no longer what it was (\(which.prefix(3).joined(separator: "; ")))")
            }
            #expect(wrong.isEmpty, "seed \(seed), step \(n): \(wrong.prefix(4)) after \(trail.suffix(10))")
            return wrong.isEmpty
        }

        // Slow, for following one run: everything undone and redone after every step.
        // `ANIMATE_DEEP=<every>,<from>`: from that step on, every so many steps.
        let deeply = (ProcessInfo.processInfo.environment["ANIMATE_DEEP"] ?? "").split(separator: ",").compactMap { Int($0) }
        func deep(_ n: Int) -> Bool {
            guard let every = deeply.first, every > 0 else { return false }
            let from = deeply.count > 1 ? deeply[1] : 0
            return n >= from && (n - from) % every == 0
        }
        func roundTrip(_ n: Int) -> Bool {
            var doc = store.doc
            var states: [BezzleDocument] = []
            var undone = 0
            while bench.undo.canUndo, undone < 5000 {
                // A step that changed nothing is on the stack all the same, with nothing to redo.
                let before = store.doc
                bench.undo.undo()
                undone += 1
                if store.doc != before { states.append(before) }
            }
            // Only what was undone just now: a step the run itself undid stays undone.
            while bench.undo.canRedo, !states.isEmpty {
                let name = bench.undo.redoActionName, before = store.doc
                bench.undo.redo()
                guard store.doc != before, let was = states.popLast() else { continue }
                let same = store.doc == was
                #expect(same, "seed \(seed), step \(n): \(name) redone, \(states.count) from the end, is not what it was, after \(trail.suffix(n < 40 ? 40 : 8))")
                guard same else { return false }
            }
            doc.viewport = store.doc.viewport
            return store.doc == doc
        }
        var moving = 0, most = 0
        for n in 0..<360 {
            let before = store.doc, said = trail.count
            step(n)
            guard sound(n) else { return }
            // Whatever a step changed, it undoes to exactly what was, and redoes to exactly what it made.
            let after = store.doc
            if after != before, trail.count > said, trail.last?.hasPrefix("undo") != true, trail.last?.hasPrefix("redo") != true {
                bench.undo.undo()
                let back = store.doc == before
                // Its Shape keys fit the design as it was before the step, too.
                let fitted = Self.faults(in: store.doc)
                #expect(fitted.isEmpty, "seed \(seed), step \(n) undone: \(fitted.prefix(4)) after \(trail.suffix(6))")
                bench.undo.redo()
                let again = store.doc == after
                #expect(back && again, "seed \(seed), step \(n): \(back ? "" : "undone, not as it was; ")\(again ? "" : "redone, not as it was made; ")after \(trail.suffix(6))")
                guard back && again, sound(n) else { return }
            }
            if deep(n) { guard roundTrip(n) else { return } }
            let keys = store.doc.allNodes.reduce(0) { $0 + ($1.motion ?? [:]).values.reduce(0) { $0 + $1.keys.count } }
            if keys > 0 { moving += 1 }
            most = max(most, keys)
        }
        // The run did make films: it was not three hundred steps of nothing.
        #expect(moving > 60 && most >= 6, "seed \(seed): a film at \(moving) steps, \(most) keys at most; animating \(store.animating), board \(store.filmBoard?.name ?? "none"), hidden \(store.doc.artboards.filter(\.hidden).map(\.name)), began \(trail.prefix(30))")

        // Everything undone, the design is as it began; and everything redone, as it ended, by
        // way of everything it was in between.
        store.pauseFilm()
        func kept() -> BezzleDocument {
            var doc = store.doc
            doc.viewport = began.viewport
            return doc
        }
        /// Where two designs' films differ, briefly.
        func difference(_ a: BezzleDocument, _ b: BezzleDocument) -> String {
            var out: [String] = []
            for (x, y) in zip(a.allNodes, b.allNodes) where x.motion != y.motion || x.film != y.film {
                for p in MotionProperty.allCases where x[track: p] != y[track: p] {
                    out.append("\(x.name).\(p.rawValue): \((x[track: p]?.keys ?? []).map(\.t)) and \((y[track: p]?.keys ?? []).map(\.t))")
                }
                if x.film != y.film { out.append("\(x.name)'s film") }
            }
            return out.isEmpty ? "elsewhere than in a film" : out.prefix(3).joined(separator: "; ")
        }
        let ended = kept()
        var passed: [BezzleDocument] = []
        var undone = 0
        var undos: [String] = [], redos: [String] = []
        while bench.undo.canUndo, undone < 5000 {
            let before = kept()
            undos.append(bench.undo.undoActionName)
            bench.undo.undo()
            undone += 1
            if kept() != before { passed.append(before) } else { undos[undos.count - 1] += " (nothing)" }
            design = Self.plain(store.doc)
            did("undo all \(undone)")
            guard sound(1000 + undone) else { return }
        }
        let asBegan = kept() == began
        #expect(asBegan, "seed \(seed): undone, the design is not as it began: \(difference(kept(), began))")
        while bench.undo.canRedo, !passed.isEmpty {
            let name = bench.undo.redoActionName, before = kept()
            bench.undo.redo()
            redos.append(name + (kept() == before ? " (nothing)" : ""))
            guard kept() != before, let was = passed.popLast() else { continue }
            let same = kept() == was
            #expect(same, "seed \(seed): \(name) redone, \(passed.count) steps from the end, is not what it was: \(difference(kept(), was))")
            guard same else { return }
        }
        design = Self.plain(store.doc)
        let asEnded = kept() == ended
        #expect(asEnded, "seed \(seed): redone, the design is not as it ended: \(difference(kept(), ended)); undone first \(undos.prefix(8)), redone last \(redos.suffix(8)), \(passed.count) left; the run ended \(trail.filter { !$0.hasPrefix("undo all") }.suffix(8))")
        _ = sound(9999)
    }
}
