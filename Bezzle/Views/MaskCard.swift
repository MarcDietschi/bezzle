import SwiftUI

/// A mask selected, as a card: the kind of shape that holds. Pulled off, the mask is taken
/// apart and what it held shows whole again. See `Mask`.
struct MaskCard: View {
    let store: DocumentStore
    let group: Node

    var body: some View {
        AspectCard(aspect: .mask, title: "Mask", summary: group.holder?.kind.title ?? "", remove: { store.releaseMask(group.id) },
                   removal: "Release mask",
                   accessory: AnyView(TextButton(title: "Release") { store.releaseMask(group.id) })) {
            MaskGlyph()
        } picks: {
            EmptyView()
        }
    }
}

/// A layer inside a mask selected, as a card: which mask it is in. Pulled off, it comes out of it.
struct MaskedLayerCard: View {
    let store: DocumentStore
    let node: Node
    let group: Node

    var body: some View {
        let name = group.holder?.name ?? group.name
        AspectCard(aspect: .mask, title: "Mask", summary: name, remove: { store.takeOutOfMask([node.id]) },
                   removal: "Take out of mask",
                   accessory: AnyView(TextButton(title: "Take Out") { store.takeOutOfMask([node.id]) })) {
            MaskGlyph()
        } picks: {
            EmptyView()
        }
    }
}

/// A hill and a sun seen through a round window: a mask.
struct MaskGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: 0.8, dy: 0.8)
            let window = Path(ellipseIn: r)
            ctx.drawLayer { inside in
                inside.clip(to: window)
                let hill = Path { p in
                    p.move(to: CGPoint(x: r.minX - 1, y: r.maxY + 1))
                    p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.52))
                    p.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.7))
                    p.addLine(to: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.58))
                    p.addLine(to: CGPoint(x: r.maxX + 1, y: r.maxY + 1))
                    p.closeSubpath()
                }
                inside.fill(hill, with: .foreground)
                inside.fill(Path(ellipseIn: CGRect(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.18, width: r.width * 0.22, height: r.width * 0.22)),
                            with: .foreground)
            }
            ctx.stroke(window, with: .foreground, lineWidth: 1.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
