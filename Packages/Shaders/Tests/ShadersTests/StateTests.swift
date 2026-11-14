#if !os(Windows)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import Shaders

/// WebGL's tests and masks: depth, stencil, faces left out, colorMask, the scissor box,
/// polygonOffset, instances, textures of numbers, and a canvas drawn onto in several passes.
@Suite(.enabled(if: drawsPasses)) struct StateTests {
    static let vertex = "attribute vec3 a_position; void main() { gl_Position = vec4(a_position, 1.0); }"

    static func flat(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> String {
        "precision mediump float; void main() { gl_FragColor = vec4(\(r), \(g), \(b), \(a)); }"
    }

    /// A rectangle from x0 to x1 across clip space and all of its height, at depth z.
    static func wall(_ x0: Float, _ x1: Float, z: Float, _ fragment: String) -> ShaderDraw {
        ShaderDraw(vertex: vertex, fragment: fragment,
                   attributes: ["a_position": .init(components: 3, values: [x0, -1, z, x1, -1, z, x0, 1, z, x0, 1, z, x1, -1, z, x1, 1, z])],
                   count: 6)
    }

    static func canvas(_ draws: [ShaderDraw], size: Int = 8, antialias: Bool = false) -> ShaderFrame {
        ShaderFrame(size: CGSize(width: size, height: size), draws: draws, antialias: antialias)
    }

    static let red = [255, 0, 0, 255], green = [0, 255, 0, 255], blue = [0, 0, 255, 255], nothing = [0, 0, 0, 0]

    @Test func whatIsNearerCoversWhatIsFurther() throws {
        // The near wall first, the far one after: with the depth test the near one stays.
        var near = Self.wall(-1, 0.5, z: -0.5, Self.flat(1, 0, 0)), far = Self.wall(-1, 1, z: 0.5, Self.flat(0, 0, 1))
        #expect(try draw(Self.canvas([near, far]))[1, 4] == Self.blue)
        near.depth = .init()
        far.depth = .init()
        let tested = try draw(Self.canvas([near, far]))
        #expect(tested[1, 4] == Self.red && tested[7, 4] == Self.blue)
        // The same in a tile at three times, and with four samples a pixel.
        let tile = try draw(Self.canvas([near, far], antialias: true), scale: 3, region: CGRect(x: 4, y: 2, width: 4, height: 4))
        #expect(tile[2, 6] == Self.red && tile[10, 6] == Self.blue)
        // Not written, the near wall's depth does not hold the far one back.
        near.depth?.writes = false
        #expect(try draw(Self.canvas([near, far]))[1, 4] == Self.blue)
        // As far as each other: LESS lets the first stay, LEQUAL the second cover it.
        var first = Self.wall(-1, 1, z: 0, Self.flat(1, 0, 0)), second = Self.wall(-1, 1, z: 0, Self.flat(0, 1, 0))
        first.depth = .init()
        second.depth = .init()
        #expect(try draw(Self.canvas([first, second]))[4, 4] == Self.red)
        second.depth = .init(compare: .lessEqual)
        #expect(try draw(Self.canvas([first, second]))[4, 4] == Self.green)
        // And polygonOffset brings the second a little nearer.
        second.depth = .init()
        second.offset = .init(factor: -1, units: -4)
        #expect(try draw(Self.canvas([first, second]))[4, 4] == Self.green)
        // depthRange puts the first at the far end, where nothing is nearer than what was cleared.
        first.depth = .init(compare: .less, near: 1, far: 1)
        second.offset = nil
        #expect(try draw(Self.canvas([first]))[4, 4] == Self.nothing)
    }

    @Test func depthIsTestedInATargetToo() throws {
        var near = Self.wall(-1, 0, z: -0.5, Self.flat(1, 0, 0)), far = Self.wall(-1, 1, z: 0.5, Self.flat(0, 0, 1))
        near.depth = .init()
        far.depth = .init()
        var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: false)
        frame.targets = [ShaderTarget(width: 8, height: 8)]
        frame.passes = [ShaderPass(colors: [0], depth: 0, clearColor: [0, 0, 0, 0], clearDepth: 1, draws: [near, far]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [TargetsTests.showing(0, 8, 8, nearest: true)])]
        let pixels = try draw(frame)
        #expect(pixels[1, 4] == Self.red && pixels[6, 4] == Self.blue)
        // Without a depth buffer every test passes, as in WebGL.
        frame.passes[0].depth = nil
        frame.passes[0].clearDepth = nil
        #expect(try draw(frame)[1, 4] == Self.blue)
        // A second pass into the same framebuffer finds its depth.
        frame.passes = [ShaderPass(colors: [0], depth: 0, clearColor: [0, 0, 0, 0], clearDepth: 1, draws: [near]),
                        ShaderPass(colors: [0], depth: 0, draws: [far]),
                        ShaderPass(clearColor: [0, 0, 0, 0], draws: [TargetsTests.showing(0, 8, 8, nearest: true)])]
        let again = try draw(frame)
        #expect(again[1, 4] == Self.red && again[6, 4] == Self.blue)
    }

    @Test func theStencilCutsOut() throws {
        // The left half written into the stencil without colour, then green where the stencil is 1.
        var mask = Self.wall(-1, 0, z: 0, Self.flat(1, 1, 1))
        mask.channels = []
        mask.stencil = .init(front: .init(compare: .always, reference: 1, pass: .replace))
        var fill = Self.wall(-1, 1, z: 0, Self.flat(0, 1, 0))
        fill.stencil = .init(front: .init(compare: .equal, reference: 1))
        let pixels = try draw(Self.canvas([mask, fill]))
        #expect(pixels[1, 4] == Self.green && pixels[6, 4] == Self.nothing)
        // Where it is not 1, and with a mask that hides the bit.
        fill.stencil = .init(front: .init(compare: .notEqual, reference: 1))
        #expect(try draw(Self.canvas([mask, fill]))[6, 4] == Self.green)
        fill.stencil = .init(front: .init(compare: .equal, reference: 1, readMask: 2))
        #expect(try draw(Self.canvas([mask, fill]))[6, 4] == Self.green)
        // Counted up twice, then drawn where it is 2.
        var count = mask
        count.stencil = .init(front: .init(compare: .always, pass: .increment))
        fill.stencil = .init(front: .init(compare: .equal, reference: 2))
        let twice = try draw(Self.canvas([count, count, fill]))
        #expect(twice[1, 4] == Self.green && twice[6, 4] == Self.nothing)
    }

    @Test func facesAreLeftOut() throws {
        // Counter-clockwise on the left, clockwise on the right.
        let fragment = Self.flat(1, 0, 0)
        func pair(_ change: (inout ShaderDraw) -> Void) throws -> (Bool, Bool) {
            var front = ShaderDraw(vertex: Self.vertex, fragment: fragment,
                                   attributes: ["a_position": .init(components: 3, values: [-1, -1, 0, 0, -1, 0, -1, 1, 0])], count: 3)
            var back = ShaderDraw(vertex: Self.vertex, fragment: fragment,
                                  attributes: ["a_position": .init(components: 3, values: [1, -1, 0, 0, -1, 0, 1, 1, 0])], count: 3)
            change(&front)
            change(&back)
            let onCanvas = try draw(Self.canvas([front, back]))
            // The same drawn into a texture, which is drawn the other way up.
            var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 8, height: 8)]
            frame.passes = [ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [front, back]),
                            ShaderPass(clearColor: [0, 0, 0, 0], draws: [TargetsTests.showing(0, 8, 8, nearest: true)])]
            let inTarget = try draw(frame)
            #expect(onCanvas.bytes == inTarget.bytes)
            return (onCanvas[0, 6] == Self.red, onCanvas[7, 6] == Self.red)
        }
        #expect(try pair { _ in } == (true, true))
        #expect(try pair { $0.cull = .back } == (true, false))
        #expect(try pair { $0.cull = .front } == (false, true))
        #expect(try pair { $0.cull = .back; $0.clockwiseFront = true } == (false, true))
        #expect(try pair { $0.cull = .both } == (false, false))
    }

    @Test func colorMaskAndTheScissorBox() throws {
        var white = Self.wall(-1, 1, z: 0, Self.flat(1, 1, 1))
        white.channels = [.red, .alpha]
        #expect(try draw(Self.canvas([white]))[4, 4] == Self.red)
        // The box is counted from the bottom left: two in, two up, four across and three high.
        white.channels = .all
        white.scissor = CGRect(x: 2, y: 2, width: 4, height: 3)
        let cut = try draw(Self.canvas([white]))
        let lit = (0..<64).filter { cut.bytes[$0 * 4 + 3] == 255 }
        #expect(lit == [26, 27, 28, 29, 34, 35, 36, 37, 42, 43, 44, 45])
        // In a tile at twice the size it lands where it should.
        let tile = try draw(Self.canvas([white]), scale: 2, region: CGRect(x: 4, y: 0, width: 4, height: 8))
        #expect(tile[3, 6][3] == 255 && tile[4, 6][3] == 0 && tile[0, 5][3] == 0 && tile[0, 11][3] == 255 && tile[0, 12][3] == 0)
        // And inside the viewport's own cut.
        white.viewport = CGRect(x: 0, y: 0, width: 4, height: 8)
        let both = try draw(Self.canvas([white]))
        #expect((0..<64).filter { both.bytes[$0 * 4 + 3] == 255 } == [26, 27, 34, 35, 42, 43])
    }

    @Test func instancesEachTakeTheirOwn() throws {
        // A small square drawn three times, each moved and coloured by what its instance is given.
        let vertex = """
            attribute vec2 a_position;
            attribute vec2 a_offset;
            attribute vec3 a_color;
            varying vec3 v_color;
            void main() { v_color = a_color; gl_Position = vec4(a_position * 0.25 + a_offset, 0.0, 1.0); }
            """
        let fragment = "precision mediump float; varying vec3 v_color; void main() { gl_FragColor = vec4(v_color, 1.0); }"
        var squares = ShaderDraw(vertex: vertex, fragment: fragment,
                                 attributes: ["a_position": ShaderDraw.fullSurfacePositions,
                                              "a_offset": .init(components: 2, values: [-0.75, 0.75, 0, 0, 0.75, -0.75], divisor: 1),
                                              "a_color": .init(components: 3, values: [1, 0, 0, 0, 1, 0, 0, 0, 1], divisor: 1)],
                                 count: 6)
        squares.instances = 3
        let pixels = try draw(Self.canvas([squares], size: 16))
        #expect(pixels[1, 1] == Self.red && pixels[8, 8] == Self.green && pixels[14, 14] == Self.blue && pixels[1, 14] == Self.nothing)
        // One colour for every two instances; with indices; fewer instances drawn.
        squares.attributes["a_color"] = .init(components: 3, values: [1, 0, 0, 0, 0, 1], divisor: 2)
        squares.attributes["a_position"] = .init(components: 2, values: [-1, -1, 1, -1, 1, 1, -1, 1])
        squares.indices = [0, 1, 2, 0, 2, 3]
        let shared = try draw(Self.canvas([squares], size: 16))
        #expect(shared[1, 1] == Self.red && shared[8, 8] == Self.red && shared[14, 14] == Self.blue)
        squares.instances = 2
        #expect(try draw(Self.canvas([squares], size: 16))[14, 14] == Self.nothing)
        // More instances than their arrays hold: nothing is drawn, as WebGL refuses it.
        squares.instances = 5
        #expect(try draw(Self.canvas([squares], size: 16)).variety.visible == 0)
        // WebGL 2 counts them itself.
        var counted = ShaderDraw(vertex: """
            #version 300 es
            in vec2 a_position;
            flat out int v_which;
            void main() { v_which = gl_InstanceID; gl_Position = vec4(a_position * 0.25 + vec2(float(gl_InstanceID) * 0.75 - 0.75), 0.0, 1.0); }
            """, fragment: """
            #version 300 es
            precision mediump float;
            flat in int v_which;
            out vec4 color;
            void main() { color = vec4(v_which == 0 ? 1.0 : 0.0, v_which == 1 ? 1.0 : 0.0, v_which == 2 ? 1.0 : 0.0, 1.0); }
            """, attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        counted.instances = 3
        let numbered = try draw(Self.canvas([counted], size: 16))
        #expect(numbered[1, 14] == Self.red && numbered[8, 8] == Self.green && numbered[14, 1] == Self.blue)
    }

    static let read = """
        precision highp float;
        uniform sampler2D u_data;
        uniform vec2 u_resolution;
        uniform float u_scale;
        void main() { gl_FragColor = texture2D(u_data, gl_FragCoord.xy / u_resolution) * u_scale; }
        """

    static func reading(_ data: ShaderData, scale: Float = 1, width: Int = 2, height: Int = 2) -> ShaderFrame {
        var draw = ShaderDraw.fullSurface(fragment: read, uniforms: ["u_resolution": [Float(width), Float(height)], "u_scale": [scale]])
        draw.data["u_data"] = data
        draw.sampling["u_data"] = .init(magnify: .nearest, minify: .nearest)
        return ShaderFrame(size: CGSize(width: width, height: height), draws: [draw], antialias: false)
    }

    @Test func texturesOfNumbers() throws {
        // Floats beyond 1, the first row at the bottom as WebGL reads a typed array.
        let floats: [Float] = [2, 0, 0, 2, 0, 4, 0, 4, 0, 0, 8, 8, 1, 1, 1, 4]
        let data = try #require(ShaderData(width: 2, height: 2, format: .rgba32Float, bytes: floats.withUnsafeBytes { Array($0) }))
        let pixels = try draw(Self.reading(data, scale: 0.125))
        #expect(near(pixels[0, 1], [64, 0, 0, 64], within: 1))       // bottom left: the first texel
        #expect(near(pixels[1, 1], [0, 128, 0, 128], within: 1))
        #expect(near(pixels[0, 0], [0, 0, 255, 255], within: 1))     // top left: the third
        #expect(near(pixels[1, 0], [32, 32, 32, 128], within: 1))
        // The same as half floats.
        let halves = floats.map(Half.bits)
        let half = try #require(ShaderData(width: 2, height: 2, format: .rgba16Float, bytes: halves.withUnsafeBytes { Array($0) }))
        #expect(try draw(Self.reading(half, scale: 0.125)).bytes == pixels.bytes)
        // LUMINANCE reads as grey and opaque, ALPHA as alpha alone, LUMINANCE_ALPHA as both.
        let luminance = try #require(ShaderData(width: 2, height: 1, format: .luminance8, bytes: [255, 128]))
        let grey = try draw(Self.reading(luminance, width: 2, height: 1))
        #expect(grey[0, 0] == [255, 255, 255, 255] && grey[1, 0] == [128, 128, 128, 255])
        let alpha = try #require(ShaderData(width: 2, height: 1, format: .alpha8, bytes: [255, 128]))
        let clear = try draw(Self.reading(alpha, width: 2, height: 1))
        #expect(clear[0, 0] == [0, 0, 0, 255] && clear[1, 0] == [0, 0, 0, 128])
        let both = try #require(ShaderData(width: 1, height: 1, format: .luminanceAlpha8, bytes: [128, 255]))
        #expect(try draw(Self.reading(both, width: 1, height: 1))[0, 0] == [128, 128, 128, 255])
        // Bytes with colour where alpha is nought stay as they are: nothing premultiplies them.
        let bytes = try #require(ShaderData(width: 1, height: 1, format: .rgba8, bytes: [200, 100, 50, 0]))
        var plain = Self.reading(bytes, width: 1, height: 1)
        plain.draws[0].fragment = "precision highp float; uniform sampler2D u_data; void main() { gl_FragColor = vec4(texture2D(u_data, vec2(0.5)).rgb, 1.0); }"
        #expect(try draw(plain)[0, 0] == [200, 100, 50, 255])
        // Too few bytes for its size is no texture.
        #expect(ShaderData(width: 2, height: 2, format: .rgba8, bytes: [1, 2, 3]) == nil)
        // One format read as another, as a target takes its first contents.
        let asFloats: [Float] = bytes.bytes(as: .rgba32Float).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let expected: [Float] = [200, 100, 50, 0].map { $0 / 255 }
        #expect(asFloats == expected)
        let asHalves: [UInt16] = data.bytes(as: .rg16Float).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let two: [Float] = [2, 0, 0, 4, 0, 0, 1, 1]
        #expect(asHalves.map(Half.float) == two)
        #expect(luminance.bytes(as: .rgba8) == [255, 255, 255, 255, 128, 128, 128, 255])
    }

    @Test func aPictureKeptAsSRGBIsReadAsLight() throws {
        let image = picture(1, 1, [128, 128, 128, 255])
        var shown = ShaderDraw.fullSurface(fragment: "precision highp float; uniform sampler2D u_image; void main() { gl_FragColor = texture2D(u_image, vec2(0.5)); }",
                                           textures: ["u_image": image])
        #expect(try draw(Self.canvas([shown], size: 2))[0, 0] == [128, 128, 128, 255])
        shown.decodes = ["u_image"]
        // 128 of 255 in sRGB is 0.2158 of the light.
        #expect(near(try draw(Self.canvas([shown], size: 2))[0, 0], [55, 55, 55, 255], within: 1))
    }

    @Test func theCanvasIsDrawnOntoInSeveralPasses() throws {
        for antialias in [false, true] {
            // Cleared, drawn onto, then drawn onto again without a clear: both stay.
            let left = Self.wall(-1, 0, z: 0, Self.flat(1, 0, 0)), right = Self.wall(0, 1, z: 0, Self.flat(0, 0, 1))
            var frame = ShaderFrame(size: CGSize(width: 8, height: 8), draws: [], antialias: antialias)
            frame.passes = [ShaderPass(clearColor: [0, 1, 0, 1], draws: [left]), ShaderPass(draws: [right])]
            let both = try draw(frame)
            #expect(both[1, 4] == Self.red && both[6, 4] == Self.blue)
            // Cleared again in between: only what came after is there.
            frame.passes = [ShaderPass(clearColor: [0, 1, 0, 1], draws: [left]), ShaderPass(clearColor: [0, 0, 0, 0], draws: [right])]
            let after = try draw(frame)
            #expect(after[1, 4] == Self.nothing && after[6, 4] == Self.blue)
            // Depth stays from one pass to the next, unless it is cleared.
            var near = Self.wall(-1, 1, z: -0.5, Self.flat(1, 0, 0)), far = Self.wall(-1, 1, z: 0.5, Self.flat(0, 0, 1))
            near.depth = .init()
            far.depth = .init()
            frame.passes = [ShaderPass(clearColor: [0, 0, 0, 0], clearDepth: 1, draws: [near]), ShaderPass(draws: [far])]
            #expect(try draw(frame)[4, 4] == Self.red)
            frame.passes = [ShaderPass(clearColor: [0, 0, 0, 0], clearDepth: 1, draws: [near]), ShaderPass(clearDepth: 1, draws: [far])]
            #expect(try draw(frame)[4, 4] == Self.blue)
            // A canvas that is not see-through, with depth: finished after its last pass.
            frame.alpha = false
            frame.passes = [ShaderPass(clearColor: [0, 0, 0, 0], clearDepth: 1, draws: [near]), ShaderPass(draws: [])]
            #expect(try draw(frame)[4, 4] == Self.red)
        }
    }
}
