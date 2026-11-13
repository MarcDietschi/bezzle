#if !os(Windows)
import CoreGraphics
#endif
import Foundation
import Testing
import ShaderCompiler
@testable import Shaders

/// GLSL as pages write it: the preprocessor, the language, and names ES 3.10 took for itself.
@Suite struct LanguageTests {
    @Test func preprocessorAndLanguageWebGL1() throws {
        let fragment = """
            #ifdef GL_ES
            precision mediump float;
            #endif
            #define PI 3.14159265
            #define SCALE(x, k) ((x) * (k))
            #define HALF(x) SCALE(x, 0.5)
            #if __VERSION__ < 300
            #define WEBGL1 1
            #endif

            struct Ring { float inner; float outer; };

            // Overloads.
            float weight(float x) { return x * 2.0; }
            float weight(vec2 v) { return v.x + v.y; }

            float sum(Ring r) {
                float total = 0.0;
                for (int i = 0; i < 4; i++) {
                    total += r.inner;
                    if (i == 2) { break; }
                }
                return total + r.outer;
            }

            void main() {
                float a = mod(-1.5, 1.0);                      // GLSL: 0.5, not -0.5
                float b = atan(1.0, -1.0) / PI;                // 0.75
                Ring ring = Ring(0.05, 0.1);
                float c = HALF(sum(ring)) + weight(vec2(0.0, 0.0)) + weight(0.0);  // 0.125
            #ifdef WEBGL1
                gl_FragColor = vec4(a, b, c, 1.0);
            #else
                gl_FragColor = vec4(0.0);
            #endif
            }
            """
        let pixels = try draw(frame(8, 8, fragment))
        #expect(near(pixels[4, 4], [128, 191, 32, 255], within: 1))
    }

    @Test func languageWebGL2() throws {
        let fragment = """
            #version 300 es
            precision highp float;
            precision highp int;
            out vec4 color;
            const vec3 palette[3] = vec3[3](vec3(1.0, 0.0, 0.0), vec3(0.0, 0.5, 0.0), vec3(0.0, 0.0, 0.25));
            struct Mix { vec3 tint; float amount; };
            vec3 blend(Mix m, vec3 base) { return mix(base, m.tint, m.amount); }
            void main() {
                vec3 sum = vec3(0.0);
                for (int i = 0; i < palette.length(); ++i) { sum += palette[i]; }
                int k = 7 % 3;                                  // ints, ES 3 only
                uint bits = uint(k) << 1u;                      // 2
                Mix m = Mix(vec3(1.0), 0.0);
                color = vec4(blend(m, sum) * float(bits) * 0.5, 1.0);
            }
            """
        let pixels = try draw(frame(8, 8, fragment))
        #expect(near(pixels[4, 4], [255, 128, 64, 255], within: 1))
    }

