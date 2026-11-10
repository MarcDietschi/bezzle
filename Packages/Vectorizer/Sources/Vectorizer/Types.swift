import Foundation

/// A picture to trace: 8 bits each of red, green, blue and alpha for every pixel, rows from the
/// top, the colours in sRGB and not multiplied by their alpha.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// A colour in sRGB, each part 0…255.
public struct Tint: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }
}

/// A place in the picture, in its pixels: 0,0 its top left corner, y going down.
public struct Spot: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x; self.y = y
    }
}

/// One stretch of an outline, from where the last ended.
public enum Stretch: Hashable, Sendable {
    case line(Spot)
    case curve(Spot, Spot, Spot)

    public var end: Spot {
        switch self {
        case .line(let p): p
        case .curve(_, _, let p): p
        }
    }
}

/// A closed outline: it starts at `start`, and its last stretch ends there.
public struct Outline: Hashable, Sendable {
    public var start: Spot
    public var stretches: [Stretch]

    public init(start: Spot, stretches: [Stretch]) {
        self.start = start
        self.stretches = stretches
    }
}

/// A shape found to be one a design app has by name, so it can be made as that rather than as a
/// path. Angles are in degrees clockwise on screen.
public enum Figure: Hashable, Sendable {
    case ellipse(center: Spot, radiusX: Double, radiusY: Double, angle: Double)
    case rectangle(center: Spot, width: Double, height: Double, radius: Double, angle: Double)
}

/// Colours running across a shape instead of one: from `from` at `start` to `to` at `end`.
public struct Blend: Hashable, Sendable {
    public var start: Spot
    public var end: Spot
    public var stops: [Stop]

    public struct Stop: Hashable, Sendable {
        public var offset: Double
        public var color: Tint
    }
}

/// One shape of the tracing: its colour and its outlines, filled even-odd, so the outlines
/// inside the first are holes.
public struct Shape: Hashable, Sendable {
    public var color: Tint
    public var outlines: [Outline]
    /// The same shape as a rectangle or an ellipse, when it is one.
    public var figure: Figure?
    /// Colours running across it, when it is not one colour.
    public var blend: Blend?
    /// How much of the picture it covers, in pixels, as it shows: not counting what lies under
    /// the shapes over it.
    public var area: Double
}

/// How a picture is traced.
public struct Settings: Hashable, Sendable {
    /// How many colours at most; nil finds how many the picture has.
    public var colors: Int?
    /// How much of the picture's small things are kept, 0…1: more colours, smaller shapes.
    public var detail: Double
    /// How closely the outlines follow every turn, 0, to how calm they run, 1.
    public var smoothing: Double
    /// Quick and coarser, for showing while a setting is dragged.
    public var draft: Bool

    public init(colors: Int? = nil, detail: Double = 0.5, smoothing: Double = 0.5, draft: Bool = false) {
        self.colors = colors
        self.detail = detail
        self.smoothing = smoothing
        self.draft = draft
    }
}

/// A picture as shapes, the bottom one first: each lies a little under those over it that it
/// touches, so no gap shows between them however they are drawn.
public struct Tracing: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var shapes: [Shape]
    /// The colours found, the most of first.
    public var palette: [Tint]
    /// Whether the picture was taken for pixel art, and traced square by square.
    public var pixelArt: Bool
}
