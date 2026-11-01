import Testing
import AppKit
@testable import Bezzle

@MainActor
struct SketchImportTests {
    static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> String {
        #"{"_class":"color","red":\#(r),"green":\#(g),"blue":\#(b),"alpha":\#(a)}"#
    }

    static let red = color(1, 0, 0), blue = color(0, 0, 1), gray = color(0.5, 0.5, 0.5)

    static func fill(_ c: String) -> String { #"{"_class":"fill","isEnabled":true,"fillType":0,"color":\#(c)}"# }

    /// A rectangle's four points, each with its corner radius: top left, top right, bottom right, bottom left.
    static func corners(_ r: [Double]) -> String {
        let at = ["{0, 0}", "{1, 0}", "{1, 1}", "{0, 1}"]
        return "[" + at.enumerated().map { i, p in
            #"{"_class":"curvePoint","cornerRadius":\#(r[i]),"curveFrom":"\#(p)","curveTo":"\#(p)","curveMode":1,"hasCurveFrom":false,"hasCurveTo":false,"point":"\#(p)"}"#
        }.joined(separator: ",") + "]"
    }

    static func rectangle(_ name: String, _ frame: String, style: String = "{}", extra: String = "") -> String {
        #"{"_class":"rectangle","name":"\#(name)","frame":\#(frame),"style":\#(style),"points":\#(corners([0, 0, 0, 0])),"isClosed":true\#(extra)}"#
    }

    static func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
        #"{"_class":"rect","x":\#(x),"y":\#(y),"width":\#(w),"height":\#(h)}"#
    }

    static func text(_ name: String, _ words: String, _ frame: String, font: String, size: Double, behaviour: Int, attributes: String = "", id: String = "") -> String {
        let run = #"{"MSAttributedStringFontAttribute":{"_class":"fontDescriptor","attributes":{"name":"\#(font)","size":\#(size)}},"MSAttributedStringColorAttribute":\#(red)\#(attributes)}"#
        return #"{"_class":"text","do_objectID":"\#(id)","name":"\#(name)","frame":\#(frame),"textBehaviour":\#(behaviour),"style":{"textStyle":{"encodedAttributes":\#(run)}},"attributedString":{"_class":"attributedString","string":"\#(words)","attributes":[{"_class":"stringAttribute","location":0,"length":\#(words.count),"attributes":\#(run)}]}}"#
    }

