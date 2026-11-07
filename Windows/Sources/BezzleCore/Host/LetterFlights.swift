import Foundation
import CBezzleHost

// Letters on their way, as the Mac's CurveTool flies them (Canvas/CurveTool.swift, "Letters on
// their way"): whenever a text's letters change places other than by moving the whole text, as it
// is bent, put on a shape, taken off one, slid along it, typed into or undone, each letter springs
// to its new place. Only letters going onto a curve, along it or off it fly; other changes to text
// show at once, and so does typing. Letter by letter, from the one nearest where it began (the
// pointer, as the canvas says with `fly`), or from the middle; while a drag goes on, all together
// and stiffly, so they keep up.
//
// While a text's letters fly, the canvas leaves it out of its pictures (`flying`) and shows them
// over the design (`picture`); once they land, the text is drawn again as it is.
//
// The Mac's numbers throughout: the same springs, the same waits between letters, the same rest.
// Its letters are Core Text's; these are Skia's, each a letter of a line the host keeps
// (`bz_text_glyphs` along a curve, `bz_text_letters` straight), known by where in the words it is
// from, as the Mac knows them.

extension WindowsCore {
    @MainActor public final class LetterFlights {
        public init() {}

        /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
        static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

        // MARK: Time

        private var lastFrame: Double = 0
        private var dt: Double = 1.0 / 120

        /// The time since the last step, as the Mac's tick has it, but for nought when stepped twice
        /// in one frame: the canvas steps on each change it draws as well as on each frame.
        private func tick() {
            let now = WindowsCore.now
            dt = (lastFrame == 0 ? 1.0 / 120 : min(max(now - lastFrame, 0), 1.0 / 20)) / Self.slow
            lastFrame = now
        }

        /// Whether the canvas should be drawn again next frame, for letters on their way.
        public var animating: Bool { tracks.values.contains(where: \.moving) }

        // MARK: Letters

        struct Pose {
            var p: CGPoint
            var a: CGFloat
        }

        /// A letter as the host draws it on its own (drawing call 13), and where it is from.
        struct Letter {
            /// Where in the words (UTF-16) it is from: the first of its letters, for a ligature.
            let key: Int
            /// The line the host keeps it in, and its place there.
            let line: Int
            let index: Int
            let color: CGColor
            /// From the letter's own space, its baseline's left end at zero and y running down, into the layer's.
            let place: CGAffineTransform
            let advance: CGFloat
            let ascent: CGFloat
            let descent: CGFloat
        }

        private struct Flier {
            let key: Int
            var letter: Letter
            var pose: Pose
            var target: Pose
            var v = CGPoint.zero
            var w: CGFloat = 0
            var wait: Double = 0
            var alpha: Double = 1
            var alphaTarget: Double = 1
            var settled = true
        }

        /// What a text's letters' places depend on, other than where the text is.
        private struct Signature: Equatable {
            let text: String?
            let spans: [TextSpan]?
            let style: TextStyle?
            let curve: TextCurve?
            let curvePath: String?
            let size: CGSize
            let rotation: Double
            let color: RGBA?
            let editing: Bool
        }

        private struct Track {
            var signature: Signature
            var origin: CGPoint
            var fliers: [Flier]
            var moving = false
            var stiff = false
            var opacity: Double
        }

        private var tracks: [UUID: Track] = [:]
        /// Texts whose next change flies letter by letter, from the letter nearest the point.
        private var flights: [UUID: CGPoint] = [:]

        /// Texts whose letters are springing to new places, which the canvas leaves to this.
        public var flying: Set<UUID> { Set(tracks.lazy.filter(\.value.moving).map(\.key)) }

        /// Has a text's next change fly letter by letter, from the letter nearest `p` (on the
        /// canvas), even during a drag; from the middle without one.
        public func fly(_ id: UUID, from p: CGPoint? = nil) {
            flights[id] = p ?? CGPoint(x: CGFloat.nan, y: .nan)
        }

        /// Forgets every text, as when no design is open.
        func forget() {
            tracks = [:]
            flights = [:]
        }

        /// The texts whose letters are watched: those selected or in what is selected, and any on their way.
        private func watched(_ doc: BezzleDocument, selection: [UUID], editing: UUID?, holding: UUID?) -> Set<UUID> {
            var ids = Set<UUID>()
            for id in selection.prefix(24) {
                guard let n = doc.node(id) else { continue }
                if n.kind == .text { ids.insert(id) }
                if n.isGroup { for c in n.children where c.kind == .text { ids.insert(c.id) } }
                if TextCurve.canCarry(n), let parent = doc.parent(of: id), parent.carrier?.id == id {
                    for c in parent.children where c.rides { ids.insert(c.id) }
                }
            }
            if let editing { ids.insert(editing) }
            if let holding { ids.insert(holding) }
            ids.formUnion(flights.keys)
            ids.formUnion(tracks.lazy.filter(\.value.moving).map(\.key))
            return ids
        }

