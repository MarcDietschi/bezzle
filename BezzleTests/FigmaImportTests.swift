import Testing
import AppKit
@testable import Bezzle

/// Kiwi written as Figma writes it, for Figma files made by hand: a schema of only what the tests
/// use, under Figma's own names, and messages in it given as dictionaries.
enum TestKiwi {
    /// Each type: its name, enum 0, struct 1 or message 2, and its fields by name and type, a
    /// trailing [] for a list; an enum's fields are its cases.
    static let schema: [(name: String, kind: UInt8, fields: [String])] = [
        ("NodeType", 0, ["DOCUMENT", "CANVAS", "FRAME", "RECTANGLE", "ROUNDED_RECTANGLE", "ELLIPSE", "TEXT", "INSTANCE", "SYMBOL", "VECTOR"]),
        ("GUID", 1, ["sessionID uint", "localID uint"]),
        ("Color", 1, ["r float", "g float", "b float", "a float"]),
        ("Vector", 1, ["x float", "y float"]),
        ("Matrix", 1, ["m00 float", "m01 float", "m02 float", "m10 float", "m11 float", "m12 float"]),
        ("ParentIndex", 2, ["guid GUID", "position string"]),
        ("PaintType", 0, ["SOLID", "GRADIENT_LINEAR", "GRADIENT_RADIAL", "IMAGE"]),
        ("ImageScaleMode", 0, ["STRETCH", "FIT", "FILL", "TILE"]),
        ("ColorStop", 1, ["color Color", "position float"]),
        ("Image", 2, ["hash byte[]", "name string"]),
        ("Paint", 2, ["type PaintType", "color Color", "opacity float", "visible bool", "stops ColorStop[]", "transform Matrix", "image Image",
                      "imageScaleMode ImageScaleMode", "originalImageWidth uint", "originalImageHeight uint"]),
        ("EffectType", 0, ["DROP_SHADOW", "INNER_SHADOW", "FOREGROUND_BLUR", "BACKGROUND_BLUR"]),
        ("BlurOpType", 0, ["NORMAL", "PROGRESSIVE"]),
        ("Effect", 2, ["type EffectType", "color Color", "offset Vector", "radius float", "visible bool", "blurOpType BlurOpType",
                       "startOffset Vector", "endOffset Vector"]),
        ("FontName", 2, ["family string", "style string", "postscript string"]),
        ("NumberUnits", 0, ["RAW", "PIXELS", "PERCENT"]),
        ("Number", 2, ["value float", "units NumberUnits"]),
        ("Baseline", 2, ["position Vector"]),
        ("LineType", 0, ["PLAIN", "ORDERED_LIST", "UNORDERED_LIST"]),
        ("TextLineData", 2, ["lineType LineType"]),
        ("TextData", 2, ["characters string", "baselines Baseline[]", "characterStyleIDs uint[]", "styleOverrideTable NodeChange[]",
                         "lines TextLineData[]"]),
        ("TextDecoration", 0, ["NONE", "UNDERLINE", "STRIKETHROUGH"]),
        ("TextAlignHorizontal", 0, ["LEFT", "CENTER", "RIGHT", "JUSTIFIED"]),
        ("TextAlignVertical", 0, ["TOP", "CENTER", "BOTTOM"]),
        ("OpenTypeFeature", 0, ["LIGA", "SS01", "TNUM"]),
        ("FontVariation", 2, ["axisTag uint", "axisName string", "value float"]),
        ("GUIDPath", 2, ["guids GUID[]"]),
        ("SymbolData", 2, ["symbolID GUID", "symbolOverrides NodeChange[]"]),
        ("StrokeAlign", 0, ["CENTER", "INSIDE", "OUTSIDE"]),
        ("TextAutoResize", 0, ["NONE", "WIDTH_AND_HEIGHT", "HEIGHT"]),
        ("TextCase", 0, ["ORIGINAL", "UPPER", "LOWER", "TITLE", "SMALL_CAPS"]),
        ("WindingRule", 0, ["NONZERO", "ODD"]),
        ("Path", 2, ["windingRule WindingRule", "commandsBlob uint", "styleID uint"]),
        ("LayoutGridType", 0, ["MIN", "CENTER", "STRETCH", "MAX"]),
        ("Axis", 0, ["X", "Y"]),
        ("LayoutGridPattern", 0, ["STRIPES", "GRID"]),
        ("LayoutGrid", 2, ["type LayoutGridType", "axis Axis", "visible bool", "numSections int", "offset float", "sectionSize float",
                           "gutterSize float", "pattern LayoutGridPattern"]),
        ("Guide", 2, ["axis Axis", "offset float"]),
        ("MaskType", 0, ["ALPHA", "OUTLINE", "LUMINANCE"]),
        ("NodeChange", 2, ["guid GUID", "guidPath GUIDPath", "parentIndex ParentIndex", "type NodeType", "name string", "visible bool",
                           "opacity float", "size Vector", "transform Matrix", "fillPaints Paint[]", "strokePaints Paint[]", "strokeWeight float",
                           "strokeAlign StrokeAlign", "effects Effect[]", "cornerRadius float", "rectangleCornerRadiiIndependent bool",
                           "rectangleTopLeftCornerRadius float", "rectangleTopRightCornerRadius float", "rectangleBottomRightCornerRadius float",
                           "rectangleBottomLeftCornerRadius float", "frameMaskDisabled bool", "resizeToFit bool", "mask bool", "internalOnly bool",
                           "fontName FontName", "fontSize float", "letterSpacing Number", "textData TextData", "textAutoResize TextAutoResize",
                           "textCase TextCase", "symbolData SymbolData", "derivedSymbolData NodeChange[]", "fillGeometry Path[]",
                           "styleID uint", "textDecoration TextDecoration", "textAlignHorizontal TextAlignHorizontal",
                           "textAlignVertical TextAlignVertical", "paragraphSpacing float", "lineHeight Number",
                           "toggledOnOTFeatures OpenTypeFeature[]", "fontVariations FontVariation[]", "layoutGrids LayoutGrid[]",
                           "guides Guide[]", "maskType MaskType"]),
        ("Blob", 2, ["bytes byte[]"]),
        ("Message", 2, ["nodeChanges NodeChange[]", "blobs Blob[]"]),
    ]

