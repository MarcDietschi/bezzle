import Foundation
import LZFSE

// Apple's Foundation compresses data; here LZFSE is Apple's own reference code (Sources/LZFSE),
// which is what shared designs are packed with. zlib, which only the icon library uses, is not here yet.
nonisolated public extension NSData {
    enum CompressionAlgorithm: Int, Sendable { case lzfse, lz4, lzma, zlib }

    struct Unsupported: Error {}
    struct Corrupt: Error {}

    func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .lzfse else { throw Unsupported() }
        let input = [UInt8](self as Data)
        guard !input.isEmpty else { return NSData() }
        var capacity = Swift.max(input.count * 8, 4096)
        // Int is 32 bits here: 1 << 31 would be negative.
        while capacity <= 1 << 30 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = out.withUnsafeMutableBufferPointer { o in
                input.withUnsafeBufferPointer { i in lzfse_decode_buffer(o.baseAddress!, capacity, i.baseAddress!, input.count, nil) }
            }
            // Filled to the brim, it may not all have fitted: try again with more room.
            if n == 0 { throw Corrupt() }
            if n < capacity { return Data(out[0..<n]) as NSData }
            capacity *= 4
        }
        throw Corrupt()
    }

    func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .lzfse else { throw Unsupported() }
        let input = [UInt8](self as Data)
        let capacity = input.count + input.count / 8 + 4096
        var out = [UInt8](repeating: 0, count: capacity)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: lzfse_encode_scratch_size(), alignment: 16)
        defer { scratch.deallocate() }
        let n = out.withUnsafeMutableBufferPointer { o in
            input.withUnsafeBufferPointer { i in lzfse_encode_buffer(o.baseAddress!, capacity, i.baseAddress!, input.count, scratch) }
        }
        guard n > 0 else { throw Corrupt() }
        return Data(out[0..<n]) as NSData
    }
}

nonisolated public extension NSMutableAttributedString {
    convenience init() { self.init(string: "") }
}