    /// A small picture, for the bitmap layer.
    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A small Sketch file. On the first page, an artboard with a card, a turned group, a flipped
    /// shape, two texts, a mask, a combined shape, a symbol instance and a picture, and a loose
    /// oval beside it; on the second, one loose square; and a page of symbols that the instance
    /// shows, so it is left out.
    static func file() throws -> URL {
        let card = rectangle("Card", frame(16, 20, 100, 40), style: """
            {"fills":[\(fill(red))],"borders":[{"_class":"border","isEnabled":true,"fillType":0,"color":\(blue),"position":1,"thickness":2}],
             "shadows":[{"_class":"shadow","isEnabled":true,"offsetX":0,"offsetY":3,"blurRadius":6,"spread":0,"color":\(color(0, 0, 0, 0.2))}]}
            """).replacingOccurrences(of: corners([0, 0, 0, 0]), with: corners([4, 8, 4, 8]))
        let spun = #"{"_class":"group","name":"Spun","frame":\#(frame(300, 400, 60, 10)),"rotation":90,"layers":[\#(rectangle("Bar", frame(0, 0, 60, 10), style: "{\"fills\":[\(fill(blue))]}"))]}"#
        let flipped = rectangle("Flipped", frame(16, 100, 80, 40), style: """
            {"fills":[{"_class":"fill","isEnabled":true,"fillType":1,"color":\(red),"gradient":{"_class":"gradient","gradientType":0,"from":"{0.5, 0}","to":"{0.5, 1}",
              "stops":[{"_class":"gradientStop","position":0,"color":\(red)},{"_class":"gradientStop","position":1,"color":\(blue)}]}}]}
            """, extra: #","isFlippedVertical":true"#).replacingOccurrences(of: corners([0, 0, 0, 0]), with: corners([10, 0, 0, 0]))
        let hello = text("Hello", "Hello", frame(20, 200, 60, 24), font: "Helvetica-Bold", size: 20, behaviour: 0,
                         attributes: #","kerning":1,"MSAttributedStringTextTransformAttribute":1"#)
        let note = text("Note", "Two lines of words", frame(20, 300, 150, 60), font: "Helvetica", size: 16, behaviour: 1,
                        attributes: #","paragraphStyle":{"_class":"paragraphStyle","alignment":2,"maximumLineHeight":30,"minimumLineHeight":30}"#)
        let masked = """
            {"_class":"group","name":"Masked","frame":\(frame(0, 500, 300, 300)),"layers":[
              {"_class":"oval","name":"Round","frame":\(frame(0, 0, 100, 100)),"hasClippingMask":true,"style":{"fills":[\(fill(gray))]}},
              \(rectangle("Big", frame(0, 0, 200, 200), style: "{\"fills\":[\(fill(blue))]}")),
              \(rectangle("Free", frame(150, 150, 20, 20), style: "{\"fills\":[\(fill(red))]}", extra: #","shouldBreakMaskChain":true"#))]}
            """
        let combined = """
            {"_class":"shapeGroup","name":"Combined","frame":\(frame(200, 300, 100, 100)),"style":{"windingRule":1,"fills":[\(fill(blue))]},"layers":[
              \(rectangle("A", frame(0, 0, 100, 100), extra: #","booleanOperation":-1"#)),
              {"_class":"oval","name":"B","frame":\(frame(25, 25, 50, 50)),"booleanOperation":1,"isClosed":true}]}
            """
        let instance = #"{"_class":"symbolInstance","name":"Button","frame":\#(frame(16, 700, 200, 44)),"symbolID":"S1","overrideValues":[{"_class":"overrideValue","overrideName":"T1_stringValue","value":"Go"}]}"#
        let photo = #"{"_class":"bitmap","name":"Photo","frame":\#(frame(200, 600, 40, 30)),"image":{"_class":"MSJSONFileReference","_ref_class":"MSImageData","_ref":"images/abc.png"},"exportOptions":{"_class":"exportOptions","exportFormats":[{"_class":"exportFormat","absoluteSize":0,"fileFormat":"png","name":"","namingScheme":0,"scale":1,"visibleScaleType":0},{"_class":"exportFormat","absoluteSize":0,"fileFormat":"png","name":"@2x","namingScheme":0,"scale":2,"visibleScaleType":0},{"_class":"exportFormat","absoluteSize":512,"fileFormat":"webp","name":"-big","namingScheme":0,"scale":1,"visibleScaleType":1},{"_class":"exportFormat","absoluteSize":0,"fileFormat":"eps","name":"","namingScheme":0,"scale":1,"visibleScaleType":0}]}}"#
        let board = """
            {"_class":"artboard","name":"Board","frame":\(frame(100, 50, 375, 812)),"hasBackgroundColor":true,"backgroundColor":\(color(0, 0, 0)),
             "layers":[\([card, spun, flipped, hello, note, masked, combined, instance, photo].joined(separator: ","))]}
            """
        let loose = #"{"_class":"oval","name":"Loose","frame":\#(frame(600, 0, 50, 50)),"style":{"fills":[\#(fill(red))]}}"#
        let first = #"{"_class":"page","name":"Page 1","layers":[\#(loose),\#(board)]}"#
        let second = #"{"_class":"page","name":"Second","layers":[\#(rectangle("Below", frame(0, 0, 50, 50), style: "{\"fills\":[\(fill(red))]}"))]}"#
        let label = text("Label", "Label", frame(10, 10, 80, 20), font: "Helvetica", size: 14, behaviour: 1,
                         attributes: #","paragraphStyle":{"_class":"paragraphStyle","alignment":2}"#, id: "T1")
            .replacingOccurrences(of: #""_class":"text","#, with: #""_class":"text","resizingConstraint":58,"#)
        let master = """
            {"_class":"symbolMaster","name":"Button Master","symbolID":"S1","frame":\(frame(0, 0, 100, 40)),"layers":[
              \(rectangle("Fill", frame(0, 0, 100, 40), style: "{\"fills\":[\(fill(gray))]}")),\(label)]}
            """
        let symbols = #"{"_class":"page","name":"Symbols","layers":[\#(master)]}"#
        let document = #"{"_class":"document","colorSpace":1,"pages":[{"_ref":"pages/P1"},{"_ref":"pages/P2"},{"_ref":"pages/P3"}]}"#
        let zip = TestZip.make([("document.json", Data(document.utf8)), ("meta.json", Data(#"{"appVersion":"70","version":136}"#.utf8)),
                                ("pages/P1.json", Data(first.utf8)), ("pages/P2.json", Data(second.utf8)), ("pages/P3.json", Data(symbols.utf8)),
                                ("images/abc.png", png())], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try zip.write(to: url)
        return url
    }

    @Test func bringsASketchFileAcross() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try SketchImporter.read(url)
        let doc = imported.document
        func named(_ name: String) throws -> Node { try #require(doc.allNodes.first { $0.name == name }) }
        // The symbols page is only masters the instance shows, so it is left out.
        #expect(imported.report.artboards == 1)
        #expect(imported.report.notes.isEmpty)

        let board = try named("Board")
        #expect(doc.nodes.first?.id == board.id)
        #expect(board.frame == CGRect(x: 100, y: 50, width: 375, height: 812))
        #expect(board.fill.on && board.fill.color.hex == "000000")

        let card = try named("Card")
        #expect(card.kind == .rectangle && card.frame == CGRect(x: 16, y: 20, width: 100, height: 40))
        #expect(card.corners == [4, 8, 4, 8])
        #expect(card.fill.color.hex == "FF0000")
        #expect(card.border.on && card.border.width == 2 && card.border.position == .inside && card.border.color.hex == "0000FF")
        #expect(card.shadow.on && card.shadow.y == 3 && card.shadow.blur == 6 && abs(card.shadow.color.a - 0.2) < 0.001)

        // Sketch turns anticlockwise; the group's turn goes to what it holds, about the group's middle.
        let bar = try named("Bar"), spun = try named("Spun")
        #expect(bar.rotation == -90)
        #expect(doc.absoluteFrame(of: bar.id).map { CGPoint(x: $0.midX, y: $0.midY) } == CGPoint(x: 430, y: 455))
        #expect(spun.rotation == 0 && spun.frame.size.width.rounded() == 10 && spun.frame.size.height.rounded() == 60)

        // Turned over top to bottom: its rounded corner and its gradient go with it.
        let flipped = try named("Flipped")
        #expect(flipped.frame == CGRect(x: 16, y: 100, width: 80, height: 40) && flipped.rotation == 0)
        #expect(flipped.corners == [0, 0, 0, 10])
        #expect(flipped.fill.gradient?.start == CGPoint(x: 0.5, y: 1) && flipped.fill.gradient?.end == CGPoint(x: 0.5, y: 0))

        // A text as wide as its words, its box where Sketch's is.
        let hello = try named("Hello")
        #expect(hello.kind == .text && hello.text == "Hello")
        #expect(hello.style?.family == "Helvetica" && hello.style?.face == "Bold" && hello.style?.size == 20)
        #expect(hello.style?.tracking == 50 && hello.style?.letterCase == .upper && hello.style?.sizing == .autoWidth)
        #expect(hello.frame.origin == CGPoint(x: 20, y: 200))
        // A text of fixed width, centred, its line height set: its first baseline where Sketch's is,
        // the line's room all above the letters.
        let note = try named("Note")
        #expect(note.style?.sizing == .autoHeight && note.style?.align == .center && note.style?.lineSpacing == 30)
        #expect(note.frame.minX == 20 && note.frame.width == 150)
        let descent = Fonts.font(note.style ?? TextStyle()).descender
        #expect(abs(note.frame.minY + TextLayout.firstBaseline(note) - (300 + 30 + descent)) < 0.6)

        // The mask cuts off the layer above it, up to the one that breaks the chain, and is drawn
        // under it: a mask of Bezzle's, its circle the shape that holds the rest.
        let masks = try #require(doc.allNodes.first { $0.isMask && $0.children.first?.name == "Round" })
        #expect(masks.mask == nil && masks.name == "Mask 1" && masks.children[0].kind == .ellipse)
        #expect(masks.children[0].fill.on && masks.children[0].fill.color.hex == "808080")
        #expect(doc.absoluteFrame(of: masks.id) == CGRect(x: 100, y: 550, width: 100, height: 100))
        #expect(masks.children.map(\.name) == ["Round", "Big"])
        #expect(doc.parent(of: try named("Free").id)?.name == "Masked")

        // A square less a circle is one path, its hole cut out.
        let combined = try named("Combined")
        #expect(combined.kind == .path && combined.frame == CGRect(x: 200, y: 300, width: 100, height: 100) && combined.evenOdd == true)
        let outline = PathData.cgPath(try #require(combined.path))
        #expect(outline.contains(CGPoint(x: 10, y: 10), using: .evenOdd) && !outline.contains(CGPoint(x: 50, y: 50), using: .evenOdd))

        // The instance is its master's layers, laid out at its size as their constraints say, with its own words.
        let button = try named("Button")
        #expect(button.isGroup && button.frame == CGRect(x: 16, y: 700, width: 200, height: 44))
        #expect(button.children.first { $0.name == "Fill" }?.frame == CGRect(x: 0, y: 0, width: 200, height: 44))
        let label = try #require(button.children.first { $0.name == "Label" })
        #expect(label.text == "Go" && label.frame.minX == 10 && label.frame.width == 180 && label.style?.align == .center)

        let photo = try named("Photo")
        #expect(photo.kind == .rectangle && photo.fill.image?.asset == "abc.png" && photo.fill.image?.size == CGSize(width: 4, height: 3))
        #expect(photo.fill.image?.mode == .stretch && imported.pictures["abc.png"] == "images/abc.png")
        // Marked for export as it was, and what Bezzle does not write, as a PNG.
        #expect(photo.exports == [ExportPreset(), ExportPreset(size: .scale(2)), ExportPreset(size: .width(512), format: .webp, suffix: "-big"), ExportPreset()])
        #expect(card.exports == nil)

        // The second page lies under the first, lined up on its left.
        #expect(try named("Loose").frame == CGRect(x: 600, y: 0, width: 50, height: 50))
        #expect(try named("Below").frame == CGRect(x: 100, y: 862 + 800, width: 50, height: 50))
    }

    /// One run of a text's words, in a font and colour, and with what else it says.
    static func run(_ location: Int, _ length: Int, font: String, size: Double, color c: String, _ more: String = "") -> String {
        #"{"_class":"stringAttribute","location":\#(location),"length":\#(length),"attributes":{"MSAttributedStringFontAttribute":{"_class":"fontDescriptor","attributes":{"name":"\#(font)","size":\#(size)}},"MSAttributedStringColorAttribute":\#(c)\#(more)}}"#
    }

    /// A page of texts whose letters differ, as Sketch keeps them: one with a word in bold and red,
    /// underlined and spaced out, and one struck through, justified at the foot of its box; and one
    /// with big letters and small, its line height set.
    static func lettersFile() throws -> URL {
        let paragraph = #","paragraphStyle":{"_class":"paragraphStyle","alignment":3,"paragraphSpacing":12},"textStyleVerticalAlignmentKey":2"#
        let rich = #"{"_class":"text","name":"Rich","frame":\#(frame(20, 400, 300, 200)),"textBehaviour":2,"style":{},"attributedString":{"_class":"attributedString","string":"Hard coded colors\nstruck","attributes":["#
            + [run(0, 5, font: "Helvetica", size: 24, color: blue, paragraph),
               run(5, 5, font: "Helvetica-Bold", size: 24, color: red, #","underlineStyle":1,"kerning":2.4"# + paragraph),
               run(10, 8, font: "Helvetica", size: 24, color: blue, paragraph),
               run(18, 6, font: "Helvetica", size: 24, color: blue, #","strikethroughStyle":1"# + paragraph)].joined(separator: ",") + "]}}"
        let line = #","paragraphStyle":{"_class":"paragraphStyle","maximumLineHeight":50,"minimumLineHeight":50}"#
        let mixed = #"{"_class":"text","name":"Mixed","frame":\#(frame(20, 650, 200, 50)),"textBehaviour":0,"style":{},"attributedString":{"_class":"attributedString","string":"Big small","attributes":["#
            + [run(0, 4, font: "Helvetica", size: 40, color: gray, line), run(4, 5, font: "Helvetica", size: 16, color: gray, line)].joined(separator: ",") + "]}}"
        let page = #"{"_class":"page","name":"Page 1","layers":[\#(rich),\#(mixed)]}"#
        let document = #"{"_class":"document","colorSpace":1,"pages":[{"_ref":"pages/P1"}]}"#
        let zip = TestZip.make([("document.json", Data(document.utf8)), ("meta.json", Data(#"{"appVersion":"70","version":136}"#.utf8)),
                                ("pages/P1.json", Data(page.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try zip.write(to: url)
        return url
    }

    @Test func bringsStyledLettersAcross() throws {
        let url = try Self.lettersFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try SketchImporter.read(url)
        func named(_ name: String) throws -> Node { try #require(imported.document.allNodes.first { $0.name == name }) }
        #expect(imported.report.notes.isEmpty)

        let rich = try named("Rich")
        #expect(rich.text == "Hard coded colors\nstruck")
        #expect(rich.style?.family == "Helvetica" && rich.style?.face == "Regular" && rich.style?.size == 24 && rich.fill.color.hex == "0000FF")
        let runs = rich.runs
        #expect(runs.map(\.text) == ["Hard ", "coded", " colors\n", "struck"])
        #expect(runs[1].look.face == "Bold" && runs[1].look.color?.hex == "FF0000" && runs[1].look.underline == true && runs[1].look.tracking == 100)
        #expect(runs[1].look.family == nil && runs[1].look.size == nil && runs[1].look.strikethrough == nil)
        #expect(runs[0].look.isPlain && runs[2].look.isPlain && runs[3].look == TextLook(strikethrough: true))
        // Justified, with room after each paragraph, its lines at the foot of the box it keeps.
        #expect(rich.style?.align == .justify && rich.style?.paragraphSpacing == 12)
        #expect(rich.style?.sizing == .fixed && rich.style?.vertical == .bottom)
        #expect(rich.frame == CGRect(x: 20, y: 400, width: 300, height: 200))

        // Its line height set, Sketch puts the line's room above the letters, the biggest at its foot.
        let mixed = try named("Mixed")
        #expect(mixed.style?.size == 16 && mixed.runs.map(\.text) == ["Big ", "small"] && mixed.runs[0].look.size == 40)
        var big = mixed.style ?? TextStyle()
        big.size = 40
        let descent = Fonts.font(big).descender
        #expect(abs(mixed.frame.minY + TextLayout.firstBaseline(mixed) - (650 + 50 + descent)) < 0.6)
    }

    /// A gradient fill of Sketch's, down its layer from one colour to another.
    static func gradient(_ from: String, _ to: String) -> String {
        #"{"_class":"fill","isEnabled":true,"fillType":1,"color":\#(from),"gradient":{"_class":"gradient","gradientType":0,"from":"{0.5, 0}","to":"{0.5, 1}","stops":[{"_class":"gradientStop","position":0,"color":\#(from)},{"_class":"gradientStop","position":1,"color":\#(to)}]}}"#
    }

    /// Texts with fills over one another: a gradient over a colour it covers; a gradient half
    /// seen through over red; and one half seen through over another.
    static func paintedLettersFile() throws -> URL {
        func painted(_ name: String, _ y: Double, _ fills: [String]) -> String {
            text(name, name, frame(20, y, 100, 24), font: "Helvetica", size: 16, behaviour: 0)
                .replacingOccurrences(of: #""style":{"textStyle""#, with: #""style":{"fills":[\#(fills.joined(separator: ","))],"textStyle""#)
        }
        let yellow = color(1, 1, 0), green = color(0, 1, 0)
        let layers = [painted("Covered", 20, [fill(blue), gradient(red, blue)]),
                      painted("Tinted", 60, [fill(red), gradient(color(1, 1, 0, 0.5), color(0, 1, 0, 0.5))]),
                      painted("Two", 100, [gradient(yellow, green), gradient(color(1, 0, 0, 0.5), color(0, 0, 1, 0.5))])]
        let page = #"{"_class":"page","name":"Page 1","layers":[\#(layers.joined(separator: ","))]}"#
        let document = #"{"_class":"document","colorSpace":1,"pages":[{"_ref":"pages/P1"}]}"#
        let zip = TestZip.make([("document.json", Data(document.utf8)), ("meta.json", Data(#"{"appVersion":"70","version":136}"#.utf8)),
                                ("pages/P1.json", Data(page.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try zip.write(to: url)
        return url
    }

    @Test func paintsLettersWithTheGradientTheirFillsComeTo() throws {
        let url = try Self.paintedLettersFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try SketchImporter.read(url)
        func named(_ name: String) throws -> Node { try #require(imported.document.allNodes.first { $0.name == name }) }
        // Only the two gradients are in a colour.
        #expect(imported.report.notes == ["Texts filled with a gradient, in its first colour": 1])

        // What an opaque gradient covers does not show.
        let covered = try named("Covered")
        #expect(covered.fill.gradient?.stops.map(\.color.hex) == ["FF0000", "0000FF"] && covered.fill.color.hex == "FF0000" && covered.spans == nil)
        // Red under a gradient half seen through is a gradient of the colours they make.
        let tinted = try named("Tinted")
        #expect(tinted.fill.gradient?.stops.map(\.color.hex) == ["FF8000", "808000"] && tinted.spans == nil)
        // Two gradients showing are in the colour their first colours make.
        let two = try named("Two")
        #expect(two.fill.gradient == nil && two.fill.color.hex == "FF8000")
    }

    /// An artboard laid out on Sketch's columns and square grid, with guides out of both rulers, an
    /// alpha mask, a text with a word in capitals, and an artboard inside a group whose layer
    /// reaches past its edge.
    static func helpersFile() throws -> URL {
        let layout = #""layout":{"_class":"layoutGrid","isEnabled":true,"columnWidth":60,"gutterWidth":20,"guttersOutside":false,"horizontalOffset":30,"numberOfColumns":4,"drawVertical":true,"drawHorizontal":false,"gutterHeight":10,"rowHeightMultiplication":3,"totalWidth":300},"grid":{"_class":"simpleGrid","isEnabled":true,"gridSize":8,"thickGridTimes":8}"#
        let rulers = #""horizontalRulerData":{"_class":"rulerData","base":0,"guides":[40,320]},"verticalRulerData":{"_class":"rulerData","base":0,"guides":[100]}"#
        let fade = """
            {"_class":"group","name":"Faded","frame":\(frame(0, 0, 200, 200)),"layers":[
              {"_class":"oval","name":"Fader","frame":\(frame(0, 0, 100, 100)),"hasClippingMask":true,"clippingMaskMode":1,"style":{"fills":[\(fill(gray))]}},
              \(rectangle("Faded picture", frame(0, 0, 200, 200), style: "{\"fills\":[\(fill(blue))]}"))]}
            """
        let words = #"{"_class":"text","name":"Shout","frame":\#(frame(20, 300, 200, 24)),"textBehaviour":0,"style":{},"attributedString":{"_class":"attributedString","string":"Hello new world","attributes":["#
            + [run(0, 6, font: "Helvetica", size: 16, color: blue), run(6, 3, font: "Helvetica", size: 16, color: blue, #","MSAttributedStringTextTransformAttribute":1"#),
               run(9, 6, font: "Helvetica", size: 16, color: blue)].joined(separator: ",") + "]}}"
        let inner = """
            {"_class":"group","name":"Holder","frame":\(frame(0, 400, 200, 200)),"layers":[
              {"_class":"artboard","name":"Inner","frame":\(frame(0, 0, 100, 100)),"hasBackgroundColor":true,"backgroundColor":\(red),"layers":[
                \(rectangle("Spill", frame(50, 50, 100, 100), style: "{\"fills\":[\(fill(blue))]}"))]}]}
            """
        let ring = rectangle("Ring", frame(200, 20, 40, 40), style: """
            {"borders":[{"_class":"border","isEnabled":true,"fillType":1,"color":\(red),"position":0,"thickness":4,"gradient":{"_class":"gradient","gradientType":0,"from":"{0, 0.5}","to":"{1, 0.5}",
              "stops":[{"_class":"gradientStop","position":0,"color":\(red)},{"_class":"gradientStop","position":1,"color":\(blue)}]}}]}
            """)
        let board = #"{"_class":"artboard","name":"Board","frame":\#(frame(0, 0, 360, 800)),\#(layout),\#(rulers),"layers":[\#([fade, words, inner, ring].joined(separator: ","))]}"#
        let page = #"{"_class":"page","name":"Page 1","layers":[\#(board)]}"#
        let document = #"{"_class":"document","colorSpace":1,"pages":[{"_ref":"pages/P1"}]}"#
        let zip = TestZip.make([("document.json", Data(document.utf8)), ("meta.json", Data(#"{"appVersion":"70","version":136}"#.utf8)),
                                ("pages/P1.json", Data(page.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try zip.write(to: url)
        return url
    }

    @Test func bringsMasksGridsAndGuidesAcross() throws {
        let url = try Self.helpersFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try SketchImporter.read(url)
        let doc = imported.document, notes = imported.report.notes
        func named(_ name: String) throws -> Node { try #require(doc.allNodes.first { $0.name == name }) }

        // Four columns of 60 with gutters of 20, 30 in from the left of 360: in the middle, as they were.
        let board = try named("Board")
        #expect(board.layout == LayoutGrid(columns: LayoutGrid.Track(count: 4, gutter: 20, margin: 30), rows: nil, baseline: nil))
        #expect(notes["Square grids, left out"] == 1 && notes["Layout grids with uneven margins, centred"] == nil)
        // The top ruler's guides run down the artboard, the side ruler's across it.
        #expect(board.sortedGuides().map(\.guide) == [Guideline(vertical: true, edge: .start, offset: 40), Guideline(vertical: true, edge: .end, offset: 40),
                                                     Guideline(vertical: false, edge: .start, offset: 100)])

        // An alpha mask is not drawn itself, only cuts.
        let faded = try #require(doc.allNodes.first { $0.isMask && $0.children.first?.name == "Fader" })
        #expect(faded.children[0].fills.isEmpty && faded.children.map(\.name) == ["Fader", "Faded picture"])
        #expect(notes["Alpha masks, cutting by their outline"] == 1)

        let shout = try named("Shout")
        #expect(shout.text == "Hello NEW world" && shout.style?.letterCase == nil)

        // A border is drawn with its gradient, measured on the layer as a fill's is.
        let ring = try named("Ring")
        #expect(ring.border.gradient?.start == CGPoint(x: 0, y: 0.5) && ring.border.gradient?.end == CGPoint(x: 1, y: 0.5))
        #expect(notes["Borders with a gradient, in its first colour"] == nil)

        // An artboard in a group cuts off what reaches past its edge, its background the shape
        // that holds it.
        let inner = try #require(doc.allNodes.first { $0.isMask && $0.children.contains { $0.name == "Spill" } })
        #expect(inner.children.map(\.name) == ["Background", "Spill"] && inner.children[0].fill.color.hex == "FF0000")
        #expect(doc.absoluteFrame(of: inner.id) == CGRect(x: 0, y: 400, width: 100, height: 100))
    }

    @Test func writesTheDesignAsAPackage() throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (design, report) = try Importer.importFile(url, into: folder)
        #expect(report.source == "Sketch")
        #expect(DesignFile.isPackage(design))
        #expect(try DesignFile.read(design).artboards.count == 1)
        let picture = design.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("abc.png")
        #expect(try Data(contentsOf: picture) == Self.png())
    }

    @Test func turnsAwayWhatItCannotRead() throws {
        let folder = FileManager.default.temporaryDirectory
        // Files from before Sketch 43 are a database, and need saving again in a newer Sketch.
        let old = folder.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try Data("SQLite format 3\u{0}and the rest".utf8).write(to: old)
        defer { try? FileManager.default.removeItem(at: old) }
        #expect(throws: SketchImporter.Failure.tooOld) { try SketchImporter.read(old) }
        let other = folder.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try TestZip.make([("hello.txt", Data("hello".utf8))], deflate: false).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(throws: SketchImporter.Failure.notSketch) { try SketchImporter.read(other) }
    }
}
