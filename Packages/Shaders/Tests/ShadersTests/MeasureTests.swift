#if !os(Windows)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import Shaders

/// How long translating and drawing take; prints what it measures (README.md has the numbers).
@Suite(.serialized) struct MeasureTests {
    @Test func translationAndDrawing() throws {
        // A renderer of its own and a uniform no other run has, so nothing is kept from before.
        #if os(Windows)
        let fresh = ShaderRenderer()!
        let (language, compiler) = ("HLSL", "Direct3D (\(fresh.adapter))")
        #else
        let fresh = ShaderRenderer(device: renderer.device)!
        let (language, compiler) = ("MSL", "Metal")
        #endif
        let unique = "uniform float u_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""));\n"
        var lines: [String] = []
        // glslang's tables are made once in a process, at its first program.
        let first = Date()
        _ = try Program(device: fresh.device, vertex: ShaderDraw.fullSurfaceVertex,
                        fragment: "precision mediump float; \(unique) void main() { gl_FragColor = vec4(1.0); }")
        lines.append(String(format: "the first program in a process: %.1f ms", Date().timeIntervalSince(first) * 1000))
        for (name, vertex, fragment) in [
            ("gradient mesh", unique + RealWorldTests.meshVertex, RealWorldTests.meshFragment),
            ("film grain", ShaderDraw.fullSurfaceVertex, RealWorldTests.grain.replacingOccurrences(of: "uniform float u_time;", with: "uniform float u_time;\n" + unique)),
            ("shadertoy", ShaderDraw.fullSurfaceVertex, RealWorldTests.shadertoy.replacingOccurrences(of: "uniform float iTime;", with: "uniform float iTime;\n" + unique)),
        ] {
            let start = Date()
            let program = try Program(device: fresh.device, vertex: vertex, fragment: fragment)
            let total = Date().timeIntervalSince(start)
            lines.append(String(format: "%@: GLSL to %@ %.1f ms, %@ %.1f ms, together %.1f ms", name, language,
                                program.translationTime * 1000, compiler, program.buildTime * 1000, total * 1000))
        }

        func time(_ label: String, _ frame: ShaderFrame, scale: Double) throws {
            let pixels = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
            _ = try fresh.image(of: frame, pixels: pixels) // translated, built and uploaded once
            let runs = 10
            let start = Date()
            for _ in 0..<runs { _ = try fresh.image(of: frame, pixels: pixels) }
            let each = Date().timeIntervalSince(start) / Double(runs)
            lines.append(String(format: "%@ at %.0f by %.0f: %.1f ms a frame", label, pixels.width, pixels.height, each * 1000))
        }
        try time("gradient mesh (2,400 triangles)", RealWorldTests.meshFrame(time: 1), scale: 1)
        try time("gradient mesh (2,400 triangles)", RealWorldTests.meshFrame(time: 1), scale: 2)
        var grain = frame(1440, 900, RealWorldTests.grain, uniforms: ["u_time": [1]])
        try time("film grain", grain, scale: 1)
        grain.antialias = false
        try time("film grain without antialias", grain, scale: 1)
        let shadertoy = frame(1440, 900, RealWorldTests.shadertoy, uniforms: ["iResolution": [1440, 900, 1], "iTime": [1]])
        try time("shadertoy", shadertoy, scale: 1)
        print(lines.map { "MEASURED " + $0 }.joined(separator: "\n"))
    }

