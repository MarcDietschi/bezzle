import SwiftUI
import AppKit

/// Over the canvas, in pencil, what the design's named looks reach: every layer that has the style
/// the pointer is on, or that a drag is changing; a change running out over them as light, the
/// nearest first, from where it was made; and what is offered for a moment after one. See `Style`.
struct StyleMarks: View {
    let store: DocumentStore

    var body: some View {
        let show = store.styleShow
        ZStack {
            outlines
            if let wave = show.wave {
                // Never faded in, even when the change comes inside an animation, as the light and
                // dark switch's does: it comes with the change.
                WaveView(store: store, wave: wave)
                    .id(wave.token)
                    .transition(.identity)
            }
            if let offer = show.offer {
                OfferChip(store: store, offer: offer)
                    .id(offer.token)
            }
        }
        // Always as big as the canvas: left to its marks, it shrinks to nothing when there are
        // none, and a wave coming inside an animation would grow out from the middle with it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The layers to outline at rest: of the style pointed at, or of the card pointed at when its
    /// look has a name, but not the selection, which the card's own marks show; those lit by an offer
    /// or a look found without a name; those a drag is changing.
    private var lit: [UUID] {
        let show = store.styleShow
        var ids: [UUID] = show.lit
        var style = show.pointed
        if style == nil, let place = store.pointedAspect?.stylePlace { style = store.sharedStyle(at: place)?.id }
        if let style {
            let mine = Set(show.pointed == nil ? store.selection : [])
            ids += store.layers(using: style).filter { !mine.contains($0) }
        }
        if store.inGesture { for id in show.live { ids += store.layers(using: id) } }
        return ids
    }

    @ViewBuilder private var outlines: some View {
        let ids = lit
        ZStack {
            if !ids.isEmpty {
                let doc = store.seenDoc, viewport = store.viewport
                Canvas { ctx, _ in
                    let pencil = Color(nsColor: CanvasInk.pencil)
                    for path in Self.outlines(of: ids, in: doc, viewport: viewport) {
                        ctx.fill(path, with: .color(pencil.opacity(0.08)))
                        ctx.stroke(path, with: .color(pencil.opacity(0.2)), lineWidth: 5)
                        ctx.stroke(path, with: .color(pencil.opacity(0.9)), lineWidth: 1.25)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: ids)
        .allowsHitTesting(false)
    }

    /// Each layer's outline in the view, as the canvas shows it; nothing for those not shown.
    static func outlines(of ids: [UUID], in doc: BezzleDocument, viewport vp: Viewport) -> [Path] {
        var seen = Set<UUID>()
        return ids.compactMap { id -> Path? in
            guard seen.insert(id).inserted, let node = doc.node(id), !node.hidden else { return nil }
            let o = doc.parentOrigin(of: id)
            let toView = CGAffineTransform(translationX: o.x, y: o.y)
                .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
            return Path(Renderer.placedOutline(of: node)).applying(toView)
        }
    }
}

// MARK: - The wave

/// How a style's wave runs over the view: from where, how fast its front goes, and when it reaches
/// each layer it lights. Ahead of the front the artboards still look as they did, which the canvas
/// draws with the design itself (`CanvasView.drawWashes`), so the change and what hides it until
/// the wave comes always reach the screen together; the marks draw the front and the glows.
struct WaveCourse {
    /// How fast it runs over the view, in points a second, and how long each layer stays lit.
    static let speed: CGFloat = 1500
    static let rise = 0.11, fall = 0.62
    /// However far apart the layers lie, the last is reached within this.
    static let longest = 0.55
    /// How soft the edge the change washes in behind is.
    static let edge: CGFloat = 36

    /// Where it starts, in the view.
    let origin: CGPoint
    /// The layers it lights, in the view, and when it reaches each.
    let paths: [Path]
    let delays: [Double]
    /// How fast its front goes, in points a second.
    let pace: CGFloat

    init(_ wave: StyleShow.Wave, in doc: BezzleDocument, viewport: Viewport, size: CGSize) {
        let paths = StyleMarks.outlines(of: wave.layers, in: doc, viewport: viewport)
        let origin = wave.origin.map { viewport.toView($0) } ?? CGPoint(x: size.width + 40, y: size.height / 2)
        let distances = paths.map { Self.distance($0, origin) }
        let far = distances.max() ?? 0
        // A long way to go is gone faster, so that the last is reached within `longest`.
        let k = far / Self.speed > CGFloat(Self.longest) ? CGFloat(Self.longest) / (far / Self.speed) : 1
        self.paths = paths
        self.origin = origin
        delays = distances.map { Double($0 / Self.speed * k) }
        pace = Self.speed * (far > 0 ? max(1, far / Self.speed / CGFloat(Self.longest)) : 1)
    }

    /// How long it runs: until the last layer it lit has faded again.
    var end: Double { (delays.max() ?? 0) + Self.rise + Self.fall }

    /// How far its front has gone, `t` seconds after it started.
    func radius(at t: Double) -> CGFloat { CGFloat(max(t, 0)) * pace }

    /// Whether some of a rectangle in the view still lies ahead of the front, `r` from the origin.
    func reaches(_ rect: CGRect, at r: CGFloat) -> Bool {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        return r < (corners.map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0) + Self.edge
    }

    /// What of a rectangle in the view lies ahead of the front, `r` from the origin, as a grey mask
    /// `scale` pixels to the point, its first row the rectangle's top: white ahead, black behind,
    /// soft over the edge between.
    func mask(for rect: CGRect, at r: CGFloat, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((rect.width * scale).rounded(.up))), h = max(1, Int((rect.height * scale).rounded(.up)))
        let grey = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: grey,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gradient = CGGradient(colorsSpace: grey, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let kx = CGFloat(w) / max(rect.width, 0.01), ky = CGFloat(h) / max(rect.height, 0.01)
        // The context counts up from the bottom; the mask's first row is the rectangle's top.
        let centre = CGPoint(x: (origin.x - rect.minX) * kx, y: (rect.maxY - origin.y) * ky)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: max(0, r - Self.edge) * kx,
                               endCenter: centre, endRadius: max(r, 0.01) * kx, options: [.drawsBeforeStartLocation])
        return ctx.makeImage()
    }

    private static func distance(_ path: Path, _ origin: CGPoint) -> CGFloat {
        let box = path.boundingRect
        let x = min(max(origin.x, box.minX), box.maxX), y = min(max(origin.y, box.minY), box.maxY)
        return hypot(x - origin.x, y - origin.y)
    }
}

/// A change to a style running out as light over every layer that has it: each lights up as the
/// wave reaches it, the nearest to where the change was made first, and fades.
private struct WaveView: View {
    let store: DocumentStore
    let wave: StyleShow.Wave

    var body: some View {
        let doc = store.seenDoc, viewport = store.viewport
        GeometryReader { geo in
            let course = WaveCourse(wave, in: doc, viewport: viewport, size: geo.size)
            let origin = course.origin
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(wave.start)
                Canvas { ctx, size in
                    let pencil = Color(nsColor: CanvasInk.pencil)
                    // The front of the wave itself, faint, so the layers it lights read as one change.
                    let r = course.radius(at: t)
                    let reach = hypot(max(origin.x, size.width - origin.x), max(origin.y, size.height - origin.y))
                    if r < reach {
                        let ring = Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
                        let k = 1 - Double(r / reach)
                        ctx.stroke(ring, with: .color(pencil.opacity(0.16 * k)), lineWidth: 1.5)
                        ctx.stroke(ring, with: .color(pencil.opacity(0.05 * k)), lineWidth: 14)
                    }
                    for (path, delay) in zip(course.paths, course.delays) {
                        let g = Self.glow(t - delay)
                        guard g > 0.005 else { continue }
                        // A glow round the layer, not over it, so the change itself is what is seen.
                        ctx.stroke(path, with: .color(pencil.opacity(0.14 * g)), lineWidth: 12)
                        ctx.stroke(path, with: .color(pencil.opacity(0.22 * g)), lineWidth: 5)
                        ctx.stroke(path, with: .color(pencil.opacity(0.9 * g)), lineWidth: 1.5)
                    }
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(course.end + 0.05))
                if store.styleShow.wave?.token == wave.token { store.styleShow.wave = nil }
            }
        }
        .allowsHitTesting(false)
    }

    /// How brightly a layer is lit `t` seconds after the wave reaches it: up quickly, down slowly.
    private static func glow(_ t: Double) -> Double {
        let rise = WaveCourse.rise, fall = WaveCourse.fall
        if t <= 0 { return 0 }
        if t < rise { let u = t / rise; return 1 - (1 - u) * (1 - u) }
        let u = (t - rise) / fall
        if u >= 1 { return 0 }
        return pow(1 - u, 2.2)
    }
}

// MARK: - The offer

/// A word over the layer a change was made on, with a button that does what it offers: to keep the
/// change there alone, or to give the new name to the other layers that look the same. Pointing at
/// the button outlines the layers it is about.
private struct OfferChip: View {
    let store: DocumentStore
    let offer: StyleOffer
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        let doc = store.seenDoc, vp = store.viewport
        GeometryReader { geo in
            if store.selection.contains(offer.anchor), store.editingText == nil, let frame = doc.absoluteFrame(of: offer.anchor) {
                let r = vp.toView(frame)
                let above = r.minY - 30 > 8
                HStack(spacing: 8) {
                    Text(verbatim: offer.words)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink)
                        .padding(.leading, 12)
                    Text(verbatim: offer.button)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background { Capsule().fill(Color(nsColor: hovering ? CanvasInk.pencil.blended(withFraction: 0.15, of: .black) ?? CanvasInk.pencil : CanvasInk.pencil)) }
                        .contentShape(Capsule())
                        .onHover { inside in
                            hovering = inside
                            store.styleShow.lit = inside ? offer.layers : []
                        }
                        .onTapGesture {
                            store.styleShow.lit = []
                            withAnimation(Theme.pop) { store.take(offer) }
                        }
                        .padding(.trailing, 4)
                }
                .frame(height: 28)
                .background {
                    Capsule().fill(Theme.card)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }
                .fixedSize()
                .scaleEffect(shown ? 1 : 0.85, anchor: above ? .bottom : .top)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : (above ? 6 : -6))
                .position(x: min(max(r.midX, 120), geo.size.width - 120), y: above ? r.minY - 24 : r.maxY + 24)
                .onAppear { withAnimation(Theme.pop) { shown = true } }
                .onDisappear { if hovering { store.styleShow.lit = [] } }
            }
        }
    }
}
