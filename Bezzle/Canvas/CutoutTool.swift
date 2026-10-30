import AppKit

/// What the canvas shows of cutting out a picture: the work as it goes, and picking subjects.
///
/// While a picture is cut out, the pencil goes over it. A pencil line sweeps across while Vision
/// looks; once the subject is found, it is traced in pencil and the rest of the picture sinks into
/// the table; when the cutout is made, the background melts away from the subject outwards, until
/// only the subject is left, standing on whatever is behind it.
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

    /// One picture being cut out, as the canvas shows it, until it has melted away or faded.
    private struct Run {
        var look: Look
        /// The picture the layer showed as it began: the photo, or an earlier cutout of it.
        let shown: String
        let began: CFTimeInterval
        /// The background, white where the subject was not found; and the subject's edge, white
        /// in a narrow line round it.
        var background: CGImage?
        var edge: CGImage?
        var foundAt: CFTimeInterval?
        /// The subject's middle, across and down the picture.
        var middle = CGPoint(x: 0.5, y: 0.5)
        /// When it ended, and whether with a cutout to melt into.
        var ended: (at: CFTimeInterval, made: Bool)?
    }

    private var runs: [UUID: Run] = [:]
    private static let sweep: CFTimeInterval = 1.15
    private static let trace: CFTimeInterval = 0.35
    private static let melt: CFTimeInterval = 0.62
    private static let fade: CFTimeInterval = 0.24

    /// Whether the canvas has to draw again soon, for something moving here.
    var animating: Bool { !runs.isEmpty || !store.cuttingOut.isEmpty }

    func draw(_ ctx: CGContext, scale: CGFloat) {
        let now = CACurrentMediaTime()
        for (id, work) in store.cuttingOut {
            if runs[id] == nil || runs[id]?.ended != nil, let look = look(id) {
                runs[id] = Run(look: look, shown: look.image.shown, began: now)
            }
            guard var run = runs[id] else { continue }
            if let look = look(id) { run.look = look }
            if run.foundAt == nil, let found = work.found {
                run.background = Self.inverted(found)
                run.edge = Self.edge(of: found)
                run.middle = Self.middle(of: found)
                run.foundAt = now
            }
            runs[id] = run
        }
        for (id, run) in runs where run.ended == nil && store.cuttingOut[id] == nil {
            let image = store.node(id)?.fill.image
            runs[id]?.ended = (now, image?.cutout != nil && image?.shown != run.shown)
        }
        for (id, run) in runs {
            let look = look(id) ?? run.look
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
        picking(ctx)
    }

    /// While it works: the pencil sweeping across, and once the subject is found, it traced in
    /// pencil and the rest sunk into the table.
    private func working(_ run: Run, _ look: Look, _ now: CFTimeInterval, alpha: CGFloat, _ ctx: CGContext) {
        let shown = Self.ease(min((now - run.began) / 0.2, 1))
        let traced = run.foundAt.map { Self.ease(min((now - $0) / Self.trace, 1)) } ?? 0
        inPicture(look, ctx) {
            ctx.setAlpha(alpha * shown)
            if traced < 1 { sweeping(look, (now - run.began) / Self.sweep, alpha: 1 - traced, ctx) }
            if let background = run.background { sinking(background, alpha: traced, ctx) }
            if let edge = run.edge {
                // Alive while it works on: the line breathes.
                let breath = 0.72 + 0.28 * cos((now - (run.foundAt ?? now)) * 2 * .pi / 1.3)
                tracing(edge, alpha: traced * CGFloat(breath), ctx)
            }
        }
    }

    /// Done: the picture as it was melts away from the subject's middle outwards, leaving the cutout.
    private func melting(_ run: Run, _ look: Look, _ t: CGFloat, _ now: CFTimeInterval, _ ctx: CGContext) {
        let e = 1 - pow(1 - t, 3)
        let pixels = max(look.frame.width, look.frame.height) * look.viewport.zoom * 2
        inPicture(look, ctx) {
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            if let picture = store.assets.image(run.shown, pixels: pixels) { Self.drawUnit(picture, ctx) }
            if let background = run.background { sinking(background, alpha: 1, ctx) }
            // Cleared from the middle out, softly at the edge of what is cleared.
            let c = run.middle
            let far = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 1
            let radius = max(far * 1.3 * e, 0.0001)
            if let clear = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                                      locations: [0, 0.62, 1]) {
                ctx.setBlendMode(.destinationOut)
                ctx.drawRadialGradient(clear, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
            }
            ctx.endTransparencyLayer()
            if let edge = run.edge { tracing(edge, alpha: 1 - e, ctx) }
        }
    }

    /// A pencil line going across the picture, a wash of pencil trailing it, `phase` sweeps along.
    private func sweeping(_ look: Look, _ phase: Double, alpha: CGFloat, _ ctx: CGContext) {
        guard alpha > 0 else { return }
        let along = phase - floor(phase)
        // Easing in and out of each sweep, from just before the picture to just past it.
        let x = CGFloat(-0.15 + 1.3 * (0.5 - 0.5 * cos(along * .pi)))
        let pencil = CanvasInk.pencil
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [pencil.withAlphaComponent(0).cgColor, pencil.withAlphaComponent(0.2).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.clip(to: CGRect(x: x - 0.3, y: 0, width: 0.3, height: 1))
            ctx.drawLinearGradient(wash, start: CGPoint(x: x - 0.3, y: 0), end: CGPoint(x: x, y: 0), options: [])
            ctx.resetClip()
        }
        ctx.setFillColor(pencil.cgColor)
        ctx.fill(CGRect(x: x - look.pointInPicture.width * 0.75, y: 0, width: look.pointInPicture.width * 1.5, height: 1))
        ctx.restoreGState()
    }

    /// Everything but the subject sunk into the table, a little pencil in it.
    private func sinking(_ background: CGImage, alpha: CGFloat, _ ctx: CGContext) {
        guard alpha > 0 else { return }
        ctx.saveGState()
        Self.clipUnit(background, ctx)
        ctx.setFillColor(CanvasInk.table.withAlphaComponent(0.62 * alpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.07 * alpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.restoreGState()
    }

    /// The subject's edge in pencil.
    private func tracing(_ edge: CGImage, alpha: CGFloat, _ ctx: CGContext) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        Self.clipUnit(edge, ctx)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(alpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.restoreGState()
    }

    // MARK: - Picking subjects

    /// Each picture's parts, once found, by its name; and those being looked for, or with none.
    private var parts: [String: CutoutMaker.Subjects] = [:]
    private var looking: Set<String> = []
    private var hovered: Int?
    private var pending: DispatchWorkItem?

    /// The layer whose cut-out picture is being placed, and its parts once found.
    private func pickable() -> (id: UUID, look: Look, cutout: Cutout, subjects: CutoutMaker.Subjects?)? {
        guard let id = store.editingPicture, store.cuttingOut[id] == nil, let look = look(id), let cutout = look.image.cutout else { return nil }
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
                Task {
                    do { try await self.store.cutOut([id], picks: picks) } catch { self.store.trouble(error) }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// While a cut-out picture is placed: its background faint inside the layer, the parts kept
    /// traced in pencil, the one under the pointer clearly, filled with pencil if it is to be kept.
    private func picking(_ ctx: CGContext) {
        guard let (_, look, cutout, subjects) = pickable() else { return }
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
        for (i, part) in subjects.parts.enumerated() where keep.contains(i) || i == hovered {
            guard let outline = part.outline.copy(using: &toView) else { continue }
            if i == hovered && !keep.contains(i) {
                ctx.addPath(outline)
                ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.16).cgColor)
                ctx.fillPath(using: .evenOdd)
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

    /// Drawing kept to where a grey mask is white, across the unit square.
    private static func clipUnit(_ mask: CGImage, _ ctx: CGContext) {
        ctx.translateBy(x: 0, y: 1)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1), mask: mask)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -1)
    }

    private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }

    /// A grey mask the other way round.
    private static func inverted(_ mask: CGImage) -> CGImage? {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for i in 0..<(h * ctx.bytesPerRow) { data[i] = 255 - data[i] }
        return ctx.makeImage()
    }

    /// A narrow line just outside the white of a grey mask, made once: drawn through every frame,
    /// it costs one mask rather than one for each side it is pushed out to.
    private static func edge(of mask: CGImage) -> CGImage? {
        let shrink = min(1, 900 / Double(max(mask.width, mask.height)))
        let w = max(1, Int(Double(mask.width) * shrink)), h = max(1, Int(Double(mask.height) * shrink))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = ctx.bytesPerRow, reach = 2
        let inside = (0..<h).flatMap { y in (0..<w).map { x in data[y * row + x] } }
        // The most solid within reach, across and then down; less what was there.
        var across = inside
        for y in 0..<h {
            for x in 0..<w {
                var most: UInt8 = 0
                for d in -reach...reach where x + d >= 0 && x + d < w { most = max(most, inside[y * w + x + d]) }
                across[y * w + x] = most
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var most: UInt8 = 0
                for d in -reach...reach where y + d >= 0 && y + d < h { most = max(most, across[(y + d) * w + x]) }
                data[y * row + x] = most > inside[y * w + x] ? most - inside[y * w + x] : 0
            }
        }
        return ctx.makeImage()
    }

    /// Where the white of a grey mask is, on the whole, across and down from its top left.
    private static func middle(of mask: CGImage) -> CGPoint {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), w > 0, h > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return CGPoint(x: 0.5, y: 0.5) }
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where data[y * ctx.bytesPerRow + x] > 127 {
                sx += Double(x); sy += Double(y); n += 1
            }
        }
        return n > 0 ? CGPoint(x: (sx / n + 0.5) / Double(w), y: (sy / n + 0.5) / Double(h)) : CGPoint(x: 0.5, y: 0.5)
    }
}
