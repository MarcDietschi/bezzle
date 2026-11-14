import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// Taking a picture's background away: the cutout made and kept beside the picture, drawn in its
/// place with its shadow cast by the subject alone, shared and exported with the design, undone,
/// and asked for by an assistant.
@MainActor
struct CutoutTests {
    /// A shaded ball on a soft backdrop, its shadow on the table: something that stands out.
    static func ball(_ w: Int = 900, _ h: Int = 700) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let backdrop = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1),
                                                                CGColor(srgbRed: 0.7, green: 0.74, blue: 0.78, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        let c = CGPoint(x: CGFloat(w) * 0.5, y: CGFloat(h) * 0.48), r = CGFloat(min(w, h)) * 0.26
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.9, y: c.y - r * 1.12, width: r * 1.8, height: r * 0.35))
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let shading = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.55, blue: 0.4, alpha: 1), CGColor(srgbRed: 0.75, green: 0.12, blue: 0.08, alpha: 1),
                                                               CGColor(srgbRed: 0.35, green: 0.03, blue: 0.02, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(shading, startCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.4), startRadius: 0, endCenter: c, endRadius: r * 1.05, options: [])
        return ctx.makeImage()!
    }

    /// A picture `w` × `h` of one colour, with a disc of another in its middle when given.
    static func plain(_ w: Int, _ h: Int, _ color: CGColor?, disc: (radius: CGFloat, color: CGColor)? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let color { ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        if let disc {
            ctx.setFillColor(disc.color)
            ctx.fillEllipse(in: CGRect(x: CGFloat(w) / 2 - disc.radius, y: CGFloat(h) / 2 - disc.radius, width: disc.radius * 2, height: disc.radius * 2))
        }
        return ctx.makeImage()!
    }

    private static func png(_ image: CGImage, to url: URL) throws {
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))
    }

    /// A design kept as a package, with `pictures` in its images, and a 200 × 150 layer "Photo" on
    /// artboard "A" filled with `fill`.
    private func design(_ fill: ImageFill, pictures: [String: CGImage], shadow: Shadow? = nil) throws -> (DocumentStore, UndoManager) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        var photo = CanvasTests.rect("Photo", CGRect(x: 50, y: 50, width: 200, height: 150))
        photo.fill = Fill(color: .shape, image: fill)
        if let shadow { photo.shadow = shadow }
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        board.children = [photo]
        var doc = BezzleDocument()
        doc.nodes = [board]
        try DesignFile.write(doc, to: url)
        for (name, image) in pictures {
            try Self.png(image, to: url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent(name))
        }
        let store = try DocumentStore(opening: url)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func photo(_ store: DocumentStore) -> Node? { store.doc.allNodes.first { $0.name == "Photo" } }

    /// Red, green, blue and alpha at x, y from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + (y * image.width + x) * 4
        return (0..<4).map { Int(p[$0]) }
    }

    private func read(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func aPictureIsCutOutBesideItselfAndUndoes() async throws {
        let (store, undo) = try design(ImageFill(asset: "photo.png", size: CGSize(width: 900, height: 700)), pictures: ["photo.png": Self.ball()])
        let images = try #require(store.assets.folder)
        let before = try Data(contentsOf: images.appendingPathComponent("photo.png"))
        let id = try #require(photo(store)?.id)

        let shown = try await store.cutOut([id])
        #expect(shown == [id])
        let image = try #require(photo(store)?.fill.image)
        let cutout = try #require(image.cutout)
        #expect(image.asset == "photo.png" && image.shown == cutout.asset && cutout.picks == nil)
        #expect(store.cuttingOut.isEmpty)
        // The picture itself is as it was; the cutout lies beside it, its subject alone.
        #expect(try Data(contentsOf: images.appendingPathComponent("photo.png")) == before)
        let cut = try read(images.appendingPathComponent(cutout.asset))
        #expect(cut.width == 900 && cut.height == 700)
        // The ball is 182 round 450, 364 from the top; its shadow on the table, under it, is background.
        #expect(pixel(cut, 450, 364)[3] == 255)
        #expect(pixel(cut, 12, 12)[3] == 0)
        #expect(pixel(cut, 450, 562)[3] < 20)

        undo.undo()
        #expect(photo(store)?.fill.image?.cutout == nil)
        undo.redo()
        #expect(photo(store)?.fill.image?.cutout == cutout)
        store.step({ store.restoreBackground() }, selecting: [id])
        #expect(photo(store)?.fill.image?.cutout == nil)
        // Cut out again, it is the same cutout, found made: none piles up from going back and forth.
        let modified = try images.appendingPathComponent(cutout.asset).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await store.cutOut([id])
        #expect(photo(store)?.fill.image?.cutout == cutout)
        #expect(try images.appendingPathComponent(cutout.asset).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).sorted() == ["photo-cutout.png", "photo.png"])
        // Picked, it is a cutout of its own, named the same wherever it is made.
        #expect(DocumentStore.cutoutName(of: "photo.png", picks: [CGPoint(x: 0.5, y: 0.5)]) == DocumentStore.cutoutName(of: "photo.png", picks: [CGPoint(x: 0.5, y: 0.5)]))
        #expect(DocumentStore.cutoutName(of: "photo.png", picks: [CGPoint(x: 0.5, y: 0.5)]) != DocumentStore.cutoutName(of: "photo.png", picks: [CGPoint(x: 0.4, y: 0.5)]))
    }

    @Test func nothingStandingOutLeavesThePictureAsItWas() async throws {
        let flat = Self.plain(300, 200, CGColor(gray: 0.6, alpha: 1))
        let (store, undo) = try design(ImageFill(asset: "flat.png", size: CGSize(width: 300, height: 200)), pictures: ["flat.png": flat])
        let id = try #require(photo(store)?.id)
        await #expect(throws: DocumentStore.CutoutTrouble.self) { try await store.cutOut([id]) }
        #expect(photo(store)?.fill.image?.cutout == nil)
        #expect(!undo.canUndo)
        // Picked where nothing stands out, a picture with a subject is left too.
        let (balled, _) = try design(ImageFill(asset: "photo.png", size: CGSize(width: 900, height: 700)), pictures: ["photo.png": Self.ball()])
        let ball = try #require(photo(balled)?.id)
        do {
            try await balled.cutOut([ball], picks: [CGPoint(x: 0.02, y: 0.02)])
            Issue.record("Cut out where nothing was picked")
        } catch let trouble as DocumentStore.CutoutTrouble {
            #expect("\(trouble)".contains("where the picture was picked"))
        }
        // Picked on the ball, it is cut out, and the pick is kept.
        try await balled.cutOut([ball], picks: [CGPoint(x: 0.5, y: 0.5)])
        #expect(photo(balled)?.fill.image?.cutout?.picks == [CGPoint(x: 0.5, y: 0.5)])
    }

    /// `ball()` as a camera with wider colours than sRGB's takes it: its numbers said to be
    /// `space`'s, and in its middle a square of a red, 200, 60 and 40 in `space`, that has other
    /// numbers in any other.
    static func wideBall(_ space: CGColorSpace) -> CGImage {
        let ball = Self.ball(), w = ball.width, h = ball.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(ball.copy(colorSpace: space)!, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [200.0 / 255, 60.0 / 255, 40.0 / 255, 1])!)
        // 40 round 450, 364 from the top, where the ball is.
        ctx.fill(CGRect(x: 430, y: h - 364 - 20, width: 40, height: 40))
        return ctx.makeImage()!
    }

    /// Red, green, blue and alpha at x, y from the top left, as the picture's own numbers: in
    /// its own colours, brought into no other.
    private func own(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let space = try #require(image.colorSpace)
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + (y * image.width + x) * 4
        return (0..<4).map { Int(p[$0]) }
    }

    @Test func aPhotoInWiderColoursIsCutOutInItsOwn() throws {
        // An iPhone's photos are in Display P3. Cut out in sRGB, their fullest colours would be
        // cut down to sRGB's, and the cutout would no longer say which colours its numbers are.
        // Bezzle for Windows is held to the same (Windows/README.md, Remove Background).
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, type) in [("photo.png", UTType.png), ("shot.jpg", .jpeg)] {
            let file = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(file, Self.wideBall(p3), [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
            #expect(CGImageDestinationFinalize(file))
            let cutout = try DocumentStore.cutout(of: name, in: folder, picks: nil, model: nil)
            let cut = try read(folder.appendingPathComponent(cutout.asset))
            // The cutout says the photo's colours, and is the photo's own profile.
            #expect(cut.colorSpace?.name == CGColorSpace.displayP3, "\(name)")
            #expect(cut.colorSpace?.copyICCData() == p3.copyICCData(), "\(name)")
            // Its numbers are the photo's own, brought into no other colours and back (a JPEG
            // keeps them to a level or two); in sRGB the same red has other numbers.
            let red = try own(cut, 450, 364)
            #expect(abs(red[0] - 200) <= 2 && abs(red[1] - 60) <= 2 && abs(red[2] - 40) <= 2 && red[3] == 255, "\(name): \(red)")
            #expect(pixel(cut, 450, 364)[0] > 210, "\(name)")
            #expect(try own(cut, 12, 12)[3] == 0, "\(name)")
        }
        // A photo in sRGB is cut out in sRGB, as ever.
        let file = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent("plain.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(file, Self.ball(), nil)
        #expect(CGImageDestinationFinalize(file))
        let plain = try read(folder.appendingPathComponent(try DocumentStore.cutout(of: "plain.png", in: folder, picks: nil, model: nil).asset))
        #expect(plain.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func theCutoutIsDrawnAndCastsItsShadowFromTheSubject() throws {
        // The picture is all blue; cut out, a green disc in the middle of where it lies.
        let blue = Self.plain(200, 150, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let disc = Self.plain(200, 150, nil, disc: (30, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))
        var fill = ImageFill(asset: "photo.png", size: CGSize(width: 200, height: 150))
        fill.cutout = Cutout(asset: "cut.png")
        let (store, _) = try design(fill, pictures: ["photo.png": blue, "cut.png": disc],
                                    shadow: Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 1), x: 0, y: 20, blur: 0))
        let board = store.doc.nodes[0]
        let image = try #require(Renderer.image(of: board, scale: 1, assets: store.assets))
        // The layer runs 50…250 across and 50…200 down, the disc round 150, 125.
        #expect(pixel(image, 150, 125) == [0, 255, 0, 255])
        #expect(pixel(image, 60, 60) == [255, 255, 255, 255])
        // The shadow falls under the disc, not under the layer's rectangle.
        #expect(pixel(image, 150, 125 + 30 + 10)[1] < 40)
        #expect(pixel(image, 60, 210) == [255, 255, 255, 255])

        // Not here yet, from someone sharing the design, the picture shows as it was.
        try FileManager.default.removeItem(at: store.assets.folder!.appendingPathComponent("cut.png"))
        let waiting = try #require(Renderer.image(of: board, scale: 1, assets: Assets(design: store.url)))
        #expect(pixel(waiting, 60, 60) == [0, 0, 255, 255])
    }

    @Test func aCutoutGoesWhereverThePictureGoes() throws {
        let disc = Self.plain(200, 150, nil, disc: (30, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))
        var fill = ImageFill(asset: "photo.png", size: CGSize(width: 200, height: 150))
        fill.cutout = Cutout(asset: "cut.png", picks: [CGPoint(x: 0.5, y: 0.4)])
        let (store, _) = try design(fill, pictures: ["photo.png": Self.plain(200, 150, CGColor(gray: 0.5, alpha: 1)), "cut.png": disc])
        let node = try #require(photo(store))
        // Shared with both, the picture to have back and the cutout to show.
        #expect(Collaboration.pictures(in: store.doc) == ["photo.png", "cut.png"])
        #expect(node.shows(picture: "cut.png") && node.shows(picture: "photo.png"))
        #expect(Library.pictureSizes(in: store.doc, thumbnail: CGSize(width: 200, height: 200), scale: 2).keys.contains("cut.png"))
        // Exported as cut out.
        let board = ExportItem(artboard: store.doc.nodes[0])
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: store.assets), assets: store.assets)
        let cut = try Data(contentsOf: store.assets.folder!.appendingPathComponent("cut.png")).base64EncodedString()
        #expect(svg.contains(cut))

        // Kept in the file, and an older file without one reads as it did.
        let again = try JSONDecoder().decode(ImageFill.self, from: JSONEncoder().encode(fill))
        #expect(again == fill)
        let old = try JSONDecoder().decode(ImageFill.self, from: Data(#"{"asset":"a.png","mode":"cover","size":[10,20],"offset":[0,0],"scale":1}"#.utf8))
        #expect(old.cutout == nil && old.shown == "a.png" && old.assets == ["a.png"])
    }

    /// Two balls side by side on a backdrop: two things that stand out.
    static func balls() -> CGImage {
        let w = 1200, h = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let backdrop = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1),
                                                                CGColor(srgbRed: 0.7, green: 0.74, blue: 0.78, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        for (x, colours) in [(300.0, [CGColor(srgbRed: 1, green: 0.55, blue: 0.4, alpha: 1), CGColor(srgbRed: 0.6, green: 0.08, blue: 0.05, alpha: 1)]),
                             (900.0, [CGColor(srgbRed: 0.5, green: 0.8, blue: 1, alpha: 1), CGColor(srgbRed: 0.05, green: 0.2, blue: 0.55, alpha: 1)])] {
            let c = CGPoint(x: x, y: 300), r: CGFloat = 170
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.clip()
            let shading = CGGradient(colorsSpace: space, colors: colours as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(shading, startCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.4), startRadius: 0, endCenter: c, endRadius: r * 1.05, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    @Test func outlinesAreTracedRoundWhatIsSolid() {
        // A disc 40 across in a plane 100 across, and a ring with a hole in it.
        let disc = CutoutMaker.Plane(100, 100), ring = CutoutMaker.Plane(100, 100)
        for y in 0..<100 {
            for x in 0..<100 {
                let d = hypot(Double(x) + 0.5 - 50, Double(y) + 0.5 - 50)
                disc.p[y * 100 + x] = d <= 20 ? 1 : 0
                ring.p[y * 100 + x] = d <= 30 && d >= 15 ? 1 : 0
            }
        }
        let round = CutoutMaker.path(CutoutMaker.trace(disc, side: 100))
        #expect(round.contains(CGPoint(x: 0.5, y: 0.5), using: .evenOdd))
        #expect(!round.contains(CGPoint(x: 0.75, y: 0.5), using: .evenOdd))
        #expect(abs(round.boundingBoxOfPath.width - 0.4) < 0.02)
        let holed = CutoutMaker.path(CutoutMaker.trace(ring, side: 100))
        #expect(!holed.contains(CGPoint(x: 0.5, y: 0.5), using: .evenOdd))
        #expect(holed.contains(CGPoint(x: 0.5, y: 0.27), using: .evenOdd))
        // Kept as path data and read back, it is the same outline.
        let read = PathData.cgPath(CutoutMaker.pathData(CutoutMaker.trace(disc, side: 100)))
        #expect(abs(read.boundingBoxOfPath.width - round.boundingBoxOfPath.width) < 0.001)
    }

    @Test func aCutoutIsOnlyWhereItsSubjectIsAndItsBorderGoesRoundIt() async throws {
        let (store, _) = try design(ImageFill(asset: "photo.png", size: CGSize(width: 900, height: 700)), pictures: ["photo.png": Self.ball()])
        let id = try #require(photo(store)?.id)
        try await store.cutOut([id])
        let node = try #require(photo(store))
        #expect(node.fill.image?.cutout?.outline?.isEmpty == false)
        // The layer is 200 × 150 at 50, 50; the ball covers it at 900 × 700, so it is 0.26 × 200 / 900 × 700 / 700… round its middle.
        let silhouette = try #require(node.silhouette)
        #expect(silhouette.contains(CGPoint(x: 100, y: 70), using: .evenOdd))
        #expect(!silhouette.contains(CGPoint(x: 4, y: 4), using: .evenOdd))
        // A click on what was background goes through; one on the ball takes the layer.
        #expect(Geometry.contains(node, CGPoint(x: 150, y: 120), tolerance: 1))
        #expect(!Geometry.contains(node, CGPoint(x: 55, y: 55), tolerance: 1))

        // A border goes round the ball, as a sticker's edge, not round the layer's frame.
        store.update([id], "Border") { $0.border = Border(on: true, color: RGBA(r: 1, g: 0, b: 0, a: 1), width: 4, position: .outside) }
        let image = try #require(Renderer.image(of: store.doc.nodes[0], scale: 1, assets: store.assets))
        #expect(pixel(image, 52, 52) == [255, 255, 255, 255])
        let edge = (0..<200).map { pixel(image, 50 + $0, 125) }.filter { $0[0] > 200 && $0[1] < 60 && $0[2] < 60 }
        #expect(edge.count >= 4)
        // Exported, the border is drawn round the outline too.
        let svg = SVGWriter.document(for: ExportItem(artboard: store.doc.nodes[0]), bounds: store.doc.nodes[0].frame, assets: store.assets)
        #expect(svg.contains("clip-rule=\"evenodd\"") || svg.contains("fill-rule=\"evenodd\""))
    }

    @Test func eachSubjectCanBePickedAlone() async throws {
        let subjects = try CutoutMaker.subjects(of: Self.balls())
        #expect(subjects.parts.count == 2)
        let left = try #require(subjects.parts.min { $0.point.x < $1.point.x })
        #expect(left.point.x < 0.5 && !left.person)
        #expect(subjects.part(at: CGPoint(x: 0.75, y: 0.5)) != subjects.part(at: CGPoint(x: 0.25, y: 0.5)))
        // Picked by its point, only it is left.
        let cut = try CutoutMaker.cut(Self.balls(), picks: [left.point])
        #expect(pixel(cut, 300, 300)[3] == 255)
        #expect(pixel(cut, 900, 300)[3] == 0)
        // Each step is told as it is taken, and what stands out as soon as it is found.
        var told: [CutoutMaker.Progress] = []
        _ = try CutoutMaker.cut(Self.balls()) { told.append($0) }
        #expect(told.map(\.step) == [.look, .matte, .finish])
        #expect(told.first?.found != nil)
    }

    /// As a learned matte might have `balls()`, at half its size: both balls, each with a soft rim
    /// beyond what Vision finds, and something else that stands out, high in the middle.
    struct Balls: CutoutMaker.Matting {
        func matte(of picture: CGImage) throws -> CutoutMaker.Plane {
            let m = CutoutMaker.Plane(600, 300)
            for y in 0..<300 {
                for x in 0..<600 {
                    let px = (Double(x) + 0.5) * 2, py = (Double(y) + 0.5) * 2
                    let ball = min(hypot(px - 300, py - 300), hypot(px - 900, py - 300))
                    let rim = min(max((190 - ball) / 20, 0), 1)
                    m.p[y * 600 + x] = Float(max(rim, hypot(px - 600, py - 60) < 40 ? 1 : 0))
                }
            }
            return m
        }
    }

    @Test func aLearnedMatteDrawsTheEdgesKeptToWhatWasPicked() throws {
        let matting = Balls()
        let left = try #require(CutoutMaker.subjects(of: Self.balls()).parts.min { $0.point.x < $1.point.x })
        var told: [CutoutPace.Step] = []
        let cut = try CutoutMaker.cut(Self.balls(), picks: [left.point], matting: matting) { told.append($0.step) }
        #expect(pixel(cut, 300, 300)[3] == 255)
        // The rim is see-through as the matte has it, fading out past the ball's outline.
        let rim = pixel(cut, 300, 300 - 178)[3]
        #expect(rim > 10 && rim < 245)
        // The other ball and the something else were not picked, nor are they near what was.
        #expect(pixel(cut, 900, 300)[3] == 0)
        #expect(pixel(cut, 600, 60)[3] == 0)
        #expect(told == [.look, .finish])
        // Unpicked, both balls are left, and still not what is away from them both.
        let both = try CutoutMaker.cut(Self.balls(), matting: matting)
        #expect(pixel(both, 300, 300)[3] == 255 && pixel(both, 900, 300)[3] == 255)
        #expect(pixel(both, 600, 60)[3] == 0)
    }

    @Test func theAppComesWithTheLearnedMatteAndItFindsTheSubject() async throws {
        // Made by Scripts/subject-matte/make.sh: without it, the app cuts pictures out less finely.
        let url = try #require(Bundle.main.url(forResource: "BiRefNet", withExtension: "mlmodelc"))
        // At its light size on the processor, the way every Mac can take.
        let model = try SubjectMatte(contentsOf: url, route: .light)
        let matte = try model.matte(of: Self.ball())
        #expect(matte.w == 1024 && matte.h == 1024)
        // The ball is round the middle, a little above it; the corners are backdrop.
        #expect(matte.p[500 * matte.w + 512] > 0.9)
        #expect(matte.p[20 * matte.w + 20] < 0.1)
        let cut = try CutoutMaker.cut(Self.ball(), matting: model)
        #expect(pixel(cut, 450, 364)[3] == 255 && pixel(cut, 12, 12)[3] == 0)
        // It has its fine size too: the two share their weights in the one model.
        #expect(try SubjectMatte(contentsOf: url, route: .fine).route.side == 2048)
    }

    @Test func cutoutsAreNamedForHowFinelyTheyWereMade() {
        #expect(DocumentStore.cutoutName(of: "photo.png", picks: nil) == "photo-cutout.png")
        #expect(DocumentStore.cutoutName(of: "photo.png", picks: nil, grade: .fine) == "photo-cutout-m\(SubjectMatte.version).png")
        #expect(DocumentStore.cutoutName(of: "photo.png", picks: nil, grade: .light) == "photo-cutout-m\(SubjectMatte.version)-1024.png")
        let picks = [CGPoint(x: 0.5, y: 0.5)]
        let names = SubjectMatte.Grade.allCases.map { DocumentStore.cutoutName(of: "photo.png", picks: picks, grade: $0) }
        #expect(Set(names).count == 3 && names[2].hasPrefix("photo-cutout-m\(SubjectMatte.version)-"))
    }

    /// A matting that cannot make its matte, as a model too much for the Mac.
    struct Failing: CutoutMaker.Matting {
        func matte(of picture: CGImage) throws -> CutoutMaker.Plane { throw CutoutMaker.Failure.unreadable }
    }

    @Test func aMatteThatCannotBeMadeLeavesThePictureCutOutThePlainWay() throws {
        var told: [CutoutPace.Step] = []
        let cut = try CutoutMaker.cut(Self.balls(), matting: Failing()) { told.append($0.step) }
        #expect(pixel(cut, 300, 300)[3] == 255 && pixel(cut, 900, 300)[3] == 255 && pixel(cut, 600, 60)[3] == 0)
        #expect(told == [.look, .matte, .finish])
    }

    @Test func aCutoutMadeMoreFinelyElsewhereIsTakenAsItIs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.png(Self.ball(), to: folder.appendingPathComponent("photo.png"))
        // Without the model, it is made the plain way and named so.
        let plain = try DocumentStore.cutout(of: "photo.png", in: folder, picks: nil, model: nil)
        #expect(plain.asset == "photo-cutout.png")
        // One made finely on another Mac, sharing the design, is there already: it is the one shown.
        let fine = DocumentStore.cutoutName(of: "photo.png", picks: nil, grade: .fine)
        try FileManager.default.copyItem(at: folder.appendingPathComponent(plain.asset), to: folder.appendingPathComponent(fine))
        #expect(try DocumentStore.cutout(of: "photo.png", in: folder, picks: nil, model: nil).asset == fine)
    }

    @Test func aCutGivenUpLeavesTheDesignAsItWas() async throws {
        let (store, undo) = try design(ImageFill(asset: "photo.png", size: CGSize(width: 900, height: 700)), pictures: ["photo.png": Self.ball()])
        let id = try #require(photo(store)?.id)
        store.selection = [id]
        let cutting = Task { try await store.cutOut([id]) }
        while store.cuttingOut[id] == nil { await Task.yield() }
        // While it is cut out it says how far it is, and never that it is done.
        #expect((store.cuttingOut[id]?.pace.done(at: CACurrentMediaTime()) ?? 1) < 1)
        store.giveUpRemovingBackground()
        #expect(store.cuttingOut.isEmpty)
        #expect(try await cutting.value.isEmpty)
        #expect(photo(store)?.fill.image?.cutout == nil && !undo.canUndo)
        // Asked for again, it is cut out as ever.
        #expect(try await store.cutOut([id]) == [id])
    }

    @Test func aClickOnAPicturePlacedIsToldAndADragIsNot() {
        var photo = CanvasTests.rect("Photo", CGRect(x: 50, y: 50, width: 100, height: 100))
        photo.fill.image = ImageFill(asset: "photo.png", mode: .cover, size: CGSize(width: 200, height: 100))
        let bench = Bench(extra: [photo])
        bench.store.selection = [bench.node("Photo")!.id]
        var clicks: [CGPoint] = []
        bench.canvas.pictureTool.clicked = { clicks.append($0) }
        bench.step { bench.store.editPicture() }
        bench.click(CGPoint(x: 200, y: 200))
        #expect(clicks.count == 1)
        bench.drag(CGPoint(x: 200, y: 200), CGPoint(x: 230, y: 200))
        #expect(clicks.count == 1)
    }

    @Test func anAssistantCanRemoveAndRestoreTheBackground() async throws {
        let (store, _) = try design(ImageFill(asset: "photo.png", size: CGSize(width: 900, height: 700)), pictures: ["photo.png": Self.ball()])
        MCPTools.opened(store)
        defer { MCPTools.closed(store) }
        let tools = MCPTools()
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let removed = await call("remove_background", ["layers": ["Photo"], "picks": [["x": 0.5, "y": 0.45]]])
        #expect(!removed.failed, "\(removed.text)")
        #expect(removed.text.contains("backgroundRemoved"))
        #expect(photo(store)?.fill.image?.cutout?.picks == [CGPoint(x: 0.5, y: 0.45)])
        let outside = await call("remove_background", ["layers": ["Photo"], "picks": [["x": 1.5, "y": 0.45]]])
        #expect(outside.failed)
        let restored = await call("remove_background", ["layers": ["Photo"], "restore": true])
        #expect(!restored.failed, "\(restored.text)")
        #expect(photo(store)?.fill.image?.cutout == nil)
        let none = await call("remove_background", ["layers": ["A"]])
        #expect(none.failed)
    }
}

private extension DocumentStore {
    /// Does `body` with `ids` selected, as one click would.
    func step(_ body: () -> Void, selecting ids: [UUID]) {
        selection = ids
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
    }
}
