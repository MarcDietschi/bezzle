import Testing
import AppKit
@testable import Bezzle

/// The shader model as Bezzle 1.7 reads a design: what its structs keep and nothing else
/// (`git show v1.7:Bezzle/Model/Shader.swift`, and `Fill` of `Node.swift` there), with the coding
/// Swift makes for them, as 1.7's is. A design written today is read with these to prove what
/// 1.7 makes of it.
enum Bezzle17 {
    struct ShaderFill: Codable, Equatable {
        var size: CGSize
        var clear: [Double]?
        var programs: [ShaderProgram]
        var draws: [ShaderDraw]
        var clocks: [ShaderClock] = []
        var recordings: [ShaderRecording]?
        var speed: Double = 1
        var at: Double = 0
        var flippedX: Bool?
        var flippedY: Bool?
        var alpha: Bool?
        var premultipliedAlpha: Bool?
        var antialias: Bool?
    }

    struct ShaderProgram: Codable, Equatable {
        var vertex: String
        var fragment: String
    }

    struct ShaderDraw: Codable, Equatable {
        enum Mode: String, Codable { case triangles, triangleStrip, triangleFan, lines, lineStrip, points }

        var program: Int
        var uniforms: [String: [Double]]
        var attributes: [String: ShaderAttribute]
        var indices: Data?
        var mode: Mode
        var first: Int
        var count: Int
        var textures: [String: ShaderTexture]?
        var flipsTextures: Bool?
        var premultipliesTextures: Bool?
        var sampling: [String: ShaderSampling]?
        var blend: ShaderBlend?
        var viewport: CGRect?
    }

    struct ShaderAttribute: Codable, Equatable {
        var components: Int
        var values: Data?
        var constant: [Double]?
    }

    struct ShaderSampling: Codable, Equatable {
        var wrapS = "clamp"
        var wrapT = "clamp"
        var magnify = "linear"
        var minify = "linear"
        var mipmap: String?
    }

    struct ShaderTexture: Codable, Equatable {
        var asset: String
        var size: CGSize
    }

    struct ShaderBlend: Codable, Equatable {
        var source: String
        var destination: String
        var sourceAlpha: String
        var destinationAlpha: String
        var equation: String = "func-add"
        var equationAlpha: String = "func-add"
    }

    struct ShaderRecording: Codable, Equatable {
        var program: Int
        var uniform: String
        var component: Int
        var times: [Double]
        var values: [Double]
    }

    struct ShaderClock: Codable, Equatable {
        var program: Int
        var uniform: String
        var component: Int
        var start: Double
        var rate: Double
    }

    struct Fill: Codable, Equatable {
        var on = true
        var color: RGBA
        var gradient: Gradient?
        var image: ImageFill?
        var named: UUID? = nil
        var shader: ShaderFill? = nil
    }
}

/// Shader fills with passes into textures, kept in a design: what is written, what Bezzle 1.7
/// makes of it, and how a fill that builds on the frames before it counts its steps.
@MainActor
struct ShaderSceneTests {
    static let corners = ShaderAttribute.floats([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1], components: 2)

    /// A fill as 1.7 knows them, with everything 1.7 keeps.
    static var plain: ShaderFill {
        var draw = ShaderDraw(program: 0, uniforms: ["u_time": [1], "u_tint": [1, 0.5, 0.25]], attributes: ["a": corners, "b": ShaderAttribute(components: 4, constant: [0, 0, 0, 1])],
                              indices: Data([0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0]), mode: .triangleStrip, first: 0, count: 3)
        draw.textures = ["u_image": ShaderTexture(asset: "a.png", size: CGSize(width: 4, height: 4))]
        draw.flipsTextures = true
        draw.premultipliesTextures = true
        draw.sampling = ["u_image": ShaderSampling(wrapS: "repeat", mipmap: "linear")]
        draw.blend = ShaderBlend(source: "one", destination: "one-minus-src-alpha", sourceAlpha: "one", destinationAlpha: "one-minus-src-alpha")
        draw.viewport = CGRect(x: 1, y: 2, width: 30, height: 40)
        var fill = ShaderFill(size: CGSize(width: 64, height: 48), clear: [0, 0, 0, 1], programs: [ShaderProgram(vertex: "v", fragment: "f")], draws: [draw],
                              clocks: [ShaderClock(program: 0, uniform: "u_time", component: 0, start: 1, rate: 1)])
        fill.recordings = [ShaderRecording(program: 0, uniform: "u_tint", component: 1, times: [0, 1], values: [0.5, 0.6])]
        fill.speed = 0.5
        fill.at = 2
        fill.flippedX = true
        fill.alpha = false
        fill.premultipliedAlpha = false
        fill.antialias = false
        return fill
    }

