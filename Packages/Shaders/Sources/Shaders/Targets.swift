import Foundation

/// Numbers a page gave as a texture (texImage2D with a typed array), or what a target held when
/// the page was recorded: read by samplers as WebGL reads them. Kept by identity, as pictures are:
/// the same numbers are uploaded once.
public final class ShaderData: @unchecked Sendable {
    /// What a texel holds. LUMINANCE reads as its value three times and 1, ALPHA as nought three
    /// times and its value, LUMINANCE_ALPHA as both.
    public enum Format: Sendable, Hashable {
        case rgba8, rg8, r8, luminance8, alpha8, luminanceAlpha8
        case rgba16Float, rg16Float, r16Float
        case rgba32Float, rg32Float, r32Float

        public var bytesPerTexel: Int {
            switch self {
            case .r8, .luminance8, .alpha8: 1
            case .rg8, .luminanceAlpha8, .r16Float: 2
            case .rgba8, .rg16Float, .r32Float: 4
            case .rgba16Float, .rg32Float: 8
            case .rgba32Float: 16
            }
        }

        /// Whether a pass can draw into it.
        public var drawn: Bool {
            switch self {
            case .luminance8, .alpha8, .luminanceAlpha8: false
            default: true
            }
        }
    }

    public let width: Int
    public let height: Int
    public let format: Format
    /// Texel after texel, rows from t = 0 up (the first row texImage2D was given, the bottom
    /// row readPixels answers with), `width` times `height` times the format's bytes.
    public let bytes: [UInt8]

    /// nil when `bytes` are not as many as the size and the format take.
    public init?(width: Int, height: Int, format: Format, bytes: [UInt8]) {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              bytes.count == width * height * format.bytesPerTexel else { return nil }
        self.width = width
        self.height = height
        self.format = format
        self.bytes = bytes
    }
}

extension ShaderData.Format {
    enum Kind { case byte, half, float }

    var kind: Kind {
        switch self {
        case .rgba8, .rg8, .r8, .luminance8, .alpha8, .luminanceAlpha8: .byte
        case .rgba16Float, .rg16Float, .r16Float: .half
        case .rgba32Float, .rg32Float, .r32Float: .float
        }
    }

    /// How many numbers a texel holds.
    var channels: Int {
        switch self {
        case .r8, .luminance8, .alpha8, .r16Float, .r32Float: 1
        case .rg8, .luminanceAlpha8, .rg16Float, .rg32Float: 2
        case .rgba8, .rgba16Float, .rgba32Float: 4
        }
    }
}

extension ShaderData {
    /// Its texels in another format, as a sampler would read them and a draw would write them
    /// there: red, green, blue and alpha as WebGL reads this format, the first of them kept that
    /// the other holds. The same bytes when the format is the same.
    func bytes(as other: Format) -> [UInt8] {
        if other == format { return bytes }
        let count = width * height
        let from = format.channels, to = other.channels
        var out = [UInt8](repeating: 0, count: count * other.bytesPerTexel)
        bytes.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                var texel: [Float] = [0, 0, 0, 1]
                for i in 0..<count {
                    // As WebGL reads it.
                    var numbers: [Float] = [0, 0, 0, 0]
                    for c in 0..<from {
                        switch format.kind {
                        case .byte: numbers[c] = Float(source[i * from + c]) / 255
                        case .half: numbers[c] = Half.float(source.loadUnaligned(fromByteOffset: (i * from + c) * 2, as: UInt16.self))
                        case .float: numbers[c] = source.loadUnaligned(fromByteOffset: (i * from + c) * 4, as: Float.self)
                        }
                    }
                    switch format {
                    case .luminance8: texel = [numbers[0], numbers[0], numbers[0], 1]
                    case .alpha8: texel = [0, 0, 0, numbers[0]]
                    case .luminanceAlpha8: texel = [numbers[0], numbers[0], numbers[0], numbers[1]]
                    default:
                        texel = [numbers[0], from > 1 ? numbers[1] : 0, from > 2 ? numbers[2] : 0, from > 3 ? numbers[3] : 1]
                    }
                    for c in 0..<to {
                        let value = other == .alpha8 ? texel[3] : other == .luminanceAlpha8 && c == 1 ? texel[3] : texel[c]
                        switch other.kind {
                        case .byte: target[i * to + c] = UInt8(max(0, min(255, (value * 255).rounded())))
                        case .half: target.storeBytes(of: Half.bits(value), toByteOffset: (i * to + c) * 2, as: UInt16.self)
                        case .float: target.storeBytes(of: value, toByteOffset: (i * to + c) * 4, as: Float.self)
                        }
                    }
                }
            }
        }
        return out
    }
}

