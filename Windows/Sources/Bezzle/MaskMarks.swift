import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// What the Mac's MaskTool draws over the design (Canvas/MaskTool.swift), drawn as it draws it:
///
/// - Something being dragged, resting over a shape: a line runs round the shape's outline as the
///   moment passes (0.9 s), from where the outline begins, stronger and glowing as it closes, over
///   the faint whole of it.
/// - The shape opened, or a mask shown made from the word offered: its outline glows, breathing
///   (every 1.6 s), and what it cuts off fades to a ghost (30%) where it reaches past the outline;
///   its name under it ("Into …").
/// - Something picked inside a mask: the mask's outline in pencil and the ghost of what it cuts
///   off, to take hold of; dragged wholly off it, the outline dashed, the ghost almost whole (85%),
///   and "Out of …" under it.
/// - An outline drawn once as something sinks into a mask (drawing in a little, as a breath taken)
///   or comes out of it (growing a little as it goes), over half a second.
///
/// The ghosts' strength is on the Mac's spring (240, 26), the glow's on its own (320, 22). Shown
/// made from the word offered, the mask goes only once what it cut off has grown back whole.
@MainActor
final class MaskMarks {
    /// Over the artboards, under the selection and every other mark.
    let layer = Canvas()
    private let lines = Canvas()
    private var images: [(image: Image, bitmap: WriteableBitmap?, key: Int?)] = []

    /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage, which is
    /// `size` big, `scale` pixels to its point.
    var view: () -> (zoom: Double, pan: CGPoint, size: CGSize, scale: Double) = { (1, .zero, .zero, 1) }
    /// What is under way on the canvas: what is selected, the shape rested on and since when,
    /// the mask opened in a drag and the shape it is made of, the mask what is dragged lies
    /// wholly off, and whether a text is being typed into.
    var state: () -> (selection: [UUID], waiting: (over: UUID, since: Double)?, opened: (shape: UUID, mask: UUID)?, leaving: UUID?, typing: Bool) = {
        ([], nil, nil, nil, false)
    }
    /// The mask shown made from the word offered was taken away: the design shows as it is again.
    var unwound: () -> Void = {}

    private struct Ghost {
        var ids: [UUID]
        var alpha: DeckSpring
    }
    private var ghost: Ghost?
    private var fading: [Ghost] = []
    private var glow = DeckSpring(0)
    private var glowing: UUID?
    private let began = WindowsCore.now

    /// The mask shown made from the word offered, and whether it is on its way back.
    private var previewing: WindowsCore.MaskOffer?
    private var unwinding = false

    /// Outlines drawn once, running in or out: as they were on the canvas, from when.
    private var rings: [(outline: String, born: Double, out: Bool)] = []
    private static let ringTime = 0.5
    private static let rest = 0.9
    /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower,
    /// the rest over a shape too.
    static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1
    private static let ghostLevel = 0.3
    private static let leavingLevel = 0.85

    private var ticking: EventCleanup?
    private var lastTick = 0.0
    private var dt = 1.0 / 60

    init() {
        layer.isHitTestVisible = false
        lines.isHitTestVisible = false
        for _ in 0..<3 {
            let image = Image()
            image.isHitTestVisible = false
            image.stretch = .fill
            image.visibility = .collapsed
            layer.children.append(image)
            images.append((image, nil, nil))
        }
        layer.children.append(lines)
    }

    /// Whether anything is on its way, for drawing again next frame.
    private var animating: Bool {
        let s = state()
        if s.opened != nil || s.waiting != nil || s.leaving != nil || previewing != nil { return true }
        return ghost?.alpha.settled == false || !fading.isEmpty || !glow.settled || !rings.isEmpty
    }

    // MARK: What happens

    /// An outline drawn once over the mask: in, as something sinks into it, or out, as it is let go.
    func ring(_ mask: UUID, out: Bool) {
        guard let outline = WindowsCore.canvasOutline(of: mask) else { return }
        rings.append((outline, WindowsCore.now, out))
        update()
    }

