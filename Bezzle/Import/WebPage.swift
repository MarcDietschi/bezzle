import CoreGraphics
import Foundation

/// A web page as the page reader took it apart (see WebPageReader.js), at one width: its boxes,
/// words, pictures and outlines, every place measured in the page's pixels from its top left, as
/// the page is laid out with nothing moved by a transform.
nonisolated struct WebPage: Decodable {
    var url: String
    var title: String
    /// How wide the page was laid out, and how tall the window it was laid out in.
    var w: Double
    var vh: Double
    /// How much of the page was read, and how tall it is in all.
    var h: Double
    var fullHeight: Double?
    var bg: Background
    var root: WebItem?
    /// The pictures the page shows, by where they are; items refer to them by their place in this list.
    var images: [String]
    /// What the reader could only come close to, and how often.
    var notes: [String: Int]
    var lang: String?

    /// The page's own background, which covers all of it.
    struct Background: Decodable {
        var c: [Double]
        var layers: [WebLayer]?
    }
}

/// A box, a run of words, or a box an inline element draws behind its words.
nonisolated struct WebItem: Decodable {
    /// "el" an element, "text" words, "deco" a line's piece of an inline element's box.
    var t: String
    /// The element, to be photographed by, or for words, the element they lie in.
    var id: Int?
    var tag: String?
    /// What the element says it is, by its label, id or class.
    var label: String?
    /// The element's border box, as laid out.
    var x: Double?
    var y: Double?
    var w: Double?
    var h: Double?
    /// How the element is moved by its transforms and those of what holds it: a, b, c, d, tx, ty,
    /// taking the page's coordinates to the page's coordinates. None is none.
    var m: [Double]?
    var fixed: Bool?

    // Where it stands in depth, only where the page has anything in depth (see `WebDepth`). Each
    // matrix is DOMMatrix's sixteen numbers, column by column, from the page as laid out.
    /// How the element is drawn on the page, as the browser draws it, perspective and all.
    var w3: [Double]?
    /// How it stands in the 3D context it is in, before that is drawn flat into its plane.
    var c3: [Double]?
    /// The element whose plane that context is drawn into; none for the page itself.
    var pl: Int?
    /// Whether what it holds keeps its depth (transform-style: preserve-3d, as it is used).
    var p3: Bool?
    /// Whether it is turned or moved in depth by a transform of its own.
    var o3: Bool?
    /// Whether its back is turned to the eye and the page hides it (backface-visibility: hidden).
    var back: Bool?

    // Where it is painted among the others.
    var pos: String?
    var z: Int?
    /// Whether it is painted as a whole of its own, as a stacking context is.
    var sc: Bool?
    /// Floated.
    var fl: Bool?
    /// Laid out in a line of words, as an inline block or a picture is.
    var inl: Bool?
    /// A ::before, painted before what its element holds.
    var before: Bool?
    var pseudo: String?

    // How it is painted.
    var op: Double?
    var blend: String?
    var filter: String?
    /// visibility: hidden: its own box is not drawn, though what it holds may be.
    var hidden: Bool?
    var bg: [Double]?
    var layers: [WebLayer]?
    /// Its background shows only through its letters.
    var textClip: Bool?
    /// The four sides' borders, top first, clockwise; nil where there is none.
    var bd: [WebSide?]?
    var sh: String?
    var ol: WebOutline?
    var backdrop: String?
    /// Why it is to be a picture of itself, when it cannot be taken apart, and what the picture
    /// will show, the same for things that look alike, so that one photograph serves them all.
    var shot: String?
    var key: String?
    /// The corners, each across and down: top left, top right, bottom right, bottom left.
    var rad: [Double]?
    /// Whether what it holds is cut off at its edge.
    var clip: Bool?
    var clipPath: String?
    /// Border widths, top, right, bottom, left, then the padding, alike.
    var ins: [Double]?
    var img: WebImage?
    /// The outlines of an SVG, in the page's coordinates.
    var vec: [WebPath]?
    var kids: [WebItem]?
    var contents: Bool?

    // Words.
    var text: String?
    /// The letters in runs, each its length in UTF-16 and the style it is in.
    var runs: [[Int]]?
    var styles: [WebLetters]?
    var lines: [WebLine]?
    /// What the words are laid out in.
    var cont: WebBlock?
    /// Whether the words are all the element's own, so that it lays them out from side to side
    /// as a paragraph, rather than among boxes.
    var clean: Bool?
    var marker: Bool?
    var field: Bool?
    var paint: WebPaintBox?

    var box: CGRect { CGRect(x: x ?? 0, y: y ?? 0, width: w ?? 0, height: h ?? 0) }

    /// Border and padding, top, right, bottom and left.
    var borders: (CGFloat, CGFloat, CGFloat, CGFloat) {
        let i = ins ?? []
        func at(_ k: Int) -> CGFloat { k < i.count ? CGFloat(i[k]) : 0 }
        return (at(0), at(1), at(2), at(3))
    }

    var paddings: (CGFloat, CGFloat, CGFloat, CGFloat) {
        let i = ins ?? []
        func at(_ k: Int) -> CGFloat { k < i.count ? CGFloat(i[k]) : 0 }
        return (at(4), at(5), at(6), at(7))
    }

    /// The box inside the border.
    var paddingBox: CGRect {
        let b = borders
        return CGRect(x: box.minX + b.3, y: box.minY + b.0, width: max(box.width - b.1 - b.3, 0), height: max(box.height - b.0 - b.2, 0))
    }

    /// The box inside the border and the padding.
    var contentBox: CGRect {
        let p = paddings, inner = paddingBox
        return CGRect(x: inner.minX + p.3, y: inner.minY + p.0, width: max(inner.width - p.1 - p.3, 0), height: max(inner.height - p.0 - p.2, 0))
    }

    var matrix: CGAffineTransform? {
        guard let m, m.count == 6, m.allSatisfy(\.isFinite) else { return nil }
        let t = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        return t.isIdentity ? nil : t
    }
}

