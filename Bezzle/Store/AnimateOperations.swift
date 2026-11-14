import AppKit
import Observation
import QuartzCore
import UniformTypeIdentifiers

/// Animate's desk: the film being worked on and what of it is in hand. Here alone, as the zoom
/// is; the film itself is in the design (`Node.motion`, `Node.film`).
@Observable
final class FilmDesk {
    /// The artboard whose film it is.
    var board: UUID?
    /// Where the playhead rests: the moment that is posed.
    var time = 0.0
    /// Where the playhead shows: the same, but for while the film plays, when it runs ahead.
    /// Only what follows the playing reads it, so that nothing else is drawn again each frame.
    var live = 0.0
    /// The same again, where nothing watches it: the stage reads it each frame of the screen.
    @ObservationIgnored var head = 0.0
    /// The moment the panels show: where the playhead rests, but caught up with no more than
    /// thirty times a second while a hand drags it. The numbers of a scrub are not read at the
    /// screen's pace, and drawing the panels' cards again at every step took most of the main
    /// thread; the film, the playhead and its clock still follow the hand at every step.
    var shown = 0.0
    @ObservationIgnored var shownAt: CFTimeInterval = 0
    @ObservationIgnored var catching = false
    var playing = false
    /// The camera picked, rather than any layer.
    var camera = false
    /// The keys picked in the timeline.
    var keys: Set<FilmKeyRef> = []
    /// The layers whose rows are opened into one for each property.
    var open: Set<UUID> = []
    /// Whether the moves given in one go are how layers go, rather than how they come on.
    var going = false
    /// How many seconds apart several layers are given a move, one after another.
    var apart = 0.06
    /// How far saving the film as a movie has come, 0 to 1, while it is being saved.
    var exporting: Double?

    /// One run of the playhead: from where, begun when; for a look at something just made, to
    /// where, and where the playhead rests after it.
    struct Pass {
        var began: CFTimeInterval
        var from: Double
        var to: Double?
        var back: Double?
    }
    @ObservationIgnored var pass: Pass?
    @ObservationIgnored var saving: Task<Void, Never>?

    /// How long a film that goes round rests at its end before it begins again.
    static let breath = 0.7
}

extension MotionProperty {
    /// Names a change to it in the Edit menu.
    var action: LocalizedStringResource { .verbatim(title) }
}

extension DocumentStore {
    // MARK: The mode

    func animatingChanged() {
        if animating {
            // Animated on the prototype's table, where nothing is drawn.
            if inspecting { inspecting = false }
            if !prototyping { prototyping = true }
            writingNote = nil
            flowPreview = nil
            focusFilm()
            frameFilm()
        } else {
            pauseFilm()
            film.camera = false
            film.keys = []
        }
        canvas?.motionTool.modeChanged(animating)
    }

    // MARK: The film on the desk

    /// The artboard whose film is worked on, as it is seen.
    var filmBoard: Node? {
        guard let id = film.board, let board = seenDoc.node(id), board.isArtboard, !board.hidden else { return nil }
        return board
    }

    /// Turns the desk to the artboard the selection is on; with nothing picked it stays, and
    /// before any was, takes the one most in sight.
    func focusFilm() {
        // Only an artboard that shows has a film to work on.
        func film(of id: UUID?) -> UUID? {
            guard let id, let board = doc.node(id), board.isArtboard, !board.hidden else { return nil }
            return id
        }
        var id: UUID?
        if let first = selection.first { id = film(of: doc.node(first)?.isArtboard == true ? first : doc.artboard(of: first)?.id) }
        if id == nil { id = film(of: self.film.board) }
        if id == nil { id = film(of: focusedArtboard?.id) ?? doc.artboards.first { !$0.hidden }?.id }
        guard self.film.board != id else { return }
        pauseFilm()
        self.film.board = id
        self.film.keys = []
        self.film.camera = false
        self.film.time = 0
        self.film.shown = 0
        self.film.live = 0
        self.film.head = 0
        if animating { frameFilm() }
    }

