import Foundation
import CoreGraphics

// The choices the inspector's cards offer, shared by every Bezzle: corners, shadows, borders,
// text sizes, blurs and the rest, and how each is put on a layer. The Mac's PresetStrips and the
// Windows ones offer the same.

enum Presets {
    /// Corner radii by name; a pill rounds the short sides fully, whatever the size.
    static let corners: [(id: String, name: LocalizedStringResource, radius: CGFloat?)] = [
        ("corner-square", "Square", 0), ("corner-slight", "Slightly rounded", 4), ("corner-soft", "Soft", 12),
        ("corner-round", "Round", 24), ("corner-pill", "Pill", nil),
    ]

    /// How smoothly a squircle's corners run into its sides when it is chosen: a little smoother
    /// than the 60% iOS draws its icons with.
    static let squircle: CGFloat = 0.8

    static func cornerRadius(_ radius: CGFloat?, for node: Node) -> CGFloat {
        radius ?? min(node.frame.width, node.frame.height) / 2
    }

    typealias ShadowPreset = (id: String, name: LocalizedStringResource, y: CGFloat, blur: CGFloat, alpha: Double, inset: Bool)

    /// Shadows from barely there to floating high above; each keeps the layer's own shadow colour.
    static let shadows: [ShadowPreset] = [
        ("shadow-subtle", "Subtle", 1, 3, 0.14, false), ("shadow-soft", LocalizedStringResource("shadow.soft", defaultValue: "Soft", comment: "A shadow preset."), 4, 12, 0.14, false),
        ("shadow-lifted", "Lifted", 10, 28, 0.18, false), ("shadow-floating", "Floating", 24, 56, 0.22, false),
    ]

    /// Shadows inside, from a fine line along the top edge to a deep hollow, each across from the
    /// shadow under the layer in the same place.
    static let innerShadows: [ShadowPreset] = [
        ("shadow-etched", "Etched", 1, 2, 0.14, true), ("shadow-pressed", "Pressed", 2, 6, 0.16, true),
        ("shadow-sunken", "Sunken", 4, 12, 0.2, true), ("shadow-deep", "Deep", 8, 24, 0.26, true),
    ]

    static func applyShadow(_ preset: ShadowPreset, to n: inout Node) { applyShadow(preset, to: &n.shadow) }

    static func applyShadow(_ preset: ShadowPreset, to s: inout Shadow) {
        s.on = true
        s.x = 0
        s.y = preset.y
        s.blur = preset.blur
        s.spread = nil
        s.color = s.color.with(alpha: preset.alpha)
        s.inset = preset.inset ? true : nil
    }

    /// A new shadow made by a preset, in the colour of `like`.
    static func shadow(_ preset: ShadowPreset, like: Shadow) -> Shadow {
        var s = like
        applyShadow(preset, to: &s)
        return s
    }

    static func isShadow(_ preset: ShadowPreset, _ s: Shadow) -> Bool {
        s.on && (s.inset == true) == preset.inset && s.x == 0 && s.y == preset.y && s.blur == preset.blur && s.grown == 0
            && abs(s.color.a - preset.alpha) < 0.005
    }

    /// Moves a shadow inside the layer or back under it. A shadow that is one of the choices
    /// becomes the one across from it, Soft becoming Pressed; one set by hand keeps its numbers.
    static func setShadowInset(_ inset: Bool, on n: inout Node) { setShadowInset(inset, on: &n.shadow) }

    static func setShadowInset(_ inset: Bool, on s: inout Shadow) {
        let from = inset ? shadows : innerShadows, to = inset ? innerShadows : shadows
        if let i = from.firstIndex(where: { isShadow($0, s) }) {
            applyShadow(to[i], to: &s)
        } else {
            s.on = true
            s.inset = inset ? true : nil
        }
    }

    /// How high a shadow lifts its layer: 0 for none, 1 for the first preset and each whole step
    /// the next, and between two presets a blend of them, measured by how far the shadow falls.
    /// A shadow inside goes by the presets inside.
    static func elevation(of s: Shadow) -> Double {
        let falls = [0] + (s.inset == true ? innerShadows : shadows).map(\.y)
        let y = max(s.y, 0)
        for i in 1..<falls.count where y <= falls[i] {
            return Double(i - 1) + Double((y - falls[i - 1]) / max(falls[i] - falls[i - 1], .ulpOfOne))
        }
        return Double(falls.count - 1)
    }

    /// The highest elevation, the last preset's.
    static var topElevation: Double { Double(shadows.count) }

    /// Lifts the layer's shadow to an elevation, keeping its colour, how far it falls sideways and
    /// whether it falls inside. A whole elevation is that preset exactly.
    static func setElevation(_ elevation: Double, on n: inout Node) { setElevation(elevation, on: &n.shadow) }

