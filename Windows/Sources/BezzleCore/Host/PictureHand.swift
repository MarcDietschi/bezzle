import Foundation
import CBezzleHost

// Placing a picture inside the layer it fills, as the Mac's PictureTool (Canvas/PictureTool.swift),
// ported: double click the layer, or select it and press Enter. The whole picture shows, faded
// where it reaches past the layer's outline, which is what cuts it off, with crop marks at its
// corners. Drag the picture to move it, or a corner to make it bigger or smaller about the corner
// across, or about its middle with Alt (the Mac's Option); Shift keeps a move straight across or
// down. Its middle catches on the layer's middle (Ctrl moves it freely, as ⌘ on the Mac). It keeps
// its proportions and always covers the layer: pulled too far, it gives a little, as on elastic,
// and springs back when let go. The arrow keys move it a point at a time, ten with Shift. Enter,
// Escape, a double click on it or a click anywhere else ends placing. The placing itself is the
// shared `ImageFill.placed/covering/elastic` (Model/PicturePlacing.swift).

extension WindowsCore {
    public final class PictureHand {
        public init() {}

        /// The layer whose picture is being placed (the Mac's store.editingPicture).
        public var editing: UUID? {
            didSet {
                guard editing != oldValue else { return }
                finishSettling()
                if drag != nil { cancelDrag() }
                caught = (false, false)
            }
        }
        /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// Draws the canvas's marks again, and the design, as it changes here.
        public var redraw: () -> Void = {}
        public var changed: () -> Void = {}
        /// A press on the picture let go without moving it, where it was pressed on the stage: a
        /// cut-out picture keeps or drops the subject there (the Mac's PictureTool.clicked).
        public var clicked: (CGPoint) -> Void = { _ in }

        /// The layer being placed in, and the ways between its own coordinates and the stage.
        struct Look {
            let id: UUID
            let node: Node
            let image: ImageFill
            /// The layer's frame on the canvas.
            let frame: CGRect
            let zoom: CGFloat
            let pan: CGPoint

            var size: CGSize { frame.size }
            /// Where the picture lies in the layer.
            var rect: CGRect { Renderer.imageRect(image, in: size) }

            /// From the layer's own coordinates, its top left at zero, to the stage.
            var toView: CGAffineTransform {
                CGAffineTransform(translationX: frame.midX, y: frame.midY)
                    .rotated(by: Geometry.radians(node.rotation))
                    .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                    .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y))
            }

            func view(_ p: CGPoint) -> CGPoint { p.applying(toView) }
            func local(_ v: CGPoint) -> CGPoint { v.applying(toView.inverted()) }

            /// A corner of `rect` in the layer's coordinates.
            func point(_ corner: Handle, of rect: CGRect) -> CGPoint {
                CGPoint(x: rect.minX + corner.unit.x * rect.width, y: rect.minY + corner.unit.y * rect.height)
            }

