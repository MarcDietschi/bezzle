import CoreGraphics
import Foundation

/// The line drawn round a picture while its subject is cut out: where the cut will be. It begins
/// as the layer's own outline and pulls tight round the subject as the work goes on, like a loop
/// of thread drawn in, so how far it has closed in says how far the work is. Until the subject
/// has been found it only comes a little loose of the frame; once it has, it makes for it.
///
/// Worked out on a small grid over the layer: how far each cell is from the frame's outline and
/// from the subject's, less than nothing inside. The line runs where a mix of the two is nothing,
/// which is the frame with none of the subject mixed in, the subject with all of it, and between
/// them a line as far from the one as from the other, by the mix. So one line parts into several
/// round several subjects on its own.
nonisolated struct CutoutLoop: Sendable {
    /// Cells across and down the layer's frame.
    let w: Int, h: Int
    /// Cells of nothing kept round the frame, so every line closes.
    private static let rim = 3
    private let frame: [Float]
    /// Where the line makes for while nothing is known of the subject: the frame drawn in a
    /// little, its corners rounded as a thread's are.
    private let loose: [Float]
    private var subject: [Float]?

    /// Whether the subject has been found.
    var found: Bool { subject != nil }

    /// The cells for a layer `size` big, about `side` along its longer side.
    static func cells(for size: CGSize, side: Int = 160) -> (w: Int, h: Int) {
        let long = max(size.width, size.height, 0.0001)
        return (max(8, Int((size.width / long * CGFloat(side)).rounded())), max(8, Int((size.height / long * CGFloat(side)).rounded())))
    }

    /// Round a layer of `w` × `h` cells. `inside` is the layer's outline where it is no plain
    /// rectangle: a value a cell, row by row from the top, 128 and more inside.
    init(w: Int, h: Int, inside: [UInt8]? = nil) {
        self.w = w
        self.h = h
        let W = w + 2 * Self.rim, H = h + 2 * Self.rim
        var frame = [Float](repeating: 0, count: W * H)
        if let inside, inside.count == w * h {
            frame = Self.signed(Self.padded(inside, w, h), W, H)
        } else {
            // A rectangle's outline is known exactly, corners and all.
            let cx = Float(W) / 2, cy = Float(H) / 2, hx = Float(w) / 2, hy = Float(h) / 2
            for y in 0..<H {
                for x in 0..<W {
                    let dx = abs(Float(x) + 0.5 - cx) - hx, dy = abs(Float(y) + 0.5 - cy) - hy
                    let outside = (max(dx, 0) * max(dx, 0) + max(dy, 0) * max(dy, 0)).squareRoot()
                    frame[y * W + x] = outside + min(max(dx, dy), 0)
                }
            }
        }
        self.frame = frame
        let slack = 0.14 * Float(min(w, h))
        loose = Self.blurred(frame, W, H, radius: max(1, Int(slack * 0.8))).map { $0 + slack }
    }

    /// The subject has been found: `mask` says where it lies in the layer, a value a cell of the
    /// frame, row by row from the top, 128 and more on it. Nothing of it found leaves the line as it is.
    mutating func find(_ mask: [UInt8]) {
        guard mask.count == w * h, mask.contains(where: { $0 >= 128 }) else { return }
        let W = w + 2 * Self.rim, H = h + 2 * Self.rim
        let own = Self.signed(Self.padded(mask, w, h), W, H)
        // Only as much of it as lies in the frame.
        subject = zip(own, frame).map { max($0, $1) }
    }

    /// The line with `tight` of the way from the frame to what it makes for behind it (a little
    /// past 1 draws it in past the subject, as a thread pulled tight gives), `found` of the way
    /// from loose of the frame to the subject once that is known. Closed lines, clockwise, across
    /// and down the frame from 0 to 1, each beginning at its point furthest to the frame's top left.
    func lines(tight: Double, found: Double = 1) -> [[CGPoint]] {
        let W = w + 2 * Self.rim, H = h + 2 * Self.rim
        let u = Float(min(max(tight, 0), 1.25)), s = subject == nil ? 0 : Float(min(max(found, 0), 1))
        var field = [Float](repeating: 0, count: W * H)
        frame.withUnsafeBufferPointer { f in
            loose.withUnsafeBufferPointer { l in
                field.withUnsafeMutableBufferPointer { out in
                    if let subject, s > 0 {
                        subject.withUnsafeBufferPointer { t in
                            for i in 0..<(W * H) { out[i] = (1 - u) * f[i] + u * ((1 - s) * l[i] + s * t[i]) }
                        }
                    } else {
                        for i in 0..<(W * H) { out[i] = (1 - u) * f[i] + u * l[i] }
                    }
                }
            }
        }
        let rim = CGFloat(Self.rim)
        return Self.contours(field, W, H).map { line in
            line.map { CGPoint(x: ($0.x - rim) / CGFloat(w), y: ($0.y - rim) / CGFloat(h)) }
        }
    }

    // MARK: Distances

    /// `mask` with the rim of nothing round it, as whether each cell is inside.
    private static func padded(_ mask: [UInt8], _ w: Int, _ h: Int) -> [Bool] {
        let W = w + 2 * rim, H = h + 2 * rim
        var inside = [Bool](repeating: false, count: W * H)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] >= 128 { inside[(y + rim) * W + x + rim] = true }
        }
        return inside
    }

    /// How far each cell is from the outline of what is `inside`, in cells, less than nothing
    /// inside it: smoothed a little, as cells make steps of any slanted outline.
    private static func signed(_ inside: [Bool], _ W: Int, _ H: Int) -> [Float] {
        let toInside = distances(to: inside, W, H), toOutside = distances(to: inside.map { !$0 }, W, H)
        var out = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) { out[i] = inside[i] ? 0.5 - toOutside[i] : toInside[i] - 0.5 }
        return blurred(out, W, H, radius: 1)
    }

    /// How far each cell is from the nearest cell of `set`, nothing for those in it (Felzenszwalb
    /// and Huttenlocher's distance transform: along each row, then down each column).
    private static func distances(to set: [Bool], _ W: Int, _ H: Int) -> [Float] {
        let far: Float = 1e12
        var d = set.map { $0 ? Float(0) : far }
        let n = max(W, H)
        var f = [Float](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        func pass(_ count: Int, _ at: (Int) -> Int) {
            for q in 0..<count { f[q] = d[at(q)] }
            var k = 0
            v[0] = 0
            z[0] = -.infinity
            z[1] = .infinity
            for q in 1..<count {
                var s: Float
                repeat {
                    let p = v[k]
                    s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
            k = 0
            for q in 0..<count {
                while z[k + 1] < Float(q) { k += 1 }
                let p = v[k]
                d[at(q)] = Float((q - p) * (q - p)) + f[p]
            }
        }
        if W > 1 { for y in 0..<H { pass(W) { y * W + $0 } } }
        if H > 1 { for x in 0..<W { pass(H) { $0 * W + x } } }
        return d.map { min($0, far).squareRoot() }
    }

    /// The mean over a square `2 × radius + 1` cells wide, the edge's cells standing for what
    /// would lie beyond it.
    private static func blurred(_ a: [Float], _ W: Int, _ H: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return a }
        var across = [Float](repeating: 0, count: W * H), out = across
        let n = Float(2 * radius + 1)
        for y in 0..<H {
            var sum: Float = 0
            for k in -radius...radius { sum += a[y * W + min(max(k, 0), W - 1)] }
            for x in 0..<W {
                across[y * W + x] = sum / n
                sum += a[y * W + min(x + radius + 1, W - 1)] - a[y * W + max(x - radius, 0)]
            }
        }
        for x in 0..<W {
            var sum: Float = 0
            for k in -radius...radius { sum += across[min(max(k, 0), H - 1) * W + x] }
            for y in 0..<H {
                out[y * W + x] = sum / n
                sum += across[min(y + radius + 1, H - 1) * W + x] - across[max(y - radius, 0) * W + x]
            }
        }
        return out
    }

    // MARK: The line

    /// Where `field` is nothing, between its cells' middles (marching squares): closed lines in
    /// cells, clockwise with y down, each from its point furthest to the top left; specks left out.
    private static func contours(_ field: [Float], _ W: Int, _ H: Int) -> [[CGPoint]] {
        // A crossing lies on the edge between two cells' middles: across from cell x to x + 1
        // (numbered y · W + x), or down from cell y to y + 1 (W · H more).
        let down = W * H
        var points = [CGPoint](repeating: .zero, count: 2 * down)
        var links = [Int32](repeating: -1, count: 4 * down)
        var crossings: [Int] = []
        func middle(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5) }
        func cross(_ id: Int, _ a: CGPoint, _ va: Float, _ b: CGPoint, _ vb: Float) {
            guard links[2 * id] < 0 else { return }
            let t = CGFloat(min(max(va / (va - vb), 0), 1))
            points[id] = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func link(_ a: Int, _ b: Int) {
            for (from, to) in [(a, b), (b, a)] {
                if links[2 * from] < 0 {
                    links[2 * from] = Int32(to)
                    crossings.append(from)
                } else {
                    links[2 * from + 1] = Int32(to)
                }
            }
        }
        field.withUnsafeBufferPointer { v in
            for y in 0..<(H - 1) {
                for x in 0..<(W - 1) {
                    let tl = v[y * W + x], tr = v[y * W + x + 1], br = v[(y + 1) * W + x + 1], bl = v[(y + 1) * W + x]
                    let c = (tl < 0 ? 8 : 0) | (tr < 0 ? 4 : 0) | (br < 0 ? 2 : 0) | (bl < 0 ? 1 : 0)
                    guard c != 0 && c != 15 else { continue }
                    let top = y * W + x, bottom = (y + 1) * W + x, left = down + y * W + x, right = down + y * W + x + 1
                    if (tl < 0) != (tr < 0) { cross(top, middle(x, y), tl, middle(x + 1, y), tr) }
                    if (bl < 0) != (br < 0) { cross(bottom, middle(x, y + 1), bl, middle(x + 1, y + 1), br) }
                    if (tl < 0) != (bl < 0) { cross(left, middle(x, y), tl, middle(x, y + 1), bl) }
                    if (tr < 0) != (br < 0) { cross(right, middle(x + 1, y), tr, middle(x + 1, y + 1), br) }
                    let inMiddle = (tl + tr + br + bl) / 4 < 0
                    switch c {
                    case 1, 14: link(left, bottom)
                    case 2, 13: link(bottom, right)
                    case 3, 12: link(left, right)
                    case 4, 11: link(top, right)
                    case 6, 9: link(top, bottom)
                    case 7, 8: link(left, top)
                    case 5: if inMiddle { link(left, top); link(bottom, right) } else { link(left, bottom); link(top, right) }
                    case 10: if inMiddle { link(left, bottom); link(top, right) } else { link(left, top); link(bottom, right) }
                    default: break
                    }
                }
            }
        }
        // Each crossing joins two others: walked round, they make the closed lines.
        var walked = [Bool](repeating: false, count: 2 * down), lines: [[CGPoint]] = []
        for start in crossings where !walked[start] {
            var line: [CGPoint] = [], previous = -1, at = start
            while !walked[at] {
                walked[at] = true
                line.append(points[at])
                let a = Int(links[2 * at]), b = Int(links[2 * at + 1])
                let next = a >= 0 && a != previous && !walked[a] ? a : b >= 0 && b != previous && !walked[b] ? b : -1
                guard next >= 0 else { break }
                previous = at
                at = next
            }
            guard line.count >= 6 else { continue }
            var twice: CGFloat = 0
            for i in line.indices {
                let p = line[i], q = line[(i + 1) % line.count]
                twice += p.x * q.y - q.x * p.y
            }
            guard abs(twice) >= 12 else { continue }
            if twice < 0 { line.reverse() }
            let first = line.indices.min { line[$0].x + line[$0].y < line[$1].x + line[$1].y } ?? 0
            lines.append(Array(line[first...] + line[..<first]))
        }
        return lines
    }
}
