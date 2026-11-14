import Foundation

extension WindowsCore {
    /// For trying the film's stage without the app (bezzle-render): the first artboard of the open
    /// design that has a film, on a desk in Animate, with the layers named in `pick` picked, laid
    /// out by the stage as the canvas shows it on a stage `width` by `height` points, the artboard
    /// fitted in it with room round it (`closer` times nearer, on its middle), one pixel to the
    /// point. At each of `times` the playhead is
    /// put there and the frame written to `folder` as a PNG. With `scrub` (from, to, steps) the
    /// playhead is moved from one moment to the other and back in that many steps first, as a hand
    /// on the timeline moves it, and what each step cost the stage said. Says what was made.
    @MainActor public static func stageCheck(times: [Double], scrub: (from: Double, to: Double, steps: Int)?, pick: [String],
                                             width: Int, height: Int, closer: Double = 1, into folder: URL) -> [String] {
        guard let doc = design, let board = doc.nodes.first(where: { $0.isArtboard && !$0.hidden && ($0.hasFilm || $0.holdsMovingShader) }) else {
            return ["no artboard moves"]
        }
        let desk = FilmDesk()
        desk.inSight = { board.id }
        desk.modeChanged(true)
        var picked: [UUID] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if pick.contains(n.name) { picked.append(n.id) }
                walk(n.children)
            }
        }
        walk(board.children)
        desk.selectionChanged(picked)
        let stage = FilmStage()
        let f = board.frame
        let zoom = min(Double(width) * 0.86 / Double(f.width), Double(height) * 0.86 / Double(f.height)) * max(closer, 0.05)
        let pan = CGPoint(x: (Double(width) - Double(f.width) * zoom) / 2 - Double(f.minX) * zoom,
                          y: (Double(height) - Double(f.height) * zoom) / 2 - Double(f.minY) * zoom)
        let size = CGSize(width: width, height: height)
        var buffer: [UInt8] = []
        var drawn = (0, 0)
        func draw() -> Bool {
            stage.draw(desk, zoom: zoom, pan: pan, size: size, pixelScale: 1) { w, h in
                if buffer.count != w * h * 4 { buffer = [UInt8](repeating: 0, count: w * h * 4) }
                drawn = (w, h)
                return buffer.withUnsafeMutableBytes { $0.baseAddress }
            } != nil
        }
        var said = ["\(board.name): \(board.filmPieces().count) pieces, \(board.filmLength) s, \(picked.count) picked, zoom \(String(format: "%.3f", zoom))"]
        // The first frame lays out every picture: not a step of a scrub.
        desk.seek(scrub?.from ?? times.first ?? 0)
        _ = draw()
        if let scrub, scrub.steps > 1 {
            let pictures = stage.picturesMade, parts = stage.partsMade
            var costs: [Double] = []
            Probe.begin()
            for i in 0..<scrub.steps {
                let k = Double(i) / Double(scrub.steps - 1)
                let u = k < 0.5 ? k * 2 : 2 - k * 2
                let started = WindowsCore.now
                desk.seek(scrub.from + (scrub.to - scrub.from) * u)
                _ = draw()
                costs.append((WindowsCore.now - started) * 1000)
            }
            let sorted = costs.sorted()
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            said.append(String(format: "  scrub %d steps: ms a step p50 %.1f p90 %.1f max %.1f, %.0f in all; pictures %d, parts %d",
                               scrub.steps, at(0.5), at(0.9), sorted.last ?? 0, costs.reduce(0, +),
                               stage.picturesMade - pictures, stage.partsMade - parts))
            said.append(Probe.end(over: costs.reduce(0, +) / 1000))
        }
        func write(_ t: Double, _ more: String) {
            // The stage's pixels are BGRA, as WinUI's bitmaps take them; a PNG wants RGBA.
            var rgba = buffer
            for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
            let file = folder.appendingPathComponent("\(board.name)-stage-\(String(format: "%.2f", t))\(more).png")
            do {
                try writePNG(rgba, width: drawn.0, height: drawn.1, to: file)
                said.append("  \(t) s: \(drawn.0)x\(drawn.1) -> \(file.lastPathComponent)")
            } catch {
                said.append("  \(t) s: \(error)")
            }
        }
        for t in times {
            desk.seek(t)
            guard draw() else {
                said.append("  \(t) s: not drawn")
                continue
            }
            // Come to from another moment, the frame is the one a scrub shows on its way, which
            // leaves the sharper parts for the frame that rests: both are written where they differ.
            if stage.owesParts {
                write(t, "-moving")
                _ = draw()
            }
            write(t, "")
        }
        return said
    }
}
