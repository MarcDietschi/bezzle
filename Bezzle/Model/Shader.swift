import Foundation
import CoreGraphics

/// A picture a program draws on the graphics card, as a web page's WebGL canvas draws it: the
/// page's own shaders (GLSL, as WebGL takes it), what it gave them, and how its time runs. It is
/// one frame of the canvas, kept to be drawn again: each of its draws in turn, into a drawing
/// buffer of `size`, with the inputs that ran with time (`clocks`) set for the moment drawn. So it
/// is as sharp as it is shown however near it is looked at, and moves as the film plays.
///
/// It is a fill's (`Fill.shader`), drawn in place of the fill's picture, which stays as the canvas
/// looked when it came in: what cannot draw shaders (an older Bezzle, Windows and the browser
/// viewer so far) shows that, and a design taken elsewhere never comes out empty.
///
/// A page that draws into textures first (post-processing, a blur chain, a simulation) has
/// `targets` and `passes` too, and one whose frames build on the frames before them (feedback) is
/// drawn step by step from what its textures held when it came in (`builds`, `step(at:)`).
/// Bezzle 1.7 knows none of that and would draw such a frame wrongly, so a fill that has any of
/// it (`beyondPlain`) is written in the design under a key of its own, where 1.7 does not look
/// and shows the picture (`Fill`'s coding).
nonisolated struct ShaderFill: Codable, Hashable, Sendable {
    /// The drawing buffer, in pixels: the page's canvas, as wide and as tall as it drew.
    var size: CGSize
    /// What the frame is cleared to before its first draw, red, green, blue and alpha 0…1;
    /// see-through when nil.
    var clear: [Double]?
    /// The programs its draws use, each once.
    var programs: [ShaderProgram]
    var draws: [ShaderDraw]
    /// Its inputs that grew steadily as the page ran, by program and name: what moves it.
    var clocks: [ShaderClock] = []
    /// Its inputs the page's own script moved some other way, as they went over the seconds
    /// before it came in: played back and forth, so they move as they did and never jump.
    var recordings: [ShaderRecording]?
    /// How fast its time runs, 1 as the page ran it.
    var speed: Double = 1
    /// Seconds into its time where it is shown in the design, and where the film starts it. 0 is
    /// the moment it came in.
    var at: Double = 0
    /// Turned over where it is drawn, left to right or top to bottom, as its layer was flipped.
    var flippedX: Bool?
    var flippedY: Bool?
    /// How the page's canvas was made, as WebGL's context attributes say: whether it can be
    /// see-through, whether what it draws is taken as premultiplied, and whether its edges are
    /// smoothed. Each as WebGL has it, true, when nil.
    var alpha: Bool?
    var premultipliedAlpha: Bool?
    var antialias: Bool?
    /// The textures its passes draw into, each by its place here; none when nil.
    var targets: [ShaderTarget]?
    /// Its draws pass by pass, in order: each pass has the next `count` of `draws`. One pass onto
    /// the canvas, cleared to `clear`, when nil.
    var passes: [ShaderPass]?
    /// The textures of numbers its draws read, each by its place here (`ShaderDraw.texels`).
    var texels: [ShaderTexels]?
    /// For a fill whose frames build on the frames before: where each target stands in the next
    /// step, by its place in `targets` (a page that draws into two textures in turn swaps them
    /// every frame). Every target stays where it is when nil.
    var turn: [Int]?
    /// How many steps it takes a second, as often as the page drew: 60 when nil. Only where it
    /// `builds`.
    var rate: Double?
    /// Animate: the keys of its inputs, by input, for the layer's motion to reach every step of
    /// a fill that builds (`Node.withInputs`). Never kept in a design.
    var keyed: [String: MotionTrack]?

    /// `keyed` is the film's, set for a moment and not the design's.
    enum CodingKeys: String, CodingKey {
        case size, clear, programs, draws, clocks, recordings, speed, at, flippedX, flippedY, alpha, premultipliedAlpha, antialias
        case targets, passes, texels, turn, rate
    }

    /// Whether anything of it moves with time.
    var moves: Bool { (clocks.contains { $0.rate != 0 } || recordings?.isEmpty == false || builds) && speed != 0 }

    /// Its own time at a moment of the film, in seconds from the film's start; in the design
    /// (`film` nil), its moment there.
    func time(film: Double?) -> Double { at + (film ?? 0) * speed }

    /// The inputs a draw is given at its own time `t`: as the page gave them, but those that ran
    /// with time, which are where they would have come to `t` seconds after it came in. `place`
    /// is the draw's among the fill's, for what moved in that draw alone.
    func uniforms(of draw: ShaderDraw, at t: Double, place: Int? = nil) -> [String: [Double]] {
        var out = draw.uniforms
        for clock in clocks where clock.program == draw.program && (clock.draw == nil || clock.draw == place) {
            var values = out[clock.uniform] ?? []
            guard clock.component >= 0 else { continue }
            while values.count <= clock.component { values.append(0) }
            values[clock.component] = clock.start + clock.rate * t
            out[clock.uniform] = values
        }
        for recording in recordings ?? [] where recording.program == draw.program && (recording.draw == nil || recording.draw == place) {
            var values = out[recording.uniform] ?? []
            guard recording.component >= 0, let v = recording.value(at: t) else { continue }
            while values.count <= recording.component { values.append(0) }
            values[recording.component] = v
            out[recording.uniform] = values
        }
        // The film's keys of its inputs, at the film's moment this time of its own is.
        if let keyed, speed != 0 {
            let film = (t - at) / speed
            for (name, track) in keyed {
                guard let design = out[name] else { continue }
                let change = track.value(at: film, rest: Array(repeating: 0, count: design.count))
                out[name] = design.enumerated().map { i, v in v + (i < change.count ? change[i] : 0) }
            }
        }
        return out
    }

    /// The pictures it samples, for keeping and sharing with the design's other pictures.
    var pictures: [ImageFill] {
        draws.flatMap { ($0.textures ?? [:]).values }.map { ImageFill(asset: $0.asset, size: $0.size) }
    }

    /// The same drawing turned over with its layer.
    func flipped(horizontally: Bool) -> ShaderFill {
        var s = self
        if horizontally { s.flippedX = flippedX == true ? nil : true } else { s.flippedY = flippedY == true ? nil : true }
        return s
    }
}

