import Foundation
import CoreGraphics

// Depth of field. A film's camera is sharp at one distance, and what stands nearer or further
// than that shows blurred, the more the further off it stands.
//
// The distance is the eye's along its line of sight: how far in front of the eye a point lies,
// however the scene is tipped and swung under the camera. It is counted from where the camera
// looks, in the artboard's points: the point of the artboard's sheet in the middle of the frame
// is at nothing, a layer lifted a hundred points under a camera that looks straight down is a
// hundred nearer, and under a camera tipped back the top of the sheet is further and its foot
// nearer (`FilmLens.nearness`). `FilmCamera.focus` is the distance that is sharp, counted the
// same way. So a camera at rest is sharp on the page, and with nothing lifted nothing is
// blurred, whatever its blur; and a camera that comes closer stays sharp on what it looks at.
//
// `FilmCamera.blur` is how much: so many points of blur for every hundred points a thing stands
// off the focus, measured as a layer's own blur is, in the artboard's points, before the camera
// shows the thing larger or smaller. A card a hundred points off the focus under a blur of 4 is
// blurred as its own Blur of 4 would blur it.
//
// A flat thing that the camera does not face stands at other distances from side to side: the
// sheet under a camera tipped back is sharp along one line and softer toward its top and its
// foot. In the frame that is as simple as it could be: the blur is how far a point is from a
// straight line, times a number (`FilmSoft`). So every piece of a film says its blur with three
// numbers, and whatever draws the film blurs each point of the piece by what they give there.

/// How much a piece of a film is blurred for standing off the camera's focus, at each point of
/// the film's frame: `|x * across + y * down + level|` points of blur, in the frame's points,
/// for the point `x`, `y` of the frame. A piece that faces the camera is blurred alike all over
/// (`level` alone); one that lies at an angle is sharp along a line, and more blurred the further
/// from it, both ways. Pieces lying in one plane have the same three numbers, wherever in it
/// they lie.
nonisolated struct FilmSoft: Equatable, Sendable {
    var across = 0.0
    var down = 0.0
    var level = 0.0

    /// The most anything is blurred, in the frame's points: as much as a layer's own blur goes to.
    static let most = 200.0

    /// The points of blur at a point of the frame.
    func blur(at p: CGPoint) -> Double { min(abs(across * Double(p.x) + down * Double(p.y) + level), Self.most) }

    /// The least and the most it blurs within a part of the frame.
    func range(in rect: CGRect) -> (least: Double, most: Double) {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let values = corners.map { across * Double($0.x) + down * Double($0.y) + level }
        let low = values.min() ?? 0, high = values.max() ?? 0
        // The sharp line runs through it: nothing, somewhere.
        let least = low <= 0 && high >= 0 ? 0 : min(abs(low), abs(high))
        return (min(least, Self.most), min(max(abs(low), abs(high)), Self.most))
    }

    /// Whether another blurs as this does all over a frame of `size`, to within what shows:
    /// pieces lying in one plane, which are blurred as the one picture they are.
    func matches(_ other: FilmSoft, in size: CGSize) -> Bool {
        abs(across - other.across) * Double(size.width) + abs(down - other.down) * Double(size.height) + abs(level - other.level) < 0.02
    }
}

nonisolated extension FilmCamera {
    /// The blur a camera is given when it is told what to be sharp at and blurs nothing yet.
    static let usualBlur = 4.0
}

