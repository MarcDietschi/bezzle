import Foundation
import CoreGraphics

// MARK: - What moves

/// What of a layer can change as time passes, in Animate. Each is kept as a change from the design
/// and never as a place of its own: `move` is how far from where the design has the layer, `scale`
/// how many times its size, `fade` how much of its opacity. So the design stays where things
/// belong: a layer moved or restyled there takes its whole motion with it, and a layer with no
/// keys is simply as designed. The camera's are an artboard's: the whole scene as it is filmed.
nonisolated enum MotionProperty: String, CaseIterable, Codable, Hashable, Sendable {
    /// Points right and down from where the design has it.
    case move
    /// Times its width and its height, about its middle.
    case scale
    /// Degrees clockwise, added to how far it is turned.
    case turn
    /// Times its opacity.
    case fade
    /// Points nearer the eye, above the artboard.
    case lift
    /// Degrees tipped back, its top going away.
    case tilt
    /// Degrees swung round, its right side going away.
    case swing
    /// Points of blur, added to its own.
    case blur
    /// Where the camera looks, in points from the artboard's middle.
    case cameraMove
    /// How many times closer than seeing the whole artboard.
    case cameraZoom
    /// Degrees the picture is turned clockwise.
    case cameraRoll
    /// Degrees the scene is tipped back under the camera, its top going away.
    case cameraTilt
    /// Degrees the scene is swung round under it, its right side going away.
    case cameraSwing

    static let layer: [MotionProperty] = [.move, .scale, .turn, .fade, .lift, .tilt, .swing, .blur]
    static let camera: [MotionProperty] = [.cameraMove, .cameraZoom, .cameraRoll, .cameraTilt, .cameraSwing]

    var isCamera: Bool { Self.camera.contains(self) }

    /// The value that changes nothing: the layer as designed, the camera on the whole artboard.
    var rest: [Double] {
        switch self {
        case .move, .cameraMove: [0, 0]
        case .scale: [1, 1]
        case .fade, .cameraZoom: [1]
        case .turn, .lift, .tilt, .swing, .blur, .cameraRoll, .cameraTilt, .cameraSwing: [0]
        }
    }

    /// A value as it may be kept: as many numbers as the property has, each within what shows.
    func clamped(_ v: [Double]) -> [Double] {
        var out = rest
        for i in out.indices where i < v.count && v[i].isFinite { out[i] = v[i] }
        switch self {
        case .scale: out = out.map { min(max($0, 0.001), 100) }
        case .fade: out[0] = min(max(out[0], 0), 1)
        case .blur: out[0] = min(max(out[0], 0), 200)
        case .lift: out[0] = min(max(out[0], -4000), 4000)
        case .tilt, .swing: out[0] = min(max(out[0], -360), 360)
        case .cameraZoom: out[0] = min(max(out[0], 0.1), 16)
        case .cameraTilt, .cameraSwing: out[0] = min(max(out[0], -80), 80)
        case .move, .turn, .cameraMove, .cameraRoll: break
        }
        return out
    }

    var title: String {
        switch self {
        case .move: String(localized: "animate.move", defaultValue: "Move")
        case .scale: String(localized: "animate.scale", defaultValue: "Scale")
        case .turn: String(localized: "animate.turn", defaultValue: "Turn")
        case .fade: String(localized: "animate.fade", defaultValue: "Fade")
        case .lift: String(localized: "animate.lift", defaultValue: "Lift")
        case .tilt: String(localized: "animate.tilt", defaultValue: "Tilt")
        case .swing: String(localized: "animate.swing", defaultValue: "Swing")
        case .blur: String(localized: "animate.blur", defaultValue: "Blur")
        case .cameraMove: String(localized: "animate.camera.move", defaultValue: "Look At")
        case .cameraZoom: String(localized: "animate.camera.zoom", defaultValue: "Zoom")
        case .cameraRoll: String(localized: "animate.camera.roll", defaultValue: "Roll")
        case .cameraTilt: String(localized: "animate.camera.tilt", defaultValue: "Tilt")
        case .cameraSwing: String(localized: "animate.camera.swing", defaultValue: "Swing")
        }
    }
}

// MARK: - Keys