/// One layer of a background: a gradient or a picture, and how it is laid in the box.
nonisolated struct WebLayer: Decodable {
    var img: Int?
    var grad: String?
    var other: String?
    var size: String?
    var x: String?
    var y: String?
    var rep: String?
    var origin: String?
    var clip: String?
    var blend: String?
}

nonisolated struct WebSide: Decodable {
    var w: Double
    var s: String
    var c: [Double]
}

nonisolated struct WebOutline: Decodable {
    var w: Double
    var s: String
    var c: [Double]
    var o: Double
}

/// A picture an element shows, by its place in the page's list, and how it fills the box.
nonisolated struct WebImage: Decodable {
    var src: Int?
    var fit: String?
    var pos: String?
    /// Its own size, in pixels.
    var nat: [Double]?
}

/// An outline of an SVG: SVG path data, and the transform taking it into the page.
nonisolated struct WebPath: Decodable {
    var d: String
    var m: [Double]
    var fill: WebSVGPaint?
    var rule: String?
    var stroke: WebStroke?
    var op: Double?

    var matrix: CGAffineTransform {
        guard m.count == 6, m.allSatisfy(\.isFinite) else { return .identity }
        return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }
}

nonisolated struct WebSVGPaint: Decodable {
    var c: [Double]?
    var g: WebSVGGradient?
}

/// An SVG gradient, its points in the shape's own coordinates: a linear one from `a` to `b`, a
/// radial one round `a` out to `b` across and `e` down.
nonisolated struct WebSVGGradient: Decodable {
    var k: String
    var stops: [WebStop]
    var a: [Double]
    var b: [Double]
    var e: [Double]?
}

nonisolated struct WebStop: Decodable {
    var o: Double
    var c: [Double]
}

nonisolated struct WebStroke: Decodable {
    var paint: WebSVGPaint
    var w: Double
    var dash: [Double]?
    var cap: String?
    var join: String?
}