/// Half floats, 16 bits, as textures keep them: Swift's own Float16 is not on every Mac.
enum Half {
    static func float(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            // Subnormal: mantissa times 2 to the -24.
            let value = Float(mantissa) * 5.9604645e-08
            return sign != 0 ? -value : value
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | (mantissa << 13))
    }

    static func bits(_ value: Float) -> UInt16 {
        let raw = value.bitPattern
        let sign = UInt16((raw >> 16) & 0x8000)
        let exponent = Int((raw >> 23) & 0xFF) - 127
        let mantissa = raw & 0x7F_FFFF
        if exponent == 128 { return sign | 0x7C00 | (mantissa != 0 ? 0x200 : 0) }   // infinity, not a number
        if exponent > 15 { return sign | 0x7C00 }                                   // too large: infinity
        if exponent >= -14 {
            // Rounded to the nearest, ties to even; a carry runs into the exponent as it should.
            var half = UInt32(exponent + 15) << 10 | (mantissa >> 13)
            let rest = mantissa & 0x1FFF
            if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        if exponent >= -25 {
            // Subnormal.
            let full = mantissa | 0x80_0000
            let shift = UInt32(-exponent - 14 + 13)
            var half = full >> shift
            let rest = full & ((1 << shift) - 1), middle = UInt32(1) << (shift - 1)
            if rest > middle || (rest == middle && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        return sign
    }
}

/// A texture a page drew into through a framebuffer, for later draws to read.
public struct ShaderTarget: Sendable {
    public var width: Int
    public var height: Int
    public var format: ShaderData.Format
    /// An RGB texture: its alpha reads 1 whatever is drawn.
    public var opaque: Bool
    /// Has smaller copies of itself, made when a pass asks for them (`ShaderPass.mipmaps`).
    public var mipmapped: Bool
    /// Keeps what it holds from one frame to the next (feedback, a simulation's state): the frame
    /// then depends on the frames before it, and is drawn step by step (`ShaderFrame.Identity`).
    public var keeps: Bool
    /// What it holds before the first step; nothing (nought everywhere) when nil.
    public var contents: ShaderData?
    /// Sized by the canvas, so drawn larger where the output is: a blur chain's and a
    /// post-processing pass's textures, which stay as sharp as the canvas however near it is
    /// looked at. Never in a frame with targets that keep, whose steps must come out the same
    /// at every size.
    public var scales: Bool

    public init(width: Int, height: Int, format: ShaderData.Format = .rgba8, opaque: Bool = false, mipmapped: Bool = false,
                keeps: Bool = false, contents: ShaderData? = nil, scales: Bool = false) {
        self.width = width
        self.height = height
        self.format = format
        self.opaque = opaque
        self.mipmapped = mipmapped
        self.keeps = keeps
        self.contents = contents
        self.scales = scales
    }
}

/// What a page drew into one framebuffer before it bound another or cleared it whole: its draws
/// in order, into targets or onto the canvas.
public struct ShaderPass: Sendable {
    /// The targets it draws into, in drawBuffers' order; none for the canvas.
    public var colors: [Int]
    /// Which depth and stencil buffer it tests against, by a number the frame's passes into
    /// targets share (a framebuffer's depth attachment); nil for none, where every depth and
    /// stencil test passes. The canvas has its own.
    public var depth: Int?
    /// What it is cleared to before its draws; nil keeps what is there (what an earlier pass
    /// drew, or for a target that keeps, what the frame before left; else nothing).
    public var clearColor: [Float]?
    public var clearDepth: Float?
    public var clearStencil: Int?
    public var draws: [ShaderDraw]
    /// The targets whose smaller copies are made after its draws (generateMipmap).
    public var mipmaps: [Int]

    public init(colors: [Int] = [], depth: Int? = nil, clearColor: [Float]? = nil, clearDepth: Float? = nil,
                clearStencil: Int? = nil, draws: [ShaderDraw], mipmaps: [Int] = []) {
        self.colors = colors
        self.depth = depth
        self.clearColor = clearColor
        self.clearDepth = clearDepth
        self.clearStencil = clearStencil
        self.draws = draws
        self.mipmaps = mipmaps
    }

    /// Whether it draws onto the canvas.
    public var ontoCanvas: Bool { colors.isEmpty }
}

extension ShaderFrame {
    /// Everything it draws, pass by pass: `passes`, or the one pass onto the canvas that `clear`
    /// and `draws` are.
    public var everyPass: [ShaderPass] {
        passes.isEmpty ? [ShaderPass(clearColor: clear ?? [0, 0, 0, 0], draws: draws)] : passes
    }

    /// Whether any of its targets keeps what the frame before left.
    public var keeps: Bool { targets.contains { $0.keeps } }

    /// Whether a pass onto the canvas tests depth or stencil, so that the canvas needs the buffer.
    var canvasTestsDepth: Bool {
        everyPass.contains { pass in
            pass.ontoCanvas && (pass.clearDepth != nil || pass.clearStencil != nil
                                || pass.draws.contains { $0.depth != nil || $0.stencil != nil })
        }
    }

    /// Why it cannot be drawn, when what its passes name is not there.
    func fault() -> String? {
        for (index, target) in targets.enumerated() {
            guard target.width > 0, target.height > 0, target.width <= 16384, target.height <= 16384 else {
                return "Target \(index) cannot be \(target.width) by \(target.height)."
            }
            guard target.format.drawn else { return "Target \(index) is of a kind nothing is drawn into." }
            if let contents = target.contents, contents.width != target.width || contents.height != target.height {
                return "Target \(index) is \(target.width) by \(target.height) and starts from \(contents.width) by \(contents.height)."
            }
        }
        for pass in passes {
            guard pass.colors.count <= 4 else { return "A pass draws into more than four targets." }
            for index in pass.colors + pass.mipmaps where !targets.indices.contains(index) {
                return "A pass draws into target \(index), which the frame does not have."
            }
            if let first = pass.colors.first {
                let size = (targets[first].width, targets[first].height)
                for index in pass.colors where (targets[index].width, targets[index].height) != size {
                    return "A pass draws into targets of different sizes."
                }
            }
            for draw in pass.draws {
                for (name, index) in draw.targets where !targets.indices.contains(index) {
                    return "\(name) reads target \(index), which the frame does not have."
                }
            }
        }
        if passes.isEmpty {
            for draw in draws {
                for (name, index) in draw.targets where !targets.indices.contains(index) {
                    return "\(name) reads target \(index), which the frame does not have."
                }
            }
        }
        return nil
    }

    /// What it has beyond draws onto a cleared canvas with blending alone, in a word: nil when a
    /// back end that knows only those draws it rightly. For a back end to refuse the rest by
    /// name until it draws it.
    var beyondPlainDraws: String? {
        if !targets.isEmpty { return "passes into textures" }
        if passes.count > 1 || passes.contains(where: { !$0.ontoCanvas || $0.clearColor == nil }) {
            return "several passes"
        }
        for draw in everyPass.flatMap(\.draws) {
            if !draw.targets.isEmpty { return "passes into textures" }
            if !draw.data.isEmpty { return "textures of numbers" }
            if !draw.decodes.isEmpty { return "sRGB textures" }
            if draw.depth != nil || draw.offset != nil { return "the depth test" }
            if draw.stencil != nil { return "the stencil test" }
            if draw.cull != nil { return "faces left out" }
            if draw.channels != .all { return "colorMask" }
            if draw.scissor != nil { return "the scissor box" }
            if draw.instances != 1 || draw.attributes.values.contains(where: { $0.divisor != 0 }) { return "instances" }
        }
        return nil
    }
}

/// Of a recording whose frames build on the frames before them, the state after every so many
/// steps is kept, so that going back to a step draws no more than these on the way.
enum Feedback {
    static let stride = 32
}

/// How much larger than a target's own size it is drawn for an output `scale` times the canvas:
/// the next power of two, so that zooming makes few sizes, and no larger than keeps its longer
/// side under 8192.
func targetScale(_ scale: Double, for frame: ShaderFrame) -> Int {
    guard !frame.keeps, scale > 1, frame.targets.contains(where: { $0.scales }) else { return 1 }
    var factor = 1
    while Double(factor) < scale && factor < 16 { factor *= 2 }
    let longest = frame.targets.filter { $0.scales }.map { max($0.width, $0.height) }.max() ?? 1
    while factor > 1 && longest * factor > 8192 { factor /= 2 }
    return factor
}
