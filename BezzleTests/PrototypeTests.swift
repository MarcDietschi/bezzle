import Testing
import AppKit
@testable import Bezzle

/// The prototype: where layers go, read from the canvas and kept per layer through components,
/// grids, files and sharing; threads pulled by hand on the canvas; states read from variants'
/// names; tokens for code; and the assistant's tools and prompts.
@MainActor
struct PrototypeTests {
    /// Artboard A holding a group "Button" (a rectangle and its words) and B beside it.
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

    // MARK: States

    @Test func variantNamesSayTheirStatesInEveryLanguage() {
        #expect(VariantState.of("Hover") == .hover)
        #expect(VariantState.of("Button / Pressed") == .pressed)
        #expect(VariantState.of("Gedrückt") == .pressed)
        #expect(VariantState.of("Appuyé") == .pressed)
        #expect(VariantState.of("Premuto") == .pressed)
        #expect(VariantState.of("Ausgewählt") == .selected)
        #expect(VariantState.of("Sélectionné") == .selected)
        #expect(VariantState.of("Deaktiviert") == .disabled)
        #expect(VariantState.of("Lädt") == .loading)
        #expect(VariantState.of("Chargement") == .loading)
        #expect(VariantState.of("Errore") == .error)
        #expect(VariantState.of("Primary selected hover") == .hover)
        #expect(VariantState.of("Large") == nil)
        #expect(VariantState.of("Variant 2") == nil)
        // Each state's own name, in the language it is shown in, is read as that state.
        for s in VariantState.allCases { #expect(VariantState.of(s.title) == s, "\(s.title)") }
    }

    @Test func aComponentsStatesComeFromItsVariantsNames() {
        let bench = bench()
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let copy = bench.store.selection[0]
        bench.step { bench.store.addVariant(from: copy) }
        let master = bench.store.doc.masters[0]
        let v = master.master!.variants[0]
        bench.step { bench.store.renameVariant(v, of: master.id, to: "Hover") }
        let states = Components.states(of: bench.store.doc.masters[0])
        #expect(states[.hover] == .some(v))
        #expect(states[.pressed] == nil)
        // The first variant is no state until it is named one.
        #expect(Components.state(of: nil, in: bench.store.doc.masters[0]) == nil)
    }

    // MARK: Linking

    @Test func linkingAndUnlinkingIsOneStepEach() {
        let bench = bench()
        let button = bench.node("Button")!.id
        bench.step { bench.store.linkFlow([button], to: bench.b.id) }
        #expect(bench.store.doc.node(button)?.flow?.to == bench.b.id)
        bench.step { bench.store.setNote("  after signing in ", for: [button]) }
        #expect(bench.store.doc.node(button)?.flow?.note == "after signing in")
        bench.step { bench.store.setMotion(.dissolve, for: [button]) }
        #expect(bench.store.doc.node(button)?.flow?.motion == .dissolve)
        bench.step { bench.store.setMotion(.auto, for: [button]) }
        #expect(bench.store.doc.node(button)?.flow?.motion == nil)
        bench.step { bench.store.unlinkFlow([button]) }
        #expect(bench.store.doc.node(button)?.flow == nil)
        bench.undoLast()
        #expect(bench.store.doc.node(button)?.flow?.note == "after signing in")
    }

    @Test func aLayerInACopyLinksTheWholeCopy() {
        let bench = bench()
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let copy = bench.store.selection[0]
        let label = bench.store.doc.node(copy)!.children.first { $0.name == "Label" }!.id
        #expect(bench.store.doc.linkable(label) == copy)
        bench.step { bench.store.linkFlow([label], to: bench.b.id) }
        #expect(bench.store.doc.node(copy)?.flow?.to == bench.b.id)
        #expect(bench.store.doc.node(label)?.flow == nil)
    }

    @Test func whereACopyGoesIsItsOwnAsItsWordsAre() {
        let bench = bench()
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let first = bench.store.selection[0]
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 60)) }
        let second = bench.store.selection[0]
        // A flow on the first copy, and on a layer deep in it (as the assistant might set one).
        let label = bench.store.doc.node(first)!.children.first { $0.name == "Label" }!.id
        bench.step { bench.store.linkFlow([first], to: bench.b.id) }
        bench.step { bench.store.edit("Deep") { $0.update(label) { $0.flow = FlowLink(back: true) } } }
        // The look changed in the other copy goes everywhere; where they go does not.
        let shape = bench.store.doc.node(second)!.children.first { $0.name == "Shape" }!.id
        bench.step { bench.store.update([shape], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        let doc = bench.store.doc
        #expect(doc.node(first)?.children.first { $0.name == "Shape" }?.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(doc.node(first)?.flow?.to == bench.b.id)
        #expect(doc.node(label)?.flow?.goesBack == true)
        #expect(doc.node(second)?.flow == nil)
        #expect(doc.node(second)?.children.allSatisfy { $0.flow == nil } == true)
        // The component itself goes nowhere.
        func flows(_ n: Node) -> Bool { n.flow != nil || n.children.contains(where: flows) }
        #expect(!doc.masters.contains(where: flows))
    }

    @Test func aGridsCellsEachGoWhereTheyWereToldTo() {
        let bench = bench()
        let button = bench.node("Button")!.id
        var made: UUID?
        bench.step { bench.store.edit("Grid") { made = DocumentStore.makeRepeatGrid(of: [button], in: &$0, rows: 3, rowGap: 10) } }
        let grid = bench.store.doc.node(made!)!
        #expect(grid.children.count == 3)
        let third = grid.children[2].id
        bench.step { bench.store.linkFlow([third], to: bench.b.id) }
        // The first cell changes, and every cell is made again from it.
        let shape = bench.store.doc.node(grid.children[0].id)!.children.first { $0.name == "Shape" }!.id
        bench.step { bench.store.update([shape], "Fill") { $0.fill.color = RGBA(r: 0, g: 1, b: 0) } }
        let now = bench.store.doc.node(made!)!
        #expect(now.children[2].flow?.to == bench.b.id)
        #expect(now.children[1].flow == nil)
        #expect(now.children[0].flow == nil)
        #expect(now.children[2].children.first { $0.name == "Shape" }?.fill.color == RGBA(r: 0, g: 1, b: 0))
    }

    @Test func flowsTravelWithTheFileAndWithSharing() throws {
        let bench = bench()
        let button = bench.node("Button")!.id
        bench.step { bench.store.linkFlow([button], to: bench.b.id) }
        bench.step { bench.store.setNote("after signing in", for: [button]) }
        bench.step { bench.store.setStart(bench.a.id) }
        let doc = bench.store.doc
        let data = try JSONEncoder().encode(doc)
        let read = try JSONDecoder().decode(BezzleDocument.self, from: data)
        #expect(read.node(button)?.flow == doc.node(button)?.flow)
        #expect(read.node(bench.a.id)?.starts == true)
        let shared = FlatDesign(doc).document()
        #expect(shared.node(button)?.flow?.note == "after signing in")
        #expect(shared.node(bench.a.id)?.starts == true)
        #expect(LayerField.all.contains { $0.name == "flow" } && LayerField.all.contains { $0.name == "starts" })
    }

    @Test func aDuplicatedScreenKeepsWhereItsLayersGo() {
        let bench = bench()
        let button = bench.node("Button")!.id
        let b = bench.b.id
        bench.step { bench.store.linkFlow([button], to: b) }
        bench.store.selection = [bench.a.id]
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 400)) }
        let copy = bench.store.doc.node(bench.store.selection[0])!
        #expect(copy.id != bench.a.id)
        #expect(copy.children.first { $0.name == "Button" }?.flow?.to == b)
    }

    // MARK: Reading the canvas

    @Test func whereScreensLieSaysHowTheyMove() {
        func board(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 390, _ h: CGFloat = 844) -> Node {
            Node(kind: .artboard, name: "S", frame: CGRect(x: x, y: y, width: w, height: h))
        }
        let a = board(0, 0)
        #expect(Prototype.way(from: a, to: board(500, 0), motion: nil) == .push(from: CGVector(dx: 1, dy: 0), morph: false))
        #expect(Prototype.way(from: a, to: board(-500, 30), motion: nil) == .push(from: CGVector(dx: -1, dy: 0), morph: false))
        #expect(Prototype.way(from: a, to: board(40, 1000), motion: nil) == .push(from: CGVector(dx: 0, dy: 1), morph: false))
        #expect(Prototype.way(from: a, to: board(500, 0, 390, 420), motion: nil) == .sheet)
        #expect(Prototype.way(from: a, to: board(500, 0), motion: .dissolve) == .dissolve)
        #expect(Prototype.way(from: a, to: board(500, 0), motion: .instant) == .instant)
        #expect(Prototype.way(from: a, to: board(500, 0, 390, 420), motion: .slide) == .push(from: CGVector(dx: 1, dy: 0), morph: false))
    }

    @Test func twoScreensMostlyTheSameMorph() {
        var a = Node(kind: .artboard, name: "Closed", frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 20, y: 600, width: 350, height: 200))
        let title = Node(kind: .text, name: "Title", frame: CGRect(x: 20, y: 40, width: 200, height: 30))
        let bar = Node(kind: .rectangle, name: "Bar", frame: CGRect(x: 0, y: 0, width: 390, height: 30))
        a.children = [bar, title, card]
        var b = a.freshCopy()
        b.frame.origin.x = 500
        card.frame = CGRect(x: 0, y: 200, width: 390, height: 644)
        b.children[2].frame = card.frame
        #expect(Prototype.way(from: a, to: b, motion: nil) == .push(from: CGVector(dx: 1, dy: 0), morph: true))
        // Screens of one app sharing only their bar slide; the bar stays put as they do.
        var c = Node(kind: .artboard, name: "Other", frame: CGRect(x: 500, y: 0, width: 390, height: 844))
        c.children = [bar.freshCopy(), Node(kind: .ellipse, name: "Photo", frame: CGRect(x: 40, y: 80, width: 300, height: 300)),
                      Node(kind: .text, name: "Caption", frame: CGRect(x: 40, y: 400, width: 300, height: 30))]
        #expect(Prototype.way(from: a, to: c, motion: nil) == .push(from: CGVector(dx: 1, dy: 0), morph: false))
        let pairs = Prototype.matches(a.children, c.children)
        #expect(pairs.count == 1)
        #expect(Prototype.same(pairs.values.first!, c.children[0]))
        // A copy of the screen with most of it hidden and one thing opened up still morphs.
        var d = a.freshCopy()
        d.frame.origin.y = 1000
        d.children[1].hidden = true
        d.children[2].frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        #expect(Prototype.way(from: a, to: d, motion: nil) == .push(from: CGVector(dx: 0, dy: 1), morph: true))
    }

    @Test func thePrototypeStartsWhereItIsMarked() {
        let bench = bench()
        let button = bench.node("Button")!.id
        // Unmarked: where a flow leaves that none reaches.
        bench.step { bench.store.linkFlow([button], to: bench.b.id) }
        #expect(Prototype.start(of: bench.store.doc)?.id == bench.a.id)
        bench.step { bench.store.setStart(bench.b.id) }
        #expect(Prototype.start(of: bench.store.doc)?.id == bench.b.id)
        #expect(bench.store.doc.artboards.filter { $0.starts == true }.count == 1)
        bench.step { bench.store.setStart(bench.a.id) }
        #expect(bench.store.doc.artboards.filter { $0.starts == true }.map(\.id) == [bench.a.id])
        #expect(Prototype.steps(from: bench.a.id, in: bench.store.doc)[bench.b.id] == 1)
    }

    // MARK: The canvas

    @Test func aThreadPulledOntoAScreenLinksIt() {
        let bench = bench()
        bench.store.prototyping = true
        let button = bench.node("Button")!.id
        let from = bench.store.doc.absoluteFrame(of: button)!
        bench.drag(CGPoint(x: from.midX, y: from.midY), CGPoint(x: bench.b.frame.midX, y: bench.b.frame.midY))
        #expect(bench.store.doc.node(button)?.flow?.to == bench.b.id)
        // Nothing moved: in the prototype a drag pulls a thread.
        #expect(bench.store.doc.absoluteFrame(of: button) == from)
        // Pulled out of the layer again and let go in the open, it springs back: nothing changes.
        bench.drag(CGPoint(x: from.midX, y: from.midY), CGPoint(x: 550, y: 1000))
        #expect(bench.store.doc.node(button)?.flow?.to == bench.b.id)
        // Pulled off the screen by its end and let go in the open, it is cut.
        bench.drag(CGPoint(x: bench.b.frame.minX, y: from.midY), CGPoint(x: 550, y: 1000))
        #expect(bench.store.doc.node(button)?.flow == nil)
        // A thread pulled to the well beside its screen goes back.
        bench.drag(CGPoint(x: from.midX, y: from.midY), CGPoint(x: bench.a.frame.minX - 38, y: from.midY))
        #expect(bench.store.doc.node(button)?.flow?.goesBack == true)
    }

    @Test func deleteInThePrototypeCutsThreadsNeverLayers() {
        let bench = bench()
        let button = bench.node("Button")!.id
        bench.step { bench.store.linkFlow([button], to: bench.b.id) }
        bench.store.prototyping = true
        bench.store.selection = [button]
        bench.key(51)
        #expect(bench.store.doc.node(button) != nil)
        #expect(bench.store.doc.node(button)?.flow == nil)
        // The drawing tools' keys do nothing here.
        bench.key(15, "r")
        #expect(bench.store.tool == .select)
    }

    @Test func comingIntoThePrototypePutsTheToolsDown() {
        let bench = bench()
        bench.store.tool = .rectangle
        bench.store.prototyping = true
        #expect(bench.store.tool == .select)
        bench.store.play()
        #expect(bench.store.player != nil)
        bench.store.prototyping = false
        #expect(bench.store.player == nil)
    }

    // MARK: Playing

    @Test func playingFollowsTheFlowsAndComesBack() {
        let bench = bench()
        let button = bench.node("Button")!.id
        bench.step { bench.store.linkFlow([button], to: bench.b.id) }
        bench.store.play(from: bench.a.id)
        let player = bench.store.player!
        #expect(player.visit.board == bench.a.id)
        // A tap on the button, in the device's screen's points.
        let f = bench.store.doc.absoluteFrame(of: button)!.offsetBy(dx: -bench.a.frame.minX, dy: -bench.a.frame.minY)
        player.phase = .playing
        player.down(at: CGPoint(x: f.midX, y: f.midY))
        player.up(at: CGPoint(x: f.midX, y: f.midY))
        #expect(player.visit.board == bench.b.id)
        player.back()
        #expect(player.visit.board == bench.a.id)
        // No way back from the first: the device shakes its head.
        let before = player.refusals
        player.back()
        #expect(player.refusals == before + 1)
        // A move sets off, and the screen's picture is made.
        player.take(FlowLink(to: bench.b.id), from: button)
        #expect(player.transit != nil)
        #expect(player.picture() != nil)
        #expect(player.scene(of: player.visit)?.board.name == "B")
        #expect(!player.tappable().isEmpty || player.visit.board == bench.b.id)
    }

    @Test func aScreenIsPlayedOnTheDeviceItIsFor() {
        #expect(Player.device(for: CGSize(width: 402, height: 874)).0 == .phone(island: true))
        let long = Player.device(for: CGSize(width: 402, height: 2400))
        #expect(long.1.width == 402 && long.1.height < 1000)
        #expect(Player.device(for: CGSize(width: 1440, height: 1024)).0 == .browser)
    }

    // MARK: Tokens

    private func styled() -> Bench {
        let bench = bench()
        let shape = bench.node("Shape")!.id
        bench.step {
            bench.store.edit("Styles") { doc in
                doc.styles = [
                    Style(name: "Brand Blue", look: .colour(ColourLook(color: RGBA(r: 0.2, g: 0.4, b: 1)))),
                    Style(name: "Title", look: .text(TypeLook(TextStyle(family: "System", face: "Semibold", size: 28)))),
                    Style(name: "Card", look: .shadow(Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.16), x: 0, y: 3, blur: 6))),
                    Style(name: "Soft", look: .corners(CornerLook(radius: 12))),
                ]
                let blue = doc.styles![0].id
                doc.update(shape) { $0.fill.named = blue }
            }
        }
        return bench
    }

    @Test func namedLooksGoOutAsTokens() throws {
        let bench = styled()
        let css = DesignTokens.css(bench.store.doc, named: "Shop")
        #expect(css.contains("--color-brand-blue: #3366FF;"))
        #expect(css.contains("--font-title-size: 28px;"))
        #expect(css.contains("--font-title-weight: 600;"))
        #expect(css.contains("--shadow-card: 0px 3px 6px rgba(0, 0, 0, 0.16);"))
        #expect(css.contains("--radius-soft: 12px;"))
        #expect(css.contains(".text-title"))
        let swift = DesignTokens.swiftUI(bench.store.doc, named: "Shop")
        #expect(swift.contains("static let brandBlue = Color(.sRGB, red: 0.2, green: 0.4, blue: 1, opacity: 1)"))
        #expect(swift.contains("static let title = TypeToken(font: Font.system(size: 28, weight: .semibold)"))
        #expect(swift.contains("static let soft: CGFloat = 12"))
        let json = try JSONSerialization.jsonObject(with: Data(DesignTokens.json(bench.store.doc).utf8)) as? [String: Any]
        let color = (json?["color"] as? [String: Any])?["brand-blue"] as? [String: Any]
        #expect(color?["$value"] as? String == "#3366FF")
        #expect(color?["$type"] as? String == "color")
    }

    @Test func darkLooksGoOutWhereTheDesignIsDark() {
        let bench = styled()
        bench.step { bench.store.edit("Dark") { $0.update(bench.b.id) { $0.dark = true } } }
        let css = DesignTokens.css(bench.store.doc, named: "Shop")
        #expect(css.contains("@media (prefers-color-scheme: dark)"))
        #expect(DesignTokens.swiftUI(bench.store.doc, named: "Shop").contains("Color(light:"))
    }

    @Test func tokenNamesAreFitForCode() {
        #expect(DesignTokens.kebab("Brand Blue / 500") == "brand-blue-500")
        #expect(DesignTokens.kebab("darkBlue") == "dark-blue")
        #expect(DesignTokens.camel("Brand Blue") == "brandBlue")
        #expect(DesignTokens.camel("2xl") == "_2xl")
        #expect(DesignTokens.camel("Default") == "`default`")
        #expect(DesignTokens.unique(["Blue", "blue", "Red"]) == ["Blue", "blue 2", "Red"])
    }
}

