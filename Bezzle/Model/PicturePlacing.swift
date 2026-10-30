import CoreGraphics

/// A picture moved and resized by hand inside the layer it fills. Placed this way it keeps its
/// own proportions and always covers the layer, so no edge of the layer ever shows through; where
/// it lies is kept as its offset and scale, so it stays in place as the layer is resized.
///
/// Rectangles here are in the layer's own coordinates, its top left at zero, as the picture is
/// drawn in them: see `Renderer.imageRect`.
nonisolated extension ImageFill {
    /// Points to the picture's pixels when it just covers a layer of `size`.
    func coverScale(in size: CGSize) -> CGFloat {
        max(size.width / max(self.size.width, 1), size.height / max(self.size.height, 1))
    }

    /// How wide the picture is when it just covers a layer of `size`: it is never narrower.
    func coverWidth(in size: CGSize) -> CGFloat {
        max(self.size.width, 1) * coverScale(in: size)
    }

    /// How tall the picture is when `width` wide, at its own proportions.
    func height(forWidth width: CGFloat) -> CGFloat {
        width * max(self.size.height, 1) / max(self.size.width, 1)
    }

    /// The picture covering a layer of `size`, as wide as `rect` and with its middle where `rect`'s
    /// is. Whatever way it was shown, it covers from now on.
    func placed(at rect: CGRect, in size: CGSize) -> ImageFill {
        var i = self
        i.mode = .cover
        i.scale = max(rect.width / coverWidth(in: size), 0.01)
        i.offset = CGPoint(x: size.width > 0 ? (rect.midX - size.width / 2) / size.width : 0,
                           y: size.height > 0 ? (rect.midY - size.height / 2) / size.height : 0)
        return i
    }

    /// `rect`, moved as little as it takes for no edge of it to lie inside a layer of `size`.
    /// Along a side it is too short to cover, it is put in the middle.
    static func covering(_ rect: CGRect, in size: CGSize) -> CGRect {
        var r = rect
        r.origin.x = r.width >= size.width ? min(max(r.minX, size.width - r.width), 0) : (size.width - r.width) / 2
        r.origin.y = r.height >= size.height ? min(max(r.minY, size.height - r.height), 0) : (size.height - r.height) / 2
        return r
    }

    /// How far something pulled `beyond` a limit goes, when it gives less and less the further it
    /// is pulled, as on elastic: never quite as far as `reach`.
    static func elastic(_ beyond: CGFloat, reach: CGFloat) -> CGFloat {
        guard reach > 0, beyond != 0 else { return 0 }
        let stretch = (1 - 1 / (abs(beyond) * 0.55 / reach + 1)) * reach
        return beyond < 0 ? -stretch : stretch
    }
}
