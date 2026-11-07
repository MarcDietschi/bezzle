import Foundation

/// Develops photos as their `Develop` says, as the Mac's Canvas/Developer.swift does with Core
/// Image: what each pixel becomes by itself worked out here as a colour cube, with the shared
/// `PointMap`, and laid over the picture's pixels by the page, which also takes its haze away and
/// sharpens it as the Mac's kernels do (`Images.Change.develop`).
///
/// A developed picture is kept, so that it is the same picture each time it is drawn, which the
/// page has already made.
nonisolated enum Developer {
    /// How many steps the cube has along each of red, green and blue, as on the Mac: fewer while
    /// Bezzle is being worked on, where working out each step is many times slower.
    #if DEBUG
    static let cubeSize = 24
    #else
    static let cubeSize = 40
    #endif

    private struct Key: Hashable {
        let source: ObjectIdentifier
        let develop: Develop
    }

    private struct Entry {
        /// Held, so that no other picture comes to have its identity while this is kept.
        let source: CGImage
        let image: CGImage
        var used: Int
    }

    private static let kept = Shared((images: [Key: Entry](), cubes: [Develop: [Float]](), tick: 0))

    /// The picture as `develop` makes it; the picture itself when it changes nothing.
    static func developed(_ picture: CGImage, _ develop: Develop?) -> CGImage {
        guard let develop, !develop.isNeutral || develop.isolate != nil else { return picture }
        let key = Key(source: ObjectIdentifier(picture), develop: develop)
        if let hit = kept.with({ k -> CGImage? in
            k.tick += 1
            k.images[key]?.used = k.tick
            return k.images[key]?.image
        }) { return hit }
        let point = develop.pointOnly
        let changes = !point.isNeutral || point.isolate != nil ? cube(point) : []
        let image = CGImage(width: picture.width, height: picture.height, source: .changed(picture, [
            .develop(cube: changes, size: cubeSize, dehaze: develop[.dehaze] / 100,
                     clarity: Self.clarity(develop), texture: develop[.texture] / 100 * 0.85, sharpness: develop[.sharpness] / 100 * 1.6),
        ]))
        kept.with { k in
            k.tick += 1
            k.images[key] = Entry(source: picture, image: image, used: k.tick)
            // A few kept, the latest used: a photo being developed makes one at each step of a drag.
            while k.images.count > 16, let oldest = k.images.min(by: { $0.value.used < $1.value.used })?.key { k.images[oldest] = nil }
        }
        return image
    }

    /// Clarity as the Mac's kernel takes it: a little less when it softens than when it sharpens.
    private static func clarity(_ d: Develop) -> Double {
        let c = d[.clarity] / 100
        return c * (c > 0 ? 0.9 : 0.75)
    }

    /// The colour cube for what each pixel becomes by itself: red changing fastest, then green,
    /// then blue, three numbers each, as the Mac's is made (Developer.cube) but for its alphas.
    static func cube(_ d: Develop) -> [Float] {
        if let known = kept.with({ $0.cubes[d] }) { return known }
        let n = cubeSize
        let map = PointMap(d)
        var values = [Float](repeating: 0, count: n * n * n * 3)
        var lin = [SIMD3<Double>](repeating: .zero, count: n * n * n)
        // The brightest any colour comes out, for the shoulder that brings it back.
        var top = 0.0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = map.apply(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                    top = max(top, c.max())
                    lin[(b * n + g) * n + r] = SIMD3(Double(Float(c.x)), Double(Float(c.y)), Double(Float(c.z)))
                }
            }
        }
        let shoulder = PointMap.Shoulder(top: PointMap.encode(top), knee: 0.86)
        for i in lin.indices {
            let c = map.finish(lin[i], shoulder: shoulder)
            values[i * 3] = Float(c.x)
            values[i * 3 + 1] = Float(c.y)
            values[i * 3 + 2] = Float(c.z)
        }
        kept.with { k in
            if k.cubes.count > 12 { k.cubes.removeAll() }
            k.cubes[d] = values
        }
        return values
    }
}
