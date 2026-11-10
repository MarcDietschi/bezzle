import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vectorizer

// Works on the engine from the command line:
//
//   vectorize-cli trace <picture> <out.svg> [--png <out.png>] [--zoom 4] [--detail 0.5] [--colors 8] [--smoothing 0.5] [--draft]
//   vectorize-cli samples <folder>            drawings whose true shapes are known, as small pictures and 4× truths
//   vectorize-cli score <folder> [--keep <folder>]   traces every sample and says how far the tracing is from the truth

// MARK: Pictures in and out

func load(_ path: String) -> Bitmap? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return bitmap(image)
}

func bitmap(_ image: CGImage) -> Bitmap? {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    // Not multiplied by alpha, as the engine takes it.
    for i in 0..<(w * h) {
        let a = Int(pixels[i * 4 + 3])
        guard a > 0, a < 255 else { continue }
        for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(255, (Int(pixels[i * 4 + c]) * 255 + a / 2) / a)) }
    }
    return Bitmap(width: w, height: h, pixels: pixels)
}

func context(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y down, as pictures are.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func save(_ image: CGImage, _ path: String, jpeg quality: Double? = nil) {
    let type = quality == nil ? UTType.png : UTType.jpeg
    guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(out, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
    CGImageDestinationFinalize(out)
}

/// A tracing drawn `zoom` times its size: shape by shape, or with `packed`, as the layers a design
/// gets of it, which has to come to the same picture.
func render(_ tracing: Tracing, zoom: Int, background: CGColor? = nil, packed: Bool = false) -> CGImage {
    let ctx = context(tracing.width * zoom, tracing.height * zoom)
    if let background {
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: tracing.width * zoom, height: tracing.height * zoom))
    }
    ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
    let drawn: [(color: Tint, outlines: [Outline])] = packed ? tracing.layers(most: 0).map { ($0.color, $0.outlines) } : tracing.shapes.map { ($0.color, $0.outlines) }
    for shape in drawn {
        let path = CGMutablePath()
        for outline in shape.outlines {
            path.move(to: CGPoint(x: outline.start.x, y: outline.start.y))
            for stretch in outline.stretches {
                switch stretch {
                case .line(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
                case .curve(let a, let b, let p):
                    path.addCurve(to: CGPoint(x: p.x, y: p.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
                }
            }
            path.closeSubpath()
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(shape.color.r) / 255, green: CGFloat(shape.color.g) / 255, blue: CGFloat(shape.color.b) / 255, alpha: 1))
        ctx.fillPath(using: packed ? .winding : .evenOdd)
    }
    return ctx.makeImage()!
}

/// The share of pixels two pictures of one size clearly differ in.
func differing(_ a: CGImage, _ b: CGImage) -> Double {
    func bytes(_ image: CGImage) -> [UInt8] {
        let ctx = context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * image.height))
    }
    let x = bytes(a), y = bytes(b)
    var n = 0
    for i in stride(from: 0, to: min(x.count, y.count) - 3, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])) > 60 { n += 1 }
    return Double(n) / Double(max(a.width * a.height, 1))
}

// MARK: Drawings with known shapes

struct Sample {
    let name: String
    let size: CGSize
    /// Kept as a JPEG of this quality, then traced from that.
    var jpeg: Double?
    /// Drawn with hard edges and scaled up by this, as pixel art is.
    var blocks: Int?
    let draw: (CGContext) -> Void
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func text(_ ctx: CGContext, _ string: String, at p: CGPoint, size: CGFloat, font: String = "Helvetica-Bold", color: CGColor) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]))
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func star(_ c: CGPoint, _ outer: CGFloat, _ inner: CGFloat, points: Int = 5) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<(points * 2) {
        let r = i % 2 == 0 ? outer : inner, a = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
        let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

let logo: (CGContext) -> Void = { ctx in
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    ctx.setFillColor(rgb(0x1F6FEB)); ctx.fillEllipse(in: CGRect(x: 30.3, y: 28.6, width: 150, height: 150))
    ctx.setFillColor(rgb(0xE5484D))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 120.5, y: 90.25, width: 180, height: 110), cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0xF5C518)); ctx.addPath(star(CGPoint(x: 320.4, y: 70.7), 52, 21)); ctx.fillPath()
    text(ctx, "Bezzle", at: CGPoint(x: 42, y: 262), size: 56, color: rgb(0x111111))
    ctx.setStrokeColor(rgb(0x111111)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: 250, y: 232)); ctx.addCurve(to: CGPoint(x: 380, y: 262), control1: CGPoint(x: 290, y: 200), control2: CGPoint(x: 340, y: 290)); ctx.strokePath()
}