    /// The design changed with a film on the desk. One whose artboard is gone or hidden, by an
    /// undo or by someone working along, gives way to another's; and a playhead left past the
    /// end of a film that got shorter comes back to its end, where poses go.
    func filmDesignChanged() {
        if let id = film.board, let board = doc.node(id), board.isArtboard, !board.hidden {
            if !film.playing, let length = filmBoard?.filmLength, max(film.time, film.live) > length + 1e-9 { seek(length) }
        } else {
            focusFilm()
        }
    }

    /// Glides the view so the film's artboard lies whole above the timeline: it is what is worked
    /// on, and belongs neither half out of sight nor under the card at the canvas's foot. One
    /// that shows whole there already is left where it is.
    func frameFilm() {
        guard let board = filmBoard, canvasSize.width > 0, canvasSize.height > FilmTimeline.foot + 160 else { return }
        let room = CGSize(width: canvasSize.width, height: canvasSize.height - FilmTimeline.foot)
        let seen = CGRect(origin: viewport.origin, size: CGSize(width: room.width / viewport.zoom, height: room.height / viewport.zoom))
        guard !seen.insetBy(dx: 12 / viewport.zoom, dy: 12 / viewport.zoom).contains(board.frame) else { return }
        var target = viewport
        target.fit(board.frame, in: room, padding: 40, maxZoom: max(1, min(viewport.zoom, 2)))
        glide.fly(self, to: target)
    }

    func filmSelectionChanged() {
        focusFilm()
        if !selection.isEmpty, selection != film.board.map({ [$0] }) { film.camera = false }
        let board = film.board
        let kept = film.keys.filter { $0.layer == board || selection.contains($0.layer) }
        if kept != film.keys { film.keys = kept }
    }

    /// The moment that is posed: the playhead, within the film as it is now.
    var filmTime: Double { min(max(film.time, 0), filmBoard?.filmLength ?? 0) }

    /// The moment the panels show (`FilmDesk.shown`), within the film as it is now.
    var panelTime: Double { min(max(film.shown, 0), filmBoard?.filmLength ?? 0) }

