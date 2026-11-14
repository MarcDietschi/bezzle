import Foundation
import CoreGraphics

// Looking at an artboard's scene from the side, shared by every Bezzle. The page is not turned:
// the eye is moved, as someone in front of a window moves their head. So the page and all that
// lies flat in it stay exactly where they are, and everything done there stays true, while what
// is held up off the page shows how high it stands by how far it goes aside, and what is turned
// shows more of one side. It is a way of looking only: kept beside the design for as long as it
// is open, never in it (`BezzleDocument.looks`), so never saved, sent or exported.

/// From where an artboard's scene is looked at: how far round from straight in front the eye
/// stands, as high above the page as ever.
nonisolated struct DepthLook: Equatable, Hashable, Sendable {
    /// Degrees to the right of straight in front; to the left below 0.
    var across = 0.0
    /// Degrees below it; above below 0.
    var down = 0.0

    static let front = DepthLook()
    /// No further round than this: beyond it what is held up runs away across the page.
    static let most = 60.0
    /// Degrees for a point the pointer is dragged on the canvas.
    static let rate = 0.35

    var isFront: Bool { across == 0 && down == 0 }
    /// How far round it is, whichever way.
    var angle: Double { (across * across + down * down).squareRoot() }

    /// The same way round, no further than `most`.
    var held: DepthLook {
        let a = angle
        guard a > Self.most else { return self }
        return DepthLook(across: across * Self.most / a, down: down * Self.most / a)
    }

    /// How far aside of straight in front an eye `distance` above the page then stands.
    func aside(distance: CGFloat) -> CGPoint {
        let look = held, a = look.angle
        guard a > 0 else { return .zero }
        let far = Double(distance) * tan(a * .pi / 180)
        return CGPoint(x: CGFloat(far * look.across / a), y: CGFloat(far * look.down / a))
    }

    /// The look after the pointer has been dragged by `d` canvas-view points from where this was
    /// the look. What is held up goes with the pointer, as if the scene were taken hold of and
    /// turned: the eye goes the other way. `steps` goes in fives, and near the front it catches
    /// there.
    func dragged(by d: CGPoint, steps: Bool) -> DepthLook {
        var next = DepthLook(across: across - Double(d.x) * Self.rate, down: down - Double(d.y) * Self.rate).held
        if steps {
            next.across = (next.across / 5).rounded() * 5
            next.down = (next.down / 5).rounded() * 5
        } else {
            next.across = next.across.rounded()
            next.down = next.down.rounded()
            if abs(next.across) < 2 { next.across = 0 }
            if abs(next.down) < 2 { next.down = 0 }
        }
        // Not -0.
        if next.across == 0 { next.across = 0 }
        if next.down == 0 { next.down = 0 }
        return next.held
    }
}

/// A post under a corner of a layer held up off the page: from where the corner would lie in the
/// page, straight under it, to where it shows.
nonisolated struct DepthPost: Equatable, Sendable {
    var foot: CGPoint
    var top: CGPoint
}

nonisolated extension Eye {
    /// The same eye looking from where `look` says: moved aside, as high above the page.
    func looking(_ look: DepthLook?) -> Eye {
        guard let look, !look.isFront else { return self }
        let aside = look.aside(distance: distance)
        return Eye(at: CGPoint(x: at.x + aside.x, y: at.y + aside.y), distance: distance)
    }
}

nonisolated extension BezzleDocument {
    /// Where an artboard's scene is seen from, in its own points: in front of its middle
    /// (`Eye.stage`), or from where it is looked at for now (`looks`).
    func stage(of board: Node) -> Eye {
        Eye.stage(board.frame.size).looking(looks?[board.id])
    }

    /// The design looked at from the front, whatever it is looked at from for now: what anything
    /// that leaves the canvas reads, so a way of looking never goes with it.
    var front: BezzleDocument {
        guard looks != nil else { return self }
        var doc = self
        doc.looks = nil
        return doc
    }

    /// The posts of an artboard looked at from the side, on the canvas: one under each corner of
    /// every layer on it that stands off the page, so that how high each stands can be read.
    /// With some of those layers `picked`, only theirs, so that what is being worked on reads
    /// alone. None looked at from the front, where a post is seen end on.
    func posts(of board: Node, picked: Set<UUID> = []) -> [DepthPost] {
        guard board.isArtboard, let look = looks?[board.id], !look.isFront else { return [] }
        var all: [DepthPost] = [], chosen: [DepthPost] = []
        func walk(_ holder: Node, within: Bool) {
            for node in holder.children where !node.hidden {
                let mine = within || picked.contains(node.id)
                if Perspective.inDepth(node) {
                    for corner in DepthBody.corners(of: node) where abs(corner.z) > 0.01 {
                        let foot = shown(ScenePoint(x: corner.x, y: corner.y), inside: holder.id)
                        let top = shown(corner, inside: holder.id)
                        guard hypot(top.x - foot.x, top.y - foot.y) > 0.01 else { continue }
                        all.append(DepthPost(foot: foot, top: top))
                        if mine { chosen.append(DepthPost(foot: foot, top: top)) }
                    }
                } else if node.isGroup {
                    // A group lying in the page holds layers that may stand off it.
                    walk(node, within: mine)
                }
            }
        }
        walk(board, within: false)
        return chosen.isEmpty ? all : chosen
    }
}
