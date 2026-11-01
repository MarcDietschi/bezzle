import SwiftUI
import AppKit

/// An artboard shown dark, as a card: its named looks in their dark looks, made dark by themselves
/// until one is changed there by hand, which then is its own in the dark. Taken away, the artboard
/// is light again. The dashed card that makes one shows the artboard dark on the canvas while it is
/// pointed at. See `Style.dark`.
struct DarkCard: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        let (named, own) = counts
        let dark = board.showsDark
        // The switch lies on the card's line, to flip between the two at a click.
        let pair = LightDarkPair(dark: dark, small: true) { d in store.show(board.id, dark: d) }
        AspectCard(aspect: .appearance, title: dark ? Appearance.dark : Appearance.light,
                   summary: own == 0 ? "" : String(localized: "\(own) of \(named) adjusted"),
                   remove: { store.forgetDark(board.id) }, removal: "No dark look", accessory: AnyView(pair)) {
            ZStack {
                if dark { MoonGlyph(size: 14).transition(.scale(scale: 0.4).combined(with: .opacity)) }
                else { SunGlyph(size: 15).transition(.scale(scale: 0.4).combined(with: .opacity)) }
            }
            .animation(Theme.pop, value: dark)
        } picks: {
            HStack(spacing: 8) {
                CardButton(title: "Light One Beside It", height: Theme.controlHeight) {
                    var made: UUID?
                    store.edit("Add Light Version") { doc in made = DocumentStore.lightTwin(of: board.id, in: &doc) }
                    if let made {
                        store.styleShow.wave = StyleShow.Wave(origin: CGPoint(x: board.frame.maxX, y: board.frame.midY), layers: [made])
                    }
                }
            }
        }
    }

    /// How many styles the artboard's layers use, and of those, how many have been made dark by hand.
    private var counts: (Int, Int) {
        var used = Set<UUID>()
        func visit(_ n: Node) {
            for place in StylePlace.all(in: n) { if let id = place.named(in: n) { used.insert(id) } }
            n.children.forEach(visit)
        }
        visit(board)
        let styles = (store.doc.styles ?? []).filter { used.contains($0.id) }
        // Kept as it is in the light, as words on a button are, is no change made by hand.
        return (styles.count, styles.filter { $0.dark != nil && $0.dark != $0.look }.count)
    }
}

extension SelectionInspector {
    /// Showing a single light artboard dark: pointed at, the canvas shows it so.
    func addDark(_ nodes: [Node]) -> AddBar.Item? {
        guard nodes.count == 1, let board = nodes.first, board.isArtboard, board.dark == nil, !board.locked else { return nil }
        return .init(id: "add-dark", aspect: .appearance, title: Appearance.dark, help: "Show this artboard dark", action: "Make Dark",
                     change: { _ in }, add: { [store] in store.show(board.id, dark: true) },
                     reshape: store.previewing(board.id, dark: true))
    }
}

/// Light and dark as the inspector says them, apart from the light of a picture.
enum Appearance {
    static let dark = LocalizedStringResource("appearance.dark", defaultValue: "Dark", comment: "An artboard shown dark, its colours in their dark looks.")
    static let light = LocalizedStringResource("appearance.light", defaultValue: "Light", comment: "An artboard shown light, as opposed to dark.")
}

// MARK: - Small pictures

/// A crescent moon, drawn: a disc with a disc taken out of it.
struct MoonGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let r = min(s.width, s.height) / 2
            var moon = Path(ellipseIn: CGRect(x: s.width / 2 - r, y: s.height / 2 - r, width: r * 2, height: r * 2))
            moon = moon.subtracting(Path(ellipseIn: CGRect(x: s.width / 2 - r * 0.35, y: s.height / 2 - r * 1.25, width: r * 1.8, height: r * 1.8)))
            ctx.fill(moon, with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A sun, drawn: a disc and its rays.
struct SunGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2), r = min(s.width, s.height) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.42, y: c.y - r * 0.42, width: r * 0.84, height: r * 0.84)), with: .foreground)
            var rays = Path()
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                rays.move(to: CGPoint(x: c.x + cos(a) * r * 0.66, y: c.y + sin(a) * r * 0.66))
                rays.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.95, y: c.y + sin(a) * r * 0.95))
            }
            ctx.stroke(rays, with: .foreground, style: StrokeStyle(lineWidth: max(1, r * 0.17), lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Light or dark, as a sun and a moon in one well, the one chosen raised.
struct LightDarkPair: View {
    let dark: Bool
    /// On a card's folded line rather than in a row of controls.
    var small = false
    let choose: (Bool) -> Void
    @Namespace private var namespace
    @State private var hovered: Bool?

    var body: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { d in
                Group {
                    if d { MoonGlyph(size: 13) } else { SunGlyph(size: 14) }
                }
                .foregroundStyle(d == dark || hovered == d ? Theme.ink : Theme.ink3)
                .frame(width: small ? 28 : 36, height: small ? 20 : Theme.controlHeight - 4)
                .background {
                    if d == dark {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.card)
                            .shadow(color: Theme.shadow.opacity(0.12), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "thumb", in: namespace)
                    }
                }
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? d : (hovered == d ? nil : hovered) }
                .onTapGesture { withAnimation(Theme.spring) { choose(d) } }
                .help(Text(d ? Appearance.dark : Appearance.light))
                .accessibilityLabel(Text(d ? Appearance.dark : Appearance.light))
                .accessibilityAddTraits(d == dark ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .well(radius: 8)
        .animation(Theme.quick, value: hovered)
    }
}
