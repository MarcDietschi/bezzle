import Testing
import AppKit
import ImageIO
@testable import Bezzle

// MARK: - Helpers

/// Pages for the web importer: read by WebKit from HTML, or written by hand as the page reader
/// hands them over.
@MainActor
enum WebTest {
    static let size = WebCapture.Size(name: "Desktop", width: 800, height: 600)

    /// A page as the page reader writes it, around `root`.
    static func page(_ root: String, w: Double = 800, h: Double = 600, images: [String] = [], bg: String = "[1,1,1,1]", notes: String = "{}") throws -> WebPage {
        let list = images.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"url":"https://example.com/","title":"Test page","w":\#(w),"vh":\#(h),"h":\#(h),"bg":{"c":\#(bg)},"root":\#(root),"images":[\#(list)],"notes":\#(notes)}"#
        return try JSONDecoder().decode(WebPage.self, from: Data(json.utf8))
    }

    /// An <html> holding `kids`.
    static func html(_ kids: String...) -> String {
        #"{"t":"el","id":0,"tag":"html","x":0,"y":0,"w":800,"h":600,"ins":[0,0,0,0,0,0,0,0],"kids":[\#(kids.joined(separator: ","))]}"#
    }

    static func convert(_ page: WebPage, assets: WebAssets = WebAssets()) -> (BezzleDocument, ImportReport) {
        WebConverter.document([WebRead(name: "Desktop", page: page, assets: assets)], source: "example.com")
    }

