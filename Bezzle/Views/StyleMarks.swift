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
                WaveView(store: store, wave: wave)
                    .id(wave.token)
            }
            if let offer = show.offer {
                OfferChip(store: store, offer: offer)
                    .id(offer.token)
            }
        }
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

/// A change to a style running out as light over every layer that has it: each lights up as the
/// wave reaches it, the nearest to where the change was made first, and fades.
private struct WaveView: View {
    let store: DocumentStore
    let wave: StyleShow.Wave

    /// How fast it runs over the view, in points a second, and how long each layer stays lit.
    private static let speed: CGFloat = 1500
    private static let rise = 0.11, fall = 0.62
    /// However far apart the layers lie, the last is reached within this.
    private static let longest = 0.55

    var body: some View {
        let doc = store.seenDoc, viewport = store.viewport
        let paths = StyleMarks.outlines(of: wave.layers, in: doc, viewport: viewport)
        GeometryReader { geo in
            let origin = wave.origin.map { viewport.toView($0) } ?? CGPoint(x: geo.size.width + 40, y: geo.size.height / 2)
            let delays = Self.delays(paths, from: origin)
            let end = (delays.max() ?? 0) + Self.rise + Self.fall
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(wave.start)
                Canvas { ctx, size in
                    let pencil = Color(nsColor: CanvasInk.pencil)
                    // The front of the wave itself, faint, so the layers it lights read as one change.
                    let r = CGFloat(t) * Self.speed * Self.scale(delays, paths, origin)
                    let reach = hypot(max(origin.x, size.width - origin.x), max(origin.y, size.height - origin.y))
                    // Ahead of the wave the artboards still look as they did; behind it, the change has
                    // washed in, over a soft edge.
                    for wash in wave.washes where r < Self.far(of: viewport.toView(wash.rect), from: origin) + Self.edge {
                        ctx.drawLayer { layer in
                            layer.clipToLayer(opacity: 1) { mask in
                                mask.fill(Path(CGRect(origin: .zero, size: size)),
                                          with: .radialGradient(SwiftUI.Gradient(colors: [.clear, .black]), center: origin,
                                                                startRadius: max(0, r - Self.edge), endRadius: max(r, 0.01)))
                            }
                            layer.draw(Image(decorative: wash.image, scale: 1), in: viewport.toView(wash.rect))
                        }
                    }
                    if r < reach {
                        let ring = Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
                        let k = 1 - Double(r / reach)
                        ctx.stroke(ring, with: .color(pencil.opacity(0.16 * k)), lineWidth: 1.5)
                        ctx.stroke(ring, with: .color(pencil.opacity(0.05 * k)), lineWidth: 14)
                    }
                    for (path, delay) in zip(paths, delays) {
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
                try? await Task.sleep(for: .seconds(end + 0.05))
                if store.styleShow.wave?.token == wave.token { store.styleShow.wave = nil }
            }
        }
        .allowsHitTesting(false)
    }

    /// How soft the edge the change washes in behind is.
    private static let edge: CGFloat = 36

    /// How far from `origin` the furthest corner of a rectangle is.
    private static func far(of r: CGRect, from origin: CGPoint) -> CGFloat {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
    }

    /// How much the wave is slowed down, or sped up, to reach the furthest layer within `longest`.
    private static func scale(_ delays: [Double], _ paths: [Path], _ origin: CGPoint) -> CGFloat {
        let far = paths.map { distance($0, origin) }.max() ?? 0
        guard far > 0 else { return 1 }
        return max(1, far / speed / CGFloat(longest))
    }

    private static func delays(_ paths: [Path], from origin: CGPoint) -> [Double] {
        let distances = paths.map { distance($0, origin) }
        let far = distances.max() ?? 0
        let k = far / speed > CGFloat(longest) ? CGFloat(longest) / (far / speed) : 1
        return distances.map { Double($0 / speed * k) }
    }

    private static func distance(_ path: Path, _ origin: CGPoint) -> CGFloat {
        let box = path.boundingRect
        let x = min(max(origin.x, box.minX), box.maxX), y = min(max(origin.y, box.minY), box.maxY)
        return hypot(x - origin.x, y - origin.y)
    }

    /// How brightly a layer is lit `t` seconds after the wave reaches it: up quickly, down slowly.
    private static func glow(_ t: Double) -> Double {
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
