// Draws Bezzle's app icon: a mark pressed into the same warm paper tile as Distill's drop and Gerty's rings,
// some with Bezzle's one colour, the draftsman's blue pencil, inked into it.
//
// Usage: swift Scripts/make-icon.swift            renders `chosen` into the asset catalog
//        swift Scripts/make-icon.swift drafts     renders every draft, and a lineup of them between Distill and
//                                                 Gerty, into Branding/drafts
//        swift Scripts/make-icon.swift document   renders the icon designs carry in the Finder into
//                                                 Bezzle/App/BezzleDocument.icns
//        swift Scripts/make-icon.swift <draft>    renders that one into Branding/drafts
import AppKit
import CoreGraphics
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let chosen = "layers"
let only = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// The floor of an impression inked with Theme.pencil, darker under its top edge, as Distill's copper is, and
/// as muted as it, so the three sit together: a blue pencil's lead rather than the screen's.
let pencilFloor = [(CGFloat(0), color(0x2B4596)), (0.6, color(0x3D5DB8)), (1, color(0x5373C6))]
/// The floor of a bare impression, as Gerty's rings have: the paper a shade darker, and darker again a step down.
let paperFloor = [(CGFloat(0), color(0xDDD8CE)), (1, color(0xE8E4DC))]
let paperFloor2 = [(CGFloat(0), color(0xD3CDC1)), (1, color(0xE0DBD1))]
let paperFloor3 = [(CGFloat(0), color(0xC9C2B5)), (1, color(0xD8D2C6))]

/// How an impression is lit: the paper around it shaded above and lit along its lower rim, its walls shadowed
/// deep and then tightly under the top edge, and light on the bottom wall.
struct Walls { var rimShade, rimLight, deep, edge, light: CGColor }
let inked = Walls(rimShade: color(0x3A2A1C, 0.29), rimLight: color(0xFFFFFF), deep: color(0x08154A, 0.7),
                  edge: color(0x040B2E, 0.55), light: color(0xD6E1FF, 0.55))
let bare = Walls(rimShade: color(0x3A2A1C, 0.29), rimLight: color(0xFFFFFF), deep: color(0x3A2A1C, 0.4),
                 edge: color(0x2A1E12, 0.3), light: color(0xFFFFFF, 0.75))

// Everything is drawn in 1024 units with y pointing down.

struct Painter {
    let ctx: CGContext
    let s: CGFloat

