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
        for sample in Self.samples {
            let pixels = try draw(sample.frame, scale: sample.scale, region: sample.region)
            try PNG.data(pixels).write(to: folder.appendingPathComponent(sample.name + ".png"))
        }
    }

    @Test(.enabled(if: environment["SHADERS_REFERENCES"] != nil))
    func agreesWithTheReferences() throws {
        let references = URL(fileURLWithPath: Self.environment["SHADERS_REFERENCES"]!, isDirectory: true)
        let out = URL(fileURLWithPath: Self.environment["SHADERS_COMPARED"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = ["sample\tsize\tlargest\tmean\tbeyond 2\tbeyond 8\tallowed"]
        for sample in Self.samples {
            let data = try Data(contentsOf: references.appendingPathComponent(sample.name + ".png"))
            let reference = try #require(PNG.pixels(data), "\(sample.name): the reference does not read")
            let drawn = try draw(sample.frame, scale: sample.scale, region: sample.region)
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
        return list
    }
}