let samples: [Sample] = [
    Sample(name: "logo", size: CGSize(width: 400, height: 300), draw: logo),
    Sample(name: "logo-jpeg", size: CGSize(width: 400, height: 300), jpeg: 0.6, draw: logo),
    Sample(name: "figures", size: CGSize(width: 360, height: 240)) { ctx in
        ctx.setFillColor(rgb(0xF4F1EA)); ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
        ctx.setFillColor(rgb(0x2D7D46)); ctx.fill(CGRect(x: 20, y: 20, width: 90, height: 60))
        ctx.setFillColor(rgb(0x7A3EB1)); ctx.fillEllipse(in: CGRect(x: 130.4, y: 18.3, width: 96.6, height: 61.2))
        ctx.setFillColor(rgb(0xD9480F))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 245.5, y: 20.5, width: 96, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
        ctx.saveGState()
        ctx.translateBy(x: 70, y: 160); ctx.rotate(by: 0.42)
        ctx.setFillColor(rgb(0x0B7285)); ctx.fill(CGRect(x: -40, y: -26, width: 80, height: 52))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x212529)); ctx.fillEllipse(in: CGRect(x: 150, y: 120, width: 80, height: 80))
        ctx.setFillColor(rgb(0xF4F1EA)); ctx.fillEllipse(in: CGRect(x: 168, y: 138, width: 44, height: 44))
        ctx.setFillColor(rgb(0xC2255C))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 250, y: 140, width: 92, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil)); ctx.fillPath()
        ctx.setFillColor(rgb(0x212529))
        ctx.move(to: CGPoint(x: 262, y: 212)); ctx.addLine(to: CGPoint(x: 300, y: 196)); ctx.addLine(to: CGPoint(x: 338, y: 226)); ctx.closePath(); ctx.fillPath()
    },
    Sample(name: "cartoon", size: CGSize(width: 320, height: 240)) { ctx in
        ctx.setFillColor(rgb(0xBFE3F5)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        ctx.setFillColor(rgb(0x7CC36E)); ctx.fill(CGRect(x: 0, y: 170, width: 320, height: 70))
        ctx.setStrokeColor(rgb(0x1B1B1B)); ctx.setLineWidth(2.5); ctx.setLineJoin(.round)
        func outlined(_ path: CGPath, _ fill: UInt32) {
            ctx.addPath(path); ctx.setFillColor(rgb(fill)); ctx.fillPath()
            ctx.addPath(path); ctx.strokePath()
        }
        outlined(CGPath(rect: CGRect(x: 90, y: 110, width: 120, height: 90), transform: nil), 0xF2D0A4)
        let roof = CGMutablePath(); roof.move(to: CGPoint(x: 78, y: 112)); roof.addLine(to: CGPoint(x: 150, y: 58)); roof.addLine(to: CGPoint(x: 222, y: 112)); roof.closeSubpath()
        outlined(roof, 0xC0392B)
        outlined(CGPath(rect: CGRect(x: 135, y: 150, width: 30, height: 50), transform: nil), 0x8E5B3A)
        outlined(CGPath(ellipseIn: CGRect(x: 104, y: 124, width: 24, height: 24), transform: nil), 0xFDF6C3)
        outlined(CGPath(ellipseIn: CGRect(x: 246, y: 26, width: 46, height: 46), transform: nil), 0xFFD43B)
        let cloud = CGMutablePath()
        cloud.addEllipse(in: CGRect(x: 30, y: 36, width: 44, height: 30)); cloud.addEllipse(in: CGRect(x: 56, y: 26, width: 50, height: 38))
        outlined(cloud.copy(strokingWithWidth: 0.01, lineCap: .round, lineJoin: .round, miterLimit: 1).union(cloud), 0xFFFFFF)
    },
    Sample(name: "small-text", size: CGSize(width: 360, height: 160)) { ctx in
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 160))
        text(ctx, "The quick brown fox jumps", at: CGPoint(x: 12, y: 30), size: 22, font: "Georgia", color: rgb(0x000000))
        text(ctx, "over the lazy dog 0123456789", at: CGPoint(x: 12, y: 58), size: 16, font: "Helvetica", color: rgb(0x000000))
        text(ctx, "Pack my box with five dozen liquor jugs.", at: CGPoint(x: 12, y: 82), size: 12, font: "Helvetica", color: rgb(0xB00020))
        text(ctx, "Sphinx of black quartz, judge my vow.", at: CGPoint(x: 12, y: 102), size: 10, font: "Times-Roman", color: rgb(0x0B5394))
        ctx.setFillColor(rgb(0x1B1B1B)); ctx.fill(CGRect(x: 0, y: 116, width: 360, height: 44))
        text(ctx, "White on black, 14 pt", at: CGPoint(x: 12, y: 144), size: 14, font: "Helvetica-Bold", color: rgb(0xFFFFFF))
    },
    Sample(name: "thin-lines", size: CGSize(width: 300, height: 200)) { ctx in
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        ctx.setStrokeColor(rgb(0x123456))
        for (i, width) in [0.75, 1, 1.5, 2, 3].enumerated() {
            ctx.setLineWidth(CGFloat(width))
            ctx.move(to: CGPoint(x: 20, y: 24.3 + Double(i) * 18)); ctx.addLine(to: CGPoint(x: 280, y: 40.8 + Double(i) * 18)); ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: 30.5 + Double(i) * 52, y: 120.5, width: 40, height: 56))
        }
    },
    Sample(name: "grey-between", size: CGSize(width: 240, height: 160)) { ctx in
        // A grey that lies between black and white, with black shapes on white beside it: the
        // edges of the black shapes must not grow grey lines.
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        ctx.setFillColor(rgb(0x808080)); ctx.fillEllipse(in: CGRect(x: 20.5, y: 20.5, width: 70, height: 70))
        ctx.setFillColor(rgb(0x000000)); ctx.fillEllipse(in: CGRect(x: 110.3, y: 24.7, width: 110, height: 60))
        text(ctx, "Grey", at: CGPoint(x: 24, y: 140), size: 40, color: rgb(0x000000))
        ctx.setFillColor(rgb(0x808080)); ctx.addPath(star(CGPoint(x: 190, y: 122), 30, 13)); ctx.fillPath()
    },
    Sample(name: "pixel-art", size: CGSize(width: 24, height: 24), blocks: 8) { ctx in
        ctx.setFillColor(rgb(0x5FCDE4)); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        ctx.setFillColor(rgb(0xAC3232)); ctx.fill(CGRect(x: 6, y: 8, width: 12, height: 10))
        ctx.setFillColor(rgb(0xD95763)); ctx.fill(CGRect(x: 8, y: 6, width: 8, height: 2))
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 8, y: 10, width: 3, height: 3)); ctx.fill(CGRect(x: 13, y: 10, width: 3, height: 3))
        ctx.setFillColor(rgb(0x222034)); ctx.fill(CGRect(x: 9, y: 11, width: 1, height: 1)); ctx.fill(CGRect(x: 14, y: 11, width: 1, height: 1))
        for i in 0..<5 { ctx.fill(CGRect(x: 7 + i * 2, y: 18 + i % 2, width: 2, height: 1)) }
        ctx.setFillColor(rgb(0x4B692F)); ctx.fill(CGRect(x: 0, y: 21, width: 24, height: 3))
    },
]

