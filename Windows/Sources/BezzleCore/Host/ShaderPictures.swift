import Foundation
import CBezzleHost
import Shaders

// Shader fills are drawn by the Mac's own ShaderPainting (Bezzle/Canvas/ShaderPainting.swift,
// linked beside this file): the region a tile shows, its pixel density, the cache of programs
// that do not build. It asks the engine (Packages/Shaders, which draws with Direct3D here) in the
// Mac's types, Core Graphics' sizes, rectangles and pictures, which in the core are the stand-ins
// of Platform/; the engine on Windows takes Foundation's geometry and plain pixels. These say the
// same in the core's types.

nonisolated extension Shaders.ShaderDraw {
    init(vertex: String, fragment: String, uniforms: [String: [Float]], attributes: [String: Attribute],
         indices: [UInt32]?, mode: Mode, first: Int, count: Int, textures: [String: CGImage], flipsTextures: Bool,
         premultipliesTextures: Bool, sampling: [String: Sampling], blend: Blend?, viewport: CGRect?) {
        self.init(vertex: vertex, fragment: fragment, uniforms: uniforms, attributes: attributes, indices: indices,
                  mode: mode, first: first, count: count, textures: textures.mapValues(ShaderPictures.picture),
                  flipsTextures: flipsTextures, premultipliesTextures: premultipliesTextures, sampling: sampling,
                  blend: blend, viewport: viewport.map(ShaderPictures.rect))
    }
}

nonisolated extension ShaderFrame {
    init(size: CGSize, clear: [Float]?, draws: [Shaders.ShaderDraw], alpha: Bool, premultipliedAlpha: Bool, antialias: Bool) {
        self.init(size: Foundation.CGSize(width: size.width, height: size.height), clear: clear, draws: draws, alpha: alpha,
                  premultipliedAlpha: premultipliedAlpha, antialias: antialias)
    }
}

nonisolated extension ShaderRenderer {
    /// `region` of the frame drawn `pixels` big, as a picture the core draws like any other.
    func image(of frame: ShaderFrame, pixels: CGSize, region: CGRect) throws -> CGImage {
        let picture = try image(of: frame, pixels: Foundation.CGSize(width: pixels.width, height: pixels.height),
                                region: ShaderPictures.rect(region))
        return CGImage(width: picture.width, height: picture.height,
                       source: .pixels(picture.pixels, bytesPerRow: picture.width * 4, gray: false))
    }
}

/// The core's pictures as the engine takes them, each made once: the engine keeps a texture per
/// picture it is given, so the same picture is given every time.
nonisolated enum ShaderPictures {
    private static let kept = Shared<[Int: (image: CGImage, picture: ShaderPicture)]>([:])

    static func rect(_ r: CGRect) -> Foundation.CGRect {
        Foundation.CGRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    /// Premultiplied RGBA, rows top first; a picture that cannot be read is one clear pixel, as a
    /// missing picture draws nothing.
    static func picture(_ image: CGImage) -> ShaderPicture {
        if let held = kept.with({ $0[image.id]?.picture }) { return held }
        let picture = pixels(image) ?? ShaderPicture(width: 1, height: 1, pixels: [0, 0, 0, 0])
        kept.with { list in
            // At most 48, as the engine keeps at most 48 textures; the oldest pictures go first.
            while list.count >= 48, let oldest = list.keys.min() { list[oldest] = nil }
            list[image.id] = (image, picture)
        }
        return picture
    }

    private static func pixels(_ image: CGImage) -> ShaderPicture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        if case .pixels(let bytes, let row, let gray) = image.source {
            // Made here: taken as they are, premultiplied where they were not.
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    if gray {
                        let i = y * row + x
                        guard i < bytes.count else { return nil }
                        out[o] = bytes[i]; out[o + 1] = bytes[i]; out[o + 2] = bytes[i]; out[o + 3] = 255
                    } else {
                        let i = y * row + x * 4
                        guard i + 3 < bytes.count else { return nil }
                        let alpha = Int(bytes[i + 3])
                        for c in 0..<3 {
                            out[o + c] = image.straightAlpha ? UInt8((Int(bytes[i + c]) * alpha + 127) / 255) : bytes[i + c]
                        }
                        out[o + 3] = bytes[i + 3]
                    }
                }
            }
            return ShaderPicture(width: width, height: height, pixels: out)
        }
        // One of the design's pictures, or one made of others: Skia makes it, what it is made of
        // first. The core draws on the main thread; elsewhere only a picture sent already reads.
        if Thread.isMainThread { MainActor.assumeIsolated { send(image) } }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let read = out.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(width), Int32(height), 0, $0.baseAddress) }
        return read == 0 ? ShaderPicture(width: width, height: height, pixels: out) : nil
    }

    @MainActor private static func send(_ image: CGImage) {
        if case .changed(let from, _) = image.source { send(from) }
        for used in image.uses { send(used) }
        WindowsCore.send(image)
    }
}
