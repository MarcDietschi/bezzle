import SwiftUI
import AppKit

/// Choices drawn as small pictures in a well, the one in use raised. Pointing at one shows it on
/// the canvas straight away; a click makes it. The exact numbers sit under them.
struct PresetStrip<Glyph: View>: View {
    @Environment(DocumentStore.self) private var store
    let action: LocalizedStringResource
    let items: [PresetItem]
    /// Inside the well's rim, the whole as tall as any control.
    var height: CGFloat = Theme.controlHeight - 4
    @ViewBuilder let glyph: (PresetItem) -> Glyph
    @Namespace private var namespace
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                glyph(item)
                    .foregroundStyle(item.active || hovered == item.id ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        if item.active {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: Theme.shadow.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: namespace)
                        } else if hovered == item.id {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.ink.opacity(0.05))
                        }
                    }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                        store.showPreview(item.id, inside && !item.active ? item.change : nil)
                    }
                    .onTapGesture {
                        store.showPreview(item.id, nil)
                        withAnimation(Theme.spring) { store.updateSelection(action, item.change) }
                    }
                    .help(Text(item.name))
                    .accessibilityLabel(Text(item.name))
                    .accessibilityAddTraits(item.active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .well(radius: 8)
        .animation(Theme.quick, value: hovered)
        .onDisappear { if let hovered { store.showPreview(hovered, nil) } }
    }
}

/// One choice in a strip.
struct PresetItem: Identifiable {
    /// Names the choice, and the preview it shows.
    let id: String
    let name: LocalizedStringResource
    let active: Bool
    let change: (inout Node) -> Void
}

// MARK: - Pictures of the choices

/// A corner rounded as the choice rounds it, or a pill.
struct CornerGlyph: View {
    let radius: CGFloat?
    /// Squircle corners, eased into the sides, rather than plain arcs.
    var smooth = false

    var body: some View {
        let pill = radius == nil
        // Spread apart so each reads at a glance, rather than to scale.
        let r: CGFloat = switch radius {
        case nil: 5.5
        case let r? where r <= 0: 0
        case let r? where r <= 4: 2.5
        case let r? where r <= 12: 4.5
        default: 7
        }
        RoundedRectangle(cornerRadius: r, style: smooth ? .continuous : .circular)
            .strokeBorder(lineWidth: 1.4)
            .frame(width: pill ? 21 : 15, height: pill ? 11 : 15)
    }
}

/// A card lifted as far as the shadow lifts it, or pressed as far into the page.
struct ShadowGlyph: View {
    let y: CGFloat
    let blur: CGFloat
    var inset = false

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if inset {
            card
                .fill(Theme.card.shadow(.inner(color: Theme.shadow.opacity(0.7), radius: 0.4 + blur / 7, y: 0.6 + y / 3)))
                .overlay { card.strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5) }
                .frame(width: 16, height: 13)
        } else {
            card
                .fill(Theme.card)
                .overlay { card.strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5) }
                .frame(width: 16, height: 13)
                .shadow(color: Theme.shadow.opacity(0.45), radius: max(blur / 9, 0.6), y: max(y / 5, 0.5))
                .offset(y: -min(y / 8, 2.5))
        }
    }
}

/// A dot as soft as the blur leaves it; for a blur of what is behind, a dot with a pane of frosted
/// glass over half of it, sharp beside the pane and soft through it.
struct BlurGlyph: View {
    /// From 0, a touch, to 1, heavy.
    let amount: CGFloat
    let behind: Bool

    var body: some View {
        let soft = 0.3 + amount * 2.6
        if behind {
            let pane = RoundedRectangle(cornerRadius: 2, style: .continuous)
            ZStack {
                Circle().frame(width: 11, height: 11).position(x: 7, y: 9)
                    .mask(alignment: .leading) { Rectangle().frame(width: 8) }
                Circle().frame(width: 11, height: 11).position(x: 7, y: 9)
                    .blur(radius: soft)
                    .mask { pane.frame(width: 8, height: 15).position(x: 12.5, y: 9) }
                pane.strokeBorder(lineWidth: 1).frame(width: 8, height: 15).position(x: 12.5, y: 9)
            }
            .frame(width: 18, height: 18)
        } else {
            Circle()
                .frame(width: 11, height: 11)
                .blur(radius: soft)
        }
    }
}

/// A square drawn in the border's weight, or dashed.
struct BorderGlyph: View {
    let width: CGFloat?

    var body: some View {
        let w: CGFloat = width.map { $0 == 1 ? 1 : $0 == 2 ? 1.8 : 3 } ?? 1.3
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: w, dash: width == nil ? [2.6, 2] : []))
            .frame(width: 15, height: 15)
    }
}

// MARK: - Adding what is not there

/// What the selection does not have yet and could, as dashed cards: pointing at one shows it on
/// the canvas, and a click adds it, already looking right, and opens its card.
struct AddBar: View {
    struct Item: Identifiable {
        let id: String
        /// The card it becomes, opened as it is added.
        let aspect: Aspect
        let title: LocalizedStringResource
        /// Says what a click does, such as "Add a shadow".
        let help: LocalizedStringResource
        /// Names the step in the Edit menu, such as "Add Shadow".
        let action: LocalizedStringResource
        let change: (inout Node) -> Void
        /// Done instead of changing each selected layer, for what is more than that, such as
        /// repeating them in a grid.
        var add: (() -> Void)? = nil
        /// What it does to the design as a whole, shown on the canvas while it is pointed at, for
        /// what changes more than the selected layers, such as an artboard turned dark.
        var reshape: ((inout BezzleDocument) -> Void)? = nil
    }

    @Environment(DocumentStore.self) private var store
    let items: [Item]

    var body: some View {
        Flow(spacing: 6) {
            ForEach(items) { item in
                AddChip(title: item.title, help: item.help) { inside in
                    if let reshape = item.reshape {
                        store.showPreview(item.id, reshaping: inside ? reshape : nil)
                    } else {
                        store.showPreview(item.id, inside ? item.change : nil)
                    }
                    if inside { store.pointedAspect = item.aspect } else if store.pointedAspect == item.aspect { store.pointedAspect = nil }
                } add: {
                    store.showPreview(item.id, nil)
                    store.showPreview(item.id, reshaping: nil)
                    store.pointedAspect = nil
                    withAnimation(Theme.unfold) {
                        if let add = item.add { add() } else { store.updateSelection(item.action, item.change) }
                        store.openAspect = item.aspect
                    }
                }
            }
        }
        // A chip that comes as the bar moves, when another block opens or shuts above it, comes
        // with the bar rather than waiting where the bar is going.
        .geometryGroup()
    }
}

/// Its views side by side at the size they want, going on in a new row below when the next one
/// would not fit beside the others, rather than squeezing them all into one.
struct Flow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let used = frames(of: subviews, width: width).reduce(CGRect.zero) { $0.union($1) }
        return CGSize(width: width.isFinite ? width : used.width, height: used.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(of: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(of subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

private struct AddChip: View {
    let title: LocalizedStringResource
    let help: LocalizedStringResource
    let hover: (Bool) -> Void
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 9.5, weight: .bold))
            Text(title)
                .font(.system(size: 12))
        }
        .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.ink.opacity(hovering ? 0.28 : 0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .onTapGesture(perform: add)
        .onDisappear { if hovering { hover(false) } }
        .animation(Theme.quick, value: hovering)
        .help(Text(help))
    }
}
