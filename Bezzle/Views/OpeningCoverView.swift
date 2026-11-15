import AppKit
import QuartzCore
import SwiftUI

/// The paper over a design's tab while the design opens, with Bezzle's mark pressed into it
/// (`OpeningMark`; when it comes and goes is `OpeningCover`). Drawn by Core Animation alone: once
/// its layers and their animations are handed over, the whole gesture plays in the window server,
/// whatever the main thread is busy with meanwhile, reading the design or laying out its panels.
final class OpeningCoverView: NSView {
    private let cover: OpeningCover
    private let calm: Bool
    private let paper = CALayer()
    private let mark = CALayer()
    private let word = CALayer()
    private var letters: [CAShapeLayer] = []
    private var lifted = false
    /// How big the mark is drawn, its name under it.
    private var markSize: CGSize = .zero
    private var wordSize: CGSize = .zero
    private var capHeight: CGFloat = 0
    private var descender: CGFloat = 0

    init(cover: OpeningCover, calm: Bool = OpeningCoverView.reducesMotion) {
        self.cover = cover
        self.calm = calm
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// With Reduce Motion on, the mark only fades in and out. BEZZLE_REDUCE_MOTION=1 asks for that
    /// in a test copy.
    static var reducesMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BEZZLE_REDUCE_MOTION"] != nil { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override var isFlipped: Bool { false }

    /// Takes clicks while it covers the design, none once it lifts.
    override func hitTest(_ point: NSPoint) -> NSView? { lifted ? nil : super.hitTest(point) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, paper.superlayer == nil, let root = layer else { return }
        build(in: root)
        press()
        #if DEBUG
        // BEZZLE_COVER_AT=seconds holds the mark still that long after it is pressed, to photograph it.
        if let t = ProcessInfo.processInfo.environment["BEZZLE_COVER_AT"].flatMap(Double.init) {
            root.speed = 0
            root.timeOffset = cover.marks + t
        }
        #endif
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.frame = bounds
        place()
        CATransaction.commit()
    }

    // MARK: Putting it together

    private func build(in root: CALayer) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = max(window?.backingScaleFactor ?? 2, 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paper.backgroundColor = NSColor(Theme.paper).cgColor
        }
        root.addSublayer(paper)
        paper.frame = bounds
        // The mark: a layer for each sheet, holding its parts, each struck about its own middle.
        let k = OpeningMark.side / 500
        markSize = CGSize(width: OpeningMark.canvas.width * k, height: OpeningMark.canvas.height * k)
        mark.bounds = CGRect(origin: .zero, size: markSize)
        paper.addSublayer(mark)
        for sheet in OpeningMark.sheets.indices {
            let holder = CALayer()
            holder.bounds = mark.bounds
            let middle = OpeningMark.middle(of: sheet)
            // Layers count up from the bottom.
            holder.anchorPoint = CGPoint(x: middle.x / OpeningMark.canvas.width, y: 1 - middle.y / OpeningMark.canvas.height)
            holder.position = CGPoint(x: holder.anchorPoint.x * markSize.width, y: holder.anchorPoint.y * markSize.height)
            holder.name = "sheet\(sheet)"
            for part in [OpeningMark.Part.rim, .floor, .walls] {
                holder.addSublayer(picture(part, sheet, dark: dark, scale: scale))
            }
            if OpeningMark.has(.ink, sheet) {
                // The ink runs in from the top edge: a soft edge drawn down the sheet.
                let ink = CALayer()
                ink.frame = holder.bounds
                ink.name = "ink"
                ink.addSublayer(picture(.ink, sheet, dark: dark, scale: scale))
                ink.addSublayer(picture(.inkWalls, sheet, dark: dark, scale: scale))
                let edge = CAGradientLayer()
                edge.frame = ink.bounds
                edge.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
                edge.startPoint = CGPoint(x: 0.5, y: 1)
                edge.endPoint = CGPoint(x: 0.5, y: 0)
                edge.locations = [1, 1.3]
                edge.name = "edge"
                ink.mask = edge
                holder.addSublayer(ink)
            }
            mark.addSublayer(holder)
        }
        // The name, in New York as the home tab and the website set it, a layer for each letter.
        let base = NSFont.systemFont(ofSize: OpeningMark.wordSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: OpeningMark.wordSize) } ?? base
        capHeight = font.capHeight
        descender = font.descender
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: OpeningMark.word, attributes: [
            .font: font, .kern: OpeningMark.wordTracking * OpeningMark.wordSize]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        wordSize = CGSize(width: ceil(width), height: ceil(font.ascender - font.descender))
        word.bounds = CGRect(origin: .zero, size: wordSize)
        var ink = NSColor.black.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = Theme.inkNS.cgColor }
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                // Each letter its own layer about its own middle, to be struck about it.
                let box = outline.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
                let letter = CAShapeLayer()
                letter.bounds = CGRect(origin: .zero, size: box.size)
                letter.position = CGPoint(x: positions[i].x + box.midX, y: -font.descender + box.midY)
                var place = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                letter.path = outline.copy(using: &place)
                letter.fillColor = ink
                letter.contentsScale = scale
                word.addSublayer(letter)
                letters.append(letter)
            }
        }
        paper.addSublayer(word)
        place()
    }

    /// One part of a sheet, drawn at the screen's pixels, the size of the whole mark.
    private func picture(_ part: OpeningMark.Part, _ sheet: Int, dark: Bool, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = mark.bounds
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.name = "\(part)"
        let pixels = OpeningMark.side / 500 * scale
        let size = CGSize(width: ceil(OpeningMark.canvas.width * pixels), height: ceil(OpeningMark.canvas.height * pixels))
        if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // The mark's units, y down.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: pixels, y: -pixels)
            ctx.translateBy(x: -OpeningMark.canvas.minX, y: -OpeningMark.canvas.minY)
            OpeningMark.paint(part, of: sheet, dark: dark, pixels: pixels, in: ctx)
            layer.contents = ctx.makeImage()
        }
        return layer
    }

    /// The mark and its name together in the middle of the room, a little above it.
    private func place() {
        guard markSize != .zero else { return }
        let side = OpeningMark.side
        // From the outer sheet's top to the name's baseline; layers count up from the bottom.
        let tall = side + OpeningMark.wordGap + capHeight
        let top = bounds.midY + bounds.height * OpeningMark.lift + tall / 2
        mark.position = CGPoint(x: bounds.midX.rounded(), y: (top - side / 2).rounded())
        let baseline = (top - tall).rounded()
        // The name's layer reaches below its baseline by the font's descender, which is negative.
        word.position = CGPoint(x: bounds.midX.rounded(), y: baseline + descender + wordSize.height / 2)
    }

    // MARK: The gesture

    /// Everything the mark does, handed to Core Animation at once, from when it is pressed.
    private func press() {
        let at = cover.marks
        // Reduce Motion: the mark and its name simply come, all at once.
        guard !calm else {
            fade(mark, from: 0, to: 1, at: at, for: 0.3)
            fade(word, from: 0, to: 1, at: at, for: 0.3)
            return
        }
        for (i, holder) in (mark.sublayers ?? []).enumerated() {
            let strike = at + OpeningMark.strikes[i]
            fade(holder, from: 0, to: 1, at: strike, for: OpeningMark.deepens, timing: .easeOut)
            spring(holder, "transform.scale", from: OpeningMark.strikeFrom, to: 1, at: strike, OpeningMark.strike)
            // Then it breathes: pressed a little shallower and back, its walls, its floor and the
            // paper round it; the ink stays.
            let breathe = at + OpeningMark.breathes + OpeningMark.breathLag(i)
            for part in holder.sublayers ?? [] where ["rim", "floor", "walls", "ink"].contains(part.name) {
                let targets = part.name == "ink" ? (part.sublayers?.filter { $0.name == "inkWalls" } ?? []) : [part]
                for target in targets {
                    let breath = CABasicAnimation(keyPath: "opacity")
                    breath.fromValue = 1
                    breath.toValue = OpeningMark.shallowest
                    breath.duration = OpeningMark.breath / 2
                    breath.autoreverses = true
                    breath.repeatCount = .infinity
                    breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    breath.beginTime = breathe
                    target.add(breath, forKey: "breath")
                }
            }
            if let ink = holder.sublayers?.first(where: { $0.name == "ink" }), let edge = ink.mask as? CAGradientLayer {
                let run = CABasicAnimation(keyPath: "locations")
                run.fromValue = [-0.3, 0]
                run.toValue = [1, 1.3]
                run.duration = OpeningMark.inking
                run.beginTime = at + OpeningMark.inks
                run.fillMode = .both
                run.isRemovedOnCompletion = false
                run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                edge.add(run, forKey: "run")
            }
        }
        for (i, letter) in letters.enumerated() {
            let sets = at + OpeningMark.sets(i)
            fade(letter, from: 0, to: 1, at: sets, for: OpeningMark.letterShows, timing: .easeOut)
            spring(letter, "transform.scale", from: OpeningMark.letterFrom, to: 1, at: sets, OpeningMark.letter)
            spring(letter, "transform.translation.y", from: OpeningMark.letterDrop * OpeningMark.wordSize, to: 0, at: sets, OpeningMark.letter)
        }
    }

    /// The design is ready: the mark is pressed flat and the paper clears from `at` on, or, when
    /// the mark never came, the paper simply clears.
    func lift(at: CFTimeInterval, marked: Bool) {
        guard !lifted else { return }
        lifted = true
        guard marked else {
            mark.removeFromSuperlayer()
            word.removeFromSuperlayer()
            fade(paper, from: 1, to: 0, at: at, for: OpeningCover.quick, timing: .easeOut)
            return
        }
        let clears = OpeningCover.lifting - OpeningMark.clears
        if !calm {
            fade(mark, from: 1, to: 0, at: at, for: OpeningMark.flattens, timing: .easeInEaseOut)
            let flat = CABasicAnimation(keyPath: "transform.scale")
            flat.fromValue = 1
            flat.toValue = OpeningMark.flatTo
            flat.duration = OpeningMark.flattens
            flat.beginTime = at
            flat.fillMode = .forwards
            flat.isRemovedOnCompletion = false
            flat.timingFunction = CAMediaTimingFunction(name: .easeIn)
            mark.add(flat, forKey: "flat")
            fade(word, from: 1, to: 0, at: at, for: OpeningMark.flattens, timing: .easeInEaseOut)
        }
        fade(paper, from: 1, to: 0, at: at + (calm ? 0 : OpeningMark.clears), for: calm ? OpeningCover.lifting : clears, timing: .easeInEaseOut)
    }

    // MARK: Animations

    /// Opacity from one to another, held at the start before and at the end after.
    private func fade(_ layer: CALayer, from: Float, to: Float, at: CFTimeInterval, for duration: Double,
                      timing: CAMediaTimingFunctionName = .easeInEaseOut) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = at
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(a, forKey: "fade\(to)")
    }

    /// A value carried along a spring's course, from its start held before.
    private func spring(_ layer: CALayer, _ keyPath: String, from: CGFloat, to: CGFloat, at: CFTimeInterval, _ spring: OpeningMark.Spring) {
        let course = spring.course()
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = course.map { from + (to - from) * CGFloat($0.v) }
        a.keyTimes = course.map { NSNumber(value: $0.t / spring.settles) }
        a.calculationMode = .linear
        a.duration = spring.settles
        a.beginTime = at
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: keyPath)
    }
}

/// The cover in SwiftUI, over the tab's page while its design opens.
struct OpeningCoverHost: NSViewRepresentable {
    let opening: DesignTab.Opening

    func makeNSView(context: Context) -> OpeningCoverView {
        let view = OpeningCoverView(cover: opening.cover)
        opening.view = view
        return view
    }

    func updateNSView(_ view: OpeningCoverView, context: Context) {}
}