/// How a value comes to a key from the one before it.
nonisolated struct MotionEase: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// Read from the keys round it: a motion that keeps going the same way flows through its
        /// keys, and one that ends or turns back comes to rest there.
        case auto
        /// Starts gently and arrives gently.
        case smooth
        /// Starts gently, arrives at speed.
        case easeIn = "in"
        /// Starts at speed, arrives gently.
        case easeOut = "out"
        /// The same speed all the way.
        case linear
        /// Arrives as on a spring, a little past and back.
        case spring
        /// Stays as it was, then is there at once.
        case hold
    }

    var kind: Kind = .auto
    /// Springs only: how far past it goes, 0 (not at all) to 1.
    var bounce: Double?

    static let auto = MotionEase()
    static let smooth = MotionEase(kind: .smooth)
    static let easeIn = MotionEase(kind: .easeIn)
    static let easeOut = MotionEase(kind: .easeOut)
    static let linear = MotionEase(kind: .linear)
    static let hold = MotionEase(kind: .hold)
    static func spring(_ bounce: Double = 0.3) -> MotionEase { MotionEase(kind: .spring, bounce: bounce) }

    var title: String {
        switch kind {
        case .auto: String(localized: "ease.auto", defaultValue: "Auto")
        case .smooth: String(localized: "ease.smooth", defaultValue: "Smooth")
        case .easeIn: String(localized: "ease.in", defaultValue: "Gathers Speed")
        case .easeOut: String(localized: "ease.out", defaultValue: "Settles")
        case .linear: String(localized: "ease.linear", defaultValue: "Even")
        case .spring: String(localized: "ease.spring", defaultValue: "Spring")
        case .hold: String(localized: "ease.hold", defaultValue: "Hold")
        }
    }

    /// How far along the way the value is when `u` of the time has passed, both 0 to 1; a spring
    /// goes past 1 and comes back. `auto` is worked out by the track (`MotionTrack.pace`).
    func progress(_ u: Double) -> Double { Self.progress(kind, u, bounce: bounce ?? 0.3) }

    static func progress(_ kind: Kind, _ u: Double, bounce: Double = 0.3) -> Double {
        let u = min(max(u, 0), 1)
        switch kind {
        case .auto, .smooth: return bezier(0.45, 0, 0.2, 1, u)
        case .easeIn: return bezier(0.6, 0, 0.9, 0.4, u)
        case .easeOut: return bezier(0.1, 0.7, 0.2, 1, u)
        case .linear: return u
        case .hold: return u >= 1 ? 1 : 0
        case .spring: return spring(u, bounce: bounce)
        }
    }

    /// Setting off from rest, and reaching full speed as it arrives: what a flight through
    /// several keys begins with. Its slope where it arrives is 1, the speed the flight goes on at.
    static func setOff(_ u: Double) -> Double { u * u * (2 - u) }
    /// The other way: at full speed first, slowing to rest.
    static func setDown(_ u: Double) -> Double { 1 - setOff(1 - u) }

    /// A spring let go at 0 that settles at 1 by the end: critically damped with no bounce, and
    /// ringing more the more it has.
    static func spring(_ u: Double, bounce: Double) -> Double {
        let zeta = 1 - 0.78 * min(max(bounce, 0), 1)
        // Stiff enough to have all but settled when the time is up.
        let omega = 7.2 / zeta
        func raw(_ x: Double) -> Double {
            if zeta >= 0.999 { return 1 - exp(-omega * x) * (1 + omega * x) }
            let wd = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * x) * (cos(wd * x) + zeta * omega / wd * sin(wd * x))
        }
        // What is left of it at the end is taken up evenly, so it ends exactly there.
        return raw(u) + (1 - raw(1)) * u
    }

    /// A cubic Bézier timing curve from 0,0 to 1,1 with these two handles, as CSS has them.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func at(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        // The curve's own parameter where it is `x` across, by halving: it only ever rises.
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<32 {
            let got = at(x1, x2, t)
            if abs(got - x) < 1e-7 { break }
            if got < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return at(y1, y2, t)
    }
}

