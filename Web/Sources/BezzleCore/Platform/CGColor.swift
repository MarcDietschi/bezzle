import Foundation

nonisolated public final class CGColorSpace: @unchecked Sendable, Equatable {
    public let name: CFString?
    public init?(name: CFString) { self.name = name }
    init(named: String) { name = named }
    public static func == (a: CGColorSpace, b: CGColorSpace) -> Bool { a.name == b.name }

    public static let sRGB: CFString = "kCGColorSpaceSRGB"
    public static let extendedSRGB: CFString = "kCGColorSpaceExtendedSRGB"
    public static let linearSRGB: CFString = "kCGColorSpaceLinearSRGB"
    public static let displayP3: CFString = "kCGColorSpaceDisplayP3"
    public static let genericGrayGamma2_2: CFString = "kCGColorSpaceGenericGrayGamma2_2"
    public static let linearGray: CFString = "kCGColorSpaceLinearGray"
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear"
    /// Printing's ink, as a Photoshop document can keep its colours.
    public static let genericCMYK: CFString = "kCGColorSpaceGenericCMYK"

    public var numberOfComponents: Int {
        name == Self.genericGrayGamma2_2 || name == Self.linearGray ? 1 : name == Self.genericCMYK ? 4 : 3
    }
}

nonisolated public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(named: CGColorSpace.sRGB) }
nonisolated public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(named: CGColorSpace.genericGrayGamma2_2) }

/// A colour in sRGB, as everything here is drawn.
nonisolated public final class CGColor: Equatable, Hashable, @unchecked Sendable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat
    public let alpha: CGFloat
    let gray: Bool

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; gray = false
    }
    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    public init(gray: CGFloat, alpha: CGFloat) {
        red = gray; green = gray; blue = gray; self.alpha = alpha; self.gray = true
    }
    public convenience init(genericGrayGamma2_2Gray gray: CGFloat, alpha: CGFloat) { self.init(gray: gray, alpha: alpha) }
    public convenience init?(colorSpace: CGColorSpace, components: UnsafePointer<CGFloat>) {
        if colorSpace.numberOfComponents == 1 { self.init(gray: components[0], alpha: components[1]) } else {
            self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        }
    }

    public static let white = CGColor(gray: 1, alpha: 1)
    public static let black = CGColor(gray: 0, alpha: 1)
    public static let clear = CGColor(gray: 0, alpha: 0)

    public var components: [CGFloat]? { gray ? [red, alpha] : [red, green, blue, alpha] }
    public var numberOfComponents: Int { gray ? 2 : 4 }
    public var colorSpace: CGColorSpace? { gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB() }

    public func copy(alpha: CGFloat) -> CGColor? {
        gray ? CGColor(gray: red, alpha: alpha) : CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public func converted(to space: CGColorSpace, intent: CGColorRenderingIntent, options: CFDictionary?) -> CGColor? {
        space.numberOfComponents == 1 ? CGColor(gray: 0.299 * red + 0.587 * green + 0.114 * blue, alpha: alpha)
            : CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static func == (a: CGColor, b: CGColor) -> Bool {
        a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha
    }
    public func hash(into h: inout Hasher) { h.combine(red); h.combine(green); h.combine(blue); h.combine(alpha) }

    var rgba: [Double] { [Double(red), Double(green), Double(blue), Double(alpha)] }
}

nonisolated public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent, absoluteColorimetric, relativeColorimetric, perceptual, saturation
}

nonisolated public struct CGGradientDrawingOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let drawsBeforeStartLocation = CGGradientDrawingOptions(rawValue: 1)
    public static let drawsAfterEndLocation = CGGradientDrawingOptions(rawValue: 2)
}

nonisolated public final class CGGradient: @unchecked Sendable {
    let colors: [CGColor]
    let locations: [CGFloat]

    public init?(colorsSpace: CGColorSpace?, colors: CFArray, locations: UnsafePointer<CGFloat>?) {
        let list = colors.compactMap { $0 as? CGColor }
        guard !list.isEmpty else { return nil }
        self.colors = list
        if let locations {
            self.locations = (0..<list.count).map { locations[$0] }
        } else {
            self.locations = list.count == 1 ? [0] : (0..<list.count).map { CGFloat($0) / CGFloat(list.count - 1) }
        }
    }

    public convenience init?(colorsSpace: CGColorSpace?, colors: CFArray, locations: [CGFloat]?) {
        if let locations {
            let copied = locations
            self.init(colorsSpace: colorsSpace, colors: colors, locations: copied.withUnsafeBufferPointer { UnsafePointer($0.baseAddress!) })
        } else {
            self.init(colorsSpace: colorsSpace, colors: colors, locations: nil as UnsafePointer<CGFloat>?)
        }
    }
}

nonisolated public enum CGBlendMode: Int32, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight,
         difference, exclusion, hue, saturation, color, luminosity, clear, copy, sourceIn, sourceOut, sourceAtop,
         destinationOver, destinationIn, destinationOut, destinationAtop, xor, plusDarker, plusLighter
}

nonisolated public enum CGInterpolationQuality: Int32, Sendable { case `default`, none, low, high, medium }
nonisolated public enum CGPathDrawingMode: Int32, Sendable { case fill, eoFill, stroke, fillStroke, eoFillStroke }
nonisolated public enum CGTextDrawingMode: Int32, Sendable { case fill, stroke, fillStroke, invisible, fillClip, strokeClip, fillStrokeClip, clip }

nonisolated public enum CGImageAlphaInfo: UInt32, Sendable {
    case none, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

nonisolated public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrderDefault = CGBitmapInfo(rawValue: 0)
}
