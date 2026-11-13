import Foundation
import CoreGraphics

/// What a WebGL canvas drew, as the recorder in the page (WebPageGL.js) hands it over: its last
/// frame, draw by draw, and the uniforms that ran with time over the frames before it; or why it
/// cannot be drawn again, and stays a picture.
struct WebGLScene: Decodable {
    struct Program: Decodable {
        var vertex: String
        var fragment: String
    }

    struct Attribute: Decodable {
        var components: Int
        var values: String?
        var constant: [Double]?
    }

    struct Blend: Decodable {
        var source: String
        var destination: String
        var sourceAlpha: String
        var destinationAlpha: String
        var equation: String
        var equationAlpha: String
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
    }

    struct Picture: Decodable {
        var url: String?
        var data: String?
        var w: Double?
        var h: Double?
    }

    var why: String?
    var size: [Double]?
    var clear: [Double]?
    var programs: [Program]?
    var draws: [Draw]?
    var clocks: [ShaderClock]?
    var recordings: [ShaderRecording]?
    var pictures: [String: Picture]?
    var frames: Int?
    var still: Bool?
    /// The canvas's context attributes: alpha, premultipliedAlpha, antialias.
    var attributes: [String: Bool]?

    /// Why a scene cannot be read.
    struct Unreadable: Error, CustomStringConvertible { var description: String }

    /// The scene as the fill its layer is drawn with, its pictures as they were kept; nil when
    /// something of it cannot be read.
    func fill(textures: [Int: ShaderTexture]) -> ShaderFill? { try? make(textures: textures) }

    /// The same, saying what of it cannot be read.
    func make(textures: [Int: ShaderTexture]) throws -> ShaderFill {
        guard let size, size.count == 2, size[0] >= 1, size[1] >= 1 else { throw Unreadable(description: "its size, \(size ?? [])") }
        guard let programs, !programs.isEmpty, let draws, !draws.isEmpty else { throw Unreadable(description: "no programs or draws") }
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
                    attributes[name] = ShaderAttribute(components: a.components, values: data)
                } else {
                    attributes[name] = ShaderAttribute(components: a.components, constant: a.constant ?? [0, 0, 0, 1])
                }
            }
            var samplers: [String: ShaderTexture] = [:]
            for (name, picture) in d.textures ?? [:] {
                guard let texture = textures[picture] else { throw Unreadable(description: "draw \(i): \(name)'s picture \(picture)") }
                samplers[name] = texture
            }
            var indices: Data?
            if let list = d.indices {
                guard let data = Data(base64Encoded: list), data.count % 4 == 0 else { throw Unreadable(description: "draw \(i): its indices") }
                indices = data
            }
            let blend = d.blend.map { ShaderBlend(source: $0.source, destination: $0.destination, sourceAlpha: $0.sourceAlpha,
                                                  destinationAlpha: $0.destinationAlpha, equation: $0.equation, equationAlpha: $0.equationAlpha) }
            let viewport = d.viewport.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            made.append(ShaderDraw(program: d.program, uniforms: d.uniforms, attributes: attributes, indices: indices, mode: mode, first: d.first,
                                   count: d.count, textures: samplers.isEmpty ? nil : samplers, flipsTextures: d.flipsTextures == true ? true : nil,
                                   premultipliesTextures: d.premultipliesTextures == true ? true : nil,
                                   sampling: d.sampling.flatMap { $0.isEmpty ? nil : $0 }, blend: blend, viewport: viewport))
        }
        let clocks = (clocks ?? []).filter { programs.indices.contains($0.program) && $0.rate.isFinite && $0.start.isFinite }
        var fill = ShaderFill(size: CGSize(width: size[0], height: size[1]), clear: clear,
                              programs: programs.map { ShaderProgram(vertex: $0.vertex, fragment: $0.fragment) }, draws: made, clocks: clocks)
        let recorded = (recordings ?? []).filter { programs.indices.contains($0.program) && $0.times.count == $0.values.count && $0.times.count >= 2
            && $0.times.allSatisfy(\.isFinite) && $0.values.allSatisfy(\.isFinite) }
        if !recorded.isEmpty { fill.recordings = recorded }
        // Only what differs from WebGL's own.
        if attributes?["alpha"] == false { fill.alpha = false }
        if attributes?["premultipliedAlpha"] == false { fill.premultipliedAlpha = false }
        if attributes?["antialias"] == false { fill.antialias = false }
        return fill
    }
}
