import Foundation
import ShaderDirect3D

/// Pictures uploaded as textures the way WebGL's texImage2D does it, and as the Mac's Metal
/// textures are: the picture's top row is the texture's first (t = 0) unless UNPACK_FLIP_Y_WEBGL,
/// colours in sRGB, alpha not premultiplied unless UNPACK_PREMULTIPLY_ALPHA_WEBGL. Kept per
/// picture, so the tiles of one frame upload it once.
final class Textures: @unchecked Sendable {
    struct Key: Hashable {
        var image: ObjectIdentifier
        var flip: Bool
        var premultiply: Bool
        var mipmaps: Bool
        var cube: Bool
    }

    private struct Entry {
        var image: ShaderPicture // held, so no other picture takes its identity while it is here
        var texture: Handle
        var cost: Int
    }

    private let device: OpaquePointer
    /// At most 48 pictures and 512 MB of textures.
    private let cache = OnceCache<Key, Entry>(capacity: 48, budget: 512 << 20, keepsFailures: false,
                                              cost: { $0.cost })
    private let blanks = OnceCache<Bool, Handle>(capacity: 2)

    init(device: OpaquePointer) {
        self.device = device
    }

    func texture(_ image: ShaderPicture, flip: Bool, premultiply: Bool, mipmaps: Bool, cube: Bool) throws -> Handle {
        let key = Key(image: ObjectIdentifier(image), flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube)
        return try cache.value(key) {
            let (texture, cost) = try upload(image, flip: flip, premultiply: premultiply, mipmaps: mipmaps, cube: cube)
            return Entry(image: image, texture: texture, cost: cost)
        }.texture
    }

    /// What WebGL samples where no texture is bound: opaque black.
    func blank(cube: Bool) throws -> Handle {
        try blanks.value(cube) {
            let black = [UInt8](repeating: 0, count: 4 * (cube ? 6 : 1)).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
            guard let made = bz_d3d_texture(device, 1, 1, black, cube ? 1 : 0, 0) else {
                throw ShaderError("Direct3D: no texture.")
            }
            return Handle(made)
        }
    }

    private func upload(_ image: ShaderPicture, flip: Bool, premultiply: Bool, mipmaps: Bool,
                        cube: Bool) throws -> (Handle, Int) {
        let width = image.width
        // A cube's six faces stacked top to bottom; any other picture serves every face.
        let stacked = cube && image.height == width * 6
        let faceHeight = stacked ? width : image.height
        guard width > 0, faceHeight > 0, width <= 16384, faceHeight <= 16384 else {
            throw ShaderError("A picture too large or empty for a texture (\(width) by \(image.height)).")
        }
        let row = width * 4
        var pixels = image.pixels
        if flip {
            // As it is, the picture's top row is the first in memory; flipped, its last.
            var turned = [UInt8](repeating: 0, count: pixels.count)
            for y in 0..<image.height {
                turned.replaceSubrange((image.height - 1 - y) * row..<(image.height - y) * row,
                                       with: pixels[y * row..<(y + 1) * row])
            }
            pixels = turned
        }
        if !premultiply { Packing.straighten(&pixels) }
        let bytes: [UInt8]
        let height: Int
        if cube {
            // Square faces, as a cube's are; a flipped stack keeps its faces' order, each turned in its place.
            height = width
            var faces = [UInt8](repeating: 0, count: 6 * width * row)
            for slice in 0..<6 {
                let face = stacked ? (flip ? 5 - slice : slice) : 0
                let rows = min(faceHeight, width)
                faces.replaceSubrange(slice * width * row..<(slice * width + rows) * row,
                                      with: pixels[face * faceHeight * row..<(face * faceHeight + rows) * row])
            }
            bytes = faces
        } else {
            height = faceHeight
            bytes = pixels
        }
        guard let made = bz_d3d_texture(device, Int32(width), Int32(height), bytes, cube ? 1 : 0, mipmaps ? 1 : 0) else {
            throw ShaderError("Direct3D: no texture of \(width) by \(height).")
        }
        return (Handle(made), mipmaps ? bytes.count * 4 / 3 : bytes.count)
    }
}
