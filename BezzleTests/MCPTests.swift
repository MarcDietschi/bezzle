import Testing
import AppKit
@testable import Bezzle

/// The tools an AI assistant works in Bezzle with, called as the server calls them.
@MainActor
struct MCPTests {
    let bench = Bench()
    let tools = MCPTools()

    init() {
        MCPTools.opened(bench.store)
    }

    /// A rectangle put on artboard A at `frame`, measured in A as the tools measure it.
    private func rect(_ name: String, _ frame: CGRect) {
        bench.step { bench.store.add(CanvasTests.rect(name, frame.offsetBy(dx: bench.a.frame.minX, dy: bench.a.frame.minY)), onto: bench.a.id) }
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

    @Test func componentsAreMadePlacedAndVaried() async {
        rect("Shape", CGRect(x: 20, y: 20, width: 120, height: 40))
        let made = await call("make_component", ["layers": ["Shape"], "name": "Chip"])
        #expect(!made.failed, "\(made.text)")
        let copy = bench.store.doc.copies(of: bench.store.doc.masters.first?.id ?? UUID()).first
        #expect(copy != nil)
        let added = await call("add_copy", ["component": "Chip", "artboard": "A", "x": 20, "y": 120, "width": 200])
        #expect(!added.failed, "\(added.text)")
        #expect(bench.store.doc.copies(of: bench.store.doc.masters[0].id).count == 2)
        let listed = json(await call("list_components", [:]).text)
        let components = listed["components"] as? [[String: Any]] ?? []
        #expect(components.first?["name"] as? String == "Chip")
        #expect((components.first?["copies"] as? [Any])?.count == 2)
        let variant = await call("add_variant", ["layer": copy!.id.uuidString, "name": "Quiet"])
        #expect(!variant.failed, "\(variant.text)")
        #expect(variant.text.contains("\"variant\":\"Quiet\""))
        let other = bench.store.doc.copies(of: bench.store.doc.masters[0].id).first { $0.id != copy!.id }!
        let shown = await call("set_variant", ["layers": [other.id.uuidString], "variant": "Quiet"])
        #expect(!shown.failed, "\(shown.text)")
        #expect(bench.store.doc.node(other.id)?.instance?.variant == bench.store.doc.masters[0].master?.variants.first)
        let unlinked = await call("unlink_copies", ["layers": [other.id.uuidString]])
        #expect(!unlinked.failed)
        #expect(bench.store.doc.node(other.id)?.isCopy == false)
    }

    @Test func addingBuildsLayersInTheirParentsCoordinates() async {
        let answer = await call("add_layers", ["parent": "A", "layers": [
            ["kind": "rectangle", "name": "Box", "x": 10, "y": 20, "width": 30, "height": 40, "fill": "#FF0000"],
            ["kind": "text", "name": "Label", "text": "Hi", "x": 50, "y": 60],
            ["kind": "group", "name": "Pair", "children": [
                ["kind": "ellipse", "name": "Left", "x": 100, "y": 100, "width": 20, "height": 20],
                ["kind": "ellipse", "name": "Right", "x": 140, "y": 110, "width": 20, "height": 20],
            ]],
        ]])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.node("Box")?.frame == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(bench.node("Box")?.fill.color.hex == "FF0000")
        #expect(bench.store.doc.parent(of: bench.node("Label")!.id)?.name == "A")
        #expect(bench.node("Label")?.frame.origin == CGPoint(x: 50, y: 60))
        // A new group fits itself round its layers, which stay where they were put.
        #expect(bench.node("Pair")?.frame == CGRect(x: 100, y: 100, width: 60, height: 30))
        #expect(bench.store.doc.absoluteFrame(of: bench.node("Right")!.id) == CGRect(x: 240, y: 210, width: 20, height: 20))
        #expect(Set(bench.store.selection) == Set(["Box", "Label", "Pair"].compactMap { bench.node($0)?.id }))
    }

    @Test func aLayerNotPlacedGoesInTheMiddleOfItsParent() async {
        _ = await call("add_layers", ["parent": "A", "layers": [["kind": "rectangle", "name": "Mid", "width": 100, "height": 50]]])
        #expect(bench.node("Mid")?.frame == CGRect(x: 150, y: 125, width: 100, height: 50))
    }

    @Test func updatesChangeOnlyWhatTheyGive() async {
        rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        let answer = await call("update_layers", ["updates": [[
            "layer": "R", "x": 20, "fill": ["gradient": ["type": "linear", "angle": 180, "stops": ["#000000", "#FFFFFF80"]]],
            "border": ["width": 2, "color": "#00F"], "shadow": "soft", "cornerRadius": [1, 2, 3, 4], "opacity": 0.5,
        ]]])
        #expect(!answer.failed, "\(answer.text)")
        let r = bench.node("R")!
        #expect(r.frame == CGRect(x: 20, y: 10, width: 100, height: 100))
        #expect(r.fill.gradient?.start == CGPoint(x: 0.5, y: 0) && r.fill.gradient?.end == CGPoint(x: 0.5, y: 1))
        #expect(abs((r.fill.gradient?.stops.last?.color.a ?? 0) - 128.0 / 255) < 0.001)
        #expect(r.border.on && r.border.width == 2 && r.border.color.hex == "0000FF")
        #expect(r.shadow.on && r.shadow.blur == 12)
        #expect(r.corners == [1, 2, 3, 4])
        #expect(r.opacity == 0.5)
    }

    @Test func aMistakeChangesNothing() async {
        rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        let before = bench.store.doc
        // The first update is fine; the second names something layers do not have.
        let answer = await call("update_layers", ["updates": [["layer": "R", "x": 50], ["layer": "R", "colour": "#FFF"]]])
        #expect(answer.failed)
        #expect(answer.text.contains("colour"))
        #expect(bench.store.doc == before)
    }

    @Test func eachChangeIsOneStepToUndo() async {
        _ = await call("add_layers", ["parent": "A", "layers": [["kind": "rectangle", "name": "R", "x": 0, "y": 0]]])
        _ = await call("update_layers", ["updates": [["layer": "R", "x": 5]]])
        _ = await call("update_layers", ["updates": [["layer": "R", "x": 9]]])
        // Changing nothing leaves nothing to undo.
        _ = await call("update_layers", ["updates": [["layer": "R", "x": 9]]])
        #expect(bench.undo.groupingLevel == 0)
        let undone = json(await call("undo", ["steps": 2]).text)
        #expect(undone["undid"] as? [String] == ["Change", "Change"])
        #expect(bench.node("R")?.frame.minX == 0)
        _ = await call("undo", [:])
        #expect(bench.node("R") == nil)
    }

    @Test func menuCommandsAreOneStepEach() async {
        rect("Back", CGRect(x: 0, y: 0, width: 50, height: 50))
        rect("Front", CGRect(x: 20, y: 20, width: 50, height: 50))
        let answer = await call("arrange_layers", ["layers": ["Front"], "order": "back"])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.a.children.map(\.name) == ["Front", "Back"])
        #expect(bench.undo.undoActionName == "Send to Back")
        // Already at the back: nothing changes, and there is no new step.
        _ = await call("arrange_layers", ["layers": ["Front"], "order": "back"])
        bench.undo.undo()
        #expect(bench.a.children.map(\.name) == ["Back", "Front"])

        _ = await call("combine_shapes", ["layers": ["Back", "Front"], "operation": "union"])
        #expect(bench.a.children.map(\.kind) == [.path])
        #expect(bench.store.selection == bench.a.children.map(\.id))
    }

