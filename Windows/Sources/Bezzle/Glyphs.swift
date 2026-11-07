import Foundation
import WinUI
import UWP
import BezzleCore

/// The Mac's hand-drawn pictures for the tools and the layers' kinds (Views/Workspace.swift:
/// ToolGlyph, LayersGlyph, KindGlyph), point for point, as WinUI paths: round ends, one weight.
@MainActor
enum Glyphs {
    enum Tool: String, CaseIterable {
        case select, artboard, rectangle, ellipse, line, pen, knife, text, note
        var title: String {
            switch self {
            case .select: "Select"
            case .artboard: "Artboard"
            case .rectangle: "Rectangle"
            case .ellipse: "Ellipse"
            case .line: "Line"
            case .pen: "Pen"
            case .knife: "Knife"
            case .text: "Text"
            case .note: "Note"
            }
        }
        var key: String {
            switch self {
            case .select: "V"
            case .artboard: "A"
            case .rectangle: "R"
            case .ellipse: "E"
            case .line: "L"
            case .pen: "P"
            case .knife: "K"
            case .text: "T"
            case .note: "N"
            }
        }
    }

    /// One part of a picture: stroked, filled, or filled with the paper and then stroked (a sheet
    /// laid over another).
    struct Part {
        enum Mode { case stroke, fill, cover }
        var data: String
        var mode: Mode
        var width = 1.5
        /// Round ends, or cut straight across, as dashes are.
        var round = true
    }

