#if !os(Windows)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import Shaders

/// Passes into textures that later draws read: within a frame (blur chains, post-processing),
/// from the frame before (feedback, ping-pong), at any size and in tiles.
@Suite(.enabled(if: drawsPasses)) struct TargetsTests {
    static let quad = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"

    /// Shows a target over the whole canvas, its t = 0 at the canvas's bottom as WebGL reads it.
    static let show = """
        precision highp float;
        uniform sampler2D u_from;
        uniform vec2 u_resolution;
        void main() { gl_FragColor = texture2D(u_from, gl_FragCoord.xy / u_resolution); }
        """

    static func showing(_ target: Int, _ width: Int, _ height: Int, nearest: Bool = false) -> ShaderDraw {
        var draw = ShaderDraw.fullSurface(fragment: show, uniforms: ["u_resolution": [Float(width), Float(height)]])
        draw.targets["u_from"] = target
        if nearest { draw.sampling["u_from"] = .init(magnify: .nearest, minify: .nearest) }
        return draw
    }

    static func into(_ target: Int, _ fragment: String, uniforms: [String: [Float]] = [:], reads: [String: Int] = [:],
                     clear: [Float]? = [0, 0, 0, 0]) -> ShaderPass {
        var draw = ShaderDraw.fullSurface(fragment: fragment, uniforms: uniforms)
        draw.targets = reads
        for name in reads.keys { draw.sampling[name] = .init(magnify: .nearest, minify: .nearest) }
        return ShaderPass(colors: [target], clearColor: clear, draws: [draw])
    }

    @Test func aPassIntoATextureIsReadTheRightWayUp() throws {
        // Red grows to the right and green upwards in the target, as gl_FragCoord runs; read back
        // by its texture coordinates it shows the same on the canvas as drawn there directly.
        var frame = ShaderFrame(size: CGSize(width: 64, height: 32), draws: [])
        frame.targets = [ShaderTarget(width: 64, height: 32)]
        frame.passes = [
            Self.into(0, ConventionsTests.gradient, uniforms: ["u_resolution": [64, 32]]),
            ShaderPass(clearColor: [0, 0, 0, 0], draws: [Self.showing(0, 64, 32, nearest: true)]),
        ]
        let pixels = try draw(frame)
        let direct = try draw(Support.frame(64, 32, ConventionsTests.gradient))
        #expect(pixels.bytes == direct.bytes)
        #expect(near(pixels[0, 31], [1, 4, 0, 255]))     // bottom left: black
        #expect(near(pixels[63, 0], [253, 251, 0, 255])) // top right: red and green
    }

    @Test func whatFacesFrontAndRunsUpDoesSoInATargetToo() throws {
        // A counter-clockwise triangle faces the front, dFdy of gl_FragCoord.y is positive, and a
        // point's coordinate starts at its top, also where the page drew into a texture.
        let facing = """
            #extension GL_OES_standard_derivatives : enable
            precision mediump float;
            void main() { gl_FragColor = vec4(gl_FrontFacing ? 1.0 : 0.0, dFdy(gl_FragCoord.y) > 0.0 ? 1.0 : 0.0, 0.0, 1.0); }
            """
        let triangle = ShaderDraw(vertex: Self.quad, fragment: facing,
                                  attributes: ["a_position": .init(components: 2, values: [-1, -1, 1, -1, -1, 1])], count: 3)
        let point = ShaderDraw(vertex: "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); gl_PointSize = 8.0; }",
                               fragment: "precision mediump float; void main() { gl_FragColor = vec4(gl_PointCoord, 1.0, 1.0); }",
                               attributes: ["a_position": .init(components: 2, values: [0.5, 0.5])], mode: .points, count: 1)
        var frame = ShaderFrame(size: CGSize(width: 16, height: 16), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 16, height: 16)]
        frame.passes = [ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [triangle, point]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [Self.showing(0, 16, 16, nearest: true)])]
        let pixels = try draw(frame)
        #expect(pixels[2, 13] == [255, 255, 0, 255])                  // the triangle's corner, bottom left
        // The point's centre is at 12, 4 from the top left, eight pixels across.
        #expect(near(pixels[8, 0], [16, 16, 255, 255], within: 2))    // its top left
        #expect(near(pixels[15, 7], [239, 239, 255, 255], within: 2)) // its bottom right
    }

    @Test func aBlurChainStaysSharpAtAnySize() throws {
        // A hard edge drawn into a texture the size of the canvas, shown on the canvas: looked at
        // four times as near, the texture is drawn four times as large, and the edge is as hard.
        let edge = """
            precision highp float;
            uniform vec2 u_resolution;
            void main() { gl_FragColor = vec4(vec3(step(0.5, gl_FragCoord.x / u_resolution.x + gl_FragCoord.y / u_resolution.y * 0.2)), 1.0); }
            """
        func frame(scales: Bool) -> ShaderFrame {
            var frame = ShaderFrame(size: CGSize(width: 32, height: 32), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 32, height: 32, scales: scales)]
            frame.passes = [Self.into(0, edge, uniforms: ["u_resolution": [32, 32]]),
                            ShaderPass(clearColor: [0, 0, 0, 0], draws: [Self.showing(0, 32, 32)])]
            return frame
        }
        let region = CGRect(x: 8, y: 8, width: 16, height: 16)
        let direct = try draw(Support.frame(32, 32, edge), scale: 4, region: region)
        let sharp = try draw(frame(scales: true), scale: 4, region: region)
        let soft = try draw(frame(scales: false), scale: 4, region: region)
        func grays(_ pixels: Pixels) -> Int {
            stride(from: 0, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] > 8 && pixels.bytes[$0] < 247 }.count
        }
        #expect(grays(direct) == 0)
        #expect(grays(sharp) == 0)
        #expect(grays(soft) > 100)
        var apart = 0
        for i in stride(from: 0, to: direct.bytes.count, by: 4) where direct.bytes[i] != sharp.bytes[i] { apart += 1 }
        #expect(apart == 0)
    }

    /// Two targets that keep, drawn into in turn, each step adding to what the other holds: red
    /// counts the steps, green is the step's own input.
    static func pingPong(step: Int, input: Float = 0.25, recording: Int = 7) -> ShaderFrame {
        let add = """
            precision highp float;
            uniform sampler2D u_before;
            uniform vec2 u_resolution;
            uniform float u_input;
            void main() {
                vec4 before = texture2D(u_before, gl_FragCoord.xy / u_resolution);
                gl_FragColor = vec4(before.r + 1.0 / 16.0, u_input, before.b, 1.0);
            }
            """
        let from = step % 2, to = 1 - from
        // Blue is where it started: one corner of the state, its first texel, at the bottom left.
        var start = [UInt8](repeating: 0, count: 4 * 4 * 4)
        start[2] = 255
        start[3] = 255
        let contents = ShaderData(width: 4, height: 4, format: .rgba8, bytes: start)!
        var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 4, height: 4, keeps: true, contents: contents),
                         ShaderTarget(width: 4, height: 4, keeps: true)]
        frame.passes = [Self.into(to, add, uniforms: ["u_resolution": [4, 4], "u_input": [input]], reads: ["u_before": from]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [Self.showing(to, 8, 8, nearest: true)])]
        frame.identity = .init(recording: recording, moment: step)
        return frame
    }

    @Test func aFrameBuildsOnTheFramesBefore() throws {
        func red(_ step: Int, recording: Int) throws -> (Int, [Int]) {
            let frame = Self.pingPong(step: step, recording: recording)
            let image = try renderer.image(of: frame, pixels: CGSize(width: 8, height: 8)) { Self.pingPong(step: $0, recording: recording) }
            let pixels = Pixels(image)
            return (pixels[5, 2][0], pixels[0, 7])
        }
        // Step n has added n + 1 sixteenths; the corner that started blue is still blue.
        #expect(try red(0, recording: 71).0 == 16)
        #expect(try red(0, recording: 71).1[2] == 255)
        #expect(try red(1, recording: 71).0 == 32)
        #expect(try red(2, recording: 71).0 == 48)
        // Asked for out of the blue, a step is drawn from the steps before it; gone back to, it
        // is the same again, and so is one from a recording never drawn before.
        #expect(try red(9, recording: 71).0 == 160)
        #expect(try red(3, recording: 71).0 == 64)
        #expect(try red(9, recording: 72).0 == 160)
        #expect(try red(9, recording: 72).1[2] == 255)
        // Far on, past the steps that are kept on the way.
        #expect(try red(Feedback.stride * 2 + 5, recording: 73).0 == 255)
        #expect(try red(Feedback.stride + 3, recording: 73).0 == 255)
        #expect(try red(5, recording: 73).0 == 96)
    }

    @Test func aTargetThatIsDrawnOverKeepsWhatWasThere() throws {
        // One target that keeps, each step adding a little over what it holds, by blending.
        func frame(_ step: Int) -> ShaderFrame {
            var more = ShaderDraw.fullSurface(fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.125, 0.0, 0.0, 0.0); }",
                                              blend: ShaderDraw.Blend(source: .one, destination: .one))
            more.viewport = CGRect(x: 0, y: 0, width: 2, height: 4)
            var frame = ShaderFrame(size: CGSize(width: 4, height: 4), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 4, height: 4, format: .rgba16Float, keeps: true)]
            frame.passes = [ShaderPass(colors: [0], draws: [more]),
                            ShaderPass(clearColor: [0, 0, 0, 1], draws: [Self.showing(0, 4, 4, nearest: true)])]
            frame.identity = .init(recording: 91, moment: step)
            return frame
        }
        for step in [0, 1, 4, 2] {
            let pixels = Pixels(try renderer.image(of: frame(step), pixels: CGSize(width: 4, height: 4), earlier: frame))
            #expect(abs(pixels[0, 1][0] - Int((0.125 * Float(step + 1) * 255).rounded())) <= 1, "step \(step): \(pixels[0, 1])")
            #expect(pixels[3, 1][0] == 0)
        }
    }

    @Test func theTilesOfOneFrameDrawItsPassesOnce() throws {
        // A noisy pass into a texture, shown on the canvas: sixteen tiles drawn at once are the whole.
        var frame = ShaderFrame(size: CGSize(width: 64, height: 64), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 64, height: 64, scales: true)]
        frame.passes = [Self.into(0, RealWorldTests.grain, uniforms: ["u_time": [1.5], "u_resolution": [64, 64]]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [Self.showing(0, 64, 64)])]
        frame.identity = .init(recording: 5, moment: 0)
        let whole = try draw(frame, scale: 2)
        let tiles = UncheckedBox([Pixels?](repeating: nil, count: 16))
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            let region = CGRect(x: (i % 4) * 16, y: (i / 4) * 16, width: 16, height: 16)
            let tile = try? draw(frame, scale: 2, region: region)
            tiles.lock.withLock { tiles.value[i] = tile }
        }
        for i in 0..<16 {
            let tile = try #require(tiles.value[i])
            for y in 0..<32 {
                for x in 0..<32 {
                    let expected = whole[(i % 4) * 32 + x, (i / 4) * 32 + y]
                    guard tile[x, y] == expected else {
                        Issue.record("tile \(i) at \(x), \(y): \(tile[x, y]) for \(expected)")
                        return
                    }
                }
            }
        }
    }

    @Test func aTargetIsReadAsItWasWhenThePageDrewOntoTheCanvas() throws {
        // As filters do: the same texture is drawn into twice, and shown on the canvas after
        // each; the left half shows the first, the right half the second.
        let color = "precision mediump float; uniform vec3 u_color; void main() { gl_FragColor = vec4(u_color, 1.0); }"
        var left = Self.showing(0, 8, 8, nearest: true), right = Self.showing(0, 8, 8, nearest: true)
        left.viewport = CGRect(x: 0, y: 0, width: 4, height: 8)
        right.viewport = CGRect(x: 4, y: 0, width: 4, height: 8)
        var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 8, height: 8)]
        frame.passes = [Self.into(0, color, uniforms: ["u_color": [1, 0, 0]]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [left]),
                        Self.into(0, color, uniforms: ["u_color": [0, 0, 1]], clear: nil),
                        ShaderPass(draws: [right])]
        let pixels = try draw(frame)
        #expect(pixels[1, 4] == [255, 0, 0, 255])
        #expect(pixels[6, 4] == [0, 0, 255, 255])
    }

    @Test func smallerCopiesAreMadeOfATarget() throws {
        // A fine checkerboard drawn into a texture, its smaller copies made, read far off: grey.
        let board = "precision mediump float; void main() { gl_FragColor = vec4(vec3(mod(floor(gl_FragCoord.x) + floor(gl_FragCoord.y), 2.0)), 1.0); }"
        func frame(mipmapped: Bool) -> ShaderFrame {
            var show = Self.showing(0, 4, 4)
            show.sampling["u_from"] = .init(minify: .linear, mipmap: mipmapped ? .linear : nil)
            var pass = Self.into(0, board)
            if mipmapped { pass.mipmaps = [0] }
            var frame = ShaderFrame(size: CGSize(width: 4, height: 4), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 64, height: 64, mipmapped: mipmapped)]
            frame.passes = [pass, ShaderPass(clearColor: [0, 0, 0, 0], draws: [show])]
            return frame
        }
        let grey = try draw(frame(mipmapped: true))
        #expect(near(grey[1, 1], [128, 128, 128, 255], within: 2))
        #expect(near(grey[2, 3], [128, 128, 128, 255], within: 2))
    }

    @Test func aPassDrawsIntoSeveralTargetsAtOnce() throws {
        let both = """
            #extension GL_EXT_draw_buffers : require
            precision mediump float;
            void main() { gl_FragData[0] = vec4(1.0, 0.0, 0.0, 1.0); gl_FragData[1] = vec4(0.0, 0.5, 1.0, 1.0); }
            """
        var left = Self.showing(0, 8, 8, nearest: true), right = Self.showing(1, 8, 8, nearest: true)
        left.viewport = CGRect(x: 0, y: 0, width: 4, height: 8)
        right.viewport = CGRect(x: 4, y: 0, width: 4, height: 8)
        var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 8, height: 8), ShaderTarget(width: 8, height: 8, format: .rgba16Float)]
        frame.passes = [ShaderPass(colors: [0, 1], clearColor: [0, 0, 0, 0], draws: [ShaderDraw.fullSurface(fragment: both)]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [left, right])]
        let pixels = try draw(frame)
        #expect(pixels[1, 4] == [255, 0, 0, 255])
        #expect(near(pixels[6, 4], [0, 128, 255, 255], within: 1))
        // WebGL 2's own outputs.
        var two = ShaderDraw(vertex: "#version 300 es\nin vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }",
                             fragment: """
                                #version 300 es
                                precision mediump float;
                                layout(location = 0) out vec4 first;
                                layout(location = 1) out vec4 second;
                                void main() { first = vec4(0.0, 1.0, 0.0, 1.0); second = vec4(1.0, 1.0, 0.0, 1.0); }
                                """, attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        two.viewport = nil
        frame.passes[0].draws = [two]
        let again = try draw(frame)
        #expect(again[1, 4] == [0, 255, 0, 255])
        #expect(again[6, 4] == [255, 255, 0, 255])
    }

    @Test func numbersBeyondOneStayInAFloatTarget() throws {
        // A particle simulation's kind of texture: what is written is read back as it was.
        let write = "precision highp float; void main() { gl_FragColor = vec4(3.5, -2.0, 1000.0, 0.25); }"
        let read = """
            precision highp float;
            uniform sampler2D u_from;
            void main() { vec4 v = texture2D(u_from, vec2(0.5)); gl_FragColor = vec4(v.r / 7.0, -v.g / 4.0, v.b / 2000.0, v.a * 2.0); }
            """
        for format in [ShaderData.Format.rgba16Float, .rgba32Float] {
            var show = ShaderDraw.fullSurface(fragment: read)
            show.targets["u_from"] = 0
            var frame = ShaderFrame(size: CGSize(width: 2, height: 2), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 2, height: 2, format: format)]
            frame.passes = [Self.into(0, write), ShaderPass(clearColor: [0, 0, 0, 0], draws: [show])]
            #expect(near(try draw(frame)[0, 0], [128, 128, 128, 128], within: 1))
        }
        // An RGB target's alpha reads 1 whatever is drawn.
        var show = ShaderDraw.fullSurface(fragment: "precision highp float; uniform sampler2D u_from; void main() { gl_FragColor = texture2D(u_from, vec2(0.5)); }")
        show.targets["u_from"] = 0
        var frame = ShaderFrame(size: CGSize(width: 2, height: 2), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 2, height: 2, opaque: true)]
        frame.passes = [Self.into(0, "precision highp float; void main() { gl_FragColor = vec4(0.5, 0.25, 1.0, 0.25); }", clear: nil),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [show])]
        #expect(near(try draw(frame)[0, 0], [128, 64, 255, 255], within: 1))
    }

    @Test func whatAFrameNamesMustBeThere() throws {
        var frame = ShaderFrame(size: CGSize(width: 4, height: 4), draws: [], antialias: false)
        frame.passes = [ShaderPass(colors: [2], draws: [])]
        #expect(throws: ShaderError.self) { try renderer.check(frame) }
        #expect(throws: ShaderError.self) { try draw(frame) }
    }

    @Test func halfFloatsRoundTrip() {
        for value: Float in [0, 1, -1, 0.5, 3.5, 1000, 65504, 6.1035156e-05, 5.9604645e-08, -0.33325195] {
            #expect(Half.float(Half.bits(value)) == value, "\(value)")
        }
        #expect(Half.bits(1) == 0x3C00 && Half.bits(-2) == 0xC000 && Half.bits(.infinity) == 0x7C00)
        #expect(Half.float(Half.bits(1e9)).isInfinite && Half.float(Half.bits(.nan)).isNaN)
        #expect(Half.bits(1e-10) == 0)
    }
}

/// A value several threads fill under its lock.
final class UncheckedBox<Value>: @unchecked Sendable {
    let lock = NSLock()
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// `frame` from Support, under a name the suites' own methods do not hide.
enum Support {
    static func frame(_ width: Int, _ height: Int, _ fragment: String, uniforms: [String: [Float]] = [:],
                      antialias: Bool = false) -> ShaderFrame {
        ShadersTests.frame(width, height, fragment, uniforms: uniforms, antialias: antialias)
    }
}