    @Test func groupingAndUngroupingKeepWhereLayersAre() async {
        rect("One", CGRect(x: 10, y: 10, width: 20, height: 20))
        rect("Two", CGRect(x: 60, y: 40, width: 20, height: 20))
        let frames = bench.a.children.map(\.frame)
        _ = await call("group_layers", ["layers": ["One", "Two"], "name": "G"])
        #expect(bench.a.children.map(\.name) == ["G"])
        #expect(bench.node("G")?.frame == CGRect(x: 10, y: 10, width: 70, height: 50))
        _ = await call("ungroup_layers", ["layers": ["G"]])
        #expect(bench.a.children.map(\.name) == ["One", "Two"])
        #expect(bench.a.children.map(\.frame) == frames)
    }

    @Test func layersAreFoundByIdNameOrPlace() async throws {
        rect("Title", CGRect(x: 0, y: 0, width: 10, height: 10))
        bench.step { bench.store.add(CanvasTests.rect("Title", CGRect(x: 600, y: 100, width: 10, height: 10)), onto: bench.b.id) }
        let onB = bench.b.children[0].id
        #expect(try MCPTools.layer(onB.uuidString, in: bench.store.doc) == onB)
        #expect(try MCPTools.layer("B/Title", in: bench.store.doc) == onB)
        #expect(throws: MCPError.self) { try MCPTools.layer("Title", in: bench.store.doc) }
        #expect(try MCPTools.layer("a", in: bench.store.doc) == bench.a.id)
    }

    @Test func coloursAreReadAsTheyAreWritten() throws {
        #expect(try MCPTools.color("#abc", "c").hex == "AABBCC")
        #expect(try MCPTools.color("rgba(255, 0, 0, 0.5)", "c") == RGBA(r: 1, g: 0, b: 0, a: 0.5))
        let half = try MCPTools.color("#11223380", "c")
        #expect(half.hex == "112233" && abs(half.a - 128.0 / 255) < 0.001)
        #expect(MCPTools.hex(half) == "#11223380")
        #expect(MCPTools.hex(.white) == "#FFFFFF")
        #expect(throws: MCPError.self) { try MCPTools.color("reddish", "c") }
    }

    @Test func aPathIsGivenInItsParentAndReadBackSo() async {
        _ = await call("add_layers", ["parent": "A", "layers": [["kind": "path", "name": "Tri", "path": "M 10 10 L 110 10 L 60 90 Z"]]])
        #expect(bench.node("Tri")?.frame == CGRect(x: 10, y: 10, width: 100, height: 80))
        _ = await call("update_layers", ["updates": [["layer": "Tri", "x": 20]]])
        let read = json(await call("get_layers", ["layers": ["Tri"]]).text)
        let path = ((read["layers"] as? [[String: Any]])?.first?["path"] as? String) ?? ""
        #expect(PathData.bounds(path) == CGRect(x: 20, y: 10, width: 100, height: 80))
    }

