import Foundation

// Masks on Windows, as on the Mac (the shared `BezzleDocument.maskPlan`/`mask`/`takeOutOfMasks`,
// see `Mask`): of several layers, a shape holds the rest; taken apart again, or a layer taken out.

extension WindowsCore {
    /// Whether the layers can be masked: a shape among them would hold the rest, which overlap it.
    public static func canMask(_ ids: [UUID]) -> Bool { design?.maskPlan(ids) != nil }

    /// The layers masked as the plan says, as one step; the mask.
    public static func mask(_ ids: [UUID]) -> UUID? {
        guard let plan = design?.maskPlan(ids) else { return nil }
        var made: UUID?
        edit { made = $0.mask(plan) }
        return made.flatMap { design?.node($0) != nil ? $0 : nil }
    }

    /// The mask the layers would make, as the word offered tells of one, for the canvas to show
    /// made while the menu's entry is pointed at.
    public static func maskPlanOffer(_ ids: [UUID]) -> MaskOffer? {
        guard let doc = previewBase ?? design, let plan = doc.maskPlan(ids), var box = doc.canvasBounds(of: plan.shape) else { return nil }
        for id in plan.held { if let r = doc.canvasBounds(of: id) { box = box.union(r) } }
        return MaskOffer(shape: plan.shape, held: plan.held, box: box)
    }

    /// Shows the mask the layers would make, while its menu entry is pointed at.
    public static func previewMask(_ ids: [UUID], _ on: Bool) {
        endPreview()
        guard on, let plan = design?.maskPlan(ids) else { return }
        preview { _ = $0.mask(plan) }
    }

    /// The one mask selected, or the mask the one layer selected lies in.
    public static func selectedMask(_ ids: [UUID]) -> UUID? {
        guard ids.count == 1, let doc = design, let n = doc.node(ids[0]) else { return nil }
        if n.isMask { return n.id }
        return doc.parent(of: n.id).flatMap { $0.isMask ? $0.id : nil }
    }

    /// The mask taken apart: its shape and what it held lie where they are, the shape under them; those.
    public static func releaseMask(_ id: UUID) -> [UUID] {
        guard design?.node(id)?.isMask == true else { return [] }
        var freed: [UUID] = []
        edit { freed = $0.ungroup([id]) }
        return freed.filter { design?.node($0) != nil }
    }

    /// The layers taken out of the masks they lie in, each just above its mask.
    public static func takeOutOfMask(_ ids: [UUID]) {
        edit { $0.takeOutOfMasks(ids) }
    }

    /// The Mask card of the one layer selected: a mask itself (the kind of shape that holds it),
    /// or a layer in one (the name of the shape that holds it). Nil for anything else.
    public static func maskCard(_ ids: [UUID]) -> (isMask: Bool, summary: String, locked: Bool)? {
        guard ids.count == 1, let doc = design, let n = doc.node(ids[0]) else { return nil }
        if n.isMask { return (true, n.holder?.kind.title ?? "", n.locked) }
        guard let mask = doc.parent(of: n.id), mask.isMask, mask.children.first?.id != n.id else { return nil }
        return (false, mask.holder?.name ?? mask.name, mask.locked)
    }

    /// Whether the one layer selected lies in a mask without being the shape that holds it.
    public static func inMask(_ ids: [UUID]) -> Bool { maskCard(ids)?.isMask == false }
}

// MARK: - The word offered, and a drag off a mask

extension WindowsCore {
    /// What the word "Mask" offers to mask, as the Mac's MaskTool: the shape and what it would
    /// hold, and the box round all of them on the canvas, which the word sits above.
    nonisolated public struct MaskOffer: Equatable, Sendable {
        public let shape: UUID
        public let held: [UUID]
        public let box: CGRect
    }

    /// A shape just drawn, moved or resized over a picture, and the design as it was then: the
    /// word offering to mask the picture in it shows until anything else changes.
    nonisolated(unsafe) static var invited: (plan: MaskPlan, doc: BezzleDocument)?

    /// After a shape has been drawn, moved or resized: offers to mask the picture under it, when it
    /// lies mostly over one that reaches past it (the shared `maskInvitation`).
    public static func inviteMask(_ selection: [UUID]) {
        invited = nil
        guard let doc = previewBase ?? design, let plan = doc.maskInvitation(selection) else { return }
        invited = (plan, doc)
    }

    /// What the word offers now, for what is picked: the invitation, while nothing has changed and
    /// the shape is still what is picked, or several layers a shape among them would cut off.
    public static func maskOffer(_ selection: [UUID]) -> MaskOffer? {
        guard let doc = previewBase ?? design else { return nil }
        var plan: MaskPlan?
        if let invited, invited.doc == doc, selection == [invited.plan.shape] { plan = invited.plan }
        if plan == nil { plan = doc.maskOffer(selection) }
        guard let plan, var box = doc.canvasBounds(of: plan.shape) else { return nil }
        for id in plan.held { if let r = doc.canvasBounds(of: id) { box = box.union(r) } }
        return MaskOffer(shape: plan.shape, held: plan.held, box: box)
    }

