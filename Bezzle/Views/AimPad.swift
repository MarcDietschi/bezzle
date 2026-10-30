import SwiftUI
import AppKit

/// A pad to aim layers held up off the page with, rather than numbers for axes: the card in it
/// faces where the pointer is, and the layers on the canvas turn with it, live. The middle is
/// face on, flat in the page; the ring is edge on. Shift turns in steps of 15°, and a double
/// click lays them flat again.
struct AimPad: View {
    @Environment(DocumentStore.self) private var store
    /// How the first of the selected layers is turned.
    let turn: Transform3D
    @State private var grip: CGSize?

    /// From the middle to the ring, where the face is seen edge on.
    private let radius: CGFloat = 38

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let f = DepthTool.facing(turn)
            let knob = CGPoint(x: c.x + f.x * radius, y: c.y + f.y * radius)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: c.x - radius, y: c.y)); p.addLine(to: CGPoint(x: c.x + radius, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - radius)); p.addLine(to: CGPoint(x: c.x, y: c.y + radius))
                }
                .stroke(Theme.ink.opacity(0.07), lineWidth: 1)
                Circle()
                    .strokeBorder(Theme.ink.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(c)
                CardInDepth(turn: turn)
                    .frame(width: 44, height: 32)
                    .position(c)
                Path { p in p.move(to: c); p.addLine(to: knob) }
                    .stroke(Theme.ink, lineWidth: 1.25)
                Circle()
                    .fill(Theme.card)
                    .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1) }
                    .overlay { Circle().fill(Theme.ink).frame(width: 3.5, height: 3.5) }
                    .frame(width: 12, height: 12)
                    .shadow(color: Theme.shadow.opacity(0.2), radius: 1.5, y: 1)
                    .position(knob)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if grip == nil {
                        store.beginGesture()
                        // Taken by the knob, it does not jump; anywhere else, it faces there at once.
                        let near = hypot(g.startLocation.x - knob.x, g.startLocation.y - knob.y) <= 12
                        grip = near ? CGSize(width: knob.x - g.startLocation.x, height: knob.y - g.startLocation.y) : .zero
                    }
                    let at = CGPoint(x: g.location.x + (grip?.width ?? 0) - c.x, y: g.location.y + (grip?.height ?? 0) - c.y)
                    let (x, y) = DepthTool.turn(facing: CGPoint(x: at.x / radius, y: at.y / radius))
                    let (sx, sy) = DepthTool.settled(x, y, steps: NSEvent.modifierFlags.contains(.shift))
                    store.updateSelection("Turn in Depth") { n in
                        var t = n.transform3D ?? Transform3D()
                        t.x = sx
                        t.y = sy
                        n.transform3D = t
                    }
                }
                .onEnded { _ in
                    grip = nil
                    store.endGesture("Turn in Depth")
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(Theme.spring) {
                    store.updateSelection("Lay Flat") { n in n.transform3D?.x = 0; n.transform3D?.y = 0 }
                }
            })
        }
        .frame(height: 100)
        .well(radius: 9)
        .help("Drag to aim it: the card faces where you point. Double click to lay it flat.")
        .accessibilityElement()
        .accessibilityLabel("Aim in depth")
        .accessibilityValue("Tipped \(Int(turn.x.rounded()))°, swung \(Int(turn.y.rounded()))°")
    }
}

/// A card turned as a layer is, drawn small, with its perspective made strong enough to read at
/// that size: lit from above the page, darker as it turns its face away, and grey from behind.
struct CardInDepth: View {
    let turn: Transform3D

    var body: some View {
        Canvas { ctx, size in
            let w = size.width * 0.82, h = size.height * 0.82
            let card = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            let p = Perspective(Transform3D(x: turn.x, y: turn.y), center: card.center, distance: max(w, h) * 2.4)
            let pts = [CGPoint(x: card.minX, y: card.minY), CGPoint(x: card.maxX, y: card.minY),
                       CGPoint(x: card.maxX, y: card.maxY), CGPoint(x: card.minX, y: card.maxY)].map(p.shown)
            var shape = Path()
            shape.addLines(pts)
            shape.closeSubpath()
            // Turned past edge on, its corners run the other way round: it shows its back.
            let area = zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
            let back = area < 0
            ctx.fill(shape, with: .color(back ? Theme.ink.opacity(0.18) : Theme.card))
            if !back {
                // The light is above the page, a little in front: a face turned up from it, brighter.
                let a = turn.x * .pi / 180, b = turn.y * .pi / 180
                let lit = max(0, -sin(a) * cos(b) * -0.5 + cos(a) * cos(b) * 0.87)
                ctx.fill(shape, with: .color(Color.black.opacity((1 - lit) * 0.22)))
            }
            ctx.stroke(shape, with: .color(Theme.ink.opacity(0.5)), lineWidth: 1)
            // Its top, stronger, so which way up it is reads.
            var top = Path()
            top.move(to: pts[0])
            top.addLine(to: pts[1])
            ctx.stroke(top, with: .color(Theme.ink), lineWidth: 1.6)
        }
    }
}