/// A moment at which a property has a set value: between two of them it changes from the one to
/// the other.
nonisolated struct MotionKey: Codable, Hashable, Sendable {
    /// Seconds from the start of the artboard's film.
    var t: Double
    /// The value there, as many numbers as its property has.
    var v: [Double]
    /// How the value comes here from the key before; nil reads it from the keys round it.
    var ease: MotionEase?
    /// Made by Bezzle to go with the first key posed: the design itself, where the motion ends or
    /// begins. It gives way when a later key is posed past it, and is anyone's once it is touched.
    var given: Bool?

    init(t: Double, v: [Double], ease: MotionEase? = nil, given: Bool? = nil) {
        self.t = MotionTiming.time(t)
        self.v = v
        self.ease = ease
        self.given = given
    }
}

/// One property's keys, in the order of their times.
nonisolated struct MotionTrack: Codable, Hashable, Sendable {
    var keys: [MotionKey] = []

    init(_ keys: [MotionKey] = []) {
        self.keys = keys.sorted { $0.t < $1.t }
    }

    var start: Double? { keys.first?.t }
    var end: Double? { keys.last?.t }

    /// The key at a time, give or take a quarter of a frame.
    func index(at t: Double) -> Int? { keys.firstIndex { MotionTiming.same($0.t, t) } }

    /// How the stretch from key `i` to the next is paced.
    enum Pace: Equatable {
        case curve(MotionEase.Kind, bounce: Double)
        /// Part of a flight through several keys: setting off, on its way, or setting down.
        case setOff, onward, setDown
    }

    /// Whether the motion keeps going the same way through key `i`, rather than ending or
    /// turning back there: then it flows through, at speed.
    func flows(through i: Int) -> Bool {
        guard i > 0, i < keys.count - 1 else { return false }
        // Only where both stretches are left to Bezzle; a pace that was chosen is kept.
        guard (keys[i].ease?.kind ?? .auto) == .auto, (keys[i + 1].ease?.kind ?? .auto) == .auto else { return false }
        let a = keys[i - 1].v, b = keys[i].v, c = keys[i + 1].v
        var dot = 0.0, before = 0.0, after = 0.0
        for k in 0..<min(a.count, b.count, c.count) {
            let d1 = b[k] - a[k], d2 = c[k] - b[k]
            dot += d1 * d2
            before += d1 * d1
            after += d2 * d2
        }
        return dot > 1e-9 && before > 1e-12 && after > 1e-12
    }

    func pace(of i: Int, rest: [Double]) -> Pace {
        let ease = keys[i + 1].ease ?? .auto
        guard ease.kind == .auto else { return .curve(ease.kind, bounce: ease.bounce ?? 0.3) }
        switch (flows(through: i), flows(through: i + 1)) {
        case (true, true): return .onward
        case (false, true): return .setOff
        case (true, false): return .setDown
        case (false, false):
            // Coming home to the design, it arrives gently; anywhere else, gently both ways.
            return .curve(MotionTiming.alike(keys[i + 1].v, rest) && !MotionTiming.alike(keys[i].v, rest) ? .easeOut : .smooth, bounce: 0.3)
        }
    }

    /// The value at a time: before the first key what that says, after the last what that says,
    /// and between two, on the way from one to the other.
    func value(at t: Double, rest: [Double]) -> [Double] {
        guard let first = keys.first, let last = keys.last else { return rest }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        var i = 0
        while i < keys.count - 2, keys[i + 1].t <= t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        guard span > 1e-9 else { return b.v }
        let u = (t - a.t) / span
        let n = min(a.v.count, b.v.count)
        func mix(_ p: Double) -> [Double] { (0..<n).map { a.v[$0] + (b.v[$0] - a.v[$0]) * p } }
        switch pace(of: i, rest: rest) {
        case .curve(let kind, let bounce):
            return mix(MotionEase.progress(kind, u, bounce: bounce))
        case .setOff:
            return flown(i, MotionEase.setOff(u))
        case .setDown:
            return flown(i, MotionEase.setDown(u))
        case .onward:
            return flown(i, u)
        }
    }

    /// Part of a flight through keys: a curve through them that leaves and reaches each at the
    /// speed the flight has there, so nothing jerks where one stretch hands over to the next.
    private func flown(_ i: Int, _ p: Double) -> [Double] {
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        let n = min(a.v.count, b.v.count)
        // The speed through a key: from the key before it to the one after, over the time between.
        func speed(_ k: Int, _ c: Int) -> Double {
            guard flows(through: k) else { return (b.v[c] - a.v[c]) / span }
            return (keys[k + 1].v[c] - keys[k - 1].v[c]) / (keys[k + 1].t - keys[k - 1].t)
        }
        let p2 = p * p, p3 = p2 * p
        let h00 = 2 * p3 - 3 * p2 + 1, h10 = p3 - 2 * p2 + p, h01 = -2 * p3 + 3 * p2, h11 = p3 - p2
        return (0..<n).map { c in
            h00 * a.v[c] + h10 * speed(i, c) * span + h01 * b.v[c] + h11 * speed(i + 1, c) * span
        }
    }
}

