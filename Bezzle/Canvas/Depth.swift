import AppKit
import CoreImage

/// Layers turned in depth, drawn the only way Core Graphics allows, as blurs are: the layer as it
/// would lie flat, into a picture first, then that picture bent into place with Core Image, as a
/// card's face is when it is held up. A shadow under it falls from the shape it makes on the page,
/// the light above the page as always; one inside it is part of its face, and turns with it. The
/// pictures are kept until the layer changes, or how close the canvas is.
nonisolated extension Renderer {
    static func drawInDepth(_ node: Node, _ perspective: Perspective, in ctx: CGContext, options: Options) {
        let plain = flattened(node)
        let eye = options.eye
        // Lying flat, it is drawn as in the page: only where it stands is the scene's.
        var level = options
        level.space = nil
        var region = reach(of: plain, eye: eye?.level).insetBy(dx: -1, dy: -1).integral
        // Sharp where it comes nearest: made as big as it shows there, within reason.
        let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
        var scale = pixelScale(ctx) * min(max(corners.map(perspective.magnification).max() ?? 1, 1), 4)
        // A large layer seen up close is only made as big as what can be seen of it.
        let budget: CGFloat = 16_000_000
        if region.width * region.height * scale * scale > budget, let around = around(options) {
            let toCanvas = CGPoint(x: (options.board?.frame.minX ?? 0) + options.offset.x, y: (options.board?.frame.minY ?? 0) + options.offset.y)
            let seen = around.offsetBy(dx: -toCanvas.x, dy: -toCanvas.y)
            let back = [CGPoint(x: seen.minX, y: seen.minY), CGPoint(x: seen.maxX, y: seen.minY),
                        CGPoint(x: seen.maxX, y: seen.maxY), CGPoint(x: seen.minX, y: seen.maxY)].map(perspective.flat)
            if back.allSatisfy({ $0 != nil }) {
                let xs = back.map { $0!.x }, ys = back.map { $0!.y }
                let flat = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                region = region.intersection(flat.insetBy(dx: -2, dy: -2)).integral
                guard !region.isNull, region.width > 0, region.height > 0 else { return }
            }
        }
        scale = min(scale, sqrt(budget / max(region.width * region.height, 1)))

        // Drawn partway, or with something left out, it is not the layer to keep. It is kept by
        // how it looks lying flat and how it is turned, whatever its shadow, so that its shadow,
        // made apart from it at fewer pixels, is cast by the same picture.
        let keeps = options.halt == nil && options.skipping.isEmpty
        var key = plain
        key.transform3D = node.transform3D
        let made: (image: CGImage, at: CGPoint)?
        if keeps, let kept = BlurCache.shared.depth(key, scale: scale, region: region, casting: options.castingShadow, eye: eye) {
            made = kept
        } else {
            made = offscreen(region, scale: scale) { drawNode(plain, in: $0, options: level) }
                .flatMap { bent($0, from: region.origin, scale: scale, by: perspective) }
            if keeps, let made { BlurCache.shared.keep(depth: key, scale: scale, region: region, casting: options.castingShadow, eye: eye, image: made.image, at: made.at) }
        }
        guard let made else { return }
        ctx.saveGState()
        // Several shadows are each cast on their own, by the same picture.
        let outer = node.outerShadows
        if outer.count == 1 || options.castingShadow, let shadow = outer.first {
            if !drawShadowApart(node, shadow, in: ctx, options: options) { setShadow(shadow, in: ctx) }
        } else {
            for shadow in outer { drawShadowAlone(node, shadow, in: ctx, options: options) }
        }
        if node.opacity < 1 { ctx.setAlpha(node.opacity) }
        if let blend = node.blend { ctx.setBlendMode(blend.cg) }
        place(made.image, at: made.at, scale: scale, in: ctx)
        ctx.restoreGState()
    }

    /// The layer as it would lie flat, as its picture is made: faded, mixed with what is under it,
    /// and casting its shadow only once it is in place.
    static func flattened(_ node: Node) -> Node {
        var plain = node
        plain.transform3D = nil
        plain.opacity = 1
        plain.blend = nil
        // Those inside are part of its face; those under it fall once it is in place.
        let inner = node.innerShadows
        if inner.count != node.shadows.count {
            plain.shadow = Shadow()
            plain.moreShadows = nil
            if !inner.isEmpty { plain.shadows = inner }
        }
        return plain
    }

    /// A picture of a layer lying flat, made from `origin` in its parent at `scale`, bent into
    /// place; and where the bent picture goes.
    private static func bent(_ image: CGImage, from origin: CGPoint, scale: CGFloat, by perspective: Perspective) -> (image: CGImage, at: CGPoint)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let covered = CGRect(x: origin.x, y: origin.y, width: w / scale, height: h / scale)
        // Core Image measures in pixels from the bottom left.
        func pixel(_ q: CGPoint) -> CIVector {
            let s = perspective.shown(q)
            return CIVector(x: (s.x - origin.x) * scale, y: h - (s.y - origin.y) * scale)
        }
        let output = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": pixel(CGPoint(x: covered.minX, y: covered.minY)),
            "inputTopRight": pixel(CGPoint(x: covered.maxX, y: covered.minY)),
            "inputBottomRight": pixel(CGPoint(x: covered.maxX, y: covered.maxY)),
            "inputBottomLeft": pixel(CGPoint(x: covered.minX, y: covered.maxY)),
        ])
        let extent = output.extent.integral
        // Seen edge on, nothing of it shows.
        guard !extent.isNull, !extent.isInfinite, extent.width >= 1, extent.height >= 1, extent.width * extent.height < 64_000_000,
              let bent = imaging.createCGImage(output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        return (bent, CGPoint(x: origin.x + extent.minX / scale, y: origin.y + (h - extent.maxY) / scale))
    }

    /// A layer turned in depth, finished, as a picture: for writing it into a file that cannot
    /// turn things in depth itself. In the layer's parent's coordinates.
    /// It is mixed with what lies under it by the file, as it is not there to mix with here.
    static func depthPicture(of node: Node, scale: CGFloat, options: Options) -> (image: CGImage, region: CGRect)? {
        var alone = node
        alone.blend = nil
        let region = reach(of: node, eye: options.eye).integral
        guard !region.isNull, region.width > 0, region.height > 0,
              let image = offscreen(region, scale: scale, { drawNode(alone, in: $0, options: options) }) else { return nil }
        return (image, region)
    }

    /// Layers of groups that keep their depth, standing in a scene next to one another in the
    /// order it is drawn in (`DepthOrder.scene`), drawn as `drawScene` draws them, as one picture:
    /// for a file that cannot turn things in depth itself. In the coordinates of the layers the
    /// scene was asked about. One alone is mixed with what lies under it by the file.
    static func scenePicture(of pieces: [DepthOrder.Standing], scale: CGFloat, options: Options) -> (image: CGImage, region: CGRect)? {
        var region = CGRect.null
        for piece in pieces { region = region.union(reach(of: piece.node, eye: piece.eye).offsetBy(dx: piece.origin.x, dy: piece.origin.y)) }
        region = region.integral
        guard !region.isNull, region.width > 0, region.height > 0, let image = offscreen(region, scale: scale, { ctx in
            for piece in pieces {
                var node = piece.node
                if pieces.count == 1 { node.blend = nil }
                var inner = options
                inner.offset = CGPoint(x: options.offset.x + piece.origin.x, y: options.offset.y + piece.origin.y)
                inner.space = piece.eye?.space
                ctx.saveGState()
                ctx.translateBy(x: piece.origin.x, y: piece.origin.y)
                drawNode(node, in: ctx, options: inner)
                ctx.restoreGState()
            }
        }) else { return nil }
        return (image, region)
    }
}
