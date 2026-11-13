import CoreGraphics
import Metal

/// Pictures uploaded as textures the way WebGL's texImage2D does it: the picture's top row is
/// the texture's first (t = 0) unless UNPACK_FLIP_Y_WEBGL, colours in sRGB, alpha not
/// premultiplied unless UNPACK_PREMULTIPLY_ALPHA_WEBGL. Kept per picture, so the tiles of one
/// frame upload it once.
final class Textures: @unchecked Sendable {
    struct Key: Hashable {
        var image: ObjectIdentifier
        var flip: Bool
        var premultiply: Bool
        var mipmaps: Bool
        var cube: Bool
    }

    private struct Entry {
        var image: CGImage // held, so no other picture takes its identity while it is here
        var texture: MTLTexture
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// At most 48 pictures and 512 MB of textures.
    private let cache = OnceCache<Key, Entry>(capacity: 48, budget: 512 << 20, keepsFailures: false,
                                              cost: { $0.texture.allocatedSize })
    private let blanks = OnceCache<Bool, MTLTexture>(capacity: 2)

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    func texture(_ image: CGImage, flip: Bool, premultiply: Bool, mipmaps: Bool, cube: Bool) throws -> MTLTexture {
        let key = Key(image: ObjectIdentifier(image), flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube)
        return try cache.value(key) {
            Entry(image: image, texture: try upload(image, flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube))
        }.texture
    }

    /// What WebGL samples where no texture is bound: opaque black.
    func blank(cube: Bool) throws -> MTLTexture {
        try blanks.value(cube) {
            let descriptor = cube
                ? MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm, size: 1, mipmapped: false)
                : MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = storageMode
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShaderError("Metal: no texture.") }
            var black: [UInt8] = [0, 0, 0, 255]
            for slice in 0..<(cube ? 6 : 1) {
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: slice, withBytes: &black,
                                bytesPerRow: 4, bytesPerImage: 4)
            }
            return texture
        }
    }

    private var storageMode: MTLStorageMode { device.hasUnifiedMemory ? .shared : .managed }

    private func upload(_ image: CGImage, flip: Bool, premultiply: Bool, mipmaps: Bool, cube: Bool) throws -> MTLTexture {
        let width = image.width
        // A cube's six faces stacked top to bottom; any other picture serves every face.
        let stacked = cube && image.height == width * 6
        let faceHeight = stacked ? width : image.height
        let size = cube ? width : 0
        guard width > 0, faceHeight > 0, width <= 16384, faceHeight <= 16384 else {
            throw ShaderError("A picture too large or empty for a texture (\(width) by \(image.height)).")
        }
        let descriptor = cube
            ? MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm, size: size, mipmapped: mipmaps)
            : MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: faceHeight,
                                                       mipmapped: mipmaps)
        descriptor.storageMode = storageMode
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShaderError("Metal: no texture.") }

        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            if flip {
                // Drawn as it is, the picture's top row is the first in memory; flipped, its last.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ShaderError("A picture did not read.") }
        if !premultiply {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[i + 3])
                if alpha == 0 || alpha == 255 { continue }
                for c in 0..<3 {
                    pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        pixels.withUnsafeBytes { bytes in
            for slice in 0..<(cube ? 6 : 1) {
                // A flipped stack keeps its faces' order: each face is turned in its place.
                let face = stacked ? (flip ? 5 - slice : slice) : 0
                let rows = bytes.baseAddress! + face * faceHeight * width * 4
                texture.replace(region: MTLRegionMake2D(0, 0, width, faceHeight), mipmapLevel: 0, slice: slice,
                                withBytes: rows, bytesPerRow: width * 4, bytesPerImage: width * faceHeight * 4)
            }
        }
        if mipmaps, texture.mipmapLevelCount > 1 {
            guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
                throw ShaderError("Metal: no command buffer.")
            }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }
}
