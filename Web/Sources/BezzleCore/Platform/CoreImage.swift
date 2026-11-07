import Foundation

// What Bezzle's shared drawing takes from Core Image, which is a blur and a bend into perspective:
// each picture made here is only a description, made by the page when it is drawn.

nonisolated public struct CIVector: Sendable {
    public let x: CGFloat, y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
}

nonisolated public struct CIColor: Sendable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha }
}

nonisolated public struct CIFormat: Sendable { public static let RGBA8 = CIFormat() }

/// A picture and what is done to it, measured as Core Image measures, in pixels from the bottom left.
nonisolated public final class CIImage: @unchecked Sendable {
    let source: CGImage?
    let changes: [Images.Change]
    public let extent: CGRect
    /// Its edges carry on outward without end.
    let clamped: Bool
    /// A linear gradient from black at `from` to white at `to` (Core Image's pixels from the
    /// bottom left), as a masked variable blur takes its mask; nil for a picture.
    var gradient: (from: CGPoint, to: CGPoint)?

    public init(cgImage: CGImage) {
        source = cgImage
        changes = []
        extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        clamped = false
    }

    init(_ source: CGImage?, _ changes: [Images.Change], extent: CGRect, clamped: Bool) {
        self.source = source; self.changes = changes; self.extent = extent; self.clamped = clamped
    }

    public func clampedToExtent() -> CIImage { CIImage(source, changes, extent: extent, clamped: true) }

    public func applyingGaussianBlur(sigma: Double) -> CIImage {
        CIImage(source, changes + [.blur(sigma: sigma, clamp: clamped)], extent: clamped ? extent : extent.insetBy(dx: -sigma * 3, dy: -sigma * 3), clamped: clamped)
    }

    /// Blurred by none at `from` growing to `sigma` at `to`, in Core Image's pixels from the
    /// bottom left, as the masked variable blur along a linear gradient blurs it.
    func applyingRampBlur(sigma: Double, from: CGPoint, to: CGPoint) -> CIImage {
        let h = CGFloat(source?.height ?? 0)
        let change = Images.Change.rampBlur(sigma: sigma, clamp: clamped, from: CGPoint(x: from.x, y: h - from.y), to: CGPoint(x: to.x, y: h - to.y))
        return CIImage(source, changes + [change], extent: clamped ? extent : extent.insetBy(dx: -sigma * 3, dy: -sigma * 3), clamped: clamped)
    }

    public func cropped(to r: CGRect) -> CIImage { CIImage(source, changes, extent: extent.intersection(r), clamped: false) }

    public func applyingFilter(_ name: String, parameters: [String: Any] = [:]) -> CIImage {
        if name == "CIMorphologyMaximum" || name == "CIMorphologyMinimum" {
            let radius = Double(parameters["inputRadius"] as? CGFloat ?? 0)
            let wider = name == "CIMorphologyMaximum" ? extent.insetBy(dx: -radius, dy: -radius) : extent
            return CIImage(source, changes + [.spread(radius: name == "CIMorphologyMaximum" ? radius : -radius)], extent: wider, clamped: clamped)
        }
        guard name == "CIPerspectiveTransform", let source,
              let tl = parameters["inputTopLeft"] as? CIVector, let tr = parameters["inputTopRight"] as? CIVector,
              let br = parameters["inputBottomRight"] as? CIVector, let bl = parameters["inputBottomLeft"] as? CIVector else { return self }
        // From the picture's own corners, in pixels from the top left, to the corners given, from the bottom left.
        let w = CGFloat(source.width), h = CGFloat(source.height)
        let to = [tl, tr, br, bl].map { CGPoint(x: $0.x, y: h - $0.y) }
        guard let m = Homography.square(from: [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)], to: to) else { return self }
        let xs = to.map(\.x), ys = to.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // Back in Core Image's terms: from the bottom left.
        return CIImage(source, changes + [.perspective(m, origin: .zero)], extent: CGRect(x: box.minX, y: h - box.maxY, width: box.width, height: box.height), clamped: false)
    }

    /// The picture, `rect` of it in Core Image's terms.
    func made(_ rect: CGRect) -> CGImage? {
        guard let source, !rect.isNull, !rect.isInfinite, rect.width >= 1, rect.height >= 1 else { return nil }
        // The page works from the top left: the rectangle's top left there, in the source's pixels.
        let h = CGFloat(source.height)
        let top = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        return CGImage(width: Int(rect.width.rounded()), height: Int(rect.height.rounded()), source: .changed(source, changes + [.crop(top)]))
    }
}

nonisolated public struct CIContextOption: Hashable, Sendable {
    public let name: String
    public static let cacheIntermediates = CIContextOption(name: "cache")
    public static let workingColorSpace = CIContextOption(name: "space")
    public static let useSoftwareRenderer = CIContextOption(name: "software")
}

nonisolated public final class CIContext: @unchecked Sendable {
    public init(options: [CIContextOption: Any]? = nil) {}
    public func createCGImage(_ image: CIImage, from rect: CGRect, format: CIFormat = .RGBA8, colorSpace: CGColorSpace? = nil) -> CGImage? {
        image.made(rect)
    }
    public func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? { image.made(rect) }
}

/// The filters Bezzle's blurs name.
nonisolated public class CIFilter: @unchecked Sendable {
    public var inputImage: CIImage?
    public var outputImage: CIImage? { inputImage }
    public init() {}

    public static func linearGradient() -> LinearGradient { LinearGradient() }
    public static func maskedVariableBlur() -> MaskedVariableBlur { MaskedVariableBlur() }

    public final class LinearGradient: CIFilter, @unchecked Sendable {
        public var point0 = CGPoint.zero, point1 = CGPoint.zero
        public var color0 = CIColor(red: 0, green: 0, blue: 0), color1 = CIColor(red: 1, green: 1, blue: 1)
        public override var outputImage: CIImage? {
            let image = CIImage(nil, [], extent: .infinite, clamped: false)
            image.gradient = (point0, point1)
            return image
        }
    }

    /// Blurred as much as its mask is light: along a linear gradient from black to white, none
    /// at its start growing to `radius` at its end; any other mask blurs it evenly.
    public final class MaskedVariableBlur: CIFilter, @unchecked Sendable {
        public var mask: CIImage?
        public var radius: Float = 0
        public override var outputImage: CIImage? {
            guard let inputImage else { return nil }
            if let g = mask?.gradient { return inputImage.applyingRampBlur(sigma: Double(radius), from: g.from, to: g.to) }
            return inputImage.applyingGaussianBlur(sigma: Double(radius))
        }
    }
}

/// The 3×3 matrix taking four points to four others, row by row, as CanvasKit reads it.
nonisolated public enum Homography {
    public static func square(from a: [CGPoint], to b: [CGPoint]) -> [Double]? {
        // Solve for h0…h7 with h8 = 1: eight equations, two per corner.
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(a[i].x), y = Double(a[i].y), u = Double(b[i].x), v = Double(b[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            guard let pivot = (col..<8).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let f = m[row][col] / m[col][col]
                for k in col..<9 { m[row][k] -= f * m[col][k] }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] } + [1]
    }
}
