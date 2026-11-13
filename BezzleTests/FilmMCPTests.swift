import Testing
import AppKit
@testable import Bezzle

/// What an assistant sees of a film and makes of it: moments of it drawn, a sheet of them, the
/// camera sent to look at layers, the movie saved, and the ask that brings it all.
@MainActor
@Suite(.serialized)
struct FilmMCPTests {
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

    private func size(_ png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test func drawsTheFilmAtMomentsOnASheet() async throws {
        let set = await call("animate", ["artboard": "A", "length": 2, "moves": [["move": "rise", "layers": ["Title", "Card"], "apart": 0.2]]])
        #expect(!set.failed)
        let one = await call("render", ["layer": "A", "time": 0.5, "scale": 1])
        #expect(!one.failed && one.pictures.count == 1)
        #expect(size(one.pictures[0]) == CGSize(width: 400, height: 300))
        #expect(json(one.text)["moments"] as? [Double] == [0.5])
        // At the start the layers are still below and see-through; at the end where the design has them.
        let start = await call("render", ["layer": "A", "time": 0, "scale": 1])
        let end = await call("render", ["layer": "A", "time": 2, "scale": 1])
        #expect(start.pictures != end.pictures)
        let sheet = await call("render", ["layer": "Card", "frames": 6, "maxSize": 900])
        #expect(!sheet.failed && sheet.pictures.count == 1)
        let said = json(sheet.text)
        #expect((said["moments"] as? [Double])?.count == 6)
        #expect((said["moments"] as? [Double])?.first == 0)
        #expect(said["order"] as? String == "2 across, 3 down, left to right and top to bottom")
        let drawn = try #require(size(sheet.pictures[0]))
        #expect(max(drawn.width, drawn.height) <= 900 && drawn.height > drawn.width)
        #expect(await call("render", ["layer": "A", "frames": 40]).failed)
    }

    @Test func sendsTheCameraToLookAtLayers() async throws {
        let sent = await call("animate", ["artboard": "A", "keys": [["time": 0, "to": ["Title", "Card"]], ["time": 1.5, "to": "Card", "pace": "smooth"]]])
        #expect(!sent.failed)
        let board = bench.store.doc.nodes[0]
        let move = try #require(board[track: .cameraMove]), zoom = try #require(board[track: .cameraZoom])
        #expect(move.keys.map(\.t) == [0, 1.5] && zoom.keys.map(\.t) == [0, 1.5])
        // The card's middle is 290, 210 on a 400 by 300 artboard: 90 right of its middle and 60 down.
        #expect(move.keys[1].v == [90, 60])
        // As close as the card fits with a third more round it: its width decides, 400 / (140 * 1.35).
        #expect(abs(zoom.keys[1].v[0] - 400 / (140 * 1.35)) < 1e-6)
        #expect(await call("animate", ["artboard": "A", "keys": [["time": 1, "to": "Card", "value": [0, 0]]]]).failed)
    }

    @Test(.timeLimit(.minutes(3))) func savesTheFilmAsAMovie() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("film-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = await call("export", ["layers": ["A"], "format": "mp4", "folder": folder.path])
        #expect(still.failed && still.text.contains("nothing that moves"))
        _ = await call("animate", ["artboard": "A", "length": 0.5, "moves": [["move": "fade", "layers": ["Card"]]]])
        let saved = await call("export", ["layers": ["Card"], "format": "mp4", "fps": 10, "scale": 0.5, "folder": folder.path])
        #expect(!saved.failed)
        let movie = try #require((json(saved.text)["movies"] as? [[String: Any]])?.first)
        let file = try #require(movie["file"] as? String)
        #expect(file.hasSuffix("/A.mp4") && FileManager.default.fileExists(atPath: file))
        #expect(movie["pixels"] as? String == "200×150" && movie["fps"] as? Int == 10)
        // Again, beside it, numbered.
        let again = await call("export", ["layers": ["A"], "format": "mp4", "fps": 10, "scale": 0.5, "folder": folder.path])
        #expect((json(again.text)["movies"] as? [[String: Any]])?.first?["file"] as? String == folder.appendingPathComponent("A 2.mp4").path)
    }

    @Test func theAskBringsTheFilmAndHowToDoItWell() async throws {
        #expect(MCPTools.prompts.contains { $0.name == "animate" })
        let asked = try await tools.prompt("animate", ["design": bench.store.name, "artboard": "A", "brief": "a calm product tour"])
        let read = try JSONSerialization.jsonObject(with: asked.data) as? [String: Any]
        let contents = (read?["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? [String: Any] }
        let texts = contents.compactMap { $0["text"] as? String }
        #expect(texts.first?.contains("a calm product tour") == true)
        #expect(texts.first?.contains("render with frames") == true)
        #expect(texts.contains { $0.contains("\"Card\"") })
        #expect(contents.contains { $0["type"] as? String == "image" })
        #expect(MCPTools.instructions.contains("export with format mp4"))
    }
}
