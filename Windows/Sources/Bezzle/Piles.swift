import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// A layer's fills, borders or shadows in the inspector, as the Mac's Views/Piles.swift has them:
/// one card each, several of a kind close together as a pile, the top one first as the layers
/// panel lists them. A card in a pile is picked up by dragging it up or down and put back in
/// another place, the others moving aside to make room.
///
/// Picked up, a card follows the pointer at once, lifted off the panel, within its pile but for a
/// little give past either end; the others move aside softly (the Mac's Theme.spring), and the
/// place it would go is the one whose top is nearest, however tall the cards about it are, as an
/// open one is. Let go, it is put there as one step, and lands from where it was let go.
@MainActor
final class Pile {
    /// How far apart the cards of a pile lie: closer than cards of different kinds, so they read as one.
    static let gap = 4.0

    let root = StackPanel()
    /// fill, border or shadow, as LookChange names them.
    let look: String
    /// The slot each card shows, top first.
    let slots: [Int]
    /// How many places at the bottom are not to be had: a picture stays at the bottom, where a
    /// repeat grid's cells and a stack's posts keep their own.
    let lowest: Int
    /// Whether its cards can be moved at all: several, and every slot shown.
    let movable: Bool
    /// Puts what is in slot `from` in slot `to`, as one step, the card landing `landing` points
    /// below its new place (above, when less than nought), and the panel made again.
    var commit: ((_ from: Int, _ to: Int, _ landing: Double) -> Void)?
    /// Told as a card is picked up (true) and once it has been put back where it was (false):
    /// meanwhile the panel is not made again under it.
    var holding: ((Bool) -> Void)?

    private var holders: [Grid] = []
    private var moves: [CompositeTransform] = []
    /// How far each card is shown moved from its place, by its place in the pile.
    private var offsets: [DeckSpring] = []
    /// How far the card picked up is lifted off the panel, 0 to 1, and its shadow.
    private var lift = DeckSpring(0)
    private let shadow = Image()
    private var lifted: Int?
    /// The card picked up, and the place it would go if let go now, counted from the top.
    private var carried: Int?
    private var target = 0
    private var heights: [Double] = []
    private lazy var ticker = Motion.Ticker { [weak self] dt in self?.step(dt) ?? false }

    /// `count` is how many slots the layers have, `lowest` the places at the bottom not to be had.
    /// A card just put in a place lands from where it was let go: `landing` is its slot and how
    /// far from that place it was.
    init(look: String, slots: [Int], count: Int, lowest: Int, landing: (slot: Int, offset: Double)?) {
        self.look = look
        self.slots = slots
        self.lowest = lowest
        movable = slots.count > 1 && slots.count == count
        root.spacing = Self.gap
        shadow.isHitTestVisible = false
        shadow.opacity = 0
        landed = landing
    }

    private var landed: (slot: Int, offset: Double)?

    /// What a card of the pile does when dragged up or down (nil: let go), for the card of `slot`;
    /// nil for one that stays where it is.
    func restack(_ slot: Int) -> ((Double?) -> Void)? {
        guard movable, slot >= lowest else { return nil }
        return { [weak self] dy in
            guard let self, let i = self.slots.firstIndex(of: slot) else { return }
            if let dy { self.carry(i, by: dy) } else { self.letGo(i) }
        }
    }

    /// The cards, top first, as made for each of `slots`.
    func hold(_ cards: [UIElement]) -> UIElement {
        for (k, card) in cards.enumerated() {
            let holder = Grid()
            let move = CompositeTransform()
            holder.renderTransform = move
            holder.children.append(card)
            root.children.append(holder)
            holders.append(holder)
            moves.append(move)
            offsets.append(DeckSpring(0))
            // The card just put here lands from where it was let go, lifted, and settles.
            if let landed, k < slots.count, slots[k] == landed.slot {
                offsets[k] = DeckSpring(landed.offset)
                offsets[k].target = 0
                lift = DeckSpring(1)
                lift.target = 0
                lifted = k
                try? Canvas.setZIndex(holder, 1)
                try? Canvas.setZIndex(root, 1)
                holder.loaded.addHandler { [weak self] _, _ in
                    guard let self, self.lifted == k else { return }
                    self.drawShadow(k)
                    self.place()
                    self.ticker.start()
                }
            }
        }
        landed = nil
        place()
        return root
    }

    // MARK: Carrying

    /// How far a card gives, pulled `over` points past the end of where it can go: less and less
    /// the further it is pulled, and never more than `limit` (the Mac's Dial.give).
    static func give(_ over: Double, limit: Double) -> Double {
        limit * (1 - exp(-over / (limit * 1.6)))
    }

