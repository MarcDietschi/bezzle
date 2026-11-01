import SwiftUI
import AppKit

/// A layer's fills, borders and shadows in the inspector: one card each, as any other aspect has,
/// and several of a kind close together as a pile, the top one first as the layers panel lists
/// them. A + on an open card adds another of its kind on top. A card in a pile is picked up by
/// dragging it up or down and put back in another place, the others moving aside to make room;
/// torn off, it alone goes, and the pile closes up.
extension SelectionInspector {
    /// How far apart the cards of a pile lie: closer than cards of different kinds, so they read as one.
    static let pileGap: CGFloat = 4

    /// A card picked up off its pile, and where it would go if it were let go now.
    struct Restacking: Equatable {
        let look: Look
        let key: Int
        /// How far it is shown moved: as far as the pointer, but within its pile, giving a little
        /// past either end of it.
        var dy: CGFloat
        /// Its place counted from the top of the pile.
        var target: Int
    }

    /// The selected layers that have a slot of a look, which its card shows and changes: all of
    /// them for the first, and for those over it, the ones that have that many.
    func holding(_ look: Look, _ slot: Int) -> [Node] {
        guard slot > 0 else { return nodes }
        let those = nodes.filter { $0.slots(look) > slot }
        return those.isEmpty ? nodes : those
    }

    /// The value some of the selected layers share, or nil when they differ.
    func common<T: Equatable>(among those: [Node], _ value: (Node) -> T) -> T? {
        guard let first = those.first.map(value) else { return nil }
        return those.allSatisfy { value($0) == first } ? first : nil
    }

    /// The highest slot of a look any selected layer has.
    func topSlot(_ look: Look) -> Int {
        (nodes.map { $0.slots(look) }.max() ?? 1) - 1
    }

    /// Takes away one of the selection's fills, borders or shadows, those over it coming down a
    /// place, and keeps the open card on what it showed.
    func removeLook(_ look: Look, _ slot: Int, _ action: LocalizedStringResource) {
        store.updateSelection(action) { $0.remove(look, at: slot) }
        lookKeys.removed(look, at: slot)
        if case let (open, at)? = store.openAspect?.look, open == look {
            store.openAspect = at == slot ? nil : at > slot ? .of(look, at - 1) : store.openAspect
        }
    }

