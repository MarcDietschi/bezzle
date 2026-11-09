import Foundation
import WinUI
import UWP
import BezzleCore

/// The rulers along the canvas's top and left, as the Mac's (Canvas/Rulers.swift): 20 thick, in
/// the table's colour, a lighter sheet where the artboard they measure lies, counted from its
/// corner; a long tick at every number, shorter ones between fading as the view zooms away; the
/// selection a band of pencil with its edges' numbers in pills.
@MainActor
final class Rulers {
    static let thickness = 20.0
    let root = Canvas()
    private let strips = [Strip(across: true), Strip(across: false)]
    private let corner = Border()

    /// The Mac's label steps, the first at least 56 points apart on screen.
    private static let steps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000]
    private static var rulerInk: UInt32 { Theme.ink }
    private static var sheetColour: UInt32 { Theme.rulerSheet }

    private final class Strip {
        let across: Bool
        let box = Canvas()
        let background = Rectangle()
        let sheet = Rectangle()
        let band = Rectangle()
        /// The band's two edges.
        let edges = [Rectangle(), Rectangle()]
        var paths: [UIElement] = []
        var labels: [TextBlock] = []
        var pills: [(box: Border, text: TextBlock)] = []
        /// The scale as last drawn, and where its numbers lie along the strip: drawn again only
        /// when the view moves or zooms, not as a selection moves along it.
        var scale = ""
        var places: [(at: Double, width: Double)] = []
        init(across: Bool) { self.across = across }
    }

    init() {
        root.isHitTestVisible = false
        for s in strips {
            s.background.fill = Theme.brush(Theme.table)
            s.sheet.fill = Theme.brush(Self.sheetColour)
            s.band.fill = Theme.brush(Theme.selection, 0.13)
            for r in [s.background, s.sheet, s.band] { s.box.children.append(r) }
            for e in s.edges {
                e.fill = Theme.brush(Theme.selection, 0.75)
                e.visibility = .collapsed
                s.box.children.append(e)
            }
            for _ in 0..<2 {
                let pill = Border()
                pill.background = Theme.brush(Theme.selection)
                pill.cornerRadius = Theme.corners(4)
                pill.height = 13
                let text = Theme.text("", size: 9, weight: 600)
                text.foreground = Theme.brush(0xFFFFFF)
                text.margin = Theme.inset(4, 0, 4, 0)
                text.horizontalAlignment = .center
                pill.child = text
                pill.visibility = .collapsed
                s.pills.append((pill, text))
                s.box.children.append(pill)
            }
            root.children.append(s.box)
        }
        corner.background = Theme.brush(Theme.table)
        corner.width = Self.thickness
        corner.height = Self.thickness
        root.children.append(corner)
        tabs.isHitTestVisible = false
        root.children.append(tabs)
    }

    private let tabs = Canvas()

    /// The guides' tabs, as the Mac's rulers draw them: a small pencil triangle on each ruler's
    /// inner edge where a guide crosses it (across the top for one running down), larger when lit.
    func showTabs(_ list: [(at: Double, vertical: Bool, lit: Bool)]) {
        tabs.children.clear()
        let inner = Self.thickness
        for tab in list {
            let w = tab.lit ? 11.0 : 9.0, h = tab.lit ? 8.0 : 6.5, at = tab.at
            guard at > inner else { continue }
            var p = PathData()
            if tab.vertical {
                p.move(at, inner); p.line(at - w / 2, inner - h); p.line(at + w / 2, inner - h)
            } else {
                p.move(inner, at); p.line(inner - h, at - w / 2); p.line(inner - h, at + w / 2)
            }
            p.close()
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(p.d)' StrokeThickness='2.5' StrokeLineJoin='Round'/>"
            guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
            shape.fill = Theme.brush(Theme.selection)
            shape.stroke = Theme.brush(Theme.selection)
            tabs.children.append(shape)
        }
    }

    /// The rulers for a canvas `width` by `height` (on the stage) at `zoom`, the design's origin at
    /// `pan`; `sheet` the artboard measured, `selection` the selection's bounds (both in the design).
    func show(width: Double, height: Double, zoom: Double, pan: CGPoint, sheet: CGRect?, selection: CGRect?) {
        let zero = sheet.map { (x: Double($0.minX), y: Double($0.minY)) } ?? (x: 0, y: 0)
        for s in strips {
            let length = s.across ? width : height
            let t = Self.thickness
            let origin = s.across ? Double(pan.x) : Double(pan.y)
            func view(_ v: Double) -> Double { origin + v * zoom }
            size(s.box, s.across ? (length, t) : (t, length), at: s.across ? (0, 0) : (0, 0))
            size(s.background, s.across ? (length, t) : (t, length), at: (0, 0))
            if let sheet {
                let a = view(s.across ? Double(sheet.minX) : Double(sheet.minY)), b = view(s.across ? Double(sheet.maxX) : Double(sheet.maxY))
                size(s.sheet, s.across ? (max(b - a, 0), t) : (t, max(b - a, 0)), at: s.across ? (a, 0) : (0, a))
                s.sheet.visibility = .visible
            } else {
                s.sheet.visibility = .collapsed
            }
            var avoid: [(Double, Double)] = []
            if let r = selection {
                let lo = view(s.across ? Double(r.minX) : Double(r.minY)), hi = view(s.across ? Double(r.maxX) : Double(r.maxY))
                size(s.band, s.across ? (max(hi - lo, 1), t) : (t, max(hi - lo, 1)), at: s.across ? (lo, 0) : (0, lo))
                s.band.visibility = .visible
                for (edge, p) in zip(s.edges, [lo, hi]) {
                    size(edge, s.across ? (1, t) : (t, 1), at: s.across ? (p - 0.5, 0) : (0, p - 0.5))
                    edge.visibility = .visible
                }
                let texts = [label(s.across ? Double(r.minX) - zero.x : Double(r.minY) - zero.y),
                             label(s.across ? Double(r.maxX) - zero.x : Double(r.maxY) - zero.y)]
                for (k, text) in texts.enumerated() {
                    let w = Double(text.count) * 5.6 + 8
                    let at = k == 0 ? lo - w - 2 : hi + 2
                    s.pills[k].text.text = text
                    s.pills[k].box.width = w
                    rotate(s.pills[k].box, s.across, at: at, cross: (t - 13) / 2, length: w)
                    s.pills[k].box.visibility = .visible
                    avoid.append((at - 3, at + w + 3))
                }
            } else {
                s.band.visibility = .collapsed
                for e in s.edges { e.visibility = .collapsed }
                for p in s.pills { p.box.visibility = .collapsed }
            }

            // The scale, drawn again only when it moved: a selection moving along the ruler only
            // hides the numbers its pills cover.
            let scale = "\(length) \(zoom) \(origin) \(s.across ? zero.x : zero.y) \(Self.rulerInk)"
            if scale != s.scale {
                s.scale = scale
                drawScale(s, length: length, zoom: zoom, origin: origin, o: s.across ? zero.x : zero.y)
            }
            for (k, place) in s.places.enumerated() {
                let covered = avoid.contains { place.at + 3 < $0.1 && place.at + 3 + place.width > $0.0 }
                let visibility: Visibility = covered ? .collapsed : .visible
                if s.labels[k].visibility != visibility { s.labels[k].visibility = visibility }
            }
        }
        try? Canvas.setLeft(corner, 0)
        try? Canvas.setTop(corner, 0)
    }

    /// A strip's ticks and numbers for the view at `zoom`, its design origin at `origin` along it,
    /// counted from `o`.
    private func drawScale(_ s: Strip, length: Double, zoom: Double, origin: Double, o: Double) {
        let t = Self.thickness
        func view(_ v: Double) -> Double { origin + v * zoom }
        func design(_ p: Double) -> Double { (p - origin) / zoom }
        let labelStep = Self.steps.first { $0 * zoom >= 56 } ?? Self.steps.last!
        let lead = labelStep / pow(10, floor(log10(labelStep)))
        let mid = lead == 5 ? labelStep / 5 : labelStep / 2
        let small = labelStep / 10
        let start = design(0), end = design(length)
        let smallAlpha = min(max((small * zoom - 3) / 5, 0), 1) * 0.22
        let midAlpha = min(max((mid * zoom - 3) / 5, 0), 1) * 0.3
        var smallTicks = PathData(), midTicks = PathData(), majorTicks = PathData()
        if smallAlpha > 0.01 {
            var k = ((start - o) / small).rounded(.down)
            while o + k * small <= end { bar(&smallTicks, s.across, at: view(o + k * small).rounded() - 0.5, from: t - 3, length: 3, width: 1); k += 1 }
        }
        if midAlpha > 0.01 {
            var k = ((start - o) / mid).rounded(.down)
            while o + k * mid <= end { bar(&midTicks, s.across, at: view(o + k * mid).rounded() - 0.5, from: t - 5, length: 5, width: 1); k += 1 }
        }
        s.places = []
        var k = ((start - o) / labelStep).rounded(.down) - 1
        while o + k * labelStep <= end + labelStep {
            let v = k * labelStep
            k += 1
            let p = view(o + v)
            bar(&majorTicks, s.across, at: p.rounded() - 0.5, from: t - 8, length: 8, width: 1)
            let text = label(v)
            let w = Double(text.count) * 5.6
            if s.places.count == s.labels.count {
                let tb = Theme.text("", size: 9, weight: 500)
                s.labels.append(tb)
                s.box.children.append(tb)
            }
            let tb = s.labels[s.places.count]
            s.places.append((p, w))
            tb.text = text
            tb.foreground = Theme.brush(Self.rulerInk, 0.5)
            rotate(tb, s.across, at: p + 3, cross: 2, length: w)
            tb.visibility = .visible
        }
        for tb in s.labels[s.places.count...] { tb.visibility = .collapsed }

        // Under the band's edges and the pills.
        for old in s.paths { removeChild(old, from: s.box) }
        s.paths = []
        for (data, alpha) in [(smallTicks.d, smallAlpha), (midTicks.d, midAlpha), (majorTicks.d, 0.4)] where !data.isEmpty {
            let path = Glyphs.view([Glyphs.Part(data: data, mode: .fill)], size: 1, brush: Theme.brush(Self.rulerInk, alpha))
            try? s.box.children.insertAt(3 + UInt32(s.paths.count), path)
            s.paths.append(path)
        }
    }

    // MARK: Pieces

    private func bar(_ p: inout PathData, _ across: Bool, at a: Double, from b: Double, length: Double, width: Double) {
        if across { p.rect(a, b, width, length) } else { p.rect(b, a, length, width) }
    }

    private func size(_ e: FrameworkElement, _ wh: (Double, Double), at xy: (Double, Double)) {
        e.width = max(0, wh.0)
        e.height = max(0, wh.1)
        try? Canvas.setLeft(e, xy.0)
        try? Canvas.setTop(e, xy.1)
    }

    /// Places `e` along the strip at `at`, `cross` in from its outer edge; on the left ruler,
    /// turned to read upwards, as the Mac's.
    private func rotate(_ e: FrameworkElement, _ across: Bool, at: Double, cross: Double, length: Double) {
        if across {
            e.renderTransform = nil
            try? Canvas.setLeft(e, at)
            try? Canvas.setTop(e, cross)
        } else {
            let turn = CompositeTransform()
            turn.rotation = -90
            e.renderTransform = turn
            try? Canvas.setLeft(e, cross)
            try? Canvas.setTop(e, at + length)
        }
    }

    private func label(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        let s = r == r.rounded() ? String(Int(abs(r))) : String(format: "%g", abs(r))
        return r < 0 ? "−" + s : s
    }

    private func removeChild(_ e: UIElement, from c: Canvas) {
        var k: UInt32 = 0
        if (try? c.children.indexOf(e, &k)) == true { c.children.removeAt(k) }
    }
}
