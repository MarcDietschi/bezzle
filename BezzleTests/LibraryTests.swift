import Testing
import AppKit
@testable import Bezzle

/// Libraries: every design's components and styles can be taken into another, which keeps them as
/// its own and remembers where they came from; what changed there since is offered, and taken or
/// left. Nothing ever changes the other design.
@MainActor
struct LibraryTests {
    private static let blue = RGBA(r: 0.2, g: 0.4, b: 1)

    /// A design system: artboard A holding a component "Button", a rectangle "Shape" filled in the
    /// colour style "Primary" and the words "Button" over it. Written into the test library under
    /// a name of its own.
    private func system(_ name: String = "System \(UUID().uuidString.prefix(6))") -> (Bench, URL) {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: 40, y: 40, width: 120, height: 40))
        shape.fill.color = Self.blue
        var label = Node(kind: .text, name: "Label", frame: .zero)
        label.text = "Button"
        label.style?.size = 16
        label.refit()
        label.frame.origin = CGPoint(x: 60, y: 50)
        var button = Node(kind: .group, name: "Button", frame: .zero)
        button.children = [shape, label]
        let bench = Bench(extra: [button])
        bench.step { bench.store.edit("Fit") { $0.fitGroups() } }
        let shapeID = bench.node("Shape")!.id
        bench.store.selection = [shapeID]
        bench.step { _ = bench.store.nameLook(at: .fill(0), "Primary") }
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let url = Library.shared.folder.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        return (bench, url)
    }

    /// Writes a design where the home screen finds it, and reads the libraries again.
    private func publish(_ bench: Bench, to url: URL) async {
        try? DesignFile.write(bench.store.doc, to: url)
        Library.shared.touched(url)
        await LibraryShelf.shared.refreshed()
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Library.shared.refresh()
    }

    private func content(_ url: URL) -> LibraryContent { LibraryShelf.shared.content(url)! }

    private func shape(in copy: Node) -> Node? { copy.children.first { $0.name == "Shape" } }

    @Test func takingAComponentBringsItsStylesAndRemembersWhere() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let library = content(url)
        let button = library.ownMasters[0]
        #expect(library.isLibrary)
        #expect(library.ownStyles.map(\.name) == ["Primary"])
        // A design is no library to itself, however its link is written.
        #expect(!LibraryShelf.shared.libraries(except: url).contains { $0.name == library.name })
        #expect(!LibraryShelf.shared.libraries(except: URL(fileURLWithPath: url.path + "/")).contains { $0.name == library.name })

        let app = Bench()
        app.step { _ = app.store.place(.library(url, button.id)) }
        let doc = app.store.doc
        #expect(doc.masters.map(\.id) == [button.id])
        #expect(doc.masters[0].master?.library == LibraryLink(design: library.name, seen: library.prints[button.id]!))
        let primary = doc.styles?.first { $0.name == "Primary" }
        #expect(primary?.id == library.ownStyles[0].id)
        #expect(primary?.library?.design == library.name)
        let copy = doc.copies(of: button.id).first
        #expect(copy != nil)
        #expect(copy.flatMap(shape)?.fill.named == primary?.id)
        #expect(copy.flatMap(shape)?.fill.color == Self.blue)
        // Taken again, it is another copy of the same component.
        app.step { _ = app.store.place(.library(url, button.id)) }
        #expect(app.store.doc.masters.count == 1)
        #expect(app.store.doc.copies(of: button.id).count == 2)
        #expect(app.store.doc.libraryNews(in: [library]).isEmpty)
        // Nothing changed the other design.
        #expect(system.store.doc.masters[0].master?.library == nil)
    }

    @Test func aChangeThereIsOfferedAndTakenInEveryCopy() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let id = system.store.doc.masters[0].id
        let app = Bench()
        app.step { _ = app.store.place(.library(url, id)) }
        app.step { _ = app.store.place(.library(url, id)) }

        // The button turns red in the design system: through its colour, a change to Primary too.
        let red = RGBA(r: 0.9, g: 0.1, b: 0.1)
        let copy = system.store.doc.copies(of: id)[0]
        system.step { system.store.update([shape(in: copy)!.id], "Fill") { $0.fill.color = red } }
        await publish(system, to: url)
        let news = LibraryShelf.shared.news(for: app.store.doc, at: app.store.url)
        #expect(news.count == 1)
        #expect(news.first?.masters == [id])
        #expect(news.first?.styles.count == 1)
        // Until taken, nothing here changes.
        #expect(app.store.doc.copies(of: id).allSatisfy { shape(in: $0)?.fill.color == Self.blue })

        app.step { app.store.update(from: news[0]) }
        #expect(app.store.doc.copies(of: id).count == 2)
        #expect(app.store.doc.copies(of: id).allSatisfy { shape(in: $0)?.fill.color == red })
        #expect(app.store.doc.styles?.first { $0.name == "Primary" }?.look.paint?.color == red)
        #expect(LibraryShelf.shared.news(for: app.store.doc, at: app.store.url).isEmpty)
        app.undoLast()
        #expect(app.store.doc.copies(of: id).allSatisfy { shape(in: $0)?.fill.color == Self.blue })
        #expect(LibraryShelf.shared.news(for: app.store.doc, at: app.store.url).count == 1)
    }

    @Test func aChangeHereAloneIsNoNews() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let id = system.store.doc.masters[0].id
        let app = Bench()
        app.step { _ = app.store.place(.library(url, id)) }
        let copy = app.store.doc.copies(of: id)[0]
        app.step { app.store.update([shape(in: copy)!.id], "Corners") { $0.cornerRadius = 12 } }
        #expect(app.store.doc.masters[0] != content(url).master(id))
        #expect(LibraryShelf.shared.news(for: app.store.doc, at: app.store.url).isEmpty)
    }

    @Test func setAsideNewsComesBackOnlyWhenThereIsNewer() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let id = system.store.doc.masters[0].id
        let app = Bench()
        app.step { _ = app.store.place(.library(url, id)) }
        let copy = system.store.doc.copies(of: id)[0]
        system.step { system.store.update([shape(in: copy)!.id], "Corners") { $0.cornerRadius = 6 } }
        await publish(system, to: url)
        let news = LibraryShelf.shared.news(for: app.store.doc, at: app.store.url)
        #expect(news.count == 1)
        LibraryShelf.shared.setAside(news[0], for: app.store.url)
        #expect(LibraryShelf.shared.news(for: app.store.doc, at: app.store.url).isEmpty)
        system.step { system.store.update([shape(in: copy)!.id], "Corners") { $0.cornerRadius = 10 } }
        await publish(system, to: url)
        #expect(LibraryShelf.shared.news(for: app.store.doc, at: app.store.url).count == 1)
    }

    @Test func aStyleOfTheSameNameHereStandsIn() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let id = system.store.doc.masters[0].id
        // This design has a Primary of its own, green.
        let green = RGBA(r: 0.1, g: 0.7, b: 0.3)
        var dot = Node(kind: .rectangle, name: "Dot", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        dot.fill.color = green
        let app = Bench(extra: [dot])
        app.store.selection = [app.node("Dot")!.id]
        app.step { _ = app.store.nameLook(at: .fill(0), "Primary") }
        let mine = app.store.doc.styles![0]

        app.step { _ = app.store.place(.library(url, id)) }
        #expect(app.store.doc.styles?.count == 1)
        #expect(app.store.doc.styles?[0].library == nil)
        let copy = app.store.doc.copies(of: id)[0]
        #expect(shape(in: copy)?.fill.named == mine.id)
        #expect(shape(in: copy)?.fill.color == green)
        // And it stays so when the component is brought up to date.
        let theirs = system.store.doc.copies(of: id)[0]
        system.step { system.store.update([shape(in: theirs)!.id], "Corners") { $0.cornerRadius = 9 } }
        await publish(system, to: url)
        let news = LibraryShelf.shared.news(for: app.store.doc, at: app.store.url)
        #expect(news.first?.styles.isEmpty == true)
        app.step { app.store.update(from: news[0]) }
        let updated = app.store.doc.copies(of: id)[0]
        #expect(shape(in: updated)?.cornerRadius == 9)
        #expect(shape(in: updated)?.fill.named == mine.id)
        #expect(shape(in: updated)?.fill.color == green)
        #expect(app.store.doc.styles?[0].look.paint?.color == green)
    }

    @Test func componentsHeldInATakenOneComeAlong() async {
        let (system, url) = system()
        defer { clean(url) }
        let button = system.store.doc.masters[0].id
        // A card holding a copy of the button.
        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 120, y: 100, width: 200, height: 120))
        card.fill.color = .white
        system.step { system.store.add(card, onto: system.a.id) }
        let copy = system.store.doc.copies(of: button)[0]
        system.store.selection = [system.node("Card")!.id, copy.id]
        system.step { system.store.group() }
        system.step { system.store.makeComponent() }
        let cardID = system.store.doc.masters.first { $0.id != button }!.id
        await publish(system, to: url)

        let app = Bench()
        app.step { _ = app.store.place(.library(url, cardID)) }
        let ids = Set(app.store.doc.masters.map(\.id))
        #expect(ids == [button, cardID])
        #expect(app.store.doc.masters.allSatisfy { $0.master?.library?.design == content(url).name })
        #expect(app.store.doc.copies(of: button).count == 1)
    }

    @Test func pastingFromAnotherDesignRemembersIt() async {
        let (system, url) = system()
        defer { clean(url) }
        let id = system.store.doc.masters[0].id
        system.store.selection = [system.store.doc.copies(of: id)[0].id]
        system.store.copySelection()
        let app = Bench()
        app.step { app.store.paste() }
        #expect(app.store.doc.masters.first?.master?.library?.design == system.store.name)
        #expect(app.store.doc.masters.first?.master?.library?.seen == Fingerprint.of(system.store.doc.masters[0]))
        #expect(app.store.doc.styles?.first?.library?.design == system.store.name)
        // Pasted into the design it came from, nothing is taken from anywhere.
        system.step { system.store.paste() }
        #expect(system.store.doc.masters.allSatisfy { $0.master?.library == nil })
        #expect(system.store.doc.styles?.allSatisfy { $0.library == nil } == true)
    }

    @Test func aLibraryStyleIsGivenToTheSelectionOrOnlyBroughtIn() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let library = content(url)
        let primary = library.ownStyles[0]
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        box.fill.color = .white
        let app = Bench(extra: [box])
        app.store.selection = [app.node("Box")!.id]
        app.step { app.store.use(primary.id, of: library) }
        #expect(app.node("Box")?.fill.named == primary.id)
        #expect(app.node("Box")?.fill.color == Self.blue)
        #expect(app.store.doc.style(primary.id)?.library?.design == library.name)

        let other = Bench()
        other.store.selection = []
        other.step { other.store.use(primary.id, of: library) }
        #expect(other.store.doc.styles?.map(\.id) == [primary.id])
    }

    @Test func theAssistantListsTakesAndUpdates() async {
        let (system, url) = system()
        defer { clean(url) }
        await publish(system, to: url)
        let library = content(url)
        let id = library.ownMasters[0].id
        var box = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 300, y: 300, width: 50, height: 50))
        box.fill.color = .white
        let app = Bench(extra: [box])
        MCPTools.opened(app.store)
        defer { MCPTools.closed(app.store) }
        let tools = MCPTools()
        func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = app.store.name
            let result = await tools.call("libraries", arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }

        let listed = await call([:])
        #expect(!listed.failed, "\(listed.text)")
        #expect(listed.text.contains(library.name))
        let took = await call(["take": "Button", "from": library.name, "artboard": "A", "x": 10, "y": 20])
        #expect(!took.failed, "\(took.text)")
        let copy = app.store.doc.copies(of: id).first
        #expect(copy.flatMap { app.store.doc.absoluteFrame(of: $0.id) }?.origin == CGPoint(x: app.a.frame.minX + 10, y: app.a.frame.minY + 20))
        let styled = await call(["take": "Primary", "from": library.name, "layers": ["Box"]])
        #expect(!styled.failed, "\(styled.text)")
        #expect(app.node("Box")?.fill.color == Self.blue)

        let red = RGBA(r: 0.9, g: 0.1, b: 0.1)
        system.step { system.store.changeStyle(library.ownStyles[0].id, "Colour") { $0 = .colour(ColourLook(color: red)) } }
        await publish(system, to: url)
        #expect(json(await call([:]).text).contains { $0["changedThere"] as? Bool == true })
        let updated = await call(["update": true])
        #expect(!updated.failed, "\(updated.text)")
        #expect(app.node("Box")?.fill.color == red)
        #expect(app.store.doc.copies(of: id).allSatisfy { shape(in: $0)?.fill.color == red })
        #expect(await call(["update": true]).text.contains("Nothing"))
    }

    /// What `libraries` lists as taken.
    private func json(_ text: String) -> [[String: Any]] {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return object?["taken"] as? [[String: Any]] ?? []
    }

    @Test func theSourceIsFoundRenamedAndPreferredByName() {
        let master = { () -> Node in
            var m = Node(kind: .group, name: "Button", frame: .zero)
            m.master = Master()
            return m
        }()
        let old = Date(timeIntervalSince1970: 1000), new = Date(timeIntervalSince1970: 2000)
        let a = LibraryContent(url: URL(fileURLWithPath: "/x/A.bezzle"), name: "A", modified: old, masters: [master], styles: [])
        let b = LibraryContent(url: URL(fileURLWithPath: "/x/B.bezzle"), name: "B", modified: new, masters: [master], styles: [])
        var taken = master
        taken.master?.library = LibraryLink(design: "Gone", seen: "x")
        let c = LibraryContent(url: URL(fileURLWithPath: "/x/C.bezzle"), name: "C", modified: new, masters: [taken], styles: [])
        #expect(Libraries.source(master: master.id, link: LibraryLink(design: "A", seen: ""), in: [a, b, c])?.name == "A")
        // Renamed since: the one changed last of those that have it as their own.
        #expect(Libraries.source(master: master.id, link: LibraryLink(design: "Gone", seen: ""), in: [a, b, c])?.name == "B")
        // A design that took it from elsewhere is no source of it.
        #expect(Libraries.source(master: master.id, link: LibraryLink(design: "C", seen: ""), in: [c]) == nil)
    }

    @Test func fingerprintsStayTheSameThroughAFile() throws {
        let (system, _) = system()
        let master = system.store.doc.masters[0]
        let style = system.store.doc.styles![0]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let again = try JSONDecoder().decode(BezzleDocument.self, from: encoder.encode(system.store.doc))
        #expect(Fingerprint.of(again.masters[0]) == Fingerprint.of(master))
        #expect(Fingerprint.of(again.styles![0]) == Fingerprint.of(style))
        var linked = master
        linked.master?.library = LibraryLink(design: "Elsewhere", seen: "abc")
        #expect(Fingerprint.of(linked) == Fingerprint.of(master))
    }

    @Test func whereThingsCameFromIsShared() {
        let (system, _) = system()
        var doc = system.store.doc
        let link = LibraryLink(design: "Design System", seen: "0123")
        doc.changeStyle(doc.styles![0].id) { $0.library = link }
        var masters = doc.masters
        masters[0].master?.library = link
        doc.masters = masters
        var shared = SharedDesign()
        _ = shared.absorb(FlatDesign(doc), since: FlatDesign(BezzleDocument()), by: "a", at: 1)
        let back = shared.flatDesign().document()
        #expect(back.styles?.first?.library == link)
        #expect(back.masters.first?.master?.library == link)
        // A step undone or redone changes where it came from only where no one else changed it since.
        var later = back
        later.changeStyle(doc.styles![0].id) { $0.library = LibraryLink(design: "Design System", seen: "4567") }
        #expect(FlatDesign.apply(from: back, to: later, onto: back).styles?.first?.library?.seen == "4567")
        var theirs = back
        theirs.changeStyle(doc.styles![0].id) { $0.library = LibraryLink(design: "Design System", seen: "9999") }
        #expect(FlatDesign.apply(from: back, to: later, onto: theirs).styles?.first?.library?.seen == "9999")
    }
}
