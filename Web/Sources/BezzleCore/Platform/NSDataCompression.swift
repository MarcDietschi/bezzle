import Foundation

// Apple's Foundation compresses and decompresses data; here neither is done yet. Only the icon
// library and live co-working use them, and drawing needs neither.
public extension NSData {
    enum CompressionAlgorithm: Int, Sendable { case lzfse, lz4, lzma, zlib }

    struct Unsupported: Error {}

    func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData { throw Unsupported() }
    func compressed(using algorithm: CompressionAlgorithm) throws -> NSData { throw Unsupported() }
}

public extension NSMutableAttributedString {
    convenience init() { self.init(string: "") }
}
