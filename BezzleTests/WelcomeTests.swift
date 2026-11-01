import Testing
import AppKit
@testable import Bezzle

/// The welcome tour: its sheets in order, what is there to read locked and what is there to try
/// free, a stack made as the app makes one, and the canvas opening on the first sheet.
@MainActor
struct WelcomeTests {
    @Test func sheetsRunDownFromTheWelcome() throws {
        let doc = Welcome.design()
        // Listed from the first down: the welcome sheet lies on top.
        let all = Array(doc.nodes.reversed())
        #expect(all.count == 29)
        #expect(all.allSatisfy { $0.isArtboard })
        #expect(all.first?.id == Welcome.coverID)
        // Two lessons are tried on an artboard of their own, listed after their sheet and lying
        // beside it, its foot level with the sheet's, its right edge where the other sheets end.
        let beside = Welcome.besideSheets(doc)
        #expect(beside.map(\.name) == ["Weather", "Flyer"])
        for other in beside {
            let sheet = all[try #require(all.firstIndex(of: other)) - 1]
            #expect(sheet.name.first?.isNumber == true)
            #expect(sheet.frame.maxY == other.frame.maxY && sheet.frame.maxX < other.frame.minX - 40)
            #expect(other.frame.minY >= sheet.frame.minY && other.frame.maxX == all[0].frame.maxX)
        }
        let sheets = all.filter { !beside.contains($0) }
        #expect(sheets.dropFirst().enumerated().allSatisfy { i, sheet in sheet.name.hasPrefix("\(i + 1). ") })
        #expect(sheets.count == 27)
        for (above, below) in zip(sheets, sheets.dropFirst()) {
            #expect(below.frame.minY > above.frame.maxY + 100)
            #expect(below.frame.minX == above.frame.minX)
        }
    }

    @Test func wordsAreLockedAndThingsToTryAreFree() {
        let doc = Welcome.design()
        for name in ["Sun", "Poster", "Tile", "Button", "Lemon", "Card", "Panel", "Block", "Photo frame", "Photo", "Arch", "App icon", "Sticker", "Badge", "Words to bend", "Label",
                     "Words to paint", "Painted words", "Ring", "Event card", "Tag", "Rule", "Join button"] {
            let found = doc.allNodes.filter { $0.name == name }
            #expect(!found.isEmpty, "no \(name)")
            #expect(found.contains { !$0.locked && !doc.ancestors(of: $0.id).contains { $0.locked } }, "\(name) is locked")
        }
        // Words straight on a sheet are there to be read, and stay put; but for the headline to type
        // over, the recipe to restyle, and the words to bend and paint.
        let beside = Welcome.besideSheets(doc)
        for sheet in doc.nodes where !beside.contains(sheet) {
            for layer in sheet.children where layer.kind == .text {
                let free = layer.text == "Your words here." || layer.spans != nil || ["Words to bend", "Label", "Words to paint", "Painted words"].contains(layer.name)
                #expect(layer.locked == !free, "\(layer.name)")
            }
        }
        // An artboard to try a lesson on is a design like any other, all of it free.
        for other in beside {
            #expect(!other.locked && other.children.allSatisfy { !$0.locked }, "\(other.name)")
        }
    }

    /// The lesson on notes: a ticket to talk about, and Bezzle's note round its title waiting
    /// unread, its card in the free margin beside the sheet, never over one.
    @Test func aNoteWaitsBesideTheTicket() throws {
        let doc = Welcome.design()
        let threads = doc.threads
        #expect(threads.count == 1)
        let note = try #require(threads.first?.start)
        #expect(note.by == Welcome.noteWriter)
        #expect(note.on == Welcome.ticketTitleID)
        #expect(!note.isDone)
        #expect(doc.unread(note.id, seen: nil, replica: CloudSync.replica))
        let title = try #require(doc.node(Welcome.ticketTitleID))
        #expect(title.kind == .text)
        let area = try #require(doc.area(of: note))
        let frame = try #require(doc.absoluteFrame(of: Welcome.ticketTitleID))
        #expect(area.contains(CGPoint(x: frame.midX, y: frame.midY)) && area.width > frame.width)
        let sheet = try #require(doc.sheet(of: note))
        #expect(sheet.name.hasSuffix(". Notes"))
        // The price to circle and the button to pin to are there, free.
        for name in ["Price", "Ticket button"] {
            let found = try #require(doc.allNodes.first { $0.name == name }, "no \(name)")
            #expect(!found.locked && !doc.ancestors(of: found.id).contains { $0.locked })
        }
        // At actual size, its card goes in the margin to the right of its sheet, clear of every sheet.
        let spot = try #require(doc.spot(of: note))
        let want = NotePlacement.Want(id: note.id, spot: spot, home: sheet.frame, sheet: sheet.id,
                                      height: NoteCardSize.shut(note, answered: false))
        let place = try #require(NotePlacement.place([want], around: doc.nodes.map(\.frame)).first)
        #expect(place.kind == .card)
        #expect(place.side == .right)
        #expect(doc.nodes.allSatisfy { !$0.frame.insetBy(dx: 1, dy: 1).intersects(place.frame) })
        // The cover counts it.
        #expect(doc.allNodes.contains { $0.text == String(localized: "Twenty-six lessons, about a minute each.") })
    }

    @Test func stackHasThreePostsEachWithItsOwnWords() throws {
        let doc = Welcome.design()
        let stack = try #require(doc.nodes.first { $0.isDeck })
        #expect(stack.posts.count == 3)
        let titles = stack.posts.compactMap { post in
            stack.layers(of: post).first { $0.kind == .text && $0.style?.family == "Charter" && $0.style?.size == 34 }?.text
        }
        #expect(titles == ["This sheet is a stack.", "Restyle one, restyle all.", "Each post has its own words."])
        // Made whole already: opening it has nothing to repair.
        var repaired = doc
        repaired.repairDecks()
        repaired.repairGrids()
        #expect(repaired == doc)
    }

    /// The lessons on what came later are tried on the real thing: a button of many looks, a recipe
    /// styled in places, a sheet with a layout grid, the tour's photo, an icon marked for export.
    @Test func newerLessonsHaveTheirThingsToTry() throws {
        let doc = Welcome.design()
        let button = try #require(doc.allNodes.first { $0.name == "Button" })
        #expect(button.fills.count == 2 && button.borders.count == 2 && button.shadows.count == 3)
        #expect(button.innerShadows.count == 1)

        let recipe = doc.allNodes.filter { $0.kind == .text && $0.hasStyledLetters }
        #expect(recipe.count == 3)
        let list = try #require(recipe.first { $0.runs.contains { $0.look.list == .bullet } })
        #expect(list.runs.contains { $0.look.strikethrough == true && $0.text.contains("4 eggs") })
        #expect(!list.text!.contains("~") && !recipe.contains { $0.text!.contains("*") })

        let lined = try #require(doc.nodes.first { $0.layout != nil })
        #expect(lined.layout?.columns?.count == 12)
        // The mat lies on the columns, from the sixth to the last.
        let columns = try #require(lined.layout?.columns).bands(along: lined.frame.width)
        #expect(lined.children.first?.frame.minX == columns[5].start && lined.children.first?.frame.maxX == columns[11].end)

        // For the photo editor, the mask, the letters it shows through and the flyer.
        let photos = doc.allNodes.filter { $0.fill.image != nil }
        #expect(photos.count == 4 && photos.allSatisfy { $0.fill.image?.asset == Welcome.photoAsset })
        #expect(photos.contains { $0.kind == .text })
        let ring = try #require(doc.allNodes.first { $0.name == "Ring" })
        #expect(ring.border.on && !ring.border.paints && !ring.fill.on)
        let icon = try #require(doc.allNodes.first { $0.name == "App icon" })
        #expect(icon.exports?.map(\.size) == [.scale(1), .scale(2), .scale(3)])
    }

    /// Each lesson on looks with names has colours of its own, so trying it names nothing on the
    /// other sheets: naming the button's colour finds just the tag and the rule beside it, and the
    /// weather screen shown dark names only its own colours.
    @Test func namedLooksStayWithTheirLesson() throws {
        var doc = Welcome.design()
        let button = try #require(doc.allNodes.first { $0.name == "Join button" })
        let look = try #require(StylePlace.fill(0).look(of: button))
        let alike = Set(doc.looksAlike(look, besides: [button.id]).map(\.layer))
        #expect(alike == Set(doc.allNodes.filter { ["Tag", "Rule"].contains($0.name) }.map(\.id)))

        let screen = try #require(doc.nodes.first { $0.name == "Weather" })
        #expect(screen.dark == nil && doc.styles == nil)
        let made = doc.show(screen.id, dark: true, name: { _ in "Colour" })
        #expect(made.count >= 6)
        #expect(doc.node(screen.id)?.showsDark == true)
        func named(_ n: Node) -> Bool { StylePlace.all(in: n).contains { $0.named(in: n) != nil } || n.children.contains(where: named) }
        for top in doc.nodes where top.id != screen.id {
            #expect(!named(top), "\(top.name)")
        }
        // The flyer lays its design out again for a new size, as every artboard does at first.
        let flyer = try #require(doc.nodes.first { $0.name == "Flyer" })
        #expect(flyer.pinsLayers == nil)
    }

    /// The lesson on versions comes with the poster's past: four versions over two days, one of
    /// them named, each a step further back, the first without moon or lanterns.
    @Test func thePosterComesWithItsPast() throws {
        let doc = Welcome.design()
        let now = Date()
        let past = Welcome.history(of: doc, now: now)
        #expect(past.count == 4)
        #expect(past.map(\.version.date) == past.map(\.version.date).sorted(by: >))
        #expect(past.compactMap(\.version.name) == [String(localized: "First draft")])
        #expect(past.allSatisfy { $0.version.date < now.addingTimeInterval(-3600) })
        let poster: [UUID] = [Welcome.Poster.sky, Welcome.Poster.moon, Welcome.Poster.title, Welcome.Poster.date] + Welcome.Poster.lanterns
        #expect(poster.allSatisfy { doc.node($0) != nil })
        var after = doc
        after.viewport = nil
        for (version, then) in past {
            #expect(then != after)
            let changed = VersionShelf.differences(then, after).changed
            #expect(changed.isSubset(of: Set(poster)), "\(changed.subtracting(poster).compactMap { then.node($0)?.name })")
            #expect(version.layers == then.layerCount)
            after = then
        }
        let first = try #require(past.last?.doc)
        #expect(first.node(Welcome.Poster.moon) == nil)
        #expect(Welcome.Poster.lanterns.allSatisfy { first.node($0) == nil })
        // Packed as versions are, each comes back whole.
        for (_, then) in past { #expect(VersionFiles.unpack(VersionFiles.pack(then)!) == then) }
    }

    /// The lessons on inspecting and on libraries have their things to try: a profile card with a
    /// button to measure, and two designs a button goes from one to the other between.
    @Test func inspectingAndLibrariesHaveTheirThingsToTry() throws {
        let doc = Welcome.design()
        let card = try #require(doc.allNodes.first { $0.kind == .group && $0.name == String(localized: "Profile card") })
        let follow = try #require(card.children.first { $0.name == String(localized: "Follow button") })
        #expect(follow.children.count == 2 && follow.children.allSatisfy { !$0.locked })
        let designs = doc.allNodes.filter { $0.kind == .group && [String(localized: "Design system"), String(localized: "New design")].contains($0.name) }
        #expect(designs.count == 2)
        #expect(designs.allSatisfy { $0.children.allSatisfy { !$0.locked } })
        // In the order they are taught: libraries after the styles, inspecting after export, versions after notes.
        let names = doc.nodes.reversed().map(\.name)
        func at(_ lesson: String) -> Int? { names.firstIndex { $0.hasSuffix(". " + lesson) } }
        let order = ["Light and dark", "Libraries", "Export sizes", "Inspect", "Notes", "Versions", "Share and export"].map(at)
        #expect(order.allSatisfy { $0 != nil })
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
    }

    /// Every layer is there once: a layer twice under one id is found in one place and changed
    /// in another.
    @Test func everyLayerIsThereOnce() {
        let ids = Welcome.design().allNodes.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func photoIsPaintedTheSameEachTime() throws {
        let one = try #require(WelcomePhoto.jpeg())
        #expect(one == WelcomePhoto.jpeg())
        let source = try #require(CGImageSourceCreateWithData(one as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGSize(width: image.width, height: image.height) == WelcomePhoto.size)
    }

    @Test func survivesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Welcome.bezzle")
        let doc = Welcome.design()
        try DesignFile.write(doc, to: url)
        #expect(try DesignFile.read(url) == doc)
    }

    @Test func opensOnTheWelcomeSheet() throws {
        let doc = Welcome.design()
        let store = DocumentStore(url: FileManager.default.temporaryDirectory, document: doc)
        store.canvasSize = CGSize(width: 860, height: 820)
        store.lookFirst()
        let cover = try #require(doc.node(Welcome.coverID)).frame
        let seen = store.viewport.toView(cover)
        #expect(seen.minX >= 0 && seen.maxX <= 860 && seen.minY >= 0 && seen.maxY <= 820)
        #expect(seen.width > 860 * 0.8)
        // Anything else still opens on everything.
        let other = DocumentStore(url: FileManager.default.temporaryDirectory, document: BezzleDocument())
        other.canvasSize = CGSize(width: 860, height: 820)
        other.lookFirst()
        #expect(other.viewport.zoom == 1)
    }
}

extension Welcome {
    /// The artboards lessons are tried on, each beside its sheet, from the first down: unlike the
    /// sheets, named without a number.
    static func besideSheets(_ doc: BezzleDocument) -> [Node] {
        doc.nodes.reversed().filter { $0.id != coverID && $0.name.first?.isNumber != true }
    }
}
