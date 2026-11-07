import CBezzleHost

// What the Mac's importers take from Apple's Compression framework (ZIP archives, Photoshop's
// zipped channels), on Windows: raw DEFLATE, which is what Apple's COMPRESSION_ZLIB means,
// unpacked by Skia's own zlib in the host.

public struct compression_algorithm: RawRepresentable, Equatable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public let COMPRESSION_ZLIB = compression_algorithm(rawValue: 0x205)

/// Unpacks `srcSize` bytes into `dst`, which holds `dstSize`, as Apple's does: how many bytes it
/// wrote (all of `dstSize` when there was more), 0 when they cannot be unpacked.
public func compression_decode_buffer(_ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
                                      _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int {
    guard algorithm == COMPRESSION_ZLIB, dstSize > 0, srcSize > 0 else { return 0 }
    return Int(max(bz_inflate_into(src, Int64(srcSize), dst, Int64(dstSize)), 0))
}
