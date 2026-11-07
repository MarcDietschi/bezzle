import Foundation

// MARK: - Versions

/// A design as it was at one moment, kept to look back at and to go back to. Some are taken by
/// themselves as a design is worked on; some are given a name, and those are kept for good and,
/// in a shared design, shared with everyone.
nonisolated struct DesignVersion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    /// A name given it; a version with one is kept for good.
    var name: String?
    /// Who took or named it.
    var by: String?
    var replica: String?
    /// How many layers the design had.
    var layers = 0
    /// Named in a shared design, and so kept by everyone it is shared with.
    var shared: Bool?

    var isNamed: Bool { name != nil }
}

/// What is worked out about a design's versions, wherever they are kept: how each is packed and
/// listed, which are worth keeping, the story they tell, what differs between two, and where
/// each stands on the ruler.
nonisolated enum VersionKeeping {
    /// The design packed as a version keeps it: without where it was looked at.
    static func pack(_ doc: BezzleDocument) -> Data? {
        var doc = doc
        doc.viewport = nil
        guard let json = try? JSONEncoder().encode(doc) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func unpack(_ data: Data) -> BezzleDocument? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
              var doc = try? JSONDecoder().decode(BezzleDocument.self, from: json) else { return nil }
        doc.repairStyles()
        return doc
    }

    /// A list of versions as its file has it, oldest first; nothing if it cannot be read.
    static func list(from data: Data) -> [DesignVersion] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return ((try? decoder.decode([DesignVersion].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    /// A list of versions as its file keeps it.
    static func data(of list: [DesignVersion]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(list)
    }

    /// Of the versions taken by themselves, those worth keeping, as Time Machine keeps backups:
    /// every one of the last hour, one each half hour of the last day, one a day for a month, and
    /// one a week before that. Named versions are always kept, and the newest is.
    static func kept(_ list: [DesignVersion], now: Date = Date()) -> [DesignVersion] {
        var out: [DesignVersion] = []
        var buckets = Set<String>()
        for v in list.sorted(by: { $0.date > $1.date }) {
            let age = now.timeIntervalSince(v.date)
            // The newest needs no exception: its bucket is always still free, and it claims it.
            if v.isNamed || age < 3600 { out.append(v); continue }
            let bucket: String
            if age < 86_400 { bucket = "h\(Int(v.date.timeIntervalSince1970 / 1800))" }
            else if age < 30 * 86_400 { bucket = "d\(Int(v.date.timeIntervalSince1970 / 86_400))" }
            else { bucket = "w\(Int(v.date.timeIntervalSince1970 / (7 * 86_400)))" }
            if buckets.insert(bucket).inserted { out.append(v) }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// The versions a story is told by: all of them while they are few, else the named ones and
    /// enough of the others, evenly spread, to tell it in some thirty steps.
    static func story(of list: [DesignVersion]) -> [UUID] {
        let most = 30
        guard list.count > most else { return list.map(\.id) }
        let named = list.indices.filter { list[$0].isNamed }
        let room = max(most - named.count, 2)
        let spread = (0..<room).map { Int((Double($0) / Double(room - 1) * Double(list.count - 1)).rounded()) }
        return Set(named + spread).sorted().map { list[$0].id }
    }

    /// What differs between a design then and now: layers changed since, not counting what they
    /// hold; gone since; and made since.
    static func differences(_ past: BezzleDocument, _ now: BezzleDocument) -> (changed: Set<UUID>, gone: Set<UUID>, added: Set<UUID>) {
        var gone = Set<UUID>(), changed = Set<UUID>()
        var mine: [UUID: Node] = [:]
        for n in now.allNodes { mine[n.id] = n }
        var seen = Set<UUID>()
        for n in past.allNodes {
            seen.insert(n.id)
            guard let m = mine[n.id] else { gone.insert(n.id); continue }
            var a = n, b = m
            a.children = []
            b.children = []
            if a != b { changed.insert(n.id) }
        }
        return (changed, gone, Set(mine.keys).subtracting(seen))
    }

    /// Where each version stands along a comb this wide, and now after the last: each a step
    /// apart, a little more between one day and the next, the first at the left, now at the right.
    static func slots(_ dates: [Date], width: CGFloat, now: Date = Date(), calendar: Calendar = .current) -> [CGFloat] {
        let lead: CGFloat = 4, tail: CGFloat = 6
        let all = dates + [now]
        var units: [CGFloat] = [0]
        for i in all.indices.dropFirst() {
            let apart: CGFloat = calendar.isDate(all[i - 1], inSameDayAs: all[i]) ? 1 : 1.8
            units.append(units[i - 1] + apart)
        }
        guard let span = units.last, span > 0 else { return [width - tail] }
        let scale = (width - lead - tail) / span
        return units.map { lead + $0 * scale }
    }

    /// The slot nearest `x`.
    static func nearest(_ x: CGFloat, in xs: [CGFloat]) -> Int {
        xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? max(xs.count - 1, 0)
    }
}

/// Looking back, at a version shown on the canvas in place of the design as it is now.
nonisolated struct VersionTravel: Equatable {
    var at: UUID
    var doc: BezzleDocument
    /// Layers that differ from the design now: changed since, gone since, and made since.
    var changed: Set<UUID>
    var gone: Set<UUID>
    var added: Set<UUID> = []
    /// Layers picked on the canvas, to bring back alone.
    var picked: Set<UUID> = []

    /// Looking back at `doc`, version `at`, from the design as it is `now`.
    init(at: UUID, doc: BezzleDocument, now: BezzleDocument) {
        self.at = at
        self.doc = doc
        let d = VersionKeeping.differences(doc, now)
        changed = d.changed
        gone = d.gone
        added = d.added
    }

    /// What differs, worked out again against the design as it is now, which may have changed
    /// meanwhile; picked layers that no longer differ are let go.
    mutating func compare(with now: BezzleDocument) {
        let d = VersionKeeping.differences(doc, now)
        changed = d.changed
        gone = d.gone
        added = d.added
        picked = picked.filter { d.changed.contains($0) || d.gone.contains($0) }
    }

    /// A click on a layer that differs picks it to bring back alone, or lets it go again.
    mutating func pick(at p: CGPoint) {
        guard let hit = layer(at: p) else { return }
        if picked.contains(hit) { picked.remove(hit) } else { picked.insert(hit) }
    }

    /// The layer that differs from now under a canvas point, as the design was then: the
    /// smallest, as it is the one most likely meant.
    func layer(at p: CGPoint) -> UUID? {
        changed.union(gone).compactMap { id -> (UUID, CGFloat)? in
            guard let f = doc.absoluteFrame(of: id), f.contains(p) else { return nil }
            return (id, f.width * f.height)
        }.min { $0.1 < $1.1 }?.0
    }
}

extension BezzleDocument {
    /// Whether the design is what `other` is, apart from where it is looked at and its notes:
    /// going back to it would change nothing.
    nonisolated func sameDesign(as other: BezzleDocument) -> Bool {
        var a = self, b = other
        a.viewport = nil
        b.viewport = nil
        a.notes = nil
        b.notes = nil
        return a == b
    }

    /// Becomes the design as it was in `past`, kept where it is looked at, and with its notes as
    /// they are now.
    nonisolated mutating func goBack(to past: BezzleDocument) {
        let viewport = viewport, notes = notes
        self = past
        self.viewport = viewport
        self.notes = notes
    }

    /// Brings layers back as they were in `past`, into the design as it is now: each where it is
    /// now, or, if it has gone since, where it was. Those inside something else brought back come
    /// with it; the outer ones first, so what they go into is there before them.
    nonisolated mutating func bringBack(_ ids: Set<UUID>, from past: BezzleDocument) {
        let outer = ids.filter { id in !past.ancestors(of: id).contains { ids.contains($0.id) } }
            .sorted { (past.path(of: $0)?.indices ?? []).lexicographicallyPrecedes(past.path(of: $1)?.indices ?? []) }
        for id in outer {
            guard let old = past.node(id) else { continue }
            if node(id) != nil {
                update(id) { $0 = old }
            } else if let parent = past.parent(of: id), let there = path(of: parent.id) {
                let index = past.path(of: id)?.indices.last ?? 0
                let count = node(parent.id)?.children.count ?? 0
                insert(old, at: NodePath(indices: there.indices + [min(index, count)]))
            } else {
                var loose = old
                if let frame = past.absoluteFrame(of: id) { loose.frame = frame }
                nodes.append(loose)
            }
        }
    }
}

// MARK: - The ruler's motion

/// A number that follows where it is meant to be as a spring does, slightly past it and back.
nonisolated struct MotionSpring {
    var value: Double
    var target: Double
    var velocity: Double = 0

    init(_ v: Double) {
        value = v
        target = v
    }

    var settled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }
    var isMoving: Bool { !settled }

    mutating func step(_ dt: Double, stiffness: Double = 260, damping: Double = 24) {
        guard !settled else {
            value = target
            velocity = 0
            return
        }
        // A few small steps, so a long frame never makes it fly off.
        let n = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
        }
    }
}

/// The comb's motion: each stroke's height on a spring, swelling under the pointer and plucked
/// as the pencil line passes it; the line itself, and the label gliding with the pointer.
@MainActor
final class RulerMotion {
    private(set) var heights: [MotionSpring] = []
    private(set) var glow: [Double] = []
    private(set) var head = MotionSpring(0)
    private(set) var lift = MotionSpring(0)
    private(set) var lens = MotionSpring(0)
    private(set) var lensShown = MotionSpring(0)
    private var last: Date?
    private var born: Date?
    private var placed = false

    /// A string along the comb, sampled every `spacing`: how far each point of it stands out,
    /// and how fast it moves, as a ripple runs along it from where a stroke was plucked.
    private(set) var wave: [Double] = []
    private var speed: [Double] = []
    static let spacing: CGFloat = 5
    private var pointer: CGFloat?
    private var swellShown = MotionSpring(0)

    init() {}

    /// How much the comb swells at `x` under the pointer, 0 to 1.
    func swell(at x: CGFloat) -> CGFloat {
        guard let p = pointer else { return 0 }
        let d = Double(x - p) / 26
        return CGFloat(exp(-d * d) * swellShown.value)
    }

    /// The ripple running along the comb at `x`.
    func ripple(at x: CGFloat) -> Double {
        guard !wave.isEmpty else { return 0 }
        let u = Double(x / Self.spacing - 0.5)
        let i = min(max(Int(u.rounded(.down)), 0), wave.count - 1), j = min(i + 1, wave.count - 1)
        let f = min(max(u - Double(i), 0), 1)
        return wave[i] * (1 - f) + wave[j] * f
    }

    /// Moves everything on to `now`: the strokes towards `bases`, swollen near `pointer`, and
    /// the line towards `target`, closely while `held`.
    func step(at now: Date, xs: [CGFloat], bases: [CGFloat], pointer: CGFloat?, head target: CGFloat, held: Bool, width: CGFloat = 600) {
        let dt = min(max(now.timeIntervalSince(last ?? now), 0), 1.0 / 20)
        last = now
        if born == nil { born = now }
        let samples = max(Int(width / Self.spacing), 1)
        if wave.count != samples {
            wave = Array(repeating: 0, count: samples)
            speed = wave
        }
        if let pointer { self.pointer = pointer }
        swellShown.target = pointer == nil ? 0 : 1
        swellShown.step(dt, stiffness: 300, damping: 30)
        ring(dt)
        if heights.count != xs.count {
            heights = xs.indices.map { i in i < heights.count ? heights[i] : MotionSpring(0) }
            glow = xs.indices.map { i in i < glow.count ? glow[i] : 0 }
        }
        if !placed {
            head = MotionSpring(Double(target))
            placed = true
        }
        let from = head.value
        head.target = Double(target)
        if held { head.step(dt, stiffness: 1600, damping: 80) } else { head.step(dt, stiffness: 230, damping: 23) }
        let passed = Self.crossed(from: CGFloat(from), to: CGFloat(head.value), xs: xs)
        lastXs = xs

        let age = now.timeIntervalSince(born ?? now)
        for i in xs.indices {
            // Printed in from now back to the first as the card comes out.
            let delay = Double(xs.count - 1 - i) / Double(max(xs.count, 1)) * 0.35
            var goal = age < delay ? 0 : Double(bases[i])
            if let p = pointer, goal > 0 {
                let d = Double(p - xs[i]) / 24
                goal *= 1 + 0.9 * exp(-d * d)
            }
            heights[i].target = goal
            heights[i].step(dt, stiffness: 420, damping: 19)
            glow[i] *= exp(-dt * 3.2)
        }
        for i in passed where i < heights.count { pluck(i) }
        lift.target = held ? 1 : 0
        lift.step(dt, stiffness: 520, damping: 30)
        if let p = pointer {
            let snapped = Double(xs[RulerMotion.nearest(p, in: xs)])
            if lensShown.value < 0.05 { lens = MotionSpring(snapped) }
            lens.target = snapped
        }
        lens.step(dt, stiffness: 360, damping: 30)
        lensShown.target = pointer == nil ? 0 : 1
        lensShown.step(dt, stiffness: 420, damping: 32)
    }

    /// The strokes a line moving from one place to another passes over or lands on: not the
    /// one it leaves, nor now's end.
    static func crossed(from a: CGFloat, to b: CGFloat, xs: [CGFloat]) -> [Int] {
        guard abs(b - a) > 0.001 else { return [] }
        return xs.indices.dropLast().filter { i in
            b < a ? xs[i] >= b - 0.01 && xs[i] < a - 0.01 : xs[i] > a + 0.01 && xs[i] <= b + 0.01
        }
    }

    static func nearest(_ x: CGFloat, in xs: [CGFloat]) -> Int {
        VersionKeeping.nearest(x, in: xs)
    }

    private var plucked: [CGFloat] = []

    private func pluck(_ i: Int) {
        heights[i].velocity += 150
        glow[i] = 1
        plucked.append(lastXs.indices.contains(i) ? lastXs[i] : 0)
    }

    private var lastXs: [CGFloat] = []

    /// The string, stepped on: each point pulled towards its neighbours and back to rest, slowly
    /// stilled; a stroke plucked sets it going where it stands.
    private func ring(_ dt: Double) {
        for x in plucked {
            let c = Double(x / Self.spacing - 0.5)
            for k in max(Int(c) - 3, 0)...min(Int(c) + 3, wave.count - 1) {
                let d = Double(k) - c
                speed[k] += 70 * exp(-d * d / 2)
            }
        }
        plucked = []
        let n = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Double(n)
        let tension = 2600.0, rest = 70.0, still = 5.0
        for _ in 0..<n {
            for k in wave.indices {
                let left = k > 0 ? wave[k - 1] : 0, right = k < wave.count - 1 ? wave[k + 1] : 0
                speed[k] += (tension * (left - 2 * wave[k] + right) - rest * wave[k] - still * speed[k]) * h
            }
            for k in wave.indices { wave[k] += speed[k] * h }
        }
    }

    private var ringing: Bool { wave.contains { abs($0) > 0.05 } || speed.contains { abs($0) > 0.5 } }

    var settled: Bool {
        heights.allSatisfy(\.settled) && head.settled && lift.settled && lens.settled && lensShown.settled && swellShown.settled
            && glow.allSatisfy { $0 < 0.02 } && !ringing
    }
}

// MARK: - The sky

/// The sky of a moment, for the ruler of time: where the sun stands, how warm its light is, how
/// dark it is. The days are as long as they are at this latitude through the year, and noon moves
/// with summer time.
nonisolated struct Sky: Equatable {
    /// Where the light falls from, across the table: 0 at the left, 1 at the right.
    var x: Double
    /// How high the sun stands: 0 at the horizon or below, 1 at its highest in summer.
    var sun: Double
    /// How warm the light is: 0 the pale light of noon, 1 the gold of a low sun or a lamp.
    var warmth: Double
    /// How dark it is outside: 0 by day, 1 by night, between at dusk and dawn.
    var night: Double
    /// How near the sun is to the horizon, at dusk and dawn.
    var dusk: Double

    static let latitude = 47.0

    static func at(_ date: Date, calendar: Calendar = .current) -> Sky {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 172)
        let noon = 12.5 + (calendar.timeZone.isDaylightSavingTime(for: date) ? 1 : 0)
        let rad = Double.pi / 180
        let declination = 23.44 * rad * sin(2 * .pi * (day - 80) / 365.25)
        let angle = (hour - noon) * 15 * rad
        let lat = latitude * rad
        // The sine of how high the sun stands.
        let e = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(angle)
        let night = smooth(from: 0.04, to: -0.18, e)
        let golden = min(max(1 - e / 0.36, 0), 1)
        let dayX = 0.5 + 0.38 * sin(angle)
        return Sky(x: dayX + (0.78 - dayX) * night,
                   sun: min(max(e / 0.92, 0), 1),
                   warmth: golden + (1 - golden) * night,
                   night: night,
                   dusk: min(max(1 - abs(e + 0.03) / 0.13, 0), 1))
    }

    /// Steps from 0 to 1 as `v` goes from `a` to `b`, gently at both ends.
    private static func smooth(from a: Double, to b: Double, _ v: Double) -> Double {
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The light itself: pale by day, gold low down, a lamp's at night.
    var light: (r: Double, g: Double, b: Double) {
        let cool = (0.93, 0.96, 1.0), gold = (1.0, 0.74, 0.45)
        let t = warmth
        return (cool.0 + (gold.0 - cool.0) * t, cool.1 + (gold.1 - cool.1) * t, cool.2 + (gold.2 - cool.2) * t)
    }

    /// The colour of the sky then, for the ruler of time: blue by day, gold and rose as the sun
    /// goes down, indigo by night.
    var sky: (r: Double, g: Double, b: Double) {
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let blue = (0.56, 0.74, 0.95), gold = (0.98, 0.72, 0.40), rose = (0.80, 0.48, 0.62), indigo = (0.17, 0.19, 0.38)
        let day = mix(blue, gold, (1 - night) * min(max(1 - sun / 0.4, 0), 1))
        let c = mix(mix(day, rose, dusk * 0.75), indigo, night)
        return (c.0, c.1, c.2)
    }
}
