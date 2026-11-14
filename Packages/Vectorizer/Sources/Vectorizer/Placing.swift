import Foundation

// An edge is placed, as the picture is read, by how much of each side's colour its pixels hold,
// and the colours are the palette's. Beside colours that run that is a little wrong all along:
// the palette has one colour for each band of the run, the picture another at every pixel, and
// the edge is found too far in where the run is lighter than its band's colour and too far out
// where it is darker, by half a pixel and more, with a jog wherever one band ends. Once the run
// is known (`blended`), the colours either side of the edge are known at every pixel, and the
// edge is placed again by them: the samples beside it are given to the side they lie on.

/// What colour each region is at a place: one colour, or those of the run across it.
struct Coloured {
    /// For each region the colours that run across it, in the raster's pixels.
    let blends: [Blend?]
    /// For each region its one colour, and nil for see-through.
    let flat: [SIMD3<Double>?]

    /// The colour of region `r` at a pixel's middle.
    @inline(__always) func color(_ r: Int32, _ x: Int, _ y: Int) -> SIMD3<Double>? {
        guard let blend = blends[Int(r)], let first = blend.stops.first, let last = blend.stops.last else { return flat[Int(r)] }
        let t = blend.offset(of: Spot(Double(x) + 0.5, Double(y) + 0.5))
        func real(_ c: Tint) -> SIMD3<Double> { SIMD3(Double(c.r), Double(c.g), Double(c.b)) }
        if t <= first.offset { return real(first.color) }
        for k in 1..<blend.stops.count where t <= blend.stops[k].offset {
            let a = blend.stops[k - 1], b = blend.stops[k]
            let u = b.offset > a.offset ? (t - a.offset) / (b.offset - a.offset) : 1
            return real(a.color) * (1 - u) + real(b.color) * u
        }
        return real(last.color)
    }
}

