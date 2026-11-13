import CoreGraphics
import Foundation
import Testing
@testable import Shaders

/// Shaders written the way sites write them for hero backgrounds.
@Suite struct RealWorldTests {
    /// A plane of many triangles bent by noise and coloured by it, as the gradient meshes of
    /// payment and startup sites do (WebGL 1, drawElements, a time uniform, a few colours).
    static let meshVertex = """
        precision highp float;
        attribute vec3 position;
        attribute vec2 uv;
        uniform mat4 projectionMatrix;
        uniform mat4 modelViewMatrix;
        uniform float u_time;
        uniform vec2 u_frequency;
        uniform vec3 u_baseColor;
        uniform vec3 u_waveColors[3];
        varying vec3 v_color;
        varying vec2 v_uv;

        //
        // Simplex 3D noise, after Ashima Arts (MIT).
        //
        vec4 permute(vec4 x) { return mod(((x * 34.0) + 1.0) * x, 289.0); }
        vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
        float snoise(vec3 v) {
            const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
            const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
            vec3 i = floor(v + dot(v, C.yyy));
            vec3 x0 = v - i + dot(i, C.xxx);
            vec3 g = step(x0.yzx, x0.xyz);
            vec3 l = 1.0 - g;
            vec3 i1 = min(g.xyz, l.zxy);
            vec3 i2 = max(g.xyz, l.zxy);
            vec3 x1 = x0 - i1 + C.xxx;
            vec3 x2 = x0 - i2 + C.yyy;
            vec3 x3 = x0 - D.yyy;
            i = mod(i, 289.0);
            vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0)) + i.y + vec4(0.0, i1.y, i2.y, 1.0))
                + i.x + vec4(0.0, i1.x, i2.x, 1.0));
            float n_ = 1.0 / 7.0;
            vec3 ns = n_ * D.wyz - D.xzx;
            vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
            vec4 x_ = floor(j * ns.z);
            vec4 y_ = floor(j - 7.0 * x_);
            vec4 x = x_ * ns.x + ns.yyyy;
            vec4 y = y_ * ns.x + ns.yyyy;
            vec4 h = 1.0 - abs(x) - abs(y);
            vec4 b0 = vec4(x.xy, y.xy);
            vec4 b1 = vec4(x.zw, y.zw);
            vec4 s0 = floor(b0) * 2.0 + 1.0;
            vec4 s1 = floor(b1) * 2.0 + 1.0;
            vec4 sh = -step(h, vec4(0.0));
            vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
            vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
            vec3 p0 = vec3(a0.xy, h.x);
            vec3 p1 = vec3(a0.zw, h.y);
            vec3 p2 = vec3(a1.xy, h.z);
            vec3 p3 = vec3(a1.zw, h.w);
            vec4 norm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
            p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
            vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
            m = m * m;
            return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
        }

        void main() {
            v_uv = uv;
            vec2 noiseCoord = uv * u_frequency;
            float tilt = -0.8 * uv.y;
            float incline = uv.x * 0.1;
            float offset = incline * mix(-0.25, 0.25, uv.y);
            float noise = snoise(vec3(noiseCoord.x + u_time * 3.0, noiseCoord.y, u_time * 10.0));
            noise = max(0.0, noise);
            vec3 pos = vec3(position.x, position.y, position.z + noise * 0.3 + tilt + incline + offset);
            v_color = u_baseColor;
            for (int i = 0; i < 3; i++) {
                float f = float(i + 1);
                float n = snoise(vec3(noiseCoord.x * f * 0.7 + u_time * (1.0 + f * 0.3), noiseCoord.y * f, u_time * 5.0 + f * 10.0));
                n = smoothstep(0.2, 0.8, n * 0.5 + 0.5);
                v_color = mix(v_color, u_waveColors[i], n);
            }
            gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
        }
        """

    static let meshFragment = """
        precision highp float;
        varying vec3 v_color;
        varying vec2 v_uv;
        void main() {
            vec3 color = v_color;
            color.g += 0.02 * sin(v_uv.x * 40.0);
            gl_FragColor = vec4(color, 1.0);
        }
        """

    /// A film grain over a soft gradient, animated by time, with `dFdx`-free hashing.
    static let grain = """
        precision mediump float;
        uniform vec2 u_resolution;
        uniform float u_time;
        float hash(vec2 p) {
            vec3 p3 = fract(vec3(p.xyx) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }
        void main() {
            vec2 uv = gl_FragCoord.xy / u_resolution;
            vec3 base = mix(vec3(0.05, 0.07, 0.2), vec3(0.6, 0.3, 0.8), uv.y + 0.1 * sin(u_time + uv.x * 6.2831));
            float n = hash(gl_FragCoord.xy + fract(u_time) * 1000.0) - 0.5;
            gl_FragColor = vec4(base + n * 0.08, 1.0);
        }
        """