nonisolated extension FilmLens {
    /// How many points nearer the eye than the point the camera looks at a point of a flat thing
    /// lies, along the camera's line of sight, in the artboard's points; further, below nothing.
    /// `map` is the thing as the camera shows it in a frame of `size` (`ground`, `layer`), and
    /// `p` a point of it as the map takes them.
    static func nearness(of p: CGPoint, in map: FilmMap, camera: FilmCamera, size: CGSize) -> Double {
        (distance(for: size) - map.depth(at: p)) / max(camera.zoom, 1e-6)
    }

    /// How much a flat thing is blurred for standing off the camera's focus, across the frame;
    /// nil under a camera that blurs nothing, and for a thing seen edge on, which shows nothing.
    ///
    /// A point that lies `n` nearer than where the camera looks (`nearness`) is blurred by
    /// `blur / 100 * |n - focus|` in the artboard's points, and shows that as many times larger
    /// as it is shown itself. Along a flat thing, how many times larger a point shows runs
    /// evenly across the frame, and so does this.
    static func soft(of map: FilmMap, camera: FilmCamera, size: CGSize) -> FilmSoft? {
        guard camera.blur > 0, let back = map.inverse else { return nil }
        let far = distance(for: size)
        // Where the focus lies in front of the eye, as the map counts it.
        let sharp = far - camera.zoom * camera.focus
        let k = camera.blur / 100 * far
        // One over how far in front of the eye the point lies that shows at a point of the frame.
        let soft = FilmSoft(across: k * sharp * back.g, down: k * sharp * back.h, level: k * (sharp * back.i - 1))
        guard soft.across.isFinite, soft.down.isFinite, soft.level.isFinite else { return nil }
        return soft
    }

    /// The line of a flat thing that lies in the camera's focus, within a rect of it: its two
    /// ends, in the thing's own points; nil where the focus does not cut the rect, as on a thing
    /// that faces the camera. `map` is the thing as the camera shows it in a frame of `size`.
    static func sharpLine(of rect: CGRect, in map: FilmMap, camera: FilmCamera, size: CGSize) -> (CGPoint, CGPoint)? {
        let sharp = distance(for: size) - camera.zoom * camera.focus
        // The points as far in front of the eye as the focus: `g x + h y + i = sharp`.
        let g = map.g, h = map.h, c = map.i - sharp
        guard abs(g) > 1e-12 || abs(h) > 1e-12, rect.width > 0, rect.height > 0 else { return nil }
        var ends: [CGPoint] = []
        func add(_ p: CGPoint) {
            if !ends.contains(where: { abs($0.x - p.x) < 1e-6 && abs($0.y - p.y) < 1e-6 }) { ends.append(p) }
        }
        let x0 = Double(rect.minX), x1 = Double(rect.maxX), y0 = Double(rect.minY), y1 = Double(rect.maxY)
        if abs(h) > 1e-12 {
            for x in [x0, x1] {
                let y = -(g * x + c) / h
                if y >= y0 - 1e-9, y <= y1 + 1e-9 { add(CGPoint(x: x, y: y)) }
            }
        }
        if abs(g) > 1e-12 {
            for y in [y0, y1] {
                let x = -(h * y + c) / g
                if x >= x0 - 1e-9, x <= x1 + 1e-9 { add(CGPoint(x: x, y: y)) }
            }
        }
        guard ends.count >= 2 else { return nil }
        return (ends[0], ends[1])
    }
}

extension Node {
    /// Artboards: what the camera's focus has to be at a moment for layers to be sharp: how much
    /// nearer than where the camera looks their middles stand then (`FilmLens.nearness`), to the
    /// whole point. For several at different distances, half way between the nearest and the
    /// furthest, so that those are as soft as each other. Nil when none of them is on it.
    func focus(on ids: [UUID], at t: Double, pieces: [FilmPiece]) -> Double? {
        let camera = camera(at: t)
        var near: [Double] = []
        for id in ids {
            guard let layer = descendant(id), let map = filmPointMap(of: id, at: t, pieces: pieces) else { continue }
            let middle = CGPoint(x: layer.frame.width / 2, y: layer.frame.height / 2)
            let n = FilmLens.nearness(of: middle, in: map, camera: camera, size: frame.size)
            if n.isFinite { near.append(n) }
        }
        guard let least = near.min(), let most = near.max() else { return nil }
        return ((least + most) / 2).rounded()
    }
}