func drawn(_ sample: Sample, zoom: Int) -> CGImage {
    if let blocks = sample.blocks {
        // Drawn small and hard, then every pixel a square.
        let w = Int(sample.size.width), h = Int(sample.size.height)
        let small = context(w, h)
        small.setShouldAntialias(false)
        sample.draw(small)
        let image = small.makeImage()!
        let ctx = context(w * blocks * zoom, h * blocks * zoom)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -CGFloat(h * blocks * zoom))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w * blocks * zoom, height: h * blocks * zoom))
        return ctx.makeImage()!
    }
    let ctx = context(Int(sample.size.width) * zoom, Int(sample.size.height) * zoom)
    ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
    sample.draw(ctx)
    return ctx.makeImage()!
}

// MARK: How far a tracing is from the truth

struct Score {
    /// How far the edges lie from where they should, in pixels of the small picture, on the whole.
    var offset: Double
    /// The mean difference of the colours, 0…255.
    var difference: Double
}

func score(_ image: CGImage, against truth: CGImage, zoom: Int) -> Score {
    guard let a = bitmap(image), let b = bitmap(truth), a.width == b.width, a.height == b.height else { return Score(offset: .nan, difference: .nan) }
    let w = a.width, h = a.height
    var area = 0.0, total = 0.0, edges = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c]))
                worst = max(worst, d)
                total += Double(d)
            }
            area += Double(worst) / 255
            // The truth's edges: where it differs from the pixel to its right or below.
            if x < w - 1, y < h - 1 {
                var jump = 0
                for c in 0..<3 {
                    jump = max(jump, abs(Int(b.pixels[i + c]) - Int(b.pixels[i + 4 + c])), abs(Int(b.pixels[i + c]) - Int(b.pixels[i + w * 4 + c])))
                }
                edges += Double(jump) / 255
            }
        }
    }
    return Score(offset: edges > 0 ? area / edges / Double(zoom) : 0, difference: total / Double(w * h * 3))
}

