import SwiftUI
import AppKit

/// Warm paper and near-black ink, Gerty's and Distill's stock, with one colour of Bezzle's own:
/// the blue pencil a draftsman marks a sheet up with. It is what Bezzle draws over your work
/// (selection, handles, guides, measurements) and the one or two places that point at it.
/// Every action is ink.
enum Theme {
    static let paper = dynamic(0xF0EDE7, 0x1B1A18)
    static let panel = dynamic(0xF6F4EF, 0x22211F)
    static let card = dynamic(0xFCFBF8, 0x2A2926)
    static let well = dynamic(0xE5E1D9, 0x141312)
    static let ink = dynamic(0x1C1B19, 0xEDEAE4)
    static let ink2 = ink.opacity(0.64)
    static let ink3 = ink.opacity(0.44)
    static let ink4 = ink.opacity(0.22)
    static let hairline = ink.opacity(0.09)
    static let shadow = dynamic(0x3A3226, 0x000000)
    static let lip = dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.75, darkAlpha: 0.05)
    /// Text on the ink button.
    static let onInk = dynamic(0xF6F4EF, 0x1B1A18)

    static let pencil = dynamic(0x3559C7, 0x8FA8F2)
    static let pencilWash = dynamic(0x3559C7, 0x8FA8F2, lightAlpha: 0.10, darkAlpha: 0.16)
    /// Reserved for things that went wrong.
    static let warning = dynamic(0xB3402F, 0xE4705C)

    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let quick = Animation.spring(response: 0.18, dampingFraction: 0.9)
    static let open = Animation.spring(response: 0.24, dampingFraction: 0.86)
    static let close = Animation.easeIn(duration: 0.12)
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.58)
    /// A part of a panel opening or shutting. It never overshoots, since what it holds is clipped to it.
    static let unfold = Animation.spring(response: 0.3, dampingFraction: 1)
    /// What a part holds leaves before its room has closed, and comes once its room has begun to open.
    static let fadeOut = Animation.easeOut(duration: 0.08)
    static let fadeIn = Animation.easeOut(duration: 0.18).delay(0.07)
    /// A menu growing out of its control, settling with a little give.
    static let menu = Animation.spring(response: 0.26, dampingFraction: 0.74)

    static let radius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    /// How tall a control in a row of them is: fields, menus, wells of choices, so that side by
    /// side they line up top and bottom.
    static let controlHeight: CGFloat = 28
    /// Height of the strip along the top of the window, level with the traffic lights.
    static let barHeight: CGFloat = 52

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark, darkAlpha) : hex(light, lightAlpha)
        }
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// The canvas's own colours, for drawing with Core Graphics. Your work keeps its colours in either
/// appearance; only the table it lies on and the marks drawn over it follow the window.
enum CanvasInk {
    /// The table the artboards lie on: a well pressed into the paper.
    static let table = Theme.dynamicNS(0xE5E1D9, 0x0F0E0D)
    /// Selection, handles and guides. One blue that reads on white artboards and on the dark table alike.
    static let pencil = Theme.hex(0x3A63D8)
    /// Gaps as wide as each other, set apart from the guides in pencil.
    static let gap = Theme.hex(0xE0457B)
    static let label = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.50, darkAlpha: 0.50)
    static let labelSelected = Theme.dynamicNS(0x3559C7, 0x8FA8F2)
    static let shadow = Theme.dynamicNS(0x3A3226, 0x000000)
    /// A layout grid's columns and rows: the red a margin is ruled in on lined paper.
    static let column = Theme.hex(0xE5484D)
    /// Its baselines: the pale blue of the lines on that paper.
    static let baseline = Theme.hex(0x1E9BD7)
    /// The rulers: printed on the table itself, down in the well with the work, and a shade lighter
    /// along the artboard they measure.
    static let ruler = table
    static let rulerSheet = Theme.dynamicNS(0xEAE7E0, 0x161514)
    static let rulerInk = Theme.dynamicNS(0x1C1B19, 0xEDEAE4)
}

// MARK: - Surfaces

extension View {
    /// A card resting on the paper: lighter stock, hairline edge, soft contact shadow.
    func card(radius: CGFloat = Theme.radius, lifted: Bool = false, fill: Color = Theme.card) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .shadow(color: Theme.shadow.opacity(lifted ? 0.16 : 0.07), radius: lifted ? 18 : 7, y: lifted ? 9 : 3)
                .shadow(color: Theme.shadow.opacity(0.08), radius: 0.5, y: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }

