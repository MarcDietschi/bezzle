import Testing
import AppKit
@testable import Bezzle

/// WebGL canvases brought in live: what a page's shaders draw recorded as it runs (WebPageGL.js),
/// kept as a shader fill on the canvas's picture, and its time found in the numbers that grow.
@MainActor
@Suite(.serialized)
struct ShaderImportTests {
    /// A full-surface gradient that moves with time, drawn on a timer as some pages do.
    static let gradient = """
    <canvas id="c" width="320" height="200" style="width: 320px; height: 200px; display: block"></canvas>
    <script>
    const c = document.getElementById('c'), gl = c.getContext('webgl');
    const vs = 'attribute vec2 a_position; void main() { gl_Position = vec4(a_position, 0.0, 1.0); }';
    const fs = 'precision mediump float; uniform vec2 u_resolution; uniform float u_time; uniform vec3 u_colors[2];' +
      'void main() { vec2 p = gl_FragCoord.xy / u_resolution; float t = 0.5 + 0.5 * sin(u_time + p.x * 3.0);' +
      ' gl_FragColor = vec4(mix(u_colors[0], u_colors[1], t * p.y), 1.0); }';
    function shader(type, src) { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; }
    const p = gl.createProgram();
    gl.attachShader(p, shader(gl.VERTEX_SHADER, vs)); gl.attachShader(p, shader(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
    const b = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(p, 'a_position');
    const res = gl.getUniformLocation(p, 'u_resolution'), time = gl.getUniformLocation(p, 'u_time'), colors = gl.getUniformLocation(p, 'u_colors');
    const start = performance.now();
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(p);
      gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      gl.uniform2f(res, c.width, c.height);
      gl.uniform1f(time, 5 + (performance.now() - start) / 1000 * 0.5);
      gl.uniform3fv(colors, [1, 0.2, 0.4, 0.1, 0.3, 1]);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }
    frame();
    setInterval(frame, 40);
    </script>
    """

    @Test(.timeLimit(.minutes(5))) func keepsAWebGLCanvasLiveWithItsTime() async throws {
        let (read, held) = try await WebTest.read(Self.gradient)
        let scene = try #require(read.assets.scenes.values.first)
        #expect(read.assets.stills.isEmpty)
        #expect(scene.size == CGSize(width: 320, height: 200))
        #expect(scene.clear == [0, 0, 0, 1])
        #expect(scene.programs.count == 1 && scene.programs[0].fragment.contains("u_colors"))
        let draw = try #require(scene.draws.first)
        #expect(draw.mode == .triangles && draw.count == 6 && draw.first == 0)
        #expect(draw.attributes["a_position"]?.components == 2)
        #expect(draw.attributes["a_position"]?.floats == [-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1])
        #expect(draw.uniforms["u_resolution"] == [320, 200])
        #expect(draw.uniforms["u_colors"]?.count == 6)
        // Its time is found: half a second a second, as the page ran it.
        let clock = try #require(scene.clocks.first)
        #expect(scene.clocks.count == 1 && clock.uniform == "u_time" && clock.component == 0)
        #expect(abs(clock.rate - 0.5) < 0.08)
        #expect(clock.start >= 5)
        #expect(scene.uniforms(of: draw, at: 2)["u_time"]?.first.map { abs($0 - (clock.start + 2 * clock.rate)) < 1e-9 } == true)

        // The canvas's layer keeps its picture, and is drawn by its shader.
        let (doc, report) = WebConverter.document([read], source: "test")
        let layer = try #require(doc.allNodes.first { $0.fill.shader != nil })
        #expect(layer.fill.image != nil && held[layer.fill.image!.asset] != nil)
        #expect(layer.frame.size == CGSize(width: 320, height: 200))
        #expect(!report.notes.keys.contains { $0.contains("WebGL") })
        // It goes into a file and comes out the same.
        let data = try JSONEncoder().encode(layer)
        #expect(try JSONDecoder().decode(Node.self, from: data).fill.shader == scene)
    }

    @Test(.timeLimit(.minutes(5))) func saysWhyACanvasStaysAPicture() async throws {
        // Drawn into a texture first, which is not drawn again yet.
        let (read, _) = try await WebTest.read("""
        <canvas id="c" width="64" height="64"></canvas>
        <script>
        const gl = document.getElementById('c').getContext('webgl');
        const fb = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
        const vs = 'attribute vec2 a; void main() { gl_Position = vec4(a, 0.0, 1.0); }', fs = 'void main() { gl_FragColor = vec4(1.0); }';
        function sh(t, s) { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return x; }
        const p = gl.createProgram(); gl.attachShader(p, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
        gl.useProgram(p); gl.drawArrays(gl.TRIANGLES, 0, 3);
        </script>
        """)
        #expect(read.assets.scenes.isEmpty)
        #expect(read.assets.stills.values.contains("framebuffer"))
    }

    @Test func aFillsShaderComesThroughOlderFilesAndFlips() throws {
        // A file from before shaders has none, and a fill with one keeps its picture beside it.
        let old = #"{"on":true,"color":{"r":1,"g":0,"b":0,"a":1}}"#
        #expect(try JSONDecoder().decode(Fill.self, from: Data(old.utf8)).shader == nil)
        var fill = Fill(color: .white)
        fill.shader = ShaderFill(size: CGSize(width: 10, height: 10), programs: [ShaderProgram(vertex: "v", fragment: "f")],
                                 draws: [ShaderDraw(program: 0, uniforms: [:], attributes: [:], mode: .triangles, first: 0, count: 3)],
                                 clocks: [ShaderClock(program: 0, uniform: "t", component: 0, start: 1, rate: 2)])
        #expect(fill.paints)
        #expect(fill.shader?.moves == true)
        #expect(fill.flipped(horizontally: true).shader?.flippedX == true)
        #expect(fill.flipped(horizontally: true).flipped(horizontally: true).shader?.flippedX == nil)
        #expect(fill.shader?.time(film: 3) == 3)
        fill.shader?.speed = 0.5
        fill.shader?.at = 1
        #expect(fill.shader?.time(film: 4) == 3)
    }

