import Testing
import AppKit
import AVFoundation
@testable import Bezzle

/// WebGL canvases that draw through framebuffers, with depth and stencil, instances, textures of
/// numbers and the rest of what pages do beyond draws onto the canvas: each a small page of its
/// own, read as Bezzle reads a website, kept as a shader fill and drawn again by Bezzle, which
/// must show what the page's canvas showed. Some draw as the libraries pages are made with do:
/// three.js with its EffectComposer, a Shadertoy with a buffer, a bloom's blur chain, particles
/// whose places are kept in a float texture, PixiJS with a filter.
@MainActor
@Suite(.serialized)
struct ShaderPassImportTests {
    /// What every page here starts with.
    static let prelude = """
    function sh(gl, t, s) { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); if (!gl.getShaderParameter(x, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(x)); return x; }
    function prog(gl, vs, fs) { const p = gl.createProgram(); gl.attachShader(p, sh(gl, gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl, gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p); if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p)); return p; }
    function buf(gl, data) { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW); return b; }
    function attr(gl, p, name, b, n) { const l = gl.getAttribLocation(p, name); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.enableVertexAttribArray(l); gl.vertexAttribPointer(l, n, gl.FLOAT, false, 0, 0); return l; }
    function params(gl, filter) { gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE); }
    function tex(gl, w, h, filter) { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null); params(gl, filter || gl.LINEAR); return t; }
    function fbo(gl, t) { const f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0); gl.bindFramebuffer(gl.FRAMEBUFFER, null); return f; }
    const QUAD = [-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1];
    const FULL = 'attribute vec2 a; varying vec2 v; void main() { v = a * 0.5 + 0.5; gl_Position = vec4(a, 0.0, 1.0); }';
    const FULL3 = '#version 300 es\\nin vec2 a; out vec2 v; void main() { v = a * 0.5 + 0.5; gl_Position = vec4(a, 0.0, 1.0); }';
    window.onerror = (m) => { document.title = 'error: ' + m; };
    """

    struct Kept {
        var fill: ShaderFill
        var read: WebRead
        /// The canvas's own picture, as the page showed it.
        var canvas: CGImage
        var folder: URL
        var size: CGSize

        var board: Node {
            var layer = CanvasTests.rect("Canvas", CGRect(origin: .zero, size: size))
            layer.fill = Fill(color: .white)
            layer.fill.shader = fill
            var board = Node(kind: .artboard, name: "A", frame: CGRect(origin: .zero, size: size))
            board.fill = Fill(color: .white)
            board.children = [layer]
            return board
        }

        /// What Bezzle draws of it in the design, the moment it came in.
        func drawn(scale: CGFloat = 1) throws -> CGImage {
            try #require(Renderer.image(of: board, scale: scale, assets: Assets(design: folder)))
        }

        /// What Bezzle draws of it at a moment of a film.
        func film(_ t: Double) throws -> CGImage {
            try #require(FilmExport.frame(of: board, at: t, size: size, assets: Assets(design: folder)))
        }

