import AppKit

/// The rulers along the canvas's top and left edges: a scale printed on the table itself, down in
/// the well with the work rather than raised with the paper round it. They count from the top left corner of the artboard being worked on, which shows along them as a
/// lighter sheet; as the work moves to another artboard they slide over to it, numbers and all.
/// What is selected shows on them as a band, its edges' numbers in pencil; the artboard's guides
/// show as tabs, and its columns and rows faintly red along the sheet. A guide is pulled out of
/// either ruler, and a click on one puts a guide where it was clicked, as a tab is set on a
/// typewriter's ruler. The set square in the corner where they meet holds what they show, and a
/// drag from it puts down two guides at once.
final class Rulers {
    private let store: DocumentStore
    static let thickness: CGFloat = 20

    enum Part: Equatable { case top, left, corner }

    /// A guide's tab on a ruler: across the top for a guide running down, on screen.
    struct Tab {
        var at: CGFloat
        var vertical: Bool
        var lit: Bool
        /// How brightly it calls, 0 to 1: its guide is pointed at where a layer lies over it, and
        /// this is where to take it.
        var glow: CGFloat = 0
    }

    /// How far out the rulers are: 0 put away, 1 out.
    private var out = DeckTool.Spring(1)
    /// Where they count from, and the sheet of the artboard they measure, on the canvas, gliding
    /// from one artboard to the next.
    private var zeroX = DeckTool.Spring(0), zeroY = DeckTool.Spring(0)
    private var sheetRight = DeckTool.Spring(0), sheetBottom = DeckTool.Spring(0)
    private var sheetShown = DeckTool.Spring(0)
    private var measured: UUID?
    /// The artboard the pointer was last over, which they keep measuring as it goes up to them.
    private var lastOver: UUID?
    /// Where the pointer is, on screen, marked on both rulers.
    var pointer: CGPoint?
    private(set) var cornerLit = false
    private var last: CFTimeInterval?
    private var first = true

    init(store: DocumentStore) {
        self.store = store
        out = DeckTool.Spring(Helpers.shared.rulers ? 1 : 0)
    }

    /// How thick they are on screen just now.
    var thickness: CGFloat { Self.thickness * CGFloat(max(min(out.value, 1.05), 0)) }

    var isAnimating: Bool { out.isMoving || zeroX.isMoving || zeroY.isMoving || sheetRight.isMoving || sheetBottom.isMoving || sheetShown.isMoving }

    // MARK: - What they measure

    /// The artboard the rulers count from: the selection's, else the one the pointer was last on,
    /// else the one most in sight.
    var board: Node? {
        let doc = store.doc
        if let first = store.selection.first {
            if let n = doc.node(first), n.isArtboard { return n }
            if let b = doc.artboard(of: first) { return b }
        }
        if let id = lastOver, let b = doc.node(id), b.isArtboard, !b.hidden { return b }
        return store.focusedArtboard
    }

    /// The pointer has moved on the canvas, or left it (nil).
    func hover(_ v: CGPoint?) {
        pointer = v
        if let v, part(at: v) == nil, let b = store.doc.artboard(at: store.viewport.toCanvas(v)) { lastOver = b.id }
        let lit = v.map { part(at: $0) == .corner } ?? false
        if lit != cornerLit { cornerLit = lit }
    }

    func part(at v: CGPoint) -> Part? {
        guard Helpers.shared.rulers, out.value > 0.5, v.x >= 0, v.y >= 0 else { return nil }
        let t = thickness
        if v.x < t && v.y < t { return .corner }
        if v.y < t { return .top }
        if v.x < t { return .left }
        return nil
    }

    /// Where the rulers count from on the canvas, as it is now, not as it glides there.
    var zero: CGPoint { board?.frame.origin ?? .zero }

    // MARK: - Motion

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(now - (last ?? now), 1.0 / 30)
        last = now
        out.target = Helpers.shared.rulers ? 1 : 0
        out.step(dt, stiffness: 420, damping: 30)

