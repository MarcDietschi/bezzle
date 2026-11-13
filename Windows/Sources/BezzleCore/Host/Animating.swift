import Foundation

// Animate on Windows, as the Mac's store has it (Store/AnimateOperations.swift, ported): the film
// on the desk, its playhead, what of it is picked, and everything the panel, the timeline, the
// canvas and the AI server do to it. The film itself is in the design (`Node.motion`, `Node.film`,
// Model/Motion.swift and Film.swift, shared); what is read of it for the timeline and the camera's
// aim are the shared Model/FilmKeys.swift.
//
// Where the Mac makes two changes in one gesture (the camera flown somewhere, the scene turned),
// each a step from the one before, they are one change here: inside a gesture the Windows core
// makes every change again from where the gesture began (Editing.swift).

extension WindowsCore {
    /// How a property stands at the playhead, for the bead beside it (the shared `FilmKeyState`).
    public enum KeyBead: Sendable { case none, between, here }

    @MainActor public final class FilmDesk {
        // MARK: The desk (the Mac's FilmDesk)

        /// The artboard whose film it is.
        public private(set) var board: UUID?
        /// Where the playhead rests: the moment that is posed.
        public private(set) var time = 0.0
        /// Where the playhead shows: the same, but for while the film plays, when it runs ahead.
        public private(set) var live = 0.0
        /// The same again, which the stage reads each frame.
        public private(set) var head = 0.0
        public private(set) var playing = false
        /// The camera picked, rather than any layer.
        public var camera = false { didSet { if camera != oldValue { changed() } } }
        /// The keys picked in the timeline.
        var keys: Set<FilmKeyRef> = [] { didSet { if keys != oldValue { changed() } } }
        /// The layers whose lines are opened into one for each property.
        public var open: Set<UUID> = [] { didSet { if open != oldValue { changed() } } }
        /// Whether the moves given in one go are how layers go, rather than how they come on.
        public var going = false { didSet { if going != oldValue { changed() } } }
        /// How many seconds apart several layers are given a move, one after another.
        public var apart = 0.06 { didSet { if apart != oldValue { changed() } } }
        /// How far saving the film as a movie has come, 0 to 1, while it is being saved.
        public internal(set) var exporting: Double? {
            didSet {
                guard exporting != oldValue else { return }
                savingChanged()
                // Begun or ended, the panel shows it; how far it has come it follows by itself.
                if (exporting == nil) != (oldValue == nil) { changed() }
            }
        }

        struct Pass {
            var began: Double
            var from: Double
            var to: Double?
            var back: Double?
        }
        var pass: Pass?
        var saving: Task<Void, Never>?

        /// How long a film that goes round rests at its end before it begins again.
        public static let breath = 0.7

        // MARK: What it is told, and tells

        /// The design animated: the window's fourth mode.
        public private(set) var on = false
        /// What is selected, as the window has it.
        public private(set) var selection: [UUID] = []
        /// Asks the window to select other layers (its select, which tells the film back).
        public var select: ([UUID]) -> Void = { _ in }
        /// The desk changed: the playhead, what is picked, the camera. Shown again.
        public var changed: () -> Void = {}
        /// The design was changed through the film: shown and saved.
        public var edited: () -> Void = {}
        /// The film began to play, or show something: the stage runs frame by frame.
        public var run: () -> Void = {}
        /// The artboard most in sight on the canvas.
        public var inSight: () -> UUID? = { nil }
        /// Glides the view so an artboard lies whole above the timeline, when it does not.
        public var frame: (UUID) -> Void = { _ in }
        /// Saving a movie went on or ended: how far it is, nil once it ended.
        public var savingChanged: () -> Void = {}

        public init() {}

        private var doc: BezzleDocument? { WindowsCore.design }

        // MARK: The mode

        public func modeChanged(_ animating: Bool) {
            guard animating != on else { return }
            on = animating
            if on {
                focus()
                frameIt()
            } else {
                pause()
                camera = false
                keys = []
            }
            changed()
        }

        /// The window's selection changed: the desk turns to its artboard, the camera is let go
        /// of for layers picked, and the picked keys of what is no longer picked go.
        public func selectionChanged(_ ids: [UUID]) {
            selection = ids
            guard on else { return }
            focus()
            if !ids.isEmpty, ids != board.map({ [$0] }) { camera = false }
            let kept = keys.filter { $0.layer == board || ids.contains($0.layer) }
            if kept != keys { keys = kept }
        }

