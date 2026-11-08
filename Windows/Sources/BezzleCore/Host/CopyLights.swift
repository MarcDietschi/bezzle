import Foundation

// What the canvas shows of copies on Windows, as the Mac's ComponentTool draws it: the light that
// runs from a copy changed to every copy that followed, the copies as they were until it reaches
// them, an outline drawn round what was just made a component, and the row of variants beside a
// copy picked (Canvas/ComponentTool.swift; the store's componentEcho).

extension WindowsCore {
    /// What the last change did to copies, as the Mac's store.componentEcho: the copies it came
    /// from and those that followed, whether they were just made copies, and the design before a
    /// change made at once (none during a drag), whose copies show until the light reaches them.
    nonisolated(unsafe) static var copyEcho: (echo: ComponentEcho, token: Int, was: BezzleDocument?)?
    nonisolated(unsafe) private static var echoes = 0

    /// Tells the canvas what a change did to copies (the Mac's noteEcho): only one that reached
    /// other copies.
    static func noteEcho(_ echo: ComponentEcho?, was: BezzleDocument?) {
        guard let echo, !echo.to.isEmpty else { return }
        tellEcho(echo, was: was)
    }

    /// Copies just made, by making a component or linking to one: an outline is drawn round each.
    static func tellEcho(_ echo: ComponentEcho, was: BezzleDocument?) {
        echoes &+= 1
        copyEcho = (echo, echoes, was)
    }

    /// The last echo, as the canvas takes it: which, from what, to what, whether made, and whether
    /// the copies as they were can be shown.
    nonisolated public struct CopyEchoLook: Sendable {
        public let token: Int
        public let from: [UUID]
        public let to: [UUID]
        public let made: Bool
        public let was: Bool
    }

    public static var copyEchoLook: CopyEchoLook? {
        copyEcho.map { CopyEchoLook(token: $0.token, from: $0.echo.from, to: $0.echo.to, made: $0.echo.made, was: $0.was != nil) }
    }

    /// A copy as it shows on the canvas: its corners, turned as it is, in canvas points (the Mac's
    /// ComponentTool.corners); nil when it is not there, or lies in a post of a deck turned to
    /// another (`seen`).
    public static func copyCorners(_ id: UUID) -> [CGPoint]? {
        // The design as it is, not as a change pointed at shows it, as the Mac's store.doc.
        guard let doc = previewBase ?? design, let copy = doc.node(id), let inst = copy.instance, copySeen(id, in: doc) else { return nil }
        let o = doc.parentOrigin(of: copy.id) + copy.frame.origin
        if let t = inst.turn, t != 0 {
            let c = CGPoint(x: inst.box.midX + o.x, y: inst.box.midY + o.y)
            return Geometry.corners(of: CGRect(x: c.x - inst.box.width / 2, y: c.y - inst.box.height / 2, width: inst.box.width, height: inst.box.height), rotation: t)
        }
        return Geometry.corners(of: CGRect(origin: o, size: copy.frame.size), rotation: 0)
    }

    /// Whether a copy is seen: not in a post of a deck turned to another.
    static func copySeen(_ id: UUID, in doc: BezzleDocument) -> Bool {
        guard let (deck, post) = doc.post(of: id) else { return true }
        return post == nil ? false : post == deck.front(in: fronts)
    }

    /// A copy as it looked before the change the light runs from, drawn whole where it was, over
    /// as much of the stage (`stage` big) as it covers, `scale` pixels a point, into pixels as
    /// `render(board:)` does; where, or nil (the Mac's ComponentTool ghosts).
    public static func copyGhost(_ id: UUID, scale: Double, zoom: Double, pan: CGPoint, stage: CGSize,
                                 into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
        guard let was = copyEcho?.was, var old = was.node(id), let frame = was.absoluteFrame(of: id) else { return nil }
        old.frame.origin = frame.origin
        let reach = Renderer.reach(of: old)
        let z = CGFloat(zoom), toView = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: pan.x, ty: pan.y)
        let box = reach.insetBy(dx: -2, dy: -2).applying(toView).intersection(CGRect(origin: .zero, size: stage))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        return overlay(box: box, scale: scale, into: fill) { ctx in
            ctx.concatenate(toView)
            Renderer.withFlippedContext(ctx) {
                Renderer.drawNode(old, in: ctx, options: Renderer.Options(deviceScale: CGFloat(scale) * z, assets: assets))
            }
        }
    }

    /// With a copy picked, every other copy of its component, by id, as its corners on the canvas.
    public static func otherCopiesByID(_ selection: [UUID]) -> [(id: UUID, corners: [CGPoint])] {
        guard let doc = previewBase ?? design, let copy = doc.selectedCopy(selection) ?? doc.selectedCopies(selection).first,
              let inst = copy.instance else { return [] }
        return doc.copies(of: inst.of).filter { $0.id != copy.id && !$0.hidden && copySeen($0.id, in: doc) }.compactMap { other in
            doc.shownCorners(of: other.id).map { (other.id, $0) }
        }
    }
}

// MARK: - The row of variants

extension WindowsCore {
    /// The row of variants under (or beside) a copy picked, as the Mac's ComponentTool.row has
    /// it: the copy, its variants and their names, the one it shows, and how wide each one's card
    /// is for its height of 30 (from 24 to 96, as the variant is wide).
    nonisolated public struct VariantRow: Sendable, Equatable {
        public let copy: UUID
        public let variants: [Int?]
        public let names: [String]
        public let current: Int
        public let widths: [Double]
        /// Counts the changes to the copy and its component, for the cards' pictures to be made again.
        public let version: Int
    }

    /// The row for the copy picked, when its component has variants and it can be changed.
    public static func variantRow(_ selection: [UUID]) -> VariantRow? {
        // The design as it is: pointing at a card shows the copy as that variant, which the row
        // goes on showing as the one it was.
        guard !isReadOnly, let doc = previewBase ?? design, let copy = doc.selectedCopy(selection), !copy.locked,
              let inst = copy.instance, let master = doc.component(of: copy) else { return nil }
        let variants = Components.variants(of: master)
        guard variants.count >= 2 else { return nil }
        let h = 30.0
        let widths = variants.map { v -> Double in
            let b = Components.box(of: master, variant: v)
            return min(96, max(24, h * (b.height > 0 ? Double(b.width / b.height) : 1)))
        }
        let current = variants.firstIndex { $0 == Components.variant(inst.variant, of: master) } ?? 0
        let stamp: Int
        if let seen = rowSeen, seen.copy == copy, seen.master == master {
            stamp = seen.stamp
        } else {
            stamp = (rowSeen?.stamp ?? 0) &+ 1
            rowSeen = (copy, master, stamp)
        }
        return VariantRow(copy: copy.id, variants: variants, names: variants.map { Components.name(of: $0, in: master) },
                          current: current, widths: widths, version: stamp)
    }

    /// The copy and component the row's pictures were last made for.
    nonisolated(unsafe) private static var rowSeen: (copy: Node, master: Node, stamp: Int)?

    /// The copy as it shows on the canvas, upright, for the row to lie beside.
    public static func copyBox(_ id: UUID) -> CGRect? {
        guard let corners = copyCorners(id), let first = corners.first else { return nil }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let x0 = xs.min() ?? first.x, y0 = ys.min() ?? first.y
        return CGRect(x: x0, y: y0, width: (xs.max() ?? x0) - x0, height: (ys.max() ?? y0) - y0)
    }
}