/// Times and values as Animate keeps and compares them.
nonisolated enum MotionTiming {
    /// A time as it is kept: to the thousandth of a second, never before the start.
    static func time(_ t: Double) -> Double { (max(t, 0) * 1000).rounded() / 1000 }

    /// Whether two times are the same moment: within a quarter of a frame at 60 a second.
    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0042 }

    static func alike(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
    }

    /// How long a motion made in one go lasts, such as a layer posed at the start flying home.
    static let beat = 0.5
    /// How long a film is while nothing in it says: long enough to pose a few things in.
    static let shortest = 2.0
}

// MARK: - A layer's motion

nonisolated extension Node {
    /// One property's keys; nil while it has none. Setting a track without keys takes it away.
    subscript(track property: MotionProperty) -> MotionTrack? {
        get { motion?[property.rawValue] }
        set {
            var all = motion ?? [:]
            all[property.rawValue] = newValue.flatMap { $0.keys.isEmpty ? nil : $0 }
            motion = all.isEmpty ? nil : all
        }
    }

    /// The properties with keys, layers' before the camera's, in their own order.
    var motionProperties: [MotionProperty] {
        guard let motion, !motion.isEmpty else { return [] }
        return MotionProperty.allCases.filter { motion[$0.rawValue]?.keys.isEmpty == false }
    }

    /// Whether the layer itself moves in time: any of its own properties has keys.
    var isAnimated: Bool { motionProperties.contains { !$0.isCamera } }

    /// Whether anything it holds does, however deep.
    var holdsMotion: Bool { children.contains { $0.isAnimated || $0.holdsMotion } }

    /// Artboards: whether the camera ever leaves the whole artboard.
    var hasCamera: Bool { motionProperties.contains(where: \.isCamera) }

    /// A property's value at a time: on its way between its keys, or as designed.
    func value(of property: MotionProperty, at t: Double) -> [Double] {
        guard let track = self[track: property] else { return property.rest }
        return property.clamped(track.value(at: t, rest: property.rest))
    }

    /// Every moment the layer has a key at, for any of these properties, in order.
    func keyTimes(_ properties: [MotionProperty] = MotionProperty.layer) -> [Double] {
        var out: [Double] = []
        for p in properties {
            for k in self[track: p]?.keys ?? [] where !out.contains(where: { MotionTiming.same($0, k.t) }) { out.append(k.t) }
        }
        return out.sorted()
    }

    /// The last moment anything of it, or in it, has a key at.
    var lastKey: Double {
        var last = 0.0
        for track in (motion ?? [:]).values { last = max(last, track.end ?? 0) }
        for child in children { last = max(last, child.lastKey) }
        return last
    }

    // MARK: Posing

    /// Poses a property at a moment, as moving a layer there in Animate does. The first key a
    /// property is given comes with the design for company, so one gesture makes a whole motion:
    /// posed at the start, the layer flies home from there over `home` seconds; posed later, it
    /// leaves the design at the start and is there by then. After that, each pose is one more key.
    /// Posing a property that has no keys as designed does nothing.
    mutating func pose(_ property: MotionProperty, _ value: [Double], at time: Double, home: Double = MotionTiming.beat) {
        let t = MotionTiming.time(time), v = property.clamped(value)
        guard var track = self[track: property] else {
            guard !MotionTiming.alike(v, property.rest) else { return }
            if t < 0.0042 {
                self[track: property] = MotionTrack([MotionKey(t: 0, v: v), MotionKey(t: max(home, 0.05), v: property.rest, given: true)])
            } else {
                self[track: property] = MotionTrack([MotionKey(t: 0, v: property.rest, given: true), MotionKey(t: t, v: v)])
            }
            return
        }
        if let i = track.index(at: t) {
            track.keys[i].v = v
            track.keys[i].given = nil
        } else {
            // The design it was given to fly home to gives way to a key posed past it.
            if let last = track.keys.last, last.given == true, t > last.t, track.keys.count == 2 { track.keys.removeLast() }
            track.keys.append(MotionKey(t: t, v: v))
            track.keys.sort { $0.t < $1.t }
        }
        self[track: property] = track
    }

    /// Sets a key and nothing else: where one is wanted exactly, as the timeline and an assistant ask.
    mutating func setKey(_ property: MotionProperty, _ value: [Double], at time: Double, ease: MotionEase? = nil) {
        let t = MotionTiming.time(time)
        var track = self[track: property] ?? MotionTrack()
        if let i = track.index(at: t) {
            track.keys[i].v = property.clamped(value)
            track.keys[i].given = nil
            if let ease { track.keys[i].ease = ease.kind == .auto ? nil : ease }
        } else {
            track.keys.append(MotionKey(t: t, v: property.clamped(value), ease: ease.flatMap { $0.kind == .auto ? nil : $0 }))
            track.keys.sort { $0.t < $1.t }
        }
        self[track: property] = track
    }

    /// Takes away the keys at a moment, of these properties. A property left with one key that
    /// says what the design does has nothing more to say, and goes too.
    mutating func removeKeys(at time: Double, of properties: [MotionProperty]) {
        for p in properties {
            guard var track = self[track: p] else { continue }
            track.keys.removeAll { MotionTiming.same($0.t, time) }
            if track.keys.count == 1, MotionTiming.alike(track.keys[0].v, p.rest) { track.keys = [] }
            self[track: p] = track
        }
    }

    /// Moves the keys at one moment to another, of these properties; a key already there gives way.
    mutating func moveKeys(from: Double, to: Double, of properties: [MotionProperty]) {
        let to = MotionTiming.time(to)
        guard !MotionTiming.same(from, to) else { return }
        for p in properties {
            guard var track = self[track: p], let i = track.index(at: from) else { continue }
            var key = track.keys[i]
            key.t = to
            key.given = nil
            track.keys.remove(at: i)
            track.keys.removeAll { MotionTiming.same($0.t, to) }
            track.keys.append(key)
            track.keys.sort { $0.t < $1.t }
            self[track: p] = track
        }
    }

    /// Sets how the keys at a moment are come to, of these properties.
    mutating func setEase(_ ease: MotionEase, at time: Double, of properties: [MotionProperty]) {
        for p in properties {
            guard var track = self[track: p], let i = track.index(at: time) else { continue }
            track.keys[i].ease = ease.kind == .auto ? nil : ease
            track.keys[i].given = nil
            self[track: p] = track
        }
    }

    /// Every key of these properties later by `delta` seconds, none before the start.
    mutating func shiftKeys(by delta: Double, of properties: [MotionProperty] = MotionProperty.allCases) {
        for p in properties {
            guard var track = self[track: p] else { continue }
            let shift = max(delta, -(track.start ?? 0))
            for i in track.keys.indices { track.keys[i].t = MotionTiming.time(track.keys[i].t + shift) }
            self[track: p] = track
        }
    }
}