    /// The shape rested on has opened: what was showing whole a moment ago fades from there, and
    /// it begins to glow.
    func opened(holding ids: [UUID]) {
        ghost = Ghost(ids: ids, alpha: DeckSpring(1))
        glow = DeckSpring(0)
        glow.target = 1
        update()
    }

    /// Dragged off the shape it opened, it closes: its outline runs out once.
    func closed(_ mask: UUID) {
        ring(mask, out: true)
        ghost = nil
        glow.target = 0
        update()
    }

    /// The word offered pointed at (or no longer): the mask shows made, what it would cut off
    /// fading away; let go, what it cut off grows back whole, and only then is it taken away.
    func preview(_ offer: WindowsCore.MaskOffer, _ on: Bool) {
        if on {
            unwinding = false
            if previewing != offer {
                previewing = offer
                WindowsCore.previewOffer(offer, true)
                ghost = Ghost(ids: offer.held, alpha: DeckSpring(1))
            }
            ghost?.alpha.target = Self.ghostLevel
            glow.target = 1
        } else if previewing == offer {
            unwinding = true
            ghost?.alpha.target = 1
            glow.target = 0
        }
        update()
    }

    /// The mask shown made has been made, or taken away by something else: no longer shown.
    func previewEnded() {
        previewing = nil
        unwinding = false
        glow.target = 0
    }

    /// Made from the word offered: what was cut off sinks in, and its outline draws in once.
    func committed(_ mask: UUID) {
        previewEnded()
        ring(mask, out: false)
    }

    // MARK: Drawing

