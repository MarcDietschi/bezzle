import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The Mac's own drawing of what the browser viewer once left out, for it to be compared with
/// (tools/compare.mjs): one design, `Features.bezzle`, made here and written as the Mac writes a
/// design, with an artboard for each: text on curves, lists with their markers, paragraphs set
/// apart, letters painted with a gradient or a picture, photos developed, blurs that grow along
/// a ramp, layers mixed as plus darker and plus lighter mix them, and shader fills as the design
/// shows them. Its texts are set in the faces `tools/fonts.py` copies (SF Pro, Avenir Next, Futura,
/// Bodoni 72), so what differs is the drawing and not a font that is not there.
///
/// Like WebTruthTests, this is copied into `BezzleTests/` to be run, with
/// `TEST_RUNNER_WEB_TRUTH_OUT=<dir>`. Everything goes to `<dir>/features`: the design, each
/// artboard drawn at 2×, and `truth.json` in the shape WebTruthTests writes, so
/// `node tools/compare.mjs --truth <dir>/features --designs <dir>/features` compares them.
@MainActor
struct FeatureTruthTests {
    private static let ink = RGBA(r: 0.12, g: 0.13, b: 0.2), soft = RGBA(r: 0.42, g: 0.44, b: 0.5)
    private static let blue = RGBA(r: 0.1, g: 0.3, b: 0.9), red = RGBA(r: 0.85, g: 0.22, b: 0.18), green = RGBA(r: 0.1, g: 0.6, b: 0.3)
    private static let paper = RGBA(r: 0.97, g: 0.96, b: 0.94)
    private static let photo = "lake.jpg", stripes = "stripes.png", glow = "glow.png"
    private static let stripesSize = CGSize(width: 600, height: 300)

    private static func text(_ runs: [TextSpan], family: String = TextStyle.system, face: String = "Regular", size: CGFloat = 16,
                             sizing: TextSizing = .autoWidth, width: CGFloat = 10, height: CGFloat = 10, align: TextAlign = .left,
                             tracking: CGFloat = 0, lineSpacing: CGFloat? = nil, paragraphSpacing: CGFloat? = nil, color: RGBA = ink,
                             name: String, at: CGPoint) -> Node {
        var n = Node(kind: .text, name: name, frame: CGRect(origin: at, size: CGSize(width: width, height: height)))
        var s = TextStyle()
        s.family = family
        s.face = face
        s.size = size
        s.sizing = sizing
        s.align = align
        s.tracking = tracking
        s.lineSpacing = lineSpacing
        s.paragraphSpacing = paragraphSpacing
        n.style = s
        n.fill.color = color
        n.setRuns(runs)
        n.refit()
        return n
    }

    private static func words(_ s: String) -> [TextSpan] { [TextSpan(text: s)] }

    private static func board(_ name: String, x: CGFloat, size: CGSize, color: RGBA = paper, _ children: [Node]) -> Node {
        var b = Node(kind: .artboard, name: name, frame: CGRect(origin: CGPoint(x: x, y: 0), size: size))
        b.fill.color = color
        b.children = children
        return b
    }