// MARK: - Poses

/// A layer as it is at one moment: every property's value there.
nonisolated struct MotionPose: Equatable, Sendable {
    var move = CGPoint.zero
    var scale = CGPoint(x: 1, y: 1)
    var turn = 0.0
    var fade = 1.0
    var lift = 0.0
    var tilt = 0.0
    var swing = 0.0
    var blur = 0.0

    static let rest = MotionPose()

    var isRest: Bool { self == .rest }
    /// Whether it leaves the page: lifted, tipped or swung.
    var inDepth: Bool { lift != 0 || tilt != 0 || swing != 0 }

    subscript(property: MotionProperty) -> [Double] {
        get {
            switch property {
            case .move: [Double(move.x), Double(move.y)]
            case .scale: [Double(scale.x), Double(scale.y)]
            case .turn: [turn]
            case .fade: [fade]
            case .lift: [lift]
            case .tilt: [tilt]
            case .swing: [swing]
            case .blur: [blur]
            default: property.rest
            }
        }
        set {
            let v = property.clamped(newValue)
            switch property {
            case .move: move = CGPoint(x: v[0], y: v[1])
            case .scale: scale = CGPoint(x: v[0], y: v[1])
            case .turn: turn = v[0]
            case .fade: fade = v[0]
            case .lift: lift = v[0]
            case .tilt: tilt = v[0]
            case .swing: swing = v[0]
            case .blur: blur = v[0]
            default: break
            }
        }
    }
}