    /// Shows the mask the word offers made, while it is pointed at, or takes it away again.
    public static func previewOffer(_ offer: MaskOffer, _ on: Bool) {
        endPreview()
        guard on else { return }
        let plan = MaskPlan(shape: offer.shape, held: offer.held)
        preview { _ = $0.mask(plan) }
    }

    /// Makes the mask the word offers, as one step; the mask.
    public static func takeOffer(_ offer: MaskOffer) -> UUID? {
        invited = nil
        let plan = MaskPlan(shape: offer.shape, held: offer.held)
        var made: UUID?
        edit { made = $0.mask(plan) }
        return made.flatMap { design?.node($0) != nil ? $0 : nil }
    }

    /// The mask the layers being moved lie in, when they have been dragged wholly off its shape:
    /// let go, they come out of it.
    public static func leavingMask(_ ids: [UUID]) -> UUID? { design?.leavingMask(ids) }

    /// A mask picked alone: what it holds, for Enter to pick.
    public static func maskHeld(_ selection: [UUID]) -> [UUID]? { design?.maskHeld(selection) }
}

// MARK: - Holding a drag over a shape

extension WindowsCore {
    /// The shape, or the mask, layers being moved are held over at `p` on the canvas (the shared
    /// `maskTarget`).
    public static func dipTarget(at p: CGPoint, moving ids: [UUID]) -> UUID? {
        design?.maskTarget(at: p, moving: ids) { $0.seenLayers(fronts: fronts) }
    }

    /// Whether resting over the shape would put them into it: it holds things, and would cut
    /// something of them off that shows.
    public static func canDip(_ ids: [UUID], over: UUID) -> Bool { design?.cuttingDip(ids, over: over) != nil }

    /// The shape rested on opens, during the move: what is moved goes into it, and the move goes
    /// on inside it, all one step with the move. The mask, or nil when it did not open.
    public static func openDip(_ ids: [UUID], over: UUID) -> UUID? {
        guard let doc = design, let plan = doc.cuttingDip(ids, over: over), let start = Editing.gestureStart else { return nil }
        var made: UUID?
        Editing.gestureBase = Editing.edited(Editing.gestureBase ?? start, start: nil) { made = $0.mask(plan) }
        replayMove()
        return made.flatMap { design?.node($0) != nil ? $0 : nil }
    }

    /// Dragged off the shape it opened, it closes: what it took in is as it was, wherever it is now.
    public static func closeDip() {
        Editing.gestureBase = nil
        replayMove()
    }

    /// Whether `p` on the canvas is still on the mask, its outline or a little way past it (the
    /// pointer may stray `slop` canvas points off it).
    public static func onDip(_ mask: UUID, at p: CGPoint, slop: CGFloat) -> Bool {
        guard let doc = design, let outline = Mask.outline(of: mask, in: doc) else { return false }
        return outline.contains(p) || outline.copy(strokingWithWidth: slop * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).contains(p)
    }

    /// A shape's outline, or a mask's, on the stage (where a canvas point `p` lies at
    /// `pan + p · zoom`), as path data.
    public static func outlineData(of id: UUID, zoom: Double, pan: CGPoint) -> String? {
        guard let doc = design, let n = doc.node(id) else { return nil }
        guard let outline = n.isMask ? Mask.outline(of: id, in: doc) : doc.outline(of: id) else { return nil }
        var t = CGAffineTransform(a: CGFloat(zoom), b: 0, c: 0, d: CGFloat(zoom), tx: pan.x, ty: pan.y)
        return outline.copy(using: &t).map { PathData.string($0) }
    }
}

// MARK: - What the canvas shows of masks

// The Mac's MaskTool draws more than the outline: the line run round a shape as something rests
// over it, the rings an outline draws as something sinks into a mask or comes out, the ghost of
// what a mask cuts off, and the names under a mask opened or left. These are their parts the
// canvas cannot work out by itself.

extension WindowsCore {
    /// Whether the canvas shows a change pointed at rather than the design as it is.
    public static var previewing: Bool { previewBase != nil }

    /// The mask the layers picked lie in, when they are all that is picked and its shape is not
    /// one of them (the Mac's MaskTool.picked).
    public static func maskPicked(_ selection: [UUID]) -> UUID? {
        guard let doc = design, let first = selection.first, let mask = doc.parent(of: first), let holder = mask.holder,
              selection.allSatisfy({ doc.parent(of: $0)?.id == mask.id && $0 != holder.id }) else { return nil }
        return mask.id
    }

    /// The mask the first of these layers lies in, in the design as it shows now.
    public static func mask(holding id: UUID) -> UUID? {
        guard let mask = design?.parent(of: id), mask.isMask else { return nil }
        return mask.id
    }

    /// A shape's outline, or a mask's, on the canvas, as path data: what a ring is drawn from
    /// after the mask has gone.
    public static func canvasOutline(of id: UUID) -> String? {
        guard let doc = design, let n = doc.node(id) else { return nil }
        guard let outline = n.isMask ? Mask.outline(of: id, in: doc) : doc.outline(of: id) else { return nil }
        return PathData.string(outline)
    }