    private static let plain = ["bool": -1, "byte": -2, "int": -3, "uint": -4, "float": -5, "string": -6]

    private static func type(_ name: String) -> Int { plain[name] ?? schema.firstIndex { $0.name == name }! }

    /// A field's name, type and whether it is a list.
    private static func field(_ s: String) -> (String, String, Bool) {
        let parts = s.split(separator: " ").map(String.init)
        let list = parts[1].hasSuffix("[]")
        return (parts[0], list ? String(parts[1].dropLast(2)) : parts[1], list)
    }

    private struct Writer {
        var out = Data()

        mutating func uint(_ v: Int) {
            var v = UInt64(v)
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            out.append(UInt8(v))
        }

        mutating func int(_ v: Int) { uint(Int(UInt32(bitPattern: Int32(v) << 1 ^ Int32(v) >> 31))) }

        mutating func float(_ v: Double) {
            let bits = Float(v).bitPattern
            guard bits != 0 else { out.append(0); return }
            let s = bits << 9 | bits >> 23
            for i in 0..<4 { out.append(UInt8((s >> (8 * UInt32(i))) & 0xFF)) }
        }

        mutating func string(_ s: String) { out.append(Data(s.utf8)); out.append(0) }

        mutating func value(_ v: Any?, type t: String, list: Bool) {
            if list {
                if t == "byte" { let d = v as? Data ?? Data(); uint(d.count); out.append(d); return }
                let items = v as? [Any] ?? []
                uint(items.count)
                for item in items { value(item, type: t, list: false) }
                return
            }
            switch t {
            case "bool": out.append((v as? Bool ?? false) ? 1 : 0)
            case "uint": uint(v as? Int ?? 0)
            case "int": int(v as? Int ?? 0)
            case "float": float((v as? Double) ?? Double(v as? Int ?? 0))
            case "string": string(v as? String ?? "")
            default:
                let d = TestKiwi.schema[TestKiwi.type(t)]
                switch d.kind {
                case 0: uint(d.fields.firstIndex(of: v as? String ?? "") ?? 0)
                case 1:
                    let o = v as? [String: Any] ?? [:]
                    for f in d.fields.map(TestKiwi.field) { value(o[f.0], type: f.1, list: f.2) }
                default:
                    let o = v as? [String: Any] ?? [:]
                    for (i, f) in d.fields.map(TestKiwi.field).enumerated() where o[f.0] != nil {
                        uint(i + 1)
                        value(o[f.0], type: f.1, list: f.2)
                    }
                    uint(0)
                }
            }
        }
    }

    static func schemaData() -> Data {
        var w = Writer()
        w.uint(schema.count)
        for d in schema {
            w.string(d.name)
            w.out.append(d.kind)
            w.uint(d.fields.count)
            for (i, f) in d.fields.enumerated() {
                if d.kind == 0 {
                    w.string(f)
                    w.int(0)
                    w.out.append(0)
                    w.uint(i)
                } else {
                    let (name, t, list) = field(f)
                    w.string(name)
                    w.int(type(t))
                    w.out.append(list ? 1 : 0)
                    w.uint(d.kind == 2 ? i + 1 : 0)
                }
            }
        }
        return w.out
    }

    static func message(_ m: [String: Any]) -> Data {
        var w = Writer()
        w.value(m, type: "Message", list: false)
        return w.out
    }