func scaledUp(_ image: CGImage, zoom: Int) -> CGImage {
    let ctx = context(image.width * zoom, image.height * zoom)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -CGFloat(image.height * zoom))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width * zoom, height: image.height * zoom))
    return ctx.makeImage()!
}

// MARK: Commands

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

var settings = Settings()
if let v = option("--detail").flatMap(Double.init) { settings.detail = v }
if let v = option("--smoothing").flatMap(Double.init) { settings.smoothing = v }
if let v = option("--colors").flatMap(Int.init) { settings.colors = v }
settings.draft = flag("--draft")
let zoom = option("--zoom").flatMap(Int.init) ?? 4
let png = option("--png")
let keep = option("--keep")

func describe(_ t: Tracing, seconds: Double) -> String {
    let figures = t.shapes.filter { $0.figure != nil }.count
    return "\(t.shapes.count) shapes, \(t.points) points, \(t.palette.count) colours, \(figures) figures, \(t.layers(most: 0).count) layers packed\(t.pixelArt ? ", pixel art" : ""), \(String(format: "%.2f", seconds)) s"
}

switch arguments.first {
case "trace" where arguments.count >= 3:
    guard let picture = load(arguments[1]) else { fatalError("cannot read \(arguments[1])") }
    let began = Date()
    guard let tracing = Vectorizer.trace(picture, settings: settings) else { fatalError("stopped") }
    print("\(picture.width)×\(picture.height): " + describe(tracing, seconds: Date().timeIntervalSince(began)))
    print("palette: " + tracing.palette.map { String(format: "#%02x%02x%02x", $0.r, $0.g, $0.b) }.joined(separator: " "))
    for shape in tracing.shapes { if let f = shape.figure { print("  \(f)") } }
    try! tracing.svg().write(toFile: arguments[2], atomically: true, encoding: .utf8)
    if let png { save(render(tracing, zoom: zoom), png) }
    if flag("--packed") {
        let share = differing(render(tracing, zoom: 2), render(tracing, zoom: 2, packed: true))
        print("packed into layers, \(String(format: "%.4f", share * 100)) % of the pixels differ")
        if let png { save(render(tracing, zoom: zoom, packed: true), png.replacingOccurrences(of: ".png", with: "-packed.png")) }
    }

case "samples" where arguments.count >= 2:
    let folder = arguments[1]
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for sample in samples {
        let small = drawn(sample, zoom: 1)
        if let quality = sample.jpeg {
            save(small, "\(folder)/\(sample.name).jpg", jpeg: quality)
        } else {
            save(small, "\(folder)/\(sample.name).png")
        }
        save(drawn(sample, zoom: 4), "\(folder)/\(sample.name)@truth.png")
    }
    print("\(samples.count) samples in \(folder)")

case "score" where arguments.count >= 2:
    let folder = arguments[1]
    if let keep { try? FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true) }
    for sample in samples {
        let file = "\(folder)/\(sample.name).\(sample.jpeg == nil ? "png" : "jpg")"
        guard let picture = load(file), let truthSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(folder)/\(sample.name)@truth.png") as CFURL, nil),
              let truth = CGImageSourceCreateImageAtIndex(truthSource, 0, nil),
              let small = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            print("\(sample.name): missing; run samples first")
            continue
        }
        let began = Date()
        guard let tracing = Vectorizer.trace(picture, settings: settings) else { continue }
        let seconds = Date().timeIntervalSince(began)
        let traced = render(tracing, zoom: 4)
        let mine = score(traced, against: truth, zoom: 4), plain = score(scaledUp(small, zoom: 4), against: truth, zoom: 4)
        print(String(format: "%-12@ edges off %.3f px (scaled up: %.3f), colours off %.2f (%.2f)  ", sample.name as NSString, mine.offset, plain.offset, mine.difference, plain.difference)
            + describe(tracing, seconds: seconds))
        if let keep {
            save(traced, "\(keep)/\(sample.name)@traced.png")
            try? tracing.svg().write(toFile: "\(keep)/\(sample.name).svg", atomically: true, encoding: .utf8)
        }
    }

