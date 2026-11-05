import Foundation
import CoreGraphics
import WebGeometry

/// The elements of a path as numbers: each element's kind, then its points.
func numbers(_ p: CoreGraphics.CGPath) -> [Double] {
    var out: [Double] = []
    p.applyWithBlock { e in
        let n: Int
        switch e.pointee.type {
        case .moveToPoint: out.append(0); n = 1
        case .addLineToPoint: out.append(1); n = 1
        case .addQuadCurveToPoint: out.append(2); n = 2
        case .addCurveToPoint: out.append(3); n = 3
        case .closeSubpath: out.append(4); n = 0
        @unknown default: n = 0
        }
        for i in 0..<n { out.append(e.pointee.points[i].x); out.append(e.pointee.points[i].y) }
    }
    return out
}

func numbers(_ p: WebGeometry.CGPath) -> [Double] {
    var out: [Double] = []
    p.applyWithBlock { e in
        let n: Int
        switch e.pointee.type {
        case .moveToPoint: out.append(0); n = 1
        case .addLineToPoint: out.append(1); n = 1
        case .addQuadCurveToPoint: out.append(2); n = 2
        case .addCurveToPoint: out.append(3); n = 3
        case .closeSubpath: out.append(4); n = 0
        }
        for i in 0..<n { out.append(e.pointee.points[i].x); out.append(e.pointee.points[i].y) }
    }
    return out
}

/// How far apart two element lists are: infinite when their shapes differ.
func apart(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count else { return .infinity }
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

func checkPaths() {
    var worst: [String: Double] = [:]
    func note(_ what: String, _ d: Double, _ detail: @autoclosure () -> String) {
        if d > (worst[what] ?? -1) { worst[what] = d; if d > 1e-9 { print("paths: \(what) apart by \(d): \(detail())") } }
    }
    for _ in 0..<20_000 {
        let r = CoreGraphics.CGRect(x: v(), y: v(), width: abs(v()) + 0.5, height: abs(v()) + 0.5)
        let wr = WebGeometry.CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        note("ellipse", apart(numbers(CoreGraphics.CGPath(ellipseIn: r, transform: nil)), numbers(WebGeometry.CGPath(ellipseIn: wr, transform: nil))), "\(r)")
        let cw = min(abs(v()), r.width / 2), ch = min(abs(v()), r.height / 2)
        note("roundedRect", apart(numbers(CoreGraphics.CGPath(roundedRect: r, cornerWidth: cw, cornerHeight: ch, transform: nil)),
                                  numbers(WebGeometry.CGPath(roundedRect: wr, cornerWidth: cw, cornerHeight: ch, transform: nil))), "\(r) \(cw) \(ch)")
        note("rect", apart(numbers(CoreGraphics.CGPath(rect: r, transform: nil)), numbers(WebGeometry.CGPath(rect: wr, transform: nil))), "\(r)")
        let start = v(), end = v(), cw2 = Bool.random()
        let m = CoreGraphics.CGMutablePath(), w = WebGeometry.CGMutablePath()
        m.addArc(center: CoreGraphics.CGPoint(x: r.midX, y: r.midY), radius: r.width, startAngle: start, endAngle: end, clockwise: cw2)
        w.addArc(center: WebGeometry.CGPoint(x: r.midX, y: r.midY), radius: r.width, startAngle: start, endAngle: end, clockwise: cw2)
        note("addArc", apart(numbers(m), numbers(w)), "from \(start) to \(end) clockwise \(cw2)")
        let m2 = CoreGraphics.CGMutablePath(), w2 = WebGeometry.CGMutablePath()
        let p0 = (v(), v()), p1 = (v(), v()), p2 = (v(), v()), rad = abs(v()) + 0.25
        m2.move(to: CoreGraphics.CGPoint(x: p0.0, y: p0.1)); m2.addArc(tangent1End: CoreGraphics.CGPoint(x: p1.0, y: p1.1), tangent2End: CoreGraphics.CGPoint(x: p2.0, y: p2.1), radius: rad)
        w2.move(to: WebGeometry.CGPoint(x: p0.0, y: p0.1)); w2.addArc(tangent1End: WebGeometry.CGPoint(x: p1.0, y: p1.1), tangent2End: WebGeometry.CGPoint(x: p2.0, y: p2.1), radius: rad)
        note("addArc tangents", apart(numbers(m2), numbers(w2)), "\(p0) \(p1) \(p2) r \(rad)")
        let mb = m.boundingBoxOfPath, wb = w.boundingBoxOfPath
        note("boundingBoxOfPath", apart([mb.minX, mb.minY, mb.width, mb.height], [wb.minX, wb.minY, wb.width, wb.height]), "arc \(start) \(end)")
        let q = CoreGraphics.CGPoint(x: v(), y: v())
        let e = CoreGraphics.CGPath(ellipseIn: r, transform: nil), we = WebGeometry.CGPath(ellipseIn: wr, transform: nil)
        if e.contains(q) != we.contains(WebGeometry.CGPoint(x: q.x, y: q.y)) { note("contains", 1, "\(r) ∋ \(q)") }
    }
    for (k, d) in worst.sorted(by: { $0.key < $1.key }) { print(String(format: "paths: %-18@ largest difference %.3g", k as NSString, d)) }
}
