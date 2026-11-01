import Testing
import AppKit
import Compression
@testable import Bezzle

/// A ZIP archive written by hand, as small as it can be: no checksums, which the reader does not check.
enum TestZip {
    static func make(_ files: [(String, Data)], deflate: Bool) -> Data {
        /// Little-endian numbers, each of the given width in bytes.
        func fields(_ parts: [(Int, Int)]) -> Data {
            var d = Data()
            for (value, width) in parts {
                for i in 0..<width { d.append(UInt8((value >> (8 * i)) & 0xFF)) }
            }
            return d
        }
        var out = Data(), central = Data()
        for (name, data) in files {
            let packed = deflate ? deflated(data) : data
            let offset = out.count, nameData = Data(name.utf8), method = deflate ? 8 : 0
            out.append(fields([(0x0403_4B50, 4), (20, 2), (0, 2), (method, 2), (0, 2), (0, 2), (0, 4),
                               (packed.count, 4), (data.count, 4), (nameData.count, 2), (0, 2)]))
            out.append(nameData)
            out.append(packed)
            central.append(fields([(0x0201_4B50, 4), (20, 2), (20, 2), (0, 2), (method, 2), (0, 2), (0, 2), (0, 4),
                                   (packed.count, 4), (data.count, 4), (nameData.count, 2), (0, 2), (0, 2), (0, 2), (0, 2),
                                   (0, 4), (offset, 4)]))
            central.append(nameData)
        }
        let directory = out.count
        out.append(central)
        out.append(fields([(0x0605_4B50, 4), (0, 2), (0, 2), (files.count, 2), (files.count, 2), (central.count, 4), (directory, 4), (0, 2)]))
        return out
    }

    static func deflated(_ data: Data) -> Data {
        var out = Data(count: data.count + 1024)
        let n = out.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dest.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }
}

struct ZipTests {
    @Test func readsStoredAndDeflatedFiles() throws {
        let text = Data(String(repeating: "Bezzle reads XD. ", count: 200).utf8)
        for deflate in [false, true] {
            let archive = try ZipArchive(data: TestZip.make([("mimetype", Data("hello".utf8)), ("a/b.txt", text)], deflate: deflate))
            #expect(Set(archive.names) == ["mimetype", "a/b.txt"])
            #expect(try archive.read("a/b.txt") == text)
            #expect(try archive.read("mimetype") == Data("hello".utf8))
        }
        #expect(throws: (any Error).self) { try ZipArchive(data: Data("not a zip at all, not at all".utf8)) }
    }
}

struct PathDataTests {
    @Test func readsAndWritesOutlines() {
        let square = PathData.cgPath("M 0 0 L 10 0 L 10 10 L 0 10 Z")
        #expect(square.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        // Relative commands, numbers run together, and the shorthand lines.
        #expect(PathData.bounds("m5,5h10v-20l-5-5z") == CGRect(x: 5, y: -20, width: 10, height: 25))
        #expect(PathData.bounds("M1-2.5.5.5") == CGRect(x: 0.5, y: -2.5, width: 0.5, height: 3))
        // A half circle over the top, as SVG's sweep flag turns it on a page that runs down.
        let arc = PathData.bounds("M 0 0 A 5 5 0 0 1 10 0")
        #expect(abs(arc.minY + 5) < 0.01 && abs(arc.width - 10) < 0.01)
        // Written out and read again, the outline is the same.
        let curve = "M 0 0 C 10 20 30 20 40 0 Q 50 -10 60 0 Z"
        #expect(PathData.bounds(PathData.string(PathData.cgPath(curve))) == PathData.bounds(curve))
        let moved = PathData.transformed("M 0 0 L 10 0 L 10 10 Z", CGAffineTransform(translationX: 5, y: 7))
        #expect(PathData.bounds(moved) == CGRect(x: 5, y: 7, width: 10, height: 10))
    }
}

