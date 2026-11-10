import AppKit

/// What the canvas shows of cutting out a picture: the work as it goes, and picking subjects.
///
/// While a picture is cut out, the line to cut along is drawn round it in pencil, dashed as such
/// a line is, its dashes running. It begins as the layer's own outline and pulls tight round the
/// subject as the work goes on (`CutoutLoop`), so how far it has closed in is how far the work is
/// (`CutoutPace`). The picture itself stays whole meanwhile: nothing looks cut out before it is.
/// Once the cutout is made, the line pulls tight, runs solid round the subject once, and what it
/// cut off drops away from under the subject, which is left standing on whatever is behind it.
/// Given up, or with nothing found, the line slackens back to the frame and goes.
///
/// Placing a cut-out picture (double-click it), its background shows faintly inside the layer too,
/// so what was dropped can be seen. The subjects kept are traced faintly in pencil, and each lights
/// up under the pointer: a click on one drops it, a click on one dropped keeps it, and the picture
/// is cut out again. The last one is never dropped.
final class CutoutTool {
    private let store: DocumentStore
    /// Draws the canvas again, for what changes here and not in the store.
    var redraw: () -> Void = {}

    init(store: DocumentStore) {
        self.store = store
    }

    /// A layer filled with a picture, and the ways from its own coordinates and from across and
    /// down its picture (0…1) to the screen.
    private struct Look {
        let node: Node
        let image: ImageFill
        let frame: CGRect
        let viewport: Viewport

