import Foundation

// What the shared Model/Live.swift takes from ImageIO, Core Image and UniformTypeIdentifiers for
// its glimpses (a picture a few dozen pixels across, sent the moment it is placed, shown blurred
// until the picture itself comes), which Windows does not have. Here they make no glimpse and
// open none: a picture on its way shows as a missing one does, a quiet grey, until it comes.
// Glimpses on Windows would make them with Skia (decode, scale, JPEG) instead.

typealias CFURL = URL

nonisolated final class CGImageSource {}
nonisolated final class CGImageDestination {}

nonisolated let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
nonisolated let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
nonisolated let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
nonisolated let kCGImageDestinationLossyCompressionQuality: CFString = "kCGImageDestinationLossyCompressionQuality"

nonisolated func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? { nil }
nonisolated func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? { nil }
nonisolated func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? { nil }
nonisolated func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? { nil }
nonisolated func CGImageDestinationCreateWithData(_ data: NSMutableData, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? { nil }
nonisolated func CGImageDestinationAddImage(_ destination: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {}
nonisolated func CGImageDestinationFinalize(_ destination: CGImageDestination) -> Bool { false }

nonisolated struct UTType: Sendable {
    let identifier: String
    static let jpeg = UTType(identifier: "public.jpeg")
}

nonisolated extension CIImage {
    /// Only its extent: nothing here draws a glimpse grown, as no glimpse opens here.
    func transformed(by t: CGAffineTransform) -> CIImage {
        CIImage(source, changes, extent: extent.applying(t), clamped: clamped)
    }
}