        /// Steps every text's letters on, from the design as it shows: what is selected, the text
        /// typed into and the one held on an edge are watched; `zoom` says when they are still.
        public func step(selection: [UUID], editing: UUID?, holding: UUID?, zoom: CGFloat) {
            tick()
            guard let doc = WindowsCore.design else {
                forget()
                return
            }
            let inGesture = Editing.gestureStart != nil
            let watched = watched(doc, selection: selection, editing: editing, holding: holding)
            // Those watched a moment ago too, so a text left as it changes, such as one typed into and
            // clicked away from, or undone, still flies.
            let ids = watched.union(tracks.keys)
            for id in ids {
                guard let node = doc.node(id), node.kind == .text, let origin = doc.absoluteFrame(of: id)?.origin else {
                    tracks[id] = nil
                    continue
                }
                let typing = editing == id
                let signature = Signature(text: node.text, spans: node.spans, style: node.style, curve: node.curve, curvePath: node.curvePath,
                                          size: node.frame.size, rotation: node.rotation, color: node.letterColor, editing: typing)
                guard var track = tracks[id] else {
                    let letters = Self.targets(node, in: doc, editing: typing)
                    tracks[id] = Track(signature: signature, origin: origin, fliers: letters.map { Flier(key: $0.key, letter: $0.letter, pose: $0.pose, target: $0.pose) },
                                       opacity: node.opacity)
                    continue
                }
                track.opacity = node.opacity
                if track.signature == signature {
                    if track.origin != origin {
                        // Moved as a whole: its letters go with it at once.
                        let dx = origin.x - track.origin.x, dy = origin.y - track.origin.y
                        for i in track.fliers.indices {
                            track.fliers[i].pose.p.x += dx
                            track.fliers[i].pose.p.y += dy
                            track.fliers[i].target.p.x += dx
                            track.fliers[i].target.p.y += dy
                        }
                        track.origin = origin
                    }
                } else {
                    let was = track.signature
                    let letters = Self.targets(node, in: doc, editing: typing)
                    // Only letters going onto a curve, along it or off it fly: other changes to text show at once.
                    let curved = was.curve != nil || signature.curve != nil
                    let typed = typing && was.editing
                    if !curved || typed {
                        track.fliers = letters.map { Flier(key: $0.key, letter: $0.letter, pose: $0.pose, target: $0.pose) }
                        track.moving = false
                    } else {
                        let pivot = flights[id]
                        retarget(&track, to: letters, discrete: pivot != nil || !inGesture || was.editing != typing, pivot: pivot)
                    }
                    track.signature = signature
                    track.origin = origin
                }
                if track.moving { integrate(&track, zoom: zoom) }
                // Left alone and at rest, it is no longer watched.
                tracks[id] = !track.moving && !watched.contains(id) ? nil : track
            }
            for id in flights.keys where ids.contains(id) { flights[id] = nil }
        }

        /// A text's letters where they belong now, on the canvas, each by the first of its letters in
        /// the words; while it is typed into, as it is typed into, straight.
        private static func targets(_ node: Node, in doc: BezzleDocument, editing: Bool) -> [(key: Int, letter: Letter, pose: Pose)] {
            var shown = node
            var origin = doc.parentOrigin(of: node.id)
            var letters: [Letter]
            if editing, node.isCurved, let frame = doc.absoluteFrame(of: node.id) {
                let (flat, placed) = straight(node, frame: frame)
                shown = flat
                shown.frame = placed
                origin = .zero
                letters = straightLetters(shown)
            } else if let laid = CurvedText.laid(node) {
                letters = curvedLetters(laid)
            } else {
                letters = straightLetters(node)
            }
            let t = CurveHand.toCanvas(shown, origin: origin)
            return letters.map { letter in
                let m = letter.place.concatenating(t)
                // Its middle, halfway up from its baseline as its font stands (y running down).
                let c = CGPoint(x: letter.advance / 2, y: -(letter.ascent - letter.descent) / 2).applying(m)
                return (letter.key, letter, Pose(p: c, a: atan2(m.b, m.a)))
            }
        }