struct TreeTests {
    static func tree() -> BezzleDocument {
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 5, y: 5, width: 10, height: 10))
        dot.fill.on = true
        var inner = Node(kind: .group, name: "Inner", frame: CGRect(x: 20, y: 30, width: 15, height: 15))
        inner.children = [dot]
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        board.children = [inner]
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    @Test func layersInGroupsKnowWhereTheyAre() throws {
        var doc = Self.tree()
        let dot = try #require(doc.allNodes.first { $0.name == "Dot" })
        #expect(doc.absoluteFrame(of: dot.id) == CGRect(x: 125, y: 135, width: 10, height: 10))
        #expect(doc.parent(of: dot.id)?.name == "Inner")
        #expect(doc.artboard(of: dot.id)?.name == "Board")
        // Fitting the group around the dot moves nothing on the canvas.
        doc.fitGroups()
        #expect(doc.allNodes.first { $0.name == "Inner" }?.frame == CGRect(x: 25, y: 35, width: 10, height: 10))
        #expect(doc.absoluteFrame(of: dot.id) == CGRect(x: 125, y: 135, width: 10, height: 10))
        // Out of the group onto the canvas and back in, still in the same place.
        let detached = doc.detach(dot.id)
        let taken = try #require(detached)
        #expect(taken.frame == CGRect(x: 125, y: 135, width: 10, height: 10))
        doc.fitGroups()
        #expect(!doc.allNodes.contains { $0.name == "Inner" })
        doc.attach(taken, to: doc.nodes[0].id)
        #expect(doc.absoluteFrame(of: dot.id) == CGRect(x: 125, y: 135, width: 10, height: 10))
    }

    @Test func turningAGroupTurnsWhatItHolds() {
        var bar = Node(kind: .rectangle, name: "Bar", frame: CGRect(x: 0, y: 0, width: 40, height: 10))
        bar.fill.on = true
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 0, y: 0, width: 40, height: 10))
        group.children = [bar]
        let turned = BezzleDocument.turned(group, by: 90, about: CGPoint(x: 20, y: 5))
        #expect(turned.rotation == 0)
        #expect(turned.children[0].rotation == 90)
        #expect(turned.children[0].frame.center == CGPoint(x: 20, y: 5))
        let scaled = BezzleDocument.scaled(group.children, from: CGSize(width: 40, height: 10), to: CGSize(width: 80, height: 20))
        #expect(scaled[0].frame == CGRect(x: 0, y: 0, width: 80, height: 20))
    }
}

@MainActor
struct XDImportTests {
    static let red = #"{"mode":"RGB","value":{"r":255,"g":0,"b":0}}"#
    static let blue = #"{"mode":"RGB","value":{"r":0,"g":0,"b":255}}"#

