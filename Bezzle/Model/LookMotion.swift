import Foundation
import CoreGraphics

// Animate: how a layer looks, keyed as where it is. A fill's colour, a border's colour and width,
// the corners and a shadow each have a track of the layer's motion of their own, beside its
// properties' and its shader inputs' (`Node.motion`), named after what they change. Like every
// key, a look's holds a change from the design and never the design: a layer with no keys is as
// designed, a key that changes nothing is the design itself, and a layer restyled in the design
// takes its film with it. What a layer looks like at a moment is one function of the model,
// `Node.looked(at:)`, for every Bezzle to draw the same.

// MARK: - What is keyed

/// A look of a layer that keys change, and the track of its motion they are kept in.
nonisolated enum LookTrack: Hashable, Sendable {
    /// The colour of the fill in a slot, while it is one colour; a text's first is its letters'.
    case fill(Int)
    /// The colours of that fill's gradient, and where along it each lies.
    case fillStops(Int)
    /// The colour of the border in a slot, while it is one colour.
    case border(Int)
    /// The colours of that border's gradient, and where along it each lies.
    case borderStops(Int)
    /// How wide that border is.
    case borderWidth(Int)
    /// The shadow in a slot: its colour, how far it falls, how soft and how much bigger it is.
    case shadow(Int)
    /// How round the four corners are.
    case corners

    /// What its keys are kept under in a layer's motion: "fill.0", "fill.0.stops", "border.0",
    /// "border.0.stops", "border.0.width", "shadow.0" with the slot's number, and "corners".
    var name: String {
        switch self {
        case .fill(let i): "fill.\(i)"
        case .fillStops(let i): "fill.\(i).stops"
        case .border(let i): "border.\(i)"
        case .borderStops(let i): "border.\(i).stops"
        case .borderWidth(let i): "border.\(i).width"
        case .shadow(let i): "shadow.\(i)"
        case .corners: "corners"
        }
    }

    /// The look a track keys, from its name; nil for any other track.
    init?(name: String) {
        guard let first = name.utf8.first, first == 102 || first == 98 || first == 115 || first == 99 else { return nil }
        if name == "corners" {
            self = .corners
            return
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let slot = Int(parts[1]), slot >= 0, slot < 1000, String(slot) == parts[1] else { return nil }
        switch (parts[0], parts.count == 3 ? parts[2] : nil) {
        case ("fill", nil): self = .fill(slot)
        case ("fill", "stops"?): self = .fillStops(slot)
        case ("border", nil): self = .border(slot)
        case ("border", "stops"?): self = .borderStops(slot)
        case ("border", "width"?): self = .borderWidth(slot)
        case ("shadow", nil): self = .shadow(slot)
        default: return nil
        }
    }

    /// Which of the three a layer has several of it belongs to, and its slot; nil for the corners.
    var place: (look: Look, slot: Int)? {
        switch self {
        case .fill(let i), .fillStops(let i): (.fill, i)
        case .border(let i), .borderStops(let i), .borderWidth(let i): (.border, i)
        case .shadow(let i): (.shadow, i)
        case .corners: nil
        }
    }

    /// The same look of another slot.
    func at(_ slot: Int) -> LookTrack {
        switch self {
        case .fill: .fill(slot)
        case .fillStops: .fillStops(slot)
        case .border: .border(slot)
        case .borderStops: .borderStops(slot)
        case .borderWidth: .borderWidth(slot)
        case .shadow: .shadow(slot)
        case .corners: .corners
        }
    }

    /// Where it comes among a layer's looks: its fills first, each with its border after the last
    /// of them, then the corners and the shadows.
    var order: Int {
        switch self {
        case .fill(let i): 2 * i
        case .fillStops(let i): 2 * i + 1
        case .border(let i): 10_000 + 3 * i
        case .borderStops(let i): 10_000 + 3 * i + 1
        case .borderWidth(let i): 10_000 + 3 * i + 2
        case .corners: 20_000
        case .shadow(let i): 30_000 + i
        }
    }

    /// The words the looks go by, each with its English: `title(line:)` says them.
    static let words: [(key: String, english: String)] = [
        ("animate.look.fill", "Fill"), ("animate.look.gradient", "Gradient"),
        ("animate.look.border", "Border"), ("animate.look.border.gradient", "Border Gradient"), ("animate.look.border.width", "Border Width"),
        ("animate.look.line", "Line"), ("animate.look.line.gradient", "Line Gradient"), ("animate.look.line.width", "Line Width"),
        ("animate.look.shadow", "Shadow"), ("animate.look.corners", "Corners"),
    ]

    /// What it is called on its line of the timeline: the word its card has, and which of several.
    /// A line is all border, which its card calls the line.
    func title(line: Bool = false) -> String {
        let word: String
        switch self {
        case .fill: word = String(localized: "animate.look.fill", defaultValue: "Fill")
        case .fillStops: word = String(localized: "animate.look.gradient", defaultValue: "Gradient")
        case .border:
            word = line ? String(localized: "animate.look.line", defaultValue: "Line") : String(localized: "animate.look.border", defaultValue: "Border")
        case .borderStops:
            word = line ? String(localized: "animate.look.line.gradient", defaultValue: "Line Gradient")
                : String(localized: "animate.look.border.gradient", defaultValue: "Border Gradient")
        case .borderWidth:
            word = line ? String(localized: "animate.look.line.width", defaultValue: "Line Width")
                : String(localized: "animate.look.border.width", defaultValue: "Border Width")
        case .shadow: word = String(localized: "animate.look.shadow", defaultValue: "Shadow")
        case .corners: return String(localized: "animate.look.corners", defaultValue: "Corners")
        }
        guard let slot = place?.slot, slot > 0 else { return word }
        return word + " " + String(slot + 1)
    }
}

// MARK: - Colours

/// A colour as a key holds it: laid over the design's by an amount. Five numbers: the colour's
/// lightness and its two axes of OKLab, each times how much of it shows (its alpha) and times the
/// amount; how much of it shows, times the amount; and the amount itself, 1 for all the way.
/// All zero changes nothing, as every key's rest does. Between two keys the numbers go from one
/// to the other like any others, which mixes the colours along a straight line in OKLab, a colour
/// that barely shows counting for as little: the way colours mix without going grey or dark
/// between. What the design has shows through by what the amount leaves, so a key the design
/// gave follows the design when its colour is changed, and a colour that was chosen stays the
/// colour that was chosen.
nonisolated enum LookColor {
    /// How many numbers a colour's change has.
    static let count = 5

    /// A colour as it is laid: lightness and the two axes times its alpha, and its alpha.
    static func laid(_ c: RGBA) -> [Double] {
        let lab = c.oklab, alpha = c.a.isFinite ? min(max(c.a, 0), 1) : 1
        return [lab.l * alpha, lab.a * alpha, lab.b * alpha, alpha]
    }

    /// Whether two colours are one to the eye: nearer than half a step of the 256 a screen and a
    /// colour written as "#RRGGBB" have, so the design's colour typed or sent back is the design's.
    static func same(_ a: RGBA, _ b: RGBA) -> Bool {
        let step = 0.002
        return abs(a.r - b.r) < step && abs(a.g - b.g) < step && abs(a.b - b.b) < step && abs(a.a - b.a) < step
    }

    /// The change that shows a colour where the design has `design`: none for the design's own.
    static func change(to color: RGBA, over design: RGBA) -> [Double] {
        same(color, design) ? [0, 0, 0, 0, 0] : laid(color) + [1]
    }

    /// The colour that shows where the design has `design`, under a change: five numbers of `v`
    /// from `i` on. The design's own, untouched, where they change nothing.
    static func shown(_ design: RGBA, under v: [Double], from i: Int = 0) -> RGBA {
        guard i + count <= v.count else { return design }
        if (i..<(i + count)).allSatisfy({ abs(v[$0]) < 1e-9 }) { return design }
        let under = laid(design), left = 1 - v[i + 4]
        let alpha = under[3] * left + v[i + 3]
        // Nothing of it shows: the design's colour, unseen, for whatever comes after to start from.
        guard alpha.isFinite, alpha > 1e-6 else { return RGBA(r: design.r, g: design.g, b: design.b, a: 0) }
        let rgb = rgb(l: (under[0] * left + v[i]) / alpha, a: (under[1] * left + v[i + 1]) / alpha, b: (under[2] * left + v[i + 2]) / alpha)
        return RGBA(r: rgb.r, g: rgb.g, b: rgb.b, a: settled(min(alpha, 1)))
    }

    /// Red, green and blue of a colour of OKLab, each kept within what a screen shows.
    static func rgb(l: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        func gamma(_ x: Double) -> Double {
            let v = x.isFinite ? min(max(x, 0), 1) : 0
            return settled(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return (gamma(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
                gamma(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
                gamma(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc))
    }

    /// To the millionth, far finer than any screen: a colour that went to OKLab and back is the
    /// colour it was, and not a hair beside it.
    private static func settled(_ x: Double) -> Double { min(max((x * 1_000_000).rounded() / 1_000_000, 0), 1) }
}

private nonisolated extension Fill {
    /// Whether it is one colour that keys can change: on, and neither gradient, picture nor shader.
    var keysColor: Bool { on && !paints }

    /// The stops of its gradient, where that is what it paints with and keys can change them.
    var keyedStops: [GradientStop]? {
        guard on, image == nil, shader == nil, let stops = gradient?.stops, !stops.isEmpty else { return nil }
        return stops
    }
}

// MARK: - A layer's looks in time

nonisolated extension Node {
    /// The looks of the layer that have keys, in their order, whether or not the design still has
    /// what they change.
    var looks: [LookTrack] {
        guard let motion, !motion.isEmpty else { return [] }
        return motion.compactMap { name, track in track.keys.isEmpty ? nil : LookTrack(name: name) }.sorted { $0.order < $1.order }
    }

    /// Their tracks' names.
    var lookTracks: [String] { looks.map(\.name) }

    /// Whether any look of the layer has keys.
    var hasLooks: Bool {
        guard let motion, !motion.isEmpty else { return false }
        return motion.contains { !$0.value.keys.isEmpty && LookTrack(name: $0.key) != nil }
    }

    /// Whether it, or anything it holds, has a look with keys: its drawing changes as time passes.
    var holdsLooks: Bool { hasLooks || children.contains(where: \.holdsLooks) }

    /// The looks of the layer as designed that can be keyed, in their order: each fill that is on,
    /// by its colour or its gradient's; each border likewise, and its width; the corners of a
    /// rectangle; each shadow that is on. An artboard's are the design's alone.
    var keyableLooks: [LookTrack] {
        guard !isArtboard else { return [] }
        var out: [LookTrack] = []
        for i in 0..<slots(.fill) { out += [LookTrack.fill(i), .fillStops(i)].filter { lookCount($0) != nil } }
        for i in 0..<slots(.border) { out += [LookTrack.border(i), .borderStops(i), .borderWidth(i)].filter { lookCount($0) != nil } }
        if lookCount(.corners) != nil { out.append(.corners) }
        for i in 0..<slots(.shadow) where lookCount(.shadow(i)) != nil { out.append(.shadow(i)) }
        return out
    }

    /// How many numbers a key of a look has on the layer as designed: five for a colour, six for
    /// each colour of a gradient (the colour, and how far along it has moved), one for a width,
    /// four for the corners, nine for a shadow. Nil where the design has no such look to change:
    /// no fill in that slot, one that is off, a gradient where the key is for one colour.
    func lookCount(_ look: LookTrack) -> Int? {
        guard !isArtboard else { return nil }
        if let place = look.place {
            guard place.slot < slots(place.look) else { return nil }
            // What a layer of its kind is drawn with: a line is all border, text all colour, and
            // a group has neither.
            switch place.look {
            case .fill: if kind == .line || kind == .group { return nil }
            case .border: if kind == .text || kind == .group { return nil }
            case .shadow: break
            }
        }
        switch look {
        case .fill(let i): return self[fill: i].keysColor ? LookColor.count : nil
        case .fillStops(let i): return self[fill: i].keyedStops.map { $0.count * (LookColor.count + 1) }
        case .border(let i): return self[border: i].paint.keysColor ? LookColor.count : nil
        case .borderStops(let i): return self[border: i].paint.keyedStops.map { $0.count * (LookColor.count + 1) }
        case .borderWidth(let i): return self[border: i].on ? 1 : nil
        case .shadow(let i): return self[shadow: i].on ? LookColor.count + 4 : nil
        // A rectangle whose Shape has keys has its outline keyed point by point, each key for the
        // points the design's corners make: there the corners stay the design's.
        case .corners: return kind == .rectangle && self[track: .shape] == nil ? 4 : nil
        }
    }

    /// Whether a look's keys are for the layer as designed: every one with as many numbers as the
    /// look has there. Keys for what is no longer there (a fill taken away, one colour made a
    /// gradient, a gradient with other colours) change nothing, and are kept for when it is back.
    func fits(_ look: LookTrack) -> Bool {
        guard let count = lookCount(look), let track = self[track: look.name], !track.keys.isEmpty else { return false }
        return track.keys.allSatisfy { $0.v.count == count }
    }

    /// Whether any look of the layer changes as time passes: one with keys that fit it.
    var looksChange: Bool { hasLooks && looks.contains { fits($0) } }

    /// A look's change at a moment, as its keys have it: nothing, where it has none that fit.
    func lookValue(_ look: LookTrack, at t: Double) -> [Double]? {
        guard let count = lookCount(look) else { return nil }
        let rest = Array(repeating: 0.0, count: count)
        guard fits(look), let track = self[track: look.name] else { return rest }
        let v = track.value(at: t, rest: rest)
        return v.count == count ? v : rest
    }

    /// The layer as it looks at a moment: its colours, widths, corners and shadows where their
    /// keys have them, everything else as designed. Where they change nothing, the layer as it is.
    func looked(at t: Double) -> Node {
        guard hasLooks else { return self }
        var n = self
        for look in looks {
            guard let v = lookValue(look, at: t), v.contains(where: { abs($0) >= 1e-9 }) else { continue }
            show(look, v, in: &n)
        }
        return n
    }

    /// Puts a look's change into `n`, a copy of this layer; this one is the design it is from.
    private func show(_ look: LookTrack, _ v: [Double], in n: inout Node) {
        func finite(_ x: Double) -> CGFloat { x.isFinite ? CGFloat(x) : 0 }
        func stops(_ design: [GradientStop]) -> [GradientStop] {
            let each = LookColor.count + 1
            return design.enumerated().map { i, stop in
                GradientStop(offset: min(max(stop.offset + Double(finite(v[i * each + LookColor.count])), 0), 1),
                             color: LookColor.shown(stop.color, under: v, from: i * each))
            }
        }
        switch look {
        case .fill(let i):
            n[fill: i].color = LookColor.shown(self[fill: i].color, under: v)
            // A text's letters with a colour of their own are covered by as much, each from its own.
            if i == 0, kind == .text, let spans, spans.contains(where: { $0.look.color != nil }) {
                n.spans = spans.map { span in
                    var span = span
                    span.look.color = span.look.color.map { LookColor.shown($0, under: v) }
                    return span
                }
            }
        case .fillStops(let i):
            guard let design = self[fill: i].keyedStops else { return }
            n[fill: i].gradient?.stops = stops(design)
        case .border(let i):
            n[border: i].color = LookColor.shown(self[border: i].color, under: v)
        case .borderStops(let i):
            guard let design = self[border: i].paint.keyedStops else { return }
            n[border: i].gradient?.stops = stops(design)
        case .borderWidth(let i):
            n[border: i].width = max(self[border: i].width + finite(v[0]), 0)
        case .shadow(let i):
            var shadow = self[shadow: i]
            shadow.color = LookColor.shown(shadow.color, under: v)
            shadow.x += finite(v[5])
            shadow.y += finite(v[6])
            shadow.blur = max(shadow.blur + finite(v[7]), 0)
            if abs(v[8]) >= 1e-9 { shadow.spread = shadow.grown + finite(v[8]) }
            n[shadow: i] = shadow
        case .corners:
            n.radii = zip(radii, v).map { max($0 + finite($1), 0) }
        }
    }

    // MARK: Posing

    /// The numbers a key of a look holds at a moment for the layer to look there as `shown` does:
    /// `shown` is this layer as it looks then (`looked(at:)`) with the look changed, as a card or
    /// a handle changes it. What of the look was left alone keeps what its keys say there. Nil
    /// where the design has no such look, or `shown` has made it another kind of thing.
    func lookChange(_ look: LookTrack, showing shown: Node, at t: Double) -> [Double]? {
        lookChange(look, showing: shown, from: looked(at: t), at: t)
    }

    /// The same, `before` being how the layer looks at that moment, worked out already.
    private func lookChange(_ look: LookTrack, showing shown: Node, from before: Node, at t: Double) -> [Double]? {
        guard var v = lookValue(look, at: t), shown.lookCount(look) == v.count else { return nil }
        func colour(_ now: RGBA, _ was: RGBA, _ design: RGBA, at i: Int = 0) {
            guard now != was else { return }
            v.replaceSubrange(i..<(i + LookColor.count), with: LookColor.change(to: now, over: design))
        }
        func stops(_ now: [GradientStop]?, _ was: [GradientStop]?, _ design: [GradientStop]?) {
            guard let now, let was, let design, now.count == design.count, was.count == design.count else { return }
            let each = LookColor.count + 1
            for i in design.indices {
                colour(now[i].color, was[i].color, design[i].color, at: i * each)
                if now[i].offset != was[i].offset { v[i * each + LookColor.count] = now[i].offset - design[i].offset }
            }
        }
        switch look {
        case .fill(let i):
            colour(shown[fill: i].color, before[fill: i].color, self[fill: i].color)
        case .fillStops(let i):
            stops(shown[fill: i].keyedStops, before[fill: i].keyedStops, self[fill: i].keyedStops)
        case .border(let i):
            colour(shown[border: i].color, before[border: i].color, self[border: i].color)
        case .borderStops(let i):
            stops(shown[border: i].paint.keyedStops, before[border: i].paint.keyedStops, self[border: i].paint.keyedStops)
        case .borderWidth(let i):
            if shown[border: i].width != before[border: i].width { v[0] = Double(shown[border: i].width - self[border: i].width) }
        case .shadow(let i):
            let now = shown[shadow: i], was = before[shadow: i], design = self[shadow: i]
            colour(now.color, was.color, design.color)
            if now.x != was.x { v[5] = Double(now.x - design.x) }
            if now.y != was.y { v[6] = Double(now.y - design.y) }
            if now.blur != was.blur { v[7] = Double(now.blur - design.blur) }
            if now.grown != was.grown { v[8] = Double(now.grown - design.grown) }
        case .corners:
            let now = shown.radii, was = before.radii, design = radii
            for c in 0..<4 where now[c] != was[c] { v[c] = Double(now[c] - design[c]) }
        }
        return v.map { $0.isFinite ? $0 : 0 }
    }

    /// The looks in which `shown` differs from how this layer looks at a moment, of those that
    /// can be keyed: what a change made to the layer there has changed.
    func looksChanged(showing shown: Node, at t: Double) -> [LookTrack] {
        looksChanged(showing: shown, from: looked(at: t))
    }

    private func looksChanged(showing shown: Node, from before: Node) -> [LookTrack] {
        keyableLooks.filter { look in
            guard shown.lookCount(look) == lookCount(look) else { return false }
            switch look {
            case .fill(let i): return shown[fill: i].color != before[fill: i].color
            case .fillStops(let i): return shown[fill: i].gradient?.stops != before[fill: i].gradient?.stops
            case .border(let i): return shown[border: i].color != before[border: i].color
            case .borderStops(let i): return shown[border: i].gradient?.stops != before[border: i].gradient?.stops
            case .borderWidth(let i): return shown[border: i].width != before[border: i].width
            case .shadow(let i):
                let now = shown[shadow: i], was = before[shadow: i]
                return now.color != was.color || now.x != was.x || now.y != was.y || now.blur != was.blur || now.grown != was.grown
            case .corners: return shown.radii != before.radii
            }
        }
    }

    /// Poses a look at a moment, as changing it in Animate does: the layer is to look there as
    /// `shown` does. Like posing a property (`pose(_:_:at:home:)`), the first key a look is given
    /// comes with the design for company, so one change makes a whole motion; after that, each is
    /// one more key. Keys the look had for what the design no longer has give way.
    mutating func poseLook(_ look: LookTrack, showing shown: Node, at time: Double, home: Double = MotionTiming.beat) {
        poseLook(look, showing: shown, from: looked(at: time), at: time, home: home)
    }

    /// Makes a change to the layer as it looks at a moment, as a card of the inspector or a handle
    /// on the canvas makes it to the design, and poses what it changed of the layer's looks there
    /// (`poseLook`). Nothing else the change did is kept: in Animate the design stays as it is.
    /// False, with nothing done, when the change is to none of its looks but to something else:
    /// that one is the design's to take.
    mutating func poseLooks(at time: Double, home: Double = MotionTiming.beat, _ change: (inout Node) -> Void) -> Bool {
        guard !keyableLooks.isEmpty else { return false }
        let before = looked(at: time)
        var shown = before
        change(&shown)
        // Nothing to see of it at that moment: the look set to what it shows there already.
        guard shown != before else { return true }
        let looks = looksChanged(showing: shown, from: before)
        guard !looks.isEmpty else {
            // What changes nothing to see is no change to the design either. A text given the
            // colour it shows already loses only what its letters had of their own
            // (`clearLetterColors`), which the film covers by itself; and a shadow with no spread
            // may have it written out as none.
            func plain(_ n: Node) -> Node {
                var n = n
                if kind == .text {
                    n.spans = n.spans?.map { span in
                        var span = span
                        span.look.color = nil
                        return span
                    }
                }
                for i in 0..<n.slots(.shadow) where n[shadow: i].spread == 0 { n[shadow: i].spread = nil }
                return n
            }
            return plain(shown) == plain(before)
        }
        for look in looks { poseLook(look, showing: shown, from: before, at: time, home: home) }
        return true
    }

    private mutating func poseLook(_ look: LookTrack, showing shown: Node, from before: Node, at time: Double, home: Double) {
        guard let change = lookChange(look, showing: shown, from: before, at: time) else { return }
        if !fits(look) { self[track: look.name] = nil }
        let rest = Array(repeating: 0.0, count: change.count)
        let name = look.name, t = MotionTiming.time(time)
        guard var track = self[track: name] else {
            guard !MotionTiming.alike(change, rest) else { return }
            if t < 0.0042 {
                let home = home.isFinite ? max(home, 0.05) : MotionTiming.beat
                self[track: name] = MotionTrack([MotionKey(t: 0, v: change), MotionKey(t: home, v: rest, given: true)])
            } else {
                self[track: name] = MotionTrack([MotionKey(t: 0, v: rest, given: true), MotionKey(t: t, v: change)])
            }
            return
        }
        if let i = track.index(at: t) {
            track.keys[i].v = change
            track.keys[i].given = nil
        } else {
            // The design it was given to go home to gives way to a key posed past it.
            if let last = track.keys.last, last.given == true, t > last.t, track.keys.count == 2 { track.keys.removeLast() }
            track.keys.append(MotionKey(t: t, v: change))
            track.keys.sort { $0.t < $1.t }
        }
        // Put back where the design has it, a look with this one key and the design for company
        // has no motion left: only a line in the timeline, which goes.
        if track.keys.count == 2, track.keys.contains(where: { $0.given == true }), track.keys.allSatisfy({ MotionTiming.alike($0.v, rest) }) {
            self[track: name] = nil
            return
        }
        self[track: name] = track
    }

    /// Sets a key of a look and nothing else: `change` is what it holds, as `lookChange` gives it.
    /// Nothing where the design has no such look, or the change is not one of it.
    mutating func setLookKey(_ look: LookTrack, change: [Double], at time: Double, ease: MotionEase? = nil) {
        guard let count = lookCount(look), change.count == count else { return }
        if !fits(look) { self[track: look.name] = nil }
        let name = look.name, t = MotionTiming.time(time), v = change.map { $0.isFinite ? $0 : 0 }
        var track = self[track: name] ?? MotionTrack()
        if let i = track.index(at: t) {
            track.keys[i].v = v
            track.keys[i].given = nil
            if let ease { track.keys[i].ease = ease.kind == .auto ? nil : ease }
        } else {
            track.keys.append(MotionKey(t: t, v: v, ease: ease.flatMap { $0.kind == .auto ? nil : $0 }))
            track.keys.sort { $0.t < $1.t }
        }
        self[track: name] = track
    }

    // MARK: Following what they change

    /// The keys of the fills, borders or shadows follow them as one is taken away: its own go
    /// with it, and those of the ones over it come down a place with them. `count` is how many
    /// there were. The last to go is only turned off, and keeps its keys for when it is back.
    mutating func looksFollow(removing look: Look, at slot: Int, of count: Int) {
        guard count > 1, slot >= 0, slot < count else { return }
        renumberLooks(look) { $0 == slot ? nil : $0 > slot ? $0 - 1 : $0 }
    }

    /// The keys of the fills, borders or shadows follow them as one is moved to another place.
    mutating func looksFollow(moving look: Look, from: Int, to: Int, of count: Int) {
        guard from != to, (0..<count).contains(from), (0..<count).contains(to) else { return }
        var order = Array(0..<count)
        order.insert(order.remove(at: from), at: to)
        renumberLooks(look) { old in order.firstIndex(of: old) ?? old }
    }

    private mutating func renumberLooks(_ kind: Look, _ place: (Int) -> Int?) {
        guard let motion, hasLooks else { return }
        var out: [String: MotionTrack] = [:]
        for (name, track) in motion {
            guard let look = LookTrack(name: name), let at = look.place, at.look == kind else {
                out[name] = track
                continue
            }
            if let slot = place(at.slot) { out[look.at(slot).name] = track }
        }
        self.motion = out.isEmpty ? nil : out
    }
}
