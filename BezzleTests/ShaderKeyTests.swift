import Testing
import AppKit
@testable import Bezzle

/// A shader's inputs keyed in Animate as a layer's properties are: each key a change from what the
/// design sets, posed and keyed from the panel, on lines of their own in the timeline, drawn in
/// the film at every moment, and set by an assistant.
@MainActor
@Suite(.serialized)
struct ShaderKeyTests {
    /// A card painted by a shader with a tint and a strength, on artboard A.
    static var painted: [Node] {
        var card = CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80))
        card.fill.shader = ShaderFill.surface(fragment: "precision mediump float; uniform vec3 u_tint; uniform float u_strength; uniform vec2 u_resolution;"
                                              + " void main() { gl_FragColor = vec4(u_tint * u_strength, 1.0); }",
                                              size: CGSize(width: 240, height: 160), uniforms: ["u_tint": [0.2, 0.4, 0.8], "u_strength": [1]], time: nil)
        return [card, CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40))]
    }

    @Test func keysHoldChangesFromTheDesign() {
        var card = Self.painted[0]
        #expect(card.keyedShader?.inputs == ["u_resolution", "u_strength", "u_tint"])
        #expect(!card.isAnimated && card.inputTracks.isEmpty)
        // Posed later: it leaves the design at the start and is there by then.
        card.poseInput("u_tint", [1, 0.4, 0.8], at: 1)
        let keys = card[track: ShaderFill.inputTrack("u_tint")]?.keys ?? []
        #expect(keys.map(\.t) == [0, 1] && keys[0].given == true)
        #expect(keys[1].v.map { ($0 * 1000).rounded() / 1000 } == [0.8, 0, 0])
        #expect(card.isAnimated && card.shaderMoves && card.inputTracks == ["shader.u_tint"])
        #expect(card.shaderInput("u_tint", at: 0) == [0.2, 0.4, 0.8])
        #expect(card.shaderInput("u_tint", at: 1).map { $0.map { ($0 * 1000).rounded() / 1000 } } == [1, 0.4, 0.8])
        // The design set anew takes the motion with it.
        card.fill.shader = card.fill.shader?.setting("u_tint", to: [0, 0, 0])
        #expect(card.shaderInput("u_tint", at: 1).map { $0.map { ($0 * 1000).rounded() / 1000 } } == [0.8, 0, 0])
        // Posed, the layer's shader is where the keys have it, its own placement left to the film.
        let posed = card.posed(at: 1, own: false)
        #expect(posed.fill.shader?.value(of: "u_tint").map { $0.map { ($0 * 1000).rounded() / 1000 } } == [0.8, 0, 0])
        #expect(posed.frame == card.frame)
        // Taking the key away leaves one that says the design, which goes too.
        card.removeKeys(at: 1, tracks: ["shader.u_tint"])
        #expect(card.inputTracks.isEmpty && !card.isAnimated)
    }

    @Test func theFilmDrawsAKeyedShaderAgainAtEveryMoment() {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = Self.painted
        #expect(!board.filmPieces().contains { $0.layers == [board.children[0].id] })
        board.children[0].poseInput("u_strength", [0.25], at: 2)
        let piece = board.filmPieces().first { $0.layers == [board.children[0].id] }
        #expect(piece?.changes == true && piece?.kind == .layer)
        #expect(board.hasFilm && board.filmLength == 2)
        let subject = FilmPictures.subject(of: piece!, on: board, at: 2)
        #expect(subject.time == 2)
        #expect(subject.layers.first?.fill.shader?.value(of: "u_strength") == [0.25])
        #expect(subject.layers.first?.motion == nil)
    }

    @Test func thePanelPosesAndKeysInputs() {
        let f = FilmBench(Self.painted)
        f.step { f.store.selection = [f.id("Card")] }
        #expect(f.store.posedInputs == ["u_resolution", "u_strength", "u_tint"])
        #expect(f.store.inputKeyState("u_tint") == .none)
        f.step { f.store.seek(1.5) }
        f.step { f.store.poseInput("u_tint", number: 0, to: 0.9) }
        #expect(f.store.sharedInput("u_tint", 0).map { ($0 * 1000).rounded() / 1000 } == 0.9)
        #expect(f.store.inputKeyState("u_tint") == .here)
        #expect(f.undo.undoActionName == "Change Shader")
        // A key where there is none holds what the input is there; again, it goes.
        f.step { f.store.seek(0.75) }
        #expect(f.store.inputKeyState("u_tint") == .between)
        f.step { f.store.toggleInputKey("u_tint") }
        #expect(f.store.inputKeyState("u_tint") == .here)
        #expect(f.node("Card")[track: "shader.u_tint"]?.keys.count == 3)
        f.step { f.store.toggleInputKey("u_tint") }
        #expect(f.node("Card")[track: "shader.u_tint"]?.keys.count == 2)
        // The badge has no shader: picked with the card, there are no inputs to show.
        f.step { f.store.selection = [f.id("Card"), f.id("Badge")] }
        #expect(f.store.posedInputs.isEmpty)
    }

    @Test func theTimelineShowsInputsOnLinesOfTheirOwn() {
        let f = FilmBench(Self.painted)
        f.edit { $0.update(f.id("Card")) { $0.poseInput("u_strength", [0.5], at: 1) } }
        var rows = FilmRow.rows(of: f.board, open: [])
        let card = rows.first { $0.layer == f.id("Card") && !$0.single }
        #expect(card?.marks.map(\.t) == [0, 1])
        rows = FilmRow.rows(of: f.board, open: [f.id("Card")])
        let line = rows.first { $0.input == "u_strength" }
        #expect(line?.single == true && line?.name == "u_strength" && line?.marks.map(\.t) == [0, 1])
        #expect(line?.marks.first?.home == true && line?.marks.last?.home == false)
        // Its key, picked and dragged later, moves; Delete takes it away.
        let ref = FilmKeyRef(f.id("Card"), input: "u_strength", at: 1)
        #expect(line?.holds(ref) == true && card?.holds(ref) == true)
        #expect(rows.first { $0.property == .move }?.holds(ref) != true)
        f.step { f.store.film.keys = [ref] }
        f.step {
            f.store.beginGesture()
            f.store.retime([ref], by: 0.5)
            f.store.endGesture("Move Key")
        }
        #expect(f.node("Card")[track: "shader.u_strength"]?.keys.map(\.t) == [0, 1.5])
        f.step { f.store.film.keys = [FilmKeyRef(f.id("Card"), input: "u_strength", at: 1.5)] }
        f.step { f.store.removeFilmKeys() }
        #expect(f.node("Card").inputTracks.isEmpty)
    }

    @Test func theAssistantKeysInputsAndReadsThem() async throws {
        let bench = Bench(extra: Self.painted)
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
        let keyed = await call("animate", ["keys": [["layer": "Card", "input": "u_tint", "time": 0, "value": [0, 0, 0]],
                                                    ["layer": "Card", "input": "u_tint", "time": 2, "value": [0.6, -0.2, 0], "pace": "smooth"]]])
        #expect(!keyed.failed)
        let card = try #require(bench.node("Card"))
        #expect(card[track: "shader.u_tint"]?.keys.map(\.v) == [[0, 0, 0], [0.6, -0.2, 0]])
        #expect(card.shaderInput("u_tint", at: 2).map { $0.map { ($0 * 1000).rounded() / 1000 } } == [0.8, 0.2, 0.8])
        let read = await call("get_animation", ["artboard": "A"])
        let object = try JSONSerialization.jsonObject(with: Data(read.text.utf8)) as? [String: Any]
        let layer = (object?["layers"] as? [[String: Any]])?.first { $0["name"] as? String == "Card" }
        let tint = ((layer?["shader"] as? [String: Any])?["u_tint"]) as? [String: Any]
        #expect(tint?["design"] as? [Double] == [0.2, 0.4, 0.8])
        #expect((tint?["keys"] as? [[String: Any]])?.count == 2)
        // The wrong count, an input it has not, a layer with no shader: each said.
        #expect(await call("animate", ["keys": [["layer": "Card", "input": "u_tint", "time": 1, "value": 0.5]]]).failed)
        let none = await call("animate", ["keys": [["layer": "Card", "input": "u_glow", "time": 1, "value": 1]]])
        #expect(none.failed && none.text.contains("u_strength"))
        #expect(await call("animate", ["keys": [["layer": "Badge", "input": "u_tint", "time": 1, "value": [0, 0, 0]]]]).failed)
        // Taken away by name.
        let gone = await call("animate", ["remove": [["layer": "Card", "input": "u_tint"]]])
        #expect(!gone.failed && bench.node("Card")?.inputTracks.isEmpty == true)
    }

    @Test func twoPeopleKeyingOneInputBothKeepTheirKeys() {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = Self.painted
        var doc = BezzleDocument()
        doc.nodes = [board]
        let id = board.children[0].id
        // Both start from the same design, shared.
        var start = SharedDesign()
        start.absorb(FlatDesign(doc), since: FlatDesign(), by: "a", at: 1)
        var a = start, b = start
        var mine = doc, theirs = doc
        mine.update(id) { $0.poseInput("u_strength", [0.5], at: 1) }
        theirs.update(id) { $0.setInputKey("u_strength", change: [0.25], at: 2) }
        a.absorb(FlatDesign(mine), since: FlatDesign(doc), by: "a", at: 2)
        b.absorb(FlatDesign(theirs), since: FlatDesign(doc), by: "b", at: 3)
        a.merge(b)
        let merged = a.flatDesign().document()
        let keys = merged.node(id)?[track: "shader.u_strength"]?.keys ?? []
        #expect(keys.map(\.t) == [0, 1, 2])
        #expect(keys.map(\.v) == [[0], [-0.5], [0.25]])
    }
}