/// A WebGL program: its vertex and its fragment shader, as the page wrote them.
nonisolated struct ShaderProgram: Codable, Hashable, Sendable {
    var vertex: String
    var fragment: String
}

/// One draw of the frame, as WebGL's drawArrays or drawElements made it, with what was bound.
nonisolated struct ShaderDraw: Codable, Hashable, Sendable {
    /// `lineLoop` is not known to Bezzle 1.7: a fill with one is `beyondPlain`.
    enum Mode: String, Codable, Sendable { case triangles, triangleStrip, triangleFan, lines, lineStrip, points, lineLoop }

    /// Its place in the fill's programs.
    var program: Int
    /// Its uniforms as last set, by the names the page asked for them by ("u_time", "u_colors" or
    /// "u_colors[1]"): numbers in order, an array or a matrix flattened, matrices by column.
    var uniforms: [String: [Double]]
    /// Its vertices' attributes, by name.
    var attributes: [String: ShaderAttribute]
    /// The vertices it draws, by number, little-endian 32-bit; nil when it draws them in order.
    var indices: Data?
    var mode: Mode
    var first: Int
    var count: Int
    /// The pictures its samplers sample, by the sampler's name.
    var textures: [String: ShaderTexture]?
    /// Whether its pictures were turned upside down as they went to the graphics card
    /// (WebGL's UNPACK_FLIP_Y_WEBGL).
    var flipsTextures: Bool?
    /// Whether its pictures were premultiplied as they went (UNPACK_PREMULTIPLY_ALPHA_WEBGL).
    var premultipliesTextures: Bool?
    /// How its samplers read their pictures, by sampler; clamped to the edge, smoothed and
    /// with no smaller copies, when one has none.
    var sampling: [String: ShaderSampling]?
    /// How it lies over what was drawn before it; replacing it when nil.
    var blend: ShaderBlend?
    /// The part of the drawing buffer it draws in, in pixels from the bottom left, as WebGL's;
    /// all of it when nil. In a pass into targets, of the target.
    var viewport: CGRect?
    /// The fill's targets its samplers read, by the sampler's name: what the passes before left.
    var targets: [String: Int]?
    /// The fill's textures of numbers its samplers read, by the sampler's name.
    var texels: [String: Int]?
    /// The samplers whose picture or numbers are kept as sRGB and read as light.
    var decodes: [String]?
    /// The depth test; none when nil.
    var depth: ShaderDepth?
    /// The stencil test; none when nil.
    var stencil: ShaderStencil?
    /// The faces left out, "front", "back" or "both" (cullFace); none when nil.
    var cull: String?
    /// Whether clockwise triangles face the front (frontFace).
    var clockwiseFront: Bool?
    /// The channels it writes, as colorMask set them: 1 for red, 2 green, 4 blue, 8 alpha, added
    /// up; all of them when nil.
    var channels: Int?
    /// The scissor box, in the pixels of what it draws into, from the bottom left; none when nil.
    var scissor: CGRect?
    /// polygonOffset's factor and units.
    var offset: [Double]?
    /// How often it is drawn, each time with the next of its attributes that have a `divisor`
    /// (drawArraysInstanced); once when nil.
    var instances: Int?

    /// Whether it has anything Bezzle 1.7 does not know (`ShaderFill.beyondPlain`).
    var beyondPlain: Bool {
        targets != nil || texels != nil || decodes != nil || depth != nil || stencil != nil || cull != nil || clockwiseFront != nil
            || channels != nil || scissor != nil || offset != nil || instances != nil || mode == .lineLoop
            || attributes.values.contains { $0.divisor != nil } || blend?.color != nil
    }
}

