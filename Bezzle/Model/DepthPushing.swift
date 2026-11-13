import Foundation
import CoreGraphics

/// Pushing layers away and pulling them nearer while they are dragged, the depth key held: on the
/// Mac Control, on Windows Alt. Held, the pointer going up brings what is dragged nearer the eye,
/// and down sends it further, a point of height for each point the pointer goes, as the knob's
/// Option drag does (`DepthTurning`); across, it stays where it was. Let go of the key and the
/// drag moves it across again from where the pointer is then, so neither way jumps, however often
/// the key is pressed during one drag.
///
/// Heights catch at the page (nothing) and at the heights of the layers around, so that layers
/// are easily brought level; with Shift they go in steps of ten points. Shared by every Bezzle.
nonisolated struct DepthPushing {
    /// How far up the pointer has taken what is dragged while the key was held, in points of the
    /// canvas: as much nearer as it went up.
    private(set) var depth: CGFloat = 0
    /// How far the pointer has gone while the key was held, which moving across leaves out.
    private(set) var aside: CGPoint = .zero
    /// While the key is held: where the pointer was when it was pressed, and how far up and aside
    /// it had gone before that.
    private var held: (from: CGPoint, depth: CGFloat, aside: CGPoint)?

    init() {}

    /// Whether the key is held now, so the drag goes in depth.
    var pushing: Bool { held != nil }

    /// Whether the drag has gone in depth at all.
    var pushed: Bool { held != nil || depth != 0 }

    /// The pointer at `p` (canvas points), the key held or not.
    mutating func pointer(at p: CGPoint, holding: Bool) {
        switch (holding, held) {
        case (true, nil):
            held = (p, depth, aside)
        case (true, let h?):
            depth = h.depth + (h.from.y - p.y)
            aside = CGPoint(x: h.aside.x + p.x - h.from.x, y: h.aside.y + p.y - h.from.y)
        case (false, let h?):
            depth = h.depth + (h.from.y - p.y)
            aside = CGPoint(x: h.aside.x + p.x - h.from.x, y: h.aside.y + p.y - h.from.y)
            held = nil
        case (false, nil):
            break
        }
    }

    /// How far a drag from `start` to `p` moves what is dragged across: all the pointer went,
    /// but for what it went with the key held.
    func across(from start: CGPoint, to p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - start.x - aside.x, y: p.y - start.y - aside.y)
    }

    /// A layer's height, `original` when the drag began, pushed as far as the drag has. Caught
    /// at nothing and at `level` (the heights of the layers around) within `reach` points, or
    /// with `steps` in tens of points; to the whole point otherwise.
    func height(from original: CGFloat, level: [CGFloat] = [], reach: CGFloat, steps: Bool) -> CGFloat {
        let h = original + depth
        if steps { return (h / 10).rounded() * 10 }
        let stops = [0] + level
        if let near = stops.min(by: { abs($0 - h) < abs($1 - h) }), abs(near - h) <= reach { return near }
        return h.rounded()
    }

    /// A layer's turn in depth, `original` when the drag began, with its height set: as it was
    /// when it is back where it began, and none at all when nothing of it leaves the page.
    static func turn(_ original: Transform3D?, at height: CGFloat) -> Transform3D? {
        if height == (original?.z ?? 0) { return original }
        var t = original ?? Transform3D()
        t.z = height
        return t.x == 0 && t.y == 0 && t.z == 0 && !t.pinned ? nil : t
    }
}

nonisolated extension BezzleDocument {
    /// The heights a layer being pushed in depth catches at: those of the layers lying with it,
    /// leaving out the ones being moved.
    func levels(around ids: [UUID]) -> [UUID: [CGFloat]] {
        let moving = Set(ids)
        var out: [UUID: [CGFloat]] = [:]
        for id in ids {
            let siblings = parent(of: id)?.children ?? []
            let heights = Set(siblings.filter { !moving.contains($0.id) && !$0.hidden }.map(DepthOrder.height(of:)))
            out[id] = heights.filter { $0 != 0 }.sorted()
        }
        return out
    }
}