        private func retarget(_ track: inout Track, to letters: [(key: Int, letter: Letter, pose: Pose)], discrete: Bool, pivot: CGPoint?) {
            var old: [Int: Flier] = [:]
            for f in track.fliers where f.alphaTarget > 0 { old[f.key] = f }
            var next: [Flier] = []
            // Letter by letter from the one nearest the pivot, or from the middle.
            var first = letters.count / 2
            if let pivot, !pivot.x.isNaN, !letters.isEmpty {
                first = letters.indices.min { hypot(letters[$0].pose.p.x - pivot.x, letters[$0].pose.p.y - pivot.y) < hypot(letters[$1].pose.p.x - pivot.x, letters[$1].pose.p.y - pivot.y) } ?? first
            }
            let gap = letters.count > 1 ? min(0.012, 0.22 / Double(letters.count)) : 0
            for (i, l) in letters.enumerated() {
                if var f = old.removeValue(forKey: l.key) {
                    f.letter = l.letter
                    var target = l.pose
                    // The short way round.
                    var turn = (target.a - f.pose.a).truncatingRemainder(dividingBy: 2 * .pi)
                    if turn > .pi { turn -= 2 * .pi }
                    if turn <= -.pi { turn += 2 * .pi }
                    target.a = f.pose.a + turn
                    f.target = target
                    if discrete { f.wait = max(f.wait, Double(abs(i - first)) * gap) }
                    f.settled = false
                    next.append(f)
                } else {
                    var f = Flier(key: l.key, letter: l.letter, pose: l.pose, target: l.pose)
                    f.alpha = 0
                    f.alphaTarget = 1
                    f.settled = false
                    f.wait = discrete ? Double(abs(i - first)) * gap : 0
                    next.append(f)
                }
            }
            // Letters gone fade where they were.
            for (_, var f) in old {
                f.alphaTarget = 0
                f.target = f.pose
                f.settled = false
                next.append(f)
            }
            track.fliers = next
            track.stiff = !discrete
            track.moving = true
        }

        private func integrate(_ track: inout Track, zoom: CGFloat) {
            let k: CGFloat = track.stiff ? 1100 : 240
            let c: CGFloat = 2 * sqrt(k) * (track.stiff ? 0.9 : 0.64)
            let n = max(1, Int((dt / 0.004).rounded(.up)))
            let h = CGFloat(dt) / CGFloat(n)
            var moving = false
            for i in track.fliers.indices {
                var f = track.fliers[i]
                guard !f.settled else { continue }
                if f.wait > 0 {
                    f.wait -= dt
                    moving = true
                    track.fliers[i] = f
                    continue
                }
                for _ in 0..<n {
                    f.v.x += (-k * (f.pose.p.x - f.target.p.x) - c * f.v.x) * h
                    f.v.y += (-k * (f.pose.p.y - f.target.p.y) - c * f.v.y) * h
                    f.w += (-k * (f.pose.a - f.target.a) - c * f.w) * h
                    f.pose.p.x += f.v.x * h
                    f.pose.p.y += f.v.y * h
                    f.pose.a += f.w * h
                }
                f.alpha += (f.alphaTarget - f.alpha) * min(1, dt * 14)
                let still = 0.02 / zoom
                if abs(f.pose.p.x - f.target.p.x) < still, abs(f.pose.p.y - f.target.p.y) < still, abs(f.pose.a - f.target.a) < 0.0008,
                   hypot(f.v.x, f.v.y) < 1 / zoom, abs(f.w) < 0.01, abs(f.alpha - f.alphaTarget) < 0.01 {
                    f.pose = f.target
                    f.v = .zero
                    f.w = 0
                    f.alpha = f.alphaTarget
                    f.settled = true
                } else {
                    moving = true
                }
                track.fliers[i] = f
            }
            track.fliers.removeAll { $0.settled && $0.alpha <= 0.001 }
            track.moving = moving
        }

        // MARK: Drawing