    private static func picture(_ name: String, _ asset: String, _ frame: CGRect, size: CGSize, radius: CGFloat = 0) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.fill.image = ImageFill(asset: asset, mode: .cover, size: size)
        n.cornerRadius = radius
        return n
    }

    private static let warm = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.98, g: 0.45, b: 0.15)),
                                                              GradientStop(offset: 0.5, color: RGBA(r: 0.85, g: 0.15, b: 0.55)),
                                                              GradientStop(offset: 1, color: RGBA(r: 0.2, g: 0.35, b: 0.95))],
                                       start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
    private static let sky = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.1, g: 0.6, b: 0.9)),
                                                             GradientStop(offset: 1, color: RGBA(r: 0.1, g: 0.75, b: 0.35))],
                                      start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
    private static let sun = Gradient(kind: .radial, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 0.85, b: 0.1)),
                                                             GradientStop(offset: 1, color: RGBA(r: 0.75, g: 0.1, b: 0.1))],
                                      start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1, y: 0.5))

    /// A picture of coloured stripes across and a light falling down it, so where a picture is
    /// placed, blurred or mixed shows in the colours it takes.
    private static func stripesPNG() -> Data? {
        let w = Int(stripesSize.width), h = Int(stripesSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.95, 0.6, 0.1), (0.2, 0.7, 0.3), (0.1, 0.5, 0.9), (0.5, 0.2, 0.8), (0.1, 0.1, 0.1)]
        for (k, c) in colors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(k) * stripesSize.width / CGFloat(colors.count), y: 0, width: stripesSize.width / CGFloat(colors.count), height: stripesSize.height))
        }
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: stripesSize.height), end: CGPoint(x: 0, y: 0), options: [])
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: Text on curves

    private static func curves() -> Node {
        var arch = text(words("Words bent into an arch"), face: "Bold", size: 30, name: "arch", at: CGPoint(x: 40, y: 70))
        arch.bend(to: 0.3)
        var sag = text(words("And a line that sags"), family: "Avenir Next", face: "Demi Bold", size: 26, color: blue, name: "sag", at: CGPoint(x: 420, y: 40))
        sag.bend(to: -0.35)
        var ring = text(words("ROUND AND ROUND AND ROUND AGAIN "), family: "Futura", face: "Medium", size: 20, color: red, name: "ring", at: CGPoint(x: 60, y: 250))
        ring.bend(to: 1)
        var spaced = text([TextSpan(text: "Spaced "), TextSpan(text: "bold", look: TextLook(face: "Bold")), TextSpan(text: " and "),
                           TextSpan(text: "green", look: TextLook(color: green)), TextSpan(text: " and "),
                           TextSpan(text: "under", look: TextLook(underline: true)), TextSpan(text: " it")],
                          family: "Avenir Next", size: 20, tracking: 80, name: "spaced", at: CGPoint(x: 380, y: 170))
        spaced.bend(to: 0.2)
        var painted = text(words("Painted arc"), face: "Heavy", size: 44, name: "painted", at: CGPoint(x: 400, y: 300))
        painted.fill.gradient = warm
        painted.bend(to: 0.25)
        var turned = text(words("Turned and bent"), family: "Bodoni 72", face: "Book", size: 28, name: "turned", at: CGPoint(x: 420, y: 430))
        turned.rotation = -12
        turned.bend(to: 0.4)
        var faded = text(words("Faded on its curve"), size: 22, color: soft, name: "faded", at: CGPoint(x: 60, y: 500))
        faded.opacity = 0.6
        faded.bend(to: -0.15)
        return board("Curves", x: 0, size: CGSize(width: 760, height: 580), [arch, sag, ring, spaced, painted, turned, faded])
    }

    /// Texts riding shapes' outlines, which only a design can lay: put on after the artboards are in it.
    private static func ride(in doc: inout BezzleDocument) {
        var oval = Node(kind: .ellipse, name: "Oval", frame: CGRect(x: 250, y: 250, width: 150, height: 110))
        oval.fill.on = false
        oval.border = Border(on: true, color: RGBA(r: 0.7, g: 0.72, b: 0.78), width: 1, position: .center)
        let onOval = text(words("Riding the outline of a shape"), family: "Avenir Next", face: "Medium", size: 15, name: "on oval", at: CGPoint(x: 260, y: 230))
        var wave = Node.path(BezierPath("M 250 470 C 300 410 350 530 400 470 C 450 410 500 530 550 470"), name: "Wave")
        wave.fill.on = false
        wave.border = Border(on: true, color: RGBA(r: 0.7, g: 0.72, b: 0.78), width: 1, position: .center)
        let onWave = text(words("Hanging from a wave, read the other way"), family: "Bodoni 72", face: "Book", size: 17, color: blue, name: "on wave", at: CGPoint(x: 260, y: 500))
        doc.nodes[0].children += [oval, onOval, wave, onWave]
        doc.ride(onOval.id, on: oval.id, curve: TextCurve(rides: true))
        doc.ride(onWave.id, on: wave.id, curve: TextCurve(rides: true, at: 0.5, reversed: true, hangs: true))
    }

    // MARK: Lists and paragraphs

    private static func lists() -> Node {
        func items(_ list: TextList, _ lines: [String]) -> [TextSpan] {
            lines.enumerated().map { TextSpan(text: $0.element + ($0.offset + 1 < lines.count ? "\n" : ""), look: TextLook(list: list)) }
        }
        let bullets = text(items(.bullet, ["Bread", "Olive oil", "Lemons"]), size: 16, name: "bullets", at: CGPoint(x: 30, y: 30))
        let numbers = text(items(.number, ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven"]),
                           family: "Avenir Next", size: 15, name: "numbers", at: CGPoint(x: 200, y: 30))
        let mixed = text(items(.number, ["First of two", "Second of two"]) + [TextSpan(text: "\n")] + items(.bullet, ["Then a bullet", "And one more"])
                         + [TextSpan(text: "\nA plain line after the list")],
                         family: "Futura", face: "Medium", size: 17, name: "mixed", at: CGPoint(x: 400, y: 30))
        let wrapped = text(items(.bullet, ["An item that runs long enough to wrap over several lines of its column", "A short one",
                                           "And another long one, so that the lines after an item's first begin where its words do"]),
                           size: 14, sizing: .autoHeight, width: 250, name: "wrapped", at: CGPoint(x: 30, y: 150))
        let spaced = text(items(.number, ["Lines set apart", "by a line spacing", "of their own"]), family: "Avenir Next", face: "Medium", size: 16,
                          lineSpacing: 30, name: "spaced", at: CGPoint(x: 30, y: 330))
        let big = text([TextSpan(text: "Large first", look: TextLook(size: 26, list: .bullet)), TextSpan(text: " then small\n", look: TextLook(list: .bullet)),
                        TextSpan(text: "Red item\n", look: TextLook(color: red, list: .bullet)),
                        TextSpan(text: "Bold item", look: TextLook(face: "Bold", list: .bullet))],
                       family: "Bodoni 72", face: "Book", size: 18, name: "sizes", at: CGPoint(x: 400, y: 190))
        let centred = text(items(.number, ["Centred items of a list", "in a column of their own, which wraps"]), size: 15,
                           sizing: .autoHeight, width: 220, align: .center, name: "centred", at: CGPoint(x: 400, y: 330))
        let right = text(items(.bullet, ["Set from the right", "as some lists are"]), family: "Futura", face: "Medium", size: 15,
                         sizing: .autoHeight, width: 220, align: .right, name: "right", at: CGPoint(x: 400, y: 430))
        return board("Lists", x: 820, size: CGSize(width: 680, height: 520), [bullets, numbers, mixed, wrapped, spaced, big, centred, right])
    }

    private static let prose = "Design is not just what it looks like and feels like.\nDesign is how it works, and how each part of a page holds the next one in place.\nA third paragraph follows, so that there are two gaps to see."

    private static func paragraphs() -> Node {
        let system = text(words(prose), size: 15, sizing: .autoHeight, width: 300, paragraphSpacing: 12, name: "system 12", at: CGPoint(x: 30, y: 30))
        let avenir = text(words(prose), family: "Avenir Next", size: 14, sizing: .autoHeight, width: 300, lineSpacing: 22, paragraphSpacing: 24,
                          name: "avenir 24 on 22", at: CGPoint(x: 360, y: 30))
        let futura = text(words(prose), family: "Futura", face: "Medium", size: 15, sizing: .autoHeight, width: 300, align: .center, paragraphSpacing: 8,
                          name: "futura centred", at: CGPoint(x: 30, y: 240))
        let bodoni = text(words(prose), family: "Bodoni 72", face: "Book", size: 16, sizing: .autoHeight, width: 300, align: .justify, paragraphSpacing: 16,
                          name: "bodoni justified", at: CGPoint(x: 360, y: 280))
        let broken = text(words("A line broken by hand\u{2028}stays in its paragraph.\n\nAn empty paragraph lay before this one.\nThe last."), size: 14,
                          sizing: .autoHeight, width: 300, paragraphSpacing: 10, name: "breaks", at: CGPoint(x: 30, y: 440))
        var middle = text(words("Two paragraphs\nin the middle of a box"), family: "Avenir Next", face: "Medium", size: 16, sizing: .fixed, width: 300, height: 120,
                          align: .center, paragraphSpacing: 14, name: "middle", at: CGPoint(x: 360, y: 480))
        middle.style?.vertical = .middle
        let list = text([TextSpan(text: "Items set apart\n", look: TextLook(list: .number)), TextSpan(text: "as paragraphs are\n", look: TextLook(list: .number)),
                         TextSpan(text: "each with its number", look: TextLook(list: .number))],
                        size: 15, paragraphSpacing: 9, name: "list apart", at: CGPoint(x: 30, y: 560))
        return board("Paragraphs", x: 1560, size: CGSize(width: 690, height: 660), [system, avenir, futura, bodoni, broken, middle, list])
    }

    // MARK: Painted letters

    private static func painted() -> Node {
        var gradient = text(words("Gradient"), face: "Bold", size: 64, name: "linear", at: CGPoint(x: 30, y: 30))
        gradient.fill.gradient = warm
        var radial = text(words("Radial"), family: "Bodoni 72", face: "Bold", size: 64, name: "radial", at: CGPoint(x: 380, y: 30))
        radial.fill.gradient = sun
        var lake = text(words("Lake"), family: "Futura", face: "Bold", size: 96, name: "photo", at: CGPoint(x: 30, y: 120))
        lake.fill.image = ImageFill(asset: photo, mode: .cover, size: WelcomePhoto.size)
        var striped = text(words("Stripes"), family: "Avenir Next", face: "Heavy", size: 72, name: "stripes", at: CGPoint(x: 330, y: 130))
        striped.fill.image = ImageFill(asset: stripes, mode: .cover, size: stripesSize)
        var mixed = text([TextSpan(text: "Own "), TextSpan(text: "colour", look: TextLook(color: blue)), TextSpan(text: " among "),
                          TextSpan(text: "painted", look: TextLook(underline: true)), TextSpan(text: " and "),
                          TextSpan(text: "struck", look: TextLook(strikethrough: true)), TextSpan(text: " letters", look: TextLook(color: green, underline: true))],
                         face: "Bold", size: 30, name: "own colours", at: CGPoint(x: 30, y: 260))
        mixed.fill.gradient = warm
        var list = text([TextSpan(text: "Painted item\n", look: TextLook(list: .bullet)), TextSpan(text: "Blue item\n", look: TextLook(color: blue, list: .bullet)),
                         TextSpan(text: "Numbered\n", look: TextLook(list: .number)), TextSpan(text: "And on", look: TextLook(list: .number))],
                        family: "Avenir Next", size: 22, name: "list", at: CGPoint(x: 30, y: 320))
        list.fill.gradient = sky
        var centred = text(words("Centred lines of painted words that wrap over three lines or so"), family: "Bodoni 72", face: "Book", size: 24,
                           sizing: .autoHeight, width: 300, align: .center, name: "centred", at: CGPoint(x: 370, y: 320))
        centred.fill.gradient = warm
        var fit = text(words("Fitted picture"), face: "Bold", size: 40, name: "fit", at: CGPoint(x: 30, y: 470))
        fit.fill.image = ImageFill(asset: stripes, mode: .fit, size: stripesSize)
        var faded = text(words("Faded"), face: "Bold", size: 56, name: "faded", at: CGPoint(x: 400, y: 450))
        faded.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0.1, g: 0.2, b: 0.8, a: 1)),
                                                              GradientStop(offset: 1, color: RGBA(r: 0.9, g: 0.1, b: 0.3, a: 0.4))],
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        faded.opacity = 0.7
        var bordered = text(words("Edged"), family: "Futura", face: "Bold", size: 60, name: "bordered", at: CGPoint(x: 30, y: 540))
        bordered.fill.gradient = sky
        bordered.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.35), x: 0, y: 4, blur: 8)
        return board("Painted", x: 2310, size: CGSize(width: 720, height: 640), [gradient, radial, lake, striped, mixed, list, centred, fit, faded, bordered])
    }

    // MARK: Photos developed

    private static func developed() -> Node {
        func develop(_ set: (inout Develop) -> Void) -> Develop {
            var d = Develop()
            set(&d)
            return d
        }
        let all: [(String, Develop?)] = [
            ("As taken", nil),
            ("Exposure, contrast", develop { $0[.exposure] = 0.8; $0[.contrast] = 35 }),
            ("Tones", develop { $0[.highlights] = -60; $0[.shadows] = 55; $0[.whites] = 25; $0[.blacks] = -20 }),
            ("Colour", develop { $0[.temperature] = 40; $0[.tint] = -20; $0[.vibrance] = 50; $0[.saturation] = -15 }),
            ("Clarity", develop { $0[.clarity] = 70 }),
            ("Texture, sharpness", develop { $0[.texture] = 60; $0[.sharpness] = 70 }),
            ("Dehaze", develop { $0[.dehaze] = 55 }),
            ("Haze, a band turned", develop { $0[.dehaze] = -40; var s = Develop.Shift(); s[.hue] = 40; s[.saturation] = 30; s[.luminance] = -10; $0[.blue] = s }),
            ("Everything", develop { $0[.exposure] = -0.4; $0[.contrast] = 20; $0[.shadows] = 30; $0[.temperature] = -25; $0[.vibrance] = 30
                $0[.clarity] = 30; $0[.texture] = 20; $0[.dehaze] = 20; $0[.sharpness] = 40 }),
        ]
        var children: [Node] = []
        for (k, (name, d)) in all.enumerated() {
            let x = 30 + CGFloat(k % 3) * 230, y = 30 + CGFloat(k / 3) * 190
            var shot = picture(name, photo, CGRect(x: x, y: y, width: 210, height: 150), size: WelcomePhoto.size, radius: 8)
            shot.fill.image?.develop = d
            children.append(shot)
            children.append(text(words(name), size: 12, color: soft, name: "label \(k)", at: CGPoint(x: x, y: y + 156)))
        }
        return board("Developed", x: 3090, size: CGSize(width: 750, height: 610), children)
    }

    // MARK: Blurs along a ramp

    private static func rampBlurs() -> Node {
        let across = BlurRamp(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        let slant = BlurRamp(start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.9, y: 0.9))
        // A layer's own blur, growing: a photo, a picture of stripes turned, words, and a group.
        var lake = picture("Photo down", photo, CGRect(x: 30, y: 30, width: 210, height: 150), size: WelcomePhoto.size, radius: 10)
        lake.blur = Blur(radius: 12, ramp: .down)
        var bars = picture("Stripes across", stripes, CGRect(x: 270, y: 40, width: 200, height: 120), size: stripesSize)
        bars.blur = Blur(radius: 10, ramp: across)
        bars.rotation = 12
        var headline = text(words("Sharp to soft"), face: "Bold", size: 44, name: "Words left", at: CGPoint(x: 500, y: 40))
        headline.blur = Blur(radius: 7, ramp: .toward(3))
        var card = Parts.rect("Card", CGRect(x: 0, y: 0, width: 180, height: 110), .white, radius: 14)
        card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.3), x: 0, y: 6, blur: 14)
        let dot = Parts.oval("Dot", CGRect(x: 18, y: 18, width: 40, height: 40), red)
        let line = text(words("A group, slanting"), size: 15, name: "line", at: CGPoint(x: 18, y: 72))
        var group = Parts.group("Group slant", [card, dot, line])
        group.frame.origin = CGPoint(x: 520, y: 110)
        group.blur = Blur(radius: 9, ramp: slant)
        var even = picture("Even", stripes, CGRect(x: 30, y: 200, width: 160, height: 60), size: stripesSize)
        even.blur = Blur(radius: 6)
        var up = picture("Photo up", photo, CGRect(x: 220, y: 190, width: 150, height: 90), size: WelcomePhoto.size)
        up.blur = Blur(radius: 5, ramp: .toward(2))

        // What lies behind, blurred more toward one edge: glass over stripes, a photo and words.
        let ground = picture("Ground", stripes, CGRect(x: 30, y: 300, width: 700, height: 250), size: stripesSize)
        var behind = picture("Behind", photo, CGRect(x: 420, y: 320, width: 290, height: 210), size: WelcomePhoto.size)
        behind.rotation = -4
        let said = text(words("What lies behind the glass"), face: "Bold", size: 34, color: .white, name: "Behind words", at: CGPoint(x: 50, y: 400))
        func glass(_ name: String, _ frame: CGRect, _ blur: Blur, radius: CGFloat = 16) -> Node {
            var g = Parts.rect(name, frame, .white, radius: radius)
            g.blur = blur
            g.border = Border(on: true, color: RGBA(r: 1, g: 1, b: 1, a: 0.6), width: 1, position: .inside)
            return g
        }
        let down = glass("Glass down", CGRect(x: 60, y: 320, width: 190, height: 210), Blur(radius: 14, background: true, fillOpacity: 0.15, ramp: .down))
        let right = glass("Glass right", CGRect(x: 270, y: 330, width: 170, height: 190), Blur(radius: 18, background: true, brightness: 0.2, ramp: .toward(3)))
        var turned = glass("Glass turned", CGRect(x: 470, y: 340, width: 220, height: 170), Blur(radius: 10, background: true, brightness: -0.25, ramp: slant), radius: 40)
        turned.rotation = 8
        return board("Ramp blurs", x: 3900, size: CGSize(width: 760, height: 580), [lake, bars, headline, group, even, up, ground, behind, said, down, right, turned])
    }

    // MARK: Plus darker and plus lighter

    private static func mixing() -> Node {
        let ground = picture("Ground", stripes, CGRect(x: 0, y: 0, width: 720, height: 300), size: stripesSize)
        let lake = picture("Photo", photo, CGRect(x: 0, y: 300, width: 360, height: 240), size: WelcomePhoto.size)
        var tones = Parts.rect("Tones", CGRect(x: 360, y: 300, width: 360, height: 240), .white)
        tones.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: .white), GradientStop(offset: 1, color: .black)],
                                       start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        var children = [ground, lake, tones]
        let colors: [RGBA] = [RGBA(r: 0.9, g: 0.75, b: 0.4), RGBA(r: 0.45, g: 0.7, b: 0.95), RGBA(r: 0.6, g: 0.6, b: 0.6), RGBA(r: 0.95, g: 0.3, b: 0.5)]
        for (row, mode) in [BlendMode.plusDarker, .plusLighter].enumerated() {
            for (k, c) in colors.enumerated() {
                var o = Parts.oval("\(mode.rawValue) \(k)", CGRect(x: 30 + CGFloat(k) * 170, y: 20 + CGFloat(row) * 140, width: 150, height: 110), c)
                o.blend = mode
                // The second faded as a layer, the fourth by its colour's own alpha.
                if k == 1 { o.opacity = 0.6 }
                if k == 3 { o.fill.color = c.with(alpha: 0.55) }
                children.append(o)
            }
        }
        // Over the photo and the tones: a gradient, a picture, words and a group, each mixed.
        var band = Parts.rect("Band darker", CGRect(x: 20, y: 320, width: 320, height: 60), .white, radius: 12)
        band.fill.gradient = warm
        band.blend = .plusDarker
        var shot = picture("Picture lighter", stripes, CGRect(x: 380, y: 320, width: 150, height: 90), size: stripesSize, radius: 12)
        shot.blend = .plusLighter
        var shade = picture("Picture darker", stripes, CGRect(x: 550, y: 320, width: 150, height: 90), size: stripesSize, radius: 12)
        shade.blend = .plusDarker
        var label = text(words("Darker words"), face: "Heavy", size: 40, color: RGBA(r: 0.75, g: 0.8, b: 0.3), name: "Words darker", at: CGPoint(x: 30, y: 400))
        label.blend = .plusDarker
        var lit = text(words("Lighter words"), face: "Heavy", size: 40, color: RGBA(r: 0.3, g: 0.35, b: 0.6), name: "Words lighter", at: CGPoint(x: 400, y: 425))
        lit.blend = .plusLighter
        var plate = Parts.rect("Plate", CGRect(x: 0, y: 0, width: 140, height: 50), RGBA(r: 0.8, g: 0.85, b: 0.9), radius: 10)
        plate.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.4), x: 0, y: 4, blur: 8)
        let knob = Parts.oval("Knob", CGRect(x: 100, y: 10, width: 30, height: 30), RGBA(r: 0.95, g: 0.6, b: 0.2))
        var group = Parts.group("Group darker", [plate, knob])
        group.frame.origin = CGPoint(x: 40, y: 470)
        group.blend = .plusDarker
        group.opacity = 0.85
        // What lies behind a pane made darker or lighter, which is mixed the same two ways.
        var dim = Parts.rect("Pane darker", CGRect(x: 220, y: 460, width: 130, height: 66), .white, radius: 10)
        dim.blur = Blur(radius: 6, background: true, brightness: -0.35)
        var bright = Parts.rect("Pane lighter", CGRect(x: 380, y: 480, width: 130, height: 50), .white, radius: 10)
        bright.blur = Blur(radius: 6, background: true, brightness: 0.35)
        var dimmer = Parts.rect("Pane darkest", CGRect(x: 540, y: 470, width: 160, height: 60), .white, radius: 10)
        dimmer.blur = Blur(radius: 4, background: true, brightness: -0.7)
        children += [band, shot, shade, label, lit, group, dim, bright, dimmer]
        return board("Mixing", x: 4720, size: CGSize(width: 720, height: 540), color: .white, children)
    }

    // MARK: Shader fills in the design

    /// Bands that drift with time, see-through between them, as strong as an input says.
    private static let waves = "precision highp float; uniform vec2 u_resolution; uniform float u_time; uniform float u_strength;"
        + " void main() { vec2 p = gl_FragCoord.xy / u_resolution;"
        + " float w = 0.5 + 0.5 * sin(6.2831853 * (p.x * 1.5 + u_time * 0.4)) * cos(6.2831853 * (p.y - u_time * 0.25));"
        + " vec3 c = mix(vec3(0.07, 0.11, 0.32), vec3(0.98, 0.56, 0.25), w * u_strength);"
        + " float a = 0.35 + 0.65 * w; gl_FragColor = vec4(c * a, a); }"

    /// Rings round a point, in solid colours.
    private static let rings = "precision highp float; uniform vec2 u_resolution; uniform float u_time;"
        + " void main() { vec2 p = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;"
        + " float r = length(p - vec2(0.2 * sin(u_time), 0.1));"
        + " float w = 0.5 + 0.5 * cos(40.0 * r - u_time * 3.0);"
        + " gl_FragColor = vec4(mix(vec3(0.95, 0.9, 0.8), vec3(0.15, 0.4, 0.75), w), 1.0); }"

    private static func shaders() -> Node {
        // As it came in: its picture is what it draws at its moment, so either shows the same.
        var first = Parts.rect("As it came in", CGRect(x: 30, y: 30, width: 300, height: 200), .white, radius: 24)
        first.fill.shader = ShaderFill.surface(fragment: waves, size: CGSize(width: 600, height: 400), uniforms: ["u_strength": [1]])
        first.fill.image = ImageFill(asset: glow, mode: .stretch, size: CGSize(width: 600, height: 400))
        // Moved on since: another moment and a weaker input, which the picture does not show.
        var second = Parts.rect("Moved on", CGRect(x: 360, y: 30, width: 300, height: 200), .white, radius: 24)
        var later = ShaderFill.surface(fragment: waves, size: CGSize(width: 600, height: 400), uniforms: ["u_strength": [0.45]])
        later.at = 1.3
        second.fill.shader = later
        second.fill.image = ImageFill(asset: glow, mode: .stretch, size: CGSize(width: 600, height: 400))
        // In an oval, turned, and faded, with no picture at all.
        var third = Parts.oval("Rings", CGRect(x: 60, y: 260, width: 240, height: 170), .white)
        var ringed = ShaderFill.surface(fragment: rings, size: CGSize(width: 480, height: 340))
        ringed.at = 0.6
        third.fill.shader = ringed
        third.rotation = -10
        // Cover, in a box of another shape than its drawing: only part of it shows.
        var fourth = Parts.rect("Covering", CGRect(x: 380, y: 270, width: 260, height: 150), .white, radius: 12)
        fourth.fill.shader = ringed
        fourth.fill.image = ImageFill(asset: glow, mode: .cover, size: CGSize(width: 600, height: 400))
        fourth.opacity = 0.8
        let caption = text(words("Shader fills, as the design shows them"), size: 14, color: soft, name: "caption", at: CGPoint(x: 30, y: 450))
        return board("Shaders", x: 5500, size: CGSize(width: 690, height: 490), color: RGBA(r: 0.93, g: 0.94, b: 0.96), [first, second, third, fourth, caption])
    }

    // MARK: The truth

    @Test func dumpFeatures() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth").appendingPathComponent("features", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var doc = BezzleDocument()
        doc.nodes = [Self.curves(), Self.lists(), Self.paragraphs(), Self.painted(), Self.developed(), Self.rampBlurs(), Self.mixing(), Self.shaders()]
        Self.ride(in: &doc)
        doc.fitGroups()

        let url = root.appendingPathComponent("Features.bezzle")
        try DesignFile.write(doc, to: url)
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try #require(WelcomePhoto.jpeg()).write(to: images.appendingPathComponent(Self.photo))
        try #require(Self.stripesPNG()).write(to: images.appendingPathComponent(Self.stripes))
        // The first shader's picture: what the Mac draws of it at its moment, as an import keeps it.
        var alone = Node(kind: .artboard, name: "Glow", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        alone.fill.on = false
        var whole = Parts.rect("Whole", CGRect(x: 0, y: 0, width: 300, height: 200), .white)
        whole.fill.shader = ShaderFill.surface(fragment: Self.waves, size: CGSize(width: 600, height: 400), uniforms: ["u_strength": [1]])
        alone.children = [whole]
        try write(try #require(Renderer.image(of: alone, scale: 2, assets: Assets(design: url))), to: images.appendingPathComponent(Self.glow))

        // Read back as the app opens it, so what is drawn is what the file holds.
        let read = try DesignFile.read(url)
        let assets = Assets(design: url)
        var texts: [[String: Any]] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if n.kind == .text, !n.isCurved { texts.append(describe(n)) }
                walk(n.children)
            }
        }
        walk(read.nodes)
        var boards: [[String: Any]] = []
        for (i, board) in read.nodes.enumerated() where board.isArtboard {
            let file = "Features-\(i).png"
            try write(try #require(Renderer.image(of: board, scale: 2, assets: assets)), to: root.appendingPathComponent(file))
            boards.append(["index": i, "name": board.name, "file": file, "frame": [board.frame.minX, board.frame.minY, board.frame.width, board.frame.height]])
        }
        let all: [String: Any] = ["Features": ["texts": texts, "boards": boards]]
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("truth.json"))
    }

    private func describe(_ n: Node) -> [String: Any] {
        let laid = TextLayout.layout(n)
        let manager = laid.manager
        var lines: [[Double]] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let baseline = rect.minY + manager.location(forGlyphAt: glyphs.location).y
            lines.append([Double(chars.location), Double(NSMaxRange(chars)), Double(rect.minY), Double(rect.height), Double(used.width), Double(baseline)])
        }
        let style = n.style ?? TextStyle()
        let markers = TextLayout.markers(manager).map { [$0.text, Double($0.at.x), Double($0.at.y), Double($0.font.pointSize)] as [Any] }
        return [
            "id": n.id.uuidString, "name": n.name, "text": laid.storage.string,
            "frame": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height],
            "family": style.family, "face": style.face, "size": style.size, "sizing": "\(style.sizing)",
            "used": [laid.usedSize.width, laid.usedSize.height],
            "natural": TextLayout.naturalWidth(n), "firstBaseline": TextLayout.firstBaseline(n),
            "fitted": { let f = TextLayout.fittedFrame(n); return [f.width, f.height] }(),
            "lines": lines, "markers": markers,
        ]
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
