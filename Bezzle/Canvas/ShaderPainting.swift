import CoreGraphics
import Foundation
import ImageIO
import Shaders

/// Shader fills drawn (`ShaderFill`): the fill's frame, at a moment of its own time, handed to
/// Bezzle's Metal engine (Packages/Shaders) and drawn into the part of the layer that a tile or a
/// picture shows, as sharp as it shows there. What cannot be drawn, on a Mac without Metal or a
/// program that does not build, gives way to the fill's picture, which is how it came in.
///
/// Thread-safe: the canvas's tiles are drawn on several threads at once (`Renderer`).
nonisolated enum ShaderPainting {
    /// Whether shaders can be drawn here at all.
    static var available: Bool { ShaderRenderer.shared != nil }

    /// Fills whose programs did not build, by what they draw: not tried again tile after tile.
    private static let broken = Broken()

    private final class Broken: @unchecked Sendable {
        private let lock = NSLock()
        private var known: Set<Int> = []
        func contains(_ key: Int) -> Bool { lock.withLock { known.contains(key) } }
        func insert(_ key: Int) { lock.withLock { _ = known.insert(key) } }
    }

    /// Draws a shader fill inside an outline, a layer of `size` with its top left at zero, at the
    /// film's moment `film` (the design's moment when nil): placed as its picture is, or in the
    /// whole box. Says whether it drew, so that the picture is drawn when it did not.
    static func paint(_ shader: ShaderFill, picture: ImageFill?, in path: CGPath, size: CGSize, rule: CGPathFillRule,
                      in ctx: CGContext, film: Double?, assets: Assets?, box: CGRect? = nil) -> Bool {
        guard let renderer = ShaderRenderer.shared else { return false }
        let key = shader.hashValue
        guard !broken.contains(key) else { return false }
        let box = box ?? CGRect(origin: .zero, size: size)
        let drawn = picture.map { Renderer.imageRect($0, in: box.size).offsetBy(dx: box.minX, dy: box.minY) } ?? box
        guard drawn.width > 0, drawn.height > 0, shader.size.width >= 1, shader.size.height >= 1 else { return false }
        // Only what shows: the part of it inside the outline and in the tile being drawn.
        var part = drawn.intersection(path.boundingBoxOfPath)
        if ctx.width > 0 { part = part.intersection(ctx.boundingBoxOfClipPath) }
        guard !part.isNull, part.width > 0.01, part.height > 0.01 else { return true }
        // As sharp as it shows: a PDF, which has no pixels, gets it at twice its size in points.
        var scale = ctx.width > 0 ? Renderer.pixelScale(ctx) : 2
        while part.width * scale > 8192 || part.height * scale > 8192 { scale /= 2 }
        let pixels = CGSize(width: max(1, (part.width * scale).rounded(.up)), height: max(1, (part.height * scale).rounded(.up)))
        // That part of the drawing buffer, from its top left; across the other way where it was flipped.
        let across = shader.size.width / drawn.width, down = shader.size.height / drawn.height
        var region = CGRect(x: (part.minX - drawn.minX) * across, y: (part.minY - drawn.minY) * down,
                            width: part.width * across, height: part.height * down)
        if shader.flippedX == true { region.origin.x = shader.size.width - region.maxX }
        if shader.flippedY == true { region.origin.y = shader.size.height - region.maxY }
        guard let frame = frame(of: shader, at: shader.time(film: film), assets: assets) else { return false }
        let image: CGImage
        do {
            image = try renderer.image(of: frame, pixels: pixels, region: region)
        } catch {
            broken.insert(key)
            return false
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: rule)
        ctx.interpolationQuality = .high
        // Upright, or turned over where it lies when its layer was flipped, as a picture is.
        ctx.translateBy(x: part.midX, y: part.midY)
        ctx.scaleBy(x: shader.flippedX == true ? -1 : 1, y: shader.flippedY == true ? 1 : -1)
        ctx.draw(image, in: CGRect(x: -part.width / 2, y: -part.height / 2, width: part.width, height: part.height))
        ctx.restoreGState()
        return true
    }

    /// Whether every program of a fill builds, its pictures given as files: for an import to keep
    /// only what Bezzle can draw again. True where shaders cannot be drawn at all, as nothing
    /// then says otherwise, and the picture stands in.
    static func builds(_ shader: ShaderFill, pictures: [String: Data]) -> Bool {
        guard let renderer = ShaderRenderer.shared else { return true }
        let images = pictures.compactMapValues { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let frame = frame(of: shader, at: 0, images: { images[$0] }) else { return false }
        do { try renderer.check(frame) } catch { return false }
        return true
    }

    /// The fill's frame at its own time `t`, as the engine takes it.
    static func frame(of shader: ShaderFill, at t: Double, assets: Assets?) -> ShaderFrame? {
        frame(of: shader, at: t) { name in
            assets?.image(name, pixels: .infinity)
        }
    }

    private static func frame(of shader: ShaderFill, at t: Double, images: (String) -> CGImage?) -> ShaderFrame? {
        var draws: [Shaders.ShaderDraw] = []
        for d in shader.draws {
            guard shader.programs.indices.contains(d.program) else { return nil }
            let program = shader.programs[d.program]
            var textures: [String: CGImage] = [:]
            for (name, texture) in d.textures ?? [:] {
                guard let image = images(texture.asset) else { return nil }
                textures[name] = image
            }
            let attributes = d.attributes.mapValues { a -> Shaders.ShaderDraw.Attribute in
                a.values != nil ? .init(components: a.components, values: a.floats) : .constant((a.constant ?? [0, 0, 0, 1]).map(Float.init))
            }
            draws.append(Shaders.ShaderDraw(vertex: program.vertex, fragment: program.fragment,
                                            uniforms: shader.uniforms(of: d, at: t).mapValues { $0.map(Float.init) },
                                            attributes: attributes, indices: d.indexList, mode: mode(d.mode), first: d.first, count: d.count,
                                            textures: textures, flipsTextures: d.flipsTextures == true,
                                            premultipliesTextures: d.premultipliesTextures == true,
                                            sampling: (d.sampling ?? [:]).mapValues(sampling), blend: d.blend.map(blend), viewport: d.viewport))
        }
        return ShaderFrame(size: shader.size, clear: shader.clear?.map(Float.init), draws: draws, alpha: shader.alpha ?? true,
                           premultipliedAlpha: shader.premultipliedAlpha ?? true, antialias: shader.antialias ?? true)
    }

    private static func mode(_ m: Bezzle.ShaderDraw.Mode) -> Shaders.ShaderDraw.Mode {
        switch m {
        case .triangles: .triangles
        case .triangleStrip: .triangleStrip
        case .triangleFan: .triangleFan
        case .lines: .lines
        case .lineStrip: .lineStrip
        case .points: .points
        }
    }

    private static func sampling(_ s: ShaderSampling) -> Shaders.ShaderDraw.Sampling {
        func wrap(_ w: String) -> Shaders.ShaderDraw.Sampling.Wrap { w == "repeat" ? .repeat : w == "mirror" ? .mirroredRepeat : .clampToEdge }
        func filter(_ f: String) -> Shaders.ShaderDraw.Sampling.Filter { f == "nearest" ? .nearest : .linear }
        return Shaders.ShaderDraw.Sampling(wrapS: wrap(s.wrapS), wrapT: wrap(s.wrapT), magnify: filter(s.magnify), minify: filter(s.minify),
                                           mipmap: s.mipmap.map(filter))
    }

    private static func blend(_ b: ShaderBlend) -> Shaders.ShaderDraw.Blend {
        func factor(_ f: String) -> Shaders.ShaderDraw.Blend.Factor {
            switch f {
            case "zero": .zero
            case "src-color": .sourceColor
            case "one-minus-src-color": .oneMinusSourceColor
            case "dst-color": .destinationColor
            case "one-minus-dst-color": .oneMinusDestinationColor
            case "src-alpha": .sourceAlpha
            case "one-minus-src-alpha": .oneMinusSourceAlpha
            case "dst-alpha": .destinationAlpha
            case "one-minus-dst-alpha": .oneMinusDestinationAlpha
            case "constant-color": .constantColor
            case "one-minus-constant-color": .oneMinusConstantColor
            case "constant-alpha": .constantAlpha
            case "one-minus-constant-alpha": .oneMinusConstantAlpha
            case "src-alpha-saturate": .sourceAlphaSaturate
            default: .one
            }
        }
        func equation(_ e: String) -> Shaders.ShaderDraw.Blend.Equation {
            switch e {
            case "func-subtract": .subtract
            case "func-reverse-subtract": .reverseSubtract
            case "min": .min
            case "max": .max
            default: .add
            }
        }
        var out = Shaders.ShaderDraw.Blend(source: factor(b.source), destination: factor(b.destination),
                                           sourceAlpha: factor(b.sourceAlpha), destinationAlpha: factor(b.destinationAlpha))
        out.equation = equation(b.equation)
        out.equationAlpha = equation(b.equationAlpha)
        return out
    }
}
