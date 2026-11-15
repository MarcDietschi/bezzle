import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// Opening a design: how long reading it takes, small and large, and the cover over its tab meanwhile.
/// One at a time: the tabs are the app's own.
@MainActor @Suite(.serialized)
struct OpeningTests {
    /// A design as large as a busy one gets: `boards` web pages, each with a header, a picture across
    /// its top, words, and a grid of cards with a picture each, from `pictures` photos of their own.
    static func largeDesign(at url: URL, boards: Int = 30, cards: Int = 30, pictures: Int = 60) throws {
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for p in 0..<pictures { try photo(seed: p).write(to: images.appendingPathComponent("photo-\(p).jpg")) }
        func picture(_ p: Int) -> ImageFill { ImageFill(asset: "photo-\(p % pictures).jpg", mode: .cover, size: CGSize(width: 1600, height: 1000)) }
        func text(_ name: String, _ words: String, _ frame: CGRect, size: CGFloat, face: String = "Regular") -> Node {
            var t = Node(kind: .text, name: name, frame: frame)
            t.text = words
            t.style = TextStyle(family: TextStyle.system, face: face, size: size, sizing: .autoHeight)
            t.fill.color = RGBA(hex: "1C1B19")!
            t.refit()
            return t
        }
        var doc = BezzleDocument()
        for b in 0..<boards {
            var board = Node(kind: .artboard, name: "Page \(b + 1)", frame: CGRect(x: CGFloat(b % 6) * 1600, y: CGFloat(b / 6) * 3400, width: 1440, height: 3200))
            board.fill.color = .white
            var header = Node(kind: .group, name: "Header", frame: CGRect(x: 0, y: 0, width: 1440, height: 80))
            var logo = Node(kind: .rectangle, name: "Logo", frame: CGRect(x: 40, y: 24, width: 120, height: 32))
            logo.fill.color = RGBA(hex: "3559C7")!
            logo.cornerRadius = 8
            header.children = [logo] + (0..<6).map { text("Link \($0)", "Section \($0 + 1)", CGRect(x: 760 + CGFloat($0) * 110, y: 30, width: 100, height: 0), size: 15) }
            var hero = Node(kind: .rectangle, name: "Hero", frame: CGRect(x: 0, y: 80, width: 1440, height: 640))
            hero.fill.image = picture(b)
            let headline = text("Headline", "A page of its own, number \(b + 1), with words that wrap over two lines", CGRect(x: 120, y: 780, width: 1000, height: 0), size: 56, face: "Bold")
            let lede = text("Lede", String(repeating: "Words set on the page to read as a paragraph does, wrapping from line to line. ", count: 6),
                            CGRect(x: 120, y: 960, width: 1100, height: 0), size: 19)
            var children = [header, hero, headline, lede]
            for c in 0..<cards {
                let x = 120 + CGFloat(c % 3) * 410, y = 1240 + CGFloat(c / 3) * 190
                var card = Node(kind: .group, name: "Card \(c + 1)", frame: CGRect(x: x, y: y, width: 380, height: 170))
                var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: x, y: y, width: 380, height: 170))
                back.fill.color = RGBA(hex: "F6F4EF")!
                back.cornerRadius = 14
                back.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.14), x: 0, y: 6, blur: 18)
                var thumb = Node(kind: .rectangle, name: "Picture", frame: CGRect(x: x + 14, y: y + 14, width: 142, height: 142))
                thumb.fill.image = picture(b * cards + c)
                thumb.cornerRadius = 10
                card.children = [back, thumb, text("Title", "Card \(c + 1)", CGRect(x: x + 172, y: y + 20, width: 190, height: 0), size: 20, face: "Semibold"),
                                 text("Body", "Two lines of words under the card's title, as cards have.", CGRect(x: x + 172, y: y + 56, width: 190, height: 0), size: 14)]
                children.append(card)
            }
            board.children = children
            doc.nodes.append(board)
        }
        try DesignFile.write(doc, to: url)
    }

    /// A photo-like picture, 1600 × 1000: soft colour fields and grain, which JPEG cannot squeeze to nothing.
    private static func photo(seed: Int) throws -> Data {
        let w = 1600, h = 1000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var state = UInt64(seed * 7919 + 17)
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1)
        }
        let colors = [CGColor(red: next(), green: next(), blue: next(), alpha: 1), CGColor(red: next(), green: next(), blue: next(), alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        for _ in 0..<40 {
            ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: next() * CGFloat(w), y: next() * CGFloat(h), width: 80 + next() * 500, height: 80 + next() * 400))
        }
        for _ in 0..<6000 {
            ctx.setFillColor(CGColor(gray: next(), alpha: 0.25))
            ctx.fill(CGRect(x: next() * CGFloat(w), y: next() * CGFloat(h), width: 3, height: 3))
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// The small design: one phone screen with a few layers.
    static func smallDesign(at url: URL) throws {
        var doc = BezzleDocument()
        var board = Node(kind: .artboard, name: "Home", frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        board.fill.color = RGBA(hex: "F7F4EE")!
        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 24, y: 196, width: 345, height: 180))
        card.fill.color = .white
        card.cornerRadius = 18
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 24, y: 72, width: 0, height: 0))
        title.text = "Good morning"
        title.style = TextStyle(family: TextStyle.system, face: "Bold", size: 32)
        title.refit()
        board.children = [card, title]
        doc.nodes = [board]
        try DesignFile.write(doc, to: url)
    }

    /// Reads a small and a large design and says how long each step of opening takes. With
    /// BEZZLE_OPENING_DESIGNS (TEST_RUNNER_BEZZLE_OPENING_DESIGNS to xcodebuild) set to a folder,
    /// leaves both there to open in a running copy, and the times beside them.
    @Test func readingALargeDesignTakesItsTime() throws {
        let kept = ProcessInfo.processInfo.environment["BEZZLE_OPENING_DESIGNS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let folder = kept ?? FileManager.default.temporaryDirectory.appendingPathComponent("opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if kept == nil { try? FileManager.default.removeItem(at: folder) } }
        let small = folder.appendingPathComponent("Small.bezzle"), large = folder.appendingPathComponent("Large.bezzle")
        try? FileManager.default.removeItem(at: small)
        try? FileManager.default.removeItem(at: large)
        try Self.smallDesign(at: small)
        try Self.largeDesign(at: large)
        var lines: [String] = []
        for url in [small, large] {
            let t0 = CACurrentMediaTime()
            let doc = try DesignFile.read(url)
            let t1 = CACurrentMediaTime()
            let store = try DocumentStore(opening: url, read: doc)
            let t2 = CACurrentMediaTime()
            #expect(store.doc.artboards.count == doc.artboards.count)
            lines.append(String(format: "%@: %d layers, read %.0f ms (away from the main thread), store made of it %.0f ms",
                                url.lastPathComponent, doc.allNodes.count, (t1 - t0) * 1000, (t2 - t1) * 1000))
        }
        #expect(try DesignFile.read(large).allNodes.count > 4000)
        if let kept { try lines.joined(separator: "\n").write(to: kept.appendingPathComponent("reading.txt"), atomically: true, encoding: .utf8) }
    }

    // MARK: The cover

    /// A design open within the grace comes straight through the paper: no mark that would come
    /// and go in a flash.
    @Test func aQuickOpeningShowsNoMark() {
        let cover = OpeningCover(began: 10, growing: false)
        #expect(cover.marks == 10 + OpeningCover.grace)
        let lift = cover.lift(readyAt: 10.1)
        #expect(lift.at == 10.1 && !lift.marked)
        #expect(cover.gone(readyAt: 10.1) == 10.1 + OpeningCover.quick)
    }

    /// Once the mark is pressed it finishes its gesture before the paper lifts; a design that takes
    /// longer than that is uncovered as soon as it is ready.
    @Test func aMarkOnceShownFinishesItsGesture() {
        let cover = OpeningCover(began: 10, growing: false)
        let soon = cover.lift(readyAt: cover.marks + 0.05)
        #expect(soon.marked && soon.at == cover.marks + OpeningCover.least)
        let late = cover.lift(readyAt: 20)
        #expect(late.marked && late.at == 20)
        #expect(cover.gone(readyAt: 20) == 20 + OpeningCover.lifting)
        // Ready the moment the mark is pressed: it is there, so it stays its while.
        #expect(cover.lift(readyAt: cover.marks).marked)
    }

    /// The window growing for the first design takes longer than the grace by itself: the mark is
    /// pressed as the paper grows, however quick the design.
    @Test func aGrowingWindowShowsTheMarkAtOnce() {
        let cover = OpeningCover(began: 10, growing: true)
        #expect(cover.marks == 10)
        let lift = cover.lift(readyAt: 10.05)
        #expect(lift.marked && lift.at == 10 + OpeningCover.least)
    }

    /// The springs land a hair past and settle; everything the gesture does is done before the mark
    /// may lift, and it breathes only after that, so a short wait never sees it begin to.
    @Test func theGestureIsCompleteBeforeItMayLift() throws {
        for spring in [OpeningMark.strike, OpeningMark.letter] {
            let course = spring.course()
            #expect(course.first?.v == 0 && course.last?.v == 1)
            let most = try #require(course.map(\.v).max())
            #expect(most > 1 && most < 1.12, "\(spring): \(most)")
            #expect(abs(spring.value(at: spring.settles) - 1) < 0.002)
            #expect(zip(course, course.dropFirst()).allSatisfy { $0.t < $1.t })
        }
        let least = OpeningCover.least
        #expect(OpeningMark.strikes.allSatisfy { $0 + OpeningMark.deepens < least })
        #expect(OpeningMark.inks + OpeningMark.inking < least)
        #expect(OpeningMark.sets(OpeningMark.word.count - 1) + OpeningMark.letterShows < least)
        // The last letter is struck within a point of its place by then.
        let last = OpeningMark.letter.value(at: least - OpeningMark.sets(OpeningMark.word.count - 1))
        #expect((1 - last) * OpeningMark.letterDrop * OpeningMark.wordSize < 1)
        #expect(OpeningMark.breathes > least)
        #expect(OpeningMark.flattens + OpeningMark.clears <= OpeningCover.lifting)
    }

    /// The mark's parts, laid on the window's paper as the cover lays them: each sheet's floor a
    /// shade darker than the paper and darker a step down, a lip of light under each, and the
    /// deepest inked with the pencil's blue, in either appearance.
    @Test(arguments: [false, true]) func theMarkIsPressedIntoThePaper(dark: Bool) throws {
        let pixels: CGFloat = 1
        let size = Int(OpeningMark.canvas.width * pixels)
        let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let paper = dark ? RGBA(hex: "1B1A18")! : RGBA(hex: "F0EDE7")!
        ctx.setFillColor(paper.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: pixels, y: -pixels)
        ctx.translateBy(x: -OpeningMark.canvas.minX, y: -OpeningMark.canvas.minY)
        for sheet in OpeningMark.sheets.indices {
            for part in OpeningMark.Part.allCases where OpeningMark.has(part, sheet) {
                OpeningMark.paint(part, of: sheet, dark: dark, pixels: pixels, in: ctx)
            }
        }
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        // A point of the mark, in its units with y down.
        func at(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double) {
            let i = Int(y - OpeningMark.canvas.minY) * size * 4 + Int(x - OpeningMark.canvas.minX) * 4
            return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
        }
        func light(_ c: (r: Double, g: Double, b: Double)) -> Double { (c.r + c.g + c.b) / 3 }
        let bare = light((paper.r, paper.g, paper.b))
        // Midway down each floor, clear of the walls' shadows from the top and the light at the foot.
        let outer = at(40, 300), middle = at(110, 300)
        #expect(light(outer) < bare - 0.005, "outer floor \(outer) on paper \(bare)")
        #expect(light(middle) < light(outer), "middle floor \(middle), outer \(outer)")
        let ink = at(306, 400)
        #expect(ink.b > ink.r + 0.25 && ink.b > ink.g + 0.15, "ink \(ink)")
        // Just under the outer sheet's foot, the paper's lip catches the light.
        let lip = at(250, 504)
        #expect(light(lip) > bare, "lip \(lip) on paper \(bare)")
        // Far from the mark, only paper.
        #expect(abs(light(at(-40, -40)) - bare) < 0.01)
    }

    /// The tiles say when a frame showed every artboard in sight from tiles of their own: what the
    /// cover waits for (`DocumentStore.whenDrawn`).
    @Test func tilesTellWhenTheDesignShowsInFull() throws {
        let tiles = BoardTiles()
        let board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let ctx = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let solid = try #require(ctx.makeImage())
        func frame(now: CFTimeInterval, deadline: CFTimeInterval) -> Bool {
            tiles.begin(scale: 1, now: now, artboards: [board.id])
            _ = tiles.draw(board, in: ctx, visible: board.frame, shadowPixels: 0, now: now, deadline: deadline, live: false,
                           make: { _, _, _ in solid })
            return tiles.drewInFull
        }
        // No time to make a tile: the paper shows where they go.
        #expect(!frame(now: 0, deadline: 0))
        #expect(frame(now: 1, deadline: .infinity))
        #expect(frame(now: 2, deadline: 0))
    }

    // MARK: Opening in a tab

    private func design() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Opening-\(UUID().uuidString).bezzle")
        try Self.smallDesign(at: url)
        return url
    }

    private func waiting(_ seconds: Double, until done: () -> Bool) async throws {
        let end = CACurrentMediaTime() + seconds
        while !done(), CACurrentMediaTime() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A design opens under the cover: its tab shows at once, the design comes a moment later,
    /// read away from the main thread, and once its canvas has drawn it the cover lifts.
    @Test func aDesignOpensUnderTheCover() async throws {
        let url = try design()
        defer { try? FileManager.default.removeItem(at: url) }
        Tabs.shared.open(url)
        let tab = try #require(Tabs.shared.designs.first { $0.shows(url) })
        defer { Tabs.shared.close(tab) }
        #expect(Tabs.shared.selected === tab)
        #expect(tab.opening != nil && tab.store == nil)
        // Asked for again while on its way, as by a second click, it opens once.
        Tabs.shared.open(url.appendingPathComponent("", isDirectory: true))
        #expect(Tabs.shared.designs.filter { $0.shows(url) }.count == 1)
        try await waiting(5) { tab.store != nil }
        let store = try #require(tab.store)
        #expect(store.doc.artboards.first?.name == "Home")
        // Not drawn yet: still covered.
        #expect(tab.opening != nil)
        let drawn = try #require(store.whenDrawn)
        store.whenDrawn = nil
        drawn()
        try await waiting(OpeningCover.least + OpeningCover.lifting + 1) { tab.opening == nil }
        #expect(tab.opening == nil)
    }

    /// A canvas that never draws, as one in a window out of sight, keeps the design covered only
    /// so long.
    @Test func theCoverLiftsAfterItsPatience() async throws {
        let url = try design()
        defer { try? FileManager.default.removeItem(at: url) }
        Tabs.shared.open(url)
        let tab = try #require(Tabs.shared.designs.first { $0.shows(url) })
        defer { Tabs.shared.close(tab) }
        try await waiting(5) { tab.store != nil }
        let opened = CACurrentMediaTime()
        try await waiting(OpeningCover.patience + OpeningCover.lifting + 2) { tab.opening == nil }
        #expect(tab.opening == nil)
        #expect(CACurrentMediaTime() - opened >= OpeningCover.patience)
    }

    /// Closed before its design had come, a tab lets it go: nothing is opened after.
    @Test func closingATabWhileItOpensLetsTheDesignGo() async throws {
        let url = try design()
        defer { try? FileManager.default.removeItem(at: url) }
        Tabs.shared.open(url)
        let tab = try #require(Tabs.shared.designs.first { $0.shows(url) })
        Tabs.shared.close(tab)
        #expect(tab.opening == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.store == nil)
        #expect(!Tabs.shared.designs.contains { $0 === tab })
        #expect(!MCPTools.stores.contains { $0.isAt(url) })
    }

    /// One who works on the design straight away, as the browser bringing a page in does, has it
    /// open at once, with no cover.
    @Test func openingAtOnceHasTheDesignStraightAway() throws {
        let url = try design()
        defer { try? FileManager.default.removeItem(at: url) }
        Tabs.shared.open(url, atOnce: true)
        let tab = try #require(Tabs.shared.designs.first { $0.shows(url) })
        defer { Tabs.shared.close(tab) }
        #expect(tab.store != nil && tab.opening == nil)
    }

    /// A design that cannot be read is uncovered to say so.
    @Test func aDesignThatCannotBeReadSaysSo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Broken-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not a design".utf8).write(to: url.appendingPathComponent(DesignFile.documentName))
        Tabs.shared.open(url)
        let tab = try #require(Tabs.shared.designs.first { $0.shows(url) })
        defer { Tabs.shared.close(tab) }
        try await waiting(3) { tab.opening == nil }
        #expect(tab.failure != nil && tab.store == nil && tab.opening == nil)
    }
}
