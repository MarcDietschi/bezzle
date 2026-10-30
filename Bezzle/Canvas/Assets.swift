import Foundation
import ImageIO

/// The pictures a design holds, in its package's images folder: read once, then kept.
final class Assets {
    /// Where the pictures are; none for a design saved as a single file, which has no pictures.
    let folder: URL?
    private var sources: [String: CGImageSource] = [:]
    /// Each picture at the sizes it has been drawn at, in steps of two, up to its own.
    private var cache: [String: [Int: CGImage]] = [:]
    private var missing: Set<String> = []

    init(folder: URL?) {
        self.folder = folder
    }

    /// The images folder of the design at `url`, when it is a package.
    convenience init(design url: URL) {
        var isFolder: ObjCBool = false
        let package = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        self.init(folder: package ? url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true) : nil)
    }

    /// The picture, at least `pixels` along its longer side, or at its own size if that is
    /// smaller. A photo several thousand pixels wide drawn as a card is read small, which is
    /// quicker both to read and to draw.
    func image(_ name: String, pixels: CGFloat = .infinity) -> CGImage? {
        guard let folder, !missing.contains(name) else { return nil }
        let step = pixels.isFinite ? max(64, 1 << Int(ceil(log2(max(pixels, 1))))) : Int.max
        if let image = cache[name]?[step] { return image }
        guard let source = sources[name] ?? CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else {
            missing.insert(name)
            return nil
        }
        sources[name] = source
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: step]
        let image = step == Int.max
            ? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            : CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        guard let image else {
            missing.insert(name)
            return nil
        }
        cache[name, default: [:]][step] = image
        return image
    }
}
