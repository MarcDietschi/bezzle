import Testing
import AppKit
import ImageIO
@testable import Bezzle

/// Photoshop documents written by hand, as small as they can be: RGB, eight bits, and only what
/// each test needs.
enum TestPSD {
    struct Layer {
        var name: String
        var rect: (top: Int, left: Int, bottom: Int, right: Int)
        /// Red, green, blue and how solid, row after row; nil for a group's two records.
        var rgba: [UInt8]?
        var blend = "norm"
        var opacity: UInt8 = 255
        var clipping = false
        var hidden = false
        var blocks: [(String, Data)] = []
        /// Packs the channels with PackBits rather than keeping them raw.
        var packed = false
        /// A mask painted by hand: its rectangle, and how much shows of each of its pixels.
        var mask: (rect: (top: Int, left: Int, bottom: Int, right: Int), alpha: [UInt8])?
    }

    static func be(_ v: Int, _ width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) })
    }

    static func f64(_ v: Double) -> Data { be(Int(truncatingIfNeeded: Int64(bitPattern: v.bitPattern)), 8) }

    static func unicode(_ s: String) -> Data {
        let units = Array(s.utf16) + [0]
        return be(units.count, 4) + units.reduce(into: Data()) { $0 += be(Int($1), 2) }
    }

    static func id(_ s: String) -> Data { s.count == 4 ? be(0, 4) + Data(s.utf8) : be(s.utf8.count, 4) + Data(s.utf8) }

    /// A descriptor's value: its four letters, then what it is.
    enum Value {
        case double(Double)
        case text(String)
        case list([Double])
        case object(String, [(String, Value)])
        case choice(String, String)
        case bool(Bool)
        case unit(String, Double)

        var data: Data {
            switch self {
            case .double(let v): Data("doub".utf8) + f64(v)
            case .text(let s): Data("TEXT".utf8) + unicode(s)
            case .list(let l): Data("VlLs".utf8) + be(l.count, 4) + l.reduce(into: Data()) { $0 += Data("doub".utf8) + f64($1) }
            case .object(let cls, let items): Data("Objc".utf8) + descriptor(cls, items)
            case .choice(let set, let v): Data("enum".utf8) + id(set) + id(v)
            case .bool(let b): Data("bool".utf8) + Data([b ? 1 : 0])
            case .unit(let u, let v): Data("UntF".utf8) + Data(u.utf8) + f64(v)
            }
        }
    }

    static func descriptor(_ cls: String, _ items: [(String, Value)]) -> Data {
        var d = unicode("") + id(cls) + be(items.count, 4)
        for (key, value) in items { d += id(key) + value.data }
        return d
    }

    static func block(_ key: String, _ data: Data) -> Data {
        var d = Data("8BIM".utf8) + Data(key.utf8) + be(data.count, 4) + data
        if d.count % 2 != 0 { d.append(0) }
        return d
    }

    static func pascal(_ s: String, pad: Int) -> Data {
        var d = Data([UInt8(s.utf8.count)]) + Data(s.utf8)
        while d.count % pad != 0 { d.append(0) }
        return d
    }

    /// A group's record where it ends, below what it holds, and where it begins, above.
    static func group(_ name: String, _ children: [Layer], blend: String = "pass") -> [Layer] {
        var end = Layer(name: "</Layer group>", rect: (0, 0, 0, 0))
        end.blocks = [("lsct", be(3, 4))]
        var start = Layer(name: name, rect: (0, 0, 0, 0))
        start.blend = blend
        start.blocks = [("lsct", be(1, 4) + Data("8BIM".utf8) + Data(blend.utf8))]
        return [end] + children + [start]
    }

    static func channel(_ samples: [UInt8], width: Int, height: Int, packed: Bool) -> Data {
        guard packed else { return be(0, 2) + Data(samples) }
        var counts = Data(), rows = Data()
        for y in 0..<height {
            var row = Data()
            var x = 0
            while x < width {
                let n = min(128, width - x)
                row.append(UInt8(n - 1))
                row += Data(samples[(y * width + x)..<(y * width + x + n)])
                x += n
            }
            counts += be(row.count, 2)
            rows += row
        }
        return be(1, 2) + counts + rows
    }

    /// The file, its layers bottom first, with `global` blocks such as the files smart objects hold.
    static func file(width: Int, height: Int, layers: [Layer], global: [(String, Data)] = []) -> Data {
        var records = Data(), channels = Data()
        for l in layers {
            let w = l.rect.right - l.rect.left, h = l.rect.bottom - l.rect.top
            var planes: [(Int, Data)] = []
            if let rgba = l.rgba {
                for (k, id) in [(0, 0), (1, 1), (2, 2), (3, -1)] {
                    let samples = stride(from: k, to: rgba.count, by: 4).map { rgba[$0] }
                    planes.append((id, channel(samples, width: w, height: h, packed: l.packed)))
                }
            } else {
                for id in [-1, 0, 1, 2] { planes.append((id, be(0, 2))) }
            }
            if let m = l.mask { planes.append((-2, be(0, 2) + Data(m.alpha))) }
            records += be(l.rect.top, 4) + be(l.rect.left, 4) + be(l.rect.bottom, 4) + be(l.rect.right, 4)
            records += be(planes.count, 2)
            for (id, data) in planes { records += be(id & 0xFFFF, 2) + be(data.count, 4) }
            records += Data("8BIM".utf8) + Data(l.blend.utf8) + Data([l.opacity, l.clipping ? 1 : 0, l.hidden ? 2 : 0, 0])
            var maskData = Data()
            if let m = l.mask {
                maskData = be(m.rect.top, 4) + be(m.rect.left, 4) + be(m.rect.bottom, 4) + be(m.rect.right, 4) + Data([0, 0, 0, 0])
            }
            var extra = be(maskData.count, 4) + maskData + be(0, 4) + pascal(l.name, pad: 4)
            for (key, data) in l.blocks { extra += block(key, data) }
            records += be(extra.count, 4) + extra
            for (_, data) in planes { channels += data }
        }
        var info = be(layers.count, 2) + records + channels
        if info.count % 2 != 0 { info.append(0) }
        var section = be(info.count, 4) + info + be(0, 4)
        for (key, data) in global { section += block(key, data) }
        var out = Data("8BPS".utf8) + be(1, 2) + Data(count: 6) + be(3, 2) + be(height, 4) + be(width, 4) + be(8, 2) + be(3, 2)
        out += be(0, 4) + be(0, 4)
        out += be(section.count, 4) + section
        // The composite, raw and white.
        out += be(0, 2) + Data(repeating: 255, count: width * height * 3)
        return out
    }

    /// A smart object's placement: what it holds, where its corners go and how big it is.
    static func placed(id: String, corners: [Double], size: CGSize) -> Data {
        Data("soLD".utf8) + be(4, 4) + be(16, 4) + descriptor("null", [
            ("Idnt", .text(id)),
            ("Trnf", .list(corners)),
            ("nonAffineTransform", .list(corners)),
            ("warp", .object("warp", [("warpStyle", .choice("warpStyle", "warpNone"))])),
            ("Sz  ", .object("Pnt ", [("Wdth", .double(size.width)), ("Hght", .double(size.height))])),
        ])
    }

    /// The files smart objects hold, as the document keeps them.
    static func linked(_ files: [(id: String, name: String, data: Data)]) -> Data {
        var out = Data()
        for f in files {
            var item = Data("liFD".utf8) + be(2, 4) + Data([UInt8(f.id.utf8.count)]) + Data(f.id.utf8)
            item += unicode(f.name) + Data("png ".utf8) + Data("    ".utf8) + be(f.data.count, 8) + Data([0]) + f.data
            out += be(item.count, 8) + item
            while out.count % 4 != 0 { out.append(0) }
        }
        return out
    }

    static func solid(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        (0..<(w * h)).flatMap { _ in [c.0, c.1, c.2, c.3] }
    }

    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

