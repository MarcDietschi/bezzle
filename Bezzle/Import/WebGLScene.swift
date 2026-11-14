import Foundation
import CoreGraphics

/// What a WebGL canvas drew, as the recorder in the page (WebPageGL.js) hands it over: its last
/// frame, pass by pass and draw by draw, the textures its passes draw into with what they held,
/// the textures of numbers it reads, and the uniforms that ran with time over the frames before
/// it; or why it cannot be drawn again, and stays a picture.
struct WebGLScene: Decodable {
    struct Program: Decodable {
        var vertex: String
        var fragment: String
    }

    struct Attribute: Decodable {
        var components: Int
        var values: String?
        var constant: [Double]?
        var divisor: Int?
    }

    struct Blend: Decodable {
        var source: String
        var destination: String
        var sourceAlpha: String
        var destinationAlpha: String
        var equation: String
        var equationAlpha: String
        var color: [Double]?
    }

    struct Draw: Decodable {
        var program: Int
        var uniforms: [String: [Double]]
        var attributes: [String: Attribute]
        var mode: String
        var first: Int
        var count: Int
        /// Sampler name, and the picture's number among the scene's.
        var textures: [String: Int]?
        var flipsTextures: Bool?
        var premultipliesTextures: Bool?
        var sampling: [String: ShaderSampling]?
        var indices: String?
        var blend: Blend?
        var viewport: [Double]?
        /// Sampler name, and the place among the scene's targets of the texture it reads.
        var targets: [String: Int]?
        /// Sampler name, and the place among the scene's textures of numbers.
        var texels: [String: Int]?
        var decodes: [String]?
        var depth: ShaderDepth?
        var stencil: ShaderStencil?
        var cull: String?
        var clockwiseFront: Bool?
        var channels: Int?
        var scissor: [Double]?
        var offset: [Double]?
        var instances: Int?
    }

    struct Picture: Decodable {
        var url: String?
        var data: String?
        var w: Double?
        var h: Double?
    }

    /// A texture the page drew into: its size, what a texel holds, and, where the frame takes it
    /// over from the frame before (`keeps`), what it held when the canvas's picture was taken.
    struct Target: Decodable {
        var w: Double
        var h: Double
        var format: String?
        var opaque: Bool?
        var mipmapped: Bool?
        var keeps: Bool?
        var state: String?
    }

    struct Pass: Decodable {
        var count: Int
        var colors: [Int]?
        var depth: Int?
        var clearColor: [Double]?
        var clearDepth: Double?
        var clearStencil: Int?
        var mipmaps: [Int]?
    }

    struct Texels: Decodable {
        var w: Double
        var h: Double
        var format: String
        var bytes: String
    }

    var why: String?
    var size: [Double]?
    var clear: [Double]?
    var programs: [Program]?
    var draws: [Draw]?
    var passes: [Pass]?
    var targets: [Target]?
    var texels: [Texels]?
    var turn: [Int]?
    var rate: Double?
    var clocks: [ShaderClock]?
    var recordings: [ShaderRecording]?
    var pictures: [String: Picture]?
    /// How many of its textures were a video's frames, each kept as the picture it showed.
    var videos: Int?
    var frames: Int?
    var still: Bool?
    /// The canvas's context attributes: alpha, premultipliedAlpha, antialias.
    var attributes: [String: Bool]?

    /// Why a scene cannot be read.
    struct Unreadable: Error, CustomStringConvertible { var description: String }

    /// The scene as the fill its layer is drawn with, its pictures as they were kept; nil when
    /// something of it cannot be read.
    func fill(textures: [Int: ShaderTexture]) -> ShaderFill? { try? make(textures: textures) }

