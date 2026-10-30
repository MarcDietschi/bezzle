import AppKit
import Observation

/// The canvas: artboards lying on a table, drawn with Core Graphics, and everything the pointer
/// and keyboard do to them. The document itself only changes through the store.
final class CanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let store: DocumentStore
    /// Opens one of Bezzle's own menus at a point in the window (y measured from the top).
    var onContextMenu: ((CGPoint, [MenuEntry]) -> Void)?

    private enum Interaction {
        case none
        case pan(startOrigin: CGPoint, startView: CGPoint)
        case marquee(start: CGPoint, base: [UUID], inside: UUID?)
        case move(start: CGPoint, originals: [UUID: CGRect], bounds: CGRect, targets: SnapTargets, started: Bool, duplicate: Bool)
        case resize(handle: Handle, originals: [UUID: Node], absolute: [UUID: CGRect], bounds: CGRect, rotation: Double, targets: SnapTargets)
        case rotate(center: CGPoint, startAngle: CGFloat, originals: [UUID: Node], absolute: [UUID: CGRect])
        case lineEnd(id: UUID, fixed: CGPoint, targets: SnapTargets)
        case create(tool: Tool, start: CGPoint, id: UUID?, board: UUID?, targets: SnapTargets)
        case corner(id: UUID, frame: CGRect, rotation: Double, corner: Handle)
        case shadow(id: UUID, start: CGPoint, original: CGPoint, started: Bool)
    }

    private enum HandleHit {
        case resize(Handle)
        case rotate(Handle)
        case lineEnd(Int)
        /// A dot inside a corner of a selected rectangle, which rounds the corners.
        case corner(Handle)
        /// The selected layer's shadow, outside the layer itself, which moves the shadow.
        case shadow
        /// Just outside the middle of a side, which turns what is picked in depth.
        case turnInDepth
    }

    private var interaction: Interaction = .none
    private var spaceHeld = false
    /// Whether the pointer is on the selected rectangle, so the dots that round its corners show.
    private var showsCornerDots = false
    /// Whether the pointer is on the selected layer's shadow, so its outline shows.
    private var onShadow = false
    private var lastViewPoint: CGPoint = .zero
    private var mouseDownView: CGPoint = .zero
    private var laidOut = false
    /// A preview eases in and out, drawn again each frame while it does.
    private let previewMotion = PreviewMotion()
    private var easing: CADisplayLink?

    // Text being typed into, in a text view laid over the canvas.
    private var editorHost: FlippedView?
    private var editor: NSTextView?
    private var editorUndo = UndoManager()
    private var editingAction: LocalizedStringResource = "Typing"

    /// The pen, and the points of a path being edited.
    private(set) lazy var pathTool: PathTool = {
        let tool = PathTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A picture being placed inside the layer it fills.
    private(set) lazy var pictureTool: PictureTool = {
        let tool = PictureTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.clicked = { [weak self] v in self?.cutoutTool.click(at: v) }
        return tool
    }()

    /// A picture being cut out, and the subjects of one cut out being picked.
    private(set) lazy var cutoutTool: CutoutTool = {
        let tool = CutoutTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Cutting shapes apart along a line.
    private(set) lazy var knifeTool: KnifeTool = {
        let tool = KnifeTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Joining and wiping away the pieces overlapping shapes make.
    private(set) lazy var shapeBuilder: ShapeBuilder = {
        let tool = ShapeBuilder(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Rounding a path's corners, and pulling a shape's outline out or in.
    private(set) lazy var outlineTool: OutlineTool = {
        let tool = OutlineTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Turning layers in depth: the knob a turned layer's face points with, and the sides' grips.
    private(set) lazy var depthTool: DepthTool = {
        let tool = DepthTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.pick = { [weak self] p in self?.pick(p) }
        return tool
    }()

    /// A selected repeat grid's handles and gaps, and the copies of a layer selected in one of its cells.
    private(set) lazy var gridTool: GridTool = {
        let tool = GridTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A deck's stack of posts, the strip that turns them, and every post spread out at once.
    private(set) lazy var deckTool: DeckTool = {
        let tool = DeckTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Files dragged in from elsewhere, shown doing what they would do before they are let go.
    private(set) lazy var dropTool: DropTool = {
        let tool = DropTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    init(store: DocumentStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The table is a well pressed into the paper, with soft corners.
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // Tiles are drawn on other threads, and the canvas is drawn again as they come.
        tiles.maker = TileMaker.shared
        tiles.arrived = { [weak self] in self?.needsDisplay = true }
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        store.undoManager = window?.undoManager
        if window != nil { window?.makeFirstResponder(self) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let old = store.canvasSize
        store.canvasSize = newSize
        if !laidOut, newSize.width > 0, newSize.height > 0 {
            laidOut = true
            if store.doc.viewport == nil { store.zoomToFit() }
        } else if old.width > 0 {
            // The view keeps its centre when the window is resized.
            var v = store.viewport
            v.origin.x -= (newSize.width - old.width) / 2 / v.zoom
            v.origin.y -= (newSize.height - old.height) / 2 / v.zoom
            store.viewport = v
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.needsDisplay = true
                self?.syncEditor()
            }
        }
    }

    private var deviceScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func keepEasing() {
        guard easing == nil else { return }
        let link = displayLink(target: self, selector: #selector(easeStep))
        link.add(to: .main, forMode: .common)
        easing = link
    }

    @objc private func easeStep(_ link: CADisplayLink) {
        needsDisplay = true
        if !previewMotion.isMoving && !deckTool.isAnimating {
            link.invalidate()
            easing = nil
        }
    }

    private func render() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vp = store.viewport
        ctx.setFillColor(CanvasInk.table.cgColor)
        ctx.fill(bounds)
        deckTool.drawStacks(ctx, in: bounds)

        ctx.saveGState()
        ctx.scaleBy(x: vp.zoom, y: vp.zoom)
        ctx.translateBy(x: -vp.origin.x, y: -vp.origin.y)
        var options = Renderer.Options()
        options.artboardShadows = true
        options.deviceScale = deviceScale
        options.visible = store.visibleCanvasRect
        options.screen = options.visible
        options.assets = store.assets
        // Tiles drawn on other threads cannot ask the window whether it is light or dark.
        options.artboardShadowInk = RGBA(CanvasInk.shadow)
        // A picture wanted at a new size is read away from here; what showed it is made again then.
        options.picturesLater = true
        if store.assets.ready == nil {
            store.assets.ready = { [weak self] name in
                self?.tiles.forget(showing: name)
                BlurCache.shared.forget(showing: name)
                self?.needsDisplay = true
            }
        }
        if let editing = store.editingText { options.skipping = [editing] }
        let shown = previewMotion.frame(of: store.shownDoc, preview: store.preview, at: CACurrentMediaTime())
        options.settling = previewMotion.isMoving
        drawDesign(shown, in: ctx, options: options)
        ctx.restoreGState()
        if previewMotion.isMoving || deckTool.isAnimating { keepEasing() }
        cutoutTool.draw(ctx, scale: deviceScale)
        if cutoutTool.animating { redrawSoon() }

        drawSlideCuts(ctx)
        drawArtboardTitles(ctx)
        drawHover(ctx)
        drawSelection(ctx)
        pathTool.draw(ctx, scale: deviceScale)
        pictureTool.draw(ctx, scale: deviceScale)
        outlineTool.draw(ctx, scale: deviceScale)
        depthTool.draw(ctx, scale: deviceScale)
        gridTool.draw(ctx, scale: deviceScale)
        dropTool.draw(ctx, scale: deviceScale, in: bounds)
        shapeBuilder.draw(ctx, scale: deviceScale)
        knifeTool.draw(ctx, scale: deviceScale)
        if pictureTool.animating { redrawSoon() }
        drawGuides(ctx)
        drawMarquee(ctx)
        drawMeasurement(ctx)
        deckTool.draw(ctx, scale: deviceScale, in: bounds)
        if deckTool.isAnimating { keepEasing() }
        _ = store.tool
    }

    /// The design: each artboard from its tiles, so that moving about a large design draws a few
    /// pictures; loose layers, and an artboard being typed on, as they are.
    private func drawDesign(_ doc: BezzleDocument, in ctx: CGContext, options: Renderer.Options) {
        let now = CACurrentMediaTime()
        // While the view moves, a frame makes only as many tiles as leave it smooth, measured by
        // the screen's own frames: a ProMotion display shows one every 8 ms, and 12 spent on tiles
        // would miss every other. Once it has stayed put, more, so what is in sight is sharp sooner.
        if store.viewport != lastViewport {
            lastViewport = store.viewport
            viewportMoved = now
        }
        let still = now - viewportMoved > 0.3 && !store.inGesture
        let frame = 1 / CFTimeInterval(max(window?.screen?.maximumFramesPerSecond ?? 60, 30))
        let deadline = now + (still ? 0.03 : max(frame - 0.005, 0.002))
        let visible = options.visible ?? .infinite
        let typingOn = store.editingText.flatMap { doc.artboard(of: $0)?.id }
        var again = false
        tiles.begin(scale: store.viewport.zoom * deviceScale, now: now, artboards: Set(doc.nodes.lazy.filter(\.isArtboard).map(\.id)))
        for whole in doc.nodes where !whole.hidden {
            guard whole.isArtboard else {
                if Geometry.bounds(of: whole).insetBy(dx: -64, dy: -64).intersects(visible) { Renderer.drawNode(whole, in: ctx, options: options) }
                continue
            }
            // A deck shows the post in front of it.
            let node = whole.isDeck ? whole.showing(store.front(of: whole)) : whole
            guard node.frame.insetBy(dx: -40 / store.viewport.zoom, dy: -40 / store.viewport.zoom).intersects(visible) else { continue }
            if node.id == typingOn {
                Renderer.drawArtboard(node, in: ctx, options: options)
                continue
            }
            var alone = options
            alone.settling = false
            let more = tiles.draw(node, in: ctx, visible: visible, shadowPixels: 28 * deviceScale, now: now, deadline: deadline,
                                  live: options.settling, still: still, make: { rect, step, changing in
                var making = options
                // While it is being changed, its background blurs show what they last showed, and
                // catch up once it is left alone.
                making.settling = changing
                return Renderer.tile(of: node, rect: rect, scale: step, options: making)
            }, away: { [alone] rect, step in Renderer.tile(of: node, rect: rect, scale: step, options: alone) })
            again = again || more
        }
        if again { redrawSoon() }
    }

    let tiles = BoardTiles()
    private var lastViewport = Viewport()
    private var viewportMoved: CFTimeInterval = 0
    private var redrawPending = false

    /// Draws again next frame, to make the tiles that had to wait; each frame makes only as many
    /// as leave the pointer and keys free. A timer of the run loop's own, so it also fires while a
    /// menu is open or the window is being resized.
    private func redrawSoon() {
        guard !redrawPending else { return }
        redrawPending = true
        let timer = Timer(timeInterval: 0.016, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.redrawPending = false
                self?.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var titleWidths: [String: CGFloat] = [:]

    /// Room at the right of a carousel's first slide for its number, which the name stops short of.
    private static let slideNumberRoom: CGFloat = 28

    private func titleRect(of board: Node) -> CGRect {
        var r = store.viewport.toView(board.frame)
        if board.isCarousel, let slide = board.slideSize { r.size.width = slide.width * store.viewport.zoom - Self.slideNumberRoom }
        let measured = titleWidths[board.name] ?? {
            let w = (board.name as NSString).size(withAttributes: [.font: Self.titleFont]).width
            if titleWidths.count > 2000 { titleWidths.removeAll() }
            titleWidths[board.name] = w
            return w
        }()
        return CGRect(x: r.minX, y: r.minY - 19, width: min(measured + 2, max(r.width, 40)), height: 16)
    }

    private func drawArtboardTitles(_ ctx: CGContext) {
        let selected = Set(store.selection)
        for board in store.doc.artboards where !board.hidden {
            // Too small on screen for its name to be read.
            guard board.frame.width * store.viewport.zoom >= 30 else { continue }
            let rect = titleRect(of: board)
            let color = selected.contains(board.id) || store.hovered == board.id ? CanvasInk.labelSelected : CanvasInk.label
            if board.isCarousel { drawSlideNumbers(board, color: color) }
            guard rect.intersects(bounds) else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (board.name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: Self.titleFont, .foregroundColor: color, .paragraphStyle: paragraph])
        }
    }

    /// Each slide's number over its top right corner, in the line the artboard's name is in.
    private func drawSlideNumbers(_ board: Node, color: NSColor) {
        let zoom = store.viewport.zoom
        // Only once a slide leaves room for the name's least width beside its number.
        guard let slide = board.slideSize, slide.width * zoom >= Self.slideNumberRoom + 40 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color]
        for (i, rect) in board.slideRects.enumerated() {
            let r = store.viewport.toView(rect.offsetBy(dx: board.frame.minX, dy: board.frame.minY))
            guard r.maxX >= bounds.minX, r.minX <= bounds.maxX else { continue }
            let number = "\(i + 1)" as NSString
            let w = number.size(withAttributes: attributes).width
            number.draw(at: CGPoint(x: r.maxX - w, y: r.minY - 19), withAttributes: attributes)
        }
    }

    /// Where a carousel will be cut into slides: a dashed line down each cut, over what is on it.
    /// Only on the canvas; nothing of it is exported.
    private func drawSlideCuts(_ ctx: CGContext) {
        let zoom = store.viewport.zoom
        for board in store.doc.artboards where !board.hidden && board.isCarousel && board.slideCount > 1 {
            guard let slide = board.slideSize, slide.width * zoom >= 4 else { continue }
            let r = store.viewport.toView(board.frame)
            guard r.intersects(bounds) else { continue }
            ctx.saveGState()
            for i in 1..<board.slideCount {
                let x = crisp(CGPoint(x: r.minX + CGFloat(i) * slide.width * zoom, y: 0)).x
                guard x >= bounds.minX, x <= bounds.maxX else { continue }
                ctx.move(to: CGPoint(x: x, y: max(r.minY, bounds.minY)))
                ctx.addLine(to: CGPoint(x: x, y: min(r.maxY, bounds.maxY)))
            }
            guard let cuts = ctx.path else { ctx.restoreGState(); continue }
            ctx.setLineWidth(1)
            // A light line under the blue dashes keeps the cut in sight on dark slides and light ones.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.strokePath()
            ctx.addPath(cuts)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A layer's outline on screen: its four corners, turned with it in the page and in depth,
    /// and with any group above it that is turned in depth.
    private func viewCorners(of id: UUID) -> [CGPoint]? {
        guard let node = store.node(id) else { return nil }
        let points: [CGPoint]
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node) }
        } else {
            points = Perspective.corners(of: node)
        }
        return points.map { store.viewport.toView(store.doc.shown($0, inParentOf: id)) }
    }

    /// Where a point of a layer, given on the canvas as it would lie flat, shows: turned in depth
    /// with it and with any group above it.
    private func shownOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint {
        let o = store.doc.parentOrigin(of: node.id)
        return store.doc.shown(Perspective.shown(p - o, of: node), inParentOf: node.id)
    }

    /// The other way: where on the layer, lying flat, a point of the canvas is. Nil past its horizon.
    private func flatOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint? {
        let o = store.doc.parentOrigin(of: node.id)
        return store.doc.placed(p, inParentOf: node.id).flatMap { Perspective.flat($0, of: node) }.map { $0 + o }
    }

    /// Whether a layer shows anywhere but where its frame says, turned in depth or in a group that is.
    private func inDepth(_ node: Node) -> Bool {
        Perspective(node) != nil || store.doc.liesInDepth(node.id)
    }

    private func outlinePath(_ points: [CGPoint], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points.map(crisp))
        if closed { p.closeSubpath() }
        return p
    }

    /// Lines of one pixel fall on whole pixels.
    private func crisp(_ p: CGPoint) -> CGPoint {
        let s = deviceScale
        return CGPoint(x: (p.x * s).rounded() / s + 0.5 / s, y: (p.y * s).rounded() / s + 0.5 / s)
    }

    private func drawHover(_ ctx: CGContext) {
        guard case .none = interaction, let id = store.hovered, !store.selection.contains(id),
              let points = viewCorners(of: id) else { return }
        ctx.saveGState()
        if let node = store.node(id), node.kind == .path, !inDepth(node) {
            // A path is outlined along itself rather than round its frame.
            let vp = store.viewport, o = store.doc.parentOrigin(of: id)
            var t = CGAffineTransform(translationX: o.x, y: o.y)
                .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
            let outline = Renderer.placedOutline(of: node)
            ctx.addPath(outline.copy(using: &t) ?? outline)
        } else {
            ctx.addPath(outlinePath(points, closed: points.count > 2))
        }
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The frame the handles sit on: the layer's own for one, the box around them all for several.
    private var handleFrame: (frame: CGRect, rotation: Double, single: Node?)? {
        let ids = store.selection
        guard !ids.isEmpty else { return nil }
        if ids.count == 1, let node = store.node(ids[0]), let frame = store.doc.absoluteFrame(of: ids[0]) {
            return (frame, node.rotation, node)
        }
        guard let bounds = store.selectionBounds else { return nil }
        return (bounds, 0, nil)
    }

    private func handlePoints() -> [(Handle, CGPoint)] {
        guard let (frame, rotation, single) = handleFrame else { return [] }
        if single?.kind == .line || single?.locked == true { return [] }
        // A repeat grid has handles of its own, which repeat it.
        if single?.isRepeatGrid == true { return [] }
        let size = store.viewport.toView(frame).size
        return Handle.allCases.compactMap { h in
            // A carousel is as high as its slides: only its sides and corners pull it.
            if single?.isCarousel == true && h.unit.x == 0.5 { return nil }
            // Small things keep only their corners, so the handles do not pile up.
            if !h.isCorner && ((h.unit.x == 0.5 && size.width < 28) || (h.unit.y == 0.5 && size.height < 28)) { return nil }
            let at = Geometry.point(h.unit, of: frame, rotation: rotation)
            return (h, store.viewport.toView(single.map { shownOnCanvas(at, of: $0) } ?? at))
        }
    }

    private func drawSelection(_ ctx: CGContext) {
        let ids = store.selection
        // A path whose points show has those instead of a frame and handles.
        if ids.count == 1, ids[0] == pathTool.shownPath { return }
        // A picture being placed has its own edges and corners instead.
        if ids.count == 1, ids[0] == store.editingPicture { return }
        // Shapes being built with show their pieces instead.
        if store.building != nil { return }
        guard !ids.isEmpty, store.editingText == nil || ids.count > 1 else {
            if let editing = store.editingText, let points = viewCorners(of: editing) {
                ctx.addPath(outlinePath(points, closed: true))
                ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            return
        }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        for id in ids {
            guard let points = gridTool.outline(of: id) ?? viewCorners(of: id) else { continue }
            ctx.addPath(outlinePath(points, closed: points.count > 2))
            ctx.strokePath()
        }
        if ids.count > 1, let (frame, _, _) = handleFrame {
            ctx.addPath(outlinePath(Geometry.corners(of: frame, rotation: 0).map(store.viewport.toView), closed: true))
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        if case .move(_, _, _, _, true, _) = interaction { return }
        if ids.count == 1, let node = store.node(ids[0]), node.kind == .line, !node.locked, let ends = viewCorners(of: ids[0]) {
            for p in ends { drawHandle(p, in: ctx, round: true) }
            return
        }
        for (_, p) in handlePoints() { drawHandle(p, in: ctx, round: false) }
        if case .corner = interaction { drawCornerDots(ctx) } else if case .none = interaction, showsCornerDots { drawCornerDots(ctx) }
        if onShadow || { if case .shadow(_, _, _, true) = interaction { return true } else { return false } }() { drawShadowOutline(ctx) }
    }

    /// The dots inside a selected rectangle's corners, along the diagonal as far in as the corners
    /// are round, and never nearer a corner than ten points on screen. Only for a rectangle big
    /// enough on screen for them not to crowd it.
    private func cornerDots() -> [(Handle, CGPoint)] {
        guard store.tool == .select, store.editingText == nil, store.selection.count == 1, let node = store.node(store.selection[0]),
              node.kind == .rectangle, !node.locked, !inDepth(node), let frame = store.doc.absoluteFrame(of: node.id) else { return [] }
        let zoom = store.viewport.zoom
        guard frame.width * zoom >= 48, frame.height * zoom >= 48 else { return [] }
        let half = min(frame.width, frame.height) / 2
        let inset = min(max(min(max(node.cornerRadius, 0), half), 10 / zoom), half)
        return [Handle.topLeft, .topRight, .bottomRight, .bottomLeft].map { h in
            let sx: CGFloat = h.unit.x == 0 ? 1 : -1, sy: CGFloat = h.unit.y == 0 ? 1 : -1
            let local = CGPoint(x: (h.unit.x - 0.5) * frame.width + sx * inset, y: (h.unit.y - 0.5) * frame.height + sy * inset)
            let v = Geometry.rotate(local, by: node.rotation)
            return (h, store.viewport.toView(CGPoint(x: frame.midX + v.x, y: frame.midY + v.y)))
        }
    }

    private func drawCornerDots(_ ctx: CGContext) {
        for (_, p) in cornerDots() {
            let rect = CGRect(center: p, size: CGSize(width: 7, height: 7))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The selected layer's shape where its shadow falls, dashed, while the pointer is on it.
    private func drawShadowOutline(_ ctx: CGContext) {
        guard store.selection.count == 1, let node = store.node(store.selection[0]), let frame = store.doc.absoluteFrame(of: node.id) else { return }
        let shadowFrame = frame.offsetBy(dx: node.shadow.x, dy: node.shadow.y)
        ctx.saveGState()
        ctx.addPath(outlinePath(Geometry.corners(of: shadowFrame, rotation: node.rotation).map(store.viewport.toView), closed: true))
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Whether a point on screen is on the selected layer's shadow and not on the layer itself.
    private func isOnShadow(_ v: CGPoint) -> Bool {
        guard store.tool == .select, store.editingText == nil, store.selection.count == 1, let node = store.node(store.selection[0]),
              node.shadow.outside, !node.locked, !node.isArtboard, node.kind != .line, !inDepth(node),
              let frame = store.doc.absoluteFrame(of: node.id) else { return false }
        let p = store.viewport.toCanvas(v)
        let own = Geometry.local(p, in: frame, rotation: node.rotation)
        if abs(own.x) <= frame.width / 2 + tolerance && abs(own.y) <= frame.height / 2 + tolerance { return false }
        // As far out as the shadow shows, and a little more when it is a fine one.
        let spread = max(node.shadow.blur / 2, 6 / store.viewport.zoom)
        let shadowFrame = frame.offsetBy(dx: node.shadow.x, dy: node.shadow.y)
        let q = Geometry.local(p, in: shadowFrame, rotation: node.rotation)
        return abs(q.x) <= shadowFrame.width / 2 + spread && abs(q.y) <= shadowFrame.height / 2 + spread
    }

    private func drawHandle(_ p: CGPoint, in ctx: CGContext, round: Bool) {
        let size: CGFloat = 8
        let rect = CGRect(center: crisp(p), size: CGSize(width: size, height: size)).offsetBy(dx: -0.5 / deviceScale, dy: -0.5 / deviceScale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(.white)
        if round { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        ctx.restoreGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        if round { ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5)) } else { ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5)) }
    }

    private func drawGuides(_ ctx: CGContext) {
        guard !store.guides.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        for g in store.guides {
            ctx.move(to: crisp(store.viewport.toView(g.from)))
            ctx.addLine(to: crisp(store.viewport.toView(g.to)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawMarquee(_ ctx: CGContext) {
        guard case .marquee(let start, _, _) = interaction else { return }
        let rect = Geometry.rect(from: store.viewport.toView(start), to: lastViewPoint)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.08).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// The size of what is being drawn or resized, in a small pencil-blue pill under it.
    private func drawMeasurement(_ ctx: CGContext) {
        guard let (text, rect) = store.measurement else { return }
        let r = store.viewport.toView(rect)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: (r.midX - size.width / 2 - 7).rounded(), y: (r.maxY + 10).rounded(), width: (size.width + 14).rounded(), height: 20)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (20 - size.height) / 2), withAttributes: attrs)
    }

    // MARK: - Finding things under the pointer

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        store.viewport.toCanvas(convert(event.locationInWindow, from: nil))
    }

    private var tolerance: CGFloat { 4 / store.viewport.zoom }

    /// The topmost layer under a canvas point that a click would select.
    private func hit(_ p: CGPoint) -> UUID? {
        for node in store.doc.nodes.reversed() where !node.hidden {
            if node.isArtboard {
                let inside = node.frame.contains(p)
                guard inside || !node.clips else { continue }
                let local = p - node.frame.origin
                for child in store.seenLayers(of: node).reversed() where !child.hidden && !child.locked {
                    if Geometry.contains(child, local, tolerance: tolerance) { return child.id }
                }
                // An artboard's empty space hides what lies under it.
                if inside { return nil }
            } else if !node.locked, Geometry.contains(node, p, tolerance: tolerance) {
                return node.id
            }
        }
        return nil
    }

    /// The group the selection is in, where clicks look first, as they do after a double click into it.
    private var enteredGroup: Node? {
        guard let first = store.selection.first, let parent = store.doc.parent(of: first), parent.isGroup else { return nil }
        return parent
    }

    /// What in a group lies under a canvas point, one level down.
    private func hit(_ p: CGPoint, in group: Node) -> UUID? {
        guard let inner = store.doc.placed(p, inside: group.id) else { return nil }
        return group.children.reversed().first { !$0.hidden && !$0.locked && Geometry.contains($0, inner, tolerance: tolerance) }?.id
    }

    /// What a click picks: something in the group the selection is in, or else what is under it as usual.
    private func pick(_ p: CGPoint) -> UUID? {
        if let group = enteredGroup, let id = hit(p, in: group) { return id }
        if let id = pickInOtherCell(p) { return id }
        return hit(p)
    }

    /// Inside a cell of a repeat grid, a click on another cell picks what lies there as deep in it
    /// as the selection lies in its own, as if that cell had been entered the same way.
    private func pickInOtherCell(_ p: CGPoint) -> UUID? {
        guard let group = enteredGroup, let grid = store.grid(holding: group.id), grid.id != group.id,
              let here = RepeatGrid.cell(of: group.id, in: grid, doc: store.doc),
              let root = hit(p, in: grid), let there = RepeatGrid.cell(of: root, in: grid, doc: store.doc),
              let other = store.node(group.id.mixed(RepeatGrid.key(here.cell)).mixed(RepeatGrid.key(there.cell))) else { return nil }
        return hit(p, in: other)
    }

    private func titleHit(_ viewPoint: CGPoint) -> UUID? {
        store.doc.artboards.reversed().first { !$0.hidden && titleRect(of: $0).insetBy(dx: 0, dy: -2).contains(viewPoint) }?.id
    }

    private func handleHit(_ v: CGPoint) -> HandleHit? {
        guard store.editingText == nil, store.editingPath == nil, store.editingPicture == nil, store.building == nil else { return nil }
        let ids = store.selection
        if ids.count == 1, let node = store.node(ids[0]), node.kind == .line {
            guard !node.locked, let ends = viewCorners(of: ids[0]) else { return nil }
            for (i, p) in ends.enumerated() where hypot(p.x - v.x, p.y - v.y) <= 7 { return .lineEnd(i) }
            return nil
        }
        let points = handlePoints()
        for (h, p) in points where abs(p.x - v.x) <= 6 && abs(p.y - v.y) <= 6 { return .resize(h) }
        for (h, p) in cornerDots() where hypot(p.x - v.x, p.y - v.y) <= 6 { return .corner(h) }
        // Just outside a corner, the pointer turns things.
        guard let (frame, rotation, single) = handleFrame, single?.isArtboard != true, !store.selection.contains(where: { store.node($0)?.isArtboard == true }) else { return nil }
        let viewFrame = store.viewport.toView(frame)
        let local = Geometry.local(v, in: viewFrame, rotation: rotation)
        var outside = abs(local.x) > viewFrame.width / 2 || abs(local.y) > viewFrame.height / 2
        // Turned in depth, outside the shape it makes.
        if let single, inDepth(single), let corners = viewCorners(of: single.id) {
            outside = !outlinePath(corners, closed: true).contains(v)
        }
        guard outside else { return nil }
        for (h, p) in points where h.isCorner {
            let d = hypot(p.x - v.x, p.y - v.y)
            if d > 5 && d < 20 { return .rotate(h) }
        }
        if isOnShadow(v) { return .shadow }
        // Just outside the middle of a side, the pointer turns them in depth, as outside a corner
        // it turns them in the page.
        for (h, p) in points where !h.isCorner {
            let d = hypot(p.x - v.x, p.y - v.y)
            if d > 5 && d < 22 { return .turnInDepth }
        }
        return nil
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        lastViewPoint = v
        updateHover(v)
        if store.tool == .pen || store.editingPath != nil { pathTool.hover(v, flags: event.modifierFlags) }
        cutoutTool.hover(at: store.editingPicture != nil ? v : nil)
        hoverShapeTools(v, flags: event.modifierFlags)
        updateCursor(v, flags: event.modifierFlags)
        updateOverlays(v)
    }

    /// The knife, building with pieces, and a shape's corners and edge, which each show
    /// something of their own under the pointer.
    private func hoverShapeTools(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        shapeBuilder.hover(v, flags: flags)
        outlineTool.hover(v, flags: flags)
        depthTool.hover(v, flags: flags)
        gridTool.hover(v)
        deckTool.hover(v)
        knifeTool.hover(v, flags: flags)
    }

    /// The corner dots show while the pointer is on the selected rectangle; the shadow's outline
    /// while it is on the shadow.
    private func updateOverlays(_ v: CGPoint) {
        var dots = false
        if case .none = interaction, store.selection.count == 1, let id = store.selection.first, store.node(id)?.kind == .rectangle,
           let points = viewCorners(of: id) {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            dots = path.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v) || path.contains(v)
        }
        let shadow: Bool = if case .none = interaction { isOnShadow(v) && handleHit(v).map { if case .shadow = $0 { true } else { false } } ?? false } else { false }
        if dots != showsCornerDots || shadow != onShadow {
            showsCornerDots = dots
            onShadow = shadow
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        store.hovered = nil
        pathTool.hover(nil, flags: [])
        hoverShapeTools(nil, flags: [])
        NSCursor.arrow.set()
    }

    private func updateHover(_ v: CGPoint) {
        guard case .none = interaction, store.tool == .select else {
            if store.hovered != nil { store.hovered = nil }
            return
        }
        let id = titleHit(v) ?? pick(store.viewport.toCanvas(v))
        if store.hovered != id { store.hovered = id }
    }

    private func updateCursor(_ v: CGPoint, flags: NSEvent.ModifierFlags) {
        if spaceHeld { NSCursor.openHand.set(); return }
        if let cursor = pathTool.cursor { cursor.set(); return }
        if let cursor = pictureTool.cursor(at: v) { cursor.set(); return }
        if let cursor = depthTool.cursor { cursor.set(); return }
        if let cursor = gridTool.cursor(at: v) { cursor.set(); return }
        if let cursor = deckTool.cursor(at: v) { cursor.set(); return }
        if let cursor = shapeBuilder.cursor ?? knifeTool.cursor ?? outlineTool.cursor(at: v) { cursor.set(); return }
        switch store.tool {
        case .select:
            switch handleHit(v) {
            case .resize(let h):
                let rotation = handleFrame?.rotation ?? 0
                Cursors.resize(h.angle + rotation).set()
            case .rotate(let h):
                Cursors.rotate(h.angle + (handleFrame?.rotation ?? 0)).set()
            case .lineEnd, .corner:
                NSCursor.crosshair.set()
            case .shadow:
                NSCursor.openHand.set()
            case .turnInDepth:
                Cursors.turn.set()
            case nil:
                NSCursor.arrow.set()
            }
        case .text:
            NSCursor.iBeam.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A word offered after a change is taken before anything else.
        if deckTool.offerDown(at: convert(event.locationInWindow, from: nil)) { return }
        window?.makeFirstResponder(self)
        if store.editingText != nil { endEditing() }
        let v = convert(event.locationInWindow, from: nil)
        let p = store.viewport.toCanvas(v)
        lastViewPoint = v
        mouseDownView = v
        store.hovered = nil

        if spaceHeld {
            interaction = .pan(startOrigin: store.viewport.origin, startView: v)
            NSCursor.closedHand.set()
            return
        }
        // Every post of a deck spread out takes every press until it is put away.
        if deckTool.spreading, deckTool.down(at: v, event: event) { return }

        switch store.tool {
        case .select:
            // Off the pieces, building is done, and the press goes on as any.
            if shapeBuilder.down(at: v, event: event) { return }
            if store.editingPicture != nil {
                if pictureTool.down(at: v, clicks: event.clickCount) { return }
                // Anywhere off the picture: out of placing, and on as any press.
                store.editingPicture = nil
            }
            if store.editingPath != nil {
                if pathTool.editDown(at: v, event: event) { return }
                // Off the path's points and outline: dragging round points, or, on another
                // layer, out of editing to pick that. A click on nothing at all leaves editing too.
                let other = titleHit(v) ?? pick(p)
                if other == nil || other == store.editingPath {
                    if event.clickCount >= 2 { store.editingPath = nil } else {
                        pathTool.startMarquee(at: v, adding: event.modifierFlags.contains(.shift), offPath: other == nil)
                    }
                    return
                }
                store.editingPath = nil
            }
            selectDown(at: p, view: v, event: event)
        case .pen:
            pathTool.penDown(at: v, event: event)
        case .knife:
            knifeTool.down(at: v, event: event)
        case .text:
            if let id = hit(p), store.node(id)?.kind == .text {
                store.selection = [id]
                beginEditing(id, action: "Typing")
                return
            }
            fallthrough
        default:
            let board = store.tool == .artboard ? nil : store.doc.artboard(at: p)?.id
            let targets = SnapTargets(doc: store.seenDoc, moving: [])
            let start = snapped(p, targets: targets, event: event)
            store.beginGesture()
            interaction = .create(tool: store.tool, start: start, id: nil, board: board, targets: targets)
        }
    }

    private func selectDown(at p: CGPoint, view v: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)

        // A deck's strip turns its posts and adds them; a word offered after a change does what it says.
        if deckTool.down(at: v, event: event) { return }
        // A selected grid's handles repeat it, and its gaps space it.
        if gridTool.down(at: v, event: event) { return }
        // A turned layer's knob aims it in depth.
        if depthTool.down(at: v, event: event) { return }
        // A path's corner dots and a shape's edge with Option, unless a resize handle is in the way.
        let handle = handleHit(v)
        if case .resize = handle {} else if outlineTool.down(at: v, event: event) { return }
        if let handle {
            startHandleDrag(handle, at: p)
            return
        }

        // A double click goes into a group, and each quick click after it one level further,
        // however fast they come; on a text, it starts typing; on a path or a shape, it opens its points.
        if event.clickCount >= 2, let id = pick(p), let node = store.node(id) {
            if node.isGroup, let inner = hit(p, in: node) {
                store.selection = [inner]
                return
            }
            if node.kind == .text {
                store.selection = [id]
                beginEditing(id, action: "Typing")
                return
            }
            // On a picture, it places the picture inside it, and a drag straight on moves it.
            if !node.isArtboard, !node.locked, node.fill.on, node.fill.image != nil {
                store.selection = [id]
                store.editPicture()
                _ = pictureTool.down(at: v, clicks: 1)
                return
            }
            if node.kind == .path {
                store.selection = [id]
                store.editingPath = id
                return
            }
            if !node.locked, node.asPath() != nil {
                store.editAsPath(id)
                return
            }
        }

        if let board = titleHit(v) ?? pick(p) {
            if shift {
                if store.selection.contains(board) { store.selection.removeAll { $0 == board } } else { store.selection.append(board) }
            } else if !store.selection.contains(board) {
                store.selection = [board]
            }
            startMove(at: p, duplicate: event.modifierFlags.contains(.option))
            return
        }

        // Inside the box around several layers, a drag moves them all.
        if store.selection.count > 1, !shift, let bounds = store.selectionBounds, bounds.contains(p) {
            startMove(at: p, duplicate: event.modifierFlags.contains(.option))
            return
        }

        let base = shift ? store.selection : []
        if !shift { store.selection = [] }
        interaction = .marquee(start: p, base: base, inside: store.doc.artboard(at: p)?.id)
    }

    private func startMove(at p: CGPoint, duplicate: Bool) {
        let ids = store.selection.filter { store.node($0)?.locked == false }
        guard !ids.isEmpty, let bounds = store.selectionBounds else { return }
        var originals: [UUID: CGRect] = [:]
        for id in ids { originals[id] = store.doc.absoluteFrame(of: id) }
        interaction = .move(start: p, originals: originals, bounds: bounds, targets: SnapTargets(doc: store.seenDoc, moving: Set(ids)),
                            started: false, duplicate: duplicate)
    }

    private func startHandleDrag(_ hit: HandleHit, at p: CGPoint) {
        let ids = store.selection
        var originals: [UUID: Node] = [:], absolute: [UUID: CGRect] = [:]
        for id in ids {
            originals[id] = store.node(id)
            absolute[id] = store.doc.absoluteFrame(of: id)
        }
        store.beginGesture()
        switch hit {
        case .resize(let handle):
            guard let (frame, rotation, _) = handleFrame else { return }
            interaction = .resize(handle: handle, originals: originals, absolute: absolute, bounds: frame, rotation: rotation,
                                  targets: SnapTargets(doc: store.seenDoc, moving: Set(ids)))
        case .rotate:
            guard let (frame, _, _) = handleFrame else { return }
            let c = frame.center
            interaction = .rotate(center: c, startAngle: atan2(p.y - c.y, p.x - c.x), originals: originals, absolute: absolute)
        case .corner(let corner):
            guard let id = ids.first, let node = store.node(id), let frame = absolute[id] else { return }
            interaction = .corner(id: id, frame: frame, rotation: node.rotation, corner: corner)
        case .turnInDepth:
            // Not a gesture yet, as for a shadow.
            store.cancelGesture()
            depthTool.startTurn(at: store.viewport.toView(p))
        case .shadow:
            // Not a gesture yet: a click here without a drag selects what is under it.
            store.cancelGesture()
            guard let id = ids.first, let node = store.node(id) else { return }
            interaction = .shadow(id: id, start: p, original: CGPoint(x: node.shadow.x, y: node.shadow.y), started: false)
        case .lineEnd(let end):
            guard let id = ids.first, let node = store.node(id) else { return }
            let o = store.doc.parentOrigin(of: id)
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            let (a, b) = node.lineEnds
            // A turned line is straightened out into its ends, so they can be dragged freely.
            let ra = Geometry.rotated(a, about: c, by: node.rotation) + o, rb = Geometry.rotated(b, about: c, by: node.rotation) + o
            store.update([id], "Move Line End") { $0.rotation = 0; $0.setLineEnds(ra - o, rb - o) }
            interaction = .lineEnd(id: id, fixed: end == 0 ? rb : ra, targets: SnapTargets(doc: store.seenDoc, moving: [id]))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        lastViewPoint = v
        drag(to: v, flags: event.modifierFlags)
    }

    private func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        if pathTool.dragging { pathTool.drag(to: v, flags: flags); return }
        if pictureTool.dragging { pictureTool.drag(to: v, flags: flags); return }
        if shapeBuilder.dragging { shapeBuilder.drag(to: v, flags: flags); return }
        if outlineTool.dragging { outlineTool.drag(to: v, flags: flags); return }
        if depthTool.dragging { depthTool.drag(to: v, flags: flags); return }
        if gridTool.dragging { gridTool.drag(to: v, flags: flags); return }
        if deckTool.dragging { deckTool.drag(to: v, flags: flags); return }
        if knifeTool.dragging { knifeTool.drag(to: v, flags: flags); return }
        let p = store.viewport.toCanvas(v)
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let snapping = !flags.contains(.command)
        let threshold = 5 / store.viewport.zoom

        switch interaction {
        case .none:
            break

        case .pan(let origin, let startView):
            store.viewport.origin = CGPoint(x: origin.x - (v.x - startView.x) / store.viewport.zoom,
                                            y: origin.y - (v.y - startView.y) / store.viewport.zoom)

        case .marquee(let start, let base, let inside):
            let rect = Geometry.rect(from: start, to: p)
            var picked: [UUID] = []
            if let inside, let board = store.node(inside) {
                let local = rect.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
                picked = store.seenLayers(of: board).filter { !$0.hidden && !$0.locked && Geometry.bounds(of: $0).intersects(local) }.map(\.id)
            } else {
                for n in store.doc.nodes where !n.hidden && !n.locked {
                    if n.isArtboard ? rect.contains(n.frame) : Geometry.bounds(of: n).intersects(rect) { picked.append(n.id) }
                }
            }
            store.selection = base + picked.filter { !base.contains($0) }
            needsDisplay = true

        case .move(let start, let originals, let bounds, let targets, let started, let duplicate):
            if !started {
                guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 else { return }
                store.beginGesture()
                var originals = originals
                if duplicate {
                    var copies: [UUID] = []
                    store.edit("Duplicate") { doc in copies = DocumentStore.duplicate(Array(originals.keys), in: &doc, offset: .zero) }
                    let keys = Array(originals.keys)
                    var fresh: [UUID: CGRect] = [:]
                    for (old, new) in zip(keys, copies) { fresh[new] = originals[old] }
                    originals = fresh
                    store.selection = copies
                }
                interaction = .move(start: start, originals: originals, bounds: bounds, targets: targets, started: true, duplicate: duplicate)
                NSCursor.arrow.set()
                drag(to: v, flags: flags)
                return
            }
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            var guides: [Guide] = []
            if snapping {
                let (shiftBy, g) = targets.snap(moving: bounds.offsetBy(dx: dx, dy: dy), threshold: threshold)
                dx += shift && dx == 0 ? 0 : shiftBy.x
                dy += shift && dy == 0 ? 0 : shiftBy.y
                guides = g
            }
            dx = dx.rounded(); dy = dy.rounded()
            store.edit("Move") { doc in
                for (id, frame) in originals {
                    let o = doc.parentOrigin(of: id)
                    doc.update(id) { $0.frame.origin = CGPoint(x: frame.minX + dx - o.x, y: frame.minY + dy - o.y) }
                }
            }
            store.guides = guides

        case .resize(let handle, let originals, let absolute, let bounds, let rotation, let targets):
            let carousel = originals.count == 1 ? originals.values.first.flatMap { $0.isCarousel ? $0 : nil } : nil
            // Turned in depth, the pull is measured on the layer as it would lie flat, where its handle is.
            var p = p, flat = false
            if originals.count == 1, let original = originals.values.first, inDepth(original) {
                guard let onFlat = flatOnCanvas(p, of: original) else { return }
                p = onFlat
                flat = true
            }
            var frame = Geometry.resize(bounds, rotation: rotation, handle: handle, to: p,
                                        keepAspect: shift || keepsAspect(originals, handle), fromCenter: option)
            var guides: [Guide] = []
            if let carousel, let slide = carousel.slideSize, slide.width > 0 {
                // As many whole slides as the pointer reaches past half of one, from the side
                // across from the handle, which stays put.
                let reach = handle.unit.x == 0 ? bounds.maxX - p.x : p.x - bounds.minX
                let size = carousel.carouselSize(count: Int((reach / slide.width).rounded()))
                frame = CGRect(x: handle.unit.x == 0 ? bounds.maxX - size.width : bounds.minX, y: bounds.minY, width: size.width, height: size.height)
            } else if rotation == 0 && !flat {
                if snapping && !option {
                    (frame, guides) = targets.snap(resizing: frame, handle: handle, threshold: threshold)
                }
                frame = Geometry.snapToPixels(frame)
            }
            store.edit("Resize") { doc in
                for (id, original) in originals {
                    guard let whole = absolute[id] else { continue }
                    let o = doc.parentOrigin(of: id)
                    var next = originals.count == 1 ? frame : Geometry.map(whole, from: bounds, to: frame)
                    if originals.count > 1 { next = Geometry.snapToPixels(next) }
                    doc.update(id) { node in
                        node = original
                        node.frame = next.offsetBy(dx: -o.x, dy: -o.y)
                        if node.isGroup {
                            node.children = BezzleDocument.scaled(original.children, from: original.frame.size, to: node.frame.size)
                            node.mask = original.mask.map { BezzleDocument.scaled($0, from: original.frame.size, to: node.frame.size) }
                        }
                        if node.kind == .text {
                            let single = originals.count == 1
                            // From a side, one text's words wrap to the new width: text of auto size
                            // takes a fixed width, its height what its lines take.
                            let wraps = single && handle.unit.y == 0.5
                            // From a corner its box is what is dragged, from the corner across to the
                            // pointer, of fixed size, with its letters and lines as big as fit inside.
                            let fits = single && handle.isCorner && !shift
                            // From the top or bottom, or a corner with Shift, its letters and lines grow
                            // with its box, and a fixed width with them, so its words wrap where they did:
                            // by the side the handle moves, the longer one from a corner as text is wide.
                            // Among others, only text of auto size grows, by the height.
                            let scales = !wraps && !fits && (single || node.style?.sizing == .autoWidth) && whole.width > 0 && whole.height > 0
                            if wraps, node.style?.sizing == .autoWidth { node.style?.sizing = .autoHeight }
                            if fits, let style = original.style { node.fit(style, into: next.size) }
                            if scales {
                                let byHeight = !single || handle.unit.x == 0.5
                                node.style = original.style?.scaled(by: byHeight ? next.height / whole.height : next.width / whole.width)
                            }
                            node.refit()
                            // Its words settle its size to a point or so. The side across from the
                            // handle stays where it was; along it, the text grows as it does with more
                            // words, from its top and from the side it is aligned to. From the middle,
                            // or turned, it stays round the middle.
                            if scales || fits, single {
                                let fitted = node.frame.size
                                if option || rotation != 0 {
                                    let box = next.offsetBy(dx: -o.x, dy: -o.y)
                                    node.frame.origin = CGPoint(x: (box.midX - fitted.width / 2).rounded(), y: (box.midY - fitted.height / 2).rounded())
                                } else {
                                    let was = whole.offsetBy(dx: -o.x, dy: -o.y)
                                    let aligned: CGFloat = switch node.style?.align ?? .left {
                                    case .left: 0
                                    case .center: 0.5
                                    case .right: 1
                                    }
                                    let ax = handle.unit.x == 0.5 ? aligned : 1 - handle.unit.x, ay = handle.unit.y == 0.5 ? 0 : 1 - handle.unit.y
                                    node.frame.origin = CGPoint(x: (was.minX + (was.width - fitted.width) * ax).rounded(),
                                                                y: (was.minY + (was.height - fitted.height) * ay).rounded())
                                }
                            }
                        }
                        if node.kind == .line, original.frame.width > 0, original.frame.height > 0 {
                            node.rising = original.rising
                        }
                    }
                    // An artboard's contents stay where they are on the canvas as its edges move.
                    if original.isArtboard {
                        let shift = CGPoint(x: original.frame.minX - next.minX, y: original.frame.minY - next.minY)
                        doc.update(id) { b in
                            for i in b.children.indices { b.children[i].frame = b.children[i].frame.offsetBy(dx: shift.x, dy: shift.y) }
                        }
                    }
                }
            }
            store.guides = guides
            // Text ends up the size its words take, not quite the box dragged out.
            var shown = frame
            if originals.count == 1, let (id, original) = originals.first, original.kind == .text, let f = store.doc.absoluteFrame(of: id) {
                shown = f
            }
            if let carousel, let slide = carousel.slideSize, slide.width > 0 {
                let count = Int((frame.width / slide.width).rounded())
                store.measurement = (count == 1 ? String(localized: "1 slide") : String(localized: "\(count) slides"), frame)
            } else {
                store.measurement = ("\(Self.number(shown.width)) × \(Self.number(shown.height))", Geometry.bounds(of: shown, rotation: rotation))
            }

        case .rotate(let center, let startAngle, let originals, let absolute):
            var delta = Double((atan2(p.y - center.y, p.x - center.x) - startAngle) * 180 / .pi)
            if shift {
                let base = originals.count == 1 ? originals.values.first!.rotation : 0
                delta = ((base + delta) / 15).rounded() * 15 - base
            }
            store.edit("Rotate") { doc in
                for (id, original) in originals {
                    guard let whole = absolute[id] else { continue }
                    let o = doc.parentOrigin(of: id)
                    _ = whole
                    doc.update(id) { node in
                        node = BezzleDocument.turned(original, by: delta, about: CGPoint(x: center.x - o.x, y: center.y - o.y))
                    }
                }
            }
            let shown = originals.count == 1 ? Self.normalized(originals.values.first!.rotation + delta) : Self.normalized(delta)
            store.measurement = ("\(Self.number(shown))°", store.selectionBounds ?? .zero)

        case .lineEnd(let id, let fixed, let targets):
            var end = Geometry.lineEnd(from: fixed, to: p, constrain: shift)
            var guides: [Guide] = []
            if snapping && !shift {
                let (q, x, y) = targets.snap(point: end, threshold: threshold)
                end = q
                guides = targets.guides(for: CGRect(origin: q, size: .zero), x: x, y: y)
            }
            end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
            let o = store.doc.parentOrigin(of: id)
            store.edit("Move Line End") { doc in doc.update(id) { $0.setLineEnds(fixed - o, end - o) } }
            store.guides = guides
            store.measurement = ("\(Self.number(hypot(end.x - fixed.x, end.y - fixed.y)))", Geometry.rect(from: fixed, to: end))

        case .corner(let id, let frame, let rotation, let corner):
            // How far in along the diagonal the pointer is, measured on each side.
            let local = Geometry.local(p, in: frame, rotation: rotation)
            let sx: CGFloat = corner.unit.x == 0 ? 1 : -1, sy: CGFloat = corner.unit.y == 0 ? 1 : -1
            let along = ((local.x - (corner.unit.x - 0.5) * frame.width) * sx + (local.y - (corner.unit.y - 0.5) * frame.height) * sy) / 2
            let radius = min(max(along, 0), min(frame.width, frame.height) / 2).rounded()
            store.edit("Change Corners") { doc in doc.update(id) { $0.cornerRadius = radius } }
            store.measurement = (String(localized: "Radius \(Self.number(radius))"), Geometry.bounds(of: frame, rotation: rotation))

        case .shadow(let id, let start, let original, let started):
            if !started {
                guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 else { return }
                store.beginGesture()
                interaction = .shadow(id: id, start: start, original: original, started: true)
                NSCursor.closedHand.set()
            }
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            let x = (original.x + dx).rounded(), y = (original.y + dy).rounded()
            store.edit("Move Shadow") { doc in doc.update(id) { $0.shadow.x = x; $0.shadow.y = y } }
            if let frame = store.doc.absoluteFrame(of: id) {
                store.measurement = (String(localized: "Shadow \(Self.number(x)), \(Self.number(y))"), frame.offsetBy(dx: x, dy: y))
            }
            needsDisplay = true

        case .create(let tool, let start, let id, let board, let targets):
            var end = p
            var guides: [Guide] = []
            if snapping {
                let (q, x, y) = targets.snap(point: p, threshold: threshold)
                end = q
                guides = targets.guides(for: CGRect(origin: q, size: .zero), x: x, y: y)
            }
            end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
            guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 || id != nil else { return }
            let nodeID = id ?? createNode(tool, at: start, board: board)
            if id == nil { interaction = .create(tool: tool, start: start, id: nodeID, board: board, targets: targets) }
            let o = store.doc.parentOrigin(of: nodeID)
            if tool == .line {
                end = Geometry.lineEnd(from: start, to: end, constrain: shift)
                end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
                store.edit("Draw") { doc in doc.update(nodeID) { $0.setLineEnds(start - o, end - o) } }
                store.measurement = ("\(Self.number(hypot(end.x - start.x, end.y - start.y)))", Geometry.rect(from: start, to: end))
            } else {
                let rect = Geometry.snapToPixels(Geometry.drawnRect(from: start, to: end, square: shift, fromCenter: option))
                store.edit("Draw") { doc in
                    doc.update(nodeID) { n in
                        n.frame = rect.offsetBy(dx: -o.x, dy: -o.y)
                        if n.kind == .text { n.refit() }
                    }
                }
                store.measurement = ("\(Self.number(rect.width)) × \(Self.number(rect.height))", rect)
            }
            store.guides = guides
        }
    }

    /// Text grows and shrinks in proportion from its top and bottom; from a side its words wrap, and
    /// from a corner both at once.
    private func keepsAspect(_ originals: [UUID: Node], _ handle: Handle) -> Bool {
        originals.count == 1 && originals.values.first?.kind == .text && handle.unit.x == 0.5
    }

    override func mouseUp(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        pathTool.up(at: v, flags: event.modifierFlags)
        pictureTool.up()
        shapeBuilder.up(at: v)
        outlineTool.up()
        depthTool.up(at: v, adding: event.modifierFlags.contains(.shift))
        gridTool.up()
        deckTool.up(at: v)
        knifeTool.up(at: v)
        switch interaction {
        case .none:
            break
        case .pan:
            NSCursor.openHand.set()
        case .marquee:
            needsDisplay = true
        case .move(_, let originals, _, _, let started, let duplicate):
            if started {
                let ids = Array(originals.keys)
                store.edit("Move") { doc in store.settle(ids, in: &doc) }
                store.endGesture(duplicate ? "Duplicate" : "Move")
            }
        case .resize:
            store.endGesture("Resize")
        case .rotate:
            store.endGesture("Rotate")
        case .lineEnd:
            store.endGesture("Move Line End")
        case .corner:
            store.endGesture("Change Corners")
        case .shadow(_, _, _, let started):
            if started {
                store.endGesture("Move Shadow")
            } else {
                // Only a click: whatever is under the shadow is picked, as anywhere else.
                let p = store.viewport.toCanvas(v)
                let id = titleHit(v) ?? pick(p)
                if event.modifierFlags.contains(.shift) {
                    if let id, !store.selection.contains(id) { store.selection.append(id) }
                } else {
                    store.selection = id.map { [$0] } ?? []
                }
            }
        case .create(let tool, let start, let id, let board, _):
            finishCreating(tool, start: start, id: id, board: board)
        }
        interaction = .none
        store.guides = []
        store.measurement = nil
        updateHover(v)
        updateCursor(v, flags: event.modifierFlags)
        updateOverlays(v)
    }

    // MARK: - Drawing new layers

    private func createNode(_ tool: Tool, at p: CGPoint, board: UUID?) -> UUID {
        let kind: Node.Kind = switch tool {
        case .artboard: .artboard
        case .ellipse: .ellipse
        case .line: .line
        case .text: .text
        default: .rectangle
        }
        var node = Node(kind: kind, name: store.doc.nextName(for: kind), frame: CGRect(origin: p, size: .zero))
        if kind == .text {
            node.style?.sizing = .autoHeight
        }
        store.add(node, onto: board)
        return node.id
    }

    private func finishCreating(_ tool: Tool, start: CGPoint, id: UUID?, board: UUID?) {
        var nodeID = id
        if nodeID == nil {
            // A click without a drag makes something of a sensible size.
            nodeID = createNode(tool, at: start, board: board)
            let o = store.doc.parentOrigin(of: nodeID!)
            store.edit("Draw") { doc in
                doc.update(nodeID!) { n in
                    switch n.kind {
                    case .artboard:
                        let size = store.lastPreset ?? Preset.all[0].size
                        n.frame = CGRect(origin: start, size: size)
                    case .line:
                        n.setLineEnds(start - o, CGPoint(x: start.x + 100, y: start.y) - o)
                    case .text:
                        n.style?.sizing = .autoWidth
                        n.frame = CGRect(origin: start - o, size: .zero)
                        n.refit()
                        // The click marks where the first line's middle goes.
                        n.frame.origin.y -= (n.frame.height / 2).rounded()
                    default:
                        n.frame = CGRect(origin: start - o, size: CGSize(width: 100, height: 100))
                    }
                }
            }
        }
        guard let nodeID, let node = store.node(nodeID) else { store.endGesture("Draw"); return }
        // Text that was dragged out keeps at least a usable width.
        if node.kind == .text, node.style?.sizing == .autoHeight, node.frame.width < 20 {
            store.edit("Draw") { doc in doc.update(nodeID) { $0.style?.sizing = .autoWidth; $0.refit() } }
        }
        store.tool = .select
        if node.kind == .text {
            beginEditing(nodeID, action: "Add Text")
        } else {
            store.endGesture(node.kind.adding)
        }
    }

    private func snapped(_ p: CGPoint, targets: SnapTargets, event: NSEvent) -> CGPoint {
        let q = event.modifierFlags.contains(.command) ? p : targets.snap(point: p, threshold: 5 / store.viewport.zoom).0
        return CGPoint(x: q.x.rounded(), y: q.y.rounded())
    }

    // MARK: - Context menu

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if store.editingText != nil { endEditing() }
        let v = convert(event.locationInWindow, from: nil)
        if let id = titleHit(v) ?? pick(store.viewport.toCanvas(v)), !store.selection.contains(id) {
            store.selection = [id]
        }
        let inWindow = event.locationInWindow
        let point = CGPoint(x: inWindow.x, y: (window?.contentView?.bounds.height ?? 0) - inWindow.y)
        onContextMenu?(point, CanvasMenus.entries(for: store))
    }

    // MARK: - Scrolling and zooming

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            let step = event.hasPreciseScrollingDeltas ? 0.012 : 0.1
            let factor = exp(event.scrollingDeltaY * step)
            store.viewport.zoom(to: store.viewport.zoom * factor, keeping: v)
        } else {
            var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
            // Shift scrolls sideways. A mouse wheel usually arrives already turned by the system;
            // a trackpad, or a mouse whose driver leaves it, still scrolls up and down.
            if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
            store.viewport.origin.x -= dx / store.viewport.zoom
            store.viewport.origin.y -= dy / store.viewport.zoom
        }
        updateHover(v)
    }

    // MARK: - Middle button

    /// Holding the wheel down and dragging moves the canvas, whatever tool is in hand.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, case .none = interaction else { return super.otherMouseDown(with: event) }
        let v = convert(event.locationInWindow, from: nil)
        store.hovered = nil
        interaction = .pan(startOrigin: store.viewport.origin, startView: v)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, case .pan = interaction else { return super.otherMouseDragged(with: event) }
        drag(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, case .pan = interaction else { return super.otherMouseUp(with: event) }
        interaction = .none
        let v = convert(event.locationInWindow, from: nil)
        updateCursor(v, flags: event.modifierFlags)
        updateHover(v)
    }

    override func magnify(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        store.viewport.zoom(to: store.viewport.zoom * (1 + event.magnification), keeping: v)
    }

    /// A double tap with two fingers: in to actual size where the pointer is, or back out to everything.
    override func smartMagnify(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if abs(store.viewport.zoom - 1) < 0.01 { store.zoomToFit() } else { store.viewport.zoom(to: 1, keeping: v) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // A picture first: Return on one places it, where on a path it would open the points.
        if pictureTool.key(event) { return }
        // Building and the knife before the pen: Return ends them, where on a path it would open its points.
        if shapeBuilder.key(event) || knifeTool.key(event) { return }
        if event.keyCode == 53, outlineTool.dragging { outlineTool.cancel(); return }
        if event.keyCode == 53, depthTool.dragging { depthTool.cancel(); return }
        if event.keyCode == 53, gridTool.dragging { gridTool.cancel(); return }
        if event.keyCode == 53, deckTool.cancel() { return }
        if pathTool.key(event) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 49: // space
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.set() }
        case 51, 117: // delete
            store.deleteSelection()
        case 53: // escape
            if case .none = interaction {
                if store.tool != .select { store.tool = .select }
                else if let first = store.selection.first, store.selection.count == 1, let parent = store.doc.parent(of: first) {
                    // Out one level: from a layer to its artboard.
                    store.selection = [parent.id]
                } else { store.selection = [] }
            } else {
                store.cancelGesture()
                interaction = .none
            }
        case 36, 76: // return
            if store.selection.count == 1, let id = store.selection.first, store.node(id)?.kind == .text {
                beginEditing(id, action: "Typing")
            }
        case 116: store.turnPage(by: -1) // page up
        case 121: store.turnPage(by: 1) // page down
        case 123: store.nudge(dx: -step, dy: 0)
        case 124: store.nudge(dx: step, dy: 0)
        case 125: store.nudge(dx: 0, dy: step)
        case 126: store.nudge(dx: 0, dy: -step)
        default:
            if flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
               let chars = event.charactersIgnoringModifiers, let tool = Tool.forKey(chars) {
                store.tool = tool
                updateCursor(lastViewPoint, flags: flags)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            updateCursor(lastViewPoint, flags: event.modifierFlags)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option change a drag in progress at once, without waiting for the pointer to move.
        if pathTool.dragging { pathTool.drag(to: lastViewPoint, flags: event.modifierFlags); return }
        if pictureTool.dragging { pictureTool.drag(to: lastViewPoint, flags: event.modifierFlags); return }
        if shapeBuilder.dragging || outlineTool.dragging || knifeTool.dragging || depthTool.dragging || gridTool.dragging {
            drag(to: lastViewPoint, flags: event.modifierFlags)
            updateCursor(lastViewPoint, flags: event.modifierFlags)
            return
        }
        if case .none = interaction {
            if store.tool == .pen || store.editingPath != nil { pathTool.hover(lastViewPoint, flags: event.modifierFlags) }
            hoverShapeTools(lastViewPoint, flags: event.modifierFlags)
            updateCursor(lastViewPoint, flags: event.modifierFlags)
            return
        }
        drag(to: lastViewPoint, flags: event.modifierFlags)
    }

    // MARK: - Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        store.hovered = nil
        dropTool.begin(Dropped(sender.draggingPasteboard))
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = store.viewport.toCanvas(convert(sender.draggingLocation, from: nil))
        return dropTool.update(at: p, on: dropTarget(at: p)) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTool.end()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = store.viewport.toCanvas(convert(sender.draggingLocation, from: nil))
        let dropped = dropTool.dropped ?? Dropped(sender.draggingPasteboard)
        dropTool.end()
        window?.makeFirstResponder(self)
        return store.drop(dropped, at: p, on: dropTarget(at: p))
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTool.end()
    }

    /// The deepest layer under a point, through every group: what a dropped picture or list fills.
    private func dropTarget(at p: CGPoint) -> UUID? {
        guard var id = hit(p) else { return nil }
        while let n = store.node(id), n.isGroup, let inner = hit(p, in: n) { id = inner }
        return id
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) { store.copySelection() }
    @objc func cut(_ sender: Any?) { store.cutSelection() }
    @objc func paste(_ sender: Any?) { store.paste() }
    @objc func delete(_ sender: Any?) {
        if store.editingPath != nil { store.deleteSelectedPoints() } else { store.deleteSelection() }
    }
    @objc override func selectAll(_ sender: Any?) {
        if store.editingPath != nil { store.selectAllPoints() } else { store.selectAll() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return !store.selection.isEmpty
        case #selector(paste(_:)): return store.canPaste
        case #selector(selectAll(_:)): return !store.doc.nodes.isEmpty
        default: return true
        }
    }

    // MARK: - Typing into text layers

    func beginEditing(_ id: UUID, action: LocalizedStringResource) {
        guard !store.isReadOnly, let node = store.node(id), node.kind == .text, editor == nil else { return }
        store.beginGesture()
        editingAction = action
        store.editingText = id
        store.selection = [id]

        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)

        let text = NSTextView(frame: .zero, textContainer: container)
        text.delegate = self
        text.isRichText = false
        text.importsGraphics = false
        text.drawsBackground = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.insertionPointColor = CanvasInk.pencil
        text.selectedTextAttributes = [.backgroundColor: CanvasInk.pencil.withAlphaComponent(0.22)]
        text.focusRingType = .none
        text.string = node.text ?? ""
        applyEditorStyle(node, to: text)

        let host = FlippedView()
        host.addSubview(text)
        addSubview(host)
        editorHost = host
        editor = text
        editorUndo = UndoManager()
        syncEditor()
        window?.makeFirstResponder(text)
        text.selectAll(nil)
    }

    private func applyEditorStyle(_ node: Node, to text: NSTextView) {
        let attrs = TextLayout.attributes(node.style ?? TextStyle(), color: node.fill.on ? node.fill.color : .black)
        let selected = text.selectedRanges
        text.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: text.textStorage?.length ?? 0))
        text.typingAttributes = attrs
        text.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        text.selectedRanges = selected
    }

    /// Keeps the text view over its layer as the canvas moves, zooms and the layer changes.
    func syncEditor() {
        guard let host = editorHost, let text = editor else { return }
        guard let id = store.editingText, let node = store.node(id), let frame = store.doc.absoluteFrame(of: id) else {
            endEditing()
            return
        }
        let zoom = store.viewport.zoom
        let width = max(frame.width, 1) + 6
        let r = store.viewport.toView(frame)
        // Turned while its bounds are one to one with its frame, and only then zoomed: turning it
        // with zoomed bounds puts its middle off by half the zoom's difference, and the text with it.
        let box = CGRect(x: r.minX, y: r.minY, width: width * zoom, height: max(r.height, 4))
        host.frameRotation = 0
        host.bounds = CGRect(origin: .zero, size: box.size)
        host.frame = box
        host.frameCenterRotation = -node.rotation
        host.setBoundsSize(CGSize(width: width, height: max(frame.height, 4 / zoom)))
        let sizing = node.style?.sizing ?? .autoWidth
        let align = node.style?.align ?? .left
        text.textContainer?.size = CGSize(width: sizing == .autoWidth && align == .left ? 100_000 : max(frame.width, 1) + (sizing == .autoWidth ? 0.5 : 0),
                                          height: .greatestFiniteMagnitude)
        text.frame = CGRect(x: 0, y: 0, width: sizing == .autoWidth && align == .left ? width : max(frame.width, 1), height: max(frame.height, 1))
        let wanted = TextLayout.attributes(node.style ?? TextStyle(), color: node.fill.on ? node.fill.color : .black)
        if (text.typingAttributes[.font] as? NSFont) != (wanted[.font] as? NSFont)
            || (text.typingAttributes[.foregroundColor] as? NSColor) != (wanted[.foregroundColor] as? NSColor)
            || (text.typingAttributes[.paragraphStyle] as? NSParagraphStyle) != (wanted[.paragraphStyle] as? NSParagraphStyle)
            || (text.typingAttributes[.kern] as? CGFloat) != (wanted[.kern] as? CGFloat) {
            applyEditorStyle(node, to: text)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let id = store.editingText, let text = editor else { return }
        let string = text.string
        store.edit(editingAction) { doc in
            doc.update(id) { n in
                n.text = string
                n.refit()
            }
        }
        syncEditor()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endEditing()
            window?.makeFirstResponder(self)
            return true
        }
        // In a deck, Tab goes on to the same words in the next post, as in a table; past the
        // last, it makes one more. Shift-Tab goes back.
        if selector == #selector(insertTab(_:)) || selector == #selector(insertBacktab(_:)),
           let id = store.editingText, let (deck, post) = store.doc.post(of: id), let post {
            typeOn(in: deck.id, from: id, post: post, forward: selector == #selector(insertTab(_:)))
            return true
        }
        return false
    }

    /// Ends typing into a text in one post of a deck and starts typing into the same text in the
    /// next post, or the one before; past the last post, in a new one.
    private func typeOn(in deckID: UUID, from id: UUID, post: Int, forward: Bool) {
        guard let deck = store.node(deckID) else { return }
        let posts = deck.posts
        guard let i = posts.firstIndex(of: post) else { return }
        let j = i + (forward ? 1 : -1)
        guard j >= 0 else { return }
        endEditing()
        if j < posts.count {
            store.turn(deckID, to: posts[j])
        } else {
            store.addPost(to: deckID)
        }
        guard let now = store.node(deckID).flatMap({ store.front(of: $0) }) else { return }
        let next = id.mixed(Deck.key(from: post, to: now))
        guard store.node(next) != nil else { return }
        beginEditing(next, action: "Typing")
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    func textDidEndEditing(_ notification: Notification) {
        // Leaving the text for a field in the inspector also ends typing.
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor, self.window?.firstResponder !== editor else { return }
            self.endEditing()
        }
    }

    func endEditing() {
        guard let id = store.editingText else { return }
        editor?.delegate = nil
        editorHost?.removeFromSuperview()
        editorHost = nil
        editor = nil
        store.editingText = nil
        // A text left empty is not kept, but in a grid's cell or a deck's post it is that cell's,
        // or that post's, words.
        if let node = store.node(id), (node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.grid(holding: id) == nil,
           store.doc.post(of: id)?.post == nil {
            store.edit(editingAction) { doc in _ = doc.detach(id) }
            store.selection = []
        }
        store.endGesture(editingAction)
        needsDisplay = true
    }

    // MARK: - Helpers

    /// A measurement to a tenth, as the user's language writes numbers ("12.5", "12,5"), never grouped.
    static func number(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10 + 0
        return Double(r).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return (d * 100).rounded() / 100
    }
}

final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