    /// Shadows are measured in pixels with y pointing up, whatever the drawing's scale.
    func shadow(dy: CGFloat, blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: c)
    }

    /// `shape` pressed into the paper, or into the floor of an impression already there. Its outline may
    /// overlap itself, as a stroke's does; holes in it stay paper. `depth` scales the walls down for a narrow
    /// groove or a shallow step, whose floor a full-depth shadow would swallow.
    func press(_ shape: CGPath, floor: [(CGFloat, CGColor)], walls: Walls, depth: CGFloat = 1) {
        let shape = shape.normalized()
        // Everything but the shape: clipping to it reaches only the paper around the shape, and filling it with
        // a shadow casts that shadow inside the shape, from its edge.
        let around = CGMutablePath()
        around.addRect(CGRect(x: -1024, y: -1024, width: 3072, height: 3072))
        around.addPath(shape)

        for (dy, blur, shade) in [(-9 * depth, 25 * depth, walls.rimShade), (11 * depth, 11 * depth, walls.rimLight)] {
            ctx.saveGState()
            ctx.addPath(around); ctx.clip(using: .evenOdd)
            shadow(dy: dy, blur: blur, shade)
            ctx.addPath(shape); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        let box = shape.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient(floor), start: CGPoint(x: box.midX, y: box.minY - box.height * 0.07),
                               end: CGPoint(x: box.midX, y: box.maxY + box.height * 0.07),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        for (dy, blur, shade) in [(36 * depth, 54 * depth, walls.deep), (9 * depth, 9 * depth, walls.edge),
                                  (-11 * depth, 14 * depth, walls.light)] {
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip(using: .evenOdd)
            shadow(dy: dy, blur: blur, shade)
            ctx.addPath(around); ctx.setFillColor(color(0x000000)); ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
    }
}

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// A stroke along the cubic from `a` to `b`, as wide at each point as `width` says for how far along it is, with
/// round ends: the swelling line of a brush or a flexible nib.
func ribbon(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, width: (CGFloat) -> CGFloat) -> CGPath {
    var left: [CGPoint] = [], right: [CGPoint] = []
    let n = 240
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n), u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
        let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
        let dx = 3 * u * u * (c1.x - a.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (b.x - c2.x)
        let dy = 3 * u * u * (c1.y - a.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (b.y - c2.y)
        let l = max(hypot(dx, dy), 0.0001), w = width(t) / 2
        left.append(pt(x - dy / l * w, y + dx / l * w))
        right.append(pt(x + dy / l * w, y - dx / l * w))
    }
    let p = CGMutablePath()
    p.addLines(between: left + right.reversed())
    p.closeSubpath()
    let ends = CGMutablePath()
    for (c, w) in [(a, width(0) / 2), (b, width(1) / 2)] {
        ends.addEllipse(in: CGRect(x: c.x - w, y: c.y - w, width: w * 2, height: w * 2))
    }
    return p.union(ends)
}

/// A letter of New York, the system serif the app sets its titles in, centred on the tile and `height` tall.
func letter(_ character: Character, height: CGFloat, weight: NSFont.Weight) -> CGPath {
    let base = NSFont.systemFont(ofSize: 100, weight: weight)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: 100)!
    var glyph = CGGlyph()
    var unit = Array(String(character).utf16)
    CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
    let raw = CTFontCreatePathForGlyph(font, glyph, nil)!
    let box = raw.boundingBoxOfPath, k = height / box.height
    var t = CGAffineTransform(translationX: 512, y: 512).scaledBy(x: k, y: -k).translatedBy(x: -box.midX, y: -box.midY)
    return raw.copy(using: &t)!
}

/// The tile, as Distill's is.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                  transform: nil)

/// One stroke of a flexible nib: an S, swelling through its turn and thin at either end.
let stroke = ribbon(pt(318, 704), pt(676, 736), pt(348, 290), pt(706, 320)) { t in 30 + 112 * pow(sin(.pi * t), 1.4) }

struct Draft {
    var name: String
    var draw: (Painter) -> Void
}

