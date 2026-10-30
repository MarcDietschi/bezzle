import SwiftUI
import AppKit

/// A pad to set where a blur grows across a layer with, rather than numbers for its ends: the
/// layer drawn small, its marks blurred as the layer will be, with a ring where it is sharp and a
/// dot where the blur is whole. Drag either to move it, or drag across the pad to draw the ramp
/// afresh from where the press began; Shift keeps it to every 45°. The layers on the canvas
/// follow, live, and a double click blurs them toward the bottom again.
struct RampPad: View {
    @Environment(DocumentStore.self) private var store
    /// Where the first of the selected layers' blur grows.
    let ramp: BlurRamp
    /// Its width over its height, so the layer in the pad is shaped as it is.
    let aspect: CGFloat
    @State private var grip: Grip?

    private enum Grip { case start, end, fresh(CGPoint) }

    /// How near an end a press takes hold of it.
    private let reach: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let box = Self.box(in: geo.size, aspect: aspect)
            let a = Self.view(ramp.start, in: box), b = Self.view(ramp.end, in: box)
            ZStack {
                RampSample()
                    .frame(width: box.width, height: box.height)
                RampSample()
                    .frame(width: box.width, height: box.height)
                    .blur(radius: 3)
                    .mask {
                        LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: ramp.start.x, y: ramp.start.y),
                                       endPoint: UnitPoint(x: ramp.end.x, y: ramp.end.y))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .position(x: box.midX, y: box.midY)
            Path { p in p.move(to: a); p.addLine(to: b) }
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.25, dash: [3, 2.5]))
            Circle()
                .fill(Theme.card)
                .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.25) }
                .frame(width: 12, height: 12)
                .shadow(color: Theme.shadow.opacity(0.2), radius: 1.5, y: 1)
                .position(a)
            Circle()
                .fill(Theme.ink)
                .overlay { Circle().strokeBorder(Theme.card, lineWidth: 1.5) }
                .frame(width: 12, height: 12)
                .shadow(color: Theme.shadow.opacity(0.2), radius: 1.5, y: 1)
                .position(b)
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in drag(g, box: box, a: a, b: b) }
                    .onEnded { _ in
                        grip = nil
                        store.endGesture("Change Blur")
                    })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    withAnimation(Theme.spring) { store.updateSelection("Change Blur") { $0.blur?.ramp = .down } }
                })
        }
        .frame(height: 100)
        .well(radius: 9)
        .help("Drag the ring, where it is sharp, or the dot, where the blur is whole; or drag across to draw it afresh. Double click to blur toward the bottom.")
        .accessibilityElement()
        .accessibilityLabel("Where the blur grows")
        .accessibilityValue("From \(Self.percent(ramp.start)) to \(Self.percent(ramp.end))")
    }

    private func drag(_ g: DragGesture.Value, box: CGRect, a: CGPoint, b: CGPoint) {
        if grip == nil {
            store.beginGesture()
            let s = g.startLocation
            if hypot(s.x - a.x, s.y - a.y) <= reach {
                grip = .start
            } else if hypot(s.x - b.x, s.y - b.y) <= reach {
                grip = .end
            } else {
                grip = .fresh(s)
            }
        }
        var next = ramp
        let steps = NSEvent.modifierFlags.contains(.shift)
        switch grip {
        case .start: next.start = Self.unit(Self.settled(g.location, from: b, steps: steps), in: box)
        case .end: next.end = Self.unit(Self.settled(g.location, from: a, steps: steps), in: box)
        case .fresh(let from):
            // A press that has not gone anywhere yet leaves the ramp as it is.
            guard hypot(g.location.x - from.x, g.location.y - from.y) > 3 else { return }
            next = BlurRamp(start: Self.unit(from, in: box), end: Self.unit(Self.settled(g.location, from: from, steps: steps), in: box))
        case nil: return
        }
        store.updateSelection("Change Blur") { $0.blur?.ramp = next }
    }

    /// The layer in the pad: as large as fits with room round it for the ends, which may lie a
    /// little outside it.
    private static func box(in size: CGSize, aspect: CGFloat) -> CGRect {
        let room = CGSize(width: max(size.width - 56, 20), height: max(size.height - 28, 20))
        let a = min(max(aspect.isFinite && aspect > 0 ? aspect : 1, 0.25), 4)
        let w = min(room.width, room.height * a), h = w / a
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private static func view(_ u: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + u.x * box.width, y: box.minY + u.y * box.height)
    }

    /// A point in the pad, in the layer's box, kept to a quarter of it beyond each side.
    private static func unit(_ v: CGPoint, in box: CGRect) -> CGPoint {
        func clamp(_ x: CGFloat) -> CGFloat { (min(max(x, -0.25), 1.25) * 1000).rounded() / 1000 }
        return CGPoint(x: clamp((v.x - box.minX) / box.width), y: clamp((v.y - box.minY) / box.height))
    }

    /// Where a dragged end goes: where the pointer is, or with Shift as far from the other end
    /// in the nearest of every 45°.
    private static func settled(_ p: CGPoint, from o: CGPoint, steps: Bool) -> CGPoint {
        guard steps else { return p }
        let length = hypot(p.x - o.x, p.y - o.y)
        let angle = (atan2(p.y - o.y, p.x - o.x) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: o.x + cos(angle) * length, y: o.y + sin(angle) * length)
    }

    private static func percent(_ p: CGPoint) -> String {
        String(localized: "\(Int((p.x * 100).rounded()))% across, \(Int((p.y * 100).rounded()))% down")
    }
}

/// A card with a few marks on it, to show how much a blur softens them where.
private struct RampSample: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, m = min(w, h) * 0.16
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.card)
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ink.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Theme.ink.opacity(0.75))
                    .frame(width: m * 1.6, height: m * 1.6)
                    .offset(x: m, y: m)
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(Theme.ink.opacity(0.55))
                        .frame(width: (w - m * 2) * [0.9, 0.7, 0.8][i], height: max(m * 0.45, 2))
                        .offset(x: m, y: m * 3.3 + CGFloat(i) * m * 1.1)
                }
            }
        }
    }
}

/// A square that softens toward one edge, as a blur that grows toward it does: 0 the bottom,
/// then the left, top and right.
struct RampGlyph: View {
    let edge: Int

    var body: some View {
        let ends: (UnitPoint, UnitPoint) = switch edge % 4 {
        case 1: (.trailing, .leading)
        case 2: (.bottom, .top)
        case 3: (.leading, .trailing)
        default: (.top, .bottom)
        }
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: [.clear, .primary.opacity(0.8)], startPoint: ends.0, endPoint: ends.1))
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(lineWidth: 1)
        }
        .frame(width: 15, height: 15)
    }
}
