import Testing
import Foundation
@testable import Bezzle

/// What a right click offers, on the canvas and on a row of the layers list, which ends with the
/// canvas's menu for the same selection.
@MainActor
struct CanvasMenuTests {
    private func titles(_ store: DocumentStore) -> [String] {
        CanvasMenus.entries(for: store).filter { $0.kind == .item }.map(\.title)
    }

    @Test func aHiddenLayerIsOfferedToBeShownAgain() {
        var hidden = CanvasTests.rect("Hidden", CGRect(x: 10, y: 10, width: 20, height: 20))
        hidden.hidden = true
        let bench = Bench(extra: [hidden, CanvasTests.rect("Shown", CGRect(x: 50, y: 10, width: 20, height: 20))])
        bench.store.selection = [bench.node("Hidden")!.id]
        #expect(titles(bench.store).contains("Show"))
        #expect(!titles(bench.store).contains("Hide"))
        bench.store.selection = [bench.node("Shown")!.id]
        #expect(titles(bench.store).contains("Hide"))
        #expect(!titles(bench.store).contains("Show"))
        // Hidden and shown together: hiding is what is offered, for the rest.
        bench.store.selection = [bench.node("Hidden")!.id, bench.node("Shown")!.id]
        #expect(titles(bench.store).contains("Hide"))
    }

    @Test func aPictureIsOfferedItsBackgroundTakenAwayOrBack() {
        var photo = CanvasTests.rect("Photo", CGRect(x: 10, y: 10, width: 120, height: 80))
        photo.fill.on = true
        photo.fill.image = ImageFill(asset: "x", mode: .cover, size: CGSize(width: 1600, height: 1000))
        var cut = photo
        cut.id = UUID()
        cut.name = "Cut"
        cut.fill.image?.cutout = Cutout(asset: "x-cut")
        let bench = Bench(extra: [photo, cut, CanvasTests.rect("Plain", CGRect(x: 200, y: 10, width: 20, height: 20))])

        bench.store.selection = [bench.node("Photo")!.id]
        #expect(titles(bench.store).contains("Remove Background"))
        #expect(!titles(bench.store).contains("Restore Background"))
        bench.store.selection = [bench.node("Cut")!.id]
        #expect(titles(bench.store).contains("Restore Background"))
        #expect(!titles(bench.store).contains("Remove Background"))
        bench.store.selection = [bench.node("Plain")!.id]
        #expect(!titles(bench.store).contains { $0.hasSuffix("Background") })
    }
}
