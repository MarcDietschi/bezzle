import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The film on the canvas, in Animate, as the Mac's FilmStageView and MotionTool show it: the
/// film's artboard put together at the playhead by the core's stage (`WindowsCore.FilmStage`), in
/// a picture over the artboard's own sheet, and what is posed drawn over it in pencil from the
/// canvas hand's marks (`WindowsCore.MotionHand.marks()`). While the film plays, each frame of
/// the screen moves it on and lays its pictures out again; nothing lies over it then but the
/// small camera.
@MainActor
final class FilmView {
    let session: DesignSession
    private let stageCore = WindowsCore.FilmStage()
    /// The film's frame on the stage, under the canvas's marks.
    let image = Image()
    private var bitmap: WriteableBitmap?
    /// What is posed, over the film, on the canvas's overlay.
    let marks = Canvas()
    private var ticking: EventCleanup?
    /// The artboard whose film shows, and where on the stage; nil while none does.
    private(set) var shown: UUID?
    private(set) var frame: CGRect?
    /// Lays the film out again where the canvas is now (the canvas's `placeFilm`).
    var resync: () -> Void = {}
    /// Told of each frame while the film plays, and once when it stops.
    var frameShown: () -> Void = {}

    init(session: DesignSession) {
        self.session = session
        image.isHitTestVisible = false
        image.stretch = .fill
        image.visibility = .collapsed
        marks.isHitTestVisible = false
    }

