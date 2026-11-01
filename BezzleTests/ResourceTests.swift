import Testing
import AppKit
@testable import Bezzle

/// Putting the resources panel's parts and icons into a design: where they land, how they fit
/// the artboard, light or dark, and icons taking each other's place; by hand and by the AI.
@MainActor
struct ResourceTests {
    /// A phone-sized artboard "Phone" at 0,0 and a dark one "Night" beside it.
    let bench: Bench = {
        let bench = Bench()
        bench.step {
            bench.store.edit("Setup") { doc in
                var phone = Node(kind: .artboard, name: "Phone", frame: CGRect(x: 0, y: 1000, width: 402, height: 874))
                phone.fill = Fill(color: .white)
                var night = Node(kind: .artboard, name: "Night", frame: CGRect(x: 500, y: 1000, width: 402, height: 874))
                night.fill = Fill(color: .hex("#111111"))
                doc.nodes += [phone, night]
            }
        }
        return bench
    }()
    let tools = MCPTools()

    private func board(_ name: String) -> Node { bench.node(name)! }

    /// As a click or a drop in the panel does, in one step of the undo history.
    private func place(_ resource: Resource, at p: CGPoint, on target: UUID? = nil) -> UUID? {
        var made: UUID?
        bench.step { made = bench.store.place(resource, at: p, on: target) }
        return made
    }

    @Test func barsSettleAlongTheEdgeUnderWhatIsThere() throws {
        let phone = board("Phone")
        // Let go anywhere on the artboard, the status bar goes along its top, as wide as it.
        let status = try #require(place(.component("ios.status-bar"), at: CGPoint(x: 200, y: 1500)))
        #expect(bench.store.doc.absoluteFrame(of: status) == CGRect(x: 0, y: 1000, width: 402, height: 54))
        #expect(bench.store.doc.artboard(of: status)?.id == phone.id)
        // A second bar along the top goes under the first.
        let second = try #require(place(.component("ios.status-bar"), at: CGPoint(x: 200, y: 1300)))
        #expect(bench.store.doc.absoluteFrame(of: second)?.minY == 1054)
        // A tab bar along the bottom.
        let tabs = try #require(place(.component("ios.tab-bar"), at: CGPoint(x: 200, y: 1200)))
        let frame = try #require(bench.store.doc.absoluteFrame(of: tabs))
        #expect(frame.maxY == 1874 && frame.width == 402 && frame.minX == 0)
        #expect(bench.store.selection == [tabs])
    }

    @Test func aBarOnAnArtboardFarWiderThanItIsLeftWhereItIs() throws {
        // On an artboard more than twice as wide as a phone's bar, the bar is not stretched across it.
        bench.step { bench.store.edit("Wide") { $0.update(bench.node("Phone")!.id) { $0.frame.size.width = 1440 } } }
        let id = try #require(place(.component("ios.status-bar"), at: CGPoint(x: 1200, y: 1400)))
        let frame = try #require(bench.store.doc.absoluteFrame(of: id))
        #expect(frame.width == 402)
        #expect(abs(frame.midX - 1200) <= 1 && abs(frame.midY - 1400) <= 1)
    }

    @Test func partsComeDarkOnADarkArtboard() throws {
        let light = try #require(bench.store.placing(.component("ios.toggle"), at: CGPoint(x: 200, y: 1400)))
        let dark = try #require(bench.store.placing(.component("ios.toggle"), at: CGPoint(x: 700, y: 1400)))
        #expect(light.board == board("Phone").id && dark.board == board("Night").id)
        func track(_ n: Node) -> RGBA? { n.children.first { $0.name == "Track" }?.fill.color }
        #expect(track(light.node) != nil && track(light.node) != track(dark.node))
        #expect(Kits.isDark(board("Night")) && !Kits.isDark(board("Phone")))
    }

