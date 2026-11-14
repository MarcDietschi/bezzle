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
    /// The pictures a drawing draws, kept as long as it is (`CGContext.drawn`).
    public internal(set) var uses: [CGImage] = []
    /// The texts a drawing draws, set by the host, kept as long as it is (`CGContext.texts`).
    public internal(set) var texts: [HostTexts] = []
    /// Pixels made here whose colours are not multiplied by how solid they are, as Core
    /// Graphics' `.last` keeps them.
    public internal(set) var straightAlpha = false

    public init(width: Int, height: Int, source: Source) {
        self.width = width
        self.height = height
        self.source = source
        id = Images.add()
        Images.shared.list.append(self)
    }

    /// Told when a picture is no longer held anywhere, so that a host keeping what it made of it
    /// (Bezzle for Windows' Skia, the browser's page) can let it go too.
    public nonisolated(unsafe) static var released: ((Int) -> Void)?

    deinit { Self.released?(id) }

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
        guard space.numberOfComponents == 4, bitsPerPixel == 32 else {
            self.init(width: width, height: height, source: .pixels(Array(provider.data), bytesPerRow: bytesPerRow, gray: bitsPerPixel == 8))
            let alpha = CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & 0x1F)
            straightAlpha = alpha == .last || alpha == .first
            return
        }
        // Ink, as printing keeps it: shown here in plain sRGB, without the paper's profile.
        var rgb = [UInt8](repeating: 255, count: width * height * 4)
        provider.data.withUnsafeBytes { (ink: UnsafeRawBufferPointer) in
            rgb.withUnsafeMutableBufferPointer { out in
                guard let p = ink.baseAddress?.assumingMemoryBound(to: UInt8.self), ink.count >= bytesPerRow * (height - 1) + width * 4 else { return }
                for y in 0..<height {
                    var x = 0
                    while x < width {
                        let at = y * bytesPerRow + x * 4, to = (y * width + x) * 4
                        let k = 255 - Int(p[at + 3])
                        for c in 0..<3 { out[to + c] = UInt8((255 - Int(p[at + c])) * k / 255) }
                        x += 1
                    }
                }
            }
        }
        self.init(width: width, height: height, source: .pixels(rgb, bytesPerRow: width * 4, gray: false))
    }
}

/// Texts the host has set for the core (a text's lines, a list's markers, the letters of a line
/// for a curve), by their numbers there, held for as long as anything here may still have them
/// drawn: the layout that had them set, and every drawing that draws them (`CGContext.texts`),
/// until it is let go. A host that keeps what it set is then told (`released`) and lets go too:
/// the browser's page listens; Bezzle for Windows does not, and keeps its texts as it did.
nonisolated public final class HostTexts: @unchecked Sendable {
    public internal(set) var ids: [Int]
    public init(_ ids: [Int]) { self.ids = ids.filter { $0 > 0 } }

    public nonisolated(unsafe) static var released: (([Int]) -> Void)?

    deinit { if !ids.isEmpty { Self.released?(ids) } }
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
        /// Blurred by none at `from` growing to `sigma` at `to`, in the source's pixels from its
        /// top left, and as it is past either (Core Image's masked variable blur along a linear
        /// ramp). A page that knows no ramp blurs it evenly.
        case rampBlur(sigma: Double, clamp: Bool, from: CGPoint, to: CGPoint)
        /// Cut to part of it.
        case crop(CGRect)
        /// Drawn through a 3×3 matrix, row by row, into a picture whose top left is `origin` in its pixels.
        case perspective([Double], origin: CGPoint)
        /// A photo developed as the Mac's Developer does it: its haze taken away (above nought) or
        /// laid over, then each colour, as it looks through the sRGB curve, mapped through a cube
        /// `size` steps a side (red changing fastest, then green, then blue, three numbers each),
        /// then clarity, texture and sharpness, each −1…1 as the Mac's kernels take them.
        case develop(cube: [Float], size: Int, dehaze: Double, clarity: Double, texture: Double, sharpness: Double)
        /// Each pixel the lightest (or, below nought, the darkest) within `radius` of it, as Core
        /// Image's morphology filters make it. Worked out here, for pixels made here (Import/).
        case spread(radius: Double)
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
                    case .rampBlur(let sigma, let clamp, let a, let b):
                        return "{\"blur\":\(sigma),\"clamp\":\(clamp),\"ramp\":[\(a.x),\(a.y),\(b.x),\(b.y)]}"
                    case .crop(let r): return "{\"crop\":[\(r.minX),\(r.minY),\(r.width),\(r.height)]}"
                    case .perspective(let m, let origin): return "{\"perspective\":\(Recording.json(m)),\"origin\":[\(origin.x),\(origin.y)]}"
                    case .develop(let cube, let size, let dehaze, let clarity, let texture, let sharpness):
                        return "{\"develop\":{\"cube\":\(Recording.json(cube.map(Double.init))),\"size\":\(size),\"dehaze\":\(dehaze),"
                            + "\"clarity\":\(clarity),\"texture\":\(texture),\"sharpness\":\(sharpness)}}"
                    case .spread(let radius): return "{\"spread\":\(radius)}"
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