/// How letters look, as the browser drew them.
nonisolated struct WebLetters: Decodable, Hashable {
    /// The families asked for, in order, and the one drawn with.
    var fam: [String]
    var used: String
    /// Whether that one is the page's own, loaded from the web.
    var web: Bool
    var wt: Int
    var it: Bool
    var size: Double
    /// The distance between lines, in pixels; nil is the font's own.
    var lh: Double?
    var ls: Double
    var c: [Double]
    var u: Bool?
    var st: Bool?
    /// text-transform.
    var tt: String?
    var sc: Bool?
    var ff: String?
    var fvn: String?
    var fv: String?
    var tsh: String?
    var stroke: Double?
    var va: String?
}

/// One line of words as the browser set it: its letters by their place in the text (UTF-16),
/// its box, and its baseline.
nonisolated struct WebLine: Decodable {
    var from: Int
    var to: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var base: Double
}

/// The box words are laid out in and how: its content box, alignment, and whether lines wrap.
nonisolated struct WebBlock: Decodable {
    var x: Double
    var y: Double
    var w: Double
    var align: String
    var dir: String?
    var indent: Double?
    var wrap: Bool
}

/// What letters are painted with when a background shows through them: that background, in the
/// box it is laid in.
nonisolated struct WebPaintBox: Decodable {
    var bg: [Double]
    var layers: [WebLayer]?
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

// MARK: - Depth

/// A 4×4 matrix as the browser keeps one, DOMMatrix's sixteen numbers column by column: a point
/// across, down and up off the page, with its weight, taken to where it goes.
nonisolated struct WebMatrix {
    var m: [Double]

    init?(_ numbers: [Double]?) {
        guard let numbers, numbers.count == 16, numbers.allSatisfy(\.isFinite) else { return nil }
        m = numbers
    }

    init(columns: [Double]) { m = columns }

    /// Row `r` of column `c`, each counted from 0.
    subscript(r: Int, c: Int) -> Double { m[c * 4 + r] }

    /// The other after this one: this applied to what `b` gives.
    static func * (a: WebMatrix, b: WebMatrix) -> WebMatrix {
        var out = [Double](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a[r, k] * b[k, c] }
                out[c * 4 + r] = s
            }
        }
        return WebMatrix(columns: out)
    }

    /// Where a point of the page as laid out shows; nil where it would lie behind the eye.
    func shown(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = self[3, 0] * x + self[3, 1] * y + self[3, 3]
        guard w > 1e-9 else { return nil }
        return CGPoint(x: (self[0, 0] * x + self[0, 1] * y + self[0, 3]) / w, y: (self[1, 0] * x + self[1, 1] * y + self[1, 3]) / w)
    }

    /// What this draws of the page as laid out, where that is a flat picture moved, turned and
    /// stretched: no perspective changes how big it is from place to place, over as far as
    /// `reach`, by more than the page's six figures could. Nil where one does.
    func flat(within reach: Double) -> CGAffineTransform? {
        guard even(within: reach) else { return nil }
        let w = self[3, 3]
        return CGAffineTransform(a: CGFloat(self[0, 0] / w), b: CGFloat(self[1, 0] / w), c: CGFloat(self[0, 1] / w),
                                 d: CGFloat(self[1, 1] / w), tx: CGFloat(self[0, 3] / w), ty: CGFloat(self[1, 3] / w))
    }

    /// Whether the page as laid out is equally big everywhere by this, over as far as `reach`:
    /// its weight changes across that by no more than a thousandth. Whether that is near enough
    /// is for the corners to say (`WebDepth.agrees`).
    func even(within reach: Double) -> Bool {
        let w = self[3, 3]
        return abs(w) > 1e-12 && (abs(self[3, 0]) + abs(self[3, 1])) * reach < 1e-3 * abs(w)
    }

    /// Whether anything is seen through a perspective by it, however it lies.
    var seesInPerspective: Bool {
        let w = max(abs(self[3, 3]), 1e-12)
        return (abs(self[3, 0]) + abs(self[3, 1]) + abs(self[3, 2])) > 1e-9 * w
    }

    /// The scene as Bezzle's eye sees it, taken back from the page into the scene: from a point
    /// seen to the place a point at that height must stand to be seen there (`Eye`, `Perspective`).
    static func unseeing(_ eye: Eye) -> WebMatrix {
        let d = Double(eye.distance), ex = Double(eye.at.x), ey = Double(eye.at.y)
        return WebMatrix(columns: [1, 0, 0, 0, 0, 1, 0, 0, ex / d, ey / d, 1, 1 / d, 0, 0, 0, 1])
    }
}