    /// The film drawn at the playhead into the stage's picture, for the canvas seen at `zoom`
    /// with the design's origin at `pan`, on a stage `size` big, `pixelScale` pixels to its point.
    func sync(zoom: Double, pan: CGPoint, size: CGSize, pixelScale: Double) {
        guard session.mode == 3 else {
            if shown != nil || image.visibility == .visible { hide() }
            return
        }
        var made = bitmap
        let rect = stageCore.draw(session.film, zoom: zoom, pan: pan, size: size, pixelScale: pixelScale) { w, h in
            if made == nil || made!.pixelWidth != Int32(w) || made!.pixelHeight != Int32(h) { made = WriteableBitmap(Int32(w), Int32(h)) }
            return (try? made?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        guard let rect else {
            image.visibility = .collapsed
            shown = nil
            frame = nil
            return
        }
        try? made?.invalidate()
        if bitmap !== made { image.source = made }
        bitmap = made
        try? Canvas.setLeft(image, Double(rect.minX))
        try? Canvas.setTop(image, Double(rect.minY))
        image.width = Double(rect.width)
        image.height = Double(rect.height)
        image.visibility = .visible
        shown = session.film.board
        frame = rect
    }

    func hide() {
        stop()
        stageCore.reset()
        image.visibility = .collapsed
        image.source = nil
        bitmap = nil
        shown = nil
        frame = nil
        marks.children.clear()
    }

    // MARK: Playing

    /// Runs the film for as long as it plays: each frame of the screen moves it on.
    func run() {
        guard ticking == nil else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let desk = session.film
        let going = desk.step(WindowsCore.now)
        resync()
        frameShown()
        if !going {
            stop()
            session.changed()
        }
    }

    func stop() {
        ticking?.dispose()
        ticking = nil
    }

    // MARK: What is posed

    private static var pencil: UInt32 { Theme.selection }

    private func path(_ d: PathData, stroke: UInt32? = nil, alpha: Double = 1, width: Double = 1, fill: Brush? = nil, dash: String? = nil) -> WinUI.Path? {
        guard !d.d.isEmpty else { return nil }
        let dashes = dash.map { " StrokeDashArray='\($0)'" } ?? ""
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='\(width)' StrokeLineJoin='Round'\(dashes)/>"
        guard let p = (try? XamlReader.load(xaml)) as? WinUI.Path else { return nil }
        if let stroke { p.stroke = Theme.brush(stroke, alpha) }
        if let fill { p.fill = fill }
        p.isHitTestVisible = false
        return p
    }

    private func outline(_ q: [BezzleCore.CGPoint]) -> PathData {
        var d = PathData()
        guard let first = q.first else { return d }
        d.move(Double(first.x), Double(first.y))
        for p in q.dropFirst() { d.line(Double(p.x), Double(p.y)) }
        d.close()
        return d
    }

    private func add(_ p: WinUI.Path?) {
        if let p { marks.children.append(p) }
    }

    /// The handles: 8 square, white, ringed in pencil, on whole pixels.
    private func handles(_ points: [BezzleCore.CGPoint], scale: Double) {
        guard !points.isEmpty else { return }
        var d = PathData()
        for p in points {
            let x = (Double(p.x) * scale).rounded() / scale, y = (Double(p.y) * scale).rounded() / scale
            d.rect(x - 3.5, y - 3.5, 7, 7)
        }
        add(path(d, stroke: Self.pencil, width: 1, fill: Theme.brush(0xFFFFFF)))
    }

    /// The marks drawn again, as the canvas hand has them now.
    func drawMarks(_ m: WindowsCore.MotionHand.Marks?, pixelScale: Double) {
        marks.children.clear()
        guard session.mode == 3, let m else { return }
        if let chip = m.chip { drawChip(chip, on: m.chipOn, hot: m.chipHot, keys: m.chipKeys) }
        guard !m.playing else { return }
        if m.camera {
            var frame = PathData()
            frame.rect(Double(m.frame.minX) - 0.5, Double(m.frame.minY) - 0.5, Double(m.frame.width) + 1, Double(m.frame.height) + 1)
            add(path(frame, stroke: Self.pencil, alpha: 0.45, dash: "3 3"))
            add(path(outline(m.sheet), stroke: Self.pencil))
            let c = (Double(m.frame.midX), Double(m.frame.midY))
            var cross = PathData()
            cross.move(c.0 - 5, c.1); cross.line(c.0 + 5, c.1)
            cross.move(c.0, c.1 - 5); cross.line(c.0, c.1 + 5)
            add(path(cross, stroke: 0xFFFFFF, alpha: 0.9, width: 3))
            add(path(cross, stroke: Self.pencil))
            handles(m.handles, scale: pixelScale)
            return
        }
        for home in m.homes { add(path(outline(home), stroke: Self.pencil, alpha: 0.45, dash: "3 3")) }
        if m.way.count >= 2 {
            var way = PathData()
            way.move(Double(m.way[0].x), Double(m.way[0].y))
            for p in m.way.dropFirst() { way.line(Double(p.x), Double(p.y)) }
            add(path(way, stroke: Self.pencil, alpha: 0.55))
            var ticks = PathData()
            for p in m.ticks { dot(&ticks, p, 1.25) }
            add(path(ticks, fill: Theme.brush(Self.pencil)))
            for bead in m.beads {
                let r = bead.large ? 4.5 : 3.5
                var d = PathData()
                dot(&d, bead.at, bead.home ? r - 0.75 : r)
                add(path(d, stroke: bead.home ? Self.pencil : 0xFFFFFF, width: bead.home ? 1.5 : 1,
                         fill: Theme.brush(bead.home ? 0xFFFFFF : Self.pencil)))
            }
        }
        if let hovered = m.hovered { add(path(outline(hovered), stroke: Self.pencil, width: 1.5)) }
        for q in m.picked { add(path(outline(q), stroke: Self.pencil)) }
        handles(m.handles, scale: pixelScale)
        if let o = m.points { drawPoints(o, scale: pixelScale) }
        if let r = m.marquee {
            var box = PathData()
            box.rect(Double(r.minX) + 0.5, Double(r.minY) + 0.5, max(Double(r.width) - 1, 0), max(Double(r.height) - 1, 0))
            add(path(box, stroke: Self.pencil, alpha: 0.8, fill: Theme.brush(Self.pencil, 0.08)))
        }
    }

    /// A shape's points in hand, where the film shows them, as the pen draws them in the design:
    /// its outline, the handles on their lines (round), the points (square, filled when picked),
    /// and the box dragged round points, in pencil.
    private func drawPoints(_ o: WindowsCore.Pen.Overlay, scale: Double) {
        func crisp(_ v: Double) -> Double { (v * scale).rounded() / scale }
        if let outline = o.outline, !outline.isEmpty {
            var d = PathData()
            d.d = outline
            add(path(d, stroke: Self.pencil))
        }
        if !o.handles.isEmpty {
            var lines = PathData(), rings = PathData()
            for h in o.handles {
                lines.move(Double(h.point.x), Double(h.point.y))
                lines.line(Double(h.handle.x), Double(h.handle.y))
                dot(&rings, h.handle, 3.5)
            }
            add(path(lines, stroke: Self.pencil, alpha: 0.85))
            add(path(rings, stroke: Self.pencil, fill: Theme.brush(0xFFFFFF)))
        }
        var picked = PathData(), others = PathData()
        for a in o.anchors {
            let x = crisp(Double(a.point.x)), y = crisp(Double(a.point.y))
            if a.filled { picked.rect(x - 3.5, y - 3.5, 7, 7) } else { others.rect(x - 3.5, y - 3.5, 7, 7) }
        }
        add(path(others, stroke: Self.pencil, fill: Theme.brush(0xFFFFFF)))
        add(path(picked, stroke: Self.pencil, fill: Theme.brush(Self.pencil)))
        if let spot = o.spot {
            var d = PathData()
            d.rect(crisp(Double(spot.x)) - 3.5, crisp(Double(spot.y)) - 3.5, 7, 7)
            add(path(d, stroke: Self.pencil, alpha: 0.55, fill: Theme.brush(0xFFFFFF, 0.55)))
        }
        if let r = o.marquee {
            var box = PathData()
            box.rect(Double(r.minX) + 0.5, Double(r.minY) + 0.5, max(Double(r.width) - 1, 0), max(Double(r.height) - 1, 0))
            add(path(box, stroke: Self.pencil, alpha: 0.8, fill: Theme.brush(Self.pencil, 0.08)))
        }
    }

    private func dot(_ d: inout PathData, _ c: BezzleCore.CGPoint, _ r: Double) {
        let x = Double(c.x), y = Double(c.y)
        d.move(x + r, y)
        for k in 1...16 {
            let a = Double(k) / 16 * 2 * Double.pi
            d.line(x + r * cos(a), y + r * sin(a))
        }
        d.close()
    }

    /// The small camera over the artboard's top right corner: a click takes the camera in hand.
    private func drawChip(_ r: BezzleCore.CGRect, on: Bool, hot: Bool, keys: Bool) {
        let colour: UInt32 = on || hot ? Self.pencil : Theme.ink
        let alpha = on ? 1 : hot ? 0.8 : 0.64
        let body = (x: Double(r.maxX) - 17, y: Double(r.minY) + 5, w: 11.0, h: 8.5)
        var box = PathData()
        box.rect(body.x, body.y, body.w, body.h, radius: 2)
        var lens = PathData()
        lens.move(body.x + body.w + 1.5, body.y + body.h / 2)
        lens.line(body.x + body.w + 5.5, body.y + 0.8)
        lens.line(body.x + body.w + 5.5, body.y + body.h - 0.8)
        lens.close()
        let fill = on ? Theme.brush(colour, alpha) : nil
        add(path(box, stroke: colour, alpha: alpha, width: 1.3, fill: fill))
        add(path(lens, stroke: colour, alpha: alpha, width: 1.3, fill: fill))
        if keys {
            var bead = PathData()
            dot(&bead, BezzleCore.CGPoint(x: body.x - 6, y: body.y + body.h / 2), 2)
            add(path(bead, fill: Theme.brush(colour, alpha)))
        }
    }
}
