import SwiftUI
import AppKit

/// The switch at the top right between the design and its prototype: two words in a well, the
/// one in front resting on a card that slides across to the other. Each has a small drawing that
/// does what it says as it comes to the front: the nib writes a stroke, the flow lights up.
struct ModeSwitch: View {
    let store: DocumentStore
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            side(prototype: false)
            side(prototype: true)
        }
        .padding(2)
        .well(radius: 9)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: store.prototyping)
        .accessibilityElement(children: .contain)
    }

    private func side(prototype: Bool) -> some View {
        let on = store.prototyping == prototype
        return ModeSide(on: on, prototype: prototype, space: space) {
            guard store.prototyping != prototype else { return }
            store.prototyping = prototype
            if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
        }
    }
}

private struct ModeSide: View {
    let on: Bool
    let prototype: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ModeGlyph(prototype: prototype, on: on)
                .frame(width: 14, height: 14)
            Text(prototype ? LocalizedStringResource("mode.prototype", defaultValue: "Prototype") : LocalizedStringResource("mode.design", defaultValue: "Design"))
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on || hovering ? Theme.ink : Theme.ink2)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            if on {
                Color.clear
                    .card(radius: 7)
                    .matchedGeometryEffect(id: "mode", in: space)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(prototype ? Text("See the design as a prototype: its screens and the ways between them  ⌃P") : Text("Draw the design  ⌃P"))
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(prototype ? Text(LocalizedStringResource("mode.prototype", defaultValue: "Prototype")) : Text(LocalizedStringResource("mode.design", defaultValue: "Design")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// The nib for drawing, two screens and a flow between them for the prototype; each draws itself
/// in as it comes to the front.
private struct ModeGlyph: View {
    let prototype: Bool
    let on: Bool
    @State private var drawn: CGFloat = 1

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let ink = GraphicsContext.Shading.color(on ? Theme.ink : Theme.ink2)
            if prototype {
                let a = CGRect(x: w * 0.02, y: h * 0.12, width: w * 0.34, height: h * 0.5)
                let b = CGRect(x: w * 0.64, y: h * 0.38, width: w * 0.34, height: h * 0.5)
                ctx.stroke(Path(roundedRect: a, cornerRadius: 1.5), with: ink, style: style)
                ctx.stroke(Path(roundedRect: b, cornerRadius: 1.5), with: ink, style: style)
                var flow = Path()
                flow.move(to: CGPoint(x: a.maxX, y: a.midY))
                flow.addCurve(to: CGPoint(x: b.minX, y: b.midY), control1: CGPoint(x: w * 0.56, y: a.midY), control2: CGPoint(x: w * 0.44, y: b.midY))
                let pencil = GraphicsContext.Shading.color(on ? Theme.pencil : Theme.ink2)
                ctx.stroke(flow.trimmedPath(from: 0, to: drawn), with: pencil, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                if on, drawn < 1 {
                    let p = flow.trimmedPath(from: 0, to: drawn).currentPoint ?? .zero
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)), with: pencil)
                }
            } else {
                // A nib drawing a short stroke under it.
                var nib = Path()
                nib.move(to: CGPoint(x: w * 0.28, y: h * 0.72))
                nib.addLine(to: CGPoint(x: w * 0.72, y: h * 0.12))
                nib.addLine(to: CGPoint(x: w * 0.9, y: h * 0.28))
                nib.addLine(to: CGPoint(x: w * 0.42, y: h * 0.86))
                nib.closeSubpath()
                ctx.stroke(nib, with: ink, style: style)
                var line = Path()
                line.move(to: CGPoint(x: w * 0.04, y: h * 0.94))
                line.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.86), control: CGPoint(x: w * 0.18, y: h * 0.84))
                ctx.stroke(line.trimmedPath(from: 0, to: drawn), with: GraphicsContext.Shading.color(on ? Theme.pencil : Theme.ink2), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }
        .onChange(of: on) { _, now in
            guard now else { return }
            drawn = 0
            withAnimation(.easeOut(duration: 0.5).delay(0.08)) { drawn = 1 }
        }
    }
}

/// At the very right of the bar: Export while drawing; Play once the design is seen as a
/// prototype, the one button turning into the other.
struct ModeAction: View {
    let store: DocumentStore
    @State private var hovering = false

    var body: some View {
        let play = store.prototyping
        Button {
            if play { store.play() } else { store.exporting = true }
        } label: {
            HStack(spacing: 6) {
                if play {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .offset(x: 0.5)
                        .scaleEffect(hovering ? 1.15 : 1)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
                ZStack {
                    if play {
                        Text("Play").transition(.offset(y: 8).combined(with: .opacity))
                    } else {
                        Text("Export…").transition(.offset(y: -8).combined(with: .opacity))
                    }
                }
                .font(.system(size: 12.5, weight: play ? .semibold : .medium))
            }
            .foregroundStyle(play ? Theme.onInk : Theme.ink)
            .padding(.horizontal, play ? 13 : 14)
            .frame(height: 28)
            .background {
                // One button turning from a card into the pencil's blue.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(play ? Theme.pencil : Theme.card)
                    .shadow(color: play ? Theme.pencil.opacity(hovering ? 0.45 : 0.25) : Theme.shadow.opacity(hovering ? 0.16 : 0.07),
                            radius: hovering ? 8 : 3, y: hovering ? 3 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: play ? 0 : 0.5)
            }
            .clipped()
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(Pressable())
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .animation(.spring(response: 0.4, dampingFraction: 0.74), value: play)
        .help(play ? "Play the prototype from where it starts, or from the picked screen  ⌘↩" : "Export  ⌘E")
        .disabled(play && store.doc.artboards.isEmpty)
    }
}
