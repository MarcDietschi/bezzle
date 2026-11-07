import Foundation

// The photo itself as the control on Windows, as the Mac's DevelopTool (Canvas/DevelopTool.swift):
// while the Photo card is open with its target on (else a press on the photo moves it, as on any
// layer), pointing at it names what is under the pointer, beside it, in a small label with its
// colour, and a drag there changes that.
//
// Working on the light it is a tone: a drag up lightens it, down darkens it. Working on the
// colour it is a colour: a drag up gives more of it, down less, sideways turns its hue; on
// something with hardly any colour, sideways warms or cools the light, up and down tints it, and
// a click makes it neutral grey. Whatever the drag, it is one step to undo.

extension WindowsCore {
    @MainActor public final class DevelopHand {
        public var selection: [UUID] = []
        /// Whether the select tool is in hand with nothing being typed or edited.
        public var free = true
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// The target: the photo is the control. Off, nothing here takes the pointer.
        public var on = false { didSet { if !on { pointed = nil; drag = nil; redraw() } } }
        /// The Photo card's tab: "light", "color" or "detail" (where the photo is no control).
        public var group = "light"
        /// Draws the canvas's marks again.
        public var redraw: () -> Void = {}

        public init() {}

        private var working: Bool { on && free && group != "detail" }

        /// What a drag on the photo changes.
        enum Target: Equatable {
            case tone(Develop.Setting)
            case band(Develop.Band)
            /// Something with hardly any colour of its own.
            case neutral

            /// Whether the way the drag sets off decides what it changes.
            var turns: Bool { if case .tone = self { false } else { true } }
        }

        /// A selected photo, and the ways from the stage to across and down it.
        private struct Look {
            let id: UUID
            let node: Node
            let image: ImageFill
            let frame: CGRect
            let toView: CGAffineTransform

            /// Where a point on the stage is across and down the photo, when it is on the layer.
            func unit(_ v: CGPoint) -> CGPoint? {
                let local = v.applying(toView.inverted())
                guard Renderer.outline(of: node).contains(local) else { return nil }
                let u = local.applying(image.placing(in: frame.size).inverted())
                return (0...1).contains(u.x) && (0...1).contains(u.y) ? u : nil
            }
        }

