import Foundation
import CBezzleHost

// Pictures drawn on their own, for comparing with the Mac (bezzle-render's `pictures`): an HDR
// picture brought down as Core Graphics brings it (CBezzleHost/hdr.h), a P3 one as it converts it.

extension WindowsCore {
    /// For comparing with the Mac's Renderer (bezzle-render's BEZZLE_PICTURES): each picture file
    /// drawn as a picture fill draws it into an 8-bit sRGB picture, at its own size and with its
    /// longer side each of `sides`, as <name>-full.png and <name>-<side>.png in `out`; with
    /// `develop`, developed so (as Developer develops it) into <name>-developed.png too.
    public static func drawPictures(_ files: [URL], sides: [Int], develop: [String: Double], into out: URL) throws -> [String] {
        var said: [String] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: file)
            let asset = UUID().uuidString + "." + file.pathExtension
            giveSkia(asset, data)
            guard let image = Assets(folder: nil).image(asset) else { said.append("\(name): not read"); continue }
            var settings = Develop()
            for (key, value) in develop { if let s = Develop.Setting(rawValue: key) { settings[s] = value } }
            var shown: [(String, Int, Int, CGImage)] = [("full", image.width, image.height, image)]
            for side in sides {
                let k = Double(side) / Double(max(image.width, image.height))
                shown.append(("\(side)", max(1, Int((Double(image.width) * k).rounded())), max(1, Int((Double(image.height) * k).rounded())), image))
            }
            if !develop.isEmpty { shown.append(("developed", image.width, image.height, Developer.developed(image, settings))) }
            for (label, w, h, picture) in shown {
                let started = Date()
                let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
                guard let ctx = Renderer.bitmap(CGSize(width: w, height: h)) else { continue }
                ctx.interpolationQuality = .high
                ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let drawn = ctx.makeImage() else { continue }
                // The picture drawn, made before this drawing began, then what the drawing made.
                send(picture)
                for p in Images.shared.list where p.id >= first { send(p) }
                var pixels = [UInt8](repeating: 0, count: w * h * 4)
                let read = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(drawn.id), Int32(w), Int32(h), 0, $0.baseAddress) }
                forget(before: first)
                guard read == 0 else { said.append("\(name) \(label): not drawn"); continue }
                try writePNG(pixels, width: w, height: h, to: out.appendingPathComponent("\(name)-\(label).png"))
                said.append("\(name) \(label): \(w)×\(h) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
        return said
    }
}
