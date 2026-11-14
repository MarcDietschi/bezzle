#if canImport(Vectorizer)
import CoreGraphics
import Foundation
import Vectorizer

// Vectorize as the Mac and Windows share it: how a picture is traced (`VectorSettings`), which
// layers may be traced (`vectorizable`), what of a layer is read and at how many pixels, the
// tracing made a group of layers in the picture's place (`VectorMaker.made`), and the picture
// remembered while the design is open (`VectorSource`), found again by its group and given back
// where the group lies. Each platform draws the layer into pixels itself (`VectorMaker.source`):
// the Mac with Core Graphics, Windows with Skia. The browser has no Vectorizer, so it has none of this.

/// How a picture is vectorized, as the Vector card sets it.
nonisolated struct VectorSettings: Hashable, Sendable {
    /// How much of the picture's small things are kept, 0…1.
    var detail = 0.5
    /// How many colours at most; nil finds how many the picture has.
    var colors: Int?
    /// How closely the outlines follow every turn of the picture, 0, to how calm they run, 1.
    var smoothing = 0.5

    static let smoothings: [(value: Double, title: LocalizedStringResource)] = [
        (0.15, LocalizedStringResource("vector.outlines.exact", defaultValue: "Exact", comment: "Vector card: the outlines follow every turn of the picture")),
        (0.5, LocalizedStringResource("vector.outlines.balanced", defaultValue: "Balanced", comment: "Vector card: outlines between exact and smooth")),
        (0.85, LocalizedStringResource("vector.outlines.smooth", defaultValue: "Smooth", comment: "Vector card: the outlines run calm")),
    ]
    static let colorCounts = [2, 4, 8, 16, 32]

    /// Within what the card and an assistant may ask for.
    var held: VectorSettings {
        var s = self
        s.detail = min(max(s.detail, 0), 1)
        s.smoothing = min(max(s.smoothing, 0), 1)
        s.colors = s.colors.map { min(max($0, 2), 64) }
        return s
    }

    /// The choice of outlines nearest to how they are.
    var nearestSmoothing: Double {
        Self.smoothings.map(\.value).min { abs($0 - smoothing) < abs($1 - smoothing) } ?? 0.5
    }
}

extension BezzleDocument {
    /// Whether a layer shows a picture that can become shapes: not one whose place something
    /// else counts on, as the shape of a mask, a copy of a component, a repeat grid's cell or a
    /// deck's post.
    func vectorizable(_ id: UUID) -> Bool {
        guard let n = node(id), !n.isArtboard, !n.locked, [.rectangle, .ellipse, .path].contains(n.kind), n.fill.on, n.fill.image != nil,
              n.frame.width > 0, n.frame.height > 0 else { return false }
        guard parent(of: id)?.holder?.id != id else { return false }
        return !inCopy(id) && !ancestors(of: id).contains(where: \.isRepeatGrid) && artboard(of: id)?.isDeck != true
    }
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

    /// How a layer's picture is read: as many pixels as the picture has where it lies in the
    /// layer, and no more than are traced, so many across and down, and the pixels to a point
    /// it is drawn at. Nil when it shows no picture.
    static func reading(_ node: Node) -> (size: CGSize, scale: CGFloat)? {
        guard node.fill.on, let image = node.fill.image, node.frame.width > 0, node.frame.height > 0 else { return nil }
        let lying = Renderer.imageRect(image, in: node.frame.size)
        var scale = lying.width > 0 && image.size.width > 0 ? image.size.width / lying.width : 2
        let area = node.frame.width * node.frame.height
        scale = min(scale, (4_400_000 / area).squareRoot())
        scale = max(scale, min(1, 24 / min(node.frame.width, node.frame.height)))
        return (CGSize(width: max(1, (node.frame.width * scale).rounded()), height: max(1, (node.frame.height * scale).rounded())), scale)
    }

    /// The layer as it is read: without its place, border, shadows, opacity and turn, drawn in its
    /// own coordinates.
    static func plain(_ node: Node) -> Node {
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
        return plain
    }