    @Test func aPartLetGoOffEveryArtboardLiesOnTheCanvas() throws {
        let id = try #require(place(.component("ios.toggle"), at: CGPoint(x: -500, y: -500)))
        #expect(bench.store.doc.nodes.contains { $0.id == id })
        #expect(bench.store.doc.absoluteFrame(of: id)?.center == CGPoint(x: -500, y: -500))
    }

    @Test func iconsComeInkOrLightAndTakeEachOthersPlace() throws {
        let heart = try #require(place(.icon(.lucide, "heart", IconStyle(index: 0, weight: 2)), at: CGPoint(x: 200, y: 1400)))
        let node = try #require(bench.store.node(heart))
        #expect(node.kind == .path && node.name == "heart" && node.frame.size == CGSize(width: 24, height: 24))
        #expect(node.fill.color.r < 0.2)
        let onNight = try #require(place(.icon(.material, "home", IconStyle(index: 1)), at: CGPoint(x: 700, y: 1400)))
        #expect(try #require(bench.store.node(onNight)).fill.color.r > 0.8)

        // Recoloured and grown, then another icon let go onto it: the same layer, the new outline.
        bench.step { bench.store.edit("Change") { $0.update(heart) { n in n.fill.color = .hex("#FF0000"); n.frame.size = CGSize(width: 48, height: 48) } } }
        let swapped = try #require(place(.icon(.phosphor, "star", IconStyle(index: 4)), at: CGPoint(x: 200, y: 1400), on: heart))
        #expect(swapped == heart)
        let star = try #require(bench.store.node(heart))
        #expect(star.name == "star" && star.fill.color.hex == "FF0000")
        #expect(abs(star.frame.width - 48) < 0.01 && abs(star.frame.minX - 200 + 12) < 0.01)
        #expect(bench.store.doc.allNodes.filter { $0.kind == .path }.count == 2)
    }

    @Test func placingIsOneStepToUndo() throws {
        let before = bench.store.doc
        _ = place(.component("ios.tab-bar"), at: CGPoint(x: 200, y: 1400))
        #expect(bench.store.doc != before)
        bench.undo.undo()
        #expect(bench.store.doc == before)
    }

    // MARK: The AI

    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        MCPTools.opened(bench.store)
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    @Test func theAIListsAndAdds() async throws {
        let all = await call("list_resources", [:])
        #expect(!all.failed && all.text.contains("\"ios\"") && all.text.contains("lucide"))
        let ios = await call("list_resources", ["library": "ios"])
        #expect(ios.text.contains("ios.tab-bar"))
        let found = await call("list_resources", ["query": "heart"])
        #expect(found.text.contains("lucide/heart"))

        let bar = await call("add_resource", ["resource": "ios.status-bar", "artboard": "Night"])
        #expect(!bar.failed, "\(bar.text)")
        let status = try #require(bench.store.doc.allNodes.first { $0.name == "Status Bar" })
        #expect(bench.store.doc.artboard(of: status.id)?.name == "Night")
        #expect(status.frame == CGRect(x: 0, y: 0, width: 402, height: 54))

        let icon = await call("add_resource", ["resource": "phosphor/heart", "artboard": "Phone", "x": 10, "y": 20, "size": 32, "style": "fill", "color": "#3559C7"])
        #expect(!icon.failed, "\(icon.text)")
        let heart = try #require(bench.node("heart"))
        #expect(heart.frame == CGRect(x: 10, y: 20, width: 32, height: 32))
        #expect(heart.fill.color.hex == "3559C7")
        #expect(heart.path == Icons.icon("heart", in: .phosphor)?.paths[4])

        let swap = await call("add_resource", ["resource": "lucide/star", "replace": "heart"])
        #expect(!swap.failed, "\(swap.text)")
        #expect(bench.node("star")?.id == heart.id)

        let wrong = await call("add_resource", ["resource": "lucide/hearts"])
        #expect(wrong.failed && wrong.text.contains("heart"))
        let narrow = await call("add_resource", ["resource": "ios.tab-bar", "width": 100])
        #expect(narrow.failed)
    }
}