struct PhotoshopImportTests {
    private func board(_ imported: Imported) throws -> Node {
        try #require(imported.document.nodes.first { $0.isArtboard })
    }

    @Test func layersComeAcrossWithTheirGroupsBlendsAndOpacity() throws {
        var paper = TestPSD.Layer(name: "Paper", rect: (0, 0, 30, 40), rgba: TestPSD.solid(40, 30, (250, 250, 245, 255)))
        paper.packed = true
        var shadow = TestPSD.Layer(name: "Shadow", rect: (5, 5, 15, 15), rgba: TestPSD.solid(10, 10, (0, 0, 0, 255)))
        shadow.blend = "mul "
        shadow.opacity = 128
        var glare = TestPSD.Layer(name: "Glare", rect: (2, 2, 6, 6), rgba: TestPSD.solid(4, 4, (255, 255, 255, 200)))
        glare.blend = "lddg"
        glare.hidden = true
        let data = TestPSD.file(width: 40, height: 30, layers: [paper] + TestPSD.group("Lights", [shadow, glare]))
        let imported = try PhotoshopImporter.read(data, named: "Mockup")
        let b = try board(imported)
        #expect(b.name == "Mockup")
        #expect(b.frame == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(b.children.map(\.name) == ["Paper", "Lights"])
        let lights = b.children[1]
        #expect(lights.isGroup)
        #expect(lights.children.map(\.name) == ["Shadow", "Glare"])
        let s = lights.children[0], g = lights.children[1]
        #expect(s.blend == .multiply)
        #expect(abs(s.opacity - 128.0 / 255) < 0.001)
        #expect(g.blend == .plusLighter)
        #expect(g.hidden)
        // Where each lies on the artboard, its group fitted round it.
        #expect(lights.frame.origin == CGPoint(x: 2, y: 2))
        #expect(s.frame == CGRect(x: 3, y: 3, width: 10, height: 10))
        // Each is a picture of its own pixels, kept with the design.
        let picture = try #require(b.children[0].fill.image)
        #expect(picture.size == CGSize(width: 40, height: 30))
        #expect(imported.held[picture.asset] != nil)
        #expect(imported.report.layers == 4)
    }

