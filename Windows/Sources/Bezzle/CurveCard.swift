import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The Curve card, as the Mac's CurveCard: texts along a curve.
///
/// Bent, the drag bends them, from a dip through straight to a ring, the picks are the bends worth
/// having, and the degrees say exactly how far round a circle they go; pulled past a full dip
/// they are straight again. Riding a shape, the drag slides them round its outline, the arrows
/// send them to its other side, and taken away, they come off it.
extension Inspector {
    func curveCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard let c = WindowsCore.curveLook(ids) else { return nil }
        @MainActor func edited() { session.edited(board: board) }
        if c.riding {
            let several = Words.t("Several")
            let dial = Dial(fraction: c.at, set: { WindowsCore.slide(ids, at: ($0 * 100).rounded() / 100) },
                            summary: { _ in c.shape ?? several }, stops: [0, 0.25, 0.5, 0.75, 1])
            let flip = Controls.iconButton(Glyphs.bothWays(across: false), size: 22) { WindowsCore.flipCurves(ids); edited() }
            try? ToolTipService.setToolTip(flip, Words.t("To the other side"))
            // Its press is its own, not the card's line's, which would fold the card.
            flip.pointerPressed.addHandler { _, args in args?.handled = true }
            return card("On Path", c.shape ?? several, mark: Glyphs.view(Glyphs.riding(), size: 15, brush: Theme.ink(2)), dial: dial,
                        remove: { WindowsCore.straighten(ids); edited() }, removal: "Take off path", accessory: flip)
        }
        // The drag runs from a full dip (−100) through straight (0) to a ring (100), in fives.
        func bend(_ f: Double) -> Double { ((f * 2 - 1) * 20).rounded() / 20 }
        let dial = Dial(fraction: (c.bend + 1) / 2, set: { WindowsCore.bend(ids, to: bend($0)) },
                        summary: { WindowsCore.curveSummary(bend($0)) }, stops: [0, 0.25, 0.5, 0.75, 1])
        return card("Curve", c.same ? WindowsCore.curveSummary(c.bend) : Words.t("Several"),
                    mark: Glyphs.view(Glyphs.curve(bend: c.bend), size: 15, brush: Theme.ink(2)), dial: dial,
                    remove: { WindowsCore.straighten(ids); edited() }, removal: "Straighten", body: { [self] in
            let bends = WindowsCore.curveBends
            let picks = Controls.presetStrip(bends.map { b in
                (Glyphs.view(Glyphs.curve(bend: b.bend), size: 15, brush: Theme.ink(2)), c.same && abs(c.bend - b.bend) < 0.0005)
            }, width: Theme.cardWidth - 24 - 72, point: { k in
                WindowsCore.previewBend(ids, k.map { bends[$0].bend })
                session.previewed(board: board)
            }, choose: { k in
                WindowsCore.bend(ids, to: bends[k].bend)
                edited()
            })
            let degrees = field("", c.same ? (c.bend * 360).rounded() : nil, unit: "°", range: -360...360, scrub: 1, width: 64) { v in
                WindowsCore.bend(ids, to: v / 360)
                edited()
            }
            let line = StackPanel()
            line.orientation = .horizontal
            line.spacing = 8
            line.children.append(picks)
            line.children.append(degrees)
            return [line]
        })
    }
}

extension Glyphs {
    /// A line of letters, bent as far as the words are, as the Mac's CurveGlyph: short strokes
    /// along an arc, as a line of type is drawn small.
    static func curve(bend: Double, size s: Double = 15) -> [Part] {
        let theta = min(abs(bend), 1) * 2 * .pi
        var arc: [(Double, Double)] = []
        if theta < 0.05 {
            arc = [(0, 0), (1, 0)]
        } else {
            let up: Double = bend > 0 ? 1 : -1
            for i in 0...48 {
                let phi = -theta / 2 + theta * Double(i) / 48
                arc.append((sin(phi), -up * cos(phi)))
            }
        }
        let xs = arc.map(\.0), ys = arc.map(\.1)
        let box = (x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
        let width = 2.3, inset = width / 2 + 0.4
        let room = (w: s - inset * 2, h: s - inset * 2)
        let k = min(room.w / max(box.w, 0.001), box.h > 0.001 ? room.h / box.h : .greatestFiniteMagnitude)
        let points = arc.map { (s / 2 + ($0.0 - (box.x + box.w / 2)) * k, s / 2 + ($0.1 - (box.y + box.h / 2)) * k) }
        return [Part(data: dashes(along: points, on: 1.9, off: 1.1), mode: .stroke, width: width, round: false)]
    }

    /// A shape's outline with a line of letters lying along its top: words riding a shape, as the
    /// Mac's RidingGlyph.
    static func riding(size s: Double = 15) -> [Part] {
        let r = (x: 4.0, y: 4.0 + 1.6, w: s - 8, h: s - 8)
        var ring = PathData()
        ring.ellipse(r.x, r.y, r.w, r.h)
        let c = (x: r.x + r.w / 2, y: r.y + r.h / 2), radius = r.w / 2 + 1.9
        let arc = (0...30).map { i -> (Double, Double) in
            let a = (-165 + 150 * Double(i) / 30) * .pi / 180
            return (c.x + radius * cos(a), c.y + radius * sin(a))
        }
        return [Part(data: ring.d, mode: .stroke, width: 1),
                Part(data: dashes(along: arc, on: 1.8, off: 1.1), mode: .stroke, width: 2.1, round: false)]
    }

    /// Path data for dashes `on` long with gaps `off` along a line through `points`.
    private static func dashes(along points: [(Double, Double)], on: Double, off: Double) -> String {
        var p = PathData()
        var drawing = true, left = on
        var pen = false
        for i in 1..<max(points.count, 1) {
            var a = points[i - 1]
            let b = points[i]
            var span = hypot(b.0 - a.0, b.1 - a.1)
            while span > 0 {
                let step = min(span, left)
                let t = step / span
                let q = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
                if drawing {
                    if !pen { p.move(a.0, a.1); pen = true }
                    p.line(q.0, q.1)
                }
                span -= step
                left -= step
                a = q
                if left <= 1e-9 {
                    drawing.toggle()
                    left = drawing ? on : off
                    pen = false
                }
            }
        }
        return p.d
    }
}
