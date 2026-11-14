#if !os(Windows)
import CoreGraphics
import Metal
#endif
import Foundation
import Testing
@testable import Shaders

/// WebGL's coordinates kept however the output is scaled, cut into tiles or drawn into.
@Suite struct ConventionsTests {
    static let gradient = """
        precision mediump float;
        uniform vec2 u_resolution;
        void main() {
            vec2 uv = gl_FragCoord.xy / u_resolution;
            gl_FragColor = vec4(uv.x, uv.y, 0.0, 1.0);
        }
        """

    @Test func fragCoordStartsAtTheBottomLeft() throws {
        let pixels = try draw(frame(64, 32, Self.gradient))
        #expect(pixels.width == 64 && pixels.height == 32)
        #expect(near(pixels[0, 31], [1, 4, 0, 255]))       // bottom left: black
        #expect(near(pixels[0, 0], [1, 251, 0, 255]))      // top left: green
        #expect(near(pixels[63, 31], [253, 4, 0, 255]))    // bottom right: red
        #expect(near(pixels[63, 0], [253, 251, 0, 255]))
    }

    @Test func aRegionAtFourTimesMatchesTheWhole() throws {
        let whole = try draw(frame(64, 32, Self.gradient))
        let region = CGRect(x: 16, y: 8, width: 24, height: 12)
        let part = try draw(frame(64, 32, Self.gradient), scale: 4, region: region)
        #expect(part.width == 96 && part.height == 48)
        for j in 0..<12 {
            for i in 0..<24 {
                let expected = whole[16 + i, 8 + j]
                let block = part.mean(x: i * 4, y: j * 4, size: 4)
                #expect(near(block, expected, within: 1.5), "at \(i), \(j): \(block) against \(expected)")
            }
        }
    }

