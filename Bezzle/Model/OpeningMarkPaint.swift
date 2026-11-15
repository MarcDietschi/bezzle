import Foundation
import CoreGraphics

/// The drawing of Bezzle's mark as the opening cover shows it (`OpeningMark`): each part of each
/// sheet's impression, as the icon presses it into its tile (Scripts/make-icon.swift, `press`),
/// here into the window's own paper, light or dark.
nonisolated extension OpeningMark {
    static func path(of sheet: Int) -> CGPath {
        let r = sheets[sheet]
        return CGPath(roundedRect: r, cornerWidth: corner(of: r), cornerHeight: corner(of: r), transform: nil)
    }

    /// Paints a part of a sheet's impression into `ctx`, whose space is the mark's units with y
    /// down, `canvas` filling it, and `pixels` pixels to a unit: shadows are measured in pixels.
    static func paint(_ part: Part, of sheet: Int, dark: Bool, pixels: CGFloat, in ctx: CGContext) {
        let shape = path(of: sheet)
        // Everything but the sheet: clipping to it reaches the paper round the sheet, and a shadow
        // of filling it falls inside the sheet, from its edge.
        let around = CGMutablePath()
        around.addRect(canvas.insetBy(dx: -1000, dy: -1000))
        around.addPath(shape)
        let depth = depths[sheet]
        let inks = Inks(dark: dark)
        // Shadows go in pixels, with y up.
        func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: RGBA) {
            ctx.setShadow(offset: CGSize(width: 0, height: -dy * pixels), blur: blur * pixels, color: color.cgColor)
        }
        func floor(_ stops: [(CGFloat, RGBA)]) {
            let box = sheets[sheet]
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { $0.1.cgColor } as CFArray,
                                            locations: stops.map { $0.0 }) else { return }
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip(using: .evenOdd)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY - box.height * 0.07),
                                   end: CGPoint(x: box.midX, y: box.maxY + box.height * 0.07),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        func walls(_ w: Inks.Walls) {
            for (dy, blur, shade) in [(36 * depth, 54 * depth, w.deep), (9 * depth, 9 * depth, w.edge), (-11 * depth, 14 * depth, w.light)] {
                ctx.saveGState()
                ctx.addPath(shape)
                ctx.clip(using: .evenOdd)
                shadow(dy, blur, shade)
                ctx.addPath(around)
                ctx.setFillColor(RGBA(r: 0, g: 0, b: 0, a: 1).cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            }
        }
        switch part {
        case .rim:
            let w = inks.bare
            for (dy, blur, shade) in [(-9 * depth, 25 * depth, w.rimShade), (11 * depth, 11 * depth, w.rimLight)] {
                ctx.saveGState()
                ctx.addPath(around)
                ctx.clip(using: .evenOdd)
                shadow(dy, blur, shade)
                ctx.addPath(shape)
                ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 1).cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            }
        case .floor:
            floor(inks.floors[sheet])
        case .walls:
            walls(inks.bare)
        case .ink:
            floor(inks.ink)
        case .inkWalls:
            walls(inks.inked)
        }
    }

    /// The paper's shades and the pencil's ink, as the icon has them in the light, and as they
    /// read on the dark paper.
    struct Inks {
        struct Walls {
            let rimShade, rimLight, deep, edge, light: RGBA
        }
        /// Each sheet's floor, darker a step down, top to bottom.
        let floors: [[(CGFloat, RGBA)]]
        let ink: [(CGFloat, RGBA)]
        let bare, inked: Walls

        init(dark: Bool) {
            func c(_ hex: String, _ a: Double = 1) -> RGBA { RGBA(hex: hex, alpha: a)! }
            if dark {
                // On dark paper a step down reads by the light its lower lip catches more than
                // by its shade, which the paper already has.
                floors = [[(0, c("141311")), (1, c("1A1917"))], [(0, c("100F0E")), (1, c("171614"))], [(0, c("0D0C0B")), (1, c("141312"))]]
                ink = [(0, c("2C4895")), (0.6, c("3D5CB5")), (1, c("5271C6"))]
                bare = Walls(rimShade: c("000000", 0.7), rimLight: c("FFFFFF", 0.16), deep: c("000000", 0.7),
                             edge: c("000000", 0.6), light: c("FFFFFF", 0.12))
                inked = Walls(rimShade: c("000000", 0.7), rimLight: c("FFFFFF", 0.16), deep: c("040A24", 0.75),
                              edge: c("02061A", 0.6), light: c("C8D6FF", 0.3))
            } else {
                floors = [[(0, c("DDD8CE")), (1, c("E8E4DC"))], [(0, c("D3CDC1")), (1, c("E0DBD1"))], [(0, c("C9C2B5")), (1, c("D8D2C6"))]]
                ink = [(0, c("2B4596")), (0.6, c("3D5DB8")), (1, c("5373C6"))]
                bare = Walls(rimShade: c("3A2A1C", 0.29), rimLight: c("FFFFFF"), deep: c("3A2A1C", 0.4),
                             edge: c("2A1E12", 0.3), light: c("FFFFFF", 0.75))
                inked = Walls(rimShade: c("3A2A1C", 0.29), rimLight: c("FFFFFF"), deep: c("08154A", 0.7),
                              edge: c("040B2E", 0.55), light: c("D6E1FF", 0.55))
            }
        }
    }
}