        /// The letters on their way, drawn over the design: into BGRA pixels, rows top first, that
        /// `fill` gives once it has their size, `scale` pixels a point. Answers the part of the stage
        /// they cover, in its points (a canvas point `p` is at `pan + p · zoom`, the stage `stage`
        /// big); nil when no letter shows there.
        public func picture(zoom: CGFloat, pan: CGPoint, scale: Double, stage: CGSize,
                            into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            let toView = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y)
            var shown: [(letter: Letter, m: CGAffineTransform, alpha: Double)] = []
            var box = CGRect.null
            for track in tracks.values where track.moving {
                for f in track.fliers where f.alpha > 0.005 && f.letter.color.alpha > 0 {
                    let l = f.letter
                    // Its middle where the pose is, turned as the pose is.
                    let m = CGAffineTransform(translationX: -l.advance / 2, y: (l.ascent - l.descent) / 2)
                        .concatenating(CGAffineTransform(rotationAngle: f.pose.a))
                        .concatenating(CGAffineTransform(translationX: f.pose.p.x, y: f.pose.p.y))
                        .concatenating(toView)
                    shown.append((l, m, f.alpha * track.opacity))
                    // Room for what leans or reaches past its width.
                    let reach = max(l.ascent, 1)
                    box = box.union(CGRect(x: -reach * 0.4, y: -l.ascent - reach * 0.2, width: l.advance + reach * 0.8, height: l.ascent + l.descent + reach * 0.4).applying(m))
                }
            }
            box = box.intersection(CGRect(origin: .zero, size: stage))
            guard !shown.isEmpty, !box.isNull, box.width > 0, box.height > 0 else { return nil }
            let s = CGFloat(scale)
            let x0 = (box.minX * s).rounded(.down), y0 = (box.minY * s).rounded(.down)
            // In steps of 64 pixels, so the canvas can keep its bitmap from frame to frame.
            let w = ((box.maxX * s).rounded(.up) - x0) / 64, h = ((box.maxY * s).rounded(.up) - y0) / 64
            let size = CGSize(width: max(w.rounded(.up), 1) * 64, height: max(h.rounded(.up), 1) * 64)
            let drawn = WindowsCore.picture({
                guard let ctx = Renderer.bitmap(size) else { return nil }
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: s, y: -s)
                ctx.translateBy(x: -x0 / s, y: -y0 / s)
                for (l, m, alpha) in shown {
                    ctx.saveGState()
                    ctx.concatenate(m)
                    ctx.setAlpha(CGFloat(alpha))
                    ctx.drawGlyph(l.index, of: l.line, color: l.color)
                    ctx.restoreGState()
                }
                return ctx.makeImage()
            }, into: fill)
            return drawn ? CGRect(x: x0 / s, y: y0 / s, width: size.width / s, height: size.height / s) : nil
        }

        // MARK: Letters from the host

        /// Where in the words each letter of a line the host keeps is from, by the line.
        private static var starts: [Int: [Int32]] = [:]
        /// A straight text's letters one by one, by the text's number in the host: the line they are
        /// kept in, nine numbers each (`bz_text_letters`) and how many.
        private static var straights: [Int: (line: Int, numbers: [Double], count: Int)] = [:]

        /// A curved text's letters, as it is laid along its curve.
        static func curvedLetters(_ laid: CurvedText.Laid) -> [Letter] {
            laid.letters.map { l in
                let at = lineStarts(l.line)
                return Letter(key: l.index < at.count ? Int(at[l.index]) : l.index, line: l.line, index: l.index, color: l.color, place: l.place,
                              advance: l.advance, ascent: l.ascent, descent: l.descent)
            }
        }

        private static func lineStarts(_ line: Int) -> [Int32] {
            if let kept = starts[line] { return kept }
            var at = [Int32](repeating: 0, count: 256)
            var count = Int(at.withUnsafeMutableBufferPointer { bz_glyph_starts(Int32(line), $0.baseAddress, Int32($0.count)) })
            if count > at.count {
                at = [Int32](repeating: 0, count: count)
                count = Int(at.withUnsafeMutableBufferPointer { bz_glyph_starts(Int32(line), $0.baseAddress, Int32($0.count)) })
            }
            let kept = Array(at.prefix(max(count, 0)))
            if starts.count > 600 { starts.removeAll() }
            starts[line] = kept
            return kept
        }

        /// A straight text's letters as it is drawn, each placed as those along a curve are, in its
        /// own coordinates: for letters going onto a curve and coming off it. Spaces and breaks are
        /// left out, as the Mac's Text Kit leaves them out.
        static func straightLetters(_ node: Node) -> [Letter] {
            let laid = TextLayout.layout(node)
            guard laid.id != 0 else { return [] }
            let words = Array(laid.string.utf16)
            let got: (line: Int, numbers: [Double], count: Int)
            if let kept = straights[laid.id] {
                got = kept
            } else {
                var capacity = words.count * 2 + 16
                var numbers = [Double](repeating: 0, count: capacity * 9)
                var count: Int32 = 0
                var line = numbers.withUnsafeMutableBufferPointer { bz_text_letters(Int32(laid.id), $0.baseAddress, Int32(capacity), &count) }
                if Int(count) > capacity {
                    capacity = Int(count)
                    numbers = [Double](repeating: 0, count: capacity * 9)
                    line = numbers.withUnsafeMutableBufferPointer { bz_text_letters(Int32(laid.id), $0.baseAddress, Int32(capacity), &count) }
                }
                got = (Int(line), numbers, min(Int(count), capacity))
                if straights.count > 600 { straights.removeAll() }
                straights[laid.id] = got
            }
            guard got.line != 0, got.count > 0 else { return [] }
            // Each letter's colour is its run's.
            let runs = TextLayout.runs(node)
            var ends: [Int] = []
            var total = 0
            for run in runs {
                total += ((run["text"] as? String) ?? "").utf16.count
                ends.append(total)
            }
            let down = TextLayout.offset(node)
            func number(_ k: Int, _ i: Int) -> CGFloat { CGFloat(got.numbers[k * 9 + i]) }
            var letters: [Letter] = []
            letters.reserveCapacity(got.count)
            for k in 0..<got.count {
                let at = Int(number(k, 8))
                if at < words.count, let scalar = Unicode.Scalar(words[at]), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                let run = ends.firstIndex { at < $0 } ?? max(runs.count - 1, 0)
                let look = runs.indices.contains(run) ? runs[run] : [:]
                let rgba = (look["color"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                let color = rgba.count == 4 ? CGColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3])) : CGColor(gray: 0, alpha: 0)
                // As far as the next letter on its line, or for a line's last, its own width and
                // the spacing after it: as a curve's letters are measured (`bz_text_glyphs`), so that
                // a letter going onto a curve or off it keeps its middle where it was.
                let x = number(k, 0), y = number(k, 1)
                let advance: CGFloat
                if k + 1 < got.count, abs(number(k + 1, 1) - y) < 0.01, number(k + 1, 0) >= x {
                    advance = number(k + 1, 0) - x
                } else {
                    advance = number(k, 2) + CGFloat(look["tracking"] as? Double ?? 0)
                }
                letters.append(Letter(key: at, line: got.line, index: k, color: color, place: CGAffineTransform(translationX: x, y: down + y),
                                      advance: advance, ascent: number(k, 3), descent: number(k, 4)))
            }
            return letters
        }

        // MARK: Typing

        /// A text on a curve as it is typed into, as the Mac's CurvedText.straight: straight, in a
        /// frame of the size its words take, placed and turned so that the point its words are
        /// placed from stays where it is and the words run as the curve does there. `frame` is the
        /// layer's frame where it is wanted, such as on the canvas. The text as it is, for one that
        /// is straight.
        static func straight(_ node: Node, frame: CGRect) -> (node: Node, frame: CGRect) {
            guard node.isCurved, let laid = CurvedText.laid(node) else { return (node, frame) }
            var flat = node
            flat.curve = nil
            flat.curvePath = nil
            flat.frame = frame
            let fitted = TextLayout.fittedFrame(flat)
            let v = Geometry.rotate(CGPoint(x: laid.anchor.x - frame.width / 2, y: laid.anchor.y - frame.height / 2), by: node.rotation)
            let page = CGPoint(x: frame.midX + v.x, y: frame.midY + v.y)
            var turn = node.rotation + Double(laid.anchorAngle * 180 / .pi)
            turn = turn.truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn -= 360 }
            if turn <= -180 { turn += 360 }
            flat.rotation = (turn * 100).rounded() / 100
            let rest = CGPoint(x: laid.alignK * fitted.width, y: TextLayout.firstBaseline(Node.with(flat, frame: fitted)))
            let w = Geometry.rotate(CGPoint(x: rest.x - fitted.width / 2, y: rest.y - fitted.height / 2), by: flat.rotation)
            let placed = CGRect(x: page.x - w.x - fitted.width / 2, y: page.y - w.y - fitted.height / 2, width: fitted.width, height: fitted.height)
            flat.frame = placed
            return (flat, placed)
        }
    }

    /// Where a text on a curve is typed into, on the canvas: straight, its frame unturned and
    /// how far it is turned about its middle, in degrees; nil for a straight text.
    public static func typingPlace(of id: UUID) -> (frame: CGRect, rotation: Double)? {
        guard let doc = design, let node = doc.node(id), node.isCurved, let frame = doc.absoluteFrame(of: id) else { return nil }
        let (flat, placed) = LetterFlights.straight(node, frame: frame)
        return (placed, flat.rotation)
    }
}