    /// A Shadertoy shader as sites paste it: `mainImage`, iResolution, iTime, wrapped in a main.
    static let shadertoy = """
        #ifdef GL_ES
        precision highp float;
        #endif
        uniform vec3 iResolution;
        uniform float iTime;
        uniform vec4 iMouse;

        #define S(a, b, t) smoothstep(a, b, t)
        mat2 Rot(float a) { float s = sin(a), c = cos(a); return mat2(c, -s, s, c); }

        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
            vec3 col = vec3(0.0);
            for (float i = 0.0; i < 4.0; i++) {
                uv *= Rot(iTime * 0.1 + i);
                float d = length(uv - vec2(sin(iTime + i) * 0.3, cos(iTime * 0.7 + i) * 0.2));
                col += S(0.25, 0.0, d) * (0.5 + 0.5 * cos(iTime + i + vec3(0.0, 2.0, 4.0)));
            }
            fragColor = vec4(col, 1.0);
        }

        void main() {
            mainImage(gl_FragColor, gl_FragCoord.xy);
        }
        """

    /// A plane of `columns` by `rows` quads in clip space, with its uvs and indices.
    static func plane(_ columns: Int, _ rows: Int) -> (positions: [Float], uvs: [Float], indices: [UInt32]) {
        var positions: [Float] = [], uvs: [Float] = [], indices: [UInt32] = []
        for y in 0...rows {
            for x in 0...columns {
                let u = Float(x) / Float(columns), v = Float(y) / Float(rows)
                positions += [u * 2.4 - 1.2, v * 2.4 - 1.2, 0]
                uvs += [u, v]
            }
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let a = UInt32(y * (columns + 1) + x), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
                indices += [a, b, d, a, d, c]
            }
        }
        return (positions, uvs, indices)
    }

    static func meshFrame(time: Float) -> ShaderFrame {
        let plane = plane(64, 36)
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let projection: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -0.1, 0, 0, 0, 0, 1]
        let draw = ShaderDraw(vertex: meshVertex, fragment: meshFragment,
                              uniforms: ["projectionMatrix": projection, "modelViewMatrix": identity, "u_time": [time],
                                         "u_frequency": [3, 4], "u_baseColor": [0.95, 0.4, 0.3],
                                         "u_waveColors": [0.2, 0.4, 0.95, 0.9, 0.8, 0.2, 0.6, 0.2, 0.8]],
                              attributes: ["position": .init(components: 3, values: plane.positions),
                                           "uv": .init(components: 2, values: plane.uvs)],
                              indices: plane.indices, count: plane.indices.count)
        return ShaderFrame(size: CGSize(width: 1440, height: 900), clear: [1, 1, 1, 1], draws: [draw])
    }

    @Test func gradientMesh() throws {
        let interface = try renderer.interface(of: Self.meshVertex, Self.meshFragment)
        #expect(Set(interface.attributes.map(\.name)) == ["position", "uv"])
        #expect(interface.uniforms.contains(ShaderUniform(name: "u_waveColors", type: .vec3, count: 3)))
        let frame = Self.meshFrame(time: 0.4)
        try renderer.check(frame)
        let pixels = try Shaders_draw(frame, scale: 0.25)
        #expect(pixels.variety.different > pixels.width * pixels.height / 2)
        // The mesh is opaque and covers the canvas.
        #expect(pixels.variety.visible == pixels.width * pixels.height)
        // It moves with time.
        let later = try Shaders_draw(Self.meshFrame(time: 2.4), scale: 0.25)
        #expect(later.bytes != pixels.bytes)
    }

    @Test func filmGrain() throws {
        let pixels = try draw(frame(160, 90, Self.grain, uniforms: ["u_time": [3.5]]))
        #expect(pixels.variety.different > 160 * 90 / 2)
        #expect(pixels.variety.visible == 160 * 90)
    }

    /// What three.js puts before a ShaderMaterial's own GLSL for WebGL 2, much shortened.
    static let threeVertex = """
        #version 300 es
        #define attribute in
        #define varying out
        #define texture2D texture
        precision highp float;
        precision highp int;
        precision highp sampler2D;
        precision highp samplerCube;
        precision highp sampler3D;
        precision highp sampler2DArray;
        precision highp sampler2DShadow;
        precision highp isampler2D;
        precision highp usampler2D;
        #define HIGH_PRECISION
        #define SHADER_TYPE ShaderMaterial
        #define SHADER_NAME HeroGradient
        uniform mat4 modelMatrix;
        uniform mat4 modelViewMatrix;
        uniform mat4 projectionMatrix;
        uniform mat4 viewMatrix;
        uniform mat3 normalMatrix;
        uniform vec3 cameraPosition;
        uniform bool isOrthographic;
        #ifdef USE_INSTANCING
            attribute mat4 instanceMatrix;
        #endif
        attribute vec3 position;
        attribute vec3 normal;
        attribute vec2 uv;
        varying vec2 vUv;
        void main() {
            vUv = uv;
            gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
        }
        """

    static let threeFragment = """
        #version 300 es
        #define varying in
        layout(location = 0) out highp vec4 pc_fragColor;
        #define gl_FragColor pc_fragColor
        #define gl_FragDepthEXT gl_FragDepth
        #define texture2D texture
        #define textureCube texture
        #define texture2DProj textureProj
        #define texture2DLodEXT textureLod
        #define texture2DProjLodEXT textureProjLod
        #define textureCubeLodEXT textureLod
        #define texture2DGradEXT textureGrad
        #define texture2DProjGradEXT textureProjGrad
        #define textureCubeGradEXT textureGrad
        precision highp float;
        precision highp int;
        precision highp sampler2D;
        precision highp samplerCube;
        precision highp sampler3D;
        precision highp sampler2DArray;
        precision highp sampler2DShadow;
        precision highp samplerCubeShadow;
        precision highp sampler2DArrayShadow;
        precision highp isampler2D;
        precision highp isampler3D;
        precision highp isamplerCube;
        precision highp isampler2DArray;
        precision highp usampler2D;
        precision highp usampler3D;
        precision highp usamplerCube;
        precision highp usampler2DArray;
        #define HIGH_PRECISION
        #define SHADER_TYPE ShaderMaterial
        #define SHADER_NAME HeroGradient
        uniform mat4 viewMatrix;
        uniform vec3 cameraPosition;
        uniform bool isOrthographic;
        vec4 LinearTransferOETF( in vec4 value ) { return value; }
        vec4 linearToOutputTexel( vec4 value ) { return LinearTransferOETF( value ); }
        uniform float uTime;
        uniform vec3 uColorA;
        uniform vec3 uColorB;
        varying vec2 vUv;
        void main() {
            float wave = 0.5 + 0.5 * sin(vUv.x * 6.2831 + uTime);
            gl_FragColor = linearToOutputTexel(vec4(mix(uColorA, uColorB, wave * vUv.y), 1.0));
        }
        """

    @Test func threeJSShaderMaterial() throws {
        let interface = try renderer.interface(of: Self.threeVertex, Self.threeFragment)
        #expect(Set(interface.attributes.map(\.name)) == ["position", "uv"])
        #expect(Set(interface.uniforms.map(\.name)).isSuperset(of: ["projectionMatrix", "modelViewMatrix", "uTime", "uColorA", "uColorB"]))
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let plane = Self.plane(1, 1)
        let draw = ShaderDraw(vertex: Self.threeVertex, fragment: Self.threeFragment,
                              uniforms: ["projectionMatrix": identity, "modelViewMatrix": identity, "uTime": [0.5],
                                         "uColorA": [0.1, 0.2, 0.8], "uColorB": [1, 0.6, 0.2]],
                              attributes: ["position": .init(components: 3, values: plane.positions),
                                           "uv": .init(components: 2, values: plane.uvs)],
                              indices: plane.indices, count: plane.indices.count)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 64, height: 36), draws: [draw]))
        #expect(pixels.variety.visible == 64 * 36)
        #expect(pixels.variety.different > 64 * 36 / 2)
        // Bottom left: the plane overhangs the canvas, so uv is (0.103, 0.095) there, the wave
        // 0.956, and the colour A + (B - A) * 0.0907.
        #expect(near(pixels[1, 35], [46, 60, 190, 255], within: 1))
    }

    @Test func shadertoyWrapped() throws {
        let interface = try renderer.interface(of: ShaderDraw.fullSurfaceVertex, Self.shadertoy)
        #expect(Set(interface.uniforms.map(\.name)) == ["iResolution", "iTime"])  // iMouse is not used
        let pixels = try draw(frame(160, 90, Self.shadertoy, uniforms: ["iResolution": [160, 90, 1], "iTime": [1.5]]))
        #expect(pixels.variety.different > 160 * 90 / 4)
        // Something lit near the middle, the corners dark.
        #expect(pixels.mean(x: 70, y: 35, size: 20).prefix(3).reduce(0, +) > 30)
        #expect(pixels[0, 0].prefix(3).reduce(0, +) < 30)
    }
}
