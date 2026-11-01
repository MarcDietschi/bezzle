import Testing
import AppKit
@testable import Bezzle

/// The design inspected: distances read as a drawing reads them, a click taking the smallest thing
/// and then the next one out, nothing changed, looks written as code by their tokens, and the same
/// through the AI server.
@MainActor
struct InspectTests {
    /// Artboard A holding a group "Button" (a rectangle "Shape" and its words "Label") and B beside it.
    private func bench() -> Bench {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: 40, y: 200, width: 160, height: 44))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 1)
        var label = Node(kind: .text, name: "Label", frame: .zero)
        label.text = "Sign in"
        label.style?.size = 16
        label.refit()
        label.frame.origin = CGPoint(x: 120 - label.frame.width / 2, y: 222 - label.frame.height / 2)
        var button = Node(kind: .group, name: "Button", frame: .zero)
        button.children = [shape, label]
        let bench = Bench(extra: [button])
        bench.step { bench.store.edit("Fit") { $0.fitGroups() } }
        return bench
    }

    /// The middle of the label, on the canvas.
    private let onLabel = CGPoint(x: 220, y: 322)

    // MARK: Measuring

    @Test func distancesAreReadAsADrawingMarksThem() {
        // Inside another: from each side to the one round it.
        let inside = Inspect.spans(from: CGRect(x: 20, y: 10, width: 60, height: 20), to: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(inside.map(\.length).sorted() == [10, 20, 20, 20])
        // Side by side: across the gap, in the middle of where they face.
        let a = CGRect(x: 0, y: 0, width: 10, height: 10), b = CGRect(x: 30, y: 5, width: 10, height: 10)
        let side = Inspect.spans(from: a, to: b)
        #expect(side.count == 1)
        #expect(side.first?.length == 20)
        #expect(side.first?.from.y == 7.5)
        #expect(side.first?.reach == nil)
        #expect(Inspect.gaps(between: a, and: b) == [CGRect(x: 10, y: 5, width: 20, height: 5)])
        // On a slant: both ways, each meeting the far edge drawn on past its end.
        let slant = Inspect.spans(from: a, to: CGRect(x: 30, y: 40, width: 10, height: 10))
        #expect(slant.count == 2)
        #expect(Set(slant.map(\.length)) == [20, 30])
        #expect(slant.allSatisfy { $0.reach != nil })
        #expect(Inspect.gaps(between: a, and: CGRect(x: 30, y: 40, width: 10, height: 10)).isEmpty)
        // Lying partly over each other: side from side.
        #expect(Inspect.spans(from: a, to: CGRect(x: 5, y: 5, width: 10, height: 10)).map(\.length) == [5, 5, 5, 5])
        #expect(Inspect.Insets(of: CGRect(x: -4, y: 2, width: 10, height: 10), in: CGRect(x: 0, y: 0, width: 20, height: 20))
            == Inspect.Insets(top: 2, right: 14, bottom: 8, left: -4))
    }

    // MARK: On the canvas

    @Test func theModesFollowOneAnother() {
        let bench = Bench()
        bench.store.selection = [bench.a.id, bench.b.id]
        bench.store.inspecting = true
        #expect(bench.store.prototyping)
        #expect(bench.store.canvasMode == .inspect)
        // One thing at a time.
        #expect(bench.store.selection == [bench.a.id])
        bench.store.show(.prototype)
        #expect(!bench.store.inspecting)
        #expect(bench.store.canvasMode == .prototype)
        bench.store.show(.inspect)
        bench.store.prototyping = false
        #expect(!bench.store.inspecting)
        #expect(bench.store.canvasMode == .design)
    }

    @Test func aClickTakesTheSmallestThingAndAgainTheNextOneOut() {
        let bench = bench()
        let label = bench.node("Label")!.id, button = bench.node("Button")!.id
        bench.store.inspecting = true
        bench.click(onLabel)
        #expect(bench.store.selection == [label])
        bench.click(onLabel)
        #expect(bench.store.selection == [button])
        bench.click(onLabel)
        #expect(bench.store.selection == [bench.a.id])
        bench.click(onLabel)
        #expect(bench.store.selection == [label])
        // Escape takes the next one out too, and from the screen lets go.
        bench.key(53)
        #expect(bench.store.selection == [button])
        bench.key(53)
        #expect(bench.store.selection == [bench.a.id])
        bench.key(53)
        #expect(bench.store.selection.isEmpty)
        // A click on the paper lets go.
        bench.click(onLabel)
        bench.click(CGPoint(x: 50, y: 50))
        #expect(bench.store.selection.isEmpty)
    }

    @Test func nothingInspectedChanges() {
        let bench = bench()
        bench.store.inspecting = true
        let before = bench.store.doc
        let origin = bench.store.viewport.origin
        // A drag moves the view, as a hand moves the sheet.
        bench.drag(onLabel, CGPoint(x: 300, y: 380))
        #expect(bench.store.viewport.origin != origin)
        #expect(bench.store.selection.isEmpty)
        bench.click(onLabel)
        bench.key(51)
        bench.canvas.delete(nil)
        bench.canvas.cut(nil)
        bench.canvas.paste(nil)
        #expect(bench.store.doc == before)
        #expect(bench.node("Label") != nil)
    }

    @Test func whatThePointerIsOnIsMeasuredFromWhatIsPicked() {
        let bench = bench()
        bench.store.inspecting = true
        let tool = bench.canvas.inspectTool
        let label = bench.node("Label")!.id, button = bench.node("Button")!.id, shape = bench.node("Shape")!.id
        bench.move(onLabel)
        #expect(tool.showing == .outline(label))
        bench.store.selection = [label]
        // On the picked layer: how far it lies inside what a click would take next.
        bench.move(onLabel)
        #expect(tool.showing == .around(label, button))
        // On something else: the way to it.
        bench.move(CGPoint(x: 150, y: 310))
        #expect(tool.showing == .between(label, shape))
        bench.move(CGPoint(x: 700, y: 200))
        #expect(tool.showing == .between(label, bench.b.id))
        // On the paper: its own size.
        bench.move(CGPoint(x: 50, y: 50))
        #expect(tool.showing == .size(label))
        // The screen picked, a layer on it is measured to its edges.
        bench.store.selection = [bench.a.id]
        bench.move(onLabel)
        #expect(tool.showing == .between(label, bench.a.id))
    }

    // MARK: As code

    @Test func looksAreWrittenAsCodeByTheirTokens() {
        let bench = bench()
        let shape = bench.node("Shape")!.id, label = bench.node("Label")!.id
        let card = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.16), x: 0, y: 3, blur: 6)
        bench.step {
            bench.store.edit("Styles") { doc in
                doc.styles = [
                    Style(name: "Brand Blue", look: .colour(ColourLook(color: RGBA(r: 0.2, g: 0.4, b: 1)))),
                    Style(name: "Body", look: .text(TypeLook(TextStyle(family: "System", face: "Medium", size: 16)))),
                    Style(name: "Card", look: .shadow(card)),
                    Style(name: "Soft", look: .corners(CornerLook(radius: 12))),
                ]
                let ids = doc.styles!.map(\.id)
                doc.update(shape) {
                    $0.fill.named = ids[0]
                    $0.cornerRadius = 12
                    $0.cornersNamed = ids[3]
                    $0.shadow = card
                    $0.shadow.named = ids[2]
                }
                doc.update(label) {
                    var t = $0.style!
                    t.face = "Medium"
                    t.named = ids[1]
                    $0.style = t
                }
            }
        }
        let doc = bench.store.seenDoc, tokens = Inspect.Tokens(doc)
        let css = Inspect.css(doc.node(shape)!, in: doc, tokens: tokens)
        #expect(css.hasPrefix(".shape {"))
        #expect(css.contains("  width: 160px;"))
        #expect(css.contains("  background: var(--color-brand-blue); /* #3366FF */"))
        #expect(css.contains("  border-radius: var(--radius-soft); /* 12px */"))
        #expect(css.contains("  box-shadow: var(--shadow-card);"))
        let words = Inspect.css(doc.node(label)!, in: doc, tokens: tokens)
        #expect(words.contains("  white-space: nowrap;"))
        #expect(words.contains("  font-size: var(--font-body-size); /* 16px */"))
        #expect(words.contains("  font-weight: var(--font-body-weight); /* 500 */"))
        let swift = Inspect.swiftUI(doc.node(shape)!, in: doc, tokens: tokens)
        #expect(swift.hasPrefix("RoundedRectangle(cornerRadius: Tokens.Corners.soft)"))
        #expect(swift.contains("    .fill(Tokens.Colors.brandBlue)"))
        #expect(swift.contains("    .frame(width: 160, height: 44)"))
        #expect(swift.contains("    .shadowToken(Tokens.Shadows.card)"))
        let text = Inspect.swiftUI(doc.node(label)!, in: doc, tokens: tokens)
        #expect(text.hasPrefix("Text(\"Sign in\")"))
        #expect(text.contains("    .typeToken(Tokens.Typography.body)"))
        #expect(text.contains("    .fixedSize()"))
        // The tokens themselves name their type so that it builds: a type can't be called Type.
        #expect(DesignTokens.swiftUI(doc, named: "Shop").contains("    enum Typography {"))
    }

    @Test func aGroupIsWrittenWithWhatItHolds() {
        let bench = bench()
        let doc = bench.store.seenDoc
        let button = doc.node(bench.node("Button")!.id)!
        let label = bench.node("Label")!
        let css = Inspect.css(button, in: doc, tokens: .none)
        #expect(css.hasPrefix(".button {\n  position: relative;\n  width: 160px;"))
        #expect(css.contains(".button > .shape {\n  position: absolute;\n  left: 0;\n  top: 0;"))
        #expect(css.contains(".button > .label {\n  position: absolute;\n  left: \(Inspect.px(label.frame.minX));"))
        let swift = Inspect.swiftUI(button, in: doc, tokens: .none)
        #expect(swift.hasPrefix("ZStack(alignment: .topLeading) {\n    Rectangle()\n        .fill("))
        #expect(swift.contains("    Text(\"Sign in\")"))
        #expect(swift.contains("        .offset(x: \(Inspect.number(label.frame.minX)), y: \(Inspect.number(label.frame.minY)))"))
        #expect(swift.contains("}\n    .frame(width: 160, height: 44)"))
    }

    @Test func plainLooksAreWrittenByTheirValues() {
        var n = Node(kind: .rectangle, name: "2 Pill", frame: CGRect(x: 0, y: 0, width: 80, height: 32))
        n.fill = Fill(color: RGBA(r: 1, g: 0, b: 0, a: 0.5))
        n.cornerRadius = 16
        n.border = Border(on: true, color: .black, width: 2, position: .inside)
        n.opacity = 0.8
        let css = Inspect.css(n, in: BezzleDocument(), tokens: .none)
        #expect(css.hasPrefix("._2-pill {"))
        #expect(css.contains("  background: rgba(255, 0, 0, 0.5);"))
        #expect(css.contains("  border: 2px solid #000000;"))
        #expect(css.contains("  box-sizing: border-box;"))
        #expect(css.contains("  border-radius: 16px;"))
        #expect(css.contains("  opacity: 0.8;"))
        let swift = Inspect.swiftUI(n, in: BezzleDocument(), tokens: .none)
        #expect(swift.hasPrefix("Capsule()"))
        #expect(swift.contains("    .fill(Color(red: 1, green: 0, blue: 0).opacity(0.5))"))
        #expect(swift.contains("    .overlay { Capsule().strokeBorder(Color(red: 0, green: 0, blue: 0), lineWidth: 2) }"))
        #expect(swift.contains("    .opacity(0.8)"))
    }

    @Test func aLayerIsTakenAwayAsAFile() {
        let bench = bench()
        bench.store.inspecting = true
        let shape = bench.node("Shape")!.id
        let png = InspectCopy.file(of: shape, as: .png, scale: 2, store: bench.store)
        #expect(png?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
        let svg = InspectCopy.file(of: shape, as: .svg, scale: 1, store: bench.store).map { String(decoding: $0, as: UTF8.self) }
        #expect(svg?.contains("<svg") == true)
        let url = InspectCopy.dragged(shape, as: .png, scale: 2, store: bench.store)
        #expect(url?.lastPathComponent == "Shape@2x.png")
        #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}

/// Inspecting through the AI server, called as the server calls it.
@MainActor
struct InspectMCPTests {
    let bench = Bench(extra: [CanvasTests.rect("Go", CGRect(x: 20, y: 30, width: 120, height: 40))])
    let tools = MCPTools()

    init() {
        MCPTools.opened(bench.store)
    }

    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    @Test func aLayerIsHandedOverAsItIsBuilt() async throws {
        let got = await call("inspect", ["layer": "Go", "to": "B"])
        #expect(!got.failed, "\(got.text)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(got.text.utf8)) as? [String: Any])
        #expect(json["path"] as? [String] == ["A", "Go"])
        #expect(json["insets"] as? [String: Double] == ["top": 30, "right": 260, "bottom": 230, "left": 20])
        #expect(json["onScreen"] as? [String: Double] == ["x": 20, "y": 30, "width": 120, "height": 40])
        let distances = json["distances"] as? [[String: Any]]
        #expect(distances?.count == 1)
        #expect(distances?.first?["length"] as? Double == 360)
        #expect((json["css"] as? String)?.contains("width: 120px;") == true)
        #expect((json["swiftui"] as? String)?.contains(".frame(width: 120, height: 40)") == true)
        let css = await call("inspect", ["layer": "Go", "format": "css"])
        #expect(css.text.contains("\"css\""))
        #expect(!css.text.contains("\"swiftui\""))
        let wrong = await call("inspect", ["layer": "Nothing"])
        #expect(wrong.failed)
    }
}