/// Where the camera is at one moment. At rest it sees the whole artboard, straight on.
nonisolated struct FilmCamera: Equatable, Sendable {
    /// Where it looks, in points from the artboard's middle.
    var x = 0.0
    var y = 0.0
    var zoom = 1.0
    var roll = 0.0
    var tilt = 0.0
    var swing = 0.0

    static let rest = FilmCamera()

    var isRest: Bool { self == .rest }
    /// Whether it sees the artboard at an angle, so that what is lifted off it shows its height.
    var inDepth: Bool { tilt != 0 || swing != 0 }

    subscript(property: MotionProperty) -> [Double] {
        get {
            switch property {
            case .cameraMove: [x, y]
            case .cameraZoom: [zoom]
            case .cameraRoll: [roll]
            case .cameraTilt: [tilt]
            case .cameraSwing: [swing]
            default: property.rest
            }
        }
        set {
            let v = property.clamped(newValue)
            switch property {
            case .cameraMove: x = v[0]; y = v[1]
            case .cameraZoom: zoom = v[0]
            case .cameraRoll: roll = v[0]
            case .cameraTilt: tilt = v[0]
            case .cameraSwing: swing = v[0]
            default: break
            }
        }
    }
}

nonisolated extension Node {
    /// The layer's pose at a moment.
    func pose(at t: Double) -> MotionPose {
        guard motion != nil else { return .rest }
        var pose = MotionPose()
        for p in motionProperties where !p.isCamera { pose[p] = value(of: p, at: t) }
        return pose
    }

    /// Artboards: the camera at a moment.
    func camera(at t: Double) -> FilmCamera {
        guard motion != nil else { return .rest }
        var camera = FilmCamera()
        for p in motionProperties where p.isCamera { camera[p] = value(of: p, at: t) }
        return camera
    }
}

// MARK: - The film

/// What an artboard's film is besides its keys. Artboards only.
nonisolated struct Film: Codable, Hashable, Sendable {
    /// How many seconds it runs; nil runs as long as its last key, and at least two seconds.
    var length: Double?
    /// Whether it plays once and stops, rather than round and round; nil goes round.
    var once: Bool?
    /// What shows past the artboard's edges when the camera sees them; nil is chosen to go with
    /// the artboard, light under a light one and dark under a dark one.
    var backdrop: RGBA?
}

nonisolated extension Node {
    /// Artboards: how many seconds the film runs.
    var filmLength: Double {
        if let length = film?.length, length > 0 { return length }
        // To the next half second past the last key.
        return max(MotionTiming.shortest, (lastKey * 2).rounded(.up) / 2)
    }

    /// Artboards: whether anything on it, or its camera, moves at all.
    var hasFilm: Bool { hasCamera || holdsMotion }

    /// Artboards: what shows past its edges in the film.
    var filmBackdrop: RGBA {
        if let backdrop = film?.backdrop { return backdrop }
        let c = fill.on ? fill.color : RGBA.white
        let light = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.45
        return light ? RGBA(r: 0.898, g: 0.882, b: 0.851) : RGBA(r: 0.059, g: 0.055, b: 0.051)
    }
}

// MARK: - Moves made in one go