    /// Brings the panels' moment to the playhead: at once when they last caught up a thirtieth of
    /// a second ago or more, as for a step of the arrows; else as soon as that much has passed,
    /// so the last moment of a drag is always the one they show.
    func catchUpPanels() {
        guard film.shown != film.time else { return }
        let now = CACurrentMediaTime(), every = 1.0 / 30
        if now - film.shownAt >= every {
            film.shown = film.time
            film.shownAt = now
            return
        }
        guard !film.catching else { return }
        film.catching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + every - (now - film.shownAt)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.film.catching = false
                self.catchUpPanels()
            }
        }
    }

    /// The layers a pose is given to: those picked that lie on the film's artboard.
    var posedLayers: [UUID] {
        guard let board = filmBoard else { return [] }
        // Worked out once for each design and selection: what it is read from is read all the
        // same, so whatever watches it hears of a change.
        if let had = posedWorkedOut, had.version == version, had.fronts == fronts, had.board == board.id, had.selection == selection {
            return had.layers
        }
        let layers = selection.filter { id in id != board.id && board.descendant(id).map { !$0.locked } == true }
        posedWorkedOut = (version, fronts, board.id, selection, layers)
        return layers
    }

    /// Picks the camera, and lets go of the layers.
    func pickCamera() {
        guard filmBoard != nil else { return }
        if !selection.isEmpty { selection = [] }
        film.keys = []
        film.camera = true
    }

    // MARK: The playhead

    /// Puts the playhead at a moment, and stops the film there.
    func seek(_ t: Double) {
        // Only when it changes: each time it is set, all that watches it is drawn again, and a
        // hand scrubbing through the film sets the playhead many times a second.
        if film.playing { film.playing = false }
        film.pass = nil
        // A moment that is no number at all is the start. Never past the end, even by the
        // fraction that rounding to a thousandth can add.
        let length = filmBoard?.filmLength ?? 0
        let to = min(MotionTiming.time(min(max(t.isNaN ? 0 : t, 0), length)), length)
        if film.time != to { film.time = to }
        if film.live != to { film.live = to }
        film.head = to
        catchUpPanels()
    }

    /// Plays the film from the playhead, or from its start once it has reached the end.
    func playFilm(fromStart: Bool = false) {
        // Not under a hand that is posing: the menu and the AI server can ask in the middle of a drag.
        guard !inGesture, let board = filmBoard else { return }
        var from = fromStart ? 0 : filmTime
        if from >= board.filmLength - 0.001 { from = 0 }
        film.pass = FilmDesk.Pass(began: CACurrentMediaTime(), from: from)
        film.live = from
        film.head = from
        film.playing = true
        canvas?.filmStage.run()
    }

    /// Shows something just made by playing it once: from one moment to another, after which the
    /// playhead rests at `back`, where it was.
    func showFilm(from: Double, to: Double, back: Double) {
        guard filmBoard != nil, to > from else { return }
        film.pass = FilmDesk.Pass(began: CACurrentMediaTime(), from: from, to: to, back: back)
        film.live = from
        film.head = from
        film.playing = true
        canvas?.filmStage.run()
    }

    /// Stops the film where it is.
    func pauseFilm() {
        guard film.playing else { return }
        let rest = film.pass?.back ?? film.live
        film.playing = false
        film.pass = nil
        seek(rest)
    }

    func toggleFilm() {
        if film.playing { pauseFilm() } else { playFilm() }
    }

    /// Moves the playing film on to now. False once it has stopped.
    func filmStep(_ now: CFTimeInterval) -> Bool {
        guard film.playing, let pass = film.pass, let board = filmBoard else {
            // Its artboard is gone: stopped, and the playhead shows where it rests again.
            film.playing = false
            film.pass = nil
            if film.live != film.time { film.live = film.time }
            film.head = film.time
            return false
        }
        let length = board.filmLength
        // Never before where it began, whatever the clock says.
        let t = pass.from + max(now - pass.began, 0)
        if let to = pass.to {
            // A look at something just made: there, a moment's rest, and back.
            if t >= to + 0.4 {
                film.playing = false
                film.pass = nil
                seek(pass.back ?? to)
                return false
            }
            film.head = min(t, to)
        } else if board.film?.once == true {
            if t >= length {
                film.playing = false
                film.pass = nil
                seek(length)
                return false
            }
            film.head = t
        } else {
            // Round and round, with a breath at the end before it begins again.
            film.head = min(t.truncatingRemainder(dividingBy: length + FilmDesk.breath), length)
        }
        film.live = film.head
        return true
    }

    /// The moments anything picked has a key at, or with nothing picked, anything in the film:
    /// where the playhead steps to.
    var filmStops: [Double] {
        guard let board = filmBoard else { return [] }
        var times: [Double] = []
        func add(_ more: [Double]) {
            for t in more where !times.contains(where: { MotionTiming.same($0, t) }) { times.append(t) }
        }
        let picked = posedLayers
        if film.camera {
            add(board.keyTimes(MotionProperty.camera))
        } else if !picked.isEmpty {
            for id in picked { add(board.descendant(id)?.keyTimes() ?? []) }
        } else {
            add(board.keyTimes(MotionProperty.camera))
            // As the timeline has them: nothing of a hidden layer, nor of what it holds.
            func walk(_ n: Node) {
                guard !n.hidden else { return }
                add(n.keyTimes())
                n.children.forEach(walk)
            }
            board.children.forEach(walk)
        }
        return times.sorted()
    }

    /// Steps the playhead to the key before or after it. A film that plays stops first, and the
    /// step is taken from where it stopped.
    func stepToKey(forward: Bool) {
        pauseFilm()
        let now = filmTime
        let stops = filmStops
        let next = forward ? stops.first { $0 > now + 0.0042 } : stops.last { $0 < now - 0.0042 }
        seek(next ?? (forward ? filmBoard?.filmLength ?? 0 : 0))
    }

    // MARK: Posing

    /// Poses a property of layers at the playhead, each at the value worked out from what it is.
    func pose(_ property: MotionProperty, of ids: [UUID], _ value: (Node) -> [Double]) {
        // The camera's are posed on its artboard, by `poseCamera`.
        guard !property.isCamera else { return }
        let t = filmTime
        edit(property.action) { doc in
            for id in ids {
                doc.update(id) { n in
                    guard !n.locked else { return }
                    n.pose(property, value(n), at: t)
                }
            }
        }
    }

    /// Poses the camera at the playhead. Its first key at the start has it fly out to the whole
    /// artboard over the film's length, rather than in a layer's short beat.
    func poseCamera(_ property: MotionProperty, _ value: [Double]) {
        guard let board = filmBoard, property.isCamera else { return }
        let t = filmTime, home = max(board.filmLength, 1)
        edit(property.action) { doc in
            doc.update(board.id) { $0.pose(property, value, at: t, home: home) }
        }
    }

    /// The number layers share of a property at the playhead, as the panel shows it; nil where
    /// they differ, or there are none.
    func sharedValue(_ property: MotionProperty, _ index: Int, of ids: [UUID], at moment: Double? = nil) -> Double? {
        guard let board = filmBoard, index < property.rest.count else { return nil }
        let t = moment ?? filmTime
        let values = ids.compactMap { board.descendant($0)?.value(of: property, at: t)[index] }
        guard let first = values.first, values.allSatisfy({ abs($0 - first) < 1e-6 }) else { return nil }
        return first
    }

    /// Sets one number of a property of layers at the playhead, as the panel's fields do: the
    /// others keep what each layer has. A scale's width set grows the layer as a whole, its
    /// height keeping to its width.
    func pose(_ property: MotionProperty, number index: Int, to v: Double, of ids: [UUID]) {
        guard index < property.rest.count, v.isFinite else { return }
        let t = filmTime
        pose(property, of: ids) { n in
            var now = n.value(of: property, at: t)
            if property == .scale, index == 0 {
                let k = v / max(now[0], 0.001)
                now = [v, now[1] * k]
            } else {
                now[index] = v
            }
            return now
        }
    }

    /// The same for the camera.
    func poseCamera(_ property: MotionProperty, number index: Int, to v: Double) {
        guard let board = filmBoard, property.isCamera, index < property.rest.count, v.isFinite else { return }
        var now = board.value(of: property, at: filmTime)
        now[index] = v
        poseCamera(property, now)
    }

    // MARK: Shader inputs

    /// The inputs of the shader every picked layer has, by name: those a person may set and key.
    var posedInputs: [String] {
        guard let board = filmBoard else { return [] }
        let shaders = posedLayers.compactMap { board.descendant($0)?.keyedShader }
        guard let first = shaders.first, shaders.count == posedLayers.count else { return [] }
        return first.inputs.filter { name in shaders.allSatisfy { $0.value(of: name)?.count == first.value(of: name)?.count } }
    }

    /// One number of an input the picked layers share at the playhead; nil where they differ.
    func sharedInput(_ name: String, _ index: Int, at moment: Double? = nil) -> Double? {
        guard let board = filmBoard else { return nil }
        let t = moment ?? filmTime
        let values = posedLayers.compactMap { board.descendant($0)?.shaderInput(name, at: t) }.compactMap { index < $0.count ? $0[index] : nil }
        guard values.count == posedLayers.count, let first = values.first, values.allSatisfy({ abs($0 - first) < 1e-6 }) else { return nil }
        return first
    }

    /// Poses an input of the picked layers at the playhead, each at the value worked out from
    /// what it is there.
    func poseInput(_ name: String, _ value: @escaping (Node) -> [Double]?) {
        let t = filmTime
        let ids = posedLayers
        edit("Change Shader") { doc in
            for id in ids {
                doc.update(id) { n in
                    guard !n.locked, let v = value(n) else { return }
                    n.poseInput(name, v, at: t)
                }
            }
        }
    }

    /// Sets one number of an input at the playhead, as the panel's fields do.
    func poseInput(_ name: String, number index: Int, to v: Double) {
        guard v.isFinite else { return }
        let t = filmTime
        poseInput(name) { n in
            guard var now = n.shaderInput(name, at: t), index < now.count else { return nil }
            now[index] = v
            return now
        }
    }

    /// How an input stands at the playhead, over the picked layers.
    func inputKeyState(_ name: String, at moment: Double? = nil) -> FilmKeyState {
        guard let board = filmBoard else { return .none }
        let t = moment ?? filmTime
        var state = FilmKeyState.none
        for id in posedLayers {
            guard let track = board.descendant(id)?[track: ShaderFill.inputTrack(name)] else { continue }
            if track.index(at: t) != nil { return .here }
            state = .between
        }
        return state
    }

    /// Sets a key of an input at the playhead, holding what it is there; or, where every picked
    /// layer has one there already, takes it away.
    func toggleInputKey(_ name: String) {
        guard let board = filmBoard else { return }
        let t = filmTime, track = ShaderFill.inputTrack(name)
        let ids = posedLayers.filter { board.descendant($0)?.shaderInput(name) != nil }
        guard !ids.isEmpty else { return }
        let all = ids.allSatisfy { board.descendant($0)?[track: track]?.index(at: t) != nil }
        edit(all ? "Remove Key" : "Add Key") { doc in
            for id in ids {
                doc.update(id) { n in
                    if all {
                        n.removeKeys(at: t, tracks: [track])
                    } else if n[track: track]?.index(at: t) == nil, let design = n.shaderInput(name) {
                        let change = n[track: track]?.value(at: t, rest: Array(repeating: 0, count: design.count)) ?? Array(repeating: 0, count: design.count)
                        n.setInputKey(name, change: change, at: t)
                    }
                }
            }
        }
    }

    /// What poses and keys go to: the camera's artboard when the camera is picked, or the layers.
    private var keyTargets: [UUID] {
        if film.camera { return film.board.map { [$0] } ?? [] }
        return posedLayers
    }

    private func targets(of property: MotionProperty) -> [UUID] {
        property.isCamera ? (film.board.map { [$0] } ?? []) : posedLayers
    }

    /// How a property stands at the playhead, over everything it would be keyed for.
    func keyState(_ property: MotionProperty, at moment: Double? = nil) -> FilmKeyState {
        guard let board = filmBoard else { return .none }
        let t = moment ?? filmTime
        var state = FilmKeyState.none
        for id in targets(of: property) {
            guard let track = (id == board.id ? board : board.descendant(id))?[track: property] else { continue }
            if track.index(at: t) != nil { return .here }
            state = .between
        }
        return state
    }

    /// Sets a key of a property at the playhead, holding what it is there; or, where everything
    /// picked has one there already, takes it away.
    func toggleKey(_ property: MotionProperty) {
        guard let board = filmBoard else { return }
        let t = filmTime
        let ids = targets(of: property)
        guard !ids.isEmpty else { return }
        func node(_ id: UUID) -> Node? { id == board.id ? board : board.descendant(id) }
        let all = ids.allSatisfy { node($0)?[track: property]?.index(at: t) != nil }
        edit(all ? "Remove Key" : "Add Key") { doc in
            for id in ids {
                doc.update(id) { n in
                    if all {
                        n.removeKeys(at: t, of: [property])
                    } else if n[track: property]?.index(at: t) == nil {
                        n.setKey(property, n.value(of: property, at: t), at: t)
                    }
                }
            }
        }
    }

    /// Holds what is picked as it is at the playhead: a key there for every property that moves.
    func holdHere() {
        let t = filmTime
        let ids = keyTargets
        guard !ids.isEmpty else { return }
        edit("Add Key") { doc in
            for id in ids {
                doc.update(id) { n in
                    for p in n.motionProperties where n[track: p]?.index(at: t) == nil {
                        n.setKey(p, n.value(of: p, at: t), at: t)
                    }
                    for name in n.inputTracks {
                        guard var track = n[track: name], track.index(at: t) == nil else { continue }
                        track.keys.append(MotionKey(t: t, v: track.value(at: t, rest: n.rest(of: name))))
                        track.keys.sort { $0.t < $1.t }
                        n[track: name] = track
                    }
                }
            }
        }
    }

    /// How what is picked stands at the playhead, over everything of it that moves: for the bead
    /// that holds it there.
    var holdState: FilmKeyState { holdState(at: filmTime) }

    /// The same at a moment, as the panels show it (`panelTime`).
    func holdState(at t: Double) -> FilmKeyState {
        guard let board = filmBoard else { return .none }
        var state = FilmKeyState.none
        for id in keyTargets {
            guard let node = id == board.id ? board : board.descendant(id) else { continue }
            let tracks = node.motionProperties.compactMap { node[track: $0] } + node.inputTracks.compactMap { node[track: $0] }
            if tracks.contains(where: { $0.index(at: t) != nil }) { return .here }
            if !tracks.isEmpty { state = .between }
        }
        return state
    }

    /// The tracks a picked key stands for: one property's, one input's, or all the layer's, or
    /// all the camera's.
    private func tracks(of ref: FilmKeyRef) -> [String] {
        if let p = ref.property { return [p.rawValue] }
        if let input = ref.input { return [ShaderFill.inputTrack(input)] }
        if ref.layer == film.board { return MotionProperty.camera.map(\.rawValue) }
        guard let node = filmBoard?.descendant(ref.layer) else { return MotionProperty.layer.map(\.rawValue) }
        return node.layerTracks
    }

    /// The keys picked in the timeline that are still there. An undo, the AI or someone working
    /// along can take a picked key away, and what is done to the picked keys must then fall to
    /// those at the playhead again, not to nothing.
    var pickedKeys: [FilmKeyRef] {
        guard !film.keys.isEmpty, let board = filmBoard else { return [] }
        return film.keys.filter { ref in
            guard let node = ref.layer == board.id ? board : board.descendant(ref.layer) else { return false }
            return tracks(of: ref).contains { node[track: $0]?.index(at: ref.time) != nil }
        }
    }

    /// Whether Delete has keys to take away: some picked in the timeline, or some at the playhead
    /// of what is picked.
    var hasKeysToRemove: Bool { hasKeysToRemove(at: filmTime) }

    /// The same at a moment, as the panels show it (`panelTime`).
    func hasKeysToRemove(at t: Double) -> Bool {
        if !pickedKeys.isEmpty { return true }
        guard let board = filmBoard else { return false }
        return keyTargets.contains { id in
            (id == board.id ? board : board.descendant(id))?.motion?.values.contains { $0.index(at: t) != nil } == true
        }
    }

    /// Takes away the keys picked in the timeline; with none picked, those at the playhead of
    /// what is picked. Never a layer.
    func removeFilmKeys() {
        let t = filmTime
        var refs = pickedKeys
        if refs.isEmpty { refs = keyTargets.map { FilmKeyRef($0, at: t) } }
        if !film.keys.isEmpty { film.keys = [] }
        guard !refs.isEmpty else { return }
        edit("Remove Key") { doc in
            for ref in refs {
                doc.update(ref.layer) { $0.removeKeys(at: ref.time, tracks: tracks(of: ref)) }
            }
        }
    }

    /// Sets how the picked keys are come to; with none picked, those at the playhead.
    func setEase(_ ease: MotionEase) {
        let t = filmTime
        var refs = pickedKeys
        if refs.isEmpty { refs = keyTargets.map { FilmKeyRef($0, at: t) } }
        guard !refs.isEmpty else { return }
        edit("Change Pace") { doc in
            for ref in refs {
                doc.update(ref.layer) { $0.setEase(ease, at: ref.time, tracks: tracks(of: ref)) }
            }
        }
    }

    /// The pace the picked keys share, or those at the playhead; nil when they differ or there are none.
    var sharedEase: MotionEase? { sharedEase(at: filmTime) }

    /// The same at a moment, as the panels show it (`panelTime`).
    func sharedEase(at t: Double) -> MotionEase? {
        guard let board = filmBoard else { return nil }
        var refs = pickedKeys
        if refs.isEmpty { refs = keyTargets.map { FilmKeyRef($0, at: t) } }
        var found: MotionEase?
        var any = false
        for ref in refs {
            guard let node = ref.layer == board.id ? board : board.descendant(ref.layer) else { continue }
            for name in tracks(of: ref) {
                guard let track = node[track: name], let i = track.index(at: ref.time) else { continue }
                let ease = track.keys[i].ease ?? .auto
                if any, found != ease { return nil }
                found = ease
                any = true
            }
        }
        return found
    }

    /// Moves keys in time, within a drag: `refs` are the keys as the drag began, and `delta` how
    /// far they have been dragged since. Gives back where they are now.
    @discardableResult
    func retime(_ refs: [FilmKeyRef], by delta: Double) -> [FilmKeyRef] {
        guard let before = gestureBefore, !refs.isEmpty else { return refs }
        let delta = max(delta, -(refs.map(\.time).min() ?? 0))
        // The later first when they go later, so none lands on one still to move.
        let ordered = refs.sorted { delta > 0 ? $0.ms > $1.ms : $0.ms < $1.ms }
        edit("Move Key") { doc in
            for layer in Set(refs.map(\.layer)) {
                let was = before.node(layer)?.motion
                doc.update(layer) { $0.motion = was }
            }
            for ref in ordered {
                doc.update(ref.layer) { $0.moveKeys(from: ref.time, to: ref.time + delta, tracks: tracks(of: ref)) }
            }
        }
        return refs.map { FilmKeyRef($0.layer, $0.property, input: $0.input, at: MotionTiming.time($0.time + delta)) }
    }

    // MARK: The camera, sent somewhere

    /// Has the camera look at layers from the playhead on, as close as shows them whole with
    /// room round them, and shows the flight there from where it was before. Its roll and how
    /// the scene is turned under it stay as they are, so a flight low over the page stays low.
    func flyCamera(to ids: [UUID]) {
        guard let board = filmBoard else { return }
        let t = filmTime
        guard let aim = Self.cameraAim(at: ids, on: board, in: seenDoc, time: t) else { return }
        let before = board.keyTimes(MotionProperty.camera).last { $0 < t - 0.0042 } ?? 0
        let was = board.motion
        beginGesture()
        poseCamera(.cameraMove, aim.move)
        poseCamera(.cameraZoom, [aim.zoom])
        endGesture("Fly the Camera Here")
        // Already looking there, there is no flight to show.
        if filmBoard?.motion != was, t > before + 0.05 { showFilm(from: before, to: t, back: t) }
    }

    /// Where the camera looks, and how close, to show layers whole with room round them at a
    /// moment: as close as they fit with a third more round them, and never further back than
    /// the whole artboard nor closer than eight times. Where each is then: its place in the
    /// design, grown as it is posed, and moved as it and everything that holds it are.
    static func cameraAim(at ids: [UUID], on board: Node, in doc: BezzleDocument, time t: Double) -> (move: [Double], zoom: Double)? {
        board.cameraAim(at: ids, in: doc, time: t)
    }

    /// Turns the scene under the camera as its pad is dragged: from how the camera stood when
    /// the drag began, by how far the pointer has gone since. Down tips the scene back, and left
    /// swings it round. Straight on is caught, each way by itself; `stepped`, with Shift held, it
    /// goes by fifteen degrees. Within a gesture, which the pad begins and ends.
    func turnScene(from: FilmCamera, by drag: CGSize, stepped: Bool) {
        var tilt = from.tilt + Double(drag.height) * 0.6
        var swing = from.swing - Double(drag.width) * 0.6
        if stepped {
            tilt = (tilt / 15).rounded() * 15
            swing = (swing / 15).rounded() * 15
        } else {
            if abs(tilt) < 2.5 { tilt = 0 }
            if abs(swing) < 2.5 { swing = 0 }
        }
        poseCamera(.cameraTilt, [tilt])
        poseCamera(.cameraSwing, [swing])
    }

    /// Has the camera look straight down at the playhead, as two clicks on its pad do.
    func straightenScene() {
        beginGesture()
        poseCamera(.cameraTilt, [0])
        poseCamera(.cameraSwing, [0])
        endGesture("Look Straight Down")
    }

    /// Has the camera see the whole artboard, straight on, from the playhead on.
    func restCamera() {
        guard filmBoard?.hasCamera == true else { return }
        beginGesture()
        for p in MotionProperty.camera { poseCamera(p, p.rest) }
        endGesture("See the Whole Artboard")
    }

    // MARK: Moves made in one go

    /// Gives what is picked a move at the playhead, one after another when there are several;
    /// with nothing picked, everything on the artboard. Then shows it.
    func applyMove(_ move: MotionMove) {
        guard let board = filmBoard else { return }
        var ids = posedLayers
        if ids.isEmpty { ids = board.children.filter { !$0.hidden && !$0.locked }.map(\.id) }
        guard !ids.isEmpty else { return }
        let t = filmTime
        let apart = ids.count > 1 ? film.apart : 0
        let going = film.going
        edit(.verbatim(move.title)) { $0.apply(move, to: ids, at: t, going: going, apart: apart) }
        let end = t + move.time + apart * Double(ids.count - 1)
        showFilm(from: t, to: min(end, filmBoard?.filmLength ?? end), back: going ? t : min(end, filmBoard?.filmLength ?? end))
    }

    /// Takes all motion from what is picked: the camera's, the layers', or with nothing picked
    /// the whole artboard's.
    func clearFilmMotion() {
        guard let board = filmBoard else { return }
        if film.camera {
            edit("Remove Motion") { doc in
                doc.update(board.id) { n in
                    for p in MotionProperty.camera { n[track: p] = nil }
                }
            }
        } else {
            let ids = posedLayers.isEmpty ? [board.id] : posedLayers
            edit("Remove Motion") { $0.clearMotion(ids) }
        }
        film.keys = []
    }

    // MARK: The film's own settings

    func setFilm(_ action: LocalizedStringResource, _ change: (inout Film) -> Void) {
        guard let board = filmBoard else { return }
        edit(action) { doc in
            doc.update(board.id) { n in
                var film = n.film ?? Film()
                change(&film)
                // A length is kept like a key's moment, to the thousandth of a second; one that
                // is none lets the film follow its keys.
                film.length = film.length.flatMap { $0.isFinite && MotionTiming.time($0) > 0 ? MotionTiming.time($0) : nil }
                n.film = film == Film() ? nil : film
            }
        }
        if film.time > (filmBoard?.filmLength ?? 0) { seek(film.time) }
    }

    // MARK: The film as a movie

    /// Asks where, and saves the film there as a movie, while the desk tells how far it is; then
    /// shows the movie in the Finder.
    func saveFilm(scale: CGFloat, fps: Int) {
        guard film.saving == nil, let board = filmBoard else { return }
        pauseFilm()
        // A film too long for a movie is said before asking where, not after.
        do { try FilmExport.check(board) } catch { NSAlert(error: error).runModal(); return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Save the Film as a Movie")
        panel.nameFieldStringValue = board.name + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeFilm(to: url, scale: scale, fps: fps)
    }

    /// Saves the film at a place as a movie, while the desk tells how far it is. A film that
    /// plays is stopped first. False, with nothing done, while another movie is being saved or
    /// with no film on the desk. `after` is told how it ended once the desk is clear again: with
    /// nothing when the movie is whole, with `CancellationError` when it was stopped, or with
    /// what went wrong. Left out, the movie is shown in the Finder, and what went wrong is said.
    @discardableResult
    func writeFilm(to url: URL, scale: CGFloat, fps: Int, after: (@MainActor (Error?) -> Void)? = nil) -> Bool {
        guard film.saving == nil, let board = filmBoard else { return false }
        pauseFilm()
        film.exporting = 0
        let assets = assets
        film.saving = Task { [weak self] in
            var failure: Error?
            do {
                try await FilmExport.write(board, assets: assets, to: url, settings: FilmExport.Settings(scale: scale, fps: fps)) { done in
                    self?.film.exporting = done
                }
            } catch {
                failure = error
            }
            self?.film.exporting = nil
            self?.film.saving = nil
            if let after {
                after(failure)
            } else if let failure {
                // Stopped by hand, there is nothing to say.
                if !(failure is CancellationError) { NSAlert(error: failure).runModal() }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        return true
    }

    func stopSavingFilm() {
        film.saving?.cancel()
    }
}
