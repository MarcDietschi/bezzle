import CoreGraphics
import WebGeometry

typealias Mac = CoreGraphics.CGRect
typealias Web = WebGeometry.CGRect

// Rectangles of every kind Core Graphics treats apart: ordinary, negative, empty, null, infinite,
// on a coarse grid so that edges often touch.
nonisolated(unsafe) var rng = SystemRandomNumberGenerator()
func v() -> Double { Double(Int.random(in: -6...6, using: &rng)) * [1, 0.5, 2.25][Int.random(in: 0...2, using: &rng)] }
func pair() -> (Mac, Web) {
    switch Int.random(in: 0..<20, using: &rng) {
    case 0: return (.null, .null)
    case 1: return (.infinite, .infinite)
    case 2: return (.zero, .zero)
    default:
        let x = v(), y = v(), w = v(), h = Int.random(in: 0..<5, using: &rng) == 0 ? 0 : v()
        return (Mac(x: x, y: y, width: w, height: h), Web(x: x, y: y, width: w, height: h))
    }
}
func same(_ m: Mac, _ w: Web) -> Bool {
    func eq(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
    return eq(m.origin.x, w.origin.x) && eq(m.origin.y, w.origin.y) && eq(m.size.width, w.size.width) && eq(m.size.height, w.size.height)
}

nonisolated(unsafe) var failures: [String: Int] = [:], checked = 0
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String) {
    checked += 1
    if !ok { failures[what, default: 0] += 1; if failures[what] == 1 { print("differs: \(what): \(detail())") } }
}

