import Foundation
import CoreGraphics

// What Animate's timeline and panel read of a film, in every Bezzle: a key picked, how a property
// stands at the playhead, the timeline's lines and where moments lie along them, and where the
// camera looks to show layers whole. Moved here unchanged from the Mac's AnimateOperations.swift
// and FilmHand.swift, for Windows to work out the same.

/// A key picked in the timeline.
struct FilmKeyRef: Hashable {
    /// The layer whose key it is; the artboard for the camera's.
    var layer: UUID
    /// One property's key, or every key the layer has at that moment.
    var property: MotionProperty?
    /// One shader input's key, in place of a property's.
    var input: String?
    /// The moment, in thousandths of a second.
    var ms: Int

    init(_ layer: UUID, _ property: MotionProperty? = nil, input: String? = nil, at time: Double) {
        self.layer = layer
        self.property = property
        self.input = input
        ms = Int((time * 1000).rounded())
    }

    var time: Double { Double(ms) / 1000 }
}

/// How a property stands at the playhead, for the bead beside it.
enum FilmKeyState {
    /// No keys at all: as designed throughout.
    case none
    /// Keys, but none at this moment.
    case between
    /// A key at this moment.
    case here
}

// MARK: - Lines

/// One line of the timeline: the camera, a layer that moves, or one property of either.
struct FilmRow: Identifiable, Equatable {
    var id: String
    /// The layer whose line it is; the artboard for the camera's.
    var layer: UUID
    var camera = false
    /// One property's keys alone, on a line opened out of its layer's.
    var property: MotionProperty?
    /// One shader input's keys alone, likewise.
    var input: String?
    var name: String
    var kind: Node.Kind?
    var marks: [Mark] = []

    /// Whether it is one property's or one input's line, opened out of its layer's.
    var single: Bool { property != nil || input != nil }

    /// Whether a picked key is on this line: one of its own, or any of its layer's on the layer's line.
    func holds(_ ref: FilmKeyRef) -> Bool {
        guard ref.layer == layer else { return false }
        let whole = ref.property == nil && ref.input == nil
        return whole || !single || (ref.property == property && ref.input == input)
    }

    /// A moment with a key.
    struct Mark: Equatable {
        var t: Double
        /// As designed there: its bead is hollow.
        var home: Bool
        /// Made by Bezzle to go with a first pose, and not yet touched.
        var given: Bool
        /// How it is come to from the one before, on a property's own line.
        var pace: MotionTrack.Pace?
    }

    /// The camera's line, then one for each layer that moves, the front ones first as the
    /// layers list has them; and under those opened, one for each of their properties.
    static func rows(of board: Node, open: Set<UUID>) -> [FilmRow] {
        var out: [FilmRow] = []
        func add(_ node: Node, camera: Bool) {
            let properties = node.motionProperties.filter { $0.isCamera == camera }
            var row = FilmRow(id: node.id.uuidString + (camera ? ":camera" : ""), layer: node.id, camera: camera,
                              name: camera ? String(localized: "animate.camera", defaultValue: "Camera") : node.name,
                              kind: camera ? nil : node.kind)
            let inputs = camera ? [] : node.inputTracks
            row.marks = marks(of: node, tracks: properties.map(\.rawValue) + inputs)
            out.append(row)
            guard open.contains(node.id) else { return }
            for p in properties {
                var line = FilmRow(id: row.id + ":" + p.rawValue, layer: node.id, camera: camera, property: p, name: p.title)
                line.marks = marks(of: node, [p])
                out.append(line)
            }
            for track in inputs {
                guard let input = ShaderFill.input(of: track) else { continue }
                var line = FilmRow(id: row.id + ":" + track, layer: node.id, camera: false, input: input, name: input)
                line.marks = marks(of: node, tracks: [track])
                out.append(line)
            }
        }
        add(board, camera: true)
        func walk(_ nodes: [Node]) {
            for n in nodes.reversed() where !n.hidden {
                if n.isAnimated { add(n, camera: false) }
                walk(n.children)
            }
        }
        walk(board.children)
        return out
    }

    static func marks(of node: Node, _ properties: [MotionProperty]) -> [Mark] {
        marks(of: node, tracks: properties.map(\.rawValue))
    }

    /// The moments of these tracks' keys, by name: a property's or a shader input's.
    static func marks(of node: Node, tracks names: [String]) -> [Mark] {
        var out: [Mark] = []
        for name in names {
            guard let track = node[track: name] else { continue }
            let rest = node.rest(of: name)
            for (i, key) in track.keys.enumerated() {
                let home = MotionTiming.alike(key.v, rest)
                if let j = out.firstIndex(where: { MotionTiming.same($0.t, key.t) }) {
                    out[j].home = out[j].home && home
                    out[j].given = out[j].given && key.given == true
                } else {
                    out.append(Mark(t: key.t, home: home, given: key.given == true,
                                    pace: names.count == 1 && i > 0 ? track.pace(of: i - 1, rest: rest) : nil))
                }
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}

/// Where moments lie along the sheet.
struct FilmScale: Equatable {
    var width: CGFloat
    /// The seconds the width shows.
    var span: Double

    /// Room either side, so a bead at the start or the end is whole.
    static let inset: CGFloat = 14

    /// The film, and a little past its end: room for the flag, and to pose something later.
    static func span(for length: Double) -> Double { max(length / 0.9, 0.5) }

    var perSecond: CGFloat { max(width - Self.inset * 2, 1) / CGFloat(span) }
    func x(_ t: Double) -> CGFloat { Self.inset + CGFloat(t) * perSecond }
    func t(_ x: CGFloat) -> Double { Double((x - Self.inset) / perSecond) }
}

// MARK: - The camera, sent somewhere

extension Node {
    /// Artboards: where the camera looks, and how close, to show layers whole with room round
    /// them at a moment: as close as they fit with a third more round them, and never further
    /// back than the whole artboard nor closer than eight times. Where each is then: its place in
    /// the design, grown as it is posed, and moved as it and everything that holds it are.
    func cameraAim(at ids: [UUID], in doc: BezzleDocument, time t: Double) -> (move: [Double], zoom: Double)? {
        let board = self
        var whole = CGRect.null
        for id in ids {
            guard let way = board.way(to: id), let node = way.last, let frame = doc.absoluteFrame(of: id) else { continue }
            let pose = node.pose(at: t)
            var r = frame.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
            for holder in way {
                let move = holder.pose(at: t).move
                r = r.offsetBy(dx: move.x, dy: move.y)
            }
            r = r.insetBy(dx: r.width * (1 - pose.scale.x) / 2, dy: r.height * (1 - pose.scale.y) / 2)
            whole = whole.union(r)
        }
        guard !whole.isNull else { return nil }
        let size = board.frame.size
        // A line has no height to fill the picture with, and is looked at by its length alone.
        let zoom = min(max(min(size.width / (max(whole.width, 1) * 1.35), size.height / (max(whole.height, 1) * 1.35)), 1), 8)
        return ([Double(whole.midX - size.width / 2), Double(whole.midY - size.height / 2)], Double(zoom))
    }
}
