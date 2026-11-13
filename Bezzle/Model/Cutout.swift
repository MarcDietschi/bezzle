import CoreGraphics

/// A picture with its background taken away: its subject alone, see-through all round it and
/// soft where the photo was. It is made from the picture by `CutoutMaker` and kept beside it in
/// the design's images, so the picture itself never changes, and its background can always be
/// had back.
nonisolated struct Cutout: Codable, Hashable {
    /// The picture as cut out: a PNG in the design's images.
    var asset: String
    /// Where the subjects kept were picked, 0…1 across and down the picture as it was taken;
    /// none keeps everything that stands out in it.
    var picks: [CGPoint]?
    /// Round the subject, where it is at least half solid: SVG path data across and down the
    /// picture from 0 to 1, filled even-odd. A border follows it, and a click on the layer
    /// outside it goes through to what lies under. Cutouts made before it was kept have none.
    var outline: String?
}

nonisolated extension ImageFill {
    /// The picture as it is drawn: cut out, or as it was taken.
    var shown: String { cutout?.asset ?? asset }

    /// Every picture it is drawn from, kept and shared with the design.
    var assets: [String] { cutout.map { [asset, $0.asset] } ?? [asset] }

    /// From across and down the picture as it was taken, 0…1, to where that is drawn in a layer of
    /// `size`, its top left at zero: placed and turned over as the picture is.
    func placing(in size: CGSize) -> CGAffineTransform {
        let r = Renderer.imageRect(self, in: size)
        let fx = flippedX == true, fy = flippedY == true
        return CGAffineTransform(a: fx ? -r.width : r.width, b: 0, c: 0, d: fy ? -r.height : r.height,
                                 tx: fx ? r.maxX : r.minX, ty: fy ? r.maxY : r.minY)
    }
}

nonisolated extension Node {
    /// The pictures the layer itself paints with, whether they are on or not: its first fill's,
    /// which text's letters show too, and any of its borders'.
    var paintedPictures: [ImageFill] {
        var out: [ImageFill] = []
        if let image = fill.image { out.append(image) }
        out += fill.shader?.pictures ?? []
        if let image = border.image { out.append(image) }
        for b in moreBorders ?? [] { if let image = b.image { out.append(image) } }
        return out
    }

    /// What a cut-out picture leaves of this layer: the subject's outline in the layer's own
    /// coordinates, cut to the layer's outline. None for a layer that shows no cutout.
    var silhouette: CGPath? {
        guard fill.on, kind != .text, kind != .line, !isContainer, let image = fill.image, let data = image.cutout?.outline else { return nil }
        var placing = image.placing(in: frame.size)
        guard let placed = Silhouettes.path(data).copy(using: &placing) else { return nil }
        return placed.intersection(Renderer.outline(of: self), using: .evenOdd)
    }
}

/// Outlines read from their path data once and kept, as hit-testing asks for them as the pointer moves.
nonisolated enum Silhouettes {
    private static let read = Shared([String: CGPath]())

    static func path(_ data: String) -> CGPath {
        if let path = read.with({ $0[data] }) { return path }
        let path = PathData.cgPath(data)
        read.with {
            if $0.count > 200 { $0.removeAll() }
            $0[data] = path
        }
        return path
    }
}