        // MARK: The film on the desk

        /// The artboard whose film is worked on, as it is seen.
        var filmBoard: Node? {
            guard let id = board, let n = doc?.node(id), n.isArtboard, !n.hidden else { return nil }
            return WindowsCore.seen(n)
        }

        public var hasFilm: Bool { filmBoard != nil }

        /// Turns the desk to the artboard the selection is on; with nothing picked it stays, and
        /// before any was, takes the one most in sight.
        public func focus() {
            guard let doc else { return }
            func film(of id: UUID?) -> UUID? {
                guard let id, let n = doc.node(id), n.isArtboard, !n.hidden else { return nil }
                return id
            }
            var id: UUID?
            if let first = selection.first { id = film(of: doc.node(first)?.isArtboard == true ? first : doc.artboard(of: first)?.id) }
            if id == nil { id = film(of: board) }
            if id == nil { id = film(of: inSight()) ?? doc.artboards.first { !$0.hidden }?.id }
            guard board != id else { return }
            pause()
            board = id
            keys = []
            camera = false
            time = 0
            live = 0
            head = 0
            if on { frameIt() }
            changed()
        }

        /// The design changed with a film on the desk. One whose artboard is gone or hidden gives
        /// way to another's; a playhead left past the end of a film that got shorter comes back.
        public func designChanged() {
            guard on else { return }
            if let id = board, let n = doc?.node(id), n.isArtboard, !n.hidden {
                if !playing, let length = filmBoard?.filmLength, max(time, live) > length + 1e-9 { seek(length) }
            } else {
                focus()
            }
        }

        private func frameIt() {
            if let id = board { frame(id) }
        }

        /// The moment that is posed: the playhead, within the film as it is now.
        public var filmTime: Double { min(max(time, 0), filmBoard?.filmLength ?? 0) }

        /// The layers a pose is given to: those picked that lie on the film's artboard.
        public var posedLayers: [UUID] {
            guard let board = filmBoard else { return [] }
            return selection.filter { id in id != board.id && board.descendant(id).map { !$0.locked } == true }
        }

        /// Picks the camera, and lets go of the layers.
        public func pickCamera() {
            guard filmBoard != nil else { return }
            if !selection.isEmpty { select([]) }
            keys = []
            camera = true
        }

        // MARK: The playhead

        /// Puts the playhead at a moment, and stops the film there.
        public func seek(_ t: Double) {
            playing = false
            pass = nil
            let length = filmBoard?.filmLength ?? 0
            let to = min(MotionTiming.time(min(max(t.isNaN ? 0 : t, 0), length)), length)
            time = to
            live = to
            head = to
            changed()
        }

        /// Plays the film from the playhead, or from its start once it has reached the end.
        public func play(fromStart: Bool = false) {
            guard !WindowsCore.inGesture, let board = filmBoard else { return }
            var from = fromStart ? 0 : filmTime
            if from >= board.filmLength - 0.001 { from = 0 }
            pass = Pass(began: WindowsCore.now, from: from)
            live = from
            head = from
            playing = true
            changed()
            run()
        }

        /// Shows something just made by playing it once: from one moment to another, after which
        /// the playhead rests at `back`.
        public func show(from: Double, to: Double, back: Double) {
            guard filmBoard != nil, to > from else { return }
            pass = Pass(began: WindowsCore.now, from: from, to: to, back: back)
            live = from
            head = from
            playing = true
            changed()
            run()
        }

        /// Whether what plays is only a look at something just made.
        public var looking: Bool { pass?.to != nil }

        /// Stops the film where it is.
        public func pause() {
            guard playing else { return }
            let rest = pass?.back ?? live
            playing = false
            pass = nil
            seek(rest)
        }

        public func toggle() {
            if playing { pause() } else { play() }
        }

