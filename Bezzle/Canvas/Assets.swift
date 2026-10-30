import Foundation
import ImageIO

/// The pictures a design holds, in its package's images folder: read once, then kept.
/// Safe to use from several threads at once, as the canvas's tiles are drawn: what it keeps is
/// behind a lock, and pictures are read outside it, so several are read side by side; one being
/// read already is waited for rather than read again.
nonisolated final class Assets: @unchecked Sendable {
    /// Where the pictures are; none for a design saved as a single file, which has no pictures.
    let folder: URL?

    private struct Kept {
        /// Each picture at the sizes it has been drawn at, in steps of two, up to its own.
        var cache: [String: [Int: CGImage]] = [:]
        var missing: Set<String> = []
        /// Pictures read ahead of time at the one size a thumbnail draws them at, given for any size.
        var previews: [String: CGImage] = [:]
        /// Pictures being read, by size and name.
        var reading: Set<String> = []
    }
    private var kept = Kept()
    /// Guards `kept`, and is waited on for a picture another thread is reading.
    private let lock = NSCondition()

    init(folder: URL?) {
        self.folder = folder
    }

    /// The images folder of the design at `url`, when it is a package.
    convenience init(design url: URL) {
        var isFolder: ObjCBool = false
        let package = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        self.init(folder: package ? url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true) : nil)
    }

    private func locked<Result>(_ body: (inout Kept) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&kept)
    }

    /// The picture, at least `pixels` along its longer side, or at its own size if that is
    /// smaller. A photo several thousand pixels wide drawn as a card is read small, which is
    /// quicker both to read and to draw.
    func image(_ name: String, pixels: CGFloat = .infinity) -> CGImage? {
        let step = Self.step(pixels), key = Self.key(name, step)
        lock.lock()
        // A photo across many tiles is wanted by each of the threads drawing them at once.
        while kept.reading.contains(key) { lock.wait() }
        if let preview = kept.previews[name] { lock.unlock(); return preview }
        guard let folder, !kept.missing.contains(name) else { lock.unlock(); return nil }
        if let image = kept.cache[name]?[step] { lock.unlock(); return image }
        kept.reading.insert(key)
        lock.unlock()
        let image = Self.read(folder.appendingPathComponent(name), step: step)
        finish(name, step: step, image)
        return image
    }

    /// A picture read: kept, or noted as missing, and whoever waits for it told.
    private func finish(_ name: String, step: Int, _ image: CGImage?) {
        lock.lock()
        kept.reading.remove(Self.key(name, step))
        if let image { kept.cache[name, default: [:]][step] = image } else { kept.missing.insert(name) }
        lock.broadcast()
        lock.unlock()
    }

    private static func key(_ name: String, _ step: Int) -> String { "\(step) \(name)" }

    /// Told on the main thread, with its name, when a picture read away from it is ready.
    var ready: (@MainActor (String) -> Void)?
    private static let readers = DispatchQueue(label: "Bezzle pictures", qos: .userInitiated, attributes: .concurrent)

    /// The same, but on the main thread, when the picture has been read before at another size
    /// and `later` allows, that one for now, to be drawn stretched or shrunk, while this one is
    /// read away from it and `ready` is told once it is. Moving closer asks for every picture in
    /// sight at a new size, and reading a large photo stops the canvas for a moment. The first
    /// time a picture is asked for, it is read at once, so it is never missing from what is
    /// drawn; and away from the main thread it is simply read, as nothing waits on it there.
    func image(_ name: String, pixels: CGFloat, later: Bool) -> CGImage? {
        let step = Self.step(pixels), key = Self.key(name, step)
        guard later, pixels.isFinite, Thread.isMainThread, let folder else { return image(name, pixels: pixels) }
        let (sizes, start) = locked { k -> ([Int: CGImage]?, Bool) in
            guard k.previews[name] == nil, !k.missing.contains(name), k.cache[name]?[step] == nil,
                  let sizes = k.cache[name], !sizes.isEmpty else { return (nil, false) }
            return (sizes, k.reading.insert(key).inserted)
        }
        guard let sizes else { return image(name, pixels: pixels) }
        if start {
            let url = folder.appendingPathComponent(name), back = Handoff(assets: self)
            // Kept from here, not from the main thread, which may itself be waiting for it.
            Self.readers.async {
                guard let assets = back.assets else { return }
                let image = Self.read(url, step: step)
                assets.finish(name, step: step, image)
                if image != nil { TileMaker.onMain { back.assets?.ready?(name) } }
            }
        }
        // The nearest size it has, a larger one rather than a smaller.
        func distance(_ s: Int) -> Double { s == Int.max ? 64 : abs(log2(Double(s) / Double(step))) + (s < step ? 0.5 : 0) }
        return sizes.min { distance($0.key) < distance($1.key) }?.value
    }

    /// Where a picture read away from the main thread goes back to.
    private struct Handoff: Sendable { weak var assets: Assets? }

    /// The size a picture is read at for `pixels`: the next power of two, so a little closer or
    /// further keeps using the same.
    private static func step(_ pixels: CGFloat) -> Int {
        pixels.isFinite ? max(64, 1 << Int(ceil(log2(max(pixels, 1))))) : Int.max
    }

    /// Reads a picture at a size, from its own source each time: one source read on two threads at once is not to be trusted.
    private static func read(_ url: URL, step: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: step]
        return step == Int.max
            ? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            : CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The pictures of the design at `url`, each read at the size given, all at once on every
    /// core. Decoding a large picture takes as long whatever size it is read at, so a thumbnail
    /// of a design with many reads them here, away from the main thread, and is then only drawn.
    static func previews(_ sizes: [String: Int], design url: URL) -> Assets {
        let assets = Assets(design: url)
        guard let folder = assets.folder, !sizes.isEmpty else { return assets }
        let names = Array(sizes.keys)
        let read = Previews(count: names.count)
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: sizes[names[i]] ?? 64]
            let image = CGImageSourceCreateWithURL(folder.appendingPathComponent(names[i]) as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            read.set(i, image)
        }
        for (i, name) in names.enumerated() {
            assets.locked { if let image = read.images[i] { $0.previews[name] = image } else { _ = $0.missing.insert(name) } }
        }
        return assets
    }

    /// Pictures read on several threads at once, each into its own place.
    private final class Previews: @unchecked Sendable {
        private(set) var images: [CGImage?]
        private let lock = NSLock()
        init(count: Int) { images = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ image: CGImage?) { lock.withLock { images[i] = image } }
    }

    /// A picture that was not there has come, from someone sharing the design: it is looked for again.
    func arrived(_ name: String) {
        locked { _ = $0.missing.remove(name) }
    }
}

nonisolated extension Node {
    /// Whether this layer, or any it holds, is filled with the picture.
    func shows(picture name: String) -> Bool {
        fill.image?.assets.contains(name) == true || children.contains { $0.shows(picture: name) }
    }
}
