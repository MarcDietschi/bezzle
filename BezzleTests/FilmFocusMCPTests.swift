import Testing
import AppKit
@testable import Bezzle

/// The camera's focus and blur as an assistant sets and reads them: two more of the camera's
/// properties, a key that is sharp on layers, and what it is told when nothing would show.
@MainActor
@Suite(.serialized)
struct FilmFocusMCPTests {
    /// On artboard A (400 by 300): a title on the page and a card, which the tests lift.
    let bench = Bench(extra: [
        CanvasTests.rect("Title", CGRect(x: 40, y: 30, width: 200, height: 30)),
        CanvasTests.rect("Card", CGRect(x: 220, y: 160, width: 140, height: 100)),
    ])
    let tools = MCPTools()

    init() { MCPTools.opened(bench.store) }

    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool, pictures: [Data]) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        let pictures = content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true, pictures)
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func warnings(_ text: String) -> [String] { json(text)["warnings"] as? [String] ?? [] }

    private var board: Node { bench.store.doc.nodes[0] }

    /// The card held 120 above the page for the whole film.
    private func lift() async {
        _ = await call("animate", ["artboard": "A", "keys": [["layer": "Card", "property": "lift", "time": 0, "value": 120]]])
    }

    @Test func theLensIsSetWithTheCamerasOtherKeysAndReadBack() async throws {
        await lift()
        let set = await call("animate", ["artboard": "A", "keys": [
            ["property": "cameraBlur", "time": 0, "value": 4],
            ["property": "cameraFocus", "time": 0, "value": 120],
            ["property": "cameraFocus", "time": 1.5, "value": 0, "pace": "smooth"],
        ]])
        #expect(!set.failed, "\(set.text)")
        #expect(board[track: .cameraBlur]?.keys == [MotionKey(t: 0, v: [4])])
        #expect(board[track: .cameraFocus]?.keys == [MotionKey(t: 0, v: [120]), MotionKey(t: 1.5, v: [0], ease: .smooth)])
        // One key of the blur is a lens that stays, and nothing to be told about.
        #expect(warnings(set.text).isEmpty, "\(warnings(set.text))")
        // The answer has the camera as it is now, and get_animation reads the same.
        for text in [set.text, await call("get_animation", ["artboard": "A"]).text] {
            let camera = try #require(json(text)["camera"] as? [String: Any])
            let blur = try #require(camera["cameraBlur"] as? [[String: Any]]), focus = try #require(camera["cameraFocus"] as? [[String: Any]])
            #expect(blur.count == 1 && blur[0]["time"] as? Double == 0 && blur[0]["value"] as? Double == 4)
            #expect(focus.map { $0["value"] as? Double } == [120, 0] && focus[1]["pace"] as? String == "smooth")
        }
        // More than the camera takes is kept within it, and said.
        let much = await call("animate", ["artboard": "A", "keys": [["property": "cameraBlur", "time": 0, "value": 250]]])
        #expect(!much.failed && board[track: .cameraBlur]?.keys == [MotionKey(t: 0, v: [100])])
        #expect(warnings(much.text).contains { $0.contains("kept as 100") })
        // They are the camera's, never a layer's.
        #expect(await call("animate", ["artboard": "A", "keys": [["layer": "Card", "property": "cameraBlur", "time": 0, "value": 4]]]).failed)
        // Taken away by name, or with all of the camera's.
        _ = await call("animate", ["artboard": "A", "keys": [["property": "cameraZoom", "time": 0, "value": 2]], "remove": [["property": "cameraBlur"]]])
        #expect(board[track: .cameraBlur] == nil && board[track: .cameraFocus] != nil && board[track: .cameraZoom] != nil)
        _ = await call("animate", ["artboard": "A", "remove": [["property": "camera"]]])
        #expect(!board.hasCamera && board.children.contains { $0[track: .lift] != nil })
    }

    @Test func aKeyWithFocusOnIsSharpOnLayersWhereverTheyStandThen() async throws {
        // The card rises from the page to 120 above it over the first second.
        _ = await call("animate", ["artboard": "A", "keys": [
            ["layer": "Card", "property": "lift", "time": 0, "value": 0], ["layer": "Card", "property": "lift", "time": 1, "value": 120, "pace": "linear"],
        ]])
        let set = await call("animate", ["artboard": "A", "keys": [
            ["property": "cameraBlur", "time": 0, "value": 6],
            ["time": 0.5, "focusOn": "Card"], ["time": 1, "focusOn": ["Card"], "pace": "linear"], ["time": 2, "focusOn": ["Title", "Card"]],
        ]])
        #expect(!set.failed, "\(set.text)")
        // Half way up at half a second, all the way at one; then half way between the title on the page and the card.
        #expect(board[track: .cameraFocus]?.keys == [MotionKey(t: 0.5, v: [60]), MotionKey(t: 1, v: [120], ease: .linear), MotionKey(t: 2, v: [60])])
        #expect(board[track: .cameraBlur]?.keys == [MotionKey(t: 0, v: [6])] && warnings(set.text).isEmpty, "\(warnings(set.text))")
        #expect(json(set.text)["done"] as? String == "4 keys set.")
        #expect((json(set.text)["camera"] as? [String: Any])?["cameraFocus"] != nil)
        // The frame an assistant is shown has the blur: the card is sharp at one second and the title soft.
        let sharp = await call("render", ["layer": "A", "time": 1, "scale": 1])
        _ = await call("animate", ["artboard": "A", "remove": [["property": "cameraBlur"]]])
        let plain = await call("render", ["layer": "A", "time": 1, "scale": 1])
        #expect(!sharp.failed && sharp.pictures.count == 1 && plain.pictures.count == 1 && sharp.pictures != plain.pictures)
    }

    @Test func besideToTheCameraLooksAtLayersAndIsSharpOnThem() async throws {
        await lift()
        // Tipped back, where it looks decides how far off a thing stands: the focus is worked out after the look.
        let set = await call("animate", ["artboard": "A", "keys": [
            ["property": "cameraBlur", "time": 0, "value": 4], ["property": "cameraTilt", "time": 0, "value": 40],
            ["time": 1, "to": "Title", "focusOn": "Title"],
        ]])
        #expect(!set.failed, "\(set.text)")
        #expect(board[track: .cameraMove]?.keys.map(\.t) == [1] && board[track: .cameraZoom]?.keys.map(\.t) == [1])
        // Looked at, the title's middle is where the camera looks: at nothing off its focus.
        #expect(board[track: .cameraFocus]?.keys == [MotionKey(t: 1, v: [0])])
        // Alone, from where the camera looks at the start, the artboard's middle: the title's
        // middle lies 105 above that, and under a camera tipped back by 40 degrees 105 sin 40 = 67.5 further.
        let alone = await call("animate", ["artboard": "A", "keys": [["time": 0, "focusOn": "Title"]], "remove": [["property": "cameraMove"], ["property": "cameraZoom"]]])
        #expect(!alone.failed && board[track: .cameraFocus]?.keys.first == MotionKey(t: 0, v: [-67]), "\(String(describing: board[track: .cameraFocus]?.keys))")
    }

    @Test func whatWouldShowNothingIsSaid() async throws {
        await lift()
        // Sharp on something with nothing blurred.
        var set = await call("animate", ["artboard": "A", "keys": [["time": 1, "focusOn": "Card"]]])
        #expect(!set.failed && board[track: .cameraFocus]?.keys == [MotionKey(t: 1, v: [120])] && board[track: .cameraBlur] == nil)
        #expect(warnings(set.text).contains { $0.contains("blurs nothing at 1 s") && $0.contains("cameraBlur") }, "\(warnings(set.text))")
        set = await call("animate", ["artboard": "A", "keys": [["property": "cameraBlur", "time": 0, "value": 4]]])
        #expect(warnings(set.text).isEmpty, "\(warnings(set.text))")
        // A lens over a flat page seen straight on.
        _ = await call("animate", ["artboard": "A", "remove": "all"])
        set = await call("animate", ["artboard": "A", "keys": [["property": "cameraBlur", "time": 0, "value": 4], ["layer": "Card", "property": "move", "time": 0, "value": [10, 0]], ["layer": "Card", "property": "move", "time": 1, "value": [0, 0]]]])
        #expect(!set.failed && warnings(set.text).contains { $0.contains("stands off the page") }, "\(warnings(set.text))")
        // With the camera tipped there is near and far, and nothing to say.
        set = await call("animate", ["artboard": "A", "keys": [["property": "cameraTilt", "time": 0, "value": 30], ["property": "cameraBlur", "time": 0, "value": 8]]])
        #expect(!warnings(set.text).contains { $0.contains("stands off the page") || $0.contains("blurs nothing") }, "\(warnings(set.text))")
    }

    @Test func aKeyWithFocusOnTakesNothingElseOfItsOwn() async {
        await lift()
        let before = bench.store.doc
        for key: [String: Any] in [
            ["time": 1, "focusOn": "Card", "value": 120], ["time": 1, "focusOn": "Card", "layer": "Card"], ["time": 1, "focusOn": [String]()],
            ["time": 1, "focusOn": "Card", "property": "cameraZoom"], ["focusOn": "Card"], ["time": 1, "focusOn": "Nobody"],
            ["time": 1, "focusOn": "Card", "look": "fill"], ["time": 1, "focusOn": "Card", "to": "Card", "property": "cameraFocus"],
        ] {
            let set = await call("animate", ["artboard": "A", "keys": [key]])
            #expect(set.failed, "\(key)")
        }
        // A layer of another artboard is not in this film.
        bench.step { bench.store.edit("Add") { $0.nodes[1].children = [CanvasTests.rect("Far", CGRect(x: 20, y: 20, width: 50, height: 50))] } }
        let other = bench.store.doc
        #expect(await call("animate", ["artboard": "A", "keys": [["time": 1, "focusOn": "Far"]]]).failed)
        #expect(bench.store.doc == other && other.nodes[0] == before.nodes[0])
        // Named with its property, it is the same key.
        let named = await call("animate", ["artboard": "A", "keys": [["time": 1, "focusOn": "Card", "property": "cameraFocus"], ["property": "cameraBlur", "time": 0, "value": 4]]])
        #expect(!named.failed && board[track: .cameraFocus]?.keys == [MotionKey(t: 1, v: [120])])
    }
}
