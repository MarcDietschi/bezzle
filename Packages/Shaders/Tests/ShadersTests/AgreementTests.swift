import Foundation
import Testing
@testable import Shaders

/// The same frames drawn by the Mac with Metal and by Windows with Direct3D, pixel for pixel.
///
/// `SHADERS_WRITE_REFERENCES=<folder>` writes each sample as this platform draws it, `<name>.png`
/// (on the Mac, the references). `SHADERS_REFERENCES=<folder>` draws each again and compares it
/// with the reference there, writing what it drew and the difference into `SHADERS_COMPARED`
/// (or the system's temporary folder) and the numbers into `agreement.txt` beside them.
/// Windows/VM/shader-agreement.sh does the whole round: references on the Mac, comparison in the VM.
@Suite(.serialized) struct AgreementTests {
    struct Sample {
        var name: String
        var frame: ShaderFrame
        var scale: Double = 1
        var region: CGRect? = nil
        /// How far the two may part, and why, where more than the rounding of a colour.
        var tolerance = Tolerance.close
        /// The frames of the steps before, where the frame builds on them.
        var earlier: ((Int) -> ShaderFrame)? = nil
    }

    /// The samples this platform's back end draws: all of them on the Mac; on Windows, those
    /// with nothing Direct3D refuses yet.
    static var drawn: [Sample] {
        samples.filter { drawsPasses || $0.frame.beyondPlainDraws == nil }
    }

    /// The largest difference in any channel, the mean difference over all channels, and the
    /// share of channels more than 2 apart (of 255).
    struct Tolerance {
        var largest: Int
        var mean: Double
        var beyond: Double
        var why: String?

