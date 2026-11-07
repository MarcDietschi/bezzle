import Foundation
import AppKit
import CBezzleHost

// Designs made in Adobe XD, Figma, Sketch and Photoshop, brought in on Windows as the Mac brings
// them in (Import/Importing.swift): each file becomes a new design in the designs folder, named
// after it, with its pictures in images/, and the file itself is left as it is.

extension WindowsCore {
    /// What bringing a design in came to, as the Mac's ImportReport says it.
    nonisolated public struct ImportSummary: Sendable {
        /// The app the design was made in, as it calls itself: "Figma".
        public let source: String
        public let artboards: Int
        public let layers: Int
        /// What was only approximated, in the user's language, and how often, the most frequent first.
        public let notes: [(text: String, count: Int)]
        public let missingFonts: [String]

        /// The notes as sentences, as the Mac's ImportReport.lines makes them.
        public var lines: [String] { notes.map { "\($0.text): \($0.count)" } }
    }

    /// The file extensions brought in: xd, fig, sketch, psd, psb.
    public static var importedExtensions: [String] { Importer.fileExtensions }

    /// Whether a file is one to bring in as a new design.
    public static func imports(_ url: URL) -> Bool { Importer.imports(url) }

    /// Makes a new design in `folder` out of a file from Adobe XD, Figma, Sketch or Photoshop, as
    /// the Mac does: named after the file ("Name", then "Name 2"…), its pictures in images/.
    /// Answers where it is and what came across. Nothing that is open changes.
    public static func importDesign(_ file: URL, into folder: URL) throws -> (URL, ImportSummary) {
        start()
        ImportPictures.begin()
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        defer {
            // The pictures made while reading are let go, and Skia forgets them with them.
            Images.shared.list.removeAll { image in
                if case .asset = image.source { return false }
                return image.id >= first
            }
            ImportPictures.end()
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Library.shared.folder = folder
        let (url, report) = try Importer.importFile(file, into: folder)
        let notes = report.notes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (text: $0.key, count: $0.value) }
        return (url, ImportSummary(source: report.source, artboards: report.artboards, layers: report.layers, notes: notes,
                                   missingFonts: report.missingFonts.sorted()))
    }
}

