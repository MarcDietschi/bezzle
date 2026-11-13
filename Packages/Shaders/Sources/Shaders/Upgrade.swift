import Foundation

/// A page's WebGL GLSL rewritten as the GLSL ES 3.10 glslang turns into SPIR-V, and the hooks
/// that keep WebGL's conventions when Metal draws it at any size and in tiles.
///
/// The rewriting works on tokens, so comments, the preprocessor and macros keep working:
/// - The version line becomes `#version 310 es`; `#line 1` keeps the page's line numbers in
///   the compiler's messages, and `__VERSION__` still reads 100 or 300.
/// - WebGL 1: `attribute` and `varying` become `in` and `out`, `gl_FragColor` and
///   `gl_FragData` declared outputs, `texture2D` and its kin `texture`, `textureLod`, ...;
///   extension lines for what ES 3.10 has built in are dropped.
/// - Names the page could use for its own things in its version but ES 3.10 keeps for itself
///   (`texture`, `sample`, `round`, `buffer`, ...) are renamed, and named back in reflection.
/// - lowp and mediump become highp: Metal computes in 32 bits anyway, and uniforms of one name
///   must agree across the stages.
/// - The page's `main` is called from one of Bezzle's, which maps `gl_Position` from the
///   drawing buffer's clip space onto the output (`bezzle_clip`), scales `gl_PointSize`, and
///   gives the fragment stage `gl_FragCoord` in drawing-buffer pixels from the bottom left
///   (`bezzle_fragCoord`). `dFdy` is turned round, since Metal's y runs down.
/// - A depth written (`gl_FragDepth`, `gl_FragDepthEXT`) goes to a plain variable: no depth
///   buffer is kept, and Metal will not build a shader that writes depth without one.
/// - Globals may start from uniforms and other globals, as browsers allow in WebGL 1.
enum Upgrade {
    struct Result {
        var source: String
        /// Names in `source` that the page wrote otherwise, to its own.
        var original: [String: String]
        var webGL2: Bool
    }

    /// What the page's names that ES 3.10 keeps for itself are given before them.
    static let ownPrefix = "bezzle_"
    /// Uniforms Bezzle adds, never shown as the page's.
    static let ownUniforms: Set<String> = ["bezzle_clip", "bezzle_fragCoord", "bezzle_pointScale"]

    static func upgrade(_ text: String, stage: ShaderStage) -> Result {
        let bytes = Array(text.utf8)
        // Pass one: the version and which words appear.
        var version = 100
        var words = Set<String>()
        var drawBuffers = false
        scan(bytes) { token in
            switch token {
            case .version(let number, _): version = number
            case .identifier(let word): words.insert(word)
            case .directive(let name, let body):
                if name == "extension", body.contains("GL_EXT_draw_buffers") { drawBuffers = true }
            default: break
            }
        }
        let webGL2 = version >= 300
        let fragment = stage == .fragment

        var renames: [String: String] = [:]
        var original: [String: String] = [:]
        for word in (webGL2 ? newSince300 : newSince100) where words.contains(word) {
            renames[word] = ownPrefix + word
            original[ownPrefix + word] = word
        }
        renames["lowp"] = "highp"
        renames["mediump"] = "highp"
        renames["__VERSION__"] = String(version)
        if !webGL2 {
            if fragment {
                renames["varying"] = "in"
                renames["gl_FragColor"] = "bezzle_FragColor"
                renames["gl_FragData"] = "bezzle_FragData"
                renames["gl_FragDepthEXT"] = "bezzle_FragDepth"
            } else {
                renames["attribute"] = "in"
                renames["varying"] = "out"
            }
            for (old, new) in textureFunctions { renames[old] = new }
        }
        // No depth buffer is kept, so a depth written goes nowhere, as with WebGL's depth test off.
        let fragDepth = fragment && (words.contains("gl_FragDepth") || (!webGL2 && words.contains("gl_FragDepthEXT")))
        if fragDepth { renames["gl_FragDepth"] = "bezzle_FragDepth" }
        let fragCoord = fragment && words.contains("gl_FragCoord")
        let wraps = !fragment || fragCoord
        if fragCoord { renames["gl_FragCoord"] = "bezzle_FragCoord" }
        if fragment && words.contains("dFdy") { renames["dFdy"] = "bezzle_dFdy" }
        if wraps { renames["main"] = "bezzle_main" }

        // Pass two: the rewritten body.
        var body = [UInt8]()
        body.reserveCapacity(bytes.count + 256)
        scan(bytes) { token in
            switch token {
            case .text(let text): body.append(contentsOf: text)
            case .identifier(let word): body.append(contentsOf: Array((renames[word] ?? word).utf8))
            case .version(_, let lines), .dropped(let lines):
                body.append(contentsOf: [UInt8](repeating: 0x0A, count: lines))
            case .directive: break
            }
        } directive: { name, line in
            name == "extension" && droppedExtensions.contains(where: { line.contains($0) })
        }

        // Browsers take globals set from uniforms or other globals in WebGL 1 (ANGLE warns of it);
        // glslang does with this extension.
        var header = """
            #version 310 es
            #extension GL_EXT_shader_non_constant_global_initializers : enable
            precision highp float;
            precision highp int;

            """
        var footer = "\n"
        if fragment {
            if fragCoord {
                header += "uniform highp vec4 bezzle_fragCoord;\nhighp vec4 bezzle_FragCoord;\n"
            }
            if fragDepth {
                header += "highp float bezzle_FragDepth;\n"
            }
            if !webGL2 && words.contains("gl_FragColor") {
                header += "layout(location = 0) out highp vec4 bezzle_FragColor;\n"
            }
            if !webGL2 && words.contains("gl_FragData") {
                header += "layout(location = 0) out highp vec4 bezzle_FragData[\(drawBuffers ? 4 : 1)];\n"
            }
            if words.contains("dFdy") {
                for type in ["float", "vec2", "vec3", "vec4"] {
                    header += "highp \(type) bezzle_dFdy(highp \(type) v) { return -dFdy(v); }\n"
                }
            }
            if fragCoord {
                footer += """
                    void main() {
                        bezzle_FragCoord = vec4(gl_FragCoord.xy * bezzle_fragCoord.xy + bezzle_fragCoord.zw, gl_FragCoord.zw);
                        bezzle_main();
                    }

                    """
            }
        } else {
            let pointSize = words.contains("gl_PointSize")
            header += "uniform highp vec4 bezzle_clip;\n"
            if pointSize { header += "uniform highp float bezzle_pointScale;\n" }
            footer += """
                void main() {
                    bezzle_main();
                    gl_Position.xy = gl_Position.xy * bezzle_clip.xy + bezzle_clip.zw * gl_Position.w;
                \(pointSize ? "    gl_PointSize *= bezzle_pointScale;\n" : "")}

                """
        }
        header += "#line 1\n"
        let source = header + String(decoding: body, as: UTF8.self) + footer
        return Result(source: source, original: original, webGL2: webGL2)
    }