        /// Moves the playing film on to `now` (WindowsCore.now). False once it has stopped.
        public func step(_ now: Double) -> Bool {
            guard playing, let pass, let board = filmBoard else {
                let was = playing
                playing = false
                self.pass = nil
                live = time
                head = time
                if was { changed() }
                return false
            }
            let length = board.filmLength
            let t = pass.from + max(now - pass.began, 0)
            if let to = pass.to {
                if t >= to + 0.4 {
                    playing = false
                    self.pass = nil
                    seek(pass.back ?? to)
                    return false
                }
                head = min(t, to)
            } else if board.film?.once == true {
                if t >= length {
                    playing = false
                    self.pass = nil
                    seek(length)
                    return false
                }
                head = t
            } else {
                head = min(t.truncatingRemainder(dividingBy: length + Self.breath), length)
            }
            live = head
            return true
        }

        /// The moments anything picked has a key at, or with nothing picked, anything in the film.
        var stops: [Double] {
            guard let board = filmBoard else { return [] }
            var times: [Double] = []
            func add(_ more: [Double]) {
                for t in more where !times.contains(where: { MotionTiming.same($0, t) }) { times.append(t) }
            }
            let picked = posedLayers
            if camera {
                add(board.keyTimes(MotionProperty.camera))
            } else if !picked.isEmpty {
                for id in picked { add(board.descendant(id)?.keyTimes() ?? []) }
            } else {
                add(board.keyTimes(MotionProperty.camera))
                func walk(_ n: Node) {
                    guard !n.hidden else { return }
                    add(n.keyTimes())
                    n.children.forEach(walk)
                }
                board.children.forEach(walk)
            }
            return times.sorted()
        }

        /// Steps the playhead to the key before or after it, stopping a film that plays first.
        public func stepToKey(forward: Bool) {
            pause()
            let now = filmTime
            let all = stops
            let next = forward ? all.first { $0 > now + 0.0042 } : all.last { $0 < now - 0.0042 }
            seek(next ?? (forward ? filmBoard?.filmLength ?? 0 : 0))
        }

        /// Steps the playhead by frames of a sixtieth of a second, onto the frames themselves.
        public func stepFrames(_ count: Int) {
            pause()
            let frames = filmTime * 60
            let from = count > 0 ? (frames + 0.05).rounded(.down) : (frames - 0.05).rounded(.up)
            seek((from + Double(count)) / 60)
        }

        // MARK: Changing the design

        private func edit(_ change: (inout BezzleDocument) -> Void) {
            let before = WindowsCore.design
            WindowsCore.edit(change)
            if WindowsCore.design != before { edited() }
        }

        // MARK: Posing

        /// Poses a property of layers at the playhead, each at the value worked out from what it is.
        func pose(_ property: MotionProperty, of ids: [UUID], _ value: (Node) -> [Double]) {
            guard !property.isCamera else { return }
            let t = filmTime
            edit { doc in
                for id in ids {
                    doc.update(id) { n in
                        guard !n.locked else { return }
                        n.pose(property, value(n), at: t)
                    }
                }
            }
        }

        /// Poses several properties of layers at the playhead in one change, each layer's values
        /// worked out from what it is.
        func pose(of ids: [UUID], _ values: (Node) -> [(MotionProperty, [Double])]) {
            let t = filmTime
            edit { doc in
                for id in ids {
                    doc.update(id) { n in
                        guard !n.locked else { return }
                        for (property, value) in values(n) where !property.isCamera { n.pose(property, value, at: t) }
                    }
                }
            }
        }

        /// Poses camera properties at the playhead, in one change. Its first key at the start has
        /// it fly out to the whole artboard over the film's length, rather than in a layer's beat.
        func poseCamera(_ values: [(MotionProperty, [Double])]) {
            guard let board = filmBoard else { return }
            let t = filmTime, home = max(board.filmLength, 1)
            edit { doc in
                doc.update(board.id) { n in
                    for (property, value) in values where property.isCamera { n.pose(property, value, at: t, home: home) }
                }
            }
        }

        func poseCamera(_ property: MotionProperty, _ value: [Double]) { poseCamera([(property, value)]) }

        /// The number layers share of a property at the playhead, as the panel shows it; nil
        /// where they differ, or there are none.
        public func sharedValue(_ name: String, _ index: Int) -> Double? {
            guard let property = MotionProperty(rawValue: name), let board = filmBoard, index < property.rest.count else { return nil }
            let t = filmTime
            let values = posedLayers.compactMap { board.descendant($0)?.value(of: property, at: t)[index] }
            guard let first = values.first, values.allSatisfy({ abs($0 - first) < 1e-6 }) else { return nil }
            return first
        }