/// The prototype through the AI server, called as the server calls it.
@MainActor
struct PrototypeMCPTests {
    let bench = Bench()
    let tools = MCPTools()

    init() {
        MCPTools.opened(bench.store)
        bench.step { bench.store.add(CanvasTests.rect("Go", CGRect(x: 120, y: 120, width: 120, height: 40)), onto: bench.a.id) }
    }

    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool, images: Int) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true,
                content.filter { $0["type"] as? String == "image" }.count)
    }

    @Test func layersAreLinkedNotedAndMoved() async {
        let linked = await call("prototype", ["layers": ["Go"], "to": "B", "note": "after paying", "motion": "dissolve"])
        #expect(!linked.failed, "\(linked.text)")
        let go = bench.node("Go")!
        #expect(go.flow?.to == bench.b.id)
        #expect(go.flow?.note == "after paying")
        #expect(go.flow?.motion == .dissolve)
        #expect(linked.text.contains("after paying"))
        let back = await call("prototype", ["layers": ["Go"], "to": "back"])
        #expect(!back.failed)
        #expect(bench.node("Go")?.flow?.goesBack == true)
        let timed = await call("prototype", ["layers": ["A"], "to": "B", "after": 2])
        #expect(!timed.failed, "\(timed.text)")
        #expect(bench.a.flow?.after == 2)
        let wrong = await call("prototype", ["layers": ["Go"], "after": 2])
        #expect(wrong.failed)
        let start = await call("prototype", ["start": "B"])
        #expect(!start.failed)
        #expect(bench.b.starts == true)
        // Every change is one step of the undo history.
        #expect(bench.undo.canUndo)
    }

    @Test func thePrototypeIsHandedOverWhole() async {
        _ = await call("prototype", ["layers": ["Go"], "to": "B", "note": "after paying"])
        let got = await call("get_prototype", [:])
        #expect(!got.failed, "\(got.text)")
        #expect(got.images == 2)
        let json = (try? JSONSerialization.jsonObject(with: Data((got.text.components(separatedBy: "\nScreen ").first ?? "").utf8))) as? [String: Any]
        #expect((json?["screens"] as? [Any])?.count == 2)
        let flows = json?["flows"] as? [[String: Any]]
        #expect(flows?.count == 1)
        #expect(flows?.first?["note"] as? String == "after paying")
        #expect((flows?.first?["moves"] as? String)?.contains("push from the right") == true)
        #expect(json?["tokens"] != nil)
        #expect((json?["howToBuild"] as? String)?.contains("data-bezzle-id") == true)
        #expect(((json?["screens"] as? [[String: Any]])?.first?["adapts"] as? [String: Any])?["mode"] != nil)
    }

    @Test func tokensAreWrittenInEachFormat() async {
        let all = await call("design_tokens", [:])
        #expect(!all.failed)
        let css = await call("design_tokens", ["format": "css"])
        #expect(css.text.contains("no named styles"))
        let wrong = await call("design_tokens", ["format": "xml"])
        #expect(wrong.failed)
    }

    @Test func thePromptsBringEverythingWithThem() async throws {
        #expect(tools.promptList.count == 2)
        let built = try await tools.prompt("build_prototype", ["design": bench.store.name, "stack": "SwiftUI"])
        let object = try JSONSerialization.jsonObject(with: built.data) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        #expect(messages.count >= 3)
        #expect(((messages.first?["content"] as? [String: Any])?["text"] as? String)?.contains("SwiftUI") == true)
        #expect(messages.contains { ($0["content"] as? [String: Any])?["type"] as? String == "image" })
        // With no stack asked for, it is built to open with a double click: no server.
        let plain = try await tools.prompt("build_prototype", ["design": bench.store.name])
        #expect(plain.text.contains("no server"))
        let back = try await tools.prompt("write_back", ["design": bench.store.name])
        #expect(back.text.contains("data-bezzle-id"))
        await #expect(throws: MCPError.self) { try await tools.prompt("nothing", [:]) }
        // The server says it has prompts.
        let info = MCPServer.shared.initialize([:])
        #expect(info.text.contains("\"prompts\""))
    }
}