    /// A picture `size` square in `brush`, as a WinUI element.
    static func view(_ parts: [Part], size: Double, brush: Brush) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = size
        canvas.height = size
        canvas.isHitTestVisible = false
        for part in parts {
            guard let path = shape(part) else { continue }
            switch part.mode {
            case .stroke: path.stroke = brush
            case .fill: path.fill = brush
            case .cover: path.fill = Theme.brush(Theme.paper); path.stroke = brush
            }
            canvas.children.append(path)
        }
        return canvas
    }

    /// An artboard's shape in small, as the Mac's FrameGlyph: its proportions in a box `box`
    /// square, on the card's fill with an ink rim, a carousel's slides parted by lines.
    static func frame(size: CGSize, box: Double = 22, slides: Int = 1) -> FrameworkElement {
        let holder = Grid()
        holder.width = box
        holder.height = box
        holder.isHitTestVisible = false
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let s = box / max(w, h)
        let sheet = Grid()
        sheet.width = max(w * s, 6)
        sheet.height = max(h * s, 6)
        sheet.horizontalAlignment = .center
        sheet.verticalAlignment = .center
        let fill = Border()
        fill.cornerRadius = Theme.corners(2)
        fill.background = Theme.brush(Theme.card)
        sheet.children.append(fill)
        if slides > 1 {
            let lines = Canvas()
            for i in 1..<slides {
                let line = Border()
                line.width = 1
                line.height = sheet.height
                line.background = Theme.ink(3)
                try? Canvas.setLeft(line, sheet.width * Double(i) / Double(slides) - 0.5)
                lines.children.append(line)
            }
            sheet.children.append(lines)
        }
        let rim = Border()
        rim.cornerRadius = Theme.corners(2)
        rim.borderBrush = Theme.ink(2)
        rim.borderThickness = Theme.inset(1.2)
        sheet.children.append(rim)
        holder.children.append(sheet)
        return holder
    }

    /// The Mac's MaskGlyph: a hill and a sun seen through a round window.
    static func mask(size: Double = 14, brush: Brush) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = size
        canvas.height = size
        canvas.isHitTestVisible = false
        let glyph = WindowsCore.maskGlyph(size: size)
        for (data, filled) in [(glyph.fill, true), (glyph.rim, false)] {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='1.3'/>"
            guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
            if filled { path.fill = brush } else { path.stroke = brush }
            canvas.children.append(path)
        }
        return canvas
    }

    /// Two rings overlapping, filled where a path's outline lies over itself, or with the
    /// overlap cut out (the Mac's OverlapGlyph): 32 by 20.
    static func overlap(cut: Bool, brush: Brush) -> FrameworkElement {
        let canvas = Canvas()
        canvas.width = 32
        canvas.height = 20
        canvas.isHitTestVisible = false
        let r = 6.5, step = 7.0, y = 10.0, x = (32 - step) / 2
        func ring(_ cx: Double) -> String {
            String(format: "M%.2f,%.2f A%.2f,%.2f 0 1 1 %.2f,%.2f A%.2f,%.2f 0 1 1 %.2f,%.2f Z ", cx - r, y, r, r, cx + r, y, r, r, cx - r, y)
        }
        let rings = ring(x) + ring(x + step)
        for filled in [true, false] {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(filled ? (cut ? "F0 " : "F1 ") : "")\(rings)' StrokeThickness='1'/>"
            guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
            if filled {
                path.fill = brush
                path.opacity = 0.5
            } else {
                path.stroke = brush
            }
            canvas.children.append(path)
        }
        return canvas
    }

    /// A tick, as the Mac's CheckMark.
    static func check(size s: Double = 10) -> [Part] {
        var p = PathData()
        p.move(s * 0.12, s * 0.55)
        p.line(s * 0.4, s * 0.82)
        p.line(s * 0.88, s * 0.18)
        return [Part(data: p.d, mode: .stroke, width: 1.5)]
    }

    /// A glyph made by `view` in another ink.
    static func paint(_ view: FrameworkElement, _ brush: Brush) {
        guard let canvas = view as? Canvas else { return }
        for child in canvas.children {
            guard let path = child as? WinUI.Path else { continue }
            if path.stroke != nil { path.stroke = brush }
            if path.fill != nil { path.fill = brush }
        }
    }

    /// Locked, a padlock filled and shut; unlocked, outlined with its shackle open, as the Mac's
    /// lock.fill and lock.open.
    static func lock(locked: Bool, size s: Double = 12) -> [Part] {
        var body = PathData(), shackle = PathData()
        body.rect(s * 0.2, s * 0.46, s * 0.6, s * 0.42, radius: s * 0.08)
        shackle.move(s * 0.33, s * 0.46)
        shackle.line(s * 0.33, s * 0.32)
        shackle.cubic(s * 0.33, s * 0.12, s * 0.67, s * 0.12, s * 0.67, s * 0.32)
        if locked { shackle.line(s * 0.67, s * 0.46) } else { shackle.line(s * 0.67, s * 0.36) }
        return [Part(data: body.d, mode: locked ? .fill : .stroke, width: 1.1), Part(data: shackle.d, mode: .stroke, width: 1.2)]
    }

    /// An eye, and struck through while hidden, as the Mac's eye and eye.slash.
    static func eye(hidden: Bool, size s: Double = 12) -> [Part] {
        var outline = PathData(), pupil = PathData()
        outline.move(s * 0.06, s * 0.5)
        outline.quad(s * 0.5, s * 0.08, s * 0.94, s * 0.5)
        outline.quad(s * 0.5, s * 0.92, s * 0.06, s * 0.5)
        outline.close()
        pupil.ellipse(s * 0.37, s * 0.37, s * 0.26, s * 0.26)
        var parts = [Part(data: outline.d, mode: .stroke, width: 1.1), Part(data: pupil.d, mode: .fill)]
        if hidden {
            var slash = PathData()
            slash.move(s * 0.16, s * 0.12)
            slash.line(s * 0.84, s * 0.88)
            parts.append(Part(data: slash.d, mode: .stroke, width: 1.2))
        }
        return parts
    }

    private static func shape(_ part: Part) -> WinUI.Path? {
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(part.data)' "
            + "StrokeThickness='\(part.width)' StrokeStartLineCap='\(part.round ? "Round" : "Flat")' StrokeEndLineCap='\(part.round ? "Round" : "Flat")' StrokeLineJoin='Round'/>"
        return (try? XamlReader.load(xaml)) as? WinUI.Path
    }

    static func tool(_ tool: Tool, size s: Double = 18) -> [Part] {
        let w = s, h = s
        var p = PathData()
        switch tool {
        case .select:
            p.move(w * 0.26, h * 0.14); p.line(w * 0.78, h * 0.56); p.line(w * 0.52, h * 0.60); p.line(w * 0.66, h * 0.88)
            p.line(w * 0.56, h * 0.92); p.line(w * 0.43, h * 0.64); p.line(w * 0.26, h * 0.80); p.close()
            return [Part(data: p.d, mode: .fill)]
        case .artboard:
            p.rect(w * 0.26, h * 0.26, w * 0.48, h * 0.48)
            for (x, y) in [(0.26, 0.26), (0.74, 0.26), (0.74, 0.74), (0.26, 0.74)] {
                let dx = x < 0.5 ? -1.0 : 1.0, dy = y < 0.5 ? -1.0 : 1.0
                p.move(w * x, h * (y + dy * 0.06)); p.line(w * x, h * (y + dy * 0.2))
                p.move(w * (x + dx * 0.06), h * y); p.line(w * (x + dx * 0.2), h * y)
            }
        case .rectangle:
            p.rect(w * 0.16, h * 0.22, w * 0.68, h * 0.56, radius: 2)
        case .ellipse:
            p.ellipse(w * 0.17, h * 0.17, w * 0.66, h * 0.66)
        case .line:
            p.move(w * 0.2, h * 0.8); p.line(w * 0.8, h * 0.2)
        case .pen:
            // A nib writing towards the bottom left, with the collar above it: drawn upright, point
            // down, then turned.
            let k = w / 18 * 1.12
            p.place = Affine(tx: w / 2 - 4.24 * k, ty: h / 2 + 4.24 * k, angle: .pi / 4, scale: k)
            p.move(0, 0); p.quad(4.4, -4.2, 4.2, -8.6); p.line(-4.2, -8.6); p.quad(-4.4, -4.2, 0, 0); p.close()
            p.move(0, -0.8); p.line(0, -4.6)
            p.move(-2.8, -11.6); p.line(2.8, -11.6)
            var dot = PathData()
            dot.place = p.place
            dot.ellipse(-1.25, -6.9, 2.5, 2.5)
            return [Part(data: p.d, mode: .stroke), Part(data: dot.d, mode: .fill)]
        case .knife:
            // A box cutter cutting towards the bottom left, as the pen writes.
            let k = w / 18 * 0.92
            p.place = Affine(tx: w / 2 - 6.4 * k, ty: h / 2 + 6.4 * k, angle: .pi / 4, scale: k)
            p.move(-2.4, 0); p.line(2.4, -4.4); p.line(2.4, -6.4); p.line(-2.4, -6.4); p.close()
            p.move(-3.6, -8); p.line(3.6, -8)
            p.rect(-2.8, -18.1, 5.6, 8.4, radius: 1.6)
            p.move(0, -12.2); p.line(0, -15.4)
        case .text:
            p.move(w * 0.22, h * 0.28); p.line(w * 0.22, h * 0.2); p.line(w * 0.78, h * 0.2); p.line(w * 0.78, h * 0.28)
            p.move(w * 0.5, h * 0.2); p.line(w * 0.5, h * 0.82)
            p.move(w * 0.38, h * 0.82); p.line(w * 0.62, h * 0.82)
        case .note:
            p.rect(w * 0.4, h * 0.16, w * 0.44, h * 0.36, radius: w * 0.06)
            p.move(w * 0.5, h * 0.28); p.line(w * 0.74, h * 0.28)
            p.move(w * 0.5, h * 0.4); p.line(w * 0.66, h * 0.4)
            p.move(w * 0.4, h * 0.46); p.quad(w * 0.26, h * 0.5, w * 0.24, h * 0.74)
            var dot = PathData()
            dot.ellipse(w * 0.24 - 1.6, h * 0.74 - 1.6, 3.2, 3.2)
            return [Part(data: p.d, mode: .stroke), Part(data: dot.d, mode: .fill)]
        }
        return [Part(data: p.d, mode: .stroke)]
    }

    /// Two sheets, one over the other: the layers switch.
    static func layers(size s: Double = 18) -> [Part] {
        func sheet(_ y: Double) -> String {
            var p = PathData()
            p.move(s * 0.5, s * (y - 0.18)); p.line(s * 0.88, s * y); p.line(s * 0.5, s * (y + 0.18)); p.line(s * 0.12, s * y); p.close()
            return p.d
        }
        return [Part(data: sheet(0.6), mode: .stroke), Part(data: sheet(0.4), mode: .cover)]
    }

    /// A small picture of a layer's kind, for the layers list (15 points).
    static func kind(_ kind: String, size s: Double = 15) -> [Part] {
        switch kind {
        case "artboard": return tool(.artboard, size: s)
        case "rectangle": return tool(.rectangle, size: s)
        case "ellipse": return tool(.ellipse, size: s)
        case "line": return tool(.line, size: s)
        case "text": return tool(.text, size: s)
        case "group":
            var back = PathData(), front = PathData()
            back.rect(s * 0.14, s * 0.14, s * 0.5, s * 0.5, radius: 1.5)
            front.rect(s * 0.36, s * 0.36, s * 0.5, s * 0.5, radius: 1.5)
            return [Part(data: back.d, mode: .stroke, width: 1.3), Part(data: front.d, mode: .cover, width: 1.3)]
        default:
            var p = PathData(), dots = PathData()
            p.move(s * 0.16, s * 0.8); p.cubic(s * 0.2, s * 0.2, s * 0.6, s * 0.86, s * 0.84, s * 0.22)
            dots.ellipse(s * 0.16 - 1.6, s * 0.8 - 1.6, 3.2, 3.2)
            dots.ellipse(s * 0.84 - 1.6, s * 0.22 - 1.6, 3.2, 3.2)
            return [Part(data: p.d, mode: .stroke, width: 1.3), Part(data: dots.d, mode: .fill)]
        }
    }

    /// A ring, for the corners card; a disc, for opacity.
    static func ring(size s: Double = 16) -> [Part] {
        var p = PathData()
        p.ellipse(s * 0.18, s * 0.18, s * 0.64, s * 0.64)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }

    static func disc(size s: Double = 16) -> [Part] {
        var p = PathData()
        p.ellipse(s * 0.18, s * 0.18, s * 0.64, s * 0.64)
        return [Part(data: p.d, mode: .fill)]
    }

    /// The tab's close cross: 18 square, line 1.3, as TabBar.swift draws it.
    static func cross(size s: Double = 18) -> [Part] {
        var p = PathData()
        p.move(s * 0.36, s * 0.36); p.line(s * 0.64, s * 0.64)
        p.move(s * 0.64, s * 0.36); p.line(s * 0.36, s * 0.64)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    static func plus(size s: Double = 26) -> [Part] {
        var p = PathData()
        p.move(s * 0.5, s * 0.32); p.line(s * 0.5, s * 0.68)
        p.move(s * 0.32, s * 0.5); p.line(s * 0.68, s * 0.5)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }

    /// Versions: a clock with an arrow going back round it (the Mac's clock.arrow.circlepath, drawn
    /// here in Bezzle's own hand, as Apple's symbols are not to be used off its platforms).
    static func history(size s: Double = 16) -> [Part] {
        var p = PathData()
        let cx = s * 0.52, cy = s * 0.52, r = s * 0.34
        // Most of a circle, from the left round over the top, ending in an arrowhead at the left.
        p.move(cx - r, cy)
        for k in 1...15 {
            let a = Double.pi + Double(k) / 15 * 1.65 * Double.pi
            p.line(cx + r * cos(a), cy + r * sin(a))
        }
        p.move(cx - r - s * 0.1, cy - s * 0.1); p.line(cx - r, cy); p.line(cx - r + s * 0.1, cy - s * 0.08)
        p.move(cx, cy - r * 0.55); p.line(cx, cy); p.line(cx + r * 0.45, cy + r * 0.3)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// Share: two people, one behind the other (the Mac's person.2.fill, in Bezzle's own hand).
    static func share(size s: Double = 14) -> [Part] {
        var back = PathData(), front = PathData()
        back.ellipse(s * 0.56, s * 0.14, s * 0.3, s * 0.3)
        back.move(s * 0.46, s * 0.86); back.cubic(s * 0.5, s * 0.56, s * 0.94, s * 0.56, s * 0.98, s * 0.86); back.close()
        front.ellipse(s * 0.14, s * 0.2, s * 0.34, s * 0.34)
        front.move(s * 0.0, s * 0.94); front.cubic(s * 0.04, s * 0.6, s * 0.58, s * 0.6, s * 0.62, s * 0.94); front.close()
        return [Part(data: back.d, mode: .fill), Part(data: front.d, mode: .fill)]
    }

    /// The disclosure chevron of a row that holds layers, pointing down (open) or right.
    enum Alignment { case left, centerX, right, top, centerY, bottom }

    /// Align, as the Mac's align.horizontal/vertical symbols draw it: the line things line up on,
    /// and two bars, one longer, set against it (or across it, for centres and middles).
    static func align(_ how: Alignment, size s: Double = 16) -> [Part] {
        let across = [Alignment.left, .centerX, .right].contains(how)
        func at(_ x: Double, _ y: Double) -> (Double, Double) { across ? (x * s, y * s) : (y * s, x * s) }
        let along: Double = switch how {
        case .left, .top: 0.16
        case .centerX, .centerY: 0.5
        case .right, .bottom: 0.84
        }
        var line = PathData(), bars = PathData()
        let a = at(along, 0.1), b = at(along, 0.9)
        line.move(a.0, a.1)
        line.line(b.0, b.1)
        for (top, length) in [(0.24, 0.62), (0.58, 0.4)] {
            let start: Double = switch how {
            case .left, .top: along + 0.08
            case .centerX, .centerY: 0.5 - length / 2
            case .right, .bottom: along - 0.08 - length
            }
            let p = at(start, top), q = at(start + length, top + 0.18)
            bars.rect(min(p.0, q.0), min(p.1, q.1), abs(q.0 - p.0), abs(q.1 - p.1), radius: s * 0.04)
        }
        return [Part(data: line.d, mode: .stroke, width: 1.3), Part(data: bars.d, mode: .fill)]
    }

    /// Space evenly, as distribute.horizontal/vertical draw it: two lines at the ends and a block
    /// between them.
    static func distribute(horizontally: Bool, size s: Double = 16) -> [Part] {
        func at(_ x: Double, _ y: Double) -> (Double, Double) { horizontally ? (x * s, y * s) : (y * s, x * s) }
        var lines = PathData(), block = PathData()
        for x in [0.14, 0.86] {
            let a = at(x, 0.12), b = at(x, 0.88)
            lines.move(a.0, a.1)
            lines.line(b.0, b.1)
        }
        let p = at(0.36, 0.28), q = at(0.64, 0.72)
        block.rect(min(p.0, q.0), min(p.1, q.1), abs(q.0 - p.0), abs(q.1 - p.1), radius: s * 0.05)
        return [Part(data: lines.d, mode: .stroke, width: 1.3), Part(data: block.d, mode: .fill)]
    }

    /// Flip, as the Mac's symbols draw it: two right triangles mirrored across their line, under
    /// an arrow both ways (turned a quarter for top to bottom).
    static func flip(horizontally: Bool, size s: Double = 16) -> [Part] {
        func at(_ x: Double, _ y: Double) -> (Double, Double) { horizontally ? (x * s, y * s) : (y * s, x * s) }
        var t = PathData(), a = PathData()
        for (x, y) in [(0.44, 0.38), (0.44, 0.84), (0.12, 0.84)] {
            let p = at(x, y)
            if t.d.isEmpty { t.move(p.0, p.1) } else { t.line(p.0, p.1) }
        }
        t.close()
        for (k, (x, y)) in [(0.56, 0.38), (0.56, 0.84), (0.88, 0.84)].enumerated() {
            let p = at(x, y)
            if k == 0 { t.move(p.0, p.1) } else { t.line(p.0, p.1) }
        }
        t.close()
        let l = at(0.2, 0.17), r = at(0.8, 0.17)
        a.move(l.0, l.1); a.line(r.0, r.1)
        for (tip, back) in [(0.2, 0.31), (0.8, 0.69)] {
            let p = at(back, 0.07), q = at(tip, 0.17), u = at(back, 0.27)
            a.move(p.0, p.1); a.line(q.0, q.1); a.line(u.0, u.1)
        }
        return [Part(data: t.d, mode: .stroke, width: 1.2), Part(data: a.d, mode: .stroke, width: 1.2)]
    }

    /// The Mac's ComponentGlyph: four diamonds round a middle.
    static func component(size s: Double = 13) -> [Part] {
        var p = PathData()
        let c = s / 2, r = s * 0.25, d = s * 0.2
        for (x, y) in [(c, c - r), (c + r, c), (c, c + r), (c - r, c)] {
            p.move(x, y - d); p.line(x + d, y); p.line(x, y + d); p.line(x - d, y); p.close()
        }
        return [Part(data: p.d, mode: .fill)]
    }

    /// A pin, for what is kept as it is: a head and a point.
    static func pin(size s: Double = 14) -> [Part] {
        var head = PathData()
        let c = s / 2
        head.move(c - s * 0.22, s * 0.12); head.line(c + s * 0.22, s * 0.12); head.line(c + s * 0.16, s * 0.5)
        head.line(c + s * 0.28, s * 0.62); head.line(c - s * 0.28, s * 0.62); head.line(c - s * 0.16, s * 0.5); head.close()
        var point = PathData()
        point.move(c, s * 0.62); point.line(c, s * 0.92)
        return [Part(data: head.d, mode: .stroke, width: 1.2), Part(data: point.d, mode: .stroke, width: 1.2)]
    }

    /// A diamond, as a component is marked over its copy.
    static func diamond(size s: Double = 8) -> [Part] {
        var p = PathData()
        p.move(s / 2, 0); p.line(s, s / 2); p.line(s / 2, s); p.line(0, s / 2); p.close()
        return [Part(data: p.d, mode: .fill)]
    }

    /// A chevron pointing left, for the copy before.
    static func back(size s: Double = 9) -> [Part] {
        var p = PathData()
        p.move(s * 0.65, s * 0.2); p.line(s * 0.35, s * 0.5); p.line(s * 0.65, s * 0.8)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// From the start again: a ring open at its top left, running round to an arrow there.
    static func restart(size s: Double = 32) -> [Part] {
        var p = PathData()
        let cx = s * 0.5, cy = s * 0.52, r = s * 0.17
        var first = true
        var a = 180.0
        while a >= -110 {
            let x = cx + r * cos(a * .pi / 180), y = cy + r * sin(a * .pi / 180)
            if first { p.move(x, y); first = false } else { p.line(x, y) }
            a -= 10
        }
        let end = -110.0 * .pi / 180
        let ex = cx + r * cos(end), ey = cy + r * sin(end)
        let dx = sin(end), dy = -cos(end), head = s * 0.09
        for turn in [0.7, -0.7] {
            let bx = -(dx * cos(turn) - dy * sin(turn)), by = -(dx * sin(turn) + dy * cos(turn))
            p.move(ex, ey); p.line(ex + bx * head, ey + by * head)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.6)]
    }

    /// The triangle of play.
    static func play(size s: Double = 12) -> [Part] {
        var p = PathData()
        p.move(s * 0.3, s * 0.2); p.line(s * 0.3, s * 0.8); p.line(s * 0.8, s * 0.5); p.close()
        return [Part(data: p.d, mode: .fill)]
    }

    static func chevron(open: Bool, size s: Double = 9) -> [Part] {
        var p = PathData()
        if open { p.move(s * 0.2, s * 0.35); p.line(s * 0.5, s * 0.65); p.line(s * 0.8, s * 0.35) }
        else { p.move(s * 0.35, s * 0.2); p.line(s * 0.65, s * 0.5); p.line(s * 0.35, s * 0.8) }
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }
}

/// A turn, a scale and a move, as the Mac's `CGAffineTransform(translationX:y:).rotated(by:).scaledBy(x:y:)`.
struct Affine {
    var tx = 0.0, ty = 0.0, angle = 0.0, scale = 1.0
    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        let c = cos(angle), s = sin(angle)
        return (tx + (x * c - y * s) * scale, ty + (x * s + y * c) * scale)
    }
}

