@_exported import CoreGraphics

// What Bezzle's shared code takes from AppKit, in the browser.

/// Text Kit draws into the current graphics context; here the renderer's text goes straight
/// into the recording context, so this only carries it.
public final class NSGraphicsContext: @unchecked Sendable {
    public let cgContext: CGContext
    public let isFlipped: Bool
    public nonisolated(unsafe) static var current: NSGraphicsContext?
    public init(cgContext: CGContext, flipped: Bool) {
        self.cgContext = cgContext
        isFlipped = flipped
    }
}

public final class NSColor: @unchecked Sendable {
    public let redComponent: CGFloat, greenComponent: CGFloat, blueComponent: CGFloat, alphaComponent: CGFloat
    public init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        redComponent = r; greenComponent = g; blueComponent = b; alphaComponent = a
    }
    public convenience init(red r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(white w: CGFloat, alpha a: CGFloat) { self.init(srgbRed: w, green: w, blue: w, alpha: a) }
    public convenience init?(cgColor c: CGColor) {
        guard let k = c.components else { return nil }
        if k.count == 2 { self.init(white: k[0], alpha: k[1]) } else { self.init(srgbRed: k[0], green: k[1], blue: k[2], alpha: k[3]) }
    }
    public var usingSRGB: NSColor? { self }
    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? { self }
    public var cgColor: CGColor { CGColor(red: redComponent, green: greenComponent, blueComponent, alpha: alphaComponent) }
    public func withAlphaComponent(_ a: CGFloat) -> NSColor { NSColor(srgbRed: redComponent, green: greenComponent, blue: blueComponent, alpha: a) }
    public func getRed(_ r: UnsafeMutablePointer<CGFloat>?, green g: UnsafeMutablePointer<CGFloat>?, blue b: UnsafeMutablePointer<CGFloat>?, alpha a: UnsafeMutablePointer<CGFloat>?) {
        r?.pointee = redComponent; g?.pointee = greenComponent; b?.pointee = blueComponent; a?.pointee = alphaComponent
    }
    public static let clear = NSColor(white: 0, alpha: 0)
    public static let black = NSColor(white: 0, alpha: 1)
    public static let white = NSColor(white: 1, alpha: 1)
}

public final class NSColorSpace: @unchecked Sendable {
    public static let sRGB = NSColorSpace()
    public static let extendedSRGB = NSColorSpace()
    public static let displayP3 = NSColorSpace()
}

extension CGColor {
    convenience init(red: CGFloat, green: CGFloat, _ blue: CGFloat, alpha: CGFloat) { self.init(red: red, green: green, blue: blue, alpha: alpha) }
}

/// The fonts the page has, by family; see `Fonts` in the web build.
public final class NSFontManager: @unchecked Sendable {
    public static let shared = NSFontManager()
    public nonisolated(unsafe) var families: [String: [String]] = [:]
    public var availableFontFamilies: [String] { families.keys.sorted() }
    public func availableMembers(ofFontFamily family: String) -> [[Any]]? {
        families[family].map { $0.map { [family + "-" + $0, $0, 5, 0] } }
    }
}