        /// Rounding alone: what two GPUs computing in 32 bits part by, a texture's linear filter
        /// weighing its four texels each its own way among them.
        static let close = Tolerance(largest: 3, mean: 0.5, beyond: 0.001)
    }

    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["SHADERS_WRITE_REFERENCES"] != nil))
    func writeReferences() throws {
        let folder = URL(fileURLWithPath: Self.environment["SHADERS_WRITE_REFERENCES"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sample in Self.drawn {
            let pixels = try draw(sample.frame, scale: sample.scale, region: sample.region, earlier: sample.earlier)
            try PNG.data(pixels).write(to: folder.appendingPathComponent(sample.name + ".png"))
        }
    }

    @Test(.enabled(if: environment["SHADERS_REFERENCES"] != nil))
    func agreesWithTheReferences() throws {
        let references = URL(fileURLWithPath: Self.environment["SHADERS_REFERENCES"]!, isDirectory: true)
        let out = URL(fileURLWithPath: Self.environment["SHADERS_COMPARED"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = ["sample\tsize\tlargest\tmean\tbeyond 2\tbeyond 8\tallowed"]
        for sample in Self.samples where !drawsPasses {
            if let what = sample.frame.beyondPlainDraws { report.append("\(sample.name)\tnot drawn here yet: \(what)") }
        }
        for sample in Self.drawn {
            let data = try Data(contentsOf: references.appendingPathComponent(sample.name + ".png"))
            let reference = try #require(PNG.pixels(data), "\(sample.name): the reference does not read")
            let drawn = try draw(sample.frame, scale: sample.scale, region: sample.region, earlier: sample.earlier)
            try PNG.data(drawn).write(to: out.appendingPathComponent(sample.name + ".png"))
            #expect(drawn.width == reference.width && drawn.height == reference.height, "\(sample.name): size")
            guard drawn.width == reference.width, drawn.height == reference.height else { continue }
            var largest = 0, sum = 0, beyond2 = 0, beyond8 = 0
            var difference = [UInt8](repeating: 255, count: drawn.bytes.count)
            for i in 0..<drawn.bytes.count {
                let d = abs(Int(drawn.bytes[i]) - Int(reference.bytes[i]))
                largest = max(largest, d)
                sum += d
                if d > 2 { beyond2 += 1 }
                if d > 8 { beyond8 += 1 }
                if i % 4 != 3 {
                    // The difference, magnified eight times, over opaque white.
                    let pixel = i - i % 4
                    let most = (0..<4).map { abs(Int(drawn.bytes[pixel + $0]) - Int(reference.bytes[pixel + $0])) }.max()!
                    difference[i] = UInt8(max(0, 255 - min(255, most * 8)))
                }
            }
            try PNG.data(Pixels(width: drawn.width, height: drawn.height, bytes: difference))
                .write(to: out.appendingPathComponent(sample.name + ".difference.png"))
            let channels = Double(drawn.bytes.count)
            let mean = Double(sum) / channels, share = Double(beyond2) / channels
            let t = sample.tolerance
            func f(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
            report.append("\(sample.name)\t\(drawn.width)x\(drawn.height)\t\(largest)\t\(f(mean, 3))\t\(f(share * 100, 3))%"
                + "\t\(f(Double(beyond8) / channels * 100, 3))%\t\(t.largest), \(f(t.mean, 2)), \(f(t.beyond * 100, 2))%"
                + (t.why.map { " (\($0))" } ?? ""))
            #expect(largest <= t.largest && mean <= t.mean && share <= t.beyond,
                    "\(sample.name): largest \(largest), mean \(mean), \(share * 100)% beyond 2")
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: out.appendingPathComponent("agreement.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    // MARK: The samples

    static let quadVertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
    static let white = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"

    static func shape(_ positions: [Float], mode: ShaderDraw.Mode = .triangles, fragment: String = white,
                      vertex: String = quadVertex, blend: ShaderDraw.Blend? = nil) -> ShaderDraw {
        ShaderDraw(vertex: vertex, fragment: fragment, attributes: ["a_position": .init(components: 2, values: positions)],
                   mode: mode, count: positions.count / 2, blend: blend)
    }

    static func canvas(_ width: Int, _ height: Int, _ draws: [ShaderDraw], clear: [Float]? = nil,
                       antialias: Bool = false) -> ShaderFrame {
        ShaderFrame(size: CGSize(width: width, height: height), clear: clear, draws: draws, antialias: antialias)
    }

    /// A picture with a colour ramp across, alpha falling down it, and a hard-edged square.
    static let photo: ShaderPicture = {
        var rgba: [UInt8] = []
        for y in 0..<24 {
            for x in 0..<32 {
                let square = (8..<16).contains(x) && (6..<14).contains(y)
                rgba += square ? [250, 250, 40, 255]
                    : [UInt8(x * 255 / 31), UInt8(255 - y * 10), UInt8((x * y) % 256), UInt8(255 - y * 9)]
            }
        }
        return picture(32, 24, rgba)
    }()

    static let checker: ShaderPicture = {
        var rgba: [UInt8] = []
        for y in 0..<64 { for x in 0..<64 { rgba += (x / 4 + y / 4) % 2 == 0 ? [255, 255, 255, 255] : [20, 40, 200, 255] } }
        return picture(64, 64, rgba)
    }()

    static let sampling = """
        precision mediump float;
        uniform sampler2D u_image;
        uniform vec2 u_resolution;
        uniform vec2 u_repeat;
        void main() {
            vec2 uv = gl_FragCoord.xy / u_resolution * u_repeat - 0.3;
            gl_FragColor = texture2D(u_image, uv);
        }
        """

    static func textured(_ width: Int, _ height: Int, _ image: ShaderPicture, repeat count: Float = 1,
                         sampling: ShaderDraw.Sampling = .init(), flip: Bool = false, premultiply: Bool = false,
                         blend: ShaderDraw.Blend? = nil) -> ShaderFrame {
        var draw = ShaderDraw.fullSurface(fragment: Self.sampling, uniforms: ["u_resolution": [Float(width), Float(height)],
                                                                             "u_repeat": [count, count]],
                                          textures: ["u_image": image], blend: blend)
        draw.sampling["u_image"] = sampling
        draw.flipsTextures = flip
        draw.premultipliesTextures = premultiply
        return ShaderFrame(size: CGSize(width: width, height: height), draws: [draw], antialias: false)
    }

    static let pointVertex = """
        attribute vec2 a_position;
        attribute float a_size;
        void main() { gl_Position = vec4(a_position, 0.0, 1.0); gl_PointSize = a_size; }
        """
    static let pointFragment = "precision mediump float; void main() { gl_FragColor = vec4(gl_PointCoord, 0.5, 1.0); }"

    static func points(antialias: Bool = false) -> ShaderFrame {
        let draw = ShaderDraw(vertex: pointVertex, fragment: pointFragment,
                              attributes: ["a_position": .init(components: 2, values: [-0.6, -0.5, 0, 0.1, 0.55, 0.6, 0.9, -0.9]),
                                           "a_size": .init(components: 1, values: [3, 8, 13.5, 6])],
                              mode: .points, count: 4)
        return canvas(40, 40, [draw], antialias: antialias)
    }

    static func blended(_ blend: ShaderDraw.Blend, clear: [Float] = [0.2, 0.4, 0.6, 0.8]) -> ShaderFrame {
        let ramp = """
            precision mediump float;
            uniform vec2 u_resolution;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                gl_FragColor = vec4(uv.x, 1.0 - uv.y, 0.5, uv.x * 0.8 + 0.1) * vec4(vec3(uv.x * 0.8 + 0.1), 1.0);
            }
            """
        return ShaderFrame(size: CGSize(width: 32, height: 32), clear: clear,
                           draws: [ShaderDraw.fullSurface(fragment: ramp, uniforms: ["u_resolution": [32, 32]], blend: blend)],
                           antialias: false)
    }

    static var samples: [Sample] {
        let gradient = ConventionsTests.gradient
        var list: [Sample] = [
            Sample(name: "gradient", frame: frame(64, 32, gradient)),
            Sample(name: "gradient-twice", frame: frame(64, 32, gradient), scale: 2),
            Sample(name: "gradient-region-four-times", frame: frame(64, 32, gradient), scale: 4,
                   region: CGRect(x: 16, y: 8, width: 24, height: 12)),
            Sample(name: "gradient-region-uneven", frame: frame(64, 32, gradient), scale: 2.5,
                   region: CGRect(x: 10.5, y: 3.25, width: 20, height: 10)),
        ]

        // gl_FragCoord's depth and w, and perspective across a quad whose corners lie at different w.
        let depth = ShaderDraw(vertex: """
            attribute vec3 a_position;
            varying vec2 v_uv;
            void main() {
                v_uv = a_position.xy * 0.5 + 0.5;
                float w = a_position.z;
                gl_Position = vec4(a_position.xy * w, (a_position.x * 0.5) * w, w);
            }
            """, fragment: """
            precision highp float;
            varying vec2 v_uv;
            void main() {
                float check = mod(floor(v_uv.x * 8.0) + floor(v_uv.y * 8.0), 2.0);
                gl_FragColor = vec4(gl_FragCoord.z, gl_FragCoord.w * 0.5, check, 1.0);
            }
            """, attributes: ["a_position": .init(components: 3, values: [-1, -1, 0.5, 1, -1, 2, -1, 1, 0.5, -1, 1, 0.5, 1, -1, 2, 1, 1, 2])],
            count: 6)
        list.append(Sample(name: "depth-and-perspective", frame: canvas(48, 48, [depth])))
        list.append(Sample(name: "depth-and-perspective-region", frame: canvas(48, 48, [depth]), scale: 3,
                           region: CGRect(x: 10, y: 14, width: 20, height: 12)))

        // Derivatives: of gl_FragCoord (exact) and of a curve (as each GPU's 2 by 2 quads take them).
        let derivatives = """
            #extension GL_OES_standard_derivatives : enable
            precision highp float;
            void main() {
                float up = dFdy(gl_FragCoord.y), right = dFdx(gl_FragCoord.x);
                gl_FragColor = vec4(up * 0.5, right * 0.5, 0.0, 1.0);
            }
            """
        list.append(Sample(name: "derivatives-of-fragcoord-twice", frame: frame(16, 16, derivatives), scale: 2))
        let curve = """
            #extension GL_OES_standard_derivatives : enable
            precision highp float;
            void main() {
                float v = sin(gl_FragCoord.x * 0.35) * cos(gl_FragCoord.y * 0.2);
                gl_FragColor = vec4(fwidth(v) * 3.0, v * 0.5 + 0.5, 0.0, 1.0);
            }
            """
        list.append(Sample(name: "derivatives-of-a-curve", frame: frame(48, 32, curve)))

        // Faces, clip space, the viewport.
        let faces = "precision mediump float; void main() { gl_FragColor = gl_FrontFacing ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }"
        list.append(Sample(name: "front-and-back-faces",
                           frame: canvas(32, 32, [shape([-1, -1, 0, -1, -1, 1], fragment: faces), shape([0.2, -1, 0.2, 1, 1, -1], fragment: faces)])))
        var viewport = ShaderDraw.fullSurface(fragment: gradient, uniforms: ["u_resolution": [64, 32]])
        viewport.viewport = CGRect(x: 8, y: 4, width: 36, height: 20)
        list.append(Sample(name: "viewport", frame: canvas(64, 32, [viewport])))
        list.append(Sample(name: "viewport-region-twice", frame: canvas(64, 32, [viewport]), scale: 2,
                           region: CGRect(x: 24, y: 8, width: 24, height: 16)))

        // Points, sized and with gl_PointCoord, also where a tile cuts them and with antialias.
        list.append(Sample(name: "points", frame: points()))
        list.append(Sample(name: "points-three-times", frame: points(), scale: 3))
        list.append(Sample(name: "points-cut-by-a-region", frame: points(), scale: 2, region: CGRect(x: 24, y: 6, width: 16, height: 16)))
        list.append(Sample(name: "points-centre-outside-a-region", frame: points(), scale: 2,
                           region: CGRect(x: 33, y: 0, width: 7, height: 16)))
        list.append(Sample(name: "points-antialiased", frame: points(antialias: true)))

        // Lines, a loop and a strip, and a fan.
        let lines = [shape([-0.8, -0.8, 0.7, -0.3, -0.5, 0.9, 0.9, 0.95], mode: .lines),
                     shape([-0.9, 0.2, -0.3, 0.6, 0.3, -0.6, 0.8, 0.1], mode: .lineStrip),
                     shape([-0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, 0.5], mode: .lineLoop)]
        list.append(Sample(name: "lines", frame: canvas(32, 32, lines),
                           tolerance: Tolerance(largest: 255, mean: 0.5, beyond: 0.002,
                                                why: "a slanted line one pixel wide: which pixel it lights at a tie is each GPU's own")))
        list.append(Sample(name: "lines-antialiased", frame: canvas(32, 32, lines, antialias: true),
                           tolerance: Tolerance(largest: 64, mean: 1.5, beyond: 0.025,
                                                why: "samples a line passes exactly through: which side they fall is each GPU's own")))
        list.append(Sample(name: "fan", frame: canvas(24, 24, [shape([0, 0, 0.9, 0, 0.6, 0.7, -0.2, 0.9, -0.8, 0.3, -0.7, -0.6], mode: .triangleFan)])))

        // Edges with four samples a pixel.
        list.append(Sample(name: "antialiased-edges",
                           frame: canvas(48, 48, [shape([-1, -1, 1, -0.7, -1, 1]), shape([0.1, 0.9, 0.95, -0.95, 0.6, 0.8],
                                                                                        fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.2, 0.6, 1.0, 1.0); }")],
                                          antialias: true)))

        // Pictures: nearest with and without the flip, linear and repeated, mirrored, straight
        // and premultiplied, mipmapped, and a cube.
        let tiny = picture(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let nearest = ShaderDraw.Sampling(magnify: .nearest, minify: .nearest)
        list.append(Sample(name: "picture-nearest", frame: textured(8, 8, tiny, sampling: nearest)))
        list.append(Sample(name: "picture-nearest-flipped", frame: textured(8, 8, tiny, sampling: nearest, flip: true)))
        list.append(Sample(name: "picture-linear", frame: textured(80, 60, photo)))
        list.append(Sample(name: "picture-linear-flipped-premultiplied",
                           frame: textured(80, 60, photo, flip: true, premultiply: true, blend: .premultipliedOver)))
        list.append(Sample(name: "picture-repeated", frame: textured(96, 72, photo, repeat: 2.5,
                                                                      sampling: .init(wrapS: .repeat, wrapT: .mirroredRepeat))))
        list.append(Sample(name: "picture-mipmapped", frame: textured(24, 24, checker, repeat: 1.5,
                                                                       sampling: .init(wrapS: .repeat, wrapT: .repeat, minify: .linear, mipmap: .linear))))
        list.append(Sample(name: "picture-minified-nearest", frame: textured(24, 24, checker, repeat: 1.5,
                                                                              sampling: .init(wrapS: .repeat, wrapT: .repeat, magnify: .nearest, minify: .nearest))))
        let faces6: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255], [255, 255, 255, 255], [128, 128, 128, 255]]
        var stacked: [UInt8] = []
        for (index, face) in faces6.enumerated() {
            for y in 0..<4 { for x in 0..<4 { stacked += (x + y) % 2 == 0 ? face : [UInt8(index * 40), 30, 60, 255] } }
        }
        let sky = picture(4, 24, stacked)
        let cube = """
            precision mediump float;
            uniform samplerCube u_sky;
            uniform vec2 u_resolution;
            void main() {
                vec2 p = gl_FragCoord.xy / u_resolution * 2.0 - 1.0;
                float a = p.x * 3.1416, b = p.y * 1.5;
                gl_FragColor = textureCube(u_sky, vec3(cos(b) * sin(a), sin(b), cos(b) * cos(a)));
            }
            """
        var cubeDraw = ShaderDraw.fullSurface(fragment: cube, uniforms: ["u_resolution": [64, 32]], textures: ["u_sky": sky])
        cubeDraw.sampling["u_sky"] = nearest
        list.append(Sample(name: "cube", frame: ShaderFrame(size: CGSize(width: 64, height: 32), draws: [cubeDraw], antialias: false)))
        cubeDraw.flipsTextures = true
        list.append(Sample(name: "cube-flipped", frame: ShaderFrame(size: CGSize(width: 64, height: 32), draws: [cubeDraw], antialias: false)))

        // Blending, and what the canvas does with alpha.
        list.append(Sample(name: "blend-premultiplied-over", frame: blended(.premultipliedOver)))
        list.append(Sample(name: "blend-straight-over", frame: blended(.over)))
        list.append(Sample(name: "blend-added", frame: blended(ShaderDraw.Blend(source: .one, destination: .one))))
        list.append(Sample(name: "blend-subtracted", frame: blended(ShaderDraw.Blend(source: .one, destination: .one, equation: .reverseSubtract,
                                                                                    equationAlpha: .subtract))))
        list.append(Sample(name: "blend-least-and-most", frame: blended(ShaderDraw.Blend(source: .one, destination: .one, equation: .min,
                                                                                        equationAlpha: .max))))
        list.append(Sample(name: "blend-colours", frame: blended(ShaderDraw.Blend(source: .destinationColor, destination: .oneMinusSourceColor,
                                                                                 sourceAlpha: .oneMinusDestinationAlpha, destinationAlpha: .sourceAlphaSaturate))))
        list.append(Sample(name: "blend-constant", frame: blended(ShaderDraw.Blend(source: .constantColor, destination: .oneMinusConstantColor,
                                                                                  color: [0.25, 0.5, 0.75, 0.6]))))
        list.append(Sample(name: "blend-constant-alpha", frame: blended(ShaderDraw.Blend(source: .constantAlpha, destination: .oneMinusConstantAlpha,
                                                                                        sourceAlpha: .one, destinationAlpha: .zero,
                                                                                        color: [0.9, 0.1, 0.1, 0.3]))))
        let glow = "precision mediump float; uniform vec2 u_resolution; void main() { vec2 uv = gl_FragCoord.xy / u_resolution; gl_FragColor = vec4(uv.x, uv.y, 0.8, 0.5 * uv.x); }"
        var straight = frame(32, 16, glow)
        straight.premultipliedAlpha = false
        list.append(Sample(name: "canvas-not-premultiplied", frame: straight))
        var opaque = frame(32, 16, glow, antialias: true)
        opaque.alpha = false
        list.append(Sample(name: "canvas-opaque", frame: opaque))
        list.append(Sample(name: "canvas-premultiplied-brighter-than-alpha", frame: frame(32, 16, glow)))

        // State: indices, matrices, attributes, uniforms of every kind.
        let meshVertex = """
            attribute vec2 a_position;
            attribute vec3 a_color;
            uniform mat3 u_matrix;
            varying vec3 v_color;
            void main() { v_color = a_color; gl_Position = vec4((u_matrix * vec3(a_position, 1.0)).xy, 0.0, 1.0); }
            """
        let mesh = ShaderDraw(vertex: meshVertex, fragment: "precision mediump float; varying vec3 v_color; void main() { gl_FragColor = vec4(v_color, 1.0); }",
                              uniforms: ["u_matrix": [0.8, 0.3, 0, -0.3, 0.8, 0, 0.1, -0.05, 1]],
                              attributes: ["a_position": .init(components: 2, values: [-0.7, -0.7, 0.7, -0.7, 0.7, 0.7, -0.7, 0.7]),
                                           "a_color": .init(components: 3, values: [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0])],
                              indices: [0, 1, 2, 0, 2, 3], count: 6)
        list.append(Sample(name: "mesh-indexed-turned", frame: canvas(40, 40, [mesh], antialias: true)))
        let attributes = ShaderDraw(vertex: """
            attribute vec2 a_position;
            attribute mat2 a_turn;
            attribute vec4 a_short;
            attribute vec4 a_constant;
            attribute vec4 a_never;
            attribute float a_count;
            varying vec4 v_color;
            void main() {
                v_color = vec4(a_turn[1][0] * 0.5 + 0.5, a_short.z + a_short.w * 0.5, a_constant.y, a_never.w * 0.5 + a_count * 0.1);
                gl_Position = vec4(a_turn * a_position, 0.0, 1.0);
            }
            """, fragment: "precision mediump float; varying vec4 v_color; void main() { gl_FragColor = v_color; }",
            attributes: ["a_position": .init(components: 2, values: [-0.8, -0.8, 0.8, -0.6, -0.4, 0.9]),
                         "a_turn": .init(components: 4, values: [0.9, 0.3, -0.3, 0.9, 0.7, 0.7, -0.7, 0.7, 1, 0, 0, 1]),
                         "a_short": .init(components: 2, values: [0.2, 0.4, 0.6, 0.8, 1, 0]),
                         "a_constant": .constant([0.1, 0.7]),
                         "a_count": .init(components: 1, values: [1, 2, 4])],
            count: 3)
        list.append(Sample(name: "attributes", frame: canvas(32, 32, [attributes])))
        let uniformsFragment = """
            precision mediump float;
            struct Light { vec3 color; float power; };
            uniform Light u_lights[2];
            uniform vec3 u_colors[4];
            uniform int u_which;
            uniform bool u_on;
            uniform bvec2 u_flags;
            uniform mat2 u_m;
            uniform mat4 u_big;
            uniform ivec3 u_steps;
            void main() {
                int i = int(gl_FragCoord.x / 8.0);
                vec3 c = u_colors[0];
                if (i == 1) c = u_colors[1];
                if (i == 2) c = u_colors[2];
                if (i == 3) c = u_colors[3];
                Light light = u_which == 1 ? u_lights[1] : u_lights[0];
                vec4 big = u_big * vec4(c, 1.0);
                float m = u_m[1][0];
                gl_FragColor = vec4(mix(c, light.color * light.power, gl_FragCoord.y / 8.0) + big.xyz * 0.1,
                                    u_on && u_flags.y && !u_flags.x ? m + float(u_steps.y) * 0.1 : 0.0);
            }
            """
        list.append(Sample(name: "uniforms", frame: frame(32, 8, uniformsFragment, uniforms: [
            "u_lights[0].color": [1, 0, 0], "u_lights[0].power": [1], "u_lights[1].color": [0, 1, 0.5], "u_lights[1].power": [0.5],
            "u_colors": [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0], "u_colors[2]": [1, 0, 1], "u_which": [1], "u_on": [1], "u_flags": [0, 1],
            "u_m": [0, 0, 0.5, 0], "u_big": [1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0.1, 0.2, 0.3, 1], "u_steps": [1, 3, 5],
        ])))
        let block = ShaderDraw(vertex: """
            #version 300 es
            in vec2 a_position;
            out vec2 v_uv;
            void main() { v_uv = a_position * 0.5 + 0.5; gl_Position = vec4(a_position, 0.0, 1.0); }
            """, fragment: """
            #version 300 es
            precision highp float;
            uniform Look { vec4 tint; float strength; vec2 offset; } look;
            uniform Plain { vec3 base; };
            in vec2 v_uv;
            out vec4 color;
            void main() { color = vec4(mix(base, look.tint.rgb, v_uv.x * look.strength) + vec3(look.offset, 0.0) * v_uv.y, 1.0); }
            """, uniforms: ["Look.tint": [0.9, 0.2, 0.1, 1], "Look.strength": [0.8], "Look.offset": [0.1, 0.3], "base": [0.1, 0.2, 0.7]],
            attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        list.append(Sample(name: "webgl2-uniform-blocks", frame: canvas(32, 16, [block])))

        // Shaders as sites write them, whole and in tiles.
        list.append(Sample(name: "gradient-mesh", frame: RealWorldTests.meshFrame(time: 0.4), scale: 0.25,
                           tolerance: Tolerance(largest: 8, mean: 0.3, beyond: 0.01,
                                                why: "simplex noise in the vertex stage, interpolated across 2,400 triangles")))
        list.append(Sample(name: "gradient-mesh-tile-twice", frame: RealWorldTests.meshFrame(time: 0.4), scale: 2,
                           region: CGRect(x: 600, y: 300, width: 120, height: 80),
                           tolerance: Tolerance(largest: 8, mean: 0.3, beyond: 0.01,
                                                why: "simplex noise in the vertex stage, interpolated across 2,400 triangles")))
        list.append(Sample(name: "film-grain", frame: frame(160, 90, RealWorldTests.grain, uniforms: ["u_time": [3.5]]),
                           tolerance: Tolerance(largest: 32, mean: 0.05, beyond: 0.0005,
                                                why: "a hash of gl_FragCoord through fract: the last bit of a float turns a grain")))
        list.append(Sample(name: "film-grain-tile-twice", frame: frame(160, 90, RealWorldTests.grain, uniforms: ["u_time": [3.5]], antialias: true),
                           scale: 2, region: CGRect(x: 40, y: 20, width: 48, height: 32)))
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let plane = RealWorldTests.plane(1, 1)
        let three = ShaderDraw(vertex: RealWorldTests.threeVertex, fragment: RealWorldTests.threeFragment,
                               uniforms: ["projectionMatrix": identity, "modelViewMatrix": identity, "uTime": [0.5],
                                          "uColorA": [0.1, 0.2, 0.8], "uColorB": [1, 0.6, 0.2]],
                               attributes: ["position": .init(components: 3, values: plane.positions),
                                            "uv": .init(components: 2, values: plane.uvs)],
                               indices: plane.indices, count: plane.indices.count)
        list.append(Sample(name: "threejs-material", frame: canvas(64, 36, [three], antialias: true)))
        let toy = frame(320, 180, RealWorldTests.shadertoy, uniforms: ["iResolution": [320, 180, 1], "iTime": [1.5]])
        list.append(Sample(name: "shadertoy", frame: toy))
        list.append(Sample(name: "shadertoy-tile-three-times", frame: toy, scale: 3, region: CGRect(x: 130, y: 60, width: 40, height: 30)))
        return list + passes
    }

    /// Passes into textures and WebGL's tests and masks.
    static var passes: [Sample] {
        var list: [Sample] = []
        // A picture drawn small into a texture, blurred across into a second and down onto the canvas.
        let blur = """
            precision highp float;
            uniform sampler2D u_from;
            uniform vec2 u_resolution;
            uniform vec2 u_step;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                vec4 sum = texture2D(u_from, uv) * 0.4;
                sum += (texture2D(u_from, uv + u_step) + texture2D(u_from, uv - u_step)) * 0.2;
                sum += (texture2D(u_from, uv + u_step * 2.0) + texture2D(u_from, uv - u_step * 2.0)) * 0.1;
                gl_FragColor = sum;
            }
            """
        func chain(scales: Bool) -> ShaderFrame {
            var first = ShaderDraw.fullSurface(fragment: sampling, uniforms: ["u_resolution": [48, 36], "u_repeat": [1.6, 1.6]],
                                               textures: ["u_image": photo])
            first.sampling["u_image"] = .init(wrapS: .repeat, wrapT: .mirroredRepeat)
            var across = ShaderDraw.fullSurface(fragment: blur, uniforms: ["u_resolution": [48, 36], "u_step": [1.5 / 48, 0]])
            across.targets["u_from"] = 0
            var down = ShaderDraw.fullSurface(fragment: blur, uniforms: ["u_resolution": [48, 36], "u_step": [0, 1.5 / 36]])
            down.targets["u_from"] = 1
            var frame = ShaderFrame(size: CGSize(width: 48, height: 36), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 48, height: 36, scales: scales), ShaderTarget(width: 48, height: 36, scales: scales)]
            frame.passes = [ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [first]),
                            ShaderPass(colors: [1], clearColor: [0, 0, 0, 0], draws: [across]),
                            ShaderPass(clearColor: [0, 0, 0, 0], draws: [down])]
            return frame
        }
        list.append(Sample(name: "target-blur-chain", frame: chain(scales: true)))
        list.append(Sample(name: "target-blur-chain-tile-three-times", frame: chain(scales: true), scale: 3,
                           region: CGRect(x: 10, y: 8, width: 20, height: 16)))
        list.append(Sample(name: "target-blur-chain-its-own-size-twice", frame: chain(scales: false), scale: 2))

        // A triangle, a point and a derivative in a texture: the right way up, the right way round.
        let facing = """
            #extension GL_OES_standard_derivatives : enable
            precision mediump float;
            void main() { gl_FragColor = vec4(gl_FrontFacing ? 1.0 : 0.2, dFdy(gl_FragCoord.y) > 0.0 ? 1.0 : 0.2, gl_FragCoord.y / 24.0, 1.0); }
            """
        var triangle = shape([-0.9, -0.9, 0.9, -0.9, -0.9, 0.9], fragment: facing)
        triangle.cull = .back
        var spot = ShaderDraw(vertex: pointVertex, fragment: pointFragment,
                              attributes: ["a_position": .init(components: 2, values: [0.45, 0.45, -0.5, 0.75]),
                                           "a_size": .init(components: 1, values: [9, 6])], mode: .points, count: 2)
        spot.viewport = nil
        var shown = TargetsTests.showing(0, 24, 24, nearest: true)
        shown.blend = .premultipliedOver
        var turned = ShaderFrame(size: CGSize(width: 24, height: 24), draws: [], antialias: false)
        turned.targets = [ShaderTarget(width: 24, height: 24)]
        turned.passes = [ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [triangle, spot]),
                         ShaderPass(clearColor: [0.1, 0.1, 0.3, 1], draws: [shown])]
        list.append(Sample(name: "target-the-right-way-up", frame: turned))

        // Feedback: the fifth step of two textures drawn into in turn, and of one blended onto.
        list.append(Sample(name: "target-feedback", frame: TargetsTests.pingPong(step: 5, recording: 9001),
                           earlier: { TargetsTests.pingPong(step: $0, recording: 9001) }))

        // Several outputs, a float target read beyond 1, smaller copies of a target.
        let outputs = """
            #extension GL_EXT_draw_buffers : require
            precision mediump float;
            uniform vec2 u_resolution;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                gl_FragData[0] = vec4(uv, 0.0, 1.0);
                gl_FragData[1] = vec4(4.0 * uv.y, 8.0 * uv.x, 2.0, 1.0);
            }
            """
        var left = TargetsTests.showing(0, 32, 16), right = ShaderDraw.fullSurface(fragment: """
            precision highp float;
            uniform sampler2D u_from;
            uniform vec2 u_resolution;
            void main() { gl_FragColor = vec4(texture2D(u_from, gl_FragCoord.xy / u_resolution).rgb / 8.0, 1.0); }
            """, uniforms: ["u_resolution": [32, 16]])
        right.targets["u_from"] = 1
        left.viewport = CGRect(x: 0, y: 0, width: 16, height: 16)
        left.uniforms["u_resolution"] = [16, 16]
        right.viewport = CGRect(x: 16, y: 0, width: 16, height: 16)
        var several = ShaderFrame(size: CGSize(width: 32, height: 16), draws: [], antialias: false)
        several.targets = [ShaderTarget(width: 16, height: 16), ShaderTarget(width: 16, height: 16, format: .rgba16Float)]
        several.passes = [ShaderPass(colors: [0, 1], clearColor: [0, 0, 0, 0],
                                     draws: [ShaderDraw.fullSurface(fragment: outputs, uniforms: ["u_resolution": [16, 16]])]),
                          ShaderPass(clearColor: [0, 0, 0, 0], draws: [left, right])]
        list.append(Sample(name: "target-several-outputs-and-floats", frame: several))

        let board = "precision mediump float; void main() { gl_FragColor = vec4(vec3(mod(floor(gl_FragCoord.x / 2.0) + floor(gl_FragCoord.y / 2.0), 2.0)), 1.0); }"
        var far = TargetsTests.showing(0, 16, 16)
        far.sampling["u_from"] = .init(minify: .linear, mipmap: .linear)
        var copies = ShaderFrame(size: CGSize(width: 16, height: 16), draws: [], antialias: false)
        copies.targets = [ShaderTarget(width: 64, height: 64, mipmapped: true)]
        copies.passes = [ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [ShaderDraw.fullSurface(fragment: board)], mipmaps: [0]),
                         ShaderPass(clearColor: [0, 0, 0, 0], draws: [far])]
        list.append(Sample(name: "target-smaller-copies", frame: copies))

        // Depth: two walls that cross, tested, in a tile and with four samples a pixel.
        let slanted = "attribute vec3 a_position; varying float v_z; void main() { v_z = a_position.z; gl_Position = vec4(a_position, 1.0); }"
        func wall(_ z0: Float, _ z1: Float, _ color: String) -> ShaderDraw {
            var draw = ShaderDraw(vertex: slanted,
                                  fragment: "precision mediump float; varying float v_z; void main() { gl_FragColor = vec4(\(color), 1.0) * (0.6 + 0.4 * v_z); }",
                                  attributes: ["a_position": .init(components: 3, values: [-0.9, -0.8, z0, 0.9, -0.8, z1, -0.9, 0.8, z0,
                                                                                           -0.9, 0.8, z0, 0.9, -0.8, z1, 0.9, 0.8, z1])],
                                  count: 6)
            draw.depth = .init()
            return draw
        }
        var offset = wall(-0.1, -0.1, "0.2, 0.9, 0.3")
        offset.viewport = CGRect(x: 8, y: 4, width: 16, height: 10)
        offset.depth = .init(compare: .lessEqual, writes: false)
        offset.offset = .init(factor: -1, units: -2)
        let crossing = [wall(-0.6, 0.8, "1.0, 0.3, 0.2"), wall(0.7, -0.5, "0.2, 0.4, 1.0"), offset]
        var deep = canvas(40, 24, [], antialias: false)
        deep.passes = [ShaderPass(clearColor: [0, 0, 0, 0], clearDepth: 1, draws: crossing)]
        list.append(Sample(name: "depth-test", frame: deep))
        var deepSmooth = deep
        deepSmooth.antialias = true
        list.append(Sample(name: "depth-test-antialiased-tile-twice", frame: deepSmooth, scale: 2, region: CGRect(x: 12, y: 4, width: 20, height: 16)))
        var deepTarget = ShaderFrame(size: CGSize(width: 40, height: 24), draws: [], antialias: false)
        deepTarget.targets = [ShaderTarget(width: 40, height: 24, scales: true)]
        deepTarget.passes = [ShaderPass(colors: [0], depth: 0, clearColor: [0, 0, 0, 0], clearDepth: 1, draws: crossing),
                             ShaderPass(clearColor: [0, 0, 0, 0], draws: [TargetsTests.showing(0, 40, 24, nearest: true)])]
        list.append(Sample(name: "depth-test-in-a-target", frame: deepTarget))

        // The stencil: a triangle written into it, a gradient drawn where it is and where it is not.
        var mask = shape([-0.8, -0.8, 0.8, -0.6, 0.0, 0.9])
        mask.channels = []
        mask.stencil = .init(front: .init(compare: .always, reference: 1, pass: .replace), back: .init(compare: .always, reference: 1, pass: .replace))
        var inside = ShaderDraw.fullSurface(fragment: ConventionsTests.gradient, uniforms: ["u_resolution": [32, 32]])
        inside.stencil = .init(front: .init(compare: .equal, reference: 1), back: .init(compare: .equal, reference: 1))
        var outside = ShaderDraw.fullSurface(fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.1, 0.1, 0.4, 0.5); }")
        outside.stencil = .init(front: .init(compare: .notEqual, reference: 1), back: .init(compare: .notEqual, reference: 1))
        var cut = canvas(32, 32, [], antialias: false)
        cut.passes = [ShaderPass(clearColor: [0, 0, 0, 0], clearStencil: 0, draws: [mask, inside, outside])]
        list.append(Sample(name: "stencil", frame: cut))
        list.append(Sample(name: "stencil-tile-twice", frame: cut, scale: 2, region: CGRect(x: 8, y: 8, width: 16, height: 16)))

        // Faces left out, colorMask and the scissor box.
        var kept = shape([-0.9, -0.9, -0.1, -0.9, -0.9, 0.9, 0.9, -0.9, 0.1, -0.9, 0.9, 0.9],
                         fragment: "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.8, 0.4, 1.0); }")
        kept.cull = .back
        var band = ShaderDraw.fullSurface(fragment: white)
        band.channels = [.green, .alpha]
        band.scissor = CGRect(x: 4, y: 6, width: 20, height: 5)
        list.append(Sample(name: "cull-mask-scissor", frame: canvas(32, 24, [kept, band])))
        list.append(Sample(name: "cull-mask-scissor-tile-uneven", frame: canvas(32, 24, [kept, band]), scale: 2.5,
                           region: CGRect(x: 2, y: 10, width: 16, height: 12)))

        // Instances: a small square drawn nine times, each with its own place and colour.
        var places: [Float] = [], colours: [Float] = []
        for i in 0..<9 {
            places += [Float(i % 3) * 0.6 - 0.6, Float(i / 3) * 0.6 - 0.6]
            colours += [Float(i % 3) / 2, Float(i / 3) / 2, 1 - Float(i) / 8]
        }
        var squares = ShaderDraw(vertex: """
            attribute vec2 a_position;
            attribute vec2 a_offset;
            attribute vec3 a_color;
            varying vec3 v_color;
            void main() { v_color = a_color; gl_Position = vec4(a_position * 0.22 + a_offset, 0.0, 1.0); }
            """, fragment: "precision mediump float; varying vec3 v_color; void main() { gl_FragColor = vec4(v_color, 1.0); }",
            attributes: ["a_position": ShaderDraw.fullSurfacePositions,
                         "a_offset": .init(components: 2, values: places, divisor: 1),
                         "a_color": .init(components: 3, values: colours, divisor: 1)], count: 6)
        squares.instances = 9
        list.append(Sample(name: "instances", frame: canvas(36, 36, [squares], antialias: true)))

        // Textures of numbers: floats beyond 1, and LUMINANCE with ALPHA.
        var numbers: [Float] = []
        for y in 0..<4 { for x in 0..<4 { numbers += [Float(x) * 1.5, Float(y) * 1.5, Float(x * y) / 2, 1] } }
        let floats = ShaderData(width: 4, height: 4, format: .rgba32Float, bytes: numbers.withUnsafeBytes { Array($0) })!
        var reads = ShaderDraw.fullSurface(fragment: """
            precision highp float;
            uniform sampler2D u_data;
            uniform sampler2D u_grey;
            uniform vec2 u_resolution;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                gl_FragColor = vec4(texture2D(u_data, uv).rgb / 4.5, 1.0) * texture2D(u_grey, uv);
            }
            """, uniforms: ["u_resolution": [32, 32]])
        reads.data["u_data"] = floats
        reads.data["u_grey"] = ShaderData(width: 2, height: 2, format: .luminanceAlpha8, bytes: [255, 255, 128, 255, 255, 128, 64, 255])!
        reads.sampling["u_data"] = .init(magnify: .nearest, minify: .nearest)
        list.append(Sample(name: "textures-of-numbers", frame: canvas(32, 32, [reads])))

        // The canvas drawn onto in two passes, the second without a clear, and a picture read as sRGB.
        var linear = ShaderDraw.fullSurface(fragment: sampling, uniforms: ["u_resolution": [32, 24], "u_repeat": [1, 1]], textures: ["u_image": photo])
        linear.decodes = ["u_image"]
        linear.viewport = CGRect(x: 0, y: 0, width: 16, height: 24)
        var over = shape([0, -0.5, 0.9, -0.5, 0.45, 0.8], fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.5, 0.0, 0.5, 0.5); }",
                         blend: .premultipliedOver)
        over.viewport = nil
        var twice = canvas(32, 24, [], antialias: true)
        twice.passes = [ShaderPass(clearColor: [0.9, 0.9, 0.8, 1], draws: [linear]), ShaderPass(draws: [over])]
        list.append(Sample(name: "canvas-passes-and-srgb", frame: twice))
        return list
    }
}
