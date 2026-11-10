import Foundation

// The Mac's CutoutTool (Canvas/CutoutTool.swift) ported: what the canvas shows of cutting out a
// picture, and picking subjects. Drawn over the stage in one picture a frame (`draw`), which the
// canvas shows above the artboards, as the Mac draws it over the canvas.
//
// While a picture is cut out, the line to cut along is drawn round it in pencil, dashed as such
// a line is, its dashes running. It begins as the layer's own outline and pulls tight round the
// subject as the work goes on (`CutoutLoop`), so how far it has closed in is how far the work is
// (`CutoutPace`). The picture itself stays whole meanwhile: nothing looks cut out before it is.
// Once the cutout is made, the line pulls tight, runs solid round the subject once, and what it
// cut off drops away from under the subject, which is left standing on whatever is behind it.
// Given up, or with nothing found, the line slackens back to the frame and goes.
//
// Placing a cut-out picture (double-click it), its background shows faintly inside the layer too,
// so what was dropped can be seen. The subjects kept are traced faintly in pencil, and each lights
// up under the pointer: a click on one drops it, a click on one dropped keeps it, and the picture
// is cut out again. The last one is never dropped. The Mac's Vision tells people apart where they
// touch; here the parts are the matte's own regions, so people who touch are one part.
//
// What differs from the Mac's, for how Windows draws:
// - The Mac has Core Graphics fill a small grey bitmap to know which cells of the line's grid lie
//   in the layer and on the subject. Bezzle's drawing here is written down for Skia and not read
//   back, so the cells are worked out from the outlines' own points (`CutoutCells`).
// - The Mac draws the layer whole and with its cutout into two bitmaps ahead of the cut, away
//   from the main thread, and lets those drop. Here the layer is drawn as it was and as it is
//   each frame of the drop, into the frame's picture, which Skia plays: nothing to make ahead.
// - Until the subject is found, the Mac's line only comes loose of the frame for a moment, as
//   Vision finds the subject at once. Here the matte itself finds it, so the line stays loose of
//   the frame through most of the work and makes for the subject near its end.

extension WindowsCore {
    public final class CutoutHand {
        public init() {}

        /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// The layer whose picture is being placed (the Mac's store.editingPicture).
        public var placing: UUID?
        /// Draws the canvas's marks again, for what changes here and not in the design.
        public var redraw: () -> Void = {}

        private static let pencil = RGBA(hex: "3A63D8")!
        private static func ink(_ alpha: CGFloat = 1) -> CGColor { CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: alpha) }

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