    @Test func theAssistantPaintsWithAShaderOfItsOwn() async throws {
        let bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 30, width: 200, height: 100))])
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let tools = MCPTools()
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        // A Shadertoy program, wrapped as pages wrap one.
        let toy = "void mainImage(out vec4 c, in vec2 p) { vec2 uv = p / iResolution.xy; c = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0); }"
        let made = await call("update_layers", ["updates": [["layer": "Card", "fill": ["shader": ["fragment": toy, "speed": 0.5]]]]])
        #expect(!made.failed)
        let shader = try #require(bench.node("Card")?.fill.shader)
        #expect(shader.size == CGSize(width: 400, height: 200))
        #expect(shader.programs[0].fragment.contains("void main() { mainImage(gl_FragColor, gl_FragCoord.xy); }"))
        #expect(shader.programs[0].fragment.contains("uniform float iTime;"))
        #expect(shader.draws[0].uniforms["iResolution"] == [400, 200, 1])
        #expect(shader.clocks.map(\.uniform) == ["iTime"] && shader.speed == 0.5 && shader.moves)
        #expect(bench.node("Card")?.shaderMoves == true)
        // Its film draws it again as time passes.
        #expect(bench.store.doc.nodes[0].filmPieces().contains { $0.layers == [bench.node("Card")!.id] && $0.changes })
        let read = await call("get_layers", ["layers": ["Card"]])
        #expect(read.text.contains("\"shader\"") && read.text.contains("iTime"))
        // Its inputs are changed by name; one it does not have is said so.
        let wrong = await call("update_layers", ["updates": [["layer": "Card", "fill": ["shader": ["uniforms": ["u_nothing": 1]]]]]])
        #expect(wrong.failed && wrong.text.contains("iResolution"))
        let gone = await call("update_layers", ["updates": [["layer": "Card", "fill": "#FF0000"]]])
        #expect(!gone.failed && bench.node("Card")?.fill.shader == nil)
    }

    /// A glow the page's script swings to and fro, and a time that runs steadily, as hero
    /// backgrounds have: drawn on a timer, the page running a while before it is read.
    static let swinging = """
    <canvas id="c" width="160" height="100" style="width: 160px; height: 100px; display: block"></canvas>
    <script>
    const c = document.getElementById('c'), gl = c.getContext('webgl');
    function sh(t, s) { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return x; }
    const p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, 'attribute vec2 a; void main() { gl_Position = vec4(a, 0.0, 1.0); }'));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, 'precision mediump float; uniform float uTime; uniform float uGlow; uniform float uFixed;' +
      ' void main() { gl_FragColor = vec4(uGlow, fract(uTime), uFixed, 1.0); }'));
    gl.linkProgram(p);
    const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(p, 'a');
    const time = gl.getUniformLocation(p, 'uTime'), glow = gl.getUniformLocation(p, 'uGlow'), fixed = gl.getUniformLocation(p, 'uFixed');
    const start = performance.now();
    setInterval(() => {
      const t = (performance.now() - start) / 1000;
      gl.useProgram(p); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1f(time, t); gl.uniform1f(glow, 0.5 + 0.4 * Math.sin(t * 4)); gl.uniform1f(fixed, 0.25);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }, 30);
    </script>
    """

    @Test(.timeLimit(.minutes(5))) func timeRunsAndWhatTheScriptSwingsIsRecorded() async throws {
        let capture = WebCapture()
        capture.stepDelay = 300
        defer { capture.close() }
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"margin: 0\">\(Self.swinging)</body></html>"
        let (read, _) = try await capture.read(html: html, base: nil, size: WebTest.size)
        let scene = try #require(read.assets.scenes.values.first)
        // Its time alone runs with time; its glow is what the script did, and no straight line.
        #expect(scene.clocks.map(\.uniform) == ["uTime"])
        #expect(abs((scene.clocks.first?.rate ?? 0) - 1) < 0.05)
        let glow = try #require(scene.recordings?.first { $0.uniform == "uGlow" })
        #expect(scene.recordings?.count == 1)
        #expect((glow.times.last ?? 0) >= 0.75 && glow.times.count >= 3, "\(glow.times.count) values over \(glow.times.last ?? 0) s")
        // At its time 0 it is as it came in; played on it stays within what the script ever did,
        // however long the film, and comes back round without a jump.
        let draw = try #require(scene.draws.first)
        #expect(scene.uniforms(of: draw, at: 0)["uGlow"]?.first == glow.values.last)
        for t in stride(from: 0.0, to: 60, by: 0.37) {
            let v = scene.uniforms(of: draw, at: t)["uGlow"]?.first ?? -1
            #expect(v >= 0.09 && v <= 0.91, "at \(t): \(v)")
        }
        let span = (glow.times.last ?? 0) - (glow.times.first ?? 0)
        let before = scene.uniforms(of: draw, at: 2 * span - 0.001)["uGlow"]?.first ?? 0
        let after = scene.uniforms(of: draw, at: 2 * span + 0.001)["uGlow"]?.first ?? 1
        #expect(abs(before - after) < 0.02)
        #expect(draw.uniforms["uFixed"] == [0.25] && scene.inputs == ["uFixed"])
        #expect(scene.moves)
    }
}