for _ in 0..<200_000 {
    let (a, wa) = pair(), (b, wb) = pair()
    let d = v(), e = v()
    check(same(a.standardized, wa.standardized), "standardized", "\(a)")
    check(same(a.integral, wa.integral), "integral", "\(a)")
    check(same(a.insetBy(dx: d, dy: e), wa.insetBy(dx: d, dy: e)), "insetBy", "\(a) by \(d), \(e)")
    check(same(a.offsetBy(dx: d, dy: e), wa.offsetBy(dx: d, dy: e)), "offsetBy", "\(a) by \(d), \(e)")
    check(same(a.union(b), wa.union(wb)), "union", "\(a) ∪ \(b) mac \(a.union(b)) web \(wa.union(wb))")
    check(same(a.intersection(b), wa.intersection(wb)), "intersection", "\(a) ∩ \(b) mac \(a.intersection(b)) web \(wa.intersection(wb))")
    check(a.intersects(b) == wa.intersects(wb), "intersects", "\(a), \(b): mac \(a.intersects(b))")
    check(a.contains(b) == wa.contains(wb), "contains rect", "\(a) ⊇ \(b): mac \(a.contains(b))")
    let p = CoreGraphics.CGPoint(x: d, y: e)
    check(a.contains(p) == wa.contains(WebGeometry.CGPoint(x: d, y: e)), "contains point", "\(a) ∋ \(p): mac \(a.contains(p))")
    for (k, edge) in [CoreGraphics.CGRectEdge.minXEdge, .minYEdge, .maxXEdge, .maxYEdge].enumerated() {
        let m = a.divided(atDistance: d, from: edge), w = wa.divided(atDistance: d, from: WebGeometry.CGRectEdge(rawValue: UInt32(k))!)
        check(same(m.slice, w.slice) && same(m.remainder, w.remainder), "divided", "\(a) at \(d) from \(edge)")
    }
    check([a.minX, a.midX, a.maxX, a.minY, a.midY, a.maxY, a.width, a.height] == [wa.minX, wa.midX, wa.maxX, wa.minY, wa.midY, wa.maxY, wa.width, wa.height],
          "edges", "\(a)")
    check(a.isNull == wa.isNull && a.isEmpty == wa.isEmpty && a.isInfinite == wa.isInfinite, "is", "\(a)")
    let t = CoreGraphics.CGAffineTransform(a: d, b: e, c: v(), d: v(), tx: v(), ty: v())
    let wt = WebGeometry.CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    check(same(a.applying(t), wa.applying(wt)), "applying", "\(a) by \(t) mac \(a.applying(t)) web \(wa.applying(wt))")
    let i = t.inverted(), wi = wt.inverted()
    check([i.a, i.b, i.c, i.d, i.tx, i.ty] == [wi.a, wi.b, wi.c, wi.d, wi.tx, wi.ty], "inverted", "\(t)")
    let u = t.concatenating(CoreGraphics.CGAffineTransform(rotationAngle: d)), wu = wt.concatenating(WebGeometry.CGAffineTransform(rotationAngle: d))
    check([u.a, u.b, u.c, u.d, u.tx, u.ty] == [wu.a, wu.b, wu.c, wu.d, wu.tx, wu.ty], "concatenating rotation", "\(t), \(d)")
    let tr = t.translatedBy(x: d, y: e), wtr = wt.translatedBy(x: d, y: e)
    check([tr.a, tr.b, tr.c, tr.d, tr.tx, tr.ty] == [wtr.a, wtr.b, wtr.c, wtr.d, wtr.tx, wtr.ty], "translatedBy", "\(t)")
    let sc = t.scaledBy(x: d, y: e), wsc = wt.scaledBy(x: d, y: e)
    check([sc.a, sc.b, sc.c, sc.d, sc.tx, sc.ty] == [wsc.a, wsc.b, wsc.c, wsc.d, wsc.tx, wsc.ty], "scaledBy", "\(t)")
    let ro = t.rotated(by: d), wro = wt.rotated(by: d)
    check([ro.a, ro.b, ro.c, ro.d, ro.tx, ro.ty] == [wro.a, wro.b, wro.c, wro.d, wro.tx, wro.ty], "rotated", "\(t) by \(d)")
    let sz = CoreGraphics.CGSize(width: d, height: e).applying(t), wsz = WebGeometry.CGSize(width: d, height: e).applying(wt)
    check(sz.width == wsz.width && sz.height == wsz.height, "size applying", "\(t)")
}
// Off the grid, where a sum is not exact: rectangles as designs have them, one in another, the
// same again, grown or shrunk by a hair or a hundredth, touching an edge, or anywhere. On the grid
// alone, `contains` asked as "adding it changes nothing" agreed everywhere and was wrong for more
// than half of these, (x + w) − x being w only by luck.
func fine() -> Double { Double.random(in: -500...2000, using: &rng) }
func size() -> Double { Double.random(in: 0.1...2000, using: &rng) }
func web(_ r: Mac) -> Web { r.isNull ? .null : Web(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height) }
for _ in 0..<400_000 {
    let a = Int.random(in: 0..<6, using: &rng) == 0
        ? Mac(x: Double(Int.random(in: 0...1920, using: &rng)), y: Double(Int.random(in: 0...1080, using: &rng)),
              width: Double(Int.random(in: 1...900, using: &rng)), height: Double(Int.random(in: 1...900, using: &rng)))
        : Mac(x: fine(), y: fine(), width: size(), height: size())
    var b: Mac
    switch Int.random(in: 0..<9, using: &rng) {
    case 0: b = a
    case 1: b = a.insetBy(dx: Double.random(in: 0...Double(a.width) / 2.1, using: &rng), dy: Double.random(in: 0...Double(a.height) / 2.1, using: &rng))
    case 2: b = a.insetBy(dx: -0.01, dy: -0.01)
    case 3: b = a.insetBy(dx: 0.01, dy: 0.01).insetBy(dx: -0.01, dy: -0.01)
    case 4: b = Mac(x: a.minX, y: a.minY + a.height / 4, width: a.width, height: a.height / 2)
    case 5: b = Mac(x: a.minX.nextDown, y: a.minY, width: a.width, height: a.height)
    case 6: b = Mac(x: a.minX, y: a.minY, width: a.width.nextUp, height: a.height.nextDown)
    case 7: b = a.offsetBy(dx: Double.random(in: -1...1, using: &rng) * Double(a.width), dy: Double.random(in: -1...1, using: &rng) * Double(a.height))
    default: b = Mac(x: fine(), y: fine(), width: size(), height: size())
    }
    let wa = web(a), wb = web(b)
    check(a.contains(b) == wa.contains(wb), "contains rect, off the grid", "\(a) ⊇ \(b): mac \(a.contains(b))")
    check(b.contains(a) == wb.contains(wa), "contains rect, off the grid", "\(b) ⊇ \(a): mac \(b.contains(a))")
    check(a.intersects(b) == wa.intersects(wb), "intersects, off the grid", "\(a), \(b): mac \(a.intersects(b))")
    check(same(a.union(b), wa.union(wb)), "union, off the grid", "\(a) ∪ \(b) mac \(a.union(b)) web \(wa.union(wb))")
    check(same(a.intersection(b), wa.intersection(wb)), "intersection, off the grid", "\(a) ∩ \(b) mac \(a.intersection(b)) web \(wa.intersection(wb))")
    let d = Double.random(in: -3...3, using: &rng), e = Double.random(in: -3...3, using: &rng)
    check(same(a.insetBy(dx: d, dy: e), wa.insetBy(dx: d, dy: e)), "insetBy, off the grid", "\(a) by \(d), \(e)")
    check(same(a.integral, wa.integral), "integral, off the grid", "\(a)")
    let p = CoreGraphics.CGPoint(x: Bool.random(using: &rng) ? a.maxX : a.minX + d, y: Bool.random(using: &rng) ? a.minY : a.maxY + e)
    check(a.contains(p) == wa.contains(WebGeometry.CGPoint(x: p.x, y: p.y)), "contains point, off the grid", "\(a) ∋ \(p): mac \(a.contains(p))")
    check([a.minX, a.midX, a.maxX, a.minY, a.midY, a.maxY, a.width, a.height] == [wa.minX, wa.midX, wa.maxX, wa.minY, wa.midY, wa.maxY, wa.width, wa.height],
          "edges, off the grid", "\(a)")
}
checkPaths()
print(failures.isEmpty ? "all \(checked) checks agree with Core Graphics" : "\(failures.values.reduce(0, +)) of \(checked) differ: \(failures)")
