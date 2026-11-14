import SwiftUI
import AppKit

/// Animate: how the picked layers look, on the cards the design has for it. The corners, each
/// fill, border and shadow keep their card, dial, swatch and fields; here they show the layers as
/// they look at the playhead, and what they change is keyed there (`DocumentStore.poseLooks`).
/// What cannot be keyed is the design's and is left off them: adding one and taking one away,
/// their order, their styles, a border's dashes and side, which side a shadow falls on.
extension SelectionInspector {
    /// The cards of the looks every picked layer can be keyed in, as the design has them: the
    /// corners first, then the fills, borders and shadows, the top one of each first.
    @ViewBuilder func filmLooks(_ nodes: [Node]) -> some View {
        let kinds = Set(nodes.map(\.kind))
        let live = filmLive(nodes)
        let fills = keyedSlots(.fill), borders = keyedSlots(.border), shadows = keyedSlots(.shadow)
        // Rectangles' alone, and not of one whose points are keyed, which keeps the design's.
        if nodes.allSatisfy({ $0.lookCount(.corners) != nil }) { cornersCard(live: live.contains(.corners)) }
        if !fills.isEmpty {
            VStack(alignment: .leading, spacing: Self.pileGap) {
                ForEach(fills, id: \.self) { slot in
                    if stillPicked { fillCard(slot: slot, removable: false, live: live.contains(.fill(slot))) }
                }
            }
        }
        if !borders.isEmpty {
            VStack(alignment: .leading, spacing: Self.pileGap) {
                ForEach(borders, id: \.self) { slot in
                    if stillPicked { borderCard(slot: slot, lineOnly: kinds == [.line], removable: false, live: live.contains(.border(slot))) }
                }
            }
        }
        if !shadows.isEmpty {
            VStack(alignment: .leading, spacing: Self.pileGap) {
                ForEach(shadows, id: \.self) { slot in
                    if stillPicked {
                        shadowCard(slot: slot, canInset: !kinds.contains(.line), canSpread: kinds.isSubset(of: [.rectangle, .ellipse, .path, .line]),
                                   live: live.contains(.shadow(slot)))
                    }
                }
            }
        }
    }

    /// SwiftUI draws a pile's cards once more when the selection has just gone (the camera
    /// picked, the layers deleted), before the panel takes the pile away, and a card reads the
    /// selection as it is then (`pile` in Design keeps the same watch). With nothing picked
    /// there is nothing to show.
    private var stillPicked: Bool { !nodes.isEmpty }

    /// Whether the picked layers have any look to key, and so any card here.
    static func keysLooks(_ nodes: [Node]) -> Bool {
        !nodes.isEmpty && nodes.contains { !$0.keyableLooks.isEmpty }
    }

    /// The slots of a look whose card shows here, the top one first: those every layer that has
    /// the slot can be keyed in. A picture, a shader and one that is off are the design's.
    private func keyedSlots(_ look: Look) -> [Int] {
        (0...topSlot(look)).reversed().filter { slot in
            let those = slot == 0 ? nodes : nodes.filter { $0.slots(look) > slot }
            return !those.isEmpty && those.allSatisfy { n in Self.tracks(look, slot).contains { n.lookCount($0) != nil } }
        }
    }

    /// The tracks a card keys: a fill's or a border's colour or its gradient's, a border's width
    /// with them, a shadow's whole.
    private static func tracks(_ look: Look, _ slot: Int) -> [LookTrack] {
        switch look {
        case .fill: [.fill(slot), .fillStops(slot)]
        case .border: [.border(slot), .borderStops(slot), .borderWidth(slot)]
        case .shadow: [.shadow(slot)]
        }
    }

    /// The bead on a card that keys its looks at the playhead; none in the design.
    func keyBead(_ looks: [LookTrack], _ name: LocalizedStringResource) -> AnyView? {
        filming ? AnyView(LookBead(store: store, looks: looks, name: name)) : nil
    }

    /// What a drag going on has changed of how the layers look at the playhead, so the card it
    /// changes lifts while it goes on.
    private func filmLive(_ nodes: [Node]) -> Set<Aspect> {
        guard let before = store.gestureBefore else { return [] }
        let t = store.panelTime
        var live = Set<Aspect>()
        for n in nodes {
            guard let was = before.node(n.id)?.looked(at: t), was != n else { continue }
            if was.radii != n.radii { live.insert(.corners) }
            for slot in 0..<n.slots(.fill) where was[fill: slot] != n[fill: slot] { live.insert(.fill(slot)) }
            for slot in 0..<n.slots(.border) where was[border: slot] != n[border: slot] { live.insert(.border(slot)) }
            for slot in 0..<n.slots(.shadow) where was[shadow: slot] != n[shadow: slot] { live.insert(.shadow(slot)) }
        }
        return live
    }
}

/// A look's key at the playhead, on its card: faint while the look never changes, a ring while
/// it does but has no key here, and filled where it has one. A click sets a key here, holding
/// how it looks; on a key, it takes that away.
struct LookBead: View {
    let store: DocumentStore
    let looks: [LookTrack]
    let name: LocalizedStringResource
    @State private var hovering = false

    var body: some View {
        let state = store.lookKeyState(looks, at: store.panelTime)
        ZStack {
            Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0))
            Circle()
                .fill(state == .here ? Theme.pencil : Theme.card)
                .overlay {
                    Circle().strokeBorder(state == .here ? Theme.pencil : state == .between ? Theme.ink2 : Theme.ink4, lineWidth: 1.4)
                }
                .frame(width: 9, height: 9)
                .scaleEffect(state == .here ? 1.1 : 1)
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggleLookKeys(looks) }
        .help(state == .here ? Text("A key here. Click to take it away.") : Text("Set a key here"))
        .animation(Theme.pop, value: state)
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(state == .here ? [.isButton, .isSelected] : .isButton)
    }
}