    static func setElevation(_ elevation: Double, on s: inout Shadow) {
        let presets = s.inset == true ? innerShadows : shadows
        let steps: [(y: CGFloat, blur: CGFloat, alpha: Double)] = [(0, 0, 0)] + presets.map { ($0.y, $0.blur, $0.alpha) }
        let e = min(max(elevation, 0), Double(steps.count - 1))
        let i = min(Int(e), steps.count - 2), t = e - Double(i)
        let a = steps[i], b = steps[i + 1]
        let between = { (x: CGFloat, y: CGFloat) in t == 0 ? x : t == 1 ? y : ((x + (y - x) * t) * 10).rounded() / 10 }
        s.on = true
        s.y = between(a.y, b.y)
        s.blur = between(a.blur, b.blur)
        s.color = s.color.with(alpha: t == 0 ? a.alpha : t == 1 ? b.alpha : a.alpha + (b.alpha - a.alpha) * t)
    }

    /// Border weights, and a dashed line of the weight there is.
    static let borders: [(id: String, name: LocalizedStringResource, width: CGFloat?)] = [
        ("border-thin", "Thin", 1), ("border-medium", "Medium", 2), ("border-bold", "Bold", 4), ("border-dashed", "Dashed", nil),
    ]

    static func applyBorder(_ width: CGFloat?, to n: inout Node) { applyBorder(width, to: &n.border) }

    static func applyBorder(_ width: CGFloat?, to b: inout Border) {
        b.on = true
        if let width {
            b.width = width
            b.dash = 0
            b.gap = 0
        } else {
            b.dash = max(4, b.width * 2)
            b.gap = b.dash
        }
    }

    // MARK: Another one

    /// A fill to lay over a layer's others: a shade from nothing at the top to dark at the bottom,
    /// as words over a picture want, and plain to see over anything, to make into what it should be.
    static let overlay = Fill(color: RGBA(r: 0, g: 0, b: 0, a: 0.5),
                              gradient: Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0, g: 0, b: 0, a: 0)),
                                                                        GradientStop(offset: 1, color: RGBA(r: 0, g: 0, b: 0, a: 0.5))],
                                                 start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)))

    /// A border to draw over a layer's others: a ring of their colour, fainter, on the other side
    /// of the edge from the top one, so that both show. A line's is a finer line along the middle
    /// of it, in white over a dark one and black over a light one.
    static func border(over n: Node) -> Border {
        let top = n.borders.last ?? Border(on: true)
        var b = top
        b.on = true
        b.dash = 0
        b.gap = 0
        if n.kind == .line {
            b.width = max((top.width / 3 * 2).rounded() / 2, 0.5)
            b.color = top.color.hsb.b > 0.6 ? .black : .white
        } else {
            b.width = max(2, top.width)
            b.position = top.position == .outside ? .inside : .outside
            b.color = top.color.with(alpha: max(top.color.a * 0.35, 0.15))
        }
        return b
    }

    /// A shadow to cast with a layer's others, falling the way `like` does: under the layer, a
    /// close one that sets it down on the page, as a soft one far below cannot alone; inside it, a
    /// fine line along the top edge.
    static func shadow(besides like: Shadow) -> Shadow {
        shadow(like.inset == true ? innerShadows[0] : shadows[0], like: like)
    }

    static func isBorder(_ width: CGFloat?, _ b: Border) -> Bool {
        guard b.on else { return false }
        if let width { return b.width == width && b.dash == 0 }
        return b.dash > 0
    }

    /// A type scale, from small print to display.
    static let textSizes: [CGFloat] = [12, 14, 16, 20, 24, 32, 48, 64]

    /// Blurs from a touch to heavy, of the layer itself or of what lies behind it.
    static let blurs: [(id: String, name: LocalizedStringResource, radius: CGFloat)] = [
        ("blur-slight", "Slight", 3), ("blur-soft", LocalizedStringResource("blur.soft", defaultValue: "Soft", comment: "A blur preset."), 8), ("blur-strong", "Strong", 16), ("blur-heavy", "Heavy", 32),
    ]

    /// Blurs that grow toward one edge of the layer, by the edge: 0 the bottom, then the left, top and right.
    static let ramps: [(id: String, name: LocalizedStringResource, edge: Int)] = [
        ("ramp-bottom", "Toward the bottom", 0), ("ramp-top", "Toward the top", 2), ("ramp-left", "Toward the left", 1), ("ramp-right", "Toward the right", 3),
    ]

    /// A layer just put in 3D: held up a little, turned toward the left, as a card is to be looked at.
    static let heldUp = Transform3D(x: 16, y: -22)

    /// Blurs the layer by `radius`, keeping whether it blurs the layer or what is behind it.
    static func applyBlur(_ radius: CGFloat, to n: inout Node) {
        var blur = n.blur ?? Blur(radius: radius)
        blur.on = true
        blur.radius = radius
        n.blur = blur
    }
}