let drafts: [Draft] = [
    // The nib's stroke pressed in and inked.
    Draft(name: "stroke") { p in
        p.press(stroke,
                floor: pencilFloor, walls: inked, depth: 0.8)
    },
    // The same stroke blind, as Gerty's rings are: only the paper, and its shadows.
    Draft(name: "stroke-blind") { p in
        p.press(stroke,
                floor: paperFloor2, walls: bare, depth: 0.8)
    },
    // Sheets laid on one another, each pressed a step deeper than the last, the deepest inked: the layers of a
    // design, and vellum's leaves.
    Draft(name: "layers") { p in
        func sheet(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerWidth: side * 0.2,
                   cornerHeight: side * 0.2, transform: nil)
        }
        p.press(sheet(262, 262, 500), floor: paperFloor, walls: bare, depth: 0.7)
        p.press(sheet(340, 340, 400), floor: paperFloor2, walls: bare, depth: 0.6)
        p.press(sheet(418, 418, 300), floor: pencilFloor, walls: inked, depth: 0.6)
    },
    // Two discs pressed in, and where they overlap pressed deeper and inked, as two sheets of vellum show
    // darker where one lies on the other.
    Draft(name: "overlap") { p in
        let a = CGPath(ellipseIn: CGRect(x: 236, y: 316, width: 380, height: 380), transform: nil)
        let b = CGPath(ellipseIn: CGRect(x: 408, y: 316, width: 380, height: 380), transform: nil)
        p.press(a.union(b), floor: paperFloor, walls: bare, depth: 0.8)
        p.press(a.intersection(b), floor: pencilFloor, walls: inked, depth: 0.7)
    },
    // The same initial inked with the pencil.
    Draft(name: "letter-inked") { p in
        p.press(letter("V", height: 500, weight: .medium), floor: pencilFloor, walls: inked, depth: 0.7)
    },
    // A loop of the pen's path, crossing itself once, as a groove.
    Draft(name: "loop") { p in
        let path = CGMutablePath()
        path.move(to: pt(226, 706))
        path.addCurve(to: pt(620, 380), control1: pt(430, 706), control2: pt(660, 540))
        path.addCurve(to: pt(420, 410), control1: pt(590, 250), control2: pt(420, 270))
        path.addCurve(to: pt(798, 640), control1: pt(420, 560), control2: pt(640, 700))
        p.press(path.copy(strokingWithWidth: 70, lineCap: .round, lineJoin: .round, miterLimit: 10),
                floor: pencilFloor, walls: inked, depth: 0.55)
    },
    // The initial in New York, blind pressed, as a letterpress printer would.
    Draft(name: "letter") { p in
        p.press(letter("V", height: 500, weight: .medium), floor: paperFloor2, walls: bare, depth: 0.7)
    },
    // The tile's corner peeled back, the pencil blue beneath it: vellum as a sheet that lifts.
    Draft(name: "peel") { p in
        let ctx = p.ctx
        // The fold runs from the top edge to the right one, along y = x - c; past it the paper has lifted.
        let c: CGFloat = 430
        let past = CGMutablePath()
        past.addLines(between: [pt(c - 300, -300), pt(1400, -300), pt(1400, 1400 - c)])
        past.closeSubpath()
        let corner = tile.intersection(past)
        ctx.saveGState()
        ctx.addPath(corner); ctx.clip()
        ctx.drawLinearGradient(gradient(pencilFloor), start: pt(924, 100), end: pt(700, 324), options: [])
        ctx.restoreGState()
        // Folded over, the corner lies mirrored across the fold, its back a shade warmer, lit along the crease.
        var mirror = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: c, ty: -c)
        let flap = corner.copy(using: &mirror)!
        ctx.saveGState()
        p.shadow(dy: 16, blur: 40, color(0x3A2A1C, 0.3))
        ctx.addPath(flap); ctx.setFillColor(color(0xE6E0D5)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(flap); ctx.clip()
        // From the middle of the crease to where the tile's corner has come to lie.
        ctx.drawLinearGradient(gradient([(0, color(0xFBF9F4)), (0.3, color(0xF1ECE3)), (1, color(0xD9D2C5))]),
                               start: pt((c + 1024) / 2, (1024 - c) / 2), end: pt(c + 100, 1024 - c - 100),
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    },
]

func render(_ d: Draft, pixels px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let p = Painter(ctx: ctx, s: s)

    // The tile: warm paper, lit from above.
    ctx.saveGState()
    p.shadow(dy: 12, blur: 30, color(0x000000, 0.28))
    ctx.addPath(tile); ctx.setFillColor(color(0xEDE8DF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xF8F5EF)), (1, color(0xE6E0D5))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    d.draw(p)
    ctx.restoreGState()

    // A light edge just inside the tile.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 101.5, y: 101.5, width: 821, height: 821),
                       cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.6)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])! }

