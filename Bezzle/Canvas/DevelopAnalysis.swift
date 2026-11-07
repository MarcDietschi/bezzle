import CoreGraphics
import Foundation

// Reading a picture's look with Core Graphics (`PictureLook` and `Develop.auto` themselves are
// shared, in Model/PictureLook.swift).

nonisolated extension PictureLook {
    /// The look of `picture` as `develop` makes it. Read small: `picture` is best a few hundred pixels.
    init?(_ picture: CGImage, _ develop: Develop?) {
        guard let px = Pixels(Developer.developed(picture, develop), longest: 200) else { return nil }
        self.init(pixels: px)
    }
}

nonisolated extension Develop {
    /// What would suit `picture` best (`auto(pixels:)`), read from it small.
    static func auto(for picture: CGImage) -> Develop {
        guard let px = Pixels(picture, longest: 160) else { return Develop() }
        return auto(pixels: px)
    }
}
