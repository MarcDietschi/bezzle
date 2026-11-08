import Foundation
import CBezzleHost

// The Mac's CutoutTool (Canvas/CutoutTool.swift) ported: what the canvas shows of cutting out a
// picture, and picking subjects. Drawn over the stage in one picture a frame (`draw`), which the
// canvas shows above the artboards, as the Mac draws it over the canvas.
//
// While a picture is cut out, the pencil goes over it. A pencil line sweeps across while the
// matte looks; once the subject is found, it is traced in pencil and the rest of the picture sinks
// into the table; when the cutout is made, the background melts away from the subject outwards,
// until only the subject is left, standing on whatever is behind it. (On the Mac, Vision finds the
// subject in a moment and the learned matte works after; here the matte is what finds it, so the
// sweep lasts while it runs, and tracing and melting follow close on each other.)
//
// Placing a cut-out picture (double-click it), its background shows faintly inside the layer too,
// so what was dropped can be seen. The subjects kept are traced faintly in pencil, and each lights
// up under the pointer: a click on one drops it, a click on one dropped keeps it, and the picture
// is cut out again. The last one is never dropped. The Mac's Vision tells people apart where they
// touch; here the parts are the matte's own regions, so people who touch are one part.
//
// What the Mac clips to a grey mask (the sinking table, the traced edge) is drawn here as the mask
// made into a picture of that colour: Bezzle's drawing on Windows clips to paths, not masks.

extension WindowsCore {
    public final class CutoutHand {
        public init() {}

        /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// The layer whose picture is being placed (the Mac's store.editingPicture).
        public var placing: UUID?
        /// The table's colour, which what is not the subject sinks into.
        public var table: UInt32 = 0xE5E1D9
        /// Draws the canvas's marks again, for what changes here and not in the design.
        public var redraw: () -> Void = {}
        /// Says why a picture could not be cut out again with other picks.
        public var trouble: (Swift.Error) -> Void = { _ in }

        private static let pencil = RGBA(hex: "3A63D8")!

        /// A layer filled with a picture, and the ways from its own coordinates and from across and
        /// down its picture (0…1) to the stage.
        private struct Look {
            let node: Node
            let image: ImageFill
            let frame: CGRect
            let zoom: CGFloat
            let pan: CGPoint

            var toView: CGAffineTransform {
                CGAffineTransform(translationX: frame.midX, y: frame.midY)
                    .rotated(by: Geometry.radians(node.rotation))
                    .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                    .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y))
            }

            var pictureToView: CGAffineTransform { image.placing(in: frame.size).concatenating(toView) }

            /// How much of the picture a point on screen is, across and down.
            var pointInPicture: CGSize {
                let r = Renderer.imageRect(image, in: frame.size)
                return CGSize(width: 1 / max(r.width * zoom, 1), height: 1 / max(r.height * zoom, 1))
            }

