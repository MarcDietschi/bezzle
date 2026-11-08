import Foundation

// What the shared Model/Live.swift takes from ImageIO and UniformTypeIdentifiers for its glimpses,
// beyond what the importers' stand-ins give (Import/ImportStandIns.swift), only so that it builds:
// on Windows glimpses are made and opened by Host/Glimpses.swift with Skia, off the main thread
// where they are made, as the core's pictures cannot be; LiveGlimpse.of and standIn are not used.

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
    /// Only its extent, and no picture: Live.swift's standIn is not used here (Glimpses.swift
    /// grows and blurs a glimpse in Skia instead).
    func transformed(by t: CGAffineTransform) -> CIImage {
        CIImage(nil, [], extent: extent.applying(t), clamped: clamped)
    }
}
