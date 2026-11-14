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
        /// Kept as sRGB and read as light (WebGL 2's SRGB8_ALPHA8).
        var decodes = false
    }

    private struct Entry {
        var image: AnyObject // held, so no other picture takes its identity while it is here
        var texture: MTLTexture
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// At most 48 pictures and 512 MB of textures.
    private let cache = OnceCache<Key, Entry>(capacity: 48, budget: 512 << 20, keepsFailures: false,
                                              cost: { $0.texture.allocatedSize })
    private let blanks = OnceCache<Bool, MTLTexture>(capacity: 2)
    private let nothing = OnceCache<Bool, MTLTexture>(capacity: 1)

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    func texture(_ image: CGImage, flip: Bool, premultiply: Bool, mipmaps: Bool, cube: Bool,
                 decodes: Bool = false) throws -> MTLTexture {
        let key = Key(image: ObjectIdentifier(image), flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube,
                      decodes: decodes)
        return try cache.value(key) {
            Entry(image: image, texture: try upload(image, flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube,
                                                    decodes: decodes))
        }.texture
    }

    /// Numbers a page gave as a texture, as they are: the first row is t = 0.
    func texture(_ data: ShaderData, mipmaps: Bool, decodes: Bool) throws -> MTLTexture {
        let key = Key(image: ObjectIdentifier(data), flip: false, premultiply: false, mipmaps: mipmaps, cube: false,
                      decodes: decodes)
        return try cache.value(key) {
            Entry(image: data, texture: try upload(data, mipmaps: mipmaps, decodes: decodes))
        }.texture
    }

    /// What a target that nothing was drawn into reads: nought everywhere.
    func empty() throws -> MTLTexture {
        try nothing.value(true) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = storageMode
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShaderError("Metal: no texture.") }
            var clear: [UInt8] = [0, 0, 0, 0]
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)
            return texture
        }
    }

    /// The Metal format that holds a format's texels, and how its channels are read where WebGL
    /// reads them otherwise (LUMINANCE, ALPHA).
    static func format(_ format: ShaderData.Format, decodes: Bool = false) -> (MTLPixelFormat, MTLTextureSwizzleChannels?) {
        switch format {
        case .rgba8: (decodes ? .rgba8Unorm_srgb : .rgba8Unorm, nil)
        case .rg8: (.rg8Unorm, nil)
        case .r8: (.r8Unorm, nil)
        case .luminance8: (.r8Unorm, MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .one))
        case .alpha8: (.r8Unorm, MTLTextureSwizzleChannels(red: .zero, green: .zero, blue: .zero, alpha: .red))
        case .luminanceAlpha8: (.rg8Unorm, MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green))
        case .rgba16Float: (.rgba16Float, nil)
        case .rg16Float: (.rg16Float, nil)
        case .r16Float: (.r16Float, nil)
        case .rgba32Float: (.rgba32Float, nil)
        case .rg32Float: (.rg32Float, nil)
        case .r32Float: (.r32Float, nil)
        }
    }

    private func upload(_ data: ShaderData, mipmaps: Bool, decodes: Bool) throws -> MTLTexture {
        let (format, swizzle) = Self.format(data.format, decodes: decodes)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: data.width, height: data.height,
                                                                  mipmapped: mipmaps)
        descriptor.storageMode = storageMode
        descriptor.usage = [.shaderRead]
        if let swizzle { descriptor.swizzle = swizzle }
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShaderError("Metal: no texture.") }
        let row = data.width * data.format.bytesPerTexel
        data.bytes.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, data.width, data.height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: row)
        }
        try makeMipmaps(texture, when: mipmaps)
        return texture
    }

    private func makeMipmaps(_ texture: MTLTexture, when mipmaps: Bool) throws {
        guard mipmaps, texture.mipmapLevelCount > 1 else { return }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw ShaderError("Metal: no command buffer.")
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
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

    private func upload(_ image: CGImage, flip: Bool, premultiply: Bool, mipmaps: Bool, cube: Bool,
                        decodes: Bool) throws -> MTLTexture {
        let width = image.width
        // A cube's six faces stacked top to bottom; any other picture serves every face.
        let stacked = cube && image.height == width * 6
        let faceHeight = stacked ? width : image.height
        let size = cube ? width : 0
        guard width > 0, faceHeight > 0, width <= 16384, faceHeight <= 16384 else {
            throw ShaderError("A picture too large or empty for a texture (\(width) by \(image.height)).")
        }
        let format: MTLPixelFormat = decodes ? .rgba8Unorm_srgb : .rgba8Unorm
        let descriptor = cube
            ? MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: format, size: size, mipmapped: mipmaps)
            : MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: faceHeight,
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
        if !premultiply { Packing.straighten(&pixels) }
        pixels.withUnsafeBytes { bytes in
            for slice in 0..<(cube ? 6 : 1) {
                // A flipped stack keeps its faces' order: each face is turned in its place.
                let face = stacked ? (flip ? 5 - slice : slice) : 0
                let rows = bytes.baseAddress! + face * faceHeight * width * 4
                texture.replace(region: MTLRegionMake2D(0, 0, width, faceHeight), mipmapLevel: 0, slice: slice,
                                withBytes: rows, bytesPerRow: width * 4, bytesPerImage: width * faceHeight * 4)
            }
        }
        try makeMipmaps(texture, when: mipmaps)
        return texture
    }
}
