import CoreGraphics
import Foundation
import Testing
@testable import Shaders

/// How long translating and drawing take; prints what it measures (README.md has the numbers).
@Suite(.serialized) struct MeasureTests {
    @Test func translationAndDrawing() throws {
        // A renderer of its own and a uniform no other run has, so nothing is kept from before.
        let fresh = ShaderRenderer(device: renderer.device)!
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
            lines.append(String(format: "%@: GLSL to MSL %.1f ms, Metal %.1f ms, together %.1f ms", name,
                                program.translationTime * 1000, program.buildTime * 1000, total * 1000))
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
}