        var toView: CGAffineTransform {
            CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: Geometry.radians(node.rotation))
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom).translatedBy(x: -viewport.origin.x, y: -viewport.origin.y))
        }

        var pictureToView: CGAffineTransform { image.placing(in: frame.size).concatenating(toView) }

        /// How much of the picture a point on screen is, across and down.
        var pointInPicture: CGSize {
            let r = Renderer.imageRect(image, in: frame.size)
            return CGSize(width: 1 / max(r.width * viewport.zoom, 1), height: 1 / max(r.height * viewport.zoom, 1))
        }
    }

    private func look(_ id: UUID) -> Look? {
        guard let node = store.node(id), node.fill.on, let image = node.fill.image, let frame = store.doc.absoluteFrame(of: id) else { return nil }
        return Look(node: node, image: image, frame: frame, viewport: store.viewport)
    }

    // MARK: - The work as it goes

    /// One picture being cut out, as the canvas shows it, until what was cut off has dropped away.
    private struct Run {
        var look: Look
        /// The layer as it was when this began.
        let before: Node
        let began: CFTimeInterval
        /// Whether its picture was cut out already: other subjects picked in a picture being
        /// placed, which `picking` shows.
        let again: Bool
        /// The line, and what of the layer it was laid for.
        var loop: CutoutLoop?
        var laid = ""
        var foundAt: CFTimeInterval?
        /// How tight the line is drawn, and when it last was.
        var tight = 0.0
        var drawn: CFTimeInterval
        /// The cutout made: when, how tight the line was then, the layer as it still shows, and
        /// the subject's outline, across and down the picture.
        var made: (at: CFTimeInterval, tight: Double)?
        var outline: [[CGPoint]] = []
        /// The layer as it shows whole, and as it will with its cutout: drawn away from the main
        /// thread while the line pulls tight, so the cut itself takes no time. `after` is the
        /// layer they were drawn for.
        var whole: CGImage?
        var left: CGImage?
        var after: Node?
        /// Which way what is cut off turns as it drops: its heavier side first.
        var turn = 1.0
        /// The design showing the cutout: when, and the layer as it shows now.
        var cut: (at: CFTimeInterval, left: CGImage?)?
        /// Given up, or nothing found: when, and how tight the line was then.
        var slack: (at: CFTimeInterval, tight: Double)?

        var over: Bool { cut != nil || slack != nil }
    }

    private var runs: [UUID: Run] = [:]

    /// Whether the canvas has to draw again soon, for something moving here.
    var animating: Bool { !runs.isEmpty || !store.cuttingOut.isEmpty }

    func draw(_ ctx: CGContext, scale: CGFloat) {
        let now = CACurrentMediaTime()
        for (id, work) in store.cuttingOut {
            if runs[id] == nil || runs[id]?.over == true, let look = look(id) {
                runs[id] = Run(look: look, before: look.node, began: now, again: look.image.cutout != nil, drawn: now)
            }
            guard var run = runs[id] else { continue }
            if let look = look(id) { run.look = look }
            if !run.again {
                lay(&run, found: work.found, made: work.made, now)
                if run.made == nil, work.pace.ended != nil {
                    run.made = (now, run.tight)
                    if let data = work.made?.outline {
                        let outline = Silhouettes.path(data)
                        run.outline = Self.lines(of: outline)
                        run.turn = outline.boundingBoxOfPath.midX < 0.5 ? 1 : -1
                    }
                    prepare(id, &run, cutout: work.made, scale: scale)
                }
            }
            runs[id] = run
        }
        for (id, run) in runs where !run.over && store.cuttingOut[id] == nil {
            let image = store.node(id)?.fill.image
            if image?.cutout != nil, image?.shown != run.before.fill.image?.shown {
                // What was drawn ahead holds only for the layer as it then was.
                let node = store.node(id), same = node?.fill == run.after?.fill && node?.frame.size == run.after?.frame.size
                if !same || run.whole == nil || run.left == nil { runs[id]?.whole = nil }
                runs[id]?.cut = (now, same ? run.left : nil)
            } else {
                runs[id]?.slack = (now, run.tight)
            }
        }
        for id in Array(runs.keys) {
            guard var run = runs[id] else { continue }
            if let look = look(id) { run.look = look }
            runs[id] = draw(&run, working: store.cuttingOut[id], now, ctx) ? run : nil
        }
        picking(ctx, now)
    }

    /// Lays the line round the layer, once and again when the layer or its picture is placed
    /// otherwise, and tells it where the subject is once that is known: roughly as the work
    /// found it, or exactly from a cutout that was found made.
    private func lay(_ run: inout Run, found: CGImage?, made: Cutout?, _ now: CFTimeInterval) {
        let look = run.look
        let placing = look.image.placing(in: look.frame.size)
        let key = "\(look.frame.size) \(placing)"
        if run.loop == nil || run.laid != key {
            let cells = CutoutLoop.cells(for: look.frame.size)
            let outline = Renderer.outline(of: look.node)
            // A plain rectangle's outline the line knows itself, corners and all.
            let inside = outline.isRect(nil) ? nil : Self.cells(cells.w, cells.h, of: look.frame.size) { ctx in
                ctx.addPath(outline)
                ctx.fillPath(using: look.node.evenOdd == true ? .evenOdd : .winding)
            }
            run.loop = CutoutLoop(w: cells.w, h: cells.h, inside: inside)
            run.laid = key
        }
        guard var loop = run.loop, !loop.found else { return }
        let subject: [UInt8]?
        if let found {
            subject = Self.cells(loop.w, loop.h, of: look.frame.size) { ctx in
                ctx.concatenate(placing)
                ctx.interpolationQuality = .medium
                Self.drawUnit(found, ctx)
            }
        } else if let data = made?.outline {
            subject = Self.cells(loop.w, loop.h, of: look.frame.size) { ctx in
                ctx.concatenate(placing)
                ctx.addPath(Silhouettes.path(data))
                ctx.fillPath(using: .evenOdd)
            }
        } else {
            return
        }
        guard let subject else { return }
        loop.find(subject)
        run.loop = loop
        if loop.found, run.foundAt == nil { run.foundAt = now }
    }

    /// Draws one picture's cutting out as it stands at `now`; false once there is no more to show.
    private func draw(_ run: inout Run, working: CutoutWork?, _ now: CFTimeInterval, _ ctx: CGContext) -> Bool {
        guard !run.again else { return !run.over }
        let look = run.look
        var line = Self.ease(min((now - run.began) / 0.18, 1)), dashes: CGFloat = 1, solid: CGFloat = 0, along = 0.0
        if let slack = run.slack {
            // Let go: back out to the frame, and gone.
            let t = (now - slack.at) / CutoutMotion.slack
            guard t < 1 else { return false }
            run.tight = slack.tight * Double(1 - Self.ease(t))
            line *= CGFloat(1 - t)
        } else if let made = run.made {
            // Pulled tight, a little past and back; then the cut runs round, the dashes giving way to it.
            let t = now - made.at
            run.tight = made.tight + (1 - made.tight) * CutoutMotion.sprung(t / CutoutMotion.pull)
            along = min(max((t - CutoutMotion.pull) / CutoutMotion.cut, 0), 1)
            dashes = CGFloat(1 - along)
            solid = 1
            if let cut = run.cut {
                let t = (now - cut.at) / CutoutMotion.drop
                guard t < 1 else { return false }
                along = 1
                dashes = 0
                solid = CGFloat(max(0, 1 - t * 1.6))
                dropping(run, look, t, ctx)
            }
        } else if let working {
            // Closing in as the work goes on, eased after what is done so no step of it jumps.
            let wanted = CutoutMotion.tightest * working.pace.done(at: now)
            run.tight += (wanted - run.tight) * (1 - exp(-max(0, now - run.drawn) / 0.14))
        }
        run.drawn = now
        guard let loop = run.loop else { return true }
        let toView = CGAffineTransform(scaleX: look.frame.width, y: look.frame.height).concatenating(look.toView)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        if dashes > 0.01 {
            // How far it makes for the subject rather than only coming loose of the frame.
            let made = run.made != nil
            let found = run.foundAt.map { Double(Self.ease(min((now - $0) / (made ? CutoutMotion.pull : CutoutMotion.found), 1))) } ?? 0
            let path = CGMutablePath()
            for points in loop.lines(tight: run.tight, found: found) { Self.add(points, to: path, using: toView) }
            Self.stroke(path, in: ctx, alpha: line * dashes, running: now - run.began)
        }
        if solid > 0.01, along > 0, !run.outline.isEmpty {
            // The cut: solid round the subject as far as it has come, only where the layer shows.
            let pictureToView = look.pictureToView
            var frameToView = look.toView
            ctx.saveGState()
            if let frame = Renderer.outline(of: look.node).copy(using: &frameToView) {
                ctx.addPath(frame.union(frame.copy(strokingWithWidth: 3, lineCap: .butt, lineJoin: .miter, miterLimit: 4)))
                ctx.clip()
            }
            let e = Self.inOut(along)
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
            Self.stroke(path, in: ctx, alpha: line * solid, running: nil)
            ctx.restoreGState()
        }
        return true
    }

    /// What was cut off dropping away, `t` of the way: the layer as it showed, less the subject,
    /// let go downwards, turning a little as a piece of paper does and fading, behind the subject
    /// standing where it was.
    private func dropping(_ run: Run, _ look: Look, _ t: Double, _ ctx: CGContext) {
        guard let whole = run.whole, let left = run.cut?.left, look.node.transform3D == nil else { return }
        let size = look.frame.size
        // Falling as things do, ever faster, straight down the screen however the layer is turned.
        let fallen = CGSize(width: 0, height: CutoutMotion.fall * t * t).applying(look.toView.inverted())
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(look.toView)
        ctx.addPath(Renderer.outline(of: look.node))
        ctx.clip(using: look.node.evenOdd == true ? .evenOdd : .winding)
        ctx.interpolationQuality = .high
        func show(_ image: CGImage) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(1 - t * t) * CGFloat(look.node.opacity))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.translateBy(x: fallen.width + size.width / 2, y: fallen.height + size.height / 2)
        ctx.rotate(by: Geometry.radians(run.turn * CutoutMotion.turn * t * t))
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        show(whole)
        ctx.setBlendMode(.destinationOut)
        show(left)
        ctx.restoreGState()
        // Nothing of it over the subject, which stands in front.
        ctx.setBlendMode(.destinationOut)
        show(left)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // The subject as it stands, for the moment the canvas takes to draw the layer anew:
        // through the first half of the drop, then given over to the canvas.
        if look.node.opacity >= 1, look.node.blend == nil, look.node.blur == nil {
            ctx.setAlpha(1 - Self.inOut((t - 0.5) / 0.5))
            show(left)
        }
    }

    /// Has the layer drawn as it shows whole and as it will with `cutout`, away from the main
    /// thread, while the line pulls tight and the cut runs round. Drawing them reads the cutout
    /// at the size the canvas will ask for, so that is ready too.
    private func prepare(_ id: UUID, _ run: inout Run, cutout: Cutout?, scale: CGFloat) {
        guard let cutout else { return }
        let before = run.before, began = run.began, zoom = run.look.viewport.zoom, assets = store.assets
        var after = before
        after.fill.image?.cutout = cutout
        run.after = after
        Task.detached(priority: .userInitiated) { [weak self, after] in
            let whole = Sent(Self.picture(of: before, zoom: zoom, scale: scale, assets: assets))
            let left = Sent(Self.picture(of: after, zoom: zoom, scale: scale, assets: assets))
            await MainActor.run {
                guard let self, self.runs[id]?.began == began, self.runs[id]?.cut == nil else { return }
                self.runs[id]?.whole = whole.value
                self.runs[id]?.left = left.value
            }
        }
    }

    /// The layer as it shows, without its border, shadows, opacity and turn: what is cut, and
    /// what the cut leaves of it.
    nonisolated private static func picture(of node: Node, zoom: CGFloat, scale: CGFloat, assets: Assets) -> CGImage? {
        guard node.frame.width > 0, node.frame.height > 0 else { return nil }
        // As many pixels as it has on screen, and no more than a large screen's worth.
        var pixels = zoom * scale
        pixels = min(pixels, (6_000_000 / (node.frame.width * node.frame.height)).squareRoot())
        let size = CGSize(width: max(1, (node.frame.width * pixels).rounded()), height: max(1, (node.frame.height * pixels).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
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
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / node.frame.width, y: -size.height / node.frame.height)
        ctx.interpolationQuality = .high
        Renderer.withFlippedContext(ctx) {
            Renderer.drawNode(plain, in: ctx, options: Renderer.Options(deviceScale: pixels, assets: assets))
        }
        return ctx.makeImage()
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
        guard let id = store.editingPicture, working || store.cuttingOut[id] == nil, let look = look(id), let cutout = look.image.cutout else { return nil }
        return (id, look, cutout, subjects(of: look.image.asset))
    }

    private func subjects(of asset: String) -> CutoutMaker.Subjects? {
        if let found = parts[asset] { return found }
        guard !looking.contains(asset), let picture = store.assets.image(asset, pixels: 1024) else { return nil }
        looking.insert(asset)
        let sent = Sent(picture)
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = try? CutoutMaker.subjects(of: sent.value)
            await MainActor.run {
                // None found stays looked for, so it is not looked for again.
                if let found { self?.parts[asset] = found }
                self?.redraw()
            }
        }
        return nil
    }

    nonisolated private struct Sent<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Which parts the cutout keeps: those its picks are on, or all of them.
    private func kept(_ subjects: CutoutMaker.Subjects, _ cutout: Cutout) -> Set<Int> {
        guard let picks = cutout.picks, !picks.isEmpty else { return Set(subjects.parts.indices) }
        return Set(picks.compactMap { subjects.part(at: $0) })
    }

    /// The part under the pointer, while a cut-out picture is placed.
    func hover(at v: CGPoint?) {
        var now: Int?
        if let v, let (_, look, _, subjects) = pickable(), let subjects {
            now = subjects.part(at: v.applying(look.pictureToView.inverted()))
        }
        if now != hovered {
            hovered = now
            redraw()
        }
    }

    /// A click on the picture being placed: the part there kept or dropped, once it is clear the
    /// click is not the first of a double click, which ends placing.
    func click(at v: CGPoint) {
        pending?.cancel()
        guard let (id, look, cutout, subjects) = pickable(), let subjects,
              let part = subjects.part(at: v.applying(look.pictureToView.inverted())) else { return }
        var keep = kept(subjects, cutout)
        if keep.contains(part) { keep.remove(part) } else { keep.insert(part) }
        guard !keep.isEmpty else { return }
        let picks = keep.count == subjects.parts.count ? nil : keep.sorted().map { subjects.parts[$0].point }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.store.editingPicture == id else { return }
                self.changing = part
                Task {
                    do { try await self.store.cutOut([id], picks: picks) } catch { self.store.trouble(error) }
                    self.changing = nil
                    self.redraw()
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// While a cut-out picture is placed: its background faint inside the layer, the parts kept
    /// traced in pencil, the one under the pointer clearly, filled with pencil if it is to be kept.
    /// A part just clicked is drawn round as a line to cut along, its dashes running, until the
    /// picture has been cut out again with or without it.
    private func picking(_ ctx: CGContext, _ now: CFTimeInterval) {
        guard let (id, look, cutout, subjects) = pickable(working: true) else { return }
        let working = store.cuttingOut[id] != nil
        let pixels = max(look.frame.width, look.frame.height) * look.viewport.zoom * 2
        if let picture = store.assets.image(look.image.asset, pixels: pixels), let cut = store.assets.image(cutout.asset, pixels: pixels) {
            inPicture(look, ctx) {
                ctx.setAlpha(0.42)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                Self.drawUnit(picture, ctx)
                ctx.setBlendMode(.destinationOut)
                Self.drawUnit(cut, ctx)
                ctx.endTransparencyLayer()
            }
        }
        guard let subjects else { return }
        let keep = kept(subjects, cutout)
        var toView = look.pictureToView
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineJoin(.round)
        let hovered = working ? nil : hovered
        for (i, part) in subjects.parts.enumerated() where keep.contains(i) || i == hovered || (working && i == changing) {
            guard let outline = part.outline.copy(using: &toView) else { continue }
            if i == hovered && !keep.contains(i) {
                ctx.addPath(outline)
                ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.16).cgColor)
                ctx.fillPath(using: .evenOdd)
            }
            if working && i == changing {
                Self.stroke(outline, in: ctx, alpha: 1, running: now)
                continue
            }
            ctx.addPath(outline)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(i == hovered ? 1 : 0.4).cgColor)
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
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setAlpha(alpha)
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1.5)
        if let phase { ctx.setLineDash(phase: phase, lengths: [6, 5]) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - min(max(t, 0), 1), 3)) }

    /// Setting off slowly and arriving slowly.
    private static func inOut(_ t: Double) -> CGFloat { CGFloat(0.5 - 0.5 * cos(min(max(t, 0), 1) * .pi)) }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    /// What `draw` fills in white, as the cells of a layer `size` big: a value a cell, row by row
    /// from the top, drawn in the layer's own coordinates.
    private static func cells(_ w: Int, _ h: Int, of size: CGSize, _ draw: (CGContext) -> Void) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: CGFloat(w) / max(size.width, 0.0001), y: -CGFloat(h) / max(size.height, 0.0001))
            ctx.setFillColor(gray: 1, alpha: 1)
            draw(ctx)
            return true
        }
        return drawn ? bytes : nil
    }

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
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if line.count >= 3 { lines.append(line) }
                line = [e.points[0]]
            case .addLineToPoint:
                line.append(e.points[0])
            case .addQuadCurveToPoint:
                line.append(e.points[1])
            case .addCurveToPoint:
                line.append(e.points[2])
            case .closeSubpath:
                if line.count >= 3 { lines.append(line) }
                line = []
            @unknown default:
                break
            }
        }
        if line.count >= 3 { lines.append(line) }
        return lines
    }
}