/// Where the plane of an element stands in the artboard's scene, by a stand Bezzle has for a
/// layer: its points laid out flat, as the element's flat matrix then says (`WebItem.m`), tipped
/// and swung as a layer is (`Spin(Transform3D)`), and moved to `base`.
nonisolated struct WebStand: Equatable {
    var tip: Double
    var swing: Double
    var base: ScenePoint

    var spin: Spin { Spin(Transform3D(x: tip, y: swing)) }
}

/// A page's 3D transforms, read for the artboard it becomes: which of its elements Bezzle can
/// stand in the artboard's scene exactly as the browser shows them, which it lays flat, and why.
///
/// The reader hands over, for each element touched by depth, how the browser draws it (`w3`) and
/// how it stands in its 3D context before that is drawn flat into the plane of the element the
/// context belongs to (`c3`, `pl`). An element stands in the scene where that plane lies in the
/// page and what draws the context is the artboard's own eye (`Eye.stage`): taken back from the
/// page by that eye, its plane is then only turned, moved and stretched, which Bezzle says as a
/// layer's tilt, swing, lift and turn, its stretch kept in its flat matrix as before. Where the
/// context is drawn into an element turned in depth, a card, what it holds lies flat in the
/// card's plane. Whatever does not come out so, or whose corners would not land within half a
/// pixel of where the browser has them, keeps the flat matrix it always had, and is told.
nonisolated enum WebDepth {
    /// Why an element turned in depth by a transform of its own is drawn flat after all.
    enum Flat: Hashable {
        /// Seen through a perspective other than the artboard's eye, or as near the eye as no
        /// layer is held.
        case perspective
        /// Slanted out of square in depth, which no layer is.
        case slanted
        /// Seen through no perspective at all, so the page draws it flat too.
        case unseen
    }

    struct Prepared {
        /// The page with the flat matrices of what stands in depth laid into their own planes.
        var root: WebItem
        /// Where each element in depth stands, by its id, which its words and the inline boxes
        /// behind them share.
        var stands: [Int: WebStand] = [:]
        var flat: [Flat: Int] = [:]
        /// How many faces turned away from the eye the page hides.
        var hiddenBacks = 0
    }

    /// The plane of an element's box as it lies in the scene: a point across and down it, as the
    /// page is laid out, stands at `a1` times across, `a2` times down and `t`; its face points
    /// along `normal`.
    struct Plane {
        var a1: ScenePoint
        var a2: ScenePoint
        var t: ScenePoint
        var normal = ScenePoint(z: 1)

        /// The page itself.
        static let page = Plane(a1: ScenePoint(x: 1), a2: ScenePoint(y: 1), t: ScenePoint())

        /// A flat picture of the page moved in the page.
        init(_ m: CGAffineTransform) {
            a1 = ScenePoint(x: Double(m.a), y: Double(m.b))
            a2 = ScenePoint(x: Double(m.c), y: Double(m.d))
            t = ScenePoint(x: Double(m.tx), y: Double(m.ty))
        }

        init(a1: ScenePoint, a2: ScenePoint, t: ScenePoint, normal: ScenePoint = ScenePoint(z: 1)) {
            self.a1 = a1
            self.a2 = a2
            self.t = t
            self.normal = normal
        }

        /// A flat picture of this plane laid in it.
        func after(_ m: CGAffineTransform) -> Plane {
            Plane(a1: a1 * Double(m.a) + a2 * Double(m.b), a2: a1 * Double(m.c) + a2 * Double(m.d),
                  t: a1 * Double(m.tx) + a2 * Double(m.ty) + t, normal: normal)
        }

        /// As a flat picture of the page, where it lies in the page.
        var picture: CGAffineTransform {
            CGAffineTransform(a: CGFloat(a1.x), b: CGFloat(a1.y), c: CGFloat(a2.x), d: CGFloat(a2.y), tx: CGFloat(t.x), ty: CGFloat(t.y))
        }

        /// The scene as this plane, lying in the page, holds it, where it is no more than moved,
        /// turned and scaled alike both ways: then what stands up off it is scaled as much.
        var similarity: WebMatrix? {
            let s = a1.length
            guard s > 1e-9, abs(a1.z) < 1e-4 * s, abs(a2.z) < 1e-4 * s, abs(t.z) < 1e-3 else { return nil }
            guard abs(a2.length - s) < 1e-4 * s, abs(a1.dot(a2)) < 1e-4 * s * s else { return nil }
            return WebMatrix(columns: [a1.x, a1.y, 0, 0, a2.x, a2.y, 0, 0, 0, 0, s, 0, t.x, t.y, 0, 1])
        }
    }

    /// A number read off a page, whose computed matrices carry six figures: what is a round
    /// hundredth but for those is that hundredth, so a card turned 35° there is turned 35° here.
    static func tidy(_ v: Double) -> Double {
        let r = (v * 100).rounded() / 100
        return abs(r - v) < 1e-3 ? (r == 0 ? 0 : r) : v
    }

    /// A flat matrix tidied so: its turn and its place to round hundredths, and its stretch and
    /// slant to what they are but for the last figures.
    static func tidied(_ m: CGAffineTransform) -> CGAffineTransform {
        let a = Double(m.a), b = Double(m.b), c = Double(m.c), d = Double(m.d)
        let turn = tidy(atan2(b, a) * 180 / .pi) * .pi / 180
        let cs = cos(turn), sn = sin(turn)
        func snap(_ v: Double) -> Double {
            let r = (v * 1e4).rounded() / 1e4
            return abs(r - v) < 1e-5 ? r : v
        }
        // Turned back, it is stretched along its own sides and slanted.
        let sx = snap(cs * a + sn * b), k = snap(cs * c + sn * d), sy = snap(cs * d - sn * c)
        return CGAffineTransform(a: CGFloat(sx * cs), b: CGFloat(sx * sn), c: CGFloat(k * cs - sy * sn), d: CGFloat(k * sn + sy * cs),
                                 tx: CGFloat(tidy(Double(m.tx))), ty: CGFloat(tidy(Double(m.ty))))
    }

    /// A plane taken back into the scene: where the page as laid out stands by `m`, if that
    /// leaves it a flat picture turned and moved in the scene, which no perspective bends.
    static func plane(_ m: WebMatrix, reach: Double) -> Plane? {
        guard m.even(within: reach) else { return nil }
        let w = m[3, 3]
        let a1 = ScenePoint(x: m[0, 0] / w, y: m[1, 0] / w, z: m[2, 0] / w)
        let a2 = ScenePoint(x: m[0, 1] / w, y: m[1, 1] / w, z: m[2, 1] / w)
        let up = ScenePoint(x: m[0, 2] / w, y: m[1, 2] / w, z: m[2, 2] / w)
        var normal = a1.cross(a2)
        if normal.dot(up) < 0 { normal = normal * -1 }
        return Plane(a1: a1, a2: a2, t: ScenePoint(x: m[0, 3] / w, y: m[1, 3] / w, z: m[2, 3] / w), normal: normal)
    }

    /// A plane as Bezzle stands a layer: laid out flat by `flat`, tipped and swung in the model's
    /// order (`Spin(Transform3D)`, the nearer to `near` of the two ways of saying it), its face
    /// toward the plane's, and moved; whether `flat` is slanted, which no layer is. Nil for a
    /// plane pressed into a line, which shows nothing.
    static func stand(_ p: Plane, near: (tip: Double, swing: Double)) -> (stand: WebStand, flat: CGAffineTransform, slanted: Bool)? {
        let l1 = p.a1.length
        guard l1 > 1e-9 else { return nil }
        let r1 = p.a1 * (1 / l1)
        let rest = p.a2 - r1 * p.a2.dot(r1)
        let l2 = rest.length
        guard l2 > 1e-9 else { return nil }
        var r2 = rest * (1 / l2), r3 = r1.cross(r2)
        // A face turned over in its own plane is a flip in its flat matrix, not a turn in depth.
        if r3.dot(p.normal) < 0 {
            r2 = r2 * -1
            r3 = r3 * -1
        }
        let turn = Spin(a: r1.x, b: r2.x, c: r3.x, d: r1.y, e: r2.y, f: r3.y, g: r1.z, h: r2.z, i: r3.z)
        let angles = turn.angles(near: near)
        let tip = tidy(angles.tip), swing = tidy(angles.swing)
        let spin = Spin(Transform3D(x: tip, y: swing)), back = spin.back
        // What is left of the turn, a turn in its own plane, and its stretch, are its flat matrix.
        let n = spin.facing, foot = n * n.dot(p.t)
        let base = ScenePoint(x: tidy(foot.x), y: tidy(foot.y), z: tidy(foot.z))
        let u = back(p.a1), v = back(p.a2), o = back(p.t - base)
        let flat = CGAffineTransform(a: CGFloat(u.x), b: CGFloat(u.y), c: CGFloat(v.x), d: CGFloat(v.y), tx: CGFloat(o.x), ty: CGFloat(o.y))
        return (WebStand(tip: tip, swing: swing, base: base), tidied(flat), abs(r1.dot(p.a2)) > 0.001 * max(l1, l2, 1))
    }

    /// Whether a layer standing so shows the element's corners where the browser draws them, to
    /// within half a pixel, seen from the artboard's eye as Bezzle sees a layer (`Perspective`):
    /// its middle held no nearer than a layer is, and nothing of it reaching the eye.
    static func agrees(_ s: WebStand, flat: CGAffineTransform, item: WebItem, eye: Eye) -> Bool {
        guard let drawn = WebMatrix(item.w3) else { return false }
        let box = item.box, d = Double(eye.distance), spin = s.spin
        func standing(_ p: CGPoint) -> ScenePoint {
            let f = p.applying(flat)
            return spin(ScenePoint(x: Double(f.x), y: Double(f.y))) + s.base
        }
        guard standing(CGPoint(x: box.midX, y: box.midY)).z <= d * 0.4 else { return false }
        for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)] {
            guard let truth = drawn.shown(corner) else { return false }
            let p = standing(corner)
            guard d - p.z > d * 0.02 else { return false }
            let x = Double(eye.at.x) + d * (p.x - Double(eye.at.x)) / (d - p.z)
            let y = Double(eye.at.y) + d * (p.y - Double(eye.at.y)) / (d - p.z)
            if hypot(x - Double(truth.x), y - Double(truth.y)) > 0.5 { return false }
        }
        return true
    }

    /// What is known of an element for those it holds.
    private struct Known {
        var plane: Plane?
        /// Whether its plane lies in the page, as the page's own: what is drawn into it can
        /// stand in the artboard's scene.
        var page: Bool
        var turn: (tip: Double, swing: Double) = (0, 0)
    }

    /// Reads the page's depth for an artboard of `size`: lays the flat matrix of each element
    /// standing in depth into its own plane, and of each drawn flat into the page as the browser
    /// draws it, and says where each stands.
    static func prepare(_ root: WebItem, size: CGSize) -> Prepared {
        var out = Prepared(root: root)
        let eye = Eye.stage(size)
        let reach = Double(max(size.width, size.height, 1))
        var known: [Int: Known] = [:]

        func visit(_ item: inout WebItem) {
            guard item.t == "el" else { return }
            let was = item.m
            var stand: WebStand?
            if let id = item.id, let c = WebMatrix(item.c3) {
                let parent = item.pl.map { known[$0] ?? Known(plane: nil, page: false) } ?? Known(plane: .page, page: true)
                var placed: (plane: Plane, stand: WebStand?, flat: CGAffineTransform)?
                var why: Flat?
                // Standing in the scene: its context drawn into the page, through the artboard's eye.
                let level = WebStand(tip: 0, swing: 0, base: ScenePoint())
                if parent.page, let lift = parent.plane?.similarity, let plane = Self.plane(WebMatrix.unseeing(eye) * lift * c, reach: reach) {
                    if let s = Self.stand(plane, near: (0, 0)) {
                        if s.slanted {
                            why = .slanted
                        } else if agrees(s.stand, flat: s.flat, item: item, eye: eye) {
                            placed = (plane, s.stand == level ? nil : s.stand, s.flat)
                        } else {
                            why = .perspective
                        }
                    }
                }
                // Drawn flat into the plane of what it lies in, as the page draws it there.
                if placed == nil, let g = c.flat(within: reach), let into = parent.plane {
                    let plane = into.after(g)
                    if parent.page {
                        let flat = tidied(plane.picture)
                        if agrees(level, flat: flat, item: item, eye: eye) { placed = (plane, nil, flat) }
                    } else if let s = Self.stand(plane, near: parent.turn), agrees(s.stand, flat: s.flat, item: item, eye: eye) {
                        placed = (plane, s.stand, s.flat)
                    }
                    if placed != nil, why == nil { why = c.seesInPerspective ? .perspective : .unseen }
                }
                if let placed {
                    known[id] = Known(plane: placed.plane, page: placed.stand == nil, turn: placed.stand.map { ($0.tip, $0.swing) } ?? (0, 0))
                    let f = [placed.flat.a, placed.flat.b, placed.flat.c, placed.flat.d, placed.flat.tx, placed.flat.ty].map { Double($0) }
                    // What lies flat where it always lay keeps the matrix it always had, to the last place.
                    let old = item.matrix ?? .identity
                    let same = zip(f, [old.a, old.b, old.c, old.d, old.tx, old.ty]).allSatisfy { abs($0 - Double($1)) < 1e-3 }
                    if placed.stand != nil || !same { item.m = f == [1, 0, 0, 1, 0, 0] ? nil : f }
                    stand = placed.stand
                    if let stand { out.stands[id] = stand }
                } else {
                    known[id] = Known(plane: nil, page: false)
                    why = why ?? .perspective
                }
                if item.o3 == true, let why { out.flat[why, default: 0] += 1 }
            } else if let id = item.id {
                known[id] = Known(plane: Plane(item.matrix ?? .identity), page: true)
            }
            if item.back == true { out.hiddenBacks += 1 }
            guard var kids = item.kids else { return }
            for k in kids.indices {
                if kids[k].t == "el" {
                    visit(&kids[k])
                    continue
                }
                // Its words and the boxes behind them lie where it does.
                if item.m != was, kids[k].m == was { kids[k].m = item.m }
                if let stand, let id = kids[k].id { out.stands[id] = stand }
            }
            item.kids = kids
        }
        var page = root
        visit(&page)
        out.root = page
        return out
    }
}

nonisolated fileprivate extension ScenePoint {
    static func * (p: ScenePoint, k: Double) -> ScenePoint { ScenePoint(x: p.x * k, y: p.y * k, z: p.z * k) }
    func dot(_ o: ScenePoint) -> Double { x * o.x + y * o.y + z * o.z }
    func cross(_ o: ScenePoint) -> ScenePoint { ScenePoint(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x) }
    var length: Double { sqrt(dot(self)) }
}
