import Testing
import AppKit
@testable import Bezzle

/// Placing a picture inside the layer it fills: moving it, resizing it, and always covering.
@MainActor
struct PictureTests {
    /// A square layer on artboard A with a picture twice as wide as it is tall covering it: the
    /// layer is 100 × 100 at 150, 150 on the canvas, and the picture 200 × 100, from 100 to 300 across.
    private func bench(mode: ImageFill.Mode = .cover) -> Bench {
        var photo = CanvasTests.rect("Photo", CGRect(x: 50, y: 50, width: 100, height: 100))
        photo.fill.image = ImageFill(asset: "photo.png", mode: mode, size: CGSize(width: 200, height: 100))
        let bench = Bench(extra: [photo])
        bench.store.selection = [bench.node("Photo")!.id]
        return bench
    }

    private func image(_ bench: Bench) -> ImageFill { bench.node("Photo")!.fill.image! }

    @Test func placingKeepsThePictureWhereItWasDrawn() {
        let fill = ImageFill(asset: "p", mode: .cover, size: CGSize(width: 300, height: 200), offset: CGPoint(x: 0.1, y: -0.05), scale: 1.4)
        let size = CGSize(width: 120, height: 90)
        let rect = Renderer.imageRect(fill, in: size)
        let again = Renderer.imageRect(fill.placed(at: rect, in: size), in: size)
        #expect(abs(again.minX - rect.minX) < 0.001 && abs(again.minY - rect.minY) < 0.001 && abs(again.width - rect.width) < 0.001)
        // Covering moves it no further than it has to.
        let layer = CGSize(width: 100, height: 50)
        #expect(ImageFill.covering(CGRect(x: 20, y: -10, width: 200, height: 100), in: layer) == CGRect(x: 0, y: -10, width: 200, height: 100))
        #expect(ImageFill.covering(CGRect(x: -150, y: -60, width: 200, height: 100), in: layer) == CGRect(x: -100, y: -50, width: 200, height: 100))
        // The elastic gives less the further it is pulled, and never as far as its reach.
        let a = ImageFill.elastic(10, reach: 50), b = ImageFill.elastic(100, reach: 50), c = ImageFill.elastic(10_000, reach: 50)
        #expect(a > 0 && a < 10 && b > a && c > b && c < 50)
        #expect(ImageFill.elastic(-10, reach: 50) == -a)
    }

    @Test func doubleClickOrReturnPlacesAPicture() {
        let bench = bench()
        bench.click(CGPoint(x: 200, y: 200), clicks: 2)
        #expect(bench.store.editingPicture == bench.node("Photo")?.id)
        bench.key(36)
        #expect(bench.store.editingPicture == nil)
        bench.key(36)
        #expect(bench.store.editingPicture == bench.node("Photo")?.id)
        // A click off the picture ends placing, and goes on as any click.
        bench.click(CGPoint(x: 450, y: 350))
        #expect(bench.store.editingPicture == nil)
        #expect(bench.store.selection.isEmpty)
    }

    @Test func draggingMovesThePictureInsideItsFrame() {
        let bench = bench()
        bench.step { bench.store.editPicture() }
        bench.key(124)
        #expect(abs(image(bench).offset.x - 0.01) < 0.001)
        bench.drag(CGPoint(x: 200, y: 200), CGPoint(x: 229, y: 200))
        #expect(abs(image(bench).offset.x - 0.3) < 0.001)
        #expect(bench.node("Photo")?.frame == CGRect(x: 50, y: 50, width: 100, height: 100))
        // Pulled past covering, it gives, and once let go springs back to the edge.
        bench.drag(CGPoint(x: 200, y: 200), CGPoint(x: 400, y: 200))
        #expect(image(bench).offset.x > 0.5)
        bench.step { bench.canvas.pictureTool.finishSettling() }
        #expect(abs(image(bench).offset.x - 0.5) < 0.001)
        // A drag, spring and all, is one step to undo.
        bench.undoLast()
        #expect(abs(image(bench).offset.x - 0.3) < 0.001)
    }

    @Test func aCornerResizesThePictureButNeverBelowCovering() {
        let bench = bench()
        bench.step { bench.store.editPicture() }
        // The picture's bottom right corner, at 300, 250 on the canvas, pulled a quarter further out.
        bench.drag(CGPoint(x: 300, y: 250), CGPoint(x: 350, y: 275))
        #expect(abs(image(bench).scale - 1.25) < 0.001)
        #expect(abs(image(bench).offset.x - 0.25) < 0.001 && abs(image(bench).offset.y - 0.125) < 0.001)
        // Pushed in past covering, it springs back to just covering.
        bench.drag(CGPoint(x: 350, y: 275), CGPoint(x: 200, y: 200))
        bench.step { bench.canvas.pictureTool.finishSettling() }
        #expect(abs(image(bench).scale - 1) < 0.001)
        let rect = Renderer.imageRect(image(bench), in: CGSize(width: 100, height: 100))
        #expect(rect.minX <= 0 && rect.maxX >= 100 && rect.minY <= 0 && rect.maxY >= 100)
    }

    @Test func aPictureShownWholeCoversOnceMoved() {
        let bench = bench(mode: .fit)
        bench.step { bench.store.editPicture() }
        bench.drag(CGPoint(x: 200, y: 200), CGPoint(x: 210, y: 200))
        #expect(image(bench).mode == .cover)
        #expect(abs(image(bench).scale - 1) < 0.001 && abs(image(bench).offset.x - 0.1) < 0.001)
    }
}
