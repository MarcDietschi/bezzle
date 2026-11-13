#if !os(Windows)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import Shaders

/// What WebGL's state gives a draw: meshes, uniforms, textures, blending, and many tiles at once.
@Suite struct DrawingTests {
    @Test func aMeshMovedByAMatrixWithIndices() throws {
        let vertex = """
            attribute vec2 a_position;
            attribute vec3 a_color;
            uniform mat3 u_matrix;
            varying vec3 v_color;
            void main() {
                v_color = a_color;
                gl_Position = vec4((u_matrix * vec3(a_position, 1.0)).xy, 0.0, 1.0);
            }
            """
        let fragment = """
            precision mediump float;
            varying vec3 v_color;
            void main() { gl_FragColor = vec4(v_color, 1.0); }
            """
        // A square of half the clip space's width at its centre, moved up and right by half.
        let positions: [Float] = [-0.25, -0.25, 0.25, -0.25, 0.25, 0.25, -0.25, 0.25]
        let colors: [Float] = Array(repeating: [0, 0, 1], count: 4).flatMap { $0 }
        let matrix: [Float] = [1, 0, 0, 0, 1, 0, 0.5, 0.5, 1]  // column-major: translation in the last column
        let draw = ShaderDraw(vertex: vertex, fragment: fragment, uniforms: ["u_matrix": matrix],
                              attributes: ["a_position": .init(components: 2, values: positions),
                                           "a_color": .init(components: 3, values: colors)],
                              indices: [0, 1, 2, 0, 2, 3], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 40, height: 40), draws: [draw], antialias: false))
        // The square spans clip x and y from 0.25 to 0.75: pixels 25 to 35 across, 5 to 15 down.
        #expect(pixels[30, 10] == [0, 0, 255, 255])
        #expect(pixels[25, 5] == [0, 0, 255, 255])
        #expect(pixels[34, 14] == [0, 0, 255, 255])
        #expect(pixels[24, 10] == [0, 0, 0, 0])
        #expect(pixels[30, 15] == [0, 0, 0, 0])
        #expect(pixels[20, 20] == [0, 0, 0, 0])
        // drawElements from the fourth index on: only the second triangle.
        var second = draw
        second.first = 3
        second.count = 3
        let half = try Shaders_draw(ShaderFrame(size: CGSize(width: 40, height: 40), draws: [second], antialias: false))
        #expect(half[26, 6] == [0, 0, 255, 255])   // upper left of the square: the triangle 0, 2, 3
        #expect(half[34, 14] == [0, 0, 0, 0])      // lower right: the first, not drawn
    }

    @Test func attributesFillLikeWebGL() throws {
        // A vec4 attribute given two numbers reads z = 0 and w = 1; a disabled array its constant.
        let vertex = """
            attribute vec2 a_position;
            attribute vec4 a_short;
            attribute vec4 a_constant;
            attribute vec4 a_never;
            varying vec4 v_color;
            void main() {
                v_color = vec4(a_short.z, a_short.w, a_constant.x, a_never.w);
                gl_Position = vec4(a_position, 0.0, 1.0);
            }
            """
        let fragment = "precision mediump float; varying vec4 v_color; void main() { gl_FragColor = v_color; }"
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": ShaderDraw.fullSurfacePositions,
                                           "a_short": .init(components: 2, values: Array(repeating: 0.5, count: 12)),
                                           "a_constant": .constant([0.5])],
                              count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [0, 255, 128, 255], within: 1))
    }

    @Test func fansAndLoops() throws {
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
        let square: [Float] = [-1, -1, 1, -1, 1, 1, -1, 1]
        let fan = ShaderDraw(vertex: vertex, fragment: fragment, attributes: ["a_position": .init(components: 2, values: square)],
                             mode: .triangleFan, count: 4)
        let filled = try Shaders_draw(ShaderFrame(size: CGSize(width: 8, height: 8), draws: [fan], antialias: false))
        #expect(filled.variety.visible == 64)
        let inner: [Float] = [-0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, 0.5]
        let loop = ShaderDraw(vertex: vertex, fragment: fragment, attributes: ["a_position": .init(components: 2, values: inner)],
                              mode: .lineLoop, count: 4)
        let outline = try Shaders_draw(ShaderFrame(size: CGSize(width: 16, height: 16), draws: [loop], antialias: false))
        #expect(outline[8, 8][3] == 0)                                 // inside stays empty
        #expect(outline[4, 8][3] == 255 || outline[3, 8][3] == 255)   // the closing side, from the last corner to the first
        #expect(outline[12, 8][3] == 255 || outline[11, 8][3] == 255)
    }

    @Test func uniformArraysWholeAndByElement() throws {
        let fragment = """
            precision mediump float;
            uniform vec3 u_colors[4];
            void main() {
                int i = int(gl_FragCoord.x / 16.0);
                vec3 c = u_colors[0];
                if (i == 1) c = u_colors[1];
                if (i == 2) c = u_colors[2];
                if (i == 3) c = u_colors[3];
                gl_FragColor = vec4(c, 1.0);
            }
            """
        let whole: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0]
        let pixels = try draw(frame(64, 4, fragment, uniforms: ["u_colors": whole]))
        #expect(pixels[8, 2] == [255, 0, 0, 255])
        #expect(pixels[24, 2] == [0, 255, 0, 255])
        #expect(pixels[40, 2] == [0, 0, 255, 255])
        #expect(pixels[56, 2] == [255, 255, 0, 255])
        // Element by element, as uniform3fv(location of "u_colors[2]", ...) sets them: the third
        // and, with six numbers, the fourth too; the first alone by its own name.
        let elements = try draw(frame(64, 4, fragment, uniforms: [
            "u_colors": whole, "u_colors[2]": [1, 0, 1, 0, 1, 1], "u_colors[0]": [0.5, 0.5, 0.5],
        ]))
        #expect(near(elements[8, 2], [128, 128, 128, 255], within: 1))
        #expect(elements[24, 2] == [0, 255, 0, 255])
        #expect(elements[40, 2] == [255, 0, 255, 255])
        #expect(elements[56, 2] == [0, 255, 255, 255])
    }

    @Test func structsIntsAndBools() throws {
        let fragment = """
            precision mediump float;
            struct Light { vec3 color; float power; };
            uniform Light u_lights[2];
            uniform int u_which;
            uniform bool u_on;
            uniform bvec2 u_flags;
            uniform mat2 u_m;
            void main() {
                Light light = u_which == 1 ? u_lights[1] : u_lights[0];
                float m = u_m[1][0];                                     // column 1, row 0
                gl_FragColor = vec4(light.color * light.power, u_on && u_flags.y && !u_flags.x ? m : 0.0);
            }
            """
        let pixels = try draw(frame(4, 4, fragment, uniforms: [
            "u_lights[0].color": [1, 0, 0], "u_lights[0].power": [1],
            "u_lights[1].color": [0, 1, 0], "u_lights[1].power": [0.5],
            "u_which": [1], "u_on": [1], "u_flags": [0, 1], "u_m": [0, 0, 1, 0],
        ]))
        #expect(near(pixels[2, 2], [0, 128, 0, 255], within: 1))
    }

    @Test func premultipliedOverInTwoDraws() throws {
        let red = ShaderDraw.fullSurface(fragment: "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }")
        let blue = ShaderDraw.fullSurface(fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.0, 0.0, 0.5, 0.5); }",
                                          blend: .premultipliedOver)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [red, blue]))
        #expect(near(pixels[2, 2], [128, 0, 128, 255], within: 1))
        // Over a clear colour, with straight alpha.
        let over = ShaderDraw.fullSurface(fragment: "precision mediump float; void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 0.25); }",
                                          blend: ShaderDraw.Blend(source: .sourceAlpha, destination: .oneMinusSourceAlpha,
                                                                  sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha))
        let cleared = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), clear: [1, 1, 1, 1], draws: [over]))
        #expect(near(cleared[2, 2], [191, 255, 191, 255], within: 1))
    }

    @Test func aPictureAsATextureWithAndWithoutFlip() throws {
        // Top left red, top right green, bottom left blue, bottom right white.
        let image = picture(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let fragment = """
            precision mediump float;
            uniform sampler2D u_image;
            uniform vec2 u_resolution;
            void main() { gl_FragColor = texture2D(u_image, gl_FragCoord.xy / u_resolution); }
            """
        var draw = ShaderDraw.fullSurface(fragment: fragment, uniforms: ["u_resolution": [8, 8]], textures: ["u_image": image])
        draw.sampling["u_image"] = ShaderDraw.Sampling(magnify: .nearest, minify: .nearest)
        // Without the flip, t = 0 is the picture's top row, and it is at the canvas's bottom.
        let plain = try Shaders_draw(ShaderFrame(size: CGSize(width: 8, height: 8), draws: [draw]))
        #expect(plain[1, 6] == [255, 0, 0, 255])
        #expect(plain[6, 6] == [0, 255, 0, 255])
        #expect(plain[1, 1] == [0, 0, 255, 255])
        #expect(plain[6, 1] == [255, 255, 255, 255])
        // With it, the picture stands the right way up.
        draw.flipsTextures = true
        let flipped = try Shaders_draw(ShaderFrame(size: CGSize(width: 8, height: 8), draws: [draw]))
        #expect(flipped[1, 1] == [255, 0, 0, 255])
        #expect(flipped[6, 1] == [0, 255, 0, 255])
        #expect(flipped[1, 6] == [0, 0, 255, 255])
        #expect(flipped[6, 6] == [255, 255, 255, 255])
    }

    @Test func texturesRepeatAndKeepStraightAlpha() throws {
        // Half-transparent red: WebGL samples it unpremultiplied unless asked.
        let image = picture(1, 1, [255, 0, 0, 128])
        let fragment = """
            precision mediump float;
            uniform sampler2D u_image;
            void main() { vec4 c = texture2D(u_image, vec2(3.25, -2.5)); gl_FragColor = vec4(c.r, c.a, 0.0, 1.0); }
            """
        var draw = ShaderDraw.fullSurface(fragment: fragment, textures: ["u_image": image])
        draw.sampling["u_image"] = ShaderDraw.Sampling(wrapS: .repeat, wrapT: .repeat)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 2, height: 2), draws: [draw]))
        #expect(near(pixels[1, 1], [255, 128, 0, 255], within: 1))
        draw.premultipliesTextures = true
        let premultiplied = try Shaders_draw(ShaderFrame(size: CGSize(width: 2, height: 2), draws: [draw]))
        #expect(near(premultiplied[1, 1], [128, 128, 0, 255], within: 1))
        // A sampler without a picture reads opaque black.
        draw.textures = [:]
        #expect(try Shaders_draw(ShaderFrame(size: CGSize(width: 2, height: 2), draws: [draw]))[1, 1] == [0, 255, 0, 255])
    }

    @Test func matrixAttributes() throws {
        let vertex = """
            attribute vec2 a_position;
            attribute mat2 a_turn;
            attribute vec3 a_rest;
            varying vec3 v_color;
            void main() {
                v_color = vec3(a_turn[1][0], a_turn[0][1], a_rest.z);
                gl_Position = vec4(a_turn * a_position, 0.0, 1.0);
            }
            """
        let fragment = "precision mediump float; varying vec3 v_color; void main() { gl_FragColor = vec4(v_color, 1.0); }"
        // Turned a quarter: column 0 is (0, 1), column 1 is (-1, 0).
        let turn: [Float] = Array(repeating: [0, 1, -1, 0], count: 3).flatMap { $0 }
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [-1, -1, 1, -1, -1, 1]),
                                           "a_turn": .init(components: 4, values: turn),
                                           "a_rest": .init(components: 3, values: Array(repeating: 0.5, count: 9))],
                              count: 3)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 16, height: 16), draws: [draw], antialias: false))
        // The lower-left triangle turned a quarter counter-clockwise lands lower right.
        #expect(near(pixels[14, 10], [0, 255, 128, 255], within: 1))
        #expect(pixels[2, 6] == [0, 0, 0, 0])
        #expect(try renderer.interface(of: vertex, fragment).attributes.contains(ShaderAttribute(name: "a_turn", type: .mat2)))
    }

    @Test func clockwiseFacesBack() throws {
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let fragment = """
            precision mediump float;
            void main() { gl_FragColor = gl_FrontFacing ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
            """
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [-1, -1, -1, 1, 1, -1])], count: 3)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 16, height: 16), draws: [draw], antialias: false))
        #expect(pixels[2, 13] == [255, 0, 0, 255])
    }

    @Test func antialiasedEdges() throws {
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [-1, -1, 1, -0.7, -1, 1])], count: 3)
        let partial = { (pixels: Pixels) in stride(from: 3, to: pixels.bytes.count, by: 4).filter { 0 < pixels.bytes[$0] && pixels.bytes[$0] < 255 }.count }
        let smooth = try Shaders_draw(ShaderFrame(size: CGSize(width: 32, height: 32), draws: [draw], antialias: true))
        let hard = try Shaders_draw(ShaderFrame(size: CGSize(width: 32, height: 32), draws: [draw], antialias: false))
        #expect(partial(smooth) > 20)
        #expect(partial(hard) == 0)
    }

    @Test func sixteenTilesAtOnceMakeTheWhole() async throws {
        // A program no other test has, so the tiles also translate it at the same moment.
        let fragment = RealWorldTests.grain + "\n// tiles \(UUID())\n"
        let size = 128, tile = 32
        let frame = frame(size, size, fragment, uniforms: ["u_time": [1.25]], antialias: true)
        let tiles = try await withThrowingTaskGroup(of: (Int, Pixels).self) { group in
            for index in 0..<16 {
                group.addTask {
                    let region = CGRect(x: (index % 4) * tile, y: (index / 4) * tile, width: tile, height: tile)
                    return (index, try Shaders_draw(frame, scale: 2, region: region))
                }
            }
            var tiles: [Int: Pixels] = [:]
            for try await (index, pixels) in group { tiles[index] = pixels }
            return tiles
        }
        let whole = try Shaders_draw(frame, scale: 2)
        var differences = 0
        for (index, pixels) in tiles {
            let x0 = (index % 4) * tile * 2, y0 = (index / 4) * tile * 2
            for y in 0..<(tile * 2) {
                for x in 0..<(tile * 2) where !near(pixels[x, y], whole[x0 + x, y0 + y], within: 1) {
                    differences += 1
                }
            }
        }
        #expect(differences == 0)
        #expect(whole.variety.different > size * size)
    }
}