    /// A `canvas.fig`: its header and version, then the schema and the message, each deflated.
    static func canvas(_ m: [String: Any], message data: Data? = nil) -> Data {
        var out = Data("fig-kiwi".utf8)
        func u32(_ v: Int) { for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        u32(48)
        for part in [schemaData(), data ?? message(m)] {
            let packed = TestZip.deflated(part)
            u32(packed.count)
            out.append(packed)
        }
        return out
    }
}

@MainActor
struct FigmaImportTests {
    static func guid(_ s: Int, _ l: Int) -> [String: Any] { ["sessionID": s, "localID": l] }
    static func at(_ x: Double, _ y: Double) -> [String: Any] { ["m00": 1.0, "m11": 1.0, "m02": x, "m12": y] }
    static func size(_ w: Double, _ h: Double) -> [String: Any] { ["x": w, "y": h] }
    static func solid(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> [String: Any] {
        ["type": "SOLID", "color": ["r": r, "g": g, "b": b, "a": a], "opacity": 1.0, "visible": true]
    }
    static func node(_ id: (Int, Int), _ type: String, _ name: String, in parent: (Int, Int), _ position: String, _ more: [String: Any] = [:]) -> [String: Any] {
        var n: [String: Any] = ["guid": guid(id.0, id.1), "type": type, "name": name, "visible": true, "opacity": 1.0,
                                "parentIndex": ["guid": guid(parent.0, parent.1), "position": position]]
        n.merge(more) { $1 }
        return n
    }

    /// A small picture, four pixels by two.
    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A triangle as Figma keeps an outline: a command byte and its points as floats.
    static func triangle() -> Data {
        var d = Data()
        func command(_ c: UInt8, _ points: [Float]) {
            d.append(c)
            for p in points { withUnsafeBytes(of: p.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        }
        command(1, [0, 0]); command(2, [20, 0]); command(2, [10, 20]); command(0, [])
        return d
    }

    /// Two pages. The first has an artboard with a card, a turned group with a gradient, a line of
    /// text, an instance of a master kept off the pages with its fill changed, a frame that clips,
    /// a layer with a blur that grows, a picture, an outline and a mask; the second a loose square.
    static func message() -> [String: Any] {
        let board = (1, 1), page = (0, 1)
        let nodes: [[String: Any]] = [
            ["guid": guid(0, 0), "type": "DOCUMENT", "name": "Document"],
            node(page, "CANVAS", "Page 1", in: (0, 0), "!"),
            node((0, 2), "CANVAS", "Page 2", in: (0, 0), "\""),
            node((0, 3), "CANVAS", "Internal Only Canvas", in: (0, 0), "~", ["internalOnly": true]),
            node(board, "FRAME", "Board", in: page, "!", ["size": size(375, 812), "transform": at(100, 50), "fillPaints": [solid(1, 1, 1)]]),
            node((1, 2), "RECTANGLE", "Card", in: board, "!", [
                "size": size(100, 40), "transform": at(16, 20), "fillPaints": [solid(1, 0, 0)], "strokePaints": [solid(0, 0, 1)],
                "strokeWeight": 2.0, "strokeAlign": "INSIDE", "rectangleCornerRadiiIndependent": true,
                "rectangleTopLeftCornerRadius": 4.0, "rectangleTopRightCornerRadius": 8.0,
                "rectangleBottomRightCornerRadius": 4.0, "rectangleBottomLeftCornerRadius": 8.0,
                "effects": [["type": "DROP_SHADOW", "color": ["r": 0.0, "g": 0.0, "b": 0.0, "a": 0.2], "offset": ["x": 0.0, "y": 3.0], "radius": 6.0, "visible": true]],
            ]),
            node((1, 3), "FRAME", "Turned", in: board, "\"", ["resizeToFit": true, "size": size(10, 60),
                                                               "transform": ["m00": 0.0, "m01": -1.0, "m02": 300.0, "m10": 1.0, "m11": 0.0, "m12": 350.0]]),
            node((1, 4), "RECTANGLE", "Bar", in: (1, 3), "!", ["size": size(60, 10), "transform": at(0, 0), "fillPaints": [[
                "type": "GRADIENT_LINEAR", "opacity": 1.0, "visible": true, "transform": at(0, 0),
                "stops": [["color": ["r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0], "position": 0.0], ["color": ["r": 0.0, "g": 0.0, "b": 1.0, "a": 1.0], "position": 1.0]],
            ]]]),
            node((1, 5), "TEXT", "Hello", in: board, "#", [
                "size": size(60, 24), "transform": at(20, 200), "fillPaints": [solid(0, 0, 0)],
                "fontName": ["family": "Helvetica", "style": "Bold", "postscript": "Helvetica-Bold"], "fontSize": 20.0,
                "letterSpacing": ["value": 5.0, "units": "PERCENT"], "textCase": "UPPER", "textAutoResize": "WIDTH_AND_HEIGHT",
                "textData": ["characters": "Hello", "baselines": [["position": ["x": 0.0, "y": 18.0]]]],
            ]),
            node((1, 20), "SYMBOL", "Pill", in: (0, 3), "!", ["size": size(80, 30), "transform": at(0, 0), "frameMaskDisabled": true]),
            node((1, 21), "ROUNDED_RECTANGLE", "Shape", in: (1, 20), "!", ["size": size(80, 30), "transform": at(0, 0), "cornerRadius": 15.0,
                                                                         "fillPaints": [solid(0, 0, 1)]]),
            node((1, 6), "INSTANCE", "Pill copy", in: board, "$", [
                "size": size(120, 30), "transform": at(10, 400), "frameMaskDisabled": true,
                "symbolData": ["symbolID": guid(1, 20), "symbolOverrides": [["guidPath": ["guids": [guid(1, 21)]], "fillPaints": [solid(0, 1, 0)]]]],
                "derivedSymbolData": [["guidPath": ["guids": [guid(1, 21)]], "size": size(120, 30)]],
            ]),
            node((1, 7), "FRAME", "Clip", in: board, "%", ["size": size(100, 100), "transform": at(100, 500), "cornerRadius": 12.0,
                                                          "fillPaints": [solid(0.5, 0.5, 0.5)]]),
            node((1, 8), "RECTANGLE", "Big", in: (1, 7), "!", ["size": size(300, 300), "transform": at(-50, -50), "fillPaints": [solid(0, 0, 1)]]),
            node((1, 9), "ELLIPSE", "Frosted", in: board, "&", ["size": size(50, 50), "transform": at(200, 600), "fillPaints": [solid(1, 1, 1)],
                "effects": [["type": "FOREGROUND_BLUR", "radius": 20.0, "visible": true, "blurOpType": "PROGRESSIVE",
                             "startOffset": ["x": 0.5, "y": 0.2], "endOffset": ["x": 0.5, "y": 0.9]]]]),
            node((1, 10), "RECTANGLE", "Photo", in: board, "'", ["size": size(40, 20), "transform": at(300, 600), "fillPaints": [[
                "type": "IMAGE", "opacity": 1.0, "visible": true, "image": ["hash": Data([0xAB, 0xCD]), "name": "photo"],
                "imageScaleMode": "FIT", "originalImageWidth": 4, "originalImageHeight": 2,
            ]]]),
            node((1, 11), "VECTOR", "Wedge", in: board, "(", ["size": size(20, 20), "transform": at(10, 700), "fillPaints": [solid(1, 0.5, 0)],
                                                              "fillGeometry": [["windingRule": "ODD", "commandsBlob": 0]]]),
            node((1, 12), "RECTANGLE", "Window", in: board, ")", ["size": size(50, 50), "transform": at(300, 700), "mask": true, "fillPaints": [solid(0, 0, 0)]]),
            node((1, 13), "RECTANGLE", "Masked", in: board, "*", ["size": size(100, 100), "transform": at(280, 680), "fillPaints": [solid(1, 0, 1)]]),
            node((2, 1), "RECTANGLE", "Loose", in: (0, 2), "!", ["size": size(30, 30), "transform": at(0, 0), "fillPaints": [solid(1, 0, 0)]]),
        ]
        return ["nodeChanges": nodes, "blobs": [["bytes": triangle()]]]
    }

    static func file() throws -> URL {
        let zip = TestZip.make([("canvas.fig", TestKiwi.canvas(message())), ("meta.json", Data("{}".utf8)), ("images/abcd", png())], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).fig")
        try zip.write(to: url)
        return url
    }

    @Test func bringsAFigmaFileAcross() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try FigmaImporter.read(url)
        let doc = imported.document, report = imported.report
        func named(_ name: String) throws -> Node { try #require(doc.allNodes.first { $0.name == name }) }

        let board = try named("Board")
        #expect(board.isArtboard && board.frame == CGRect(x: 100, y: 50, width: 375, height: 812))
        #expect(board.fill.color.hex == "FFFFFF")
        // The master kept off the pages is not shown itself.
        #expect(report.artboards == 1 && !doc.allNodes.contains { $0.name == "Pill" })

        let card = try named("Card")
        #expect(card.kind == .rectangle && card.frame == CGRect(x: 16, y: 20, width: 100, height: 40))
        #expect(card.corners == [4, 8, 4, 8] && card.fill.color.hex == "FF0000")
        #expect(card.border.on && card.border.width == 2 && card.border.position == .inside && card.border.color.hex == "0000FF")
        #expect(card.shadow.on && card.shadow.y == 3 && card.shadow.blur == 6 && abs(card.shadow.color.a - 0.2) < 0.001)

        // The group's quarter turn goes to what it holds; the group itself stays upright around it.
        let bar = try named("Bar"), turned = try named("Turned")
        #expect(turned.kind == .group && turned.rotation == 0 && bar.rotation == 90)
        let center = try #require(doc.absoluteFrame(of: bar.id)).center
        #expect(abs(center.x - 395) < 0.01 && abs(center.y - 430) < 0.01)
        #expect(bar.fill.gradient?.kind == .linear && bar.fill.gradient?.start == CGPoint(x: 0, y: 0.5) && bar.fill.gradient?.end == CGPoint(x: 1, y: 0.5))

        let hello = try named("Hello")
        #expect(hello.kind == .text && hello.text == "Hello")
        #expect(hello.style?.family == "Helvetica" && hello.style?.face == "Bold" && hello.style?.size == 20)
        #expect(hello.style?.tracking == 50 && hello.style?.letterCase == .upper && hello.style?.sizing == .autoWidth)
        // Its first baseline is where Figma put it.
        #expect(hello.frame.minX == 20 && abs(hello.frame.minY + TextLayout.firstBaseline(hello) - 218) < 0.5)

        // The instance is its master's layers, stretched to the instance, with its fill changed.
        let pill = try named("Pill copy"), shape = try named("Shape")
        #expect(pill.kind == .group && pill.children.map(\.name) == ["Shape"])
        #expect(shape.fill.color.hex == "00FF00" && shape.cornerRadius == 15)
        #expect(doc.absoluteFrame(of: shape.id) == CGRect(x: 110, y: 450, width: 120, height: 30))

        // A frame in a frame cutting off what reaches past it is a mask of Bezzle's, its rounded
        // background the shape that holds the rest.
        let clip = try named("Clip")
        #expect(clip.kind == .group && clip.isMask && clip.mask == nil)
        #expect(clip.frame == CGRect(x: 100, y: 500, width: 100, height: 100))
        #expect(clip.children.map(\.name) == ["Background", "Big"] && clip.children[0].fill.color.hex == "808080")
        #expect(clip.children[0].kind == .rectangle && clip.children[0].cornerRadius == 12)

        let frosted = try named("Frosted")
        #expect(frosted.kind == .ellipse && frosted.blur?.radius == 10 && frosted.blur?.background == false)
        let ramp = try #require(frosted.blur?.ramp)
        #expect(abs(ramp.start.y - 0.2) < 1e-6 && abs(ramp.end.y - 0.9) < 1e-6 && ramp.start.x == 0.5 && ramp.end.x == 0.5)

        let photo = try named("Photo")
        #expect(photo.fill.image?.asset == "abcd.png" && photo.fill.image?.mode == .fit && photo.fill.image?.size == CGSize(width: 4, height: 2))
        #expect(imported.pictures == ["abcd.png": "images/abcd"])

        let wedge = try named("Wedge")
        #expect(wedge.kind == .path && wedge.evenOdd == true && wedge.frame == CGRect(x: 10, y: 700, width: 20, height: 20))

        // The mask cuts off the layer above it: a mask of Bezzle's, its shape clear, as Figma
        // does not draw a mask.
        let masked = try named("Masked")
        let mask = try #require(doc.allNodes.first { $0.children.contains { $0.id == masked.id } })
        #expect(mask.isMask && mask.name == "Mask 1" && mask.frame == CGRect(x: 300, y: 700, width: 50, height: 50))
        #expect(mask.children.map(\.name) == ["Window", "Masked"] && mask.children[0].fills.isEmpty)

        // The second page lies under the first, lined up on its left.
        let loose = try named("Loose")
        #expect(loose.frame.minX == 100 && loose.frame.minY > board.frame.maxY)
        #expect(report.notes["Pages, laid out under the first"] == 1)
    }

    static let helvetica: [String: Any] = ["family": "Helvetica", "style": "Regular", "postscript": "Helvetica"]

    /// A board of texts whose letters differ: one with a word in bold, in red and struck through,
    /// its first paragraph an item of a list, justified, in the middle of its box; one mostly in
    /// big blue letters, so those are the layer's own; and one with features and axes set.
    static func lettersMessage() -> [String: Any] {
        let board = (1, 1), page = (0, 1)
        let nodes: [[String: Any]] = [
            ["guid": guid(0, 0), "type": "DOCUMENT", "name": "Document"],
            node(page, "CANVAS", "Page 1", in: (0, 0), "!"),
            node(board, "FRAME", "Board", in: page, "!", ["size": size(375, 812), "transform": at(0, 0), "fillPaints": [solid(1, 1, 1)]]),
            node((1, 2), "TEXT", "Rich", in: board, "!", [
                "size": size(200, 120), "transform": at(20, 40), "fillPaints": [solid(0, 0, 0)], "fontName": helvetica, "fontSize": 20.0,
                "textAutoResize": "NONE", "textAlignHorizontal": "JUSTIFIED", "textAlignVertical": "CENTER", "paragraphSpacing": 8.0,
                "textData": [
                    "characters": "Hello bold world\nsecond", "characterStyleIDs": Array(repeating: 0, count: 6) + Array(repeating: 1, count: 4),
                    "styleOverrideTable": [["styleID": 1, "fontName": ["family": "Helvetica", "style": "Bold", "postscript": "Helvetica-Bold"],
                                            "fillPaints": [solid(1, 0, 0)], "textDecoration": "STRIKETHROUGH"]],
                    "lines": [["lineType": "UNORDERED_LIST"], ["lineType": "PLAIN"]],
                ],
            ]),
            node((1, 3), "TEXT", "Mostly", in: board, "\"", [
                "size": size(150, 40), "transform": at(20, 200), "fillPaints": [solid(0, 0, 0)], "fontName": helvetica, "fontSize": 16.0,
                "textAutoResize": "WIDTH_AND_HEIGHT",
                "textData": [
                    "characters": "ab cdefgh", "characterStyleIDs": [0, 0, 0, 1, 1, 1, 1, 1, 1],
                    "styleOverrideTable": [["styleID": 1, "fontSize": 30.0, "fillPaints": [solid(0, 0, 1)]]],
                    "baselines": [["position": ["x": 0.0, "y": 28.0]]],
                ],
            ]),
            node((1, 4), "TEXT", "Tuned", in: board, "#", [
                "size": size(100, 24), "transform": at(20, 300), "fillPaints": [solid(0, 0, 0)], "fontName": helvetica, "fontSize": 16.0,
                "textAutoResize": "WIDTH_AND_HEIGHT", "textCase": "SMALL_CAPS", "toggledOnOTFeatures": ["SS01", "TNUM"],
                "fontVariations": [["axisTag": 0x7767_6874, "axisName": "Weight", "value": 600.0]],
                "textData": ["characters": "Figures 0123"],
            ]),
        ]
        return ["nodeChanges": nodes, "blobs": [] as [Any]]
    }

    @Test func bringsStyledLettersAcross() throws {
        let zip = TestZip.make([("canvas.fig", TestKiwi.canvas(Self.lettersMessage())), ("meta.json", Data("{}".utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).fig")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try FigmaImporter.read(url)
        func named(_ name: String) throws -> Node { try #require(imported.document.allNodes.first { $0.name == name }) }
        // Nothing of them is left out or set otherwise.
        #expect(imported.report.notes.isEmpty)

        // The word keeps its own face, colour and line; the first paragraph is an item of a list.
        let rich = try named("Rich")
        #expect(rich.text == "Hello bold world\nsecond")
        #expect(rich.style?.family == "Helvetica" && rich.style?.face == "Regular" && rich.style?.size == 20 && rich.fill.color.hex == "000000")
        let runs = rich.runs
        #expect(runs.map(\.text) == ["Hello ", "bold", " world\n", "second"])
        #expect(runs[1].look.face == "Bold" && runs[1].look.color?.hex == "FF0000" && runs[1].look.strikethrough == true)
        #expect(runs[1].look.family == nil && runs[1].look.size == nil && runs[1].look.underline == nil)
        #expect(runs.map(\.look.list) == [TextList.bullet, .bullet, .bullet, nil])
        #expect(runs[0].look == TextLook(list: .bullet) && runs[3].look.isPlain)
        // Justified, with room after each paragraph, its lines in the middle of the box it keeps.
        #expect(rich.style?.align == .justify && rich.style?.paragraphSpacing == 8)
        #expect(rich.style?.sizing == .fixed && rich.style?.vertical == .middle)
        #expect(rich.frame == CGRect(x: 20, y: 40, width: 200, height: 120))

        // Most of its letters are big and blue, so the layer is; the rest are small and black,
        // and the first baseline is still where Figma put it.
        let mostly = try named("Mostly")
        #expect(mostly.style?.size == 30 && mostly.fill.color.hex == "0000FF")
        #expect(mostly.runs.map(\.text) == ["ab ", "cdefgh"])
        #expect(mostly.runs[0].look.size == 16 && mostly.runs[0].look.color?.hex == "000000" && mostly.runs[1].look.isPlain)
        #expect(abs(mostly.frame.minY + TextLayout.firstBaseline(mostly) - 228) < 0.5)

        let tuned = try named("Tuned")
        #expect(tuned.style?.letterCase == .smallCaps && tuned.spans == nil)
        #expect(tuned.style?.features == ["ss01": 1, "tnum": 1] && tuned.style?.axes == ["wght": 600])
    }

    /// A grid of Figma's: its kind, axis, number of bands and their sizes.
    static func grid(_ type: String, _ axis: String, count: Int, offset: Double = 0, section: Double = 0, gutter: Double = 0,
                     pattern: String = "STRIPES", visible: Bool = true) -> [String: Any] {
        ["type": type, "axis": axis, "visible": visible, "numSections": count, "offset": offset, "sectionSize": section, "gutterSize": gutter,
         "pattern": pattern]
    }

    /// Masks, layout grids, guides and paints laid over one another: an artboard filled with two
    /// colours and laid out on columns, baselines and a square grid, with guides; one filled with a
    /// colour and a gradient, on centred columns; a group that is a mask; a frame whose layer fits
    /// inside it; a text with a word in capitals and its own line height, in two paints; and a
    /// mask lying right on the page.
    static func helpersMessage() -> [String: Any] {
        let page = (0, 1), board = (1, 1), second = (2, 1)
        let red = solid(1, 0, 0), halfBlue = solid(0, 0, 1, 0.5)
        let gradient: [String: Any] = ["type": "GRADIENT_LINEAR", "opacity": 1.0, "visible": true, "transform": at(0, 0),
                                       "stops": [["color": ["r": 1.0, "g": 1.0, "b": 0.0, "a": 1.0], "position": 0.0],
                                                 ["color": ["r": 0.0, "g": 1.0, "b": 0.0, "a": 1.0], "position": 1.0]]]
        let nodes: [[String: Any]] = [
            ["guid": guid(0, 0), "type": "DOCUMENT", "name": "Document"],
            node(page, "CANVAS", "Page 1", in: (0, 0), "!", ["guides": [["axis": "X", "offset": 10.0]]]),
            node(board, "FRAME", "Board", in: page, "!", [
                "size": size(375, 812), "transform": at(0, 0), "fillPaints": [red, halfBlue],
                "layoutGrids": [grid("STRETCH", "X", count: 4, offset: 16, gutter: 16),
                                grid("MIN", "Y", count: Int(Int32.max), section: 8),
                                grid("STRETCH", "X", count: 12, pattern: "GRID"),
                                grid("STRETCH", "X", count: 12, visible: false)],
                "guides": [["axis": "X", "offset": 24.0], ["axis": "Y", "offset": 100.0], ["axis": "X", "offset": 351.0]],
            ]),
            node((1, 2), "FRAME", "Pair", in: board, "!", ["resizeToFit": true, "mask": true, "size": size(50, 20), "transform": at(10, 10)]),
            node((1, 3), "RECTANGLE", "A", in: (1, 2), "!", ["size": size(20, 20), "transform": at(0, 0), "fillPaints": [red]]),
            node((1, 4), "RECTANGLE", "B", in: (1, 2), "\"", ["size": size(20, 20), "transform": at(30, 0), "fillPaints": [red]]),
            node((1, 5), "RECTANGLE", "Under", in: board, "\"", ["size": size(60, 20), "transform": at(5, 10), "fillPaints": [halfBlue]]),
            node((1, 6), "FRAME", "Fits", in: board, "#", ["size": size(100, 100), "transform": at(100, 100), "fillPaints": [red],
                                                          "layoutGrids": [grid("STRETCH", "X", count: 2, gutter: 10)]]),
            node((1, 7), "RECTANGLE", "Inside", in: (1, 6), "!", ["size": size(10, 10), "transform": at(10, 10), "fillPaints": [halfBlue]]),
            node((1, 9), "FRAME", "Rounded", in: board, "%", ["size": size(100, 100), "transform": at(200, 400), "cornerRadius": 16.0]),
            node((1, 10), "RECTANGLE", "Filling", in: (1, 9), "!", ["size": size(100, 100), "transform": at(0, 0), "fillPaints": [red]]),
            node((1, 8), "TEXT", "Mixed", in: board, "$", [
                "size": size(200, 24), "transform": at(20, 300), "fillPaints": [solid(1, 1, 1), solid(0, 0, 0, 0.5)],
                "fontName": helvetica, "fontSize": 16.0, "textAutoResize": "WIDTH_AND_HEIGHT",
                "textData": ["characters": "Hello new world", "characterStyleIDs": Array(repeating: 0, count: 6) + [1, 1, 1],
                             "styleOverrideTable": [["styleID": 1, "textCase": "UPPER", "lineHeight": ["value": 30.0, "units": "PIXELS"]]]],
            ]),
            node(second, "FRAME", "Second", in: page, "\"", [
                "size": size(300, 200), "transform": at(500, 0), "fillPaints": [red, gradient],
                "layoutGrids": [grid("CENTER", "X", count: 2, section: 100, gutter: 20)],
            ]),
            node((2, 2), "RECTANGLE", "Content", in: second, "!", ["size": size(10, 10), "transform": at(10, 10), "fillPaints": [halfBlue]]),
            node((2, 3), "RECTANGLE", "Ringed", in: second, "\"", ["size": size(40, 40), "transform": at(50, 50), "strokePaints": [gradient],
                                                                  "strokeWeight": 4.0]),
            node((2, 4), "TEXT", "Glow", in: second, "#", [
                "size": size(100, 24), "transform": at(20, 120), "fillPaints": [gradient], "fontName": helvetica, "fontSize": 20.0,
                "textAutoResize": "WIDTH_AND_HEIGHT", "textData": ["characters": "Glowing"],
            ]),
            node((3, 1), "ELLIPSE", "Porthole", in: page, "#", ["mask": true, "size": size(50, 50), "transform": at(1000, 0), "fillPaints": [red]]),
            node((3, 2), "RECTANGLE", "Seen", in: page, "$", ["size": size(100, 100), "transform": at(1000, 0), "fillPaints": [halfBlue]]),
        ]
        return ["nodeChanges": nodes, "blobs": [] as [Any]]
    }

    @Test func bringsMasksGridsAndPaintsAcross() throws {
        let zip = TestZip.make([("canvas.fig", TestKiwi.canvas(Self.helpersMessage())), ("meta.json", Data("{}".utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).fig")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try FigmaImporter.read(url)
        let doc = imported.document, notes = imported.report.notes
        func named(_ name: String) throws -> Node { try #require(doc.allNodes.first { $0.name == name }) }

        // Two colours over one another are the one colour they make: red under half a blue.
        let board = try named("Board")
        #expect(board.fill.on && board.fill.color.hex == "800080" && board.children.first?.name != "Background")
        // Its columns stretch between their margins; rows that touch are baselines; the square
        // grid and the hidden one are left out.
        #expect(board.layout?.columns == LayoutGrid.Track(count: 4, gutter: 16, margin: 16))
        #expect(board.layout?.baseline == LayoutGrid.Baseline(step: 8, offset: 0) && board.layout?.rows == nil)
        #expect(notes["Square grids, left out"] == 1 && notes["Further layout grids of the same kind, left out"] == nil)
        // Guides near an edge keep to it.
        let guides = board.sortedGuides().map(\.guide)
        #expect(guides == [Guideline(vertical: true, edge: .start, offset: 24), Guideline(vertical: true, edge: .end, offset: 24),
                           Guideline(vertical: false, edge: .start, offset: 100)])
        #expect(notes["Guides on the canvas, left out"] == 1)

        // A colour and a gradient need a layer of their own under what the artboard holds.
        let second = try named("Second")
        #expect(!second.fill.on && second.children.map(\.name) == ["Background", "Content", "Ringed", "Glow"] && second.children[0].fills.count == 2)

        // Borders and letters are painted with the gradient itself.
        let ringed = try named("Ringed"), glow = try named("Glow")
        #expect(ringed.border.on && ringed.border.gradient?.stops.count == 2 && ringed.border.color.hex == "FFFF00")
        #expect(glow.fill.gradient?.kind == .linear && glow.fill.color.hex == "FFFF00" && glow.spans == nil)
        #expect(notes["Texts filled with a gradient, in its first colour"] == nil && notes["Borders drawn with a gradient, in its first colour"] == nil)
        #expect(second.layout?.columns == LayoutGrid.Track(count: 2, gutter: 20, margin: 40))

        // A group that is a mask cuts by an outline round both its layers, and shows nothing itself;
        // as in Figma, it cuts off every layer above it in its frame.
        let pairMask = try #require(doc.allNodes.first { $0.isMask && $0.children.first?.name == "Pair" })
        #expect(pairMask.name == "Mask 1" && pairMask.children.map(\.name) == ["Pair", "Under", "Fits", "Mixed", "Rounded"])
        let holder = pairMask.children[0]
        #expect(holder.kind == .path && holder.fills.isEmpty && pairMask.frame == CGRect(x: 10, y: 10, width: 50, height: 20))
        let outline = Renderer.outline(of: holder)
        #expect(outline.contains(CGPoint(x: 10, y: 10)) && !outline.contains(CGPoint(x: 25, y: 10)) && outline.contains(CGPoint(x: 40, y: 10)))

        // A frame its layer fits in cuts off nothing, so it is a group as any other; its grid has
        // nowhere to go.
        let fits = try named("Fits")
        #expect(!fits.isMask && fits.mask == nil && fits.children.map(\.name) == ["Background", "Inside"])
        #expect(notes["Layout grids on frames inside frames, left out"] == 1)
        // One its layer fills to the edge cuts off that layer's corners, so it is a mask, its
        // outline clear as the frame has no fill.
        let rounded = try named("Rounded")
        #expect(rounded.isMask && rounded.children.map(\.name) == ["Edge", "Filling"])
        #expect(rounded.children[0].cornerRadius == 16 && rounded.children[0].fills.isEmpty)

        // The word in capitals keeps them, written into its letters; the paints come to grey.
        let mixed = try named("Mixed")
        #expect(mixed.text == "Hello NEW world" && mixed.style?.letterCase == nil && mixed.fill.color.hex == "808080")
        #expect(notes["Texts with several line or paragraph spacings, spaced as their main part"] == 1)
        #expect(notes["Layers with several fills, keeping the top one"] == nil)

        // A mask right on the page cuts off what lies over it there.
        let porthole = try #require(doc.nodes.first { $0.isMask })
        #expect(porthole.children.map(\.name) == ["Porthole", "Seen"] && porthole.children[0].kind == .ellipse)
        #expect(porthole.frame.size == CGSize(width: 50, height: 50))
    }

    @Test func writesTheDesignWithItsPictures() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (design, report) = try Importer.importFile(url, into: folder)
        #expect(report.source == "Figma")
        #expect(DesignFile.isPackage(design))
        #expect(try DesignFile.read(design).artboards.count == 1)
        let picture = design.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("abcd.png")
        #expect(try Data(contentsOf: picture) == Self.png())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func readsTheDesignOnItsOwnAsOlderCopiesAre() throws {
        // Without an archive round it, only the pictures are missing.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).fig")
        try TestKiwi.canvas(Self.message()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try FigmaImporter.read(url)
        #expect(imported.archive == nil && imported.document.artboards.count == 1)
        #expect(imported.report.notes["Pictures missing from the Figma file"] == 1)
    }

    @Test func aDamagedOrForeignFileFailsRatherThanStopping() throws {
        let whole = TestKiwi.message(Self.message())
        // Cut short anywhere, the message throws; it never traps.
        for cut in stride(from: 0, to: whole.count, by: max(whole.count / 40, 1)) {
            #expect(throws: (any Error).self) { try FigmaImporter.message(TestKiwi.canvas([:], message: whole.prefix(cut))) }
        }
        #expect(throws: (any Error).self) { try FigmaImporter.message(Data("not a figma file at all".utf8)) }
        let zip = TestZip.make([("document.json", Data("{}".utf8))], deflate: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).fig")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FigmaImporter.Failure.self) { try FigmaImporter.read(url) }
    }

    @Test func kiwiReadsWhatItsSchemaSays() throws {
        let schema = try Kiwi.Schema(TestKiwi.schemaData())
        let message = try schema.read(TestKiwi.message(["nodeChanges": [["name": "A", "opacity": 0.25, "size": ["x": -3.5, "y": 1e6]]]]), as: "Message")
        let node = try #require(message["nodeChanges"]?.objects.first)
        #expect(node["name"]?.string == "A" && node["opacity"]?.number == 0.25)
        #expect(node["size"]?.object?["x"]?.number == -3.5 && node["size"]?.object?["y"]?.number == 1e6)
        #expect(node["type"] == nil)
        let merged = node.merged(with: node.setting("name", .string("B")))
        #expect(merged["name"]?.string == "B" && merged["opacity"]?.number == 0.25)
    }
}