    @Test func aClippedLayerShowsOnlyWhereItsBaseDoes() throws {
        // The base is solid on its left half only.
        var base = [UInt8]()
        for _ in 0..<20 { for x in 0..<20 { base += [200, 0, 0, x < 10 ? 255 : 0] } }
        let screen = TestPSD.Layer(name: "Screen", rect: (0, 0, 20, 20), rgba: base)
        var glare = TestPSD.Layer(name: "Glare", rect: (0, 0, 20, 20), rgba: TestPSD.solid(20, 20, (0, 0, 255, 255)))
        glare.clipping = true
        let imported = try PhotoshopImporter.read(TestPSD.file(width: 20, height: 20, layers: [screen, glare]), named: "Clip")
        let b = try board(imported)
        #expect(b.children.map(\.name) == ["Screen", "Glare"])
        #expect(b.children[1].frame == CGRect(x: 0, y: 0, width: 10, height: 20))
    }

    @Test func aSmartObjectBecomesAPicturePinnedWhereItShows() throws {
        let quad: [Double] = [10, 10, 50, 14, 48, 40, 8, 36]
        let content = TestPSD.png(width: 100, height: 80)
        var screen = TestPSD.Layer(name: "Your Design Here", rect: (10, 8, 40, 50), rgba: TestPSD.solid(42, 30, (128, 128, 128, 255)))
        screen.blocks = [("SoLd", TestPSD.placed(id: "screen-1", corners: quad, size: CGSize(width: 100, height: 80)))]
        let data = TestPSD.file(width: 60, height: 50, layers: [screen],
                                global: [("lnk2", TestPSD.linked([("screen-1", "Screen.png", content)]))])
        let imported = try PhotoshopImporter.read(data, named: "Phone")
        let n = try #require(try board(imported).children.first)
        #expect(n.name == "Your Design Here")
        #expect(n.kind == .rectangle)
        let image = try #require(n.fill.image)
        #expect(image.size == CGSize(width: 100, height: 80))
        #expect(imported.held[image.asset] == content || imported.held[image.asset] != nil)
        // As wide for its height as what it holds, and its corners exactly where Photoshop put them.
        #expect(abs(n.frame.width / n.frame.height - 1.25) < 0.001)
        #expect(n.transform3D?.pinned == true)
        let shown = Perspective.corners(of: n)
        for (p, k) in zip(shown, stride(from: 0, to: 8, by: 2)) {
            #expect(abs(p.x - quad[k]) < 0.01 && abs(p.y - quad[k + 1]) < 0.01)
        }
    }