/// Every draft in a row between Distill and Gerty as the Dock shows them, and beside that at the sizes Finder
/// and the menu bar do, each drawn at that size rather than scaled down.
func lineup() -> CGImage {
    let big = 200, gap = 28, margin = 40, label = 34
    let smalls = [64, 32, 16]
    let rowHeight = big + label + gap
    let width = margin * 2 + big * 3 + gap * 2 + 56 + smalls.reduce(0, +) + gap * (smalls.count - 1)
    let height = margin * 2 + rowHeight * drafts.count - gap
    let ctx = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    ctx.setFillColor(color(0xD6D7DB)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func sibling(_ app: String) -> CGImage {
        // The largest size: Gerty's 512 px one carries a stray rectangle at its top left.
        let url = root.deletingLastPathComponent().appendingPathComponent("\(app)/\(app)/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
        return NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    let (distill, gerty) = (sibling("Distill"), sibling("Gerty"))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, d) in drafts.enumerated() {
        let top = height - margin - i * rowHeight
        let y = top - big
        ctx.interpolationQuality = .high
        for (j, image) in [distill, render(d, pixels: big * 2), gerty].enumerated() {
            ctx.draw(image, in: CGRect(x: margin + j * (big + gap), y: y, width: big, height: big))
        }
        var x = margin + big * 3 + gap * 2 + 56
        for size in smalls {
            ctx.draw(render(d, pixels: size * 2), in: CGRect(x: x, y: y + (big - size) / 2, width: size, height: size))
            x += size + gap
        }
        NSAttributedString(string: d.name, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                        .foregroundColor: NSColor(white: 0.18, alpha: 1)])
            .draw(at: CGPoint(x: margin + big + gap + 14, y: y - label + 6))
    }
    return ctx.makeImage()!
}

// MARK: The document icon

/// A design's file: a sheet of the same warm paper with the chosen mark pressed into it, its top right corner
/// folded over. The thumbnails Quick Look shows for designs (BezzleThumbnails/Sheet.swift) are this sheet with
/// the design on it, so the sheet's paper and fold are drawn alike there.
struct Sheet {
    /// Where macOS lays a document's page in its icon, and its corners.
    let rect = CGRect(x: 184, y: 72, width: 656, height: 880)
    let corner: CGFloat = 58
    /// How far along the top edge, and down the right one, the fold reaches.
    let ear: CGFloat = 214

    var whole: CGPath { CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil) }
    /// Everything past the crease.
    var past: CGPath {
        let p = CGMutablePath()
        p.addLines(between: [pt(rect.maxX - ear, rect.minY), pt(rect.maxX - ear + 2000, rect.minY - 2000),
                             pt(rect.maxX + 2000, rect.minY + ear), pt(rect.maxX, rect.minY + ear)])
        p.closeSubpath()
        return p
    }
    var page: CGPath { whole.subtracting(past) }
    /// The corner past the crease folded over onto the sheet, mirrored across the crease: its rounded tip points in.
    var flap: CGPath {
        let c = rect.maxX - ear - rect.minY
        var mirror = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: c, ty: -c)
        return whole.intersection(past).copy(using: &mirror)!
    }
}