/// Path data as XAML reads it (the SVG path syntax), in points.
struct PathData {
    var d = ""
    var place = Affine()

    private func n(_ v: Double) -> String { String(format: "%.3f", v) }
    private func pt(_ x: Double, _ y: Double) -> String { let (a, b) = place.apply(x, y); return n(a) + "," + n(b) }

    mutating func move(_ x: Double, _ y: Double) { d += "M" + pt(x, y) + " " }
    mutating func line(_ x: Double, _ y: Double) { d += "L" + pt(x, y) + " " }
    mutating func quad(_ cx: Double, _ cy: Double, _ x: Double, _ y: Double) { d += "Q" + pt(cx, cy) + " " + pt(x, y) + " " }
    mutating func cubic(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ x: Double, _ y: Double) {
        d += "C" + pt(c1x, c1y) + " " + pt(c2x, c2y) + " " + pt(x, y) + " "
    }
    mutating func close() { d += "Z " }

    /// A rectangle, its corners rounded by `radius` with quarter curves (kappa 0.5523).
    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double = 0) {
        let r = min(radius, w / 2, h / 2)
        guard r > 0 else { move(x, y); line(x + w, y); line(x + w, y + h); line(x, y + h); close(); return }
        let k = r * 0.5523
        move(x + r, y); line(x + w - r, y); cubic(x + w - r + k, y, x + w, y + r - k, x + w, y + r)
        line(x + w, y + h - r); cubic(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h)
        line(x + r, y + h); cubic(x + r - k, y + h, x, y + h - r + k, x, y + h - r)
        line(x, y + r); cubic(x, y + r - k, x + r - k, y, x + r, y); close()
    }

    /// A rectangle whose corners are each rounded their own way (SwiftUI's UnevenRoundedRectangle),
    /// clockwise from the top left.
    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, corners tl: Double, _ tr: Double, _ br: Double, _ bl: Double) {
        let m = min(w, h) / 2
        let a = min(tl, m), b = min(tr, m), c = min(br, m), e = min(bl, m), k = 0.5523
        move(x + a, y); line(x + w - b, y)
        if b > 0 { cubic(x + w - b + b * k, y, x + w, y + b - b * k, x + w, y + b) }
        line(x + w, y + h - c)
        if c > 0 { cubic(x + w, y + h - c + c * k, x + w - c + c * k, y + h, x + w - c, y + h) }
        line(x + e, y + h)
        if e > 0 { cubic(x + e - e * k, y + h, x, y + h - e + e * k, x, y + h - e) }
        line(x, y + a)
        if a > 0 { cubic(x, y + a - a * k, x + a - a * k, y, x + a, y) }
        close()
    }

    /// An ellipse in four cubic quarters.
    mutating func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        let rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry, kx = rx * 0.5523, ky = ry * 0.5523
        move(cx + rx, cy)
        cubic(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
        cubic(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
        cubic(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
        cubic(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
        close()
    }
}

// MARK: - Text

extension Glyphs {
    /// Lines set left, centred, right or justified, as text.alignleft and the others draw them.
    static func textAlign(_ how: String, size s: Double = 14) -> [Part] {
        var p = PathData()
        for (k, long) in [true, false, true, false].enumerated() {
            let y = s * (0.2 + Double(k) * 0.2)
            let full = s * 0.76, short = s * 0.5
            let w = how == "justify" ? (k == 3 ? short : full) : long ? full : short
            let x: Double = switch how {
            case "center": (s - w) / 2
            case "right": s * 0.88 - w
            default: s * 0.12
            }
            p.move(x, y)
            p.line(x + w, y)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// A U over a line, as the underline symbol.
    static func underline(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.3, s * 0.14)
        p.line(s * 0.3, s * 0.5)
        p.cubic(s * 0.3, s * 0.76, s * 0.7, s * 0.76, s * 0.7, s * 0.5)
        p.line(s * 0.7, s * 0.14)
        p.move(s * 0.22, s * 0.88)
        p.line(s * 0.78, s * 0.88)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// An S with a line through it, as the strikethrough symbol.
    static func strikethrough(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.7, s * 0.25)
        p.cubic(s * 0.65, s * 0.15, s * 0.56, s * 0.12, s * 0.49, s * 0.12)
        p.cubic(s * 0.37, s * 0.12, s * 0.3, s * 0.2, s * 0.3, s * 0.29)
        p.cubic(s * 0.3, s * 0.47, s * 0.7, s * 0.45, s * 0.7, s * 0.67)
        p.cubic(s * 0.7, s * 0.79, s * 0.61, s * 0.87, s * 0.5, s * 0.87)
        p.cubic(s * 0.4, s * 0.87, s * 0.32, s * 0.82, s * 0.28, s * 0.74)
        p.move(s * 0.16, s * 0.5)
        p.line(s * 0.84, s * 0.5)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// Three items of a list, each after a dot or its number, as list.bullet and list.number.
    static func list(numbered: Bool, size s: Double = 14) -> [Part] {
        var lines = PathData(), marks = PathData()
        for k in 0..<3 {
            let y = s * (0.22 + Double(k) * 0.28)
            lines.move(s * 0.36, y)
            lines.line(s * 0.9, y)
            if !numbered {
                let r = s * 0.065
                marks.rect(s * 0.16 - r, y - r, 2 * r, 2 * r, radius: r)
            }
        }
        guard numbered else { return [Part(data: lines.d, mode: .stroke, width: 1.3), Part(data: marks.d, mode: .fill)] }
        var digits = PathData()
        // 1, 2 and 3, small, before the lines.
        digits.move(s * 0.12, s * 0.17); digits.line(s * 0.17, s * 0.13); digits.line(s * 0.17, s * 0.31)
        digits.move(s * 0.1, s * 0.42)
        digits.cubic(s * 0.11, s * 0.37, s * 0.23, s * 0.37, s * 0.23, s * 0.44)
        digits.cubic(s * 0.23, s * 0.49, s * 0.1, s * 0.53, s * 0.1, s * 0.59)
        digits.line(s * 0.24, s * 0.59)
        digits.move(s * 0.1, s * 0.69)
        digits.cubic(s * 0.13, s * 0.65, s * 0.23, s * 0.65, s * 0.23, s * 0.71)
        digits.cubic(s * 0.23, s * 0.75, s * 0.18, s * 0.77, s * 0.15, s * 0.77)
        digits.cubic(s * 0.2, s * 0.77, s * 0.24, s * 0.8, s * 0.24, s * 0.84)
        digits.cubic(s * 0.24, s * 0.9, s * 0.13, s * 0.92, s * 0.1, s * 0.86)
        return [Part(data: lines.d, mode: .stroke, width: 1.3), Part(data: digits.d, mode: .stroke, width: 1.0)]
    }

    /// A line with an arrowhead at either end, across or down, as arrow.left.and.right and
    /// arrow.up.and.down.
    static func bothWays(across: Bool, size s: Double = 14) -> [Part] {
        func at(_ x: Double, _ y: Double) -> (Double, Double) { across ? (x * s, y * s) : (y * s, x * s) }
        var p = PathData()
        let a = at(0.12, 0.5), b = at(0.88, 0.5)
        p.move(a.0, a.1); p.line(b.0, b.1)
        for (tip, back) in [(0.12, 0.3), (0.88, 0.7)] {
            let t = at(tip, 0.5), u = at(back, 0.32), v = at(back, 0.68)
            p.move(u.0, u.1); p.line(t.0, t.1); p.line(v.0, v.1)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// A box drawn in dashes, as rectangle.dashed.
    static func dashedBox(size s: Double = 14) -> [Part] {
        var p = PathData()
        let x0 = s * 0.1, x1 = s * 0.9, y0 = s * 0.22, y1 = s * 0.78
        // Each side in dashes, a dash at every corner.
        func side(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, dashes: Int) {
            let n = Double(dashes * 2 - 1)
            for k in stride(from: 0, to: dashes * 2, by: 2) {
                let f = Double(k) / n, g = Double(k + 1) / n
                p.move(ax + (bx - ax) * f, ay + (by - ay) * f)
                p.line(ax + (bx - ax) * g, ay + (by - ay) * g)
            }
        }
        side(x0, y0, x1, y0, dashes: 4)
        side(x0, y1, x1, y1, dashes: 4)
        side(x0, y0, x0, y1, dashes: 3)
        side(x1, y0, x1, y1, dashes: 3)
        return [Part(data: p.d, mode: .stroke, width: 1.2)]
    }

    /// A chevron pointing down, 9 square, as the Mac's Chevron; up, as it is turned when open.
    static func chevron(up: Bool = false, size s: Double = 9) -> [Part] {
        var p = PathData()
        p.move(s * 0.18, s * (up ? 0.64 : 0.36))
        p.line(s * 0.5, s * (up ? 0.34 : 0.66))
        p.line(s * 0.82, s * (up ? 0.64 : 0.36))
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }
}

// MARK: - Looks

extension Glyphs {
    /// A framed picture of a hill under the sun, as the photo symbol.
    static func picture(size s: Double = 12) -> [Part] {
        var frame = PathData(), hill = PathData(), sun = PathData()
        frame.rect(s * 0.06, s * 0.14, s * 0.88, s * 0.72, radius: s * 0.12)
        hill.move(s * 0.14, s * 0.78); hill.line(s * 0.42, s * 0.46); hill.line(s * 0.6, s * 0.64); hill.line(s * 0.7, s * 0.54); hill.line(s * 0.86, s * 0.78)
        sun.rect(s * 0.62, s * 0.26, s * 0.14, s * 0.14, radius: s * 0.07)
        return [Part(data: frame.d, mode: .stroke, width: 1.1), Part(data: hill.d, mode: .stroke, width: 1.1), Part(data: sun.d, mode: .fill)]
    }

    /// A ring filled from the left as far as `level`, as the Mac's LevelGlyph.
    static func level(_ level: Double, size s: Double = 14) -> [Part] {
        var ring = PathData()
        ring.rect(s * 0.05, s * 0.05, s * 0.9, s * 0.9, radius: s * 0.45)
        let l = min(max(level, 0), 1)
        guard l > 0 else { return [Part(data: ring.d, mode: .stroke, width: 1.4)] }
        // The part of the disc left of x = l·s: an arc and a chord.
        var fill = PathData()
        let r = s * 0.45, c = s * 0.5
        let x = s * 0.05 + l * s * 0.9
        if l >= 0.999 {
            fill.rect(s * 0.05, s * 0.05, s * 0.9, s * 0.9, radius: r)
        } else {
            let dx = x - c, dy = (r * r - dx * dx).squareRoot()
            fill.move(x, c - dy)
            fill.d += "A\(r),\(r) 0 \(dx > 0 ? 1 : 0) 0 \(String(format: "%.3f", x)),\(String(format: "%.3f", c + dy)) Z "
        }
        return [Part(data: fill.d, mode: .fill), Part(data: ring.d, mode: .stroke, width: 1.4)]
    }

    /// A corner rounded as a choice rounds it, or a pill, as the Mac's CornerGlyph: spread apart
    /// so each reads at a glance, rather than to scale.
    static func corner(_ radius: Double?, size s: Double = 16) -> [Part] {
        var p = PathData()
        let r: Double = switch radius {
        case nil: 5.5
        case let r? where r <= 0: 0
        case let r? where r <= 4: 2.5
        case let r? where r <= 12: 4.5
        default: 7
        }
        if radius == nil {
            p.rect((s - 21) / 2 + 0.7, (s - 11) / 2 + 0.7, 19.6, 9.6, radius: r)
        } else {
            p.rect((s - 15) / 2 + 0.7, (s - 15) / 2 + 0.7, 13.6, 13.6, radius: r)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }

    /// A square drawn in a border's weight, or dashed, as the Mac's BorderGlyph.
    static func border(_ width: Double?, size s: Double = 16) -> [Part] {
        let w: Double = width.map { $0 == 1 ? 1 : $0 == 2 ? 1.8 : 3 } ?? 1.3
        let o = (s - 15) / 2 + w / 2, side = 15 - w
        guard width == nil else {
            var p = PathData()
            p.rect(o, o, side, side, radius: 2.5)
            return [Part(data: p.d, mode: .stroke, width: w)]
        }
        // Dashed: each side in dashes 2.6 long, 2 apart.
        var p = PathData()
        for (ax, ay, bx, by) in [(o, o, o + side, o), (o + side, o, o + side, o + side), (o + side, o + side, o, o + side), (o, o + side, o, o)] {
            let length = abs(bx - ax) + abs(by - ay)
            var t = 0.0
            while t < length {
                let e = min(t + 2.6, length)
                p.move(ax + (bx - ax) * t / length, ay + (by - ay) * t / length)
                p.line(ax + (bx - ax) * e / length, ay + (by - ay) * e / length)
                t = e + 2
            }
        }
        return [Part(data: p.d, mode: .stroke, width: w)]
    }
}

extension Glyphs {
    enum Edge { case inside, center, outside }

    /// Where a border lies on its layer's edge, as square.inset.filled, square.dashed and square.fill.
    static func edge(_ edge: Edge, size s: Double = 14) -> [Part] {
        var p = PathData()
        switch edge {
        case .inside:
            p.rect(s * 0.1, s * 0.1, s * 0.8, s * 0.8, radius: s * 0.16)
            var inner = PathData()
            inner.rect(s * 0.27, s * 0.27, s * 0.46, s * 0.46, radius: s * 0.06)
            return [Part(data: p.d, mode: .stroke, width: 1.2), Part(data: inner.d, mode: .fill)]
        case .center:
            return dashedBox(size: s)
        case .outside:
            p.rect(s * 0.1, s * 0.1, s * 0.8, s * 0.8, radius: s * 0.16)
            return [Part(data: p.d, mode: .fill)]
        }
    }
}

extension Glyphs {
    /// A tray with an arrow rising out of it, as square.and.arrow.up.
    static func export(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.34, s * 0.42); p.line(s * 0.2, s * 0.42); p.line(s * 0.2, s * 0.9); p.line(s * 0.8, s * 0.9); p.line(s * 0.8, s * 0.42); p.line(s * 0.66, s * 0.42)
        p.move(s * 0.5, s * 0.62); p.line(s * 0.5, s * 0.08)
        p.move(s * 0.34, s * 0.22); p.line(s * 0.5, s * 0.08); p.line(s * 0.66, s * 0.22)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    static func minus(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.3, s * 0.5); p.line(s * 0.7, s * 0.5)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }
}
