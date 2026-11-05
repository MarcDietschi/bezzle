@_exported import CoreGraphics

/// The kinds of picture file that can be written. The browser writes PNG, JPEG and WebP.
public func CGImageDestinationCopyTypeIdentifiers() -> CFArray { ["public.png", "public.jpeg", "org.webmproject.webp"] }
