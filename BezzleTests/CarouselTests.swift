import Testing
import AppKit
@testable import Bezzle

/// Carousels: an artboard of slides side by side, kept whole slides as it is resized, with the
/// slides to snap to, and cut into a file per slide on export.
@MainActor
struct CarouselTests {
    /// The bench's artboard A, 400 × 300 at 100,100, made a carousel of two 200 × 300 slides.
    private func bench(extra: [Node] = []) -> Bench {
        let bench = Bench(extra: extra)
        bench.step { bench.store.edit("Make Carousel") { doc in doc.update(bench.a.id) { $0.slideSize = CGSize(width: 200, height: 300) } } }
        return bench
    }

    /// The colour at a pixel, counted from the top left, as hex.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> String {
        let ctx = Renderer.bitmap(CGSize(width: image.width, height: image.height))!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
        return String(format: "%02X%02X%02X", p[0], p[1], p[2])
    }

    /// "Launch", three slides of 100 × 80 at 100,50: a red bar across the first cut, a blue
    /// square on the last slide alone.
    private func launch() -> Node {
        var board = Node(kind: .artboard, name: "Launch", frame: CGRect(x: 100, y: 50, width: 300, height: 80))
        board.slideSize = CGSize(width: 100, height: 80)
        var cross = Node(kind: .rectangle, name: "Cross", frame: CGRect(x: 80, y: 20, width: 40, height: 40))
        cross.fill.color = RGBA(r: 1, g: 0, b: 0)
        var last = Node(kind: .rectangle, name: "Last", frame: CGRect(x: 230, y: 20, width: 40, height: 40))
        last.fill.color = RGBA(r: 0, g: 0, b: 1)
        board.children = [cross, last]
        return board
    }

    @Test func aCarouselIsAsManySlidesAsItIsWide() {
        let board = launch()
        #expect(board.isCarousel && board.slideCount == 3)
        #expect(board.slideRects.map(\.minX) == [0, 100, 200])
        #expect(board.carouselSize(count: 5) == CGSize(width: 500, height: 80))
        // No fewer than one, and no more than the platforms take.
        #expect(board.carouselSize(count: 0).width == 100)
        #expect(board.carouselSize(count: 99).width == 100 * CGFloat(Carousel.counts.upperBound))
        #expect(!Node(kind: .artboard, frame: .zero).isCarousel)
    }

    @Test func aSizeTypedInComesToWholeSlides() {
        let bench = bench()
        bench.store.selection = [bench.a.id]
        bench.step { bench.store.updateSelection("Resize") { $0.frame.size = CGSize(width: 530, height: 123) } }
        #expect(bench.a.frame == CGRect(x: 100, y: 100, width: 600, height: 300))
        #expect(bench.a.slideCount == 3)
    }

    @Test func draggingTheRightEdgeAddsSlides() {
        let bench = bench()
        bench.store.selection = [bench.a.id]
        // The right handle sits at 500,250; past half a slide further, a third slide is added.
        bench.drag(CGPoint(x: 500, y: 250), CGPoint(x: 620, y: 250))
        #expect(bench.a.frame == CGRect(x: 100, y: 100, width: 600, height: 300))
        bench.undoLast()
        #expect(bench.a.frame.width == 400)
    }

    @Test func draggingTheLeftEdgeTakesSlidesFromThereAndLeavesTheLayers() {
        let bench = bench(extra: [CanvasTests.rect("R", CGRect(x: 250, y: 20, width: 20, height: 20))])
        bench.store.selection = [bench.a.id]
        bench.drag(CGPoint(x: 100, y: 250), CGPoint(x: 0, y: 250))
        #expect(bench.a.frame == CGRect(x: -100, y: 100, width: 600, height: 300))
        // Back to one slide, from the left: the right edge stays, and so does R on the canvas.
        bench.drag(CGPoint(x: -100, y: 250), CGPoint(x: 330, y: 250))
        #expect(bench.a.frame == CGRect(x: 300, y: 100, width: 200, height: 300))
        #expect(bench.store.doc.absoluteFrame(of: bench.node("R")!.id)?.origin == CGPoint(x: 350, y: 120))
    }

    @Test func theTopAndBottomDoNotPullACarousel() {
        let bench = bench()
        bench.store.selection = [bench.a.id]
        bench.drag(CGPoint(x: 300, y: 400), CGPoint(x: 300, y: 500))
        #expect(bench.a.frame == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func aLayerSnapsToTheMiddleOfASlide() {
        let bench = bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 20, height: 20))])
        // The second slide's middle is at 300 in the artboard; R's middle starts at 20.
        bench.drag(CGPoint(x: 120, y: 120), CGPoint(x: 397, y: 120))
        #expect(bench.node("R")?.frame.midX == 300)
    }

    @Test func aCarouselSurvivesSavingAndOpening() throws {
        let bench = bench()
        bench.store.save()
        DocumentStore.finishSaving()
        let reopened = try DocumentStore(opening: bench.store.url)
        #expect(reopened.doc.nodes[0].slideSize == CGSize(width: 200, height: 300))
        try? FileManager.default.removeItem(at: bench.store.url)
    }

    @Test func eachSlideGoesOutAsAPictureOfItsOwn() throws {
        let board = launch()
        let slides = ExportItem.items(for: board)
        #expect(slides.map(\.name) == ["Launch 01", "Launch 02", "Launch 03"])
        let (second, rect) = try #require(slides[1].picture(scale: 1, opaque: true, assets: nil))
        #expect(second.width == 100 && second.height == 80)
        #expect(rect == CGRect(x: 200, y: 50, width: 100, height: 80))
        // The bar runs on from the first slide into the second, and stops where it does.
        #expect(pixel(second, 10, 40) == "FF0000")
        #expect(pixel(second, 30, 40) == "FFFFFF")
        let (first, _) = try #require(slides[0].picture(scale: 2, opaque: true, assets: nil))
        #expect(first.width == 200 && first.height == 160)
        #expect(pixel(first, 180, 80) == "FF0000")
        let (third, _) = try #require(slides[2].picture(scale: 1, opaque: true, assets: nil))
        #expect(pixel(third, 50, 40) == "0000FF")
        // A plain artboard goes out whole.
        #expect(ExportItem.items(for: Node(kind: .artboard, name: "Plain", frame: CGRect(x: 0, y: 0, width: 50, height: 50))).map(\.name) == ["Plain"])
    }

    @Test func slidesGoOutAFileEachOrAPageEach() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-carousel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let slides = ExportItem.items(for: launch())
        let pngs = Exporter.export(slides, format: .png, scale: 1, name: "Design", to: folder)
        #expect(pngs.map(\.lastPathComponent) == ["Launch 01.png", "Launch 02.png", "Launch 03.png"])
        let pdfs = Exporter.export(slides, format: .pdf, scale: 1, name: "Design", to: folder)
        #expect(pdfs.map(\.lastPathComponent) == ["Launch.pdf"])
        let pdf = try #require(CGPDFDocument(folder.appendingPathComponent("Launch.pdf") as CFURL))
        #expect(pdf.numberOfPages == 3)
        let page = try #require(pdf.page(at: 2)).getBoxRect(.mediaBox)
        #expect(page.size == CGSize(width: 100, height: 80))
    }

    @Test func aSlidesSVGShowsThatSlideAndWhatReachesIt() {
        let slides = ExportItem.items(for: launch())
        let first = SVGWriter.document(for: slides[0], bounds: slides[0].bounds(assets: nil), assets: nil)
        #expect(XMLParser(data: Data(first.utf8)).parse())
        #expect(first.contains("viewBox=\"0 0 100 80\"") && first.contains("translate(-100 -50)"))
        #expect(first.contains("id=\"Cross\"") && !first.contains("id=\"Last\""))
        let third = SVGWriter.document(for: slides[2], bounds: slides[2].bounds(assets: nil), assets: nil)
        #expect(third.contains("translate(-300 -50)") && third.contains("id=\"Last\"") && !third.contains("id=\"Cross\""))
    }
}