        private func look(at v: CGPoint) -> (Look, CGPoint)? {
            guard working, let doc = WindowsCore.design else { return nil }
            for id in selection.reversed() {
                guard let node = doc.node(id), node.fill.on, let image = node.fill.image, !node.locked,
                      let frame = doc.absoluteFrame(of: id) else { continue }
                // From the layer's own coordinates, its top left at zero, to the stage.
                let toView = CGAffineTransform(translationX: -frame.width / 2, y: -frame.height / 2)
                    .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
                    .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
                    .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y))
                let look = Look(id: id, node: node, image: image, frame: frame, toView: toView)
                if let u = look.unit(v) { return (look, u) }
            }
            return nil
        }

        // MARK: What is under the pointer

        private struct Point {
            let view: CGPoint
            let color: SIMD3<Double>
            let target: Target
        }

        private var pointed: Point?
        /// The photo developed as it is now, small: what the pointer reads its colour from.
        private var read: (key: String, develop: Develop?, pixels: Pixels)?

        private func color(of look: Look, at unit: CGPoint) -> SIMD3<Double>? {
            let key = look.image.shown
            if read?.key != key || read?.develop != look.image.develop {
                let image = look.image
                guard let px = WindowsCore.pixels(of: {
                    (WindowsCore.assets.image(image.shown, pixels: 256) ?? WindowsCore.assets.image(image.asset, pixels: 256))
                        .map { Developer.developed($0, image.develop) }
                }, longest: 256) else { return nil }
                read = (key, look.image.develop, px)
            }
            // A small patch round the point, not one pixel: a leaf in shadow is green, though the
            // darkest pixel of it may be nearly grey.
            guard let px = read?.pixels else { return nil }
            var sum = SIMD3<Double>(), count = 0.0
            for dy in -2...2 {
                for dx in -2...2 {
                    let u = CGPoint(x: unit.x + CGFloat(dx) / CGFloat(px.width), y: unit.y + CGFloat(dy) / CGFloat(px.height))
                    guard let c = px.color(at: u), c.w > 0.3 else { continue }
                    sum += PointMap.decode(SIMD3(c.x, c.y, c.z))
                    count += 1
                }
            }
            return count > 0 ? PointMap.encode(sum / count) : nil
        }

        /// What a colour is to work on: its tone, or its colour.
        private func target(for color: SIMD3<Double>) -> Target {
            if group == "color" {
                let (h, s) = PointMap.hueAndSaturation(color)
                guard s > 0.12 else { return .neutral }
                let (i, share) = Develop.Band.split(hue: h)
                let bands = Develop.Band.allCases
                return .band(share >= 0.5 ? bands[i] : bands[(i + 1) % bands.count])
            }
            let l = min(max(PointMap.encode(PointMap.norm(PointMap.decode(color))), 0), 1)
            let zone = WindowsCore.toneZones.first { l >= $0.from && l <= $0.to }?.setting ?? "exposure"
            return .tone(Develop.Setting(rawValue: zone) ?? .exposure)
        }

        /// The pointer at rest on the stage, or gone; whether what shows changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool {
            guard drag == nil else { return false }
            var next: Point?
            if let v, let (look, unit) = look(at: v), let c = color(of: look, at: unit) {
                next = Point(view: v, color: c, target: target(for: c))
            }
            guard next != nil || pointed != nil else { return false }
            pointed = next
            redraw()
            return true
        }

        /// What the pointer shows: a cross on the photo, or which way a drag going on changes it.
        public enum Pointer { case cross, across, upDown }
        public func pointer(at v: CGPoint) -> Pointer? {
            if let drag { return drag.axis == .across ? .across : drag.axis == .down ? .upDown : .cross }
            return pointed != nil && look(at: v) != nil ? .cross : nil
        }

        // MARK: Dragging

        private enum Axis { case none, across, down }

        private struct Drag {
            let id: UUID
            /// Where the way the drag has come is counted from, and the development there: where
            /// it began, or where Alt was last pressed or let go, so going slower never jumps.
            var start: CGPoint
            let target: Target
            let color: SIMD3<Double>
            var from: Develop
            var slow = false
            var axis: Axis = .none
            var moved = false
        }

        private var drag: Drag?
        public var dragging: Bool { drag != nil }
        /// The colour a press on the photo was on, for the card to show its rows.
        public private(set) var pressedBand: String?

        /// A press on a selected photo while it is the control; false leaves it to the canvas.
        public func down(at v: CGPoint, clicks: Int) -> Bool {
            guard clicks < 2, let (look, unit) = look(at: v), let c = color(of: look, at: unit) else { return false }
            let target = target(for: c)
            drag = Drag(id: look.id, start: v, target: target, color: c, from: look.image.develop ?? Develop())
            pointed = Point(view: v, color: c, target: target)
            if case .band(let b) = target { pressedBand = b.rawValue } else { pressedBand = nil }
            redraw()
            return true
        }

        public func drag(to v: CGPoint, slow: Bool) {
            guard var d = drag else { return }
            if !d.moved {
                guard hypot(v.x - d.start.x, v.y - d.start.y) >= 3 else { return }
                d.moved = true
                WindowsCore.beginGesture()
            }
            // A colour is turned or strengthened, one or the other, by which way the drag set off.
            if d.axis == .none {
                let dx = v.x - d.start.x, dy = v.y - d.start.y
                if !d.target.turns { d.axis = .down } else if hypot(dx, dy) >= 6 { d.axis = abs(dx) > abs(dy) ? .across : .down }
            }
            // Alt goes slower from here on, and back again from where it is let go.
            if slow != d.slow {
                d.slow = slow
                d.start = v
                d.from = WindowsCore.design?.node(d.id)?.fill.image?.develop ?? d.from
            }
            drag = d
            let dx = Double(v.x - d.start.x), up = Double(d.start.y - v.y)
            let k = d.slow ? 0.25 : 1
            let from = d.from, target = d.target, axis = d.axis, id = d.id
            WindowsCore.edit { doc in
                doc.update(id) { n in
                    guard var image = n.fill.image else { return }
                    var dev = image.develop ?? Develop()
                    switch target {
                    case .tone(let s):
                        // Exposure counted in fewer stops: the photo's whole light is a lot to move at once.
                        let span = s == .exposure ? 4 : s.range.upperBound - s.range.lowerBound
                        dev[s] = from[s] + up / 320 * span * k
                    case .band(let b):
                        var shift = from[b]
                        if axis == .across { shift.hue = from[b].hue + dx / 160 * 100 * k }
                        if axis == .down { shift.saturation = from[b].saturation + up / 160 * 100 * k }
                        dev[b] = shift
                    case .neutral:
                        // Sideways warmer or cooler, up towards magenta and down towards green.
                        if axis == .across { dev[.temperature] = from[.temperature] + dx / 320 * 200 * k }
                        if axis == .down { dev[.tint] = from[.tint] + up / 320 * 200 * k }
                    }
                    image.develop = dev.kept
                    n.fill.image = image
                }
            }
            pointed = Point(view: v, color: d.color, target: d.target)
            redraw()
        }

        public func up(at v: CGPoint) {
            guard let d = drag else { return }
            drag = nil
            if d.moved {
                WindowsCore.endGesture()
            } else if d.target == .neutral {
                // A click on something without colour of its own: it becomes neutral grey.
                Self.neutralize(d.id, d.color)
            }
            hover(v)
        }

        /// Escape: a drag going on is taken back, else the photo stops being the control. Whether
        /// there was either.
        public func cancel() -> Bool {
            if let d = drag {
                drag = nil
                if d.moved { WindowsCore.cancelGesture() }
                pointed = nil
                redraw()
                return true
            }
            guard on else { return false }
            on = false
            return true
        }

        /// The colour at a point of the photo made neutral grey: the white balance set so it has no
        /// colour of its own, its tint too (the Mac's DocumentStore.neutralize).
        private static func neutralize(_ id: UUID, _ color: SIMD3<Double>) {
            WindowsCore.edit { doc in
                doc.update(id) { n in
                    guard var image = n.fill.image else { return }
                    var d = image.develop ?? Develop()
                    // Taken back through the white balance it has now, to the colour as it was lit.
                    let now = PointMap.whiteBalance(d[.temperature] / 100)
                    var lit = PointMap.decode(color) / now
                    lit.y /= exp2(-0.42 * d[.tint] / 100)
                    guard lit.min() > 1e-4 else { return }
                    var lo = -100.0, hi = 100.0
                    for _ in 0..<30 {
                        let mid = (lo + hi) / 2
                        let g = PointMap.whiteBalance(mid / 100)
                        if (lit.x * g.x) / (lit.z * g.z) < 1 { lo = mid } else { hi = mid }
                    }
                    let warm = (lo + hi) / 2
                    let g = PointMap.whiteBalance(warm / 100)
                    let balanced = lit * g
                    // Green against the mean of red and blue.
                    d[.temperature] = warm
                    d[.tint] = log2(balanced.y / ((balanced.x + balanced.z) / 2)) / 0.42 * 100
                    image.develop = d.kept
                    n.fill.image = image
                }
            }
        }

        // MARK: What shows

        /// A ring where the colour is read, and beside it a label: the colour (0xRRGGBB), what it
        /// is, and while dragging, how much.
        public struct Mark {
            public let at: CGPoint
            public let colour: UInt32
            public let words: String
            public let amount: String?
        }

        public func mark() -> Mark? {
            guard let p = pointed, working else { return nil }
            let words: String
            switch p.target {
            case .tone(let s): words = String(localized: s.title)
            case .band(let b): words = String(localized: b.title)
            case .neutral:
                words = drag?.moved == true ? String(localized: drag?.axis == .down ? Develop.Setting.tint.title : Develop.Setting.temperature.title)
                    : WindowsCore.say("Click to make neutral")
            }
            var amount: String?
            if let drag, drag.moved {
                let d = WindowsCore.design?.node(drag.id)?.fill.image?.develop ?? Develop()
                let v: Double, decimals: Int
                switch p.target {
                case .tone(let s): v = d[s]; decimals = s == .exposure ? 2 : 0
                case .band(let b): v = drag.axis == .across ? d[b].hue : d[b].saturation; decimals = 0
                case .neutral: v = drag.axis == .down ? d[.tint] : d[.temperature]; decimals = 0
                }
                amount = v == 0 ? "0" : (v > 0 ? "+" : "−") + String(format: "%.\(decimals)f", abs(v))
            }
            func byte(_ x: Double) -> UInt32 { UInt32(min(max(x, 0), 1) * 255 + 0.5) }
            return Mark(at: p.view, colour: byte(p.color.x) << 16 | byte(p.color.y) << 8 | byte(p.color.z), words: words, amount: amount)
        }
    }
}
