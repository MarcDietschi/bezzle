import AppKit

/// A part or an icon from the resources panel, dragged over the canvas: the real thing, at the
/// size it will be, under the pointer. Over an artboard it takes the artboard's light or dark;
/// a bar springs to the edge it belongs on, as wide as the artboard, and a list stretches across
/// it, following the pointer up and down; an icon over another icon shows taking its place. The
/// artboard it will go onto is outlined, and a label says what letting go does.
final class ResourceDropTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}

    private(set) var resource: Resource?
    private(set) var plan: ResourcePlacing?
    /// Where the ghost is drawn, on the canvas, easing toward where the plan puts it.
    private var shown: CGRect?
    private var velocity = (x: CGFloat(0), y: CGFloat(0), w: CGFloat(0), h: CGFloat(0))
    private var easing = false
    private var link: Timer?
    private var lastStep: CFTimeInterval = 0
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        self.store = store
    }

    func begin(_ resource: Resource) {
        self.resource = resource
        plan = nil
        shown = nil
        easing = false
    }

    /// The drag is over a canvas point, on a layer or on nothing. Whether letting go would add it.
    func update(at p: CGPoint, on target: UUID?) -> Bool {
        guard let resource else { return false }
        let old = plan
        plan = store.placing(resource, at: p, on: target)
        guard let plan else { redraw(); return false }
        let goal = plan.node.frame
        // A change of how it fits, or of where, eases; otherwise it stays under the pointer.
        let jumped = old.map { $0.fit != plan.fit || $0.board != plan.board || $0.swap != plan.swap } ?? false
        if shown == nil { shown = goal } else if jumped || easing { startEasing() } else { shown = goal }
        redraw()
        return true
    }

    func end() {
        resource = nil
        plan = nil
        shown = nil
        easing = false
        link?.invalidate()
        link = nil
        redraw()
    }

    // MARK: Easing

    private func startEasing() {
        easing = true
        guard link == nil else { return }
        lastStep = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        link = timer
    }

    /// One step of a spring a little short of still, so a bar settling on an edge lands with
    /// the faintest give.
    private func step() {
        guard let goal = plan?.node.frame, var r = shown else { link?.invalidate(); link = nil; return }
        let now = CACurrentMediaTime(), dt = min(now - lastStep, 1.0 / 30)
        lastStep = now
        let stiffness: CGFloat = 520, damping: CGFloat = 38
        func spring(_ x: inout CGFloat, _ v: inout CGFloat, _ to: CGFloat) {
            v += ((to - x) * stiffness - v * damping) * dt
            x += v * dt
        }
        var x = r.minX, y = r.minY, w = r.width, h = r.height
        spring(&x, &velocity.x, goal.minX)
        spring(&y, &velocity.y, goal.minY)
        spring(&w, &velocity.w, goal.width)
        spring(&h, &velocity.h, goal.height)
        r = CGRect(x: x, y: y, width: w, height: h)
        let near = abs(x - goal.minX) + abs(y - goal.minY) + abs(w - goal.width) + abs(h - goal.height) < 0.3
        let still = abs(velocity.x) + abs(velocity.y) + abs(velocity.w) + abs(velocity.h) < 4
        if near && still {
            r = goal
            velocity = (0, 0, 0, 0)
            easing = false
            link?.invalidate()
            link = nil
        }
        shown = r
        redraw()
    }

    // MARK: Drawing

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        guard let plan, let r = shown else { return }
        deviceScale = scale
        let vp = store.viewport
        let toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        let board = plan.board.flatMap { store.node($0) }

        // The artboard it goes onto, or the icon it replaces, outlined in pencil.
        if let swap = plan.swap, let frame = store.doc.absoluteFrame(of: swap) {
            ctx.saveGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(frame.applying(toView).insetBy(dx: -3, dy: -3))
            ctx.restoreGState()
        } else if let board {
            ctx.saveGState()
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(plan.fit == .free ? 0.4 : 0.75).cgColor)
            ctx.setLineWidth(plan.fit == .free ? 1.5 : 2)
            ctx.stroke(board.frame.applying(toView).insetBy(dx: -1, dy: -1))
            ctx.restoreGState()
        }

        // The ghost itself: what is made, drawn where it is easing to, a little lifted.
        let node = plan.node
        guard node.frame.width > 0, node.frame.height > 0 else { return }
        ctx.saveGState()
        if let board, plan.fit != .free {
            // Docked or stretched, it stays on the artboard, as it will.
            ctx.addRect(board.frame.applying(toView))
            ctx.clip()
        }
        ctx.concatenate(toView)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: r.width / node.frame.width, y: r.height / node.frame.height)
        ctx.translateBy(x: -node.frame.minX, y: -node.frame.minY)
        ctx.setAlpha(plan.swap == nil ? 0.94 : 0.85)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        var options = Renderer.Options()
        options.deviceScale = scale * vp.zoom
        options.assets = store.assets
        if let board {
            options.board = board
            options.offset = CGPoint(x: -board.frame.minX, y: -board.frame.minY)
        }
        Renderer.withFlippedContext(ctx) { Renderer.drawNode(node, in: ctx, options: options) }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        drawLabel(label(plan, board: board), under: r.applying(toView), in: bounds, ctx)
    }

    private func label(_ plan: ResourcePlacing, board: Node?) -> String {
        if let swap = plan.swap, let old = store.node(swap) {
            return String(localized: "Replace \(old.name)")
        }
        switch (plan.fit, board?.name) {
        case (.top, let name?): return String(localized: "Along the top of \(name)")
        case (.bottom, let name?): return String(localized: "Along the bottom of \(name)")
        case (.across, let name?): return String(localized: "Across \(name)")
        case (_, let name?): return String(localized: "Add to \(name)")
        default: return String(localized: "Add to the canvas")
        }
    }

    /// The same small pencil-blue pill the picture drops use, under the ghost, kept on screen.
    private func drawLabel(_ text: String, under r: CGRect, in bounds: CGRect, _ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var pill = CGRect(x: (r.midX - size.width / 2 - 9).rounded(), y: (r.maxY + 12).rounded(), width: (size.width + 18).rounded(), height: 22)
        pill.origin.x = min(max(pill.minX, bounds.minX + 8), bounds.maxX - pill.width - 8)
        if pill.maxY > bounds.maxY - 8 { pill.origin.y = max(bounds.minY + 8, (r.minY - 34).rounded()) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * deviceScale), blur: 4 * deviceScale, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(at: CGPoint(x: pill.minX + 9, y: pill.minY + (22 - size.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// What the resources panel is dragging, kept here while it is dragged: the pasteboard only says
/// that it is one.
@MainActor
enum ResourceDrag {
    static let type = NSPasteboard.PasteboardType("com.erik.bezzle.resource")
    static var current: Resource?
    /// The small picture the drag started with, to show again once it leaves the canvas.
    static var picture: NSImage?
}
