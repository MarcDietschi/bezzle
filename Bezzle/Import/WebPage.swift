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
