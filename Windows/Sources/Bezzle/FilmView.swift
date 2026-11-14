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
    /// How many frames have been put together, to know whether one is still the last.
    private var framed = 0
    /// Lays the film out again where the canvas is now (the canvas's `placeFilm`).
    var resync: () -> Void = {}
    /// Told of each frame while the film plays, and once when it stops.
    var frameShown: () -> Void = {}
    /// How many pictures and parts the stage has drawn, for looking at what it costs.
    var picturesMade: Int { stageCore.picturesMade }
    var partsMade: Int { stageCore.partsMade }

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
        // A frame on a scrub's way leaves its sharper parts undrawn (`FilmStage.owesParts`): they
        // come once the playhead has rested for an eighth of a second, with a frame asked for here.
        framed += 1
        if stageCore.owesParts, !session.film.playing { sharpen(after: framed, waits: 2) }
        guard let rect else {
            image.visibility = .collapsed
            shown = nil
            frame = nil
            return
        }
        Probe.time("stage.invalidate") { try? made?.invalidate() }
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

    /// Asks for the frame again, with its sharper parts, if the one numbered `last` is still the
    /// last a little later. It waits twice: a step of a scrub that took as long as the first wait
    /// has the next step waiting already, which goes first.
    private func sharpen(after last: Int, waits: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits > 1 ? 0.1 : 0.025)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.framed == last, self.session.mode == 3, !self.session.film.playing else { return }
                // A hand still on the design: asked again, until it has let go.
                if WindowsCore.inGesture { self.sharpen(after: last, waits: 2) } else if waits > 1 { self.sharpen(after: last, waits: waits - 1) } else { self.resync() }
            }
        }
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
        laid = []
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

    /// A mark as it is drawn: a path and its look.
    private struct Mark: Equatable {
        var d: String
        var stroke: UInt32?
        var alpha = 1.0
        var width = 1.0
        var fill: UInt32?
        var fillAlpha = 1.0
        var dash: String?
    }

    /// The marks on the canvas, in their order, and those of the drawing under way. Each is read
    /// from XAML, which is slow, so a mark that is as it was drawn the last time stays as it is:
    /// while the playhead moves, a picked layer's way, its beads and its home lie where they lay,
    /// and only its outline and its handles are made again; while the film plays, nothing is.
    private var laid: [(mark: Mark, path: WinUI.Path)] = []
    private var wanted: [Mark] = []

    private func add(_ d: PathData, stroke: UInt32? = nil, alpha: Double = 1, width: Double = 1, fill: (colour: UInt32, alpha: Double)? = nil, dash: String? = nil) {
        guard !d.d.isEmpty else { return }
        wanted.append(Mark(d: d.d, stroke: stroke, alpha: alpha, width: width, fill: fill?.colour, fillAlpha: fill?.alpha ?? 1, dash: dash))
    }

    private func made(_ m: Mark) -> WinUI.Path? {
        let dashes = m.dash.map { " StrokeDashArray='\($0)'" } ?? ""
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(m.d)' StrokeThickness='\(m.width)' StrokeLineJoin='Round'\(dashes)/>"
        guard let p = (try? XamlReader.load(xaml)) as? WinUI.Path else { return nil }
        if let stroke = m.stroke { p.stroke = Theme.brush(stroke, m.alpha) }
        if let fill = m.fill { p.fill = Theme.brush(fill, m.fillAlpha) }
        p.isHitTestVisible = false
        return p
    }

    /// Puts the marks wanted on the canvas: one that is where and as it was stays, the others are made.
    private func lay() {
        var next: [(mark: Mark, path: WinUI.Path)] = []
        for mark in wanted {
            let at = next.count
            if at < laid.count, laid[at].mark == mark {
                next.append(laid[at])
                continue
            }
            guard let path = made(mark) else { continue }
            if at < Int(marks.children.size) {
                marks.children.removeAt(UInt32(at))
                marks.children.insertAt(UInt32(at), path)
            } else {
                marks.children.append(path)
            }
            next.append((mark, path))
        }
        while Int(marks.children.size) > next.count { marks.children.removeAt(marks.children.size - 1) }
        laid = next
        wanted = []
    }

    private func outline(_ q: [BezzleCore.CGPoint]) -> PathData {
        var d = PathData()
        guard let first = q.first else { return d }
        d.move(Double(first.x), Double(first.y))
        for p in q.dropFirst() { d.line(Double(p.x), Double(p.y)) }
        d.close()
        return d
    }

    /// The handles: 8 square, white, ringed in pencil, on whole pixels.
    private func handles(_ points: [BezzleCore.CGPoint], scale: Double) {
        guard !points.isEmpty else { return }
        var d = PathData()
        for p in points {
            let x = (Double(p.x) * scale).rounded() / scale, y = (Double(p.y) * scale).rounded() / scale
            d.rect(x - 3.5, y - 3.5, 7, 7)
        }
        add(d, stroke: Self.pencil, width: 1, fill: (0xFFFFFF, 1))
    }

    /// The marks drawn again, as the canvas hand has them now.
    func drawMarks(_ m: WindowsCore.MotionHand.Marks?, pixelScale: Double) {
        Probe.time("marks.xaml") {
            wanted = []
            if session.mode == 3, let m { list(m, pixelScale: pixelScale) }
            lay()
        }
    }

    private func list(_ m: WindowsCore.MotionHand.Marks, pixelScale: Double) {
        if let chip = m.chip { drawChip(chip, on: m.chipOn, hot: m.chipHot, keys: m.chipKeys) }
        guard !m.playing else { return }
        if m.camera {
            var frame = PathData()
            frame.rect(Double(m.frame.minX) - 0.5, Double(m.frame.minY) - 0.5, Double(m.frame.width) + 1, Double(m.frame.height) + 1)
            add(frame, stroke: Self.pencil, alpha: 0.45, dash: "3 3")
            add(outline(m.sheet), stroke: Self.pencil)
            let c = (Double(m.frame.midX), Double(m.frame.midY))
            var cross = PathData()
            cross.move(c.0 - 5, c.1); cross.line(c.0 + 5, c.1)
            cross.move(c.0, c.1 - 5); cross.line(c.0, c.1 + 5)
            add(cross, stroke: 0xFFFFFF, alpha: 0.9, width: 3)
            add(cross, stroke: Self.pencil)
            handles(m.handles, scale: pixelScale)
            return
        }
        for home in m.homes { add(outline(home), stroke: Self.pencil, alpha: 0.45, dash: "3 3") }
        if m.way.count >= 2 {
            var way = PathData()
            way.move(Double(m.way[0].x), Double(m.way[0].y))
            for p in m.way.dropFirst() { way.line(Double(p.x), Double(p.y)) }
            add(way, stroke: Self.pencil, alpha: 0.55)
            var ticks = PathData()
            for p in m.ticks { dot(&ticks, p, 1.25) }
            add(ticks, fill: (Self.pencil, 1))
            for bead in m.beads {
                let r = bead.large ? 4.5 : 3.5
                var d = PathData()
                dot(&d, bead.at, bead.home ? r - 0.75 : r)
                add(d, stroke: bead.home ? Self.pencil : 0xFFFFFF, width: bead.home ? 1.5 : 1, fill: (bead.home ? 0xFFFFFF : Self.pencil, 1))
            }
        }
        if let hovered = m.hovered { add(outline(hovered), stroke: Self.pencil, width: 1.5) }
        for q in m.picked { add(outline(q), stroke: Self.pencil) }
        handles(m.handles, scale: pixelScale)
        if let o = m.points { drawPoints(o, scale: pixelScale) }
        if let r = m.marquee {
            var box = PathData()
            box.rect(Double(r.minX) + 0.5, Double(r.minY) + 0.5, max(Double(r.width) - 1, 0), max(Double(r.height) - 1, 0))
            add(box, stroke: Self.pencil, alpha: 0.8, fill: (Self.pencil, 0.08))
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
            add(d, stroke: Self.pencil)
        }
        if !o.handles.isEmpty {
            var lines = PathData(), rings = PathData()
            for h in o.handles {
                lines.move(Double(h.point.x), Double(h.point.y))
                lines.line(Double(h.handle.x), Double(h.handle.y))
                dot(&rings, h.handle, 3.5)
            }
            add(lines, stroke: Self.pencil, alpha: 0.85)
            add(rings, stroke: Self.pencil, fill: (0xFFFFFF, 1))
        }
        var picked = PathData(), others = PathData()
        for a in o.anchors {
            let x = crisp(Double(a.point.x)), y = crisp(Double(a.point.y))
            if a.filled { picked.rect(x - 3.5, y - 3.5, 7, 7) } else { others.rect(x - 3.5, y - 3.5, 7, 7) }
        }
        add(others, stroke: Self.pencil, fill: (0xFFFFFF, 1))
        add(picked, stroke: Self.pencil, fill: (Self.pencil, 1))
        if let spot = o.spot {
            var d = PathData()
            d.rect(crisp(Double(spot.x)) - 3.5, crisp(Double(spot.y)) - 3.5, 7, 7)
            add(d, stroke: Self.pencil, alpha: 0.55, fill: (0xFFFFFF, 0.55))
        }
        if let r = o.marquee {
            var box = PathData()
            box.rect(Double(r.minX) + 0.5, Double(r.minY) + 0.5, max(Double(r.width) - 1, 0), max(Double(r.height) - 1, 0))
            add(box, stroke: Self.pencil, alpha: 0.8, fill: (Self.pencil, 0.08))
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
        let fill: (colour: UInt32, alpha: Double)? = on ? (colour, alpha) : nil
        add(box, stroke: colour, alpha: alpha, width: 1.3, fill: fill)
        add(lens, stroke: colour, alpha: alpha, width: 1.3, fill: fill)
        if keys {
            var bead = PathData()
            dot(&bead, BezzleCore.CGPoint(x: body.x - 6, y: body.y + body.h / 2), 2)
            add(bead, fill: (colour, alpha))
        }
    }
}
