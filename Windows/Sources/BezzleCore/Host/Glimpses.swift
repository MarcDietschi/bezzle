import Foundation
import CBezzleHost

// Glimpses on Windows (the shared Model/Live.swift's LiveGlimpse): a picture placed in a shared
// design goes to the others in its live room at once as a glimpse of it, the same picture a few
// dozen pixels across, about a kilobyte; whoever does not have the picture yet sees it grown and
// blurred in its place, as through frosted glass, until the picture itself comes from the room.
// Made and opened here with Skia as the Mac does with Image I/O and Core Image: so a Mac opens a
// glimpse made here, and the other way round, and both show it alike. Live.swift's own `of` and
// `standIn` are not used here (Host/GlimpseStandIns.swift lets them build): a glimpse is made off
// the main thread, where the core's pictures cannot be.

extension WindowsCore {
    /// How a glimpse is written, as LiveGlimpse.of writes it: JPEG at Image I/O's 0.72.
    nonisolated static let glimpseQuality = 0.72
    /// How large a glimpse is grown to stand in for its picture, along its longer side, as
    /// LiveGlimpse.standIn grows it.
    static let glimpseShown: Int32 = 320

    /// The pictures shown by their glimpse until they come, by name (CBezzleHost's
    /// bz_asset_stand_in): the names are the pictures' own UUIDs, so one set does for every design.
    nonisolated(unsafe) static var glimpsed: Set<String> = []

    /// A glimpse of the picture in the file at `url`, as the Mac's LiveGlimpse.of makes one: the
    /// picture upright, its longer side 32 pixels, as JPEG. On any thread.
    nonisolated static func glimpse(of url: URL, name: String) -> LiveGlimpse? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let side = LiveGlimpse.pixels
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var w: Int32 = 0, h: Int32 = 0
        let made = data.withUnsafeBytes { d in
            pixels.withUnsafeMutableBytes { bz_image_thumbnail(d.baseAddress, Int64(d.count), Int32(side), &w, &h, $0.baseAddress) }
        }
        guard made != 0 else { return nil }
        var out = [UInt8](repeating: 0, count: 64 * 1024)
        let n = pixels.withUnsafeBytes { p in
            out.withUnsafeMutableBytes { bz_jpeg_encode(w, h, p.baseAddress, glimpseQuality, $0.baseAddress, Int64($0.count)) }
        }
        guard n > 0 else { return nil }
        return LiveGlimpse(name: name, jpeg: Data(out.prefix(Int(n))))
    }

    /// The glimpse of the picture at `url`, as a JPEG file's bytes, and how large it is: for
    /// bezzle-render to show.
    public nonisolated static func glimpseJPEG(of url: URL) -> (jpeg: Data, width: Int, height: Int)? {
        guard let g = glimpse(of: url, name: url.lastPathComponent) else { return nil }
        var w: Int32 = 0, h: Int32 = 0
        _ = g.jpeg.withUnsafeBytes { bz_image_size($0.baseAddress, Int32($0.count), &w, &h) }
        return (g.jpeg, Int(w), Int(h))
    }

    /// Shows the picture a glimpse is of by the glimpse, grown and blurred as the Mac shows it,
    /// until the picture itself comes: Skia draws it wherever the picture is drawn, so its place,
    /// crop and development are the picture's. False when the picture is here already, or the
    /// glimpse cannot be read.
    @discardableResult static func standIn(_ g: LiveGlimpse) -> Bool {
        guard !glimpsed.contains(g.name) else { return false }
        let n = g.jpeg.withUnsafeBytes { bz_asset_stand_in(g.name, $0.baseAddress, Int32($0.count), glimpseShown) }
        guard n > 0 else { return false }
        glimpsed.insert(g.name)
        // Kept as itself, so it can still be drawn fading off the picture once that has come; Skia
        // told of it now, as it is made outside any drawing.
        if let image = Assets(folder: nil).image(g.name) {
            send(image)
            glimpseImages[g.name] = image
        }
        // Drawn again: the picture looked for before and not found is asked for again.
        pictureCame = true
        tellShareNews()
        return true
    }

    /// A picture shown by its glimpse came: the open design's pictures are looked up again, as
    /// what it drew before was the glimpse.
    static func glimpseDone(_ name: String) {
        glimpseImages[name] = nil
        guard glimpsed.remove(name) != nil else { return }
        assets = Assets(folder: assets.folder)
    }

    /// The glimpses shown in place of pictures not here yet, grown and blurred, by name: what a
    /// picture on its way develops from (Host/Developing.swift).
    nonisolated(unsafe) static var glimpseImages: [String: CGImage] = [:]

    /// What Skia draws for the open design's picture `name`, itself or its glimpse grown, as
    /// premultiplied RGBA: for bezzle-share to show the Mac's tests.
    static func pictureShown(named name: String) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let image = Assets(folder: assets.folder).image(name) else { return nil }
        send(image)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let read = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 0, $0.baseAddress) }
        return read == 0 ? (image.width, image.height, pixels) : nil
    }
}