    /// A fill with everything that came after 1.7.
    static var scene: ShaderFill {
        var fill = plain
        fill.clear = nil
        fill.targets = [ShaderTarget(width: 2, height: 2, format: "rgba16f", opaque: true, mipmapped: true, keeps: true, contents: Data(repeating: 7, count: 32)),
                        ShaderTarget(width: 64, height: 48, scales: true)]
        fill.passes = [ShaderPass(colors: [0, 1], depth: 0, clearColor: [0, 0, 0, 0], clearDepth: 1, clearStencil: 0, count: 1, mipmaps: [0]), ShaderPass(count: 1)]
        fill.texels = [ShaderTexels(width: 2, height: 1, format: "l8", bytes: Data([1, 2]))]
        fill.turn = [1, 0]
        fill.rate = 30
        var draw = fill.draws[0]
        draw.targets = ["u_before": 0]
        draw.texels = ["u_table": 0]
        draw.decodes = ["u_image"]
        draw.depth = ShaderDepth(compare: "lequal", writes: false, range: [0.1, 0.9])
        draw.stencil = ShaderStencil(front: .init(compare: "equal", reference: 1, readMask: 3, writeMask: 5, fail: "keep", depthFail: "incr-wrap", pass: "replace"), back: .init())
        draw.cull = "back"
        draw.clockwiseFront = true
        draw.channels = 7
        draw.scissor = CGRect(x: 0, y: 0, width: 8, height: 8)
        draw.offset = [1, 2]
        draw.instances = 3
        draw.blend?.color = [0.1, 0.2, 0.3, 0.4]
        draw.attributes["c"] = ShaderAttribute(components: 1, values: Data(repeating: 0, count: 12), divisor: 1)
        fill.draws = [draw, draw]
        return fill
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func aSceneGoesIntoADesignAndComesOutTheSame() throws {
        var fill = Fill(color: .white)
        fill.image = ImageFill(asset: "poster.png", size: CGSize(width: 64, height: 48))
        fill.shader = Self.scene
        #expect(Self.scene.beyondPlain && Self.scene.builds)
        let written = try Self.json(fill)
        // Under a key of its own, where Bezzle 1.7 does not look.
        #expect(written.contains("\"scene\":{") && !written.contains("\"shader\":"))
        let read = try JSONDecoder().decode(Fill.self, from: Data(written.utf8))
        #expect(read == fill && read.shader == Self.scene)
        // In a layer, and in a whole design.
        var layer = CanvasTests.rect("Glow", CGRect(x: 0, y: 0, width: 64, height: 48))
        layer.fill = fill
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(layer)).fill.shader == Self.scene)
        // The keys of its inputs are the film's, set for a moment: never written.
        fill.shader?.keyed = ["u_tint": MotionTrack([MotionKey(t: 0, v: [0, 0, 0]), MotionKey(t: 1, v: [1, 1, 1])])]
        #expect(try !Self.json(fill).contains("keyed"))
    }

    @Test func aPlainShaderIsWrittenAsBezzle17WritesIt() throws {
        var fill = Fill(color: .white)
        fill.image = ImageFill(asset: "poster.png", size: CGSize(width: 64, height: 48))
        fill.shader = Self.plain
        #expect(!Self.plain.beyondPlain && !Self.plain.builds)
        let written = try Self.json(fill)
        #expect(written.contains("\"shader\":{") && !written.contains("\"scene\""))
        // 1.7 reads all of it, and writes the very same.
        let old = try JSONDecoder().decode(Bezzle17.Fill.self, from: Data(written.utf8))
        #expect(old.shader != nil && old.shader?.draws.count == 1)
        #expect(try Self.json(old) == written)
        // And what 1.7 wrote is read as it was.
        #expect(try JSONDecoder().decode(Fill.self, from: Data(try Self.json(old).utf8)) == fill)
        // A fill with no shader at all, too.
        let bare = Fill(color: .white)
        #expect(try Self.json(try JSONDecoder().decode(Bezzle17.Fill.self, from: Data(try Self.json(bare).utf8))) == Self.json(bare))
    }

    @Test func bezzle17OpensADesignWithASceneAndShowsItsPicture() throws {
        var fill = Fill(color: .white)
        fill.image = ImageFill(asset: "poster.png", size: CGSize(width: 64, height: 48))
        fill.shader = Self.scene
        let old = try JSONDecoder().decode(Bezzle17.Fill.self, from: Data(try Self.json(fill).utf8))
        #expect(old.shader == nil && old.image == fill.image && old.color == fill.color)

        // Each thing 1.7 does not know sends the fill there by itself: 1.7 would draw it wrongly,
        // or, for a way of drawing or a key it cannot read, not open the design at all.
        let changes: [(String, (inout ShaderFill) -> Void)] = [
            ("targets", { $0.targets = [ShaderTarget(width: 1, height: 1)] }),
            ("passes", { $0.passes = [ShaderPass(count: 1)] }),
            ("texels", { $0.texels = [ShaderTexels(width: 1, height: 1, format: "r8", bytes: Data([0]))] }),
            ("turn", { $0.turn = [0] }),
            ("rate", { $0.rate = 30 }),
            ("a draw's targets", { $0.draws[0].targets = ["u": 0] }),
            ("a draw's texels", { $0.draws[0].texels = ["u": 0] }),
            ("decodes", { $0.draws[0].decodes = ["u"] }),
            ("depth", { $0.draws[0].depth = ShaderDepth() }),
            ("stencil", { $0.draws[0].stencil = ShaderStencil(front: .init()) }),
            ("cull", { $0.draws[0].cull = "back" }),
            ("clockwiseFront", { $0.draws[0].clockwiseFront = true }),
            ("channels", { $0.draws[0].channels = 7 }),
            ("scissor", { $0.draws[0].scissor = CGRect(x: 0, y: 0, width: 1, height: 1) }),
            ("offset", { $0.draws[0].offset = [1, 1] }),
            ("instances", { $0.draws[0].instances = 2 }),
            ("a divisor", { $0.draws[0].attributes["a"]?.divisor = 1 }),
            ("a line loop", { $0.draws[0].mode = .lineLoop }),
            ("a blend's constant", { $0.draws[0].blend?.color = [0, 0, 0, 0.5] }),
            ("a clock of one draw", { $0.clocks[0].draw = 0 }),
            ("a recording of one draw", { $0.recordings?[0].draw = 0 }),
        ]
        for (name, change) in changes {
            var shader = Self.plain
            change(&shader)
            #expect(shader.beyondPlain, "\(name)")
            var changed = fill
            changed.shader = shader
            let written = try Self.json(changed)
            #expect(written.contains("\"scene\":{") && !written.contains("\"shader\":"), "\(name)")
            #expect(try JSONDecoder().decode(Bezzle17.Fill.self, from: Data(written.utf8)).shader == nil, "\(name)")
            #expect(try JSONDecoder().decode(Fill.self, from: Data(written.utf8)).shader == shader, "\(name)")
        }
        // Why a way of drawing 1.7 does not know must not be under its key: it cannot read it.
        var loop = Self.plain
        loop.draws[0].mode = .lineLoop
        let under17sKey = #"{"on":true,"color":\#(try Self.json(RGBA.white)),"shader":\#(try Self.json(loop))}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Bezzle17.Fill.self, from: Data(under17sKey.utf8)) }

        // A scene from a Bezzle yet to come that this one cannot read leaves the picture, too.
        let later = #"{"on":true,"color":\#(try Self.json(RGBA.white)),"scene":{"size":[1,1],"somethingNew":true}}"#
        #expect(try JSONDecoder().decode(Fill.self, from: Data(later.utf8)).shader == nil)
    }

    @Test func aFillThatBuildsCountsItsSteps() throws {
        var fill = Self.scene
        fill.rate = nil
        // Sixty steps a second; step 0 at the moment it came in and before.
        #expect(fill.stepRate == 60)
        #expect(fill.step(at: -3) == 0 && fill.step(at: 0) == 0 && fill.step(at: 0.016) == 0 && fill.step(at: 1.0 / 60) == 1)
        #expect(fill.step(at: 1) == 60 && fill.step(at: 2.5) == 150)
        #expect(fill.step(at: 1e9) == ShaderFill.mostSteps && fill.step(at: .nan) == 0)
        // A step's own time is that of the frame the page would have drawn then: step 0 the
        // next one after it came in.
        #expect(abs(fill.time(ofStep: 0) - 1.0 / 60) < 1e-12 && abs(fill.time(ofStep: 89) - 1.5) < 1e-12)
        fill.rate = 30
        #expect(fill.stepRate == 30 && fill.step(at: 1) == 30)
        fill.rate = 100_000
        #expect(fill.stepRate == 240)
        // It moves by itself, with no clock at all.
        fill.clocks = []
        fill.recordings = nil
        #expect(fill.moves)
        fill.targets?[0].keeps = nil
        #expect(!fill.builds && !fill.moves)

        // Two textures drawn into in turn stand in each other's place every other step.
        let turning = Self.scene
        #expect(turning.target(0, after: 0) == 0 && turning.target(0, after: 1) == 1 && turning.target(0, after: 2) == 0)
        #expect(turning.target(1, after: 7) == 0 && turning.target(1, after: 36_000) == 1)
        var three = turning
        three.turn = [1, 2, 0]
        #expect((0..<7).map { three.target(0, after: $0) } == [0, 1, 2, 0, 1, 2, 0])
        three.turn = nil
        #expect(three.target(1, after: 5) == 1)
        // A turn that leads nowhere is none.
        three.turn = [5, 0, 1]
        #expect(three.target(0, after: 3) == 0)

        // Its draws by pass.
        let byPass = turning.drawsByPass
        #expect(byPass.count == 2 && byPass[0].draws.count == 1 && byPass[1].draws.count == 1 && byPass[0].pass.colors == [0, 1] && byPass[1].pass.colors == nil)
        #expect(Self.plain.drawsByPass.count == 1 && Self.plain.drawsByPass[0].pass.clearColor == [0, 0, 0, 1] && Self.plain.drawsByPass[0].draws.count == 1)
    }

    @Test func everyStepOfAFillThatBuildsHasItsInputsAsTheFilmKeysThem() throws {
        var fill = Self.scene
        fill.clocks = []
        fill.recordings = nil
        fill.speed = 1
        fill.at = 0
        fill.rate = nil
        var layer = CanvasTests.rect("Glow", CGRect(x: 0, y: 0, width: 64, height: 48))
        layer.fill.shader = fill
        // Its tint goes from 1, 0.5, 0.25 to 0.5, 0.5, 0 over a second.
        layer.poseInput("u_tint", [0.5, 0.5, 0], at: 1)
        let posed = layer.withInputs(at: 0.5)
        let shader = try #require(posed.fill.shader)
        // The keys themselves go with it, since the steps before this moment are drawn too.
        #expect(shader.keyed?["u_tint"] != nil && shader.draws[0].uniforms["u_tint"] == [1, 0.5, 0.25])
        let draw = shader.draws[0]
        let start = shader.uniforms(of: draw, at: 0)["u_tint"] ?? []
        let middle = shader.uniforms(of: draw, at: shader.time(ofStep: 29))["u_tint"] ?? []
        let end = shader.uniforms(of: draw, at: shader.time(ofStep: 59))["u_tint"] ?? []
        #expect(start == [1, 0.5, 0.25])
        #expect(middle.count == 3 && middle[0] < 1 && middle[0] > 0.5 && middle[1] == 0.5 && middle[2] > 0 && middle[2] < 0.25, "\(middle)")
        #expect(end.count == 3 && abs(end[0] - 0.5) < 1e-9 && abs(end[2]) < 1e-9, "\(end)")
        // The same moment gives the same fill, whatever moment it is asked at: one recording.
        #expect(layer.withInputs(at: 0.9).fill.shader == shader)
        // A fill that does not build is given its inputs for the moment, as before.
        var still = Self.plain
        still.clocks = []
        still.recordings = nil
        layer.fill.shader = still
        let set = layer.withInputs(at: 1).fill.shader
        #expect(set?.keyed == nil && set?.draws[0].uniforms["u_tint"].map { abs($0[0] - 0.5) < 1e-9 } == true)
    }
}
