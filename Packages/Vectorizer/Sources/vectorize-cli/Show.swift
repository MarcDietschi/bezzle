import CoreGraphics
import Foundation

// Draws an SVG file made of paths, this engine's or another's, with the points of its outlines
// marked: to see how an outline is built, and to hold two tracings of one picture side by side.

/// One path of an SVG file: what it is filled or stroked with, and its outline with the points
/// its stretches end at.
struct Drawn {
    var fill: CGColor?
    var stroke: CGColor?
    var evenOdd = false
    var path = CGMutablePath()
    var points: [CGPoint] = []
    var handles: [(CGPoint, CGPoint)] = []
    var lines = 0, curves = 0
}

func color(_ text: String) -> CGColor? {
    guard text.hasPrefix("#") else { return nil }
    var hex = String(text.dropFirst())
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return rgb(v)
}

/// An SVG arc as cubic curves added to `path`.
func arc(_ path: CGMutablePath, from p0: CGPoint, rx: CGFloat, ry: CGFloat, turn: CGFloat, large: Bool, sweep: Bool, to p1: CGPoint) {
    var rx = abs(rx), ry = abs(ry)
    guard rx > 1e-9, ry > 1e-9, p0 != p1 else { path.addLine(to: p1); return }
    let phi = turn * .pi / 180, c = cos(phi), s = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
    let l = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if l > 1 { rx *= l.squareRoot(); ry *= l.squareRoot() }
    let num = max(rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, 0), den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    let k = (large != sweep ? 1 : -1) * (den > 0 ? (num / den).squareRoot() : 0)
    let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
    let cx = c * cx1 - s * cy1 + (p0.x + p1.x) / 2, cy = s * cx1 + c * cy1 + (p0.y + p1.y) / 2
    let a0 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
    var da = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - a0
    if sweep, da < 0 { da += 2 * .pi }
    if !sweep, da > 0 { da -= 2 * .pi }
    let n = max(1, Int(ceil(abs(da) / (.pi / 2))))
    let step = da / CGFloat(n), t = 4 / 3 * tan(step / 4)
    func at(_ a: CGFloat) -> CGPoint { CGPoint(x: cx + rx * cos(a) * c - ry * sin(a) * s, y: cy + rx * cos(a) * s + ry * sin(a) * c) }
    func heading(_ a: CGFloat) -> CGPoint { CGPoint(x: -rx * sin(a) * c - ry * cos(a) * s, y: -rx * sin(a) * s + ry * cos(a) * c) }
    for i in 0..<n {
        let a = a0 + step * CGFloat(i), b = a + step
        let p = at(a), q = at(b), d0 = heading(a), d1 = heading(b)
        path.addCurve(to: q, control1: CGPoint(x: p.x + d0.x * t, y: p.y + d0.y * t), control2: CGPoint(x: q.x - d1.x * t, y: q.y - d1.y * t))
    }
}