            /// Where the picture lies once it covers the layer, for one shown whole or squeezed to
            /// it: as small as covering takes, about the same middle.
            var coverRect: CGRect {
                let r = rect
                guard image.mode != .cover else { return r }
                let w = image.coverWidth(in: size)
                return ImageFill.covering(CGRect(center: CGPoint(x: r.midX, y: r.midY), size: CGSize(width: w, height: image.height(forWidth: w))), in: size)
            }
        }

        private var look: Look? {
            guard let id = editing, let doc = design, let node = doc.node(id), node.fill.on, let image = node.fill.image,
                  !node.locked, let frame = doc.absoluteFrame(of: id) else { return nil }
            return Look(id: id, node: node, image: image, frame: frame, zoom: zoom, pan: pan)
        }

        private enum Drag {
            /// Moving the picture from where it lay; the press was at `start`, in the layer's coordinates.
            case move(start: CGPoint, from: CGRect)
            /// Resizing it by a corner, about the corner across, or its middle with Alt.
            case resize(corner: Handle, from: CGRect)
        }

        private var drag: Drag?
        /// Whether the press has gone far enough to be a drag, and so begun a gesture.
        private var moved = false
        private var downView: CGPoint = .zero
        /// Where the picture comes to rest when let go, which is short of where it was pulled to
        /// when that would leave an edge of the layer showing.
        private var rest: CGRect?
        /// Springing back to rest once let go: from where to where, since when, and what it last set.
        private var settling: (id: UUID, from: CGRect, to: CGRect, began: Double, last: ImageFill?)?
        /// Whether the picture's middle has caught on the layer's, across and down, for the guides.
        private var caught = (x: false, y: false)
        /// The layer whose picture shows, and since when, as it fades in; the one that showed
        /// before, as it fades out.
        private var shown: (id: UUID, since: Double)?
        private var lastLook: Look?
        private var leaving: (look: Look, since: Double)?

        private static let corners: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        /// How near a corner a press takes hold of it, on screen.
        private static let reach: CGFloat = 11
        /// How far the elastic lets the picture go past covering, at most, on screen.
        private static let give: CGFloat = 120
        private static let fadeIn = 0.22
        private static let fadeOut = 0.16
        private static let settleTime = 0.38
        /// How much of the picture past the layer shows, faded.
        public static let ghost = 0.42

        public var dragging: Bool { drag != nil }

        /// Whether the canvas has to draw again next frame, for a fade or a spring on its way.
        public var animating: Bool {
            let now = WindowsCore.now
            return settling != nil || leaving != nil || shown.map { now - $0.since < Self.fadeIn } == true
        }

        /// Whether the one layer picked has a picture that can be placed inside it (the Mac's
        /// canPlace­Picture: not an artboard, not locked, its fill on and a picture).
        public static func canPlace(_ selection: [UUID]) -> Bool {
            guard selection.count == 1, let n = design?.node(selection[0]) else { return false }
            return !n.isArtboard && !n.locked && n.fill.on && n.fill.image != nil
        }

        // MARK: Where things are

        private func corner(at v: CGPoint, _ look: Look) -> Handle? {
            let rect = look.rect
            let near = Self.corners.map { ($0, look.view(look.point($0, of: rect))) }.map { ($0.0, hypot($0.1.x - v.x, $0.1.y - v.y)) }
            return near.filter { $0.1 <= Self.reach }.min { $0.1 < $1.1 }?.0
        }

        private func across(_ corner: Handle) -> Handle {
            switch corner {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomRight: .topLeft
            default: .topRight
            }
        }

        /// What the pointer shows over the picture being placed: a two-headed arrow at a corner
        /// (its angle in degrees, clockwise from across), the hand over the picture; nil elsewhere.
        public enum PicturePointer: Equatable { case resize(Double), hand }

        public func pointer(at v: CGPoint) -> PicturePointer? {
            guard let look else { return nil }
            switch drag {
            case .resize(let corner, _): return .resize(corner.angle + look.node.rotation)
            case .move: return .hand
            case nil: break
            }
            if let corner = corner(at: v, look) { return .resize(corner.angle + look.node.rotation) }
            return look.rect.contains(look.local(v)) ? .hand : nil
        }

        // MARK: The pointer

        /// A press while placing, `clicks` the press's count. Returns whether it was taken here, on
        /// the picture or one of its corners; anywhere else placing ends, and the press goes on as usual.
        public func down(at v: CGPoint, clicks: Int) -> Bool {
            finishSettling()
            guard let look else { return false }
            downView = v
            moved = false
            if let corner = corner(at: v, look) {
                drag = .resize(corner: corner, from: look.rect)
                return true
            }
            let p = look.local(v)
            guard look.rect.contains(p) else { return false }
            if clicks >= 2 {
                editing = nil
                redraw()
                return true
            }
            drag = .move(start: p, from: look.rect)
            return true
        }

        public func drag(to v: CGPoint, shift: Bool, option: Bool, command: Bool) {
            guard var drag, let look else { return }
            if !moved {
                guard hypot(v.x - downView.x, v.y - downView.y) > 2 else { return }
                moved = true
                beginGesture()
                // A picture shown whole, or squeezed to the layer, covers it from the first move on.
                if look.image.mode != .cover {
                    switch drag {
                    case .move(let start, _): drag = .move(start: start, from: look.coverRect)
                    case .resize(let corner, _): drag = .resize(corner: corner, from: look.coverRect)
                    }
                    self.drag = drag
                }
            }
            let size = look.size, zoom = look.zoom
            let p = look.local(v)
            switch drag {
            case .move(let start, let from):
                var dx = p.x - start.x, dy = p.y - start.y
                if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
                var r = from.offsetBy(dx: dx, dy: dy)
                // Its middle catches on the layer's, five points either side on screen, along a
                // side it has room to move along. Ctrl moves it freely.
                let near = 5 / zoom, snaps = !command
                caught = (snaps && r.width - size.width > 0.5 && abs(r.midX - size.width / 2) < near,
                          snaps && r.height - size.height > 0.5 && abs(r.midY - size.height / 2) < near)
                if caught.x { r.origin.x = (size.width - r.width) / 2 }
                if caught.y { r.origin.y = (size.height - r.height) / 2 }
                // Past covering, it gives as on elastic, less the further it is pulled.
                let settled = ImageFill.covering(r, in: size)
                var shown = settled
                shown.origin.x += ImageFill.elastic(r.minX - settled.minX, reach: min(Self.give / zoom, size.width / 2))
                shown.origin.y += ImageFill.elastic(r.minY - settled.minY, reach: min(Self.give / zoom, size.height / 2))
                rest = settled
                set(shown, of: look.id)
                measure = nil

            case .resize(let corner, let from):
                let anchor = option ? CGPoint(x: from.midX, y: from.midY) : look.point(across(corner), of: from)
                let grabbed = look.point(corner, of: from)
                // As far out as the pointer has gone along either side, the proportions kept.
                let kx = grabbed.x != anchor.x ? (p.x - anchor.x) / (grabbed.x - anchor.x) : 0
                let ky = grabbed.y != anchor.y ? (p.y - anchor.y) / (grabbed.y - anchor.y) : 0
                let wanted = from.width * max(kx, ky, 0)
                // Never smaller than covering takes; pushed smaller, it gives as on elastic.
                let least = look.image.coverWidth(in: size)
                let width = wanted >= least ? wanted : least - ImageFill.elastic(least - wanted, reach: min(Self.give / zoom, least / 2))
                func scaled(_ w: CGFloat) -> CGRect {
                    let s = from.width > 0 ? w / from.width : 1
                    return CGRect(x: anchor.x + (from.minX - anchor.x) * s, y: anchor.y + (from.minY - anchor.y) * s,
                                  width: w, height: from.height * s)
                }
                rest = ImageFill.covering(scaled(max(wanted, least)), in: size)
                caught = (false, false)
                set(ImageFill.covering(scaled(width), in: size), of: look.id)
                let bounds = Geometry.bounds(of: look.frame, rotation: look.node.rotation)
                measure = ("\(Int((max(wanted, least) / least * 100).rounded()))%", bounds)
            }
            changed()
        }

        public func up() {
            guard let drag else { return }
            self.drag = nil
            caught = (false, false)
            measure = nil
            defer {
                rest = nil
                redraw()
            }
            if !moved, case .move = drag { clicked(downView) }
            guard moved, let look else { return }
            // Let go past covering, it springs back; the gesture ends once it is there.
            if let rest, !Self.same(rest, look.rect) {
                settling = (look.id, look.rect, rest, WindowsCore.now, look.image)
            } else {
                endGesture()
                changed()
            }
        }

        /// The drag called off: the picture back where it was.
        public func cancelDrag() {
            if moved { cancelGesture() }
            drag = nil
            moved = false
            rest = nil
            caught = (false, false)
            measure = nil
            changed()
        }

        /// A frame of the spring back to rest, while there is one: quick to leave, slow to arrive,
        /// never past it, as on the Mac.
        public func step() {
            guard let s = settling else { return }
            // Something else changed the picture meanwhile, such as an undo: it is left as it is.
            guard let node = design?.node(s.id), node.fill.image == s.last else { return finishSettling(placing: false) }
            let t = min((WindowsCore.now - s.began) / Self.settleTime, 1)
            guard t < 1 else { return finishSettling() }
            let k = 1 - (1 + 10 * t) * exp(-10 * t)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(k) }
            let r = CGRect(x: mix(s.from.minX, s.to.minX), y: mix(s.from.minY, s.to.minY),
                           width: mix(s.from.width, s.to.width), height: mix(s.from.height, s.to.height))
            settling?.last = set(r, of: s.id)
            changed()
        }

        /// Brings a picture springing back straight to rest, and ends its gesture: when it gets
        /// there, or when something else wants the canvas first.
        public func finishSettling() { finishSettling(placing: true) }

        private func finishSettling(placing: Bool) {
            guard let s = settling else { return }
            settling = nil
            if placing { set(s.to, of: s.id) }
            endGesture()
            changed()
        }

        // MARK: Placing

        /// Puts the picture at `rect` in its layer, and returns it as it now is.
        @discardableResult
        private func set(_ rect: CGRect, of id: UUID) -> ImageFill? {
            guard let node = design?.node(id), let image = node.fill.image else { return nil }
            let placed = image.placed(at: rect, in: node.frame.size)
            edit { doc in doc.update(id) { $0.fill.image = placed } }
            return placed
        }

        private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
        }

        /// Moves the picture by `dx` and `dy` across and down the screen, whichever way the layer is
        /// turned, as far as it still covers the layer.
        private func nudge(_ dx: CGFloat, _ dy: CGFloat, _ look: Look) {
            let d = Geometry.rotate(CGPoint(x: dx, y: dy), by: -look.node.rotation)
            set(ImageFill.covering(look.coverRect.offsetBy(dx: d.x, dy: d.y), in: look.size), of: look.id)
            changed()
        }

        // MARK: Keys

        /// A key while placing ("escape", "enter", "left", "right", "up", "down"), or Enter on a
        /// selected picture, which starts placing it. Whether it was taken here.
        public func key(_ key: String, shift: Bool, selection: [UUID], free: Bool) -> Bool {
            finishSettling()
            let escape = key == "escape", enter = key == "enter"
            if drag != nil {
                if escape { cancelDrag(); drag = nil; redraw(); return true }
                return false
            }
            if editing != nil {
                guard let look else {
                    editing = nil
                    redraw()
                    return false
                }
                if escape || enter {
                    editing = nil
                    redraw()
                    return true
                }
                let step: CGFloat = shift ? 10 : 1
                switch key {
                case "left": nudge(-step, 0, look)
                case "right": nudge(step, 0, look)
                case "down": nudge(0, step, look)
                case "up": nudge(0, -step, look)
                default: return false
                }
                return true
            }
            if enter, free, Self.canPlace(selection) {
                editing = selection[0]
                redraw()
                return true
            }
            return false
        }

        // MARK: Drawing

        /// What placing shows of a layer, on the stage: the picture's edge and its corners, the
        /// layer's outline that cuts it off, the guides through the middle it caught on, and the
        /// crop marks, all at `alpha` as it fades in or out; `key` tells one picture's place from
        /// another, for drawing it past the outline again only when it moves.
        public struct Marks {
            public let alpha: Double
            public let edge: [CGPoint]
            public let outline: String
            public let guides: String?
            public let crops: String
            public let key: String
            let look: Look
        }

        /// What shows now: the picture fading out, if one is, then the one being placed.
        public func marks() -> [Marks] {
            let now = WindowsCore.now
            let current = look
            if current?.id != shown?.id {
                if shown != nil, let was = lastLook { leaving = (was, now) }
                shown = current.map { ($0.id, now) }
            }
            lastLook = current ?? lastLook
            var all: [Marks] = []
            if let (was, since) = leaving {
                let t = (now - since) / Self.fadeOut
                if t >= 1 { leaving = nil } else { all.append(marks(was, (1 - t) * (1 - t), guides: false)) }
            }
            if let current, let shown {
                let t = min((now - shown.since) / Self.fadeIn, 1)
                all.append(marks(current, 1 - pow(1 - t, 3), guides: true))
            }
            return all
        }

        private func marks(_ look: Look, _ alpha: Double, guides: Bool) -> Marks {
            let rect = look.rect, toView = look.toView
            let corners = Self.corners.map { look.view(look.point($0, of: rect)) }
            var t = toView
            let outline = Renderer.outline(of: look.node).copy(using: &t).map { PathData.string($0) } ?? ""
            var lines: String?
            // Where the picture's middle caught on the layer's: a guide through the middle.
            if guides, caught.x || caught.y {
                let g = CGMutablePath(), s = look.size
                if caught.x { g.addLines(between: [look.view(CGPoint(x: s.width / 2, y: 0)), look.view(CGPoint(x: s.width / 2, y: s.height))]) }
                if caught.y { g.addLines(between: [look.view(CGPoint(x: 0, y: s.height / 2)), look.view(CGPoint(x: s.width, y: s.height / 2))]) }
                lines = PathData.string(g)
            }
            // Crop marks: an L at each corner along the picture's edges.
            let crops = CGMutablePath()
            for (i, c) in corners.enumerated() {
                let next = corners[(i + 1) % 4], previous = corners[(i + 3) % 4]
                let arm = min(15, hypot(next.x - c.x, next.y - c.y) * 0.3, hypot(previous.x - c.x, previous.y - c.y) * 0.3)
                func toward(_ q: CGPoint) -> CGPoint {
                    let d = hypot(q.x - c.x, q.y - c.y)
                    return d > 0 ? CGPoint(x: c.x + (q.x - c.x) / d * arm, y: c.y + (q.y - c.y) / d * arm) : c
                }
                crops.move(to: toward(next))
                crops.addLine(to: c)
                crops.addLine(to: toward(previous))
            }
            let key = "\(look.id) \(look.image.offset) \(look.image.scale) \(look.image.mode) \(look.frame) \(look.node.rotation) \(look.zoom) \(look.pan)"
            return Marks(alpha: alpha, edge: corners, outline: outline, guides: lines, crops: PathData.string(crops), key: key, look: look)
        }

        /// The whole picture past the layer's outline (inside it, the layer shows the picture
        /// itself), at full strength: the canvas shows it at `ghost` of the marks' alpha. Drawn
        /// over as much of the stage (`stage` big) as it covers, `scale` pixels a point, into pixels
        /// as `render(board:)` does; where on the stage, or nil.
        public func ghost(_ m: Marks, scale: Double, stage: CGSize,
                          into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            let look = m.look, rect = look.rect, toView = look.toView
            let box = rect.applying(toView).insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: stage))
            guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
            // The picture alone, as wide as it lies, the whole of it even when cut out.
            var image = look.image.placed(at: CGRect(origin: .zero, size: rect.size), in: rect.size)
            image.cutout = nil
            var picture = Node(kind: .rectangle, name: "", frame: rect)
            picture.fill.on = true
            picture.fill.gradient = nil
            picture.fill.image = image
            let outline = Renderer.outline(of: look.node)
            return WindowsCore.overlay(box: box, scale: scale, into: fill) { ctx in
                ctx.concatenate(toView)
                ctx.beginPath()
                ctx.addRect(rect)
                ctx.addPath(outline)
                ctx.clip(using: .evenOdd)
                Renderer.withFlippedContext(ctx) {
                    Renderer.drawNode(picture, in: ctx, options: Renderer.Options(deviceScale: CGFloat(scale) * look.zoom, assets: assets))
                }
            }
        }
    }

    /// Draws over the part `box` of the stage (in its points) at `scale` pixels a point what
    /// `draw` draws in the stage's points, y down, into pixels as `render(board:)` does. The part
    /// drawn grows to whole steps of 64 pixels, so the canvas can keep its bitmap from frame to
    /// frame; where on the stage it is, or nil.
    static func overlay(box: CGRect, scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?,
                        _ draw: (CGContext) -> Void) -> CGRect? {
        let s = CGFloat(scale)
        let x0 = (box.minX * s).rounded(.down), y0 = (box.minY * s).rounded(.down)
        let w = ((box.maxX * s).rounded(.up) - x0) / 64, h = ((box.maxY * s).rounded(.up) - y0) / 64
        let size = CGSize(width: max(w.rounded(.up), 1) * 64, height: max(h.rounded(.up), 1) * 64)
        let drawn = WindowsCore.picture({
            guard let ctx = Renderer.bitmap(size) else { return nil }
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: s, y: -s)
            ctx.translateBy(x: -x0 / s, y: -y0 / s)
            draw(ctx)
            return ctx.makeImage()
        }, into: fill)
        return drawn ? CGRect(x: x0 / s, y: y0 / s, width: size.width / s, height: size.height / s) : nil
    }
}
