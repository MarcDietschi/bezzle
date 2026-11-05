import Foundation

/// A picture, as the page will make it when it is drawn: one of the design's pictures it has
/// read, a drawing recorded into an offscreen context, or another picture changed (blurred,
/// bent into perspective, cut to part of it). All of them are listed in `Images`, which goes to
/// the page with the drawing.
nonisolated public final class CGImage: @unchecked Sendable, Equatable, Hashable {
    public let id: Int
    public let width: Int
    public let height: Int

    public enum Source {
        /// A picture the page has read, by its own number.
        case asset(Int)
        /// What was drawn into an offscreen context, in its own pixels.
        case picture([Double])
        /// Another picture, changed: see `Images.Change`.
        case changed(CGImage, [Images.Change])
        /// Pixels made here.
        case pixels([UInt8], bytesPerRow: Int, gray: Bool)
    }
    public let source: Source

    public init(width: Int, height: Int, source: Source) {
        self.width = width
        self.height = height
        self.source = source
        id = Images.add()
        Images.shared.list.append(self)
    }

    public static func == (a: CGImage, b: CGImage) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var bitsPerComponent: Int { 8 }
    public var bitsPerPixel: Int { 32 }
    public var bytesPerRow: Int { width * 4 }
    public var colorSpace: CGColorSpace? { CGColorSpaceCreateDeviceRGB() }
    public var alphaInfo: CGImageAlphaInfo { .premultipliedLast }
    public var bitmapInfo: CGBitmapInfo { CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue) }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return CGImage(width: Int(r.width), height: Int(r.height), source: .changed(self, [.crop(r)]))
    }

    /// Pixels in rows from the top, RGBA, `bytesPerRow` apart.
    public convenience init?(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int,
                             space: CGColorSpace, bitmapInfo: CGBitmapInfo, provider: CGDataProvider,
                             decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool, intent: CGColorRenderingIntent) {
        guard width > 0, height > 0, bitsPerComponent == 8 else { return nil }
        self.init(width: width, height: height, source: .pixels(Array(provider.data), bytesPerRow: bytesPerRow, gray: bitsPerPixel == 8))
    }
}

nonisolated public final class CGDataProvider: @unchecked Sendable {
    public let data: Data
    public init?(data: CFData) { self.data = data }
}

/// Every picture made for one drawing, in the order made.
nonisolated public final class Images: @unchecked Sendable {
    public nonisolated(unsafe) static let shared = Images()
    public var list: [CGImage] = []
    private var next = 1

    static func add() -> Int {
        defer { shared.next += 1 }
        return shared.next
    }

    /// How a picture is made from another, in its pixels counted from its top left.
    public enum Change {
        /// Blurred by `sigma` pixels; with `clamp`, its edges carry on outward first.
        case blur(sigma: Double, clamp: Bool)
        /// Cut to part of it.
        case crop(CGRect)
        /// Drawn through a 3×3 matrix, row by row, into a picture whose top left is `origin` in its pixels.
        case perspective([Double], origin: CGPoint)
    }

    /// The pictures from `first` on, as the page reads them.
    public func json(from first: Int = 0) -> String {
        var parts: [String] = []
        for image in list where image.id >= first {
            var s = "{\"id\":\(image.id),\"w\":\(image.width),\"h\":\(image.height),"
            switch image.source {
            case .asset(let n):
                s += "\"asset\":\(n)"
            case .picture(let commands):
                s += "\"picture\":" + Recording.json(commands)
            case .changed(let from, let changes):
                s += "\"from\":\(from.id),\"changes\":["
                s += changes.map { change -> String in
                    switch change {
                    case .blur(let sigma, let clamp): return "{\"blur\":\(sigma),\"clamp\":\(clamp)}"
                    case .crop(let r): return "{\"crop\":[\(r.minX),\(r.minY),\(r.width),\(r.height)]}"
                    case .perspective(let m, let origin): return "{\"perspective\":\(Recording.json(m)),\"origin\":[\(origin.x),\(origin.y)]}"
                    }
                }.joined(separator: ",") + "]"
            case .pixels(let bytes, let row, let gray):
                s += "\"pixels\":\"\(Data(bytes).base64EncodedString())\",\"row\":\(row),\"gray\":\(gray)"
            }
            parts.append(s + "}")
        }
        return "[" + parts.joined(separator: ",") + "]"
    }
}

nonisolated public enum Recording {
    public static func json(_ values: [Double]) -> String {
        var s = "["
        s.reserveCapacity(values.count * 6)
        for (i, v) in values.enumerated() {
            if i > 0 { s += "," }
            if v.isFinite {
                if v == v.rounded(), abs(v) < 1e15 { s += String(Int(v)) } else { s += String(Float(v)) }
            } else {
                s += "0"
            }
        }
        return s + "]"
    }
}
