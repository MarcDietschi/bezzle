import Foundation
import CBezzleHost

// Small pictures the panels show that only the renderer can draw as the Mac does: a blur, a
// pane blurring what is behind it, a card blurring toward an edge. Each is a few layers drawn by
// the shared Renderer onto nothing, into pixels as `render(board:)` hands them over.

extension WindowsCore {
    /// A colour as the panels give it: six hex digits and an alpha.
    private static func ink(_ hex: UInt32, _ alpha: Double = 1) -> RGBA {
        RGBA(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: alpha)
    }

    private static func shape(_ kind: Node.Kind, _ frame: CGRect, fill: RGBA?, border: (RGBA, CGFloat)? = nil, radius: CGFloat = 0) -> Node {
        var n = Node(kind: kind, name: "", frame: frame)
        n.fill.on = fill != nil
        if let fill { n.fill.color = fill }
        n.border.on = border != nil
        if let (c, w) = border {
            n.border.color = c
            n.border.width = w
            n.border.position = .inside
        }
        n.cornerRadius = radius
        return n
    }

    /// Draws `nodes` (in a `size` box) at `scale` pixels a point, into pixels: on a clear
    /// artboard, as a blur works out what it blurs from the artboard it lies on.
    static func drawGlyph(_ nodes: [Node], size: CGSize, scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        var board = Node(kind: .artboard, name: "", frame: CGRect(origin: .zero, size: size))
        board.fill.on = true
        board.fill.color = RGBA(r: 1, g: 1, b: 1, a: 0)
        board.children = nodes
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = Renderer.image(of: board, scale: CGFloat(scale), opaque: false, assets: assets) else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }

    /// The Mac's BlurGlyph, 18 square: a dot 11 across in `ink` softened by `amount` (0 a touch,
    /// 1 heavy); behind, the dot half under a pane 8 by 15 that blurs what it lies over.
    public static func blurGlyph(amount: Double, behind: Bool, ink hex: UInt32, scale: Double,
                                 into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        let soft = CGFloat(0.3 + amount * 2.6), c = ink(hex)
        var dot = shape(.ellipse, CGRect(x: 1.5, y: 3.5, width: 11, height: 11), fill: c)
        guard behind else {
            dot.frame.origin = CGPoint(x: 3.5, y: 3.5)
            dot.blur = Blur(radius: soft)
            return drawGlyph([dot], size: CGSize(width: 18, height: 18), scale: scale, into: fill)
        }
        var pane = shape(.rectangle, CGRect(x: 8.5, y: 1.5, width: 8, height: 15), fill: nil, border: (c, 1), radius: 2)
        pane.blur = Blur(radius: soft, background: true)
        return drawGlyph([dot, pane], size: CGSize(width: 18, height: 18), scale: scale, into: fill)
    }

    /// The Mac's RampSample on its pad, `size` big: a card with a dot and three lines on it, in
    /// `card` and `ink`, blurred by 3 from sharp at the ramp's start to whole at its end.
    public static func rampSample(size: CGSize, start: CGPoint, end: CGPoint, card: UInt32, ink hex: UInt32, scale: Double,
                                  into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        let w = size.width, h = size.height, m = min(w, h) * 0.16
        var group = Node(kind: .group, name: "", frame: CGRect(origin: .zero, size: size))
        var children = [shape(.rectangle, CGRect(origin: .zero, size: size), fill: ink(card), border: (ink(hex, 0.35), 1), radius: 5),
                        shape(.ellipse, CGRect(x: m, y: m, width: m * 1.6, height: m * 1.6), fill: ink(hex, 0.75))]
        for (i, f) in [0.9, 0.7, 0.8].enumerated() {
            let bar = max(m * 0.45, 2)
            children.append(shape(.rectangle, CGRect(x: m, y: m * 3.3 + CGFloat(i) * m * 1.1, width: (w - m * 2) * f, height: bar),
                                  fill: ink(hex, 0.55), radius: bar / 2))
        }
        group.children = children
        var blur = Blur(radius: 3)
        blur.ramp = BlurRamp(start: start, end: end)
        group.blur = blur
        return drawGlyph([group], size: size, scale: scale, into: fill)
    }
}

extension WindowsCore {
    /// The Mac's MaskGlyph, `size` square: a hill and a sun seen through a round window, as path
    /// data: what is filled (cut to the window) and the window's rim.
    public static func maskGlyph(size s: Double) -> (fill: String, rim: String) {
        let r = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: 0.8, dy: 0.8)
        let window = CGPath(ellipseIn: r, transform: nil)
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: r.minX - 1, y: r.maxY + 1))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.52))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.7))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.58))
        hill.addLine(to: CGPoint(x: r.maxX + 1, y: r.maxY + 1))
        hill.closeSubpath()
        let sun = CGPath(ellipseIn: CGRect(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.18, width: r.width * 0.22, height: r.width * 0.22), transform: nil)
        let seen = hill.union(sun).intersection(window)
        return (PathData.string(seen), PathData.string(window))
    }
}