/// The app's name in New York, spaced out, centred on `centre`.
func wordmark(_ text: String, size: CGFloat, centre: CGPoint) -> CGPath {
    let base = NSFont.systemFont(ofSize: size, weight: .medium)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: size)!
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: size * 0.35]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for i in 0..<count {
            if let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                path.addPath(g, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    let box = path.boundingBoxOfPath
    var t = CGAffineTransform(translationX: centre.x, y: centre.y).scaledBy(x: 1, y: -1).translatedBy(x: -box.midX, y: -box.midY)
    return path.copy(using: &t)!
}

/// The document icon at `px` pixels square. From 256 pixels up the sheet carries the app's name under the mark, blind
/// pressed as the mark's paper steps are; smaller, the letters would only blur.
func renderDocument(pixels px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let p = Painter(ctx: ctx, s: s)
    let sheet = Sheet(), page = sheet.page, r = sheet.rect
    let named = px >= 256

    // The sheet lies on the desk: a soft shadow under it, and a tight one along its edge.
    for (dy, blur, alpha) in [(CGFloat(14), CGFloat(30), CGFloat(0.22)), (1.5, 3, 0.25)] {
        ctx.saveGState()
        p.shadow(dy: dy, blur: blur, color(0x000000, alpha))
        ctx.addPath(page); ctx.setFillColor(color(0xEDE8DF)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Warm paper, lit from above, as the app's tile is, with the chosen mark pressed into it at 62%: its sheets
    // are 500, 400 and 300 across there, each a step down and to the right.
    ctx.saveGState()
    ctx.addPath(page); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xF9F6F0)), (1, color(0xE9E4DA))]),
                           start: pt(512, r.minY), end: pt(512, r.maxY), options: [])
    let k: CGFloat = 0.62, c = pt(512, named ? 520 : 560)
    func square(_ step: CGFloat, _ side: CGFloat) -> CGPath {
        let x = c.x - 250 * k + step * 78 * k, y = c.y - 250 * k + step * 78 * k
        return CGPath(roundedRect: CGRect(x: x, y: y, width: side * k, height: side * k), cornerWidth: side * k * 0.2,
                      cornerHeight: side * k * 0.2, transform: nil)
    }
    p.press(square(0, 500), floor: paperFloor, walls: bare, depth: 0.7 * k)
    p.press(square(1, 400), floor: paperFloor2, walls: bare, depth: 0.6 * k)
    p.press(square(2, 300), floor: pencilFloor, walls: inked, depth: 0.6 * k)
    if named {
        p.press(wordmark("BEZZLE", size: 62, centre: pt(512, 838)), floor: paperFloor2, walls: bare, depth: 0.2)
    }
    // A light edge just inside the sheet.
    ctx.addPath(page); ctx.setStrokeColor(color(0xFFFFFF, 0.7)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.restoreGState()

    // The fold casts a shadow down onto the sheet, and is lit along the crease.
    let flap = sheet.flap
    ctx.saveGState()
    ctx.addPath(page); ctx.clip()
    p.shadow(dy: 12, blur: 26, color(0x3A2A1C, 0.28))
    ctx.addPath(flap); ctx.setFillColor(color(0xE6E0D5)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(flap); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFEFB)), (0.35, color(0xF4F0E8)), (1, color(0xDDD6CA))]),
                           start: pt(r.maxX - sheet.ear / 2, r.minY + sheet.ear / 2), end: pt(r.maxX - sheet.ear, r.minY + sheet.ear),
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// Renders the document icon into Bezzle/App/BezzleDocument.icns, which Info.plist names for designs, and a
/// large copy into Branding.
func makeDocumentIcon() throws {
    let fm = FileManager.default
    let set = fm.temporaryDirectory.appendingPathComponent("BezzleDocument-\(UUID().uuidString).iconset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: set) }
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            try png(renderDocument(pixels: points * scale))
                .write(to: set.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
        }
    }
    let icns = root.appendingPathComponent("Bezzle/App/BezzleDocument.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", set.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
    try png(renderDocument(pixels: 1024)).write(to: root.appendingPathComponent("Branding/bezzle-document.png"))
    print("Rendered Bezzle/App/BezzleDocument.icns and Branding/bezzle-document.png")
}

if only == "document" {
    try makeDocumentIcon()
} else if let only {
    let dir = root.appendingPathComponent("Branding/drafts")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let picked = only == "drafts" ? drafts : drafts.filter { $0.name == only }
    guard !picked.isEmpty else { fatalError("No draft \(only); there are \(drafts.map(\.name).joined(separator: ", "))") }
    for d in picked { try png(render(d, pixels: 1024)).write(to: dir.appendingPathComponent("\(d.name).png")) }
    if only == "drafts" { try png(lineup()).write(to: dir.appendingPathComponent("lineup.png")) }
    print("Rendered \(picked.map(\.name).joined(separator: ", ")) into Branding/drafts")
} else {
    let d = drafts.first { $0.name == chosen }!
    let out = root.appendingPathComponent("Bezzle/Assets.xcassets/AppIcon.appiconset")
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try png(render(d, pixels: points * scale)).write(to: out.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        .write(to: out.appendingPathComponent("Contents.json"))
    try png(render(d, pixels: 1024)).write(to: root.appendingPathComponent("Branding/bezzle-icon.png"))
    print("Rendered the icon set from \(chosen) and Branding/bezzle-icon.png")
}