/// A texture a page drew into through a framebuffer, for its later draws to read.
nonisolated struct ShaderTarget: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
    /// What a texel holds: "rgba8" when nil; "rg8", "r8", and the same in half floats ("rgba16f",
    /// "rg16f", "r16f") and floats ("rgba32f", "rg32f", "r32f").
    var format: String?
    /// An RGB texture: its alpha reads 1 whatever is drawn.
    var opaque: Bool?
    /// Has smaller copies of itself, made when a pass asks (`ShaderPass.mipmaps`).
    var mipmapped: Bool?
    /// Keeps what it holds from one frame to the next: the fill then builds on the frames before.
    var keeps: Bool?
    /// What it held when the canvas came in: its texels in `format`, little-endian, rows from the
    /// bottom up. Nothing when nil.
    var contents: Data?
    /// Sized by the canvas, so drawn larger where the fill is shown larger. Never where the fill
    /// builds.
    var scales: Bool?

    /// How many bytes a texel of a format takes, of a target's or of a texture of numbers; nil
    /// for a name that is none.
    static func bytesPerTexel(_ format: String?) -> Int? {
        switch format ?? "rgba8" {
        case "r8", "l8", "a8": 1
        case "rg8", "la8", "r16f": 2
        case "rgba8", "rg16f", "r32f": 4
        case "rgba16f", "rg32f": 8
        case "rgba32f": 16
        default: nil
        }
    }
}

/// What a page drew into one framebuffer in a row.
nonisolated struct ShaderPass: Codable, Hashable, Sendable {
    /// The targets it draws into, in drawBuffers' order; the canvas when nil.
    var colors: [Int]?
    /// The depth and stencil buffer it tests against, a number the passes into one framebuffer
    /// share; none when nil. The canvas has its own.
    var depth: Int?
    /// What it is cleared to before its draws, each kept as it is when nil.
    var clearColor: [Double]?
    var clearDepth: Double?
    var clearStencil: Int?
    /// How many of the fill's draws are its own, after those of the passes before it.
    var count: Int
    /// The targets whose smaller copies are made after its draws (generateMipmap).
    var mipmaps: [Int]?
}

/// A texture of numbers a page gave from a typed array: a lookup table, a noise, the start of a
/// simulation.
nonisolated struct ShaderTexels: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
    /// As `ShaderTarget.format` names them, and "l8", "a8" and "la8" for LUMINANCE, ALPHA and
    /// LUMINANCE_ALPHA.
    var format: String
    /// Its texels, little-endian, rows from t = 0 up, never premultiplied.
    var bytes: Data
}

/// The depth test of a draw: depthFunc by WebGL's name lowercased ("less", "lequal", "always"...),
/// depthMask and depthRange.
nonisolated struct ShaderDepth: Codable, Hashable, Sendable {
    var compare: String = "less"
    /// Whether it writes its depth; true when nil.
    var writes: Bool?
    /// depthRange's near and far; 0 and 1 when nil.
    var range: [Double]?
}