    /// Pixels drawn premultiplied, red, green, blue and alpha, rows top first, as the tracing
    /// takes them: their colours as they are, not multiplied by how solid they are. Nil when none
    /// of them shows anything.
    static func straightened(_ data: UnsafePointer<UInt8>, width w: Int, height h: Int, rowBytes row: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var any = false
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let from = data + y * row, to = out.baseAddress! + y * w * 4
                for x in 0..<w {
                    let a = Int(from[x * 4 + 3])
                    guard a > 0 else { continue }
                    any = true
                    to[x * 4] = UInt8(min(255, (Int(from[x * 4]) * 255 + a / 2) / a))
                    to[x * 4 + 1] = UInt8(min(255, (Int(from[x * 4 + 1]) * 255 + a / 2) / a))
                    to[x * 4 + 2] = UInt8(min(255, (Int(from[x * 4 + 2]) * 255 + a / 2) / a))
                    to[x * 4 + 3] = UInt8(a)
                }
            }
        }
        return any ? pixels : nil
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

    /// The colours a tracing found running across a shape, as the gradient of the layer made of
    /// it: a layer's gradient is placed in the layer's own frame, 0,0 its top left and 1,1 its
    /// bottom right, and the tracing's in the picture's pixels, `sx` and `sy` points each. The
    /// layer's middle lies at `middle` in the picture's points, it is `size` large and `turned`
    /// degrees about its middle. A round blend is a circle in the picture, so on a layer that
    /// is not square it has both its radii (`across`); and where a point is not as wide as it
    /// is high, a straight blend ends where its lines of one colour stay the picture's.
    static func gradient(_ blend: Blend, middle: CGPoint, size: CGSize, turned: Double, sx: CGFloat, sy: CGFloat) -> Gradient {
        let back = CGAffineTransform(rotationAngle: -turned * .pi / 180)
        func own(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - middle.x, y: p.y - middle.y).applying(back) }
        func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width + 0.5, y: p.y / size.height + 0.5) }
        let stops = blend.stops.map {
            GradientStop(offset: min(max($0.offset, 0), 1), color: RGBA(r: Double($0.color.r) / 255, g: Double($0.color.g) / 255, b: Double($0.color.b) / 255))
        }
        let start = CGPoint(x: blend.start.x * sx, y: blend.start.y * sy)
        switch blend.kind {
        case .linear:
            // How far along a place is, by its points: the way to the end in pixels, each
            // pixel `sx` by `sy` points.
            let dx = blend.end.x - blend.start.x, dy = blend.end.y - blend.start.y, long = dx * dx + dy * dy
            let gx = long > 0 ? dx / sx / long : 0, gy = long > 0 ? dy / sy / long : 0, g = gx * gx + gy * gy
            let end = g > 0 ? CGPoint(x: start.x + gx / g, y: start.y + gy / g) : CGPoint(x: blend.end.x * sx, y: blend.end.y * sy)
            return Gradient(kind: .linear, stops: stops, start: unit(own(start)), end: unit(own(end)))
        case .radial:
            let centre = own(start)
            let reach = hypot(blend.end.x - blend.start.x, blend.end.y - blend.start.y)
            return Gradient(kind: .radial, stops: stops, start: unit(centre), end: unit(CGPoint(x: centre.x + reach * sx, y: centre.y)),
                            radius: reach * sx / size.width, across: unit(CGPoint(x: centre.x, y: centre.y + reach * sy)))
        }
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
        func rgba(_ color: Tint) -> RGBA { RGBA(r: Double(color.r) / 255, g: Double(color.g) / 255, b: Double(color.b) / 255) }
        func layer(_ kind: Node.Kind, _ color: Tint, _ blend: Blend?, middle: CGPoint, size: CGSize, turned: Double = 0) -> Node {
            var n = Node(kind: kind, name: kind.title, frame: CGRect(center: middle.applying(placement), size: size))
            n.fill = Fill(on: true, color: rgba(color))
            // Colours that run across it are the layer's gradient, its one colour the one halfway.
            if let blend, size.width > 0, size.height > 0 {
                n.fill.gradient = Self.gradient(blend, middle: middle, size: size, turned: turned, sx: sx, sy: sy)
            }
            n.border.on = false
            n.rotation = picture.rotation + turned
            return n
        }
        var children: [Node] = []
        for traced in tracing.layers(most: ownLayers) {
            switch traced.figure {
            case .rectangle(let c, let w, let h, let radius, let angle)? where even || abs(angle) < 0.01:
                var n = layer(.rectangle, traced.color, traced.blend, middle: point(c), size: CGSize(width: w * sx, height: h * sy), turned: angle)
                n.cornerRadius = ((radius * min(sx, sy)) * 100).rounded() / 100
                children.append(n)
            case .ellipse(let c, let rx, let ry, let angle)? where even || abs(angle) < 0.01:
                children.append(layer(.ellipse, traced.color, traced.blend, middle: point(c), size: CGSize(width: 2 * rx * sx, height: 2 * ry * sy), turned: angle))
            default:
                let path = CGMutablePath()
                add(traced.outlines, to: path)
                let box = path.boundingBoxOfPath
                guard !box.isNull, box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { continue }
                var n = layer(.path, traced.color, traced.blend, middle: box.center, size: box.size)
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

/// A picture vectorized while the design is open: what it was, to have it traced another way,
/// or to have the picture back. Kept with the open design, not in its file.
nonisolated struct VectorSource: @unchecked Sendable {
    /// The layer as it was.
    let picture: Node
    /// As it showed, in pixels.
    let pixels: VectorMaker.Source
    /// Each way it was traced, the last made last.
    var versions: [Version] = []

    struct Version {
        /// The group's layers as made: its first, and how many.
        let first: UUID
        let count: Int
        let settings: VectorSettings
        /// Where the group lay, fitted round its layers, as it was made.
        let frame: CGRect
        let shapes: Int
        let colors: [RGBA]
    }

    /// How `group` was traced, while it is still the layers that were made of this picture:
    /// moved, resized and looking as it likes, but holding what it held.
    func version(of group: Node) -> Version? {
        guard group.kind == .group, let first = group.children.first else { return nil }
        return versions.last { $0.first == first.id && $0.count == group.children.count }
    }

    /// The picture layer as it would lie now, where `group`, made as `version`, lies and as large,
    /// and moving in its film as `group` does now: keys set since it became shapes are not the
    /// picture's to lose.
    func lying(_ version: Version, as group: Node) -> Node {
        var picture = picture
        picture.motion = group.motion
        let was = version.frame, now = group.frame
        let fx = was.width > 0 ? now.width / was.width : 1, fy = was.height > 0 ? now.height / was.height : 1
        picture.frame = CGRect(x: now.minX + (picture.frame.minX - was.minX) * fx, y: now.minY + (picture.frame.minY - was.minY) * fy,
                               width: picture.frame.width * fx, height: picture.frame.height * fy)
        return picture
    }

    /// The group just made of it, `made` with `settings`, remembered as one more way it was traced.
    mutating func remember(_ group: Node, _ settings: VectorSettings, shapes: Int, colors: [RGBA]) {
        guard let first = group.children.first else { return }
        versions.append(.init(first: first.id, count: group.children.count, settings: settings, frame: group.frame, shapes: shapes, colors: colors))
        if versions.count > 24 { versions.removeFirst(versions.count - 24) }
    }
}
#endif
