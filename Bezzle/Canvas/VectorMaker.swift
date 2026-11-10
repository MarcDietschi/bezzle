import CoreGraphics
import Foundation
import Vectorizer

/// How a picture is vectorized, as the Vector card sets it.
nonisolated struct VectorSettings: Hashable, Sendable {
    /// How much of the picture's small things are kept, 0…1.
    var detail = 0.5
    /// How many colours at most; nil finds how many the picture has.
    var colors: Int?
    /// How closely the outlines follow every turn, 0, to how calm they run, 1.
    var smoothing = 0.5

    static let smoothings: [(value: Double, title: LocalizedStringResource)] = [
        (0.15, LocalizedStringResource("vector.outlines.exact", defaultValue: "Exact", comment: "Vector card: the outlines follow every turn of the picture")),
        (0.5, LocalizedStringResource("vector.outlines.balanced", defaultValue: "Balanced", comment: "Vector card: outlines between exact and smooth")),
        (0.85, LocalizedStringResource("vector.outlines.smooth", defaultValue: "Smooth", comment: "Vector card: the outlines run calm")),
    ]
    static let colorCounts = [2, 4, 8, 16, 32]
}

/// Vectorize: a layer's picture made the shapes it shows.
///
/// The layer is drawn as it shows, its picture developed, cut out and cropped by the layer's
/// outline, at the picture's own pixels; that is traced (the `Vectorizer` package), and the
/// tracing made a group of layers lying where the picture did: rectangles and ellipses where it
/// drew some, paths for the rest. All of it away from the main thread.
nonisolated enum VectorMaker {
    /// A layer's picture as pixels, and how many of them there are to a point of the layer.
    struct Source: @unchecked Sendable {
        let bitmap: Bitmap
        let image: CGImage
        let scale: CGFloat
    }

    /// A picture vectorized: the group of layers, and what the canvas shows of it being made.
    struct Made: @unchecked Sendable {
        let group: Node
        /// How many shapes were found, and their colours, the most of first.
        let shapes: Int
        let colors: [RGBA]
        /// The larger shapes' outlines, in the picture layer's own coordinates.
        let outlines: CGPath
    }

    /// No more shapes than this are each a layer of their own; a picture with more, as a
    /// photograph has, shares layers among shapes of one colour.
    static let ownLayers = 300

    /// The layer as it shows, without its border, shadows, opacity and turn, as pixels. Nil when
    /// it shows no picture, or nothing at all.
    static func source(of node: Node, assets: Assets) -> Source? {
        guard node.fill.on, let image = node.fill.image, node.frame.width > 0, node.frame.height > 0 else { return nil }
        // As many pixels as the picture has where it lies in the layer, and no more than are traced.
        let lying = Renderer.imageRect(image, in: node.frame.size)
        var scale = lying.width > 0 && image.size.width > 0 ? image.size.width / lying.width : 2
        let area = node.frame.width * node.frame.height
        scale = min(scale, (4_400_000 / area).squareRoot())
        scale = max(scale, min(1, 24 / min(node.frame.width, node.frame.height)))
        let size = CGSize(width: max(1, (node.frame.width * scale).rounded()), height: max(1, (node.frame.height * scale).rounded()))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        var plain = node
        plain.frame.origin = .zero
        plain.rotation = 0
        plain.border.on = false
        plain.moreBorders = nil
        plain.shadows = []
        plain.opacity = 1
        plain.blend = nil
        plain.blur = nil
        plain.transform3D = nil
        plain.hidden = false
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / node.frame.width, y: -size.height / node.frame.height)
        ctx.interpolationQuality = .high
        Renderer.withFlippedContext(ctx) {
            Renderer.drawNode(plain, in: ctx, options: Renderer.Options(deviceScale: scale, assets: assets))
        }
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self), let made = ctx.makeImage() else { return nil }
        let w = ctx.width, h = ctx.height, row = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var any = false
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let from = data + y * row, to = out.baseAddress! + y * w * 4
                for x in 0..<w {
                    let a = Int(from[x * 4 + 3])
                    guard a > 0 else { continue }
                    any = true
                    // Colours as they are, not multiplied by how solid they are.
                    to[x * 4] = UInt8(min(255, (Int(from[x * 4]) * 255 + a / 2) / a))
                    to[x * 4 + 1] = UInt8(min(255, (Int(from[x * 4 + 1]) * 255 + a / 2) / a))
                    to[x * 4 + 2] = UInt8(min(255, (Int(from[x * 4 + 2]) * 255 + a / 2) / a))
                    to[x * 4 + 3] = UInt8(a)
                }
            }
        }
        guard any else { return nil }
        return Source(bitmap: Bitmap(width: w, height: h, pixels: pixels), image: made, scale: size.width / node.frame.width)
    }

    /// `source` traced, as a group of layers in place of `picture`, the layer it was drawn from,
    /// or as that layer lies and is as large now. `progress` is told how far along the work is
    /// and stops it by answering false. Nil when it was stopped, or nothing was found to trace.
    static func make(_ source: Source, _ settings: VectorSettings, draft: Bool = false, replacing picture: Node,
                     progress: (@Sendable (Double) -> Bool)? = nil) -> Made? {
        let asked = Settings(colors: settings.colors, detail: settings.detail, smoothing: settings.smoothing, draft: draft)
        guard let tracing = Vectorizer.trace(source.bitmap, settings: asked, progress: progress), !tracing.shapes.isEmpty else { return nil }
        return made(of: tracing, replacing: picture)
    }

    /// A tracing as a group of layers in place of `picture`, whose frame the tracing fills.
    static func made(of tracing: Tracing, replacing picture: Node) -> Made? {
        guard tracing.width > 0, tracing.height > 0 else { return nil }
        // From the tracing's pixels to the layer's own points.
        let sx = picture.frame.width / CGFloat(tracing.width), sy = picture.frame.height / CGFloat(tracing.height)
        let even = abs(sx - sy) <= 0.001 * max(sx, sy)
        func point(_ s: Spot) -> CGPoint { CGPoint(x: s.x * sx, y: s.y * sy) }
        func add(_ outlines: [Outline], to path: CGMutablePath) {
            for outline in outlines {
                path.move(to: point(outline.start))
                for stretch in outline.stretches {
                    switch stretch {
                    case .line(let p): path.addLine(to: point(p))
                    case .curve(let a, let b, let p): path.addCurve(to: point(p), control1: point(a), control2: point(b))
                    }
                }
                path.closeSubpath()
            }
        }
        // In the group, which lies where the picture did until it is fitted round its layers; a
        // group is never turned, so each layer is, about the picture's middle.
        let placement = picture.placement.concatenating(CGAffineTransform(translationX: -picture.frame.minX, y: -picture.frame.minY))
        func layer(_ kind: Node.Kind, _ color: Tint, middle: CGPoint, size: CGSize, turned: Double = 0) -> Node {
            var n = Node(kind: kind, name: kind.title, frame: CGRect(center: middle.applying(placement), size: size))
            n.fill = Fill(on: true, color: RGBA(r: Double(color.r) / 255, g: Double(color.g) / 255, b: Double(color.b) / 255))
            n.border.on = false
            n.rotation = picture.rotation + turned
            return n
        }
        var children: [Node] = []
        for traced in tracing.layers(most: ownLayers) {
            switch traced.figure {
            case .rectangle(let c, let w, let h, let radius, let angle)? where even || abs(angle) < 0.01:
                var n = layer(.rectangle, traced.color, middle: point(c), size: CGSize(width: w * sx, height: h * sy), turned: angle)
                n.cornerRadius = ((radius * min(sx, sy)) * 100).rounded() / 100
                children.append(n)
            case .ellipse(let c, let rx, let ry, let angle)? where even || abs(angle) < 0.01:
                children.append(layer(.ellipse, traced.color, middle: point(c), size: CGSize(width: 2 * rx * sx, height: 2 * ry * sy), turned: angle))
            default:
                let path = CGMutablePath()
                add(traced.outlines, to: path)
                let box = path.boundingBoxOfPath
                guard !box.isNull, box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { continue }
                var n = layer(.path, traced.color, middle: box.center, size: box.size)
                n.path = PathData.string(path)
                n.pathBox = box
                children.append(n)
            }
        }
        guard !children.isEmpty else { return nil }

        var group = picture
        group.kind = .group
        group.fill = Fill(on: false, color: .shape)
        group.moreFills = nil
        group.border.on = false
        group.moreBorders = nil
        group.rotation = 0
        group.cornerRadius = 0
        group.corners = nil
        group.cornerSmoothing = nil
        group.cornersNamed = nil
        group.path = nil
        group.pathBox = nil
        group.evenOdd = nil
        group.transform3D = nil
        group.children = children

        // What the canvas draws in pencil as the picture turns into shapes: the larger of them.
        let outlines = CGMutablePath()
        for shape in tracing.shapes.sorted(by: { $0.area > $1.area }).prefix(400) { add(shape.outlines, to: outlines) }
        let colors = tracing.palette.map { RGBA(r: Double($0.r) / 255, g: Double($0.g) / 255, b: Double($0.b) / 255) }
        return Made(group: group, shapes: tracing.shapes.count, colors: colors, outlines: outlines)
    }
}