    @Test func aShadowGoesInsideByNameOrAsked() async {
        rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        _ = await call("update_layers", ["updates": [["layer": "R", "shadow": "pressed"]]])
        #expect(bench.node("R")?.shadow.inside == true && bench.node("R")?.shadow.blur == 6)
        let read = json(await call("get_layers", ["layers": ["R"]]).text)
        let shadow = (read["layers"] as? [[String: Any]])?.first?["shadow"] as? [String: Any]
        #expect(shadow?["inset"] as? Bool == true)
        _ = await call("update_layers", ["updates": [["layer": "R", "shadow": ["inset": false, "y": 3]]]])
        #expect(bench.node("R")?.shadow.outside == true && bench.node("R")?.shadow.y == 3)

        _ = await call("add_layers", ["parent": "A", "layers": [["kind": "line", "name": "L", "x1": 0, "y1": 0, "x2": 50, "y2": 0]]])
        let answer = await call("update_layers", ["updates": [["layer": "L", "shadow": ["inset": true]]]])
        #expect(!answer.failed && answer.text.contains("no inside"), "\(answer.text)")
        #expect(bench.node("L")?.shadow.outside == true)
    }

    @Test func aBlurGrowsTowardAnEdgeOrBetweenTwoPoints() async {
        rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        _ = await call("update_layers", ["updates": [["layer": "R", "blur": ["radius": 12, "ramp": "top"]]]])
        #expect(bench.node("R")?.blur?.ramp == BlurRamp.toward(2) && bench.node("R")?.blur?.radius == 12)
        _ = await call("update_layers", ["updates": [["layer": "R", "blur": ["ramp": ["end": ["x": 1, "y": 1]]]]]])
        #expect(bench.node("R")?.blur?.ramp == BlurRamp(start: BlurRamp.toward(2).start, end: CGPoint(x: 1, y: 1)))
        let read = json(await call("get_layers", ["layers": ["R"]]).text)
        let blur = (read["layers"] as? [[String: Any]])?.first?["blur"] as? [String: Any]
        #expect((blur?["ramp"] as? [String: Any])?["end"] as? [String: Double] == ["x": 1, "y": 1])
        let wrong = await call("update_layers", ["updates": [["layer": "R", "blur": ["ramp": "sideways"]]]])
        #expect(wrong.failed || wrong.text.contains("ramp"), "\(wrong.text)")
        _ = await call("update_layers", ["updates": [["layer": "R", "blur": ["ramp": "none"]]]])
        #expect(bench.node("R")?.blur?.ramp == nil && bench.node("R")?.blur?.radius == 12)
    }

    @Test func aLayerIsHeldUpInDepthAndReadBackSo() async {
        rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        _ = await call("update_layers", ["updates": [["layer": "R", "transform3D": ["x": 20, "y": -30]]]])
        #expect(bench.node("R")?.transform3D == Transform3D(x: 20, y: -30))
        let read = json(await call("get_layers", ["layers": ["R"]]).text)
        let turn = (read["layers"] as? [[String: Any]])?.first?["transform3D"] as? [String: Any]
        #expect(turn?["y"] as? Double == -30)
        _ = await call("update_layers", ["updates": [["layer": "R", "transform3D": "none"]]])
        #expect(bench.node("R")?.transform3D == nil)
        let answer = await call("update_layers", ["updates": [["layer": "A", "transform3D": ["x": 10]]]])
        #expect(answer.text.contains("page itself"), "\(answer.text)")
    }

    @Test func theClaudeDesktopExtensionListsEveryTool() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Extension test \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Bezzle.mcpb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ClaudeExtension.write(to: file)

        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, folder.appending(path: "out").path]
        try unzip.run()
        unzip.waitUntilExit()
        let out = folder.appending(path: "out")
        let read = { (path: String) in try JSONSerialization.jsonObject(with: Data(contentsOf: out.appending(path: path))) as? [String: Any] ?? [:] }
        let manifest = try read("manifest.json")
        let snapshot = try read("server/snapshot.json")
        let count = MCPTools().list.count
        #expect((manifest["tools"] as? [Any])?.count == count)
        #expect((snapshot["tools"] as? [Any])?.count == count)
        #expect((snapshot["initialize"] as? [String: Any])?["instructions"] as? String == MCPTools.instructions)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "server/index.js").path))
        #expect(NSImage(contentsOf: out.appending(path: "icon.png"))?.size == CGSize(width: 512, height: 512))
    }

    @Test func jsonKeepsItsOrderAndEscapes() {
        let value: JSONValue = ["b": 1, "a": [true, nil, 2.5], "s": .string("say \"hi\"\n\u{1}")]
        #expect(value.text == #"{"b":1,"a":[true,null,2.5],"s":"say \"hi\"\n\u0001"}"#)
    }
}