case "show" where arguments.count >= 3:
    // show <file.svg> <out.png> [--zoom 2] [--crop x,y,w,h] [--nodes]
    let nodes = flag("--nodes")
    let crop = option("--crop").map { $0.split(separator: ",").compactMap { Double($0) } }.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    let only = option("--only").flatMap(Int.init)
    guard let shown = show(arguments[1], zoom: CGFloat(zoom), crop: crop, nodes: nodes, only: only) else { fatalError("cannot read \(arguments[1])") }
    save(shown.image, arguments[2])
    print("\(shown.shapes) shapes, \(shown.points) points, \(shown.lines) lines, \(shown.curves) curves")

case "against" where arguments.count >= 3:
    // against <pictures folder> <folder of reference .svg>: traces every picture that has a
    // reference tracing of the same name, and says how far its edges lie from the reference's,
    // in pixels, and how many shapes and points each has.
    let folder = arguments[1], references = arguments[2]
    if let keep { try? FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true) }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
    var offs: [Double] = [], ratios: [Double] = []
    let temporary = NSTemporaryDirectory() + "vectorize-against-\(ProcessInfo.processInfo.processIdentifier).svg"
    for name in names {
        let base = (name as NSString).deletingPathExtension
        guard FileManager.default.fileExists(atPath: "\(references)/\(base).svg"), let picture = load("\(folder)/\(name)") else { continue }
        let began = Date()
        guard let tracing = Vectorizer.trace(picture, settings: settings) else { continue }
        let seconds = Date().timeIntervalSince(began)
        let file = keep.map { "\($0)/\(base).svg" } ?? temporary
        try! tracing.svg().write(toFile: file, atomically: true, encoding: .utf8)
        guard let mine = show(file, zoom: 2, crop: nil, nodes: false), let theirs = show("\(references)/\(base).svg", zoom: 2, crop: nil, nodes: false),
              mine.image.width == theirs.image.width, mine.image.height == theirs.image.height else {
            print("\(base): sizes differ")
            continue
        }
        // Where the two clearly differ, over how long the reference's edges are: how far apart the edges lie.
        guard let a = bitmap(mine.image), let b = bitmap(theirs.image) else { continue }
        let w = a.width, h = a.height
        var area = 0, edges = 0
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let i = (y * w + x) * 4
                func far(_ p: [UInt8], _ i: Int, _ q: [UInt8], _ j: Int) -> Bool {
                    abs(Int(p[i]) - Int(q[j])) + abs(Int(p[i + 1]) - Int(q[j + 1])) + abs(Int(p[i + 2]) - Int(q[j + 2])) > 90
                }
                if far(a.pixels, i, b.pixels, i) { area += 1 }
                if far(b.pixels, i, b.pixels, i + 4) || far(b.pixels, i, b.pixels, i + w * 4) { edges += 1 }
            }
        }
        let off = edges > 0 ? Double(area) / Double(edges) / 2 : 0
        offs.append(off)
        ratios.append(Double(mine.points) / Double(max(theirs.points, 1)))
        print(String(format: "%-18@ edges %.2f px from the reference's; shapes %4d (%4d), points %5d (%5d), %.2f s", base as NSString, off,
                     mine.shapes, theirs.shapes, mine.points, theirs.points, seconds))
        if keep != nil { save(show(file, zoom: 2, crop: nil, nodes: true)!.image, "\(keep!)/\(base)-points.png") }
    }
    if !offs.isEmpty {
        print(String(format: "on the whole: edges %.3f px off, %.2f times the reference's points", offs.reduce(0, +) / Double(offs.count), ratios.reduce(0, +) / Double(ratios.count)))
    }
    try? FileManager.default.removeItem(atPath: temporary)

case "pixels" where arguments.count >= 3:
    // pixels <picture> <out.png> [--zoom 12] [--crop x,y,w,h]: the picture's own pixels, each a square.
    let crop = option("--crop").map { $0.split(separator: ",").compactMap { Double($0) } }.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(arguments[1])") }
    let part = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let ctx = context(Int(part.width) * zoom, Int(part.height) * zoom)
    ctx.interpolationQuality = .none
    ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
    ctx.translateBy(x: -part.minX, y: -part.minY)
    ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    save(ctx.makeImage()!, arguments[2])

default:
    print("usage: vectorize-cli trace <picture> <out.svg> [--png out.png] [--zoom 4] [--detail 0.5] [--colors n] [--smoothing 0.5] [--draft]")
    print("       vectorize-cli samples <folder>")
    print("       vectorize-cli score <folder> [--keep <folder>]")
    print("       vectorize-cli show <file.svg> <out.png> [--zoom 2] [--crop x,y,w,h] [--nodes] [--only n]")
    print("       vectorize-cli against <pictures folder> <folder of reference .svg> [--keep <folder>]")
    print("       vectorize-cli pixels <picture> <out.png> [--zoom 12] [--crop x,y,w,h]")
}
