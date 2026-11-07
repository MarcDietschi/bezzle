import Foundation

// What the shared Model/Live.swift takes from ImageIO and UniformTypeIdentifiers for its glimpses
// (a picture a few dozen pixels across, sent the moment it is placed, shown blurred until the
// picture itself comes), beyond what the importers' stand-ins give (Import/ImportStandIns.swift).
// Here no glimpse is made: a picture on its way shows as a missing one does, a quiet grey, until
// it comes. Glimpses on Windows would make them with Skia (decode, scale, JPEG) instead.

typealias CFURL = URL

nonisolated let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
nonisolated let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
nonisolated let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
nonisolated let kCGImageDestinationLossyCompressionQuality: CFString = "kCGImageDestinationLossyCompressionQuality"

nonisolated func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? { nil }
nonisolated func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? { nil }

nonisolated extension UTType {
    static let jpeg = UTType("public.jpeg")!
}

nonisolated extension CIImage {
    /// Only its extent, and no picture: nothing here draws a glimpse grown, so a glimpse sent
    /// from a Mac (which the importers' Image I/O stand-ins can read) opens to nothing, and the
    /// picture on its way stays grey rather than showing a corner of itself.
    func transformed(by t: CGAffineTransform) -> CIImage {
        CIImage(nil, [], extent: extent.applying(t), clamped: clamped)
    }
}