    /// Reads HTML as Bezzle reads a web page.
    static func read(_ body: String, css: String = "", size: WebCapture.Size = WebTest.size, maxHeight: CGFloat = 30_000) async throws -> (WebRead, [String: Data]) {
        let capture = WebCapture()
        capture.stepDelay = 10
        capture.maxHeight = maxHeight
        defer { capture.close() }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>body { margin: 0; font-family: Helvetica; } \(css)</style></head>
        <body>\(body)</body></html>
        """
        return try await capture.read(html: html, base: nil, size: size)
    }

    /// The design a page read makes.
    static func design(_ body: String, css: String = "", size: WebCapture.Size = WebTest.size) async throws -> (BezzleDocument, ImportReport, WebRead) {
        let (read, _) = try await read(body, css: css, size: size)
        let (doc, report) = WebConverter.document([read], source: "test")
        return (doc, report, read)
    }

    /// Every item of a page, depth first.
    static func items(_ page: WebPage) -> [WebItem] {
        var out: [WebItem] = []
        func walk(_ i: WebItem) {
            out.append(i)
            i.kids?.forEach(walk)
        }
        page.root.map(walk)
        return out
    }

    /// A PNG of one colour.
    static func png(_ width: Int, _ height: Int, _ color: CGColor) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func close(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.001) -> Bool { abs(a.x - b.x) <= e && abs(a.y - b.y) <= e }
    static func close(_ a: CGRect, _ b: CGRect, _ e: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) <= e && abs(a.minY - b.minY) <= e && abs(a.width - b.width) <= e && abs(a.height - b.height) <= e
    }
    static func close(_ a: RGBA, _ b: RGBA, _ e: Double = 0.01) -> Bool {
        abs(a.r - b.r) <= e && abs(a.g - b.g) <= e && abs(a.b - b.b) <= e && abs(a.a - b.a) <= e
    }

    /// The layers with a fill of this colour.
    static func filled(_ doc: BezzleDocument, _ color: RGBA) -> [Node] {
        doc.allNodes.filter { n in !n.isGroup && n.fills.contains { close($0.color, color) && $0.gradient == nil && $0.image == nil } }
    }
}

// MARK: - CSS values

struct CSSValueTests {
    @Test func readsColoursInTheirNotations() {
        #expect(CSS.color("rgba(255, 0, 0, 0.5)") == RGBA(r: 1, g: 0, b: 0, a: 0.5))
        #expect(CSS.color("rgb(0, 128, 255)")?.hex == "0080FF")
        #expect(CSS.color("#fff") == .white)
        #expect(CSS.color("#336699")?.hex == "336699")
        #expect(CSS.color("transparent")?.a == 0)
        #expect(CSS.color("rgb(100% 0% 0% / 25%)") == RGBA(r: 1, g: 0, b: 0, a: 0.25))
        #expect(CSS.color([0.5, 0.25, 1, 0.5]) == RGBA(r: 0.5, g: 0.25, b: 1, a: 0.5))
        #expect(CSS.color("bogus") == nil)
        #expect(CSS.color("12px") == nil)
    }

    @Test func splitsAtTheTopLevelOnly() {
        #expect(CSS.split("rgba(0, 0, 0, 0.1) 0px 1px 2px, rgba(1, 2, 3, 1) 0px 4px 8px") == ["rgba(0, 0, 0, 0.1) 0px 1px 2px", "rgba(1, 2, 3, 1) 0px 4px 8px"])
        #expect(CSS.words("rgba(0, 0, 0, 0.1)   0px 1px") == ["rgba(0, 0, 0, 0.1)", "0px", "1px"])
        #expect(CSS.split(#"url("a,b.png"), linear-gradient(red, blue)"#).count == 2)
        #expect(CSS.function("blur(4px)")?.name == "blur")
        #expect(CSS.function("blur(4px)")?.args == "4px")
    }

    @Test func readsLengthsAndAngles() {
        #expect(CSS.length("12px") == 12)
        #expect(CSS.length("12.5") == 12.5)
        #expect(CSS.length("50%", of: 300) == 150)
        #expect(CSS.length("calc(50% + 10px)", of: 200) == 110)
        #expect(CSS.length("calc(100% - 20px)", of: 80) == 60)
        #expect(CSS.length("2em", em: 10) == 20)
        #expect(CSS.length("1rem") == 16)
        #expect(CSS.length("auto") == nil)
        #expect(CSS.angle("90deg") == 90)
        #expect(CSS.angle("0.5turn") == 180)
        #expect(CSS.angle("100grad") == 90)
        #expect(abs(CSS.angle("3.14159265rad")! - 180) < 0.001)
        #expect(CSS.amount("50%") == 0.5)
        #expect(CSS.amount("1.5") == 1.5)
    }

    @Test func readsShadowsTheTopOneLast() {
        let s = CSS.shadows("rgba(0, 0, 0, 0.1) 0px 4px 6px -1px, rgba(255, 0, 0, 1) 1px 2px 3px 0px inset")
        #expect(s.count == 2)
        // The first listed lies on top, so it is cast last.
        #expect(s[1].color.a == 0.1 && s[1].y == 4 && s[1].blur == 6 && s[1].spread == -1 && s[1].inset == nil)
        #expect(s[0].inset == true && s[0].x == 1 && s[0].spread == nil && s[0].color == RGBA(r: 1, g: 0, b: 0))
        #expect(CSS.shadows("none").isEmpty)
        // A shadow no one sees is left out.
        #expect(CSS.shadows("rgba(0, 0, 0, 0) 0px 0px 10px 0px").isEmpty)
        // Text shadows have no spread, and take the text's colour when they name none.
        let text = CSS.shadows("2px 2px 4px", current: RGBA(r: 0, g: 0, b: 1))
        #expect(text.first?.color == RGBA(r: 0, g: 0, b: 1) && text.first?.blur == 4)
    }

    @Test func readsFilters() {
        let shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.5), x: 0, y: 2, blur: 4)
        #expect(CSS.filters("blur(4px) grayscale(1) drop-shadow(rgba(0, 0, 0, 0.5) 0px 2px 4px)") == [.blur(4), .grayscale(1), .dropShadow(shadow)])
        #expect(CSS.filters("brightness(150%) hue-rotate(90deg) url(#f)") == [.brightness(1.5), .hueRotate(90), .other("url")])
        #expect(CSS.filters("none").isEmpty)
    }

    @Test func laysLinearGradientsAcrossTheBox() throws {
        let size = CGSize(width: 200, height: 100)
        let right = try #require(CSS.gradient("linear-gradient(to right, rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))", size: size))
        #expect(right.kind == .linear)
        #expect(WebTest.close(right.start, CGPoint(x: 0, y: 0.5)) && WebTest.close(right.end, CGPoint(x: 1, y: 0.5)))
        #expect(right.stops.map(\.offset) == [0, 1])
        #expect(right.stops[0].color == RGBA(r: 1, g: 0, b: 0) && right.stops[1].color == RGBA(r: 0, g: 0, b: 1))
        // Down, from the top, unless it says otherwise.
        let down = try #require(CSS.gradient("linear-gradient(rgba(0, 0, 0, 1), rgba(255, 255, 255, 1))", size: size))
        #expect(WebTest.close(down.start, CGPoint(x: 0.5, y: 0)) && WebTest.close(down.end, CGPoint(x: 0.5, y: 1)))
        let ninety = try #require(CSS.gradient("linear-gradient(90deg, rgba(0, 0, 0, 1) 0%, rgba(255, 255, 255, 1) 100%)", size: size))
        #expect(WebTest.close(ninety.start, CGPoint(x: 0, y: 0.5)) && WebTest.close(ninety.end, CGPoint(x: 1, y: 0.5)))
        // Into a corner, the line runs square to the diagonal between the other two corners,
        // which both lie halfway along it.
        let corner = try #require(CSS.gradient("linear-gradient(to top right, rgba(0, 0, 0, 1), rgba(255, 255, 255, 1))", size: size))
        let a = CGPoint(x: corner.start.x * 200, y: corner.start.y * 100), b = CGPoint(x: corner.end.x * 200, y: corner.end.y * 100)
        func along(_ p: CGPoint) -> CGFloat {
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            return ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / (d.x * d.x + d.y * d.y)
        }
        #expect(abs(along(CGPoint(x: 0, y: 0)) - 0.5) < 0.001)
        #expect(abs(along(CGPoint(x: 200, y: 100)) - 0.5) < 0.001)
        #expect(abs(along(CGPoint(x: 0, y: 100))) < 0.001)
        #expect(abs(along(CGPoint(x: 200, y: 0)) - 1) < 0.001)
        // At 45°, the far corners are its ends.
        let diagonal = try #require(CSS.gradient("linear-gradient(45deg, rgba(0, 0, 0, 1), rgba(255, 255, 255, 1))", size: CGSize(width: 100, height: 100)))
        #expect(WebTest.close(diagonal.start, CGPoint(x: 0, y: 1)) && WebTest.close(diagonal.end, CGPoint(x: 1, y: 0)))
    }

    @Test func placesGradientStops() throws {
        let stops = try #require(CSS.stops(["rgba(0, 0, 0, 1)", "rgba(255, 0, 0, 1) 50px", "rgba(0, 255, 0, 1)", "rgba(0, 0, 255, 1)"], length: 200))
        #expect(stops.map(\.offset) == [0, 0.25, 0.625, 1])
        // Two places make two stops of one colour; a stop before the one before it moves up to it.
        let doubled = try #require(CSS.stops(["rgba(0, 0, 0, 1) 10% 20%", "rgba(255, 255, 255, 1) 5%"], length: 100))
        #expect(doubled.map(\.offset) == [0.1, 0.2, 0.2])
        // A hint alone is left out.
        #expect(CSS.stops(["rgba(0, 0, 0, 1)", "30%", "rgba(255, 255, 255, 1)"], length: 100)?.count == 2)
        // Stops past the ends are cut off there, at the colours they come to.
        let wide = try #require(CSS.gradient("linear-gradient(90deg, rgba(0, 0, 0, 1) -50%, rgba(255, 255, 255, 1) 150%)", size: CGSize(width: 100, height: 100)))
        #expect(wide.stops.count == 2)
        #expect(WebTest.close(wide.stops[0].color, RGBA(r: 0.25, g: 0.25, b: 0.25)) && WebTest.close(wide.stops[1].color, RGBA(r: 0.75, g: 0.75, b: 0.75)))
        // Stripes repeat until they fill the line.
        let stripes = try #require(CSS.gradient("repeating-linear-gradient(90deg, rgba(0, 0, 0, 1) 0px, rgba(0, 0, 0, 1) 10px, rgba(255, 255, 255, 1) 10px, rgba(255, 255, 255, 1) 20px)", size: CGSize(width: 100, height: 20)))
        #expect(stripes.stops.count >= 20)
        #expect(stripes.stops.first?.color == .black)
        // A conic gradient is no gradient Bezzle draws.
        #expect(CSS.gradient("conic-gradient(rgba(0, 0, 0, 1), rgba(255, 255, 255, 1))", size: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func spreadsRadialGradients() throws {
        let square = CGSize(width: 100, height: 100)
        let circle = try #require(CSS.gradient("radial-gradient(circle at 50% 50%, rgba(255, 255, 255, 1) 0%, rgba(0, 0, 0, 1) 100%)", size: square))
        #expect(circle.kind == .radial && WebTest.close(circle.start, CGPoint(x: 0.5, y: 0.5)))
        // Out to the farthest corner.
        #expect(abs(circle.end.x - 0.5 - hypot(50, 50) / 100) < 0.001)
        let ellipse = try #require(CSS.gradient("radial-gradient(closest-side, rgba(255, 255, 255, 1), rgba(0, 0, 0, 1))", size: CGSize(width: 200, height: 100)))
        #expect(WebTest.close(ellipse.end, CGPoint(x: 1, y: 0.5)) && WebTest.close(ellipse.across ?? .zero, CGPoint(x: 0.5, y: 1)))
        let placed = try #require(CSS.gradient("radial-gradient(20px 10px at 10px 10px, rgba(255, 255, 255, 1), rgba(0, 0, 0, 1))", size: square))
        #expect(WebTest.close(placed.start, CGPoint(x: 0.1, y: 0.1)) && WebTest.close(placed.end, CGPoint(x: 0.3, y: 0.1)) && WebTest.close(placed.across ?? .zero, CGPoint(x: 0.1, y: 0.2)))
    }

    @Test func readsPositions() {
        let box = CGSize(width: 100, height: 100), thing = CGSize(width: 20, height: 20)
        #expect(CSS.position(["right", "10px", "bottom", "20px"], in: box, object: thing) == CGPoint(x: 70, y: 60))
        #expect(CSS.position(["50%", "50%"], in: box, object: thing) == CGPoint(x: 40, y: 40))
        #expect(CSS.position(["left", "top"], in: box, object: thing) == .zero)
        #expect(CSS.position(["center"], in: box, object: thing) == CGPoint(x: 40, y: 40))
        #expect(CSS.position(["10px", "25%"], in: box, object: thing) == CGPoint(x: 10, y: 20))
        #expect(CSS.offset("right 10px", room: 80, horizontal: true) == 70)
        #expect(CSS.offset("calc(100% - 5px)", room: 80, horizontal: true) == 75)
        #expect(CSS.offset("center", room: 80, horizontal: false) == 40)
        #expect(CSS.offset("12px", room: 80, horizontal: false) == 12)
    }

    @Test func readsTheShapesBoxesAreCutTo() {
        let box = CGSize(width: 100, height: 100)
        #expect(CSS.clipShape("inset(10px 20px round 5px)", size: box) == .rect(CGRect(x: 20, y: 10, width: 60, height: 80), radius: 5))
        #expect(CSS.clipShape("inset(10% 0px 0px 0px)", size: box) == .rect(CGRect(x: 0, y: 10, width: 100, height: 90), radius: 0))
        #expect(CSS.clipShape("circle(50% at 50% 50%)", size: box) == .ellipse(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(CSS.clipShape("circle(closest-side at 25% 50%)", size: box) == .ellipse(CGRect(x: 0, y: 25, width: 50, height: 50)))
        #expect(CSS.clipShape("ellipse(50px 25px at 50% 50%)", size: box) == .ellipse(CGRect(x: 0, y: 25, width: 100, height: 50)))
        #expect(CSS.clipShape("polygon(50% 0%, 100% 100%, 0% 100%)", size: box) == .path("M 50 0 L 100 100 L 0 100 Z", evenOdd: false))
        #expect(CSS.clipShape("polygon(evenodd, 0px 0px, 10px 0px, 0px 10px)", size: box) == .path("M 0 0 L 10 0 L 0 10 Z", evenOdd: true))
        #expect(CSS.clipShape(#"path("M 0 0 L 10 0 L 0 10 Z")"#, size: box) == .path("M 0 0 L 10 0 L 0 10 Z", evenOdd: false))
        #expect(CSS.clipShape("circle(40px) border-box", size: box) == .ellipse(CGRect(x: 10, y: 10, width: 80, height: 80)))
        #expect(CSS.clipShape(##"url("#clip")"##, size: box) == nil)
    }
}

// MARK: - From what the reader hands over to layers

@MainActor
struct WebConverterTests {
    let side = #"{"w":2,"s":"solid","c":[0,0,1,1]}"#

    @Test func drawsABoxWithItsFillBorderCornersAndShadow() throws {
        let card = #"{"t":"el","id":1,"tag":"div","label":"card","x":100,"y":50,"w":200,"h":120,"bg":[1,0,0,1],"bd":[\#(side),\#(side),\#(side),\#(side)],"rad":[12,12,12,12,12,12,12,12],"sh":"rgba(0, 0, 0, 0.25) 0px 4px 8px 0px","ins":[2,2,2,2,0,0,0,0]}"#
        let (doc, report) = WebTest.convert(try WebTest.page(WebTest.html(card)))
        let board = try #require(doc.nodes.first)
        #expect(board.isArtboard && board.frame == CGRect(x: 0, y: 0, width: 800, height: 600) && board.name == "Desktop")
        #expect(board.fill.color == .white && board.clips)
        let node = try #require(doc.allNodes.first { $0.name == "Card" })
        #expect(node.kind == .rectangle && node.frame == CGRect(x: 100, y: 50, width: 200, height: 120))
        #expect(node.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(node.cornerRadius == 12 && node.corners == nil)
        #expect(node.borders.count == 1 && node.border.width == 2 && node.border.position == .inside && node.border.color == RGBA(r: 0, g: 0, b: 1))
        #expect(node.shadows.count == 1 && node.shadows[0].blur == 8 && node.shadows[0].y == 4 && node.shadows[0].color.a == 0.25)
        #expect(report.artboards == 1 && report.layers == 1 && report.source == "example.com")
    }

    @Test func roundAllRoundIsAnEllipseAndCornersCanDiffer() throws {
        let dot = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":50,"h":50,"bg":[0,1,0,1],"rad":[25,25,25,25,25,25,25,25]}"#
        let tab = #"{"t":"el","id":2,"tag":"div","x":100,"y":0,"w":80,"h":40,"bg":[0,0,1,1],"rad":[8,8,8,8,0,0,0,0]}"#
        let (doc, report) = WebTest.convert(try WebTest.page(WebTest.html(dot, tab)))
        #expect(WebTest.filled(doc, RGBA(r: 0, g: 1, b: 0)).first?.kind == .ellipse)
        let t = try #require(WebTest.filled(doc, RGBA(r: 0, g: 0, b: 1)).first)
        #expect(t.kind == .rectangle && t.radii == [8, 8, 0, 0])
        #expect(report.notes.isEmpty)
        // Oval corners are made round, and said so.
        let oval = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":100,"h":50,"bg":[0,1,0,1],"rad":[20,10,20,10,20,10,20,10]}"#
        let (ovalDoc, ovalReport) = WebTest.convert(try WebTest.page(WebTest.html(oval)))
        #expect(WebTest.filled(ovalDoc, RGBA(r: 0, g: 1, b: 0)).first?.cornerRadius == 10)
        #expect(ovalReport.notes.keys.contains { $0.contains("Oval") })
    }

    @Test func drawsBordersOnSomeSidesAsBars() throws {
        let rule = #"{"t":"el","id":1,"tag":"div","x":10,"y":20,"w":300,"h":40,"bd":[null,null,{"w":1,"s":"solid","c":[0,0,0,1]},{"w":4,"s":"solid","c":[1,0,0,1]}],"ins":[0,0,1,4,0,0,0,0]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(rule)))
        let bars = doc.allNodes.filter { $0.name == "Border" }
        #expect(bars.count == 2)
        #expect(bars.contains { $0.frame == CGRect(x: 10, y: 59, width: 300, height: 1) && $0.fill.color == .black })
        #expect(bars.contains { $0.frame == CGRect(x: 10, y: 20, width: 4, height: 40) && $0.fill.color == RGBA(r: 1, g: 0, b: 0) })
    }

    @Test func boxesThatOnlyHoldOthersAreNotKept() throws {
        let inner = #"{"t":"el","id":3,"tag":"div","x":10,"y":10,"w":50,"h":50,"bg":[1,0,0,1]}"#
        let wrapper = #"{"t":"el","id":2,"tag":"div","x":0,"y":0,"w":800,"h":100,"kids":[\#(inner)]}"#
        let body = #"{"t":"el","id":1,"tag":"body","label":"home","x":0,"y":0,"w":800,"h":100,"kids":[\#(wrapper)]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(body)))
        // No groups for the html, the body or the wrapper: the box lies on the artboard itself.
        #expect(doc.nodes[0].children.count == 1)
        #expect(doc.nodes[0].children[0].kind == .rectangle)
        // A part of the page with a name of its own, holding several, stays a group.
        let a = #"{"t":"el","id":4,"tag":"div","x":0,"y":0,"w":10,"h":10,"bg":[1,0,0,1]}"#
        let b = #"{"t":"el","id":5,"tag":"div","x":20,"y":0,"w":10,"h":10,"bg":[0,1,0,1]}"#
        let nav = #"{"t":"el","id":6,"tag":"nav","x":0,"y":0,"w":100,"h":10,"kids":[\#(a),\#(b)]}"#
        let (navDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(nav)))
        let group = try #require(navDoc.nodes[0].children.first)
        #expect(group.isGroup && group.name == String(localized: "Navigation") && group.children.count == 2)
    }

    @Test func paintsChildrenInTheBrowsersOrder() throws {
        func box(_ id: Int, _ name: String, _ extra: String) -> String {
            #"{"t":"el","id":\#(id),"tag":"div","label":"\#(name)","x":0,"y":0,"w":10,"h":10,"bg":[1,0,0,1]\#(extra)}"#
        }
        let html = WebTest.html(box(1, "front", #","pos":"absolute","z":2"#), box(2, "block", ""), box(3, "behind", #","pos":"absolute","z":-1"#),
                                box(4, "positioned", #","pos":"relative""#), box(5, "floated", #","fl":true"#), box(6, "inline", #","inl":true"#),
                                box(7, "faded", #","sc":true,"op":0.5"#))
        let (doc, _) = WebTest.convert(try WebTest.page(html))
        #expect(doc.nodes[0].children.map(\.name) == ["Behind", "Block", "Floated", "Inline", "Positioned", "Faded", "Front"])
    }

    @Test func zIndexReachesPastWhatIsNoStackingContext() throws {
        func box(_ id: Int, _ name: String, _ extra: String, kids: [String] = []) -> String {
            #"{"t":"el","id":\#(id),"tag":"div","label":"\#(name)","x":0,"y":0,"w":10,"h":10,"bg":[1,0,0,1]\#(extra),"kids":[\#(kids.joined(separator: ","))]}"#
        }
        // A header over the page's main part, which holds a background brought forward only a little.
        let header = box(1, "header", #","pos":"relative","z":2"#)
        let background = box(4, "background", #","pos":"absolute","z":1"#)
        let section = box(3, "section", #","pos":"relative""#, kids: [background])
        let main = #"{"t":"el","id":2,"tag":"main","x":0,"y":0,"w":10,"h":10,"kids":[\#(section)]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(header, main)))
        let order = doc.allNodes.map(\.name)
        #expect(order.firstIndex(of: "Header")! > order.firstIndex(of: "Background")!)
        // A copy brought forward inside a box that is not a stacking context comes before a
        // picture positioned after it.
        let copy = box(6, "copy", #","pos":"relative","z":2"#)
        let content = box(5, "content", #","pos":"relative""#, kids: [copy])
        let picture = box(7, "picture", #","pos":"absolute""#)
        let (tile, _) = WebTest.convert(try WebTest.page(WebTest.html(content, picture)))
        let names = tile.allNodes.map(\.name)
        #expect(names.firstIndex(of: "Copy")! > names.firstIndex(of: "Picture")!)
    }

    @Test func cutsOffWhatReachesPastAClippingBox() throws {
        let child = #"{"t":"el","id":2,"tag":"div","x":50,"y":50,"w":100,"h":100,"bg":[1,0,1,1]}"#
        let clip = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":100,"h":100,"bg":[1,1,1,1],"clip":true,"rad":[10,10,10,10,10,10,10,10],"kids":[\#(child)]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(clip)))
        let mask = try #require(doc.nodes[0].children.first)
        #expect(mask.isMask)
        #expect(mask.children[0].fill.color == .white && mask.children[0].cornerRadius == 10)
        #expect(mask.children.count == 2)
        // What lies inside is not cut, and needs no mask.
        let inside = #"{"t":"el","id":2,"tag":"div","x":10,"y":10,"w":20,"h":20,"bg":[1,0,1,1]}"#
        let calm = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":100,"h":100,"bg":[1,1,1,1],"clip":true,"kids":[\#(inside)]}"#
        let (calmDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(calm)))
        #expect(!calmDoc.allNodes.contains { $0.isMask })
        // What lies wholly outside is gone.
        let away = #"{"t":"el","id":2,"tag":"div","x":300,"y":10,"w":20,"h":20,"bg":[1,0,1,1]}"#
        let slides = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":100,"h":100,"clip":true,"kids":[\#(inside),\#(away)]}"#
        let (slideDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(slides)))
        #expect(WebTest.filled(slideDoc, RGBA(r: 1, g: 0, b: 1)).count == 1)
    }

    @Test func cutsToTheShapeOfAClipPath() throws {
        let kid = #"{"t":"el","id":2,"tag":"div","x":0,"y":0,"w":100,"h":100,"bg":[1,0,0,1]}"#
        let round = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":100,"h":100,"clipPath":"circle(50% at 50% 50%)","kids":[\#(kid)]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(round)))
        let mask = try #require(doc.allNodes.first { $0.isMask })
        #expect(mask.children[0].kind == .ellipse && mask.children[0].frame == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func fadesTheWholeOrTheOne() throws {
        let a = #"{"t":"el","id":2,"tag":"div","x":0,"y":0,"w":10,"h":10,"bg":[1,0,0,1]}"#
        let b = #"{"t":"el","id":3,"tag":"div","x":20,"y":0,"w":10,"h":10,"bg":[0,1,0,1]}"#
        let two = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":40,"h":10,"op":0.5,"blend":"multiply","kids":[\#(a),\#(b)]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(two)))
        let group = try #require(doc.nodes[0].children.first)
        #expect(group.isGroup && group.opacity == 0.5 && group.blend == .multiply)
        let one = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":40,"h":10,"op":0.5,"kids":[\#(a)]}"#
        let (oneDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(one)))
        #expect(oneDoc.nodes[0].children.first?.kind == .rectangle && oneDoc.nodes[0].children.first?.opacity == 0.5)
    }

    @Test func turnsWhatTheTransformTurns() throws {
        // rotate(90deg) about the box's middle, (150, 125).
        let box = #"{"t":"el","id":1,"tag":"div","x":100,"y":100,"w":100,"h":50,"bg":[1,0,0,1],"m":[0,1,-1,0,275,-25]}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(box)))
        let node = try #require(doc.nodes[0].children.first)
        #expect(WebTest.close(node.frame, CGRect(x: 100, y: 100, width: 100, height: 50), 0.01))
        #expect(abs(node.rotation - 90) < 0.01)
        // Scaled to twice its size, about its top left, it draws its corners twice as round.
        let grown = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":50,"h":20,"bg":[1,0,0,1],"rad":[4,4,4,4,4,4,4,4],"m":[2,0,0,2,0,0]}"#
        let (grownDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(grown)))
        let g = try #require(grownDoc.nodes[0].children.first)
        #expect(WebTest.close(g.frame, CGRect(x: 0, y: 0, width: 100, height: 40), 0.01) && g.cornerRadius == 8)
    }

    @Test func laysBackgroundsInTheirBoxes() throws {
        let layers = #"[{"grad":"linear-gradient(to right, rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))","size":"auto","x":"0%","y":"0%","rep":"repeat","origin":"padding-box","clip":"border-box","blend":"normal"},{"img":0,"size":"cover","x":"50%","y":"50%","rep":"no-repeat","origin":"padding-box","clip":"border-box","blend":"normal"}]"#
        let box = #"{"t":"el","id":1,"tag":"div","x":0,"y":0,"w":200,"h":100,"bg":[0,0,0,1],"layers":\#(layers)}"#
        var assets = WebAssets()
        assets.pictures[0] = WebAssets.Picture(asset: "pic.png", size: CGSize(width: 400, height: 400))
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(box), images: ["https://example.com/pic.png"]), assets: assets)
        let node = try #require(doc.nodes[0].children.first)
        // The colour at the bottom, then the layers from the last listed up.
        #expect(node.fills.count == 3)
        #expect(node.fills[0].color == .black && node.fills[0].gradient == nil)
        #expect(node.fills[1].image?.asset == "pic.png" && node.fills[1].image?.mode == .cover)
        #expect(node.fills[2].gradient?.kind == .linear)
        // Covering and centred, it is drawn as the browser draws it.
        let image = try #require(node.fills[1].image)
        let drawn = Renderer.imageRect(image, in: node.frame.size)
        #expect(WebTest.close(drawn, CGRect(x: 0, y: -50, width: 200, height: 200)))
    }

    @Test func picturesFillTheirBoxAsTheBrowserDrawsThem() {
        // However a picture is laid in a box, its fill draws it in that place.
        let picture = WebAssets.Picture(asset: "p.png", size: CGSize(width: 300, height: 150))
        let size = CGSize(width: 120, height: 90)
        let places = [CGRect(x: 0, y: 0, width: 180, height: 90), CGRect(x: -30, y: 0, width: 180, height: 90),
                      CGRect(x: 0, y: 15, width: 120, height: 60), CGRect(x: 10, y: 20, width: 40, height: 20),
                      CGRect(x: -100, y: -50, width: 600, height: 300)]
        for drawn in places {
            let fill = WebConverter.imageFill(picture, drawn: drawn, in: size)
            #expect(WebTest.close(Renderer.imageRect(fill, in: size), drawn, 0.01), "\(drawn)")
        }
        // Squeezed to the box, it is stretched.
        #expect(WebConverter.imageFill(picture, drawn: CGRect(origin: .zero, size: size), in: size).mode == .stretch)
    }

    @Test func showsPicturesAsObjectFitAndObjectPositionSay() throws {
        let img = #"{"t":"el","id":1,"tag":"img","label":"Hero","x":0,"y":0,"w":100,"h":100,"rad":[8,8,8,8,8,8,8,8],"img":{"src":0,"fit":"cover","pos":"0% 50%","nat":[400,200]},"ins":[0,0,0,0,0,0,0,0]}"#
        var assets = WebAssets()
        assets.pictures[0] = WebAssets.Picture(asset: "hero.jpg", size: CGSize(width: 800, height: 400))
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(img), images: ["x"]), assets: assets)
        let node = try #require(doc.nodes[0].children.first)
        #expect(node.name == "Hero" && node.cornerRadius == 8)
        let image = try #require(node.fill.image)
        #expect(WebTest.close(Renderer.imageRect(image, in: node.frame.size), CGRect(x: 0, y: 0, width: 200, height: 100)))
        // Contained, it is shown whole in the middle.
        let contained = #"{"t":"el","id":1,"tag":"img","x":0,"y":0,"w":100,"h":100,"img":{"src":0,"fit":"contain","pos":"50% 50%","nat":[400,200]}}"#
        let (cDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(contained), images: ["x"]), assets: assets)
        let c = try #require(cDoc.nodes[0].children.first?.fill.image)
        #expect(WebTest.close(Renderer.imageRect(c, in: CGSize(width: 100, height: 100)), CGRect(x: 0, y: 25, width: 100, height: 50)))
        // Greyed by a filter, it is developed grey.
        let grey = #"{"t":"el","id":1,"tag":"img","x":0,"y":0,"w":100,"h":100,"filter":"grayscale(1)","img":{"src":0,"fit":"fill","pos":"50% 50%","nat":[400,200]}}"#
        let (gDoc, gReport) = WebTest.convert(try WebTest.page(WebTest.html(grey), images: ["x"]), assets: assets)
        #expect(gDoc.nodes[0].children.first?.fill.image?.develop?[.saturation] == -100)
        #expect(gReport.notes.isEmpty)
    }

    @Test func drawsSVGOutlinesAsPaths() throws {
        let paths = #"[{"d":"M0 0 L10 0 L10 10 Z","m":[1,0,0,1,50,50],"fill":{"c":[1,0,0,1]},"rule":"evenodd","stroke":{"paint":{"c":[0,0,0,1]},"w":2,"dash":[4,2]}},{"d":"M0 0 L20 0","m":[2,0,0,2,0,0],"stroke":{"paint":{"c":[0,0,1,1]},"w":1.5}},{"d":"M0 0 L10 0 L10 10 L0 10 Z","m":[1,0,0,1,100,0],"fill":{"g":{"k":"linear","stops":[{"o":0,"c":[1,0,0,1]},{"o":1,"c":[0,0,1,1]}],"a":[0,0],"b":[10,0]}}}]"#
        let svg = #"{"t":"el","id":1,"tag":"svg","label":"Logo","x":0,"y":0,"w":200,"h":100,"vec":\#(paths)}"#
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(svg)))
        let group = try #require(doc.nodes[0].children.first)
        #expect(group.isGroup && group.name == "Logo" && group.children.count == 3)
        let tri = doc.allNodes.first { $0.kind == .path && $0.fill.color == RGBA(r: 1, g: 0, b: 0) }
        #expect(tri?.evenOdd == true && tri?.border.width == 2 && tri?.border.dash == 4 && tri?.border.gap == 2 && tri?.border.position == .center)
        #expect(doc.absoluteFrame(of: tri!.id) == CGRect(x: 50, y: 50, width: 10, height: 10))
        // A stroke is as wide as the transform makes it.
        let line = doc.allNodes.first { $0.kind == .path && $0.border.color == RGBA(r: 0, g: 0, b: 1) }
        #expect(line?.border.width == 3 && line?.fills.isEmpty == true)
        // A gradient keeps its ends, carried onto the layer.
        let shaded = try #require(doc.allNodes.first { $0.fill.gradient != nil })
        #expect(WebTest.close(shaded.fill.gradient!.start, CGPoint(x: 0, y: 0)) && WebTest.close(shaded.fill.gradient!.end, CGPoint(x: 1, y: 0)))
    }

    @Test func photographsAreDrawnWhereTheyWereTaken() throws {
        let icon = #"{"t":"el","id":5,"tag":"i","label":"Star","x":10,"y":10,"w":20,"h":20,"shot":"icon"}"#
        var assets = WebAssets()
        assets.shots[5] = WebAssets.Shot(asset: "shot.png", size: CGSize(width: 66, height: 66), frame: CGRect(x: 9, y: 9, width: 22, height: 22))
        let (doc, report) = WebTest.convert(try WebTest.page(WebTest.html(icon)), assets: assets)
        let node = try #require(doc.nodes[0].children.first)
        #expect(node.name == "Star" && node.frame == CGRect(x: 9, y: 9, width: 22, height: 22))
        #expect(node.fill.image?.asset == "shot.png" && node.fill.image?.mode == .stretch)
        #expect(report.notes.keys.contains { $0.contains("icon") })
        // A box whose background could only be photographed keeps its border and corners, filled with the photograph.
        let conic = #"{"t":"el","id":6,"tag":"div","x":0,"y":0,"w":50,"h":50,"rad":[6,6,6,6,6,6,6,6],"bd":[\#(side),\#(side),\#(side),\#(side)],"layers":[{"grad":"conic-gradient(rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))","size":"auto","x":"0%","y":"0%","rep":"repeat","origin":"padding-box","clip":"border-box","blend":"normal"}],"ins":[2,2,2,2,0,0,0,0]}"#
        var own = WebAssets()
        own.backgrounds[6] = WebAssets.Shot(asset: "back.png", size: CGSize(width: 100, height: 100), frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let (ownDoc, _) = WebTest.convert(try WebTest.page(WebTest.html(conic)), assets: own)
        let box = try #require(ownDoc.nodes[0].children.first)
        #expect(box.fill.image?.asset == "back.png" && box.border.width == 2 && box.cornerRadius == 6)
    }

    @Test func plansWhatMustBePhotographed() throws {
        let icon = #"{"t":"el","id":1,"tag":"i","x":0,"y":0,"w":20,"h":20,"shot":"icon","kids":[{"t":"el","id":9,"tag":"span","x":0,"y":0,"w":2,"h":2,"shot":"icon"}]}"#
        let missing = #"{"t":"el","id":2,"tag":"img","x":0,"y":0,"w":20,"h":20,"img":{"src":0,"fit":"fill","pos":"50% 50%","nat":[1,1]}}"#
        let conic = #"{"t":"el","id":3,"tag":"div","x":0,"y":0,"w":20,"h":20,"layers":[{"grad":"conic-gradient(rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))","rep":"repeat"}]}"#
        let sepia = #"{"t":"el","id":4,"tag":"div","x":0,"y":0,"w":100,"h":100,"filter":"sepia(1)"}"#
        let blurred = #"{"t":"el","id":5,"tag":"div","x":0,"y":0,"w":100,"h":100,"filter":"blur(4px)"}"#
        let fine = #"{"t":"el","id":6,"tag":"div","x":0,"y":0,"w":20,"h":20,"layers":[{"grad":"linear-gradient(rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))","rep":"repeat"}]}"#
        let page = try WebTest.page(WebTest.html(icon, missing, conic, sepia, blurred, fine), images: ["x"])
        let wanted = WebConverter.photographs(in: page, assets: WebAssets())
        #expect(wanted.map(\.id) == [1, 2, 3, 4])
        #expect(wanted.map(\.own) == [false, false, true, false])
    }

    @Test func namesLayersAsThePageNamesItsParts() {
        #expect(WebConverter.humanized("hero-banner") == "Hero banner")
        #expect(WebConverter.humanized("heroBanner") == "Hero banner")
        #expect(WebConverter.humanized("site_header--big") == "Site header big")
        #expect(WebConverter.humanized("Main menu") == "Main menu")
        #expect(WebConverter.humanized("CTA") == "CTA")
        #expect(WebConverter.textName("A very long heading that goes on and on and on, longer than forty") == "A very long heading that goes on and on…")
        #expect(WebConverter.textName("Two\nlines") == "Two lines")
    }

    // MARK: Words

    /// A text the page reader would hand over: `runs` of `styles`, set in `lines`.
    private func text(_ words: String, runs: String, styles: [String], lines: String, cont: String, clean: Bool = true, extra: String = "") -> String {
        #"{"t":"text","id":1,"text":"\#(words)","runs":\#(runs),"styles":[\#(styles.joined(separator: ","))],"lines":\#(lines),"cont":\#(cont),"clean":\#(clean)\#(extra)}"#
    }

    private func style(_ fam: String = #"["Helvetica"]"#, used: String = "Helvetica", web: Bool = false, wt: Int = 400, it: Bool = false, size: Double = 16, lh: String = "null", ls: Double = 0, c: String = "[0,0,0,1]", extra: String = "") -> String {
        #"{"fam":\#(fam),"used":"\#(used)","web":\#(web),"wt":\#(wt),"it":\#(it),"size":\#(size),"lh":\#(lh),"ls":\#(ls),"c":\#(c)\#(extra)}"#
    }

    @Test func setsAParagraphInItsBoxOnItsBaseline() throws {
        let t = text("Hello world", runs: "[[11,0]]", styles: [style(lh: "24")], lines: #"[{"from":0,"to":11,"x":40,"y":100,"w":80,"h":18,"base":114}]"#,
                     cont: #"{"x":40,"y":97,"w":500,"align":"center","dir":"ltr","indent":0,"wrap":true}"#)
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(t)))
        let node = try #require(doc.allNodes.first { $0.kind == .text })
        #expect(node.text == "Hello world" && node.name == "Hello world")
        #expect(node.style?.sizing == .autoHeight && node.style?.align == .center && node.style?.lineSpacing == 24)
        #expect(node.style?.family == "Helvetica" && node.style?.face == "Regular" && node.style?.size == 16)
        #expect(node.frame.minX == 40 && node.frame.width == 500)
        #expect(abs(node.frame.minY + TextLayout.firstBaseline(node) - 114) < 0.01)
    }

    @Test func setsRunsOfLettersAsTheyLook() throws {
        let bold = style(wt: 700, c: "[1,0,0,1]", extra: #","u":true"#)
        let t = text("Hello world", runs: "[[6,0],[5,1]]", styles: [style(), bold], lines: #"[{"from":0,"to":11,"x":0,"y":0,"w":80,"h":18,"base":14}]"#,
                     cont: #"{"x":0,"y":0,"w":0,"align":"start","dir":"ltr","wrap":false}"#, clean: false)
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(t)))
        let node = try #require(doc.allNodes.first { $0.kind == .text })
        #expect(node.style?.sizing == .autoWidth && node.frame.minX == 0)
        let runs = node.runs
        #expect(runs.map(\.text) == ["Hello ", "world"])
        let look = runs[1].look.resolved(over: node.style!, color: node.fill.color)
        #expect(look.face == "Bold" && look.color == RGBA(r: 1, g: 0, b: 0) && look.underline)
    }

    @Test func carriesCaseSpacingAndFeatures() throws {
        let s = style(ls: 1.6, extra: #","tt":"uppercase","ff":"\"ss01\", \"liga\" 0","fvn":"tabular-nums","fv":"\"wght\" 650""#)
        let t = text("Shout", runs: "[[5,0]]", styles: [s], lines: #"[{"from":0,"to":5,"x":0,"y":0,"w":80,"h":18,"base":14}]"#,
                     cont: #"{"x":0,"y":0,"w":0,"align":"left","dir":"ltr","wrap":false}"#, clean: false)
        let (doc, _) = WebTest.convert(try WebTest.page(WebTest.html(t)))
        let node = try #require(doc.allNodes.first { $0.kind == .text })
        #expect(node.style?.letterCase == .upper)
        #expect(node.style?.tracking == 100)
        #expect(node.style?.features == ["ss01": 1, "liga": 0, "tnum": 1])
        #expect(node.style?.axes == ["wght": 650])
    }

    @Test func setsTextWrappedRoundOthersALineAtATime() throws {
        let t = text("one two", runs: "[[7,0]]", styles: [style()], lines: #"[{"from":0,"to":4,"x":200,"y":0,"w":30,"h":18,"base":14},{"from":4,"to":7,"x":0,"y":24,"w":30,"h":18,"base":38}]"#,
                     cont: #"{"x":0,"y":0,"w":500,"align":"left","dir":"ltr","wrap":true}"#, clean: false)
        let (doc, report) = WebTest.convert(try WebTest.page(WebTest.html(t)))
        let texts = doc.allNodes.filter { $0.kind == .text }
        #expect(texts.map { $0.text ?? "" } == ["one ", "two"] || texts.map { $0.text ?? "" } == ["one", "two"])
        let two = try #require(texts.first { $0.text == "two" })
        #expect(doc.absoluteFrame(of: two.id)?.minX == 0)
        #expect(abs((doc.absoluteFrame(of: two.id)?.minY ?? 0) + TextLayout.firstBaseline(two) - 38) < 0.01)
        let one = try #require(texts.first { $0.text?.hasPrefix("one") == true })
        #expect(doc.absoluteFrame(of: one.id)?.minX == 200)
        #expect(report.notes.keys.contains { $0.contains("a text a line") })
    }

    @Test func paragraphsBesideFloatsKeepTheirLines() throws {
        func line(_ x: Double, _ w: Double, _ base: Double) -> WebLine { WebLine(from: 0, to: 1, x: x, y: base - 12, w: w, h: 16, base: base) }
        let box = WebBlock(x: 0, y: 0, w: 600, align: "left", dir: "ltr", indent: 0, wrap: true)
        // Ragged as words leave it: the whole box.
        #expect(WebConverter.room([line(0, 590, 14), line(0, 560, 38), line(0, 120, 62)], cont: box, align: .left) == 600)
        // A float beside every line: as wide as the lines reach.
        #expect(WebConverter.room([line(0, 340, 14), line(0, 352, 38), line(0, 90, 62)], cont: box, align: .left) == 353)
        // A float beside some lines only, or to the left: lines of their own.
        #expect(WebConverter.room([line(0, 340, 14), line(0, 596, 38), line(0, 90, 62)], cont: box, align: .left) == nil)
        #expect(WebConverter.room([line(260, 330, 14), line(0, 596, 38)], cont: box, align: .left) == nil)
        // Centred lines are as long as their words, wherever they lie.
        #expect(WebConverter.room([line(100, 400, 14), line(250, 100, 38)], cont: box, align: .center) == 600)
        // Shaped by a picture's outline, a box that could not be photographed is left out.
        let icon = #"{"t":"el","id":1,"tag":"span","x":0,"y":0,"w":20,"h":20,"bg":[0,0,0,1],"shot":"mask"}"#
        #expect(WebTest.convert(try WebTest.page(WebTest.html(icon))).0.nodes[0].children.isEmpty)
    }

    @Test func findsTheFontsTheBrowserDrewWith() throws {
        func node(_ s: String) throws -> Node? {
            let t = text("Aa", runs: "[[2,0]]", styles: [s], lines: #"[{"from":0,"to":2,"x":0,"y":0,"w":20,"h":18,"base":14}]"#,
                         cont: #"{"x":0,"y":0,"w":0,"align":"left","dir":"ltr","wrap":false}"#, clean: false)
            return WebTest.convert(try WebTest.page(WebTest.html(t))).0.allNodes.first { $0.kind == .text }
        }
        // The Mac's own for the system's.
        let system = try node(style(#"["-apple-system", "BlinkMacSystemFont", "Helvetica"]"#, used: "-apple-system", wt: 600))
        #expect(system?.style?.family == TextStyle.system && system?.style?.face == "Semibold")
        // A generic family as Safari draws it.
        #expect(try node(style(#"["sans-serif"]"#, used: "sans-serif"))?.style?.family == "Helvetica")
        #expect(try node(style(#"["monospace"]"#, used: "monospace"))?.style?.family == "Courier")
        // The face nearest in weight, leaning as asked.
        #expect(try node(style(#"["Helvetica"]"#, wt: 700))?.style?.face == "Bold")
        #expect(try node(style(#"["Helvetica"]"#, wt: 400, it: true))?.style?.face == "Oblique")
        // Case does not matter, as in CSS.
        #expect(try node(style(#"["helvetica neue"]"#, used: "helvetica neue"))?.style?.family == "Helvetica Neue")
        // A font of the page's own that this Mac lacks keeps its name, and is reported.
        let t = text("Aa", runs: "[[2,0]]", styles: [style(#"["Inter Nowhere", "Helvetica"]"#, used: "Inter Nowhere", web: true, wt: 600)],
                     lines: #"[{"from":0,"to":2,"x":0,"y":0,"w":20,"h":18,"base":14}]"#, cont: #"{"x":0,"y":0,"w":0,"align":"left","dir":"ltr","wrap":false}"#, clean: false)
        let (doc, report) = WebTest.convert(try WebTest.page(WebTest.html(t)))
        let web = try #require(doc.allNodes.first { $0.kind == .text })
        #expect(web.style?.family == "Inter Nowhere" && web.style?.face == "SemiBold")
        #expect(report.missingFonts.contains { $0.hasPrefix("Inter Nowhere") })
        // One the page asked for but could not load is passed over for the next.
        let fallback = try node(style(#"["Missing Font", "Georgia"]"#, used: "Georgia"))
        #expect(fallback?.style?.family == "Georgia")
        #expect(WebConverter.faceName(weight: 400, italic: true) == "Italic")
        #expect(WebConverter.faceName(weight: 800, italic: true) == "ExtraBold Italic")
        #expect(WebConverter.systemFace(weight: 350, italic: false) == "Light" || WebConverter.systemFace(weight: 350, italic: false) == "Regular")
    }

    @Test func leavesOutWordsNoOneSees() throws {
        let t = text("Hidden", runs: "[[6,0]]", styles: [style(c: "[0,0,0,0]")], lines: #"[{"from":0,"to":6,"x":0,"y":0,"w":20,"h":18,"base":14}]"#,
                     cont: #"{"x":0,"y":0,"w":0,"align":"left","dir":"ltr","wrap":false}"#)
        #expect(!WebTest.convert(try WebTest.page(WebTest.html(t))).0.allNodes.contains { $0.kind == .text })
        // Words painted with the background behind them show it.
        let paint = #","paint":{"bg":[0,0,0,0],"layers":[{"grad":"linear-gradient(to right, rgba(255, 0, 0, 1), rgba(0, 0, 255, 1))","rep":"repeat"}],"x":0,"y":0,"w":200,"h":40}"#
        let painted = text("Shine", runs: "[[5,0]]", styles: [style(c: "[0,0,0,0]")], lines: #"[{"from":0,"to":5,"x":0,"y":0,"w":40,"h":18,"base":14}]"#,
                           cont: #"{"x":0,"y":0,"w":200,"align":"left","dir":"ltr","wrap":true}"#, extra: paint)
        let shine = WebTest.convert(try WebTest.page(WebTest.html(painted))).0.allNodes.first { $0.kind == .text }
        #expect(shine?.fill.gradient?.kind == .linear)
    }

    @Test func artboardsLieSideBySideAndCarryThePagesColour() throws {
        let page = try WebTest.page(WebTest.html(), bg: "[0,0,0,0.5]")
        let mobile = try WebTest.page(WebTest.html(), w: 390, h: 1200)
        let (doc, report) = WebConverter.document([WebRead(name: "Desktop", page: page, assets: WebAssets()), WebRead(name: "Mobile", page: mobile, assets: WebAssets())], source: "example.com")
        #expect(doc.nodes.count == 2 && report.artboards == 2)
        #expect(doc.nodes[0].frame == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(doc.nodes[1].frame == CGRect(x: 1200, y: 0, width: 390, height: 1200) && doc.nodes[1].name == "Mobile")
        // A see-through page lies on white.
        #expect(WebTest.close(doc.nodes[0].fill.color, RGBA(r: 0.5, g: 0.5, b: 0.5)))
    }

    @Test func saysWhatTheReaderCouldOnlyComeCloseTo() throws {
        let page = try WebTest.page(WebTest.html(), notes: #"{"3d":2,"counter":1}"#)
        let (_, report) = WebTest.convert(page)
        #expect(report.notes.count == 2)
        #expect(report.notes.values.sorted() == [1, 2])
    }
}

// MARK: - Addresses, pictures, photographs

@MainActor
struct WebCaptureUnitTests {
    @Test func makesAddressesOfWhatWasTyped() {
        #expect(WebCapture.address("example.com")?.absoluteString == "https://example.com")
        #expect(WebCapture.address("  http://example.org/a?b=1 ")?.absoluteString == "http://example.org/a?b=1")
        #expect(WebCapture.address("localhost:3000")?.host == "localhost")
        #expect(WebCapture.address("not a page") == nil)
        #expect(WebCapture.address("ftp://example.com") == nil)
        #expect(WebCapture.address("word") == nil)
        #expect(WebCapture.address("") == nil)
        #expect(WebCapture.address("file:///tmp/a.html")?.isFileURL == true)
    }

    @Test func readsDataAddressesAndKnowsSVGs() {
        #expect(WebCapture.dataURL("data:text/plain;base64,SGVsbG8=") == Data("Hello".utf8))
        #expect(WebCapture.dataURL("data:image/svg+xml,%3Csvg%3E%3C/svg%3E") == Data("<svg></svg>".utf8))
        #expect(WebCapture.isSVG(Data("<?xml version=\"1.0\"?><svg xmlns=\"x\"/>".utf8), url: "a"))
        #expect(!WebCapture.isSVG(WebTest.png(2, 2, .black), url: "a.png"))
        #expect(WebCapture.assetName(Data("x".utf8), ext: "png").hasSuffix(".png"))
        #expect(WebCapture.assetName(Data("x".utf8), ext: "png") == WebCapture.assetName(Data("x".utf8), ext: "png"))
    }

    @Test func tellsWhatShowsThroughFromWhatIsThere() throws {
        func ctx(_ fill: (CGContext) -> Void) -> CGContext {
            let c = CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            fill(c)
            return c
        }
        // Red, half-clear black, and nothing at all, on white and on black.
        let white = ctx { c in
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            c.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }
        let black = ctx { c in
            c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let png = try #require(WebCapture.matted(white: white, black: black))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let out = ctx { $0.draw(image, in: CGRect(x: 0, y: 0, width: 3, height: 1)) }
        let p = try #require(out.data).assumingMemoryBound(to: UInt8.self)
        #expect(p[0] == 255 && p[1] == 0 && p[3] == 255)
        #expect(abs(Int(p[7]) - 127) <= 2 && p[4] <= 2)
        #expect(p[11] == 0)
    }

    @Test func offersSizesWidestFirstEachOnce() {
        let model = WebImporting()
        model.desktop = true
        model.mobile = true
        model.custom = true
        model.customWidth = 1440
        #expect(model.sizes.map(\.width) == [1440, 390])
        model.customWidth = 1024
        #expect(model.sizes.map(\.width) == [1440, 1024, 390])
        model.desktop = false
        model.mobile = false
        model.custom = false
        model.address = "example.com"
        #expect(!model.canStart)
        model.tablet = true
        #expect(model.canStart)
        model.address = "not a page"
        #expect(!model.canStart)
        #expect(WebCapture.Size.custom(375).mobile && !WebCapture.Size.custom(1280).mobile)
        #expect(WebCapture.Size.custom(10).width == 240)
    }

    @Test func theAssistantCanBringInAWebsite() async {
        let tools = MCPTools()
        #expect(tools.has("import_website"))
        let result = await tools.call("import_website", ["url": "not a page"])
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        #expect(object?["isError"] as? Bool == true)
    }
}

// MARK: - Pages read by WebKit

@MainActor
@Suite(.serialized)
struct WebPageReadingTests {
    @Test(.timeLimit(.minutes(5))) func readsAPageIntoBoxesAndWords() async throws {
        let css = """
        body { background: rgb(240, 240, 240); }
        header { height: 60px; background: rgb(20, 30, 40); display: flex; align-items: center; padding: 0 24px; }
        header h1 { color: white; font-size: 24px; margin: 0; font-weight: 700; }
        .card { margin: 40px; width: 300px; padding: 20px; background: white; border-radius: 16px; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2); }
        .card p { margin: 0; font-size: 16px; line-height: 24px; color: rgb(51, 51, 51); }
        .button { display: inline-block; margin-top: 16px; padding: 10px 20px; background: rgb(0, 102, 255); color: white; border-radius: 8px; font-size: 14px; }
        """
        let body = """
        <header><h1>Bezzle</h1></header>
        <div class="card"><p>Designs come from somewhere. This one comes from a web page, read by WebKit and taken apart into layers.</p><a class="button">Get started</a></div>
        """
        let (doc, report, read) = try await WebTest.design(body, css: css)
        let board = try #require(doc.nodes.first)
        #expect(board.frame.width == 800 && board.frame.height == 600)
        #expect(WebTest.close(board.fill.color, RGBA(r: 240 / 255, g: 240 / 255, b: 240 / 255)))
        let header = try #require(WebTest.filled(doc, RGBA(r: 20 / 255, g: 30 / 255, b: 40 / 255)).first)
        #expect(doc.absoluteFrame(of: header.id) == CGRect(x: 0, y: 0, width: 800, height: 60))
        // The heading, white and bold, on the browser's baseline.
        let title = try #require(doc.allNodes.first { $0.text == "Bezzle" })
        #expect(title.style?.size == 24 && title.style?.face == "Bold" && title.fill.color == .white)
        let line = try #require(WebTest.items(read.page).first { $0.text == "Bezzle" }?.lines?.first)
        let titleFrame = try #require(doc.absoluteFrame(of: title.id))
        #expect(abs(titleFrame.minY + TextLayout.firstBaseline(title) - CGFloat(line.base)) < 0.6)
        #expect(abs(titleFrame.minX - 24) < 0.6)
        // The card: its margin, padding, corners and shadow.
        let card = try #require(WebTest.filled(doc, .white).first { $0.cornerRadius == 16 })
        let cardFrame = try #require(doc.absoluteFrame(of: card.id))
        #expect(WebTest.close(cardFrame, CGRect(x: 40, y: 100, width: 340, height: cardFrame.height)))
        #expect(card.shadows.first?.blur == 12 && card.shadows.first?.y == 4 && abs((card.shadows.first?.color.a ?? 0) - 0.2) < 0.01)
        // The paragraph wraps in its box as the browser wrapped it.
        let paragraph = try #require(doc.allNodes.first { $0.text?.hasPrefix("Designs come") == true })
        let lines = try #require(WebTest.items(read.page).first { $0.text?.hasPrefix("Designs come") == true }?.lines)
        #expect(lines.count > 1)
        #expect(paragraph.style?.sizing == .autoHeight && paragraph.style?.lineSpacing == 24)
        #expect(WebConverter.lineCount(paragraph) == lines.count)
        #expect(abs((doc.absoluteFrame(of: paragraph.id)?.minX ?? 0) - 60) < 0.6)
        // The button, round and blue, its words white on it.
        let button = try #require(WebTest.filled(doc, RGBA(r: 0, g: 0.4, b: 1)).first)
        #expect(button.cornerRadius == 8)
        let label = try #require(doc.allNodes.first { $0.text == "Get started" })
        #expect(label.fill.color == .white && label.style?.size == 14)
        let buttonFrame = try #require(doc.absoluteFrame(of: button.id)), labelFrame = try #require(doc.absoluteFrame(of: label.id))
        #expect(buttonFrame.insetBy(dx: -1, dy: -1).contains(labelFrame))
        #expect(report.missingFonts.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func turnsStacksAndCutsAsThePageDoes() async throws {
        let css = """
        .rot { position: absolute; left: 100px; top: 100px; width: 100px; height: 50px; background: rgb(255, 0, 0); transform: rotate(45deg); }
        .badge { position: absolute; left: 300px; top: 50px; width: 80px; height: 80px; background: rgb(0, 0, 255); }
        .badge::before { content: ""; position: absolute; inset: 10px; background: rgb(0, 255, 0); }
        .clear::after { content: ""; display: table; clear: both; }
        .over { position: absolute; left: 0; top: 300px; width: 100px; height: 100px; background: rgb(0, 0, 0); z-index: 2; }
        .under { position: absolute; left: 50px; top: 350px; width: 100px; height: 100px; background: rgb(255, 255, 0); z-index: 1; }
        .clip { position: absolute; left: 400px; top: 300px; width: 100px; height: 100px; overflow: hidden; border-radius: 50px; background: rgb(200, 200, 200); }
        .clip div { width: 200px; height: 200px; background: rgb(255, 0, 255); }
        .gone { display: none; } .ghost { visibility: hidden; width: 10px; height: 10px; background: rgb(1, 2, 3); } .clear-away { opacity: 0; width: 10px; height: 10px; background: rgb(4, 5, 6); }
        """
        let body = """
        <div class="rot"></div><div class="badge"></div><div class="clear"></div>
        <div class="over"></div><div class="under"></div>
        <div class="clip"><div></div></div>
        <div class="gone" style="background: rgb(7, 8, 9); height: 10px"></div><div class="ghost"></div><div class="clear-away"></div>
        """
        let (doc, _, _) = try await WebTest.design(body, css: css)
        let rot = try #require(WebTest.filled(doc, RGBA(r: 1, g: 0, b: 0)).first)
        #expect(WebTest.close(rot.frame, CGRect(x: 100, y: 100, width: 100, height: 50)) && abs(rot.rotation - 45) < 0.01)
        // The pseudo-element is drawn, inside its box and over it; the clearfix is nothing.
        let badge = try #require(WebTest.filled(doc, RGBA(r: 0, g: 0, b: 1)).first)
        let before = try #require(WebTest.filled(doc, RGBA(r: 0, g: 1, b: 0)).first)
        #expect(doc.absoluteFrame(of: before.id) == CGRect(x: 310, y: 60, width: 60, height: 60))
        let order = doc.allNodes.map(\.id)
        #expect(order.firstIndex(of: badge.id)! < order.firstIndex(of: before.id)!)
        // z-index puts the black box over the yellow one, written after it.
        let over = try #require(WebTest.filled(doc, .black).first), under = try #require(WebTest.filled(doc, RGBA(r: 1, g: 1, b: 0)).first)
        #expect(order.firstIndex(of: over.id)! > order.firstIndex(of: under.id)!)
        // The round box cuts its square off at its round edge.
        let mask = try #require(doc.allNodes.first { $0.isMask })
        #expect(mask.children[0].kind == .ellipse && mask.children.contains { WebTest.close($0.fill.color, RGBA(r: 1, g: 0, b: 1)) })
        // What does not show is not brought in.
        for gone in [RGBA(r: 7 / 255, g: 8 / 255, b: 9 / 255), RGBA(r: 1 / 255, g: 2 / 255, b: 3 / 255), RGBA(r: 4 / 255, g: 5 / 255, b: 6 / 255)] {
            #expect(WebTest.filled(doc, gone).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(5))) func bringsWordsAcrossInAllTheirKinds() async throws {
        let css = """
        body { font-size: 16px; }
        .up { text-transform: uppercase; letter-spacing: 2px; }
        .grad { font-size: 40px; font-weight: 700; background: linear-gradient(90deg, rgb(255, 0, 0), rgb(0, 0, 255)); -webkit-background-clip: text; background-clip: text; color: transparent; display: inline-block; }
        ul { margin: 0; padding-left: 40px; }
        .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0, 0, 0, 0); }
        .hidden { visibility: hidden; } .none { display: none; } .zero { opacity: 0; }
        input { width: 200px; height: 40px; font-size: 14px; border: 1px solid rgb(0, 0, 0); padding: 0 10px; font-family: Helvetica; }
        """
        let body = """
        <p class="up">small caps</p>
        <p>Mixed <b>bold</b> and <span style="color: rgb(255, 0, 0)">red</span> words.</p>
        <div class="grad">Gradient</div>
        <ul><li>First</li><li>Second</li></ul>
        <span class="sr">Screen reader only</span>
        <p class="hidden">Hidden text</p><p class="none">None text</p><p class="zero">Zero text</p>
        <input placeholder="Your email">
        """
        let (doc, _, _) = try await WebTest.design(body, css: css)
        let texts = doc.allNodes.filter { $0.kind == .text }
        let up = try #require(texts.first { $0.text == "small caps" })
        #expect(up.style?.letterCase == .upper && up.style?.tracking == 125)
        let mixed = try #require(texts.first { $0.text == "Mixed bold and red words." })
        let runs = mixed.runs
        #expect(runs.contains { $0.text == "bold" && $0.look.resolved(over: mixed.style!, color: mixed.fill.color).face == "Bold" })
        #expect(runs.contains { $0.text == "red" && $0.look.resolved(over: mixed.style!, color: mixed.fill.color).color == RGBA(r: 1, g: 0, b: 0) })
        let gradient = try #require(texts.first { $0.text == "Gradient" })
        #expect(gradient.fill.gradient?.stops.first?.color == RGBA(r: 1, g: 0, b: 0))
        #expect(texts.filter { $0.text == "•" }.count == 2)
        let first = try #require(texts.first { $0.text == "First" }), bullet = try #require(texts.first { $0.text == "•" })
        #expect((doc.absoluteFrame(of: bullet.id)?.maxX ?? 99) < (doc.absoluteFrame(of: first.id)?.minX ?? 0))
        for gone in ["Screen reader only", "Hidden text", "None text", "Zero text"] { #expect(!texts.contains { $0.text == gone }) }
        let placeholder = try #require(texts.first { $0.text == "Your email" })
        #expect(placeholder.style?.size == 14)
        #expect(doc.allNodes.contains { $0.border.width == 1 && [200, 222].contains($0.frame.width) })
    }

    @Test(.timeLimit(.minutes(5))) func takesSVGsAndPicturesApart() async throws {
        let png = WebTest.png(20, 10, CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)).base64EncodedString()
        let svgPicture = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'%3E%3Ccircle cx='5' cy='5' r='5' fill='rgb(0,128,0)'/%3E%3C/svg%3E"
        let body = """
        <svg width="40" height="40" viewBox="0 0 20 20" style="display:block"><rect x="2" y="2" width="16" height="16" rx="3" fill="rgb(255,0,0)"/><path d="M5 10 L15 10" stroke="rgb(0,0,255)" stroke-width="2"/></svg>
        <img src="data:image/png;base64,\(png)" width="40" height="20" style="display:block">
        <img src="\(svgPicture)" width="50" height="50" style="display:block">
        <div style="width: 100px; height: 50px; background: url(data:image/png;base64,\(png)) center / cover no-repeat"></div>
        """
        let (read, held) = try await WebTest.read(body)
        let (doc, _) = WebConverter.document([read], source: "test")
        let square = try #require(WebTest.filled(doc, RGBA(r: 1, g: 0, b: 0)).first)
        #expect(square.kind == .path)
        #expect(WebTest.close(doc.absoluteFrame(of: square.id) ?? .zero, CGRect(x: 4, y: 4, width: 32, height: 32), 0.1))
        let stroke = try #require(doc.allNodes.first { $0.kind == .path && $0.border.color == RGBA(r: 0, g: 0, b: 1) })
        #expect(stroke.border.width == 4)
        // The PNG, kept with the design.
        let picture = try #require(doc.allNodes.first { $0.fill.image != nil && $0.frame.height == 20 })
        let asset = try #require(picture.fill.image?.asset)
        #expect(held[asset] != nil && picture.fill.image?.size == CGSize(width: 20, height: 10))
        #expect(WebTest.close(doc.absoluteFrame(of: picture.id) ?? .zero, CGRect(x: 0, y: 40, width: 40, height: 20)))
        // The SVG picture, as an outline.
        let circle = try #require(doc.allNodes.first { $0.kind == .path && WebTest.close($0.fill.color, RGBA(r: 0, g: 128 / 255, b: 0)) })
        #expect(WebTest.close(doc.absoluteFrame(of: circle.id) ?? .zero, CGRect(x: 0, y: 60, width: 50, height: 50), 0.1))
        // A background picture, covering its box.
        let back = try #require(doc.allNodes.first { $0.fill.image != nil && $0.frame.height == 50 && $0.frame.width == 100 })
        #expect(back.fill.image?.mode == .cover)
    }

    @Test(.timeLimit(.minutes(5))) func readsShadowRootsAndHidesCookieBanners() async throws {
        let body = """
        <div id="host"></div>
        <div id="onetrust-consent-sdk" style="position: fixed; bottom: 0; left: 0; right: 0; height: 100px; background: rgb(1, 2, 3)">We use cookies <button>Accept</button></div>
        <script>
          const root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<style>div { width: 50px; height: 50px; background: rgb(9, 99, 199); }</style><div></div>';
        </script>
        """
        let (doc, _, _) = try await WebTest.design(body)
        #expect(!WebTest.filled(doc, RGBA(r: 9 / 255, g: 99 / 255, b: 199 / 255)).isEmpty)
        #expect(WebTest.filled(doc, RGBA(r: 1 / 255, g: 2 / 255, b: 3 / 255)).isEmpty)
        #expect(!doc.allNodes.contains { $0.text?.contains("cookies") == true })
    }

    @Test(.timeLimit(.minutes(5))) func movesByTheTransformPropertiesOfTheirOwn() async throws {
        let css = """
        .c { position: absolute; left: 400px; top: 300px; width: 200px; height: 100px; translate: -50% -50%; background: rgb(0, 128, 255); }
        .s { position: absolute; left: 0; top: 0; width: 50px; height: 50px; scale: 2; transform-origin: 0 0; background: rgb(255, 128, 0); }
        .r { position: absolute; left: 600px; top: 0; width: 100px; height: 20px; rotate: 90deg; background: rgb(0, 128, 0); }
        .card { position: fixed; left: 10px; bottom: 10px; width: 180px; padding: 8px; background: rgb(3, 3, 3); color: white; font-size: 11px; }
        """
        let body = #"<div class="c"></div><div class="s"></div><div class="r"></div><div class="card">We use cookies to make this site better. <button>Ok</button></div>"#
        let (doc, _, _) = try await WebTest.design(body, css: css)
        let c = try #require(WebTest.filled(doc, RGBA(r: 0, g: 128 / 255, b: 1)).first)
        #expect(WebTest.close(c.frame, CGRect(x: 300, y: 250, width: 200, height: 100), 0.01))
        let s = try #require(WebTest.filled(doc, RGBA(r: 1, g: 128 / 255, b: 0)).first)
        #expect(WebTest.close(s.frame, CGRect(x: 0, y: 0, width: 100, height: 100), 0.01))
        let r = try #require(WebTest.filled(doc, RGBA(r: 0, g: 128 / 255, b: 0)).first)
        #expect(WebTest.close(r.frame, CGRect(x: 600, y: 0, width: 100, height: 20), 0.01) && abs(r.rotation - 90) < 0.01)
        // A small card about cookies, asking to be agreed to, is a banner, and goes.
        #expect(WebTest.filled(doc, RGBA(r: 3 / 255, g: 3 / 255, b: 3 / 255)).isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func photographsWhatCannotBeTakenApart() async throws {
        let body = """
        <input type="checkbox" checked style="margin: 20px">
        <div style="width: 60px; height: 60px; background: conic-gradient(rgb(255, 0, 0), rgb(0, 0, 255)); border-radius: 30px"></div>
        <span style="font-family: 'FontAwesome Nowhere'; font-size: 20px">\u{F00C}</span>
        """
        let (read, held) = try await WebTest.read(body)
        let items = WebTest.items(read.page)
        #expect(items.contains { $0.shot == "control" })
        #expect(items.contains { $0.shot == "icon" })
        #expect(!read.assets.shots.isEmpty, "the checkbox and the icon are photographed")
        #expect(!read.assets.backgrounds.isEmpty, "the conic gradient is photographed")
        for shot in read.assets.shots.values {
            #expect(held[shot.asset] != nil && shot.size.width > 0)
        }
        let (doc, _) = WebConverter.document([read], source: "test")
        #expect(doc.allNodes.contains { $0.fill.image?.mode == .stretch })
    }

    @Test(.timeLimit(.minutes(5))) func wrapsParagraphsAsTheBrowserDoes() async throws {
        let words = "The quick brown fox jumps over the lazy dog, and then it runs far away into the woods where nobody can find it again until spring."
        var body = ""
        for (w, size) in [(180, 14), (260, 16), (340, 18), (520, 15), (300, 22)] {
            body += "<p style=\"width: \(w)px; font-size: \(size)px; line-height: 1.5; margin: 0 0 20px\">\(words)</p>"
        }
        let (doc, _, read) = try await WebTest.design(body, size: WebCapture.Size(name: "Desktop", width: 800, height: 1200))
        let paragraphs = WebTest.items(read.page).filter { $0.text == words }
        #expect(paragraphs.count == 5)
        let nodes = doc.allNodes.filter { $0.text == words }
        #expect(nodes.count == 5)
        for (item, node) in zip(paragraphs, nodes.sorted { (doc.absoluteFrame(of: $0.id)?.minY ?? 0) < (doc.absoluteFrame(of: $1.id)?.minY ?? 0) }) {
            #expect(WebConverter.lineCount(node) == item.lines?.count, "\(node.style?.size ?? 0)")
            let frame = try #require(doc.absoluteFrame(of: node.id))
            #expect(abs(frame.minY + TextLayout.firstBaseline(node) - CGFloat(item.lines?.first?.base ?? 0)) < 0.6)
        }
    }

    @Test(.timeLimit(.minutes(5))) func laysOutFlexRowsWhereTheyAre() async throws {
        let css = """
        .row { display: flex; justify-content: space-between; align-items: center; width: 600px; height: 80px; margin: 10px; gap: 10px; }
        .row div { width: 100px; height: 40px; background: rgb(255, 0, 0); }
        .row div:nth-child(2) { height: 60px; background: rgb(0, 255, 0); }
        """
        let (doc, _, _) = try await WebTest.design(#"<div class="row"><div></div><div></div><div></div></div>"#, css: css)
        let reds = WebTest.filled(doc, RGBA(r: 1, g: 0, b: 0)).compactMap { doc.absoluteFrame(of: $0.id) }.sorted { $0.minX < $1.minX }
        #expect(reds == [CGRect(x: 10, y: 30, width: 100, height: 40), CGRect(x: 510, y: 30, width: 100, height: 40)])
        let green = try #require(WebTest.filled(doc, RGBA(r: 0, g: 1, b: 0)).first)
        #expect(doc.absoluteFrame(of: green.id) == CGRect(x: 260, y: 20, width: 100, height: 60))
    }

    @Test(.timeLimit(.minutes(5))) func cutsOffPagesLongerThanItReads() async throws {
        let capture = WebCapture()
        capture.stepDelay = 10
        capture.maxHeight = 1000
        defer { capture.close() }
        let (read, _) = try await capture.read(html: #"<body style="margin:0"><div style="height:3000px;background:linear-gradient(red,blue)"></div></body>"#, base: nil, size: WebTest.size)
        #expect(read.page.h == 1000 && (read.page.fullHeight ?? 0) >= 3000)
        let (doc, report) = WebConverter.document([read], source: "test")
        #expect(doc.nodes[0].frame.height == 1000)
        #expect(report.notes.keys.contains { $0.contains("cut off") })
    }

    @Test(.timeLimit(.minutes(5))) func writesADesignAtEverySizeFromAFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("web-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let site = folder.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try WebTest.png(8, 8, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)).write(to: site.appendingPathComponent("pic.png"))
        try """
        .box { width: 100px; height: 100px; background: rgb(255, 0, 0); }
        @media (max-width: 500px) { .box { background: rgb(0, 0, 255); width: 50px; } }
        .pic { width: 64px; height: 64px; background: url(pic.png) center / cover; }
        """.write(to: site.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><html><head><title>My / Site: Home</title><link rel="stylesheet" href="style.css"></head>
        <body style="margin: 0"><div class="box"></div><img src="pic.png" width="32" height="32"><div class="pic"></div></body></html>
        """.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let capture = WebCapture()
        capture.stepDelay = 10
        defer { capture.close() }
        var reads: [WebRead] = [], held: [String: Data] = [:]
        for size in [WebTest.size, WebCapture.Size.mobile] {
            let (read, pictures) = try await capture.read(site.appendingPathComponent("index.html"), size: size)
            reads.append(read)
            held.merge(pictures) { a, _ in a }
        }
        let (url, report) = try WebImport.write(reads, held: held, source: WebImport.source(of: site.appendingPathComponent("index.html")), into: folder)
        #expect(url.lastPathComponent.hasPrefix("My - Site, Home"))
        #expect(report.artboards == 2)
        let doc = try DesignFile.read(url)
        #expect(doc.nodes.count == 2 && doc.nodes[1].frame.minX == 1200 && doc.nodes[1].frame.width == 390)
        let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)
        let first = doc.nodes[0].children, second = doc.nodes[1].children
        #expect(first.contains { WebTest.close($0.fill.color, red) && $0.frame.width == 100 })
        #expect(second.contains { WebTest.close($0.fill.color, blue) && $0.frame.width == 50 })
        // The pictures went into the design with it.
        let images = url.appendingPathComponent(DesignFile.imagesFolder)
        let files = try FileManager.default.contentsOfDirectory(atPath: images.path)
        #expect(!files.isEmpty)
        let used = Set(doc.allNodes.compactMap { $0.fill.image?.asset })
        #expect(used.count >= 1 && used.isSubset(of: Set(files)))
    }

    @Test(.timeLimit(.minutes(5))) func failsWhenThePageCannotBeLoaded() async throws {
        let capture = WebCapture()
        defer { capture.close() }
        await #expect(throws: (any Error).self) {
            _ = try await capture.read(URL(fileURLWithPath: "/nowhere/at/all-\(UUID().uuidString).html"), size: WebTest.size)
        }
    }
}