            /// Where it lies on the stage, as far as its outline reaches.
            var box: CGRect { CGRect(origin: .zero, size: frame.size).applying(toView) }
        }

        private func look(_ id: UUID) -> Look? {
            guard let doc = design, let node = doc.node(id), node.fill.on, let image = node.fill.image, let frame = doc.absoluteFrame(of: id) else { return nil }
            return Look(node: node, image: image, frame: frame, zoom: zoom, pan: pan)
        }

        // MARK: - The work as it goes

        /// One picture being cut out, as the canvas shows it, until it has melted away or faded.
        private struct Run {
            var look: Look
            /// The picture the layer showed as it began: the photo, or an earlier cutout of it.
            let shown: String
            let began: Double
            var found: CutoutFound?
            /// The background, the table's colour where the subject was not found; and the
            /// subject's edge, pencil in a narrow line round it: made the first frame they are drawn.
            var background: CGImage?
            var edge: CGImage?
            var foundAt: Double?
            /// The subject's middle, across and down the picture.
            var middle = CGPoint(x: 0.5, y: 0.5)
            /// When it ended, and whether with a cutout to melt into.
            var ended: (at: Double, made: Bool)?
        }

        private var runs: [UUID: Run] = [:]
        private static let sweep = 1.15
        private static let trace = 0.35
        private static let melt = 0.62
        private static let fade = 0.24

        /// Whether the canvas has to draw again soon, for something moving here.
        public var animating: Bool { !runs.isEmpty || !cuttingOut.isEmpty }

        /// What the canvas draws over the stage now, `stage` big, at `scale` pixels a point, into
        /// pixels as `render(board:)` makes them; where on the stage, or nil for nothing.
        public func draw(scale: Double, stage: CGSize, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            let now = WindowsCore.now
            for (id, work) in cuttingOut {
                if runs[id] == nil || runs[id]?.ended != nil, let look = look(id) {
                    runs[id] = Run(look: look, shown: look.image.shown, began: now)
                }
                guard var run = runs[id] else { continue }
                if let look = look(id) { run.look = look }
                if run.foundAt == nil, let found = work.found {
                    run.found = found
                    run.middle = found.middle
                    run.foundAt = now
                }
                runs[id] = run
            }
            for (id, run) in runs where run.ended == nil && cuttingOut[id] == nil {
                let image = design?.node(id)?.fill.image
                runs[id]?.ended = (now, image?.cutout != nil && image?.shown != run.shown)
            }
            let picking = pickable()
            var box = CGRect.null
            for (id, run) in runs { box = box.union((look(id) ?? run.look).box) }
            if let picking { box = box.union(picking.look.box) }
            box = box.insetBy(dx: -4, dy: -4).intersection(CGRect(origin: .zero, size: stage))
            guard !box.isNull, box.width >= 1, box.height >= 1 else {
                for (id, run) in runs where run.ended.map({ now - $0.at > Self.melt }) == true { runs[id] = nil }
                return nil
            }
            return WindowsCore.overlay(box: box, scale: scale, into: fill) { ctx in
                for (id, var run) in runs {
                    let look = look(id) ?? run.look
                    // The masks made into pictures once, here, where Skia is given what is drawn.
                    if run.background == nil, let found = run.found {
                        run.background = tinted(found.background, found, over: table, Self.pencil, 0.62, 0.07)
                        run.edge = tinted(found.edge, found, over: nil, Self.pencil, 1, 0)
                        runs[id] = run
                    }
                    guard let ended = run.ended else {
                        working(run, look, now, alpha: 1, ctx)
                        continue
                    }
                    let t = (now - ended.at) / (ended.made ? Self.melt : Self.fade)
                    if t >= 1 {
                        runs[id] = nil
                    } else if ended.made {
                        melting(run, look, CGFloat(t), now, ctx)
                    } else {
                        working(run, look, now, alpha: CGFloat(1 - t), ctx)
                    }
                }
                if let picking { self.picking(picking, ctx) }
            }
        }

        /// A mask made into a picture of one colour: `colour` at `strength`, over `base` at
        /// `baseStrength` when there is one, as solid as the mask is (premultiplied RGBA).
        private func tinted(_ mask: [UInt8], _ found: CutoutFound, over base: UInt32?, _ colour: RGBA, _ baseStrength: Double, _ strength: Double) -> CGImage {
            // One colour: `colour` at `strength` laid over `base` at `baseStrength` (or `colour` alone).
            var r: Double, g: Double, b: Double, a: Double
            if let base {
                let br = Double((base >> 16) & 0xFF) / 255, bg = Double((base >> 8) & 0xFF) / 255, bb = Double(base & 0xFF) / 255
                a = baseStrength + strength * (1 - baseStrength)
                r = (Double(colour.r) * strength + br * baseStrength * (1 - strength))
                g = (Double(colour.g) * strength + bg * baseStrength * (1 - strength))
                b = (Double(colour.b) * strength + bb * baseStrength * (1 - strength))
            } else {
                a = baseStrength
                r = Double(colour.r) * a
                g = Double(colour.g) * a
                b = Double(colour.b) * a
            }
            var bytes = [UInt8](repeating: 0, count: found.width * found.height * 4)
            for i in 0..<(found.width * found.height) where mask[i] > 0 {
                let m = Double(mask[i]) / 255
                bytes[i * 4] = UInt8(min(r * m * 255 + 0.5, 255))
                bytes[i * 4 + 1] = UInt8(min(g * m * 255 + 0.5, 255))
                bytes[i * 4 + 2] = UInt8(min(b * m * 255 + 0.5, 255))
                bytes[i * 4 + 3] = UInt8(min(a * m * 255 + 0.5, 255))
            }
            return CGImage(width: found.width, height: found.height, source: .pixels(bytes, bytesPerRow: found.width * 4, gray: false))
        }

        /// While it works: the pencil sweeping across, and once the subject is found, it traced in
        /// pencil and the rest sunk into the table.
        private func working(_ run: Run, _ look: Look, _ now: Double, alpha: CGFloat, _ ctx: CGContext) {
            let shown = Self.ease(min((now - run.began) / 0.2, 1))
            let traced = run.foundAt.map { Self.ease(min((now - $0) / Self.trace, 1)) } ?? 0
            inPicture(look, ctx) {
                ctx.setAlpha(alpha * shown)
                if traced < 1 { sweeping(look, (now - run.began) / Self.sweep, alpha: 1 - traced, ctx) }
                if let background = run.background { Self.drawUnit(background, alpha: alpha * shown * traced, ctx) }
                if let edge = run.edge {
                    // Alive while it works on: the line breathes.
                    let breath = 0.72 + 0.28 * cos((now - (run.foundAt ?? now)) * 2 * .pi / 1.3)
                    Self.drawUnit(edge, alpha: alpha * shown * traced * CGFloat(breath), ctx)
                }
            }
        }

        /// Done: the picture as it was melts away from the subject's middle outwards, leaving the cutout.
        private func melting(_ run: Run, _ look: Look, _ t: CGFloat, _ now: Double, _ ctx: CGContext) {
            let e = 1 - pow(1 - t, 3)
            let pixels = max(look.frame.width, look.frame.height) * look.zoom * 2
            inPicture(look, ctx) {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                if let picture = assets.image(run.shown, pixels: pixels) { Self.drawUnit(picture, alpha: 1, ctx) }
                if let background = run.background { Self.drawUnit(background, alpha: 1, ctx) }
                // Cleared from the middle out, softly at the edge of what is cleared.
                let c = run.middle
                let far = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 1
                let radius = max(far * 1.3 * e, 0.0001)
                if let clear = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                                          locations: [0, 0.62, 1]) {
                    ctx.setBlendMode(.destinationOut)
                    ctx.drawRadialGradient(clear, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
                }
                ctx.endTransparencyLayer()
                if let edge = run.edge { Self.drawUnit(edge, alpha: 1 - e, ctx) }
            }
        }

        /// A pencil line going across the picture, a wash of pencil trailing it, `phase` sweeps along.
        private func sweeping(_ look: Look, _ phase: Double, alpha: CGFloat, _ ctx: CGContext) {
            guard alpha > 0 else { return }
            let along = phase - floor(phase)
            // Easing in and out of each sweep, from just before the picture to just past it.
            let x = CGFloat(-0.15 + 1.3 * (0.5 - 0.5 * cos(along * .pi)))
            let pencil = Self.pencil
            ctx.saveGState()
            ctx.setAlpha(alpha)
            if let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: 0),
                                              CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: 0.2)] as CFArray,
                                     locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: x - 0.3, y: 0, width: 0.3, height: 1))
                ctx.drawLinearGradient(wash, start: CGPoint(x: x - 0.3, y: 0), end: CGPoint(x: x, y: 0), options: [])
                ctx.restoreGState()
            }
            ctx.setFillColor(CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: 1))
            ctx.fill(CGRect(x: x - look.pointInPicture.width * 0.75, y: 0, width: look.pointInPicture.width * 1.5, height: 1))
            ctx.restoreGState()
        }

        // MARK: - Picking subjects

        /// Each picture's parts, once found, by its name; and those being looked for.
        private var parts: [String: CutoutMaker.Subjects] = [:]
        private var looking: Set<String> = []
        private var hovered: Int?
        private var pending: DispatchWorkItem?

        /// The layer whose cut-out picture is being placed, and its parts once found.
        private func pickable() -> (id: UUID, look: Look, cutout: Cutout, subjects: CutoutMaker.Subjects?)? {
            guard let id = placing, cuttingOut[id] == nil, let look = look(id), let cutout = look.image.cutout else { return nil }
            return (id, look, cutout, subjects(of: look.image.asset))
        }

        /// A picture's parts: from its matte, kept from cutting it out (or made now, off the main thread).
        private func subjects(of asset: String) -> CutoutMaker.Subjects? {
            if let found = parts[asset] { return found }
            guard !looking.contains(asset), let folder = assets.folder else { return nil }
            looking.insert(asset)
            let source = folder.appendingPathComponent(asset)
            Task { [weak self] in
                guard let matte = await SubjectModel.shared.matte() else { return }
                let found = await Task.detached(priority: .userInitiated) { () -> CutoutMaker.Subjects? in
                    guard let data = try? Data(contentsOf: source), let picture = CutoutMaker.Pixels(file: data) else { return nil }
                    // As the picture is worked on when it is cut out, so its matte is the one kept then.
                    let shrink = min(1, 2048 / Double(max(picture.w, picture.h)))
                    let ww = max(1, Int((Double(picture.w) * shrink).rounded())), wh = max(1, Int((Double(picture.h) * shrink).rounded()))
                    guard let work = (shrink < 1 ? picture.scaled(ww, wh) : picture)?.overWhite(),
                          let learned = try? RememberedMatte(matting: matte, key: source.path).matte(of: work) else { return nil }
                    return CutoutMaker.subjects(of: CutoutMaker.resample(learned, ww, wh), ww, wh)
                }.value
                // None found stays looked for, so it is not looked for again.
                if let found { self?.parts[asset] = found }
                self?.redraw()
            }
            return nil
        }

        /// Which parts the cutout keeps: those its picks are on, or all of them.
        private func kept(_ subjects: CutoutMaker.Subjects, _ cutout: Cutout) -> Set<Int> {
            guard let picks = cutout.picks, !picks.isEmpty else { return Set(subjects.parts.indices) }
            return Set(picks.compactMap { subjects.part(at: $0) })
        }

        /// The part under the pointer (on the stage), while a cut-out picture is placed.
        public func hover(at v: CGPoint?) {
            var now: Int?
            if let v, let (_, look, _, subjects) = pickable(), let subjects {
                now = subjects.part(at: v.applying(look.pictureToView.inverted()))
            }
            if now != hovered {
                hovered = now
                redraw()
            }
        }

        /// Whether a part was under the pointer when it last moved.
        public var hovering: Bool { hovered != nil }

        /// A click on the picture being placed: the part there kept or dropped, once it is clear the
        /// click is not the first of a double click, which ends placing (`doubleClick` seconds).
        public func click(at v: CGPoint, doubleClick: Double) {
            pending?.cancel()
            guard let (id, look, cutout, subjects) = pickable(), let subjects,
                  let part = subjects.part(at: v.applying(look.pictureToView.inverted())) else { return }
            var keep = kept(subjects, cutout)
            if keep.contains(part) { keep.remove(part) } else { keep.insert(part) }
            guard !keep.isEmpty else { return }
            let picks = keep.count == subjects.parts.count ? nil : keep.sorted().map { subjects.parts[$0].point }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.placing == id else { return }
                    let slot = WindowsCore.active
                    Task {
                        do { try await WindowsCore.cutOut([id], picks: picks) } catch { WindowsCore.trouble(error, in: slot) }
                    }
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClick, execute: work)
        }

        /// The click waiting to keep or drop a part is the first of a double click after all.
        public func cancelClick() {
            pending?.cancel()
            pending = nil
        }

        /// While a cut-out picture is placed: its background faint inside the layer, the parts kept
        /// traced in pencil, the one under the pointer clearly, filled with pencil if it is to be kept.
        private func picking(_ p: (id: UUID, look: Look, cutout: Cutout, subjects: CutoutMaker.Subjects?), _ ctx: CGContext) {
            let look = p.look
            let pixels = max(look.frame.width, look.frame.height) * look.zoom * 2
            if let picture = assets.image(look.image.asset, pixels: pixels), let cut = assets.image(p.cutout.asset, pixels: pixels) {
                inPicture(look, ctx) {
                    ctx.setAlpha(0.42)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    Self.drawUnit(picture, alpha: 1, ctx)
                    ctx.setBlendMode(.destinationOut)
                    Self.drawUnit(cut, alpha: 1, ctx)
                    ctx.endTransparencyLayer()
                }
            }
            guard let subjects = p.subjects else { return }
            let keep = kept(subjects, p.cutout)
            var toView = look.pictureToView
            let pencil = Self.pencil
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setLineJoin(.round)
            for (i, part) in subjects.parts.enumerated() where keep.contains(i) || i == hovered {
                guard let outline = part.outline.copy(using: &toView) else { continue }
                if i == hovered && !keep.contains(i) {
                    ctx.beginPath()
                    ctx.addPath(outline)
                    ctx.setFillColor(CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: 0.16))
                    ctx.fillPath(using: .evenOdd)
                }
                ctx.beginPath()
                ctx.addPath(outline)
                ctx.setStrokeColor(CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: i == hovered ? 1 : 0.4))
                ctx.setLineWidth(i == hovered ? 1.5 : 1)
                ctx.strokePath()
            }
        }

        // MARK: - Drawing in a picture

        /// `body` drawn across and down the layer's picture, 0…1, cut to the layer's outline.
        private func inPicture(_ look: Look, _ ctx: CGContext, _ body: () -> Void) {
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.concatenate(look.toView)
            ctx.beginPath()
            ctx.addPath(Renderer.outline(of: look.node))
            ctx.clip(using: look.node.evenOdd == true ? .evenOdd : .winding)
            ctx.concatenate(look.image.placing(in: look.frame.size))
            ctx.interpolationQuality = .high
            body()
        }

        /// A picture across the unit square, upright with y down, at `alpha`.
        private static func drawUnit(_ image: CGImage, alpha: CGFloat, _ ctx: CGContext) {
            guard alpha > 0.005 else { return }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }

        private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }
    }
}