/// The stencil test of a draw, for front faces and for back faces (as the front when nil):
/// stencilFuncSeparate, stencilMaskSeparate and stencilOpSeparate, by WebGL's names lowercased
/// with dashes ("equal", "keep", "replace", "incr-wrap").
nonisolated struct ShaderStencil: Codable, Hashable, Sendable {
    struct Face: Codable, Hashable, Sendable {
        var compare: String = "always"
        var reference: Int = 0
        var readMask: Int = 0xFF
        var writeMask: Int = 0xFF
        var fail: String = "keep"
        var depthFail: String = "keep"
        var pass: String = "keep"
    }

    var front: Face
    var back: Face?
}

/// What a vertex attribute is given: a value per vertex, or one for all.
nonisolated struct ShaderAttribute: Codable, Hashable, Sendable {
    /// How many numbers a vertex has, 1 to 4.
    var components: Int
    /// The numbers, vertex after vertex, 32-bit floats, little-endian; nil for a constant.
    var values: Data?
    /// What every vertex has, when the page gave no array.
    var constant: [Double]?
    /// For how many instances each of its values is (vertexAttribDivisor); one for each vertex
    /// when nil.
    var divisor: Int?

    /// The numbers as floats.
    var floats: [Float] {
        guard let values else { return [] }
        return values.withUnsafeBytes { raw in (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) } }
    }

    static func floats(_ numbers: [Float], components: Int) -> ShaderAttribute {
        var data = Data(capacity: numbers.count * 4)
        for n in numbers { withUnsafeBytes(of: n.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return ShaderAttribute(components: components, values: data)
    }
}

nonisolated extension ShaderDraw {
    /// The vertices' numbers as integers.
    var indexList: [UInt32]? {
        guard let indices else { return nil }
        return indices.withUnsafeBytes { raw in (0..<(raw.count / 4)).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
    }
}

/// How a sampler reads its picture, as texParameteri and generateMipmap left it: past the edges
/// ("repeat", "clamp" or "mirror"), close up and far off ("nearest" or "linear"), and from
/// smaller copies when it has them.
nonisolated struct ShaderSampling: Codable, Hashable, Sendable {
    var wrapS = "clamp"
    var wrapT = "clamp"
    var magnify = "linear"
    var minify = "linear"
    /// Between the smaller copies, "nearest" or "linear"; none when nil.
    var mipmap: String?
}

/// A picture a sampler samples: a file in the design's images, and its size in pixels.
nonisolated struct ShaderTexture: Codable, Hashable, Sendable {
    var asset: String
    var size: CGSize
}

/// How a draw lies over what is under it, as WebGL's blendFuncSeparate and
/// blendEquationSeparate set it: WebGL's names for its factors and equations, lowercased with
/// dashes ("src-alpha", "one-minus-src-alpha", "func-add").
nonisolated struct ShaderBlend: Codable, Hashable, Sendable {
    var source: String
    var destination: String
    var sourceAlpha: String
    var destinationAlpha: String
    var equation: String = "func-add"
    var equationAlpha: String = "func-add"
    /// blendColor, four numbers, where a factor takes the constant; nil for none. Bezzle 1.7
    /// does not know it (`ShaderFill.beyondPlain`).
    var color: [Double]?
}

/// An input the page's script moved, one number of a program's uniform, as it went: its values
/// at moments over the seconds before the canvas came in, the last of them as it came in. Played
/// from there backwards and then forwards again, round and round, so that it moves as it moved
/// and its time 0 is the moment it came in.
nonisolated struct ShaderRecording: Codable, Hashable, Sendable {
    var program: Int
    var uniform: String
    var component: Int
    /// Seconds from the first value, in order; the last is how long it runs.
    var times: [Double]
    var values: [Double]
    /// The one draw it moved in, by its place among the fill's, where the draws of a program
    /// each had their own (a scene's meshes, each where it stands); every draw of the program
    /// when nil. Bezzle 1.7 does not know it (`ShaderFill.beyondPlain`).
    var draw: Int?

    /// Its value at the shader's own time `t`: from the end it came in at, back to its start, and
    /// on again, between its values.
    func value(at t: Double) -> Double? {
        guard let length = times.last, let first = times.first, values.count == times.count, !values.isEmpty else { return nil }
        let span = length - first
        guard span > 0, t.isFinite else { return values.last }
        var u = abs(t).truncatingRemainder(dividingBy: 2 * span)
        if u > span { u = 2 * span - u }
        // At the moment it came in, exactly as it was.
        guard u > 0 else { return values.last }
        let at = length - u
        // The two values round it.
        var hi = times.firstIndex { $0 >= at } ?? times.count - 1
        hi = max(hi, 1)
        let lo = hi - 1
        let w = times[hi] - times[lo]
        return w > 0 ? values[lo] + (values[hi] - values[lo]) * (at - times[lo]) / w : values[hi]
    }
}

/// An input that ran with time: one number of a program's uniform, at `start` when the canvas
/// came in and `rate` more each second after.
nonisolated struct ShaderClock: Codable, Hashable, Sendable {
    var program: Int
    var uniform: String
    /// Which of its numbers.
    var component: Int
    var start: Double
    var rate: Double
    /// The one draw it ran in, as `ShaderRecording.draw`.
    var draw: Int?
}

nonisolated extension ShaderFill {
    /// A shader drawn over the whole layer by one fragment shader, as a page draws a background:
    /// two triangles across the drawing buffer, `size` in pixels, given `uniforms`, and `time`
    /// (when named) the seconds since it began, `resolution` (when named) its size in pixels. A
    /// Shadertoy program (a `mainImage` and no `main`) is given its iResolution and iTime, and a
    /// `main` that calls it, as pages that use one do.
    static func surface(fragment: String, size: CGSize, uniforms: [String: [Double]] = [:], time: String? = "u_time",
                        resolution: String? = "u_resolution") -> ShaderFill {
        var fragment = fragment
        var uniforms = uniforms
        var time = time, resolution = resolution
        let es3 = fragment.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#version 300")
        if fragment.contains("mainImage"), fragment.range(of: #"void\s+main\s*\("#, options: .regularExpression) == nil {
            let declares = { (name: String) in fragment.range(of: #"uniform\s+\w+\s+\#(name)\b"#, options: .regularExpression) != nil }
            var head = fragment.contains("precision ") ? "" : "precision highp float;\n"
            if !declares("iResolution") { head += "uniform vec3 iResolution;\n" }
            if !declares("iTime") { head += "uniform float iTime;\n" }
            var tail = "\nvoid main() { mainImage(gl_FragColor, gl_FragCoord.xy); }\n"
            if es3 { tail = "\nout vec4 bezzleColor;\nvoid main() { mainImage(bezzleColor, gl_FragCoord.xy); }\n" }
            if es3, let line = fragment.range(of: "\n") {
                fragment.insert(contentsOf: head, at: line.upperBound)
            } else {
                fragment = head + fragment
            }
            fragment += tail
            time = "iTime"
            resolution = nil
            uniforms["iResolution"] = [size.width, size.height, 1]
        }
        let vertex = es3
            ? "#version 300 es\nin vec2 a_position;\nvoid main() { gl_Position = vec4(a_position, 0.0, 1.0); }\n"
            : "attribute vec2 a_position;\nvoid main() { gl_Position = vec4(a_position, 0.0, 1.0); }\n"
        if let resolution { uniforms[resolution] = [size.width, size.height] }
        if let time, uniforms[time] == nil { uniforms[time] = [0] }
        let corners = ShaderAttribute.floats([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1], components: 2)
        let draw = ShaderDraw(program: 0, uniforms: uniforms, attributes: ["a_position": corners], mode: .triangles, first: 0, count: 6)
        let clocks = time.map { [ShaderClock(program: 0, uniform: $0, component: 0, start: uniforms[$0]?.first ?? 0, rate: 1)] } ?? []
        return ShaderFill(size: size, programs: [ShaderProgram(vertex: vertex, fragment: fragment)], draws: [draw], clocks: clocks)
    }

    /// The names of its inputs a person may set: every uniform of its draws but those that run with
    /// time or play as they were recorded, each once, in order.
    var inputs: [String] {
        var seen = Set(clocks.map(\.uniform) + (recordings ?? []).map(\.uniform)), out: [String] = []
        for d in draws { for name in d.uniforms.keys.sorted() where seen.insert(name).inserted { out.append(name) } }
        return out
    }

    /// The same, an input set to `values` in every draw that has it.
    func setting(_ name: String, to values: [Double]) -> ShaderFill {
        var s = self
        for i in s.draws.indices where s.draws[i].uniforms[name] != nil { s.draws[i].uniforms[name] = values }
        return s
    }
}

nonisolated extension ShaderFill {
    /// Whether it has anything Bezzle 1.7 does not know and would draw wrongly, or not open the
    /// design for: passes into textures, textures of numbers, WebGL's tests and masks, instances.
    /// Such a fill is kept under `Fill`'s key "scene", and 1.7 shows its picture.
    var beyondPlain: Bool {
        targets != nil || passes != nil || texels != nil || turn != nil || rate != nil || draws.contains(where: \.beyondPlain)
            || clocks.contains { $0.draw != nil } || recordings?.contains { $0.draw != nil } == true
    }

    /// Whether its frames build on the frames before them: a target keeps what the last frame
    /// left (feedback, two textures drawn into in turn, a simulation). Its picture at a moment is
    /// then the step that moment falls in, drawn through from what it held when it came in.
    var builds: Bool { targets?.contains { $0.keeps == true } == true }

    /// How many steps a fill that builds takes a second.
    var stepRate: Double {
        guard let rate, rate.isFinite, rate > 0 else { return 60 }
        return min(max(rate, 1), 240)
    }

    /// The step shown at its own time `t`: step 0 at the moment it came in and before, one more
    /// every `1 / stepRate` seconds after, and never more than `mostSteps`. The same moment is
    /// always the same step, and a step always the same picture, however it is come to.
    func step(at t: Double) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        return min(Int((t * stepRate + 1e-6).rounded(.down)), Self.mostSteps)
    }

    /// Its own time at a step: what its clocks and recordings are given there, so that a step
    /// draws the same whatever moment within it is asked for. Step 0 is the frame the page would
    /// have drawn next, from what its textures held when it came in, so its time is one step on.
    func time(ofStep step: Int) -> Double { Double(step + 1) / stepRate }

    /// A fill that builds stands still after this many steps (ten minutes at 60 a second): going
    /// to a moment costs every step up to it once.
    static let mostSteps = 36_000

    /// Where a target stands after `steps` steps, by `turn`.
    func target(_ index: Int, after steps: Int) -> Int {
        guard let turn, steps > 0, turn.indices.contains(index) else { return index }
        // Round and round: only the steps beyond whole rounds count.
        var at = index, round = 0
        repeat {
            guard turn.indices.contains(at) else { return index }
            at = turn[at]
            round += 1
        } while at != index && round < turn.count
        guard at == index else { return index }
        at = index
        for _ in 0..<(steps % round) { at = turn[at] }
        return at
    }

    /// The draws of each pass, in order; one pass onto the canvas when it has none.
    var drawsByPass: [(pass: ShaderPass, draws: ArraySlice<ShaderDraw>)] {
        guard let passes else { return [(ShaderPass(clearColor: clear ?? [0, 0, 0, 0], count: draws.count), draws[...])] }
        var out: [(ShaderPass, ArraySlice<ShaderDraw>)] = [], from = 0
        for pass in passes {
            let to = min(draws.count, from + max(0, pass.count))
            out.append((pass, draws[from..<to]))
            from = to
        }
        return out
    }

    /// What a shader input's keys are kept under in a layer's motion: "shader." and its name.
    static func inputTrack(_ name: String) -> String { "shader." + name }

    /// The input a track keys, from its name; nil for a property's track.
    static func input(of track: String) -> String? {
        track.hasPrefix("shader.") && track.count > 7 ? String(track.dropFirst(7)) : nil
    }

    /// An input's value as its draws have it.
    func value(of input: String) -> [Double]? { draws.lazy.compactMap { $0.uniforms[input] }.first }
}

/// Animate: a shader's inputs keyed as the layer's other properties are, each a track of the
/// layer's motion of its own (`ShaderFill.inputTrack`). A key holds how far the input is from what
/// the design sets, as every key holds a change from the design, so an input set anew in the
/// design takes its motion with it, and a layer with no keys is as designed. The shader keyed is
/// the first of the layer's fills that has one.
nonisolated extension Node {
    /// The tracks of its shader's inputs that have keys, in order of their names.
    var inputTracks: [String] {
        guard let motion else { return [] }
        return motion.keys.filter { ShaderFill.input(of: $0) != nil && motion[$0]?.keys.isEmpty == false }.sorted()
    }

    /// The shader its inputs' keys are for.
    var keyedShader: ShaderFill? { fills.first { $0.shader != nil }?.shader }

    /// An input of its shader as the design sets it.
    func shaderInput(_ name: String) -> [Double]? { keyedShader?.value(of: name) }

    /// An input of its shader at a moment: as the design sets it, changed by its keys.
    func shaderInput(_ name: String, at t: Double) -> [Double]? {
        guard let design = shaderInput(name) else { return nil }
        guard let track = self[track: ShaderFill.inputTrack(name)] else { return design }
        let change = track.value(at: t, rest: Array(repeating: 0, count: design.count))
        return design.enumerated().map { i, v in v + (i < change.count ? change[i] : 0) }
    }

    /// The layer with its shader's inputs where their keys have them at a moment. A shader that
    /// builds on the frames before it is given the keys themselves, since every step up to the
    /// moment is drawn with the inputs as they were then.
    func withInputs(at t: Double) -> Node {
        let tracks = inputTracks
        guard !tracks.isEmpty, let slot = fills.firstIndex(where: { $0.shader != nil }) else { return self }
        var n = self
        let path = Node.fillPath(slot)
        if n[keyPath: path].shader?.builds == true {
            var keyed: [String: MotionTrack] = [:]
            for track in tracks {
                if let name = ShaderFill.input(of: track), let keys = self[track: track] { keyed[name] = keys }
            }
            n[keyPath: path].shader?.keyed = keyed.isEmpty ? nil : keyed
            return n
        }
        for track in tracks {
            guard let name = ShaderFill.input(of: track), let value = shaderInput(name, at: t) else { continue }
            n[keyPath: path].shader = n[keyPath: path].shader?.setting(name, to: value)
        }
        return n
    }

    /// Poses an input at a moment, as posing a property does (`pose(_:_:at:home:)`): `value` is
    /// what the input is to be there, kept as how far that is from the design.
    mutating func poseInput(_ name: String, _ value: [Double], at time: Double, home: Double = MotionTiming.beat) {
        guard let design = shaderInput(name) else { return }
        let change = (0..<design.count).map { i in (i < value.count ? value[i] : design[i]) - design[i] }
        let rest = Array(repeating: 0.0, count: design.count)
        let track = ShaderFill.inputTrack(name), t = MotionTiming.time(time)
        guard var keys = self[track: track] else {
            guard !MotionTiming.alike(change, rest) else { return }
            if t < 0.0042 {
                let home = home.isFinite ? max(home, 0.05) : MotionTiming.beat
                self[track: track] = MotionTrack([MotionKey(t: 0, v: change), MotionKey(t: home, v: rest, given: true)])
            } else {
                self[track: track] = MotionTrack([MotionKey(t: 0, v: rest, given: true), MotionKey(t: t, v: change)])
            }
            return
        }
        if let i = keys.index(at: t) {
            keys.keys[i].v = change
            keys.keys[i].given = nil
        } else {
            if let last = keys.keys.last, last.given == true, t > last.t, keys.keys.count == 2 { keys.keys.removeLast() }
            keys.keys.append(MotionKey(t: t, v: change))
            keys.keys.sort { $0.t < $1.t }
        }
        self[track: track] = keys
    }

    /// Sets a key of an input and nothing else: `change` is how far it is from the design there.
    mutating func setInputKey(_ name: String, change: [Double], at time: Double, ease: MotionEase? = nil) {
        let track = ShaderFill.inputTrack(name), t = MotionTiming.time(time)
        var keys = self[track: track] ?? MotionTrack()
        if let i = keys.index(at: t) {
            keys.keys[i].v = change
            keys.keys[i].given = nil
            if let ease { keys.keys[i].ease = ease.kind == .auto ? nil : ease }
        } else {
            keys.keys.append(MotionKey(t: t, v: change, ease: ease.flatMap { $0.kind == .auto ? nil : $0 }))
            keys.keys.sort { $0.t < $1.t }
        }
        self[track: track] = keys
    }
}

nonisolated extension Node {
    /// Whether a shader of its own moves as time passes: by itself, or by keys of its inputs.
    var shaderMoves: Bool { fills.contains { $0.on && $0.shader?.moves == true } || !inputTracks.isEmpty }

    /// Whether it, or anything it holds, has a shader that moves.
    var holdsMovingShader: Bool { shaderMoves || children.contains(where: \.holdsMovingShader) }
}