        /// The share of a grid of points, one every six pixels, where two pictures of the canvas's
        /// size differ by more than a sixteenth in a channel. `coarse` compares them that many
        /// times smaller instead, every pixel, by more than a sixth: for what is drawn of points,
        /// which two graphics cards never put on the very same pixels, and for a picture drawn
        /// larger, whose edges are finer than the canvas's own.
        func apart(_ a: CGImage, _ b: CGImage, coarse: Int = 1) -> Double {
            if coarse > 1 {
                let small = CGSize(width: Int(size.width) / coarse, height: Int(size.height) / coarse)
                let one = ShaderPassImportTests.bytes(a, small, smooth: true), other = ShaderPassImportTests.bytes(b, small, smooth: true)
                let off = stride(from: 0, to: one.count, by: 4).filter { i in (0..<4).contains { abs(Int(one[i + $0]) - Int(other[i + $0])) > 42 } }.count
                return Double(off) / Double(max(1, one.count / 4))
            }
            let one = ShaderPassImportTests.bytes(a, size), other = ShaderPassImportTests.bytes(b, size)
            let w = Int(size.width), h = Int(size.height)
            var points = 0, off = 0
            for y in stride(from: 3, to: h, by: 6) {
                for x in stride(from: 3, to: w, by: 6) {
                    points += 1
                    let i = (y * w + x) * 4
                    if (0..<4).contains(where: { abs(Int(one[i + $0]) - Int(other[i + $0])) > 16 }) { off += 1 }
                }
            }
            return Double(off) / Double(max(1, points))
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    /// A picture's bytes at a size over white, as an artboard shows it, RGBA, top row first,
    /// with no colour management.
    static func bytes(_ image: CGImage, _ size: CGSize, smooth: Bool = false) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    /// A pixel of a picture drawn at the canvas's size, 0…255, x from the left and y from the top.
    static func pixel(_ image: CGImage, _ size: CGSize, _ x: Int, _ y: Int) -> [Int] {
        let all = bytes(image, size), i = (y * Int(size.width) + x) * 4
        return (0..<4).map { Int(all[i + $0]) }
    }

    /// Reads a page with one canvas, `c`, whose WebGL `script` draws with `gl`, and keeps what
    /// Bezzle kept of it. `wait` is how long the page runs between the reader's steps.
    static func keep(_ script: String, width: Int = 160, height: Int = 120, context: String = "webgl", attributes: String = "{}",
                     wait: Int = 60) async throws -> Kept {
        let page = try await read(script, width: width, height: height, context: context, attributes: attributes, wait: wait)
        let fill = try #require(page.0.assets.scenes.values.first, "It stayed a picture: \(page.0.assets.stills.values.sorted())")
        let (doc, _) = WebConverter.document([page.0], source: "test")
        let layer = try #require(doc.allNodes.first { $0.fill.shader != nil })
        #expect(layer.fill.shader == fill)
        let asset = try #require(layer.fill.image?.asset)
        let data = try #require(page.1[asset])
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let canvas = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shader-\(UUID().uuidString).bezzle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        for (name, data) in page.1 { try data.write(to: folder.appendingPathComponent("images").appendingPathComponent(name)) }
        return Kept(fill: fill, read: page.0, canvas: canvas, folder: folder, size: CGSize(width: width, height: height))
    }

    static func read(_ script: String, width: Int = 160, height: Int = 120, context: String = "webgl", attributes: String = "{}",
                     wait: Int = 60) async throws -> (WebRead, [String: Data]) {
        let capture = WebCapture()
        capture.stepDelay = wait
        defer { capture.close() }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head><body style="margin: 0">
        <canvas id="c" width="\(width)" height="\(height)" style="width: \(width)px; height: \(height)px; display: block"></canvas>
        <script>
        \(prelude)
        const c = document.getElementById('c'), gl = c.getContext('\(context)', \(attributes));
        \(script)
        </script></body></html>
        """
        return try await capture.read(html: html, base: nil, size: WebTest.size)
    }

    // MARK: Passes into textures

    /// Two triangles, the nearer drawn first, into a texture with a depth buffer; the canvas
    /// shows the texture softened and turned to its negative.
    static let postProcessed = """
    const scene = prog(gl, 'attribute vec3 a; attribute vec3 col; varying vec3 v; uniform float u_time; void main() { v = col; gl_Position = vec4(a.xy + 0.04 * vec2(sin(u_time), cos(u_time)), a.z, 1.0); }',
      'precision mediump float; varying vec3 v; void main() { gl_FragColor = vec4(v, 1.0); }');
    const post = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_scene; uniform vec2 u_px;' +
      ' void main() { vec4 s = texture2D(u_scene, v) * 0.5 + texture2D(u_scene, v + u_px) * 0.25 + texture2D(u_scene, v - u_px) * 0.25; gl_FragColor = vec4(1.0 - s.rgb, 1.0); }');
    const tris = buf(gl, [-0.8, -0.8, -0.5, 0.8, -0.8, -0.5, 0.0, 0.8, -0.5, -0.8, 0.8, 0.5, 0.8, 0.8, 0.5, 0.0, -0.8, 0.5]);
    const cols = buf(gl, [1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1]);
    const quad = buf(gl, QUAD);
    const t = tex(gl, c.width, c.height), f = fbo(gl, t);
    const rb = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, rb); gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, c.width, c.height);
    gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rb); gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    const start = performance.now();
    function frame() {
      gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0.1, 0.2, 0.1, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST);
      gl.useProgram(scene); attr(gl, scene, 'a', tris, 3); attr(gl, scene, 'col', cols, 3);
      gl.uniform1f(gl.getUniformLocation(scene, 'u_time'), (performance.now() - start) / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.disable(gl.DEPTH_TEST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.useProgram(post); attr(gl, post, 'a', quad, 2);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t);
      gl.uniform1i(gl.getUniformLocation(post, 'u_scene'), 0); gl.uniform2f(gl.getUniformLocation(post, 'u_px'), 1 / c.width, 1 / c.height);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }
    frame(); setInterval(frame, 30);
    """

    @Test(.timeLimit(.minutes(5))) func aPassIntoATextureWithDepthIsDrawnAgain() async throws {
        let kept = try await Self.keep(Self.postProcessed)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(kept.read.assets.stills.isEmpty)
        // One texture, drawn anew every frame and as large as the canvas: sharp at any size.
        #expect(fill.targets?.count == 1 && fill.targets?[0].keeps == nil && fill.targets?[0].scales == true && !fill.builds)
        #expect(fill.targets?[0].width == 160 && fill.targets?[0].height == 120 && fill.targets?[0].contents == nil)
        let passes = try #require(fill.passes)
        #expect(passes.count == 2 && passes[0].colors == [0] && passes[0].depth != nil && passes[0].clearDepth == 1 && passes[0].count == 1)
        #expect(passes[0].clearColor.map { abs($0[1] - 0.2) < 1e-6 } == true)
        #expect(passes[1].colors == nil && passes[1].count == 1)
        #expect(fill.draws.count == 2 && fill.draws[0].depth?.compare == "less" && fill.draws[1].depth == nil && fill.draws[1].targets == ["u_scene": 0])
        #expect(fill.clocks.map(\.uniform) == ["u_time"] && fill.moves && fill.turn == nil && fill.rate == nil)
        // What Bezzle draws is what the page showed.
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.03, "\(kept.apart(drawn, kept.canvas))")
        // In the middle the nearer, red triangle covers the blue one drawn after it: cyan, its negative.
        let middle = Self.pixel(drawn, kept.size, 80, 60)
        #expect(middle[0] < 30 && middle[1] > 225 && middle[2] > 225, "\(middle)")
        // At four times the size the texture is drawn four times as large (the engine's own
        // tests show that sharp), and it is the same picture.
        let large = try kept.drawn(scale: 4)
        #expect(large.width == 640 && kept.apart(large, kept.canvas, coarse: 4) < 0.05, "\(kept.apart(large, kept.canvas, coarse: 4))")
        // It goes into a design under the key Bezzle 1.7 does not read.
        var fillOfLayer = Fill(color: .white)
        fillOfLayer.shader = fill
        let written = String(decoding: try JSONEncoder().encode(fillOfLayer), as: UTF8.self)
        #expect(written.contains("\"scene\":") && !written.contains("\"shader\":"))
        #expect(try JSONDecoder().decode(Fill.self, from: Data(written.utf8)).shader == fill)
    }

    /// A Shadertoy with a buffer: a dot going round, each frame drawn over the frame before as it
    /// fades, into two textures in turn.
    static let feedback = """
    const step = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_before; uniform float u_time;' +
      ' void main() { vec2 p = vec2(0.5 + 0.3 * cos(u_time), 0.5 + 0.3 * sin(u_time)); float dot = smoothstep(0.09, 0.07, distance(v, p));' +
      ' vec4 old = texture2D(u_before, v); gl_FragColor = vec4(max(old.rgb * 0.98, vec3(dot, dot * 0.5, dot * 0.2)), 1.0); }');
    const show = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_now; void main() { gl_FragColor = texture2D(u_now, v); }');
    const quad = buf(gl, QUAD);
    let a = tex(gl, c.width, c.height), b = tex(gl, c.width, c.height);
    let fa = fbo(gl, a), fb = fbo(gl, b);
    const start = performance.now();
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.useProgram(step); attr(gl, step, 'a', quad, 2);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a);
      gl.uniform1i(gl.getUniformLocation(step, 'u_before'), 0); gl.uniform1f(gl.getUniformLocation(step, 'u_time'), (performance.now() - start) / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.useProgram(show); attr(gl, show, 'a', quad, 2);
      gl.bindTexture(gl.TEXTURE_2D, b); gl.uniform1i(gl.getUniformLocation(show, 'u_now'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      [a, b] = [b, a]; [fa, fb] = [fb, fa];
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func framesThatBuildOnTheFramesBeforeGoOnFromWhereThePageWas() async throws {
        let kept = try await Self.keep(Self.feedback, wait: 150)
        defer { kept.remove() }
        let fill = kept.fill
        // Two textures in turn: both keep, and the one the next frame reads holds what it held.
        #expect(fill.builds && fill.moves && fill.targets?.count == 2 && fill.turn == [1, 0])
        #expect(fill.targets?.allSatisfy { $0.keeps == true && $0.scales == nil } == true)
        let held = (fill.targets ?? []).compactMap(\.contents)
        #expect(held.count == 1 && held.first?.count == 160 * 120 * 4)
        #expect(fill.stepRate >= 20 && fill.stepRate <= 40, "\(fill.stepRate) steps a second")
        let passes = try #require(fill.passes)
        #expect(passes.count == 2 && passes[0].colors?.count == 1 && passes[0].clearColor == nil && passes[1].colors == nil)
        let reads = try #require(fill.draws.first?.targets?["u_before"]), writes = try #require(passes[0].colors?.first)
        #expect(reads != writes && fill.targets?[reads].contents != nil && fill.draws[1].targets?["u_now"] == writes)

        // The moment it came in: the frame the page would have drawn next, all but what it showed.
        let now = try kept.drawn()
        #expect(kept.apart(now, kept.canvas) < 0.04, "\(kept.apart(now, kept.canvas))")
        // The trail is there from the first: the page's dot had been going round a while.
        let lit = Self.bytes(now, kept.size).enumerated().filter { $0.offset % 4 == 0 && $0.element > 40 }.count
        #expect(lit > 450, "\(lit) pixels lit")

        // A second on, the dot has gone on round, and the same moment is the same picture
        // whichever way it is come to: straight, again, and back from a later moment.
        let one = try kept.film(1)
        #expect(kept.apart(one, now) > 0.01)
        let again = try kept.film(1)
        #expect(Self.bytes(one, kept.size) == Self.bytes(again, kept.size))
        let later = try kept.film(2.5)
        #expect(kept.apart(later, one) > 0.01)
        let back = try kept.film(1)
        #expect(Self.bytes(back, kept.size) == Self.bytes(one, kept.size))
        // And the moment before it came in is the moment it came in.
        #expect(Self.bytes(try kept.film(0), kept.size) == Self.bytes(now, kept.size))

        // In a design and out again, with what it held.
        var layer = kept.board.children[0]
        layer = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(layer))
        #expect(layer.fill.shader == fill)
    }

    /// A page that asks for its canvas to be kept (preserveDrawingBuffer) and never clears it: a
    /// square that goes along, leaving itself behind.
    static let trails = """
    const flat = prog(gl, 'attribute vec2 a; uniform float u_time; void main() { gl_Position = vec4(vec2(-0.9 + fract(u_time * 0.2) * 1.8, 0.5 * sin(u_time * 2.0)) + a * 0.08, 0.0, 1.0); }',
      'precision mediump float; uniform vec3 u_color; void main() { gl_FragColor = vec4(u_color, 1.0); }');
    const quad = buf(gl, QUAD);
    const start = performance.now();
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.useProgram(flat); attr(gl, flat, 'a', quad, 2);
      gl.uniform1f(gl.getUniformLocation(flat, 'u_time'), (performance.now() - start) / 1000);
      gl.uniform3f(gl.getUniformLocation(flat, 'u_color'), 1, 0.6, 0.1);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func aCanvasThatIsNeverClearedKeepsWhatWasDrawn() async throws {
        let kept = try await Self.keep(Self.trails, attributes: "{ preserveDrawingBuffer: true }", wait: 150)
        defer { kept.remove() }
        let fill = kept.fill
        // The canvas itself is a texture that keeps, shown at the end of every frame.
        #expect(fill.builds && fill.targets?.count == 1 && fill.targets?[0].keeps == true && fill.targets?[0].contents?.count == 160 * 120 * 4)
        #expect(fill.passes?.count == 2 && fill.passes?[0].colors == [0] && fill.passes?[1].colors == nil)
        let now = try kept.drawn()
        #expect(kept.apart(now, kept.canvas) < 0.03, "\(kept.apart(now, kept.canvas))")
        // What was drawn before it came in is still there a second later, with more beside it.
        let lit = { (image: CGImage) in Self.bytes(image, kept.size).enumerated().filter { $0.offset % 4 == 2 && $0.element < 100 }.count }
        let later = try kept.film(1)
        #expect(lit(later) > lit(now) && lit(now) > 50, "\(lit(now)) then \(lit(later))")

        // The same page without asking: every frame starts clear, and it is a plain fill.
        let cleared = try await Self.keep(Self.trails, wait: 150)
        defer { cleared.remove() }
        #expect(!cleared.fill.builds && cleared.fill.targets == nil && cleared.fill.passes == nil && !cleared.fill.beyondPlain)
    }

    // MARK: Tests and masks

    /// A window cut into the stencil, stripes drawn inside it alone, a corner cleared through the
    /// scissor box, and a band outside the window written into green alone.
    static let stencilled = """
    const flat = prog(gl, 'attribute vec2 a; uniform vec4 u_box; void main() { gl_Position = vec4(u_box.xy + (a * 0.5 + 0.5) * u_box.zw, 0.0, 1.0); }',
      'precision mediump float; uniform vec4 u_color; void main() { gl_FragColor = u_color; }');
    const quad = buf(gl, QUAD);
    const uBox = gl.getUniformLocation(flat, 'u_box'), uColor = gl.getUniformLocation(flat, 'u_color');
    function box(x, y, w, h, r, g, b) { gl.uniform4f(uBox, x, y, w, h); gl.uniform4f(uColor, r, g, b, 1); gl.drawArrays(gl.TRIANGLES, 0, 6); }
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.disable(gl.SCISSOR_TEST); gl.disable(gl.STENCIL_TEST); gl.colorMask(true, true, true, true); gl.stencilMask(255);
      gl.clearColor(0.9, 0.9, 0.8, 1); gl.clearStencil(0); gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
      gl.enable(gl.SCISSOR_TEST); gl.scissor(0, 0, 40, 30); gl.clearColor(0.2, 0.3, 0.9, 1); gl.clear(gl.COLOR_BUFFER_BIT); gl.disable(gl.SCISSOR_TEST);
      gl.useProgram(flat); attr(gl, flat, 'a', quad, 2);
      gl.enable(gl.STENCIL_TEST); gl.stencilFunc(gl.ALWAYS, 1, 255); gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE); gl.colorMask(false, false, false, false);
      box(-0.5, -0.5, 1.0, 1.0, 0, 0, 0);
      gl.colorMask(true, true, true, true); gl.stencilFunc(gl.EQUAL, 1, 255); gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
      box(-1, -0.2, 2, 0.4, 1, 0, 0);
      gl.stencilFunc(gl.NOTEQUAL, 1, 255); gl.colorMask(false, true, false, false);
      box(-1, 0.6, 2, 0.3, 0, 0, 0);
      gl.disable(gl.STENCIL_TEST); gl.colorMask(true, true, true, true);
    }
    frame(); setInterval(frame, 40);
    """

    @Test(.timeLimit(.minutes(5))) func theStencilTheScissorBoxAndColorMaskAreDrawnAgain() async throws {
        let kept = try await Self.keep(Self.stencilled, attributes: "{ stencil: true }")
        defer { kept.remove() }
        let fill = kept.fill
        // Onto the canvas in one go: no passes, and the clear of a corner is a draw of its own.
        #expect(fill.targets == nil && fill.passes == nil && fill.clear.map { abs($0[0] - 0.9) < 1e-6 } == true)
        #expect(fill.draws.count == 4 && fill.draws[0].scissor == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(fill.draws[1].channels == 0 && fill.draws[1].stencil?.front.pass == "replace" && fill.draws[1].stencil?.back == nil)
        #expect(fill.draws[2].stencil?.front.compare == "equal" && fill.draws[2].channels == nil)
        #expect(fill.draws[3].stencil?.front.compare == "notequal" && fill.draws[3].channels == 2)
        #expect(fill.beyondPlain)
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.02, "\(kept.apart(drawn, kept.canvas))")
        // Red inside the window, the ground beside it; the corner blue; the band without its green.
        #expect(Self.pixel(drawn, kept.size, 80, 60)[0] > 240 && Self.pixel(drawn, kept.size, 80, 60)[1] < 15)
        #expect(Self.pixel(drawn, kept.size, 20, 60)[1] > 215)
        #expect(Self.pixel(drawn, kept.size, 20, 110)[2] > 215 && Self.pixel(drawn, kept.size, 20, 110)[0] < 70)
        #expect(Self.pixel(drawn, kept.size, 80, 12)[1] < 15 && Self.pixel(drawn, kept.size, 80, 12)[0] > 215)
    }

    /// A white square laid over blue as far as blendColor says: a quarter of it shows.
    static let faded = """
    const flat = prog(gl, 'attribute vec2 a; uniform vec4 u_box; void main() { gl_Position = vec4(u_box.xy + (a * 0.5 + 0.5) * u_box.zw, 0.0, 1.0); }',
      'precision mediump float; uniform vec4 u_color; void main() { gl_FragColor = u_color; }');
    const quad = buf(gl, QUAD);
    const uBox = gl.getUniformLocation(flat, 'u_box'), uColor = gl.getUniformLocation(flat, 'u_color');
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(flat); attr(gl, flat, 'a', quad, 2);
      gl.disable(gl.BLEND);
      gl.uniform4f(uBox, -1, -1, 2, 2); gl.uniform4f(uColor, 0, 0, 1, 1); gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.enable(gl.BLEND); gl.blendColor(0.5, 1, 0, 0.25); gl.blendFunc(gl.CONSTANT_ALPHA, gl.ONE_MINUS_CONSTANT_ALPHA);
      gl.uniform4f(uBox, -0.5, -0.5, 1, 1); gl.uniform4f(uColor, 1, 1, 1, 1); gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.blendColor(0, 0, 0, 0);
    }
    frame(); setInterval(frame, 40);
    """

    @Test(.timeLimit(.minutes(5))) func aBlendsConstantIsDrawnAgain() async throws {
        let kept = try await Self.keep(Self.faded)
        defer { kept.remove() }
        let fill = kept.fill
        // The constant as it was when the square was drawn, not as the page left it.
        #expect(fill.draws.count == 2 && fill.draws[0].blend == nil && fill.draws[1].blend?.source == "constant-alpha")
        #expect(fill.draws[1].blend?.color == [0.5, 1, 0, 0.25] && fill.beyondPlain)
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.02, "\(kept.apart(drawn, kept.canvas))")
        let middle = Self.pixel(drawn, kept.size, 80, 60), beside = Self.pixel(drawn, kept.size, 10, 60)
        #expect(abs(middle[0] - 64) < 6 && abs(middle[1] - 64) < 6 && middle[2] > 249 && beside[0] < 6 && beside[2] > 249, "\(middle) \(beside)")
    }

    /// A background by one fragment shader as three.js draws one: its tests on, as three.js has
    /// them for every material, though they change nothing of a rectangle drawn alone.
    static let plainWithTests = """
    const p = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform float u_time; void main() { gl_FragColor = vec4(v, 0.5 + 0.5 * sin(u_time), 1.0); }');
    const quad = buf(gl, QUAD);
    const start = performance.now();
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LEQUAL); gl.enable(gl.CULL_FACE); gl.cullFace(gl.BACK); gl.frontFace(gl.CCW);
      gl.useProgram(p); attr(gl, p, 'a', quad, 2);
      gl.uniform1f(gl.getUniformLocation(p, 'u_time'), (performance.now() - start) / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }
    frame(); setInterval(frame, 30);
    """

    @Test(.timeLimit(.minutes(5))) func testsThatChangeNothingAreLeftOutSoThatEveryBezzleDrawsIt() async throws {
        let kept = try await Self.keep(Self.plainWithTests)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(!fill.beyondPlain && fill.draws.count == 1 && fill.draws[0].depth == nil && fill.draws[0].cull == nil)
        #expect(fill.clear == [0, 0, 0, 1] && fill.clocks.map(\.uniform) == ["u_time"])
        var layerFill = Fill(color: .white)
        layerFill.shader = fill
        let old = try JSONDecoder().decode(Bezzle17.Fill.self, from: JSONEncoder().encode(layerFill))
        #expect(old.shader?.draws.count == 1 && old.shader?.clocks.count == 1)
        #expect(kept.apart(try kept.drawn(), kept.canvas) < 0.02)
    }

    // MARK: Instances and textures of numbers

    /// WebGL 1 with its extensions: a square drawn twelve times, each with a place and a colour of
    /// its own, over a ground read from textures of numbers, LUMINANCE, ALPHA and floats.
    static let instancedOverNumbers = """
    const ext = gl.getExtension('ANGLE_instanced_arrays'), floats = gl.getExtension('OES_texture_float');
    const ground = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_gray; uniform sampler2D u_cover; uniform sampler2D u_table;' +
      ' void main() { float g = texture2D(u_gray, v).r; float a = texture2D(u_cover, v).a; vec4 t = texture2D(u_table, vec2(v.x, 0.5)); gl_FragColor = vec4(g * t.r * 0.25, a * t.g * 0.25, t.b * 0.25, 1.0); }');
    const dots = prog(gl, 'attribute vec2 a; attribute vec2 a_at; attribute vec3 a_color; varying vec3 v; void main() { v = a_color; gl_Position = vec4(a_at + a * 0.06, 0.0, 1.0); }',
      'precision mediump float; varying vec3 v; void main() { gl_FragColor = vec4(v, 1.0); }');
    const quad = buf(gl, QUAD);
    const places = [], colours = [];
    for (let i = 0; i < 12; i++) { places.push(-0.85 + (i % 4) * 0.55, -0.6 + Math.floor(i / 4) * 0.6); colours.push(i % 2, (i % 3) / 2, 1 - (i % 4) / 3); }
    const at = buf(gl, places), color = buf(gl, colours);
    function data(format, type, w, h, values, filter) { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1); gl.texImage2D(gl.TEXTURE_2D, 0, format, w, h, 0, format, type, values); params(gl, filter); return t; }
    const gray = data(gl.LUMINANCE, gl.UNSIGNED_BYTE, 3, 2, new Uint8Array([255, 128, 0, 0, 128, 255]), gl.NEAREST);
    const cover = data(gl.ALPHA, gl.UNSIGNED_BYTE, 2, 2, new Uint8Array([255, 60, 60, 255]), gl.LINEAR);
    const table = data(gl.RGBA, gl.FLOAT, 4, 1, new Float32Array([4, 0, 0, 1, 0, 4, 0, 1, 0, 0, 4, 1, 2, 2, 2, 1]), gl.NEAREST);
    function frame() {
      gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(ground); attr(gl, ground, 'a', quad, 2);
      [gray, cover, table].forEach((t, i) => { gl.activeTexture(gl.TEXTURE0 + i); gl.bindTexture(gl.TEXTURE_2D, t); });
      gl.uniform1i(gl.getUniformLocation(ground, 'u_gray'), 0); gl.uniform1i(gl.getUniformLocation(ground, 'u_cover'), 1); gl.uniform1i(gl.getUniformLocation(ground, 'u_table'), 2);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.useProgram(dots); attr(gl, dots, 'a', quad, 2);
      const la = attr(gl, dots, 'a_at', at, 2), lc = attr(gl, dots, 'a_color', color, 3);
      ext.vertexAttribDivisorANGLE(la, 1); ext.vertexAttribDivisorANGLE(lc, 1);
      ext.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 6, 12);
      ext.vertexAttribDivisorANGLE(la, 0); ext.vertexAttribDivisorANGLE(lc, 0);
      gl.disableVertexAttribArray(la); gl.disableVertexAttribArray(lc);
    }
    frame(); setInterval(frame, 40);
    """

    @Test(.timeLimit(.minutes(5))) func instancesAndTexturesOfNumbersAreDrawnAgain() async throws {
        let kept = try await Self.keep(Self.instancedOverNumbers)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(fill.draws.count == 2 && fill.draws[1].instances == 12)
        #expect(fill.draws[1].attributes["a_at"]?.divisor == 1 && fill.draws[1].attributes["a_at"]?.floats.count == 24)
        #expect(fill.draws[1].attributes["a"]?.divisor == nil && fill.draws[1].attributes["a_color"]?.divisor == 1)
        // The floats and the alphas are kept as the numbers they are; the grays, a picture as
        // well as numbers, as a picture.
        let texels = try #require(fill.texels)
        #expect(Set(texels.map(\.format)) == ["a8", "rgba32f"] && fill.draws[0].texels?.count == 2 && fill.draws[0].textures?.count == 1)
        #expect(fill.draws[0].sampling?["u_gray"]?.magnify == "nearest")
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.03, "\(kept.apart(drawn, kept.canvas))")
    }

    /// WebGL 2: a uniform block, instances from a vertex array, two textures of half floats drawn
    /// into at once, one with smaller copies of itself, and a texture given by texStorage2D and
    /// texSubImage2D as three.js gives every one.
    static let webGL2 = """
    gl.getExtension('EXT_color_buffer_float'); gl.getExtension('EXT_color_buffer_half_float');
    const both = prog(gl, '#version 300 es\\nlayout(std140) uniform Look { vec4 u_tint; mat4 u_turn; float u_gain; };\\nin vec2 a; in vec2 a_at; out vec2 v; out vec4 tint;' +
      ' void main() { v = a * 0.5 + 0.5; tint = u_tint * u_gain; gl_Position = u_turn * vec4(a_at + a * 0.12, 0.0, 1.0); }',
      '#version 300 es\\nprecision highp float; in vec2 v; in vec4 tint; uniform sampler2D u_picture; layout(location = 0) out vec4 one; layout(location = 1) out vec4 two;' +
      ' void main() { vec4 p = texture(u_picture, v); one = vec4(p.rgb * tint.rgb * 2.0, 1.0); two = vec4(v, 3.0, 1.0); }');
    const show = prog(gl, FULL3, '#version 300 es\\nprecision highp float; in vec2 v; uniform sampler2D u_one; uniform sampler2D u_two; out vec4 o;' +
      ' void main() { vec4 a = texture(u_one, v), b = textureLod(u_two, v, 3.0); o = vec4(a.rgb * 0.5 + vec3(b.xy * 0.2, b.z / 12.0), 1.0); }');
    const block = gl.createBuffer(); gl.bindBuffer(gl.UNIFORM_BUFFER, block);
    const look = new Float32Array(24); look.set([1, 0.5, 0.25, 1], 0); look.set([0.9, 0.1, 0, 0, -0.1, 0.9, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], 4); look[20] = 0.9;
    gl.bufferData(gl.UNIFORM_BUFFER, look, gl.DYNAMIC_DRAW);
    gl.uniformBlockBinding(both, gl.getUniformBlockIndex(both, 'Look'), 2); gl.bindBufferBase(gl.UNIFORM_BUFFER, 2, block);
    const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
    attr(gl, both, 'a', buf(gl, QUAD), 2);
    const la = attr(gl, both, 'a_at', buf(gl, [-0.6, -0.5, 0, -0.5, 0.6, -0.5, -0.6, 0.5, 0, 0.5, 0.6, 0.5]), 2); gl.vertexAttribDivisor(la, 1);
    gl.bindVertexArray(null);
    const full = gl.createVertexArray(); gl.bindVertexArray(full); attr(gl, show, 'a', buf(gl, QUAD), 2); gl.bindVertexArray(null);
    const picture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, picture); gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, 2, 2);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([255, 255, 255, 255, 255, 0, 0, 128, 0, 255, 0, 128, 0, 0, 255, 255])); params(gl, gl.NEAREST);
    function target(mips) { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); gl.texStorage2D(gl.TEXTURE_2D, mips ? 8 : 1, gl.RGBA16F, 128, 128); params(gl, gl.LINEAR); if (mips) gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR); return t; }
    const one = target(false), two = target(true);
    const f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, one, 0); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, two, 0);
    gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]); gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    let n = 0;
    function frame() {
      n++;
      look[20] = 0.75 + 0.25 * Math.sin(n * 0.1); gl.bindBuffer(gl.UNIFORM_BUFFER, block); gl.bufferSubData(gl.UNIFORM_BUFFER, 0, look);
      gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.viewport(0, 0, 128, 128);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(both); gl.bindVertexArray(vao);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, picture); gl.uniform1i(gl.getUniformLocation(both, 'u_picture'), 0);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, 6);
      gl.bindTexture(gl.TEXTURE_2D, two); gl.generateMipmap(gl.TEXTURE_2D);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, c.width, c.height);
      gl.useProgram(show); gl.bindVertexArray(full);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, one); gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, two);
      gl.uniform1i(gl.getUniformLocation(show, 'u_one'), 0); gl.uniform1i(gl.getUniformLocation(show, 'u_two'), 1);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.bindVertexArray(null);
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func webGL2sBlocksInstancesAndSeveralOutputsAreDrawnAgain() async throws {
        let kept = try await Self.keep(Self.webGL2, width: 128, height: 128, context: "webgl2", wait: 150)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(fill.targets?.count == 2 && fill.targets?.allSatisfy { $0.format == "rgba16f" && $0.width == 128 && $0.keeps == nil } == true)
        #expect(fill.targets?[1].mipmapped == true && fill.passes?.first?.colors == [0, 1] && fill.passes?.first?.mipmaps == [1])
        // The block's bytes as its members' numbers; the one the page moved is recorded as it went.
        let draw = try #require(fill.draws.first)
        #expect(draw.uniforms["u_tint"] == [1, 0.5, 0.25, 1] && draw.uniforms["u_turn"]?.count == 16 && draw.uniforms["u_gain"]?.count == 1)
        #expect(draw.uniforms["u_turn"].map { abs($0[1] - 0.1) < 1e-6 && abs($0[4] + 0.1) < 1e-6 } == true)
        #expect(draw.instances == 6 && draw.attributes["a_at"]?.divisor == 1)
        // The picture's pixels are half see-through: numbers, as they were given.
        #expect(fill.texels?.count == 1 && fill.texels?[0].format == "rgba8" && draw.texels?["u_picture"] == 0)
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.03, "\(kept.apart(drawn, kept.canvas))")
    }

    // MARK: As libraries draw

    /// three.js with an EffectComposer: the scene into a texture with a depth buffer, a pass from
    /// that texture into a second, and from there onto the screen; the two change places every
    /// frame, and neither is cleared before a pass draws all of it.
    static let composer = """
    gl.getExtension('EXT_color_buffer_float'); gl.getExtension('EXT_color_buffer_half_float');
    const mesh = prog(gl, '#version 300 es\\nin vec3 position; uniform mat4 modelViewMatrix; out vec3 vPos; void main() { vPos = position; gl_Position = modelViewMatrix * vec4(position, 1.0); }',
      '#version 300 es\\nprecision highp float; in vec3 vPos; uniform vec3 diffuse; out vec4 o; void main() { o = vec4(diffuse * (0.6 + 0.4 * vPos.y), 1.0); }');
    const pass = prog(gl, FULL3, '#version 300 es\\nprecision highp float; in vec2 v; uniform sampler2D tDiffuse; uniform float amount; out vec4 o;' +
      ' void main() { vec4 c = texture(tDiffuse, v); float r = texture(tDiffuse, v + vec2(amount, 0.0)).r; o = vec4(r, c.g, c.b, 1.0); }');
    const copy = prog(gl, FULL3, '#version 300 es\\nprecision highp float; in vec2 v; uniform sampler2D tDiffuse; out vec4 o; void main() { o = texture(tDiffuse, v); }');
    const geometry = gl.createVertexArray(); gl.bindVertexArray(geometry);
    attr(gl, mesh, 'position', buf(gl, [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0]), 3);
    const index = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, index); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array([0, 1, 2, 0, 2, 3]), gl.STATIC_DRAW);
    gl.bindVertexArray(null);
    const fsQuad = gl.createVertexArray(); gl.bindVertexArray(fsQuad); attr(gl, pass, 'a', buf(gl, QUAD), 2); gl.bindVertexArray(null);
    function renderTarget() {
      const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, c.width, c.height); params(gl, gl.LINEAR);
      const d = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, d); gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, c.width, c.height);
      const f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0); gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, d);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      return { t, f };
    }
    let readBuffer = renderTarget(), writeBuffer = renderTarget();
    const start = performance.now();
    function matrix(angle, x, z) { const co = Math.cos(angle), si = Math.sin(angle); return [co, si, 0, 0, -si, co, 0, 0, 0, 0, 1, 0, x, 0, z, 1]; }
    function frame() {
      const time = (performance.now() - start) / 1000;
      // RenderPass: the scene into the read buffer, cleared, its depth tested.
      gl.bindFramebuffer(gl.FRAMEBUFFER, readBuffer.f); gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0.05, 0.05, 0.1, 1); gl.clearDepth(1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LEQUAL); gl.enable(gl.CULL_FACE); gl.cullFace(gl.BACK);
      gl.useProgram(mesh); gl.bindVertexArray(geometry);
      gl.uniformMatrix4fv(gl.getUniformLocation(mesh, 'modelViewMatrix'), false, matrix(time * 0.5, -0.2, -0.3)); gl.uniform3f(gl.getUniformLocation(mesh, 'diffuse'), 1, 0.8, 0.2);
      gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_SHORT, 0);
      gl.uniformMatrix4fv(gl.getUniformLocation(mesh, 'modelViewMatrix'), false, matrix(-time * 0.3, 0.2, 0.3)); gl.uniform3f(gl.getUniformLocation(mesh, 'diffuse'), 0.2, 0.6, 1);
      gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_SHORT, 0);
      // ShaderPass: from the read buffer into the write buffer, no clear, no depth test; then they change places.
      gl.disable(gl.DEPTH_TEST); gl.disable(gl.CULL_FACE);
      gl.bindFramebuffer(gl.FRAMEBUFFER, writeBuffer.f);
      gl.useProgram(pass); gl.bindVertexArray(fsQuad);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, readBuffer.t); gl.uniform1i(gl.getUniformLocation(pass, 'tDiffuse'), 0); gl.uniform1f(gl.getUniformLocation(pass, 'amount'), 0.02);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      [readBuffer, writeBuffer] = [writeBuffer, readBuffer];
      // The last pass onto the screen.
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.useProgram(copy);
      gl.bindTexture(gl.TEXTURE_2D, readBuffer.t); gl.uniform1i(gl.getUniformLocation(copy, 'tDiffuse'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.bindVertexArray(null);
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func threeJSWithAnEffectComposerIsDrawnAgain() async throws {
        let kept = try await Self.keep(Self.composer, context: "webgl2", wait: 150)
        defer { kept.remove() }
        let fill = kept.fill
        // Its two textures change places every frame, but no frame reads what the last one left:
        // nothing keeps, and both are drawn as large as they are shown.
        #expect(!fill.builds && fill.turn == nil && fill.rate == nil && fill.targets?.count == 2)
        #expect(fill.targets?.allSatisfy { $0.keeps == nil && $0.contents == nil && $0.scales == true && $0.format == "rgba16f" } == true)
        let passes = try #require(fill.passes)
        #expect(passes.count == 3 && passes[0].count == 2 && passes[0].depth != nil && passes[1].clearColor == nil && passes[2].colors == nil)
        #expect(fill.draws[0].depth?.compare == "lequal" && fill.draws[0].cull == "back" && fill.draws[0].indices?.count == 24)
        #expect(fill.draws[2].depth == nil && fill.draws[2].targets?["tDiffuse"] == passes[0].colors?.first)
        #expect(fill.draws[3].targets?["tDiffuse"] == passes[1].colors?.first)
        // Each mesh is where it stood: what the page turned them by is kept draw by draw.
        #expect(fill.draws[0].uniforms["modelViewMatrix"] != fill.draws[1].uniforms["modelViewMatrix"])
        #expect((fill.recordings ?? []).allSatisfy { $0.uniform != "modelViewMatrix" || $0.draw != nil })
        #expect(fill.clocks.allSatisfy { $0.uniform != "modelViewMatrix" || $0.draw != nil })
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.04, "\(kept.apart(drawn, kept.canvas))")
        let large = try kept.drawn(scale: 3)
        #expect(kept.apart(large, kept.canvas, coarse: 4) < 0.05, "\(kept.apart(large, kept.canvas, coarse: 4))")
    }

    /// A bloom: the scene into a texture with smaller copies of itself, what is bright of it
    /// blurred across and then down at half the size, and both put together on the canvas.
    static let bloom = """
    const scene = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform float u_time; void main() { float d = distance(v, vec2(0.5 + 0.2 * sin(u_time), 0.5)); gl_FragColor = vec4(vec3(1.0, 0.8, 0.4) * smoothstep(0.12, 0.1, d) + vec3(0.0, 0.05, 0.1), 1.0); }');
    const blur = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_from; uniform vec2 u_dir; uniform float u_bias;' +
      ' void main() { vec4 s = vec4(0.0); for (int i = -3; i <= 3; i++) { s += texture2D(u_from, v + u_dir * float(i), u_bias); } gl_FragColor = vec4(max(s.rgb / 7.0 - 0.05, 0.0), 1.0); }');
    const join = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_scene; uniform sampler2D u_glow; void main() { gl_FragColor = vec4(texture2D(u_scene, v).rgb + texture2D(u_glow, v).rgb, 1.0); }');
    const quad = buf(gl, QUAD);
    const full = tex(gl, 128, 128); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    const across = tex(gl, 64, 64), down = tex(gl, 64, 64);
    const fFull = fbo(gl, full), fAcross = fbo(gl, across), fDown = fbo(gl, down);
    const start = performance.now();
    function pass(p, f, w, h, set) { gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.viewport(0, 0, w, h); gl.useProgram(p); attr(gl, p, 'a', quad, 2); set(p); gl.drawArrays(gl.TRIANGLES, 0, 6); }
    function frame() {
      pass(scene, fFull, 128, 128, (p) => gl.uniform1f(gl.getUniformLocation(p, 'u_time'), (performance.now() - start) / 1000));
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, full); gl.generateMipmap(gl.TEXTURE_2D);
      pass(blur, fAcross, 64, 64, (p) => { gl.bindTexture(gl.TEXTURE_2D, full); gl.uniform1i(gl.getUniformLocation(p, 'u_from'), 0); gl.uniform2f(gl.getUniformLocation(p, 'u_dir'), 1 / 64, 0); gl.uniform1f(gl.getUniformLocation(p, 'u_bias'), 1); });
      pass(blur, fDown, 64, 64, (p) => { gl.bindTexture(gl.TEXTURE_2D, across); gl.uniform2f(gl.getUniformLocation(p, 'u_dir'), 0, 1 / 64); gl.uniform1f(gl.getUniformLocation(p, 'u_bias'), 0); });
      pass(join, null, c.width, c.height, (p) => { gl.bindTexture(gl.TEXTURE_2D, full); gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, down); gl.activeTexture(gl.TEXTURE0);
        gl.uniform1i(gl.getUniformLocation(p, 'u_scene'), 0); gl.uniform1i(gl.getUniformLocation(p, 'u_glow'), 1); });
    }
    frame(); setInterval(frame, 30);
    """

    @Test(.timeLimit(.minutes(5))) func aBloomsBlurChainIsDrawnAgainAndStaysSharp() async throws {
        let kept = try await Self.keep(Self.bloom, width: 128, height: 128)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(fill.targets?.map(\.width) == [128, 64, 64] && fill.targets?.allSatisfy { $0.scales == true && $0.keeps == nil } == true)
        #expect(fill.targets?[0].mipmapped == true && fill.passes?.count == 4 && fill.passes?[0].mipmaps == [0])
        #expect(fill.draws[1].sampling?["u_from"]?.mipmap == "linear" && fill.draws[3].targets == ["u_scene": 0, "u_glow": 2])
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.03, "\(kept.apart(drawn, kept.canvas))")
        // Three times as near, every texture of the chain is drawn three times as large (the
        // engine's own tests show that sharp), and it is the same picture.
        let large = try kept.drawn(scale: 3)
        #expect(large.width == 384 && kept.apart(large, kept.canvas, coarse: 4) < 0.05, "\(kept.apart(large, kept.canvas, coarse: 4))")
    }

    /// Particles whose places are kept in a float texture, as GPU particle systems keep them: a
    /// pass moves every place a little, into two textures in turn, and each particle is a point
    /// drawn where its texel says.
    static let particles = """
    gl.getExtension('EXT_color_buffer_float');
    const move = prog(gl, FULL3, '#version 300 es\\nprecision highp float; in vec2 v; uniform sampler2D u_places; out vec4 o;' +
      ' void main() { vec4 p = texture(u_places, v); p.xy += p.zw * 0.004; p.xy = fract(p.xy); o = p; }');
    const draw = prog(gl, '#version 300 es\\nin vec2 a_index; uniform sampler2D u_places; void main() { vec4 p = texture(u_places, a_index); gl_Position = vec4(p.xy * 2.0 - 1.0, 0.0, 1.0); gl_PointSize = 5.0; }',
      '#version 300 es\\nprecision highp float; out vec4 o; void main() { o = vec4(0.3, 0.5, 1.0, 1.0); }');
    const N = 12, first = new Float32Array(N * N * 4), indices = [];
    for (let i = 0; i < N * N; i++) { const x = (i % N + 0.5) / N, y = (Math.floor(i / N) + 0.5) / N; first.set([x, y, Math.cos(i * 2.4), Math.sin(i * 2.4)], i * 4); indices.push(x, y); }
    function places(data) { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, N, N, 0, gl.RGBA, gl.FLOAT, data); params(gl, gl.NEAREST); return t; }
    let a = places(first), b = places(null), fa = fbo(gl, a), fb = fbo(gl, b);
    const quadArray = gl.createVertexArray(); gl.bindVertexArray(quadArray); attr(gl, move, 'a', buf(gl, QUAD), 2);
    const pointArray = gl.createVertexArray(); gl.bindVertexArray(pointArray); attr(gl, draw, 'a_index', buf(gl, indices), 2); gl.bindVertexArray(null);
    function frame() {
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb); gl.viewport(0, 0, N, N); gl.disable(gl.BLEND);
      gl.useProgram(move); gl.bindVertexArray(quadArray);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, a); gl.uniform1i(gl.getUniformLocation(move, 'u_places'), 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0.05, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
      gl.useProgram(draw); gl.bindVertexArray(pointArray);
      gl.bindTexture(gl.TEXTURE_2D, b); gl.uniform1i(gl.getUniformLocation(draw, 'u_places'), 0);
      gl.drawArrays(gl.POINTS, 0, N * N);
      gl.bindVertexArray(null);
      [a, b] = [b, a]; [fa, fb] = [fb, fa];
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func particlesKeptInAFloatTextureGoOnFromWhereTheyWere() async throws {
        let kept = try await Self.keep(Self.particles, context: "webgl2", wait: 150)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(fill.builds && fill.turn == [1, 0] && fill.targets?.count == 2)
        #expect(fill.targets?.allSatisfy { $0.format == "rgba32f" && $0.width == 12 && $0.keeps == true } == true)
        // Their places as they were, in floats: 144 particles, four numbers each.
        let held = try #require((fill.targets ?? []).compactMap(\.contents).first)
        #expect(held.count == 12 * 12 * 16 && (fill.targets ?? []).compactMap(\.contents).count == 1)
        let places = held.withUnsafeBytes { raw in (0..<(12 * 12 * 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        #expect(places.allSatisfy { $0.isFinite && $0 >= -1 && $0 <= 1 })
        #expect(fill.draws[1].mode == .points && fill.draws[1].targets?.count == 1 && fill.draws[1].sampling?["u_places"]?.magnify == "nearest")
        // Where they were when it came in.
        let now = try kept.drawn()
        #expect(kept.apart(now, kept.canvas, coarse: 8) < 0.03, "\(kept.apart(now, kept.canvas, coarse: 8))")
        let lit = { (image: CGImage) in Self.bytes(image, kept.size).enumerated().filter { $0.offset % 4 == 2 && $0.element > 200 }.count }
        #expect(lit(now) > 1500 && abs(lit(now) - lit(kept.canvas)) < lit(kept.canvas) / 5, "\(lit(now)) pixels lit, \(lit(kept.canvas)) on the page")
        // Two seconds on they have moved, and the same moment is the same picture again.
        let later = try kept.film(2)
        #expect(kept.apart(later, now) > 0.05 && lit(later) > 1500)
        #expect(Self.bytes(try kept.film(0.5), kept.size) == Self.bytes(try kept.film(0.5), kept.size))
        #expect(Self.bytes(try kept.film(2), kept.size) == Self.bytes(later, kept.size))
    }

    /// PixiJS with a filter on a container: two sprites of one picture, batched and drawn by
    /// their numbers into a see-through texture, which a colour filter then draws onto the canvas.
    static let filtered = """
    const batch = prog(gl, 'attribute vec2 aVertexPosition; attribute vec2 aTextureCoord; attribute vec4 aColor; varying vec2 vUv; varying vec4 vColor; void main() { vUv = aTextureCoord; vColor = aColor; gl_Position = vec4(aVertexPosition, 0.0, 1.0); }',
      'precision mediump float; varying vec2 vUv; varying vec4 vColor; uniform sampler2D uSampler; void main() { gl_FragColor = texture2D(uSampler, vUv) * vColor; }');
    const filter = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D uSampler; uniform float uAlpha; void main() { vec4 c = texture2D(uSampler, v); gl_FragColor = vec4(c.b, c.g, c.r, c.a) * uAlpha; }');
    const art = document.createElement('canvas'); art.width = 32; art.height = 32;
    const pen = art.getContext('2d'); pen.fillStyle = '#e33'; pen.beginPath(); pen.arc(16, 16, 14, 0, 7); pen.fill(); pen.fillStyle = '#fd2'; pen.fillRect(12, 4, 8, 8);
    const sprite = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, sprite); gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, art); params(gl, gl.LINEAR);
    function spriteAt(x, y, s, alpha) { return [x - s, y - s, 0, 1, alpha, alpha, alpha, alpha, x + s, y - s, 1, 1, alpha, alpha, alpha, alpha, x + s, y + s, 1, 0, alpha, alpha, alpha, alpha, x - s, y + s, 0, 0, alpha, alpha, alpha, alpha]; }
    const vertices = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vertices);
    const index = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, index); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]), gl.STATIC_DRAW);
    const quad = buf(gl, QUAD);
    const target = tex(gl, c.width, c.height), f = fbo(gl, target);
    let n = 0;
    function frame() {
      n++;
      gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.viewport(0, 0, c.width, c.height);
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(batch);
      gl.bindBuffer(gl.ARRAY_BUFFER, vertices);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(spriteAt(-0.3 + 0.1 * Math.sin(n * 0.1), 0, 0.5, 1).concat(spriteAt(0.3, 0.1, 0.4, 0.5))), gl.DYNAMIC_DRAW);
      const lp = gl.getAttribLocation(batch, 'aVertexPosition'), lt = gl.getAttribLocation(batch, 'aTextureCoord'), lc = gl.getAttribLocation(batch, 'aColor');
      gl.enableVertexAttribArray(lp); gl.enableVertexAttribArray(lt); gl.enableVertexAttribArray(lc);
      gl.vertexAttribPointer(lp, 2, gl.FLOAT, false, 32, 0); gl.vertexAttribPointer(lt, 2, gl.FLOAT, false, 32, 8); gl.vertexAttribPointer(lc, 4, gl.FLOAT, false, 32, 16);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, index);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, sprite); gl.uniform1i(gl.getUniformLocation(batch, 'uSampler'), 0);
      gl.drawElements(gl.TRIANGLES, 12, gl.UNSIGNED_SHORT, 0);
      gl.disableVertexAttribArray(lt); gl.disableVertexAttribArray(lc);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.clearColor(0.1, 0.1, 0.12, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(filter); attr(gl, filter, 'a', quad, 2);
      gl.bindTexture(gl.TEXTURE_2D, target); gl.uniform1i(gl.getUniformLocation(filter, 'uSampler'), 0); gl.uniform1f(gl.getUniformLocation(filter, 'uAlpha'), 0.9);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.disable(gl.BLEND);
    }
    frame(); setInterval(frame, 33);
    """

    @Test(.timeLimit(.minutes(5))) func pixiJSWithAFilterIsDrawnAgain() async throws {
        let kept = try await Self.keep(Self.filtered, wait: 120)
        defer { kept.remove() }
        let fill = kept.fill
        #expect(!fill.builds && fill.targets?.count == 1 && fill.targets?[0].scales == true && fill.passes?.count == 2)
        #expect(fill.passes?[0].clearColor == [0, 0, 0, 0] && fill.passes?[1].clearColor.map { abs($0[0] - 0.1) < 1e-6 } == true)
        #expect(fill.draws[0].indices?.count == 48 && fill.draws[0].textures?.count == 1 && fill.draws[0].premultipliesTextures == true)
        #expect(fill.draws[0].blend?.source == "one" && fill.draws[1].blend?.destination == "one-minus-src-alpha")
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.04, "\(kept.apart(drawn, kept.canvas))")
    }

    // MARK: What stays a picture

    @Test(.timeLimit(.minutes(5))) func aVideosFrameThatCannotBeReadLeavesThePicture() async throws {
        // A texture from a video that has no frame: there is nothing to keep of it.
        let (read, _) = try await Self.read("""
        const video = document.createElement('video');
        const p = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_video; void main() { gl_FragColor = vec4(texture2D(u_video, v).rgb + vec3(0.2, 0.4, 0.6), 1.0); }');
        const quad = buf(gl, QUAD);
        const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); params(gl, gl.LINEAR);
        function frame() {
          try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video); } catch (e) {}
          gl.useProgram(p); attr(gl, p, 'a', quad, 2); gl.uniform1i(gl.getUniformLocation(p, 'u_video'), 0);
          gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
        frame(); setInterval(frame, 40);
        """)
        #expect(read.assets.scenes.isEmpty)
        #expect(read.assets.stills.values.contains { $0.contains("video") }, "\(read.assets.stills)")
    }

    /// A film of three frames, 64 by 64, as a file's bytes: green with a white square in the middle.
    static func film() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shader-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for n in 0..<3 {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }

    @Test(.timeLimit(.minutes(5))) func aVideosFrameIsKeptAsAPicture() async throws {
        // A video the page holds, whose frame it gives a texture whenever it draws: what the
        // texture holds as the page is read is the picture it is kept as. (A page Bezzle reads
        // plays no video by itself, so this one stands on its first frame.)
        let film = try await Self.film().base64EncodedString()
        let kept = try await Self.keep("""
        const video = document.createElement('video'); video.muted = true; video.playsInline = true; video.preload = 'auto';
        video.src = 'data:video/mp4;base64,\(film)'; video.load();
        const p = prog(gl, FULL, 'precision mediump float; varying vec2 v; uniform sampler2D u_video; void main() { gl_FragColor = vec4(texture2D(u_video, v).rgb, 1.0); }');
        const quad = buf(gl, QUAD);
        const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t); params(gl, gl.LINEAR);
        function frame() {
          if (video.readyState < 2) return;
          gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
          gl.viewport(0, 0, c.width, c.height);
          gl.useProgram(p); attr(gl, p, 'a', quad, 2); gl.uniform1i(gl.getUniformLocation(p, 'u_video'), 0);
          gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
        setInterval(frame, 40);
        """, wait: 250)
        defer { kept.remove() }
        let fill = kept.fill
        // Its rows are kept as the texture held them, so nothing is turned over again.
        #expect(fill.draws.count == 1 && fill.draws[0].textures?["u_video"]?.size == CGSize(width: 64, height: 64) && fill.draws[0].flipsTextures != true)
        // Nothing here that Bezzle 1.7 could not draw.
        #expect(!fill.beyondPlain)
        let drawn = try kept.drawn()
        #expect(kept.apart(drawn, kept.canvas) < 0.03, "\(kept.apart(drawn, kept.canvas))")
        let middle = Self.pixel(drawn, kept.size, 80, 60), corner = Self.pixel(drawn, kept.size, 10, 10)
        #expect(middle[0] > 225 && middle[2] > 225 && corner[0] < 90 && corner[1] > 130, "\(middle) \(corner)")
        // The report says that the video stands still.
        #expect(kept.read.assets.videos.count == 1)
        let (_, report) = WebConverter.document([kept.read], source: "test")
        #expect(report.notes.keys.contains("Videos in WebGL drawings, as still pictures"))
    }
}
