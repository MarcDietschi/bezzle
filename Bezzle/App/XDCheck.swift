#if DEBUG
import AppKit
import ImageIO

/// Compares Bezzle's drawing of imported XD files with XD's own: every .xd file carries a
/// `preview.png` of one artboard as XD drew it. For each file, writes XD's picture, Bezzle's and
/// where they differ side by side, and a line with how far apart they are and what the import
/// reported. Run with BEZZLE_XDCHECK=folder-of-xd-files:output-folder.
enum XDCheck {
    static func run(_ spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let source = URL(fileURLWithPath: parts[0]), out = URL(fileURLWithPath: parts[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var summary: [String] = []
        for file in files {
            let started = Date()
            do {
                let (url, report) = try Importer.importFile(file, into: Library.shared.folder)
                let seconds = Date().timeIntervalSince(started)
                let doc = try DesignFile.read(url)
                let assets = Assets(design: url)
                let archive = try ZipArchive(url: file)
                guard let preview = image(try archive.read("preview.png")) else {
                    summary.append("\(file.lastPathComponent): no preview in the file")
                    continue
                }
                guard let board = previewed(preview, in: doc, assets: assets) else {
                    summary.append("\(file.lastPathComponent): no artboards")
                    continue
                }
                let width = min(CGFloat(preview.width), 900)
                let scale = width / board.frame.width
                let size = CGSize(width: width.rounded(), height: (board.frame.height * scale).rounded())
                guard let ours = Renderer.image(of: board, scale: scale, assets: assets),
                      let theirs = resized(preview, to: size), let mine = resized(ours, to: size) else { continue }
                let (difference, picture) = compare(theirs, mine)
                let name = file.deletingPathExtension().lastPathComponent
                if let sheet = sideBySide([theirs, mine, picture]) { write(sheet, to: out.appendingPathComponent("\(name).png")) }
                // The rest have nothing of XD's to compare with, but drawn together, what is off stands out.
                if doc.artboards.count > 1, let sheet = contactSheet(Array(doc.artboards.prefix(40)), assets: assets) {
                    write(sheet, to: out.appendingPathComponent("\(name)-artboards.png"))
                }
                summary.append(String(format: "%@: %.1f%% apart, %d artboards, %d layers, %.1fs. %@", file.lastPathComponent, difference * 100,
                                      report.artboards, report.layers, seconds, report.lines.joined(separator: "; ")))
            } catch {
                summary.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try? summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// XD's preview shows one artboard, and the file does not say which: of those shaped like
    /// the preview, the one that, drawn small, looks most like it.
    private static func previewed(_ preview: CGImage, in doc: BezzleDocument, assets: Assets) -> Node? {
        let aspect = CGFloat(preview.width) / CGFloat(preview.height)
        func off(_ b: Node) -> CGFloat { abs(b.frame.width / b.frame.height - aspect) / aspect }
        let closest = doc.artboards.map(off).min() ?? 1
        let shaped = doc.artboards.filter { off($0) <= closest + 0.01 }
        guard shaped.count > 1 else { return shaped.first }
        let size = CGSize(width: 96, height: (96 / aspect).rounded())
        guard let theirs = resized(preview, to: size) else { return shaped.first }
        var best: (board: Node, distance: Double)?
        for board in shaped {
            guard let drawn = Renderer.image(of: board, scale: 96 / board.frame.width, assets: assets), let mine = resized(drawn, to: size) else { continue }
            let distance = compare(theirs, mine).0
            if distance < best?.distance ?? .infinity { best = (board, distance) }
        }
        return best?.board ?? shaped.first
    }

    private static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// How different two pictures of the same size are, 0 to 1, and a picture of where: the
    /// difference made bright, over a faint copy of XD's.
    private static func compare(_ a: CGImage, _ b: CGImage) -> (Double, CGImage) {
        let size = CGSize(width: a.width, height: a.height)
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: a.width * a.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(origin: .zero, size: size))
            }
            return bytes
        }
        let pa = pixels(a), pb = pixels(b)
        var out = [UInt8](repeating: 255, count: pa.count)
        var total = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = (abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))) / 3
            total += d
            let faint = UInt8(235 + Int(pa[i]) * 20 / 255)
            let strength = min(255, d * 4)
            out[i] = UInt8(max(0, Int(faint) - strength / 3))
            out[i + 1] = UInt8(max(0, Int(faint) - strength))
            out[i + 2] = UInt8(max(0, Int(faint) - strength))
        }
        let difference = Double(total) / Double(pa.count / 4) / 255
        let picture = out.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return (difference, picture ?? a)
    }

    private static func sideBySide(_ images: [CGImage]) -> CGImage? {
        let gap = 16, width = images.map(\.width).reduce(0, +) + gap * (images.count - 1), height = images.map(\.height).max() ?? 0
        guard let ctx = context(CGSize(width: width, height: height)) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            ctx.draw(image, in: CGRect(x: x, y: height - image.height, width: image.width, height: image.height))
            x += image.width + gap
        }
        return ctx.makeImage()
    }

    /// Artboards in rows, each drawn 180 points wide.
    private static func contactSheet(_ boards: [Node], assets: Assets) -> CGImage? {
        let cell: CGFloat = 180, gap: CGFloat = 12, columns = 10
        let pictures = boards.compactMap { Renderer.image(of: $0, scale: cell / $0.frame.width, assets: assets) }
        guard !pictures.isEmpty else { return nil }
        let rowHeight = CGFloat(pictures.map(\.height).max() ?? 0)
        let rows = (pictures.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(min(columns, pictures.count)) * (cell + gap) + gap, height: CGFloat(rows) * (rowHeight + gap) + gap)
        guard let ctx = context(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        for (i, picture) in pictures.enumerated() {
            let x = gap + CGFloat(i % columns) * (cell + gap)
            let y = size.height - gap - CGFloat(i / columns + 1) * (rowHeight + gap) + gap
            ctx.draw(picture, in: CGRect(x: x, y: y + rowHeight - CGFloat(picture.height), width: CGFloat(picture.width), height: CGFloat(picture.height)))
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
#endif