    /// The same, saying what of it cannot be read. What the page drew onto its canvas in one go
    /// comes out as a plain fill, `clear` and `draws`, which every Bezzle that draws shaders reads.
    func make(textures: [Int: ShaderTexture]) throws -> ShaderFill {
        guard let size, size.count == 2, size[0] >= 1, size[1] >= 1 else { throw Unreadable(description: "its size, \(size ?? [])") }
        guard let programs, !programs.isEmpty, let draws, !draws.isEmpty else { throw Unreadable(description: "no programs or draws") }

        var numbers: [ShaderTexels] = []
        for (i, t) in (texels ?? []).enumerated() {
            let w = Int(t.w), h = Int(t.h)
            guard w > 0, h > 0, w <= 16384, h <= 16384, let per = ShaderTarget.bytesPerTexel(t.format),
                  let data = Data(base64Encoded: t.bytes), data.count == w * h * per else {
                throw Unreadable(description: "its texture of numbers \(i)")
            }
            numbers.append(ShaderTexels(width: w, height: h, format: t.format, bytes: data))
        }
        var drawnInto: [ShaderTarget] = []
        for (i, t) in (targets ?? []).enumerated() {
            let w = Int(t.w), h = Int(t.h)
            guard w > 0, h > 0, w <= 16384, h <= 16384, let per = ShaderTarget.bytesPerTexel(t.format),
                  !["l8", "a8", "la8"].contains(t.format ?? "") else {
                throw Unreadable(description: "target \(i): \(t.w) by \(t.h), \(t.format ?? "rgba8")")
            }
            var target = ShaderTarget(width: w, height: h, format: t.format == "rgba8" ? nil : t.format, opaque: t.opaque == true ? true : nil,
                                      mipmapped: t.mipmapped == true ? true : nil, keeps: t.keeps == true ? true : nil)
            if t.keeps == true, let state = t.state, let data = Data(base64Encoded: state), data.count == w * h * per { target.contents = data }
            drawnInto.append(target)
        }

        var made: [ShaderDraw] = []
        for (i, d) in draws.enumerated() {
            guard programs.indices.contains(d.program) else { throw Unreadable(description: "draw \(i): program \(d.program)") }
            guard let mode = ShaderDraw.Mode(rawValue: d.mode) else { throw Unreadable(description: "draw \(i): mode \(d.mode)") }
            guard d.count >= 0, d.first >= 0 else { throw Unreadable(description: "draw \(i): first \(d.first), count \(d.count)") }
            var attributes: [String: ShaderAttribute] = [:]
            for (name, a) in d.attributes {
                guard (1...4).contains(a.components) else { throw Unreadable(description: "draw \(i): \(name) has \(a.components) components") }
                if let values = a.values {
                    guard let data = Data(base64Encoded: values), data.count % 4 == 0 else { throw Unreadable(description: "draw \(i): \(name)'s values") }
                    attributes[name] = ShaderAttribute(components: a.components, values: data, divisor: a.divisor.flatMap { $0 > 0 ? $0 : nil })
                } else {
                    attributes[name] = ShaderAttribute(components: a.components, constant: a.constant ?? [0, 0, 0, 1])
                }
            }
            var samplers: [String: ShaderTexture] = [:]
            for (name, picture) in d.textures ?? [:] {
                guard let texture = textures[picture] else { throw Unreadable(description: "draw \(i): \(name)'s picture \(picture)") }
                samplers[name] = texture
            }
            for (name, target) in d.targets ?? [:] where !drawnInto.indices.contains(target) {
                throw Unreadable(description: "draw \(i): \(name)'s target \(target)")
            }
            for (name, texels) in d.texels ?? [:] where !numbers.indices.contains(texels) {
                throw Unreadable(description: "draw \(i): \(name)'s numbers \(texels)")
            }
            var indices: Data?
            if let list = d.indices {
                guard let data = Data(base64Encoded: list), data.count % 4 == 0 else { throw Unreadable(description: "draw \(i): its indices") }
                indices = data
            }
            let blend = d.blend.map { ShaderBlend(source: $0.source, destination: $0.destination, sourceAlpha: $0.sourceAlpha,
                                                  destinationAlpha: $0.destinationAlpha, equation: $0.equation, equationAlpha: $0.equationAlpha,
                                                  color: $0.color.flatMap { $0.count == 4 && $0.allSatisfy(\.isFinite) ? $0 : nil }) }
            func box(_ list: [Double]?) -> CGRect? {
                list.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            }
            var draw = ShaderDraw(program: d.program, uniforms: d.uniforms, attributes: attributes, indices: indices, mode: mode, first: d.first,
                                  count: d.count, textures: samplers.isEmpty ? nil : samplers, flipsTextures: d.flipsTextures == true ? true : nil,
                                  premultipliesTextures: d.premultipliesTextures == true ? true : nil,
                                  sampling: d.sampling.flatMap { $0.isEmpty ? nil : $0 }, blend: blend, viewport: box(d.viewport))
            // What Bezzle 1.7 does not know, only where the page had it.
            draw.targets = d.targets.flatMap { $0.isEmpty ? nil : $0 }
            draw.texels = d.texels.flatMap { $0.isEmpty ? nil : $0 }
            draw.decodes = d.decodes.flatMap { $0.isEmpty ? nil : $0.sorted() }
            draw.depth = d.depth
            draw.stencil = d.stencil
            draw.cull = d.cull.flatMap { ["front", "back", "both"].contains($0) ? $0 : nil }
            draw.clockwiseFront = d.clockwiseFront == true ? true : nil
            draw.channels = d.channels.flatMap { (0..<15).contains($0) ? $0 : nil }
            draw.scissor = box(d.scissor)
            draw.offset = d.offset.flatMap { $0.count == 2 && ($0[0] != 0 || $0[1] != 0) ? $0 : nil }
            draw.instances = d.instances.map { max(0, $0) }
            made.append(draw)
        }

        let clocks = (clocks ?? []).filter { programs.indices.contains($0.program) && $0.rate.isFinite && $0.start.isFinite
            && ($0.draw.map(made.indices.contains) ?? true) }
        var fill = ShaderFill(size: CGSize(width: size[0], height: size[1]), clear: clear,
                              programs: programs.map { ShaderProgram(vertex: $0.vertex, fragment: $0.fragment) }, draws: made, clocks: clocks)
        let recorded = (recordings ?? []).filter { programs.indices.contains($0.program) && $0.times.count == $0.values.count && $0.times.count >= 2
            && $0.times.allSatisfy(\.isFinite) && $0.values.allSatisfy(\.isFinite) && ($0.draw.map(made.indices.contains) ?? true) }
        if !recorded.isEmpty { fill.recordings = recorded }
        if !numbers.isEmpty { fill.texels = numbers }

        if let passes {
            guard passes.reduce(0, { $0 + max(0, $1.count) }) == made.count, passes.allSatisfy({ $0.count >= 0 }) else {
                throw Unreadable(description: "its passes have \(passes.map(\.count)) draws of \(made.count)")
            }
            for (i, p) in passes.enumerated() {
                let colors = p.colors ?? []
                guard colors.count <= 4, (colors + (p.mipmaps ?? [])).allSatisfy(drawnInto.indices.contains) else {
                    throw Unreadable(description: "pass \(i) draws into \(colors)")
                }
            }
            let only = passes.count == 1 ? passes[0] : nil
            if drawnInto.isEmpty, let only, (only.colors ?? []).isEmpty, (only.clearDepth ?? 1) == 1, (only.clearStencil ?? 0) == 0 {
                // Onto the canvas in one go: as every Bezzle that draws shaders reads it.
                fill.clear = only.clearColor
            } else {
                fill.clear = nil
                fill.passes = passes.map { p in
                    ShaderPass(colors: p.colors.flatMap { $0.isEmpty ? nil : $0 }, depth: p.depth, clearColor: p.clearColor, clearDepth: p.clearDepth,
                               clearStencil: p.clearStencil, count: p.count, mipmaps: p.mipmaps.flatMap { $0.isEmpty ? nil : $0 })
                }
                if !drawnInto.isEmpty { fill.targets = drawnInto }
            }
        } else {
            guard drawnInto.isEmpty else { throw Unreadable(description: "targets and no passes") }
        }
        // Where a page draws into two textures in turn, and how often it drew: of use only
        // where its frames build on the frames before, which whoever keeps the fill finds out
        // (`ShaderPainting.settled`).
        if fill.builds {
            if let turn, turn.count == drawnInto.count, Set(turn) == Set(drawnInto.indices), turn != Array(drawnInto.indices) { fill.turn = turn }
            if let rate, rate.isFinite, rate > 0 {
                // As often as screens draw, where it is near that; 60 goes without saying.
                let common: [Double] = [24, 25, 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 240]
                let near = common.first { abs(rate - $0) / $0 < 0.06 } ?? (min(max(rate, 1), 240) * 10).rounded() / 10
                fill.rate = near == 60 ? nil : near
            }
        }
        // Only what differs from WebGL's own.
        if attributes?["alpha"] == false { fill.alpha = false }
        if attributes?["premultipliedAlpha"] == false { fill.premultipliedAlpha = false }
        if attributes?["antialias"] == false { fill.antialias = false }
        return fill
    }
}
