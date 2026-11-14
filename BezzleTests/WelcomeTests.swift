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
        #expect(all.count == 32)
        #expect(all.allSatisfy { $0.isArtboard })
        #expect(all.first?.id == Welcome.coverID)
        // Three lessons are tried on an artboard of their own, listed after their sheet and lying
        // beside it, its foot level with the sheet's, its right edge where the other sheets end.
        let beside = Welcome.besideSheets(doc)
        #expect(beside.map(\.name) == ["Weather", "Flyer", "Postcard"])
        for other in beside {
            let sheet = all[try #require(all.firstIndex(of: other)) - 1]
            #expect(sheet.name.first?.isNumber == true)
            #expect(sheet.frame.maxY == other.frame.maxY && sheet.frame.maxX < other.frame.minX - 40)
            #expect(other.frame.minY >= sheet.frame.minY && other.frame.maxX == all[0].frame.maxX)
        }
        let sheets = all.filter { !beside.contains($0) }
        #expect(sheets.dropFirst().enumerated().allSatisfy { i, sheet in sheet.name.hasPrefix("\(i + 1). ") })
        #expect(sheets.count == 29)
        for (above, below) in zip(sheets, sheets.dropFirst()) {
            #expect(below.frame.minY > above.frame.maxY + 100)
            #expect(below.frame.minX == above.frame.minX)
        }
    }

    @Test func wordsAreLockedAndThingsToTryAreFree() {
        let doc = Welcome.design()
        for name in ["Sun", "Poster", "Tile", "Button", "Lemon", "Card", "Panel", "Block", "Photo frame", "Photo", "Arch", "App icon", "Sticker", "Badge", "Words to bend", "Label",
                     "Words to paint", "Painted words", "Ring", "Event card", "Tag", "Rule", "Join button", "Logo", "Small cloud", "Plane"] {
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
        #expect(doc.unread(note.id, seen: nil, replica: Sharing.replica))
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
        #expect(doc.allNodes.contains { $0.text == String(localized: "Twenty-eight lessons, about a minute each.") })
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

        // For the photo editor, the mask, the letters it shows through and the flyer; the one
        // other picture is the logo to trace.
        let pictures = doc.allNodes.filter { $0.fill.image != nil }
        let photos = pictures.filter { $0.fill.image?.asset == Welcome.photoAsset }
        #expect(photos.count == 4 && pictures.count == 5)
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
        // In the order they are taught: libraries after the styles, tracing a picture after the
        // other lessons on pictures, a film once the design is made, inspecting after export,
        // versions after notes.
        let names = doc.nodes.reversed().map(\.name)
        func at(_ lesson: String) -> Int? { names.firstIndex { $0.hasSuffix(". " + lesson) } }
        let order = ["Light and dark", "Libraries", "Remove background", "Photo editing", "Vectorize", "Masks", "Animate",
                     "Export sizes", "Inspect", "Notes", "Versions", "Share and export"].map(at)
        #expect(order.allSatisfy { $0 != nil })
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
    }

    // MARK: The film

    private func postcard(_ doc: BezzleDocument) throws -> Node {
        try #require(doc.nodes.first { $0.name == "Postcard" })
    }

    /// The lesson on Animate is tried on a film that is there already: a real one, with keys as
    /// Animate makes them, a camera that moves, an outline drawn on and layers that spring into
    /// place, three seconds long, and nothing in it for opening the design to repair.
    @Test func thePostcardIsAFilm() throws {
        let doc = Welcome.design()
        let card = try postcard(doc)
        #expect(card.hasFilm && card.hasCamera)
        #expect(card.filmLength == 3)
        // It is the tour's one film.
        #expect(doc.nodes.filter(\.hasFilm).map(\.id) == [card.id])
        #expect(AnimateStressTests.faults(in: doc) == [])
        var repaired = doc
        repaired.repairMotion()
        #expect(repaired == doc)

        // The camera draws back from the plane to the whole card.
        #expect(card.camera(at: 0).zoom == 1.6 && card.camera(at: 0).x < 0)
        #expect(card.camera(at: 1.7).isRest && card.camera(at: 3).isRest)
        let moving = card.children.filter { $0.motion != nil }
        #expect(Set(moving.map(\.name)) == ["Sun", "Cloud", "Trail", "Plane", "Air mail", "Off we go."])
        // A line drawn on, a flight through four places, and two that spring in.
        let trail = try #require(card.children.first { $0.name == "Trail" })
        #expect(trail.canReshape && trail[track: .draw]?.keys.map(\.t) == Welcome.flightTimes)
        let plane = try #require(card.children.first { $0.name == "Plane" })
        #expect(plane[track: .move]?.keys.map(\.t) == Welcome.flightTimes && plane[track: .turn]?.keys.count == 4)
        let springs = moving.filter { n in (n.motion ?? [:]).values.contains { $0.keys.contains { $0.ease?.kind == .spring } } }
        #expect(Set(springs.map(\.name)) == ["Sun", "Air mail"])
        // Nothing shows of what comes on later, and the trail is not drawn yet.
        for name in ["Sun", "Air mail", "Off we go."] {
            #expect(card.children.first { $0.name == name }?.pose(at: 0).fade == 0, "\(name)")
        }
        #expect(trail.pose(at: 0).drawTo == 0)
        // The design is the film's last picture: by its end everything is where the design has it.
        for layer in moving {
            #expect(layer.pose(at: 3).isRest, "\(layer.name): \(layer.pose(at: 3))")
            #expect(layer.reshaped(at: 3) == layer, "\(layer.name)")
        }
    }

    /// The plane keeps to the trail, and the trail is drawn as far as the plane has come: its end
    /// stays under the plane all the way.
    @Test func thePlaneFliesAlongItsTrail() throws {
        let card = try postcard(Welcome.design())
        let trail = try #require(card.children.first { $0.name == "Trail" })
        let plane = try #require(card.children.first { $0.name == "Plane" })
        let outline = try #require(trail.ownOutline)
        func end(drawnTo part: Double) -> CGPoint? {
            outline.trimmed(from: 0, to: part).subpaths.last?.anchors.last?.point.applying(trail.placement)
        }
        let way = (1...400).compactMap { end(drawnTo: Double($0) / 400) }
        #expect(way.count == 400)
        let home = CGPoint(x: plane.frame.midX, y: plane.frame.midY)
        var off = 0.0, apart = 0.0, before = -1.0
        for step in 1...64 {
            let t = 1.6 * Double(step) / 64
            let pose = plane.pose(at: t)
            let middle = CGPoint(x: home.x + pose.move.x, y: home.y + pose.move.y)
            off = max(off, way.map { hypot($0.x - middle.x, $0.y - middle.y) }.min() ?? .infinity)
            let drawn = trail.pose(at: t).drawTo
            #expect(drawn > before, "the trail goes back at \(t)")
            before = drawn
            let tip = try #require(end(drawnTo: drawn))
            apart = max(apart, hypot(tip.x - middle.x, tip.y - middle.y))
        }
        #expect(off < 1.5, "the plane leaves its trail by \(off)")
        // Its wings reach some twenty points from its middle.
        #expect(apart < 12, "the trail's end is \(apart) from the plane")
        // It heads the way it flies: level with its way at the start, and as designed at the end.
        #expect(plane.pose(at: 1.6).turn == 0 && plane.pose(at: 0).turn != 0)
    }

    /// The film in pictures: it begins close on the plane and ends as the artboard is drawn.
    @Test func thePostcardsFilmShowsTheDesignAtItsEnd() throws {
        let card = try postcard(Welcome.design())
        let size = FilmExport.size(of: card, settings: FilmExport.Settings(scale: 1, fps: 30))
        #expect(size == CGSize(width: 380, height: 476) || size == card.frame.size)
        func bytes(_ image: CGImage) throws -> [UInt8] {
            let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: try #require(ctx.data).assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * image.height))
        }
        func apart(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            var sum = 0
            for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
            return Double(sum) / Double(a.count)
        }
        let frames = try [0, 0.8, 1.6, 3].map { try bytes(#require(FilmExport.frame(of: card, at: $0, size: size, assets: nil))) }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(apart(a, b) > 1) }
        let drawn = try #require(Renderer.image(of: card, scale: size.width / card.frame.width, assets: nil))
        #expect(drawn.width == Int(size.width))
        if drawn.height == Int(size.height) { #expect(apart(frames[3], try bytes(drawn)) < 1) }
    }

    /// What the lesson asks for: the postcard's name clicked, Animate turns to its film; and the
    /// small cloud, moved at another moment, drifts there from where the design has it, which
    /// stays as it was.
    @Test func theSmallCloudIsThereToBePosed() throws {
        let doc = Welcome.design()
        let card = try postcard(doc)
        let cloud = try #require(card.children.first { $0.name == "Small cloud" })
        #expect(cloud.motion == nil && !cloud.locked)
        let store = DocumentStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle"), document: doc)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.selection = [card.id]
        store.show(.animate)
        #expect(store.filmBoard?.id == card.id && store.filmTime == 0)
        store.playFilm()
        #expect(store.film.playing)
        store.toggleFilm()
        #expect(!store.film.playing)

        store.seek(2)
        undo.beginUndoGrouping()
        store.pose(.move, of: [cloud.id]) { _ in [44, -10] }
        undo.endUndoGrouping()
        let keys = try #require(store.node(cloud.id)?[track: .move]?.keys)
        #expect(keys.map(\.t) == [0, 2] && keys.map(\.v) == [[0, 0], [44, -10]])
        #expect(keys.first?.given == true)
        #expect(store.node(cloud.id)?.frame == cloud.frame)
        #expect(AnimateStressTests.plain(store.doc) == AnimateStressTests.plain(doc))
        #expect(AnimateStressTests.faults(in: store.doc) == [])
        // The camera is posed the same way, once it is picked.
        store.pickCamera()
        #expect(store.film.camera)
        undo.undo()
        #expect(store.doc == doc || AnimateStressTests.plain(store.doc) == AnimateStressTests.plain(doc))
        #expect(store.node(cloud.id)?.motion == nil)
    }

    /// Turned to in a window no taller than a small laptop's, with the lesson read at actual size,
    /// the postcard comes to lie whole above the timeline, which shows a line for the camera and
    /// each of the six layers that move; and the lesson's words stay in sight beside it, since
    /// the view only moves up.
    @Test func thePostcardLiesClearOfTheTimelineBesideItsWords() throws {
        let doc = Welcome.design()
        let card = try postcard(doc)
        let all = Array(doc.nodes.reversed())
        let sheet = all[try #require(all.firstIndex(of: card)) - 1]
        let lines = FilmRow.rows(of: card, open: []).count
        #expect(lines == 7 && FilmTimeline.shown(of: lines) == 7)
        #expect(FilmTimeline.foot(lines: lines) == FilmTimeline.foot(lines: 4) + 3 * FilmTimeline.rowHeight)
        let canvas = CGSize(width: 1200, height: 800)
        func turned(from origin: CGPoint) -> DocumentStore {
            let store = DocumentStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle"), document: doc)
            store.canvasSize = canvas
            store.viewport = Viewport(origin: origin, zoom: 1)
            store.selection = [card.id]
            store.show(.animate)
            return store
        }
        // The sheet's foot, and the postcard's with it, just above the window's.
        var store = turned(from: CGPoint(x: -160, y: card.frame.maxY + 20 - canvas.height))
        var seen = store.viewport.toView(card.frame)
        #expect(seen.minX >= 0 && seen.maxX <= canvas.width && seen.minY >= 0, "\(seen)")
        #expect(seen.maxY <= canvas.height - FilmTimeline.foot(lines: lines), "\(seen)")
        #expect(store.viewport.zoom > 0.9)
        let words = store.viewport.toView(sheet.frame)
        #expect(words.minX >= 0 && words.maxX < seen.minX && words.maxY > 200, "\(words)")
        // Half out of sight at the window's side, it comes to the middle as any film's artboard does.
        store = turned(from: CGPoint(x: card.frame.midX - canvas.width, y: card.frame.minY - 40))
        seen = store.viewport.toView(card.frame)
        #expect(abs(seen.midX - canvas.width / 2) < 1 && seen.maxY <= canvas.height - FilmTimeline.foot(lines: lines), "\(seen)")
        // And where it lies whole above the timeline already, nothing moves.
        let rest = CGPoint(x: -160, y: card.frame.minY - 30)
        #expect(turned(from: rest).viewport == Viewport(origin: rest, zoom: 1))
    }

    // MARK: The picture to trace

    @Test func theLogoIsPaintedTheSameEachTime() throws {
        let one = try #require(WelcomeLogo.png())
        #expect(one == WelcomeLogo.png())
        let source = try #require(CGImageSourceCreateWithData(one as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGSize(width: image.width, height: image.height) == WelcomeLogo.size)
        let logo = try #require(Welcome.design().allNodes.first { $0.name == "Logo" })
        #expect(logo.fill.image?.asset == Welcome.logoAsset && logo.fill.image?.size == WelcomeLogo.size)
        #expect(logo.frame.width == logo.frame.height)
    }

    /// The tour as it is made brings its pictures along, and its logo is traced as the lesson
    /// says: where the picture lay there are shapes, the sun one of them, a layer of its own.
    @Test func theLogoBecomesShapes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        try Welcome.write(to: url)
        let images = url.appendingPathComponent(DesignFile.imagesFolder)
        for asset in [Welcome.photoAsset, Welcome.logoAsset] {
            #expect(FileManager.default.fileExists(atPath: images.appendingPathComponent(asset).path), "\(asset)")
        }
        let store = try DocumentStore(opening: url)
        let logo = try #require(store.doc.allNodes.first { $0.name == "Logo" })
        #expect(store.vectorizable(logo.id))
        #expect(try await store.vectorize([logo.id]) == [logo.id])
        let group = try #require(store.node(logo.id))
        #expect(group.kind == .group && group.name == "Logo" && group.frame == logo.frame)
        #expect(group.shadow == logo.shadow)
        // The paper, the ring, the disc, the water, the waves, the sails, the hull, six letters.
        #expect(group.children.count >= 14 && group.children.count <= 24, "\(group.children.count)")
        // The sun, yellow, where it is painted: as wide as it is, and as much of it as shows over
        // the water or more, since a shape can go on under the one that covers it.
        let k = logo.frame.width / 1000
        let suns = group.children.filter { n in
            let c = n.fill.color
            return n.fill.on && c.r > 0.9 && c.g > 0.65 && c.g < 0.82 && c.b < 0.35
        }
        let sun = try #require(suns.first)
        #expect(suns.count == 1)
        #expect(abs(sun.frame.midX - 666 * k) < 1.5 && abs(sun.frame.minY - 346 * k) < 1.5, "\(sun.frame)")
        #expect(abs(sun.frame.width - 184 * k) < 2 && sun.frame.height > 138 * k && sun.frame.height < 186 * k, "\(sun.frame)")
        #expect(!sun.locked)
    }

    // MARK: Words

    /// The words of the two lessons added last, as the design has them in English: each is there
    /// in German, French and Italian, and written the way Bezzle writes.
    @Test(arguments: ["de", "fr", "it"])
    func theNewLessonsAreInEveryLanguage(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        let doc = Welcome.design()
        let boards = doc.nodes.filter { $0.name.hasSuffix(". Vectorize") || $0.name.hasSuffix(". Animate") || $0.name == "Postcard" }
        #expect(boards.count == 3)
        var said: Set<String> = ["Twenty-eight lessons, about a minute each."]
        func gather(_ n: Node) {
            if n.isArtboard, let dot = n.name.firstIndex(of: "."), n.name.first?.isNumber == true {
                // A lesson's name is said with its number.
                said.insert("%lld" + n.name[dot...])
            } else if n.kind == .text, let text = n.text {
                // Words are named by how they begin: what they say is what is translated. The
                // line over a lesson's title counts it.
                said.insert(text.hasPrefix("Lesson ") && text.dropFirst(7).allSatisfy(\.isNumber) ? "Lesson %lld" : text)
            } else if !n.name.isEmpty {
                said.insert(n.name)
            }
            n.children.forEach(gather)
        }
        boards.forEach(gather)
        // What is the same everywhere: a step's number, a key's cap and the words on the air mail label.
        let plain: Set<String> = ["1", "2", "3", "⌃", "A", "PAR AVION"]
        var checked = 0
        for key in said.subtracting(plain).sorted() {
            guard let word = table[key], !word.isEmpty else {
                Issue.record("\(language) has no words for \(key)")
                continue
            }
            checked += 1
            #expect(!word.contains("—") && !word.contains(" – ") && !word.contains(" - ") && !word.contains("!"), "\(language): \(word)")
            #expect(word.contains("%lld") == key.contains("%lld"), "\(language): \(word)")
            // A key named in the words is the same key in every language.
            for glyph in ["⌃A", "×"] where key.contains(glyph) { #expect(word.contains(glyph), "\(language): \(word)") }
        }
        #expect(checked >= 23, "\(checked)")
    }

    /// With `TEST_RUNNER_WELCOME_PICTURES=<a folder>` before `xcodebuild test`, the two lessons
    /// and the film's moments are written there as pictures, to look at; with `-testLanguage de`
    /// in German.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WELCOME_PICTURES"] != nil))
    func picturesOfTheNewLessons() throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WELCOME_PICTURES"]), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        try Welcome.write(to: url)
        let doc = try DesignFile.read(url), assets = Assets(design: url)
        let language = Locale.preferredLanguages.first?.prefix(2) ?? "en"
        func write(_ image: CGImage, _ name: String) throws {
            let file = out.appendingPathComponent("\(name)-\(language).png")
            let made = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(made, image, nil)
            #expect(CGImageDestinationFinalize(made))
        }
        /// Artboards as one picture, where they lie on the canvas.
        func picture(of boards: [Node], scale: CGFloat) throws -> CGImage {
            let all = boards.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -30, dy: -30)
            let ctx = try #require(Renderer.bitmap(CGSize(width: all.width * scale, height: all.height * scale)))
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: all.width * scale, height: all.height * scale))
            for board in boards {
                let image = try #require(Renderer.image(of: board, scale: scale, assets: assets))
                ctx.draw(image, in: CGRect(x: (board.frame.minX - all.minX) * scale, y: (all.maxY - board.frame.maxY) * scale,
                                           width: board.frame.width * scale, height: board.frame.height * scale))
            }
            return try #require(ctx.makeImage())
        }
        let all = Array(doc.nodes.reversed())
        // The sheets by their place, whatever the language names them: the cover, then the lessons
        // in their order, each followed by the artboard beside it.
        let numbered = all.filter { $0.name.first?.isNumber == true }
        func lesson(_ number: Int) throws -> [Node] {
            let sheet = try #require(numbered.first { $0.name.hasPrefix("\(number). ") })
            let at = try #require(all.firstIndex(of: sheet))
            let next = at + 1 < all.count ? all[at + 1] : nil
            return [sheet] + (next.map { $0.name.first?.isNumber != true ? [$0] : [] } ?? [])
        }
        try write(picture(of: [all[0]], scale: 1.5), "cover")
        try write(picture(of: lesson(21), scale: 2), "vectorize")
        try write(picture(of: lesson(23), scale: 2), "animate")
        let card = try #require(lesson(23).last)
        // The film's moments, side by side.
        let moments: [Double] = [0, 0.3, 0.6, 0.95, 1.3, 1.6, 1.9, 2.3, 3]
        let size = CGSize(width: card.frame.width, height: card.frame.height)
        let strip = try #require(Renderer.bitmap(CGSize(width: (size.width + 12) * CGFloat(moments.count) + 12, height: size.height + 24)))
        strip.setFillColor(CGColor(gray: 0.16, alpha: 1))
        strip.fill(CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        for (i, t) in moments.enumerated() {
            let frame = try #require(FilmExport.frame(of: card, at: t, size: size, assets: assets))
            strip.draw(frame, in: CGRect(x: 12 + (size.width + 12) * CGFloat(i), y: 12, width: size.width, height: size.height))
        }
        try write(#require(strip.makeImage()), "film")
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
