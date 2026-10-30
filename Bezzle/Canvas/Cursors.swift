import AppKit

/// Pointers the system does not have: a resize arrow at any angle, so it follows a turned
/// layer's sides, and a curved arrow for turning.
enum Cursors {
    private static var resizeCache: [Int: NSCursor] = [:]
    private static var rotateCache: [Int: NSCursor] = [:]
    private static var penCache: [PenMark: NSCursor] = [:]

    /// What a click with the pen does where the pointer is, marked beside the nib.
    enum PenMark: Hashable {
        /// Puts the next point down.
        case none
        /// Adds a point to the outline.
        case add
        /// Takes the point away.
        case remove
        /// Closes the path on its first point.
        case close
        /// Takes the handle off the last point, so the next part leaves it straight.
        case convert
        /// Carries on drawing from an open end.
        case carryOn
    }

    /// A two-headed arrow pointing `degrees` clockwise from horizontal.
    static func resize(_ degrees: Double) -> NSCursor {
        // Both ends look the same, so half a turn is enough, in steps of 15°.
        let key = Int(((degrees.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180) / 15).rounded()) % 12
        if let c = resizeCache[key] { return c }
        let cursor = NSCursor(image: draw(size: 24) { ctx in
            ctx.translateBy(x: 12, y: 12)
            ctx.rotate(by: -CGFloat(Double(key) * 15) * .pi / 180)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -8, y: 0))
            p.addLine(to: CGPoint(x: -4, y: 4)); p.addLine(to: CGPoint(x: -4, y: 1.2))
            p.addLine(to: CGPoint(x: 4, y: 1.2)); p.addLine(to: CGPoint(x: 4, y: 4))
            p.addLine(to: CGPoint(x: 8, y: 0))
            p.addLine(to: CGPoint(x: 4, y: -4)); p.addLine(to: CGPoint(x: 4, y: -1.2))
            p.addLine(to: CGPoint(x: -4, y: -1.2)); p.addLine(to: CGPoint(x: -4, y: -4))
            p.closeSubpath()
            outlined(p, in: ctx)
        }, hotSpot: NSPoint(x: 12, y: 12))
        resizeCache[key] = cursor
        return cursor
    }

    /// A curved arrow round the corner at `degrees` (the corner's direction from the centre).
    static func rotate(_ degrees: Double) -> NSCursor {
        let key = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 15).rounded()) % 24
        if let c = rotateCache[key] { return c }
        let cursor = NSCursor(image: draw(size: 26) { ctx in
            ctx.translateBy(x: 13, y: 13)
            // Drawn for the bottom right corner, then turned to the one it is for.
            ctx.rotate(by: -CGFloat(Double(key) * 15 - 45) * .pi / 180)
            let p = CGMutablePath()
            let r: CGFloat = 7
            p.addArc(center: CGPoint(x: -4, y: 4), radius: r, startAngle: -.pi * 0.42, endAngle: .pi * 0.08, clockwise: false)
            let arc = p.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
            let heads = CGMutablePath()
            let a = CGPoint(x: -4 + r * cos(-.pi * 0.42), y: 4 + r * sin(-.pi * 0.42))
            let b = CGPoint(x: -4 + r * cos(.pi * 0.08), y: 4 + r * sin(.pi * 0.08))
            heads.move(to: CGPoint(x: a.x - 3.6, y: a.y + 0.4)); heads.addLine(to: CGPoint(x: a.x + 1.4, y: a.y - 3.6)); heads.addLine(to: CGPoint(x: a.x + 1.4, y: a.y + 3.6)); heads.closeSubpath()
            heads.move(to: CGPoint(x: b.x + 0.4, y: b.y + 3.6)); heads.addLine(to: CGPoint(x: b.x - 3.6, y: b.y - 1.4)); heads.addLine(to: CGPoint(x: b.x + 3.6, y: b.y - 1.4)); heads.closeSubpath()
            let whole = CGMutablePath()
            whole.addPath(arc); whole.addPath(heads)
            outlined(whole, in: ctx)
        }, hotSpot: NSPoint(x: 13, y: 13))
        rotateCache[key] = cursor
        return cursor
    }

    /// A pen nib, its point at the top left where the click lands, with a small mark beside it.
    static func pen(_ mark: PenMark) -> NSCursor {
        if let c = penCache[mark] { return c }
        let cursor = NSCursor(image: draw(size: 24, flipped: true) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: 4, y: 4)
            ctx.rotate(by: -.pi / 4)
            // The nib, its shoulders, and the collar above them, as on the tool's button.
            let nib = CGMutablePath()
            nib.move(to: .zero)
            nib.addQuadCurve(to: CGPoint(x: 4.6, y: 9.4), control: CGPoint(x: 4.8, y: 4.6))
            nib.addLine(to: CGPoint(x: -4.6, y: 9.4))
            nib.addQuadCurve(to: .zero, control: CGPoint(x: -4.8, y: 4.6))
            nib.closeSubpath()
            nib.addRect(CGRect(x: -3.4, y: 11, width: 6.8, height: 2.2))
            outlined(nib, in: ctx)
            // The slit and the hole at its top, cut out of the ink.
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: 1.6))
            ctx.addLine(to: CGPoint(x: 0, y: 5.4))
            ctx.strokePath()
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: CGRect(x: -1.3, y: 5.6, width: 2.6, height: 2.6))
            ctx.restoreGState()

            let c = CGPoint(x: 18.5, y: 18.5)
            let m = CGMutablePath()
            switch mark {
            case .none:
                break
            case .add:
                m.move(to: CGPoint(x: c.x - 3, y: c.y)); m.addLine(to: CGPoint(x: c.x + 3, y: c.y))
                m.move(to: CGPoint(x: c.x, y: c.y - 3)); m.addLine(to: CGPoint(x: c.x, y: c.y + 3))
            case .remove:
                m.move(to: CGPoint(x: c.x - 3, y: c.y)); m.addLine(to: CGPoint(x: c.x + 3, y: c.y))
            case .close:
                m.addEllipse(in: CGRect(center: c, size: CGSize(width: 5.4, height: 5.4)))
            case .convert:
                m.move(to: CGPoint(x: c.x - 3, y: c.y + 1.8)); m.addLine(to: CGPoint(x: c.x, y: c.y - 1.8)); m.addLine(to: CGPoint(x: c.x + 3, y: c.y + 1.8))
            case .carryOn:
                m.move(to: CGPoint(x: c.x - 2.4, y: c.y + 3)); m.addLine(to: CGPoint(x: c.x + 2.4, y: c.y - 3))
            }
            guard !m.isEmpty else { return }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(m)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(3.4)
            ctx.strokePath()
            ctx.addPath(m)
            ctx.setStrokeColor(.black)
            ctx.setLineWidth(1.4)
            ctx.strokePath()
        }, hotSpot: NSPoint(x: 4, y: 4))
        penCache[mark] = cursor
        return cursor
    }

    /// Ink with a white rim, as the system's pointers are drawn.
    private static func outlined(_ path: CGPath, in ctx: CGContext) {
        ctx.addPath(path)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(2.4)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(.black)
        ctx.fillPath()
    }

    private static func draw(size: CGFloat, flipped: Bool = false, _ body: @escaping (CGContext) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: flipped) { _ in
            if let ctx = NSGraphicsContext.current?.cgContext { body(ctx) }
            return true
        }
    }
}