extension Vectorizer {
    /// The edges of every run of colours placed again where the picture has them: the samples
    /// of `regions` beside such an edge given to the side they lie on, and `near` told how far
    /// from the edge each is.
    ///
    /// Across an edge, along a row of the picture, the pixels from two on the one side to two
    /// on the other are each held against the two sides' colours at that pixel: so much of it
    /// is the one, the rest the other. What the five hold of the one, laid end to end, ends
    /// where the edge crosses the middle of the row. The rows above and below tell the same,
    /// and with them how the edge slants across this one. Rows are asked where the edge
    /// crosses them squarely enough, columns where it does not. Where the pixels at the two
    /// ends are not wholly the one and the other, a corner or something else is too near to
    /// tell, and the samples stay as they were read.
    static func placed(_ regions: inout Regions, near: Store<UInt8>, raster: Raster, scale s: Int, mixing: Mixing, coloured: Coloured) {
        let W = regions.W, H = regions.H, id = regions.id.p
        let w = raster.w, h = raster.h, rgb = raster.rgb.p
        let half = s / 2
        guard w >= 5, h >= 5 else { return }
        // The region each pixel's middle lies in, as read: what tells where an edge is to be
        // looked for is not to change while they are placed.
        var at = [Int32](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = min(y * s + half, H - 1) * W
            for x in 0..<w { at[y * w + x] = id[row + min(x * s + half, W - 1)] }
        }
        @inline(__always) func seen(_ x: Int, _ y: Int) -> SIMD3<Int32> {
            let i = (y * w + x) * 3
            return SIMD3(Int32(rgb[i]), Int32(rgb[i + 1]), Int32(rgb[i + 2]))
        }
        @inline(__always) func whole(_ c: SIMD3<Double>) -> SIMD3<Int32> {
            SIMD3(Int32(c.x.rounded()), Int32(c.y.rounded()), Int32(c.z.rounded()))
        }
        var area = regions.area, box = regions.box

        // Once along the rows and once along the columns: `rows` says which, and a place is
        // named by how far along its line it is and which line.
        for rows in [true, false] {
            let long = rows ? w : h, lines = rows ? h : w
            @inline(__always) func pixel(_ along: Int, _ line: Int) -> (x: Int, y: Int) { rows ? (along, line) : (line, along) }
            /// Where the edge from `a` to `b` crosses the middle of a line, near `middle`
            /// along it, and the pixels it was told by.
            func crossing(_ line: Int, _ middle: Int, _ a: Int32, _ b: Int32) -> (at: Double, from: Int, to: Int)? {
                guard line >= 0, line < lines else { return nil }
                for far in [2, 1] {
                    guard middle - far >= 0, middle + far < long else { continue }
                    var held = 0.0, fits = true, passed = false
                    for along in (middle - far)...(middle + far) {
                        let (x, y) = pixel(along, line)
                        let here = at[y * w + x]
                        if here == b { passed = true } else if here != a || passed { fits = false; break }
                        guard let mine = coloured.color(a, x, y), let theirs = coloured.color(b, x, y) else { fits = false; break }
                        let apart = mine - theirs, gap = (apart * apart).sum()
                        // Too alike here to tell one from the other.
                        guard gap >= 400 else { fits = false; break }
                        // By its light, where the picture keeps its colour coarser: across an
                        // edge the colour then lags the light by a pixel or two.
                        let share = min(max(mixing(seen(x, y), from: whole(theirs), to: whole(mine)).light, 0), 1)
                        if (along == middle - far && share < 0.85) || (along == middle + far && share > 0.15) { fits = false; break }
                        held += share
                    }
                    if fits, passed { return (Double(middle - far) + held, middle - far, middle + far) }
                }
                return nil
            }
            for line in 0..<lines {
                for along in 0..<(long - 1) {
                    let (x0, y0) = pixel(along, line), (x1, y1) = pixel(along + 1, line)
                    let a = at[y0 * w + x0], b = at[y1 * w + x1]
                    guard a != b, coloured.blends[Int(a)] != nil || coloured.blends[Int(b)] != nil else { continue }
                    // Looked for where the samples change, and a pixel further to either side:
                    // what was read as something thin of its own along the edge went whole to
                    // one of the two, and where it was two pixels thick the samples change
                    // that far from the edge.
                    var found: (at: Double, from: Int, to: Int)?
                    for shift in [0, 1, -1, 2] {
                        found = crossing(line, along + shift, a, b)
                        if found != nil { break }
                    }
                    let about = found.map { Int($0.at) } ?? along
                    let before = (crossing(line - 1, about, a, b) ?? (found == nil ? crossing(line - 1, about + 1, a, b) : nil))?.at
                    let after = (crossing(line + 1, about, a, b) ?? (found == nil ? crossing(line + 1, about + 1, a, b) : nil))?.at
                    let here: (at: Double, from: Int, to: Int), slope: Double
                    if let found {
                        here = found
                        if let before, let after {
                            slope = (after - before) / 2
                        } else if let after {
                            slope = after - here.at
                        } else if let before {
                            slope = here.at - before
                        } else {
                            continue
                        }
                    } else if let before, let after {
                        // A line that cannot tell, as one where a picture kept coarsely rings,
                        // between two that can: the edge runs on from the one to the other.
                        let between = (before + after) / 2
                        here = (between, max(Int(between) - 2, 0), min(Int(between) + 2, long - 1))
                        slope = (after - before) / 2
                    } else {
                        continue
                    }
                    guard abs(slope) <= 1.3 else { continue }
                    let steep = (1 + slope * slope).squareRoot()
                    for sub in 0..<s {
                        // Where the edge is at this row of samples.
                        let across = line * s + sub
                        let edge = (here.at + slope * ((Double(sub) + 0.5) / Double(s) - 0.5)) * Double(s)
                        for step in (here.from * s)..<((here.to + 1) * s) {
                            let X = rows ? step : across, Y = rows ? across : step
                            guard X < W, Y < H else { continue }
                            let i = Y * W + X, was = id[i]
                            guard was == a || was == b else { continue }
                            let off = Double(step) + 0.5 - edge
                            let now = off < 0 ? a : b
                            let far = abs(off) / steep
                            if was != now {
                                id[i] = now
                                area[Int(was)] -= 1
                                area[Int(now)] += 1
                                let m = box[Int(now)]
                                box[Int(now)] = SIMD4(min(m.x, Int32(X)), min(m.y, Int32(Y)), max(m.z, Int32(X)), max(m.w, Int32(Y)))
                                near.p[i] = UInt8(min(far * 32, 253))
                            } else if far < 1.5 {
                                near.p[i] = UInt8(min(far * 32, 253))
                            }
                        }
                    }
                }
            }
        }
        regions.area = area
        regions.box = box
    }
}