    @Test func webGL2() throws {
        let fragment = """
            #version 300 es
            precision highp float;
            uniform vec2 u_resolution;
            out vec4 fragColor;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                fragColor = vec4(uv, 0.0, 1.0);
            }
            """
        let vertex = """
            #version 300 es
            in vec2 a_position;
            void main() { gl_Position = vec4(a_position, 0.0, 1.0); }
            """
        let draw = ShaderDraw(vertex: vertex, fragment: fragment, uniforms: ["u_resolution": [64, 32]],
                              attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 64, height: 32), draws: [draw]))
        #expect(near(pixels[0, 31], [1, 4, 0, 255]))
        #expect(near(pixels[0, 0], [1, 251, 0, 255]))
        #expect(near(pixels[63, 31], [253, 4, 0, 255]))
    }

    @Test func derivativesRunUpAndRight() throws {
        let fragment = """
            #extension GL_OES_standard_derivatives : enable
            precision mediump float;
            varying vec2 v_unused;
            void main() {
                float up = dFdy(gl_FragCoord.y);
                float right = dFdx(gl_FragCoord.x);
                vec2 both = dFdy(gl_FragCoord.xy);
                gl_FragColor = vec4(right > 0.0 ? 1.0 : 0.0, up > 0.0 ? 1.0 : 0.0, both.y > 0.0 ? 1.0 : 0.0, 1.0);
            }
            """
        let pixels = try draw(frame(16, 16, fragment), scale: 2)
        #expect(pixels[5, 5] == [255, 255, 255, 255])
    }

    @Test func counterClockwiseFacesFront() throws {
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let fragment = """
            precision mediump float;
            void main() { gl_FragColor = gl_FrontFacing ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
            """
        // Counter-clockwise with +y up, as WebGL counts it.
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [-1, -1, 1, -1, -1, 1])], count: 3)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 16, height: 16), draws: [draw], antialias: false))
        #expect(pixels[2, 13] == [0, 255, 0, 255])
    }

    @Test func clipSpaceUpIsTheTopOfThePicture() throws {
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
        // The top half of clip space.
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [-1, 0, 1, 0, -1, 1, 1, 1])],
                              mode: .triangleStrip, count: 4)
        let frame = ShaderFrame(size: CGSize(width: 32, height: 32), draws: [draw], antialias: false)
        let pixels = try Shaders_draw(frame)
        #expect(pixels[16, 4] == [255, 255, 255, 255])
        #expect(pixels[16, 28] == [0, 0, 0, 0])
        // A region across the middle at three times: the boundary lands where it should.
        let part = try Shaders_draw(frame, scale: 3, region: CGRect(x: 8, y: 12, width: 16, height: 8))
        #expect(part[10, 3 * 4 - 2] == [255, 255, 255, 255])
        #expect(part[10, 3 * 4 + 1] == [0, 0, 0, 0])
    }

    @Test func theViewportCutsAndPlaces() throws {
        var draw = ShaderDraw.fullSurface(fragment: Self.gradient, uniforms: ["u_resolution": [64, 32]])
        draw.viewport = CGRect(x: 0, y: 0, width: 32, height: 16) // the bottom-left quarter
        let frame = ShaderFrame(size: CGSize(width: 64, height: 32), draws: [draw], antialias: false)
        let pixels = try Shaders_draw(frame)
        #expect(pixels[40, 8] == [0, 0, 0, 0])
        #expect(pixels[10, 8] == [0, 0, 0, 0])
        #expect(near(pixels[31, 16], [125, 123, 0, 255]))  // gl_FragCoord is still the drawing buffer's
        // And in a region at twice the size, the cut lands where it should.
        let part = try Shaders_draw(frame, scale: 2, region: CGRect(x: 24, y: 8, width: 16, height: 16))
        #expect(near(part[15, 17], [126, 121, 0, 255]))
        #expect(part[16, 17][3] == 0)
        #expect(part[10, 15][3] == 0)
        #expect(part[10, 16][3] == 255)
    }

    @Test func pointsGrowWithTheOutput() throws {
        let vertex = """
            attribute vec2 a_position;
            void main() { gl_Position = vec4(a_position, 0.0, 1.0); gl_PointSize = 4.0; }
            """
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }"
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [0, 0])], mode: .points, count: 1)
        let frame = ShaderFrame(size: CGSize(width: 16, height: 16), draws: [draw], antialias: false)
        let one = try Shaders_draw(frame)
        let three = try Shaders_draw(frame, scale: 3)
        let covered = { (pixels: Pixels) in stride(from: 3, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] > 0 }.count }
        #expect(covered(one) == 16)
        #expect(covered(three) == 144)
    }

    @Test func fragCoordDepthAndW() throws {
        // A quad at clip z 0 and w 2: WebGL reads gl_FragCoord.z 0.5 (depth range 0 to 1) and .w 1/2.
        let vertex = "attribute vec2 a_position; void main() { gl_Position = vec4(a_position * 2.0, 0.0, 2.0); }"
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(gl_FragCoord.z, gl_FragCoord.w, 0.0, 1.0); }"
        let draw = ShaderDraw(vertex: vertex, fragment: fragment, attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [128, 128, 0, 255], within: 1))
    }

    @Test func pointCoordStartsAtTheTopLeft() throws {
        let vertex = """
            attribute vec2 a_position;
            void main() { gl_Position = vec4(a_position, 0.0, 1.0); gl_PointSize = 8.0; }
            """
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(gl_PointCoord, 0.0, 1.0); }"
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              attributes: ["a_position": .init(components: 2, values: [0, 0])], mode: .points, count: 1)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 16, height: 16), draws: [draw], antialias: false))
        #expect(near(pixels[4, 4], [16, 16, 0, 255], within: 2))      // the point's top left
        #expect(near(pixels[11, 11], [239, 239, 0, 255], within: 2))  // its bottom right
    }

    #if !os(Windows)
    @Test func intoATextureTheCallerOwns() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = renderer.device.makeTexture(descriptor: descriptor)!
        let commands = renderer.device.makeCommandQueue()!.makeCommandBuffer()!
        try renderer.draw(frame(64, 32, Self.gradient), into: texture, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bgra, bytesPerRow: 64 * 4, from: MTLRegionMake2D(63, 0, 1, 1), mipmapLevel: 0)
        #expect(near(bgra.map(Int.init), [0, 251, 253, 255]))  // top right: red and green, in BGRA
    }

    /// A picture for a movie, with sixteen bits to a colour, keeps what lies between eight
    /// bits' steps: a glow as dark as they come is a ramp, not five bands.
    @Test func aDeepPictureKeepsWhatLiesBetweenEightBitsSteps() throws {
        let fragment = """
            precision highp float;
            uniform vec2 u_resolution;
            void main() { gl_FragColor = vec4(gl_FragCoord.x / u_resolution.x * 0.02, 0.0, 0.0, 1.0); }
            """
        let size = CGSize(width: 512, height: 4)
        let plain = try renderer.image(of: frame(512, 4, fragment), pixels: size)
        let deep = try renderer.image(of: frame(512, 4, fragment), pixels: size, deep: true)
        #expect(plain.bitsPerComponent == 8 && deep.bitsPerComponent == 16)
        // The top row's reds, each from none to one.
        func reds(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: 512 * 4 * 4)
            values.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 512, height: 4, bitsPerComponent: 32, bytesPerRow: 512 * 16,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)!
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            return (0..<512).map { values[$0 * 4] }
        }
        let coarse = reds(plain), fine = reds(deep)
        #expect(Set(coarse).count <= 7 && Set(fine).count >= 500, "\(Set(coarse).count), \(Set(fine).count)")
        for x in 0..<512 {
            let exact = (Float(x) + 0.5) / 512 * 0.02
            #expect(abs(fine[x] - exact) < 0.0001 && abs(coarse[x] - exact) < 0.5 / 255 + 0.0001, "at \(x): \(fine[x]), \(coarse[x]) for \(exact)")
        }
    }
    #endif

    @Test func opaqueAndUnpremultipliedCanvases() throws {
        let fragment = "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.5, 0.0, 0.5); }"
        var opaque = frame(8, 8, fragment)
        opaque.alpha = false
        #expect(near(try Shaders_draw(opaque)[4, 4], [255, 128, 0, 255], within: 1))
        var straight = frame(8, 8, fragment)
        straight.premultipliedAlpha = false
        #expect(near(try Shaders_draw(straight)[4, 4], [128, 64, 0, 128], within: 1))
    }
}

/// `draw` from Support, under a name the suite's own methods do not hide.
func Shaders_draw(_ frame: ShaderFrame, scale: Double = 1, region: CGRect? = nil) throws -> Pixels {
    try draw(frame, scale: scale, region: region)
}