    /// Where the card `i` lies in the pile, and where it would lie in each place it can be put, the
    /// others closing up round it, counted from the top of the pile.
    private func places(_ i: Int) -> (at: Double, tops: [Double]) {
        let at = heights[..<i].reduce(0) { $0 + $1 + Self.gap }
        var tops: [Double] = []
        var y = 0.0
        for (k, h) in heights.enumerated() where k != i {
            tops.append(y)
            y += h + Self.gap
        }
        tops.append(y)
        return (at, Array(tops.prefix(max(heights.count - lowest, 1))))
    }

    private func carry(_ i: Int, by dy: Double) {
        if carried != i {
            carried = i
            heights = holders.map { $0.actualHeight }
            holding?(true)
            // Over the cards after it while it is carried about, and over the panel's others.
            for (k, h) in holders.enumerated() { try? Canvas.setZIndex(h, k == i ? 1 : 0) }
            try? Canvas.setZIndex(root, 1)
            lifted = i
            drawShadow(i)
            lift.target = 1
        }
        // The place nearest to where it is held, however tall the cards about it are, as one left
        // open is; and held within the pile, as a card in a box is.
        let (at, tops) = places(i)
        target = tops.indices.min { abs(tops[$0] - at - dy) < abs(tops[$1] - at - dy) } ?? 0
        let low = (tops.first ?? at) - at, high = (tops.last ?? at) - at
        let shown = dy < low ? low - Self.give(low - dy, limit: 12) : dy > high ? high + Self.give(dy - high, limit: 12) : dy
        // Picked up, a card follows the pointer at once; the others move aside softly.
        offsets[i] = DeckSpring(shown)
        let step = heights[i] + Self.gap
        for k in offsets.indices where k != i {
            offsets[k].target = i < k && k <= target ? -step : target <= k && k < i ? step : 0
        }
        place()
        ticker.start()
    }

    private func letGo(_ i: Int) {
        guard carried == i else { return }
        carried = nil
        let from = slots.count - 1 - i, to = slots.count - 1 - target
        if from != to, let commit {
            // Put in its new place as one step; the panel is made again with the card there,
            // landing from where it was let go.
            let (at, tops) = places(i)
            commit(from, to, at + offsets[i].value - tops[target])
            return
        }
        // Back where it was.
        for k in offsets.indices { offsets[k].target = 0 }
        lift.target = 0
        ticker.start()
    }

    // MARK: Motion

    private func step(_ dt: Double) -> Bool {
        let (stiffness, damping) = Motion.spring
        for k in offsets.indices where k != carried { offsets[k].step(dt, stiffness: stiffness, damping: damping) }
        lift.step(dt, stiffness: stiffness, damping: damping)
        place()
        let moving = !lift.settled || offsets.indices.contains { $0 != carried && !offsets[$0].settled }
        if !moving, carried == nil {
            // Settled: the pile lies in the panel like any card again.
            if let k = lifted, k < holders.count {
                removeShadow(k)
                try? Canvas.setZIndex(holders[k], 0)
            }
            lifted = nil
            try? Canvas.setZIndex(root, 0)
            holding?(false)
        }
        return moving || carried != nil
    }

    private func place() {
        for (k, move) in moves.enumerated() {
            // Lifted, a card stands a point and a half up, as the Mac's lifted card.
            move.translateY = offsets[k].value - (k == lifted ? 1.5 * lift.value : 0)
        }
        shadow.opacity = max(0, min(1, lift.value))
    }

    // MARK: The lifted card's shadow

    /// The Mac's lifted card: the shadow colour at 16%, blur 18, 9 down, under the card.
    private func drawShadow(_ k: Int) {
        guard k < holders.count else { return }
        let holder = holders[k]
        let scale = Double(holder.xamlRoot?.rasterizationScale ?? 1)
        let w = holder.actualWidth, h = holder.actualHeight
        guard w > 0, h > 0 else { return }
        let pad = Int((40 * scale).rounded())
        let sw = Int((w * scale).rounded()), sh = Int((h * scale).rounded())
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: sw, height: sh, pad: pad, blur: 18 * scale, dy: 0, colour: Theme.shadow, alpha: 0.16) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        shadow.source = bitmap
        shadow.width = w + 2 * Double(pad) / scale
        shadow.height = h + 2 * Double(pad) / scale
        shadow.margin = Theme.inset(-Double(pad) / scale, -Double(pad) / scale + 9, -Double(pad) / scale, -Double(pad) / scale - 9)
        var at: UInt32 = 0
        if !holder.children.indexOf(shadow, &at) {
            removeShadowEverywhere()
            holder.children.insertAt(0, shadow)
        }
    }

    private func removeShadow(_ k: Int) {
        guard k < holders.count else { return }
        var at: UInt32 = 0
        if holders[k].children.indexOf(shadow, &at) { holders[k].children.removeAt(at) }
    }

    private func removeShadowEverywhere() {
        for k in holders.indices { removeShadow(k) }
    }
}
