import Testing
import AppKit
@testable import Bezzle

/// Animate through the AI server, called as the server calls it: an artboard's film read by an
/// assistant, and changed by it, each call one step of the undo history.
@MainActor
struct MotionMCPTests {
    /// On artboard A, as a screen has them: a title, two cards side by side, and a button below.
    let bench = Bench(extra: [
        CanvasTests.rect("Title", CGRect(x: 40, y: 30, width: 200, height: 30)),
        CanvasTests.rect("Card", CGRect(x: 40, y: 90, width: 140, height: 80)),
        CanvasTests.rect("Second", CGRect(x: 220, y: 90, width: 140, height: 80)),
        CanvasTests.rect("Button", CGRect(x: 40, y: 220, width: 120, height: 40)),
    ])
    let tools = MCPTools()

    init() {
        MCPTools.opened(bench.store)
    }

    /// What a tool answered, as text, and whether it was an error. Each test names its own
    /// design: tests run side by side, so the one "in front" may be another's.
    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// The names of the layers an answer lists under `key`, in its order.
    private func names(_ key: String, in answer: [String: Any]) -> [String] {
        (answer[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// The keys an answer lists for a property of a layer, by the layer's name.
    private func keys(_ property: String, of name: String, in answer: [String: Any]) -> [[String: Any]] {
        let layer = (answer["layers"] as? [[String: Any]] ?? []).first { $0["name"] as? String == name }
        return (layer?["tracks"] as? [String: Any])?[property] as? [[String: Any]] ?? []
    }

    private func warnings(_ answer: [String: Any]) -> String {
        (answer["warnings"] as? [String] ?? []).joined(separator: " ")
    }

    // MARK: Keys

    @Test func keysAreSetExactlyAndReadBack() async {
        let asked: [[String: Any]] = [
            ["layer": "Card", "property": "move", "time": 0, "value": [0, 40]],
            ["layer": "Card", "property": "move", "time": 0.5, "value": [0, 0]],
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 0.5, "value": 1],
            ["layers": ["Title", "Button"], "property": "scale", "time": 1, "value": 1.2],
            ["layer": "Button", "property": "turn", "time": 1, "value": [15]],
        ]
        let set = await call("animate", ["keys": asked])
        #expect(!set.failed, "\(set.text)")
        let card = bench.node("Card")!
        #expect(card[track: .move]!.keys.map(\.t) == [0, 0.5])
        #expect(card[track: .move]!.keys.map(\.v) == [[0, 40], [0, 0]])
        #expect(card[track: .move]!.keys.allSatisfy { $0.given == nil && $0.ease == nil })
        #expect(card.value(of: .fade, at: 0) == [0] && card.value(of: .fade, at: 2) == [1])
        // One number for a scale is both ways, and a key is one key: none is added for company.
        #expect(bench.node("Title")![track: .scale]!.keys.map(\.v) == [[1.2, 1.2]])
        #expect(bench.node("Button")![track: .scale]!.keys.count == 1)
        #expect(bench.node("Button")!.value(of: .turn, at: 1) == [15])
        #expect(bench.node("Second")!.motion == nil && bench.a.motion == nil)

        // The answer is the film for what changed, in the order the layers lie.
        let answered = json(set.text)
        #expect(names("layers", in: answered) == ["Title", "Card", "Button"])
        #expect((answered["done"] as? String)?.contains("7 keys set") == true)
        #expect(answered["camera"] == nil)
        // A key on its own moves nothing, which is said; two that differ are a motion.
        #expect(warnings(answered).contains("Title has one scale key, so it stays at [1.2, 1.2] for the whole film"))
        #expect(warnings(answered).contains("Button has one turn key") && !warnings(answered).contains("Card"))

        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect((read["artboard"] as? [String: Any])?["name"] as? String == "A")
        #expect(names("layers", in: read) == ["Title", "Card", "Button"])
        let move = keys("move", of: "Card", in: read)
        #expect(move.map { $0["time"] as? Double } == [0, 0.5])
        #expect(move.map { $0["value"] as? [Double] } == [[0, 40], [0, 0]])
        #expect(move.allSatisfy { $0["pace"] == nil && $0["given"] == nil })
        #expect(keys("fade", of: "Card", in: read).map { $0["value"] as? Double } == [0, 1])
        #expect(keys("scale", of: "Title", in: read).first?["value"] as? [Double] == [1.2, 1.2])
        #expect(read["length"] as? Double == 2 && read["automaticLength"] as? Bool == true)
        #expect(read["loops"] as? Bool == true)
        #expect(read["backdrop"] == nil && read["camera"] == nil && read["note"] == nil)
    }

    @Test func aShapeIsKeyedByItsOutlineAndItsLineByHowMuchIsDrawn() async throws {
        // The card's outline in its own points is its rectangle; at one second its top right corner is pulled out.
        let pulled = "M 0 0 L 160 -20 L 140 80 L 0 80 Z"
        let set = await call("animate", ["keys": [
            ["layer": "Card", "property": "shape", "time": 0, "path": "M 0 0 L 140 0 L 140 80 L 0 80 Z"],
            ["layer": "Card", "property": "shape", "time": 1, "path": pulled],
            ["layer": "Title", "property": "draw", "time": 0, "value": 0],
            ["layer": "Title", "property": "draw", "time": 0.8, "value": [0, 1]],
        ] as [[String: Any]]])
        #expect(!set.failed, "\(set.text)")
        let card = try #require(bench.node("Card"))
        let outline = try #require(card.outline(at: 1))
        #expect(outline.anchorPoints == [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: -20), CGPoint(x: 140, y: 80), CGPoint(x: 0, y: 80)])
        #expect(card.outline(at: 0) == card.ownOutline)
        #expect(bench.node("Title")?[track: .draw]?.keys.map(\.v) == [[0, 0], [0, 1]])

        // Read back as outlines, the design's beside them.
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        let shape = keys("shape", of: "Card", in: read)
        #expect(shape.map { $0["time"] as? Double } == [0, 1])
        #expect(shape.allSatisfy { $0["value"] == nil })
        let back = BezierPath(try #require(shape.last?["path"] as? String))
        #expect(back.anchorPoints == outline.anchorPoints)
        let layer = (read["layers"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "Card" }
        #expect(BezierPath(try #require(layer?["outline"] as? String)) == card.ownOutline)
        #expect(keys("draw", of: "Title", in: read).map { $0["value"] as? [Double] } == [[0, 0], [0, 1]])

        // Another number of points is no shape key: the answer gives the outline to start from.
        let wrong = await call("animate", ["keys": [["layer": "Second", "property": "shape", "time": 1, "path": "M 0 0 L 10 0 L 5 8 Z"]]])
        #expect(wrong.failed && wrong.text.contains("4 points") && wrong.text.contains("M"))
        #expect(bench.node("Second")?.motion == nil)
        let raw = await call("animate", ["keys": [["layer": "Second", "property": "shape", "time": 1, "value": [1, 2]]]])
        #expect(raw.failed && raw.text.contains("path"))
    }

    @Test func anArtboardWithNoFilmSaysSo() async {
        let read = json(await call("get_animation", ["artboard": "Card"]).text)
        // A layer on the artboard names it too.
        #expect((read["artboard"] as? [String: Any])?["name"] as? String == "A")
        // And so does layer, as the tools for an artboard's grid and guides call it.
        let other = json(await call("get_animation", ["layer": "B"]).text)
        #expect((other["artboard"] as? [String: Any])?["name"] as? String == "B")
        #expect(read["layers"] == nil && read["camera"] == nil)
        #expect((read["note"] as? String)?.contains("Nothing on A moves") == true)
        #expect(read["length"] as? Double == MotionTiming.shortest)
    }

    @Test func aFilmPosedByHandIsGoneOnWith() async {
        let id = bench.node("Card")!.id
        bench.step { bench.store.edit("Pose") { doc in doc.update(id) { $0.pose(.move, [30, 0], at: 1) } } }
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        let move = keys("move", of: "Card", in: read)
        #expect(move.map { $0["time"] as? Double } == [0, 1])
        // The design Bezzle put there for company is marked.
        #expect(move.first?["given"] as? Bool == true && move.last?["given"] == nil)

        // A key set past it leaves what is there as it was.
        let on = await call("animate", ["keys": [["layer": "Card", "property": "move", "time": 2, "value": [30, 60]]]])
        #expect(!on.failed, "\(on.text)")
        #expect(bench.node("Card")![track: .move]!.keys.map(\.t) == [0, 1, 2])
        #expect(bench.node("Card")![track: .move]!.keys[0].given == true)
        // And a key set where one is changes that one, which is anyone's from then on.
        _ = await call("animate", ["keys": [["layer": "Card", "property": "move", "time": 0, "value": [0, 10]]]])
        let first = bench.node("Card")![track: .move]!.keys[0]
        #expect(first.v == [0, 10] && first.given == nil)
        #expect(bench.node("Card")![track: .move]!.keys.count == 3)
    }

    @Test func aValuePastWhatShowsIsKeptWithinItAndSaid() async {
        let set = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 0, "value": 1.4]]])
        #expect(!set.failed, "\(set.text)")
        #expect(bench.node("Card")![track: .fade]!.keys.map(\.v) == [[1]])
        #expect(warnings(json(set.text)).contains("kept as 1"))
    }