            /// Where it lies on the stage, as far as its outline reaches.
            var box: CGRect { CGRect(origin: .zero, size: frame.size).applying(toView) }
        }

        private func look(_ id: UUID) -> Look? {
            guard let doc = design, let node = doc.node(id), node.fill.on, let image = node.fill.image, let frame = doc.absoluteFrame(of: id) else { return nil }
            return Look(node: node, image: image, frame: frame, zoom: zoom, pan: pan)
        }

        // MARK: - The work as it goes

        /// One picture being cut out, as the canvas shows it, until what was cut off has dropped away.
        private struct Run {
            var look: Look
            /// The layer as it was when this began.
            let before: Node
            let began: Double
            /// Whether its picture was cut out already: other subjects picked in a picture being
            /// placed, which `picking` shows.
            let again: Bool
            /// The line, and what of the layer it was laid for.
            var loop: CutoutLoop?
            var laid = ""
            var foundAt: Double?
            /// How tight the line is drawn, and when it last was.
            var tight = 0.0
            var drawn: Double
            /// The cutout made: when, and how tight the line was then.
            var made: (at: Double, tight: Double)?
            /// The subject's outline, across and down the picture.
            var outline: [[CGPoint]] = []
            /// The layer as it will show with its cutout.
            var after: Node?
            /// Which way what is cut off turns as it drops: its heavier side first.
            var turn = 1.0
            /// The design showing the cutout: when, and whether the layer is still as it was when
            /// the cutout was made (`after`), so what was cut off can be shown dropping.
            var cut: (at: Double, same: Bool)?
            /// Given up, or nothing found: when, and how tight the line was then.
            var slack: (at: Double, tight: Double)?

            var over: Bool { cut != nil || slack != nil }
        }

        /// What of a run is drawn in one frame.
        private struct Showing {
            /// How clearly the line shows at all, its dashes and the solid cut.
            var line: CGFloat
            var dashes: CGFloat = 1
            var solid: CGFloat = 0
            /// How far round the subject the cut has come, 0…1.
            var along = 0.0
            /// How far what was cut off has dropped, 0…1, once it does.
            var drop: Double?
        }

        private var runs: [UUID: Run] = [:]

        /// Whether the canvas has to draw again soon, for something moving here.
        public var animating: Bool { !runs.isEmpty || !cuttingOut.isEmpty }

        /// What the canvas draws over the stage now, `stage` big, at `scale` pixels a point, into
        /// pixels as `render(board:)` makes them; where on the stage, or nil for nothing.
        public func draw(scale: Double, stage: CGSize, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            let now = WindowsCore.now
            for (id, work) in cuttingOut {
                if runs[id] == nil || runs[id]?.over == true, let look = look(id) {
                    runs[id] = Run(look: look, before: look.node, began: now, again: look.image.cutout != nil, drawn: now)
                }
                guard var run = runs[id] else { continue }
                if let look = look(id) { run.look = look }
                if !run.again {
                    lay(&run, found: work.found, made: work.made, now)
                    if run.made == nil, work.pace.ended != nil {
                        run.made = (now, run.tight)
                        if let cutout = work.made {
                            if let data = cutout.outline {
                                let outline = Silhouettes.path(data)
                                run.outline = Self.lines(of: outline)
                                run.turn = outline.boundingBoxOfPath.midX < 0.5 ? 1 : -1
                            }
                            var after = run.before
                            after.fill.image?.cutout = cutout
                            run.after = after
                        }
                    }
                }
                runs[id] = run
            }
            for (id, run) in runs where !run.over && cuttingOut[id] == nil {
                let node = design?.node(id), image = node?.fill.image
                if image?.cutout != nil, image?.shown != run.before.fill.image?.shown {
                    // What dropped is drawn as the layer was when the cutout was made: only while it still is.
                    runs[id]?.cut = (now, run.after != nil && node?.fill == run.after?.fill && node?.frame.size == run.after?.frame.size)
                } else {
                    runs[id]?.slack = (now, run.tight)
                }
            }
            // Each run a step on, and gone once there is no more of it to show: whether or not it
            // is on the stage just now.
            var showing: [(run: Run, shows: Showing)] = []
            for id in runs.keys.sorted(by: { (runs[$0]?.began ?? 0, $0.uuidString) < (runs[$1]?.began ?? 0, $1.uuidString) }) {
                guard var run = runs[id] else { continue }
                if let look = look(id) { run.look = look }
                guard let shows = step(&run, working: cuttingOut[id], now) else {
                    runs[id] = nil
                    continue
                }
                runs[id] = run
                if !run.again { showing.append((run, shows)) }
            }
            let picking = pickable(working: true)
            let changes = picking.map { cuttingOut[$0.id] != nil } ?? false
            var box = CGRect.null
            for (run, _) in showing { box = box.union(run.look.box) }
            if let picking { box = box.union(picking.look.box) }
            // Room for the line's width beside the frame.
            box = box.insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: stage))
            guard !box.isNull, box.width >= 1, box.height >= 1 else {
                drawn = nil
                return nil
            }
            // Only picking, and nothing of it changed: the picture drawn last time still holds.
            if showing.isEmpty, !changes, let p = picking {
                let key = "\(p.id) \(p.cutout.asset) \(p.look.image.offset) \(p.look.image.scale) \(p.look.image.mode) \(p.look.frame) "
                    + "\(p.look.node.rotation) \(zoom) \(pan) \(scale) \(hovered ?? -1) \(p.subjects?.parts.count ?? -1)"
                if let drawn, drawn.key == key { return drawn.box }
                let made = WindowsCore.overlay(box: box, scale: scale, into: fill) { ctx in self.picking(p, working: false, now, ctx) }
                drawn = made.map { (key, $0) }
                return made
            }
            drawn = nil
            return WindowsCore.overlay(box: box, scale: scale, into: fill) { ctx in
                for (run, shows) in showing { self.show(run, shows, now, scale: scale, ctx) }
                if let picking { self.picking(picking, working: changes, now, ctx) }
            }
        }

        /// What was drawn last while only picking, and what it showed.
        private var drawn: (key: String, box: CGRect)?

        /// Lays the line round the layer, once and again when the layer or its picture is placed
        /// otherwise, and tells it where the subject is once that is known: roughly as the work
        /// found it, or exactly from a cutout that was found made.
        private func lay(_ run: inout Run, found: CutoutFound?, made: Cutout?, _ now: Double) {
            let look = run.look
            let size = look.frame.size, width = Double(size.width), height = Double(size.height)
            let placing = look.image.placing(in: size)
            let key = "\(size) \(placing)"
            // Outlines as short lines, finer than the cells they are laid on.
            let fine = max(size.width, size.height) / 640
            if run.loop == nil || run.laid != key {
                let cells = CutoutLoop.cells(for: size)
                let inside = CutoutCells.cells(cells.w, cells.h, width: width, height: height,
                                               inside: Renderer.outline(of: look.node).polygons(tolerance: fine), evenOdd: look.node.evenOdd == true)
                // A plain rectangle's outline the line knows itself, corners and all.
                run.loop = CutoutLoop(w: cells.w, h: cells.h, inside: CutoutCells.isWhole(inside) ? nil : inside)
                run.laid = key
            }
            guard var loop = run.loop, !loop.found else { return }
            let subject: [UInt8]
            if let found {
                let placed = CutoutCells.Placing(a: Double(placing.a), b: Double(placing.b), c: Double(placing.c), d: Double(placing.d),
                                                 tx: Double(placing.tx), ty: Double(placing.ty))
                subject = CutoutCells.cells(loop.w, loop.h, width: width, height: height, on: found.inside, found.width, found.height, placed: placed)
            } else if let data = made?.outline {
                var inLayer = placing
                guard let outline = Silhouettes.path(data).copy(using: &inLayer) else { return }
                subject = CutoutCells.cells(loop.w, loop.h, width: width, height: height, inside: outline.polygons(tolerance: fine), evenOdd: true)
            } else {
                return
            }
            loop.find(subject)
            run.loop = loop
            if loop.found, run.foundAt == nil { run.foundAt = now }
        }

        /// One picture's cutting out as it stands at `now`: how tight its line is, and what of it
        /// shows; nil once there is no more to show.
        private func step(_ run: inout Run, working: CutoutWork?, _ now: Double) -> Showing? {
            guard !run.again else { return run.over ? nil : Showing(line: 0) }
            var shows = Showing(line: Self.ease((now - run.began) / 0.18))
            if let slack = run.slack {
                // Let go: back out to the frame, and gone.
                let t = (now - slack.at) / CutoutMotion.slack
                guard t < 1 else { return nil }
                run.tight = slack.tight * Double(1 - Self.ease(t))
                shows.line *= CGFloat(1 - t)
            } else if let made = run.made {
                // Pulled tight, a little past and back; then the cut runs round, the dashes giving way to it.
                let t = now - made.at
                run.tight = made.tight + (1 - made.tight) * CutoutMotion.sprung(t / CutoutMotion.pull)
                shows.along = min(max((t - CutoutMotion.pull) / CutoutMotion.cut, 0), 1)
                shows.dashes = CGFloat(1 - shows.along)
                shows.solid = 1
                if let cut = run.cut {
                    let t = (now - cut.at) / CutoutMotion.drop
                    guard t < 1 else { return nil }
                    shows.along = 1
                    shows.dashes = 0
                    shows.solid = CGFloat(max(0, 1 - t * 1.6))
                    if cut.same { shows.drop = t }
                }
            } else if let working {
                // Closing in as the work goes on, eased after what is done so no step of it jumps.
                let wanted = CutoutMotion.tightest * working.pace.done(at: now)
                run.tight += (wanted - run.tight) * (1 - exp(-max(0, now - run.drawn) / 0.14))
            }
            run.drawn = now
            return shows
        }

        /// Draws what `shows` of a run: what was cut off dropping, the line round the picture, and
        /// the cut round the subject.
        private func show(_ run: Run, _ shows: Showing, _ now: Double, scale: Double, _ ctx: CGContext) {
            let look = run.look
            if let t = shows.drop { dropping(run, look, t, scale: scale, ctx) }
            guard let loop = run.loop else { return }
            let toView = CGAffineTransform(scaleX: look.frame.width, y: look.frame.height).concatenating(look.toView)
            if shows.dashes > 0.01 {
                // How far it makes for the subject rather than only coming loose of the frame.
                let made = run.made != nil
                let found = run.foundAt.map { Double(Self.ease((now - $0) / (made ? CutoutMotion.pull : CutoutMotion.found))) } ?? 0
                let path = CGMutablePath()
                for points in loop.lines(tight: run.tight, found: found) { Self.add(points, to: path, using: toView) }
                Self.stroke(path, in: ctx, alpha: shows.line * shows.dashes, running: now - run.began)
            }
            if shows.solid > 0.01, shows.along > 0, !run.outline.isEmpty {
                // The cut: solid round the subject as far as it has come, only where the layer shows.
                let pictureToView = look.pictureToView
                var frameToView = look.toView
                ctx.saveGState()
                defer { ctx.restoreGState() }
                if let frame = Renderer.outline(of: look.node).copy(using: &frameToView) {
                    ctx.beginPath()
                    ctx.addPath(frame.union(frame.copy(strokingWithWidth: 3, lineCap: .butt, lineJoin: .miter, miterLimit: 4)))
                    ctx.clip()
                }
                let e = Self.inOut(shows.along)
                let path = CGMutablePath()
                for points in run.outline {
                    let placed = points.map { $0.applying(pictureToView) }
                    var whole: CGFloat = 0
                    for i in placed.indices { whole += Self.distance(placed[i], placed[(i + 1) % placed.count]) }
                    var left = whole * e
                    path.move(to: placed[0])
                    for i in placed.indices where left > 0 {
                        let a = placed[i], b = placed[(i + 1) % placed.count], d = Self.distance(a, b)
                        let t = d > 0 ? min(1, left / d) : 1
                        path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                        left -= d
                    }
                }
                Self.stroke(path, in: ctx, alpha: shows.line * shows.solid, running: nil)
            }
        }

        /// What was cut off dropping away, `t` of the way: the layer as it showed, less the subject,
        /// let go downwards, turning a little as a piece of paper does and fading, behind the subject
        /// standing where it was.
        private func dropping(_ run: Run, _ look: Look, _ t: Double, scale: Double, _ ctx: CGContext) {
            guard let after = run.after, look.node.transform3D == nil else { return }
            let size = look.frame.size
            let whole = Self.plain(run.before), left = Self.plain(after)
            let options = Renderer.Options(deviceScale: CGFloat(scale) * look.zoom, assets: assets)
            // Falling as things do, ever faster, straight down the screen however the layer is turned.
            let fallen = CGSize(width: 0, height: CutoutMotion.fall * t * t).applying(look.toView.inverted())
            func show(_ node: Node) {
                Renderer.withFlippedContext(ctx) { Renderer.drawNode(node, in: ctx, options: options) }
            }
            /// Taken out of what is drawn so far, as solid as `node` shows.
            func take(_ node: Node) {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                show(node)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.concatenate(look.toView)
            ctx.beginPath()
            ctx.addPath(Renderer.outline(of: look.node))
            ctx.clip(using: look.node.evenOdd == true ? .evenOdd : .winding)
            ctx.interpolationQuality = .high
            ctx.saveGState()
            ctx.setAlpha(CGFloat(1 - t * t) * CGFloat(look.node.opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.saveGState()
            ctx.translateBy(x: fallen.width + size.width / 2, y: fallen.height + size.height / 2)
            ctx.rotate(by: Geometry.radians(run.turn * CutoutMotion.turn * t * t))
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            show(whole)
            take(left)
            ctx.restoreGState()
            // Nothing of it over the subject, which stands in front.
            take(left)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            // The subject as it stands, for the moment the canvas takes to draw the layer anew:
            // through the first half of the drop, then given over to the canvas.
            let standing = 1 - Self.inOut((t - 0.5) / 0.5)
            if standing > 0.004, look.node.opacity >= 1, look.node.blend == nil, look.node.blur == nil {
                ctx.saveGState()
                ctx.setAlpha(standing)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                show(left)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }

        /// The layer as it shows, without its place, border, shadows, opacity and turn: what is
        /// cut, and what the cut leaves of it, to draw in the layer's own coordinates.
        private static func plain(_ node: Node) -> Node {
            var plain = node
            plain.frame.origin = .zero
            plain.rotation = 0
            plain.border.on = false
            plain.moreBorders = nil
            plain.shadows = []
            plain.opacity = 1
            plain.blend = nil
            plain.blur = nil
            plain.transform3D = nil
            plain.hidden = false
            return plain
        }

        // MARK: - Picking subjects

        /// Each picture's parts, once found, by its name; and those being looked for, or with none.
        private var parts: [String: CutoutMaker.Subjects] = [:]
        private var looking: Set<String> = []
        private var hovered: Int?
        private var pending: DispatchWorkItem?
        /// The part a click is having kept or dropped, while the picture is cut out again for it.
        private var changing: Int?

        /// The layer whose cut-out picture is being placed, and its parts once found: shown also
        /// while it is cut out again for a part kept or dropped (`working`), when no part is picked.
        private func pickable(working: Bool = false) -> (id: UUID, look: Look, cutout: Cutout, subjects: CutoutMaker.Subjects?)? {
            guard let id = placing, working || cuttingOut[id] == nil, let look = look(id), let cutout = look.image.cutout else { return nil }
            return (id, look, cutout, subjects(of: look.image.asset))
        }

        /// A picture's parts: from its matte, kept from cutting it out however finely (or made now,
        /// away from the main thread).
        private func subjects(of asset: String) -> CutoutMaker.Subjects? {
            if let found = parts[asset] { return found }
            guard !looking.contains(asset), let folder = assets.folder else { return nil }
            looking.insert(asset)
            let source = folder.appendingPathComponent(asset)
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) { () -> CutoutMaker.Subjects? in
                    guard let matting = SubjectModel.shared.cut(of: source.path, anyKept: true),
                          let data = try? Data(contentsOf: source), let picture = CutoutMaker.Pixels(file: data) else { return nil }
                    // As the picture is worked on when it is cut out, so its matte is the one kept then.
                    let shrink = min(1, Double(CutoutMaker.Tuning().workSide) / Double(max(picture.w, picture.h)))
                    let ww = max(1, Int((Double(picture.w) * shrink).rounded())), wh = max(1, Int((Double(picture.h) * shrink).rounded()))
                    guard let work = (shrink < 1 ? picture.scaled(ww, wh) : picture)?.overWhite(),
                          let learned = try? matting.matte(of: work) else { return nil }
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
                    self.changing = part
                    Task {
                        do { try await WindowsCore.cutOut([id], picks: picks) } catch { WindowsCore.trouble(error, in: slot) }
                        self.changing = nil
                        self.redraw()
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
        /// A part just clicked is drawn round as a line to cut along, its dashes running, until the
        /// picture has been cut out again with or without it (`working`).
        private func picking(_ p: (id: UUID, look: Look, cutout: Cutout, subjects: CutoutMaker.Subjects?), working: Bool, _ now: Double, _ ctx: CGContext) {
            let look = p.look
            let pixels = max(look.frame.width, look.frame.height) * look.zoom * 2
            if let picture = assets.image(look.image.asset, pixels: pixels), let cut = assets.image(p.cutout.asset, pixels: pixels) {
                inPicture(look, ctx) {
                    ctx.setAlpha(0.42)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    Self.drawUnit(picture, ctx)
                    ctx.setBlendMode(.destinationOut)
                    Self.drawUnit(cut, ctx)
                    ctx.endTransparencyLayer()
                }
            }
            guard let subjects = p.subjects else { return }
            let keep = kept(subjects, p.cutout)
            var toView = look.pictureToView
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setLineJoin(.round)
            let hovered = working ? nil : hovered
            for (i, part) in subjects.parts.enumerated() where keep.contains(i) || i == hovered || (working && i == changing) {
                guard let outline = part.outline.copy(using: &toView) else { continue }
                if i == hovered && !keep.contains(i) {
                    ctx.beginPath()
                    ctx.addPath(outline)
                    ctx.setFillColor(Self.ink(0.16))
                    ctx.fillPath(using: .evenOdd)
                }
                if working && i == changing {
                    Self.stroke(outline, in: ctx, alpha: 1, running: now)
                    continue
                }
                ctx.beginPath()
                ctx.addPath(outline)
                ctx.setStrokeColor(Self.ink(i == hovered ? 1 : 0.4))
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

        /// A picture across the unit square, upright with y down.
        private static func drawUnit(_ image: CGImage, _ ctx: CGContext) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }

        /// A line to cut along, drawn over a picture: in pencil, with a little paper showing beside
        /// it, so it reads on a dark picture as on a light one. `running` for so many seconds, it is
        /// dashed and its dashes run the way it goes round; without, it is the cut, solid.
        private static func stroke(_ path: CGPath, in ctx: CGContext, alpha: CGFloat, running: Double?) {
            guard alpha > 0.004, !path.isEmpty else { return }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setLineJoin(.round)
            ctx.setLineCap(running == nil ? .round : .butt)
            let phase = running.map { 11 - CGFloat(($0 * 30).truncatingRemainder(dividingBy: 11)) }
            // The paper reaches a point past each dash, at its ends as at its sides.
            ctx.setAlpha(alpha * 0.62)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(3.5)
            if let phase { ctx.setLineDash(phase: phase + 1, lengths: [8, 3]) }
            ctx.beginPath()
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setAlpha(alpha)
            ctx.setStrokeColor(ink())
            ctx.setLineWidth(1.5)
            if let phase { ctx.setLineDash(phase: phase, lengths: [6, 5]) }
            ctx.beginPath()
            ctx.addPath(path)
            ctx.strokePath()
        }

        private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - min(max(t, 0), 1), 3)) }

        /// Setting off slowly and arriving slowly.
        private static func inOut(_ t: Double) -> CGFloat { CGFloat(0.5 - 0.5 * cos(min(max(t, 0), 1) * .pi)) }

        private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

        /// A closed line through `points` as a thread lies, rounding each of them, added to `path`.
        private static func add(_ points: [CGPoint], to path: CGMutablePath, using transform: CGAffineTransform) {
            guard points.count >= 3 else { return }
            let placed = points.map { $0.applying(transform) }
            func between(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: between(placed[placed.count - 1], placed[0]))
            for i in placed.indices { path.addQuadCurve(to: between(placed[i], placed[(i + 1) % placed.count]), control: placed[i]) }
            path.closeSubpath()
        }

        /// The closed lines an outline is made of, its curves as short lines.
        private static func lines(of path: CGPath) -> [[CGPoint]] {
            var lines: [[CGPoint]] = [], line: [CGPoint] = []
            path.applyWithBlock { element in
                let p = element.pointee.points
                switch element.pointee.type {
                case .moveToPoint:
                    if line.count >= 3 { lines.append(line) }
                    line = [p[0]]
                case .addLineToPoint:
                    line.append(p[0])
                case .addQuadCurveToPoint:
                    line.append(p[1])
                case .addCurveToPoint:
                    line.append(p[2])
                case .closeSubpath:
                    if line.count >= 3 { lines.append(line) }
                    line = []
                }
            }
            if line.count >= 3 { lines.append(line) }
            return lines
        }
    }
}