    /// An outline on the canvas (`canvasOutline`) `grown` about its middle (1 as it is), placed
    /// on the stage: its path data there, the box round it and about how long it is, its curves
    /// measured in short straight steps (the Mac's MaskTool.length).
    public static func stageOutline(_ data: String, grown: Double = 1, zoom: Double, pan: CGPoint) -> (data: String, box: CGRect, length: Double)? {
        let path = PathData.cgPath(data)
        let box = path.boundingBoxOfPath
        guard !box.isNull else { return nil }
        let c = CGPoint(x: box.midX, y: box.midY), s = CGFloat(grown)
        var t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(a: CGFloat(zoom), b: 0, c: 0, d: CGFloat(zoom), tx: pan.x, ty: pan.y))
        guard let placed = path.copy(using: &t) else { return nil }
        return (PathData.string(placed), placed.boundingBoxOfPath, Double(length(of: placed)))
    }

    private static func length(of path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var last = CGPoint.zero, start = CGPoint.zero
        func walk(_ to: CGPoint) {
            total += hypot(to.x - last.x, to.y - last.y)
            last = to
        }
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                last = p[0]
                start = p[0]
            case .addLineToPoint:
                walk(p[0])
            case .addQuadCurveToPoint:
                let a = last
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1 - t
                    walk(CGPoint(x: u * u * a.x + 2 * u * t * p[0].x + t * t * p[1].x, y: u * u * a.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                let a = last
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * p[0].x + 3 * u * t * t * p[1].x + t * t * t * p[2].x
                    let y = u * u * u * a.y + 3 * u * u * t * p[0].y + 3 * u * t * t * p[1].y + t * t * t * p[2].y
                    walk(CGPoint(x: x, y: y))
                }
            case .closeSubpath:
                walk(start)
            @unknown default:
                break
            }
        }
        return total
    }

    /// What tells one ghost of `ids` from another: the mask they lie in as it is drawn now, and
    /// where the canvas is. Nil when they lie in no mask.
    public static func maskGhostKey(_ ids: [UUID], zoom: Double, pan: CGPoint) -> Int? {
        guard let doc = design, let first = ids.first, let mask = doc.parent(of: first), mask.isMask else { return nil }
        var h = Hasher()
        // Where each of its layers lies and how it shows: what moves while it is dragged.
        func add(_ n: Node) {
            h.combine(n.id)
            for v in [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height] { h.combine(Double(v)) }
            h.combine(n.rotation)
            h.combine(n.opacity)
            h.combine(n.hidden)
            for c in n.children { add(c) }
        }
        add(mask)
        h.combine(ids)
        h.combine(doc.parentOrigin(of: first).x)
        h.combine(doc.parentOrigin(of: first).y)
        h.combine(zoom)
        h.combine(pan.x)
        h.combine(pan.y)
        return h.finalize()
    }

    /// What of the layers `ids`, inside a mask, reaches past its shape: drawn whole, only past
    /// the outline (inside it, the mask shows them itself), as the Mac's MaskTool.drawGhost does,
    /// at full strength; the canvas fades it. Over as much of the stage (`stage` big) as it
    /// covers, `scale` pixels a point, into pixels as `render(board:)` does; where, or nil.
    public static func maskGhost(_ ids: [UUID], scale: Double, zoom: Double, pan: CGPoint, stage: CGSize,
                                 into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
        guard let doc = design, let first = ids.first, let mask = doc.parent(of: first), mask.isMask,
              let outline = Mask.outline(of: mask.id, in: doc) else { return nil }
        let o = doc.parentOrigin(of: first)
        let layers = mask.children.dropFirst().filter { ids.contains($0.id) && !$0.hidden }
        var reach = CGRect.null
        let eye = doc.eye(inside: mask.id)
        for n in layers { reach = reach.union(Renderer.reach(of: n, eye: eye).offsetBy(dx: o.x, dy: o.y)) }
        guard !reach.isNull else { return nil }
        let z = CGFloat(zoom), toView = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: pan.x, ty: pan.y)
        let box = reach.insetBy(dx: -2, dy: -2).applying(toView).intersection(CGRect(origin: .zero, size: stage))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        return overlay(box: box, scale: scale, into: fill) { ctx in
            ctx.concatenate(toView)
            ctx.beginPath()
            ctx.addRect(reach.insetBy(dx: -2, dy: -2))
            ctx.addPath(outline)
            ctx.clip(using: .evenOdd)
            ctx.translateBy(x: o.x, y: o.y)
            Renderer.withFlippedContext(ctx) {
                let options = Renderer.Options(deviceScale: CGFloat(scale) * z, assets: assets)
                for n in layers { Renderer.drawNode(n, in: ctx, options: options) }
            }
        }
    }

    /// What the canvas says under a mask opened, or left: the name of the shape it is made of,
    /// or its own.
    public static func maskName(_ id: UUID, shape: UUID? = nil) -> String? {
        guard let doc = design else { return nil }
        if let shape, let n = doc.node(shape) { return n.name }
        guard let mask = doc.node(id) else { return nil }
        return mask.holder?.name ?? mask.name
    }
}
