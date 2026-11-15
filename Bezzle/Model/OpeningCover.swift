import Foundation
import CoreGraphics

/// While a design opens, its tab is covered by the window's own paper with Bezzle's mark pressed
/// into it (`OpeningMark`), and uncovered once the design is drawn: never an empty or half-built
/// window. This is when the mark comes, how long it stays and when the paper lifts, the same on the
/// Mac and on Windows. Times are seconds on the platform's own clock.
nonisolated struct OpeningCover: Equatable, Sendable {
    /// How long opening may take before the mark is pressed at all: a design open sooner simply
    /// comes through the paper, without a mark that would come and go in a flash. Not while the
    /// window grows to make room for the first design, which takes longer than this by itself: then
    /// the mark is pressed as the paper grows.
    static let grace: Double = 0.25
    /// How long the mark stays once it is pressed, before the paper lifts: its gesture complete.
    static let least: Double = 0.72
    /// How long the paper takes to lift, the mark pressed flat and the design coming through.
    static let lifting: Double = 0.34
    /// How long a design opened within the grace takes to come through the paper.
    static let quick: Double = 0.16
    /// How long the cover waits, once the design is open, for its canvas to be drawn in full: one
    /// in a window out of sight never is.
    static let patience: Double = 1.6

    /// When opening began.
    let began: Double
    /// When the mark is pressed.
    let marks: Double

    init(began: Double, growing: Bool) {
        self.began = began
        marks = growing ? began : began + Self.grace
    }

    /// The design is ready at `now` (open and drawn in full, or open and waited for long enough,
    /// or could not be opened): when the paper lifts, and whether the mark is there to lift with it.
    func lift(readyAt now: Double) -> (at: Double, marked: Bool) {
        now < marks ? (now, false) : (max(now, marks + Self.least), true)
    }

    /// When the cover is gone, the design all the way through.
    func gone(readyAt now: Double) -> Double {
        let lift = lift(readyAt: now)
        return lift.at + (lift.marked ? Self.lifting : Self.quick)
    }
}