    @Test func aMaskedSmartObjectStaysAScreenCutOffAtTheMasksOutline() throws {
        let quad: [Double] = [10, 10, 50, 14, 48, 40, 8, 36]
        var screen = TestPSD.Layer(name: "Screen", rect: (10, 8, 40, 50), rgba: TestPSD.solid(42, 30, (128, 128, 128, 255)))
        screen.blocks = [("SoLd", TestPSD.placed(id: "s", corners: quad, size: CGSize(width: 100, height: 80)))]
        // Shown only inside 14,12 to 44,46: the screen's own rounded edge, say.
        var alpha = [UInt8](repeating: 0, count: 40 * 30)
        for y in 0..<30 { for x in 0..<40 where (4..<34).contains(x) && (4..<26).contains(y) { alpha[y * 40 + x] = 255 } }
        screen.mask = ((8, 10, 38, 50), alpha)
        let data = TestPSD.file(width: 60, height: 50, layers: [screen],
                                global: [("lnk2", TestPSD.linked([("s", "Screen.png", TestPSD.png(width: 100, height: 80))]))])
        let imported = try PhotoshopImporter.read(data, named: "Masked")
        let mask = try #require(try board(imported).children.first)
        #expect(mask.isMask)
        #expect(mask.frame.origin == CGPoint(x: 14, y: 12))
        #expect(abs(mask.frame.width - 30) < 0.6 && abs(mask.frame.height - 22) < 0.6)
        let inner = try #require(mask.children.last)
        #expect(inner.screen == true && inner.transform3D?.pinned == true)
    }

    @Test func aSmartObjectSquareToThePageIsNotPinned() throws {
        var logo = TestPSD.Layer(name: "Logo", rect: (4, 6, 24, 31), rgba: TestPSD.solid(25, 20, (0, 0, 0, 255)))
        logo.blocks = [("SoLd", TestPSD.placed(id: "logo", corners: [6, 4, 31, 4, 31, 24, 6, 24], size: CGSize(width: 50, height: 40)))]
        let data = TestPSD.file(width: 40, height: 30, layers: [logo],
                                global: [("lnk2", TestPSD.linked([("logo", "Logo.png", TestPSD.png(width: 50, height: 40))]))])
        let n = try #require(try board(try PhotoshopImporter.read(data, named: "Logo")).children.first)
        #expect(n.frame == CGRect(x: 6, y: 4, width: 25, height: 20))
        #expect(n.transform3D == nil)
    }

