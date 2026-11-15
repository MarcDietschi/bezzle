import AppKit

/// Keys copied in Animate's timeline: the app's own clipboard, kept apart from the pasteboard
/// and from every design, so that copying keys changes nothing that is saved or shared.
struct FilmClip {
    /// The keys, by the layer they were copied from (the artboard, for the camera's), each
    /// track's in the order of their moments.
    var keys: [UUID: [String: [MotionKey]]]
    /// The keys as they were picked: the pasted ones are picked the same way, a bead on a
    /// layer's line as every key it has at that moment, one on a property's line as that alone.
    var refs: [FilmKeyRef]
    /// The artboard they were copied in, whose camera's keys are among them under its id.
    var board: UUID

    /// The moment of the earliest of them: what lands on the playhead.
    var earliest: Double { keys.values.flatMap { $0.values.flatMap { $0.map(\.t) } }.min() ?? 0 }
    /// The layers whose keys they are, the camera's left out.
    var layers: [UUID] { keys.keys.filter { $0 != board } }
}

/// Copy, Cut, Paste and Duplicate in Animate, for the keys picked in the timeline. The layers
/// picked keep their own copying while no key is picked.
extension DocumentStore {
    static let cuttingKeys: LocalizedStringResource = "Cut Keys"
    static let pastingKeys: LocalizedStringResource = "Paste Keys"
    static let duplicatingKeys: LocalizedStringResource = "Duplicate Keys"

    /// The keys copied last, in any design: kept until other keys are copied, or layers are.
    static var filmClip: FilmClip?

    /// Whether there are keys picked to copy, cut or duplicate.
    var canCopyFilmKeys: Bool { animating && !pickedKeys.isEmpty }

    /// Copies the keys picked onto the app's own clipboard. False with none picked, when
    /// copying is the layers' (`copySelection`).
    @discardableResult
    func copyFilmKeys() -> Bool {
        guard animating, let board = filmBoard else { return false }
        let refs = pickedKeys
        guard !refs.isEmpty else { return false }
        Self.filmClip = FilmClip(keys: keys(of: refs, in: seenDoc), refs: refs, board: board.id)
        return true
    }

    /// Copies the keys picked and takes them away, as one step.
    func cutFilmKeys() {
        guard !isReadOnly, copyFilmKeys() else { return }
        let refs = pickedKeys
        film.keys = []
        edit(Self.cuttingKeys) { doc in
            for ref in refs {
                doc.update(ref.layer) { $0.removeKeys(at: ref.time, tracks: tracks(of: ref)) }
            }
        }
    }

    /// Whether Paste has keys to put down, and somewhere to put them.
    var canPasteFilmKeys: Bool {
        guard animating, !isReadOnly, let clip = Self.filmClip, let board = filmBoard else { return false }
        return !pasteTargets(of: clip, on: board).isEmpty
    }

    /// Pastes the keys copied at the playhead: the earliest of them on it, the others as far
    /// from it as they were from that one. Onto the layers and the properties they were copied
    /// from, and the camera's onto the camera of the film on the desk; where the keys of one
    /// layer alone were copied and other layers are picked, onto those. A key already at a
    /// moment gives way, as to a key moved onto it. As one step, after which the pasted keys
    /// are picked, with their layers.
    func pasteFilmKeys() {
        guard animating, !isReadOnly, let clip = Self.filmClip, let board = filmBoard else { return }
        let targets = pasteTargets(of: clip, on: board)
        guard !targets.isEmpty else { return }
        let delta = filmTime - clip.earliest
        var placed: [UUID: [String: [Double]]] = [:]
        edit(Self.pastingKeys) { doc in
            for (source, onto) in targets {
                guard let keys = clip.keys[source] else { continue }
                for id in onto {
                    doc.update(id) { n in
                        for (name, times) in Self.place(keys, onto: &n, by: delta, own: id == source) { placed[id, default: [:]][name, default: []] += times }
                    }
                }
            }
        }
        // Picked as they were copied: each by the bead it was picked by, where it came down.
        var refs: Set<FilmKeyRef> = []
        for (source, onto) in targets {
            for ref in clip.refs where ref.layer == source {
                let at = MotionTiming.time(ref.time + delta)
                for id in onto where placed[id]?.contains(where: { name, times in Self.holds(ref, name) && times.contains { MotionTiming.same($0, at) } }) == true {
                    refs.insert(FilmKeyRef(id, ref.property, input: ref.input, look: ref.look, at: at))
                }
            }
        }
        guard !refs.isEmpty, let after = filmBoard else { return }
        // The layers in the order the timeline has their lines; the camera where only its keys came down.
        let layers = FilmRow.rows(of: after, open: []).filter { !$0.camera }.map(\.layer).filter { id in refs.contains { $0.layer == id } }
        if selection != layers { selection = layers }
        let camera = layers.isEmpty
        if film.camera != camera { film.camera = camera }
        film.keys = refs
    }

    /// Duplicate in the Edit menu: the keys picked, while Animate has any; else the layers picked.
    func duplicate() {
        if canCopyFilmKeys { duplicateFilmKeys() } else { duplicateSelection() }
    }

    var canDuplicate: Bool { canCopyFilmKeys || !selection.isEmpty }