    /// A small XD file: an artboard with a card, a turned group with a gradient, a line of text,
    /// a component instance, and a group masked by a shape kept among the shared resources.
    static func file() throws -> URL {
        let manifest = #"{"children":[{"name":"artwork","path":"artwork","children":[{"name":"Board","path":"artboard-1","uxdesign#bounds":{"x":100,"y":50,"width":375,"height":812}}]},{"name":"resources","path":"resources","components":[]}]}"#
        let board = """
        {"children":[{"type":"artboard","style":{"fill":{"type":"solid","color":{"mode":"RGB","value":{"r":0,"g":0,"b":0}}}},"artboard":{"children":[
          {"type":"shape","name":"Card","transform":{"a":1,"b":0,"c":0,"d":1,"tx":116,"ty":70},"meta":{"ux":{"localTransform":{"a":1,"b":0,"c":0,"d":1,"tx":16,"ty":20}}},
           "style":{"fill":{"type":"solid","color":\(red)},"stroke":{"type":"solid","color":\(blue),"width":2,"align":"inside"},
             "filters":[{"type":"dropShadow","params":{"dropShadows":[{"dx":0,"dy":3,"r":6,"color":{"mode":"RGB","value":{"r":0,"g":0,"b":0},"alpha":0.2}}]}}]},
           "shape":{"type":"rect","x":0,"y":0,"width":100,"height":40,"r":[4,8,4,8]}},
          {"type":"group","name":"Turned","transform":{"a":0,"b":1,"c":-1,"d":0,"tx":300,"ty":350},"group":{"children":[
            {"type":"shape","name":"Bar","style":{"fill":{"type":"gradient","gradient":{"meta":{"ux":{"gradientResources":{"type":"linear","stops":[{"offset":0,"color":\(red)},{"offset":1,"color":\(blue)}]}}},"x1":0,"y1":0,"x2":1,"y2":0,"units":"objectBoundingBox"}}},
             "shape":{"type":"rect","x":0,"y":0,"width":60,"height":10}}]}},
          {"type":"text","name":"Hello","transform":{"a":1,"b":0,"c":0,"d":1,"tx":120,"ty":250},
           "style":{"fill":{"type":"solid","color":\(red)},"font":{"family":"Helvetica","style":"Bold","postscriptName":"Helvetica-Bold","size":20},"textAttributes":{"letterSpacing":50}},
           "meta":{"ux":{"rangedStyles":[{"length":5,"textTransform":"uppercase","fontSize":20,"postscriptName":"Helvetica-Bold","fontFamily":"Helvetica","fontStyle":"Bold"}]}},
           "text":{"rawText":"Hello","frame":{"type":"positioned"},"paragraphs":[{"lines":[[{"x":0,"y":0,"from":0,"to":5}]]}]}},
          {"type":"syncRef","syncSourceGuid":"master-1","guid":"i1","transform":{"a":1,"b":0,"c":0,"d":1,"tx":110,"ty":450}},
          {"type":"group","name":"Masked","style":{"clipPath":{"ref":"clip-1"}},"transform":{"a":1,"b":0,"c":0,"d":1,"tx":100,"ty":550},"group":{"children":[
            {"type":"shape","name":"Big","style":{"fill":{"type":"solid","color":\(blue)}},"shape":{"type":"rect","x":0,"y":0,"width":200,"height":200}}]}}
        ]}}]}
        """
        let resources = """
        {"resources":{"meta":{"ux":{"symbols":[{"type":"shape","id":"master-1","name":"Pill","style":{"fill":{"type":"solid","color":\(blue)}},"shape":{"type":"rect","x":0,"y":0,"width":80,"height":30,"r":15}}]}},
         "clipPaths":{"clip-1":{"children":[{"type":"shape","name":"Round","shape":{"type":"circle","cx":50,"cy":50,"r":50}}]}}}}
        """
        let zip = TestZip.make([("mimetype", Data("application/vnd.adobe.sparkler.project+dcxucf".utf8)),
                                ("manifest", Data(manifest.utf8)),
                                ("artwork/artboard-1/graphics/graphicContent.agc", Data(board.utf8)),
                                ("resources/graphics/graphicContent.agc", Data(resources.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).xd")
        try zip.write(to: url)
        return url
    }

    @Test func bringsAnXDFileAcross() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try XDImporter.read(url)
        let doc = imported.document, report = imported.report
        let board = try #require(doc.artboards.first)
        #expect(board.frame == CGRect(x: 100, y: 50, width: 375, height: 812))
        #expect(board.fill.color.hex == "000000")
        #expect(report.artboards == 1)
        func named(_ name: String) throws -> Node { try #require(doc.allNodes.first { $0.name == name }) }

        let card = try named("Card")
        #expect(card.kind == .rectangle)
        #expect(card.frame == CGRect(x: 16, y: 20, width: 100, height: 40))
        #expect(card.corners == [4, 8, 4, 8])
        #expect(card.fill.color.hex == "FF0000")
        #expect(card.border.on && card.border.width == 2 && card.border.position == .inside && card.border.color.hex == "0000FF")
        #expect(card.shadow.on && card.shadow.y == 3 && card.shadow.blur == 6 && abs(card.shadow.color.a - 0.2) < 0.001)

        // The group's quarter turn goes to what it holds; the group itself stays upright around it.
        let bar = try named("Bar"), turned = try named("Turned")
        #expect(turned.rotation == 0)
        #expect(bar.rotation == 90)
        #expect(doc.absoluteFrame(of: bar.id).map { CGPoint(x: $0.midX, y: $0.midY) } == CGPoint(x: 295, y: 380))
        #expect(bar.fill.gradient?.kind == .linear && bar.fill.gradient?.stops.count == 2)
        #expect(turned.frame.size == CGSize(width: 10, height: 60))

        // The text's origin is its first baseline, so its top sits above it.
        let hello = try named("Hello")
        #expect(hello.kind == .text && hello.text == "Hello")
        #expect(hello.style?.family == "Helvetica" && hello.style?.face == "Bold" && hello.style?.size == 20)
        #expect(hello.style?.tracking == 50 && hello.style?.letterCase == .upper)
        #expect(hello.frame.minX == 20 && hello.frame.minY < 200 && hello.frame.minY > 175)

        // The instance is its master, where the instance is.
        let pill = try named("Pill")
        #expect(pill.kind == .rectangle && pill.cornerRadius == 15 && pill.fill.color.hex == "0000FF")
        #expect(pill.frame == CGRect(x: 10, y: 400, width: 80, height: 30))

        // The mask from the shared resources cuts the group down to its circle: a mask of
        // Bezzle's, its circle clear, as XD does not draw it.
        let masked = try named("Masked")
        #expect(masked.isMask && masked.mask == nil && masked.children.map(\.name) == ["Round", "Big"])
        #expect(masked.children[0].kind == .ellipse && masked.children[0].fills.isEmpty)
        #expect(masked.frame == CGRect(x: 0, y: 500, width: 100, height: 100))
    }

    /// An XD file of two texts whose letters differ: one with a word in bold and red, underlined and
    /// struck through, as XD keeps its ranges of letters, the last one to the end; and one as older
    /// files keep it, on the pieces of its lines.
    static func lettersFile() throws -> URL {
        let manifest = #"{"children":[{"name":"artwork","path":"artwork","children":[{"name":"Board","path":"artboard-1","uxdesign#bounds":{"x":0,"y":0,"width":375,"height":812}}]},{"name":"resources","path":"resources","components":[]}]}"#
        let helvetica = #""fontFamily":"Helvetica","fontStyle":"Regular","postscriptName":"Helvetica","fontSize":20"#
        let board = """
        {"children":[{"type":"artboard","artboard":{"children":[
          {"type":"text","name":"Rich","transform":{"a":1,"b":0,"c":0,"d":1,"tx":20,"ty":100},
           "style":{"fill":{"type":"solid","color":{"mode":"RGB","value":{"r":0,"g":0,"b":0}}},"font":{"family":"Helvetica","style":"Regular","postscriptName":"Helvetica","size":20},
             "textAttributes":{"paragraphAlign":"justify","paragraphAfterSpacing":6}},
           "meta":{"ux":{"rangedStyles":[{"length":6,\(helvetica),"fill":{"value":4278190080}},
             {"length":4,"fontFamily":"Helvetica","fontStyle":"Bold","postscriptName":"Helvetica-Bold","fontSize":20,"fill":{"value":4294901760},"underline":true,"strikethrough":true},
             {"length":0,\(helvetica),"fill":{"value":4278190080}}]}},
           "text":{"rawText":"Hello bold world","frame":{"type":"positioned"},"paragraphs":[{"lines":[[{"x":0,"y":0,"from":0,"to":16}]]}]}},
          {"type":"text","name":"Older","transform":{"a":1,"b":0,"c":0,"d":1,"tx":20,"ty":200},
           "style":{"fill":{"type":"solid","color":{"mode":"RGB","value":{"r":0,"g":0,"b":0}}},"font":{"family":"Helvetica","style":"Regular","postscriptName":"Helvetica","size":20}},
           "text":{"rawText":"Big bold","frame":{"type":"positioned"},"paragraphs":[{"lines":[[{"x":0,"y":0,"from":0,"to":4},
             {"x":40,"y":0,"from":4,"to":8,"style":{"font":{"family":"Helvetica","style":"Bold","postscriptName":"Helvetica-Bold","size":20},
               "fill":{"type":"solid","color":\(red)},"textAttributes":{"decoration":["underline"]}}}]]}]}}
        ]}}]}
        """
        let zip = TestZip.make([("mimetype", Data("application/vnd.adobe.sparkler.project+dcxucf".utf8)), ("manifest", Data(manifest.utf8)),
                                ("artwork/artboard-1/graphics/graphicContent.agc", Data(board.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).xd")
        try zip.write(to: url)
        return url
    }

    @Test func bringsStyledLettersAcross() throws {
        let url = try Self.lettersFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try XDImporter.read(url)
        func named(_ name: String) throws -> Node { try #require(imported.document.allNodes.first { $0.name == name }) }
        #expect(imported.report.notes.isEmpty)

        let rich = try named("Rich")
        #expect(rich.text == "Hello bold world" && rich.style?.face == "Regular" && rich.fill.color.hex == "000000")
        #expect(rich.runs.map(\.text) == ["Hello ", "bold", " world"])
        let bold = rich.runs[1].look
        #expect(bold.face == "Bold" && bold.color?.hex == "FF0000" && bold.underline == true && bold.strikethrough == true && bold.size == nil)
        #expect(rich.runs[0].look.isPlain && rich.runs[2].look.isPlain)
        #expect(rich.style?.align == .justify && rich.style?.paragraphSpacing == 6)

        let older = try named("Older")
        #expect(older.runs.map(\.text) == ["Big ", "bold"])
        #expect(older.runs[1].look.face == "Bold" && older.runs[1].look.color?.hex == "FF0000" && older.runs[1].look.underline == true)
    }

    /// An XD artboard laid out on columns with uneven margins and a top margin, with guides, and a
    /// text with a word in capitals.
    static func helpersFile() throws -> URL {
        let manifest = #"{"children":[{"name":"artwork","path":"artwork","children":[{"name":"Board","path":"artboard-1","uxdesign#bounds":{"x":0,"y":0,"width":375,"height":812}}]},{"name":"resources","path":"resources","components":[]}]}"#
        let helvetica = #""fontFamily":"Helvetica","fontStyle":"Regular","postscriptName":"Helvetica","fontSize":16"#
        let board = """
        {"children":[{"type":"artboard","meta":{"ux":{
            "gridStyle":{"type":"layout","visible":true,"columns":4,"gutter":16,"marginLeft":20,"marginRight":28,"marginTop":10,"marginBottom":0,"rowSpacing":8,"columnSpacing":8},
            "guidesModel":{"verticalGuides":{"guides":[{"position":20},{"position":500}]},"horizontalGuides":{"guides":[{"position":406}]}}}},
          "artboard":{"children":[
          {"type":"text","name":"Shout","transform":{"a":1,"b":0,"c":0,"d":1,"tx":20,"ty":100},
           "style":{"fill":{"type":"solid","color":{"mode":"RGB","value":{"r":0,"g":0,"b":0}}},"font":{"family":"Helvetica","style":"Regular","postscriptName":"Helvetica","size":16}},
           "meta":{"ux":{"rangedStyles":[{"length":6,\(helvetica)},{"length":3,"textTransform":"uppercase",\(helvetica)},{"length":0,\(helvetica)}]}},
           "text":{"rawText":"Hello new world","frame":{"type":"positioned"},"paragraphs":[{"lines":[[{"x":0,"y":0,"from":0,"to":15}]]}]}}
        ]}}]}
        """
        let zip = TestZip.make([("mimetype", Data("application/vnd.adobe.sparkler.project+dcxucf".utf8)), ("manifest", Data(manifest.utf8)),
                                ("artwork/artboard-1/graphics/graphicContent.agc", Data(board.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).xd")
        try zip.write(to: url)
        return url
    }

    @Test func bringsLayoutGridsAndGuidesAcross() throws {
        let url = try Self.helpersFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try XDImporter.read(url)
        let notes = imported.report.notes
        let board = try #require(imported.document.artboards.first)
        // Bezzle's columns have one margin for both sides: halfway between XD's two.
        #expect(board.layout == LayoutGrid(columns: LayoutGrid.Track(count: 4, gutter: 16, margin: 24), rows: nil, baseline: nil))
        #expect(notes["Layout grids with uneven margins, centred"] == 1 && notes["Top and bottom margins of layout grids, left out"] == 1)
        // A guide off the artboard has nothing to line up and is left out; the one in the middle keeps to it.
        #expect(board.sortedGuides().map(\.guide) == [Guideline(vertical: true, edge: .start, offset: 20), Guideline(vertical: false, edge: .middle, offset: 0)])

        let shout = try #require(imported.document.allNodes.first { $0.name == "Shout" })
        #expect(shout.text == "Hello NEW world" && shout.style?.letterCase == nil)
        #expect(notes["Texts with several styles, shown in their main one"] == nil)
    }

    @Test func writesTheDesignAsAPackage() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (design, _) = try Importer.importFile(url, into: folder)
        #expect(DesignFile.isPackage(design))
        #expect(try DesignFile.read(design).artboards.count == 1)
        // The XD file itself is left alone.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