        /// Sets one number of a property of the picked layers at the playhead, as the panel's
        /// fields do. A scale's width set grows the layer as a whole.
        public func pose(_ name: String, number index: Int, to v: Double) {
            guard let property = MotionProperty(rawValue: name), !property.isCamera, index < property.rest.count, v.isFinite else { return }
            let t = filmTime
            pose(property, of: posedLayers) { n in
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

        /// The camera's number at the playhead.
        public func cameraValue(_ name: String, _ index: Int) -> Double {
            guard let property = MotionProperty(rawValue: name), let board = filmBoard else { return 0 }
            let v = board.value(of: property, at: filmTime)
            return index < v.count ? v[index] : 0
        }

        /// Sets one number of the camera at the playhead.
        public func poseCamera(_ name: String, number index: Int, to v: Double) {
            guard let property = MotionProperty(rawValue: name), let board = filmBoard, property.isCamera, index < property.rest.count, v.isFinite else { return }
            var now = board.value(of: property, at: filmTime)
            now[index] = v
            poseCamera(property, now)
        }

        // MARK: Shader inputs

        /// The inputs of the shader every picked layer has, by name.
        public var posedInputs: [String] {
            guard let board = filmBoard else { return [] }
            let layers = posedLayers
            let shaders = layers.compactMap { board.descendant($0)?.keyedShader }
            guard let first = shaders.first, shaders.count == layers.count else { return [] }
            return first.inputs.filter { name in shaders.allSatisfy { $0.value(of: name)?.count == first.value(of: name)?.count } }
        }

        /// How many numbers an input has.
        public func inputCount(_ name: String) -> Int {
            guard let board = filmBoard, let first = posedLayers.first else { return 1 }
            return board.descendant(first)?.shaderInput(name)?.count ?? 1
        }

        /// One number of an input the picked layers share at the playhead; nil where they differ.
        public func sharedInput(_ name: String, _ index: Int) -> Double? {
            guard let board = filmBoard else { return nil }
            let t = filmTime, layers = posedLayers
            let values = layers.compactMap { board.descendant($0)?.shaderInput(name, at: t) }.compactMap { index < $0.count ? $0[index] : nil }
            guard values.count == layers.count, let first = values.first, values.allSatisfy({ abs($0 - first) < 1e-6 }) else { return nil }
            return first
        }

        func poseInput(_ name: String, _ value: (Node) -> [Double]?) {
            let t = filmTime
            let ids = posedLayers
            edit { doc in
                for id in ids {
                    doc.update(id) { n in
                        guard !n.locked, let v = value(n) else { return }
                        n.poseInput(name, v, at: t)
                    }
                }
            }
        }

        /// Sets one number of an input at the playhead, as the panel's fields do.
        public func poseInput(_ name: String, number index: Int, to v: Double) {
            guard v.isFinite else { return }
            let t = filmTime
            poseInput(name) { n in
                guard var now = n.shaderInput(name, at: t), index < now.count else { return nil }
                now[index] = v
                return now
            }
        }

        /// Sets an input to a colour at the playhead: three or four numbers, as it has.
        public func poseInput(_ name: String, colour: [Double]) {
            poseInput(name) { n in
                guard let now = n.shaderInput(name) else { return nil }
                return Array(colour.prefix(now.count))
            }
        }

        public func inputKeyState(_ name: String) -> KeyBead {
            guard let board = filmBoard else { return .none }
            let t = filmTime
            var state = KeyBead.none
            for id in posedLayers {
                guard let track = board.descendant(id)?[track: ShaderFill.inputTrack(name)] else { continue }
                if track.index(at: t) != nil { return .here }
                state = .between
            }
            return state
        }

        public func toggleInputKey(_ name: String) {
            guard let board = filmBoard else { return }
            let t = filmTime, track = ShaderFill.inputTrack(name)
            let ids = posedLayers.filter { board.descendant($0)?.shaderInput(name) != nil }
            guard !ids.isEmpty else { return }
            let all = ids.allSatisfy { board.descendant($0)?[track: track]?.index(at: t) != nil }
            edit { doc in
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

        // MARK: Keys

        /// What poses and keys go to: the camera's artboard when the camera is picked, or the layers.
        private var keyTargets: [UUID] {
            if camera { return board.map { [$0] } ?? [] }
            return posedLayers
        }

        private func targets(of property: MotionProperty) -> [UUID] {
            property.isCamera ? (board.map { [$0] } ?? []) : posedLayers
        }

        public func keyState(_ name: String) -> KeyBead {
            guard let property = MotionProperty(rawValue: name), let board = filmBoard else { return .none }
            let t = filmTime
            var state = KeyBead.none
            for id in targets(of: property) {
                guard let track = (id == board.id ? board : board.descendant(id))?[track: property] else { continue }
                if track.index(at: t) != nil { return .here }
                state = .between
            }
            return state
        }

        /// Sets a key of a property at the playhead, holding what it is there; or, where
        /// everything picked has one there already, takes it away.
        public func toggleKey(_ name: String) {
            guard let property = MotionProperty(rawValue: name), let board = filmBoard else { return }
            let t = filmTime
            let ids = targets(of: property)
            guard !ids.isEmpty else { return }
            func node(_ id: UUID) -> Node? { id == board.id ? board : board.descendant(id) }
            let all = ids.allSatisfy { node($0)?[track: property]?.index(at: t) != nil }
            edit { doc in
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
        public func holdHere() {
            let t = filmTime
            let ids = keyTargets
            guard !ids.isEmpty else { return }
            edit { doc in
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

        /// How what is picked stands at the playhead, over everything of it that moves.
        public var holdState: KeyBead {
            guard let board = filmBoard else { return .none }
            let t = filmTime
            var state = KeyBead.none
            for id in keyTargets {
                guard let node = id == board.id ? board : board.descendant(id) else { continue }
                let tracks = node.motionProperties.compactMap { node[track: $0] } + node.inputTracks.compactMap { node[track: $0] }
                if tracks.contains(where: { $0.index(at: t) != nil }) { return .here }
                if !tracks.isEmpty { state = .between }
            }
            return state
        }

        /// The tracks a picked key stands for: one property's, one input's, or all the layer's,
        /// or all the camera's.
        func tracks(of ref: FilmKeyRef) -> [String] {
            if let p = ref.property { return [p.rawValue] }
            if let input = ref.input { return [ShaderFill.inputTrack(input)] }
            if ref.layer == board { return MotionProperty.camera.map(\.rawValue) }
            guard let node = filmBoard?.descendant(ref.layer) else { return MotionProperty.layer.map(\.rawValue) }
            return node.layerTracks
        }

        /// The keys picked in the timeline that are still there.
        var pickedKeys: [FilmKeyRef] {
            guard !keys.isEmpty, let board = filmBoard else { return [] }
            return keys.filter { ref in
                guard let node = ref.layer == board.id ? board : board.descendant(ref.layer) else { return false }
                return tracks(of: ref).contains { node[track: $0]?.index(at: ref.time) != nil }
            }
        }

        /// Whether Delete has keys to take away: some picked in the timeline, or some at the
        /// playhead of what is picked.
        public var hasKeysToRemove: Bool {
            if !pickedKeys.isEmpty { return true }
            guard let board = filmBoard else { return false }
            let t = filmTime
            return keyTargets.contains { id in
                (id == board.id ? board : board.descendant(id))?.motion?.values.contains { $0.index(at: t) != nil } == true
            }
        }

        /// Takes away the keys picked in the timeline; with none picked, those at the playhead of
        /// what is picked. Never a layer.
        public func removeKeys() {
            let t = filmTime
            var refs = pickedKeys
            if refs.isEmpty { refs = keyTargets.map { FilmKeyRef($0, at: t) } }
            if !keys.isEmpty { keys = [] }
            guard !refs.isEmpty else { return }
            edit { doc in
                for ref in refs {
                    doc.update(ref.layer) { $0.removeKeys(at: ref.time, tracks: tracks(of: ref)) }
                }
            }
        }

        /// The paces a key can come to it by: each kind's name and title.
        public static var paces: [(name: String, title: String)] {
            MotionEase.Kind.allCases.map { ($0.rawValue, MotionEase(kind: $0).title) }
        }

        static func ease(_ name: String) -> MotionEase? {
            guard let kind = MotionEase.Kind(rawValue: name) else { return nil }
            return kind == .spring ? .spring() : MotionEase(kind: kind)
        }

        /// Sets how the picked keys are come to; with none picked, those at the playhead.
        public func setEase(_ name: String) {
            guard let ease = Self.ease(name) else { return }
            let t = filmTime
            var refs = pickedKeys
            if refs.isEmpty { refs = keyTargets.map { FilmKeyRef($0, at: t) } }
            guard !refs.isEmpty else { return }
            edit { doc in
                for ref in refs {
                    doc.update(ref.layer) { $0.setEase(ease, at: ref.time, tracks: tracks(of: ref)) }
                }
            }
        }

        /// The pace the picked keys share, or those at the playhead, by name; nil when they
        /// differ or there are none.
        public var sharedEase: String? {
            guard let board = filmBoard else { return nil }
            let t = filmTime
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
            return found?.kind.rawValue
        }

        /// Moves keys in time, within a drag: `refs` are the keys as the drag began, and `delta`
        /// how far they have been dragged since. Gives back where they are now. Inside the drag's
        /// gesture each change is made again from where it began, as the Mac puts their motion
        /// back first.
        @discardableResult
        func retime(_ refs: [FilmKeyRef], by delta: Double) -> [FilmKeyRef] {
            guard WindowsCore.inGesture, !refs.isEmpty else { return refs }
            let delta = max(delta, -(refs.map(\.time).min() ?? 0))
            let ordered = refs.sorted { delta > 0 ? $0.ms > $1.ms : $0.ms < $1.ms }
            edit { doc in
                for ref in ordered {
                    doc.update(ref.layer) { $0.moveKeys(from: ref.time, to: ref.time + delta, tracks: tracks(of: ref)) }
                }
            }
            return refs.map { FilmKeyRef($0.layer, $0.property, input: $0.input, at: MotionTiming.time($0.time + delta)) }
        }

        // MARK: The camera, sent somewhere

        /// Has the camera look at the picked layers from the playhead on, and shows the flight.
        public func flyCamera() { flyCamera(to: posedLayers) }

        func flyCamera(to ids: [UUID]) {
            guard let board = filmBoard, let doc else { return }
            let t = filmTime
            guard let aim = board.cameraAim(at: ids, in: doc, time: t) else { return }
            let before = board.keyTimes(MotionProperty.camera).last { $0 < t - 0.0042 } ?? 0
            let was = board.motion
            poseCamera([(.cameraMove, aim.move), (.cameraZoom, [aim.zoom])])
            if filmBoard?.motion != was, t > before + 0.05 { show(from: before, to: t, back: t) }
        }

        /// The camera as it stands at the playhead.
        public struct CameraPose: Sendable, Equatable {
            public let x, y, zoom, roll, tilt, swing: Double
            public var isRest: Bool { x == 0 && y == 0 && zoom == 1 && roll == 0 && tilt == 0 && swing == 0 }
        }

        public var cameraPose: CameraPose? {
            guard let board = filmBoard else { return nil }
            let c = board.camera(at: filmTime)
            return CameraPose(x: c.x, y: c.y, zoom: c.zoom, roll: c.roll, tilt: c.tilt, swing: c.swing)
        }

        public var hasCameraMotion: Bool { filmBoard?.hasCamera == true }

        /// Turns the scene under the camera as its pad is dragged: from how the camera stood when
        /// the drag began, by how far the pointer has gone since. Down tips the scene back, and
        /// left swings it round; straight on is caught, each way by itself; `stepped` (Shift) goes
        /// by fifteen degrees. Within a gesture the pad begins and ends.
        public func turnScene(from: CameraPose, dx: Double, dy: Double, stepped: Bool) {
            var tilt = from.tilt + dy * 0.6
            var swing = from.swing - dx * 0.6
            if stepped {
                tilt = (tilt / 15).rounded() * 15
                swing = (swing / 15).rounded() * 15
            } else {
                if abs(tilt) < 2.5 { tilt = 0 }
                if abs(swing) < 2.5 { swing = 0 }
            }
            poseCamera([(.cameraTilt, [tilt]), (.cameraSwing, [swing])])
        }

        /// Has the camera look straight down at the playhead, as two clicks on its pad do.
        public func straightenScene() {
            poseCamera([(.cameraTilt, [0]), (.cameraSwing, [0])])
        }

        /// Has the camera see the whole artboard, straight on, from the playhead on.
        public func restCamera() {
            guard filmBoard?.hasCamera == true else { return }
            poseCamera(MotionProperty.camera.map { ($0, $0.rest) })
        }

        // MARK: Moves made in one go

        /// A property's name as Bezzle says it ("move" is Move), in the language Windows is in.
        public static func title(_ name: String) -> String { MotionProperty(rawValue: name)?.title ?? name }

        /// The moves, by name, with their titles.
        public static var moves: [(name: String, title: String)] {
            MotionMove.allCases.map { ($0.rawValue, $0.title) }
        }

        /// How long a move takes, in seconds.
        public static func moveTime(_ name: String) -> Double { MotionMove(rawValue: name)?.time ?? 0.5 }

        /// How far along a move's layer is from away (1) to home (0), `u` of its time in, as it
        /// comes on or goes; a spring goes a little past home. For the move chips' small drawings.
        public static func moveAway(_ name: String, going: Bool, at u: Double) -> Double {
            guard let move = MotionMove(rawValue: name) else { return 0 }
            if going { return MotionEase.progress(.easeIn, u) }
            return 1 - (move == .fade || move == .focus ? MotionEase.progress(.easeOut, u) : move.arriving.progress(u))
        }

        /// How many layers a move goes to now: those picked, or with none, everything on the artboard.
        public var moveCount: Int {
            guard let board = filmBoard else { return 0 }
            let picked = posedLayers
            return picked.isEmpty ? board.children.filter { !$0.hidden && !$0.locked }.count : picked.count
        }

        /// The name of the one layer picked.
        public var posedName: String? {
            guard let board = filmBoard, posedLayers.count == 1 else { return nil }
            return board.descendant(posedLayers[0])?.name
        }

        /// Gives what is picked a move at the playhead, one after another when there are several;
        /// with nothing picked, everything on the artboard. Then shows it.
        public func applyMove(_ name: String) {
            guard let move = MotionMove(rawValue: name), let board = filmBoard else { return }
            var ids = posedLayers
            if ids.isEmpty { ids = board.children.filter { !$0.hidden && !$0.locked }.map(\.id) }
            guard !ids.isEmpty else { return }
            let t = filmTime
            let apart = ids.count > 1 ? self.apart : 0
            let going = self.going
            edit { $0.apply(move, to: ids, at: t, going: going, apart: apart) }
            let end = t + move.time + apart * Double(ids.count - 1)
            let length = filmBoard?.filmLength ?? end
            show(from: t, to: min(end, length), back: going ? t : min(end, length))
        }

        /// Takes all motion from what is picked: the camera's, the layers', or with nothing
        /// picked the whole artboard's.
        public func clearMotion() {
            guard let board = filmBoard else { return }
            if camera {
                edit { doc in
                    doc.update(board.id) { n in
                        for p in MotionProperty.camera { n[track: p] = nil }
                    }
                }
            } else {
                let ids = posedLayers.isEmpty ? [board.id] : posedLayers
                edit { $0.clearMotion(ids) }
            }
            keys = []
        }

        /// Whether the artboard has any motion at all to take away.
        public var boardMoves: Bool { filmBoard?.hasFilm == true }

        // MARK: The film's own settings

        func setFilm(_ change: (inout Film) -> Void) {
            guard let board = filmBoard else { return }
            edit { doc in
                doc.update(board.id) { n in
                    var film = n.film ?? Film()
                    change(&film)
                    film.length = film.length.flatMap { $0.isFinite && MotionTiming.time($0) > 0 ? MotionTiming.time($0) : nil }
                    n.film = film == Film() ? nil : film
                }
            }
            if time > (filmBoard?.filmLength ?? 0) { seek(time) }
        }

        /// How many seconds the film runs, and whether that was set rather than following the keys.
        public var length: Double { filmBoard?.filmLength ?? MotionTiming.shortest }
        public var lengthSet: Bool { filmBoard?.film?.length != nil }
        /// The last moment anything in the film has a key at.
        public var lastKey: Double { filmBoard?.lastKey ?? 0 }
        public var once: Bool { filmBoard?.film?.once == true }

        /// Sets how long the film runs; nil lets it follow its keys.
        public func setLength(_ seconds: Double?) { setFilm { $0.length = seconds.map(MotionTiming.time) } }
        public func setOnce(_ once: Bool) { setFilm { $0.once = once ? true : nil } }

        /// What shows past the artboard's edges, as six hex digits and an alpha.
        public var backdrop: (hex: String, alpha: Double)? {
            guard let c = filmBoard?.filmBackdrop else { return nil }
            return (WindowsCore.hexOf(c), c.a)
        }

        public func setBackdrop(hex: String, alpha: Double) {
            guard let c = WindowsCore.colourOf(hex, alpha) else { return }
            setFilm { $0.backdrop = c }
        }

        /// The backdrop as the colour panel takes it.
        public var backdropColour: WindowsCore.Colour? { filmBoard.map { WindowsCore.Colour($0.filmBackdrop) } }

        public func setBackdrop(_ c: WindowsCore.Colour) {
            setFilm { $0.backdrop = RGBA(r: c.r, g: c.g, b: c.b, a: c.a) }
        }

        /// A shader input that reads as a colour, as the Mac's ShaderInputsCard tells one: named
        /// as one, three or four numbers.
        public func inputIsColour(_ name: String) -> Bool {
            let count = inputCount(name)
            return (count == 3 || count == 4) && name.range(of: "colou?r|tint|hue|ink|paint", options: [.regularExpression, .caseInsensitive]) != nil
        }

        /// An input's colour at the playhead, shared by the picked layers; nil where they differ.
        public func inputColour(_ name: String) -> WindowsCore.Colour? {
            let count = inputCount(name)
            let values = (0..<count).map { sharedInput(name, $0) }
            guard values.allSatisfy({ $0 != nil }), count >= 3 else { return nil }
            let v = values.map { min(max($0!, 0), 1) }
            return WindowsCore.Colour(r: v[0], g: v[1], b: v[2], a: count == 4 ? v[3] : 1)
        }

        public func poseInput(_ name: String, colour c: WindowsCore.Colour) {
            poseInput(name, colour: inputCount(name) == 4 ? [c.r, c.g, c.b, c.a] : [c.r, c.g, c.b])
        }

        /// The camera's pad: the film's frame fitted in a pad `size` big with room round it, and
        /// the artboard's sheet as the camera sees it there, ruled in thirds; nil corners for a
        /// sheet that reaches behind the eye.
        public func pad(size: CGSize) -> (frame: CGRect, sheet: [CGPoint]?, rules: [(CGPoint, CGPoint)])? {
            guard let board = filmBoard else { return nil }
            let s = board.frame.size
            guard s.width > 0, s.height > 0 else { return nil }
            let fit = min((size.width - 36) / s.width, (size.height - 26) / s.height)
            let frame = CGRect(x: (size.width - s.width * fit) / 2, y: (size.height - s.height * fit) / 2, width: s.width * fit, height: s.height * fit)
            let map = FilmLens.ground(board.camera(at: filmTime), size: s)
            func seen(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
                let at = CGPoint(x: x, y: y)
                guard map.depth(at: at) > 1e-3 else { return nil }
                let p = map(at)
                return CGPoint(x: frame.minX + p.x * fit, y: frame.minY + p.y * fit)
            }
            let corners = [seen(0, 0), seen(s.width, 0), seen(s.width, s.height), seen(0, s.height)].compactMap { $0 }
            var rules: [(CGPoint, CGPoint)] = []
            for i in 1..<3 {
                let k = CGFloat(i) / 3
                if let a = seen(s.width * k, 0), let b = seen(s.width * k, s.height) { rules.append((a, b)) }
                if let a = seen(0, s.height * k), let b = seen(s.width, s.height * k) { rules.append((a, b)) }
            }
            return (frame, corners.count == 4 ? corners : nil, rules)
        }
    }

    /// RGB as six hex digits.
    static func hexOf(_ c: RGBA) -> String {
        func two(_ v: Double) -> String {
            let s = String(Int((min(max(v, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return two(c.r) + two(c.g) + two(c.b)
    }

    static func colourOf(_ hex: String, _ alpha: Double) -> RGBA? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return RGBA(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: min(max(alpha, 0), 1))
    }
}