    /// Puts copies of the keys picked after them, half a second after the last of them and as
    /// far apart as they are, on the layers and the properties they are of, as one step: the
    /// motion again, a beat later. The copies are picked then.
    func duplicateFilmKeys() {
        guard animating, !isReadOnly else { return }
        let refs = pickedKeys
        guard let first = refs.map(\.time).min(), let last = refs.map(\.time).max() else { return }
        let delta = last - first + MotionTiming.beat
        let keys = keys(of: refs, in: seenDoc)
        edit(Self.duplicatingKeys) { doc in
            for (id, tracks) in keys { doc.update(id) { _ = Self.place(tracks, onto: &$0, by: delta, own: true) } }
        }
        film.keys = Set(refs.map { FilmKeyRef($0.layer, $0.property, input: $0.input, look: $0.look, at: MotionTiming.time($0.time + delta)) })
    }

    // MARK: Taking keys, and putting them down

    /// The keys picked, as a design has them: each layer's, by track, in the order of their moments.
    func keys(of refs: [FilmKeyRef], in doc: BezzleDocument) -> [UUID: [String: [MotionKey]]] {
        var out: [UUID: [String: [MotionKey]]] = [:]
        for ref in refs {
            guard let node = doc.node(ref.layer) else { continue }
            for name in tracks(of: ref) {
                guard let track = node[track: name], let i = track.index(at: ref.time) else { continue }
                var list = out[ref.layer]?[name] ?? []
                guard !list.contains(where: { MotionTiming.same($0.t, track.keys[i].t) }) else { continue }
                list.append(track.keys[i])
                list.sort { $0.t < $1.t }
                out[ref.layer, default: [:]][name] = list
            }
        }
        return out
    }

    /// Where the keys copied go, by the layer they were copied from: the camera's onto the
    /// camera of this film; a layer's onto itself, where it is on this film's artboard and not
    /// locked; but the keys of one layer alone onto the layers picked, where any other is.
    func pasteTargets(of clip: FilmClip, on board: Node) -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [:]
        let picked = posedLayers, layers = clip.layers
        for source in clip.keys.keys {
            if source == clip.board {
                out[source] = [board.id]
            } else if layers.count == 1, picked.contains(where: { $0 != source }) {
                out[source] = picked
            } else if let node = board.descendant(source), !node.locked {
                out[source] = [source]
            }
        }
        return out
    }

    /// Puts keys onto a layer at their moments, `delta` seconds later: a key already at one
    /// gives way, as it does to a key moved onto it. Onto the layer they were taken from
    /// (`own`) they go as they were; onto another only what it can take (`taken`). A key put
    /// back where it was is as it was; anywhere else it is no longer one Bezzle gave. Gives
    /// back the moments put down, by track.
    static func place(_ keys: [String: [MotionKey]], onto n: inout Node, by delta: Double, own: Bool) -> [String: [Double]] {
        var placed: [String: [Double]] = [:]
        for (name, list) in keys {
            var down: [MotionKey] = []
            for var key in list {
                let at = MotionTiming.time(key.t + delta)
                if !own {
                    guard let v = taken(key.v, onto: n, track: name) else { continue }
                    key.v = v
                }
                if !MotionTiming.same(at, key.t) { key.given = nil }
                key.t = at
                down.append(key)
            }
            guard !down.isEmpty else { continue }
            // Keys another layer has of a look it no longer has as they say give way to ones
            // that fit it, as when such a look is keyed by hand (`setLookKey`).
            if !own, let look = LookTrack(name: name), n[track: name] != nil, !n.fits(look) { n[track: name] = nil }
            var track = n[track: name] ?? MotionTrack()
            for key in down {
                track.keys.removeAll { MotionTiming.same($0.t, key.t) }
                track.keys.append(key)
                placed[name, default: []].append(key.t)
            }
            track.keys.sort { $0.t < $1.t }
            n[track: name] = track
        }
        return placed
    }

    /// A key's numbers as another layer takes them, or nil where it cannot: the camera's only
    /// onto an artboard and a layer's never; a Shape only of as many points or as an outline of
    /// its own, kept within what each property allows; a shader's input only where its shader
    /// has that input with as many numbers; a look only where the layer has it as the key says
    /// (a fill of one colour for a colour's key, a gradient of as many colours for its stops').
    private static func taken(_ v: [Double], onto n: Node, track name: String) -> [Double]? {
        if let property = MotionProperty(rawValue: name) {
            guard property.isCamera == n.isArtboard, n.takes(property, v) else { return nil }
            return n.kept(property, v)
        }
        if let input = ShaderFill.input(of: name) { return n.shaderInput(input)?.count == v.count ? v : nil }
        if let look = LookTrack(name: name) { return n.lookCount(look) == v.count ? v : nil }
        return nil
    }

    /// Whether a picked key stands for a track: a bead on a layer's line for each of them.
    private static func holds(_ ref: FilmKeyRef, _ name: String) -> Bool {
        if let property = ref.property { return property.rawValue == name }
        if let input = ref.input { return ShaderFill.inputTrack(input) == name }
        if let look = ref.look { return look.name == name }
        return true
    }
}