    /// A name as the page wrote it: each word of `u_lights[1].bezzle_sample` put back.
    static func pageName(_ name: String, _ original: [String: String]) -> String {
        guard !original.isEmpty else { return name }
        var result = ""
        var word = ""
        for character in name {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                result += original[word] ?? word
                word = ""
                result.append(character)
            }
        }
        return result + (original[word] ?? word)
    }

    // MARK: Words

    /// WebGL 1's texture functions and those of its extensions, to ES 3's.
    static let textureFunctions: [String: String] = [
        "texture2D": "texture", "texture2DProj": "textureProj", "texture2DLod": "textureLod",
        "texture2DProjLod": "textureProjLod", "textureCube": "texture", "textureCubeLod": "textureLod",
        "texture2DLodEXT": "textureLod", "texture2DProjLodEXT": "textureProjLod", "textureCubeLodEXT": "textureLod",
        "texture2DGradEXT": "textureGrad", "texture2DProjGradEXT": "textureProjGrad", "textureCubeGradEXT": "textureGrad",
        "shadow2DEXT": "texture", "shadow2DProjEXT": "textureProj",
    ]

    /// Extensions whose functions ES 3.10 has built in, or which WebGL 1 shaders name and
    /// ES 3.10 no longer knows.
    static let droppedExtensions = [
        "GL_OES_standard_derivatives", "GL_EXT_shader_texture_lod", "GL_EXT_frag_depth", "GL_EXT_draw_buffers",
        "GL_EXT_shadow_samplers",
    ]

    /// Free names in GLSL ES 1.00 that are keywords, reserved or built-in functions in ES 3.10.
    /// Found by asking glslang (see the package's tests), without vendors' extensions.
    static let newSince100: Set<String> = Set("""
        absoluteDifference acosh addSaturate asinh atanh atomicAdd atomicAnd atomicCompSwap atomicCounter
        atomicCounterDecrement atomicCounterIncrement atomicExchange atomicLoad atomicMax atomicMin atomicOr atomicStore
        atomicXor atomic_uint average averageRounded barrier bitCount bitfieldExtract bitfieldInsert bitfieldReverse buffer
        centroid coherent controlBarrier controlBarrierArrive controlBarrierWait cosh countLeadingZeros
        countTrailingZeros determinant devicecoherent dmat2 dmat2x2 dmat2x3 dmat2x4 dmat3 dmat3x2 dmat3x3 dmat3x4 dmat4
        dmat4x2 dmat4x3 dmat4x4 findLSB findMSB floatBitsToInt floatBitsToUint fma frexp groupMemoryBarrier iimage1D
        iimage1DArray iimage2D iimage2DArray iimage2DMS iimage2DMSArray iimage2DRect iimage3D iimageBuffer iimageCube
        iimageCubeArray image1D image1DArray image2D image2DArray image2DMS image2DMSArray image2DRect image3D
        imageAtomicAdd imageAtomicAnd imageAtomicCompSwap imageAtomicExchange imageAtomicLoad imageAtomicMax
        imageAtomicMin imageAtomicOr imageAtomicStore imageAtomicXor imageBuffer imageCube imageCubeArray imageLoad
        imageSize imageStore imulExtended intBitsToFloat interpolateAtCentroid interpolateAtOffset interpolateAtSample
        inverse isampler1D isampler1DArray isampler2D isampler2DArray isampler2DMS isampler2DMSArray isampler2DRect
        isampler3D isamplerBuffer isamplerCube isinf isnan layout ldexp mat2x2 mat2x3 mat2x4 mat3x2 mat3x3 mat3x4 mat4x2
        mat4x3 mat4x4 memoryBarrier memoryBarrierAtomicCounter memoryBarrierBuffer memoryBarrierImage
        memoryBarrierShared modf multiply32x16 nonprivate noperspective outerProduct pack16 pack32 pack64 packFloat2x16
        packHalf2x16 packInt2x16 packInt2x32 packInt4x16 packSnorm2x16 packSnorm4x8 packUint2x16 packUint2x32
        packUint4x16 packUnorm2x16 packUnorm4x8 patch precise queuefamilycoherent readonly resource restrict round
        roundEven sample sampler1DArray sampler1DArrayShadow sampler2DArray sampler2DArrayShadow sampler2DMS
        sampler2DMSArray samplerBuffer samplerCubeShadow shadercallcoherent shared sinh smooth subroutine
        subtractSaturate tanh texelFetch texelFetchOffset texture textureGather textureGatherOffset textureGatherOffsets
        textureGrad textureGradOffset textureLod textureLodOffset textureOffset textureProj textureProjGrad
        textureProjGradOffset textureProjLod textureProjLodOffset textureProjOffset textureSize transpose trunc uaddCarry
        uimage1D uimage1DArray uimage2D uimage2DArray uimage2DMS uimage2DMSArray uimage2DRect uimage3D uimageBuffer
        uimageCube uimageCubeArray uint uintBitsToFloat umulExtended unpack16 unpack32 unpack8 unpackFloat2x16
        unpackHalf2x16 unpackInt2x16 unpackInt2x32 unpackInt4x16 unpackSnorm2x16 unpackSnorm4x8 unpackUint2x16
        unpackUint2x32 unpackUint4x16 unpackUnorm2x16 unpackUnorm4x8 usampler1D usampler1DArray usampler2D
        usampler2DArray usampler2DMS usampler2DMSArray usampler2DRect usampler3D usamplerBuffer usamplerCube usubBorrow
        uvec2 uvec3 uvec4 workgroupcoherent writeonly
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Free names in GLSL ES 3.00 that ES 3.10 keeps for itself.
    static let newSince300: Set<String> = Set("""
        absoluteDifference addSaturate atomicAdd atomicAnd atomicCompSwap atomicCounter atomicCounterDecrement
        atomicCounterIncrement atomicExchange atomicLoad atomicMax atomicMin atomicOr atomicStore atomicXor average
        averageRounded barrier bitCount bitfieldExtract bitfieldInsert bitfieldReverse buffer controlBarrier
        controlBarrierArrive controlBarrierWait findLSB findMSB fma frexp groupMemoryBarrier iimage2DMS iimage2DMSArray
        iimageCubeArray image2DMS image2DMSArray imageAtomicAdd imageAtomicAnd imageAtomicCompSwap imageAtomicExchange
        imageAtomicLoad imageAtomicMax imageAtomicMin imageAtomicOr imageAtomicStore imageAtomicXor imageCubeArray
        imageLoad imageSize imageStore imulExtended interpolateAtCentroid interpolateAtOffset interpolateAtSample ldexp
        memoryBarrier memoryBarrierAtomicCounter memoryBarrierBuffer memoryBarrierImage memoryBarrierShared
        multiply32x16 pack16 pack32 pack64 packFloat2x16 packInt2x16 packInt2x32 packInt4x16 packSnorm4x8 packUint2x16
        packUint2x32 packUint4x16 packUnorm4x8 precise subtractSaturate textureGather textureGatherOffset
        textureGatherOffsets uaddCarry uimage2DMS uimage2DMSArray uimageCubeArray umulExtended unpack16 unpack32 unpack8
        unpackFloat2x16 unpackInt2x16 unpackInt2x32 unpackInt4x16 unpackSnorm4x8 unpackUint2x16 unpackUint2x32
        unpackUint4x16 unpackUnorm4x8 usubBorrow
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