    /// The cards of one look, top first. `first` says whether the first slot's card shows, as it
    /// does while any of the layers has one; every slot over it always does.
    @ViewBuilder func pile<Card: View>(_ look: Look, first: Bool,
                                       @ViewBuilder card: @escaping (_ slot: Int, _ restack: ((CGFloat?) -> Void)?) -> Card) -> some View {
        let count = topSlot(look) + 1
        let keys = lookKeys.keys(look, count: count, for: store.selection)
        let slots = Array((0..<count).filter { $0 > 0 || first }.reversed())
        let order = slots.map { keys[$0] }
        // A picture stays at the bottom, where a repeat grid's cells keep their own.
        let lowest = look == .fill && nodes.contains { $0.fill.image != nil } ? 1 : 0
        let movable = slots.count > 1 && slots.count == count
        let lifting = restacking?.look == look
        VStack(alignment: .leading, spacing: Self.pileGap) {
            ForEach(order, id: \.self) { key in
                // SwiftUI draws the cards once more when the selection has just gone (its layers
                // deleted, say), before the inspector takes the pile away, and a card reads the
                // selection as it is then. With nothing selected there is nothing to show.
                if !nodes.isEmpty {
                    let slot = keys.firstIndex(of: key) ?? 0
                    let picked = restacking?.key == key
                    card(slot, movable && slot >= lowest ? { dy in restack(look, key: key, by: dy, order: order, lowest: lowest) } : nil)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeights[key] = $0 }
                        .offset(y: restackOffset(key, in: order))
                        // Picked up, a card follows the pointer at once; the others move aside softly.
                        .animation(picked ? nil : Theme.spring, value: restackOffset(key, in: order))
                        .zIndex(picked ? 1 : 0)
                        .transition(.card)
                }
            }
        }
        // Over the cards after it while one of its own is carried about.
        .zIndex(lifting ? 1 : 0)
    }

    /// How far a card of a pile is moved from its place while another is picked up: the one picked
    /// up as far as the pointer, and those it passes a place up or down, out of its way.
    private func restackOffset(_ key: Int, in order: [Int]) -> CGFloat {
        guard let r = restacking, let p = order.firstIndex(of: r.key), let i = order.firstIndex(of: key) else { return 0 }
        if key == r.key { return r.dy }
        let step = (cardHeights[r.key] ?? 40) + Self.pileGap
        if p < i, i <= r.target { return -step }
        if r.target <= i, i < p { return step }
        return 0
    }

    /// Where a card's top lies in its pile, and where it would lie in each place it can be put,
    /// the others closing up round it, counted from the top of the pile: the lowest `lowest`
    /// places are not to be had.
    private func places(_ key: Int, in order: [Int], lowest: Int) -> (at: CGFloat, tops: [CGFloat]) {
        guard let p = order.firstIndex(of: key) else { return (0, [0]) }
        let heights = order.map { cardHeights[$0] ?? 40 }
        let at = heights[..<p].reduce(0) { $0 + $1 + Self.pileGap }
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for (i, h) in heights.enumerated() where i != p {
            tops.append(y)
            y += h + Self.pileGap
        }
        tops.append(y)
        return (at, Array(tops.prefix(max(order.count - lowest, 1))))
    }

    /// A card of a pile being dragged up or down, and, when `dy` is nil, let go: put back in its
    /// new place as one step, or where it was.
    private func restack(_ look: Look, key: Int, by dy: CGFloat?, order: [Int], lowest: Int) {
        guard let dy else {
            guard let r = restacking, r.key == key, let p = order.firstIndex(of: key) else { return }
            let from = order.count - 1 - p, to = order.count - 1 - r.target
            withAnimation(Theme.spring) {
                if from != to {
                    store.updateSelection(Self.restacked(look)) { $0.move(look, from: from, to: to) }
                    lookKeys.moved(look, from: from, to: to)
                    if case let (open, at)? = store.openAspect?.look, open == look {
                        store.openAspect = .of(look, at == from ? to : from < at && at <= to ? at - 1 : to <= at && at < from ? at + 1 : at)
                    }
                }
                restacking = nil
            }
            return
        }
        // The place nearest to where it is held, however tall the cards about it are, as one
        // left open is; and held within the pile, as a card in a box is.
        let (at, tops) = places(key, in: order, lowest: lowest)
        let target = tops.indices.min { abs(tops[$0] - at - dy) < abs(tops[$1] - at - dy) } ?? 0
        let low = (tops.first ?? at) - at, high = (tops.last ?? at) - at
        let shown = dy < low ? low - Dial.give(low - dy, limit: 12) : dy > high ? high + Dial.give(dy - high, limit: 12) : dy
        if let r = restacking, r.key == key {
            if r.target != target { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            restacking?.dy = shown
            restacking?.target = target
        } else {
            restacking = Restacking(look: look, key: key, dy: shown, target: target)
        }
    }

    private static func restacked(_ look: Look) -> LocalizedStringResource {
        switch look {
        case .fill: "Reorder Fills"
        case .border: "Reorder Borders"
        case .shadow: "Reorder Shadows"
        }
    }
}

extension Aspect {
    /// The look and slot of a fill's, border's or shadow's card.
    var look: (Look, Int)? {
        switch self {
        case .fill(let slot): (.fill, slot)
        case .border(let slot): (.border, slot)
        case .shadow(let slot): (.shadow, slot)
        default: nil
        }
    }
}

/// A name for each card of a pile that stays with it as the cards beside it come and go or change
/// places, so that SwiftUI moves, adds and throws off the very card that did: the slots are only
/// where each one is now. Kept for the selection it was made for, and made again for another.
@MainActor final class LookKeys {
    private var keys: [Look: [Int]] = [:]
    private var next = 0
    private var selection: [UUID] = []

    /// One key for each slot of a look, bottom first. Slots that came by other ways than these
    /// cards, as by undoing, are given new keys at the top.
    func keys(_ look: Look, count: Int, for selection: [UUID]) -> [Int] {
        if selection != self.selection {
            keys = [:]
            self.selection = selection
        }
        var k = keys[look] ?? []
        if k.count > count { k.removeLast(k.count - count) }
        while k.count < count {
            k.append(next)
            next += 1
        }
        keys[look] = k
        return k
    }

    func removed(_ look: Look, at slot: Int) {
        guard var k = keys[look], k.indices.contains(slot) else { return }
        k.remove(at: slot)
        keys[look] = k
    }

    func moved(_ look: Look, from: Int, to: Int) {
        guard var k = keys[look], k.indices.contains(from), k.indices.contains(to) else { return }
        k.insert(k.remove(at: from), at: to)
        keys[look] = k
    }
}

extension DocumentStore {
    /// Which of a layer's shadows a drag on the canvas moves: the one whose card is open, when it
    /// falls under the layer, or else the first that does.
    func shadowSlot(of node: Node) -> Int? {
        if case .shadow(let slot)? = openAspect, node[shadow: slot].outside { return slot }
        return (0..<node.slots(.shadow)).first { node[shadow: $0].outside }
    }
}