/// Bezzle's mark as the cover shows it: the three sheets of its icon (Scripts/make-icon.swift,
/// "layers"), each pressed a step deeper into the paper than the one around it, the deepest inked
/// with the pencil's blue, and under them its name. The gesture is a press at work: each sheet is
/// struck in turn, a die coming down onto the paper, its soft shadow drawing in to the sheet's edge
/// as it lands, a hair past and back; the ink runs into the deepest from its top edge; the name is
/// set letter by letter, each struck into its place. While the design is still on its way, the
/// sheets breathe, pressed a little shallower and deeper again in turn; and when it is there, the
/// mark is pressed flat and the paper clears. Both platforms draw the same parts (`paint`) and move
/// them by the same numbers.
nonisolated enum OpeningMark {
    /// The sheets, outermost first, in units of which the outer one is 500 across.
    static let sheets: [CGRect] = [CGRect(x: 0, y: 0, width: 500, height: 500),
                                   CGRect(x: 78, y: 78, width: 400, height: 400),
                                   CGRect(x: 156, y: 156, width: 300, height: 300)]
    /// How deep each is pressed, as the icon has them.
    static let depths: [CGFloat] = [0.7, 0.6, 0.6]
    /// Room round the outer sheet, in units, for the shadows its edges cast on the paper.
    static let margin: CGFloat = 48
    /// The whole of what is drawn of a sheet, its shadows on the paper included, in units.
    static let canvas = CGRect(x: -margin, y: -margin, width: 500 + margin * 2, height: 500 + margin * 2)

    /// The outer sheet's side on screen, in points.
    static let side: CGFloat = 76
    /// The name under the mark: its letters' size in points, how far below the outer sheet its
    /// letters' tops are, and how far apart they are set, of their size.
    static let word = "Bezzle"
    static let wordSize: CGFloat = 27
    static let wordGap: CGFloat = 21
    static let wordTracking: CGFloat = -0.01
    /// How far above the middle of the room the mark and its name together sit, of the room's
    /// height: where the eye takes the middle to be.
    static let lift: CGFloat = 0.035

    static func corner(of rect: CGRect) -> CGFloat { rect.width * 0.2 }

    static func path(of sheet: Int) -> CGPath {
        let r = sheets[sheet]
        return CGPath(roundedRect: r, cornerWidth: corner(of: r), cornerHeight: corner(of: r), transform: nil)
    }

    /// The middle of a sheet, in the units of `canvas` from its top left: what each is struck about.
    static func middle(of sheet: Int) -> CGPoint {
        CGPoint(x: sheets[sheet].midX - canvas.minX, y: sheets[sheet].midY - canvas.minY)
    }

    // MARK: The gesture, in seconds after the mark is pressed

    /// When each sheet is struck.
    static let strikes: [Double] = [0, 0.11, 0.22]
    /// How a sheet lands: its impression drawn in from `strikeFrom` times its size to its own.
    static let strike = Spring(response: 0.46, damping: 0.64)
    static let strikeFrom: CGFloat = 1.12
    /// How long a sheet's impression takes to come up from nothing to its full depth.
    static let deepens: Double = 0.24
    /// When the ink begins to run into the deepest sheet, and how long it takes to fill it.
    static let inks: Double = 0.30
    static let inking: Double = 0.38
    /// When each letter of the name is set, how long it takes to show, and how it is struck as the
    /// sheets are: from `letterFrom` times its size and `letterDrop` of its size above, into place.
    static func sets(_ letter: Int) -> Double { 0.22 + Double(letter) * 0.04 }
    static let letterShows: Double = 0.16
    static let letter = Spring(response: 0.34, damping: 0.75)
    static let letterFrom: CGFloat = 1.3
    static let letterDrop: CGFloat = 0.08
    /// The breathing after the gesture: when it begins, how long one breath takes in and out,
    /// how shallow a sheet is at its shallowest, of its depth, and how far behind the one around
    /// it each sheet breathes. Eased in and out, so it never moves in steps or starts over.
    static let breathes: Double = 1.1
    static let breath: Double = 3.2
    static let shallowest: CGFloat = 0.55
    static func breathLag(_ sheet: Int) -> Double { Double(sheet) * 0.32 }
    /// The lift: the mark is pressed flat over `flattens`, sinking to `flatTo` of its size, and the
    /// paper clears from `clears` after the lift begins, over the rest of `OpeningCover.lifting`.
    static let flattens: Double = 0.18
    static let flatTo: CGFloat = 0.96
    static let clears: Double = 0.1

    /// A spring as SwiftUI gives one, by its response and damping fraction, from 0 to 1.
    struct Spring: Equatable, Sendable {
        let response: Double
        let damping: Double

        /// How far along it is at `t` seconds: 0 at the start, settling at 1, a little past it on
        /// the way when it is not damped through.
        func value(at t: Double) -> Double {
            guard t > 0 else { return 0 }
            let w = 2 * Double.pi / response, z = damping
            if z >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
        }

        /// How long it takes to come within a hair of 1 and stay there.
        var settles: Double {
            let w = 2 * Double.pi / response
            return log(1 / 0.001) / (min(damping, 1) * w)
        }

        /// Its course as moments and how far along, `count` of them evenly over `settles`, the
        /// last at exactly 1: the key frames each platform moves by.
        func course(_ count: Int = 32) -> [(t: Double, v: Double)] {
            let end = settles
            return (0...count).map { i in
                let t = end * Double(i) / Double(count)
                return (t, i == count ? 1 : value(at: t))
            }
        }
    }

    // MARK: Painting

    /// What a sheet's impression is drawn in, each its own picture so each can move on its own:
    /// the paper round its edge, shaded above and lit below (`rim`); its floor (`floor`); the
    /// shadows its walls cast onto the floor (`walls`); and, for the deepest, the pencil's ink
    /// over both, its floor (`ink`) and the darker shadows of its walls (`inkWalls`).
    enum Part: CaseIterable, Sendable { case rim, floor, walls, ink, inkWalls }

    /// Whether a sheet has a part: only the deepest is inked.
    static func has(_ part: Part, _ sheet: Int) -> Bool { (part != .ink && part != .inkWalls) || sheet == sheets.count - 1 }

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
