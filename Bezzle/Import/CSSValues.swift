import CoreGraphics
import Foundation

/// The values of a web page's computed styles, read as Bezzle keeps them: colours, gradients,
/// shadows, filters, positions and the shapes a box is cut to. The page reader writes every
/// colour as rgba() with channels 0…255 (see WebPageReader.js), so that is the notation read
/// first; hex and a few names are read too.
nonisolated enum CSS {
    // MARK: Lists and words

    /// Splits at the top level: at commas, or at runs of spaces, never inside brackets or quotes.
    static func split(_ s: String, at separator: Character = ",") -> [String] {
        var out: [String] = []
        var depth = 0, quote: Character?, current = ""
        for ch in s {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
                current.append(ch)
            case "(":
                depth += 1
                current.append(ch)
            case ")":
                depth -= 1
                current.append(ch)
            default:
                if depth == 0 && (separator == " " ? ch.isWhitespace : ch == separator) {
                    let piece = current.trimmingCharacters(in: .whitespaces)
                    if separator != " " || !piece.isEmpty { out.append(piece) }
                    current = ""
                } else {
                    current.append(ch)
                }
            }
        }
        let piece = current.trimmingCharacters(in: .whitespaces)
        if separator != " " || !piece.isEmpty { out.append(piece) }
        return out.filter { separator == " " || !$0.isEmpty }
    }

    /// The words of a value, split at spaces at its top level.
    static func words(_ s: String) -> [String] { split(s, at: " ") }

    /// A function's name and what it was given: "blur(4px)" is ("blur", "4px").
    static func function(_ s: String) -> (name: String, args: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let name = String(t[..<open]).lowercased()
        let args = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
        return (name, args)
    }

    // MARK: Numbers

    /// A length in pixels; a percentage is of `of`. calc() of percentages and pixels added and
    /// taken away is worked out; anything else is nil.
    static func length(_ s: String, of whole: CGFloat = 0, em: CGFloat = 16) -> CGFloat? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t == "0" { return 0 }
        if let (name, args) = function(t), name == "calc" || name == "-webkit-calc" {
            return calc(args, of: whole, em: em)
        }
        if t.hasSuffix("%"), let v = Double(t.dropLast()) { return CGFloat(v) / 100 * whole }
        if t.hasSuffix("px"), let v = Double(t.dropLast(2)) { return CGFloat(v) }
        if t.hasSuffix("rem"), let v = Double(t.dropLast(3)) { return CGFloat(v) * 16 }
        if t.hasSuffix("em"), let v = Double(t.dropLast(2)) { return CGFloat(v) * em }
        if let v = Double(t) { return CGFloat(v) }
        return nil
    }

    /// calc() as computed styles write it: terms added and taken away, each a length.
    private static func calc(_ args: String, of whole: CGFloat, em: CGFloat) -> CGFloat? {
        var total: CGFloat = 0, sign: CGFloat = 1, any = false
        for word in words(args) {
            if word == "+" { sign = 1; continue }
            if word == "-" { sign = -1; continue }
            if let (name, inner) = function(word), name.isEmpty || name == "calc" {
                guard let v = calc(inner, of: whole, em: em) else { return nil }
                total += sign * v
            } else {
                guard let v = length(word, of: whole, em: em) else { return nil }
                total += sign * v
            }
            any = true
            sign = 1
        }
        return any ? total : nil
    }

    /// An angle in degrees.
    static func angle(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("deg"), let v = Double(t.dropLast(3)) { return v }
        if t.hasSuffix("grad"), let v = Double(t.dropLast(4)) { return v * 0.9 }
        if t.hasSuffix("rad"), let v = Double(t.dropLast(3)) { return v * 180 / .pi }
        if t.hasSuffix("turn"), let v = Double(t.dropLast(4)) { return v * 360 }
        if t == "0" { return 0 }
        return nil
    }

    /// A number, or a percentage of one: "50%" is 0.5.
    static func amount(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%"), let v = Double(t.dropLast()) { return v / 100 }
        return Double(t)
    }

    // MARK: Colours

    /// A colour: rgba() or rgb() with channels 0…255, hex, or a few names.
    static func color(_ s: String) -> RGBA? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "transparent": return RGBA(r: 0, g: 0, b: 0, a: 0)
        case "black": return .black
        case "white": return .white
        case "red": return RGBA(r: 1, g: 0, b: 0)
        default: break
        }
        if t.hasPrefix("#") { return RGBA(hex: t) }
        guard let (name, args) = function(t), name == "rgb" || name == "rgba" else { return nil }
        let parts = args.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        func channel(_ p: String) -> Double? {
            if p.hasSuffix("%") { return Double(p.dropLast()).map { $0 / 100 } }
            return Double(p).map { $0 / 255 }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        let a = parts.count > 3 ? amount(parts[3]) ?? 1 : 1
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return RGBA(r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(a))
    }

    /// A colour as the page reader hands it over: four numbers 0…1.
    static func color(_ c: [Double]?) -> RGBA? {
        guard let c, c.count >= 3 else { return nil }
        return RGBA(r: c[0], g: c[1], b: c[2], a: c.count > 3 ? c[3] : 1)
    }

    /// The colour among a value's words, and the words that are not it.
    static func pickColor(_ words: [String]) -> (RGBA?, [String]) {
        var rest: [String] = [], found: RGBA?
        for w in words {
            if found == nil, let c = color(w), w.contains("(") || w.hasPrefix("#") || Double(w) == nil && length(w) == nil {
                found = c
            } else {
                rest.append(w)
            }
        }
        return (found, rest)
    }

    // MARK: Shadows

    /// The shadows of box-shadow or text-shadow, the first, which lies on top, last, as Bezzle
    /// casts them bottom first.
    static func shadows(_ s: String, current: RGBA = .black) -> [Shadow] {
        guard s != "none" else { return [] }
        var out: [Shadow] = []
        for part in split(s) {
            var words = words(part)
            let inset = words.contains("inset")
            words.removeAll { $0 == "inset" }
            let (c, rest) = pickColor(words)
            let lengths = rest.compactMap { length($0) }
            guard lengths.count >= 2 else { continue }
            var shadow = Shadow(on: true, color: c ?? current, x: lengths[0], y: lengths[1], blur: lengths.count > 2 ? max(lengths[2], 0) : 0)
            if inset { shadow.inset = true }
            if lengths.count > 3, lengths[3] != 0 { shadow.spread = lengths[3] }
            if shadow.color.a <= 0 { continue }
            out.append(shadow)
        }
        return out.reversed()
    }

    // MARK: Filters

    enum Filter: Equatable {
        case blur(CGFloat)
        case dropShadow(Shadow)
        case opacity(Double)
        case brightness(Double)
        case contrast(Double)
        case grayscale(Double)
        case saturate(Double)
        case sepia(Double)
        case invert(Double)
        case hueRotate(Double)
        case other(String)
    }

    static func filters(_ s: String) -> [Filter] {
        guard s != "none" else { return [] }
        return words(s).compactMap { word in
            guard let (name, args) = function(word) else { return nil }
            let a = args.trimmingCharacters(in: .whitespaces)
            switch name {
            case "blur": return .blur(length(a) ?? 0)
            case "drop-shadow": return shadows(a).first.map(Filter.dropShadow)
            case "opacity": return .opacity(amount(a) ?? 1)
            case "brightness": return .brightness(amount(a) ?? 1)
            case "contrast": return .contrast(amount(a) ?? 1)
            case "grayscale": return .grayscale(amount(a) ?? 1)
            case "saturate": return .saturate(amount(a) ?? 1)
            case "sepia": return .sepia(amount(a) ?? 1)
            case "invert": return .invert(amount(a) ?? 1)
            case "hue-rotate": return .hueRotate(angle(a) ?? 0)
            default: return .other(name)
            }
        }
    }

    // MARK: Gradients

    /// A gradient as Bezzle draws it across a box of `size`, from linear-gradient(),
    /// radial-gradient() and their repeating kinds. Nil for a conic gradient, or anything else.
    static func gradient(_ s: String, size: CGSize) -> Gradient? {
        guard let (name, args) = function(s), size.width > 0, size.height > 0 else { return nil }
        let repeating = name.hasPrefix("repeating-")
        let kind = repeating ? String(name.dropFirst("repeating-".count)) : name
        var parts = split(args)
        guard !parts.isEmpty else { return nil }
        let w = size.width, h = size.height
        switch kind.replacingOccurrences(of: "-webkit-", with: "") {
        case "linear-gradient":
            var dir = CGVector(dx: 0, dy: 1)
            if let first = parts.first, color(firstWord(first)) == nil, !isStop(first) {
                parts.removeFirst()
                dir = direction(first, size: size) ?? dir
            }
            let length = abs(w * dir.dx) + abs(h * dir.dy)
            guard length > 0 else { return nil }
            guard var stops = stops(parts, length: length) else { return nil }
            if repeating { stops = repeated(stops) }
            let (clipped, from, to) = clamp(stops)
            let c = CGPoint(x: w / 2, y: h / 2)
            let a = CGPoint(x: c.x - dir.dx * length / 2, y: c.y - dir.dy * length / 2)
            let b = CGPoint(x: c.x + dir.dx * length / 2, y: c.y + dir.dy * length / 2)
            // The ends of the stops kept, should they lie inside the line.
            let start = CGPoint(x: a.x + (b.x - a.x) * from, y: a.y + (b.y - a.y) * from)
            let end = CGPoint(x: a.x + (b.x - a.x) * to, y: a.y + (b.y - a.y) * to)
            return Gradient(kind: .linear, stops: clipped,
                            start: CGPoint(x: start.x / w, y: start.y / h), end: CGPoint(x: end.x / w, y: end.y / h))
        case "radial-gradient":
            var shape = "ellipse", extent = "farthest-corner", center = CGPoint(x: w / 2, y: h / 2)
            var explicit: (CGFloat, CGFloat?)?
            if let first = parts.first, color(firstWord(first)) == nil, !isStop(first) {
                parts.removeFirst()
                var words = words(first)
                if let at = words.firstIndex(of: "at") {
                    center = position(Array(words[(at + 1)...]), in: size)
                    words = Array(words[..<at])
                }
                var lengths: [CGFloat] = []
                for (i, word) in words.enumerated() {
                    switch word {
                    case "circle", "ellipse": shape = word
                    case "closest-side", "closest-corner", "farthest-side", "farthest-corner", "contain", "cover":
                        extent = word == "contain" ? "closest-side" : word == "cover" ? "farthest-corner" : word
                    default:
                        if let v = length(word, of: lengths.isEmpty ? w : h) {
                            lengths.append(v)
                            _ = i
                        }
                    }
                }
                if lengths.count == 1 { explicit = (lengths[0], nil); shape = "circle" }
                if lengths.count >= 2 { explicit = (lengths[0], lengths[1]); shape = "ellipse" }
            }
            var rx: CGFloat, ry: CGFloat
            if let explicit {
                rx = explicit.0
                ry = explicit.1 ?? explicit.0
            } else {
                (rx, ry) = radii(shape: shape, extent: extent, center: center, size: size)
            }
            guard rx > 0, ry > 0 else { return nil }
            guard var stops = stops(parts, length: rx) else { return nil }
            if repeating { stops = repeated(stops) }
            let (clipped, _, to) = clamp(stops)
            // Stops past the edge of the circle are kept by drawing it larger.
            let k = to
            return Gradient(kind: .radial, stops: clipped, start: CGPoint(x: center.x / w, y: center.y / h),
                            end: CGPoint(x: (center.x + rx * k) / w, y: center.y / h), radius: rx * k / w,
                            across: CGPoint(x: center.x / w, y: (center.y + ry * k) / h))
        default:
            return nil
        }
    }

    private static func firstWord(_ s: String) -> String { words(s).first ?? s }

    /// Whether a part of a gradient is a colour stop, not its direction or shape.
    private static func isStop(_ s: String) -> Bool { pickColor(words(s)).0 != nil }

    /// Which way a linear gradient runs, a unit vector in the box's pixels: from an angle or "to …".
    private static func direction(_ s: String, size: CGSize) -> CGVector? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("to ") {
            let w = Set(t.dropFirst(3).split(separator: " ").map(String.init))
            let x: CGFloat = w.contains("right") ? 1 : w.contains("left") ? -1 : 0
            let y: CGFloat = w.contains("bottom") ? 1 : w.contains("top") ? -1 : 0
            if x != 0 && y != 0 {
                // Into the corner, square to the line through the corners beside it.
                let v = CGVector(dx: x * size.height, dy: y * size.width)
                let l = hypot(v.dx, v.dy)
                return CGVector(dx: v.dx / l, dy: v.dy / l)
            }
            return CGVector(dx: x, dy: y)
        }
        guard let deg = angle(t) else { return nil }
        let r = deg * .pi / 180
        return CGVector(dx: sin(r), dy: -cos(r))
    }

    private static func radii(shape: String, extent: String, center c: CGPoint, size: CGSize) -> (CGFloat, CGFloat) {
        let dx = [c.x, size.width - c.x].map(abs), dy = [c.y, size.height - c.y].map(abs)
        let close = (dx.min() ?? 0, dy.min() ?? 0), far = (dx.max() ?? 0, dy.max() ?? 0)
        switch (shape, extent) {
        case ("circle", "closest-side"):
            let r = min(close.0, close.1)
            return (r, r)
        case ("circle", "farthest-side"):
            let r = max(far.0, far.1)
            return (r, r)
        case ("circle", "closest-corner"):
            let r = hypot(close.0, close.1)
            return (r, r)
        case ("circle", _):
            let r = hypot(far.0, far.1)
            return (r, r)
        case (_, "closest-side"): return close
        case (_, "farthest-side"): return far
        case (_, "closest-corner"): return (close.0 * sqrt(2), close.1 * sqrt(2))
        default: return (far.0 * sqrt(2), far.1 * sqrt(2))
        }
    }

    /// The stops of a gradient whose line is `length` long, each placed: those with no place
    /// shared out evenly between those that have one, and none before the one before it.
    static func stops(_ parts: [String], length: CGFloat) -> [GradientStop]? {
        var colors: [RGBA] = [], places: [CGFloat?] = []
        for part in parts {
            let (c, rest) = pickColor(words(part))
            // A hint alone, with no colour, is left out.
            guard let c else { continue }
            let at = rest.compactMap { word -> CGFloat? in
                if word.hasSuffix("%"), let v = Double(word.dropLast()) { return CGFloat(v) / 100 }
                return CSS.length(word).map { $0 / length }
            }
            if at.isEmpty {
                colors.append(c)
                places.append(nil)
            }
            for p in at {
                colors.append(c)
                places.append(p)
            }
        }
        guard colors.count >= 1 else { return nil }
        if colors.count == 1 { return [GradientStop(offset: 0, color: colors[0]), GradientStop(offset: 1, color: colors[0])] }
        if places[0] == nil { places[0] = 0 }
        if places[places.count - 1] == nil { places[places.count - 1] = 1 }
        var lastKnown = 0
        for i in 1..<places.count where places[i] != nil {
            if i - lastKnown > 1, let a = places[lastKnown], let b = places[i] {
                for k in (lastKnown + 1)..<i { places[k] = a + (b - a) * CGFloat(k - lastKnown) / CGFloat(i - lastKnown) }
            }
            lastKnown = i
        }
        var out: [GradientStop] = [], highest = -CGFloat.infinity
        for (c, p) in zip(colors, places) {
            let at = max(p ?? 0, highest)
            highest = at
            out.append(GradientStop(offset: Double(at), color: c))
        }
        return out
    }

    /// A repeating gradient's stops laid end to end until they fill the line, up to a hundred times.
    private static func repeated(_ stops: [GradientStop]) -> [GradientStop] {
        guard let first = stops.first?.offset, let last = stops.last?.offset, last - first > 0.005 else { return stops }
        let period = last - first
        var out: [GradientStop] = []
        // From the copy that begins at or before the start of the line, to the one past its end.
        var k = Int((-first / period).rounded(.down))
        var count = 0
        while count < 100, first + Double(k) * period <= 1 {
            let shift = Double(k) * period
            out += stops.map { GradientStop(offset: $0.offset + shift, color: $0.color) }
            k += 1
            count += 1
        }
        return out
    }

    /// Stops that run outside 0…1 cut off at the ends, with the colours they come to there; and
    /// where, along the line they were laid on, the kept ones begin and end.
    private static func clamp(_ stops: [GradientStop]) -> ([GradientStop], CGFloat, CGFloat) {
        guard let lo = stops.first?.offset, let hi = stops.last?.offset else { return (stops, 0, 1) }
        // Stops all inside the line: the line runs from the first to the last, which may be
        // closer together than 0…1, so the gradient keeps its own ends.
        if lo >= 0 && hi <= 1 { return (stops, 0, 1) }
        func color(at t: Double) -> RGBA {
            guard let i = stops.firstIndex(where: { $0.offset >= t }) else { return stops.last!.color }
            if i == 0 { return stops[0].color }
            let a = stops[i - 1], b = stops[i]
            let f = b.offset - a.offset > 0 ? (t - a.offset) / (b.offset - a.offset) : 1
            return RGBA(r: a.color.r + (b.color.r - a.color.r) * f, g: a.color.g + (b.color.g - a.color.g) * f,
                        b: a.color.b + (b.color.b - a.color.b) * f, a: a.color.a + (b.color.a - a.color.a) * f)
        }
        let from = max(lo, 0), to = min(hi, 1)
        // A radial gradient whose stops run past its edge grows to take them in.
        if lo >= 0 && hi > 1 {
            return (stops.map { GradientStop(offset: $0.offset / hi, color: $0.color) }, 0, CGFloat(hi))
        }
        var out = [GradientStop(offset: 0, color: color(at: from))]
        out += stops.filter { $0.offset > from && $0.offset < to }.map { GradientStop(offset: ($0.offset - from) / (to - from), color: $0.color) }
        out.append(GradientStop(offset: 1, color: color(at: to)))
        return (out, CGFloat(from), CGFloat(to))
    }

    // MARK: Positions

    /// A point in a box given as background-position or object-position words: keywords,
    /// lengths and percentages, and an edge with a length from it.
    static func position(_ words: [String], in size: CGSize, object: CGSize = .zero) -> CGPoint {
        var x: CGFloat?, y: CGFloat?
        let room = CGSize(width: size.width - object.width, height: size.height - object.height)
        var i = 0
        var pending: [String] = []
        while i < words.count {
            let w = words[i].lowercased()
            let next = i + 1 < words.count ? words[i + 1] : nil
            let nextIsLength = next.flatMap { length($0, of: 1) } != nil && !["center", "left", "right", "top", "bottom"].contains(next!.lowercased())
            switch w {
            case "left", "right":
                var v: CGFloat = w == "left" ? 0 : room.width
                if nextIsLength, let n = next, let d = length(n, of: room.width) { v = w == "left" ? d : room.width - d; i += 1 }
                x = v
            case "top", "bottom":
                var v: CGFloat = w == "top" ? 0 : room.height
                if nextIsLength, let n = next, let d = length(n, of: room.height) { v = w == "top" ? d : room.height - d; i += 1 }
                y = v
            case "center":
                pending.append("center")
            default:
                pending.append(w)
            }
            i += 1
        }
        for w in pending {
            if x == nil {
                x = w == "center" ? room.width / 2 : length(w, of: room.width) ?? room.width / 2
            } else if y == nil {
                y = w == "center" ? room.height / 2 : length(w, of: room.height) ?? room.height / 2
            }
        }
        return CGPoint(x: x ?? room.width / 2, y: y ?? room.height / 2)
    }

    /// One axis of a position on its own, as backgroundPositionX and Y give it.
    static func offset(_ s: String, room: CGFloat, horizontal: Bool) -> CGFloat {
        let words = words(s.lowercased())
        guard let first = words.first else { return room / 2 }
        switch first {
        case "left", "top":
            return words.count > 1 ? length(words[1], of: room) ?? 0 : 0
        case "right", "bottom":
            return room - (words.count > 1 ? length(words[1], of: room) ?? 0 : 0)
        case "center": return room / 2
        default: return length(first, of: room) ?? room / 2
        }
    }

    // MARK: Shapes a box is cut to

    enum ClipShape: Equatable {
        case rect(CGRect, radius: CGFloat)
        case ellipse(CGRect)
        /// SVG path data in the box's own coordinates.
        case path(String, evenOdd: Bool)
    }

    /// The shape of clip-path in a box of `size`, measured from its top left.
    static func clipShape(_ s: String, size: CGSize) -> ClipShape? {
        var value = s.trimmingCharacters(in: .whitespaces)
        for box in ["border-box", "padding-box", "content-box", "margin-box", "fill-box", "stroke-box", "view-box"] {
            value = value.replacingOccurrences(of: box, with: "").trimmingCharacters(in: .whitespaces)
        }
        guard let (name, args) = function(value) else { return nil }
        let w = size.width, h = size.height
        switch name {
        case "inset":
            var words = words(args)
            var radius: CGFloat = 0
            if let round = words.firstIndex(of: "round") {
                radius = words[(round + 1)...].first.flatMap { length($0, of: min(w, h)) } ?? 0
                words = Array(words[..<round])
            }
            let v = words.map { length($0, of: 0) ?? 0 }
            let vs = words.map { $0 }
            func at(_ i: Int, _ of: CGFloat) -> CGFloat {
                guard !vs.isEmpty else { return 0 }
                let idx: Int
                switch vs.count {
                case 1: idx = 0
                case 2: idx = i % 2
                case 3: idx = i == 3 ? 1 : i
                default: idx = i
                }
                return length(vs[idx], of: of) ?? v[idx]
            }
            let top = at(0, h), right = at(1, w), bottom = at(2, h), left = at(3, w)
            return .rect(CGRect(x: left, y: top, width: max(w - left - right, 0), height: max(h - top - bottom, 0)), radius: radius)
        case "circle", "ellipse":
            var words = words(args)
            var center = CGPoint(x: w / 2, y: h / 2)
            if let at = words.firstIndex(of: "at") {
                center = position(Array(words[(at + 1)...]), in: size)
                words = Array(words[..<at])
            }
            let reference = sqrt(w * w + h * h) / sqrt(2)
            func radius(_ word: String?, along: CGFloat, center c: CGFloat, side: CGFloat) -> CGFloat {
                switch word {
                case nil, "closest-side": return min(c, side - c)
                case "farthest-side": return max(c, side - c)
                default: return length(word!, of: along) ?? min(c, side - c)
                }
            }
            if name == "circle" {
                let word = words.first
                let r: CGFloat
                switch word {
                case nil, "closest-side": r = min(center.x, w - center.x, center.y, h - center.y)
                case "farthest-side": r = max(center.x, w - center.x, center.y, h - center.y)
                default: r = length(word!, of: reference) ?? min(w, h) / 2
                }
                return .ellipse(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
            let rx = radius(words.first, along: w, center: center.x, side: w)
            let ry = radius(words.count > 1 ? words[1] : nil, along: h, center: center.y, side: h)
            return .ellipse(CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
        case "polygon":
            var parts = split(args)
            var evenOdd = false
            if let first = parts.first, first == "evenodd" || first == "nonzero" {
                evenOdd = first == "evenodd"
                parts.removeFirst()
            }
            let points = parts.compactMap { part -> CGPoint? in
                let xy = words(part)
                guard xy.count == 2, let x = length(xy[0], of: w), let y = length(xy[1], of: h) else { return nil }
                return CGPoint(x: x, y: y)
            }
            guard points.count >= 3 else { return nil }
            let d = "M " + points.map { "\(num($0.x)) \(num($0.y))" }.joined(separator: " L ") + " Z"
            return .path(d, evenOdd: evenOdd)
        case "path":
            var parts = split(args)
            var evenOdd = false
            if parts.count > 1, parts[0] == "evenodd" || parts[0] == "nonzero" {
                evenOdd = parts[0] == "evenodd"
                parts.removeFirst()
            }
            guard let d = parts.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), !d.isEmpty else { return nil }
            return .path(d, evenOdd: evenOdd)
        default:
            return nil
        }
    }

    private static func num(_ v: CGFloat) -> String {
        let r = (v * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(Double(r))
    }
}
