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

// MARK: - The choices

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

    static func applyShadow(_ preset: ShadowPreset, to n: inout Node) {
        n.shadow.on = true
        n.shadow.x = 0
        n.shadow.y = preset.y
        n.shadow.blur = preset.blur
        n.shadow.color = n.shadow.color.with(alpha: preset.alpha)
        n.shadow.inset = preset.inset ? true : nil
    }

    static func isShadow(_ preset: ShadowPreset, _ s: Shadow) -> Bool {
        s.on && (s.inset == true) == preset.inset && s.x == 0 && s.y == preset.y && s.blur == preset.blur && abs(s.color.a - preset.alpha) < 0.005
    }

    /// Moves a shadow inside the layer or back under it. A shadow that is one of the choices
    /// becomes the one across from it, Soft becoming Pressed; one set by hand keeps its numbers.
    static func setShadowInset(_ inset: Bool, on n: inout Node) {
        let from = inset ? shadows : innerShadows, to = inset ? innerShadows : shadows
        if let i = from.firstIndex(where: { isShadow($0, n.shadow) }) {
            applyShadow(to[i], to: &n)
        } else {
            n.shadow.on = true
            n.shadow.inset = inset ? true : nil
        }
    }

    /// Border weights, and a dashed line of the weight there is.
    static let borders: [(id: String, name: LocalizedStringResource, width: CGFloat?)] = [
        ("border-thin", "Thin", 1), ("border-medium", "Medium", 2), ("border-bold", "Bold", 4), ("border-dashed", "Dashed", nil),
    ]

    static func applyBorder(_ width: CGFloat?, to n: inout Node) {
        n.border.on = true
        if let width {
            n.border.width = width
            n.border.dash = 0
            n.border.gap = 0
        } else {
            n.border.dash = max(4, n.border.width * 2)
            n.border.gap = n.border.dash
        }
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

// MARK: - A block for something a layer has

/// One thing a layer has, such as its border: its name, a × to take it away while the pointer is
/// on the block, what can be picked, and under that the exact numbers.
struct OptionBlock<Content: View, Exact: View>: View {
    let title: LocalizedStringResource
    var remove: (() -> Void)?
    /// Says what the × takes away, such as "Remove shadow".
    var removal: LocalizedStringResource
    @ViewBuilder let content: Content
    @ViewBuilder let exact: Exact
    @State private var hovering = false

    init(title: LocalizedStringResource, remove: (() -> Void)? = nil, removal: LocalizedStringResource = "Remove", @ViewBuilder content: () -> Content,
         @ViewBuilder exact: () -> Exact) {
        self.title = title
        self.remove = remove
        self.removal = removal
        self.content = content()
        self.exact = exact()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if let remove {
                    RemoveButton(help: removal, action: remove)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            }
            // Every row the same distance from the next, picked or exact.
            VStack(alignment: .leading, spacing: 8) {
                content
                if Exact.self != EmptyView.self { exact }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

extension OptionBlock where Exact == EmptyView {
    init(title: LocalizedStringResource, remove: (() -> Void)? = nil, removal: LocalizedStringResource = "Remove", @ViewBuilder content: () -> Content) {
        self.init(title: title, remove: remove, removal: removal, content: content) { EmptyView() }
    }
}

private struct RemoveButton: View {
    let help: LocalizedStringResource
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
            .frame(width: 20, height: 20)
            .background { Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0)) }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(Text(help))
    }
}

// MARK: - Adding what is not there

/// What the selection does not have yet and could: pointing at one shows it on the canvas, and
/// a click adds it, already looking right.
struct AddBar: View {
    struct Item: Identifiable {
        let id: String
        let title: LocalizedStringResource
        /// Says what a click does, such as "Add a shadow".
        let help: LocalizedStringResource
        /// Names the step in the Edit menu, such as "Add Shadow".
        let action: LocalizedStringResource
        let change: (inout Node) -> Void
        /// Done instead of changing each selected layer, for what is more than that, such as
        /// repeating them in a grid.
        var add: (() -> Void)? = nil
    }

    @Environment(DocumentStore.self) private var store
    let items: [Item]

    var body: some View {
        Flow(spacing: 6) {
            ForEach(items) { item in
                AddChip(title: item.title, help: item.help) { inside in
                    store.showPreview(item.id, inside ? item.change : nil)
                } add: {
                    store.showPreview(item.id, nil)
                    withAnimation(Theme.unfold) {
                        if let add = item.add { add() } else { store.updateSelection(item.action, item.change) }
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
private struct Flow: Layout {
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