/// A motion a layer is given in one go, as its keys: how it comes on, or the same backwards, how
/// it goes. Nothing more than keys, so each can be changed afterwards like any posed by hand.
nonisolated enum MotionMove: String, CaseIterable, Codable, Hashable, Sendable {
    case fade, rise, drop, slide, pop, zoom, flip, focus

    var title: String {
        switch self {
        case .fade: String(localized: "move.fade", defaultValue: "Fade")
        case .rise: String(localized: "move.rise", defaultValue: "Rise")
        case .drop: String(localized: "move.drop", defaultValue: "Drop")
        case .slide: String(localized: "move.slide", defaultValue: "Slide")
        case .pop: String(localized: "move.pop", defaultValue: "Pop")
        case .zoom: String(localized: "move.zoom", defaultValue: "Zoom")
        case .flip: String(localized: "move.flip", defaultValue: "Flip")
        case .focus: String(localized: "move.focus", defaultValue: "Focus")
        }
    }

    /// How long it takes.
    var time: Double {
        switch self {
        case .fade: 0.4
        case .rise, .slide, .zoom, .focus: 0.5
        case .drop, .pop, .flip: 0.6
        }
    }

    /// Where the layer is before it has come, or once it has gone: each property's value away
    /// from the design. `frame` is where it lies on its artboard, of `board` size.
    func away(_ frame: CGRect, on board: CGSize) -> [MotionProperty: [Double]] {
        switch self {
        case .fade:
            return [.fade: [0]]
        case .rise:
            return [.move: [0, 28], .fade: [0]]
        case .drop:
            return [.move: [0, -36], .fade: [0]]
        case .slide:
            // From off the nearer side of the artboard.
            let left = Double(frame.midX) <= Double(board.width) / 2
            return [.move: [left ? -Double(frame.maxX) - 8 : Double(board.width - frame.minX) + 8, 0]]
        case .pop:
            return [.scale: [0.6, 0.6], .fade: [0]]
        case .zoom:
            return [.scale: [1.35, 1.35], .fade: [0]]
        case .flip:
            return [.tilt: [-80], .fade: [0]]
        case .focus:
            return [.blur: [18], .fade: [0]]
        }
    }

    /// How it arrives, coming on.
    var arriving: MotionEase {
        switch self {
        case .pop: .spring(0.42)
        case .drop: .spring(0.3)
        case .flip: .spring(0.18)
        default: .easeOut
        }
    }
}

nonisolated extension Node {
    /// Gives the layer a move at a moment: coming on from away to the design, or going, from the
    /// design to away. Keys of the same properties in the time it takes give way to it.
    mutating func apply(_ move: MotionMove, at time: Double, going: Bool = false, frame: CGRect, board: CGSize) {
        let t0 = MotionTiming.time(time), t1 = MotionTiming.time(time + move.time)
        for (p, away) in move.away(frame, on: board) {
            var track = self[track: p] ?? MotionTrack()
            track.keys.removeAll { $0.t > t0 - 0.0042 && $0.t < t1 + 0.0042 }
            if going {
                track.keys.append(MotionKey(t: t0, v: p.rest))
                track.keys.append(MotionKey(t: t1, v: p.clamped(away), ease: .easeIn))
            } else {
                track.keys.append(MotionKey(t: t0, v: p.clamped(away)))
                // What fades with a spring would flicker past full; it only fades.
                track.keys.append(MotionKey(t: t1, v: p.rest, ease: p == .fade || p == .blur ? .easeOut : move.arriving))
            }
            track.keys.sort { $0.t < $1.t }
            self[track: p] = track
        }
    }
}

nonisolated extension BezzleDocument {
    /// Gives layers a move, one after another `apart` seconds, in the order they lie on the
    /// artboard as it is read: from the top down, and across.
    mutating func apply(_ move: MotionMove, to ids: [UUID], at time: Double, going: Bool = false, apart: Double = 0) {
        let placed = ids.compactMap { id -> (UUID, CGRect, CGSize)? in
            guard let n = node(id), !n.isArtboard, let board = artboard(of: id), let whole = absoluteFrame(of: id) else { return nil }
            return (id, whole.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY), board.frame.size)
        }
        let ordered = placed.sorted { a, b in
            abs(a.1.minY - b.1.minY) > 4 ? a.1.minY < b.1.minY : a.1.minX < b.1.minX
        }
        for (i, item) in ordered.enumerated() {
            update(item.0) { $0.apply(move, at: time + Double(i) * max(apart, 0), going: going, frame: item.1, board: item.2) }
        }
    }

    /// Takes all motion from layers, and from what they hold: they are as designed again. Of an
    /// artboard, its camera's too, and what its film was set to.
    mutating func clearMotion(_ ids: [UUID]) {
        func clear(_ n: inout Node) {
            n.motion = nil
            if n.isArtboard { n.film = nil }
            for i in n.children.indices { clear(&n.children[i]) }
        }
        for id in ids { update(id) { clear(&$0) } }
    }
}