func paths(inSVG text: String) -> (size: CGSize, paths: [Drawn]) {
    var size = CGSize(width: 100, height: 100)
    if let box = text.range(of: #"viewBox="[^"]+""#, options: .regularExpression) {
        let n = text[box].dropFirst(9).dropLast().split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        if n.count == 4 { size = CGSize(width: n[2], height: n[3]) }
    }
    var out: [Drawn] = []
    let element = try! NSRegularExpression(pattern: #"<path\b[^>]*>"#, options: [.dotMatchesLineSeparators])
    let ns = text as NSString
    func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "[\\s\"]\(name)=\"[^\"]*\"", options: .regularExpression) else { return nil }
        let s = tag[r]
        return String(s[s.index(s.firstIndex(of: "=")!, offsetBy: 2)..<s.index(before: s.endIndex)])
    }
    for match in element.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let tag = ns.substring(with: match.range)
        guard let d = attribute("d", in: tag) else { continue }
        var drawn = Drawn()
        drawn.fill = attribute("fill", in: tag).flatMap(color)
        drawn.stroke = attribute("stroke", in: tag).flatMap(color)
        drawn.evenOdd = attribute("fill-rule", in: tag) == "evenodd"
        // The numbers and letters of the path, one after the other.
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in d {
            if ch.isLetter, ch != "e", ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == "-" { if !number.isEmpty, !number.hasSuffix("e"), !number.hasSuffix("E") { flush() }; number.append(ch) }
            else if ch == "." { if number.contains("."), !number.contains("e") { flush() }; number.append(ch) }
            else if ch.isNumber || ch == "e" || ch == "E" { number.append(ch) }
            else { flush() }
        }
        flush()
        var i = 0
        func next() -> CGFloat { defer { i += 1 }; return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0 }
        var at = CGPoint.zero, start = CGPoint.zero, last = CGPoint.zero, command = "M"
        while i < tokens.count {
            if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            let rel = command.lowercased() == command && command != "z"
            func point() -> CGPoint { let x = next(), y = next(); return rel ? CGPoint(x: at.x + x, y: at.y + y) : CGPoint(x: x, y: y) }
            switch command.uppercased() {
            case "M":
                at = point(); start = at; drawn.path.move(to: at); drawn.points.append(at)
                command = rel ? "l" : "L"
            case "L": at = point(); drawn.path.addLine(to: at); drawn.points.append(at); drawn.lines += 1
            case "H": let x = next(); at = CGPoint(x: rel ? at.x + x : x, y: at.y); drawn.path.addLine(to: at); drawn.points.append(at); drawn.lines += 1
            case "V": let y = next(); at = CGPoint(x: at.x, y: rel ? at.y + y : y); drawn.path.addLine(to: at); drawn.points.append(at); drawn.lines += 1
            case "C":
                let a = point(), b = point(), p = point()
                drawn.path.addCurve(to: p, control1: a, control2: b); drawn.handles.append((at, a)); drawn.handles.append((p, b))
                last = b; at = p; drawn.points.append(at); drawn.curves += 1
            case "S":
                let a = CGPoint(x: 2 * at.x - last.x, y: 2 * at.y - last.y), b = point(), p = point()
                drawn.path.addCurve(to: p, control1: a, control2: b); last = b; at = p; drawn.points.append(at); drawn.curves += 1
            case "Q":
                let a = point(), p = point()
                drawn.path.addQuadCurve(to: p, control: a); drawn.handles.append((at, a)); drawn.handles.append((p, a))
                last = a; at = p; drawn.points.append(at); drawn.curves += 1
            case "T":
                let a = CGPoint(x: 2 * at.x - last.x, y: 2 * at.y - last.y), p = point()
                drawn.path.addQuadCurve(to: p, control: a); last = a; at = p; drawn.points.append(at); drawn.curves += 1
            case "A":
                let rx = next(), ry = next(), turn = next(), large = next() != 0, sweep = next() != 0
                let p = point()
                arc(drawn.path, from: at, rx: rx, ry: ry, turn: turn, large: large, sweep: sweep, to: p)
                // A corner rounded by less than a pixel is one point, not two.
                if max(rx, ry) >= 2 { drawn.points.append(p) }
                at = p; drawn.curves += 1
            case "Z":
                drawn.path.closeSubpath(); at = start
                if let lastPoint = drawn.points.last, hypot(lastPoint.x - start.x, lastPoint.y - start.y) < 0.01 { drawn.points.removeLast() }
            default: i += 1
            }
            if command.uppercased() != "C", command.uppercased() != "S", command.uppercased() != "Q", command.uppercased() != "T" { last = at }
        }
        out.append(drawn)
    }
    return (size, out)
}

/// The file drawn `zoom` times its size, cut to `crop` (in the file's own measure) when given;
/// with `nodes`, its fills paled and every outline and point drawn over them.
func show(_ file: String, zoom: CGFloat, crop: CGRect?, nodes: Bool, only: Int? = nil) -> (image: CGImage, shapes: Int, points: Int, lines: Int, curves: Int)? {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    let (size, all) = paths(inSVG: text)
    let part = crop ?? CGRect(origin: .zero, size: size)
    let ctx = context(Int(part.width * zoom), Int(part.height * zoom))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: part.width * zoom, height: part.height * zoom))
    ctx.scaleBy(x: zoom, y: zoom)
    ctx.translateBy(x: -part.minX, y: -part.minY)
    for p in all {
        ctx.addPath(p.path)
        if let fill = p.fill {
            ctx.setFillColor(fill); ctx.fillPath(using: p.evenOdd ? .evenOdd : .winding)
        } else if let stroke = p.stroke {
            ctx.setStrokeColor(stroke); ctx.setLineWidth(2); ctx.strokePath()
        }
    }
    var filled = all.filter { $0.fill != nil }
    if let only, only < filled.count { filled = [filled[only]] }
    if nodes {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)); ctx.fill(part)
        ctx.setLineWidth(1 / zoom)
        for p in filled {
            ctx.addPath(p.path); ctx.setStrokeColor(rgb(0x1B1B1B)); ctx.strokePath()
        }
        let r = 2.2 / zoom
        for p in filled {
            ctx.setFillColor(rgb(0xE5202B))
            for q in p.points where part.insetBy(dx: -4, dy: -4).contains(q) { ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)) }
        }
    }
    return (ctx.makeImage()!, filled.count, filled.reduce(0) { $0 + $1.points.count }, filled.reduce(0) { $0 + $1.lines }, filled.reduce(0) { $0 + $1.curves })
}