    @Test func pinnedCornersGoWhereTheyArePinnedAndBack() {
        var n = Node(kind: .rectangle, frame: CGRect(x: 100, y: 50, width: 200, height: 120))
        var t = Transform3D()
        t.corners = [CGPoint(x: 0.1, y: 0), CGPoint(x: 0.95, y: 0.1), CGPoint(x: 1, y: 0.9), CGPoint(x: 0, y: 1.05)]
        n.transform3D = t
        let p = try! #require(Perspective(n))
        let corners = [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50), CGPoint(x: 300, y: 170), CGPoint(x: 100, y: 170)]
        for (c, f) in zip(corners, t.corners!) {
            let s = p.shown(c)
            #expect(abs(s.x - (100 + f.x * 200)) < 1e-6 && abs(s.y - (50 + f.y * 120)) < 1e-6)
        }
        for q in [CGPoint(x: 150, y: 80), CGPoint(x: 260, y: 160), CGPoint(x: 200, y: 110)] {
            let back = try! #require(p.flat(p.shown(q)))
            #expect(abs(back.x - q.x) < 1e-6 && abs(back.y - q.y) < 1e-6)
        }
        // Turned in depth besides, it is turned after it is pinned.
        n.transform3D?.y = 20
        let turned = try! #require(Perspective(n))
        let back = try! #require(turned.flat(turned.shown(CGPoint(x: 120, y: 60))))
        #expect(abs(back.x - 120) < 1e-6 && abs(back.y - 60) < 1e-6)
        // Corners where they lie are no pin.
        n.transform3D = Transform3D(corners: Transform3D.square)
        #expect(Perspective(n) == nil)
    }

    @Test func aFillLayerFillsTheCanvasAndAGroupsColourOverlayTintsWhatItHolds() throws {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> TestPSD.Value {
            .object("RGBC", [("Rd  ", .double(r)), ("Grn ", .double(g)), ("Bl  ", .double(b))])
        }
        // A red mark in a group laid over with blue, and a white fill clipped to the group.
        var mark = TestPSD.Layer(name: "Mark", rect: (10, 10, 20, 30), rgba: TestPSD.solid(20, 10, (255, 0, 0, 255)))
        mark.packed = true
        var group = TestPSD.group("Logo", [mark])
        let style = TestPSD.be(0, 4) + TestPSD.be(16, 4) + TestPSD.descriptor("null", [
            ("masterFXSwitch", .bool(true)),
            ("SoFi", .object("SoFi", [("enab", .bool(true)), ("Clr ", rgb(0, 0, 255)), ("Opct", .unit("#Prc", 100))])),
        ])
        group[group.count - 1].blocks.append(("lfx2", style))
        var white = TestPSD.Layer(name: "White", rect: (0, 0, 0, 0))
        white.rgba = nil
        white.clipping = true
        white.blocks = [("SoCo", TestPSD.be(16, 4) + TestPSD.descriptor("null", [("Clr ", rgb(255, 255, 255))]))]
        var paper = TestPSD.Layer(name: "Paper", rect: (0, 0, 0, 0))
        paper.blocks = [("SoCo", TestPSD.be(16, 4) + TestPSD.descriptor("null", [("Clr ", rgb(10, 20, 30))]))]
        let imported = try PhotoshopImporter.read(TestPSD.file(width: 40, height: 30, layers: [paper] + group + [white]), named: "Logo")
        let b = try board(imported)
        #expect(b.children.map(\.name) == ["Paper", "Logo", "White"])
        // A colour all over, as a shape of that colour.
        let p = b.children[0]
        #expect(p.kind == .rectangle && p.fill.image == nil && p.frame == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(abs(p.fill.color.r - 10.0 / 255) < 0.001)
        // Blue where the mark is, drawn into its picture.
        let logo = b.children[1].children[0]
        let asset = try #require(logo.fill.image).asset
        let tinted = try #require(imported.held[asset]).picture(at: CGPoint(x: 5, y: 5))
        #expect(tinted.b > 0.95 && tinted.r < 0.05)
        // White only over the mark.
        #expect(b.children[2].frame == CGRect(x: 10, y: 10, width: 20, height: 10))
    }

    @Test func notAPhotoshopFile() {
        #expect(throws: (any Error).self) { try PhotoshopImporter.read(Data("this is not a picture at all".utf8), named: "x") }
    }

    /// Imports every document in a folder and draws each beside Photoshop's own picture of it, with
    /// where they differ. Run with TEST_RUNNER_BEZZLE_PSD_SAMPLES=folder:output-folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEZZLE_PSD_SAMPLES"] != nil))
    func samples() throws {
        let spec = ProcessInfo.processInfo.environment["BEZZLE_PSD_SAMPLES"]!.split(separator: ":").map(String.init)
        let source = URL(fileURLWithPath: spec[0]), out = URL(fileURLWithPath: spec[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let library = out.appendingPathComponent("designs", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var summary: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { PhotoshopImporter.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let progress = out.appendingPathComponent("progress.txt")
        FileManager.default.createFile(atPath: progress.path, contents: nil)
        let log = try FileHandle(forWritingTo: progress)
        func say(_ s: String) {
            log.write(Data((s + "\n").utf8))
            try? log.synchronize()
        }
        for url in files {
            say("reading \(url.lastPathComponent)")
            let started = Date()
            do {
                let imported = try PhotoshopImporter.read(url)
                let read = Date().timeIntervalSince(started)
                let name = url.deletingPathExtension().lastPathComponent
                say("writing")
                let (design, report) = try Importer.write(imported, named: name, into: library)
                say("drawing")
                let doc = try DesignFile.read(design)
                let assets = Assets(design: design)
                guard let board = doc.artboards.first else { summary.append("\(name): no artboard"); continue }
                let scale = min(1, 1000 / board.frame.width)
                let ours = Renderer.image(of: board, scale: scale, assets: assets)
                let file = try PhotoshopFile(url: url)
                var theirs: CGImage?
                if let c = try file.composite() {
                    let provider = CGDataProvider(data: Data(c.pixels) as CFData)!
                    theirs = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                                     space: file.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                }
                let size = CGSize(width: (board.frame.width * scale).rounded(), height: (board.frame.height * scale).rounded())
                var difference = -1.0
                if let ours, let theirs, let a = Self.resized(theirs, to: size), let b = Self.resized(ours, to: size) {
                    let (d, picture) = Self.compare(a, b)
                    difference = d
                    Self.write(Self.sideBySide([a, b, picture]), to: out.appendingPathComponent("\(name).png"))
                } else if let ours {
                    Self.write(ours, to: out.appendingPathComponent("\(name).png"))
                }
                let screens = doc.allNodes.filter { $0.transform3D?.pinned == true }.count
                summary.append(String(format: "%@: %.1f%% apart, %d layers, %d pinned, read %.1fs, all %.1fs. %@", name, difference * 100,
                                      report.layers, screens, read, Date().timeIntervalSince(started), report.lines.joined(separator: "; ")))
            } catch {
                summary.append("\(url.lastPathComponent): \(error)")
            }
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func compare(_ a: CGImage, _ b: CGImage) -> (Double, CGImage) {
        let size = CGSize(width: a.width, height: a.height)
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: a.width * a.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(origin: .zero, size: size))
            }
            return bytes
        }
        let pa = pixels(a), pb = pixels(b)
        var out = [UInt8](repeating: 255, count: pa.count)
        var total = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = (abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))) / 3
            total += d
            let faint = UInt8(235 + Int(pa[i]) * 20 / 255)
            let strength = min(255, d * 4)
            out[i] = UInt8(max(0, Int(faint) - strength / 3))
            out[i + 1] = UInt8(max(0, Int(faint) - strength))
            out[i + 2] = UInt8(max(0, Int(faint) - strength))
        }
        let picture = out.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return (Double(total) / Double(pa.count / 4) / 255, picture ?? a)
    }

    private static func sideBySide(_ images: [CGImage]) -> CGImage? {
        let gap = 16, width = images.map(\.width).reduce(0, +) + gap * (images.count - 1), height = images.map(\.height).max() ?? 0
        guard let ctx = context(CGSize(width: width, height: height)) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            ctx.draw(image, in: CGRect(x: x, y: height - image.height, width: image.width, height: image.height))
            x += image.width + gap
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// A mockup's screen, pinned by its corners, adjusted by hand on the canvas.
@MainActor
struct PinnedScreenTests {
    /// A screen on artboard A (at 100,100), its frame 100,50 sized 200×120 and its corners pinned
    /// a little in from the frame's, as a photo shows a screen at an angle.
    private func bench() -> (Bench, UUID) {
        var screen = Node(kind: .rectangle, name: "Screen", frame: CGRect(x: 100, y: 50, width: 200, height: 120))
        screen.transform3D = Transform3D(corners: [CGPoint(x: 0.1, y: 0), CGPoint(x: 0.95, y: 0.1), CGPoint(x: 1, y: 0.9), CGPoint(x: 0, y: 1)])
        let bench = Bench(extra: [screen])
        bench.store.selection = [screen.id]
        return (bench, screen.id)
    }

    /// Where a pinned corner shows on the canvas.
    private func shown(_ bench: Bench, _ id: UUID, _ k: Int) -> CGPoint {
        let n = bench.store.doc.node(id)!, c = n.transform3D!.corners![k]
        return CGPoint(x: 100 + n.frame.minX + c.x * n.frame.width, y: 100 + n.frame.minY + c.y * n.frame.height)
    }

    @Test func aCornerGoesWhereItIsPulledAndTheOthersStay() throws {
        let (bench, id) = bench()
        let before = (0..<4).map { shown(bench, id, $0) }
        bench.drag(before[0], CGPoint(x: before[0].x - 30, y: before[0].y + 12))
        let after = (0..<4).map { shown(bench, id, $0) }
        #expect(abs(after[0].x - (before[0].x - 30)) < 0.05 && abs(after[0].y - (before[0].y + 12)) < 0.05)
        for k in 1..<4 { #expect(abs(after[k].x - before[k].x) < 0.01 && abs(after[k].y - before[k].y) < 0.01) }
        #expect(bench.store.doc.node(id)?.frame == CGRect(x: 100, y: 50, width: 200, height: 120))
        bench.undo.undo()
        let undone = (0..<4).map { shown(bench, id, $0) }
        #expect(zip(undone, before).allSatisfy { abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01 })
    }

    @Test func aSideMovesItsTwoCorners() throws {
        let (bench, id) = bench()
        let before = (0..<4).map { shown(bench, id, $0) }
        let n = bench.store.doc.node(id)!
        let p = try #require(Perspective(n))
        // The right side's handle, where its middle shows.
        let handle = p.shown(CGPoint(x: n.frame.maxX, y: n.frame.midY))
        bench.drag(CGPoint(x: handle.x + 100, y: handle.y + 100), CGPoint(x: handle.x + 140, y: handle.y + 100))
        let after = (0..<4).map { shown(bench, id, $0) }
        for k in [1, 2] { #expect(abs(after[k].x - (before[k].x + 40)) < 0.05 && abs(after[k].y - before[k].y) < 0.05) }
        for k in [0, 3] { #expect(abs(after[k].x - before[k].x) < 0.01 && abs(after[k].y - before[k].y) < 0.01) }
    }

    @Test func aPictureLetGoOverTheGlareGoesIntoTheScreenUnderIt() throws {
        var screen = Node(kind: .rectangle, name: "Screen", frame: CGRect(x: 100, y: 50, width: 200, height: 120))
        screen.screen = true
        let glare = Node(kind: .rectangle, name: "Glare", frame: CGRect(x: 80, y: 40, width: 260, height: 160))
        let bench = Bench(extra: [screen, glare])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString).png")
        try TestPSD.png(width: 20, height: 12).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let over = CGPoint(x: 300, y: 200)
        guard case .fill(let into) = bench.store.plan(for: Dropped(pictures: [file]), at: over, on: glare.id) else {
            Issue.record("A picture over a screen should fill it")
            return
        }
        #expect(into == [screen.id])
        // Beside the screen, the glare is what it fills.
        guard case .fill(let beside) = bench.store.plan(for: Dropped(pictures: [file]), at: CGPoint(x: 190, y: 145), on: glare.id) else {
            Issue.record("A picture beside a screen should fill what it is let go on")
            return
        }
        #expect(beside == [glare.id])
    }

    @Test func aPullThatWouldFoldItOverIsRefused() throws {
        let (bench, id) = bench()
        let before = bench.store.doc.node(id)!.transform3D
        let corner = shown(bench, id, 0)
        // The top left pulled past the bottom right.
        bench.drag(corner, CGPoint(x: corner.x + 400, y: corner.y + 300))
        #expect(bench.store.doc.node(id)?.transform3D == before)
        #expect(bench.store.doc.node(id)?.frame == CGRect(x: 100, y: 50, width: 200, height: 120))
    }
}

private extension Data {
    /// The colour of one pixel of a picture, in sRGB, 0 to 1.
    func picture(at p: CGPoint) -> (r: Double, g: Double, b: Double, a: Double) {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0, 0) }
        ctx.draw(image, in: CGRect(x: -p.x, y: -(CGFloat(image.height) - 1 - p.y), width: CGFloat(image.width), height: CGFloat(image.height)))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255, Double(px[3]) / 255)
    }
}