    /// Passes into textures: a chain within a frame, and the steps a frame that builds on the
    /// frames before it is drawn through.
    @Test(.enabled(if: drawsPasses)) func passesAndSteps() throws {
        var lines: [String] = []
        // Grain into a texture, then twice from texture to texture, then onto the canvas.
        let copy = """
            precision highp float;
            uniform sampler2D u_from;
            uniform vec2 u_resolution;
            void main() {
                vec2 uv = gl_FragCoord.xy / u_resolution;
                gl_FragColor = (texture2D(u_from, uv) + texture2D(u_from, uv + 1.5 / u_resolution)) * 0.5;
            }
            """
        func through(_ from: Int) -> ShaderDraw {
            var draw = ShaderDraw.fullSurface(fragment: copy, uniforms: ["u_resolution": [1440, 900]])
            draw.targets["u_from"] = from
            return draw
        }
        var chain = ShaderFrame(size: CGSize(width: 1440, height: 900), draws: [], antialias: false)
        chain.targets = [ShaderTarget(width: 1440, height: 900, scales: true), ShaderTarget(width: 1440, height: 900, scales: true)]
        chain.passes = [
            ShaderPass(colors: [0], clearColor: [0, 0, 0, 0],
                       draws: [ShaderDraw.fullSurface(fragment: RealWorldTests.grain, uniforms: ["u_time": [1], "u_resolution": [1440, 900]])]),
            ShaderPass(colors: [1], clearColor: [0, 0, 0, 0], draws: [through(0)]),
            ShaderPass(colors: [0], clearColor: [0, 0, 0, 0], draws: [through(1)]),
            ShaderPass(clearColor: [0, 0, 0, 0], draws: [through(0)]),
        ]
        for scale in [1.0, 2.0] {
            let pixels = CGSize(width: 1440 * scale, height: 900 * scale)
            _ = try renderer.image(of: chain, pixels: pixels)
            let start = Date()
            for _ in 0..<10 { _ = try renderer.image(of: chain, pixels: pixels) }
            lines.append(String(format: "three passes into textures and one onto the canvas at %.0f by %.0f: %.1f ms a frame",
                                pixels.width, pixels.height, Date().timeIntervalSince(start) / 10 * 1000))
        }
        // A simulation's two float textures of 512 by 512, each step reading one into the other.
        let recording = Int.random(in: 1_000_000..<2_000_000)
        func step(_ k: Int) -> ShaderFrame {
            let grow = """
                precision highp float;
                uniform sampler2D u_before;
                void main() {
                    vec2 uv = gl_FragCoord.xy / 512.0;
                    vec4 around = texture2D(u_before, uv + vec2(1.0 / 512.0, 0.0)) + texture2D(u_before, uv - vec2(1.0 / 512.0, 0.0))
                        + texture2D(u_before, uv + vec2(0.0, 1.0 / 512.0)) + texture2D(u_before, uv - vec2(0.0, 1.0 / 512.0));
                    gl_FragColor = mix(texture2D(u_before, uv), around * 0.25, 0.5) + vec4(0.001);
                }
                """
            var draw = ShaderDraw.fullSurface(fragment: grow)
            draw.targets["u_before"] = k % 2
            var frame = ShaderFrame(size: CGSize(width: 512, height: 512), draws: [], antialias: false)
            frame.targets = [ShaderTarget(width: 512, height: 512, format: .rgba16Float, keeps: true),
                             ShaderTarget(width: 512, height: 512, format: .rgba16Float, keeps: true)]
            frame.passes = [ShaderPass(colors: [1 - k % 2], draws: [draw]),
                            ShaderPass(clearColor: [0, 0, 0, 1], draws: [TargetsTests.showing(1 - k % 2, 512, 512)])]
            frame.identity = .init(recording: recording, moment: k)
            return frame
        }
        func time(_ label: String, _ k: Int) throws {
            let start = Date()
            _ = try renderer.image(of: step(k), pixels: CGSize(width: 512, height: 512), earlier: step)
            lines.append(String(format: "%@: %.1f ms", label, Date().timeIntervalSince(start) * 1000))
        }
        _ = try renderer.image(of: step(0), pixels: CGSize(width: 512, height: 512), earlier: step) // built once
        try time("the next step of a simulation in two 512 by 512 float textures", 1)
        try time("300 steps on, drawn through from where it was", 301)
        try time("gone back to step 290: from the state kept at 288", 290)
        try time("gone back one step, to 289", 289)
        try time("the same step again", 289)
        print(lines.map { "MEASURED " + $0 }.joined(separator: "\n"))
    }
}