        let b = board
        if let b {
            let f = b.frame
            if b.id != measured || first {
                // Over to another artboard: the scale slides along, unless there was none to slide from.
                let from = measured == nil || first
                measured = b.id
                zeroX.target = f.minX; zeroY.target = f.minY
                sheetRight.target = f.maxX; sheetBottom.target = f.maxY
                if from {
                    zeroX = DeckTool.Spring(f.minX); zeroY = DeckTool.Spring(f.minY)
                    sheetRight = DeckTool.Spring(f.maxX); sheetBottom = DeckTool.Spring(f.maxY)
                }
                first = false
            } else {
                // The same one moved or resized: they keep up with it at once, unless still on their way.
                let moving = zeroX.isMoving || zeroY.isMoving
                zeroX.target = f.minX; zeroY.target = f.minY
                sheetRight.target = f.maxX; sheetBottom.target = f.maxY
                if !moving {
                    zeroX = DeckTool.Spring(f.minX); zeroY = DeckTool.Spring(f.minY)
                    sheetRight = DeckTool.Spring(f.maxX); sheetBottom = DeckTool.Spring(f.maxY)
                }
            }
            sheetShown.target = 1
        } else {
            measured = nil
            sheetShown.target = 0
        }
        for s in [\Rulers.zeroX, \.zeroY, \.sheetRight, \.sheetBottom] as [ReferenceWritableKeyPath<Rulers, DeckTool.Spring>] {
            self[keyPath: s].step(dt, stiffness: 300, damping: 32)
        }
        sheetShown.step(dt, stiffness: 300, damping: 30)
    }

    // MARK: - Drawing

    private static let steps: [CGFloat] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000]
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    func draw(_ ctx: CGContext, in bounds: CGRect, scale: CGFloat, tabs: [Tab]) {
        step()
        let shown = CGFloat(min(max(out.value, 0), 1))
        guard shown > 0.01 else { return }
        let vp = store.viewport
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Printed where they lie, they come and go as ink does, drifting a little towards the rim.
        let hidden = (1 - shown) * 6
        if shown < 1 {
            ctx.setAlpha(shown)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if shown < 1 { ctx.endTransparencyLayer() } }

        let top = CGRect(x: 0, y: -hidden, width: bounds.width, height: Self.thickness)
        let left = CGRect(x: -hidden, y: 0, width: Self.thickness, height: bounds.height)

        let sheet = sheetShown.value > 0.01 ? CGRect(x: zeroX.value, y: zeroY.value, width: sheetRight.value - zeroX.value, height: sheetBottom.value - zeroY.value) : nil
        let selection = store.selection.isEmpty ? nil : store.selectionBounds
        let zero = CGPoint(x: zeroX.value, y: zeroY.value)

        for across in [true, false] {
            let strip = across ? top : left
            ctx.saveGState()
            ctx.clip(to: strip)
            ctx.setFillColor(CanvasInk.ruler.cgColor)
            ctx.fill(strip)
            // The artboard it measures, a lighter sheet along it.
            if let sheet {
                let a = across ? vp.toView(CGPoint(x: sheet.minX, y: 0)).x : vp.toView(CGPoint(x: 0, y: sheet.minY)).y
                let b = across ? vp.toView(CGPoint(x: sheet.maxX, y: 0)).x : vp.toView(CGPoint(x: 0, y: sheet.maxY)).y
                let band = across ? CGRect(x: a, y: strip.minY, width: b - a, height: strip.height) : CGRect(x: strip.minX, y: a, width: strip.width, height: b - a)
                ctx.setAlpha(CGFloat(min(max(sheetShown.value, 0), 1)))
                ctx.setFillColor(CanvasInk.rulerSheet.cgColor)
                ctx.fill(band)
                drawTracks(ctx, strip: strip, across: across)
                ctx.setAlpha(1)
            }
            if let selection { drawBand(ctx, selection, strip: strip, across: across) }
            drawTicks(ctx, strip: strip, across: across, zero: zero, sheet: sheet, scale: scale, avoid: selection.map { pills(for: $0, strip: strip, across: across) } ?? [])
            if let selection { drawPills(ctx, selection, strip: strip, across: across) }
            drawPointer(ctx, strip: strip, across: across, scale: scale)
            for tab in tabs where tab.vertical == across { drawTab(tab, ctx, strip: strip) }
            ctx.restoreGState()
        }
        drawCorner(ctx, CGRect(x: -hidden, y: -hidden, width: Self.thickness, height: Self.thickness), scale: scale)
    }

    /// The columns of the artboard measured along the top ruler, its rows along the left, faintly
    /// red over the sheet, with a firmer line at the inner edge under each.
    private func drawTracks(_ ctx: CGContext, strip: CGRect, across: Bool) {
        guard Helpers.shared.grids, let b = board, let grid = b.layout, (across ? grid.columns : grid.rows) != nil else { return }
        let vp = store.viewport, o = CGPoint(x: zeroX.value, y: zeroY.value)
        // Laid out on the sheet as it glides, with the artboard's own size.
        for area in LayoutGrid.areas(of: b) {
            let bands = across ? grid.columnRects(in: area).map { ($0.minX, $0.maxX) } : grid.rowRects(in: area).map { ($0.minY, $0.maxY) }
            for (lo, hi) in bands {
                let a = across ? vp.toView(CGPoint(x: o.x + lo, y: 0)).x : vp.toView(CGPoint(x: 0, y: o.y + lo)).y
                let z = across ? vp.toView(CGPoint(x: o.x + hi, y: 0)).x : vp.toView(CGPoint(x: 0, y: o.y + hi)).y
                guard z - a >= 1 else { continue }
                let r = across ? CGRect(x: a, y: strip.minY, width: z - a, height: strip.height) : CGRect(x: strip.minX, y: a, width: strip.width, height: z - a)
                ctx.setFillColor(CanvasInk.column.withAlphaComponent(0.075).cgColor)
                ctx.fill(r)
                let edge = across ? CGRect(x: a, y: strip.maxY - 2, width: z - a, height: 2) : CGRect(x: strip.maxX - 2, y: a, width: 2, height: z - a)
                ctx.setFillColor(CanvasInk.column.withAlphaComponent(0.5).cgColor)
                ctx.fill(edge)
            }
        }
    }

    /// Where the selection's edges' numbers go, so the scale's own make way for them.
    private func pills(for r: CGRect, strip: CGRect, across: Bool) -> [CGRect] {
        let vp = store.viewport
        let lo = across ? vp.toView(CGPoint(x: r.minX, y: 0)).x : vp.toView(CGPoint(x: 0, y: r.minY)).y
        let hi = across ? vp.toView(CGPoint(x: r.maxX, y: 0)).x : vp.toView(CGPoint(x: 0, y: r.maxY)).y
        let z = zero
        let a = label(across ? r.minX - z.x : r.minY - z.y), b = label(across ? r.maxX - z.x : r.maxY - z.y)
        let wa = Self.width(a, Self.pillFont) + 8, wb = Self.width(b, Self.pillFont) + 8
        let h: CGFloat = 13
        if across {
            let y = strip.midY - h / 2
            return [CGRect(x: lo - wa - 2, y: y, width: wa, height: h), CGRect(x: hi + 2, y: y, width: wb, height: h)]
        }
        let x = strip.midX - h / 2
        return [CGRect(x: x, y: lo - wa - 2, width: h, height: wa), CGRect(x: x, y: hi + 2, width: h, height: wb)]
    }

    private func drawBand(_ ctx: CGContext, _ r: CGRect, strip: CGRect, across: Bool) {
        let vp = store.viewport
        let lo = across ? vp.toView(CGPoint(x: r.minX, y: 0)).x : vp.toView(CGPoint(x: 0, y: r.minY)).y
        let hi = across ? vp.toView(CGPoint(x: r.maxX, y: 0)).x : vp.toView(CGPoint(x: 0, y: r.maxY)).y
        let band = across ? CGRect(x: lo, y: strip.minY, width: max(hi - lo, 1), height: strip.height)
                          : CGRect(x: strip.minX, y: lo, width: strip.width, height: max(hi - lo, 1))
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.13).cgColor)
        ctx.fill(band)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.75).cgColor)
        if across {
            ctx.fill(CGRect(x: lo - 0.5, y: strip.minY, width: 1, height: strip.height))
            ctx.fill(CGRect(x: hi - 0.5, y: strip.minY, width: 1, height: strip.height))
        } else {
            ctx.fill(CGRect(x: strip.minX, y: lo - 0.5, width: strip.width, height: 1))
            ctx.fill(CGRect(x: strip.minX, y: hi - 0.5, width: strip.width, height: 1))
        }
    }

    private func drawPills(_ ctx: CGContext, _ r: CGRect, strip: CGRect, across: Bool) {
        let z = zero
        let texts = [label(across ? r.minX - z.x : r.minY - z.y), label(across ? r.maxX - z.x : r.maxY - z.y)]
        for (rect, text) in zip(pills(for: r, strip: strip, across: across), texts) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setFillColor(CanvasInk.pencil.cgColor)
            ctx.fillPath()
            Self.drawText(text, font: Self.pillFont, color: .white, centeredIn: rect, vertical: !across, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// The scale: a long tick at every number, shorter ones between, those too close together on
    /// screen fading out as the view zooms away; and the numbers, those between fading in as it
    /// zooms closer, so nothing ever jumps.
    private func drawTicks(_ ctx: CGContext, strip: CGRect, across: Bool, zero: CGPoint, sheet: CGRect?, scale: CGFloat, avoid: [CGRect]) {
        let vp = store.viewport, zoom = vp.zoom
        let labelStep = Self.steps.first { $0 * zoom >= 56 } ?? Self.steps.last!
        let lead = labelStep / pow(10, floor(log10(labelStep)))
        let mid = lead == 5 ? labelStep / 5 : labelStep / 2
        let small = labelStep / 10
        let o = across ? zero.x : zero.y
        // The stretch of the canvas this ruler shows.
        let start = across ? vp.toCanvas(CGPoint(x: strip.minX, y: 0)).x : vp.toCanvas(CGPoint(x: 0, y: strip.minY)).y
        let end = across ? vp.toCanvas(CGPoint(x: strip.maxX, y: 0)).x : vp.toCanvas(CGPoint(x: 0, y: strip.maxY)).y
        let ink = CanvasInk.rulerInk
        let inner = across ? strip.maxY : strip.maxX
        let sheetLo = sheet.map { across ? $0.minX : $0.minY }, sheetHi = sheet.map { across ? $0.maxX : $0.maxY }

        func along(_ v: CGFloat) -> CGFloat { across ? vp.toView(CGPoint(x: v, y: 0)).x : vp.toView(CGPoint(x: 0, y: v)).y }
        func onSheet(_ v: CGFloat) -> Bool { sheetLo.map { v >= $0 - 0.01 && v <= sheetHi! + 0.01 } ?? false }
        func tick(_ v: CGFloat, length: CGFloat, alpha: CGFloat) {
            let p = (along(v) * scale).rounded() / scale + 0.5 / scale
            let a = alpha * (onSheet(v) ? 1 : 0.55)
            ctx.setFillColor(ink.withAlphaComponent(a).cgColor)
            if across { ctx.fill(CGRect(x: p - 0.5 / scale, y: inner - length, width: 1 / scale, height: length)) }
            else { ctx.fill(CGRect(x: inner - length, y: p - 0.5 / scale, width: length, height: 1 / scale)) }
        }

        let smallAlpha = min(max((small * zoom - 3) / 5, 0), 1) * 0.22
        let midAlpha = min(max((mid * zoom - 3) / 5, 0), 1) * 0.3
        if smallAlpha > 0.01 {
            var k = ((start - o) / small).rounded(.down)
            while o + k * small <= end {
                let v = k * small
                if (v / mid).rounded() * mid != v || true { tick(o + v, length: 3, alpha: smallAlpha) }
                k += 1
            }
        }
        if midAlpha > 0.01 {
            var k = ((start - o) / mid).rounded(.down)
            while o + k * mid <= end { tick(o + k * mid, length: 5, alpha: midAlpha); k += 1 }
        }
        // The numbers, and those between them as they come into reach.
        let fine = min(max((mid * zoom - 34) / 20, 0), 1)
        let numbered: [(CGFloat, CGFloat)] = [(labelStep, 1)] + (fine > 0.01 ? [(mid, fine)] : [])
        for (step, alpha) in numbered {
            var k = ((start - o) / step).rounded(.down) - 1
            while o + k * step <= end + step {
                let v = k * step
                defer { k += 1 }
                let isMajor = (v / labelStep).rounded() * labelStep == v
                if step != labelStep && isMajor { continue }
                if step == labelStep { tick(o + v, length: 8, alpha: 0.4) }
                let text = label(v)
                let p = along(o + v)
                let w = Self.width(text, Self.font)
                let box = across ? CGRect(x: p + 3, y: strip.minY + 2, width: w, height: 11) : CGRect(x: strip.minX + 2, y: p + 3, width: 11, height: w)
                if avoid.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(box) }) { continue }
                let a = alpha * (onSheet(o + v) ? 0.62 : 0.38)
                Self.drawText(text, font: Self.font, color: ink.withAlphaComponent(a), at: box, vertical: !across, ctx: ctx)
            }
        }
    }

    private func drawPointer(_ ctx: CGContext, strip: CGRect, across: Bool, scale: CGFloat) {
        guard let p = pointer, part(at: p) == nil else { return }
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.55).cgColor)
        if across { ctx.fill(CGRect(x: (p.x * scale).rounded() / scale, y: strip.minY, width: 1, height: strip.height)) }
        else { ctx.fill(CGRect(x: strip.minX, y: (p.y * scale).rounded() / scale, width: strip.width, height: 1)) }
    }

    /// A guide's tab: a small pencil pointer at the ruler's inner edge, pointing at the guide.
    private func drawTab(_ tab: Tab, _ ctx: CGContext, strip: CGRect) {
        let across = tab.vertical
        let w: CGFloat = tab.lit ? 11 : 9, h: CGFloat = tab.lit ? 8 : 6.5
        let inner = across ? strip.maxY : strip.maxX
        let path = CGMutablePath()
        if across {
            path.move(to: CGPoint(x: tab.at, y: inner))
            path.addLine(to: CGPoint(x: tab.at - w / 2, y: inner - h))
            path.addLine(to: CGPoint(x: tab.at + w / 2, y: inner - h))
        } else {
            path.move(to: CGPoint(x: inner, y: tab.at))
            path.addLine(to: CGPoint(x: inner - h, y: tab.at - w / 2))
            path.addLine(to: CGPoint(x: inner - h, y: tab.at + w / 2))
        }
        path.closeSubpath()
        let round = path.copy(strokingWithWidth: 2.5, lineCap: .round, lineJoin: .round, miterLimit: 1)
        ctx.saveGState()
        if tab.glow > 0.01 {
            // A soft light round it, swelling in as it calls.
            let c = across ? CGPoint(x: tab.at, y: inner - h * 0.6) : CGPoint(x: inner - h * 0.6, y: tab.at)
            for (r, a) in [(10.0, 0.10), (6.5, 0.16)] as [(CGFloat, CGFloat)] {
                let radius = r * (0.6 + 0.4 * tab.glow)
                ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(a * tab.glow).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        ctx.addPath(path)
        ctx.addPath(round)
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    /// The corner where the rulers meet, with a set square in it.
    private func drawCorner(_ ctx: CGContext, _ r: CGRect, scale: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(CanvasInk.ruler.cgColor)
        ctx.fill(r)
        // A set square: a right triangle with a triangle cut out of it.
        let c = CGPoint(x: r.midX + 0.5, y: r.midY + 0.5), s: CGFloat = 9
        let outer = CGMutablePath()
        outer.move(to: CGPoint(x: c.x - s / 2, y: c.y - s / 2))
        outer.addLine(to: CGPoint(x: c.x - s / 2, y: c.y + s / 2))
        outer.addLine(to: CGPoint(x: c.x + s / 2, y: c.y + s / 2))
        outer.closeSubpath()
        let inner = CGMutablePath()
        inner.move(to: CGPoint(x: c.x - s / 2 + 2.6, y: c.y - s / 2 + 5.6))
        inner.addLine(to: CGPoint(x: c.x - s / 2 + 2.6, y: c.y + s / 2 - 2.2))
        inner.addLine(to: CGPoint(x: c.x + s / 2 - 5.6, y: c.y + s / 2 - 2.2))
        inner.closeSubpath()
        ctx.addPath(outer)
        ctx.addPath(inner)
        ctx.setFillColor((cornerLit ? CanvasInk.pencil : CanvasInk.rulerInk.withAlphaComponent(0.42)).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - Words

    /// A number as the rulers write it: whole, and with a proper minus.
    private func label(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10
        let s = r == r.rounded() ? String(Int(abs(r))) : CanvasView.number(abs(r))
        return r < 0 ? "−" + s : s
    }

    private static var widths: [String: CGFloat] = [:]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)\(font.fontName)|\(text)"
        if let w = widths[key] { return w }
        if widths.count > 4000 { widths.removeAll() }
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = w
        return w
    }

    /// Text along a ruler: as it reads across the top, and turned to read up the left.
    private static func drawText(_ text: String, font: NSFont, color: NSColor, at box: CGRect, vertical: Bool, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if !vertical {
            (text as NSString).draw(at: CGPoint(x: box.minX, y: box.minY), withAttributes: attrs)
            return
        }
        ctx.saveGState()
        // Reading upward, its start at the bottom of the box.
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.rotate(by: -.pi / 2)
        (text as NSString).draw(at: .zero, withAttributes: attrs)
        ctx.restoreGState()
    }

    private static func drawText(_ text: String, font: NSFont, color: NSColor, centeredIn rect: CGRect, vertical: Bool, ctx: CGContext) {
        let w = width(text, font), h = ceil(font.ascender - font.descender)
        if vertical {
            drawText(text, font: font, color: color,
                     at: CGRect(x: rect.midX - h / 2, y: rect.midY - w / 2, width: h, height: w), vertical: true, ctx: ctx)
        } else {
            drawText(text, font: font, color: color,
                     at: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), vertical: false, ctx: ctx)
        }
    }
}
