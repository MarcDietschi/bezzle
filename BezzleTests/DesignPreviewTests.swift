import Testing
import AppKit
@testable import Bezzle

/// The picture of a design kept in its package for the Finder's thumbnail: one artboard is the
/// whole sheet, cut short when it is a long page; several show their canvas on the paper; a
/// design with nothing on it has none. Keeping one never dates the design as changed.
@MainActor
struct DesignPreviewTests {
    private static let red = RGBA(r: 0.9, g: 0.1, b: 0.1)

    private func board(_ frame: CGRect, colour: RGBA = red) -> Node {
        var board = Node(kind: .artboard, name: "Board", frame: frame)
        board.fill.color = colour
        return board
    }

    private func design(_ nodes: [Node]) -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = nodes
        return doc
    }

    private func colour(of image: CGImage, at point: CGPoint) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB)
    }

    @Test func oneArtboardFillsTheSheet() throws {
        let image = try #require(DesignPreview.picture(of: design([board(CGRect(x: 0, y: 0, width: 390, height: 844))]), assets: nil))
        #expect(image.height == 1024)
        #expect(abs(Double(image.width) - 1024 * 390 / 844) <= 1)
        // Edge to edge: the artboard's own colour reaches the corners.
        let corner = try #require(colour(of: image, at: CGPoint(x: 2, y: 2)))
        #expect(corner.redComponent > 0.8 && corner.greenComponent < 0.2)
    }

    @Test func aLongPageShowsItsTop() throws {
        var page = board(CGRect(x: 0, y: 0, width: 1440, height: 9000), colour: RGBA(r: 1, g: 1, b: 1))
        var top = Node(kind: .rectangle, name: "Top", frame: CGRect(x: 0, y: 0, width: 1440, height: 200))
        top.fill.color = Self.red
        page.children = [top]
        let image = try #require(DesignPreview.picture(of: design([page]), assets: nil))
        #expect(abs(CGFloat(image.width) / CGFloat(image.height) - DesignPreview.narrowest) < 0.01)
        let first = try #require(colour(of: image, at: CGPoint(x: 10, y: 10)))
        #expect(first.redComponent > 0.8 && first.greenComponent < 0.2)
    }

    @Test func severalArtboardsShowTheirCanvasOnPaper() throws {
        let row = (0..<6).map { board(CGRect(x: CGFloat($0) * 500, y: 0, width: 390, height: 844)) }
        let image = try #require(DesignPreview.picture(of: design(row), assets: nil))
        #expect(max(image.width, image.height) == 1024)
        #expect(abs(CGFloat(image.width) / CGFloat(image.height) - DesignPreview.canvasWidest) < 0.01)
        // Paper round the artboards, warm and light.
        let paper = try #require(colour(of: image, at: CGPoint(x: 3, y: 3)))
        #expect(paper.redComponent > 0.9 && paper.blueComponent > 0.85 && paper.redComponent > paper.blueComponent)
    }

    @Test func anEmptyDesignHasNone() {
        #expect(DesignPreview.picture(of: BezzleDocument(), assets: nil) == nil)
    }

    @Test func catchingUpLeavesTheDesignsDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = design([board(CGRect(x: 0, y: 0, width: 400, height: 300))])
        try DesignFile.write(doc, to: url)
        var values = URLResourceValues()
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        values.contentModificationDate = then
        var dated = url
        try dated.setResourceValues(values)

        DesignPreview.write(doc, assets: nil, to: url, keepingDate: true)
        DocumentStore.finishSaving()
        let file = DesignPreview.file(of: url)
        let picture = try #require(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(picture.width == 1024 && picture.height == 768)
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(date == then)
        // The design reads as it did, and its picture is current.
        #expect(try DesignFile.read(url).nodes.count == 1)
        #expect(DesignPreview.isCurrent(for: url))

        // Made for a design just worked on, it dates the design now, so the Finder draws it again.
        DesignPreview.write(doc, assets: nil, to: url)
        DocumentStore.finishSaving()
        let now = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(Date().timeIntervalSince(now) < 60)

        // Saved again elsewhere, it no longer is current.
        try DesignFile.write(design([board(CGRect(x: 0, y: 0, width: 300, height: 300))]), to: url)
        var older = URLResourceValues()
        older.contentModificationDate = Date(timeIntervalSinceNow: -3600)
        var picturePath = file
        try picturePath.setResourceValues(older)
        #expect(!DesignPreview.isCurrent(for: url))

        // Emptied, it shows its icon again.
        DesignPreview.write(BezzleDocument(), assets: nil, to: url)
        DocumentStore.finishSaving()
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    /// A design kept as a single file has no room for one.
    @Test func aSingleFileDesignHasNone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString).bezzle")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = design([board(CGRect(x: 0, y: 0, width: 400, height: 300))])
        try JSONEncoder().encode(doc).write(to: url)
        DesignPreview.write(doc, assets: nil, to: url)
        DocumentStore.finishSaving()
        #expect(!DesignPreview.exists(for: url))
        #expect(!DesignFile.isPackage(url))
    }
}