/// The pictures an import draws and keeps, which Skia makes: drawn into the memory of a bitmap
/// context when it is let go (CGContext.Bitmap.draw), read back as pixels to name and write them
/// (CGImage.dataProvider, CGImageDestination). Pictures made here are given to Skia as they are
/// needed, with what they draw (`CGImage.uses`).
nonisolated enum ImportPictures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: Set<Int> = []
    /// Pictures Skia made and read back, by number, for the PNGs written from other threads.
    nonisolated(unsafe) private static var read: [Int: [UInt8]] = [:]

    static func begin() {
        if CGImage.released == nil { CGImage.released = { id in bz_picture_forget(Int32(id)) } }
        CGContext.Bitmap.draw = { context, bitmap in ImportPictures.draw(context, into: bitmap) }
    }

    static func end() {
        lock.withLock {
            sent = []
            read = [:]
        }
    }

    /// A picture's pixels, RGBA, rows top first, `width` × 4 bytes each: as given for pixels made
    /// here (`straight` when not premultiplied), otherwise as Skia makes them, premultiplied.
    static func pixels(of image: CGImage) -> (bytes: [UInt8], straight: Bool)? {
        let w = image.width, h = image.height
        if case .pixels(let bytes, let row, let gray) = image.source {
            if !gray, row == w * 4 { return (bytes, image.straightAlpha) }
            var out = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    if gray {
                        let v = bytes[y * row + x]
                        out[(y * w + x) * 4] = v
                        out[(y * w + x) * 4 + 1] = v
                        out[(y * w + x) * 4 + 2] = v
                    } else {
                        for c in 0..<4 { out[(y * w + x) * 4 + c] = bytes[y * row + x * 4 + c] }
                    }
                }
            }
            return (out, gray ? false : image.straightAlpha)
        }
        if let known = lock.withLock({ read[image.id] }) { return (known, false) }
        // Skia is asked on the main thread only, where the core gives it its pictures.
        guard Thread.isMainThread else { return nil }
        let made: [UInt8]? = MainActor.assumeIsolated {
            give(image)
            var out = [UInt8](repeating: 0, count: w * h * 4)
            let done = out.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(w), Int32(h), 0, $0.baseAddress) }
            return done == 0 ? out : nil
        }
        if let made { lock.withLock { read[image.id] = made } }
        return made.map { ($0, false) }
    }

    /// Gives Skia a picture made here, and first what it is made from and what it draws.
    @MainActor static func give(_ image: CGImage) {
        guard lock.withLock({ sent.insert(image.id).inserted }) else { return }
        switch image.source {
        case .changed(let from, _): give(from)
        case .picture: for used in image.uses { give(used) }
        default: break
        }
        WindowsCore.send(image)
    }

    /// What was drawn into a bitmap context, made by Skia into the memory the context was given.
    static func draw(_ context: CGContext, into bitmap: CGContext.Bitmap) {
        guard Thread.isMainThread, !context.commands.isEmpty else { return }
        let w = context.width, h = context.height
        let pixels: [UInt8]? = MainActor.assumeIsolated {
            let picture = CGImage(width: w, height: h, source: .picture(context.commands))
            picture.uses = context.drawn
            defer { Images.shared.list.removeAll { $0 === picture } }
            give(picture)
            var out = [UInt8](repeating: 0, count: w * h * 4)
            let done = out.withUnsafeMutableBytes { bz_picture_read(Int32(picture.id), Int32(w), Int32(h), 0, $0.baseAddress) }
            return done == 0 ? out : nil
        }
        guard let pixels else { return }
        let to = bitmap.data.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let line = to + y * bitmap.bytesPerRow
                var x = 0
                if bitmap.gray {
                    // Grey is drawn as equal red, green and blue: the red is it, over what is there.
                    while x < w {
                        let at = (y * w + x) * 4
                        line[x] = UInt8(min(255, Int(p[at]) + Int(line[x]) * (255 - Int(p[at + 3])) / 255))
                        x += 1
                    }
                } else {
                    let opaque = bitmap.alpha == .none || bitmap.alpha == .noneSkipLast || bitmap.alpha == .noneSkipFirst
                    while x < w {
                        let at = (y * w + x) * 4
                        let a = Int(p[at + 3])
                        // Drawn over what is there, as Core Graphics draws into a bitmap.
                        for c in 0..<3 { line[x * 4 + c] = UInt8(min(255, Int(p[at + c]) + Int(line[x * 4 + c]) * (255 - a) / 255)) }
                        line[x * 4 + 3] = opaque ? 255 : UInt8(min(255, a + Int(line[x * 4 + 3]) * (255 - a) / 255))
                        x += 1
                    }
                }
            }
        }
    }

    /// Each pixel the lightest within `radius` of it, or, below nought, the darkest, as Core
    /// Image's morphology filters spread a grey picture through a round pen; what lies outside
    /// it counts as nought.
    static func spread(_ plane: [UInt8], width w: Int, height h: Int, radius: Double) -> [UInt8] {
        let r = abs(radius)
        guard r >= 0.5, w > 0, h > 0 else { return plane }
        let widest = Int(r)
        let lightest = radius > 0
        var out = [UInt8](repeating: lightest ? 0 : 255, count: w * h)
        // Along each row, the extreme of every run of 2a + 1 pixels, for each half width a the
        // pen has across some row of it.
        var halves = Set<Int>()
        for dy in -widest...widest { halves.insert(Int((r * r - Double(dy * dy)).squareRoot())) }
        var runs: [Int: [UInt8]] = [:]
        for a in halves { runs[a] = along(plane, width: w, height: h, half: a, lightest: lightest) }
        out.withUnsafeMutableBufferPointer { o in
            for dy in -widest...widest {
                let a = Int((r * r - Double(dy * dy)).squareRoot())
                runs[a]!.withUnsafeBufferPointer { run in
                    for y in 0..<h {
                        let from = y + dy
                        var x = 0
                        if from < 0 || from >= h {
                            // Rows outside count as nought.
                            if !lightest { while x < w { o[y * w + x] = 0; x += 1 } }
                            continue
                        }
                        let line = run.baseAddress! + from * w, at = o.baseAddress! + y * w
                        if lightest {
                            while x < w { if line[x] > at[x] { at[x] = line[x] }; x += 1 }
                        } else {
                            while x < w { if line[x] < at[x] { at[x] = line[x] }; x += 1 }
                        }
                    }
                }
            }
        }
        return out
    }

    /// The extreme of the pixels from `half` left to `half` right of each, along its row, nought past the ends.
    private static func along(_ plane: [UInt8], width w: Int, height h: Int, half a: Int, lightest: Bool) -> [UInt8] {
        guard a > 0 else { return plane }
        let k = 2 * a + 1, n = w + 2 * a
        let padded = (n + k - 1) / k * k
        var out = [UInt8](repeating: 0, count: w * h)
        var row = [UInt8](repeating: 0, count: padded), g = row, hh = row
        plane.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for i in 0..<padded { row[i] = 0 }
                    for x in 0..<w { row[x + a] = src[y * w + x] }
                    // Van Herk: from the start and the end of each block of k.
                    var i = 0
                    while i < padded {
                        if i % k == 0 { g[i] = row[i] } else { g[i] = lightest ? max(g[i - 1], row[i]) : min(g[i - 1], row[i]) }
                        i += 1
                    }
                    i = padded - 1
                    while i >= 0 {
                        if i % k == k - 1 { hh[i] = row[i] } else { hh[i] = lightest ? max(hh[i + 1], row[i]) : min(hh[i + 1], row[i]) }
                        i -= 1
                    }
                    for x in 0..<w {
                        // The run from x to x + 2a in the padded row is centred on the pixel.
                        let left = hh[x], right = g[x + 2 * a]
                        dst[y * w + x] = lightest ? max(left, right) : min(left, right)
                    }
                }
            }
        }
        return out
    }
}
