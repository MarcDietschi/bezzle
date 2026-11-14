import Foundation

/// One layer of a design made from a tracing: a shape of its own, or several of one colour that
/// lie in one layer. Filled non-zero: an outline's holes run the other way round than it does,
/// and two outlines that overlap are one area.
public struct Layer: Hashable, Sendable {
    public var color: Tint
    public var outlines: [Outline]
    /// The layer as a rectangle or an ellipse, when it is one shape that is one.
    public var figure: Figure?
    /// How many of the tracing's shapes it holds.
    public var shapes: Int
    /// The colours that run across it, when it is not one colour: then it is one shape alone,
    /// and `color` the colour halfway along.
    public var blend: Blend?
}

public extension Tracing {
    /// The tracing as layers, the bottom one first. Up to `most` shapes, each is a layer of its
    /// own, to be picked and changed alone, as the letters of a logo are. A picture with more
    /// of them, as a photograph has thousands, would bury a design in layers: there the shapes
    /// of one colour share a layer wherever that leaves the picture as it is, which is wherever
    /// nothing of another colour lies between them. Among so many, a blob that is nearly round
    /// is no ellipse anyone drew, so none is made a figure.
    func layers(most: Int = 400) -> [Layer] {
        guard shapes.count > most else {
            return shapes.map { Layer(color: $0.color, outlines: $0.outlines, figure: $0.figure, shapes: 1, blend: $0.blend) }
        }
        struct Box {
            var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
            var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
            mutating func take(_ p: Spot) {
                x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
            }
            func meets(_ o: Box) -> Bool { x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1 }
        }
        // Where each shape's outside outline reaches: its control points hold its curves.
        let boxes: [Box] = shapes.map { shape in
            var box = Box()
            guard let outside = shape.outlines.first else { return box }
            box.take(outside.start)
            for stretch in outside.stretches {
                switch stretch {
                case .line(let p): box.take(p)
                case .curve(let a, let b, let p): box.take(a); box.take(b); box.take(p)
                }
            }
            return box
        }
        var layers: [Layer] = []
        // The layer each shape went to, and each colour's layers, the lowest first.
        var layerOf = [Int](repeating: 0, count: shapes.count)
        var ofColor: [Tint: [Int]] = [:]
        // Shapes by where they are, in a grid, so each is held against its neighbours alone.
        let cell = max(Double(max(width, height)) / 48, 1)
        let across = Int(Double(width) / cell) + 1, down = Int(Double(height) / cell) + 1
        var grid = [[Int]](repeating: [], count: across * down)
        func cells(_ b: Box) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let x0 = min(max(Int(b.x0 / cell), 0), across - 1), x1 = min(max(Int(b.x1 / cell), x0), across - 1)
            let y0 = min(max(Int(b.y0 / cell), 0), down - 1), y1 = min(max(Int(b.y1 / cell), y0), down - 1)
            return (x0...x1, y0...y1)
        }
        var seen = [Int](repeating: -1, count: shapes.count)
        for (i, shape) in shapes.enumerated() {
            let box = boxes[i]
            let (xs, ys) = cells(box)
            // The highest layer holding something of another colour it lies over.
            var under = -1
            for y in ys {
                for x in xs {
                    for j in grid[y * across + x] where seen[j] != i {
                        seen[j] = i
                        let other = layers[layerOf[j]]
                        if other.color != shape.color || other.blend != nil || shape.blend != nil, boxes[j].meets(box) {
                            under = max(under, layerOf[j])
                        }
                    }
                }
            }
            var into: Int?
            // The lowest of its colour's layers over that, so the layers stay few.
            if shape.blend == nil, let own = ofColor[shape.color], let last = own.last, last > under {
                var lo = 0, hi = own.count - 1
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if own[mid] > under { hi = mid } else { lo = mid + 1 }
                }
                into = own[lo]
            }
            if let into {
                layers[into].outlines += shape.outlines
                layers[into].shapes += 1
                layerOf[i] = into
            } else {
                layers.append(Layer(color: shape.color, outlines: shape.outlines, figure: nil, shapes: 1, blend: shape.blend))
                layerOf[i] = layers.count - 1
                // Colours that run across a shape are its own: nothing shares its layer.
                if shape.blend == nil { ofColor[shape.color, default: []].append(layers.count - 1) }
            }
            for y in ys {
                for x in xs { grid[y * across + x].append(i) }
            }
        }
        return layers
    }
}