    @Test func namesES3TookForItselfStillWork() throws {
        // WebGL 1 pages use these freely; ES 3.10 has them as keywords or built-ins.
        let fragment = """
            precision mediump float;
            uniform sampler2D texture;
            uniform float sample;
            varying vec2 v_uv;
            float round(float x) { return floor(x + 0.5); }
            float tanh(float x) { float e = exp(2.0 * x); return (e - 1.0) / (e + 1.0); }
            void main() {
                vec4 smooth = texture2D(texture, vec2(0.5));
                float layout = round(sample * 10.0) / 10.0;     // 0.3
                gl_FragColor = vec4(smooth.r, layout, tanh(0.0), 1.0);
            }
            """
        let vertex = """
            attribute vec2 a_position;
            varying vec2 v_uv;
            void main() { v_uv = a_position; gl_Position = vec4(a_position, 0.0, 1.0); }
            """
        let interface = try renderer.interface(of: vertex, fragment)
        #expect(interface.uniforms.contains(ShaderUniform(name: "texture", type: .sampler2D)))
        #expect(interface.uniforms.contains(ShaderUniform(name: "sample", type: .float)))
        let white = picture(1, 1, [255, 255, 255, 255])
        let draw = ShaderDraw(vertex: vertex, fragment: fragment, uniforms: ["sample": [0.31]],
                              attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6,
                              textures: ["texture": white])
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [255, 77, 0, 255], within: 1))
    }

    /// Every word in the lists, used by a WebGL page for its own things, translates.
    @Test(arguments: [100, 300])
    func everyRenamedWordTranslates(version: Int) throws {
        let words = version == 100 ? Upgrade.newSince100 : Upgrade.newSince300
        var failed: [String] = []
        for word in words.sorted() {
            let header = version == 100 ? "precision mediump float;\n" : "#version 300 es\nprecision mediump float;\nout vec4 o;\n"
            let output = version == 100 ? "gl_FragColor" : "o"
            let fragment = header + """
                uniform float \(word);
                float twice(float \(word)) { return \(word) * 2.0; }
                void main() { float x = twice(\(word)); \(output) = vec4(x); }
                """
            let vertex = version == 100
                ? "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"
                : "#version 300 es\nin vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"
            #if os(Windows)
            let upgradedVertex = Upgrade.upgrade(vertex, stage: .vertex, sprites: .init(coordinates: false)).source
            let upgraded = Upgrade.upgrade(fragment, stage: .fragment, sprites: .init(coordinates: false))
            var translation = BZHLSLTranslation()
            let ok = bz_translate_hlsl(upgradedVertex, upgraded.source, &translation)
            let reflection = translation.reflection.map { String(cString: $0) } ?? ""
            bz_hlsl_translation_free(&translation)
            #else
            let upgradedVertex = Upgrade.upgrade(vertex, stage: .vertex).source
            let upgraded = Upgrade.upgrade(fragment, stage: .fragment)
            var translation = BZTranslation()
            let ok = bz_translate(upgradedVertex, upgraded.source, &translation)
            let reflection = translation.reflection.map { String(cString: $0) } ?? ""
            bz_translation_free(&translation)
            #endif
            if ok != 1 || !reflection.contains("\"bezzle_\(word)\"") { failed.append(word) }
        }
        #expect(failed.isEmpty, "\(failed)")
    }

    /// Names a page is free to give its own things that HLSL or the Metal Shading Language keep
    /// for themselves still draw: SPIRV-Cross renames them in what it writes.
    @Test func namesTheBackEndsKeepStillWork() throws {
        let vertex = """
            attribute vec2 point;
            varying vec2 line;
            varying float groupshared;
            void main() { line = point * 0.5 + 0.5; groupshared = 0.5; gl_Position = vec4(point, 0.0, 1.0); }
            """
        let fragment = """
            precision mediump float;
            varying vec2 line;
            varying float groupshared;
            uniform float matrix;
            uniform vec2 vector;
            uniform float cbuffer;
            uniform float register;
            float linear(float string) { return string * matrix; }
            float device(float constant) { return constant + cbuffer + register; }
            void main() { gl_FragColor = vec4(linear(line.x), groupshared, device(vector.y), 1.0); }
            """
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              uniforms: ["matrix": [1], "vector": [0, 0.25], "cbuffer": [0.25], "register": [0.25]],
                              attributes: ["point": ShaderDraw.fullSurfacePositions], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [159, 128, 191, 255], within: 2), "\(pixels[2, 2])")
        let interface = try renderer.interface(of: vertex, fragment)
        #expect(Set(interface.uniforms.map(\.name)) == ["matrix", "vector", "cbuffer", "register"])
        #expect(interface.attributes.map(\.name) == ["point"])

        // Every word on the list, as a varying, a parameter and a variable; as a uniform, keeping its
        // value; as a function.
        var failed: [String] = []
        for word in Upgrade.keptByTheBackEnds.sorted() {
            let plain = "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"
            let programs = [
                ("attribute vec2 p; varying float \(word); void main() { \(word) = 0.5; gl_Position = vec4(p, 0.0, 1.0); }",
                 "precision mediump float; varying float \(word); float f(float \(word)) { return \(word) * 1.0; }"
                     + " void main() { float c = f(\(word)); { float \(word) = c; gl_FragColor = vec4(\(word)); } }"),
                (plain, "precision mediump float; uniform float \(word); void main() { gl_FragColor = vec4(\(word)); }"),
                (plain, "precision mediump float; uniform float u; float \(word)(float x) { return x * 2.0; }"
                     + " void main() { gl_FragColor = vec4(\(word)(u)); }"),
            ]
            for (vertex, fragment) in programs {
                // Each draws 0.5 everywhere: the varying, the uniform, or 0.25 twice.
                let draw = ShaderDraw(vertex: vertex, fragment: fragment, uniforms: [word: [0.5], "u": [0.25]],
                                      attributes: ["p": ShaderDraw.fullSurfacePositions], count: 6)
                let pixels = try? Shaders_draw(ShaderFrame(size: CGSize(width: 2, height: 2), draws: [draw]))
                if pixels.map({ !near($0[1, 1], [128, 128, 128, 128], within: 1) }) ?? true { failed.append(word) }
            }
        }
        #expect(failed.isEmpty, "\(failed)")
    }

    /// How the lists were found: glslang parses a shader at the version it declares. A word is
    /// listed when a page may declare it in its own version and ES 3.10 refuses that.
    @Test func howTheListsWereFound() {
        func parses(_ source: String) -> Bool { bz_parses(source, 1, nil) == 1 }
        func declared(_ word: String, _ header: String) -> Bool {
            parses(header + "float \(word);\nfloat f(float \(word)) { return \(word); }\nvoid main() { }\n")
        }
        let es100 = "#version 100\nprecision mediump float;\n", es300 = "#version 300 es\nprecision mediump float;\n"
        let es310 = "#version 310 es\nprecision mediump float;\n"
        for word in ["sample", "texture", "round", "uint", "layout"] {
            #expect(declared(word, es100) && !declared(word, es310), "\(word)")
            #expect(Upgrade.newSince100.contains(word))
        }
        #expect(declared("buffer", es300) && !declared("buffer", es310))
        #expect(Upgrade.newSince300.contains("buffer"))
        #expect(declared("u_time", es100) && declared("u_time", es310))
    }

    /// No word WebGL 1 has built in is renamed: the lists hold only names a page is free to use.
    @Test func builtInsAreNotRenamed() {
        let es100 = """
            radians degrees sin cos tan asin acos atan pow exp log exp2 log2 sqrt inversesqrt abs sign floor ceil fract
            mod min max clamp mix step smoothstep length distance dot cross normalize faceforward reflect refract
            matrixCompMult lessThan lessThanEqual greaterThan greaterThanEqual equal notEqual any all not texture2D
            texture2DProj texture2DLod texture2DProjLod textureCube textureCubeLod dFdx dFdy fwidth main
            """.split(whereSeparator: \.isWhitespace).map(String.init)
        let es300 = es100 + """
            sinh cosh tanh asinh acosh atanh trunc round roundEven modf isnan isinf floatBitsToInt floatBitsToUint
            intBitsToFloat uintBitsToFloat packSnorm2x16 unpackSnorm2x16 packUnorm2x16 unpackUnorm2x16 packHalf2x16
            unpackHalf2x16 outerProduct transpose determinant inverse textureSize texture textureProj textureLod
            textureOffset texelFetch texelFetchOffset textureProjOffset textureLodOffset textureProjLod
            textureProjLodOffset textureGrad textureGradOffset textureProjGrad textureProjGradOffset
            """.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(Upgrade.newSince100.isDisjoint(with: es100))
        #expect(Upgrade.newSince300.isDisjoint(with: es300))
        #expect(Upgrade.keptByTheBackEnds.isDisjoint(with: es300))
    }

    @Test func webGL1Extensions() throws {
        let image = picture(1, 1, [0, 0, 255, 255])
        let fragment = """
            #extension GL_EXT_shader_texture_lod : enable
            #extension GL_EXT_frag_depth : enable
            #extension GL_OES_standard_derivatives : enable
            #extension GL_EXT_draw_buffers : require
            precision mediump float;
            uniform sampler2D u_image;
            void main() {
            #ifdef GL_EXT_shader_texture_lod
                vec4 c = texture2DLodEXT(u_image, vec2(0.5), 0.0);
            #else
                vec4 c = vec4(0.0);
            #endif
                gl_FragDepthEXT = 0.5;
                gl_FragData[0] = vec4(fwidth(gl_FragCoord.x), 0.0, c.b, 1.0);
                gl_FragData[1] = vec4(1.0);
            }
            """
        let pixels = try draw(frame(4, 4, fragment, textures: ["u_image": image]))
        #expect(pixels[1, 1] == [255, 0, 255, 255])
    }

    @Test func webGL2UniformBlocksByTheirMembersNames() throws {
        let fragment = """
            #version 300 es
            precision highp float;
            uniform Look { vec4 tint; float gain; };
            uniform Extra { vec2 shift; } extra;
            uniform float u_loose;
            out vec4 color;
            void main() { color = vec4(tint.rgb * gain + vec3(extra.shift, u_loose), 1.0); }
            """
        let vertex = "#version 300 es\nin vec2 a_position;\nvoid main() { gl_Position = vec4(a_position, 0.0, 1.0); }"
        let interface = try renderer.interface(of: vertex, fragment)
        let names = Set(interface.uniforms.map(\.name))
        #expect(names.isSuperset(of: ["tint", "gain", "Extra.shift", "u_loose"]), "\(names)")
        let draw = ShaderDraw(vertex: vertex, fragment: fragment,
                              uniforms: ["tint": [1, 0, 0, 1], "gain": [0.5], "Extra.shift": [0.25, 0], "u_loose": [1]],
                              attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [191, 0, 255, 255], within: 1))
    }

    @Test func aCacheKeepsItsBudget() throws {
        let cache = OnceCache<Int, [UInt8]>(capacity: 10, budget: 100, cost: { $0.count })
        for key in 0..<5 { _ = try cache.value(key) { [UInt8](repeating: 0, count: 40) } }
        // Only the last two fit in the budget: asking for the first makes it again.
        var made = 0
        _ = try cache.value(0) { made += 1; return [] }
        _ = try cache.value(4) { made += 1; return [] }
        #expect(made == 1)
    }

    @Test func globalsStartingFromUniforms() throws {
        // Not constant, so not GLSL ES; browsers take it in WebGL 1 all the same.
        let fragment = """
            precision mediump float;
            uniform vec2 u_resolution;
            vec2 centre = u_resolution * 0.5;
            float shade = centre.x / u_resolution.x;
            void main() { gl_FragColor = vec4(shade, 0.0, 0.0, 1.0); }
            """
        let pixels = try draw(frame(4, 4, fragment))
        #expect(near(pixels[2, 2], [128, 0, 0, 255], within: 1))
    }

    @Test func samplerArrays() throws {
        let fragment = """
            precision mediump float;
            uniform sampler2D u_layers[2];
            void main() { gl_FragColor = texture2D(u_layers[0], vec2(0.5)) + texture2D(u_layers[1], vec2(0.5)); }
            """
        let interface = try renderer.interface(of: ShaderDraw.fullSurfaceVertex, fragment)
        #expect(interface.uniforms.contains(ShaderUniform(name: "u_layers", type: .sampler2D, count: 2)), "\(interface.uniforms)")
        let red = picture(1, 1, [255, 0, 0, 255]), blue = picture(1, 1, [0, 0, 255, 255])
        let pixels = try draw(frame(4, 4, fragment, textures: ["u_layers[0]": red, "u_layers[1]": blue]))
        #expect(pixels[2, 2] == [255, 0, 255, 255])
        let first = try draw(frame(4, 4, fragment, textures: ["u_layers": red]))
        #expect(first[2, 2] == [255, 0, 0, 255])
    }

    @Test func varyingsTheOtherStageLeavesOut() throws {
        // WebGL links these: a varying only the vertex shader writes, one only the fragment
        // shader declares and never reads.
        let vertex = """
            attribute vec2 a_position;
            varying vec2 v_extra;
            varying float v_shade;
            void main() { v_extra = a_position; v_shade = 0.5; gl_Position = vec4(a_position, 0.0, 1.0); }
            """
        let fragment = """
            precision mediump float;
            varying float v_shade;
            varying vec3 v_declaredOnly;
            void main() { gl_FragColor = vec4(v_shade, 0.0, 0.0, 1.0); }
            """
        let draw = ShaderDraw(vertex: vertex, fragment: fragment, attributes: ["a_position": ShaderDraw.fullSurfacePositions], count: 6)
        let pixels = try Shaders_draw(ShaderFrame(size: CGSize(width: 4, height: 4), draws: [draw]))
        #expect(near(pixels[2, 2], [128, 0, 0, 255], within: 1))
    }

    @Test func cubeMapsFromStackedFaces() throws {
        // Faces +X, -X, +Y, -Y, +Z, -Z stacked: red, green, blue, yellow, white, grey.
        let faces: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255],
                                [255, 255, 255, 255], [128, 128, 128, 255]]
        let image = picture(1, 6, faces.flatMap { $0 })
        let fragment = """
            precision mediump float;
            uniform samplerCube u_sky;
            void main() {
                float i = floor(gl_FragCoord.x);
                vec3 d = i < 1.0 ? vec3(1, 0, 0) : i < 2.0 ? vec3(-1, 0, 0) : i < 3.0 ? vec3(0, 1, 0)
                       : i < 4.0 ? vec3(0, -1, 0) : i < 5.0 ? vec3(0, 0, 1) : vec3(0, 0, -1);
                gl_FragColor = textureCube(u_sky, d);
            }
            """
        let pixels = try draw(frame(6, 1, fragment, textures: ["u_sky": image]))
        for (i, face) in faces.enumerated() {
            #expect(pixels[i, 0] == face.map(Int.init), "face \(i)")
        }
    }

    @Test func aShaderThatDoesNotCompileSaysWhy() {
        let fragment = """
            precision mediump float;
            void main() {
                gl_FragColor = vec4(1.0) +;
            }
            """
        do {
            _ = try renderer.interface(of: ShaderDraw.fullSurfaceVertex, fragment)
            Issue.record("It compiled.")
        } catch let error as ShaderError {
            #expect(error.description.contains("fragment:3"), "\(error.description)")
            #expect(error.description.contains("syntax error"), "\(error.description)")
        } catch {
            Issue.record("Another error: \(error)")
        }
        let frame = ShaderFrame(size: CGSize(width: 4, height: 4), draws: [ShaderDraw.fullSurface(fragment: fragment)])
        #expect(throws: ShaderError.self) { try renderer.check(frame) }
        #expect(throws: ShaderError.self) { _ = try renderer.image(of: frame, pixels: CGSize(width: 4, height: 4)) }
    }

    @Test func linesKeepTheirNumbers() throws {
        let vertex = "\n\n\nattribute vec2 a_position;\nvoid main() { gl_Position = vec4(a_position, 0.0, 1.0) + undefinedThing; }\n"
        do {
            _ = try renderer.interface(of: vertex, "precision mediump float; void main() { gl_FragColor = vec4(1.0); }")
            Issue.record("It compiled.")
        } catch let error as ShaderError {
            #expect(error.description.contains("vertex:5"), "\(error.description)")
        }
    }

    @Test func interfaceAsWebGLNamesIt() throws {
        let vertex = """
            attribute vec3 a_position;
            attribute vec2 a_uv;
            uniform mat4 u_matrix;
            varying vec2 v_uv;
            void main() { v_uv = a_uv; gl_Position = u_matrix * vec4(a_position, 1.0); }
            """
        let fragment = """
            precision mediump float;
            struct Light { vec3 color; float power; };
            uniform Light u_light;
            uniform vec3 u_colors[4];
            uniform bool u_on;
            uniform int u_count;
            uniform samplerCube u_sky;
            uniform float u_unused;
            varying vec2 v_uv;
            void main() {
                vec3 c = u_colors[u_count] * u_light.color * u_light.power + textureCube(u_sky, vec3(v_uv, 1.0)).rgb;
                gl_FragColor = vec4(u_on ? c : vec3(0.0), 1.0);
            }
            """
        let interface = try renderer.interface(of: vertex, fragment)
        let uniforms = Dictionary(uniqueKeysWithValues: interface.uniforms.map { ($0.name, $0) })
        #expect(uniforms["u_matrix"] == ShaderUniform(name: "u_matrix", type: .mat4))
        #expect(uniforms["u_colors"] == ShaderUniform(name: "u_colors", type: .vec3, count: 4))
        #expect(uniforms["u_light.color"]?.type == .vec3)
        #expect(uniforms["u_light.power"]?.type == .float)
        #expect(uniforms["u_on"]?.type == .bool)
        #expect(uniforms["u_count"]?.type == .int)
        #expect(uniforms["u_sky"]?.type == .samplerCube)
        #expect(uniforms["u_unused"] == nil)  // inactive, as WebGL leaves it out
        #expect(uniforms.keys.allSatisfy { !$0.hasPrefix("bezzle") })
        #expect(Set(interface.attributes.map(\.name)) == ["a_position", "a_uv"])
        #expect(interface.attributes.first { $0.name == "a_position" }?.type == .vec3)
    }
}
