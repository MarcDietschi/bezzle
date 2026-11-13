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

    /// Whether anything of it moves with time.
    var moves: Bool { (clocks.contains { $0.rate != 0 } || recordings?.isEmpty == false) && speed != 0 }

    /// Its own time at a moment of the film, in seconds from the film's start; in the design
    /// (`film` nil), its moment there.
    func time(film: Double?) -> Double { at + (film ?? 0) * speed }

    /// The inputs a draw is given at its own time `t`: as the page gave them, but those that ran
    /// with time, which are where they would have come to `t` seconds after it came in.
    func uniforms(of draw: ShaderDraw, at t: Double) -> [String: [Double]] {
        var out = draw.uniforms
        for clock in clocks where clock.program == draw.program {
            var values = out[clock.uniform] ?? []
            guard clock.component >= 0 else { continue }
            while values.count <= clock.component { values.append(0) }
            values[clock.component] = clock.start + clock.rate * t
            out[clock.uniform] = values
        }
        for recording in recordings ?? [] where recording.program == draw.program {
            var values = out[recording.uniform] ?? []
            guard recording.component >= 0, let v = recording.value(at: t) else { continue }
            while values.count <= recording.component { values.append(0) }
            values[recording.component] = v
            out[recording.uniform] = values
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
    enum Mode: String, Codable, Sendable { case triangles, triangleStrip, triangleFan, lines, lineStrip, points }

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
    /// all of it when nil.
    var viewport: CGRect?
}

/// What a vertex attribute is given: a value per vertex, or one for all.
nonisolated struct ShaderAttribute: Codable, Hashable, Sendable {
    /// How many numbers a vertex has, 1 to 4.
    var components: Int
    /// The numbers, vertex after vertex, 32-bit floats, little-endian; nil for a constant.
    var values: Data?
    /// What every vertex has, when the page gave no array.
    var constant: [Double]?

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

    /// The layer with its shader's inputs where their keys have them at a moment.
    func withInputs(at t: Double) -> Node {
        let tracks = inputTracks
        guard !tracks.isEmpty, let slot = fills.firstIndex(where: { $0.shader != nil }) else { return self }
        var n = self
        let path = Node.fillPath(slot)
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