    /// A well pressed into the paper: darker floor, inner shadow along the top, light lip below.
    func well(radius: CGFloat = 10, depth: CGFloat = 1) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.well.shadow(.inner(color: Theme.shadow.opacity(0.22 * depth), radius: 1.5 * depth, y: depth)))
                .shadow(color: Theme.lip, radius: 0, y: 1)
        }
    }
}

struct Hairline: View {
    var vertical = false
    /// One pixel of the screen it is on: half a point on Retina, a whole one at 1×, where half
    /// a point would round to a pixel in some places and to nothing in others.
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: vertical ? 1 / scale : nil, height: vertical ? nil : 1 / scale)
    }
}

/// The check mark, drawn rather than taken from the symbol set: a short stroke and a long one
/// meeting in a soft corner.
struct CheckMark: View {
    var size: CGFloat = 11
    var color: Color = Theme.ink
    var weight: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: CGPoint(x: s.width * 0.12, y: s.height * 0.54))
            p.addLine(to: CGPoint(x: s.width * 0.40, y: s.height * 0.80))
            p.addLine(to: CGPoint(x: s.width * 0.90, y: s.height * 0.20))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A small square that holds a tick when on.
struct CheckBox: View {
    @Binding var isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? Theme.ink : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn ? Theme.ink : Theme.ink3, lineWidth: 1)
            }
            .overlay {
                CheckMark(size: 10, color: Theme.onInk, weight: 1.5)
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn ? 1 : 0.6)
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle().inset(by: -4))
            .onTapGesture { withAnimation(Theme.quick) { isOn.toggle() } }
            .animation(Theme.quick, value: isOn)
            .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// A small chevron for menus, also drawn.
struct Chevron: View {
    var color: Color = Theme.ink3

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: CGPoint(x: s.width * 0.18, y: s.height * 0.36))
            p.addLine(to: CGPoint(x: s.width * 0.5, y: s.height * 0.66))
            p.addLine(to: CGPoint(x: s.width * 0.82, y: s.height * 0.36))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 9, height: 9)
    }
}

extension View {
    /// Pointer feedback for things that can be clicked.
    func pointingHand() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// Lets a scrolling area dissolve at an edge instead of being cut off there. The fade only shows
/// where there is more to scroll to, so content at rest is never dimmed.
private struct EdgeFade: ViewModifier {
    var length: CGFloat = 28
    @State private var above = false
    @State private var below = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { g in
                [g.contentOffset.y > 1, g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1]
            } action: { _, more in
                withAnimation(.easeOut(duration: 0.2)) { above = more[0]; below = more[1] }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                }
            }
    }
}

extension View {
    func edgeFade(length: CGFloat = 28) -> some View { modifier(EdgeFade(length: length)) }

    /// A sentence or two that says how something works, in the system face at `size`. SwiftUI
    /// sets lines as close as the font allows, about 1.2 times its size: right for a label on one
    /// line, crowded for a sentence that wraps. These are opened to about 1.45, on a half point.
    func prose(_ size: CGFloat) -> some View {
        font(.system(size: size)).lineSpacing((size * 0.5).rounded() / 2)
    }
}

// MARK: - Opening and shutting

/// How a part of a panel opens and shuts: its room grows and shrinks from the top edge (or the
/// leading one, for a panel beside others), and what it holds is clipped to the room it has so
/// far, so it never slides over its neighbours as they move. What it holds fades out at once as
/// it shuts, and in once there is room for it.
struct Unfold: Transition {
    var axis: Axis = .vertical

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .animation(phase.isIdentity ? Theme.fadeIn : Theme.fadeOut) { $0.opacity(phase.isIdentity ? 1 : 0) }
            .clipShape(UnfoldClip(axis: axis, open: phase.isIdentity ? 1 : 0))
    }
}

extension Transition where Self == Unfold {
    static var unfold: Unfold { Unfold() }
}

/// The room an unfolding part has so far. All the way open it leaves space around the part for
/// shadows and the lips of wells; partly open, it cuts along the far edge.
private nonisolated struct UnfoldClip: Shape {
    let axis: Axis
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var room = rect.insetBy(dx: -40, dy: -40)
        if open < 1 {
            switch axis {
            case .vertical: room.size.height = 40 + rect.height * max(open, 0)
            case .horizontal: room.size.width = 40 + rect.width * max(open, 0)
            }
        }
        return Path(room)
    }
}
