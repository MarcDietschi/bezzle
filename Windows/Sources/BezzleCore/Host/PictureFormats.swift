import Foundation
import CBezzleHost

// What Image I/O says it can write, which ExportFormat asks (Model/ExportPreset.swift) to offer
// only those formats, in place of the browser's Platform/ImageIO.swift: PNG, JPEG and WebP, which
// Skia writes, and AVIF when this build has libavif and libaom (Windows/avif.ps1), as a Mac offers
// AVIF only where its Image I/O writes it.

nonisolated public func CGImageDestinationCopyTypeIdentifiers() -> CFArray {
    let types = ["public.png", "public.jpeg", "org.webmproject.webp"] + (bz_avif_available() != 0 ? ["public.avif"] : [])
    return types
}
