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

    // MARK: What the server says of it

    @Test func theServerTellsOfBothTools() throws {
        #expect(tools.has("get_animation") && tools.has("animate"))
        let listed = try JSONSerialization.jsonObject(with: JSONValue.array(tools.list).data) as? [[String: Any]] ?? []
        let reading = listed.first { $0["name"] as? String == "get_animation" }
        #expect((reading?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        let writing = listed.first { $0["name"] as? String == "animate" }
        #expect((writing?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
        let properties = (writing?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        #expect(Set(properties.keys) == ["design", "artboard", "keys", "moves", "remove", "length", "loop", "backdrop"])
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