    @Test func aNameOnSeveralArtboardsIsTheOneOnTheFilmsArtboard() async {
        bench.step { bench.store.add(CanvasTests.rect("Card", CGRect(x: 640, y: 140, width: 100, height: 60)), onto: bench.b.id) }
        let onB = bench.b.children[0].id
        let set = await call("animate", ["artboard": "B", "keys": [["layer": "Card", "property": "fade", "time": 0, "value": 0.5]]])
        #expect(!set.failed, "\(set.text)")
        #expect(bench.store.doc.node(onB)?[track: .fade] != nil)
        #expect(bench.a.children.allSatisfy { $0.motion == nil })
        // Without the artboard, the name alone does not say which.
        let unsure = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 0, "value": 0.5]]])
        #expect(unsure.failed && unsure.text.contains("2 layers are called"), "\(unsure.text)")
    }

    // MARK: The camera

    @Test func theCameraIsKeyedOnTheArtboard() async {
        let asked: [[String: Any]] = [
            ["property": "cameraZoom", "time": 0, "value": 1.6],
            ["property": "cameraTilt", "time": 0, "value": 40],
            ["property": "cameraMove", "time": 0, "value": [0, 60]],
            ["property": "cameraZoom", "time": 2, "value": 1],
            ["property": "cameraTilt", "time": 2, "value": 0],
            ["property": "cameraMove", "time": 2, "value": [0, 0]],
        ]
        let flown = await call("animate", ["artboard": "A", "keys": asked])
        #expect(!flown.failed, "\(flown.text)")
        let start = bench.a.camera(at: 0)
        #expect(start.zoom == 1.6 && start.tilt == 40 && start.x == 0 && start.y == 60)
        #expect(bench.a.camera(at: 2).isRest)
        #expect(bench.a.hasCamera && !bench.a.holdsMotion)
        #expect(bench.b.motion == nil)
        let answered = json(flown.text)
        let camera = answered["camera"] as? [String: Any]
        #expect(Set((camera ?? [:]).keys) == ["cameraMove", "cameraZoom", "cameraTilt"])
        #expect((camera?["cameraMove"] as? [[String: Any]])?.first?["value"] as? [Double] == [0, 60])
        #expect((camera?["cameraZoom"] as? [[String: Any]])?.last?["value"] as? Double == 1)
        #expect(answered["layers"] == nil)

        // With no artboard named and no layer, it is the selection's artboard.
        bench.store.selection = [bench.b.id]
        let other = await call("animate", ["keys": [["property": "cameraRoll", "time": 1, "value": 8]]])
        #expect(!other.failed, "\(other.text)")
        #expect(bench.b.camera(at: 1).roll == 8)
        #expect(bench.a[track: .cameraRoll] == nil)

        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect((read["camera"] as? [String: Any])?.count == 3)
        #expect(names("otherFilms", in: read) == ["B"])
    }

    // MARK: Pace

    @Test func aPaceIsChosenKeptOrHandedBack() async {
        let asked: [[String: Any]] = [
            ["layer": "Card", "property": "scale", "time": 0, "value": [0.6, 0.6]],
            ["layer": "Card", "property": "scale", "time": 0.6, "value": 1, "pace": "spring", "bounce": 0.42],
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 0.3, "value": 1, "pace": "linear"],
            ["layer": "Card", "property": "turn", "time": 0, "value": 0],
            ["layer": "Card", "property": "turn", "time": 1, "value": 90, "pace": "hold"],
            ["layer": "Second", "property": "lift", "time": 0, "value": 0, "pace": "auto"],
            ["layer": "Second", "property": "lift", "time": 0.5, "value": 20, "pace": "spring"],
            ["layer": "Second", "property": "blur", "time": 0, "value": 12, "pace": "smooth"],
            ["layer": "Second", "property": "blur", "time": 0.4, "value": 0, "pace": "out"],
            ["layer": "Second", "property": "swing", "time": 0.4, "value": 30, "pace": "in"],
        ]
        let set = await call("animate", ["keys": asked])
        #expect(!set.failed, "\(set.text)")
        let card = bench.node("Card")!, second = bench.node("Second")!
        #expect(card[track: .scale]!.keys.map(\.ease) == [nil, .spring(0.42)])
        #expect(card[track: .fade]!.keys[1].ease == .linear)
        #expect(card[track: .turn]!.keys[1].ease == .hold)
        // Held, it stays as it was and then is there at once.
        #expect(card.value(of: .turn, at: 0.9) == [0] && card.value(of: .turn, at: 1) == [90])
        #expect(card.value(of: .fade, at: 0.15)[0] == 0.5)
        // Auto is no pace of its own, and a spring with no bounce said has the usual one.
        #expect(second[track: .lift]!.keys.map(\.ease) == [nil, .spring()])
        #expect(second[track: .blur]!.keys.map(\.ease) == [.smooth, .easeOut])
        #expect(second[track: .swing]!.keys[0].ease == .easeIn)

        let read = json(await call("get_animation", ["artboard": "A"]).text)
        let scale = keys("scale", of: "Card", in: read)
        #expect(scale[0]["pace"] == nil && scale[0]["bounce"] == nil)
        #expect(scale[1]["pace"] as? String == "spring" && scale[1]["bounce"] as? Double == 0.42)
        #expect(keys("turn", of: "Card", in: read)[1]["pace"] as? String == "hold")
        #expect(keys("blur", of: "Second", in: read).map { $0["pace"] as? String } == ["smooth", "out"])
        #expect(keys("swing", of: "Second", in: read)[0]["pace"] as? String == "in")
        #expect(keys("lift", of: "Second", in: read)[1]["bounce"] as? Double == 0.3)

        // A key set again without a pace keeps the one it has.
        _ = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 0.3, "value": 0.9]]])
        #expect(bench.node("Card")![track: .fade]!.keys[1] == MotionKey(t: 0.3, v: [0.9], ease: .linear))
        // And auto hands it back to Bezzle.
        _ = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 0.3, "value": 0.9, "pace": "auto"]]])
        #expect(bench.node("Card")![track: .fade]!.keys[1].ease == nil)
        let again = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(keys("fade", of: "Card", in: again)[1]["pace"] == nil)
    }

    // MARK: Moves made in one go

    @Test func aMoveBringsLayersOnOneAfterAnotherAsTheyAreRead() async {
        let risen = await call("animate", ["moves": [["move": "rise", "layers": ["Button", "Second", "Card", "Title"], "time": 0.2, "apart": 0.1]]])
        #expect(!risen.failed, "\(risen.text)")
        // From the top down and across, whatever order they were named in.
        #expect(bench.node("Title")![track: .fade]!.start == 0.2)
        #expect(bench.node("Card")![track: .fade]!.start == 0.3)
        #expect(bench.node("Second")![track: .fade]!.start == 0.4)
        #expect(bench.node("Button")![track: .fade]!.start == 0.5)
        let card = bench.node("Card")!
        #expect(card.value(of: .move, at: 0) == [0, 28] && card.value(of: .fade, at: 0.3) == [0])
        #expect(card.value(of: .move, at: 0.8) == [0, 0])
        #expect(card.value(of: .fade, at: 2) == [1])
        let answered = json(risen.text)
        #expect((answered["done"] as? String)?.contains("rise given to 4 layers") == true)
        #expect(names("layers", in: answered) == ["Title", "Card", "Second", "Button"])
        #expect(keys("move", of: "Card", in: answered).map { $0["time"] as? Double } == [0.3, 0.8])
        #expect(keys("move", of: "Card", in: answered)[1]["pace"] as? String == "out")

        // Going is the same backwards, and the film runs as long as its last key.
        let gone = await call("animate", ["moves": [["move": "fade", "layers": ["Title"], "time": 3, "going": true]]])
        #expect(!gone.failed, "\(gone.text)")
        #expect(bench.node("Title")!.value(of: .fade, at: 3) == [1])
        #expect(bench.node("Title")!.value(of: .fade, at: 3.4) == [0])
        #expect(json(gone.text)["length"] as? Double == 3.5)

        // With no layers named, a move is the selection's.
        bench.store.selection = [bench.node("Button")!.id]
        let popped = await call("animate", ["moves": [["move": "pop", "time": 1]]])
        #expect(!popped.failed, "\(popped.text)")
        let scale = bench.node("Button")![track: .scale]!
        #expect(scale.keys.map(\.t) == [1, 1.6] && scale.keys.map(\.v) == [[0.6, 0.6], [1, 1]])
        #expect(scale.keys[1].ease == .spring(0.42))
    }

    @Test func movesAndKeysGoTogetherTheKeysLast() async {
        // The move's own key where the card arrives is changed by the key given with it.
        let both = await call("animate", [
            "moves": [["move": "rise", "layers": ["Card"]]],
            "keys": [["layer": "Card", "property": "move", "time": 0, "value": [0, 60]]],
        ])
        #expect(!both.failed, "\(both.text)")
        #expect(bench.node("Card")![track: .move]!.keys.map(\.v) == [[0, 60], [0, 0]])
        #expect(bench.node("Card")![track: .fade]!.keys.count == 2)
    }

    // MARK: Taking away

    @Test func keysTracksAndWholeMotionsAreTakenAway() async {
        let asked: [[String: Any]] = [
            ["layer": "Card", "property": "move", "time": 0, "value": [0, 40]],
            ["layer": "Card", "property": "move", "time": 0.5, "value": [0, 10]],
            ["layer": "Card", "property": "move", "time": 1, "value": [0, 0]],
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 0.5, "value": 1],
            ["layer": "Title", "property": "fade", "time": 0, "value": 0],
            ["layer": "Title", "property": "fade", "time": 0.4, "value": 1],
            ["layer": "Second", "property": "move", "time": 0, "value": [10, 0]],
            ["layer": "Second", "property": "move", "time": 1, "value": [20, 0]],
            ["layer": "Second", "property": "turn", "time": 0, "value": 15],
            ["layer": "Second", "property": "turn", "time": 1, "value": 30],
            ["property": "cameraZoom", "time": 0, "value": 1.5],
            ["property": "cameraZoom", "time": 2, "value": 1],
            ["property": "cameraRoll", "time": 0, "value": 5],
            ["property": "cameraRoll", "time": 2, "value": 0],
        ]
        let set = await call("animate", ["artboard": "A", "length": 4, "keys": asked])
        #expect(!set.failed, "\(set.text)")

        // One key.
        let one = await call("animate", ["remove": [["layer": "Card", "property": "move", "time": 0.5]]])
        #expect(!one.failed, "\(one.text)")
        #expect(bench.node("Card")![track: .move]!.keys.map(\.t) == [0, 1])
        #expect((json(one.text)["done"] as? String)?.contains("1 key taken away") == true)
        #expect(keys("move", of: "Card", in: json(one.text)).count == 2)

        // A property's whole track; the layer's others stay.
        let track = await call("animate", ["remove": [["layer": "Card", "property": "move"]]])
        #expect(!track.failed, "\(track.text)")
        #expect(bench.node("Card")![track: .move] == nil)
        #expect(bench.node("Card")![track: .fade]!.keys.count == 2)

        // A layer's keys at one moment, whatever they are of.
        let moment = await call("animate", ["remove": [["layer": "Second", "time": 0]]])
        #expect(!moment.failed, "\(moment.text)")
        #expect(bench.node("Second")![track: .move]!.keys.map(\.t) == [1])
        #expect(bench.node("Second")![track: .turn]!.keys.map(\.t) == [1])

        // A key of the camera's: what is left of its roll only says what the design does, and goes.
        let roll = await call("animate", ["artboard": "A", "remove": [["property": "cameraRoll", "time": 0]]])
        #expect(!roll.failed, "\(roll.text)")
        #expect(bench.a[track: .cameraRoll] == nil)
        #expect(bench.a[track: .cameraZoom]!.keys.count == 2)
        #expect((json(roll.text)["camera"] as? [String: Any])?.count == 1)

        // A key that is not there is said, and nothing else is touched.
        let missing = await call("animate", ["remove": [["layer": "Title", "property": "fade", "time": 3]]])
        #expect(!missing.failed, "\(missing.text)")
        #expect(warnings(json(missing.text)).contains("Title has no fade key at 3 s: its keys are at 0, 0.4 s."))
        #expect(warnings(json(missing.text)).contains("Nothing changed"))
        #expect(bench.node("Title")![track: .fade]!.keys.count == 2)

        // All motion of layers.
        let layers = await call("animate", ["remove": [["layers": ["Card", "Second"]]]])
        #expect(!layers.failed, "\(layers.text)")
        #expect(bench.node("Card")!.motion == nil && bench.node("Second")!.motion == nil)
        #expect(bench.node("Title")![track: .fade] != nil && bench.a.hasCamera)
        #expect(names("asDesigned", in: json(layers.text)) == ["Card", "Second"])
        #expect(json(layers.text)["layers"] == nil)

        // All of the camera's, which leaves the layers' and what the film was set to.
        let camera = await call("animate", ["artboard": "A", "remove": [["property": "camera"]]])
        #expect(!camera.failed, "\(camera.text)")
        #expect(bench.a.motion == nil && bench.a.film?.length == 4)
        #expect(bench.node("Title")![track: .fade] != nil)

        // The whole artboard's: its layers', its camera's, and its film's settings.
        _ = await call("animate", ["artboard": "A", "keys": [["property": "cameraTilt", "time": 1, "value": 30]]])
        let all = await call("animate", ["artboard": "A", "remove": "all"])
        #expect(!all.failed, "\(all.text)")
        #expect(bench.store.doc.allNodes.allSatisfy { $0.motion == nil && $0.film == nil })
        #expect((json(all.text)["done"] as? String)?.contains("All motion taken from A") == true)
        #expect(json(all.text)["automaticLength"] as? Bool == true)
    }

    @Test func removingComesFirstAndTheArtboardNamedAloneIsAllOfIt() async {
        _ = await call("animate", ["artboard": "A", "loop": false, "keys": [
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 1, "value": 1],
            ["property": "cameraZoom", "time": 0, "value": 2],
        ]])
        // Everything goes, and what the same call sets is the film from then on.
        let fresh = await call("animate", ["remove": [["layer": "A"]], "keys": [["layer": "Title", "property": "turn", "time": 0, "value": 10]]])
        #expect(!fresh.failed, "\(fresh.text)")
        #expect(bench.node("Card")!.motion == nil && bench.a.motion == nil && bench.a.film == nil)
        #expect(bench.node("Title")![track: .turn]!.keys.count == 1)
        // All of it is listed, as nothing of the film is as it was.
        #expect(names("layers", in: json(fresh.text)) == ["Title"])
    }

    // MARK: The film

    @Test func theFilmIsSetAndHandedBackToBezzle() async {
        let set = await call("animate", ["artboard": "A", "length": 4, "loop": false, "backdrop": "#101418"])
        #expect(!set.failed, "\(set.text)")
        #expect(bench.a.film == Film(length: 4, once: true, backdrop: RGBA(hex: "101418")))
        #expect(bench.a.filmLength == 4)
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["length"] as? Double == 4 && read["automaticLength"] == nil)
        #expect(read["loops"] as? Bool == false)
        #expect(read["backdrop"] as? String == "#101418")

        // A key past the end is set all the same, and said.
        let late = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 6, "value": 0]]])
        #expect(!late.failed, "\(late.text)")
        #expect(warnings(json(late.text)).contains("The film ends at 4 s"))

        // Only what is given changes.
        _ = await call("animate", ["artboard": "A", "loop": true])
        #expect(bench.a.film == Film(length: 4, backdrop: RGBA(hex: "101418")))
        // Null hands a setting back, and so does "auto".
        let back = await call("animate", ["artboard": "A", "length": NSNull(), "backdrop": "auto"])
        #expect(!back.failed, "\(back.text)")
        #expect(bench.a.film == nil)
        // To the next half second past the last key.
        #expect(json(back.text)["length"] as? Double == 6 && json(back.text)["automaticLength"] as? Bool == true)
        #expect(json(back.text)["loops"] as? Bool == true && json(back.text)["backdrop"] == nil)
    }

    // MARK: Mistakes

    @Test func mistakesAreNamedAndChangeNothing() async {
        bench.step { bench.store.edit("Add") { $0.nodes.append(CanvasTests.rect("Loose", CGRect(x: 0, y: 500, width: 40, height: 40))) } }
        bench.step { bench.store.add(CanvasTests.rect("Far", CGRect(x: 620, y: 120, width: 40, height: 40)), onto: bench.b.id) }
        bench.store.selection = []
        let before = bench.store.doc
        func key(_ fields: [String: Any]) -> [String: Any] { ["keys": [fields]] }
        func onA(_ what: String, _ fields: Any) -> [String: Any] { ["artboard": "A", what: fields] }
        let good: [String: Any] = ["layer": "Card", "property": "fade", "time": 0, "value": 0]
        let mistakes: [(what: String, asked: [String: Any], says: String)] = [
            ("an unknown layer", key(["layer": "Nobody", "property": "fade", "time": 0, "value": 0]), "There is no layer \"Nobody\""),
            ("an unknown layer on a named artboard", onA("keys", [["layer": "Nobody", "property": "fade", "time": 0, "value": 0]]), "There is no layer \"Nobody\""),
            ("a layer on no artboard", key(["layer": "Loose", "property": "fade", "time": 0, "value": 0]), "Loose is not on an artboard"),
            ("a layer on no artboard, the artboard named", onA("keys", [["layer": "Loose", "property": "fade", "time": 0, "value": 0]]), "Loose is not on an artboard"),
            ("a layer on another artboard", onA("keys", [["layer": "Far", "property": "fade", "time": 0, "value": 0]]), "Far is on B, not on A"),
            ("an artboard as the layer", key(["layer": "B", "property": "fade", "time": 0, "value": 0]), "B is an artboard"),
            ("a camera property on a layer", key(["layer": "Card", "property": "cameraZoom", "time": 0, "value": 2]), "cameraZoom is the camera's"),
            ("a layer property on the camera", onA("keys", [["property": "move", "time": 0, "value": [0, 10]]]), "move is a layer's"),
            ("one number for a move", key(["layer": "Card", "property": "move", "time": 0, "value": 10]), "move takes two numbers, [x, y], and 1 were given"),
            ("two numbers for a fade", key(["layer": "Card", "property": "fade", "time": 0, "value": [0, 1]]), "fade takes one number, and 2 were given"),
            ("three numbers for a scale", key(["layer": "Card", "property": "scale", "time": 0, "value": [1, 2, 3]]), "scale takes two numbers, [x, y], or one for both, and 3 were given"),
            ("three numbers for where the camera looks", onA("keys", [["property": "cameraMove", "time": 0, "value": [1, 2, 3]]]), "cameraMove takes two numbers"),
            ("a value that is no number", key(["layer": "Card", "property": "fade", "time": 0, "value": "half"]), "keys[0].value should be a number"),
            ("no value", key(["layer": "Card", "property": "fade", "time": 0]), "keys[0].value is missing"),
            ("a time before the start", key(["layer": "Card", "property": "fade", "time": -0.5, "value": 0]), "keys[0].time is -0.5"),
            ("no time", key(["layer": "Card", "property": "fade", "value": 0]), "keys[0] needs time"),
            ("an unknown property", key(["layer": "Card", "property": "opacity", "time": 0, "value": 0]), "there is no property \"opacity\""),
            ("no property", key(["layer": "Card", "time": 0, "value": 0]), "keys[0] needs property"),
            ("an unknown pace", key(["layer": "Card", "property": "fade", "time": 0, "value": 0, "pace": "ease-out"]), "pace is one of auto, smooth, in, out, linear, spring, hold"),
            ("a bounce without a spring", key(["layer": "Card", "property": "fade", "time": 0, "value": 0, "pace": "out", "bounce": 0.2]), "bounce goes with pace spring"),
            ("a bounce past 1", key(["layer": "Card", "property": "fade", "time": 0, "value": 0, "pace": "spring", "bounce": 2]), "bounce goes from 0"),
            ("a word a key does not take", key(["layer": "Card", "property": "fade", "time": 0, "value": 0, "ease": "out"]), "keys[0] has no ease"),
            ("a mistake after a key that is fine", ["keys": [good, ["layer": "Card", "property": "fade", "time": -1, "value": 1]]], "keys[1].time is -1"),
            ("an unknown move", ["moves": [["move": "wiggle", "layers": ["Card"]]]], "move is one of fade, rise, drop, slide, pop, zoom, flip, focus"),
            ("a move before the start", ["moves": [["move": "rise", "layers": ["Card"], "time": -1]]], "moves[0].time is -1"),
            ("a move with layers coming before one another", ["moves": [["move": "rise", "layers": ["Card"], "apart": -0.1]]], "apart is the seconds"),
            ("a move for a layer on no artboard", ["moves": [["move": "rise", "layers": ["Loose"]]]], "Loose is not on an artboard"),
            ("a move with nothing selected", onA("moves", [["move": "rise"]]), "nothing is selected"),
            ("a removal that names nothing", onA("remove", [[String: Any]()]), "names nothing to take away"),
            ("a removal of the camera's from a layer", ["remove": [["layer": "Card", "property": "cameraZoom"]]], "cameraZoom is the camera's"),
            ("a removal of a layer's from the camera", onA("remove", [["property": "fade"]]), "fade is a layer's"),
            ("a removal before the start", ["remove": [["layer": "Card", "time": -2]]], "remove[0].time is -2"),
            ("a removal by an unknown word", onA("remove", "everything"), "remove is \"all\""),
            ("a film of no length", onA("length", 0), "more than 0"),
            ("a backdrop that is no colour", onA("backdrop", "reddish"), "not a colour"),
            ("nothing asked for", [:], "Give keys, moves or remove"),
        ]
        for mistake in mistakes {
            let answer = await call("animate", mistake.asked)
            #expect(answer.failed, "\(mistake.what): \(answer.text)")
            #expect(answer.text.contains(mistake.says), "\(mistake.what): \(answer.text)")
        }
        #expect(bench.store.doc == before)
        let read = await call("get_animation", ["artboard": "Loose"])
        #expect(read.failed && read.text.contains("Loose is not on an artboard"), "\(read.text)")
    }

    // MARK: Undo

    @Test func oneCallIsOneStepToUndo() async {
        let before = bench.store.doc
        let asked: [String: Any] = [
            "artboard": "A",
            "moves": [["move": "rise", "layers": ["Title", "Card", "Second"], "apart": 0.08]],
            "keys": [
                ["layer": "Button", "property": "scale", "time": 0.4, "value": 0.6],
                ["layer": "Button", "property": "scale", "time": 1, "value": 1, "pace": "spring"],
                ["property": "cameraZoom", "time": 0, "value": 1.3],
                ["property": "cameraZoom", "time": 1.5, "value": 1],
            ],
            "length": 3, "loop": false,
        ]
        let answer = await call("animate", asked)
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.undo.groupingLevel == 0)
        let after = bench.store.doc
        #expect(after != before)
        #expect(bench.node("Title")!.isAnimated && bench.node("Button")!.isAnimated && bench.a.hasCamera && bench.a.film?.once == true)
        // The same again changes nothing, and leaves no step of its own.
        let again = await call("animate", asked)
        #expect(!again.failed && warnings(json(again.text)).contains("Nothing changed"), "\(again.text)")
        #expect(bench.store.doc == after)

        // All of it is taken back at once, and comes back at once.
        let undone = json(await call("undo", [:]).text)
        #expect((undone["undid"] as? [String])?.count == 1)
        #expect(bench.store.doc == before)
        #expect(!bench.undo.canUndo)
        bench.undo.redo()
        #expect(bench.store.doc == after)
    }

    @Test func aCallIsUndoneAndDoneAgainFromTheApp() async {
        let store = bench.store, before = store.doc
        let asked: [String: Any] = [
            "artboard": "A",
            "keys": [
                ["layer": "Card", "property": "move", "time": 0, "value": [0, 40]],
                ["layer": "Card", "property": "move", "time": 2.5, "value": [0, 0]],
            ],
            "length": 3, "playhead": 2.5,
        ]
        let answer = await call("animate", asked)
        store.glide.stop()
        #expect(!answer.failed, "\(answer.text)")
        let after = store.doc
        #expect(store.animating && store.filmTime == 2.5)
        // One step in the Edit menu, named as any change the assistant makes.
        #expect(bench.undo.canUndo && bench.undo.undoActionName == "Change")
        bench.undo.undo()
        #expect(store.doc == before && !bench.undo.canUndo && bench.undo.canRedo)
        // Showing the film was no part of the step: the window stays in Animate, and the playhead
        // is read within the film as it is again, two seconds long.
        #expect(store.animating && store.film.board == bench.a.id)
        #expect(store.filmTime == 2 && bench.a.filmLength == 2)
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["playhead"] as? Double == 2 && read["layers"] == nil && read["length"] as? Double == 2)
        bench.undo.redo()
        #expect(store.doc == after && bench.undo.canUndo && !bench.undo.canRedo)
        #expect(json(await call("get_animation", ["artboard": "A"]).text)["length"] as? Double == 3)
        // Undone through the server, likewise.
        let undone = json(await call("undo", [:]).text)
        #expect((undone["undid"] as? [String])?.count == 1 && store.doc == before)
    }

    // MARK: Showing the film

    /// Card rising over a second, in a film of three.
    private func rising() async {
        let set = await call("animate", ["artboard": "A", "length": 3, "keys": [
            ["layer": "Card", "property": "move", "time": 0, "value": [0, 40]],
            ["layer": "Card", "property": "move", "time": 1, "value": [0, 0]],
        ]])
        #expect(!set.failed, "\(set.text)")
    }

    @Test func aPlayheadShowsTheFilmInAnimatePosedThere() async {
        let store = bench.store
        await rising()
        // Setting keys shows nothing, and reading says the window is not in Animate.
        #expect(!store.animating && store.film.board == nil)
        var read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["animating"] as? Bool == false && read["playhead"] == nil && read["playing"] == nil)

        let before = store.doc
        let shown = await call("animate", ["artboard": "A", "playhead": 0.5])
        // The view's glide to the film's artboard is no part of what is tested here.
        store.glide.stop()
        #expect(!shown.failed, "\(shown.text)")
        #expect(store.animating && store.canvasMode == .animate && store.film.board == bench.a.id)
        #expect(store.filmTime == 0.5 && store.film.live == 0.5 && store.film.head == 0.5 && !store.film.playing)
        // There the layer is half way, as the person sees it.
        #expect(store.filmBoard?.descendant(bench.node("Card")!.id)?.pose(at: store.filmTime).move.y ?? 0 > 0)
        let answer = json(shown.text)
        #expect(answer["animating"] as? Bool == true && answer["playhead"] as? Double == 0.5 && answer["playing"] == nil)
        #expect(answer["done"] as? String == "Shown in Animate, the playhead at 0.5 s.")
        // Nothing of the design changed, which is not called nothing done, and is no step to undo.
        #expect(store.doc == before && answer["warnings"] == nil && answer["layers"] == nil)
        #expect((answer["artboard"] as? [String: Any])?["name"] as? String == "A" && answer["length"] as? Double == 3)
        read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["animating"] as? Bool == true && read["playhead"] as? Double == 0.5 && read["playing"] == nil)
        // Another artboard's film is not the one shown.
        let other = json(await call("get_animation", ["artboard": "B"]).text)
        #expect(other["animating"] as? Bool == true && other["playhead"] == nil && other["playing"] == nil)

        // Past the film's end it rests at the end, which is said.
        let past = json(await call("animate", ["artboard": "A", "playhead": 9]).text)
        #expect(store.filmTime == 3 && past["playhead"] as? Double == 3)
        #expect(warnings(past).contains("playhead 9 s is past the film's end: it rests at the end, 3 s."), "\(past)")
        #expect(past["done"] as? String == "Shown in Animate, the playhead at 3 s.")
        // At the start, and to the thousandth of a second.
        _ = await call("animate", ["artboard": "A", "playhead": 0])
        #expect(store.filmTime == 0)
        _ = await call("animate", ["artboard": "A", "playhead": 1.23456])
        #expect(store.filmTime == 1.235)

        // One undo takes back the keys, the only step there is.
        bench.undo.undo()
        #expect(!bench.undo.canUndo && bench.node("Card")!.motion == nil)
    }

    @Test func playShowsTheFilmPlayingAndStopsIt() async throws {
        let store = bench.store
        await rising()
        _ = await call("animate", ["artboard": "A", "playhead": 1.2])
        store.glide.stop()
        // From the start, wherever the playhead rested.
        let played = await call("animate", ["artboard": "A", "play": true])
        #expect(!played.failed, "\(played.text)")
        #expect(store.animating && store.film.playing && store.film.pass?.from == 0 && store.film.live == 0)
        var answer = json(played.text)
        #expect(answer["animating"] as? Bool == true && answer["playing"] as? Bool == true && answer["playhead"] as? Double == 0)
        #expect(answer["done"] as? String == "Shown in Animate, playing from the start." && answer["warnings"] == nil)
        // While it plays, reading says where the playhead shows.
        let began = try #require(store.film.pass?.began)
        #expect(store.filmStep(began + 0.7))
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["playing"] as? Bool == true && read["playhead"] as? Double == 0.7)
        // Stopped, it rests where it was.
        answer = json(await call("animate", ["artboard": "A", "play": false]).text)
        #expect(!store.film.playing && store.filmTime == 0.7 && store.film.live == 0.7)
        #expect(answer["done"] as? String == "The film is stopped." && answer["playing"] == nil && answer["playhead"] as? Double == 0.7)
        answer = json(await call("animate", ["artboard": "A", "play": false]).text)
        #expect(answer["done"] as? String == "No film was playing." && store.filmTime == 0.7)

        // With a playhead, it plays from there.
        answer = json(await call("animate", ["artboard": "A", "playhead": 0.4, "play": true]).text)
        #expect(store.film.playing && store.film.pass?.from == 0.4)
        #expect(answer["done"] as? String == "Shown in Animate, playing from 0.4 s." && answer["playhead"] as? Double == 0.4 && answer["playing"] as? Bool == true)
        // From the film's end, that is its start again.
        answer = json(await call("animate", ["artboard": "A", "playhead": 3, "play": true]).text)
        #expect(store.film.playing && store.film.pass?.from == 0 && answer["playhead"] as? Double == 0)
        #expect(answer["done"] as? String == "Shown in Animate, playing from 0 s.")
        // A playhead with play false stops it there.
        answer = json(await call("animate", ["artboard": "A", "playhead": 1, "play": false]).text)
        #expect(!store.film.playing && store.filmTime == 1)
        #expect(answer["done"] as? String == "Shown in Animate, the playhead at 1 s." && answer["playing"] == nil)

        // Keys set and the film played in one call: the keys are there when it plays.
        let both = await call("animate", ["artboard": "A", "play": true, "keys": [["layer": "Button", "property": "fade", "time": 0, "value": 0], ["layer": "Button", "property": "fade", "time": 1, "value": 1]]])
        #expect(!both.failed && store.film.playing && bench.node("Button")![track: .fade]?.keys.count == 2, "\(both.text)")
        #expect((json(both.text)["done"] as? String)?.hasSuffix("Shown in Animate, playing from the start.") == true, "\(both.text)")
        store.pauseFilm()

        // Leaving the mode stops the film, and reading says so.
        _ = await call("animate", ["artboard": "A", "play": true])
        store.show(.design)
        let left = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(left["animating"] as? Bool == false && left["playhead"] == nil && left["playing"] == nil)
        // Stopping with the window elsewhere shows nothing.
        answer = json(await call("animate", ["artboard": "A", "play": false]).text)
        #expect(!store.animating && answer["done"] as? String == "No film was playing." && answer["animating"] as? Bool == false)
    }

    @Test func showingAFilmLeavesWhatIsPickedOnItsArtboardAlone() async {
        let store = bench.store, card = bench.node("Card")!.id, a = bench.a.id, b = bench.b.id
        bench.step { store.add(CanvasTests.rect("Far", CGRect(x: 620, y: 120, width: 40, height: 40)), onto: b) }
        let far = bench.node("Far")!.id
        // A layer picked on the film's artboard stays picked.
        store.selection = [card]
        _ = await call("animate", ["artboard": "A", "playhead": 0])
        store.glide.stop()
        #expect(store.animating && store.film.board == a && store.selection == [card])
        // For another artboard's film it is let go of, for that artboard itself.
        _ = await call("animate", ["artboard": "B", "playhead": 0])
        store.glide.stop()
        #expect(store.film.board == b && store.selection == [b])
        // And the other way, from a layer on B, with the film set playing.
        store.selection = [far]
        #expect(store.film.board == b)
        _ = await call("animate", ["artboard": "A", "play": true])
        store.glide.stop()
        #expect(store.film.board == a && store.selection == [a] && store.film.playing)
        // Stopping names no film to show: the desk stays, and B's is not the one shown.
        let stopped = json(await call("animate", ["artboard": "B", "play": false]).text)
        #expect(!store.film.playing && store.film.board == a && store.selection == [a])
        #expect(stopped["animating"] as? Bool == true && stopped["playhead"] == nil && stopped["done"] as? String == "The film is stopped.")
        // With nothing picked the desk is on A still, and nothing is picked for it.
        store.selection = []
        _ = await call("animate", ["artboard": "A", "playhead": 0.5])
        #expect(store.selection.isEmpty && store.film.board == a && store.filmTime == 0.5)
        // The camera picked stays picked when its own film is shown again.
        store.pickCamera()
        _ = await call("animate", ["artboard": "A", "playhead": 1])
        #expect(store.film.camera && store.filmTime == 1)
        // Named by a layer on it, an artboard's film is shown as well.
        _ = await call("animate", ["artboard": "Far", "playhead": 0])
        store.glide.stop()
        #expect(store.film.board == b)
    }

    @Test func aHiddenArtboardsFilmIsNotShownAndNothingOfTheCallIsDone() async {
        let store = bench.store, a = bench.a.id
        bench.step { store.setHidden(true, [a]) }
        let before = store.doc
        let key: [String: Any] = ["layer": "Card", "property": "fade", "time": 0, "value": 0]
        for asked: [String: Any] in [["playhead": 0.5], ["play": true], ["playhead": 0, "keys": [key]], ["play": true, "length": 4]] {
            var asked = asked
            asked["artboard"] = "A"
            let answer = await call("animate", asked)
            #expect(answer.failed && answer.text.contains("A is hidden, and the film of a hidden artboard cannot be shown"), "\(asked): \(answer.text)")
        }
        #expect(store.doc == before && !store.animating && store.film.board == nil)
        // Its keys are set and read all the same, and stopping is no showing.
        let set = await call("animate", ["artboard": "A", "keys": [key], "play": false])
        #expect(!set.failed && bench.node("Card")![track: .fade] != nil, "\(set.text)")
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["animating"] as? Bool == false && names("layers", in: read) == ["Card"])
        // In Animate on another artboard, it is still not shown.
        _ = await call("animate", ["artboard": "B", "playhead": 0])
        store.glide.stop()
        let still = await call("animate", ["artboard": "A", "playhead": 0])
        #expect(still.failed && store.film.board == bench.b.id)
    }

    @Test func whatIsWrongWithShowingIsNamedAndChangesNothing() async {
        let store = bench.store, before = store.doc
        let good: [String: Any] = ["layer": "Card", "property": "fade", "time": 0, "value": 0]
        let mistakes: [(asked: [String: Any], says: String)] = [
            (["artboard": "A", "playhead": -1], "playhead is -1"),
            (["artboard": "A", "playhead": "soon"], "playhead should be a number"),
            (["artboard": "A", "play": "yes"], "play should be true or false"),
            (["artboard": "A", "keys": [good], "playhead": -0.5], "playhead is -0.5"),
            (["artboard": "A", "keys": [good], "play": 1], "play should be true or false"),
            (["artboard": "Nobody", "play": true], "There is no layer \"Nobody\""),
            (["artboard": "A", "play": true, "keys": [["layer": "Card", "property": "fade", "time": 0]]], "keys[0].value is missing"),
        ]
        for mistake in mistakes {
            let answer = await call("animate", mistake.asked)
            #expect(answer.failed && answer.text.contains(mistake.says), "\(mistake.asked): \(answer.text)")
        }
        #expect(store.doc == before && !store.animating && !store.film.playing && !bench.undo.canUndo)
    }

    // MARK: Where layers lie

    @Test func layersInGroupsAreKeyedWhereTheyLie() async throws {
        let store = bench.store
        // Card and Second in a group, between the title and the button.
        store.selection = [bench.node("Card")!.id, bench.node("Second")!.id]
        bench.step { store.group() }
        let made = try #require(store.selection.first)
        bench.step { store.update([made], "Rename") { $0.name = "Row" } }
        store.selection = []
        #expect(bench.a.children.map(\.name) == ["Title", "Row", "Button"])
        let asked: [[String: Any]] = [
            ["layer": "Second", "property": "fade", "time": 0, "value": 0],
            ["layer": "Second", "property": "fade", "time": 1, "value": 1],
            ["layer": "Row", "property": "move", "time": 0, "value": [0, 30]],
            ["layer": "Row", "property": "move", "time": 1, "value": [0, 0]],
            ["layer": "Row/Card", "property": "turn", "time": 0.5, "value": 10],
        ]
        let set = await call("animate", ["keys": asked, "moves": [["move": "rise", "layers": ["Card", "Title"], "time": 1]]])
        #expect(!set.failed, "\(set.text)")
        let row = try #require(bench.node("Row"))
        try #require(row.children.map(\.name) == ["Card", "Second"])
        #expect(row[track: .move]?.keys.count == 2)
        #expect(row.children[1][track: .fade]?.keys.map(\.v) == [[0], [1]])
        #expect(row.children[0][track: .turn]?.keys.map(\.v) == [[10]])
        // A layer in the group rises as one outside does, from below to where the design has it.
        #expect(row.children[0].value(of: .move, at: 1)[1] > 0 && row.children[0].value(of: .move, at: 2) == [0, 0])
        #expect(row.children[0].value(of: .move, at: 1) == bench.node("Title")!.value(of: .move, at: 1))
        // The group lies where it lay: keys move nothing in the design.
        #expect(row.frame == CGRect(x: 40, y: 90, width: 320, height: 80))
        // Listed in the order they lie: a group, then what it holds.
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(names("layers", in: read) == ["Title", "Row", "Card", "Second"])
        #expect(keys("move", of: "Row", in: read).count == 2 && keys("fade", of: "Second", in: read).count == 2)
        // One property taken from the group is the group's alone: what it holds keeps its own.
        let less = await call("animate", ["remove": [["layer": "Row", "property": "move"]]])
        #expect(!less.failed && !bench.node("Row")!.isAnimated && bench.node("Second")!.isAnimated && bench.node("Card")!.isAnimated, "\(less.text)")
        #expect(names("asDesigned", in: json(less.text)) == ["Row"] && names("layers", in: json(less.text)).isEmpty)
        // Taken away whole, a group's motion goes with that of what it holds, and the answer
        // says which those were.
        let again = await call("animate", ["keys": [
            ["layer": "Row", "property": "fade", "time": 0, "value": 0.5],
            ["layer": "Row", "property": "fade", "time": 1, "value": 1],
        ]])
        #expect(!again.failed && bench.node("Row")!.isAnimated, "\(again.text)")
        let removed = await call("animate", ["remove": [["layer": "Row"]]])
        #expect(!removed.failed, "\(removed.text)")
        #expect(!bench.node("Row")!.isAnimated && !bench.node("Second")!.isAnimated && !bench.node("Card")!.isAnimated)
        #expect(names("asDesigned", in: json(removed.text)) == ["Row", "Card", "Second"], "\(removed.text)")
        // What lies outside the group is as it was.
        #expect(bench.node("Title")!.isAnimated)
    }

    @Test func twoLayersOfOneNameOnAnArtboardAreToldApartByTheirIds() async {
        let store = bench.store, a = bench.a.id
        bench.step { store.add(CanvasTests.rect("Card", CGRect(x: 320, y: 320, width: 60, height: 40)), onto: a) }
        store.selection = []
        let cards = bench.a.children.filter { $0.name == "Card" }
        #expect(cards.count == 2)
        let before = store.doc
        let unsure = await call("animate", ["artboard": "A", "keys": [["layer": "Card", "property": "fade", "time": 0, "value": 0]]])
        #expect(unsure.failed && unsure.text.contains("2 layers are called \"Card\"") && unsure.text.contains(cards[1].id.uuidString), "\(unsure.text)")
        #expect(store.doc == before)
        let set = await call("animate", ["keys": [
            ["layer": cards[1].id.uuidString, "property": "fade", "time": 0, "value": 0],
            ["layer": cards[1].id.uuidString, "property": "fade", "time": 1, "value": 1],
        ]])
        #expect(!set.failed, "\(set.text)")
        #expect(store.doc.node(cards[1].id)?.isAnimated == true && store.doc.node(cards[0].id)?.isAnimated == false)
        // The answer says which by its id, as both have the name.
        let listed = json(set.text)["layers"] as? [[String: Any]] ?? []
        #expect(listed.map { $0["id"] as? String } == [cards[1].id.uuidString] && listed.first?["name"] as? String == "Card")
    }

    @Test func hiddenAndLockedLayersAreKeyedAsAnyOther() async {
        let store = bench.store, card = bench.node("Card")!.id, second = bench.node("Second")!.id
        bench.step { store.setHidden(true, [card]) }
        bench.step { store.setLocked(true, [second]) }
        // The assistant sets keys by name on what the person cannot pick on the canvas: a hidden
        // layer's are there for when it shows, and a locked layer is locked against the hand.
        let set = await call("animate", ["keys": [
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 1, "value": 1],
            ["layer": "Second", "property": "move", "time": 0, "value": [0, 20]],
            ["layer": "Second", "property": "move", "time": 1, "value": [0, 0]],
        ]])
        #expect(!set.failed, "\(set.text)")
        #expect(bench.node("Card")![track: .fade]?.keys.count == 2 && bench.node("Second")![track: .move]?.keys.count == 2)
        // And gives them a move, as it does any layer.
        let moved = await call("animate", ["moves": [["move": "pop", "layers": ["Card", "Second"], "time": 1.5]]])
        #expect(!moved.failed, "\(moved.text)")
        let hidden = bench.node("Card")!, locked = bench.node("Second")!
        #expect(hidden.hidden && hidden[track: .scale] != nil)
        #expect(locked.locked && locked[track: .scale] != nil && locked[track: .move]?.keys.count == 2)
        // Both are read back; neither was shown or unlocked for it.
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(names("layers", in: read) == ["Card", "Second"])
        // A hidden layer is no piece of the film as it plays, and shows nothing in a frame.
        #expect(!bench.a.filmPieces().contains { $0.layers.contains(card) })
        // And their keys are taken away as any other's.
        let removed = await call("animate", ["remove": [["layers": ["Card", "Second"]]]])
        #expect(!removed.failed && !bench.node("Card")!.isAnimated && !bench.node("Second")!.isAnimated, "\(removed.text)")
    }

    @Test func aLayerInACopyOfAComponentHasKeysOfItsOwn() async throws {
        let store = bench.store, a = bench.a.id
        // The two cards made a component, and a second copy of it below the first.
        store.selection = [bench.node("Card")!.id, bench.node("Second")!.id]
        bench.step { store.makeComponent() }
        let first = try #require(store.selection.first)
        bench.step { store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        let second = try #require(store.selection.first)
        store.selection = []
        let one = try #require(store.doc.node(first)), two = try #require(store.doc.node(second))
        let component = try #require(one.instance?.of)
        #expect(first != second && two.instance?.of == component)
        let inner = try #require(one.children.first), other = try #require(two.children.first)
        #expect(inner.name == "Card" && other.name == "Card" && inner.id != other.id)
        // By its name the layer is in both copies: the call is refused, names both, and does nothing.
        let before = store.doc
        let unsure = await call("animate", ["keys": [["layer": "Card", "property": "fade", "time": 0, "value": 0]]])
        #expect(unsure.failed && unsure.text.contains(inner.id.uuidString) && unsure.text.contains(other.id.uuidString), "\(unsure.text)")
        #expect(store.doc == before)
        // A layer inside the first copy, and the second copy as a whole, by their ids.
        let set = await call("animate", ["keys": [
            ["layer": inner.id.uuidString, "property": "fade", "time": 0, "value": 0],
            ["layer": inner.id.uuidString, "property": "fade", "time": 1, "value": 1],
            ["layer": second.uuidString, "property": "move", "time": 0, "value": [0, 30]],
            ["layer": second.uuidString, "property": "move", "time": 1, "value": [0, 0]],
        ]])
        #expect(!set.failed, "\(set.text)")
        // Motion is each copy's own: the same layer in the other copy stays as designed, and so
        // does the first copy as a whole. The component itself has none.
        #expect(store.doc.node(inner.id)?[track: .fade]?.keys.count == 2)
        #expect(store.doc.node(other.id)?.isAnimated == false)
        #expect(store.doc.node(second)?[track: .move]?.keys.count == 2 && store.doc.node(first)?.isAnimated == false)
        let master = try #require(store.doc.master(component))
        #expect(!master.isAnimated && !master.children.contains { $0.isAnimated })
        // A change to the look in one copy reaches the other, and leaves each its motion.
        bench.step { store.update([other.id], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        #expect(store.doc.node(inner.id)?.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(store.doc.node(inner.id)?[track: .fade]?.keys.count == 2 && store.doc.node(other.id)?.isAnimated == false)
        #expect(store.doc.node(second)?[track: .move]?.keys.count == 2)
        // Read back with the ids that tell the copies' layers apart.
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        let listed = (read["layers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(Set(listed) == [inner.id.uuidString, second.uuidString], "\(listed)")
        // A copy made of a copy takes its keys along, as a copy of any layer does; a copy placed
        // from the component has none.
        store.selection = [first]
        bench.step { store.duplicateSelection(offset: CGPoint(x: 0, y: 50)) }
        let third = try #require(store.selection.first.flatMap { store.doc.node($0) })
        #expect(third.id != first && third.children.first?[track: .fade]?.keys.count == 2)
        var placed: UUID?
        bench.step { placed = store.placeCopy(of: component, at: CGPoint(x: 200, y: 340), onto: a) }
        let fresh = try #require(placed.flatMap { store.doc.node($0) })
        #expect(fresh.instance?.of == component && !fresh.isAnimated && !fresh.children.contains { $0.isAnimated })
    }

    @Test func aLayerInARepeatGridIsKeyedInItsFirstCellAlone() async throws {
        let store = bench.store
        store.selection = [bench.node("Card")!.id]
        bench.step { store.makeRepeatGrid() }
        let grid = try #require(store.selection.first)
        bench.step { store.edit("Repeat Grid") { $0.update(grid) { $0.grid?.columns = 2 } } }
        store.selection = []
        let cards = store.doc.allNodes.filter { $0.name == "Card" && $0.kind == .rectangle }
        #expect(cards.count == 2)
        // By its name, the layer is the one in the first cell, as for every other tool.
        let set = await call("animate", ["keys": [
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 1, "value": 1],
        ]])
        #expect(!set.failed, "\(set.text)")
        let now = store.doc.allNodes.filter { $0.name == "Card" && $0.kind == .rectangle }
        #expect(now.count == 2 && now.filter(\.isAnimated).count == 1 && now.first?.isAnimated == true, "\(now.map(\.isAnimated))")
        // Motion is each cell's own: a change to the cell's look reaches the other, its keys do not.
        let keyed = try #require(now.first?.id), plain = try #require(now.last?.id)
        bench.step { store.update([keyed], "Fill") { $0.fill.color = RGBA(r: 0, g: 0, b: 1) } }
        #expect(store.doc.node(plain)?.fill.color == RGBA(r: 0, g: 0, b: 1))
        #expect(store.doc.node(plain)?.motion == nil && store.doc.node(keyed)?[track: .fade]?.keys.count == 2)
        // The other cell's layer is keyed by its id, and the grid as a whole as any layer.
        let more = await call("animate", ["keys": [
            ["layer": plain.uuidString, "property": "fade", "time": 0.5, "value": 0],
            ["layer": grid.uuidString, "property": "move", "time": 0, "value": [0, 20]],
        ]])
        #expect(!more.failed, "\(more.text)")
        #expect(store.doc.node(plain)?[track: .fade]?.keys.map(\.t) == [0.5] && store.doc.node(keyed)?[track: .fade]?.keys.map(\.t) == [0, 1])
        #expect(store.doc.node(grid)?[track: .move] != nil && store.doc.node(grid)?.grid?.columns == 2)
        // Another column added: the new cell is made from the first, and starts with its keys.
        // The cells that were there keep their own.
        bench.step { store.edit("Repeat Grid") { $0.update(grid) { $0.grid?.columns = 3 } } }
        let three = store.doc.allNodes.filter { $0.name == "Card" && $0.kind == .rectangle }
        #expect(three.count == 3)
        let new = try #require(three.first { $0.id != keyed && $0.id != plain })
        #expect(new[track: .fade]?.keys.map(\.t) == [0, 1], "\(String(describing: new[track: .fade]?.keys.map(\.t)))")
        #expect(store.doc.node(plain)?[track: .fade]?.keys.map(\.t) == [0.5] && store.doc.node(keyed)?[track: .fade]?.keys.map(\.t) == [0, 1])
    }

    @Test func aLayerOfADeckIsKeyedInItsFirstPostAlone() async throws {
        let store = bench.store, a = bench.a.id
        bench.step { store.addPost(to: a) }
        store.selection = []
        let posts = bench.a.posts
        try #require(bench.a.isDeck && posts.count == 2)
        // The deck holds the design its posts are made from, and each post's own layers. The post
        // added is the one in front.
        let cards = store.doc.allNodes.filter { $0.name == "Card" }
        #expect(cards.map(\.post) == [nil, posts[0], posts[1]])
        #expect(store.front(of: bench.a) == posts[1])
        // By its name, the layer is the one in the first post, as for every other tool. That post
        // lies behind, where the film does not show it, and the answer says so.
        let named = try MCPTools.layer("Card", in: store.doc)
        let set = await call("animate", ["artboard": "A", "length": 2, "keys": [
            ["layer": "Card", "property": "fade", "time": 0, "value": 0],
            ["layer": "Card", "property": "fade", "time": 1, "value": 1],
        ]])
        #expect(!set.failed, "\(set.text)")
        let now = store.doc.allNodes.filter { $0.name == "Card" }
        #expect(now.filter(\.isAnimated).map(\.id) == [named])
        #expect(now.first { $0.id == named }?.post == posts[0])
        let answer = json(set.text)
        #expect(warnings(answer).contains("layers of post 1") && warnings(answer).contains("post 2 is in front"), "\(set.text)")
        #expect((answer["layers"] as? [[String: Any]])?.first?["post"] as? Double == 1, "\(set.text)")
        // Motion is each post's own: the layer of the post in front is keyed by its id, and of
        // that there is nothing to warn.
        let other = try #require(now.first { $0.post == posts[1] }?.id)
        let more = await call("animate", ["artboard": "A", "keys": [
            ["layer": other.uuidString, "property": "move", "time": 0.5, "value": [10, 0]],
            ["layer": other.uuidString, "property": "move", "time": 1, "value": [0, 0]],
        ]])
        #expect(!more.failed && !warnings(json(more.text)).contains("in front"), "\(more.text)")
        #expect(store.doc.node(other)?[track: .move] != nil && store.doc.node(other)?[track: .fade] == nil && store.doc.node(named)?[track: .move] == nil)
        // The film is the artboard's, one for all its posts, and each layer says its post.
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(read["length"] as? Double == 2)
        let listed = read["layers"] as? [[String: Any]] ?? []
        #expect(listed.map { $0["id"] as? String } == [named.uuidString, other.uuidString])
        #expect(listed.map { $0["post"] as? Double } == [1, 2], "\(listed)")
        // Shown, the film is the deck's with the post in front on the stage: the second, whose
        // card moves and does not fade.
        let shown = await call("animate", ["artboard": "A", "playhead": 0.5])
        store.glide.stop()
        #expect(!shown.failed && store.film.board == a && store.filmTime == 0.5, "\(shown.text)")
        let seen = (store.filmBoard?.children ?? []).filter { $0.name == "Card" }
        #expect(seen.map(\.id) == [other] && seen.first?[track: .fade] == nil)
        // With the first post brought to the front, it is its card's keys that show.
        store.turn(a, to: posts[0])
        let turned = (store.filmBoard?.children ?? []).filter { $0.name == "Card" }
        #expect(turned.map(\.id) == [named] && turned.first?[track: .fade]?.keys.count == 2)
    }

    // MARK: Much, and oddly named

    @Test func veryManyKeysInOneCallAreOneStep() async {
        let store = bench.store, before = store.doc
        // Four layers, five properties each and the camera's three, a key every fiftieth of a second for two seconds.
        var asked: [[String: Any]] = []
        for k in 0...100 {
            let t = Double(k) / 50, f = Double(k) / 100
            for name in ["Title", "Card", "Second", "Button"] {
                asked.append(["layer": name, "property": "move", "time": t, "value": [f * 10, -f * 20]])
                asked.append(["layer": name, "property": "scale", "time": t, "value": 1 + f / 2])
                asked.append(["layer": name, "property": "turn", "time": t, "value": f * 90])
                asked.append(["layer": name, "property": "fade", "time": t, "value": f])
                asked.append(["layer": name, "property": "blur", "time": t, "value": 10 - f * 10, "pace": "linear"])
            }
            asked.append(["property": "cameraZoom", "time": t, "value": 1 + f])
            asked.append(["property": "cameraMove", "time": t, "value": [f * 30, 0]])
            asked.append(["property": "cameraTilt", "time": t, "value": f * 20])
        }
        #expect(asked.count == 2323)
        let clock = ContinuousClock(), began = clock.now
        let set = await call("animate", ["artboard": "A", "keys": asked])
        let took = clock.now - began
        #expect(!set.failed, "\(set.text.prefix(300))")
        for name in ["Title", "Card", "Second", "Button"] {
            let n = bench.node(name)!
            #expect(MotionProperty.layer.filter { n[track: $0] != nil }.count == 5, "\(name)")
            #expect(n[track: .move]?.keys.count == 101 && n[track: .blur]?.keys.count == 101 && n[track: .blur]?.keys.allSatisfy { $0.ease?.kind == .linear } == true, "\(name)")
            #expect(n.value(of: .turn, at: 1) == [45] && n.value(of: .move, at: 2) == [10, -20], "\(name)")
        }
        #expect(bench.a[track: .cameraZoom]?.keys.count == 101 && bench.a.camera(at: 2).zoom == 2)
        // The answer is whole and can be read, with every key in it.
        let answer = json(set.text)
        #expect((answer["done"] as? String)?.contains("2323 keys set") == true, "\(answer["done"] ?? "")")
        #expect(keys("fade", of: "Button", in: answer).count == 101)
        let read = json(await call("get_animation", ["artboard": "A"]).text)
        #expect(names("layers", in: read) == ["Title", "Card", "Second", "Button"] && keys("scale", of: "Title", in: read).count == 101)
        #expect(((read["camera"] as? [String: Any])?["cameraTilt"] as? [[String: Any]])?.count == 101)
        // One step, however many keys.
        bench.undo.undo()
        #expect(store.doc == before && !bench.undo.canUndo)
        // And quick enough not to be noticed. Said in the test's own record.
        try? "2323 keys in one animate call: \(took)".write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-mcp-timing.txt"), atomically: true, encoding: .utf8)
        #expect(took < .seconds(10), "\(took)")
    }

    @Test func aCallThatIsPartlyWrongChangesNothingOfIt() async {
        let store = bench.store
        await rising()
        let before = store.doc
        var many: [[String: Any]] = (0..<400).map { ["layer": "Title", "property": "fade", "time": Double($0) / 100, "value": 0.5] }
        many.append(["layer": "Title", "property": "fade", "time": 5, "value": "full"])
        let good: [String: Any] = ["layer": "Button", "property": "fade", "time": 0, "value": 0]
        let wrong: [(what: String, asked: [String: Any], says: String)] = [
            ("the last of very many keys", ["keys": many], "keys[400].value should be a number"),
            ("a key after moves, a removal and the film's length", [
                "artboard": "A", "length": 6, "loop": false, "backdrop": "#102030",
                "remove": [["layer": "Card"]],
                "moves": [["move": "rise", "layers": ["Title", "Second"]]],
                "keys": [good, ["layer": "Nobody", "property": "fade", "time": 0, "value": 0]],
            ], "There is no layer \"Nobody\""),
            ("a move after good keys", ["keys": [good], "moves": [["move": "tumble", "layers": ["Card"]]]], "move is one of"),
            ("a removal after good keys", ["artboard": "A", "keys": [good], "remove": [["layer": "Card", "property": "cameraZoom"]]], "cameraZoom is the camera's"),
            ("a backdrop after good keys", ["artboard": "A", "keys": [good], "backdrop": "bluish"], "not a colour"),
            ("a length after everything was taken away", ["artboard": "A", "remove": "all", "length": -1], "more than 0"),
            ("a playhead after good keys", ["artboard": "A", "keys": [good], "playhead": -2], "playhead is -2"),
        ]
        for item in wrong {
            let answer = await call("animate", item.asked)
            #expect(answer.failed && answer.text.contains(item.says), "\(item.what): \(answer.text.prefix(300))")
            #expect(store.doc == before, "\(item.what)")
        }
        // Not a step was left in the history, and nothing was shown.
        #expect(!store.animating && bench.undo.groupingLevel == 0)
        bench.undo.undo()
        #expect(!bench.undo.canUndo)
    }

    @Test func oddNamesComeBackAsTheyAre() async throws {
        let store = bench.store
        let odd = [
            "Title": "Say \"hi\" \\ to {\"x\": [1, 2]}",
            "Card": "Zeile eins\nZeile zwei\tund \u{1} mehr",
            "Second": "😀 👩‍👩‍👧 e\u{301} 日本語 \u{202E}rtl",
            "Button": String(repeating: "Sehr langer Name ", count: 300),
        ]
        var ids: [String: UUID] = [:]
        for (was, name) in odd {
            let id = bench.node(was)!.id
            ids[was] = id
            bench.step { store.update([id], "Rename") { $0.name = name } }
        }
        let a = bench.a.id
        bench.step { store.update([a], "Rename") { $0.name = "Screen \"A\" 🎬" } }
        // Named by those names, keyed, and listed with them.
        var asked: [[String: Any]] = []
        for name in odd.values {
            asked.append(["layer": name, "property": "fade", "time": 0, "value": 0])
        }
        let set = await call("animate", ["artboard": "Screen \"A\" 🎬", "keys": asked, "playhead": 0.25])
        store.glide.stop()
        #expect(!set.failed, "\(set.text.prefix(400))")
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(set.text.utf8)) as? [String: Any])
        #expect(Set(names("layers", in: answer)) == Set(odd.values))
        #expect((answer["artboard"] as? [String: Any])?["name"] as? String == "Screen \"A\" 🎬")
        // Each has one key, which is said of each by its name.
        let said = answer["warnings"] as? [String] ?? []
        for name in odd.values { #expect(said.contains { $0.hasPrefix("\(name) has one fade key") }, "\(name.prefix(40))") }
        #expect(answer["playhead"] as? Double == 0.25)
        let read = try #require(try JSONSerialization.jsonObject(with: Data(await call("get_animation", ["artboard": a.uuidString]).text.utf8)) as? [String: Any])
        #expect(Set(names("layers", in: read)) == Set(odd.values))
        for was in odd.keys { #expect(store.doc.node(ids[was]!)?[track: .fade]?.keys.count == 1, "\(was)") }
        // What is wrong is said with the name as it is, in an answer that can still be read.
        let unknown = "Nobody \"at\" all\n😶"
        let missing = await call("animate", ["keys": [["layer": unknown, "property": "fade", "time": 0, "value": 0]]])
        #expect(missing.failed && missing.text.contains("There is no layer \"\(unknown)\""), "\(missing.text)")
        let hidden = await call("animate", ["artboard": a.uuidString, "remove": [["layer": odd["Card"]!, "property": "cameraZoom"]]])
        #expect(hidden.failed && hidden.text.contains("cameraZoom is the camera's"), "\(hidden.text)")
    }

    // MARK: What the server says of it

    @Test func theServerTellsOfBothTools() throws {
        #expect(tools.has("get_animation") && tools.has("animate"))
        let listed = try JSONSerialization.jsonObject(with: JSONValue.array(tools.list).data) as? [[String: Any]] ?? []
        let reading = listed.first { $0["name"] as? String == "get_animation" }
        #expect((reading?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        let writing = listed.first { $0["name"] as? String == "animate" }
        #expect((writing?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
        let properties = (writing?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        #expect(Set(properties.keys) == ["design", "artboard", "keys", "moves", "remove", "length", "loop", "backdrop", "playhead", "play"])
        let key = ((properties["keys"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        #expect(((key["property"] as? [String: Any])?["enum"] as? [String]) == MotionProperty.allCases.map(\.rawValue))
        #expect(((key["pace"] as? [String: Any])?["enum"] as? [String]) == ["auto", "smooth", "in", "out", "linear", "spring", "hold"])
        // The short list, as the Claude Desktop extension shows it, has a whole sentence for each.
        let summaries = tools.summaries
        #expect(summaries.first { $0.name == "animate" }?.summary.hasPrefix("Changes an artboard's film") == true)
        #expect(summaries.first { $0.name == "get_animation" }?.summary.hasSuffix("with its keys.") == true)
        // And what is told on connecting says how.
        #expect(MCPTools.instructions.contains("get_animation reads its keys and animate sets them"))
        #expect(MCPTools.instructions.contains("ending at rest"))
    }
}