    /// Draws them as they now are, and frame by frame while anything is on its way.
    func update() {
        draw()
        guard ticking == nil, animating else { return }
        lastTick = WindowsCore.now
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = WindowsCore.now
                self.dt = min(max(now - self.lastTick, 1.0 / 240), 1.0 / 20) / Self.slow
                self.lastTick = now
                self.draw()
                if !self.animating {
                    self.ticking?.dispose()
                    self.ticking = nil
                    self.draw()
                }
            }
        }
    }

    /// The ghost that should show now, and how much of it (the Mac's aimGhost).
    private func aimGhost(_ s: (selection: [UUID], waiting: (over: UUID, since: Double)?, opened: (shape: UUID, mask: UUID)?, leaving: UUID?, typing: Bool)) {
        // Taken away by something else, such as another pick: gone with it.
        if previewing != nil, !WindowsCore.previewing {
            previewing = nil
            unwinding = false
            ghost = nil
        }
        var wanted: (ids: [UUID], level: Double)?
        if let plan = previewing {
            wanted = (plan.held, unwinding ? 1 : Self.ghostLevel)
        } else if s.opened != nil {
            wanted = (s.selection, Self.ghostLevel)
        } else if !s.typing, WindowsCore.maskPicked(s.selection) != nil {
            wanted = (s.selection, s.leaving != nil ? Self.leavingLevel : Self.ghostLevel)
        }
        if let wanted, let g = ghost, Set(g.ids) == Set(wanted.ids) {
            ghost?.alpha.target = wanted.level
        } else {
            if var g = ghost {
                g.alpha.target = 0
                fading.append(g)
            }
            ghost = wanted.map { w in
                // What was hidden fades in.
                var a = DeckSpring(0)
                a.target = w.level
                return Ghost(ids: w.ids, alpha: a)
            }
        }
        ghost?.alpha.step(dt, stiffness: 240, damping: 26)
        for i in fading.indices { fading[i].alpha.step(dt, stiffness: 240, damping: 26) }
        fading.removeAll { $0.alpha.settled }
        if fading.count > images.count - 1 { fading.removeFirst(fading.count - (images.count - 1)) }
    }

    private func draw() {
        let s = state()
        let v = view()
        let now = WindowsCore.now
        aimGhost(s)
        lines.children.clear()

        // The ghosts: what reaches past the mask's outline, faded.
        var used: Set<Int> = []
        for g in fading + (ghost.map { [$0] } ?? []) {
            let alpha = min(max(g.alpha.value, 0), 1)
            guard alpha > 0.01, let key = WindowsCore.maskGhostKey(g.ids, zoom: v.zoom, pan: v.pan) else { continue }
            var slot: Int?
            for k in images.indices where !used.contains(k) && images[k].key == key { slot = k; break }
            if slot == nil { slot = images.indices.first { !used.contains($0) } }
            guard let k = slot else { continue }
            used.insert(k)
            if images[k].key != key {
                var bitmap = images[k].bitmap
                let covered = WindowsCore.maskGhost(g.ids, scale: v.scale, zoom: v.zoom, pan: v.pan, stage: v.size) { width, height in
                    if bitmap == nil || bitmap!.pixelWidth != Int32(width) || bitmap!.pixelHeight != Int32(height) {
                        bitmap = WriteableBitmap(Int32(width), Int32(height))
                    }
                    return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
                }
                guard let covered else { images[k].key = nil; continue }
                try? bitmap?.invalidate()
                if images[k].bitmap !== bitmap { images[k].image.source = bitmap }
                images[k].bitmap = bitmap
                images[k].key = key
                try? Canvas.setLeft(images[k].image, Double(covered.minX))
                try? Canvas.setTop(images[k].image, Double(covered.minY))
                images[k].image.width = Double(covered.width)
                images[k].image.height = Double(covered.height)
            }
            images[k].image.opacity = alpha
            images[k].image.visibility = .visible
        }
        for k in images.indices where !used.contains(k) { images[k].image.visibility = .collapsed }

        // The mask opened or shown made, glowing; one something is picked in, outlined.
        glow.step(dt, stiffness: 320, damping: 22)
        let breath = 0.5 + 0.5 * sin((now - began) / Self.slow * 2 * .pi / 1.6)
        var glowing: UUID?
        if let opened = s.opened {
            glowing = opened.mask
        } else if let plan = previewing, let first = plan.held.first {
            glowing = WindowsCore.mask(holding: first)
        }
        if let glowing, let o = outline(glowing, v) {
            drawGlow(o.data, strength: glow.value, breath: breath)
        } else if !s.typing, let mask = WindowsCore.maskPicked(s.selection), let o = outline(mask, v) {
            let leaving = s.leaving != nil
            stroke(o.data, Theme.brush(Theme.selection, leaving ? 0.45 : 1), 1.5, dash: leaving ? [4 / 1.5, 3 / 1.5] : nil)
        }

        // Resting over a shape: a line runs round it, and once it closes the shape opens.
        if s.opened == nil, let w = s.waiting, let o = outline(w.over, v) {
            drawRest(o.data, length: o.length, progress: min((now - w.since) / (Self.rest * Self.slow), 1))
        }

        drawRings(v, now)

        if let opened = s.opened, let o = outline(opened.mask, v), let name = WindowsCore.maskName(opened.mask, shape: opened.shape) {
            label(Words.t("Into %@", name), under: o.box, v)
        } else if let mask = s.leaving, let o = outline(mask, v), let name = WindowsCore.maskName(mask) {
            label(Words.t("Out of %@", name), under: o.box, v)
        }

        // Grown back whole: the mask shown made goes.
        if unwinding, let g = ghost, g.alpha.value > 0.97 {
            unwinding = false
            previewing = nil
            ghost = nil
            if WindowsCore.endPreview() { unwound() }
        }
    }

    private func outline(_ id: UUID, _ v: (zoom: Double, pan: CGPoint, size: CGSize, scale: Double)) -> (data: String, box: CGRect, length: Double)? {
        WindowsCore.canvasOutline(of: id).flatMap { WindowsCore.stageOutline($0, zoom: v.zoom, pan: v.pan) }
    }

    /// The glow: soft strokes widening round the outline as the Mac's blurred shadow does, more
    /// as it breathes, under a firm line of pencil.
    private func drawGlow(_ data: String, strength: Double, breath: Double) {
        let k = min(max(strength, 0), 1.2)
        guard k > 0.01 else { return }
        let blur = (6 + 8 * breath) * k, strong = min(k, 1)
        // Many faint strokes, each a little wider, adding up to a falloff with no edge to it.
        let steps = 8
        for i in stride(from: steps, through: 1, by: -1) {
            let spread = Double(i) / Double(steps)
            stroke(data, Theme.brush(Theme.selection, 0.055 * strong), 2 + 2 * k + 2 * blur * spread)
        }
        stroke(data, Theme.brush(Theme.selection, 0.55 * strong), 2 + 2 * k)
        stroke(data, Theme.brush(Theme.selection, strong), 2)
    }

    /// The outline drawn round from its start as far as the rest has come, `progress` of the way,
    /// glowing more as it closes, about to open.
    private func drawRest(_ data: String, length: Double, progress: Double) {
        guard length > 0 else { return }
        let eased = 1 - pow(1 - progress, 2)
        stroke(data, Theme.brush(Theme.selection, 0.18), 1)
        let width = 2 + eased
        for (extra, alpha) in [(8.0, 0.1), (4.0, 0.16)] where eased > 0.05 {
            let w = width + extra * eased
            stroke(data, Theme.brush(Theme.selection, alpha * eased), w, dash: [max(length * eased, 0.01) / w, (length + 1) / w], round: true)
        }
        stroke(data, Theme.brush(Theme.selection, 0.5 + 0.5 * eased), width, dash: [max(length * eased, 0.01) / width, (length + 1) / width], round: true)
    }

    /// Each ring as far as it has come: out, it grows a little and goes; in, it draws in a little.
    private func drawRings(_ v: (zoom: Double, pan: CGPoint, size: CGSize, scale: Double), _ now: Double) {
        rings.removeAll { now - $0.born > Self.ringTime * Self.slow }
        for r in rings {
            let t = min((now - r.born) / (Self.ringTime * Self.slow), 1)
            let eased = 1 - pow(1 - t, 3)
            let grown = r.out ? 1 + 0.08 * eased : 1 - 0.05 * eased
            guard let o = WindowsCore.stageOutline(r.outline, grown: grown, zoom: v.zoom, pan: v.pan) else { continue }
            stroke(o.data, Theme.brush(Theme.selection, 0.75 * (1 - eased)), r.out ? 2 : 4 - 2.5 * eased)
        }
    }

    /// A name in a pencil pill, 12 under what it is about (over it, when that would leave the
    /// canvas), kept on the canvas.
    private func label(_ text: String, under r: CGRect, _ v: (zoom: Double, pan: CGPoint, size: CGSize, scale: Double)) {
        let pill = Border()
        pill.height = 22
        pill.cornerRadius = Theme.corners(7)
        pill.background = Theme.brush(Theme.selection)
        let words = Theme.text(text, size: 11.5, weight: 500)
        words.foreground = Theme.brush(0xFFFFFF)
        words.verticalAlignment = .center
        words.margin = Theme.inset(9, 0, 9, 0)
        pill.child = words
        try? pill.measure(Size(width: 600, height: 22))
        let w = Double(pill.desiredSize.width)
        var x = (Double(r.midX) - w / 2).rounded(), y = (Double(r.maxY) + 12).rounded()
        x = min(max(x, 8), max(8, Double(v.size.width) - w - 8))
        if y + 22 > Double(v.size.height) - 8 { y = max(8, (Double(r.minY) - 34).rounded()) }
        // A soft shadow under it.
        let shade = Border()
        shade.width = w + 2
        shade.height = 24
        shade.cornerRadius = Theme.corners(8)
        shade.background = Theme.brush(0, 0.14)
        try? Canvas.setLeft(shade, x - 1)
        try? Canvas.setTop(shade, y + 0.5)
        lines.children.append(shade)
        try? Canvas.setLeft(pill, x)
        try? Canvas.setTop(pill, y)
        lines.children.append(pill)
    }

    private func stroke(_ data: String, _ brush: Brush, _ width: Double, dash: [Double]? = nil, round: Bool = false) {
        guard !data.isEmpty, let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)'/>")) as? WinUI.Path else { return }
        path.stroke = brush
        path.strokeThickness = width
        path.strokeLineJoin = .round
        if let dash {
            let d = DoubleCollection()
            for v in dash { d.append(v) }
            path.strokeDashArray = d
        }
        if round {
            path.strokeStartLineCap = .round
            path.strokeEndLineCap = .round
            path.strokeDashCap = .round
        }
        lines.children.append(path)
    }
}
